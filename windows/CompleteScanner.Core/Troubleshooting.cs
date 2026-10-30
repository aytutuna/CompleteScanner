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
    /// <summary>
    /// The system suspended the app in the background before the scanner had finished (the pages
    /// received are kept). Only the iPhone and iPad produce it, through their eSCL connection; the
    /// Windows app never does, but knows its text.
    /// </summary>
    AppSuspended,
}

/// <summary>An error as the error bar shows it: what went wrong in a few words, and what to do.</summary>
public sealed record ProblemNotice(string Title, string Message);

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
        ScannerProblem.AppSuspended => "The system suspended Lazy Scan in the background before the scan finished. Keep the app open while scanning, then scan again.",
        _ => "The scanner reported a problem. Check the scanner, then try again.",
    };

    /// <summary>The title of an error that names no scanner problem.</summary>
    public const string GenericTitle = "Something went wrong";

    /// <summary>The problem in two or three words, for the title of the error bar: "Paper jam", "Scanner offline".</summary>
    public static string Title(ScannerProblem problem) => problem switch
    {
        ScannerProblem.FeederEmpty => "Feeder empty",
        ScannerProblem.PaperJam => "Paper jam",
        ScannerProblem.PaperProblem => "Paper problem",
        ScannerProblem.MultiFeed => "Several sheets fed",
        ScannerProblem.CoverOpen => "Cover open",
        ScannerProblem.Offline => "Scanner offline",
        ScannerProblem.Busy => "Scanner busy",
        ScannerProblem.WarmingUp => "Warming up",
        ScannerProblem.NeedsAttention => "Needs attention",
        ScannerProblem.CommunicationError => "Connection lost",
        ScannerProblem.AppSuspended => "App suspended",
        _ => GenericTitle,
    };

    /// <summary>
    /// What to do, in ten words at most, shown under <see cref="Title"/>; <see cref="Describe"/> is the
    /// sentence that stands on its own (error messages, the status line, the troubleshooter).
    /// </summary>
    public static string Advice(ScannerProblem problem) => problem switch
    {
        ScannerProblem.FeederEmpty => "Load paper in the feeder, then scan again.",
        ScannerProblem.PaperJam => "Clear the jam, then scan again.",
        ScannerProblem.PaperProblem => "Check the sheets in the feeder, then scan again.",
        ScannerProblem.MultiFeed => "Fan the stack, load it again, then scan again.",
        ScannerProblem.CoverOpen => "Close the cover, then scan again.",
        ScannerProblem.Offline => "Turn it on and check the cable or network.",
        ScannerProblem.Busy => "Wait until it has finished, then try again.",
        ScannerProblem.WarmingUp => "Try again in a moment.",
        ScannerProblem.NeedsAttention => "Check its display or control panel.",
        ScannerProblem.CommunicationError => "Check the cable or network, then try again.",
        ScannerProblem.AppSuspended => "Keep the app open while scanning, then scan again.",
        _ => "Check the scanner, then try again.",
    };

    /// <summary>The scanner problem an error message describes (its <see cref="Describe"/> text is in it); null when none is.</summary>
    public static ScannerProblem? Find(string? message)
    {
        if (string.IsNullOrEmpty(message)) return null;
        foreach (var problem in Enum.GetValues<ScannerProblem>())
        {
            if (message.Contains(Describe(problem), StringComparison.Ordinal)) return problem;
        }
        return null;
    }

    /// <summary>
    /// How the error bar shows <paramref name="message"/>: a title naming the problem ("Paper jam") and
    /// the message with the problem's sentence cut to what to do ("Clear the jam, then scan again.");
    /// "Something went wrong" and the message as it is when it names no problem.
    /// </summary>
    public static ProblemNotice Notice(string message)
    {
        if (Find(message) is not { } problem) return new ProblemNotice(GenericTitle, message.Trim());
        return new ProblemNotice(Title(problem), message.Replace(Describe(problem), Advice(problem), StringComparison.Ordinal).Trim());
    }

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
