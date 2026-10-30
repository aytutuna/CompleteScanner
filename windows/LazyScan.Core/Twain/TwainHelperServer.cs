using System.Collections.Concurrent;

namespace LazyScan.Core;

/// <summary>What the 32-bit helper runs the protocol against: its TWAIN library, or a stand-in in tests.</summary>
public interface ITwainHelperHost
{
    /// <summary>Whether the Data Source Manager could be used, and the sources it lists.</summary>
    TwainHelperSourceList ListSources();

    /// <summary>Opens a source (state 4). Throws <see cref="ScanException"/> or <see cref="TwainException"/> when it cannot.</summary>
    ITwainTransport Open(string name);

    /// <summary>Closes a source <see cref="Open"/> returned, whatever state it is in.</summary>
    void Close(ITwainTransport source);
}

/// <summary>
/// The helper's end of the protocol (<see cref="TwainHelperProtocol"/>). A reader thread takes
/// requests off the pipe; <see cref="Run"/> carries them out one at a time on the thread that
/// calls it (the helper's TWAIN thread), so every <see cref="ITwainTransport"/> call is made from
/// that one thread, as the interface requires. While a source is enabled, <see cref="Run"/>
/// alternates between the requests (Cancel among them) and passing the source's events on,
/// splitting image data into chunks. One source is open at a time.
/// </summary>
public sealed class TwainHelperServer
{
    private readonly Stream _stream;
    private readonly ITwainHelperHost _host;
    private readonly int _processBits;
    private readonly BlockingCollection<TwainHelperMessage> _requests = [];
    private ITwainTransport? _source;
    /// <summary>The open source is enabled: its events are passed on until it finishes or is disabled.</summary>
    private bool _acquiring;
    private bool _greeted;
    private volatile bool _disconnected;

    /// <param name="processBits">32 in the helper; reported in the hello reply.</param>
    public TwainHelperServer(Stream stream, ITwainHelperHost host, int processBits)
    {
        _stream = stream;
        _host = host;
        _processBits = processBits;
    }

    /// <summary>How long one wait for a source event lasts before the requests are looked at again.</summary>
    public TimeSpan PumpInterval { get; init; } = TimeSpan.FromMilliseconds(25);

    /// <summary>
    /// Raised on the reader thread when the app's end of the pipe closes or breaks, or sends
    /// something malformed. <see cref="Run"/> returns once the request in hand is done; the
    /// helper uses this to exit even when a driver call never returns.
    /// </summary>
    public event Action? Disconnected;

    /// <summary>Serves requests until the app asks the helper to shut down or the pipe closes. Closes the open source on the way out.</summary>
    public void Run()
    {
        var reader = new Thread(ReadLoop) { IsBackground = true, Name = "TWAIN helper pipe" };
        reader.Start();
        try
        {
            while (true)
            {
                TwainHelperMessage? request;
                if (_acquiring && _source is { } source)
                {
                    if (!_requests.TryTake(out request))
                    {
                        if (_requests.IsCompleted) break;
                        var next = source.WaitForEvent(PumpInterval, CancellationToken.None);
                        if (next is not null && !Forward(next)) break;
                        continue;
                    }
                }
                else if (!_requests.TryTake(out request, Timeout.Infinite))
                {
                    break;
                }
                if (!Handle(request)) break;
            }
        }
        finally
        {
            CloseSource();
        }
    }

    private void ReadLoop()
    {
        try
        {
            while (TwainHelperProtocol.ReadFrame(_stream) is { } message) _requests.Add(message);
        }
        catch (Exception e) when (e is TwainProtocolException or IOException or ObjectDisposedException)
        {
            // The app went away or sent something this helper cannot read: either way, stop.
        }
        _disconnected = true;
        _requests.CompleteAdding();
        Disconnected?.Invoke();
    }

    /// <summary>Carries out one request; false when the helper should stop.</summary>
    private bool Handle(TwainHelperMessage request)
    {
        if (!_greeted)
        {
            if (request is not TwainHelperHello hello) return false;
            _greeted = true;
            if (!Reply(request, new TwainHelperHelloReply(TwainHelperProtocol.Version, _processBits))) return false;
            return hello.Version == TwainHelperProtocol.Version;
        }
        switch (request)
        {
            case TwainHelperCancel:
                _source?.RequestStop();
                return true;
            case TwainHelperShutdown:
                CloseSource();
                Reply(request, new TwainHelperDone());
                return false;
            case TwainHelperListSources:
                return Answer(request, "Listing the 32-bit TWAIN drivers", () => _host.ListSources());
            case TwainHelperOpen open:
                return Answer(request, "Opening the scanner", () =>
                {
                    CloseSource();
                    _source = _host.Open(open.Name);
                    return new TwainHelperDone();
                });
            case TwainHelperReadCapabilities:
                return Answer(request, "Reading the scanner's capabilities",
                              () => new TwainHelperCapabilities(OpenSource().ReadCapabilities()));
            case TwainHelperApply apply:
                return Answer(request, "Setting up the scan", () => new TwainHelperApplied(OpenSource().Apply(apply.Request)));
            case TwainHelperEnable enable:
                return Answer(request, "Starting the scan", () =>
                {
                    OpenSource().Enable(enable.ShowDriverWindow);
                    _acquiring = true;
                    return new TwainHelperDone();
                });
            case TwainHelperDisable disable:
                return Answer(request, "Stopping the scan", () =>
                {
                    var timeout = disable.TimeoutMilliseconds < 0
                        ? Timeout.InfiniteTimeSpan
                        : TimeSpan.FromMilliseconds(disable.TimeoutMilliseconds);
                    bool succeeded = _source?.Disable(timeout) ?? true;
                    _acquiring = false;
                    return new TwainHelperDisabled(succeeded);
                });
            case TwainHelperReadDuplex:
                return Answer(request, "Reading two-sided scanning", () => new TwainHelperDuplex(OpenSource().ReadDuplexEnabled()));
            case TwainHelperClose:
                return Answer(request, "Closing the scanner", () =>
                {
                    CloseSource();
                    return new TwainHelperDone();
                });
            default:
                return Reply(request, new TwainHelperFailure(new TwainHelperError(
                    TwainHelperErrorKind.Scan, "Reading the request", 0, 0, ScanErrorKind.ScanFailed, null,
                    $"the TWAIN helper does not take {request.Type} messages.")));
        }
    }

    private ITwainTransport OpenSource() =>
        _source ?? throw ScanException.SessionFailed("no scanner is open in the 32-bit TWAIN helper.");

    private void CloseSource()
    {
        _acquiring = false;
        if (_source is not { } source) return;
        _source = null;
        try
        {
            _host.Close(source);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN helper: closing the source failed: {e.Message}");
        }
    }

    /// <summary>Runs <paramref name="work"/> and replies with its result, or with the error it threw.</summary>
    private bool Answer(TwainHelperMessage request, string operation, Func<TwainHelperMessage> work)
    {
        TwainHelperMessage reply;
        try
        {
            reply = work();
        }
        catch (Exception e)
        {
            reply = new TwainHelperFailure(TwainHelperError.From(e, operation));
        }
        return Reply(request, reply);
    }

    private bool Reply(TwainHelperMessage request, TwainHelperMessage reply) => Send(reply with { RequestId = request.RequestId });

    /// <summary>Passes one source event on; false when the pipe is gone.</summary>
    private bool Forward(TwainEvent next)
    {
        switch (next)
        {
            case TwainImageReady ready:
                return Send(new TwainHelperImageReady(ready.Info));
            case TwainStripReceived received:
            {
                var strip = received.Strip;
                return Send(new TwainHelperStripBegin(strip.Columns, strip.Rows, strip.XOffset, strip.YOffset,
                                                      strip.BytesPerRow, strip.Compression, strip.Data.Length))
                       && SendChunks(strip.Data, progress: false);
            }
            case TwainNativeImage native:
                return Send(new TwainHelperNativeBegin(native.Bitmap.Length)) && SendChunks(native.Bitmap, progress: true);
            case TwainTransferFailed failed:
                return Send(new TwainHelperTransferFailed(failed.ReturnCode, failed.ConditionCode, failed.Detail));
            case TwainTransferCancelled:
                return Send(new TwainHelperTransferCancelled());
            case TwainFinished:
                _acquiring = false;
                return Send(new TwainHelperFinished());
            default:
                return true;
        }
    }

    /// <summary>Sends <paramref name="data"/> in chunks; with <paramref name="progress"/>, says how far a long image has come.</summary>
    private bool SendChunks(byte[] data, bool progress)
    {
        int chunks = (data.Length + TwainHelperProtocol.ChunkSize - 1) / TwainHelperProtocol.ChunkSize;
        for (int i = 0; i < chunks; i++)
        {
            int start = i * TwainHelperProtocol.ChunkSize;
            int length = Math.Min(TwainHelperProtocol.ChunkSize, data.Length - start);
            if (!Send(new TwainHelperChunk(data.AsSpan(start, length).ToArray()))) return false;
            if (progress && chunks > 1 && !Send(new TwainHelperProgress((double)(i + 1) / chunks, "Receiving the page from the scanner…")))
            {
                return false;
            }
        }
        return true;
    }

    private bool Send(TwainHelperMessage message)
    {
        if (_disconnected) return false;
        byte[] frame;
        try
        {
            frame = TwainHelperProtocol.EncodeFrame(message);
        }
        catch (ArgumentException e)
        {
            // Too large for a frame (a source list beyond reason): a reply says so, an event is dropped.
            System.Diagnostics.Trace.TraceWarning($"TWAIN helper: {e.Message}");
            if (message.RequestId == 0) return true;
            frame = TwainHelperProtocol.EncodeFrame(new TwainHelperFailure(new TwainHelperError(
                TwainHelperErrorKind.Scan, "Answering", 0, 0, ScanErrorKind.ScanFailed, null,
                "the 32-bit TWAIN helper had more to say than fits in one message.")) { RequestId = message.RequestId });
        }
        try
        {
            _stream.Write(frame);
            _stream.Flush();
            return true;
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            return false;
        }
    }
}
