namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/PhotoImport.swift: the same rules, numbers and words.

/// <summary>
/// How a photo's stored pixels are turned to show it the right way up, read from the orientation
/// tag cameras write (EXIF and TIFF tag 274, values 1 to 8): mirrored left to right first when
/// <see cref="Mirrored"/>, then turned <see cref="QuarterTurns"/> quarter turns clockwise.
/// </summary>
public readonly record struct PhotoOrientation(int QuarterTurns, bool Mirrored)
{
    /// <summary>The pixels are stored the right way up (tag 1, or no tag).</summary>
    public static PhotoOrientation Upright => new(0, false);

    public bool IsUpright => QuarterTurns == 0 && !Mirrored;

    /// <summary>
    /// The turn for tag value <paramref name="value"/>: 1 upright, 2 mirrored, 3 upside down, 4 mirrored
    /// top to bottom, 5 mirrored across the main diagonal, 6 turned a quarter clockwise, 7 mirrored across
    /// the other diagonal, 8 turned a quarter counterclockwise. Any other value (no tag, 0, 9…) is upright.
    /// </summary>
    public static PhotoOrientation FromExif(int value) => value switch
    {
        2 => new(0, true),
        3 => new(2, false),
        4 => new(2, true),
        5 => new(3, true),
        6 => new(1, false),
        7 => new(1, true),
        8 => new(3, false),
        _ => Upright,
    };
}

/// <summary>What happens to an imported photo (<see cref="PhotoImport.Plan(PhotoDocumentDetection, int, int)"/>).</summary>
public enum PhotoImportAction
{
    /// <summary>The page was found clearly: it is cut out along its corners without asking.</summary>
    Correct,
    /// <summary>The user checks the corners first (or uses the whole photo, or skips it).</summary>
    Review,
}

/// <summary>Why the user is asked to check a photo's corners.</summary>
public enum PhotoReviewReason
{
    /// <summary>Nothing to check: the page was found clearly.</summary>
    None,
    /// <summary>An outline was found, but its edges are not clear enough to trust.</summary>
    Unsure,
    /// <summary>The page runs off the edge of the photo.</summary>
    CutOff,
    /// <summary>Two pages of about the same size are in the photo.</summary>
    TwoPages,
    /// <summary>No page was found.</summary>
    NothingFound,
}

/// <summary>
/// What to do with one imported photo: correct it along <see cref="Corners"/>, or show the corner
/// editor with <see cref="Corners"/> as its starting guess and <see cref="Reason"/> as its note.
/// </summary>
/// <param name="Corners">The page's corners in the photo's pixels (upright photo): the page found, else the
/// best outline seen kept within the photo, else a rectangle inset from the photo's edges.</param>
public sealed record PhotoImportPlan(PhotoImportAction Action, Quad Corners, PhotoReviewReason Reason,
                                     PhotoDocumentDetection Detection);

/// <summary>The user's answer in the corner editor.</summary>
public enum PhotoCornersChoice
{
    /// <summary>Cut the page out along the corners as placed.</summary>
    UseCorners,
    /// <summary>Add the whole photo as the page, unchanged.</summary>
    WholePhoto,
    /// <summary>Leave this photo out.</summary>
    Skip,
}

/// <summary>
/// Importing photos of documents (JPEG, PNG, HEIC… files) as pages of the queue: each photo is
/// turned upright by its orientation tag, the page is found (<see cref="PhotoDocumentDetector"/>)
/// and cut out along its corners with its perspective corrected (<see cref="PerspectiveCorrector"/>);
/// when the page is not found clearly the user places the corners (or takes the whole photo). The
/// page then goes through the clean-up stage like a scan (<see cref="PageProcessor.ForPhotoImport"/>),
/// with the photo as it was kept as its other version, so one click shows it as photographed. The
/// photo files are only read: never changed, moved or copied beside themselves.
/// </summary>
public static class PhotoImport
{
    /// <summary>A page found with at least this confidence is corrected without asking.</summary>
    public const double SureConfidence = 0.7;
    /// <summary>The resolution of a page whose paper size is not known (<see cref="PerspectiveCorrector.NominalDpi"/>).</summary>
    public const int NominalDpi = 200;
    /// <summary>The lowest resolution a page from a photo is given (a small photo of a big sheet)…</summary>
    public const int MinDpi = 50;
    /// <summary>…and the highest.</summary>
    public const int MaxDpi = 1200;
    /// <summary>With nothing found, the editor starts with a rectangle this share of the photo in from each edge.</summary>
    public const double StartInset = 0.1;
    /// <summary>The corner editor keeps every edge at least this many photo pixels long.</summary>
    public const double MinEdgePixels = 16;
    /// <summary>A photo of more pixels than this is not imported (its pixels alone would take 600 MB).</summary>
    public const long MaxPhotoPixels = 150_000_000;

    /// <summary>The file types offered for import (lowercase, without the dot).</summary>
    public static IReadOnlyList<string> FileExtensions { get; } =
        ["jpg", "jpeg", "jpe", "png", "heic", "heif", "hif", "tif", "tiff", "bmp", "webp"];

    /// <summary>The HEIF file types (iPhone photos): Windows reads them only with the HEIF extension installed.</summary>
    public static IReadOnlyList<string> HeifExtensions { get; } = ["heic", "heif", "hif"];

    public const string ButtonLabel = "Import photos of documents…";
    public const string ButtonHint =
        "Add photos of paper documents to the queue. Each page is found in its photo, straightened and cleaned up like a scan; the photo files are not changed.";
    public const string PickerTitle = "Import photos of documents";
    public const string DropHint = "Or drop photos of documents here to add them as pages.";
    /// <summary>The page strip's label on a page taken from a photo.</summary>
    public const string Label = "Photo";
    public const string LabelHelp = "Imported from a photo";
    /// <summary>The caption of a page cut out of its photo (<see cref="PageGeometry.Caption"/>).</summary>
    public const string CorrectedCaption = "Corrected from photo";
    /// <summary>The caption of such a page shown as photographed (<see cref="PageCorrections.Caption"/>).</summary>
    public const string OriginalCaption = "As photographed";
    public const string EditorTitle = "Check the page's corners";
    public const string EditorHelp =
        "Drag each corner onto a corner of the page. Arrow keys move the selected corner, Shift takes bigger steps, and keys 1 to 4 select a corner.";
    public const string UseCornersLabel = "Use these corners";
    public const string WholePhotoLabel = "Use whole photo";
    public const string SkipLabel = "Skip this photo";
    public const string NotOfferedMessage =
        "Photos of documents are added to the page queue: choose Document mode, or a document task, to import them.";
    public const string NoPhotosMessage =
        "None of those files is a photo that can be imported (JPEG, PNG, HEIC, TIFF, BMP or WebP).";
    /// <summary>Why a file that is no picture (or a damaged one) was not imported (<see cref="UnreadableMessage"/>).</summary>
    public const string UnreadableDetail = "it is not a picture this app can read, or the file is damaged.";
    /// <summary>Why a photo of more than <see cref="MaxPhotoPixels"/> was not imported.</summary>
    public const string TooLargeDetail = "the photo is too large (more than 150 megapixels).";
    /// <summary>Why a file that went away before it was read was not imported.</summary>
    public const string MissingDetail = "the file is no longer there.";

    /// <summary><paramref name="path"/> names a file of a type offered for import (by its extension).</summary>
    public static bool IsPhotoFile(string path) => FileExtensions.Contains(ExtensionOf(path));

    /// <summary><paramref name="path"/> names a HEIF file (.heic, .heif, .hif).</summary>
    public static bool IsHeif(string path) => HeifExtensions.Contains(ExtensionOf(path));

    /// <summary>The photo files among <paramref name="paths"/> (files dropped, say), in their order, each once.</summary>
    public static IReadOnlyList<string> PhotoFiles(IEnumerable<string> paths)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return paths.Where(p => IsPhotoFile(p) && seen.Add(p)).ToList();
    }

    /// <summary>Whether photos can be imported with these settings: the document queue collects them.</summary>
    public static bool IsOffered(ScanSettings settings) => TaskCatalog.FlowOf(settings) == TaskFlowKind.DocumentQueue;

    /// <summary>The photo the right way up: <paramref name="stored"/> mirrored and turned as <paramref name="orientation"/> says.</summary>
    public static RgbaImage Oriented(RgbaImage stored, PhotoOrientation orientation)
    {
        var image = orientation.Mirrored ? MirroredLeftToRight(stored) : stored;
        return orientation.QuarterTurns % 4 == 0 ? image : image.RotatedQuarterTurns(orientation.QuarterTurns);
    }

    /// <summary>What to do with <paramref name="photo"/> (upright): the page looked for, then <see cref="Plan(PhotoDocumentDetection, int, int)"/>.</summary>
    public static PhotoImportPlan Plan(RgbaImage photo) =>
        Plan(PhotoDocumentDetector.Detect(photo), photo.Width, photo.Height);

    /// <summary>
    /// What to do with a photo of <paramref name="width"/> × <paramref name="height"/> where the page
    /// search found <paramref name="detection"/>: a page found with at least <see cref="SureConfidence"/>
    /// (and that can be corrected) is corrected; anything else is shown in the corner editor, starting
    /// from the page found, else the best outline seen (kept within the photo), else a rectangle
    /// <see cref="StartInset"/> in from the photo's edges.
    /// </summary>
    public static PhotoImportPlan Plan(PhotoDocumentDetection detection, int width, int height)
    {
        if (detection.Quad is { } quad)
        {
            bool sure = detection.Confidence >= SureConfidence && PerspectiveCorrector.Plan(quad, width, height) is not null;
            return sure
                ? new PhotoImportPlan(PhotoImportAction.Correct, quad, PhotoReviewReason.None, detection)
                : new PhotoImportPlan(PhotoImportAction.Review, ClampedToPhoto(quad, width, height), PhotoReviewReason.Unsure, detection);
        }
        var reason = detection.Rejection switch
        {
            PhotoDocumentRejection.CutOff => PhotoReviewReason.CutOff,
            PhotoDocumentRejection.Ambiguous => PhotoReviewReason.TwoPages,
            PhotoDocumentRejection.LowConfidence => PhotoReviewReason.Unsure,
            _ => PhotoReviewReason.NothingFound,
        };
        var start = detection.Candidate is { } candidate ? ClampedToPhoto(candidate, width, height) : StartCorners(width, height);
        return new PhotoImportPlan(PhotoImportAction.Review, start, reason, detection);
    }

    /// <summary>The corners of the whole photo.</summary>
    public static Quad WholePhoto(int width, int height) =>
        new(new PointD(0, 0), new PointD(width, 0), new PointD(width, height), new PointD(0, height));

    /// <summary>The editor's start when nothing was found: a rectangle <see cref="StartInset"/> of the photo in from each edge.</summary>
    public static Quad StartCorners(int width, int height)
    {
        double dx = width * StartInset, dy = height * StartInset;
        return new Quad(new PointD(dx, dy), new PointD(width - dx, dy), new PointD(width - dx, height - dy), new PointD(dx, height - dy));
    }

    /// <summary>
    /// <paramref name="quad"/> with every corner moved into the photo (the editor's handles stay where
    /// they can be seen and dragged); <see cref="StartCorners"/> when that leaves no usable outline.
    /// </summary>
    public static Quad ClampedToPhoto(Quad quad, int width, int height)
    {
        var c = quad.Corners.Select(p => Clamp(p, width, height)).ToArray();
        var clamped = new Quad(c[0], c[1], c[2], c[3]);
        return CanUseCorners(clamped) ? clamped : StartCorners(width, height);
    }

    /// <summary>
    /// The corners the editor can cut a page out along: running clockwise around a convex outline,
    /// every edge at least <see cref="MinEdgePixels"/> long.
    /// </summary>
    public static bool CanUseCorners(Quad quad)
    {
        if (!quad.IsConvex) return false;
        for (int i = 0; i < 4; i++)
        {
            if (!(quad.EdgeLength(i) >= MinEdgePixels)) return false;
        }
        return true;
    }

    /// <summary>
    /// <paramref name="quad"/> with corner <paramref name="index"/> (0 top-left … 3 bottom-left, as
    /// placed) moved to <paramref name="to"/>, kept within the photo; the quad as it was when the move
    /// would leave corners the page cannot be cut out along (<see cref="CanUseCorners"/>). The corners
    /// keep their places in the quad while they are dragged; <see cref="Quad.FromCorners"/> names them
    /// again when the page is cut out.
    /// </summary>
    public static Quad MovedCorner(Quad quad, int index, PointD to, int width, int height)
    {
        var corners = quad.Corners;
        corners[index & 3] = Clamp(to, width, height);
        var moved = new Quad(corners[0], corners[1], corners[2], corners[3]);
        return CanUseCorners(moved) ? moved : quad;
    }

    /// <summary>
    /// The resolution of a page from a photo: <paramref name="dpi"/> (from the paper size its shape
    /// matched, <see cref="PerspectivePlan.Dpi"/>) rounded and kept within <see cref="MinDpi"/> to
    /// <see cref="MaxDpi"/>; <see cref="NominalDpi"/> when the size is not known.
    /// </summary>
    public static int PageDpi(double? dpi) =>
        dpi is { } d && double.IsFinite(d) && d > 0
            ? Math.Clamp((int)Math.Floor(d + 0.5), MinDpi, MaxDpi)
            : NominalDpi;

    /// <summary>The resolution of a whole photo taken as the page: from a paper size its shape matches, else <see cref="NominalDpi"/>.</summary>
    public static int WholePhotoDpi(int width, int height)
    {
        if (width <= 0 || height <= 0) return NominalDpi;
        double longSide = Math.Max(width, height), shortSide = Math.Min(width, height);
        if (PerspectiveCorrector.MatchPaper(longSide / shortSide) is not { } paper
            || PaperSizes.Inches(paper.Size) is not { } inches)
        {
            return NominalDpi;
        }
        return PageDpi(longSide / Math.Max(inches.Width, inches.Height));
    }

    /// <summary>
    /// The page cut out of <paramref name="photo"/> along <paramref name="corners"/> (named again with
    /// <see cref="Quad.FromCorners"/>), its perspective corrected, at <see cref="PageDpi"/>: a color
    /// page from a photo (<see cref="PageSource.Photo"/>) whose other version is the photo as it was
    /// (<see cref="ScannedPage.WithGeometry"/>, <see cref="GeometryBasis.Perspective"/>). Null when the
    /// corners outline no page.
    /// </summary>
    public static ScannedPage? CorrectedPage(RgbaImage photo, Quad corners, DateTime? createdAt = null)
    {
        var named = Quad.FromCorners(corners.Corners);
        if (PerspectiveCorrector.Correct(photo, named) is not { } corrected) return null;
        var page = new ScannedPage(photo, PageDpi(corrected.Plan.Dpi), ColorMode.Color, createdAt: createdAt)
        {
            Source = PageSource.Photo,
        };
        return page.WithGeometry(corrected.Image, new PageGeometry(true, 0, GeometryBasis.Perspective));
    }

    /// <summary>The whole photo as the page (<see cref="WholePhotoDpi"/>), labelled as a photo, with no other version.</summary>
    public static ScannedPage WholePhotoPage(RgbaImage photo, DateTime? createdAt = null) =>
        new(photo, WholePhotoDpi(photo.Width, photo.Height), ColorMode.Color, createdAt: createdAt)
        {
            Source = PageSource.Photo,
        };

    /// <summary>"Photo" for a page taken from a photo, "From phone" for one a paired phone sent; null for other pages.</summary>
    public static string? SourceLabel(ScannedPage page) => page.Source switch
    {
        PageSource.Photo => Label,
        PageSource.Phone => CompanionProtocol.PageLabel,
        _ => null,
    };

    /// <summary>The source label's tooltip: where a photo's or a phone's page came from; null for other pages.</summary>
    public static string? SourceHelp(ScannedPage page) => page.Source switch
    {
        PageSource.Photo => LabelHelp,
        PageSource.Phone => CompanionProtocol.PageLabelHelp,
        _ => null,
    };

    /// <summary>The corner editor's note on why it is shown; empty for <see cref="PhotoReviewReason.None"/>.</summary>
    public static string ReasonText(PhotoReviewReason reason) => reason switch
    {
        PhotoReviewReason.Unsure => "The page's edges are hard to make out. Check that each corner sits on a corner of the page.",
        PhotoReviewReason.CutOff => "The page seems to run off the edge of the photo. Move the corners onto the page, or use the whole photo.",
        PhotoReviewReason.TwoPages => "There seem to be two pages in the photo. Put the corners on the one to add.",
        PhotoReviewReason.NothingFound => "No page was found in the photo. Drag the corners onto the page's corners, or use the whole photo.",
        _ => "",
    };

    /// <summary>The corner editor's caption: "Photo 2 of 5: IMG_0042.jpg", or the file name alone for one photo.</summary>
    public static string Counter(int number, int count, string fileName) =>
        count > 1 ? $"Photo {number} of {count}: {fileName}" : fileName;

    /// <summary>"Importing photo 2 of 5…", or "Importing photo…" for one.</summary>
    public static string ProgressMessage(int number, int count) =>
        count > 1 ? $"Importing photo {number} of {count}…" : "Importing photo…";

    /// <summary>
    /// The progress while page <paramref name="page"/> of a file of <paramref name="pageCount"/> pages
    /// (a TIFF of several pages) is imported: "Importing photo 2 of 5, page 3 of 7…", or "Importing
    /// page 3 of 7…" for one file; <see cref="ProgressMessage(int, int)"/> for a file of one page.
    /// </summary>
    public static string ProgressMessage(int number, int count, int page, int pageCount)
    {
        if (pageCount <= 1) return ProgressMessage(number, count);
        return count > 1
            ? $"Importing photo {number} of {count}, page {page} of {pageCount}…"
            : $"Importing page {page} of {pageCount}…";
    }

    /// <summary>
    /// The name of page <paramref name="page"/> of a file of <paramref name="pageCount"/> pages, for the
    /// corner editor and the error messages: "fax.tif, page 2 of 5", or the file name alone for one page.
    /// </summary>
    public static string PageName(string fileName, int page, int pageCount) =>
        pageCount > 1 ? $"{fileName}, page {page} of {pageCount}" : fileName;

    /// <summary>
    /// The status after an import: "Added 3 pages from photos — 5 in queue. Scan more or save PDF."
    /// (or "No pages were added."), then " 1 photo was skipped." and " 2 photos could not be opened."
    /// when that happened.
    /// </summary>
    public static string AddedMessage(int added, int skipped, int failed, int queueCount, string saveTitle)
    {
        string text = added > 0
            ? $"Added {added} page{(added == 1 ? "" : "s")} from photos — {queueCount} in queue. Scan more or {saveTitle}."
            : "No pages were added.";
        if (skipped > 0) text += $" {skipped} photo{(skipped == 1 ? " was" : "s were")} skipped.";
        if (failed > 0) text += $" {failed} photo{(failed == 1 ? "" : "s")} could not be opened.";
        return text;
    }

    /// <summary>The status after an import was cancelled: "Cancelled." or "Cancelled after adding 2 pages from photos — 4 in queue."</summary>
    public static string CancelledMessage(int added, int queueCount) =>
        added == 0
            ? "Cancelled."
            : $"Cancelled after adding {added} page{(added == 1 ? "" : "s")} from photos — {queueCount} in queue.";

    /// <summary>"IMG_0042.jpg could not be opened: …".</summary>
    public static string UnreadableMessage(string fileName, string detail) => $"{fileName} could not be opened: {detail}";

    /// <summary>
    /// A HEIF photo Windows could not read: most often the HEIF extension (or the HEVC one) is missing,
    /// else the file is damaged (the Mac reads HEIF itself).
    /// </summary>
    public static string HeifUnavailableMessage(string fileName) =>
        $"{fileName} could not be opened: HEIC photos need the free “HEIF Image Extensions” from the Microsoft Store " +
        "(most iPhone photos also need “HEVC Video Extensions”). If they are installed, the photo may be damaged; " +
        "a phone set to save photos as JPEG avoids this.";

    /// <summary>The lowercase extension of <paramref name="path"/>, without the dot.</summary>
    private static string ExtensionOf(string path)
    {
        int slash = Math.Max(path.LastIndexOf('/'), path.LastIndexOf('\\'));
        int dot = path.LastIndexOf('.');
        return dot > slash && dot < path.Length - 1 ? path[(dot + 1)..].ToLowerInvariant() : "";
    }

    private static PointD Clamp(PointD p, double width, double height) =>
        new(Math.Clamp(p.X, 0, width), Math.Clamp(p.Y, 0, height));

    /// <summary>The image mirrored left to right.</summary>
    private static RgbaImage MirroredLeftToRight(RgbaImage image)
    {
        int w = image.Width, h = image.Height;
        var output = new byte[image.Pixels.Length];
        for (int y = 0; y < h; y++)
        {
            int row = y * w * 4;
            for (int x = 0; x < w; x++)
            {
                Array.Copy(image.Pixels, row + x * 4, output, row + (w - 1 - x) * 4, 4);
            }
        }
        return new RgbaImage(w, h, output);
    }
}
