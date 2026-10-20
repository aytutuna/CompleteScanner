using System.IO;
using CompleteScanner.App.Scanning;
using CompleteScanner.Core;
using Windows.Devices.Scanners;
using Windows.Graphics.Printing;
using Xunit;

namespace CompleteScanner.App.Tests;

// The Windows Scan connection (WinRT ImageScanner) as the app uses it, without a scanner: the Core
// mirrors of the WinRT enums, the paper sizes the feeder is asked for, and the device watcher
// running in this unpackaged process. Scanning itself needs a real WIA scanner.

public class WinRtScannerTests
{
    [Fact]
    public void CoreEnumsMirrorTheWinRtEnums()
    {
        AssertMirrors<WindowsScanSource, ImageScannerScanSource>();
        AssertMirrors<WindowsScanColorMode, ImageScannerColorMode>();
        AssertMirrors<WindowsScanFormat, ImageScannerFormat>();
    }

    private static void AssertMirrors<TCore, TWinRt>() where TCore : struct, Enum where TWinRt : struct, Enum
    {
        var core = Enum.GetValues<TCore>().Select(value => (value.ToString(), Convert.ToInt32(value))).ToList();
        var winRt = Enum.GetValues<TWinRt>().Select(value => (value.ToString(), Convert.ToInt32(value))).ToList();
        Assert.Equal(winRt, core);
    }

    [Fact]
    public void EveryPaperSizeButAutomaticIsAWinRtMediaSize()
    {
        Assert.Null(WinRtScannerSession.MediaSize(PaperSize.Auto));
        Assert.Equal(PrintMediaSize.NorthAmericaLetter, WinRtScannerSession.MediaSize(PaperSize.Letter));
        Assert.Equal(PrintMediaSize.NorthAmericaLegal, WinRtScannerSession.MediaSize(PaperSize.Legal));
        Assert.Equal(PrintMediaSize.NorthAmericaExecutive, WinRtScannerSession.MediaSize(PaperSize.Executive));
        Assert.Equal(PrintMediaSize.IsoA4, WinRtScannerSession.MediaSize(PaperSize.A4));
        Assert.Equal(PrintMediaSize.IsoA5, WinRtScannerSession.MediaSize(PaperSize.A5));
        Assert.Equal(PrintMediaSize.IsoA6, WinRtScannerSession.MediaSize(PaperSize.A6));
        Assert.Equal(PrintMediaSize.JisB5, WinRtScannerSession.MediaSize(PaperSize.B5Jis));
        Assert.Equal(PrintMediaSize.CreditCard, WinRtScannerSession.MediaSize(PaperSize.IdCard));
        Assert.All(PaperSizes.All.Where(size => size != PaperSize.Auto),
                   size => Assert.NotNull(WinRtScannerSession.MediaSize(size)));
    }

    /// <summary>
    /// The watcher starts in this unpackaged process and finishes its first pass: listing what
    /// is plugged in (nothing on a PC without a scanner), or, where Windows refuses the API,
    /// listing nothing and saying why. Stopping it lists nothing.
    /// </summary>
    [Fact]
    public async Task WatcherFinishesItsFirstPassCleanly()
    {
        string scratch = Path.Combine(Path.GetTempPath(), "CompleteScanner-winrt-test-" + Guid.NewGuid().ToString("N"));
        var backend = new WinRtScannerBackend(() => scratch);
        int changes = 0;
        backend.DevicesChanged += () => Interlocked.Increment(ref changes);
        try
        {
            backend.StartBrowsing();
            var waited = System.Diagnostics.Stopwatch.StartNew();
            while (backend.Status == WindowsScanStatus.Searching && waited.Elapsed < TimeSpan.FromSeconds(60))
            {
                await Task.Delay(50);
            }
            // Let a change posted to the test's context arrive.
            await Task.Delay(200);
            var status = backend.Status;
            Assert.Contains(status, new[] { WindowsScanStatus.Running, WindowsScanStatus.Unavailable });
            Assert.True(Volatile.Read(ref changes) > 0);
            string report = backend.DiagnosticsReport!;
            if (status == WindowsScanStatus.Running)
            {
                Assert.StartsWith($"Windows Scan (backup): watching, {backend.Devices.Count} scanner(s)", report);
                Assert.All(backend.Devices, device =>
                {
                    Assert.Equal(WindowsScanConnection.Backend, device.Backend);
                    Assert.Equal(WindowsScanConnection.Transport, device.Transport);
                    Assert.NotNull(WindowsScanConnection.DeviceId(device.Id));
                });
            }
            else
            {
                Assert.Empty(backend.Devices);
                Assert.False(string.IsNullOrWhiteSpace(backend.Note));
                Assert.StartsWith("Windows Scan (backup): unavailable, connection hidden - ", report);
            }
        }
        finally
        {
            backend.StopBrowsing();
        }
        await Task.Delay(200);
        Assert.Equal(WindowsScanStatus.Off, backend.Status);
        Assert.Empty(backend.Devices);
        // Nothing scanned, so nothing was written.
        Assert.False(Directory.Exists(scratch));
    }

    [Fact]
    public async Task OpeningADeviceThatIsNotThereIsAScanError()
    {
        Exception? refused = null;
        var error = await Assert.ThrowsAsync<ScanException>(() =>
            WinRtScannerBackend.OpenScannerAsync(@"\\?\ROOT#IMAGE#9999#{6bdd1fc6-810f-11d0-bec7-08002be2092f}", "Gone", e =>
            {
                refused = e;
                return true;
            }));
        Assert.NotEqual(ScanErrorKind.Cancelled, error.Kind);
        // Where the API works, it is not hidden for a device that is simply missing.
        if (refused is not null) Assert.True(WindowsScanErrors.UnavailableToThisApp(refused.HResult));
    }

    /// <summary>
    /// An access denial from opening a device hides the connection only as WindowsScanAccess
    /// decides; with no device listed or opened (nothing else to ask), it does, and says why.
    /// A code that is not a refusal of the API never does.
    /// </summary>
    [Fact]
    public void ARefusedOpenHidesTheConnectionOnlyWhenItIsTheApis()
    {
        var backend = new WinRtScannerBackend(() => Path.GetTempPath());
        Assert.False(backend.Refused("a", new InvalidOperationException { HResult = unchecked((int)0x80004005) }));
        Assert.NotEqual(WindowsScanStatus.Unavailable, backend.Status);
        Assert.True(backend.Refused("a", new UnauthorizedAccessException("Access is denied.")));
        Assert.Equal(WindowsScanStatus.Unavailable, backend.Status);
        Assert.Equal("Windows refused this app access to it (0x80070005: Access is denied.)", backend.Note);
        Assert.Empty(backend.Devices);
    }

    [Fact]
    public async Task OpeningADeviceTheListDoesNotHaveIsRefused()
    {
        var backend = new WinRtScannerBackend(() => Path.GetTempPath());
        var error = await Assert.ThrowsAsync<ScanException>(() => backend.OpenSessionAsync("winrt:missing"));
        Assert.Equal(ScanErrorKind.DeviceUnavailable, error.Kind);
    }

    /// <summary>What a session reads about a device's sources raises DevicesChanged, so devices.txt is written again with it.</summary>
    [Fact]
    public void RecordedSourcesAreAChange()
    {
        var backend = new WinRtScannerBackend(() => Path.GetTempPath());
        int changes = 0;
        backend.DevicesChanged += () => changes++;
        var flatbed = new WindowsScanSourceFacts { Source = ScanSource.Flatbed, MinDpi = 50, MaxDpi = 1200 };
        backend.RecordFacts("winrt:a", [flatbed]);
        Assert.Equal(1, changes);
        // Read again by the next session: written again.
        backend.RecordFacts("winrt:a", [flatbed]);
        Assert.Equal(2, changes);
    }
}

// WIA Automation finds scanners by polling; the app asks it to look again when Windows Scan
// lists a scanner first, and waits for a look that began after it asked.
public class WiaEnumerationTests
{
    [Fact]
    public void ARefreshAskedForWhileOneRunsStartsAnotherAfterIt()
    {
        var previous = SynchronizationContext.Current;
        // No context: results are applied on the enumeration thread, under the backend's lock.
        SynchronizationContext.SetSynchronizationContext(null);
        var wia = new WiaScannerBackend();
        int finished = 0;
        wia.EnumerationFinished += () => Interlocked.Increment(ref finished);
        try
        {
            Assert.Equal(0, wia.EnumerationsFinished);
            wia.StartBrowsing();
            // Asked for while the first runs (or right after it ended): exactly one more.
            wia.RefreshDevices();
            var waited = System.Diagnostics.Stopwatch.StartNew();
            while (wia.EnumerationsFinished < 2 && waited.Elapsed < TimeSpan.FromSeconds(60)) Thread.Sleep(20);
            Thread.Sleep(200);
            Assert.True(wia.EnumerationsFinished >= 2, $"finished {wia.EnumerationsFinished}");
            Assert.Equal(wia.EnumerationsFinished, Volatile.Read(ref finished));
            // Not a second one overlapping the first, and nothing more (the watchdog's first poll is 10 s away).
            if (waited.Elapsed < TimeSpan.FromSeconds(9)) Assert.Equal(2, wia.EnumerationsStarted);
        }
        finally
        {
            wia.StopBrowsing();
            SynchronizationContext.SetSynchronizationContext(previous);
        }
    }
}
