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
/// A step that can take long enough to be stopped part way: <see cref="PageProcessor.Process"/>
/// hands it the token it was given.
/// </summary>
public interface ICancellablePageStep : IPageStep
{
    ScannedPage Apply(ScannedPage page, CancellationToken token);
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

/// <summary>
/// Cuts a page taken by a camera out of its photo (<see cref="ScannedPage.Capture"/> not yet measured,
/// no geometry yet): its real size from <see cref="CaptureScale.Measure(Quad, int, int, CaptureKind, double?)"/>
/// (the capture's corners and focal length scaled to the pixels at hand when the photo in memory is
/// smaller than the one taken), the page made upright at that size by <see cref="PerspectiveWarp"/>,
/// the resolution set to the size's and recorded on the capture (<see cref="CaptureFacts.Scale"/>),
/// and the photo kept as the other version (<see cref="ScannedPage.WithGeometry"/>,
/// <see cref="GeometryBasis.Perspective"/> with the corners). Other pages, and corners that outline no
/// page, stay as they are. Runs first, before the blank check.
/// </summary>
public sealed class PerspectiveStep : IPageStep
{
    public string Name => "perspective";

    public ScannedPage Apply(ScannedPage page)
    {
        if (page.Capture is not { Scale: null } capture || page.Geometry is not null) return page;
        var photo = page.Image;
        var quad = capture.Quad;
        double? focalLength = capture.FocalLength;
        if (capture.SourceWidth > 0 && capture.SourceHeight > 0
            && (capture.SourceWidth != photo.Width || capture.SourceHeight != photo.Height))
        {
            double sx = (double)photo.Width / capture.SourceWidth, sy = (double)photo.Height / capture.SourceHeight;
            quad = quad.Scaled(sx, sy);
            if (focalLength is { } f) focalLength = f * sx;
        }
        if (!quad.IsConvex) return page;
        var scale = CaptureScale.Measure(quad, photo.Width, photo.Height, capture.Kind, focalLength);
        if (PerspectiveWarp.Warp(photo, quad, scale.PixelWidth, scale.PixelHeight) is not { } warped) return page;
        var measured = new ScannedPage(photo, scale.Dpi, page.ColorMode, page.Id, page.CreatedAt, page.FilePath, page.FullPixelSize)
        {
            RotationQuarterTurns = page.RotationQuarterTurns,
            Alternate = page.Alternate,
        }.CopyMeta(page).WithCapture(capture with { Scale = scale });
        return measured.WithGeometry(warped, new PageGeometry(true, 0, GeometryBasis.Perspective) { Quad = quad });
    }
}

/// <summary>
/// Crops the page to the sheet and straightens it (<see cref="DocumentGeometry.Correct"/>), keeping
/// the page as it was as the other version (<see cref="ScannedPage.WithGeometry"/>); a page the
/// analysis is not sure about stays as it is, and so does a page from a camera or a photo
/// (<see cref="ScannedPage.Capture"/>, <see cref="GeometryBasis.Perspective"/>), which was cut out
/// along its corners already and lies on no scanner background. Runs after the blank check, before
/// the adjustments.
/// </summary>
public sealed class GeometryStep(bool crop, bool straighten) : IPageStep
{
    public bool Crop { get; } = crop;
    public bool Straighten { get; } = straighten;
    public string Name => "geometry";

    public ScannedPage Apply(ScannedPage page)
    {
        if (page.Capture is not null || page.Geometry?.Basis == GeometryBasis.Perspective) return page;
        return DocumentGeometry.Correct(page.Image, page.Dpi, Crop, Straighten) is { } corrected
            ? page.WithGeometry(corrected.Image, corrected.Geometry)
            : page;
    }
}

/// <summary>
/// Softens the shadow along the spine on a page cut from a spread (<see cref="SpineShadow.Soften"/>), keeping
/// the page as scanned as the other version (<see cref="ScannedPage.WithSpineShadow"/>): the edge along the
/// spine is the edge of the cut, turned by the book's rotation (<paramref name="rotationQuarterTurns"/>,
/// the turn every page of the spread was given before the steps). Pages not cut from a spread, and pages
/// with no shadow to soften, stay as they are. Runs after crop and straighten, before the separator check.
/// </summary>
public sealed class SpineShadowStep(int rotationQuarterTurns) : IPageStep
{
    public int RotationQuarterTurns { get; } = BookSplitter.NormalizedTurns(rotationQuarterTurns);
    public string Name => "spineShadow";

    public ScannedPage Apply(ScannedPage page)
    {
        if (SpineShadow.GutterEdge(page.Spread, RotationQuarterTurns) is not { } edge) return page;
        return SpineShadow.Soften(page.Image, page.Dpi, edge) is { } softened
            ? page.WithSpineShadow(softened.Image, softened.Result)
            : page;
    }
}

/// <summary>
/// Looks for a patch code on the page (<see cref="PatchCodeDetector"/>) and records it: the page is
/// then a separator sheet, used when the stack is split at separator sheets
/// (<see cref="DocumentSplitter"/>). The pixels are not changed. Runs after crop and straighten,
/// before the adjustments.
/// </summary>
public sealed class SeparatorStep : IPageStep
{
    public string Name => "separator";

    public ScannedPage Apply(ScannedPage page) =>
        page.WithPatch(PatchCodeDetector.Detect(page.Image, page.Dpi)?.Code);
}

/// <summary>
/// Reads the barcodes and QR codes on the page with <paramref name="reader"/>
/// (<see cref="BarcodeSeparators.ReadPage"/>) and records them, so the stack can be split at barcode or QR
/// sheets and the documents named by them (<see cref="DocumentSplitter"/>). The pixels are not
/// changed. A page the reader fails on stays unread (<see cref="ScannedPage.Barcodes"/> null). Runs
/// after the separator check, before turning pages upright and the adjustments.
/// </summary>
public sealed class BarcodeStep(IBarcodeReader reader) : ICancellablePageStep
{
    public IBarcodeReader Reader { get; } = reader;
    public string Name => "barcode";

    public ScannedPage Apply(ScannedPage page) => Apply(page, CancellationToken.None);

    public ScannedPage Apply(ScannedPage page, CancellationToken token)
    {
        try
        {
            return page.WithBarcodes(BarcodeSeparators.ReadPage(page, Reader, token));
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            // A reading that failed leaves the page as it was: no code is made up, none is lost.
            return page;
        }
    }
}

/// <summary>
/// Turns the page upright when its text reads clearly better another way up
/// (<see cref="OrientationDecision.Check"/>, reading with <paramref name="scorer"/>), recording the
/// turn so one click undoes it (<see cref="ScannedPage.TurnedUpright"/>). Blank pages and separator
/// sheets are not read: patch-code sheets, and under <paramref name="split"/> (the scan's document
/// options) barcode or QR separator sheets (<see cref="BarcodeSeparators.IsSeparatorPage"/>); a page
/// the reading is not sure about, or that takes longer than <paramref name="maxSeconds"/>, stays as it
/// is. Runs after the separator and barcode checks, before the adjustments, on the page as cropped and
/// straightened. <paramref name="clock"/> (seconds) is for tests.
/// </summary>
public sealed class OrientationStep(IOrientationScorer scorer, double maxSeconds = OrientationDecision.MaxSecondsPerPage,
                                    Func<double>? clock = null, DocumentOptions? split = null) : ICancellablePageStep
{
    public IOrientationScorer Scorer { get; } = scorer;
    public double MaxSeconds { get; } = maxSeconds;
    /// <summary>The document options whose barcode or QR separator sheets are not read; null: none are known.</summary>
    public DocumentOptions? Split { get; } = split?.Clone();
    public string Name => "orientation";

    public ScannedPage Apply(ScannedPage page) => Apply(page, CancellationToken.None);

    public ScannedPage Apply(ScannedPage page, CancellationToken token)
    {
        if (page.Blank?.IsBlank == true || page.Patch is not null) return page;
        if (Split is { } options && BarcodeSeparators.IsSeparatorPage(page, options)) return page;
        var check = OrientationDecision.Check(page.Image, page.Dpi, Scorer, token, MaxSeconds, clock);
        return check.Verdict == OrientationVerdict.Turned ? page.TurnedUpright(check.QuarterTurns) : page;
    }
}

/// <summary>
/// The image adjustments and the color mode (<see cref="ImagePipeline.Apply"/>), on the page and on
/// its other version (the page as scanned, kept by crop and straighten or by softening the spine's
/// shadow), so either can be shown.
/// </summary>
public sealed class AdjustmentStep(AdjustmentSettings adjustments, ColorMode colorMode) : IPageStep
{
    public AdjustmentSettings Adjustments { get; } = adjustments;
    public ColorMode ColorMode { get; } = colorMode;
    public string Name => "adjust";

    public ScannedPage Apply(ScannedPage page)
    {
        var adjusted = page.WithImage(ImagePipeline.Apply(Adjustments, page.Image, ColorMode), ColorMode);
        return page.Alternate is { Image: { } other } version
            ? adjusted.WithAlternate(version with { Image = ImagePipeline.Apply(Adjustments, other, ColorMode) })
            : adjusted;
    }
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
/// <param name="Pages">
/// The same pages after every step, with the facts the steps found; with facing pages split, the pages
/// cut from each spread (<see cref="ScannedPage.Spread"/>, whose id is the spread's in <see cref="Arranged"/>).
/// </param>
public sealed record ProcessedScan(IReadOnlyList<ScannedPage> Arranged, IReadOnlyList<ScannedPage> Pages)
{
    /// <summary>Pages the blank-page check found blank at the sensitivity it ran with.</summary>
    public int BlankCount => Pages.Count(p => p.Blank?.IsBlank == true);

    /// <summary>The spreads in <see cref="Arranged"/> that pages were cut from (or kept whole as), in scan order.</summary>
    public IReadOnlyList<ScannedPage> Spreads
    {
        get
        {
            var ids = Pages.Select(p => p.SpreadId).OfType<Guid>().ToHashSet();
            return Arranged.Where(p => ids.Contains(p.Id)).ToList();
        }
    }
}

/// <summary>
/// The clean-up stage between the scanner and the page queue, the same for every scanner: the
/// pages are put in reading order with their sides (two-sided scans), each spread of an open book
/// is cut into its two pages when facing pages are split (<paramref name="book"/>), then every step
/// runs on every page in order. The order of the steps is fixed: <see cref="ForScan"/> builds them
/// from the settings: blank check (document pages), crop and straighten, softening the spine's shadow,
/// separator sheets, barcodes, turning pages upright, then adjustments.
/// </summary>
public sealed class PageProcessor(IReadOnlyList<IPageStep> steps,
                                  ScanArrangement arrangement = ScanArrangement.AsScanned,
                                  DuplexBinding binding = DuplexBinding.LongEdge,
                                  BookSplitOptions? book = null)
{
    public IReadOnlyList<IPageStep> Steps { get; } = steps;
    public ScanArrangement Arrangement { get; } = arrangement;
    public DuplexBinding Binding { get; } = binding;
    /// <summary>How the pages of each spread are turned and ordered; null when spreads are not split.</summary>
    public BookSplitOptions? Book { get; } = book;

    /// <summary>
    /// The steps for a scan made with <paramref name="settings"/>: the blank-page check for pages
    /// collected in the document queue (whether or not blank pages are left out, so the page
    /// strip can flag them), crop and straighten when asked for those pages, softening the spine's
    /// shadow when asked for on split spreads (<see cref="SoftensSpineShadow"/>), the separator-sheet
    /// check for those pages (whether or not the stack is split, so a split chosen later finds
    /// them), reading their barcodes when the stack is split at barcode or QR sheets
    /// (<see cref="ReadsBarcodes"/>) and <paramref name="barcodes"/> can read them, turning those pages
    /// upright when asked for and <paramref name="scorer"/> can read text, then the adjustments unless
    /// they change nothing. Facing pages are split before the steps when
    /// asked for those pages (<see cref="SplitsFacingPages"/>), so each page is checked, straightened
    /// and turned on its own.
    /// </summary>
    public static PageProcessor ForScan(ScanSettings settings, ScanArrangement arrangement = ScanArrangement.AsScanned,
                                        IOrientationScorer? scorer = null, IBarcodeReader? barcodes = null)
    {
        var steps = new List<IPageStep>();
        if (ChecksBlankPages(settings))
        {
            steps.Add(new BlankDetectionStep(new BlankPageOptions { Sensitivity = settings.Document.BlankSensitivity }));
        }
        if (CorrectsGeometry(settings))
        {
            steps.Add(new GeometryStep(settings.Document.AutoCrop, settings.Document.AutoStraighten));
        }
        if (SoftensSpineShadow(settings))
        {
            steps.Add(new SpineShadowStep(BookSplitOptions.Of(settings).RotationQuarterTurns));
        }
        if (ChecksBlankPages(settings))
        {
            steps.Add(new SeparatorStep());
        }
        if (ReadsBarcodes(settings) && barcodes is { IsAvailable: true })
        {
            steps.Add(new BarcodeStep(barcodes));
        }
        if (TurnsPagesUpright(settings) && scorer is { IsAvailable: true })
        {
            steps.Add(new OrientationStep(scorer, split: settings.Document));
        }
        if (!(settings.Adjustments.IsIdentity && settings.ColorMode == ColorMode.Color))
        {
            steps.Add(new AdjustmentStep(settings.Adjustments, settings.ColorMode));
        }
        return new PageProcessor(steps, arrangement, settings.BackBinding,
                                 SplitsFacingPages(settings) ? BookSplitOptions.Of(settings) : null);
    }

    /// <summary>
    /// The steps for pages made from imported photos of documents (<see cref="PhotoImport"/>), which
    /// always go to the queue: the blank-page check, the separator-sheet check, reading barcodes when
    /// the stack is split at barcode or QR sheets and <paramref name="barcodes"/> can read them, turning
    /// pages upright when asked for and <paramref name="scorer"/> can read text, then the adjustments
    /// unless they change nothing. Crop and straighten, the spine's shadow and splitting facing pages
    /// are left out: the page was cut out of the photo along its corners already, and the photo as it
    /// was is the page's other version.
    /// </summary>
    public static PageProcessor ForPhotoImport(ScanSettings settings, IOrientationScorer? scorer = null,
                                               IBarcodeReader? barcodes = null)
    {
        var steps = new List<IPageStep>
        {
            new BlankDetectionStep(new BlankPageOptions { Sensitivity = settings.Document.BlankSensitivity }),
            new SeparatorStep(),
        };
        if (settings.Document.SplitMode == SplitMode.Barcode && barcodes is { IsAvailable: true })
        {
            steps.Add(new BarcodeStep(barcodes));
        }
        if (settings.Document.AutoRotate && scorer is { IsAvailable: true })
        {
            steps.Add(new OrientationStep(scorer, split: settings.Document));
        }
        if (!(settings.Adjustments.IsIdentity && settings.ColorMode == ColorMode.Color))
        {
            steps.Add(new AdjustmentStep(settings.Adjustments, settings.ColorMode));
        }
        return new PageProcessor(steps);
    }

    /// <summary>
    /// The steps for pages taken by a camera (<see cref="ScannedPage.Capture"/>), which go to the queue
    /// like imported photos: <see cref="PerspectiveStep"/> cuts each page out of its photo at its real
    /// size, then the steps of <see cref="ForPhotoImport"/>.
    /// </summary>
    public static PageProcessor ForCapture(ScanSettings settings, IOrientationScorer? scorer = null,
                                           IBarcodeReader? barcodes = null)
    {
        var steps = new List<IPageStep> { new PerspectiveStep() };
        steps.AddRange(ForPhotoImport(settings, scorer, barcodes).Steps);
        return new PageProcessor(steps);
    }

    /// <summary>
    /// Whether scans with these settings get the blank-page check: document pages collected in
    /// the queue, where a flagged page can be seen and kept before saving. Pages saved as soon as
    /// they are scanned are never checked, so none is ever left out unseen.
    /// </summary>
    public static bool ChecksBlankPages(ScanSettings settings) =>
        TaskCatalog.FlowOf(settings) == TaskFlowKind.DocumentQueue && settings.DocumentMultiPage;

    /// <summary>
    /// Whether scans with these settings are cropped or straightened: asked for, on document pages
    /// collected in the queue, where the page strip shows a changed page and one click shows it as
    /// scanned. Pages saved as soon as they are scanned are never changed unseen.
    /// </summary>
    public static bool CorrectsGeometry(ScanSettings settings) =>
        ChecksBlankPages(settings) && (settings.Document.AutoCrop || settings.Document.AutoStraighten);

    /// <summary>
    /// Whether scans with these settings have their barcodes read: document pages collected in the
    /// queue, split at barcode or QR sheets. Reading takes time, so other splits don't read them;
    /// choosing this split reads the pages already queued (the app does that).
    /// </summary>
    public static bool ReadsBarcodes(ScanSettings settings) =>
        ChecksBlankPages(settings) && settings.Document.SplitMode == SplitMode.Barcode;

    /// <summary>
    /// Whether scans with these settings are turned upright: asked for, on document pages collected
    /// in the queue, where the page strip shows a turned page and one click undoes the turn. Pages
    /// saved as soon as they are scanned are never turned unseen.
    /// </summary>
    public static bool TurnsPagesUpright(ScanSettings settings) =>
        ChecksBlankPages(settings) && settings.Document.AutoRotate;

    /// <summary>
    /// Whether scans with these settings have their facing pages split: asked for, on document pages
    /// collected in the queue, where the page strip shows the pages and one click joins them again,
    /// scanned one side of each sheet (<see cref="BookPages.ScansOneSide"/>). Pages saved as soon as
    /// they are scanned are never cut unseen, and pages scanned on both sides keep their sheet and side.
    /// </summary>
    public static bool SplitsFacingPages(ScanSettings settings) =>
        ChecksBlankPages(settings) && settings.Document.SplitFacingPages && BookPages.ScansOneSide(settings);

    /// <summary>
    /// Whether the pages cut from spreads have their spine's shadow softened: asked for, while facing pages
    /// are split (<see cref="SplitsFacingPages"/>), where the page strip shows a softened page and one
    /// click shows it as scanned.
    /// </summary>
    public static bool SoftensSpineShadow(ScanSettings settings) =>
        SplitsFacingPages(settings) && settings.Document.SoftenSpineShadow;

    /// <summary>
    /// Arranges the pages, splits each spread when facing pages are split (where its gutter is found,
    /// <see cref="BookSplitter.FindGutter(RgbaImage, int)"/>; whole otherwise), then runs every step on
    /// every page. <paramref name="token"/> is checked before each page and each step, and handed to the
    /// steps that can stop part way (<see cref="ICancellablePageStep"/>).
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
            if (Book is { } book)
            {
                pages.AddRange(ProcessSpread(page, BookSplitter.FindGutter(page.Image, page.Dpi), book, token));
                continue;
            }
            pages.Add(RunSteps(page, token));
        }
        return new ProcessedScan(arranged, pages);
    }

    /// <summary>
    /// The pages of one spread after every step: <paramref name="spread"/> (as scanned) cut at
    /// <paramref name="cut"/>, or kept whole when it is null, each page turned as
    /// <paramref name="options"/> say, then put in reading order: by where they lie once turned by the
    /// book's rotation and the turn reading their text gave them (<see cref="BookSplitter.TotalTurns"/>).
    /// Each page records the spread (<see cref="SpreadPart"/>, with the spread's id, and whether it is the
    /// left or the right page, <see cref="SpreadPart.Left"/>), keeps the side and
    /// sheet the spread was given (<see cref="ScannedPage.Side"/>, <see cref="ScannedPage.SheetIndex"/>)
    /// and gets an id of its own. Used for every scan when facing pages are split, and to join or split
    /// a spread again.
    /// </summary>
    public IReadOnlyList<ScannedPage> ProcessSpread(ScannedPage spread, GutterResult? cut, BookSplitOptions options,
                                                    CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        int turns = BookSplitter.NormalizedTurns(options.RotationQuarterTurns);
        ScannedPage Part(RgbaImage image, int? part) =>
            new ScannedPage(image.RotatedQuarterTurns(turns), spread.Dpi, spread.ColorMode, createdAt: spread.CreatedAt)
            {
                Side = spread.Side,
                SheetIndex = spread.SheetIndex,
                Spread = new SpreadPart(spread.Id, part, part is null ? null : cut),
            };
        if (cut is null) return [RunSteps(Part(spread.Image, null), token)];
        var (first, second) = BookSplitter.Halves(spread.Image, cut);
        var a = RunSteps(Part(first, 0), token);
        var b = RunSteps(Part(second, 1), token);
        int total = BookSplitter.TotalTurns(turns, a.Upright, b.Upright);
        bool firstLeads = BookSplitter.FirstPartLeads(cut.Axis, total, options.RightToLeft);
        // The page that leads is the left one, or the right one in a book read from right to left.
        bool firstIsLeft = firstLeads != options.RightToLeft;
        a = a.WithSpread(a.Spread! with { Left = firstIsLeft });
        b = b.WithSpread(b.Spread! with { Left = !firstIsLeft });
        return firstLeads ? [a, b] : [b, a];
    }

    /// <summary>Every step on <paramref name="page"/>, in order.</summary>
    private ScannedPage RunSteps(ScannedPage page, CancellationToken token)
    {
        var current = page;
        foreach (var step in Steps)
        {
            token.ThrowIfCancellationRequested();
            current = step is ICancellablePageStep cancellable ? cancellable.Apply(current, token) : step.Apply(current);
        }
        return current;
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

    /// <summary>The page strip's label: "3 pages", "24 pages · 5 blank skipped", "4 pages · 1 skipped".</summary>
    public static string QueueSummary(IReadOnlyCollection<ScannedPage> pages, DocumentOptions options)
    {
        int total = pages.Count;
        var excluded = pages.Where(p => IsExcluded(p, options)).ToList();
        string text = $"{total} page{(total == 1 ? "" : "s")}";
        if (excluded.Count == 0) return text;
        bool allBlank = excluded.All(p => LooksBlank(p, options.BlankSensitivity));
        return $"{text} · {excluded.Count}{(allBlank ? " blank" : "")} skipped";
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

/// <summary>
/// What the page strip and the status say about crop and straighten and the softened spine shadow: a
/// caption on a changed page, its one-click swap with the page as scanned, and the note after a scan.
/// </summary>
public static class PageCorrections
{
    /// <summary>
    /// "Cropped and straightened 2.4°", "Straightened 1.5°" or "Cropped" for a changed page shown
    /// changed, followed by ", spine shadow softened" ("Spine shadow softened" alone) when the shadow was
    /// softened; "As scanned" when the user went back to the page as scanned; "Corrected from photo"
    /// and "As photographed" for a page taken from a photo; null for other pages.
    /// </summary>
    public static string? Caption(ScannedPage page)
    {
        if (page.Geometry is null && page.SpineShadow is null) return null;
        if (page.ShowsOriginal) return FromPhoto(page) ? PhotoImport.OriginalCaption : "As scanned";
        if (page.Geometry is not { } geometry) return "Spine shadow softened";
        return page.SpineShadow is null ? geometry.Caption : $"{geometry.Caption}, spine shadow softened";
    }

    /// <summary>
    /// What one click on the page's swap button does: "Show as scanned", or back: "Show cropped
    /// and straightened", "Show straightened", "Show cropped", "Show with the spine shadow softened",
    /// "Show straightened, with the spine shadow softened"; "Show as photographed" and "Show corrected"
    /// for a page taken from a photo; null when the page cannot swap.
    /// </summary>
    public static string? ToggleLabel(ScannedPage page)
    {
        if (!page.CanSwapVersions) return null;
        if (!page.ShowsOriginal) return FromPhoto(page) ? "Show as photographed" : "Show as scanned";
        if (page.Geometry is not { } geometry) return "Show with the spine shadow softened";
        return page.SpineShadow is null ? $"Show {Done(geometry)}" : $"Show {Done(geometry)}, with the spine shadow softened";
    }

    /// <summary>
    /// The status after a page's versions were swapped: "Page 3 is shown as scanned. It is saved that
    /// way.", "Page 3 is cropped and straightened again.", "Page 3 is shown with the spine shadow
    /// softened again." or "Page 3 is straightened again, with the spine shadow softened."; for a page
    /// taken from a photo "Page 3 is shown as photographed. It is saved that way." or "Page 3 is
    /// corrected again."
    /// </summary>
    public static string SwapNote(ScannedPage page, int number)
    {
        if (page.ShowsOriginal || (page.Geometry is null && page.SpineShadow is null))
        {
            return FromPhoto(page)
                ? $"Page {number} is shown as photographed. It is saved that way."
                : $"Page {number} is shown as scanned. It is saved that way.";
        }
        if (page.Geometry is not { } geometry) return $"Page {number} is shown with the spine shadow softened again.";
        return page.SpineShadow is null
            ? $"Page {number} is {Done(geometry)} again."
            : $"Page {number} is {Done(geometry)} again, with the spine shadow softened.";
    }

    /// <summary>
    /// The status after a scan's pages were queued, when crop and straighten changed some: " 2
    /// straightened." or " 3 cropped or straightened."; then, when the spine's shadow was softened on
    /// some, " Spine shadow softened on 2 pages." (leading space; empty when nothing was changed).
    /// Pages taken from photos are left out: the import's own status tells about them
    /// (<see cref="PhotoImport.AddedMessage"/>).
    /// </summary>
    public static string ScanNote(IEnumerable<ScannedPage> added)
    {
        var pages = added.ToList();
        var changed = pages.Where(p => p.Geometry is { Basis: not GeometryBasis.Perspective } && !p.ShowsOriginal)
            .Select(p => Done(p.Geometry!)).ToList();
        string note = "";
        if (changed.Count > 0)
        {
            string verb = changed.Distinct().Count() == 1 ? changed[0] : "cropped or straightened";
            note = $" {changed.Count} {verb}.";
        }
        int softened = pages.Count(p => p.SpineShadow is not null && !p.ShowsOriginal);
        if (softened > 0) note += $" Spine shadow softened on {softened} page{(softened == 1 ? "" : "s")}.";
        return note;
    }

    /// <summary>The page was taken from a photo along its corners: its other version is the photo.</summary>
    private static bool FromPhoto(ScannedPage page) => page.Geometry?.Basis == GeometryBasis.Perspective;

    /// <summary>"cropped and straightened", "straightened" or "cropped"; "corrected" for a page taken from a photo.</summary>
    private static string Done(PageGeometry geometry) =>
        geometry.Basis == GeometryBasis.Perspective ? "corrected"
        : geometry.Cropped && geometry.Straightened ? "cropped and straightened"
        : geometry.Straightened ? "straightened"
        : "cropped";
}
