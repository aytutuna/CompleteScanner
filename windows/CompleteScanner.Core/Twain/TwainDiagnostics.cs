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

/// <summary>
/// The TWAIN part of the device diagnostics (devices.txt): whether TWAIN works, which data
/// sources it lists, and which drivers are installed only in 32-bit form, which this 64-bit
/// app cannot load. Windows only (see TwainCodes.cs).
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
            text.Append($"  32-bit only (cannot be used by this 64-bit app) \"{file}\"\n");
        }
        return text.ToString();
    }

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
