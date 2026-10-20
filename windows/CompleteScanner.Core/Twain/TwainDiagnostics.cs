using System.Text;

namespace CompleteScanner.Core;

/// <summary>Whether the app can use TWAIN on this PC.</summary>
public enum TwainAvailability
{
    /// <summary>Not checked yet.</summary>
    Unknown,
    Available,
    /// <summary>No TWAIN Data Source Manager (TWAINDSM.dll) is installed.</summary>
    NoDataSourceManager,
    /// <summary>The Data Source Manager is installed but would not open.</summary>
    Failed,
}

/// <summary>Whether the 32-bit TWAIN helper (for drivers installed only for 32-bit programs) works on this PC.</summary>
public enum TwainHelperStatus
{
    /// <summary>Not checked yet.</summary>
    Unknown,
    /// <summary>No driver is installed only for 32-bit programs, so the helper was not started.</summary>
    NotNeeded,
    /// <summary>The helper started and its Data Source Manager opened (it may still list no driver the app can use).</summary>
    Available,
    /// <summary>The helper runs, but no 32-bit Data Source Manager (TWAINDSM.dll or twain_32.dll) is installed.</summary>
    NoDataSourceManager,
    /// <summary>The helper would not start, or its Data Source Manager would not open.</summary>
    Failed,
}

/// <summary>
/// The TWAIN part of the device diagnostics (devices.txt): whether TWAIN works, which data
/// sources it lists, which drivers are installed only in 32-bit form (this 64-bit app reaches
/// those through its 32-bit helper), and how the helper is doing. Windows only (see TwainCodes.cs).
/// </summary>
public static class TwainDiagnostics
{
    /// <summary>What the app tells the user when TWAIN is missing.</summary>
    public const string NoDataSourceManagerMessage =
        "TWAIN is not available: the TWAIN Data Source Manager (TWAINDSM.dll) is not installed. "
        + "Scanner drivers that use TWAIN install it, so install your scanner's TWAIN driver to use it here.";

    /// <summary>
    /// The data source files (*.ds, paths relative to the twain_32 folder) that have no 64-bit
    /// counterpart in twain_64, matched by file name with any "32"/"64" suffix removed. The
    /// Windows WIA bridge (wiatwain.ds) is left out: WIA reaches those scanners directly.
    /// </summary>
    public static List<string> ThirtyTwoBitOnlySources(IEnumerable<string> twain32Files, IEnumerable<string> twain64Files)
    {
        var present64 = twain64Files.Select(Key).ToHashSet(StringComparer.Ordinal);
        return twain32Files
            .Where(path => path.EndsWith(".ds", StringComparison.OrdinalIgnoreCase))
            .Where(path => !string.Equals(FileName(path), "wiatwain.ds", StringComparison.OrdinalIgnoreCase))
            .Where(path => !present64.Contains(Key(path)))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>The TWAIN section of the diagnostics file.</summary>
    public static string Report(TwainAvailability availability, IReadOnlyList<string> sources,
                                IReadOnlyList<string> thirtyTwoBitOnly)
    {
        var text = new StringBuilder();
        text.Append("TWAIN: ").Append(availability switch
        {
            TwainAvailability.Available => "available",
            TwainAvailability.NoDataSourceManager => "not installed (no TWAINDSM.dll)",
            TwainAvailability.Failed => "the Data Source Manager would not open",
            _ => "not checked",
        }).Append('\n');
        foreach (string source in sources) text.Append($"  source \"{source}\"\n");
        foreach (string file in thirtyTwoBitOnly)
        {
            text.Append($"  32-bit only (needs the 32-bit helper) \"{file}\"\n");
        }
        return text.ToString();
    }

    /// <summary>
    /// The 32-bit helper's section of the diagnostics file: how it is doing (with
    /// <paramref name="detail"/>, why it failed: the process, or its Data Source Manager), then
    /// every source its Data Source Manager lists, those not in <paramref name="listed"/> marked
    /// as left out (the WIA bridge, or a driver the 64-bit Data Source Manager has too). A helper
    /// whose Data Source Manager lists only the WIA bridge is stopped again, so it is not said to run.
    /// </summary>
    public static string HelperReport(TwainHelperStatus status, string? detail, IReadOnlyList<string> sources,
                                      IReadOnlyCollection<string> listed)
    {
        bool reached = TwainHelperSources.Usable(sources.Select(name => new TwainHelperSource(name)), []).Count > 0;
        var text = new StringBuilder();
        text.Append("TWAIN 32-bit helper: ").Append(status switch
        {
            TwainHelperStatus.NotNeeded => "not needed (no 32-bit-only drivers)",
            TwainHelperStatus.Available when reached => "works",
            TwainHelperStatus.Available => "reached no usable driver",
            TwainHelperStatus.NoDataSourceManager => "no 32-bit TWAIN Data Source Manager",
            TwainHelperStatus.Failed => "failed",
            _ => "not checked",
        });
        if (!string.IsNullOrWhiteSpace(detail)) text.Append(" (").Append(detail.Trim()).Append(')');
        text.Append('\n');
        foreach (string source in sources)
        {
            text.Append(listed.Contains(source)
                ? $"  source \"{source}\"\n"
                : $"  left out (WIA bridge, or also a 64-bit driver) \"{source}\"\n");
        }
        return text.ToString();
    }

    /// <summary>
    /// Why the 32-bit helper does not reach the drivers installed only for 32-bit programs, for
    /// the troubleshooter (<see cref="DiscoverySnapshot.ThirtyTwoBitHelperProblem"/>): sentences
    /// about the helper ("It …") with what to do. <paramref name="cannotRun"/> is why the helper
    /// cannot run at all (no 32-bit .NET runtime, the helper missing, Windows refusing to start
    /// it), as <c>TwainHelperProcess</c> words it. Null while it has not been tried, when it is not
    /// needed, and when <paramref name="reachedAny"/> (it lists a driver it can use).
    /// </summary>
    public static string? HelperProblem(TwainHelperStatus status, string? cannotRun, bool reachedAny) => status switch
    {
        TwainHelperStatus.Available when reachedAny => null,
        TwainHelperStatus.Available =>
            "It started, but its TWAIN Data Source Manager lists no driver it can use, which happens when a driver "
            + "did not install completely. Reinstall the scanner maker's driver, then restart CompleteScanner.",
        TwainHelperStatus.NoDataSourceManager =>
            "It found no 32-bit TWAIN Data Source Manager (TWAINDSM.dll or twain_32.dll) to load the driver with. "
            + "Reinstall the scanner maker's driver, then restart CompleteScanner.",
        TwainHelperStatus.Failed when !string.IsNullOrWhiteSpace(cannotRun) => $"It cannot run: {cannotRun.Trim()}",
        TwainHelperStatus.Failed =>
            "It did not work this time, and CompleteScanner tries again on its own. If the scanner still does not "
            + "appear, restart CompleteScanner.",
        _ => null,
    };

    /// <summary>The last path segment, whichever separator the path uses (so the result does not depend on the OS).</summary>
    private static string FileName(string path) => path[(path.LastIndexOfAny(['/', '\\']) + 1)..];

    private static string Key(string path)
    {
        string name = FileName(path);
        int dot = name.LastIndexOf('.');
        if (dot > 0) name = name[..dot];
        name = name.ToLowerInvariant();
        foreach (string suffix in new[] { "_x64", "-x64", "x64", "_64", "-64", "64", "_32", "-32", "32" })
        {
            if (name.Length > suffix.Length && name.EndsWith(suffix, StringComparison.Ordinal))
            {
                name = name[..^suffix.Length];
                break;
            }
        }
        return name;
    }
}
