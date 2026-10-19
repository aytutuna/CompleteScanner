namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/PageProcessor.swift.

/// <summary>
/// One step of the work done on every scanned page before it is queued or saved. A step gets
/// the page as the earlier steps left it and returns it changed (other pixels through
/// <see cref="ScannedPage.WithImage"/>) or with new facts (<see cref="ScannedPage.WithBlank"/>).
/// Steps run off the UI thread, one page at a time.
/// </summary>
public interface IPageStep
{
    /// <summary>A stable name ("blank", "adjust"), for tests and diagnostics.</summary>
    string Name { get; }

    ScannedPage Apply(ScannedPage page);
}

/// <summary>
/// Checks whether the page is blank (<see cref="BlankPageDetector"/>) and records the result on
/// it; the pixels are not changed. Runs before any adjustment, on the page as scanned.
/// </summary>
public sealed class BlankDetectionStep(BlankPageOptions options) : IPageStep
{
    public BlankPageOptions Options { get; } = options;
    public string Name => "blank";

    public ScannedPage Apply(ScannedPage page) =>
        page.WithBlank(BlankPageDetector.Analyze(page.Image, page.Dpi, Options));
}

/// <summary>The image adjustments and the color mode (<see cref="ImagePipeline.Apply"/>).</summary>
public sealed class AdjustmentStep(AdjustmentSettings adjustments, ColorMode colorMode) : IPageStep
{
    public AdjustmentSettings Adjustments { get; } = adjustments;
    public ColorMode ColorMode { get; } = colorMode;
    public string Name => "adjust";

    public ScannedPage Apply(ScannedPage page) =>
        page.WithImage(ImagePipeline.Apply(Adjustments, page.Image, ColorMode), ColorMode);
}

/// <summary>How the pages of one scan come out of the scanner.</summary>
public enum ScanArrangement
{
    /// <summary>One page per sheet, in the order scanned.</summary>
    AsScanned,
    /// <summary>A two-sided feeder scan: front, back, front, back… (<see cref="DocumentSides.ArrangeTwoSided"/>).</summary>
    TwoSided,
    /// <summary>The fronts of a stack turned over by hand (<see cref="DocumentSides.MarkManual"/>).</summary>
    TurnedOverFronts,
    /// <summary>The backs of a stack turned over by hand, last sheet first.</summary>
    TurnedOverBacks,
}

/// <summary>The pages of one scan after processing.</summary>
/// <param name="Arranged">The pages in reading order with their sides marked and the backs turned upright, otherwise as scanned (for the preview and the history).</param>
/// <param name="Pages">The same pages after every step, with the facts the steps found.</param>
public sealed record ProcessedScan(IReadOnlyList<ScannedPage> Arranged, IReadOnlyList<ScannedPage> Pages)
{
    /// <summary>Pages the blank-page check found blank at the sensitivity it ran with.</summary>
    public int BlankCount => Pages.Count(p => p.Blank?.IsBlank == true);
}

/// <summary>
/// The clean-up stage between the scanner and the page queue, the same for every scanner: the
/// pages are put in reading order with their sides (two-sided scans), then every step runs on
/// every page in order. The order of the steps is fixed: <see cref="ForScan"/> builds them from
/// the settings: blank check (document pages), then adjustments. Later page features slot in
/// between (crop and straighten after the blank check, separator sheets after that, turning
/// pages upright before the adjustments).
/// </summary>
public sealed class PageProcessor(IReadOnlyList<IPageStep> steps,
                                  ScanArrangement arrangement = ScanArrangement.AsScanned,
                                  DuplexBinding binding = DuplexBinding.LongEdge)
{
    public IReadOnlyList<IPageStep> Steps { get; } = steps;
    public ScanArrangement Arrangement { get; } = arrangement;
    public DuplexBinding Binding { get; } = binding;

    /// <summary>
    /// The steps for a scan made with <paramref name="settings"/>: the blank-page check for pages
    /// collected in the document queue (whether or not blank pages are left out, so the page
    /// strip can flag them), then the adjustments unless they change nothing.
    /// </summary>
    public static PageProcessor ForScan(ScanSettings settings, ScanArrangement arrangement = ScanArrangement.AsScanned)
    {
        var steps = new List<IPageStep>();
        if (ChecksBlankPages(settings))
        {
            steps.Add(new BlankDetectionStep(new BlankPageOptions { Sensitivity = settings.Document.BlankSensitivity }));
        }
        if (!(settings.Adjustments.IsIdentity && settings.ColorMode == ColorMode.Color))
        {
            steps.Add(new AdjustmentStep(settings.Adjustments, settings.ColorMode));
        }
        return new PageProcessor(steps, arrangement, settings.BackBinding);
    }

    /// <summary>
    /// Whether scans with these settings get the blank-page check: document pages collected in
    /// the queue, where a flagged page can be seen and kept before saving. Pages saved as soon as
    /// they are scanned are never checked, so none is ever left out unseen.
    /// </summary>
    public static bool ChecksBlankPages(ScanSettings settings) =>
        TaskCatalog.FlowOf(settings) == TaskFlowKind.DocumentQueue && settings.DocumentMultiPage;

    /// <summary>
    /// Arranges the pages, then runs every step on every page. <paramref name="token"/> is checked
    /// before each page and each step.
    /// </summary>
    public ProcessedScan Process(IReadOnlyList<ScannedPage> scanned, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        IReadOnlyList<ScannedPage> arranged = Arrangement switch
        {
            ScanArrangement.TwoSided => DocumentSides.ArrangeTwoSided(scanned, Binding),
            ScanArrangement.TurnedOverFronts => DocumentSides.MarkManual(scanned, PageSide.Front, Binding),
            ScanArrangement.TurnedOverBacks => DocumentSides.MarkManual(scanned, PageSide.Back, Binding),
            _ => scanned,
        };
        var pages = new List<ScannedPage>(arranged.Count);
        foreach (var page in arranged)
        {
            token.ThrowIfCancellationRequested();
            var current = page;
            foreach (var step in Steps)
            {
                token.ThrowIfCancellationRequested();
                current = step.Apply(current);
            }
            pages.Add(current);
        }
        return new ProcessedScan(arranged, pages);
    }
}

/// <summary>
/// Which queued pages are saved. A page is left out when the user skipped it, or when it looks
/// blank and blank pages are left out, unless the user kept it. Nothing is ever removed from
/// the queue by this: a left-out page stays visible, flagged, until the queue is saved.
/// </summary>
public static class PageFilter
{
    /// <summary>The page looks blank at <paramref name="sensitivity"/> (false when it was not checked).</summary>
    public static bool LooksBlank(ScannedPage page, BlankSensitivity sensitivity) =>
        page.Blank?.IsBlankAt(sensitivity) == true;

    /// <summary>Whether saving the queue with <paramref name="options"/> leaves the page out.</summary>
    public static bool IsExcluded(ScannedPage page, DocumentOptions options) => page.Inclusion switch
    {
        PageInclusion.Keep => false,
        PageInclusion.Skip => true,
        _ => options.RemoveBlankPages && LooksBlank(page, options.BlankSensitivity),
    };

    /// <summary>
    /// The inclusion after one click on the page: the opposite of what saving would do now. A
    /// click that agrees with the setting goes back to <see cref="PageInclusion.Automatic"/>, so
    /// two clicks undo one.
    /// </summary>
    public static PageInclusion Toggled(ScannedPage page, DocumentOptions options)
    {
        bool excludeNow = !IsExcluded(page, options);
        bool automatic = options.RemoveBlankPages && LooksBlank(page, options.BlankSensitivity);
        if (excludeNow == automatic) return PageInclusion.Automatic;
        return excludeNow ? PageInclusion.Skip : PageInclusion.Keep;
    }

    /// <summary>The pages saving the queue writes, in queue order.</summary>
    public static List<ScannedPage> PagesToSave(IEnumerable<ScannedPage> pages, DocumentOptions options) =>
        pages.Where(p => !IsExcluded(p, options)).ToList();

    /// <summary>
    /// The page strip's note on a page: "Blank, skipped" for a blank page left out, "Skipped" for
    /// another page the user left out, "Looks blank" for a blank page that will be saved; null
    /// for other pages.
    /// </summary>
    public static string? Badge(ScannedPage page, DocumentOptions options)
    {
        bool blank = LooksBlank(page, options.BlankSensitivity);
        if (IsExcluded(page, options)) return blank ? "Blank, skipped" : "Skipped";
        return blank ? "Looks blank" : null;
    }

    /// <summary>
    /// What one click on the page does, for its button and screen readers: "Keep this page"
    /// for a left-out page, "Skip this page" for a blank-looking page that will be saved; null
    /// when the page has no such button (it is saved and does not look blank).
    /// </summary>
    public static string? ToggleLabel(ScannedPage page, DocumentOptions options)
    {
        if (IsExcluded(page, options)) return "Keep this page";
        return LooksBlank(page, options.BlankSensitivity) || page.Inclusion != PageInclusion.Automatic
            ? "Skip this page"
            : null;
    }

    /// <summary>"3 pages in queue", "24 pages in queue, 5 blank skipped", "4 pages in queue, 1 skipped".</summary>
    public static string QueueSummary(IReadOnlyCollection<ScannedPage> pages, DocumentOptions options)
    {
        int total = pages.Count;
        var excluded = pages.Where(p => IsExcluded(p, options)).ToList();
        string text = $"{total} page{(total == 1 ? "" : "s")} in queue";
        if (excluded.Count == 0) return text;
        bool allBlank = excluded.All(p => LooksBlank(p, options.BlankSensitivity));
        return $"{text}, {excluded.Count}{(allBlank ? " blank" : "")} skipped";
    }

    /// <summary>
    /// The status after a scan's pages were queued, when some look blank: " 2 look blank and will
    /// be skipped." or " 1 looks blank." (leading space; empty when none does).
    /// </summary>
    public static string ScanNote(IEnumerable<ScannedPage> added, DocumentOptions options)
    {
        int blank = added.Count(p => LooksBlank(p, options.BlankSensitivity));
        if (blank == 0) return "";
        string verb = blank == 1 ? "looks" : "look";
        return options.RemoveBlankPages
            ? $" {blank} {verb} blank and will be skipped."
            : $" {blank} {verb} blank.";
    }

    /// <summary>The message when every queued page is left out, so there is nothing to save.</summary>
    public const string NothingToSaveMessage =
        "Every page in the queue is skipped. Keep a page, or turn off Skip blank pages, to save.";
}
