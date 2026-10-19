using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/TroubleshooterTests.swift (same fixtures, same text).
// C#-only case: OperationCanceledException in FailureFrom (Swift has CancellationError instead,
// tested there).

public class TroubleshooterTests
{
    private static readonly ScannerInfo Demo = new("mock:demo", "Demo Scanner", "Demo", IsDemo: true, Backend: "mock");
    private static readonly ScannerInfo WiaScanner = new("wia:1", "Acme Scan 100", "WIA", Backend: "wia");

    private static List<string> Ids(IReadOnlyList<TroubleshootCheck> checks) => [.. checks.Select(c => c.Id)];

    private static TroubleshootCheck Check(IReadOnlyList<TroubleshootCheck> checks, string id) => checks.Single(c => c.Id == id);

    /// <summary>A PC where everything that can be checked is fine.</summary>
    private static DiscoverySnapshot HealthyWindows() => new()
    {
        Platform = TroubleshootPlatform.Windows,
        Devices = [Demo, WiaScanner],
        Network = NetworkStatus.PrivateNetwork,
        WiaService = ServiceStatus.Running,
        Twain = TwainStatus.Available,
        TwainDriverCount = 2,
        Discovery = DiscoveryStatus.Running,
        DiscoveredCount = 1,
    };

    /// <summary>A PC where most things are wrong.</summary>
    private static DiscoverySnapshot TroubledWindows() => new()
    {
        Platform = TroubleshootPlatform.Windows,
        Devices = [Demo],
        Network = NetworkStatus.PublicNetwork,
        WiaService = ServiceStatus.Disabled,
        Twain = TwainStatus.NotInstalled,
        ThirtyTwoBitOnlyDrivers = [@"Acme\acme.ds"],
        Discovery = DiscoveryStatus.Unavailable,
        DiscoveryDetail = "Access is denied.",
        ManualHosts = [new("192.168.1.50", false, "No scanner answered at 192.168.1.50."), new("10.0.0.2", true)],
        LastFailure = new ScannerFailure("Acme Scan 100", ScannerProblems.Describe(ScannerProblem.Busy), ScannerProblem.Busy),
    };

    [Fact]
    public void HealthyWindows_ShowsWhatIsFineThenTheTips()
    {
        var snapshot = HealthyWindows();
        var checks = Troubleshooter.Diagnose(snapshot);
        Assert.Equal(["network", "wiaService", "twain", "discovery", "usb", "otherApps"], Ids(checks));
        Assert.Equal([CheckStatus.Ok, CheckStatus.Ok, CheckStatus.Ok, CheckStatus.Ok, CheckStatus.Tip, CheckStatus.Tip],
                     checks.Select(c => c.Status));
        Assert.Equal("1 scanner found", Troubleshooter.Headline(snapshot));
        Assert.Equal("Nothing here stops scanners from appearing. The tips below cover the usual causes.",
                     Troubleshooter.Summary(checks));
    }

    [Fact]
    public void ProblemsComeFirst_ThenWarnings_ThenTips()
    {
        var snapshot = TroubledWindows();
        var checks = Troubleshooter.Diagnose(snapshot);
        Assert.Equal(["lastFailure", "wiaService", "twain32", "network", "twain", "discovery",
                      "manualHost:192.168.1.50", "usb", "otherApps"], Ids(checks));
        Assert.Equal([CheckStatus.Problem, CheckStatus.Problem, CheckStatus.Problem,
                      CheckStatus.Warning, CheckStatus.Warning, CheckStatus.Warning, CheckStatus.Warning,
                      CheckStatus.Tip, CheckStatus.Tip], checks.Select(c => c.Status));
        Assert.Equal("No scanner found yet", Troubleshooter.Headline(snapshot));
        Assert.Equal("3 problems and 4 warnings found.", Troubleshooter.Summary(checks));
    }

    [Fact]
    public void NothingKnown_OnlyTheTips()
    {
        var checks = Troubleshooter.Diagnose(new DiscoverySnapshot { Platform = TroubleshootPlatform.Windows });
        Assert.Equal(["usb", "otherApps"], Ids(checks));
    }

    [Fact]
    public void BusyScanner_SaysToCloseOtherApps()
    {
        var check = Check(Troubleshooter.Diagnose(TroubledWindows()), "lastFailure");
        Assert.Equal(new TroubleshootCheck(
            "lastFailure", CheckStatus.Problem, "Acme Scan 100 is busy or in use by another app",
            "A scanner works with one app at a time. Close other apps that may be using it, such as Windows Scan "
            + "or the scanner maker's app, wait until the scanner has finished, then choose it again.",
            [TroubleshootAction.Refresh]), check);
    }

    [Fact]
    public void OtherScannerProblem_UsesItsText()
    {
        var snapshot = new DiscoverySnapshot
        {
            LastFailure = new ScannerFailure("Acme Scan 100", "x", ScannerProblem.CoverOpen),
        };
        var check = Check(Troubleshooter.Diagnose(snapshot), "lastFailure");
        Assert.Equal(CheckStatus.Problem, check.Status);
        Assert.Equal("Acme Scan 100 reported a problem", check.Title);
        Assert.Equal(ScannerProblems.Describe(ScannerProblem.CoverOpen), check.Detail);
    }

    [Fact]
    public void FailureWithoutProblem_IsAWarningWithTheMessage()
    {
        var snapshot = new DiscoverySnapshot
        {
            LastFailure = new ScannerFailure("Office MFP", "Office MFP did not answer (192.168.1.9: no answer in time)"),
        };
        var check = Check(Troubleshooter.Diagnose(snapshot), "lastFailure");
        Assert.Equal(CheckStatus.Warning, check.Status);
        Assert.Equal("Could not connect to Office MFP", check.Title);
        Assert.Equal("Office MFP did not answer (192.168.1.9: no answer in time). Check that the scanner is on "
                     + "and awake, and connected by its cable or to the same network as this PC.", check.Detail);
        var mac = Check(Troubleshooter.Diagnose(snapshot with { Platform = TroubleshootPlatform.Mac }), "lastFailure");
        Assert.EndsWith("to the same network as this Mac.", mac.Detail);
    }

    public static TheoryData<ServiceStatus, CheckStatus, string> WiaStates => new()
    {
        { ServiceStatus.Running, CheckStatus.Ok, "The Windows scanner service is running" },
        { ServiceStatus.Starting, CheckStatus.Warning, "The Windows scanner service is starting" },
        { ServiceStatus.Stopped, CheckStatus.Warning, "The Windows scanner service is not running" },
        { ServiceStatus.Stopping, CheckStatus.Warning, "The Windows scanner service is not running" },
        { ServiceStatus.Paused, CheckStatus.Warning, "The Windows scanner service is not running" },
        { ServiceStatus.Disabled, CheckStatus.Problem, "The Windows scanner service is turned off" },
        { ServiceStatus.NotInstalled, CheckStatus.Problem, "The Windows scanner service is missing" },
    };

    [Theory]
    [MemberData(nameof(WiaStates))]
    public void WiaService(ServiceStatus service, CheckStatus status, string title)
    {
        var check = Check(Troubleshooter.Diagnose(HealthyWindows() with { WiaService = service }), "wiaService");
        Assert.Equal(status, check.Status);
        Assert.Equal(title, check.Title);
        Assert.Contains("Windows Image Acquisition (WIA)", check.Detail);
    }

    [Fact]
    public void WiaService_UnknownHasNoCheck()
    {
        var checks = Troubleshooter.Diagnose(HealthyWindows() with { WiaService = ServiceStatus.Unknown });
        Assert.DoesNotContain("wiaService", Ids(checks));
    }

    [Fact]
    public void DisabledWiaService_SaysHowToTurnItOnWithoutDoingIt()
    {
        var check = Check(Troubleshooter.Diagnose(HealthyWindows() with { WiaService = ServiceStatus.Disabled }), "wiaService");
        Assert.Equal("Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners cannot "
                     + "appear. Someone with administrator rights can set its startup type to Automatic in Services, then "
                     + "restart the PC.", check.Detail);
        Assert.Equal([TroubleshootAction.Refresh], check.Actions);
    }

    [Fact]
    public void Network()
    {
        var offline = Check(Troubleshooter.Diagnose(HealthyWindows() with { Network = NetworkStatus.Offline }), "network");
        Assert.Equal((CheckStatus.Problem, "Not connected to a network"), (offline.Status, offline.Title));
        Assert.Equal("This PC is not on a network, so network scanners cannot be found. Connect to the network the "
                     + "scanner is on, then select Refresh. Scanners connected by USB are not affected.", offline.Detail);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings, TroubleshootAction.Refresh], offline.Actions);

        var publicNetwork = Check(Troubleshooter.Diagnose(HealthyWindows() with { Network = NetworkStatus.PublicNetwork }), "network");
        Assert.Equal((CheckStatus.Warning, "The network is set to Public"), (publicNetwork.Status, publicNetwork.Title));
        Assert.Equal("Windows does not look for devices on public networks, so network scanners may not be found. "
                     + "If this is your home or office network, set its network profile type to Private in Windows "
                     + "network settings. You can also add the scanner by its address.", publicNetwork.Detail);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings, TroubleshootAction.AddByAddress], publicNetwork.Actions);

        foreach (var status in new[] { NetworkStatus.PrivateNetwork, NetworkStatus.DomainNetwork })
        {
            var ok = Check(Troubleshooter.Diagnose(HealthyWindows() with { Network = status }), "network");
            Assert.Equal((CheckStatus.Ok, "Connected to a private network"), (ok.Status, ok.Title));
        }
        Assert.DoesNotContain("network", Ids(Troubleshooter.Diagnose(HealthyWindows() with { Network = NetworkStatus.Unknown })));
    }

    [Fact]
    public void TwainNotInstalled_IsAWarningOnlyWhileNoScannerIsListed()
    {
        var none = Check(Troubleshooter.Diagnose(HealthyWindows() with { Devices = [Demo], Twain = TwainStatus.NotInstalled }), "twain");
        Assert.Equal(CheckStatus.Warning, none.Status);
        Assert.Equal("TWAIN is not installed", none.Title);
        Assert.Equal("Some scanners, often document scanners, work only through their maker's TWAIN driver, which "
                     + "also installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then "
                     + "restart CompleteScanner.", none.Detail);
        var some = Check(Troubleshooter.Diagnose(HealthyWindows() with { Twain = TwainStatus.NotInstalled }), "twain");
        Assert.Equal(CheckStatus.Tip, some.Status);
    }

    [Fact]
    public void TwainFailedAndDriverCounts()
    {
        var failed = Check(Troubleshooter.Diagnose(HealthyWindows() with { Twain = TwainStatus.Failed }), "twain");
        Assert.Equal((CheckStatus.Warning, "TWAIN did not start"), (failed.Status, failed.Title));
        Assert.Equal([TroubleshootAction.Refresh], failed.Actions);
        Assert.Equal("No 64-bit TWAIN scanner driver is installed. Most scanners work without one.",
                     Check(Troubleshooter.Diagnose(HealthyWindows() with { TwainDriverCount = 0 }), "twain").Detail);
        Assert.Equal("1 TWAIN scanner driver is installed.",
                     Check(Troubleshooter.Diagnose(HealthyWindows() with { TwainDriverCount = 1 }), "twain").Detail);
        Assert.Equal("2 TWAIN scanner drivers are installed.", Check(Troubleshooter.Diagnose(HealthyWindows()), "twain").Detail);
        Assert.DoesNotContain("twain", Ids(Troubleshooter.Diagnose(HealthyWindows() with { Twain = TwainStatus.Unknown })));
    }

    [Fact]
    public void ThirtyTwoBitDrivers_AreNamedByFile()
    {
        var one = Check(Troubleshooter.Diagnose(TroubledWindows()), "twain32");
        Assert.Equal("A TWAIN driver works only with 32-bit apps", one.Title);
        Assert.Equal("\"acme.ds\" is installed only for 32-bit apps, and CompleteScanner can use only 64-bit drivers. "
                     + "Install the maker's 64-bit (x64) driver. Many scanners also work through Windows Image "
                     + "Acquisition (WIA) once the maker's full driver package is installed.", one.Detail);
        var two = Check(Troubleshooter.Diagnose(HealthyWindows() with { ThirtyTwoBitOnlyDrivers = ["Acme/acme.ds", "beta.ds"] }), "twain32");
        Assert.Equal((CheckStatus.Problem, "2 TWAIN drivers work only with 32-bit apps"), (two.Status, two.Title));
        Assert.StartsWith("\"acme.ds\", \"beta.ds\" are installed only for 32-bit apps,", two.Detail);
    }

    [Fact]
    public void NetworkSearchOnWindows()
    {
        string Detail(DiscoverySnapshot s) => Check(Troubleshooter.Diagnose(s), "discovery").Detail;
        Assert.Equal("No network scanner has been found on this network yet. A scanner that does not appear can be added by its address.",
                     Detail(HealthyWindows() with { DiscoveredCount = 0 }));
        Assert.Equal("1 network scanner found. A scanner that does not appear can be added by its address.",
                     Detail(HealthyWindows()));
        Assert.Equal("3 network scanners found. A scanner that does not appear can be added by its address.",
                     Detail(HealthyWindows() with { DiscoveredCount = 3 }));
        Assert.Equal("The search has just started. Scanners on the network appear as they answer.",
                     Detail(HealthyWindows() with { Discovery = DiscoveryStatus.Searching }));
        var running = Check(Troubleshooter.Diagnose(HealthyWindows()), "discovery");
        Assert.Equal((CheckStatus.Ok, "Looking for network scanners"), (running.Status, running.Title));
        Assert.Equal([TroubleshootAction.AddByAddress], running.Actions);

        var unavailable = Check(Troubleshooter.Diagnose(TroubledWindows()), "discovery");
        Assert.Equal((CheckStatus.Warning, "Automatic search for network scanners is not working"), (unavailable.Status, unavailable.Title));
        Assert.Equal("Windows could not search the network for scanners (Access is denied). You can still add a network "
                     + "scanner by its address.", unavailable.Detail);
        Assert.Equal([TroubleshootAction.AddByAddress, TroubleshootAction.Refresh], unavailable.Actions);
        Assert.DoesNotContain("discovery", Ids(Troubleshooter.Diagnose(HealthyWindows() with { Discovery = DiscoveryStatus.Off })));
    }

    [Fact]
    public void AddressesAddedByHand_OnlyThoseNotAnsweringAreChecks()
    {
        var checks = Troubleshooter.Diagnose(TroubledWindows());
        Assert.DoesNotContain("manualHost:10.0.0.2", Ids(checks));
        Assert.Equal(new TroubleshootCheck(
            "manualHost:192.168.1.50", CheckStatus.Warning, "No scanner answers at 192.168.1.50",
            "No scanner answered at 192.168.1.50. Check that the scanner is on and that its address has not changed; "
            + "its network settings page or control panel shows the current one. The app tries the address again every minute.",
            [TroubleshootAction.Refresh]), Check(checks, "manualHost:192.168.1.50"));
        var unchecked_ = Check(Troubleshooter.Diagnose(new DiscoverySnapshot { ManualHosts = [new("scanner.local", false)] }),
                               "manualHost:scanner.local");
        Assert.StartsWith("Check that the scanner is on", unchecked_.Detail);
    }

    [Fact]
    public void Windows_Tips()
    {
        var checks = Troubleshooter.Diagnose(HealthyWindows());
        var usb = Check(checks, "usb");
        Assert.Equal("Scanner connected by USB?", usb.Title);
        Assert.Equal("Turn the scanner on and connect it straight to the PC, not through a hub. Windows lists a USB "
                     + "scanner only once its driver is installed: get the driver from the scanner maker's website, "
                     + "install it, then select Refresh. Windows scanner settings show whether Windows sees the scanner.",
                     usb.Detail);
        Assert.Equal([TroubleshootAction.OpenScannerSettings, TroubleshootAction.Refresh], usb.Actions);
        var other = Check(checks, "otherApps");
        Assert.Equal("Still not listed?", other.Title);
        Assert.Equal("Wake the scanner (press a button on it), and close other apps that may be using it, such as "
                     + "Windows Scan or the scanner maker's app. Some scanners work only with their maker's own app; "
                     + "the maker's website says whether yours does.", other.Detail);
    }

    [Fact]
    public void Mac_HasNoWindowsChecks_AndNeverOffersAddByAddress()
    {
        var snapshot = TroubledWindows() with { Platform = TroubleshootPlatform.Mac, Discovery = DiscoveryStatus.Running };
        var checks = Troubleshooter.Diagnose(snapshot);
        Assert.Equal(["lastFailure", "network", "discovery", "usb", "networkScanner", "sharing", "otherApps"], Ids(checks));
        Assert.DoesNotContain(checks, c => c.Actions.Contains(TroubleshootAction.AddByAddress));
        Assert.Contains("such as Image Capture or the scanner maker's app", Check(checks, "lastFailure").Detail);
        var discovery = Check(checks, "discovery");
        Assert.Equal((CheckStatus.Ok, "Looking for scanners"), (discovery.Status, discovery.Title));
        Assert.Equal("macOS is looking for scanners connected by USB, on the network and shared by other Macs. They "
                     + "appear here as they are found.", discovery.Detail);
    }

    [Fact]
    public void Mac_Tips()
    {
        var checks = Troubleshooter.Diagnose(new DiscoverySnapshot { Platform = TroubleshootPlatform.Mac });
        Assert.Equal(["usb", "networkScanner", "sharing", "otherApps"], Ids(checks));
        Assert.Equal([TroubleshootAction.OpenImageCapture, TroubleshootAction.Refresh], Check(checks, "usb").Actions);
        Assert.Equal("Turn the scanner on and connect it straight to the Mac, not through a hub. macOS lists a USB "
                     + "scanner only when it can scan without a driver or its maker's macOS driver is installed: get "
                     + "it from the scanner maker's website. If Image Capture does not show the scanner either, macOS "
                     + "does not see it.", Check(checks, "usb").Detail);
        Assert.Equal("The Mac and the scanner must be on the same network. If macOS asked whether CompleteScanner may "
                     + "find devices on your local network, allow it in System Settings, Privacy & Security, Local "
                     + "Network. A network printer with a scanner added in Printers & Scanners also appears here.",
                     Check(checks, "networkScanner").Detail);
        Assert.Equal([TroubleshootAction.OpenScannerSettings], Check(checks, "networkScanner").Actions);
        Assert.Equal("It appears when Scanner Sharing is on in that Mac's System Settings, General, Sharing, and both "
                     + "Macs are on the same network.", Check(checks, "sharing").Detail);
    }

    [Fact]
    public void Mac_SearchNotRunning_AsksToRefresh()
    {
        foreach (var status in new[] { DiscoveryStatus.Off, DiscoveryStatus.Unavailable })
        {
            var check = Check(Troubleshooter.Diagnose(new DiscoverySnapshot { Platform = TroubleshootPlatform.Mac, Discovery = status }),
                              "discovery");
            Assert.Equal((CheckStatus.Warning, "Not looking for scanners"), (check.Status, check.Title));
            Assert.Equal("The search for scanners is not running. Select Refresh to start it again.", check.Detail);
            Assert.Equal([TroubleshootAction.Refresh], check.Actions);
        }
    }

    [Fact]
    public void Headline_CountsScannersButNotTheDemo()
    {
        Assert.Equal("No scanner found yet", Troubleshooter.Headline(new DiscoverySnapshot()));
        Assert.Equal("No scanner found yet", Troubleshooter.Headline(new DiscoverySnapshot { Devices = [Demo] }));
        var second = new ScannerInfo("escl:2", "Office MFP", "Network", Backend: "escl");
        Assert.Equal("2 scanners found", Troubleshooter.Headline(new DiscoverySnapshot { Devices = [Demo, WiaScanner, second] }));
    }

    [Fact]
    public void Summary_CountsProblemsAndWarnings()
    {
        TroubleshootCheck Make(CheckStatus status) => new("x", status, "t", "d", []);
        Assert.Equal("1 problem found.", Troubleshooter.Summary([Make(CheckStatus.Problem), Make(CheckStatus.Ok)]));
        Assert.Equal("1 warning found.", Troubleshooter.Summary([Make(CheckStatus.Warning), Make(CheckStatus.Tip)]));
        Assert.Equal("2 problems and 1 warning found.",
                     Troubleshooter.Summary([Make(CheckStatus.Problem), Make(CheckStatus.Warning), Make(CheckStatus.Problem)]));
    }

    [Fact]
    public void Labels()
    {
        Assert.Equal("Refresh", Troubleshooter.Label(TroubleshootAction.Refresh, TroubleshootPlatform.Windows));
        Assert.Equal("Add scanner by address…", Troubleshooter.Label(TroubleshootAction.AddByAddress, TroubleshootPlatform.Windows));
        Assert.Equal("Open Windows scanner settings", Troubleshooter.Label(TroubleshootAction.OpenScannerSettings, TroubleshootPlatform.Windows));
        Assert.Equal("Open Printers & Scanners", Troubleshooter.Label(TroubleshootAction.OpenScannerSettings, TroubleshootPlatform.Mac));
        Assert.Equal("Open network settings", Troubleshooter.Label(TroubleshootAction.OpenNetworkSettings, TroubleshootPlatform.Windows));
        Assert.Equal("Open Network settings", Troubleshooter.Label(TroubleshootAction.OpenNetworkSettings, TroubleshootPlatform.Mac));
        Assert.Equal("Open Image Capture", Troubleshooter.Label(TroubleshootAction.OpenImageCapture, TroubleshootPlatform.Mac));
        Assert.Equal("Copy diagnostics", Troubleshooter.Label(TroubleshootAction.CopyDiagnostics, TroubleshootPlatform.Mac));
        Assert.Equal(["OK", "Tip", "Warning", "Problem"],
                     new[] { CheckStatus.Ok, CheckStatus.Tip, CheckStatus.Warning, CheckStatus.Problem }.Select(Troubleshooter.StatusLabel));
    }

    [Fact]
    public void Report_ListsEveryCheckWithItsDetail()
    {
        var snapshot = HealthyWindows();
        var checks = Troubleshooter.Diagnose(snapshot);
        string report = Troubleshooter.Report(snapshot, checks);
        var lines = report.Split('\n');
        Assert.Equal("Why isn't my scanner listed?", lines[0]);
        Assert.Equal("1 scanner found. Nothing here stops scanners from appearing. The tips below cover the usual causes.", lines[1]);
        Assert.Equal("OK: Connected to a private network", lines[2]);
        Assert.Equal("  Network scanners on this network can be found.", lines[3]);
        Assert.Equal("Tip: Still not listed?", lines[^3]);
        Assert.Equal("", lines[^1]);
        Assert.Equal(2 + 2 * checks.Count + 1, lines.Length);
    }

    [Fact]
    public void CombineNetworks()
    {
        Assert.Equal(NetworkStatus.Offline, Troubleshooter.CombineNetworks([]));
        Assert.Equal(NetworkStatus.PublicNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PublicNetwork]));
        Assert.Equal(NetworkStatus.PrivateNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PublicNetwork, NetworkStatus.PrivateNetwork]));
        Assert.Equal(NetworkStatus.DomainNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PrivateNetwork, NetworkStatus.DomainNetwork]));
        Assert.Equal(NetworkStatus.Unknown, Troubleshooter.CombineNetworks([NetworkStatus.Unknown]));
        Assert.Equal(NetworkStatus.PublicNetwork, Troubleshooter.CombineNetworks([NetworkStatus.Unknown, NetworkStatus.PublicNetwork]));
    }

    [Fact]
    public void FailureFrom_KeepsWhatSaysSomethingAboutTheScanner()
    {
        var busy = Troubleshooter.FailureFrom("Acme", ScanException.ForProblem(ScannerProblem.Busy));
        Assert.Equal(new ScannerFailure("Acme", ScannerProblems.Describe(ScannerProblem.Busy), ScannerProblem.Busy), busy);
        Assert.Equal(new ScannerFailure("Acme", "Scanner unavailable: gone"),
                     Troubleshooter.FailureFrom("Acme", ScanException.DeviceUnavailable("gone")));
        Assert.Equal(new ScannerFailure("Acme", "Could not open a session with the scanner: x"),
                     Troubleshooter.FailureFrom("Acme", ScanException.SessionFailed("x")));
        Assert.Null(Troubleshooter.FailureFrom("Acme", ScanException.Cancelled()));
        Assert.Null(Troubleshooter.FailureFrom("Acme", ScanException.ExportFailed("disk full")));
        Assert.Null(Troubleshooter.FailureFrom("Acme", ScanException.Unsupported("1200 dpi")));
    }

    [Fact]
    public void FailureFrom_IgnoresCancellation()
    {
        Assert.Null(Troubleshooter.FailureFrom("Acme", new OperationCanceledException()));
        Assert.Equal(new ScannerFailure("Acme", "boom"), Troubleshooter.FailureFrom("Acme", new InvalidOperationException("boom")));
    }
}
