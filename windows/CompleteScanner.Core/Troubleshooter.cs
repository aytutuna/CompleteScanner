using System.Text;

namespace CompleteScanner.Core;

// "Why isn't my scanner listed?": what the app knows about finding scanners, gathered into one
// snapshot and turned into plain-language checks, each with the actions that help. The apps only
// read the system's state and link to the system's settings; they never change a service or a
// setting. Mirrored by Sources/CompleteScannerKit/Core/Troubleshooter.swift (same checks, same
// text, same order).

/// <summary>Which app the snapshot comes from: the checks and their wording follow it.</summary>
public enum TroubleshootPlatform
{
    Windows,
    Mac,
}

/// <summary>The network the computer is on, as far as finding network scanners goes.</summary>
public enum NetworkStatus
{
    /// <summary>Not known (the Mac does not check).</summary>
    Unknown,
    /// <summary>Not connected to any network.</summary>
    Offline,
    /// <summary>Every connected network is public: Windows does not look for devices there.</summary>
    PublicNetwork,
    PrivateNetwork,
    DomainNetwork,
}

/// <summary>The state of a system service (on Windows, Windows Image Acquisition: stisvc).</summary>
public enum ServiceStatus
{
    /// <summary>Not known (not checked, or the system would not say).</summary>
    Unknown,
    Running,
    Starting,
    Stopping,
    Stopped,
    Paused,
    /// <summary>Stopped and set not to start.</summary>
    Disabled,
    NotInstalled,
}

/// <summary>Whether TWAIN can be used on this PC (Windows only).</summary>
public enum TwainStatus
{
    /// <summary>Not checked yet, or not a Windows snapshot.</summary>
    Unknown,
    Available,
    /// <summary>No TWAIN Data Source Manager (TWAINDSM.dll) is installed.</summary>
    NotInstalled,
    /// <summary>The Data Source Manager is installed but would not open.</summary>
    Failed,
}

/// <summary>
/// The automatic search for scanners: on Windows the DNS-SD search for network (eSCL)
/// scanners, on the Mac ImageCaptureCore's device browser (USB, network and shared scanners).
/// </summary>
public enum DiscoveryStatus
{
    /// <summary>Not known; no check is shown.</summary>
    Unknown,
    /// <summary>Not running.</summary>
    Off,
    /// <summary>Started; the first pass has not finished.</summary>
    Searching,
    Running,
    /// <summary>The system would not search.</summary>
    Unavailable,
}

/// <summary>How a check came out. The order is not the display order (see <see cref="Troubleshooter.Diagnose"/>).</summary>
public enum CheckStatus
{
    Ok,
    /// <summary>Advice that applies whatever the checks found.</summary>
    Tip,
    Warning,
    Problem,
}

/// <summary>Something the troubleshooter offers to do; the app carries it out.</summary>
public enum TroubleshootAction
{
    /// <summary>Look for scanners again.</summary>
    Refresh,
    /// <summary>The "Add scanner by address" dialog (Windows only).</summary>
    AddByAddress,
    /// <summary>Windows: Settings, Printers &amp; scanners (ms-settings:printers). Mac: System Settings, Printers &amp; Scanners.</summary>
    OpenScannerSettings,
    /// <summary>Windows: Settings, Network &amp; internet (ms-settings:network-status). Mac: System Settings, Network.</summary>
    OpenNetworkSettings,
    /// <summary>The Mac's Image Capture app, which shows every scanner macOS sees.</summary>
    OpenImageCapture,
    /// <summary>Copies the checks and the device diagnostics as text.</summary>
    CopyDiagnostics,
}

/// <summary>An address added by hand (Windows: escl-hosts.json) and whether a scanner answers there.</summary>
/// <param name="Address">As the user would write it, e.g. "192.168.1.50" or "https://scanner.local".</param>
/// <param name="Listed">A scanner answered and is listed.</param>
/// <param name="Problem">Why nothing is listed, in plain language; null when listed or not checked yet.</param>
public sealed record ManualHostStatus(string Address, bool Listed, string? Problem = null);

/// <summary>The last time connecting to a scanner, or scanning with it, failed.</summary>
/// <param name="DeviceName">The scanner's name as listed.</param>
/// <param name="Message">The error the user was shown.</param>
/// <param name="Problem">The condition at the scanner behind it, when the connection could tell.</param>
public sealed record ScannerFailure(string DeviceName, string Message, ScannerProblem? Problem = null);

/// <summary>
/// Everything the troubleshooter looks at, read at one moment. The app fills in the system's
/// state and the scanners listed; each connection that implements
/// <see cref="IScannerBackendDiagnostics"/> adds what it knows. Fields left at their defaults
/// (Unknown, empty) produce no check.
/// </summary>
public sealed record DiscoverySnapshot
{
    public TroubleshootPlatform Platform { get; init; }
    /// <summary>The scanners listed, one per row, the demo scanner included.</summary>
    public IReadOnlyList<ScannerInfo> Devices { get; init; } = [];
    public NetworkStatus Network { get; init; }
    /// <summary>Windows Image Acquisition (stisvc); Windows only.</summary>
    public ServiceStatus WiaService { get; init; }
    public TwainStatus Twain { get; init; }
    /// <summary>The TWAIN drivers (data sources) this 64-bit app can use.</summary>
    public int TwainDriverCount { get; init; }
    /// <summary>TWAIN driver files installed only for 32-bit apps (paths or file names).</summary>
    public IReadOnlyList<string> ThirtyTwoBitOnlyDrivers { get; init; } = [];
    /// <summary>
    /// Why the 32-bit TWAIN helper (Windows) does not reach <see cref="ThirtyTwoBitOnlyDrivers"/>,
    /// as sentences about the helper ("It …") with what to do; null when not known. Never set on the Mac.
    /// </summary>
    public string? ThirtyTwoBitHelperProblem { get; init; }
    public DiscoveryStatus Discovery { get; init; }
    /// <summary>Why the search is unavailable, as the system put it; null otherwise.</summary>
    public string? DiscoveryDetail { get; init; }
    /// <summary>Network scanners the automatic search found (Windows); unused on the Mac.</summary>
    public int DiscoveredCount { get; init; }
    public IReadOnlyList<ManualHostStatus> ManualHosts { get; init; } = [];
    public ScannerFailure? LastFailure { get; init; }

    /// <summary>The scanners listed other than the demo scanner.</summary>
    public int ListedScannerCount => Devices.Count(device => !device.IsDemo);
}

/// <summary>One line of the troubleshooter: what was checked, how it came out, what to do.</summary>
/// <param name="Id">Stable identifier ("network", "wiaService", "manualHost:192.168.1.50", ...).</param>
/// <param name="Status">How it came out.</param>
/// <param name="Title">Six words at most.</param>
/// <param name="Detail">What it means or what to do, in one line of fifteen words at most.</param>
/// <param name="Actions">Buttons offered with it, in order.</param>
/// <param name="More">The rest of the explanation, behind "More help"; empty when the detail says it all.</param>
public sealed record TroubleshootCheck(string Id, CheckStatus Status, string Title, string Detail,
                                       IReadOnlyList<TroubleshootAction> Actions, string More = "")
{
    public bool Equals(TroubleshootCheck? other) =>
        other is not null && Id == other.Id && Status == other.Status && Title == other.Title
        && Detail == other.Detail && More == other.More && Actions.SequenceEqual(other.Actions);

    public override int GetHashCode() => HashCode.Combine(Id, Status, Title, Detail, More, Actions.Count);

    /// <summary>The detail and the more help as one text, for screen readers and the copied diagnostics.</summary>
    public string FullDetail => More.Length == 0 ? Detail : $"{Detail} {More}";
}

/// <summary>
/// A connection that can tell the troubleshooter about itself. Optional, so
/// <see cref="IScannerBackend"/> does not change; called on the UI thread like the rest of it.
/// </summary>
public interface IScannerBackendDiagnostics
{
    /// <summary>The snapshot with what this connection knows filled in.</summary>
    DiscoverySnapshot AddStatus(DiscoverySnapshot snapshot);

    /// <summary>Look for scanners again now (the troubleshooter's Refresh). Never changes system settings.</summary>
    void Rescan();
}

public static class Troubleshooter
{
    /// <summary>
    /// The checks for <paramref name="snapshot"/>: problems first, then warnings, then what is
    /// fine, then the tips that always apply; within each, in this order: the last failure, the
    /// network, the WIA service, TWAIN, 32-bit TWAIN drivers, the automatic search, the addresses
    /// added by hand, then the tips.
    /// </summary>
    public static IReadOnlyList<TroubleshootCheck> Diagnose(DiscoverySnapshot snapshot)
    {
        bool windows = snapshot.Platform == TroubleshootPlatform.Windows;
        var checks = new List<TroubleshootCheck>();

        if (snapshot.LastFailure is { } failure) checks.Add(FailureCheck(failure, snapshot.Platform));
        if (NetworkCheck(snapshot) is { } network) checks.Add(network);
        if (windows && WiaServiceCheck(snapshot.WiaService) is { } wia) checks.Add(wia);
        if (windows && TwainCheck(snapshot) is { } twain) checks.Add(twain);
        if (windows && snapshot.ThirtyTwoBitOnlyDrivers.Count > 0)
        {
            checks.Add(ThirtyTwoBitCheck(snapshot.ThirtyTwoBitOnlyDrivers, snapshot.ThirtyTwoBitHelperProblem));
        }
        if (DiscoveryCheck(snapshot) is { } discovery) checks.Add(discovery);
        if (windows)
        {
            foreach (var host in snapshot.ManualHosts.Where(host => !host.Listed))
            {
                checks.Add(new TroubleshootCheck(
                    $"manualHost:{host.Address}", CheckStatus.Warning,
                    $"No scanner answers at {host.Address}",
                    "Check that it is on and its address hasn't changed.",
                    [TroubleshootAction.Refresh],
                    JoinSentences(host.Problem,
                                  "Its network settings page or control panel shows the current address. The app "
                                  + "tries the address again every minute.")));
            }
        }
        checks.AddRange(Tips(snapshot.Platform));

        // A stable sort: problems, warnings, what is fine, tips.
        return [.. checks.Select((check, index) => (check, index))
                         .OrderBy(pair => Rank(pair.check.Status))
                         .ThenBy(pair => pair.index)
                         .Select(pair => pair.check)];
    }

    /// <summary>"No scanner found", "1 scanner found", "3 scanners found" (the demo scanner does not count).</summary>
    public static string Headline(DiscoverySnapshot snapshot) => snapshot.ListedScannerCount switch
    {
        0 => "No scanner found",
        1 => "1 scanner found",
        int count => $"{count} scanners found",
    };

    /// <summary>"2 problems and 1 warning found.", or that nothing stops scanners from appearing.</summary>
    public static string Summary(IReadOnlyList<TroubleshootCheck> checks)
    {
        int problems = checks.Count(check => check.Status == CheckStatus.Problem);
        int warnings = checks.Count(check => check.Status == CheckStatus.Warning);
        if (problems == 0 && warnings == 0)
        {
            return "Nothing here stops scanners from appearing. The tips below cover the usual causes.";
        }
        var parts = new List<string>();
        if (problems > 0) parts.Add(problems == 1 ? "1 problem" : $"{problems} problems");
        if (warnings > 0) parts.Add(warnings == 1 ? "1 warning" : $"{warnings} warnings");
        return $"{string.Join(" and ", parts)} found.";
    }

    /// <summary>
    /// The troubleshooter's one-line headline: what is listed, then how many problems and warnings
    /// there are ("No scanner found · 2 problems, 1 warning"); just what is listed when there are none.
    /// </summary>
    public static string Overview(DiscoverySnapshot snapshot, IReadOnlyList<TroubleshootCheck> checks)
    {
        int problems = checks.Count(check => check.Status == CheckStatus.Problem);
        int warnings = checks.Count(check => check.Status == CheckStatus.Warning);
        var parts = new List<string>();
        if (problems > 0) parts.Add(problems == 1 ? "1 problem" : $"{problems} problems");
        if (warnings > 0) parts.Add(warnings == 1 ? "1 warning" : $"{warnings} warnings");
        string headline = Headline(snapshot);
        return parts.Count == 0 ? headline : $"{headline} · {string.Join(", ", parts)}";
    }

    /// <summary>The button text for an action.</summary>
    public static string Label(TroubleshootAction action, TroubleshootPlatform platform) => action switch
    {
        TroubleshootAction.Refresh => "Refresh",
        TroubleshootAction.AddByAddress => "Add by address…",
        TroubleshootAction.OpenScannerSettings => platform == TroubleshootPlatform.Windows
            ? "Scanner settings" : "Printers & Scanners",
        TroubleshootAction.OpenNetworkSettings => "Network settings",
        TroubleshootAction.OpenImageCapture => "Image Capture",
        TroubleshootAction.CopyDiagnostics => "Copy diagnostics",
        _ => action.ToString(),
    };

    /// <summary>The status as a word, for screen readers and the copied text: "OK", "Tip", "Warning", "Problem".</summary>
    public static string StatusLabel(CheckStatus status) => status switch
    {
        CheckStatus.Ok => "OK",
        CheckStatus.Tip => "Tip",
        CheckStatus.Warning => "Warning",
        CheckStatus.Problem => "Problem",
        _ => status.ToString(),
    };

    /// <summary>
    /// The checks as plain text, for the clipboard and the device diagnostics file:
    /// the heading, the headline and summary, then one "Status: title" line per check with
    /// its detail indented below, and its more help (when it has some) on the line after.
    /// </summary>
    public static string Report(DiscoverySnapshot snapshot, IReadOnlyList<TroubleshootCheck> checks)
    {
        var text = new StringBuilder();
        text.Append("Why isn't my scanner listed?\n");
        text.Append(Headline(snapshot)).Append(". ").Append(Summary(checks)).Append('\n');
        foreach (var check in checks)
        {
            text.Append(StatusLabel(check.Status)).Append(": ").Append(check.Title).Append('\n');
            text.Append("  ").Append(check.Detail).Append('\n');
            if (check.More.Length > 0) text.Append("  ").Append(check.More).Append('\n');
        }
        return text.ToString();
    }

    /// <summary>
    /// The network status of a computer connected to these networks: none is offline; a domain
    /// or private network among them is enough for network scanners to be found there.
    /// </summary>
    public static NetworkStatus CombineNetworks(IEnumerable<NetworkStatus> connected)
    {
        var all = connected.Where(status => status is not (NetworkStatus.Unknown or NetworkStatus.Offline)).ToList();
        if (all.Count == 0) return connected.Any(status => status == NetworkStatus.Unknown) ? NetworkStatus.Unknown : NetworkStatus.Offline;
        if (all.Contains(NetworkStatus.DomainNetwork)) return NetworkStatus.DomainNetwork;
        if (all.Contains(NetworkStatus.PrivateNetwork)) return NetworkStatus.PrivateNetwork;
        return NetworkStatus.PublicNetwork;
    }

    /// <summary>
    /// What a failed connection or scan tells the troubleshooter; null for errors that say
    /// nothing about reaching the scanner (cancelled, saving, unsupported settings).
    /// </summary>
    public static ScannerFailure? FailureFrom(string deviceName, Exception error) => error switch
    {
        ScanException { Kind: ScanErrorKind.Cancelled or ScanErrorKind.ExportFailed or ScanErrorKind.Unsupported } => null,
        OperationCanceledException => null,
        ScanException scan => new ScannerFailure(deviceName, scan.Message, scan.Problem),
        _ => new ScannerFailure(deviceName, error.Message),
    };

    // MARK: - The checks

    private static int Rank(CheckStatus status) => status switch
    {
        CheckStatus.Problem => 0,
        CheckStatus.Warning => 1,
        CheckStatus.Ok => 2,
        _ => 3,
    };

    private static string Computer(TroubleshootPlatform platform) =>
        platform == TroubleshootPlatform.Windows ? "PC" : "Mac";

    private static string OtherApps(TroubleshootPlatform platform) =>
        platform == TroubleshootPlatform.Windows
            ? "Windows Scan or the maker's app"
            : "Image Capture or the maker's app";

    private static TroubleshootCheck FailureCheck(ScannerFailure failure, TroubleshootPlatform platform)
    {
        string name = failure.DeviceName;
        return failure.Problem switch
        {
            ScannerProblem.Busy => new TroubleshootCheck(
                "lastFailure", CheckStatus.Problem, $"{name} is busy",
                "Close other apps using it, then choose it again.",
                [TroubleshootAction.Refresh],
                $"A scanner works with one app at a time; {OtherApps(platform)} may be using it. Wait until the "
                + "scanner has finished, then choose it again."),
            { } problem => new TroubleshootCheck(
                "lastFailure", CheckStatus.Problem, $"{ScannerProblems.Title(problem)}: {name}",
                ScannerProblems.Advice(problem), [TroubleshootAction.Refresh]),
            null => new TroubleshootCheck(
                "lastFailure", CheckStatus.Warning, $"Could not connect to {name}",
                "Check that it is on, awake and connected.",
                [TroubleshootAction.Refresh],
                JoinSentences(failure.Message,
                              "It must be connected by its cable or to the same network as this " + Computer(platform) + ".")),
        };
    }

    private static TroubleshootCheck? NetworkCheck(DiscoverySnapshot snapshot)
    {
        bool windows = snapshot.Platform == TroubleshootPlatform.Windows;
        return snapshot.Network switch
        {
            NetworkStatus.Offline => new TroubleshootCheck(
                "network", CheckStatus.Problem, "Not connected to a network",
                "Connect to the network the scanner is on, then select Refresh.",
                [TroubleshootAction.OpenNetworkSettings, TroubleshootAction.Refresh],
                $"This {Computer(snapshot.Platform)} is not on a network, so network scanners can't be found. "
                + "Scanners connected by USB are not affected."),
            NetworkStatus.PublicNetwork => new TroubleshootCheck(
                "network", CheckStatus.Warning, "Network set to Public",
                "Windows won't find network scanners on a Public network.",
                windows
                    ? [TroubleshootAction.OpenNetworkSettings, TroubleshootAction.AddByAddress]
                    : [TroubleshootAction.OpenNetworkSettings],
                "If this is your home or office network, set it to Private in network settings."
                + (windows ? " You can also add the scanner by its address." : "")),
            NetworkStatus.PrivateNetwork or NetworkStatus.DomainNetwork => new TroubleshootCheck(
                "network", CheckStatus.Ok, "Connected to a private network",
                "Network scanners on this network can be found.", []),
            _ => null,
        };
    }

    private static TroubleshootCheck? WiaServiceCheck(ServiceStatus status) => status switch
    {
        ServiceStatus.Running => new TroubleshootCheck(
            "wiaService", CheckStatus.Ok, "Scanner service is on",
            "Windows Image Acquisition (WIA), which most scanners use, is on.", []),
        ServiceStatus.Starting => new TroubleshootCheck(
            "wiaService", CheckStatus.Warning, "Scanner service is starting",
            "Wait a moment, then select Refresh.",
            [TroubleshootAction.Refresh],
            "Windows Image Acquisition (WIA), which most scanners use, is starting."),
        ServiceStatus.Stopped or ServiceStatus.Stopping or ServiceStatus.Paused => new TroubleshootCheck(
            "wiaService", CheckStatus.Warning, "Scanner service is not running",
            "Restarting the PC usually starts it again.",
            [TroubleshootAction.Refresh],
            "Windows Image Acquisition (WIA), which most scanners use, is not running, so those scanners can't "
            + "appear. To start it now, someone with administrator rights can start Windows Image Acquisition (WIA) "
            + "in Services."),
        ServiceStatus.Disabled => new TroubleshootCheck(
            "wiaService", CheckStatus.Problem, "Scanner service is turned off",
            "An administrator can set it to Automatic in Services.",
            [TroubleshootAction.Refresh],
            "Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners can't appear. "
            + "Someone with administrator rights can set its startup type to Automatic in Services, then restart the PC."),
        ServiceStatus.NotInstalled => new TroubleshootCheck(
            "wiaService", CheckStatus.Problem, "Scanner service is missing",
            "Scanners with a TWAIN driver and network scanners can still work.",
            [TroubleshootAction.AddByAddress],
            "This copy of Windows has no Windows Image Acquisition (WIA) service, which most scanners use."),
        _ => null,
    };

    private static TroubleshootCheck? TwainCheck(DiscoverySnapshot snapshot) => snapshot.Twain switch
    {
        TwainStatus.Available => new TroubleshootCheck(
            "twain", CheckStatus.Ok, "TWAIN is installed",
            snapshot.TwainDriverCount switch
            {
                0 => "No 64-bit TWAIN scanner driver is installed. Most scanners work without one.",
                1 => "1 TWAIN scanner driver is installed.",
                int count => $"{count} TWAIN scanner drivers are installed.",
            },
            []),
        TwainStatus.NotInstalled => new TroubleshootCheck(
            "twain", snapshot.ListedScannerCount == 0 ? CheckStatus.Warning : CheckStatus.Tip, "TWAIN is not installed",
            "Some scanners need their maker's 64-bit TWAIN driver.",
            [],
            "Some scanners, often document scanners, work only through their maker's TWAIN driver, which also "
            + "installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then restart CompleteScanner."),
        TwainStatus.Failed => new TroubleshootCheck(
            "twain", CheckStatus.Warning, "TWAIN did not start",
            "Restart CompleteScanner; if that fails, reinstall the maker's TWAIN driver.",
            [TroubleshootAction.Refresh],
            "TWAIN is installed but would not open, so scanners that use a TWAIN driver are not listed."),
        _ => null,
    };

    /// <summary>Drivers the 32-bit helper does not reach, with why when the app knows (<paramref name="helperProblem"/>).</summary>
    private static TroubleshootCheck ThirtyTwoBitCheck(IReadOnlyList<string> drivers, string? helperProblem)
    {
        var names = drivers.Select(path => $"\"{path[(path.LastIndexOfAny(['/', '\\']) + 1)..]}\"").ToList();
        bool one = names.Count == 1;
        bool known = !string.IsNullOrWhiteSpace(helperProblem);
        string reach = "CompleteScanner reaches such drivers through its 32-bit TWAIN helper"
                       + (known ? "." : $", which has not listed {(one ? "it" : "them")} yet.");
        return new TroubleshootCheck(
            "twain32", CheckStatus.Problem,
            one ? "A TWAIN driver is 32-bit only" : $"{names.Count} TWAIN drivers are 32-bit only",
            $"{string.Join(", ", names)} {(one ? "is" : "are")} installed only for 32-bit apps.",
            [],
            JoinSentences(known ? JoinSentences(reach, helperProblem!.Trim()) : reach,
                          "A 64-bit (x64) driver from the maker, where there is one, works without the helper. Many "
                          + "scanners also work through Windows Image Acquisition (WIA) once the maker's full driver "
                          + "package is installed."));
    }

    private static TroubleshootCheck? DiscoveryCheck(DiscoverySnapshot snapshot)
    {
        string detail = string.IsNullOrWhiteSpace(snapshot.DiscoveryDetail) ? "" : $" ({snapshot.DiscoveryDetail.Trim().TrimEnd('.')})";
        if (snapshot.Platform == TroubleshootPlatform.Mac)
        {
            return snapshot.Discovery switch
            {
                DiscoveryStatus.Searching or DiscoveryStatus.Running => new TroubleshootCheck(
                    "discovery", CheckStatus.Ok, "Looking for scanners",
                    "Scanners appear here as macOS finds them.",
                    [],
                    "macOS looks for scanners connected by USB, on the network and shared by other Macs."),
                DiscoveryStatus.Off or DiscoveryStatus.Unavailable => new TroubleshootCheck(
                    "discovery", CheckStatus.Warning, "Not looking for scanners",
                    "Select Refresh to start the search again.",
                    [TroubleshootAction.Refresh],
                    $"The search for scanners is not running{detail}."),
                _ => null,
            };
        }
        return snapshot.Discovery switch
        {
            DiscoveryStatus.Searching => new TroubleshootCheck(
                "discovery", CheckStatus.Ok, "Looking for network scanners",
                "Scanners on the network appear as they answer.",
                [TroubleshootAction.AddByAddress],
                "The search has just started."),
            DiscoveryStatus.Running => new TroubleshootCheck(
                "discovery", CheckStatus.Ok, "Looking for network scanners",
                snapshot.DiscoveredCount switch
                {
                    0 => "No network scanner has been found on this network yet.",
                    1 => "1 network scanner found.",
                    int count => $"{count} network scanners found.",
                },
                [TroubleshootAction.AddByAddress],
                "A scanner that doesn't appear can be added by its address."),
            DiscoveryStatus.Unavailable => new TroubleshootCheck(
                "discovery", CheckStatus.Warning, "Network search is not working",
                "You can still add a network scanner by its address.",
                [TroubleshootAction.AddByAddress, TroubleshootAction.Refresh],
                $"Windows could not search the network for scanners{detail}."),
            _ => null,
        };
    }

    private static IEnumerable<TroubleshootCheck> Tips(TroubleshootPlatform platform)
    {
        if (platform == TroubleshootPlatform.Windows)
        {
            yield return new TroubleshootCheck(
                "usb", CheckStatus.Tip, "Connected by USB?",
                "Connect it directly (no hub) and install the maker's driver.",
                [TroubleshootAction.OpenScannerSettings, TroubleshootAction.Refresh],
                "Windows lists a USB scanner only after its driver is installed. Get it from the maker's website, "
                + "then select Refresh. Scanner settings show whether Windows sees it.");
        }
        else
        {
            yield return new TroubleshootCheck(
                "usb", CheckStatus.Tip, "Connected by USB?",
                "Connect it directly (no hub) and install the maker's macOS driver.",
                [TroubleshootAction.OpenImageCapture, TroubleshootAction.Refresh],
                "macOS lists a USB scanner only when it can scan without a driver or its maker's driver is "
                + "installed. If Image Capture doesn't show it either, macOS doesn't see it.");
            yield return new TroubleshootCheck(
                "networkScanner", CheckStatus.Tip, "Scanner on the network?",
                "The Mac and the scanner must be on the same network.",
                [TroubleshootAction.OpenScannerSettings],
                "If macOS asked whether CompleteScanner may find devices on your local network, allow it in System "
                + "Settings, Privacy & Security, Local Network. A network printer with a scanner added in Printers & "
                + "Scanners also appears here.");
            yield return new TroubleshootCheck(
                "sharing", CheckStatus.Tip, "Shared by another Mac?",
                "Turn on Scanner Sharing in that Mac's Sharing settings.",
                [],
                "It's in System Settings, General, Sharing. Both Macs must be on the same network.");
        }
        yield return new TroubleshootCheck(
            "otherApps", CheckStatus.Tip, "Still not listed?",
            "Wake the scanner and close other scanning apps.",
            [TroubleshootAction.Refresh],
            $"Press a button on the scanner. Close {OtherApps(platform)}. Some scanners work only with their maker's app.");
    }

    /// <summary>The first text as a sentence, then the second; the first may be missing.</summary>
    private static string JoinSentences(string? first, string second)
    {
        string head = first?.Trim() ?? "";
        if (head.Length == 0) return second;
        if (!".!?".Contains(head[^1])) head += ".";
        return $"{head} {second}";
    }
}
