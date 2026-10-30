namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/DocumentGeometry.swift: same constants, same steps.

/// <summary>Which way the lines of text on a page run (<see cref="DocumentGeometry.EstimateTextLayout"/>).</summary>
public enum TextAxis
{
    /// <summary>Not enough text, or no clear direction.</summary>
    Unknown,
    /// <summary>Lines run across the page, as on an upright or upside-down page.</summary>
    Horizontal,
    /// <summary>Lines run down the page: the page lies on its side.</summary>
    Vertical,
}

/// <summary>What the lines of text on a page say about how it lies.</summary>
/// <param name="Axis">Which way the lines run.</param>
/// <param name="SkewDegrees">
/// How far the lines are turned, clockwise on screen positive (the <see cref="DetectedPhotoRegion"/>
/// convention): turning the page back by this much straightens them.
/// </param>
/// <param name="Confidence">How much the best angle stands out from the others ((best − mean) / mean of the sweep).</param>
/// <param name="InkPoints">The ink pixels measured.</param>
public sealed record TextLayout(TextAxis Axis, double SkewDegrees, double Confidence, int InkPoints)
{
    /// <summary>Clear enough to straighten the page by: a direction, enough ink, a clear best angle.</summary>
    public bool IsConfident =>
        Axis != TextAxis.Unknown
        && InkPoints >= DocumentGeometry.MinInkPoints
        && Confidence >= DocumentGeometry.MinConfidence;

    public static TextLayout Nothing { get; } = new(TextAxis.Unknown, 0, 0, 0);
}

/// <summary>What told the page's angle.</summary>
public enum GeometryBasis
{
    /// <summary>The edges of the sheet against the scanner's background.</summary>
    PageEdges,
    /// <summary>The lines of text on the page.</summary>
    TextLines,
    /// <summary>
    /// The page's four corners in a photo of it (<see cref="PhotoImport"/>): the page was cut out and
    /// its perspective corrected (<see cref="PerspectiveCorrector"/>).
    /// </summary>
    Perspective,
}

/// <summary>How a page is changed (<see cref="GeometryPlan"/>).</summary>
public enum GeometryAction
{
    /// <summary>The sheet is cut out and turned upright.</summary>
    CropStraightened,
    /// <summary>The sheet is cut out along the rectangle around it, not turned.</summary>
    CropBox,
    /// <summary>The whole scan is turned about its center, on a canvas big enough to lose nothing.</summary>
    Rotate,
}

/// <summary>
/// What crop and straighten did to a page, for the page strip and for undoing it. Not stored in
/// settings files.
/// </summary>
/// <param name="Cropped">The page was cut out of the scanner's background.</param>
/// <param name="AngleDegrees">The turn taken out, clockwise positive; 0 when the page was not turned.</param>
/// <param name="Basis">What the angle (or the crop) was found from.</param>
public sealed record PageGeometry(bool Cropped, double AngleDegrees, GeometryBasis Basis)
{
    /// <summary>
    /// For <see cref="GeometryBasis.Perspective"/>: the corners the page was cut out along, in the
    /// continuous pixels of its other version (the photo) as it was taken, before any turn; null for
    /// other pages and when they are not known.
    /// </summary>
    public Quad? Quad { get; init; }

    /// <summary>The page was turned.</summary>
    public bool Straightened => AngleDegrees != 0;

    /// <summary>"Cropped and straightened 2.4°", "Straightened 1.5°" or "Cropped"; "Corrected from photo" for a page taken from a photo.</summary>
    public string Caption
    {
        get
        {
            if (Basis == GeometryBasis.Perspective) return PhotoImport.CorrectedCaption;
            string angle = DocumentGeometry.AngleText(AngleDegrees);
            if (Cropped && Straightened) return $"Cropped and straightened {angle}";
            return Straightened ? $"Straightened {angle}" : "Cropped";
        }
    }
}

/// <summary>What crop and straighten would do to a page, worked out on its analysis image.</summary>
/// <param name="Action">How the page is changed.</param>
/// <param name="AngleDegrees">The turn taken out (0 for <see cref="GeometryAction.CropBox"/>).</param>
/// <param name="Basis">What the angle or the crop comes from.</param>
/// <param name="Page">The sheet found, in analysis pixels; null when the angle comes from the text alone.</param>
/// <param name="Canvas">
/// <see cref="GeometryAction.Rotate"/> only: the size of the turned scan in analysis pixels, the
/// scan's own size unless turning it in place would cut off something in its corners.
/// </param>
/// <param name="Text">The text measurement, when one was made.</param>
public sealed record GeometryPlan(GeometryAction Action, double AngleDegrees, GeometryBasis Basis,
                                  DetectedPhotoRegion? Page, SizeD Canvas, TextLayout? Text)
{
    /// <summary>The facts the page carries once the plan is carried out.</summary>
    public PageGeometry Geometry => new(Action != GeometryAction.Rotate, AngleDegrees, Basis);
}

/// <summary>A page cropped or straightened (<see cref="DocumentGeometry.Correct"/>).</summary>
/// <param name="Image">The new pixels.</param>
/// <param name="Geometry">What was done.</param>
/// <param name="Plan">The plan carried out, in analysis pixels.</param>
/// <param name="Region">The area of the scan taken, in its pixels (for a box crop: the sheet before boxing).</param>
public sealed record GeometryCorrection(RgbaImage Image, PageGeometry Geometry, GeometryPlan Plan, DetectedPhotoRegion Region);

/// <summary>Why no sheet was taken (<see cref="DocumentGeometry.FindPage"/>).</summary>
public enum PageRejection
{
    /// <summary>A sheet was found.</summary>
    None,
    /// <summary>Nothing stands out from the background.</summary>
    NothingFound,
    /// <summary>What stands out is smaller than <see cref="DocumentGeometry.MinPageAreaFraction"/> of the scan.</summary>
    TooSmall,
    /// <summary>It covers more than <see cref="DocumentGeometry.MaxPageAreaFraction"/> of the scan: nothing to crop.</summary>
    FillsScan,
    /// <summary>It does not fill its rectangle, or is too long and thin, to be a sheet.</summary>
    NotRectangular,
    /// <summary>Text-like marks lie around it: it is something on a page, not the page.</summary>
    TextAround,
    /// <summary>Something else of some size lies beside it (another sheet, a photo): cropping would drop it.</summary>
    OtherObjects,
}

/// <summary>What the search for the sheet found.</summary>
/// <param name="Page">The sheet, or null.</param>
/// <param name="Rejection">Why there is none.</param>
/// <param name="Candidate">The largest region's rectangle, taken or not.</param>
/// <param name="AreaFraction">Its share of the scan.</param>
/// <param name="Fill">How much of its rectangle the region fills.</param>
/// <param name="OutsideMarks">Text-like marks found around it (counted only for a candidate of the right size and shape).</param>
/// <param name="TouchesBorder">
/// More than <see cref="DocumentGeometry.MaxBorderContact"/> of the region's outline is the scan's edge,
/// so its edges do not tell its angle.
/// </param>
/// <param name="Hull">The region's convex hull, in analysis pixels (empty when nothing was found).</param>
public sealed record PageSearch(DetectedPhotoRegion? Page, PageRejection Rejection, DetectedPhotoRegion? Candidate,
                                double AreaFraction, double Fill, int OutsideMarks, bool TouchesBorder,
                                IReadOnlyList<PointD> Hull)
{
    public static PageSearch Nothing { get; } = new(null, PageRejection.NothingFound, null, 0, 0, 0, false, []);
}

/// <summary>
/// The limits a sheet is held to when it is looked for (<see cref="DocumentGeometry.FindPage(GrayImage, PageSearchOptions)"/>):
/// <see cref="Default"/> is <see cref="DocumentGeometry"/>'s own constants, for pages of any kind. A
/// task that knows its paper can ask for other limits: receipts (<see cref="ReceiptDetector.PageSearch"/>)
/// are thermal paper barely darker than the lid, often curled, and up to many times as long as wide.
/// </summary>
public sealed record PageSearchOptions
{
    /// <summary>A pixel belongs to something on the glass when it differs from the background by more than this (0...1).</summary>
    public double PageContrast { get; init; } = DocumentGeometry.PageContrast;
    /// <summary>The sheet covers at least this share of the scan.</summary>
    public double MinPageAreaFraction { get; init; } = DocumentGeometry.MinPageAreaFraction;
    /// <summary>The sheet covers at most this share of the scan.</summary>
    public double MaxPageAreaFraction { get; init; } = DocumentGeometry.MaxPageAreaFraction;
    /// <summary>The sheet fills at least this share of the rectangle around it.</summary>
    public double MinPageFill { get; init; } = DocumentGeometry.MinPageFill;
    /// <summary>The sheet's long side is at most this many times its short side.</summary>
    public double MaxPageAspect { get; init; } = DocumentGeometry.MaxPageAspect;

    /// <summary>The limits for pages of any kind: <see cref="DocumentGeometry"/>'s constants.</summary>
    public static PageSearchOptions Default { get; } = new();
}

/// <summary>
/// Crop to the page and straighten it. Works on the page's gray copy at the analysis resolution
/// (<see cref="GrayImage.AnalysisDpi"/>), so the pixel constants below are 100 dpi sizes, and
/// changes the full-resolution pixels once, at the end. Cautious by design: whenever the page edges
/// or the text are unclear the page is left as scanned, a crop never cuts into the sheet, and
/// turning a page never cuts off anything in its corners.
/// <list type="bullet">
/// <item>Page edges (<see cref="DetectPage"/>): the scanner's background is the median of the
/// image's outer ring; what differs from it is the sheet, its edge shadow, or something else lying
/// on the glass. The largest such region, closed and with its holes filled (a white sheet on a
/// white lid shows only by its shadow), is the sheet when it is a filled rectangle of a sensible
/// size and nothing that looks like more of a document, or another sheet or photo, lies outside
/// it.</item>
/// <item>Text lines (<see cref="EstimateTextLayout"/>): projection profiles of the ink, swept
/// over ±<see cref="MaxTextSkewDegrees"/>: the lines of text line up, and the profile is sharpest,
/// at the angle the page is turned.</item>
/// </list>
/// When a sheet is found its edges give the angle; otherwise the text does.
/// </summary>
public static class DocumentGeometry
{
    // MARK: Page edges

    /// <summary>The outer ring of the scan whose median is the scanner's background, as a share of its short side…</summary>
    public const double BorderRingFraction = 0.02;
    /// <summary>…and at most this many inches: the backdrop around a sheet in a feeder or an archive scan can be thin.</summary>
    public const double BorderRingInches = 0.03;
    /// <summary>
    /// The outermost band of the scan, in inches, that a turn in place may cut off whatever it
    /// holds: scanners darken or lighten the very edge of the glass.
    /// </summary>
    public const double ScanEdgeInches = 0.02;
    /// <summary>A pixel belongs to something on the glass when it differs from the background by more than this (0...1).</summary>
    public const double PageContrast = 0.045;
    /// <summary>On a textured backdrop a pixel must differ from it by this many times the backdrop's median absolute deviation.</summary>
    public const double BackdropSpread = 3.7;
    /// <summary>Gaps up to twice this many pixels in the sheet's outline are closed.</summary>
    public const int CloseRadius = 3;
    /// <summary>Strands thinner than about twice this many pixels (a thread, a ruler's edge) are cut from the sheet.</summary>
    public const int OpenRadius = 2;
    /// <summary>The sheet covers at least this share of the scan…</summary>
    public const double MinPageAreaFraction = 0.15;
    /// <summary>…and at most this share: a sheet filling the scan has nothing to crop.</summary>
    public const double MaxPageAreaFraction = 0.99;
    /// <summary>
    /// A sheet with more than this share of its outline on the scan's edge has edges that are the
    /// scan's, not its own: its angle comes from the text.
    /// </summary>
    public const double MaxBorderContact = 0.1;
    /// <summary>The sheet fills at least this share of the rectangle around it.</summary>
    public const double MinPageFill = 0.9;
    /// <summary>The sheet's long side is at most this many times its short side.</summary>
    public const double MaxPageAspect = 5;
    /// <summary>Marks larger than this many pixels outside the sheet count as text there.</summary>
    public const int MinOutsideMarkPixels = 6;
    /// <summary>
    /// More text-like marks than this outside the sheet mean it is not the sheet but something on
    /// it (a photo on a page that fills the scan): nothing is cropped.
    /// </summary>
    public const int MaxOutsideMarks = 8;
    /// <summary>
    /// Anything outside the sheet as large as this share of it is another sheet or photo on the
    /// glass, not dust or a ruler's tick: nothing is cropped.
    /// </summary>
    public const double MaxOutsideObjectFraction = 0.02;

    // MARK: Text lines

    /// <summary>A pixel is ink when darker than (1 − this) of the paper around it.</summary>
    public const double InkContrast = 0.30;
    /// <summary>Marks taller and wider than this many pixels (pictures, stamps, logos) are left out of the text.</summary>
    public const int MaxGlyphSide = 60;
    /// <summary>Marks smaller than this many pixels are dust.</summary>
    public const int MinGlyphPixels = 3;
    /// <summary>At most this many ink pixels are measured (evenly picked).</summary>
    public const int MaxInkPoints = 150_000;
    /// <summary>Fewer ink pixels than this are not enough text to tell.</summary>
    public const int MinInkPoints = 2000;
    /// <summary>The text skew searched: ±this many degrees.</summary>
    public const double MaxTextSkewDegrees = 7;
    public const double CoarseStepDegrees = 0.5;
    public const double FineStepDegrees = 0.05;
    /// <summary>The best angle stands out from the sweep by at least this ((best − mean) / mean).</summary>
    public const double MinConfidence = 0.15;
    /// <summary>One direction of the lines is clear when its profile is this much sharper than the other's.</summary>
    public const double AxisMargin = 1.25;

    // MARK: Corrections

    /// <summary>Turns smaller than this are left alone: invisible, and not worth resampling the page.</summary>
    public const double MinCorrectionDegrees = 0.2;
    /// <summary>A sheet lying at more than this angle is cropped without being turned.</summary>
    public const double MaxPageAngleDegrees = 15;
    /// <summary>Content pixels a turn in place may cut off (dust); more and the canvas grows instead.</summary>
    public const int MaxLostContentPixels = 4;

    /// <summary>The full-resolution snap of the sheet's edges may move an edge by up to this many analysis pixels.</summary>
    public const double RefineTolerance = 4;
    /// <summary>The band along each cut edge searched for the sheet's shadow or the backdrop, in inches.</summary>
    public const double EdgeTrimInches = 0.04;
    /// <summary>A line along a cut edge darker than the paper inside by more than this (0...1) is shadow or backdrop.</summary>
    public const double EdgeTrimDrop = 0.03;

    /// <summary>"2.4°": the size of a turn, one decimal (halves rounded up).</summary>
    public static string AngleText(double degrees) =>
        $"{(Math.Round(Math.Abs(degrees) * 10, MidpointRounding.AwayFromZero) / 10).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)}°";

    // MARK: - Correct

    /// <summary>
    /// <paramref name="image"/>, scanned at <paramref name="dpi"/>, cropped to the sheet
    /// (<paramref name="crop"/>) and straightened (<paramref name="straighten"/>); null when the
    /// page stays as it is (nothing asked, nothing found, or not sure).
    /// </summary>
    public static GeometryCorrection? Correct(RgbaImage image, int dpi, bool crop, bool straighten)
    {
        if (!crop && !straighten) return null;
        var gray = GrayImage.From(image, dpi);
        var plan = Plan(gray, crop, straighten);
        if (plan is null) return null;
        double scale = gray.Scale > 0 ? gray.Scale : 1;
        var fill = BorderColor(image, dpi);
        switch (plan.Action)
        {
            case GeometryAction.Rotate:
            {
                var region = new DetectedPhotoRegion(
                    new PointD(image.Width / 2.0, image.Height / 2.0),
                    new SizeD(Math.Max(image.Width, Math.Ceiling(plan.Canvas.Width / scale)),
                              Math.Max(image.Height, Math.Ceiling(plan.Canvas.Height / scale))),
                    plan.AngleDegrees);
                var turned = image.ExtractRotated(region.Center, region.Size, region.AngleDegrees, fill.R, fill.G, fill.B);
                return turned is null ? null : new GeometryCorrection(turned, plan.Geometry, plan, region);
            }
            default:
            {
                var page = plan.Page!;
                var coarse = new DetectedPhotoRegion(
                    new PointD(page.Center.X / scale, page.Center.Y / scale),
                    new SizeD(page.Size.Width / scale, page.Size.Height / scale),
                    page.AngleDegrees);
                double background = BackgroundLuminance(gray) / 255.0;
                var region = Refined(coarse, image, background, RefineTolerance / scale + 2);
                bool upright = plan.Action == GeometryAction.CropStraightened || Math.Abs(region.AngleDegrees) < MinCorrectionDegrees;
                RgbaImage? cut = plan.Action == GeometryAction.CropStraightened
                    ? image.ExtractRotated(region.Center, region.Size, region.AngleDegrees, fill.R, fill.G, fill.B)
                    : image.Cropped(region.BoundingBox());
                if (cut is null) return null;
                // The sheet's edges lie along the cut: trim the shadow or backdrop left along them.
                if (upright)
                {
                    var (left, top, right, bottom) = EdgeInsets(cut, dpi);
                    if (left + top + right + bottom > 0
                        && cut.Cropped(new RectD(left, top, cut.Width - left - right, cut.Height - top - bottom)) is { } trimmed)
                    {
                        cut = trimmed;
                        double a = region.AngleDegrees * Math.PI / 180;
                        double du = (left - right) / 2.0, dv = (top - bottom) / 2.0;
                        region = new DetectedPhotoRegion(
                            new PointD(region.Center.X + du * Math.Cos(a) - dv * Math.Sin(a),
                                       region.Center.Y + du * Math.Sin(a) + dv * Math.Cos(a)),
                            new SizeD(region.Size.Width - left - right, region.Size.Height - top - bottom),
                            region.AngleDegrees);
                    }
                }
                return new GeometryCorrection(cut, plan.Geometry, plan, region);
            }
        }
    }

    /// <summary>
    /// What to do with the page whose analysis image is <paramref name="gray"/>; null to leave it.
    /// A sheet found on the background is cropped (turned upright when asked and it lies at up to
    /// <see cref="MaxPageAngleDegrees"/>, else cut out along its box), or, without cropping, the
    /// scan is turned by the sheet's angle. A sheet that runs off the scan has an edge that is the
    /// scan's own, so its angle comes from the text, and its crop is the smallest rectangle at that
    /// angle around it. Without a sheet the text lines give the angle.
    /// </summary>
    public static GeometryPlan? Plan(GrayImage gray, bool crop, bool straighten)
    {
        if (!crop && !straighten) return null;
        var search = FindPage(gray);
        TextLayout? text = null;
        double? TextSkew()
        {
            text ??= EstimateTextLayout(gray);
            if (!text.IsConfident) return null;
            double skew = text.SkewDegrees;
            return Math.Abs(skew) < MinCorrectionDegrees || Math.Abs(skew) > MaxTextSkewDegrees ? null : skew;
        }
        if (search.Page is { } page)
        {
            double angle = page.AngleDegrees;
            var basis = GeometryBasis.PageEdges;
            var region = page;
            if (search.TouchesBorder)
            {
                angle = 0;
                if (straighten && TextSkew() is { } skew)
                {
                    angle = skew;
                    basis = GeometryBasis.TextLines;
                    region = RectAtAngle(search.Hull, skew);
                }
            }
            bool turn = straighten && Math.Abs(angle) <= MaxPageAngleDegrees && Math.Abs(angle) >= MinCorrectionDegrees;
            if (crop)
            {
                if (turn) return new GeometryPlan(GeometryAction.CropStraightened, angle, basis, region, region.Size, text);
                var box = region.BoundingBox();
                return new GeometryPlan(GeometryAction.CropBox, 0, GeometryBasis.PageEdges, region, new SizeD(box.Width, box.Height), text);
            }
            // The sheet's edges say how it lies: straight already, or too far turned to be sure.
            if (!turn) return null;
            return new GeometryPlan(GeometryAction.Rotate, angle, basis, region, SafeCanvas(gray, angle), text);
        }
        if (!straighten || TextSkew() is not { } textSkew) return null;
        return new GeometryPlan(GeometryAction.Rotate, textSkew, GeometryBasis.TextLines, null, SafeCanvas(gray, textSkew), text);
    }

    /// <summary>The smallest rectangle at <paramref name="angleDegrees"/> around <paramref name="points"/>.</summary>
    public static DetectedPhotoRegion RectAtAngle(IReadOnlyList<PointD> points, double angleDegrees)
    {
        double a = angleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double minU = double.MaxValue, maxU = double.MinValue, minV = double.MaxValue, maxV = double.MinValue;
        foreach (var p in points)
        {
            double u = p.X * c + p.Y * s, v = -p.X * s + p.Y * c;
            minU = Math.Min(minU, u); maxU = Math.Max(maxU, u);
            minV = Math.Min(minV, v); maxV = Math.Max(maxV, v);
        }
        if (minU > maxU) return new DetectedPhotoRegion(PointD.Zero, SizeD.Zero, angleDegrees);
        double cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;
        return new DetectedPhotoRegion(new PointD(cu * c - cv * s, cu * s + cv * c),
                                       new SizeD(maxU - minU, maxV - minV), angleDegrees);
    }

    // MARK: - Page edges

    /// <summary>
    /// The sheet lying on the scanner's background, in <paramref name="gray"/>'s pixels; null when
    /// there is no clear sheet: it fills the scan, is too small or not rectangular, or the area
    /// around it holds more text than a background would, or another sheet or photo
    /// (<see cref="FindPage"/> says which).
    /// </summary>
    public static DetectedPhotoRegion? DetectPage(GrayImage gray) => FindPage(gray).Page;

    /// <summary>The search for the sheet (<see cref="DetectPage"/>), with what was found and why it was turned down.</summary>
    public static PageSearch FindPage(GrayImage gray) => FindPage(gray, PageSearchOptions.Default);

    /// <summary>
    /// The search for the sheet held to <paramref name="options"/> instead of the constants
    /// (<see cref="PageSearchOptions.Default"/> gives the same result as <see cref="FindPage(GrayImage)"/>).
    /// </summary>
    public static PageSearch FindPage(GrayImage gray, PageSearchOptions options)
    {
        int w = gray.Width, h = gray.Height;
        if (w < 16 || h < 16) return PageSearch.Nothing;
        double k = (gray.Dpi > 0 ? gray.Dpi : GrayImage.AnalysisDpi) / GrayImage.AnalysisDpi;

        // 1. The background: the median of the outer ring. 2. What differs from it, after a 3 × 3
        //    median (sensor noise and dust go).
        var smooth = Median3x3(gray);
        var (background, limit) = Backdrop(smooth, w, h, gray.Dpi, options.PageContrast);
        var content = ContentMask(smooth, background, limit);

        // 3. Close the outline (outside the scan counts as set, so a sheet against the glass's
        //    edge keeps its edge), fill what the background cannot reach from the border (the
        //    sheet inside its shadow), then cut thin strands.
        int close = Math.Max(1, (int)Math.Floor(CloseRadius * k + 0.5));
        int open = Math.Max(1, (int)Math.Floor(OpenRadius * k + 0.5));
        var mask = MaskOps.Erode(MaskOps.Dilate(content, w, h, close), w, h, close, outsideSet: true);
        mask = FillHoles(mask, w, h);
        mask = MaskOps.Dilate(MaskOps.Erode(mask, w, h, open, outsideSet: true), w, h, open);

        // 4. The largest region and the smallest rectangle around it.
        MaskComponent? largest = null;
        foreach (var component in MaskOps.ConnectedComponents(mask, w, h))
        {
            if (largest is null || component.Area > largest.Area) largest = component;
        }
        if (largest is null) return PageSearch.Nothing;
        var points = new List<PointD>(largest.Rows.Count * 4);
        foreach (var (y, span) in largest.Rows)
        {
            points.Add(new PointD(span.MinX, y));
            points.Add(new PointD(span.MinX, y + 1));
            points.Add(new PointD(span.MaxX + 1, y));
            points.Add(new PointD(span.MaxX + 1, y + 1));
        }
        var hull = Geometry.ConvexHull(points);
        var rect = Geometry.MinAreaRectOf(hull);
        double rectArea = rect.Size.Width * rect.Size.Height;
        if (rectArea <= 0) return PageSearch.Nothing;
        var region = new DetectedPhotoRegion(rect.Center, rect.Size, rect.AngleDegrees);
        // How much of its outline is the scan's edge: a sheet whose corners run off the scan still
        // shows its edges; one lying along the scan's edge does not.
        int onBorder = 0;
        foreach (var (y, span) in largest.Rows)
        {
            if (y == 0 || y == h - 1) onBorder += span.MaxX - span.MinX + 1;
            else
            {
                if (span.MinX == 0) onBorder++;
                if (span.MaxX == w - 1) onBorder++;
            }
        }
        bool touches = onBorder > MaxBorderContact * 2 * (rect.Size.Width + rect.Size.Height);

        // 5. A sheet: a sensible size and shape, filling its rectangle.
        double areaFraction = rectArea / ((double)w * h);
        double fill = largest.Area / rectArea;
        PageSearch Rejected(PageRejection why, int marks = 0) => new(null, why, region, areaFraction, fill, marks, touches, hull);
        if (areaFraction < options.MinPageAreaFraction) return Rejected(PageRejection.TooSmall);
        if (areaFraction > options.MaxPageAreaFraction) return Rejected(PageRejection.FillsScan);
        if (fill < options.MinPageFill) return Rejected(PageRejection.NotRectangular);
        double aspect = Math.Max(rect.Size.Width, rect.Size.Height) / Math.Max(1e-9, Math.Min(rect.Size.Width, rect.Size.Height));
        if (aspect > options.MaxPageAspect) return Rejected(PageRejection.NotRectangular);

        // 6. Around it, the background: a few objects (a ruler, a thread, a color chart) at most,
        //    not the many small marks of text, which mean the "sheet" is a picture on a page. Seen
        //    on the pixels as scanned: the median above wipes out thin print.
        var (rawBackground, rawLimit) = Backdrop(gray.Pixels, w, h, gray.Dpi, options.PageContrast);
        var marks = ContentMask(gray.Pixels, rawBackground, rawLimit);
        int minMark = Math.Max(1, (int)Math.Floor(MinOutsideMarkPixels * k * k + 0.5));
        var (outside, largestOutside) = MarksOutside(marks, w, h, region, 2 * close, minMark);
        if (outside > MaxOutsideMarks) return Rejected(PageRejection.TextAround, outside);
        // …nor another sheet or photo lying beside it, which cropping would drop.
        if (largestOutside >= MaxOutsideObjectFraction * rectArea) return Rejected(PageRejection.OtherObjects, outside);
        return new PageSearch(region, PageRejection.None, region, areaFraction, fill, outside, touches, hull);
    }

    /// <summary>The thickness of the outer ring, in pixels, of a w × h image at <paramref name="dpi"/>.</summary>
    public static int RingWidth(int w, int h, double dpi) =>
        Math.Max(1, (int)Math.Floor(Math.Min(Math.Min(w, h) * BorderRingFraction, BorderRingInches * dpi) + 0.5));

    /// <summary>The median of the outer ring (<see cref="RingWidth"/>) of the image, 0...255.</summary>
    public static int BackgroundLuminance(GrayImage gray)
    {
        int w = gray.Width, h = gray.Height;
        int ring = RingWidth(w, h, gray.Dpi > 0 ? gray.Dpi : GrayImage.AnalysisDpi);
        var histogram = new int[256];
        int count = 0;
        for (int y = 0; y < h; y++)
        {
            bool edgeRow = y < ring || y >= h - ring;
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                if (!edgeRow && x >= ring && x < w - ring) continue;
                histogram[gray.Pixels[row + x]]++;
                count++;
            }
        }
        return BackgroundMap.Percentile(histogram, count, 0.5);
    }

    /// <summary>
    /// The backdrop's luminance (the median of the outer ring of <paramref name="pixels"/>) and how
    /// far a pixel must differ from it to stand out: <paramref name="contrast"/>
    /// (<see cref="PageContrast"/> unless a search asks for another), or more on a textured
    /// backdrop (black felt, a dark archive frame), <see cref="BackdropSpread"/> times the ring's
    /// median absolute deviation.
    /// </summary>
    private static (int Median, double Limit) Backdrop(byte[] pixels, int w, int h, double dpi, double contrast = PageContrast)
    {
        int ring = RingWidth(w, h, dpi > 0 ? dpi : GrayImage.AnalysisDpi);
        var histogram = new int[256];
        int count = 0;
        for (int y = 0; y < h; y++)
        {
            bool edgeRow = y < ring || y >= h - ring;
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                if (!edgeRow && x >= ring && x < w - ring) continue;
                histogram[pixels[row + x]]++;
                count++;
            }
        }
        int median = BackgroundMap.Percentile(histogram, count, 0.5);
        var deviations = new int[256];
        for (int v = 0; v < 256; v++) deviations[Math.Abs(v - median)] += histogram[v];
        int mad = BackgroundMap.Percentile(deviations, count, 0.5);
        return (median, Math.Max(contrast * 255, BackdropSpread * mad));
    }

    /// <summary>Each pixel replaced by the median of itself and its 8 neighbors (edges repeated).</summary>
    internal static byte[] Median3x3(GrayImage gray)
    {
        int w = gray.Width, h = gray.Height;
        var src = gray.Pixels;
        var output = new byte[w * h];
        Span<int> window = stackalloc int[9];
        for (int y = 0; y < h; y++)
        {
            int y0 = Math.Max(0, y - 1), y2 = Math.Min(h - 1, y + 1);
            for (int x = 0; x < w; x++)
            {
                int x0 = Math.Max(0, x - 1), x2 = Math.Min(w - 1, x + 1);
                window[0] = src[y0 * w + x0]; window[1] = src[y0 * w + x]; window[2] = src[y0 * w + x2];
                window[3] = src[y * w + x0]; window[4] = src[y * w + x]; window[5] = src[y * w + x2];
                window[6] = src[y2 * w + x0]; window[7] = src[y2 * w + x]; window[8] = src[y2 * w + x2];
                // Insertion sort of nine values.
                for (int i = 1; i < 9; i++)
                {
                    int v = window[i], j = i - 1;
                    while (j >= 0 && window[j] > v) { window[j + 1] = window[j]; j--; }
                    window[j + 1] = v;
                }
                output[y * w + x] = (byte)window[4];
            }
        }
        return output;
    }

    /// <summary>1 where a pixel differs from <paramref name="background"/> by more than <paramref name="limit"/>.</summary>
    private static byte[] ContentMask(byte[] pixels, int background, double limit)
    {
        var mask = new byte[pixels.Length];
        for (int i = 0; i < pixels.Length; i++)
        {
            if (Math.Abs(pixels[i] - background) > limit) mask[i] = 1;
        }
        return mask;
    }

    /// <summary>The mask with every clear area the border cannot reach (4-connected) set.</summary>
    private static byte[] FillHoles(byte[] mask, int w, int h)
    {
        var reached = new bool[mask.Length];
        var stack = new Stack<int>();
        void Seed(int i)
        {
            if (mask[i] == 0 && !reached[i]) { reached[i] = true; stack.Push(i); }
        }
        for (int x = 0; x < w; x++) { Seed(x); Seed((h - 1) * w + x); }
        for (int y = 0; y < h; y++) { Seed(y * w); Seed(y * w + w - 1); }
        while (stack.Count > 0)
        {
            int i = stack.Pop();
            int x = i % w, y = i / w;
            if (x > 0) Seed(i - 1);
            if (x < w - 1) Seed(i + 1);
            if (y > 0) Seed(i - w);
            if (y < h - 1) Seed(i + w);
        }
        var output = new byte[mask.Length];
        for (int i = 0; i < mask.Length; i++) output[i] = reached[i] ? (byte)0 : (byte)1;
        return output;
    }

    /// <summary>
    /// The marks of at least <paramref name="minArea"/> pixels (4-connected) of
    /// <paramref name="content"/> lying wholly outside <paramref name="region"/> grown by
    /// <paramref name="margin"/> pixels, and the area of the largest.
    /// </summary>
    private static (int Count, int LargestArea) MarksOutside(byte[] content, int w, int h, DetectedPhotoRegion region, int margin, int minArea)
    {
        double a = region.AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double hw = region.Size.Width / 2 + margin, hh = region.Size.Height / 2 + margin;
        bool Inside(int x, int y)
        {
            double dx = x + 0.5 - region.Center.X, dy = y + 0.5 - region.Center.Y;
            double u = dx * c + dy * s, v = -dx * s + dy * c;
            return Math.Abs(u) <= hw && Math.Abs(v) <= hh;
        }
        int marks = 0, largest = 0;
        foreach (var component in MaskOps.ConnectedComponents(content, w, h))
        {
            if (component.Area < minArea) continue;
            bool outside = true;
            foreach (var (y, span) in component.Rows)
            {
                if (Inside(span.MinX, y) || Inside(span.MaxX, y) || Inside((span.MinX + span.MaxX) / 2, y))
                {
                    outside = false;
                    break;
                }
            }
            if (!outside) continue;
            marks++;
            largest = Math.Max(largest, component.Area);
        }
        return (marks, largest);
    }

    /// <summary>
    /// <paramref name="coarse"/> snapped to the sheet's edges at full resolution
    /// (<see cref="PhotoDetector.RefineRegion"/>), when no edge moves by more than
    /// <paramref name="tolerance"/> pixels; otherwise <paramref name="coarse"/>. The refinement only
    /// sharpens an edge the analysis found: a sheet as light as the background, or a textured
    /// backdrop, would let it wander into the sheet or out over the background.
    /// </summary>
    internal static DetectedPhotoRegion Refined(DetectedPhotoRegion coarse, RgbaImage image, double background, double tolerance)
    {
        var refined = PhotoDetector.RefineRegion(coarse, image, background);
        if (refined is null) return coarse;
        double a = coarse.AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double dx = refined.Center.X - coarse.Center.X, dy = refined.Center.Y - coarse.Center.Y;
        double du = dx * c + dy * s, dv = -dx * s + dy * c;
        double dw = (refined.Size.Width - coarse.Size.Width) / 2, dh = (refined.Size.Height - coarse.Size.Height) / 2;
        // How far each edge moved: left, right, top, bottom.
        bool steady = Math.Abs(du - dw) <= tolerance && Math.Abs(du + dw) <= tolerance
                      && Math.Abs(dv - dh) <= tolerance && Math.Abs(dv + dh) <= tolerance;
        return steady ? refined : coarse;
    }

    /// <summary>
    /// The lines along the edges of <paramref name="cut"/> (an upright crop of a sheet, scanned at
    /// <paramref name="dpi"/>) that are darker than the paper just inside: the sheet's shadow on a
    /// light lid, or a sliver of a dark backdrop. At most <see cref="EdgeTrimInches"/> per edge, and
    /// only lines clearly darker (<see cref="EdgeTrimDrop"/>) than the median of the band inside
    /// them, so print near the edge stays.
    /// </summary>
    internal static (int Left, int Top, int Right, int Bottom) EdgeInsets(RgbaImage cut, int dpi)
    {
        int w = cut.Width, h = cut.Height;
        int band = Math.Max(1, (int)Math.Floor(EdgeTrimInches * Math.Max(1, dpi) + 0.5));
        if (w < 4 * band + 4 || h < 4 * band + 4) return (0, 0, 0, 0);
        var px = cut.Pixels;
        // The mean luma (0...255) of a row or a column, over its middle 80 %.
        double Row(int y)
        {
            int x0 = w / 10, x1 = w - w / 10;
            long sum = 0;
            for (int x = x0; x < x1; x++) sum += Luma(px, (y * w + x) * 4);
            return (double)sum / (x1 - x0);
        }
        double Column(int x)
        {
            int y0 = h / 10, y1 = h - h / 10;
            long sum = 0;
            for (int y = y0; y < y1; y++) sum += Luma(px, (y * w + x) * 4);
            return (double)sum / (y1 - y0);
        }
        int Trim(Func<int, double> line)
        {
            var inside = new double[band];
            for (int i = 0; i < band; i++) inside[i] = line(band + i);
            Array.Sort(inside);
            double limit = inside[band / 2] - EdgeTrimDrop * 255;
            int t = 0;
            while (t < band && line(t) < limit) t++;
            return t;
        }
        return (Trim(i => Column(i)), Trim(i => Row(i)), Trim(i => Column(w - 1 - i)), Trim(i => Row(h - 1 - i)));
    }

    /// <summary>Rec. 601 luma of the RGBA pixel at <paramref name="i"/>, rounded (0...255).</summary>
    private static int Luma(byte[] px, int i) => (299 * px[i] + 587 * px[i + 1] + 114 * px[i + 2] + 500) / 1000;

    /// <summary>
    /// The color of the outer ring (each channel's median) of <paramref name="image"/>, scanned at
    /// <paramref name="dpi"/>, to fill what a turn uncovers.
    /// </summary>
    public static (byte R, byte G, byte B) BorderColor(RgbaImage image, int dpi)
    {
        int w = image.Width, h = image.Height;
        int ring = RingWidth(w, h, Math.Max(1, dpi));
        var r = new int[256];
        var g = new int[256];
        var b = new int[256];
        int count = 0;
        var px = image.Pixels;
        for (int y = 0; y < h; y++)
        {
            bool edgeRow = y < ring || y >= h - ring;
            for (int x = 0; x < w; x++)
            {
                if (!edgeRow && x >= ring && x < w - ring) continue;
                int i = (y * w + x) * 4;
                r[px[i]]++;
                g[px[i + 1]]++;
                b[px[i + 2]]++;
                count++;
            }
        }
        return (BackgroundMap.Percentile(r, count, 0.5), BackgroundMap.Percentile(g, count, 0.5),
                BackgroundMap.Percentile(b, count, 0.5));
    }

    /// <summary>
    /// The size of the scan turned by <paramref name="angleDegrees"/> about its center: its own
    /// size when what turning in place cuts off from its corners is background, otherwise grown
    /// (evenly about the center) until nothing is cut off. In analysis pixels.
    /// </summary>
    public static SizeD SafeCanvas(GrayImage gray, double angleDegrees)
    {
        int w = gray.Width, h = gray.Height;
        var smooth = Median3x3(gray);
        var (background, limit) = Backdrop(smooth, w, h, gray.Dpi);
        double a = angleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double cx = w / 2.0, cy = h / 2.0, hw = w / 2.0, hh = h / 2.0;
        double needW = hw, needH = hh;
        double k = (gray.Dpi > 0 ? gray.Dpi : GrayImage.AnalysisDpi) / GrayImage.AnalysisDpi;
        int edge = Math.Max(1, (int)Math.Floor(ScanEdgeInches * k * GrayImage.AnalysisDpi + 0.5));
        int lost = 0;
        for (int y = edge; y < h - edge; y++)
        {
            for (int x = edge; x < w - edge; x++)
            {
                if (Math.Abs(smooth[y * w + x] - background) <= limit) continue;
                // The pixel's place in the turned frame, whose axes are the straightened page's.
                double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
                double u = Math.Abs(dx * c + dy * s) + 0.5, v = Math.Abs(-dx * s + dy * c) + 0.5;
                if (u <= hw && v <= hh) continue;
                lost++;
                needW = Math.Max(needW, u);
                needH = Math.Max(needH, v);
            }
        }
        if (lost <= Math.Max(1, (int)Math.Floor(MaxLostContentPixels * k * k + 0.5))) return new SizeD(w, h);
        return new SizeD(Math.Ceiling(2 * needW), Math.Ceiling(2 * needH));
    }

    // MARK: - Text lines

    /// <summary>
    /// Which way the text on the page runs and how far it is turned, from projection profiles of
    /// its ink: the ink (darker than (1 − <see cref="InkContrast"/>) of the paper around it), less
    /// marks touching the border (the backdrop, the shadow of a page edge), dust and pictures, is
    /// projected across lines turned by each angle in ±<see cref="MaxTextSkewDegrees"/>, in
    /// <see cref="CoarseStepDegrees"/> steps and then <see cref="FineStepDegrees"/> steps around the
    /// best; the sum of squared line counts peaks where the lines of text line up. Rows and columns
    /// are both tried, for text running across or down the page.
    /// </summary>
    public static TextLayout EstimateTextLayout(GrayImage gray)
    {
        int w = gray.Width, h = gray.Height;
        double dpi = gray.Dpi > 0 ? gray.Dpi : GrayImage.AnalysisDpi;
        double k = dpi / GrayImage.AnalysisDpi;
        int tileSize = Math.Max(4, (int)Math.Floor(BlankPageDetector.TileInches * dpi + 0.5));
        var raw = BackgroundMap.Estimate(gray, 0, 0, w, h, tileSize, BlankPageDetector.BackgroundPercentile);
        if (raw is null) return TextLayout.Nothing;
        int floor = Math.Max(0, raw.MedianTile() - BlankPageDetector.DarkAreaDrop);
        var ink = raw.MaxSmoothed().ClampedBelow((byte)floor).InkMask(gray, InkContrast);

        // The glyphs: marks that do not touch the border, are not dust and are not pictures.
        int maxSide = Math.Max(1, (int)Math.Floor(MaxGlyphSide * k + 0.5));
        int minPixels = Math.Max(1, (int)Math.Floor(MinGlyphPixels * k * k + 0.5));
        var (labels, marks) = LabelMarks(ink, w, h);
        var keep = new bool[marks.Count + 1];
        int total = 0;
        for (int m = 0; m < marks.Count; m++)
        {
            var mark = marks[m];
            bool border = mark.MinX == 0 || mark.MinY == 0 || mark.MaxX == w - 1 || mark.MaxY == h - 1;
            bool picture = mark.MaxX - mark.MinX + 1 > maxSide && mark.MaxY - mark.MinY + 1 > maxSide;
            if (border || picture || mark.Area < minPixels) continue;
            keep[m + 1] = true;
            total += mark.Area;
        }
        if (total < MinInkPoints) return new TextLayout(TextAxis.Unknown, 0, 0, total);

        // Evenly picked ink pixels, centered on the image.
        int stride = (total + MaxInkPoints - 1) / MaxInkPoints;
        int n = (total + stride - 1) / stride;
        var xs = new double[n];
        var ys = new double[n];
        double cx = w / 2.0, cy = h / 2.0;
        int seen = 0, taken = 0;
        for (int i = 0; i < labels.Length && taken < n; i++)
        {
            if (!keep[labels[i]]) continue;
            if (seen % stride == 0)
            {
                xs[taken] = i % w + 0.5 - cx;
                ys[taken] = i / w + 0.5 - cy;
                taken++;
            }
            seen++;
        }
        n = taken;
        int offset = (int)Math.Ceiling(Math.Sqrt(cx * cx + cy * cy)) + 2;
        var bins = new int[2 * offset + 2];

        var horizontal = Sweep(xs, ys, n, vertical: false, bins, offset);
        var vertical = Sweep(xs, ys, n, vertical: true, bins, offset);
        double hSharp = horizontal.Sharpness, vSharp = vertical.Sharpness;
        TextAxis axis = hSharp >= AxisMargin * vSharp ? TextAxis.Horizontal
            : vSharp >= AxisMargin * hSharp ? TextAxis.Vertical
            : TextAxis.Unknown;
        var best = axis == TextAxis.Vertical ? vertical : horizontal;
        double confidence = best.Confidence;
        // A best angle at the end of the sweep may lie beyond it: not sure.
        if (Math.Abs(best.CoarseAngle) >= MaxTextSkewDegrees - 1e-9) confidence = 0;
        if (axis == TextAxis.Unknown) return new TextLayout(axis, 0, confidence, n);
        double skew = Refine(xs, ys, n, axis == TextAxis.Vertical, bins, offset, best.CoarseAngle);
        return new TextLayout(axis, skew, confidence, n);
    }

    private readonly record struct SweepResult(double CoarseAngle, double Sharpness, double Confidence);

    /// <summary>
    /// The coarse sweep for one direction: the best angle, how sharp its profile is against an
    /// even spread (sum of squares × span / count², 1 for an even spread), and the confidence.
    /// </summary>
    private static SweepResult Sweep(double[] xs, double[] ys, int n, bool vertical, int[] bins, int offset)
    {
        int steps = (int)Math.Round(MaxTextSkewDegrees / CoarseStepDegrees);
        double bestScore = double.MinValue, bestAngle = 0, sum = 0;
        int bestSpan = 1;
        for (int i = -steps; i <= steps; i++)
        {
            double angle = i * CoarseStepDegrees;
            double score = Score(xs, ys, n, angle, vertical, bins, offset, out int span);
            sum += score;
            if (score > bestScore)
            {
                bestScore = score;
                bestAngle = angle;
                bestSpan = span;
            }
        }
        double mean = sum / (2 * steps + 1);
        double sharpness = n > 0 ? bestScore * bestSpan / ((double)n * n) : 0;
        double confidence = mean > 0 ? (bestScore - mean) / mean : 0;
        return new SweepResult(bestAngle, sharpness, confidence);
    }

    /// <summary>
    /// The fine sweep around <paramref name="coarse"/> (± one coarse step), then the peak placed
    /// between the best fine angle and its neighbors (a parabola through the three scores).
    /// </summary>
    private static double Refine(double[] xs, double[] ys, int n, bool vertical, int[] bins, int offset, double coarse)
    {
        int steps = (int)Math.Round(CoarseStepDegrees / FineStepDegrees);
        var scores = new double[2 * steps + 1];
        int bestIndex = 0;
        for (int i = -steps; i <= steps; i++)
        {
            double score = Score(xs, ys, n, coarse + i * FineStepDegrees, vertical, bins, offset, out _);
            scores[i + steps] = score;
            if (score > scores[bestIndex]) bestIndex = i + steps;
        }
        double angle = coarse + (bestIndex - steps) * FineStepDegrees;
        if (bestIndex > 0 && bestIndex < scores.Length - 1)
        {
            double left = scores[bestIndex - 1], mid = scores[bestIndex], right = scores[bestIndex + 1];
            double denominator = left - 2 * mid + right;
            if (denominator < 0)
            {
                double shift = 0.5 * (left - right) / denominator;
                angle += Math.Clamp(shift, -0.5, 0.5) * FineStepDegrees;
            }
        }
        return Math.Clamp(angle, -MaxTextSkewDegrees, MaxTextSkewDegrees);
    }

    /// <summary>
    /// The sum of squared counts of the points projected, at <paramref name="angleDegrees"/>, on
    /// the page's vertical axis (rows of text: y·cos θ − x·sin θ) or its horizontal one (columns:
    /// x·cos θ + y·sin θ), in 1-pixel bins. <paramref name="span"/> is the number of bins between
    /// the first and the last one used.
    /// </summary>
    private static double Score(double[] xs, double[] ys, int n, double angleDegrees, bool vertical,
                                int[] bins, int offset, out int span)
    {
        double a = angleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        Array.Clear(bins);
        int lo = int.MaxValue, hi = int.MinValue;
        for (int i = 0; i < n; i++)
        {
            double p = vertical ? xs[i] * c + ys[i] * s : ys[i] * c - xs[i] * s;
            int b = (int)Math.Floor(p) + offset;
            bins[b]++;
            if (b < lo) lo = b;
            if (b > hi) hi = b;
        }
        span = hi >= lo ? hi - lo + 1 : 1;
        double sum = 0;
        for (int b = Math.Max(0, lo); b <= hi; b++) sum += (double)bins[b] * bins[b];
        return sum;
    }

    private sealed class Mark
    {
        public int Area, MinX = int.MaxValue, MinY = int.MaxValue, MaxX = -1, MaxY = -1;
    }

    /// <summary>The 8-connected marks of <paramref name="mask"/>: a label per pixel (0 = none, else mark index + 1) and each mark's area and box.</summary>
    private static (int[] Labels, List<Mark> Marks) LabelMarks(byte[] mask, int w, int h)
    {
        var labels = new int[mask.Length];
        var marks = new List<Mark>();
        var stack = new Stack<int>();
        for (int start = 0; start < mask.Length; start++)
        {
            if (mask[start] != 1 || labels[start] != 0) continue;
            var mark = new Mark();
            marks.Add(mark);
            int label = marks.Count;
            labels[start] = label;
            stack.Push(start);
            while (stack.Count > 0)
            {
                int i = stack.Pop();
                int x = i % w, y = i / w;
                mark.Area++;
                if (x < mark.MinX) mark.MinX = x;
                if (x > mark.MaxX) mark.MaxX = x;
                if (y < mark.MinY) mark.MinY = y;
                if (y > mark.MaxY) mark.MaxY = y;
                for (int ny = Math.Max(0, y - 1); ny <= Math.Min(h - 1, y + 1); ny++)
                {
                    for (int nx = Math.Max(0, x - 1); nx <= Math.Min(w - 1, x + 1); nx++)
                    {
                        int j = ny * w + nx;
                        if (mask[j] == 1 && labels[j] == 0)
                        {
                            labels[j] = label;
                            stack.Push(j);
                        }
                    }
                }
            }
        }
        return (labels, marks);
    }
}
