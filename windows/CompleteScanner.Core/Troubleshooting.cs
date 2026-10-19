namespace CompleteScanner.Core;

// Scanner problems every backend reports the same way (WIA HRESULTs, eSCL scanner status,
// the demo scanner), so the user sees one wording whatever the connection. Mirrored by
// Sources/CompleteScannerKit/Core/Troubleshooting.swift.

/// <summary>
/// A condition at the scanner that stops a scan and that the user can usually fix. The first
/// member is the safe default; add new members after the existing ones.
/// </summary>
public enum ScannerProblem
{
    /// <summary>The scanner reported a problem this version does not recognize.</summary>
    Unknown,
    FeederEmpty,
    PaperJam,
    /// <summary>A misfeed or a sheet the feeder could not handle (too short, too long, ...).</summary>
    PaperProblem,
    /// <summary>Several sheets were pulled in at once.</summary>
    MultiFeed,
    CoverOpen,
    Offline,
    Busy,
    WarmingUp,
    /// <summary>The scanner wants someone at its panel (lamp off, a message on its display, ...).</summary>
    NeedsAttention,
    CommunicationError,
}

public static class ScannerProblems
{
    /// <summary>User-facing text: what happened and what to do about it.</summary>
    public static string Describe(ScannerProblem problem) => problem switch
    {
        ScannerProblem.FeederEmpty => "Load paper in the feeder, then scan again.",
        ScannerProblem.PaperJam => "Paper is jammed in the scanner. Clear the jam, then scan again.",
        ScannerProblem.PaperProblem => "The scanner could not feed the paper. Check the sheets in the feeder, then scan again.",
        ScannerProblem.MultiFeed => "The scanner pulled in several sheets at once. Fan the stack, load it again, then scan again.",
        ScannerProblem.CoverOpen => "The scanner's cover is open. Close it, then scan again.",
        ScannerProblem.Offline => "The scanner is offline. Check that it is turned on and connected.",
        ScannerProblem.Busy => "The scanner is busy. Wait until it has finished, then try again.",
        ScannerProblem.WarmingUp => "The scanner is warming up. Try again in a moment.",
        ScannerProblem.NeedsAttention => "The scanner needs attention. Check its display or control panel.",
        ScannerProblem.CommunicationError => "The connection to the scanner was interrupted. Check the cable or network, then try again.",
        _ => "The scanner reported a problem. Check the scanner, then try again.",
    };

    /// <summary>
    /// How a problem is classified as a <see cref="ScanException"/>: an offline scanner is
    /// unavailable; everything else is a failed scan.
    /// </summary>
    public static ScanErrorKind Kind(ScannerProblem problem) =>
        problem == ScannerProblem.Offline ? ScanErrorKind.DeviceUnavailable : ScanErrorKind.ScanFailed;
}

/// <summary>
/// Why a feeder batch ended before the feeder ran out (a jam, a dropped connection, ...). The
/// scan still returns the pages that transferred; the session keeps this in
/// <see cref="IScannerSession.LastScanStop"/> so the app can tell the user the stack was not
/// finished.
/// </summary>
/// <param name="Reason">User-facing text of the failure that stopped the batch.</param>
/// <param name="Problem">The scanner condition behind it, when the backend could tell.</param>
public sealed record ScanStop(string Reason, ScannerProblem? Problem = null)
{
    public static ScanStop From(ScanException error) => new(error.Message, error.Problem);

    /// <summary>User-facing text: how many pages were kept, then why scanning stopped.</summary>
    public string Message(int pagesKept)
    {
        string kept = pagesKept == 1
            ? "Scanning stopped after 1 page; it was kept."
            : $"Scanning stopped after {pagesKept} pages; they were kept.";
        return string.IsNullOrWhiteSpace(Reason) ? kept : $"{kept} {Reason.Trim()}";
    }
}
