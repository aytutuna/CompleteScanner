using System.Collections.Concurrent;

namespace LazyScan.Core;

/// <summary>
/// How long the app waits for the 32-bit helper before it takes the helper for hung, stops it
/// and starts a new one on the next call. They are a little shorter than the limits the app's TWAIN
/// thread puts on the same calls (TwainScannerBackend), so the helper is the one found not responding.
/// </summary>
/// <param name="Hello">From starting the helper to its first reply (the .NET runtime loads).</param>
/// <param name="ListSources">For the driver list (the Data Source Manager loads every driver to ask its name).</param>
/// <param name="Open">For a driver to open (some show a message first).</param>
/// <param name="Request">For any other request: reading what the source offers, setting up a scan, closing.</param>
/// <param name="Enable">For the source to start a scan without its own window (a driver may show a message box there).
/// With its window the wait has no limit: the user is in it.</param>
/// <param name="Grace">Added to the time a disable request gives the source itself.</param>
public sealed record TwainHelperTimeouts(TimeSpan Hello, TimeSpan ListSources, TimeSpan Open, TimeSpan Request,
                                         TimeSpan Enable, TimeSpan Grace)
{
    public static TwainHelperTimeouts Default { get; } = new(
        Hello: TimeSpan.FromSeconds(30), ListSources: TimeSpan.FromSeconds(60), Open: TimeSpan.FromSeconds(50),
        Request: TimeSpan.FromSeconds(50), Enable: TimeSpan.FromSeconds(80), Grace: TimeSpan.FromSeconds(10));
}

/// <summary>
/// The app's end of the helper protocol over one pipe (one helper process). Requests may come
/// from any thread; each waits for its own reply. A reader thread takes replies and events off
/// the pipe, joins chunked image data back together and queues the source's events for
/// <see cref="WaitForEvent"/>. When the pipe breaks, the helper sends something malformed, or a
/// request gets no reply in time, the connection is <see cref="Lost"/>: every waiting request
/// fails, and an acquisition under way ends with a failed transfer.
/// </summary>
public sealed class TwainHelperConnection : IDisposable
{
    /// <summary>What the user is told when the helper process stopped by itself.</summary>
    public const string StoppedMessage =
        "The helper that runs the scanner's 32-bit TWAIN driver stopped unexpectedly. Try again: it restarts on its own.";

    /// <summary>What the user is told when the helper did not answer in time and was stopped.</summary>
    public const string NotRespondingMessage =
        "The scanner's 32-bit TWAIN driver is not responding, so the helper that runs it was stopped. Try again: it "
        + "restarts on its own. If this keeps happening, turn the scanner off and on.";

    private readonly Stream _stream;
    private readonly object _gate = new();
    private readonly object _writeGate = new();
    private readonly Dictionary<int, Pending> _pending = [];
    private readonly BlockingCollection<TwainEvent> _events = [];
    private int _nextId;
    private string? _lostReason;
    /// <summary>An Enable succeeded and the source has not finished or been disabled since.</summary>
    private bool _acquiring;

    // Image data being joined (reader thread only).
    private TwainHelperStripBegin? _strip;
    private bool _native;
    private byte[]? _data;
    private int _received;
    private int _expected;

    private sealed record Pending(TwainHelperMessageType Type, TaskCompletionSource<TwainHelperMessage> Reply);

    public TwainHelperConnection(Stream stream)
    {
        _stream = stream;
        new Thread(ReadLoop) { IsBackground = true, Name = "TWAIN helper replies" }.Start();
    }

    /// <summary>Raised once, on whichever thread noticed, with the user-facing reason (<see cref="StoppedMessage"/> or <see cref="NotRespondingMessage"/>).</summary>
    public event Action<string>? Lost;

    /// <summary>Receives the helper's progress messages (on the reader thread).</summary>
    public Action<ScanProgress>? ProgressHandler { get; set; }

    public bool IsAlive
    {
        get
        {
            lock (_gate) return _lostReason is null;
        }
    }

    /// <summary>Why the connection was lost; null while it works.</summary>
    public string? LostReason
    {
        get
        {
            lock (_gate) return _lostReason;
        }
    }

    /// <summary>Checks the helper speaks this protocol version and runs as a 32-bit process.</summary>
    /// <exception cref="ScanException">It does not, or it did not answer.</exception>
    public void Handshake(TimeSpan timeout, int expectedBits = 32)
    {
        var reply = Request(new TwainHelperHello(TwainHelperProtocol.Version), timeout);
        if (reply is not TwainHelperHelloReply hello)
        {
            Abort(StoppedMessage);
            throw ScanException.SessionFailed("the 32-bit TWAIN helper did not answer as expected.");
        }
        if (hello.Version != TwainHelperProtocol.Version || hello.ProcessBits != expectedBits)
        {
            Abort(StoppedMessage);
            throw ScanException.SessionFailed(
                $"the 32-bit TWAIN helper does not match this version of Lazy Scan (protocol {hello.Version}, "
                + $"{hello.ProcessBits}-bit). Reinstall Lazy Scan.");
        }
    }

    /// <summary>
    /// Sends <paramref name="request"/> and returns its reply (a <see cref="TwainHelperFailure"/> is
    /// returned, not thrown). With no reply within <paramref name="timeout"/>
    /// (<see cref="Timeout.InfiniteTimeSpan"/> = no limit), the connection is lost as not responding.
    /// </summary>
    /// <exception cref="ScanException">The connection is lost, or was lost while waiting.</exception>
    public TwainHelperMessage Request(TwainHelperMessage request, TimeSpan timeout)
    {
        var pending = new Pending(request.Type, new TaskCompletionSource<TwainHelperMessage>(TaskCreationOptions.RunContinuationsAsynchronously));
        int id;
        lock (_gate)
        {
            if (_lostReason is { } reason) throw ScanException.ScanFailed(reason);
            id = ++_nextId;
            _pending[id] = pending;
            // Events of an earlier acquisition still queued belong to nobody once a new one is asked for.
            if (request is TwainHelperDisable) _acquiring = false;
        }
        if (!Write(request with { RequestId = id })) throw ScanException.ScanFailed(LostReason ?? StoppedMessage);
        bool answered;
        try
        {
            answered = pending.Reply.Task.Wait(timeout);
        }
        catch (AggregateException e) when (e.InnerException is ScanException lost)
        {
            throw lost;
        }
        if (!answered)
        {
            Abort(NotRespondingMessage);
            throw ScanException.ScanFailed(NotRespondingMessage);
        }
        return pending.Reply.Task.Result;
    }

    /// <summary>Sends a message that gets no reply (<see cref="TwainHelperCancel"/>); a lost connection is ignored.</summary>
    public void Post(TwainHelperMessage message)
    {
        if (IsAlive) Write(message with { RequestId = 0 });
    }

    /// <summary>The next event of the acquisition, as <see cref="ITwainTransport.WaitForEvent"/>.</summary>
    public TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token)
    {
        int milliseconds = timeout == Timeout.InfiniteTimeSpan
            ? Timeout.Infinite
            : (int)Math.Clamp(timeout.TotalMilliseconds, 0, int.MaxValue);
        try
        {
            return _events.TryTake(out var next, milliseconds, token) ? next : null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    /// <summary>
    /// Gives up on the helper: closes the pipe, fails the waiting requests, ends an acquisition
    /// under way with a failed transfer, and raises <see cref="Lost"/>. Idempotent.
    /// </summary>
    public void Abort(string reason)
    {
        List<Pending> waiting;
        bool endAcquisition;
        lock (_gate)
        {
            if (_lostReason is not null) return;
            _lostReason = reason;
            waiting = [.. _pending.Values];
            _pending.Clear();
            endAcquisition = _acquiring;
            _acquiring = false;
        }
        try
        {
            _stream.Dispose();
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            // Already broken.
        }
        foreach (var pending in waiting) pending.Reply.TrySetException(ScanException.ScanFailed(reason));
        if (endAcquisition)
        {
            _events.Add(new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.Bummer, reason));
            _events.Add(new TwainFinished());
        }
        try
        {
            Lost?.Invoke(reason);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN helper: handling the lost connection failed: {e.Message}");
        }
    }

    public void Dispose() => Abort(StoppedMessage);

    private bool Write(TwainHelperMessage message)
    {
        try
        {
            lock (_writeGate) TwainHelperProtocol.WriteFrame(_stream, message);
            return true;
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
        {
            Abort(StoppedMessage);
            return false;
        }
    }

    private void ReadLoop()
    {
        try
        {
            while (TwainHelperProtocol.ReadFrame(_stream) is { } message) Receive(message);
            Abort(StoppedMessage);
        }
        catch (TwainProtocolException e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN helper: {e.Message}");
            Abort(StoppedMessage);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
        {
            Abort(StoppedMessage);
        }
    }

    private void Receive(TwainHelperMessage message)
    {
        if (_data is not null && message is not (TwainHelperChunk or TwainHelperProgress))
        {
            throw new TwainProtocolException($"A {message.Type} message came in the middle of image data.");
        }
        if (message.RequestId != 0)
        {
            Pending? pending;
            lock (_gate)
            {
                if (_pending.Remove(message.RequestId, out pending) && pending.Type == TwainHelperMessageType.Enable
                    && message is TwainHelperDone)
                {
                    // Whatever is still queued belongs to an earlier acquisition.
                    while (_events.TryTake(out _))
                    {
                    }
                    _acquiring = true;
                }
            }
            if (pending is null) throw new TwainProtocolException($"A reply came for request {message.RequestId}, which is not waiting.");
            pending.Reply.TrySetResult(message);
            return;
        }
        switch (message)
        {
            case TwainHelperImageReady ready:
                Queue(new TwainImageReady(ready.Info));
                break;
            case TwainHelperStripBegin strip:
                _strip = strip;
                BeginData(strip.Length);
                break;
            case TwainHelperNativeBegin native:
                _native = true;
                BeginData(native.Length);
                break;
            case TwainHelperChunk chunk:
                AddData(chunk.Data);
                break;
            case TwainHelperTransferFailed failed:
                Queue(new TwainTransferFailed(failed.ReturnCode, failed.ConditionCode, failed.Detail));
                break;
            case TwainHelperTransferCancelled:
                Queue(new TwainTransferCancelled());
                break;
            case TwainHelperFinished:
                Queue(new TwainFinished());
                lock (_gate) _acquiring = false;
                break;
            case TwainHelperProgress progress:
                try
                {
                    ProgressHandler?.Invoke(new ScanProgress(progress.Fraction, progress.Message));
                }
                catch (Exception e)
                {
                    System.Diagnostics.Trace.TraceWarning($"TWAIN helper: showing progress failed: {e.Message}");
                }
                break;
            default:
                throw new TwainProtocolException($"The helper sent a {message.Type} message as an event.");
        }
    }

    private void BeginData(int length)
    {
        _expected = length;
        _received = 0;
        // Grown as the chunks come, so a forged length cannot make the app allocate up front.
        _data = new byte[Math.Min(length, 4 * TwainHelperProtocol.ChunkSize)];
        if (length == 0) EndData();
    }

    private void AddData(byte[] chunk)
    {
        if (_data is null) throw new TwainProtocolException("Image data came without a strip or image before it.");
        if (chunk.Length == 0 || chunk.Length > _expected - _received)
        {
            throw new TwainProtocolException("Image data does not match the length announced for it.");
        }
        if (_received + chunk.Length > _data.Length)
        {
            int size = (int)Math.Min(_expected, Math.Max((long)_received + chunk.Length, 2L * _data.Length));
            Array.Resize(ref _data, size);
        }
        chunk.CopyTo(_data, _received);
        _received += chunk.Length;
        if (_received == _expected) EndData();
    }

    private void EndData()
    {
        var data = _data!;
        if (data.Length != _expected) Array.Resize(ref data, _expected);
        if (_native)
        {
            Queue(new TwainNativeImage(data));
        }
        else if (_strip is { } strip)
        {
            Queue(new TwainStripReceived(new TwainStrip(strip.Columns, strip.Rows, strip.XOffset, strip.YOffset,
                                                        strip.BytesPerRow, data, strip.Compression)));
        }
        _data = null;
        _strip = null;
        _native = false;
    }

    private void Queue(TwainEvent next)
    {
        lock (_gate)
        {
            // Nobody is scanning: an event of a source that was disabled is dropped.
            if (!_acquiring) return;
        }
        _events.Add(next);
    }
}

/// <summary>
/// <see cref="ITwainTransport"/> over the 32-bit helper: the same scan logic
/// (<see cref="TwainScanLoop"/>) drives a source the helper opened. The connection comes from
/// <c>connect</c> on every call, which starts a new helper when the last one stopped; the source is
/// then opened again in it, so a crash or a hang costs the scan in progress, not the session.
/// Calls that only make sense for the source that was open (stop, disable, two-sided read back)
/// do nothing when that helper is gone: nothing is enabled in a process that no longer exists.
/// </summary>
public sealed class RemoteTwainTransport : ITwainTransport
{
    private readonly Func<TwainHelperConnection> _connect;
    private readonly TwainHelperTimeouts _timeouts;
    private TwainHelperConnection? _opened;
    private bool _closed;

    /// <param name="connect">The live connection, starting the helper if needed; throws <see cref="ScanException"/> when it cannot start.</param>
    /// <param name="sourceName">The source, as <see cref="TwainHelperSource.Name"/>.</param>
    public RemoteTwainTransport(Func<TwainHelperConnection> connect, string sourceName, TwainHelperTimeouts timeouts)
    {
        _connect = connect;
        SourceName = sourceName;
        _timeouts = timeouts;
    }

    public string SourceName { get; }

    /// <summary>Receives the helper's progress messages while this source is open.</summary>
    public Action<ScanProgress>? ProgressHandler { get; set; }

    /// <summary>Opens the source in the helper. Throws <see cref="ScanException"/> when it cannot.</summary>
    public void Open()
    {
        _closed = false;
        Connection();
    }

    /// <summary>The connection the source is open on, opening it first in a helper started since.</summary>
    private TwainHelperConnection Connection()
    {
        if (_closed) throw ScanException.SessionFailed("the scanner was closed.");
        var connection = _connect();
        if (ReferenceEquals(connection, _opened) && connection.IsAlive) return connection;
        _opened = null;
        var reply = connection.Request(new TwainHelperOpen(SourceName), _timeouts.Open);
        if (reply is TwainHelperFailure failure) throw failure.Error.ToException();
        if (reply is not TwainHelperDone) throw Unexpected(connection, reply);
        connection.ProgressHandler = progress => ProgressHandler?.Invoke(progress);
        _opened = connection;
        return connection;
    }

    private static ScanException Unexpected(TwainHelperConnection connection, TwainHelperMessage reply)
    {
        connection.Abort(TwainHelperConnection.StoppedMessage);
        return ScanException.ScanFailed($"the 32-bit TWAIN helper answered with {reply.Type}.");
    }

    /// <summary>The reply of type <typeparamref name="T"/>, or the helper's error thrown as the exception it stands for.</summary>
    private static T Expect<T>(TwainHelperConnection connection, TwainHelperMessage reply) where T : TwainHelperMessage =>
        reply switch
        {
            T expected => expected,
            TwainHelperFailure failure => throw failure.Error.ToException(),
            _ => throw Unexpected(connection, reply),
        };

    public TwainDeviceCaps ReadCapabilities()
    {
        var connection = Connection();
        return Expect<TwainHelperCapabilities>(connection, connection.Request(new TwainHelperReadCapabilities(), _timeouts.Request)).Caps;
    }

    public TwainApplied Apply(TwainScanRequest request)
    {
        var connection = Connection();
        return Expect<TwainHelperApplied>(connection, connection.Request(new TwainHelperApply(request), _timeouts.Request)).Applied;
    }

    public void Enable(bool showDriverWindow)
    {
        var connection = Connection();
        var timeout = showDriverWindow ? Timeout.InfiniteTimeSpan : _timeouts.Enable;
        Expect<TwainHelperDone>(connection, connection.Request(new TwainHelperEnable(showDriverWindow), timeout));
    }

    public TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token)
    {
        if (_opened is { } connection) return connection.WaitForEvent(timeout, token);
        // Nothing can arrive: no helper has the source enabled.
        int milliseconds = timeout == Timeout.InfiniteTimeSpan ? 100 : (int)Math.Clamp(timeout.TotalMilliseconds, 0, 100);
        token.WaitHandle.WaitOne(milliseconds);
        return null;
    }

    public void RequestStop() => Live()?.Post(new TwainHelperCancel());

    /// <summary>
    /// Disables the source in the helper. A driver that stays stuck there does not wedge the app as
    /// it would in-process: the helper is stopped (the next call starts a new one), so the source
    /// counts as disabled.
    /// </summary>
    public bool Disable(TimeSpan timeout)
    {
        if (Live() is not { } connection) return true;
        int milliseconds = timeout == Timeout.InfiniteTimeSpan ? -1 : (int)Math.Clamp(timeout.TotalMilliseconds, 0, int.MaxValue);
        var wait = timeout == Timeout.InfiniteTimeSpan ? Timeout.InfiniteTimeSpan : timeout + _timeouts.Grace;
        try
        {
            if (connection.Request(new TwainHelperDisable(milliseconds), wait) is TwainHelperDisabled { Succeeded: false })
            {
                connection.Abort(TwainHelperConnection.NotRespondingMessage);
            }
            // Disabled, stopped with its helper, or (a failure) never usable: nothing is left enabled.
            return true;
        }
        catch (ScanException)
        {
            // The helper was stopped (or stopped by itself): nothing is enabled any more.
            return true;
        }
    }

    public bool? ReadDuplexEnabled()
    {
        if (Live() is not { } connection) return null;
        try
        {
            return connection.Request(new TwainHelperReadDuplex(), _timeouts.Request) is TwainHelperDuplex duplex ? duplex.Enabled : null;
        }
        catch (ScanException)
        {
            return null;
        }
    }

    /// <summary>Closes the source in the helper (the helper keeps running for the next one).</summary>
    public void Close()
    {
        _closed = true;
        if (Live() is { } connection)
        {
            try
            {
                connection.Request(new TwainHelperClose(), _timeouts.Request);
            }
            catch (ScanException e)
            {
                System.Diagnostics.Trace.TraceWarning($"TWAIN helper: closing the source failed: {e.Message}");
            }
            connection.ProgressHandler = null;
        }
        _opened = null;
    }

    private TwainHelperConnection? Live() => _opened is { IsAlive: true } connection ? connection : null;
}

/// <summary>Which 32-bit sources the app lists, and how.</summary>
public static class TwainHelperSources
{
    /// <summary><see cref="ScannerInfo.Backend"/> of a source reached through the 32-bit helper.</summary>
    public const string Backend = "twain32";

    /// <summary>
    /// <see cref="ScannerInfo.Transport"/> of those sources. <see cref="DeviceMerge.ConnectionLabel"/>
    /// shows it in the connection chooser, and their connection ranks after every other
    /// (<see cref="DeviceMerge.WindowsRanking"/> lists no "twain32"), 64-bit TWAIN included.
    /// </summary>
    public const string Transport = "TWAIN (32-bit driver)";

    /// <summary>Added to the source's name, so a scanner reached only this way says so in its row.</summary>
    public const string NameSuffix = " (32-bit driver)";

    public const string IdPrefix = "twain32:";

    /// <summary>
    /// The sources worth listing: named ones that no 64-bit driver also lists (the app uses
    /// those in-process) and that are not the Windows WIA bridge ("WIA-…", from wiatwain.ds; WIA
    /// reaches those scanners directly), once each, in the helper's order.
    /// </summary>
    public static List<TwainHelperSource> Usable(IEnumerable<TwainHelperSource> sources, IEnumerable<string> sixtyFourBitNames)
    {
        var sixtyFourBit = sixtyFourBitNames.Select(name => name.Trim()).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return sources
            .Where(source => !string.IsNullOrWhiteSpace(source.Name))
            .Where(source => !source.Name.TrimStart().StartsWith("WIA-", StringComparison.OrdinalIgnoreCase))
            .Where(source => !sixtyFourBit.Contains(source.Name.Trim()))
            .Where(source => seen.Add(source.Name))
            .ToList();
    }

    /// <summary>The device-list entry of a source: named with <see cref="NameSuffix"/>, its model the maker and product name.</summary>
    public static ScannerInfo Info(TwainHelperSource source)
    {
        string model = $"{source.Manufacturer?.Trim()} {source.Name.Trim()}".Trim();
        return new ScannerInfo(IdPrefix + source.Name, source.Name.Trim() + NameSuffix, Transport, Backend: Backend,
                               Model: model.Length > 0 ? model : null);
    }

    /// <summary>The source name in an id <see cref="Info"/> made; null for other ids.</summary>
    public static string? SourceName(string deviceId) =>
        deviceId.StartsWith(IdPrefix, StringComparison.Ordinal) ? deviceId[IdPrefix.Length..] : null;
}
