using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/TroubleshooterTests.swift (same fixtures, same text).
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
        Assert.Equal("No scanner found", Troubleshooter.Headline(snapshot));
        Assert.Equal("3 problems and 4 warnings found.", Troubleshooter.Summary(checks));
        Assert.Equal("No scanner found · 3 problems, 4 warnings", Troubleshooter.Overview(snapshot, checks));
    }

    [Fact]
    public void Overview_IsOneLine()
    {
        var healthy = HealthyWindows();
        Assert.Equal("1 scanner found", Troubleshooter.Overview(healthy, Troubleshooter.Diagnose(healthy)));
        var publicNetwork = new DiscoverySnapshot { Devices = [Demo], Network = NetworkStatus.PublicNetwork };
        Assert.Equal("No scanner found · 1 warning", Troubleshooter.Overview(publicNetwork, Troubleshooter.Diagnose(publicNetwork)));
        var offline = new DiscoverySnapshot { Network = NetworkStatus.Offline };
        Assert.Equal("No scanner found · 1 problem", Troubleshooter.Overview(offline, Troubleshooter.Diagnose(offline)));
    }

    /// <summary>Every check the fixtures make, on both platforms.</summary>
    private static IEnumerable<TroubleshootCheck> EveryCheck()
    {
        var snapshots = new List<DiscoverySnapshot> { HealthyWindows(), TroubledWindows() };
        foreach (var service in Enum.GetValues<ServiceStatus>()) snapshots.Add(HealthyWindows() with { WiaService = service });
        foreach (var twain in Enum.GetValues<TwainStatus>()) snapshots.Add(HealthyWindows() with { Twain = twain, TwainDriverCount = 0 });
        foreach (var network in Enum.GetValues<NetworkStatus>()) snapshots.Add(HealthyWindows() with { Network = network });
        foreach (var discovery in Enum.GetValues<DiscoveryStatus>())
        {
            snapshots.Add(HealthyWindows() with { Discovery = discovery });
            snapshots.Add(new DiscoverySnapshot { Platform = TroubleshootPlatform.Mac, Discovery = discovery });
        }
        foreach (var problem in Enum.GetValues<ScannerProblem>())
        {
            snapshots.Add(new DiscoverySnapshot { LastFailure = new ScannerFailure("Acme", "x", problem) });
        }
        snapshots.Add(new DiscoverySnapshot { LastFailure = new ScannerFailure("Office MFP", "Office MFP did not answer.") });
        snapshots.Add(TroubledWindows() with { Platform = TroubleshootPlatform.Mac });
        snapshots.Add(HealthyPhone());
        snapshots.Add(TroubledPhone());
        foreach (var network in Enum.GetValues<NetworkStatus>()) snapshots.Add(HealthyPhone() with { Network = network });
        foreach (var discovery in Enum.GetValues<DiscoveryStatus>()) snapshots.Add(HealthyPhone() with { Discovery = discovery });
        foreach (var problem in Enum.GetValues<ScannerProblem>())
        {
            snapshots.Add(HealthyPhone() with { LastFailure = new ScannerFailure("Acme", "x", problem) });
        }
        snapshots.Add(HealthyPhone() with { LastFailure = new ScannerFailure("Office MFP", "Office MFP did not answer.") });
        return snapshots.SelectMany(Troubleshooter.Diagnose);
    }

    // MARK: - iPhone and iPad (never produced on Windows)

    private static readonly ScannerInfo NetworkScanner =
        new("escl:uuid", "HP Color LaserJet MFP M479fdw", "Network", Backend: "escl");

    /// <summary>A phone on Wi-Fi that found a network scanner.</summary>
    private static DiscoverySnapshot HealthyPhone() => new()
    {
        Platform = TroubleshootPlatform.Ios,
        Devices = [Demo, NetworkScanner],
        Network = NetworkStatus.PrivateNetwork,
        Discovery = DiscoveryStatus.Running,
        DiscoveredCount = 1,
    };

    /// <summary>A phone off Wi-Fi, without Local Network access, with an address that does not answer.</summary>
    private static DiscoverySnapshot TroubledPhone() => new()
    {
        Platform = TroubleshootPlatform.Ios,
        Devices = [Demo],
        Network = NetworkStatus.Offline,
        Discovery = DiscoveryStatus.Denied,
        ManualHosts = [new("192.168.1.50", false, "No scanner answered at 192.168.1.50."), new("10.0.0.2", true)],
        LastFailure = new ScannerFailure("Office MFP", "Office MFP did not answer."),
    };

    [Fact]
    public void Phone_Healthy_ShowsWhatIsFineThenItsTips()
    {
        var snapshot = HealthyPhone();
        var checks = Troubleshooter.Diagnose(snapshot);
        Assert.Equal(["network", "discovery", "networkScanner", "usb", "otherApps"], Ids(checks));
        Assert.Equal([CheckStatus.Ok, CheckStatus.Ok, CheckStatus.Tip, CheckStatus.Tip, CheckStatus.Tip], checks.Select(c => c.Status));
        Assert.Equal("1 scanner found", Troubleshooter.Overview(snapshot, checks));
        var network = Check(checks, "network");
        Assert.Equal(("Connected to a local network", "Network scanners on this network can be found."), (network.Title, network.Detail));
        var discovery = Check(checks, "discovery");
        Assert.Equal((CheckStatus.Ok, "Looking for network scanners"), (discovery.Status, discovery.Title));
        Assert.Equal("1 network scanner found. A scanner that doesn't appear can be added by its address.", discovery.FullDetail);
        Assert.Equal([TroubleshootAction.AddByAddress], discovery.Actions);
        Assert.Equal(new TroubleshootCheck(
            "networkScanner", CheckStatus.Tip, "Scanner on the network?",
            "This device and the scanner must be on the same Wi-Fi.",
            [TroubleshootAction.AddByAddress],
            "Guest networks and some VPNs hide scanners. Try adding the scanner by its address."), Check(checks, "networkScanner"));
        Assert.Equal(new TroubleshootCheck(
            "usb", CheckStatus.Tip, "Connected by USB?",
            "Use its Wi-Fi connection; iPhone and iPad can't use USB scanners.",
            [],
            "Most scanners that print or copy also join Wi-Fi. The scanner's manual shows how."), Check(checks, "usb"));
        Assert.Equal("Press a button on the scanner. Close scanning apps on other devices. Some scanners work only with "
                     + "Windows (WSD) or their maker's app.", Check(checks, "otherApps").More);
    }

    [Fact]
    public void Phone_Troubled_LocalNetworkAccessOffComesFirstWithSettings()
    {
        var snapshot = TroubledPhone();
        var checks = Troubleshooter.Diagnose(snapshot);
        Assert.Equal(["network", "localNetwork", "lastFailure", "manualHost:192.168.1.50", "networkScanner", "usb", "otherApps"],
                     Ids(checks));
        Assert.Equal("No scanner found · 2 problems, 2 warnings", Troubleshooter.Overview(snapshot, checks));
        Assert.Equal(new TroubleshootCheck(
            "localNetwork", CheckStatus.Problem, "Local Network access is off",
            "Turn on Local Network for Lazy Scan in Settings.",
            [TroubleshootAction.OpenAppSettings],
            "Without it, the app can't find or reach scanners on your network. Scanners appear as soon as it's on. "
            + "If it's on already, turn it off and on again."), Check(checks, "localNetwork"));
        Assert.Equal(new TroubleshootCheck(
            "network", CheckStatus.Problem, "Not connected to Wi-Fi",
            "Join the scanner's Wi-Fi network, then tap Refresh.",
            [TroubleshootAction.Refresh],
            "Network scanners are found only on Wi-Fi or a wired network. The camera works without one."), Check(checks, "network"));
        Assert.Equal("Office MFP did not answer. It must be on the same network as this device.", Check(checks, "lastFailure").More);
        Assert.StartsWith("No scanner answered at 192.168.1.50. Its network settings page",
                          Check(checks, "manualHost:192.168.1.50").More);
        Assert.DoesNotContain("manualHost:10.0.0.2", Ids(checks));
        var busy = Troubleshooter.Diagnose(HealthyPhone() with { LastFailure = new ScannerFailure("Acme", "x", ScannerProblem.Busy) });
        Assert.Contains("another device or app may be using it", Check(busy, "lastFailure").More);
    }

    [Fact]
    public void Phone_SearchStates_SayWhatIOSDoes()
    {
        string Detail(DiscoverySnapshot s) => Check(Troubleshooter.Diagnose(s), "discovery").FullDetail;
        Assert.Equal("Scanners on the network appear as they answer. The search has just started.",
                     Detail(HealthyPhone() with { Discovery = DiscoveryStatus.Searching }));
        var unavailable = Check(Troubleshooter.Diagnose(HealthyPhone() with
        {
            Discovery = DiscoveryStatus.Unavailable,
            DiscoveryDetail = "NoSuchRecord.",
        }), "discovery");
        Assert.Equal((CheckStatus.Warning, "Network search is not working"), (unavailable.Status, unavailable.Title));
        Assert.Equal("iOS could not search the network for scanners (NoSuchRecord).", unavailable.More);
        Assert.Equal([TroubleshootAction.AddByAddress, TroubleshootAction.Refresh], unavailable.Actions);
        // Before the search has started there is nothing to say; denied access replaces the search's check.
        Assert.DoesNotContain("discovery", Ids(Troubleshooter.Diagnose(HealthyPhone() with { Discovery = DiscoveryStatus.Off })));
        var denied = Troubleshooter.Diagnose(HealthyPhone() with { Discovery = DiscoveryStatus.Denied });
        Assert.DoesNotContain("discovery", Ids(denied));
        Assert.Contains("localNetwork", Ids(denied));
        // iOS has no public networks: any local network is fine; an unknown one has no check.
        Assert.Equal(CheckStatus.Ok, Check(Troubleshooter.Diagnose(HealthyPhone() with { Network = NetworkStatus.PublicNetwork }), "network").Status);
        Assert.DoesNotContain("network", Ids(Troubleshooter.Diagnose(HealthyPhone() with { Network = NetworkStatus.Unknown })));
    }

    [Fact]
    public void Phone_NeverOffersTheComputersActions_AndTheComputersNeverOfferSettings()
    {
        var computerActions = new[]
        {
            TroubleshootAction.OpenScannerSettings, TroubleshootAction.OpenNetworkSettings, TroubleshootAction.OpenImageCapture,
        };
        var phone = new List<TroubleshootCheck>();
        foreach (var snapshot in new[] { HealthyPhone(), TroubledPhone() })
        {
            foreach (var network in Enum.GetValues<NetworkStatus>())
            {
                foreach (var discovery in Enum.GetValues<DiscoveryStatus>())
                {
                    phone.AddRange(Troubleshooter.Diagnose(snapshot with { Network = network, Discovery = discovery }));
                }
            }
        }
        Assert.DoesNotContain(phone, c => c.Actions.Intersect(computerActions).Any());
        // Windows and the Mac never report denied access, so they never offer the phone's Settings.
        Assert.DoesNotContain(Troubleshooter.Diagnose(TroubledWindows()), c => c.Actions.Contains(TroubleshootAction.OpenAppSettings));
        Assert.DoesNotContain(Troubleshooter.Diagnose(HealthyWindows() with { Platform = TroubleshootPlatform.Mac }),
                              c => c.Actions.Contains(TroubleshootAction.OpenAppSettings));
    }

    [Fact]
    public void EveryCheck_HasAShortTitle_AndAOneLineDetail_TheRestIsMoreHelp()
    {
        foreach (var check in EveryCheck())
        {
            Assert.InRange(StatusLine.Words(check.Title), 1, 6);
            Assert.InRange(StatusLine.Words(check.Detail), 1, 15);
            Assert.Equal(check.More.Length == 0 ? check.Detail : $"{check.Detail} {check.More}", check.FullDetail);
            Assert.DoesNotContain(check.Detail, check.More);
        }
        foreach (var action in Enum.GetValues<TroubleshootAction>())
        {
            Assert.InRange(StatusLine.Words(Troubleshooter.Label(action, TroubleshootPlatform.Windows)), 1, 3);
            Assert.InRange(StatusLine.Words(Troubleshooter.Label(action, TroubleshootPlatform.Mac)), 1, 3);
            Assert.InRange(StatusLine.Words(Troubleshooter.Label(action, TroubleshootPlatform.Ios)), 1, 3);
        }
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
            "lastFailure", CheckStatus.Problem, "Acme Scan 100 is busy",
            "Close other apps using it, then choose it again.",
            [TroubleshootAction.Refresh],
            "A scanner works with one app at a time; Windows Scan or the maker's app may be using it. Wait until the "
            + "scanner has finished, then choose it again."), check);
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
        Assert.Equal("Cover open: Acme Scan 100", check.Title);
        Assert.Equal("Close the cover, then scan again.", check.Detail);
        Assert.Equal(ScannerProblems.Advice(ScannerProblem.CoverOpen), check.Detail);
        Assert.Equal("", check.More);
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
        Assert.Equal("Check that it is on, awake and connected.", check.Detail);
        Assert.Equal("Office MFP did not answer (192.168.1.9: no answer in time). It must be connected by its cable or "
                     + "to the same network as this PC.", check.More);
        var mac = Check(Troubleshooter.Diagnose(snapshot with { Platform = TroubleshootPlatform.Mac }), "lastFailure");
        Assert.EndsWith("to the same network as this Mac.", mac.More);
    }

    public static TheoryData<ServiceStatus, CheckStatus, string> WiaStates => new()
    {
        { ServiceStatus.Running, CheckStatus.Ok, "Scanner service is on" },
        { ServiceStatus.Starting, CheckStatus.Warning, "Scanner service is starting" },
        { ServiceStatus.Stopped, CheckStatus.Warning, "Scanner service is not running" },
        { ServiceStatus.Stopping, CheckStatus.Warning, "Scanner service is not running" },
        { ServiceStatus.Paused, CheckStatus.Warning, "Scanner service is not running" },
        { ServiceStatus.Disabled, CheckStatus.Problem, "Scanner service is turned off" },
        { ServiceStatus.NotInstalled, CheckStatus.Problem, "Scanner service is missing" },
    };

    [Theory]
    [MemberData(nameof(WiaStates))]
    public void WiaService(ServiceStatus service, CheckStatus status, string title)
    {
        var check = Check(Troubleshooter.Diagnose(HealthyWindows() with { WiaService = service }), "wiaService");
        Assert.Equal(status, check.Status);
        Assert.Equal(title, check.Title);
        Assert.Contains("Windows Image Acquisition (WIA)", check.FullDetail);
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
        Assert.Equal("An administrator can set it to Automatic in Services.", check.Detail);
        Assert.Equal("Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners can't "
                     + "appear. Someone with administrator rights can set its startup type to Automatic in Services, then "
                     + "restart the PC.", check.More);
        Assert.Equal([TroubleshootAction.Refresh], check.Actions);
    }

    [Fact]
    public void Network()
    {
        var offline = Check(Troubleshooter.Diagnose(HealthyWindows() with { Network = NetworkStatus.Offline }), "network");
        Assert.Equal((CheckStatus.Problem, "Not connected to a network"), (offline.Status, offline.Title));
        Assert.Equal("Connect to the network the scanner is on, then select Refresh.", offline.Detail);
        Assert.Equal("This PC is not on a network, so network scanners can't be found. Scanners connected by USB are not "
                     + "affected.", offline.More);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings, TroubleshootAction.Refresh], offline.Actions);

        var publicNetwork = Check(Troubleshooter.Diagnose(HealthyWindows() with { Network = NetworkStatus.PublicNetwork }), "network");
        Assert.Equal((CheckStatus.Warning, "Network set to Public"), (publicNetwork.Status, publicNetwork.Title));
        Assert.Equal("Windows won't find network scanners on a Public network.", publicNetwork.Detail);
        Assert.Equal("If this is your home or office network, set it to Private in network settings. You can also add "
                     + "the scanner by its address.", publicNetwork.More);
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
        Assert.Equal("Some scanners need their maker's 64-bit TWAIN driver.", none.Detail);
        Assert.Equal("Some scanners, often document scanners, work only through their maker's TWAIN driver, which "
                     + "also installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then "
                     + "restart Lazy Scan.", none.More);
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
        Assert.Equal("A TWAIN driver is 32-bit only", one.Title);
        Assert.Equal("\"acme.ds\" is installed only for 32-bit apps.", one.Detail);
        Assert.Equal("Lazy Scan reaches such drivers through its 32-bit TWAIN helper, which has not listed it yet. "
                     + "A 64-bit (x64) driver from the maker, where there is one, works without the helper. Many scanners "
                     + "also work through Windows Image Acquisition (WIA) once the maker's full driver package is installed.",
                     one.More);
        var two = Check(Troubleshooter.Diagnose(HealthyWindows() with { ThirtyTwoBitOnlyDrivers = ["Acme/acme.ds", "beta.ds"] }), "twain32");
        Assert.Equal((CheckStatus.Problem, "2 TWAIN drivers are 32-bit only"), (two.Status, two.Title));
        Assert.Equal("\"acme.ds\", \"beta.ds\" are installed only for 32-bit apps.", two.Detail);
        Assert.StartsWith("Lazy Scan reaches such drivers through its 32-bit TWAIN helper, which has not listed them yet. ",
                          two.More);
    }

    [Fact]
    public void ThirtyTwoBitDrivers_SayWhyTheHelperDoesNotReachThem()
    {
        var snapshot = TroubledWindows() with
        {
            ThirtyTwoBitHelperProblem = " It cannot run: it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), "
                                        + "which is not installed. Install it, then restart Lazy Scan ",
        };
        var check = Check(Troubleshooter.Diagnose(snapshot), "twain32");
        Assert.Equal((CheckStatus.Problem, "A TWAIN driver is 32-bit only"), (check.Status, check.Title));
        Assert.Equal("\"acme.ds\" is installed only for 32-bit apps.", check.Detail);
        Assert.Equal("Lazy Scan reaches such drivers through its 32-bit TWAIN helper. It cannot run: it needs the "
                     + ".NET 10 Desktop Runtime for 32-bit programs (x86), which is not installed. Install it, then restart "
                     + "Lazy Scan. A 64-bit (x64) driver from the maker, where there is one, works without the helper. "
                     + "Many scanners also work through Windows Image Acquisition (WIA) once the maker's full driver package "
                     + "is installed.", check.More);
        Assert.Empty(check.Actions);
        // A blank reason is no reason.
        Assert.Equal(Check(Troubleshooter.Diagnose(TroubledWindows()), "twain32"),
                     Check(Troubleshooter.Diagnose(TroubledWindows() with { ThirtyTwoBitHelperProblem = "  " }), "twain32"));
        // Without 32-bit-only drivers, or on the Mac, there is nothing to say.
        Assert.DoesNotContain("twain32", Ids(Troubleshooter.Diagnose(HealthyWindows() with { ThirtyTwoBitHelperProblem = "It failed." })));
        Assert.DoesNotContain("twain32", Ids(Troubleshooter.Diagnose(snapshot with { Platform = TroubleshootPlatform.Mac })));
    }

    [Fact]
    public void NetworkSearchOnWindows()
    {
        string Detail(DiscoverySnapshot s) => Check(Troubleshooter.Diagnose(s), "discovery").FullDetail;
        Assert.Equal("No network scanner has been found on this network yet. A scanner that doesn't appear can be added by its address.",
                     Detail(HealthyWindows() with { DiscoveredCount = 0 }));
        Assert.Equal("1 network scanner found. A scanner that doesn't appear can be added by its address.",
                     Detail(HealthyWindows()));
        Assert.Equal("3 network scanners found. A scanner that doesn't appear can be added by its address.",
                     Detail(HealthyWindows() with { DiscoveredCount = 3 }));
        Assert.Equal("Scanners on the network appear as they answer. The search has just started.",
                     Detail(HealthyWindows() with { Discovery = DiscoveryStatus.Searching }));
        var running = Check(Troubleshooter.Diagnose(HealthyWindows()), "discovery");
        Assert.Equal((CheckStatus.Ok, "Looking for network scanners"), (running.Status, running.Title));
        Assert.Equal([TroubleshootAction.AddByAddress], running.Actions);

        var unavailable = Check(Troubleshooter.Diagnose(TroubledWindows()), "discovery");
        Assert.Equal((CheckStatus.Warning, "Network search is not working"), (unavailable.Status, unavailable.Title));
        Assert.Equal("You can still add a network scanner by its address.", unavailable.Detail);
        Assert.Equal("Windows could not search the network for scanners (Access is denied).", unavailable.More);
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
            "Check that it is on and its address hasn't changed.",
            [TroubleshootAction.Refresh],
            "No scanner answered at 192.168.1.50. Its network settings page or control panel shows the current address. "
            + "The app tries the address again every minute."), Check(checks, "manualHost:192.168.1.50"));
        var unchecked_ = Check(Troubleshooter.Diagnose(new DiscoverySnapshot { ManualHosts = [new("scanner.local", false)] }),
                               "manualHost:scanner.local");
        Assert.StartsWith("Its network settings page", unchecked_.More);
    }

    [Fact]
    public void Windows_Tips()
    {
        var checks = Troubleshooter.Diagnose(HealthyWindows());
        var usb = Check(checks, "usb");
        Assert.Equal("Connected by USB?", usb.Title);
        Assert.Equal("Connect it directly (no hub) and install the maker's driver.", usb.Detail);
        Assert.Equal("Windows lists a USB scanner only after its driver is installed. Get it from the maker's website, "
                     + "then select Refresh. Scanner settings show whether Windows sees it.", usb.More);
        Assert.Equal([TroubleshootAction.OpenScannerSettings, TroubleshootAction.Refresh], usb.Actions);
        var other = Check(checks, "otherApps");
        Assert.Equal("Still not listed?", other.Title);
        Assert.Equal("Wake the scanner and close other scanning apps.", other.Detail);
        Assert.Equal("Press a button on the scanner. Close Windows Scan or the maker's app. Some scanners work only with "
                     + "their maker's app.", other.More);
    }

    [Fact]
    public void Mac_HasNoWindowsChecks_AndNeverOffersAddByAddress()
    {
        var snapshot = TroubledWindows() with { Platform = TroubleshootPlatform.Mac, Discovery = DiscoveryStatus.Running };
        var checks = Troubleshooter.Diagnose(snapshot);
        Assert.Equal(["lastFailure", "network", "discovery", "usb", "networkScanner", "sharing", "otherApps"], Ids(checks));
        Assert.DoesNotContain(checks, c => c.Actions.Contains(TroubleshootAction.AddByAddress));
        Assert.Contains("Image Capture or the maker's app may be using it", Check(checks, "lastFailure").More);
        var discovery = Check(checks, "discovery");
        Assert.Equal((CheckStatus.Ok, "Looking for scanners"), (discovery.Status, discovery.Title));
        Assert.Equal("Scanners appear here as macOS finds them.", discovery.Detail);
        Assert.Equal("macOS looks for scanners connected by USB, on the network and shared by other Macs.", discovery.More);
    }

    [Fact]
    public void Mac_Tips()
    {
        var checks = Troubleshooter.Diagnose(new DiscoverySnapshot { Platform = TroubleshootPlatform.Mac });
        Assert.Equal(["usb", "networkScanner", "sharing", "otherApps"], Ids(checks));
        Assert.Equal([TroubleshootAction.OpenImageCapture, TroubleshootAction.Refresh], Check(checks, "usb").Actions);
        Assert.Equal("Connect it directly (no hub) and install the maker's macOS driver.", Check(checks, "usb").Detail);
        Assert.Equal("macOS lists a USB scanner only when it can scan without a driver or its maker's driver is installed. "
                     + "If Image Capture doesn't show it either, macOS doesn't see it.", Check(checks, "usb").More);
        Assert.Equal("The Mac and the scanner must be on the same network.", Check(checks, "networkScanner").Detail);
        Assert.Equal("If macOS asked whether Lazy Scan may find devices on your local network, allow it in System "
                     + "Settings, Privacy & Security, Local Network. A network printer with a scanner added in Printers & "
                     + "Scanners also appears here.", Check(checks, "networkScanner").More);
        Assert.Equal([TroubleshootAction.OpenScannerSettings], Check(checks, "networkScanner").Actions);
        Assert.Equal(("Shared by another Mac?", "Turn on Scanner Sharing in that Mac's Sharing settings."),
                     (Check(checks, "sharing").Title, Check(checks, "sharing").Detail));
        Assert.Equal("It's in System Settings, General, Sharing. Both Macs must be on the same network.", Check(checks, "sharing").More);
        Assert.Equal("Press a button on the scanner. Close Image Capture or the maker's app. Some scanners work only with "
                     + "their maker's app.", Check(checks, "otherApps").More);
    }

    [Fact]
    public void Mac_SearchNotRunning_AsksToRefresh()
    {
        foreach (var status in new[] { DiscoveryStatus.Off, DiscoveryStatus.Unavailable })
        {
            var check = Check(Troubleshooter.Diagnose(new DiscoverySnapshot { Platform = TroubleshootPlatform.Mac, Discovery = status }),
                              "discovery");
            Assert.Equal((CheckStatus.Warning, "Not looking for scanners"), (check.Status, check.Title));
            Assert.Equal("Select Refresh to start the search again.", check.Detail);
            Assert.Equal("The search for scanners is not running.", check.More);
            Assert.Equal([TroubleshootAction.Refresh], check.Actions);
        }
    }

    [Fact]
    public void Headline_CountsScannersButNotTheDemo()
    {
        Assert.Equal("No scanner found", Troubleshooter.Headline(new DiscoverySnapshot()));
        Assert.Equal("No scanner found", Troubleshooter.Headline(new DiscoverySnapshot { Devices = [Demo] }));
        Assert.Equal("1 scanner found", Troubleshooter.Headline(new DiscoverySnapshot { Devices = [Demo, WiaScanner] }));
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
        Assert.Equal("Add by address…", Troubleshooter.Label(TroubleshootAction.AddByAddress, TroubleshootPlatform.Windows));
        Assert.Equal("Scanner settings", Troubleshooter.Label(TroubleshootAction.OpenScannerSettings, TroubleshootPlatform.Windows));
        Assert.Equal("Printers & Scanners", Troubleshooter.Label(TroubleshootAction.OpenScannerSettings, TroubleshootPlatform.Mac));
        Assert.Equal("Network settings", Troubleshooter.Label(TroubleshootAction.OpenNetworkSettings, TroubleshootPlatform.Windows));
        Assert.Equal("Network settings", Troubleshooter.Label(TroubleshootAction.OpenNetworkSettings, TroubleshootPlatform.Mac));
        Assert.Equal("Image Capture", Troubleshooter.Label(TroubleshootAction.OpenImageCapture, TroubleshootPlatform.Mac));
        Assert.Equal("Copy diagnostics", Troubleshooter.Label(TroubleshootAction.CopyDiagnostics, TroubleshootPlatform.Mac));
        Assert.Equal("Open Settings", Troubleshooter.Label(TroubleshootAction.OpenAppSettings, TroubleshootPlatform.Ios));
        Assert.Equal("Add by address…", Troubleshooter.Label(TroubleshootAction.AddByAddress, TroubleshootPlatform.Ios));
        Assert.Equal(["OK", "Tip", "Warning", "Problem"],
                     new[] { CheckStatus.Ok, CheckStatus.Tip, CheckStatus.Warning, CheckStatus.Problem }.Select(Troubleshooter.StatusLabel));
    }

    [Fact]
    public void Report_ListsEveryCheckWithItsDetail_AndItsMoreHelp()
    {
        var snapshot = HealthyWindows();
        var checks = Troubleshooter.Diagnose(snapshot);
        string report = Troubleshooter.Report(snapshot, checks);
        var lines = report.Split('\n');
        Assert.Equal("Why isn't my scanner listed?", lines[0]);
        Assert.Equal("1 scanner found. Nothing here stops scanners from appearing. The tips below cover the usual causes.", lines[1]);
        Assert.Equal("OK: Connected to a private network", lines[2]);
        Assert.Equal("  Network scanners on this network can be found.", lines[3]);
        Assert.Equal("Tip: Still not listed?", lines[^4]);
        Assert.Equal("  Wake the scanner and close other scanning apps.", lines[^3]);
        Assert.Equal("  Press a button on the scanner. Close Windows Scan or the maker's app. Some scanners work only with "
                     + "their maker's app.", lines[^2]);
        Assert.Equal("", lines[^1]);
        Assert.Equal(2 + 2 * checks.Count + checks.Count(c => c.More.Length > 0) + 1, lines.Length);
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
