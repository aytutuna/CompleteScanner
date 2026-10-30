using System.Diagnostics;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/Orientation.swift.

/// <summary>
/// How much text recognition read on a page held one way up. Text read the right way up comes out
/// as words; upside down or sideways it comes out as few letters, or as letters that do not make
/// words ("suo!umqxa", "RTtnJqoed").
/// </summary>
/// <param name="Letters">Letters and digits read, in every word.</param>
/// <param name="WordLetters">Letters and digits in the words that look like words (<see cref="WordScore"/>).</param>
public sealed record OrientationScore(int Letters, int WordLetters)
{
    /// <summary>Nothing read.</summary>
    public static OrientationScore None { get; } = new(0, 0);

    /// <summary>The score of the lines text recognition read (words are split at white space).</summary>
    public static OrientationScore Of(IEnumerable<string> lines)
    {
        int letters = 0, wordLetters = 0;
        foreach (string line in lines)
        {
            foreach (string word in line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                letters += word.Count(char.IsLetterOrDigit);
                wordLetters += WordScore(word);
            }
        }
        return new OrientationScore(letters, wordLetters);
    }

    /// <summary>
    /// The letters of <paramref name="word"/> when it looks like a word, else 0. Punctuation around
    /// it is left out; then it must be at least 2 long and be a number, or letters only (parts joined
    /// by hyphens or apostrophes) written in one case: lower case, capitals, a capital and then lower
    /// case, or a script without case. "Lieutenant," 10, "1903." 4, "Jean-Pierre" 10, "a.10Jaq" 0,
    /// "RTtnJqoed" 0, "o" 0.
    /// </summary>
    public static int WordScore(string word)
    {
        int start = 0, end = word.Length;
        while (start < end && !char.IsLetterOrDigit(word[start])) start++;
        while (end > start && !char.IsLetterOrDigit(word[end - 1])) end--;
        string core = word[start..end];
        if (core.Length < 2) return 0;
        if (core.All(char.IsDigit)) return core.Length;
        int letters = 0;
        foreach (string part in core.Split(WordJoiners))
        {
            if (part.Length == 0 || !part.All(char.IsLetter)) return 0;
            int upper = part.Count(char.IsUpper), lower = part.Count(char.IsLower);
            bool oneCase = upper == 0 || lower == 0 || (upper == 1 && char.IsUpper(part[0]));
            if (!oneCase) return 0;
            letters += part.Length;
        }
        return letters;
    }

    /// <summary>
    /// The text reads well enough to be taken without trying the page another way up: at least
    /// <see cref="OrientationDecision.ClearWordLetters"/> letters in words, and words make up at least
    /// <see cref="OrientationDecision.ClearShare"/> of what was read.
    /// </summary>
    public bool ReadsClearly =>
        WordLetters >= OrientationDecision.ClearWordLetters && WordLetters >= OrientationDecision.ClearShare * Letters;

    private static readonly char[] WordJoiners = ['-', '\'', '’'];
}

/// <summary>
/// Reads text on a page image for <see cref="OrientationDecision"/>. The platform supplies it:
/// Windows OCR (the primary recognizer language) on Windows, Vision on the Mac.
/// </summary>
public interface IOrientationScorer
{
    /// <summary>Whether text can be read at all (on Windows: a recognizer language is installed).</summary>
    bool IsAvailable { get; }

    /// <summary>
    /// What text recognition reads on <paramref name="image"/> as it is (the caller turns it). Throws
    /// when recognition fails; <paramref name="token"/> may stop it.
    /// </summary>
    OrientationScore Score(RgbaImage image, CancellationToken token);
}

/// <summary>What <see cref="OrientationDecision.Check"/> found.</summary>
public enum OrientationVerdict
{
    /// <summary>The page reads best as it is.</summary>
    Upright,
    /// <summary>The page reads clearly better turned: <see cref="OrientationCheck.QuarterTurns"/>.</summary>
    Turned,
    /// <summary>No way up reads clearly better than the others (or text recognition failed): left as it is.</summary>
    Unsure,
    /// <summary>Too little on the page to read: not read at all.</summary>
    NoText,
    /// <summary>Reading took longer than the time a page may take: left as it is.</summary>
    OutOfTime,
}

/// <summary>The score of the page turned <paramref name="QuarterTurns"/> quarter turns clockwise.</summary>
public sealed record CandidateScore(int QuarterTurns, OrientationScore Score);

/// <summary>
/// What reading a page found: the verdict, the quarter turns clockwise that make the page upright
/// (0 unless <see cref="OrientationVerdict.Turned"/>), every way up that was read with its score, in
/// the order read, the page's lines of text, and how long it took.
/// </summary>
public sealed record OrientationCheck(OrientationVerdict Verdict, int QuarterTurns, IReadOnlyList<CandidateScore> Scores,
                                      TextLayout Layout, double Seconds)
{
    /// <summary>How many times text recognition ran.</summary>
    public int Passes => Scores.Count;
}

/// <summary>
/// Rotate pages upright: which way up a page reads, by text recognition. The lines of text on the
/// page (<see cref="DocumentGeometry.EstimateTextLayout"/>) say which ways up are worth reading:
/// across the page, as it is or upside down; down the page, a quarter turn either way; not clear,
/// all four. Each is read once on a copy at most <see cref="AnalysisMaxSide"/> pixels long, the
/// likeliest first; one that reads clearly (<see cref="OrientationScore.ReadsClearly"/>) is taken at
/// once when it is the page as it is, or when the page was already read the opposite way up (turned
/// 180° from it) and it has <see cref="Margin"/> times the letters in words of every way up read
/// before it. Otherwise every way up worth reading is read, and the one with the most letters in
/// words wins when it has at least <see cref="MinWordLetters"/> and <see cref="Margin"/> times as many
/// as any other. A page that is blank, not clear, or takes longer than <see cref="MaxSecondsPerPage"/>
/// is left as it is.
/// </summary>
public static class OrientationDecision
{
    /// <summary>The longest side of the copy that is read, in pixels.</summary>
    public const int AnalysisMaxSide = 1600;
    /// <summary>The fewest letters in words that can turn a page.</summary>
    public const int MinWordLetters = 20;
    /// <summary>How many times the letters in words of any other way up the winner needs.</summary>
    public const double Margin = 2.0;
    /// <summary>Letters in words that read clearly enough to stop reading (<see cref="OrientationScore.ReadsClearly"/>).</summary>
    public const int ClearWordLetters = 150;
    /// <summary>The share of what was read that must be words to stop reading.</summary>
    public const double ClearShare = 0.85;
    /// <summary>The time one page may take; no new reading starts after it.</summary>
    public const double MaxSecondsPerPage = 3.0;

    /// <summary>
    /// The quarter turns clockwise worth reading, likeliest first: 0 and 2 for lines across the
    /// page, 1 and 3 for lines down it, all four (0, 2, 1, 3) when that is not clear, none when the
    /// page has too little ink to hold text (<see cref="DocumentGeometry.MinInkPoints"/>).
    /// </summary>
    public static IReadOnlyList<int> Candidates(TextLayout layout)
    {
        if (layout.InkPoints < DocumentGeometry.MinInkPoints) return [];
        bool sure = layout.Confidence >= DocumentGeometry.MinConfidence;
        return (sure ? layout.Axis : TextAxis.Unknown) switch
        {
            TextAxis.Horizontal => [0, 2],
            TextAxis.Vertical => [1, 3],
            _ => [0, 2, 1, 3],
        };
    }

    /// <summary>
    /// The quarter turns of the way up that reads best, when it has at least
    /// <see cref="MinWordLetters"/> letters in words and <see cref="Margin"/> times as many as every
    /// other way up read; null when none does (nothing read, or too close to call).
    /// </summary>
    public static int? Choose(IReadOnlyList<CandidateScore> scored)
    {
        if (scored.Count == 0) return null;
        var best = scored[0];
        foreach (var candidate in scored)
        {
            if (candidate.Score.WordLetters > best.Score.WordLetters) best = candidate;
        }
        int runnerUp = 0;
        foreach (var candidate in scored)
        {
            if (!ReferenceEquals(candidate, best)) runnerUp = Math.Max(runnerUp, candidate.Score.WordLetters);
        }
        int top = best.Score.WordLetters;
        return top >= MinWordLetters && top >= Margin * runnerUp ? best.QuarterTurns : null;
    }

    /// <summary>The size of the copy that is read: the image's own when no side is longer than <see cref="AnalysisMaxSide"/>.</summary>
    public static (int Width, int Height) AnalysisSize(int width, int height)
    {
        int longest = Math.Max(width, height);
        if (longest <= AnalysisMaxSide) return (width, height);
        double scale = (double)AnalysisMaxSide / longest;
        return (Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    }

    /// <summary>The copy of <paramref name="image"/> that is read (<see cref="AnalysisSize"/>).</summary>
    public static RgbaImage AnalysisImage(RgbaImage image)
    {
        var (width, height) = AnalysisSize(image.Width, image.Height);
        return image.Resized(width, height);
    }

    /// <summary>
    /// Which way up <paramref name="image"/> (scanned at <paramref name="dpi"/>) reads (see the class
    /// summary). <paramref name="token"/> is checked before every reading and passed to the scorer;
    /// <paramref name="clock"/> (seconds; a monotonic clock by default) times the page.
    /// </summary>
    public static OrientationCheck Check(RgbaImage image, int dpi, IOrientationScorer scorer,
                                         CancellationToken token = default, double maxSeconds = MaxSecondsPerPage,
                                         Func<double>? clock = null)
    {
        clock ??= MonotonicSeconds;
        double start = clock();
        token.ThrowIfCancellationRequested();
        var layout = DocumentGeometry.EstimateTextLayout(GrayImage.From(image, dpi));
        var candidates = Candidates(layout);
        var scores = new List<CandidateScore>();
        OrientationCheck Done(OrientationVerdict verdict, int turns = 0) =>
            new(verdict, turns, scores, layout, clock() - start);
        if (candidates.Count == 0) return Done(OrientationVerdict.NoText);
        var analysis = AnalysisImage(image);
        foreach (int turns in candidates)
        {
            token.ThrowIfCancellationRequested();
            if (clock() - start > maxSeconds) return Done(OrientationVerdict.OutOfTime);
            OrientationScore score;
            try
            {
                score = scorer.Score(analysis.RotatedQuarterTurns(turns), token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception)
            {
                // Recognition failed: nothing can be said about this page.
                return Done(OrientationVerdict.Unsure);
            }
            int earlier = scores.Count == 0 ? 0 : scores.Max(s => s.Score.WordLetters);
            bool oppositeRead = scores.Any(s => s.QuarterTurns == (turns + 2) % 4);
            scores.Add(new CandidateScore(turns, score));
            if (score.ReadsClearly && (turns == 0 || (oppositeRead && score.WordLetters >= Margin * earlier)))
            {
                return turns == 0 ? Done(OrientationVerdict.Upright) : Done(OrientationVerdict.Turned, turns);
            }
        }
        return Choose(scores) switch
        {
            null => Done(OrientationVerdict.Unsure),
            0 => Done(OrientationVerdict.Upright),
            int turns => Done(OrientationVerdict.Turned, turns),
        };
    }

    private static double MonotonicSeconds() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
}

/// <summary>
/// What turning pages upright did to a page (<see cref="ScannedPage.Upright"/>; not persisted): the
/// quarter turns clockwise it was turned (1 to 3), and whether the user turned it back.
/// </summary>
public sealed record UprightTurn(int QuarterTurns, bool Undone = false);

/// <summary>
/// What the page strip, the status and the inspector say about turning pages upright: a caption on a
/// turned page, its one-click undo, the note after a scan and the switch's hint.
/// </summary>
public static class PageTurns
{
    /// <summary>
    /// "Turned upright 180°", "Turned upright 90° clockwise" or "Turned upright 90° counterclockwise"
    /// for a turned page; "Turned back as scanned" once the user undid it; null for other pages.
    /// </summary>
    public static string? Caption(ScannedPage page) => page.Upright switch
    {
        null => null,
        { Undone: true } => "Turned back as scanned",
        { QuarterTurns: 1 } => "Turned upright 90° clockwise",
        { QuarterTurns: 3 } => "Turned upright 90° counterclockwise",
        _ => "Turned upright 180°",
    };

    /// <summary>What one click on the page's turn button does: "Undo turn" or "Turn upright again"; null for a page not turned.</summary>
    public static string? ToggleLabel(ScannedPage page) => page.Upright switch
    {
        null => null,
        { Undone: true } => "Turn upright again",
        _ => "Undo turn",
    };

    /// <summary>
    /// The status after the turn of a page was undone or made again: "Page 3 is turned back as
    /// scanned. It is saved that way." or "Page 3 is turned upright again."
    /// </summary>
    public static string ToggleNote(ScannedPage page, int number) =>
        page.Upright is { Undone: false }
            ? $"Page {number} is turned upright again."
            : $"Page {number} is turned back as scanned. It is saved that way.";

    /// <summary>
    /// The status after a scan's pages were queued, when some were turned: " 2 turned upright."
    /// (leading space; empty when none was).
    /// </summary>
    public static string ScanNote(IEnumerable<ScannedPage> added)
    {
        int turned = added.Count(p => p.Upright is { Undone: false });
        return turned == 0 ? "" : $" {turned} turned upright.";
    }

    /// <summary>The status note when pages were to be turned upright but no text can be read (leading space).</summary>
    public const string UnavailableNote =
        " Pages were not turned upright: no text recognition language is installed.";

    /// <summary>
    /// The tooltip of "Rotate pages upright": why it is off for copies, receipts and scans saved at
    /// once, that it needs text recognition (shown next to it), else what it does.
    /// </summary>
    public static string Hint(ScanSettings settings, bool available)
    {
        var flow = TaskCatalog.FlowOf(settings);
        if (flow == TaskFlowKind.Copy) return "Copies print every page as scanned: pages are not turned.";
        if (flow == TaskFlowKind.ReceiptSplit) return "Receipts are kept the way they lie on the glass.";
        if (!settings.DocumentMultiPage) return "Only for pages collected before saving: a scan saved at once is kept as scanned.";
        if (!available) return "Needs a text recognition language, and none is installed.";
        return "Turns sideways or upside-down pages by reading the text";
    }
}
