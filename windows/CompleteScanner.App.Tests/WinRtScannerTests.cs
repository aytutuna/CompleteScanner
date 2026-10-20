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

/// <summary>
/// A test that asks the real WIA Automation for its devices. Where WIA cannot be asked (WIA
/// Automation not registered, or stisvc not installed or disabled) it is skipped, and the skip
/// says why, with stisvc's state and start type; with COMPLETESCANNER_REQUIRE_WIA=1 (CI) it runs
/// anyway and fails there, so it can never pass on CI without WIA having been asked.
/// </summary>
public sealed class WiaFactAttribute : FactAttribute
{
    public WiaFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("COMPLETESCANNER_REQUIRE_WIA") != "1" && WhyNot() is { } reason)
        {
            Skip = $"WIA cannot be asked here: {reason} ({ServiceDescription()}).";
        }
    }

    /// <summary>Why WIA cannot be asked on this PC; null when it can.</summary>
    internal static string? WhyNot() =>
        WiaAvailability.Unavailable(new Services.WindowsSystemDiagnostics().WiaService(), WiaScannerBackend.AutomationRegistered());

    /// <summary>stisvc's state and start type, as the app reads them and as the registry has it.</summary>
    internal static string ServiceDescription()
    {
        object? start = null;
        try
        {
            using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\stisvc");
            start = key?.GetValue("Start");
        }
        catch (Exception e)
        {
            start = e.Message;
        }
        string startType = start switch
        {
            2 => "Automatic",
            3 => "Manual",
            4 => "Disabled",
            null => "not set",
            _ => start.ToString()!,
        };
        return $"stisvc {new Services.WindowsSystemDiagnostics().WiaService()}, start type {startType}";
    }
}

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

    /// <summary>
    /// Many backends start, refresh and stop browsing from many threads at once, while other
    /// threads list WIA's scanners directly. Every WIA object is created on the one WIA thread,
    /// one place at a time: WIA used from two STA threads at once hands objects across apartments
    /// and can crash the process (an access violation in CoCreateInstance). Each enumeration and
    /// each direct call notes its thread where it creates WIA objects (<see cref="WiaApartment.Use"/>),
    /// so a thread per call, or two at once, fails here. Needs the real WIA (a stopped stisvc is
    /// started by asking it); where WIA cannot be asked the test is skipped and says why.
    /// </summary>
    [WiaFact]
    public async Task StartingAndStoppingFromManyThreadsKeepsWiaOnOneThread()
    {
        Assert.True(WiaFactAttribute.WhyNot() is null,
                    $"WIA cannot be asked here: {WiaFactAttribute.WhyNot()} ({WiaFactAttribute.ServiceDescription()}).");
        int wiaThread = WiaApartment.ThreadId;
        long usesBefore = WiaApartment.Uses;
        var askedOn = new System.Collections.Concurrent.ConcurrentBag<(int Thread, ApartmentState Apartment)>();
        var system = new Services.WindowsSystemDiagnostics();
        ServiceStatus Service()
        {
            askedOn.Add((Environment.CurrentManagedThreadId, Thread.CurrentThread.GetApartmentState()));
            return system.WiaService();
        }

        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);
        var backends = new List<WiaScannerBackend>();
        try
        {
            var browsers = Enumerable.Range(0, 8).Select(i => Task.Run(() =>
            {
                var wia = new WiaScannerBackend(Service, WiaScannerBackend.AutomationRegistered);
                lock (backends) backends.Add(wia);
                for (int round = 0; round < 25; round++)
                {
                    wia.StartBrowsing();
                    wia.RefreshDevices();
                    if ((round + i) % 3 == 0) Thread.Sleep(1);
                    wia.Rescan();
                    wia.StopBrowsing();
                }
                wia.StartBrowsing();
            }));
            // WIA asked directly too, as sessions do: every call succeeds with the same answer.
            var counts = Enumerable.Range(0, 32).Select(_ => Task.Run(() => WiaApartment.Run(CountWiaDevices)))
                                   .ToList();
            await Task.WhenAll(browsers);
            int[] answers = await Task.WhenAll(counts);
            Assert.All(answers, count => Assert.Equal(answers[0], count));

            // Each backend browses at the end: its latest enumeration finishes, with an answer.
            var waited = System.Diagnostics.Stopwatch.StartNew();
            while (backends.Any(b => b.EnumerationsFinished < b.EnumerationsStarted) && waited.Elapsed < TimeSpan.FromSeconds(120))
            {
                await Task.Delay(20);
            }
            Assert.All(backends, b => Assert.Equal(b.EnumerationsStarted, b.EnumerationsFinished));
            Assert.All(backends, b => Assert.Null(b.Unavailable));
            Assert.All(backends, b => Assert.Equal(backends[0].Devices, b.Devices));
            Assert.All(backends, b => Assert.StartsWith("WIA: ", b.DiagnosticsReport));
        }
        finally
        {
            foreach (var wia in backends) wia.StopBrowsing();
            SynchronizationContext.SetSynchronizationContext(previous);
        }
        Assert.NotEmpty(askedOn);
        Assert.All(askedOn, asked => Assert.Equal((wiaThread, ApartmentState.STA), asked));
        // WIA objects were really created: the 32 direct calls and each backend's last enumeration
        // at least, all on the WIA thread and never two at once.
        Assert.True(WiaApartment.Uses - usesBefore >= 32 + backends.Count,
                    $"WIA was asked {WiaApartment.Uses - usesBefore} times");
        Assert.Equal([wiaThread], WiaApartment.ThreadsThatUsedWia);
        Assert.Equal(1, WiaApartment.MostUsingWiaAtOnce);
    }

    /// <summary>The devices WIA lists, by plain WIA Automation calls that throw when WIA fails.</summary>
    private static int CountWiaDevices()
    {
        using var use = WiaApartment.Use();
        var type = Type.GetTypeFromProgID(WiaScannerBackend.DeviceManagerProgId, throwOnError: true)!;
        object manager = Activator.CreateInstance(type)!;
        object? infos = null;
        try
        {
            infos = ((dynamic)manager).DeviceInfos;
            return (int)((dynamic)infos!).Count;
        }
        finally
        {
            if (infos is not null) System.Runtime.InteropServices.Marshal.FinalReleaseComObject(infos);
            System.Runtime.InteropServices.Marshal.FinalReleaseComObject(manager);
        }
    }

    /// <summary>Without a service COM can start, or without WIA Automation, WIA is not asked at all: nothing is listed, devices.txt and the troubleshooter say why.</summary>
    [Theory]
    [InlineData(ServiceStatus.NotInstalled, true, "the Windows Image Acquisition service (stisvc) is not installed")]
    [InlineData(ServiceStatus.Disabled, true, "the Windows Image Acquisition service (stisvc) is disabled")]
    [InlineData(ServiceStatus.Stopped, false, "WIA Automation (wiaaut.dll) is not registered on this PC")]
    [InlineData(ServiceStatus.Running, false, "WIA Automation (wiaaut.dll) is not registered on this PC")]
    public void WithoutWiaNothingIsListedAndTheReportSaysWhy(ServiceStatus service, bool registered, string reason)
    {
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);
        var wia = new WiaScannerBackend(() => service, () => registered);
        int changes = 0;
        wia.DevicesChanged += () => Interlocked.Increment(ref changes);
        try
        {
            Assert.Equal("WIA: off\n", wia.DiagnosticsReport);
            wia.StartBrowsing();
            var waited = System.Diagnostics.Stopwatch.StartNew();
            while (wia.EnumerationsFinished < 1 && waited.Elapsed < TimeSpan.FromSeconds(60)) Thread.Sleep(10);
            Thread.Sleep(50);
            Assert.Equal(1, wia.EnumerationsFinished);
            Assert.Empty(wia.Devices);
            Assert.Equal(reason, wia.Unavailable);
            Assert.Equal($"WIA: unavailable - {reason}\n", wia.DiagnosticsReport);
            // The new reason is a change, so the app writes devices.txt again.
            Assert.Equal(1, Volatile.Read(ref changes));
            var snapshot = wia.AddStatus(new DiscoverySnapshot { Platform = TroubleshootPlatform.Windows });
            Assert.Equal(service, snapshot.WiaService);
            // What the app read itself stays.
            Assert.Equal(ServiceStatus.Running,
                         wia.AddStatus(new DiscoverySnapshot { WiaService = ServiceStatus.Running }).WiaService);
        }
        finally
        {
            wia.StopBrowsing();
            SynchronizationContext.SetSynchronizationContext(previous);
        }
        Assert.Equal("WIA: off\n", wia.DiagnosticsReport);
        Assert.Null(wia.Unavailable);
    }

    /// <summary>
    /// A stopped service (stisvc set to Manual and not yet running) does not stop the enumeration:
    /// creating WIA's Device Manager starts it. The service is read again afterwards, so the
    /// troubleshooter gets the state the enumeration left it in.
    /// </summary>
    [Theory]
    [InlineData(ServiceStatus.Stopped)]
    [InlineData(ServiceStatus.Stopping)]
    [InlineData(ServiceStatus.Paused)]
    public void AStoppedServiceIsStartedByAskingWia(ServiceStatus before)
    {
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);
        int asked = 0;
        long usesBefore = WiaApartment.Uses;
        var wia = new WiaScannerBackend(() => Interlocked.Increment(ref asked) == 1 ? before : ServiceStatus.Running, () => true);
        try
        {
            wia.StartBrowsing();
            var waited = System.Diagnostics.Stopwatch.StartNew();
            while (wia.EnumerationsFinished < 1 && waited.Elapsed < TimeSpan.FromSeconds(60)) Thread.Sleep(10);
            Assert.Equal(1, wia.EnumerationsFinished);
            Assert.True(WiaApartment.Uses > usesBefore, "WIA was not asked");
            Assert.Null(wia.Unavailable);
            Assert.Equal($"WIA: {wia.Devices.Count} scanner(s)\n", wia.DiagnosticsReport);
            Assert.Equal(2, Volatile.Read(ref asked));
            Assert.Equal(ServiceStatus.Running, wia.AddStatus(new DiscoverySnapshot()).WiaService);
        }
        finally
        {
            wia.StopBrowsing();
            SynchronizationContext.SetSynchronizationContext(previous);
        }
    }

    /// <summary>Work for WIA runs on its STA thread in the order it was asked for, and its failures reach the caller.</summary>
    [Fact]
    public async Task WiaWorkRunsInOrderOnItsStaThread()
    {
        var order = new List<int>();
        var runs = Enumerable.Range(0, 50).Select(i => WiaApartment.Run(() =>
        {
            Assert.Equal(ApartmentState.STA, Thread.CurrentThread.GetApartmentState());
            Assert.Equal(WiaApartment.ThreadId, Environment.CurrentManagedThreadId);
            order.Add(i);
            return i;
        })).ToList();
        Assert.Equal(Enumerable.Range(0, 50), await Task.WhenAll(runs));
        Assert.Equal(Enumerable.Range(0, 50), order);
        var failed = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            WiaApartment.Run<int>(() => throw new InvalidOperationException("driver")));
        Assert.Equal("driver", failed.Message);
        // The thread survives a failure.
        Assert.Equal(7, await WiaApartment.Run(() => 7));
    }
}
