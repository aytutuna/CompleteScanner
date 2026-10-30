namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/CaptureScale.swift: the same sizes, rules and arithmetic
// (+ − × ÷ and square roots on doubles in the same order, rounding with floor(x + 0.5)).

/// <summary>
/// What a camera shot shows: it decides the sizes a page can snap to (<see cref="CaptureScale.Candidates"/>)
/// and the shapes several objects in one shot are picked by (<see cref="MultiQuadPicker"/>). Stored by
/// its camelCase name ("document", "receipt", "photo", "idCard"); the first is the default and the
/// fallback for a name a newer version adds.
/// </summary>
public enum CaptureKind
{
    /// <summary>A page of a document: A4, Letter, Legal or an ID card.</summary>
    Document,
    /// <summary>A till receipt: 80 or 57 mm wide, any length.</summary>
    Receipt,
    /// <summary>A printed photo: 4 × 6, 5 × 7 or 3.5 × 5 in (10 × 15 cm has 4 × 6 in's shape and is reported as 4 × 6 in).</summary>
    Photo,
    /// <summary>An ID-1 card (85.6 × 54 mm).</summary>
    IdCard,
}

/// <summary>
/// Where a captured page's real size comes from. Stored by its camelCase name ("nominal", "paper",
/// "receiptWidth", "photoSize"); the first is the default and the fallback.
/// </summary>
public enum CaptureScaleBasis
{
    /// <summary>No known size matched: the page is taken at <see cref="CaptureScale.NominalDpi"/>, so its size is made up.</summary>
    Nominal,
    /// <summary>A paper size (<see cref="PaperSize"/>), the ID-1 card included.</summary>
    Paper,
    /// <summary>A receipt roll's width; the length is the page's own.</summary>
    ReceiptWidth,
    /// <summary>A photo print size.</summary>
    PhotoSize,
}

/// <summary>A size a captured page can snap to.</summary>
/// <param name="Id">Its stable name ("a4", "idCard", "receipt80mm", "photo4x6in"), stored with the page.</param>
/// <param name="Basis">What kind of size it is.</param>
/// <param name="ShortInches">The short side, in inches.</param>
/// <param name="LongInches">The long side, in inches; null for a receipt, whose length is free.</param>
/// <param name="Paper">The paper size it is, for <see cref="CaptureScaleBasis.Paper"/>.</param>
public sealed record CaptureSize(string Id, CaptureScaleBasis Basis, double ShortInches, double? LongInches, PaperSize? Paper = null)
{
    /// <summary>The long side over the short side; null for a free length.</summary>
    public double? LongOverShort => LongInches is { } longInches ? longInches / ShortInches : null;
}

/// <summary>
/// A captured page's real size (<see cref="CaptureScale.Measure(Quad, int, int, CaptureKind, double?)"/>):
/// what it snapped to, the resolution, and the pixel size the page is made at.
/// </summary>
/// <param name="Basis">Where the size comes from.</param>
/// <param name="Size">The <see cref="CaptureSize.Id"/> snapped to; null for <see cref="CaptureScaleBasis.Nominal"/>.</param>
/// <param name="Dpi">Pixels per inch of the page.</param>
/// <param name="PixelWidth">The page's width in pixels.</param>
/// <param name="PixelHeight">The page's height in pixels.</param>
/// <param name="WidthInches">The page's real width (the size's own when it snapped, else pixels over <see cref="Dpi"/>).</param>
/// <param name="HeightInches">The page's real height.</param>
public sealed record CaptureScaleResult(CaptureScaleBasis Basis, string? Size, int Dpi, int PixelWidth, int PixelHeight,
                                        double WidthInches, double HeightInches)
{
    /// <summary>The page snapped to a known size, so it can be printed or measured at real size.</summary>
    public bool IsRealSize => Basis != CaptureScaleBasis.Nominal;

    /// <summary>The paper size it snapped to, for <see cref="CaptureScaleBasis.Paper"/>; null otherwise.</summary>
    public PaperSize? Paper => CaptureScale.Find(Size)?.Paper;
}

/// <summary>
/// What the camera recorded about a page (<see cref="ScannedPage.Capture"/>): the page's corners in the
/// photo as it was taken, that photo's size, what the shot showed, the camera's focal length when
/// known, and, once the page was cut out (<see cref="PerspectiveStep"/>), the real size it snapped to.
/// </summary>
/// <param name="Quad">The page's corners in the photo's continuous pixels (<see cref="SourceWidth"/> × <see cref="SourceHeight"/>, before any turn).</param>
/// <param name="SourceWidth">The photo's width in pixels.</param>
/// <param name="SourceHeight">The photo's height in pixels.</param>
public sealed record CaptureFacts(Quad Quad, int SourceWidth, int SourceHeight)
{
    /// <summary>What the shot showed.</summary>
    public CaptureKind Kind { get; init; } = CaptureKind.Document;

    /// <summary>The camera's focal length in pixels of the photo (<see cref="CaptureScale.FocalLengthPixels"/>); null when not known.</summary>
    public double? FocalLength { get; init; }

    /// <summary>The real size the page snapped to when it was cut out; null until then.</summary>
    public CaptureScaleResult? Scale { get; init; }

    /// <summary>How the page was cleaned up once cut out (<see cref="EnhanceStep"/>, <see cref="DocumentEnhancer"/>; auto resolved); null until then. Kept in memory only.</summary>
    public DocumentEnhanceMode? Enhancement { get; init; }

    /// <summary>The filter the page was given once cut out (<see cref="EnhanceStep"/>); null until then, and for a photo or a card. Kept in memory only.</summary>
    public CaptureFilter? Filter { get; init; }

    /// <summary>
    /// These facts for the photo mirrored and turned as <paramref name="orientation"/> says (mirrored left
    /// to right first, then turned clockwise, as <see cref="PhotoImport.Oriented"/> turns its pixels): each
    /// corner moves with its pixel, (x, y) to (W − x, y) when mirrored and to (H − y, x) for each quarter
    /// turn of a W × H photo, and the corners are named again (<see cref="Quad.FromCorners"/>); the photo's
    /// size swaps with an odd turn; the kind, the focal length (a turn keeps the scale) and the real size
    /// stay. An upright orientation returns the facts as they are.
    /// </summary>
    public CaptureFacts Oriented(PhotoOrientation orientation)
    {
        int turns = ((orientation.QuarterTurns % 4) + 4) % 4;
        if (turns == 0 && !orientation.Mirrored) return this;
        var corners = Quad.Corners;
        var moved = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            double x = corners[i].X, y = corners[i].Y;
            if (orientation.Mirrored) x = SourceWidth - x;
            int height = SourceHeight, width = SourceWidth;
            for (int t = 0; t < turns; t++)
            {
                double turnedX = height - y;
                y = x;
                x = turnedX;
                (width, height) = (height, width);
            }
            moved[i] = new PointD(x, y);
        }
        bool swaps = turns % 2 == 1;
        return this with
        {
            Quad = Quad.FromCorners(moved),
            SourceWidth = swaps ? SourceHeight : SourceWidth,
            SourceHeight = swaps ? SourceWidth : SourceHeight,
        };
    }

    /// <summary>
    /// These facts for the photo resized to <paramref name="width"/> × <paramref name="height"/> pixels:
    /// the corners scaled with it, the focal length by the geometric mean of the two scales
    /// (√(sx · sy), the scale itself when the photo keeps its shape), and the kind and real size kept.
    /// The same size, facts without a photo size, or a size of no pixels return the facts as they are.
    /// </summary>
    public CaptureFacts ScaledTo(int width, int height)
    {
        if (SourceWidth <= 0 || SourceHeight <= 0 || width <= 0 || height <= 0) return this;
        if (width == SourceWidth && height == SourceHeight) return this;
        double sx = (double)width / SourceWidth, sy = (double)height / SourceHeight;
        double? focalLength = FocalLength is { } f ? f * Math.Sqrt(sx * sy) : null;
        return this with { Quad = Quad.Scaled(sx, sy), SourceWidth = width, SourceHeight = height, FocalLength = focalLength };
    }

    /// <summary>
    /// Whether a photo of <paramref name="width"/> × <paramref name="height"/> pixels is the photo these
    /// facts were taken on, perhaps resized: the same shape to within the rounding of a resize
    /// (|width · SourceHeight − height · SourceWidth| at most the longer source side). A photo turned a
    /// quarter since is not, unless it is nearly square, where its shape cannot tell: whoever turns a
    /// photo turns its facts with it (<see cref="Oriented"/>).
    /// </summary>
    public bool DescribesPhoto(int width, int height)
    {
        if (SourceWidth <= 0 || SourceHeight <= 0 || width <= 0 || height <= 0) return false;
        long difference = Math.Abs((long)width * SourceHeight - (long)height * SourceWidth);
        return difference <= Math.Max(SourceWidth, SourceHeight);
    }
}

/// <summary>
/// The real size of a page taken by a camera, which has no scale of its own: the page's true shape
/// (<see cref="PerspectiveCorrector.EstimateAspect(Quad, double, double, double)"/> with the camera's
/// focal length when known, else as the quad shows it) is matched against known sizes
/// (<see cref="Candidates"/>) within <see cref="Tolerance"/>, the nearest winning (the first on a tie).
/// A match fixes the resolution: the whole number of pixels per inch the camera resolved along the
/// page's long side (its short side for a receipt), at most <see cref="MaxDpi"/>, and the page is
/// made at that size: never larger than the photo shows it, so nothing is upsampled. A page that
/// matches nothing keeps its pixels at <see cref="NominalDpi"/>, and its size is made up
/// (<see cref="CaptureScaleResult.IsRealSize"/> is false), so real-size printing must fit it to the
/// paper instead.
/// </summary>
public static class CaptureScale
{
    /// <summary>A shape matches a size when the long-over-short ratios differ by at most this share (3 %).</summary>
    public const double Tolerance = PerspectiveCorrector.PaperAspectTolerance;
    /// <summary>The resolution of a page that matches no known size.</summary>
    public const int NominalDpi = 200;
    /// <summary>A snapped page is made at no more than this resolution (a close-up of a card is made smaller).</summary>
    public const int MaxDpi = 1200;
    /// <summary>The diagonal of a 36 × 24 mm frame, which "35 mm equivalent" focal lengths refer to.</summary>
    public const double FullFrameDiagonalMm = 43.266615305567875;

    private const double MmPerInch = 25.4;

    /// <summary>The paper sizes a document page snaps to (<see cref="PerspectiveCorrector.MatchedSizes"/>: A4 stands for every √2 sheet).</summary>
    public static IReadOnlyList<CaptureSize> Papers { get; } = MakePaperSizes();

    /// <summary>The receipt widths, 80 mm first (the most common roll: two widths cannot be told apart by shape).</summary>
    public static IReadOnlyList<CaptureSize> ReceiptWidths { get; } =
    [
        new("receipt80mm", CaptureScaleBasis.ReceiptWidth, 80 / MmPerInch, null),
        new("receipt57mm", CaptureScaleBasis.ReceiptWidth, 57 / MmPerInch, null),
    ];

    /// <summary>The photo print sizes (10 × 15 cm has 4 × 6 in's shape, so it is taken only when listed first).</summary>
    public static IReadOnlyList<CaptureSize> PhotoSizes { get; } =
    [
        new("photo4x6in", CaptureScaleBasis.PhotoSize, 4, 6),
        new("photo5x7in", CaptureScaleBasis.PhotoSize, 5, 7),
        new("photo3.5x5in", CaptureScaleBasis.PhotoSize, 3.5, 5),
        new("photo10x15cm", CaptureScaleBasis.PhotoSize, 100 / MmPerInch, 150 / MmPerInch),
    ];

    /// <summary>The sizes a page of <paramref name="kind"/> snaps to.</summary>
    public static IReadOnlyList<CaptureSize> Candidates(CaptureKind kind) => kind switch
    {
        CaptureKind.Receipt => ReceiptWidths,
        CaptureKind.Photo => PhotoSizes,
        CaptureKind.IdCard => [IdCard],
        _ => Papers,
    };

    /// <summary>The ID-1 card.</summary>
    public static CaptureSize IdCard => Papers.First(size => size.Paper == PaperSize.IdCard);

    /// <summary>The size named <paramref name="id"/> among every list here; null for none.</summary>
    public static CaptureSize? Find(string? id)
    {
        if (id is null) return null;
        foreach (var list in new[] { Papers, ReceiptWidths, PhotoSizes })
        {
            foreach (var size in list)
            {
                if (size.Id == id) return size;
            }
        }
        return null;
    }

    /// <summary>
    /// The focal length in pixels of a <paramref name="width"/> × <paramref name="height"/> photo whose
    /// "35 mm equivalent" focal length (EXIF FocalLenIn35mmFilm) is <paramref name="focalLength35mm"/>;
    /// null when either is not a positive number.
    /// </summary>
    public static double? FocalLengthPixels(double focalLength35mm, int width, int height)
    {
        if (!(focalLength35mm > 0) || !double.IsFinite(focalLength35mm) || width <= 0 || height <= 0) return null;
        double diagonal = Math.Sqrt((double)width * width + (double)height * height);
        return focalLength35mm * diagonal / FullFrameDiagonalMm;
    }

    /// <summary>
    /// The true shape of the page <paramref name="quad"/> outlines: from the camera's
    /// <paramref name="focalLength"/> (pixels) when known, else as <see cref="PerspectiveCorrector.EstimateAspect(Quad, double, double)"/> works it out.
    /// </summary>
    public static AspectEstimate Aspect(Quad quad, int imageWidth, int imageHeight, double? focalLength = null) =>
        focalLength is { } f
            ? PerspectiveCorrector.EstimateAspect(quad, imageWidth, imageHeight, f)
            : PerspectiveCorrector.EstimateAspect(quad, imageWidth, imageHeight);

    /// <summary>
    /// The size among <paramref name="candidates"/> a shape of <paramref name="longOverShort"/> snaps to:
    /// the fixed size whose ratio is nearest, within <paramref name="tolerance"/> of it (as a share of the
    /// size's ratio; the first on a tie); else the first free-length size (a receipt width), which any
    /// shape fits; null when none fits.
    /// </summary>
    public static CaptureSize? Match(double longOverShort, IReadOnlyList<CaptureSize> candidates, double tolerance = Tolerance)
    {
        if (!(longOverShort >= 1) || !double.IsFinite(longOverShort)) return null;
        CaptureSize? best = null;
        double bestDiff = double.MaxValue;
        CaptureSize? free = null;
        foreach (var size in candidates)
        {
            if (size.LongOverShort is not { } ratio)
            {
                free ??= size;
                continue;
            }
            double diff = Math.Abs(longOverShort - ratio) / ratio;
            if (diff <= tolerance && diff < bestDiff)
            {
                bestDiff = diff;
                best = size;
            }
        }
        return best ?? free;
    }

    /// <summary>
    /// The real size of the page <paramref name="quad"/> outlines in a <paramref name="imageWidth"/> ×
    /// <paramref name="imageHeight"/> photo, among the sizes for <paramref name="kind"/>.
    /// </summary>
    public static CaptureScaleResult Measure(Quad quad, int imageWidth, int imageHeight, CaptureKind kind, double? focalLength = null) =>
        Measure(quad, imageWidth, imageHeight, Candidates(kind), focalLength);

    /// <summary>
    /// The real size of the page <paramref name="quad"/> outlines, among <paramref name="candidates"/>:
    /// its shape (<see cref="Aspect"/>) and the pixels the camera resolved along its long side (the
    /// longer of each pair of opposite edges, kept within <see cref="PerspectiveCorrector.MaxPhotoDiagonals"/>
    /// of the photo's diagonal and <see cref="PerspectiveCorrector.MaxOutputSide"/>), then <see cref="Snap"/>.
    /// </summary>
    public static CaptureScaleResult Measure(Quad quad, int imageWidth, int imageHeight, IReadOnlyList<CaptureSize> candidates,
                                             double? focalLength = null)
    {
        var estimate = Aspect(quad, imageWidth, imageHeight, focalLength);
        double w0 = Math.Max(quad.EdgeLength(0), quad.EdgeLength(2));
        double h0 = Math.Max(quad.EdgeLength(1), quad.EdgeLength(3));
        double longSide = Math.Max(w0, h0);
        double photoDiagonal = Math.Sqrt((double)imageWidth * imageWidth + (double)imageHeight * imageHeight);
        longSide = Math.Min(longSide, Math.Min(PerspectiveCorrector.MaxPhotoDiagonals * photoDiagonal, PerspectiveCorrector.MaxOutputSide));
        return Snap(estimate.WidthOverHeight, longSide, candidates);
    }

    /// <summary>
    /// The real size of a page of shape <paramref name="widthOverHeight"/> whose long side the camera
    /// resolved in <paramref name="longSidePixels"/> pixels, among <paramref name="candidates"/>
    /// (<see cref="Match"/>). Snapped to a fixed size: the resolution is the whole number of pixels per
    /// inch along the long side, 1 to <see cref="MaxDpi"/>, and the page is the size's inches at that
    /// resolution. Snapped to a receipt width: the same along the short side, the length the page's own.
    /// Nothing matched: <see cref="NominalDpi"/>, the page keeps its pixels. Landscape when the shape is
    /// at least 1.
    /// </summary>
    public static CaptureScaleResult Snap(double widthOverHeight, double longSidePixels, IReadOnlyList<CaptureSize> candidates)
    {
        double aspect = widthOverHeight > 0 && double.IsFinite(widthOverHeight) ? widthOverHeight : 1;
        bool landscape = aspect >= 1;
        double longOverShort = landscape ? aspect : 1 / aspect;
        double longSide = longSidePixels > 1 && double.IsFinite(longSidePixels) ? longSidePixels : 1;
        var size = Match(longOverShort, candidates);
        if (size is null)
        {
            int longPx = Math.Max(1, RoundHalfUp(longSide));
            int shortPx = Math.Max(1, RoundHalfUp(longSide / longOverShort));
            return Oriented(CaptureScaleBasis.Nominal, null, NominalDpi, longPx, shortPx,
                            (double)longPx / NominalDpi, (double)shortPx / NominalDpi, landscape);
        }
        double shortInches = size.ShortInches;
        double longInches;
        double dpiExact;
        if (size.LongInches is { } fixedLong)
        {
            longInches = fixedLong;
            dpiExact = longSide / fixedLong;
        }
        else
        {
            longInches = shortInches * longOverShort;
            dpiExact = longSide / longOverShort / shortInches;
        }
        int dpi = (int)Math.Max(1, Math.Min(MaxDpi, Math.Floor(dpiExact)));
        int longPixels = Math.Max(1, RoundHalfUp(longInches * dpi));
        int shortPixels = Math.Max(1, RoundHalfUp(shortInches * dpi));
        return Oriented(size.Basis, size.Id, dpi, longPixels, shortPixels, longInches, shortInches, landscape);
    }

    /// <summary>
    /// The real size of a page already upright at <paramref name="pixelWidth"/> × <paramref name="pixelHeight"/>
    /// (Apple's document scanner gives no corners): its shape matched as <see cref="Snap"/> does, the
    /// resolution the nearest whole number of pixels per inch of the size (the pixels are kept, so it
    /// is not limited to <see cref="MaxDpi"/>); <see cref="NominalDpi"/> when nothing matches.
    /// </summary>
    public static CaptureScaleResult FromAspect(int pixelWidth, int pixelHeight, CaptureKind kind)
    {
        int w = Math.Max(1, pixelWidth), h = Math.Max(1, pixelHeight);
        bool landscape = w >= h;
        double longPx = Math.Max(w, h), shortPx = Math.Min(w, h);
        double longOverShort = longPx / shortPx;
        var size = Match(longOverShort, Candidates(kind));
        if (size is null)
        {
            return new CaptureScaleResult(CaptureScaleBasis.Nominal, null, NominalDpi, w, h, (double)w / NominalDpi, (double)h / NominalDpi);
        }
        double shortInches = size.ShortInches;
        double longInches = size.LongInches ?? shortInches * longOverShort;
        int dpi = Math.Max(1, RoundHalfUp(size.LongInches is { } fixedLong ? longPx / fixedLong : shortPx / shortInches));
        return new CaptureScaleResult(size.Basis, size.Id, dpi, w, h, landscape ? longInches : shortInches, landscape ? shortInches : longInches);
    }

    private static CaptureScaleResult Oriented(CaptureScaleBasis basis, string? id, int dpi, int longPixels, int shortPixels,
                                               double longInches, double shortInches, bool landscape) =>
        landscape
            ? new CaptureScaleResult(basis, id, dpi, longPixels, shortPixels, longInches, shortInches)
            : new CaptureScaleResult(basis, id, dpi, shortPixels, longPixels, shortInches, longInches);

    private static int RoundHalfUp(double value) => (int)Math.Floor(value + 0.5);

    private static IReadOnlyList<CaptureSize> MakePaperSizes()
    {
        var sizes = new List<CaptureSize>();
        foreach (var paper in PerspectiveCorrector.MatchedSizes)
        {
            if (PaperSizes.Inches(paper) is not { } inches) continue;
            double shortSide = Math.Min(inches.Width, inches.Height), longSide = Math.Max(inches.Width, inches.Height);
            sizes.Add(new CaptureSize(paper.RawValue(), CaptureScaleBasis.Paper, shortSide, longSide, paper));
        }
        return sizes;
    }
}
