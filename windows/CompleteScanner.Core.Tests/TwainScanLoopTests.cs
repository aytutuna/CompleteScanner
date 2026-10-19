using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// TWAIN is Windows-only: no Swift counterpart. The scan loop runs against a scripted
// transport: each WaitForEvent hands out the next scripted event, and a null entry stands
// for "nothing arrived before the timeout".

public class TwainScanLoopTests
{
    private sealed class FakeTransport : ITwainTransport
    {
        private readonly Queue<TwainEvent?> _script;

        public FakeTransport(params TwainEvent?[] script) => _script = new(script);

        public TwainApplied Applied { get; init; } = new(TwainTransferMechanisms.Memory);
        public TwainException? ApplyError { get; init; }
        public TwainException? EnableError { get; init; }
        /// <summary>RequestStop makes the source finish (as a real one does after MSG_RESET).</summary>
        public bool FinishesWhenStopped { get; init; } = true;
        public bool DisableSucceeds { get; init; } = true;
        /// <summary>Cancel this token when the script runs out of events before the cancel point.</summary>
        public CancellationTokenSource? CancelAfterEvents { get; init; }
        public int CancelAt { get; init; } = -1;

        public List<string> Calls { get; } = [];
        public List<TimeSpan> Waits { get; } = [];
        public TwainScanRequest? AppliedRequest { get; private set; }
        public bool? EnabledWithWindow { get; private set; }
        private int _handedOut;

        public TwainDeviceCaps ReadCapabilities() => new();

        public TwainApplied Apply(TwainScanRequest request)
        {
            Calls.Add("apply");
            AppliedRequest = request;
            if (ApplyError is { } error) throw error;
            return Applied;
        }

        public void Enable(bool showDriverWindow)
        {
            Calls.Add("enable");
            EnabledWithWindow = showDriverWindow;
            if (EnableError is { } error) throw error;
        }

        public TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token)
        {
            Waits.Add(timeout);
            if (_handedOut == CancelAt) CancelAfterEvents?.Cancel();
            if (token.IsCancellationRequested) return null;
            _handedOut++;
            if (_script.Count == 0)
            {
                // Waiting for an event that never comes.
                return null;
            }
            return _script.Dequeue();
        }

        public void RequestStop()
        {
            Calls.Add("stop");
            _script.Clear();
            if (FinishesWhenStopped) _script.Enqueue(new TwainFinished());
        }

        public bool Disable(TimeSpan timeout)
        {
            Calls.Add("disable");
            return DisableSucceeds;
        }
    }

    private static readonly TwainLoopTimeouts Timeouts =
        new(TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(5));

    private static TwainScanRequest Flatbed(bool driverWindow = false) =>
        new(false, TwainPixelTypes.Gray, 8, 300, new RectD(0, 0, 8.5, 11.7), 1, driverWindow, true);

    private static TwainScanRequest Feeder() =>
        new(true, TwainPixelTypes.Gray, 8, 200, new RectD(0, 0, 8.5, 14), -1, false, true);

    private static TwainImageInfo GrayInfo(double dpi = 0) => new(2, 2, TwainPixelTypes.Gray, 8, dpi, dpi);

    /// <summary>The events of one complete 2 × 2 gray page in two strips, with its first sample value.</summary>
    private static TwainEvent[] GrayPage(byte value, double dpi = 0) =>
    [
        new TwainImageReady(GrayInfo(dpi)),
        new TwainStripReceived(new TwainStrip(2, 1, 0, 0, 2, [value, value])),
        new TwainStripReceived(new TwainStrip(2, 1, 0, 1, 2, [value, value])),
    ];

    private static TwainScanResult Run(FakeTransport transport, TwainScanRequest request, CancellationToken token = default) =>
        TwainScanLoop.Run(transport, request, Timeouts, token);

    [Fact]
    public void FlatbedMemoryScan_ReturnsOnePage()
    {
        var transport = new FakeTransport([.. GrayPage(42, dpi: 300), new TwainFinished()]);
        var result = Run(transport, Flatbed());

        Assert.Null(result.Error);
        Assert.Null(result.Stop);
        var page = Assert.Single(result.Pages);
        Assert.Equal(2, page.Image.Width);
        Assert.Equal(42, page.Image.Pixels[0]);
        Assert.Equal(300, page.Dpi);
        Assert.Equal(ColorMode.Grayscale, page.ColorMode);
        Assert.Equal(["apply", "enable", "disable"], transport.Calls);
        Assert.False(transport.EnabledWithWindow);
        // The first wait allows the scanner to warm up; later ones are shorter.
        Assert.Equal(Timeouts.FirstImage, transport.Waits[0]);
        Assert.Equal(Timeouts.NextEvent, transport.Waits[1]);
    }

    [Fact]
    public void FeederScan_ReturnsEverySheetInOrder()
    {
        var transport = new FakeTransport([.. GrayPage(1), .. GrayPage(2), .. GrayPage(3), new TwainFinished()]);
        var result = Run(transport, Feeder());

        Assert.Equal([1, 2, 3], result.Pages.Select(p => (int)p.Image.Pixels[0]));
        // No resolution reported: the requested one.
        Assert.All(result.Pages, page => Assert.Equal(200, page.Dpi));
        Assert.Null(result.Stop);
    }

    [Fact]
    public void NativeTransfer_DecodesTheBitmap()
    {
        byte[] bitmap = NativeBitmap();
        var transport = new FakeTransport(
            new TwainImageReady(new TwainImageInfo(1, 1, TwainPixelTypes.Rgb, 24)),
            new TwainNativeImage(bitmap),
            new TwainFinished())
        {
            Applied = new TwainApplied(TwainTransferMechanisms.Native),
        };
        var result = Run(transport, Flatbed() with { PixelType = TwainPixelTypes.Rgb });

        var page = Assert.Single(result.Pages);
        Assert.Equal(new byte[] { 1, 2, 3, 255 }, page.Image.Pixels);
        Assert.Equal(ColorMode.Color, page.ColorMode);
        Assert.Equal(300, page.Dpi); // from the bitmap's header
    }

    [Fact]
    public void NativeTransferInProgress_HasNoTimeLimit()
    {
        // A native transfer is one call lasting the whole physical scan: nothing arrives
        // between "image ready" and the finished bitmap, however long a slow, high-resolution
        // scan takes.
        var transport = new FakeTransport(
            new TwainImageReady(new TwainImageInfo(1, 1, TwainPixelTypes.Rgb, 24)),
            new TwainNativeImage(NativeBitmap()),
            new TwainImageReady(new TwainImageInfo(1, 1, TwainPixelTypes.Rgb, 24)),
            new TwainNativeImage(NativeBitmap()),
            new TwainFinished())
        {
            Applied = new TwainApplied(TwainTransferMechanisms.Native),
        };
        var result = Run(transport, Feeder() with { PixelType = TwainPixelTypes.Rgb });

        Assert.Equal(2, result.Pages.Count);
        Assert.Equal([Timeouts.FirstImage, Timeout.InfiniteTimeSpan, Timeouts.NextEvent, Timeout.InfiniteTimeSpan, Timeouts.NextEvent],
                     transport.Waits);
    }

    [Fact]
    public void NativeTransferInProgress_CancelStillEndsTheWait()
    {
        using var cancellation = new CancellationTokenSource();
        var transport = new FakeTransport(
            new TwainImageReady(new TwainImageInfo(1, 1, TwainPixelTypes.Rgb, 24)),
            new TwainNativeImage(NativeBitmap()),
            new TwainFinished())
        {
            Applied = new TwainApplied(TwainTransferMechanisms.Native),
            CancelAfterEvents = cancellation,
            CancelAt = 1, // while the image transfers
        };
        var result = Run(transport, Flatbed() with { PixelType = TwainPixelTypes.Rgb }, cancellation.Token);

        Assert.Equal(Timeout.InfiniteTimeSpan, transport.Waits[1]);
        Assert.Equal(ScanErrorKind.Cancelled, result.Error?.Kind);
        Assert.Equal(["apply", "enable", "stop", "disable"], transport.Calls);
    }

    [Fact]
    public void MemoryTransfer_KeepsItsTimeLimitBetweenStrips()
    {
        var transport = new FakeTransport([.. GrayPage(1), new TwainFinished()]);
        Run(transport, Flatbed());
        Assert.DoesNotContain(Timeout.InfiniteTimeSpan, transport.Waits);
    }

    [Fact]
    public void Started_IsReportedOnceTheSourceIsEnabled_BeforeTheFirstWait()
    {
        var transport = new FakeTransport([.. GrayPage(1), new TwainFinished()]);
        int waitsWhenStarted = -1;
        var result = TwainScanLoop.Run(transport, Flatbed(), Timeouts, CancellationToken.None, started: () =>
        {
            transport.Calls.Add("started");
            waitsWhenStarted = transport.Waits.Count;
        });

        Assert.Single(result.Pages);
        Assert.Equal(["apply", "enable", "started", "disable"], transport.Calls);
        Assert.Equal(0, waitsWhenStarted);
    }

    [Fact]
    public void Started_WithTheDriversWindow_IsReportedBeforeEnabling()
    {
        // Some drivers keep their window open inside the enable call: the user's time there is not a hang.
        var transport = new FakeTransport([.. GrayPage(1), new TwainFinished()]);
        TwainScanLoop.Run(transport, Flatbed(driverWindow: true), Timeouts, CancellationToken.None,
                          started: () => transport.Calls.Add("started"));
        Assert.Equal(["apply", "started", "enable", "disable"], transport.Calls);
    }

    [Fact]
    public void Started_IsNotReportedWhenTheSourceNeverGetsEnabled()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var cases = new (FakeTransport Transport, TwainScanRequest Request, CancellationToken Token)[]
        {
            (new FakeTransport { ApplyError = new TwainException("Setting up the scan", TwainReturnCodes.Failure, TwainConditionCodes.Bummer) },
             Flatbed(), CancellationToken.None),
            (new FakeTransport { EnableError = new TwainException("Starting the scan", TwainReturnCodes.Failure, TwainConditionCodes.Bummer) },
             Flatbed(), CancellationToken.None),
            (new FakeTransport { Applied = new TwainApplied(TwainTransferMechanisms.Memory, FeederLoaded: false) },
             Feeder(), CancellationToken.None),
            (new FakeTransport(new TwainFinished()), Flatbed(), cancelled.Token),
        };
        foreach (var (transport, request, token) in cases)
        {
            bool started = false;
            var result = TwainScanLoop.Run(transport, request, Timeouts, token, started: () => started = true);
            Assert.NotNull(result.Error);
            Assert.False(started);
        }
    }

    /// <summary>A 1 × 1 24-bit bitmap of RGB (1, 2, 3) at 300 dpi.</summary>
    private static byte[] NativeBitmap()
    {
        var data = new byte[44];
        BitConverter.GetBytes(40).CopyTo(data, 0);
        BitConverter.GetBytes(1).CopyTo(data, 4);
        BitConverter.GetBytes(1).CopyTo(data, 8);
        BitConverter.GetBytes((ushort)1).CopyTo(data, 12);
        BitConverter.GetBytes((ushort)24).CopyTo(data, 14);
        BitConverter.GetBytes(11811).CopyTo(data, 24);
        data[40] = 3;
        data[41] = 2;
        data[42] = 1;
        return data;
    }

    [Fact]
    public void Cancel_ResetsTheSourceAndReturnsCancelled()
    {
        using var cancellation = new CancellationTokenSource();
        var transport = new FakeTransport([.. GrayPage(1), .. GrayPage(2), new TwainFinished()])
        {
            CancelAfterEvents = cancellation,
            CancelAt = 4, // after the first page and the second "image ready"
        };
        var result = Run(transport, Feeder(), cancellation.Token);

        Assert.Equal(ScanErrorKind.Cancelled, result.Error?.Kind);
        Assert.Empty(result.Pages);
        Assert.Equal(["apply", "enable", "stop", "disable"], transport.Calls);
        Assert.False(result.DriverStuck);
    }

    [Fact]
    public void CancelBeforeEnabling_NeverEnablesTheSource()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var transport = new FakeTransport(new TwainFinished());
        var result = Run(transport, Flatbed(), cancellation.Token);

        Assert.Equal(ScanErrorKind.Cancelled, result.Error?.Kind);
        Assert.Equal(["apply"], transport.Calls);
    }

    [Fact]
    public void PaperJamOnTheFirstSheet_FailsTheScan()
    {
        var transport = new FakeTransport(
            new TwainImageReady(GrayInfo()),
            new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.PaperJam),
            new TwainFinished());
        var result = Run(transport, Feeder());

        Assert.Equal(ScannerProblem.PaperJam, result.Error?.Problem);
        Assert.Throws<ScanException>(result.PagesOrThrow);
        Assert.Contains("stop", transport.Calls);
    }

    [Fact]
    public void PaperJamLater_KeepsTheSheetsAndSaysWhy()
    {
        var transport = new FakeTransport(
        [
            .. GrayPage(1), .. GrayPage(2),
            new TwainImageReady(GrayInfo()),
            new TwainStripReceived(new TwainStrip(2, 1, 0, 0, 2, [9, 9])),
            new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.PaperJam),
            new TwainFinished(),
        ]);
        var result = Run(transport, Feeder());

        Assert.Null(result.Error);
        Assert.Equal([1, 2], result.Pages.Select(p => (int)p.Image.Pixels[0]));
        Assert.Equal(ScannerProblem.PaperJam, result.Stop?.Problem);
        Assert.StartsWith("Scanning stopped after 2 pages; they were kept. Paper is jammed",
                          result.Stop!.Message(result.Pages.Count));
    }

    [Fact]
    public void EmptyFeederAfterSomeSheets_IsTheEndOfTheStack()
    {
        var transport = new FakeTransport(
        [
            .. GrayPage(1),
            new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.NoMedia),
            new TwainFinished(),
        ]);
        var result = Run(transport, Feeder());

        Assert.Single(result.Pages);
        Assert.Null(result.Stop);
        Assert.Null(result.Error);
    }

    [Fact]
    public void NothingPending_FlatbedFailsAndFeederSaysLoadPaper()
    {
        var flatbed = Run(new FakeTransport(new TwainFinished()), Flatbed());
        Assert.Equal(ScanErrorKind.ScanFailed, flatbed.Error?.Kind);
        Assert.Equal("Scan failed: The scanner did not return any image data.", flatbed.Error?.Message);

        var feeder = Run(new FakeTransport(new TwainFinished()), Feeder());
        Assert.Equal(ScannerProblem.FeederEmpty, feeder.Error?.Problem);
    }

    [Fact]
    public void FeederReportedEmpty_FailsBeforeEnabling()
    {
        var transport = new FakeTransport(new TwainFinished())
        {
            Applied = new TwainApplied(TwainTransferMechanisms.Memory, FeederLoaded: false),
        };
        var result = Run(transport, Feeder());

        Assert.Equal(ScannerProblem.FeederEmpty, result.Error?.Problem);
        Assert.Equal("Load paper in the feeder, then scan again.", result.Error?.Message);
        Assert.Equal(["apply"], transport.Calls);
    }

    [Theory]
    [InlineData(TwainReturnCodes.Failure, TwainConditionCodes.NoMedia, ScannerProblem.FeederEmpty)]
    [InlineData(TwainReturnCodes.Failure, TwainConditionCodes.CheckDeviceOnline, ScannerProblem.Offline)]
    [InlineData(TwainReturnCodes.Busy, TwainConditionCodes.Success, ScannerProblem.Busy)]
    public void EnableRefused_BecomesTheScannerProblem(int returnCode, int conditionCode, ScannerProblem expected)
    {
        var transport = new FakeTransport
        {
            EnableError = new TwainException("Starting the scan", returnCode, conditionCode),
        };
        var result = Run(transport, Feeder());

        Assert.Equal(expected, result.Error?.Problem);
        Assert.Equal(["apply", "enable", "disable"], transport.Calls);
    }

    [Fact]
    public void ApplyFailure_IsAScanFailure()
    {
        var transport = new FakeTransport
        {
            ApplyError = new TwainException("Setting up the scan", TwainReturnCodes.Failure, TwainConditionCodes.Bummer),
        };
        var result = Run(transport, Flatbed());

        Assert.Equal(ScanErrorKind.ScanFailed, result.Error?.Kind);
        Assert.Equal(["apply"], transport.Calls);
    }

    [Fact]
    public void SilentSource_IsStoppedAndReportedNotResponding()
    {
        // Nothing ever arrives: the first wait times out.
        var transport = new FakeTransport();
        var result = Run(transport, Flatbed());

        Assert.Equal(ScanErrorKind.ScanFailed, result.Error?.Kind);
        Assert.Contains("stopped responding", result.Error?.Message);
        Assert.Equal(["apply", "enable", "stop", "disable"], transport.Calls);
        Assert.Equal(Timeouts.Stop, transport.Waits[^1]);
        Assert.False(result.DriverStuck);
    }

    [Fact]
    public void SourceGoingSilentMidBatch_KeepsThePages()
    {
        var transport = new FakeTransport([.. GrayPage(1), null]);
        var result = Run(transport, Feeder());

        Assert.Single(result.Pages);
        Assert.Contains("stopped responding", result.Stop?.Reason);
    }

    [Fact]
    public void SourceThatNeverStops_IsReportedStuck()
    {
        var transport = new FakeTransport { FinishesWhenStopped = false, DisableSucceeds = false };
        var result = Run(transport, Flatbed());

        Assert.True(result.DriverStuck);
        Assert.NotNull(result.Error);
    }

    [Fact]
    public void DriverWindow_WaitsForTheUserWithoutALimit()
    {
        var transport = new FakeTransport([.. GrayPage(7), new TwainFinished()]);
        var result = Run(transport, Flatbed(driverWindow: true));

        Assert.True(transport.EnabledWithWindow);
        Assert.Equal(Timeout.InfiniteTimeSpan, transport.Waits[0]);
        Assert.Single(result.Pages);
    }

    [Fact]
    public void DriverWindowClosedWithoutScanning_IsCancelled()
    {
        var result = Run(new FakeTransport(new TwainFinished()), Flatbed(driverWindow: true));
        Assert.Equal(ScanErrorKind.Cancelled, result.Error?.Kind);
    }

    [Fact]
    public void CancelInTheDriversWindow_KeepsEarlierPages()
    {
        var transport = new FakeTransport(
        [
            .. GrayPage(1),
            new TwainImageReady(GrayInfo()),
            new TwainTransferCancelled(),
            new TwainFinished(),
        ]);
        var result = Run(transport, Feeder());
        Assert.Single(result.Pages);
        Assert.Null(result.Stop);

        var none = Run(new FakeTransport(new TwainImageReady(GrayInfo()), new TwainTransferCancelled(), new TwainFinished()),
                       Feeder());
        Assert.Equal(ScanErrorKind.Cancelled, none.Error?.Kind);
    }

    [Fact]
    public void UnreadableMemoryFormat_SwitchesToNativeTransfers()
    {
        var transport = new FakeTransport(
            new TwainImageReady(new TwainImageInfo(2, 2, TwainPixelTypes.Gray, 16)),
            new TwainFinished());
        var result = Run(transport, Flatbed());

        Assert.True(result.UseNativeTransfers);
        Assert.Equal(ScanErrorKind.ScanFailed, result.Error?.Kind);
        Assert.Contains("next scan uses another transfer method", result.Error?.Message);
    }

    [Fact]
    public void ResolutionAndColorFollowTheImage_WhenTheDriverChangedThem()
    {
        var transport = new FakeTransport(
            new TwainImageReady(new TwainImageInfo(1, 1, TwainPixelTypes.BlackWhite, 1, 150, 150)),
            new TwainStripReceived(new TwainStrip(1, 1, 0, 0, 1, [0x80])),
            new TwainFinished());
        var result = Run(transport, Flatbed(driverWindow: true));

        var page = Assert.Single(result.Pages);
        Assert.Equal(150, page.Dpi);
        Assert.Equal(ColorMode.BlackWhite, page.ColorMode);
        Assert.Equal(255, page.Image.Pixels[0]);
    }

    [Fact]
    public void ImageWithoutData_IsNotAPage()
    {
        var transport = new FakeTransport(new TwainImageReady(GrayInfo()), new TwainFinished());
        var result = Run(transport, Flatbed());
        Assert.Empty(result.Pages);
        Assert.Equal(ScanErrorKind.ScanFailed, result.Error?.Kind);
    }
}
