using System.Buffers.Binary;
using System.Collections.Concurrent;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// TWAIN is Windows-only: no Swift counterpart. The app's end of the 32-bit helper
// (TwainHelperConnection, RemoteTwainTransport) against the helper's end (TwainHelperServer)
// over an in-memory pipe, with the existing scan logic (TwainScanLoop) on top: scans, chunked
// image data, errors, cancel, a helper that crashes or stops answering. The real helper process
// is checked in LazyScan.App.Tests (TwainHelperTests).

[Collection(WallClockCollection.Name)]
public class TwainHelperSessionTests
{
    private static readonly TwainLoopTimeouts LoopTimeouts =
        new(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(5));

    private static readonly TwainHelperTimeouts Timeouts = new(
        Hello: TimeSpan.FromSeconds(10), ListSources: TimeSpan.FromSeconds(10), Open: TimeSpan.FromSeconds(10),
        Request: TimeSpan.FromSeconds(10), Enable: TimeSpan.FromSeconds(10), Grace: TimeSpan.FromSeconds(5));

    /// <summary>Sample (x, y) of page n of the stand-in sources.</summary>
    private static byte Sample(int x, int y, int page) => (byte)((x * 3 + y + page * 50) % 256);

    // MARK: - An in-memory pipe and a stand-in helper

    /// <summary>Two connected stream ends. Closing either end ends the pipe: reads see its end, writes fail.</summary>
    private sealed class MemoryPipe
    {
        private sealed class Direction
        {
            public readonly BlockingCollection<byte[]> Blocks = [];
            public byte[]? Current;
            public int Offset;
        }

        private sealed class End(Direction incoming, Direction outgoing) : Stream
        {
            public override int Read(byte[] buffer, int offset, int count)
            {
                while (incoming.Current is null || incoming.Offset == incoming.Current.Length)
                {
                    if (!incoming.Blocks.TryTake(out var block, Timeout.Infinite)) return 0;
                    incoming.Current = block;
                    incoming.Offset = 0;
                }
                int n = Math.Min(count, incoming.Current.Length - incoming.Offset);
                Array.Copy(incoming.Current, incoming.Offset, buffer, offset, n);
                incoming.Offset += n;
                return n;
            }

            public override void Write(byte[] buffer, int offset, int count)
            {
                try
                {
                    outgoing.Blocks.Add(buffer.AsSpan(offset, count).ToArray());
                }
                catch (InvalidOperationException)
                {
                    throw new IOException("The pipe is closed.");
                }
            }

            protected override void Dispose(bool disposing)
            {
                incoming.Blocks.CompleteAdding();
                outgoing.Blocks.CompleteAdding();
                base.Dispose(disposing);
            }

            public override void Flush()
            {
            }

            public override bool CanRead => true;
            public override bool CanWrite => true;
            public override bool CanSeek => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
        }

        public static (Stream App, Stream Helper) Create()
        {
            var toHelper = new Direction();
            var toApp = new Direction();
            return (new End(toApp, toHelper), new End(toHelper, toApp));
        }
    }

    /// <summary>What a stand-in source does.</summary>
    private sealed class Behavior
    {
        public int Pages { get; init; } = 1;
        public int Width { get; init; } = 700;
        public int Height { get; init; } = 400;
        public bool Native { get; init; }
        public int DelayMs { get; init; }
        public bool JamAfterFirst { get; init; }
        public TwainException? ApplyError { get; init; }
        public bool HangOnCapabilities { get; init; }
        public bool StuckOnDisable { get; init; }
        public IReadOnlyList<int> Resolutions { get; init; } = [100, 200];
    }

    private sealed class FakeHost : ITwainHelperHost
    {
        public readonly Dictionary<string, Behavior> Sources = new()
        {
            ["Scanner"] = new Behavior { Pages = 2 },
            ["Native"] = new Behavior { Native = true, Width = 300 },
            ["Jam"] = new Behavior { Pages = 3, JamAfterFirst = true },
            ["Offline"] = new Behavior { ApplyError = new TwainException("Setting up the scan", TwainReturnCodes.Failure, TwainConditionCodes.CheckDeviceOnline) },
            ["Slow"] = new Behavior { Pages = 100, Width = 50, Height = 50, DelayMs = 20 },
            ["Silent"] = new Behavior { HangOnCapabilities = true },
            ["Stuck"] = new Behavior { StuckOnDisable = true },
            // A consumer flatbed's ICAP_XRESOLUTION range, 50...9600 dpi in 1 dpi steps, as NTwainDriver expands it.
            ["Fine"] = new Behavior { Resolutions = [.. ResolutionList.ExpandRange(50, 9600, 1)] },
        };

        public readonly ConcurrentQueue<string> Calls = new();
        public readonly ManualResetEventSlim Release = new();

        public TwainHelperSourceList ListSources() =>
            new(TwainAvailability.Available, [.. Sources.Keys.Select(name => new TwainHelperSource(name, "Acme"))]);

        public ITwainTransport Open(string name)
        {
            Calls.Enqueue($"open {name}");
            if (name == "Busy") throw ScanException.ForProblem(ScannerProblem.Busy, "TWAIN TWCC_MAXCONNECTIONS");
            return Sources.TryGetValue(name, out var behavior)
                ? new FakeSource(this, behavior)
                : throw ScanException.DeviceUnavailable($"The TWAIN driver \"{name}\" is no longer installed.");
        }

        public void Close(ITwainTransport source) => Calls.Enqueue("close");
    }

    private sealed class FakeSource(FakeHost host, Behavior behavior) : ITwainTransport
    {
        private IEnumerator<TwainEvent>? _script;
        private bool _stop;

        public TwainDeviceCaps ReadCapabilities()
        {
            host.Calls.Enqueue("caps");
            if (behavior.HangOnCapabilities) host.Release.Wait();
            return new TwainDeviceCaps { HasFeeder = true, Resolutions = behavior.Resolutions, PixelTypes = [1, 2] };
        }

        public TwainApplied Apply(TwainScanRequest request)
        {
            host.Calls.Enqueue("apply");
            if (behavior.ApplyError is { } error) throw error;
            return new TwainApplied(behavior.Native ? TwainTransferMechanisms.Native : TwainTransferMechanisms.Memory);
        }

        public void Enable(bool showDriverWindow)
        {
            host.Calls.Enqueue("enable");
            _stop = false;
            _script = Script().GetEnumerator();
        }

        public TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token)
        {
            if (_script is null) return null;
            if (_stop || !_script.MoveNext())
            {
                _script = null;
                return new TwainFinished();
            }
            if (behavior.DelayMs > 0) Thread.Sleep(behavior.DelayMs);
            return _script.Current;
        }

        public void RequestStop()
        {
            host.Calls.Enqueue("stop");
            _stop = true;
        }

        public bool Disable(TimeSpan timeout)
        {
            host.Calls.Enqueue("disable");
            _script = null;
            return !behavior.StuckOnDisable;
        }

        public bool? ReadDuplexEnabled() => true;

        private IEnumerable<TwainEvent> Script()
        {
            for (int page = 1; page <= behavior.Pages; page++)
            {
                if (behavior.JamAfterFirst && page == 2)
                {
                    yield return new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.PaperJam, null);
                    yield break;
                }
                if (behavior.Native)
                {
                    yield return new TwainImageReady(null);
                    yield return new TwainNativeImage(Bitmap(behavior.Width, behavior.Height, page));
                    continue;
                }
                yield return new TwainImageReady(new TwainImageInfo(behavior.Width, behavior.Height, TwainPixelTypes.Gray, 8, 200, 200));
                // One strip of the whole page: larger than a chunk for the default size.
                var data = new byte[behavior.Width * behavior.Height];
                for (int y = 0; y < behavior.Height; y++)
                {
                    for (int x = 0; x < behavior.Width; x++) data[y * behavior.Width + x] = Sample(x, y, page);
                }
                yield return new TwainStripReceived(new TwainStrip(behavior.Width, behavior.Height, 0, 0, behavior.Width, data));
            }
        }

        private static byte[] Bitmap(int width, int height, int page)
        {
            int stride = (width * 3 + 3) & ~3;
            var bitmap = new byte[40 + stride * height];
            BinaryPrimitives.WriteInt32LittleEndian(bitmap.AsSpan(0), 40);
            BinaryPrimitives.WriteInt32LittleEndian(bitmap.AsSpan(4), width);
            BinaryPrimitives.WriteInt32LittleEndian(bitmap.AsSpan(8), height);
            BinaryPrimitives.WriteInt16LittleEndian(bitmap.AsSpan(12), 1);
            BinaryPrimitives.WriteInt16LittleEndian(bitmap.AsSpan(14), 24);
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    int at = 40 + (height - 1 - y) * stride + x * 3;
                    bitmap[at] = Sample(x, y, page);
                    bitmap[at + 1] = 0;
                    bitmap[at + 2] = 255;
                }
            }
            return bitmap;
        }
    }

    /// <summary>One stand-in helper: a server on its own thread at the far end of a pipe.</summary>
    private sealed class FakeHelper
    {
        private readonly Stream _helperEnd;
        public readonly FakeHost Host;
        public readonly TwainHelperConnection Connection;
        public readonly Thread ServerThread;

        public FakeHelper(FakeHost? host = null, int bits = 32)
        {
            Host = host ?? new FakeHost();
            var (app, helper) = MemoryPipe.Create();
            _helperEnd = helper;
            var server = new TwainHelperServer(helper, Host, bits) { PumpInterval = TimeSpan.FromMilliseconds(5) };
            ServerThread = new Thread(server.Run) { IsBackground = true };
            ServerThread.Start();
            Connection = new TwainHelperConnection(app);
        }

        public static FakeHelper Started(FakeHost? host = null)
        {
            var helper = new FakeHelper(host);
            helper.Connection.Handshake(TimeSpan.FromSeconds(10));
            return helper;
        }

        /// <summary>The helper process dies: its end of the pipe closes.</summary>
        public void Crash() => _helperEnd.Dispose();
    }

    private static TwainScanResult Scan(RemoteTwainTransport transport, ScanSource source = ScanSource.DocumentFeeder,
                                        CancellationToken token = default, Action<ScanProgress>? progress = null)
    {
        var caps = transport.ReadCapabilities();
        var settings = new ScanSettings { Source = source, ColorMode = ColorMode.Grayscale, Resolution = 200 };
        var request = TwainScanRequests.ForScan(settings, null, caps);
        // As the app's session does before every scan.
        Assert.True(transport.Disable(LoopTimeouts.Stop));
        return TwainScanLoop.Run(transport, request, LoopTimeouts, token, progress);
    }

    private static RemoteTwainTransport Opened(FakeHelper helper, string source)
    {
        var transport = new RemoteTwainTransport(() => helper.Connection, source, Timeouts);
        transport.Open();
        return transport;
    }

    // MARK: - Tests

    [Fact]
    public void FeederScan_ThroughTheHelper_ReturnsEveryPageWhole()
    {
        var helper = FakeHelper.Started();
        var transport = Opened(helper, "Scanner");
        var result = Scan(transport);

        Assert.Null(result.Error);
        Assert.Null(result.Stop);
        Assert.Equal(2, result.Pages.Count);
        for (int page = 1; page <= 2; page++)
        {
            var image = result.Pages[page - 1].Image;
            Assert.Equal((700, 400), (image.Width, image.Height));
            Assert.Equal(200, result.Pages[page - 1].Dpi);
            foreach (var (x, y) in new[] { (0, 0), (699, 0), (350, 200), (699, 399) })
            {
                Assert.Equal(Sample(x, y, page), image.Pixels[(y * image.Width + x) * 4]);
            }
        }
        transport.Close();
        Assert.Equal(["open Scanner", "caps", "disable", "apply", "enable", "disable", "close"], helper.Host.Calls);
    }

    [Fact]
    public void NativeImages_ArriveWholeWithProgress()
    {
        var helper = FakeHelper.Started();
        var transport = Opened(helper, "Native");
        var fractions = new ConcurrentQueue<double>();
        transport.ProgressHandler = progress =>
        {
            if (progress.Fraction is { } fraction) fractions.Enqueue(fraction);
        };
        var result = Scan(transport, ScanSource.Flatbed);

        Assert.Null(result.Error?.Message);
        var image = Assert.Single(result.Pages).Image;
        Assert.Equal((300, 400), (image.Width, image.Height));
        Assert.Equal(Sample(17, 33, 1), image.Pixels[(33 * 300 + 17) * 4 + 2]);
        // 360 kB in chunks of 256 kB: halfway, then whole.
        Assert.Equal([0.5, 1.0], fractions);
    }

    [Fact]
    public void SourceErrors_ReachTheAppAsTheSameScannerProblems()
    {
        var helper = FakeHelper.Started();

        var busy = Assert.Throws<ScanException>(() => Opened(helper, "Busy"));
        Assert.Equal(ScannerProblem.Busy, busy.Problem);
        Assert.Equal(ScanException.ForProblem(ScannerProblem.Busy, "TWAIN TWCC_MAXCONNECTIONS").Message, busy.Message);

        var missing = Assert.Throws<ScanException>(() => Opened(helper, "Gone"));
        Assert.Equal(ScanErrorKind.DeviceUnavailable, missing.Kind);

        var offline = Scan(Opened(helper, "Offline"));
        Assert.Equal(ScannerProblem.Offline, offline.Error?.Problem);

        var jam = Scan(Opened(helper, "Jam"));
        Assert.Single(jam.Pages);
        Assert.Equal(ScannerProblem.PaperJam, jam.Stop?.Problem);
    }

    [Fact]
    public void Cancel_StopsTheSourceInTheHelper()
    {
        var helper = FakeHelper.Started();
        var transport = Opened(helper, "Slow");
        using var cancel = new CancellationTokenSource();
        var result = Scan(transport, token: cancel.Token, progress: _ => cancel.Cancel());

        Assert.Equal(ScanErrorKind.Cancelled, result.Error?.Kind);
        Assert.False(result.DriverStuck);
        Assert.Contains("stop", helper.Host.Calls);
        // The session goes on: the next scan works.
        Assert.Equal(2, Scan(Opened(helper, "Scanner"), ScanSource.Flatbed).Pages.Count);
    }

    [Fact]
    public void ACrashedHelper_EndsTheScanClearly_AndTheNextCallUsesANewHelper()
    {
        var helpers = new List<FakeHelper> { FakeHelper.Started() };
        FakeHelper Current()
        {
            if (!helpers[^1].Connection.IsAlive) helpers.Add(FakeHelper.Started());
            return helpers[^1];
        }
        var transport = new RemoteTwainTransport(() => Current().Connection, "Slow", Timeouts);
        transport.Open();
        var caps = transport.ReadCapabilities();
        var request = TwainScanRequests.ForScan(new ScanSettings { Source = ScanSource.DocumentFeeder }, null, caps);
        bool crashed = false;
        var result = TwainScanLoop.Run(transport, request, LoopTimeouts, CancellationToken.None, progress: _ =>
        {
            if (crashed) return;
            crashed = true;
            helpers[0].Crash();
        });

        // The page that arrived is kept; the batch stops saying why.
        Assert.NotEmpty(result.Pages);
        Assert.Contains(TwainHelperConnection.StoppedMessage, result.Stop?.Reason);
        Assert.False(result.DriverStuck);
        Assert.False(helpers[0].Connection.IsAlive);
        Assert.True(helpers[0].ServerThread.Join(TimeSpan.FromSeconds(5)));

        // The same session scans again in a new helper, which opens the source first.
        var again = Scan(transport);
        Assert.Equal(100, again.Pages.Count);
        Assert.Equal(2, helpers.Count);
        Assert.Equal("open Slow", helpers[1].Host.Calls.First());
    }

    [Fact]
    public void AHelperThatCrashesBeforeAnyPage_FailsTheScanWithTheReason()
    {
        var helper = FakeHelper.Started();
        var transport = Opened(helper, "Slow");
        var caps = transport.ReadCapabilities();
        var request = TwainScanRequests.ForScan(new ScanSettings { Source = ScanSource.DocumentFeeder }, null, caps);
        transport.Apply(request);
        helper.Crash();
        var error = Assert.Throws<ScanException>(() => transport.Enable(false));
        Assert.Equal(ScanException.ScanFailed(TwainHelperConnection.StoppedMessage).Message, error.Message);
        // Nothing is enabled in a helper that is gone.
        Assert.True(transport.Disable(TimeSpan.FromSeconds(1)));
        Assert.Null(transport.ReadDuplexEnabled());
        transport.RequestStop();
    }

    [Fact]
    public void AnUnansweredRequest_StopsTheHelperAsNotResponding()
    {
        var host = new FakeHost();
        var helper = FakeHelper.Started(host);
        string? lost = null;
        helper.Connection.Lost += reason => lost = reason;
        var transport = new RemoteTwainTransport(() => helper.Connection, "Silent", Timeouts with { Request = TimeSpan.FromMilliseconds(300) });
        transport.Open();

        var error = Assert.Throws<ScanException>(transport.ReadCapabilities);
        Assert.Equal(ScanException.ScanFailed(TwainHelperConnection.NotRespondingMessage).Message, error.Message);
        Assert.Equal(TwainHelperConnection.NotRespondingMessage, lost);
        Assert.False(helper.Connection.IsAlive);
        Assert.Throws<ScanException>(() => helper.Connection.Request(new TwainHelperListSources(), TimeSpan.FromSeconds(1)));
        host.Release.Set();
    }

    [Fact]
    public void ASourceStuckInTheHelper_StopsTheHelper_InsteadOfWedgingTheApp()
    {
        var helpers = new List<FakeHelper> { FakeHelper.Started() };
        FakeHelper Current()
        {
            if (!helpers[^1].Connection.IsAlive) helpers.Add(FakeHelper.Started());
            return helpers[^1];
        }
        var transport = new RemoteTwainTransport(() => Current().Connection, "Stuck", Timeouts);
        transport.Open();
        // The disable before the scan already finds it stuck: that helper is stopped, the scan goes on in a new one.
        var result = Scan(transport, ScanSource.Flatbed);
        Assert.False(result.DriverStuck);
        Assert.Single(result.Pages);
        Assert.False(helpers[0].Connection.IsAlive);
        Assert.Equal(TwainHelperConnection.NotRespondingMessage, helpers[0].Connection.LostReason);
        Assert.True(helpers.Count >= 2);
    }

    [Fact]
    public void Handshake_RefusesAHelperOfAnotherKind()
    {
        // A 64-bit helper is not what the app starts it for.
        var helper = new FakeHelper(bits: 64);
        var error = Assert.Throws<ScanException>(() => helper.Connection.Handshake(TimeSpan.FromSeconds(10)));
        Assert.Contains("does not match", error.Message);
        Assert.False(helper.Connection.IsAlive);
    }

    [Fact]
    public void Server_StopsAtAHelloOfAnotherVersion_AndAnswersNothingElseFirst()
    {
        var (app, helperEnd) = MemoryPipe.Create();
        var server = new TwainHelperServer(helperEnd, new FakeHost(), 32);
        var thread = new Thread(server.Run) { IsBackground = true };
        thread.Start();
        TwainHelperProtocol.WriteFrame(app, new TwainHelperHello(TwainHelperProtocol.Version + 1) { RequestId = 1 });
        var reply = Assert.IsType<TwainHelperHelloReply>(TwainHelperProtocol.ReadFrame(app));
        Assert.Equal((TwainHelperProtocol.Version, 32), (reply.Version, reply.ProcessBits));
        Assert.True(thread.Join(TimeSpan.FromSeconds(5)));

        // Without a hello first, nothing is served.
        var (app2, helperEnd2) = MemoryPipe.Create();
        var thread2 = new Thread(new TwainHelperServer(helperEnd2, new FakeHost(), 32).Run) { IsBackground = true };
        thread2.Start();
        TwainHelperProtocol.WriteFrame(app2, new TwainHelperListSources { RequestId = 1 });
        Assert.True(thread2.Join(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void RequestsWithoutAnOpenSource_AreErrors_AndListingWorks()
    {
        var helper = FakeHelper.Started();
        var reply = helper.Connection.Request(new TwainHelperReadCapabilities(), TimeSpan.FromSeconds(10));
        var failure = Assert.IsType<TwainHelperFailure>(reply);
        Assert.Equal(ScanErrorKind.SessionFailed, Assert.IsType<ScanException>(failure.Error.ToException()).Kind);

        var list = Assert.IsType<TwainHelperSourceList>(helper.Connection.Request(new TwainHelperListSources(), TimeSpan.FromSeconds(10)));
        Assert.Equal(TwainAvailability.Available, list.Availability);
        Assert.Contains(new TwainHelperSource("Scanner", "Acme"), list.Sources);
    }

    [Fact]
    public void AFineResolutionRange_CrossesWhole_AndTheScannerWorks()
    {
        var helper = FakeHelper.Started();
        var transport = Opened(helper, "Fine");
        var caps = transport.ReadCapabilities();
        Assert.Equal(ResolutionList.ExpandRange(50, 9600, 1), caps.Resolutions);
        Assert.Equal(9551, caps.Resolutions.Count);
        // The app offers what it would offer for the same driver loaded in-process.
        var local = new TwainDeviceCaps { HasFeeder = true, Resolutions = [.. ResolutionList.ExpandRange(50, 9600, 1)], PixelTypes = [1, 2] };
        Assert.Equal(TwainScanRequests.Capabilities(local).SupportedResolutions, TwainScanRequests.Capabilities(caps).SupportedResolutions);
        var result = Scan(transport);
        Assert.Null(result.Error);
        Assert.Single(result.Pages);
    }

    [Fact]
    public void AReplyTooLargeForAFrame_IsAnError_AndTheHelperGoesOn()
    {
        var host = new FakeHost();
        for (int i = 0; i < 100; i++) host.Sources[new string('x', 5000) + i] = new Behavior();
        var helper = FakeHelper.Started(host);
        var failure = Assert.IsType<TwainHelperFailure>(helper.Connection.Request(new TwainHelperListSources(), TimeSpan.FromSeconds(10)));
        Assert.Equal(ScanErrorKind.ScanFailed, Assert.IsType<ScanException>(failure.Error.ToException()).Kind);
        Assert.True(helper.Connection.IsAlive);
        Assert.Equal(2, Scan(Opened(helper, "Scanner"), ScanSource.Flatbed).Pages.Count);
    }

    [Fact]
    public async Task GarbageFromTheHelper_LosesTheConnection()
    {
        var (app, helperEnd) = MemoryPipe.Create();
        var connection = new TwainHelperConnection(app);
        var lost = new TaskCompletionSource<string>();
        connection.Lost += reason => lost.TrySetResult(reason);
        helperEnd.Write([0xFF, 0xFF, 0xFF, 0x7F, 1, 2, 3]);
        Assert.Equal(TwainHelperConnection.StoppedMessage, await lost.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.False(connection.IsAlive);
    }

    [Fact]
    public void Shutdown_ClosesTheSourceAndEndsTheServer()
    {
        var helper = FakeHelper.Started();
        Opened(helper, "Scanner");
        Assert.IsType<TwainHelperDone>(helper.Connection.Request(new TwainHelperShutdown(), TimeSpan.FromSeconds(10)));
        Assert.True(helper.ServerThread.Join(TimeSpan.FromSeconds(5)));
        Assert.Equal(["open Scanner", "close"], helper.Host.Calls);
    }
}
