using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/ReceiptProcessing.swift: same constants, same steps,
// same patterns.

/// <summary>How a receipt's edges were found (<see cref="ReceiptDetector"/>).</summary>
public enum ReceiptBasis
{
    /// <summary>The paper stands out from the lid: the receipt is cut along its own edges.</summary>
    Paper,
    /// <summary>The paper does not stand out (thermal paper on a white lid): the receipt is cut around its print, with a margin.</summary>
    Text,
}

/// <summary>One receipt found on a scan.</summary>
/// <param name="Region">Where it lies, in the pixels of the image searched.</param>
/// <param name="Basis">What its edges come from.</param>
public sealed record ReceiptRegion(DetectedPhotoRegion Region, ReceiptBasis Basis);

/// <summary>How receipts are looked for.</summary>
public sealed class ReceiptDetectorOptions
{
    /// <summary>At most this many receipts are taken from one scan (the largest).</summary>
    public int MaxReceipts { get; set; } = ReceiptDetector.MaxReceipts;

    /// <summary>
    /// The scan holds one receipt (a sheet from the feeder): everything printed on it is one
    /// receipt, however far apart.
    /// </summary>
    public bool SingleReceipt { get; set; }
}

/// <summary>
/// Finds the receipts lying on a scan, several at once. Thermal paper on a white lid hardly
/// differs from the lid, so receipts are found by their print and cut out along their paper when
/// it shows:
/// <list type="number">
/// <item>Marks: on the scan's gray copy at the analysis resolution, what differs from the lid (the
/// median of the outer ring) by more than <see cref="MarkContrast"/>: print, and paper edges with
/// some contrast.</item>
/// <item>Blocks: the marks closed by <see cref="CloseInches"/> (letters and lines run together)
/// and opened by one pixel (specks go); the blocks one above the other (overlapping across by at
/// least <see cref="ColumnOverlap"/> of the narrower, less than <see cref="ColumnGapInches"/>
/// apart) are one receipt, and a block too small to be a receipt joins the receipt it lies next
/// to (less than <see cref="ColumnGapInches"/> away), or beside (a column of prices, up to
/// <see cref="SideGapInches"/> away). Where the paper shows, blocks on different sheets are never
/// joined, and a small block joins the receipt on its own sheet.</item>
/// <item>Receipts: blocks at least <see cref="MinShortSideInches"/> by <see cref="MinLongSideInches"/>
/// and <see cref="MinAreaSquareInches"/>, at most <see cref="MaxReceipts"/>.</item>
/// <item>Edges: around each one, the paper is looked for as a sheet (<see cref="DocumentGeometry.FindPage(GrayImage, PageSearchOptions)"/>
/// held to <see cref="PageSearch"/>: thermal paper's low contrast, curled edges, receipts many
/// times as long as wide); when it holds all the print, the receipt is cut along it
/// (<see cref="ReceiptBasis.Paper"/>). Otherwise it is cut around its print at the angle of its
/// lines of text (<see cref="DocumentGeometry.EstimateTextLayout"/>), with
/// <see cref="PaddingInches"/> of margin (<see cref="ReceiptBasis.Text"/>).</item>
/// </list>
/// Regions are sorted top to bottom, then left to right, as photos are.
/// </summary>
public static class ReceiptDetector
{
    /// <summary>A pixel is a mark when it differs from the lid by more than this (0...1).</summary>
    public const double MarkContrast = 0.09;
    /// <summary>Marks closer than about twice this many inches run together into a block.</summary>
    public const double CloseInches = 0.12;
    /// <summary>Blocks smaller than this many square inches (dust) take no part.</summary>
    public const double MinBlockSquareInches = 0.01;
    /// <summary>Blocks one above the other overlap across by at least this share of the narrower…</summary>
    public const double ColumnOverlap = 0.5;
    /// <summary>…and are less than this many inches apart to be one receipt; a small block joins a receipt this close.</summary>
    public const double ColumnGapInches = 0.6;
    /// <summary>
    /// A small block beside a receipt (most of its height within the receipt's) joins it up to this
    /// many inches away: the prices printed far right of short items.
    /// </summary>
    public const double SideGapInches = 1.5;
    /// <summary>A receipt is at least this many inches wide…</summary>
    public const double MinShortSideInches = 0.5;
    /// <summary>…this many inches long…</summary>
    public const double MinLongSideInches = 1.0;
    /// <summary>…and covers this many square inches.</summary>
    public const double MinAreaSquareInches = 0.75;
    /// <summary>The most receipts taken from one scan.</summary>
    public const int MaxReceipts = 12;
    /// <summary>A receipt cut around its print gets this margin on every side, in inches.</summary>
    public const double PaddingInches = 0.08;
    /// <summary>
    /// The paper is looked for this far around the print, in inches, and, when it is not found
    /// there (it may run further: a blank tail), this far.
    /// </summary>
    public static readonly double[] SearchMarginsInches = [0.4, 1.2];
    /// <summary>The paper's edges hold all the print, give or take this many inches.</summary>
    public const double PaperToleranceInches = 0.05;
    /// <summary>A sheet of paper that shows is at least this many square inches.</summary>
    public const double MinPaperSquareInches = 0.5;

    /// <summary>
    /// The limits a receipt's paper is held to: thermal paper differs from a white lid by a few
    /// levels only, its edges curl, and a long receipt is many times as long as wide. Only the
    /// Receipts task relaxes <see cref="DocumentGeometry"/>'s limits this way.
    /// </summary>
    public static PageSearchOptions PageSearch { get; } = new()
    {
        PageContrast = 0.02,
        MinPageFill = 0.85,
        MaxPageAspect = 15,
    };

    /// <summary>
    /// The receipts on <paramref name="image"/>, scanned at <paramref name="dpi"/>, in its pixels,
    /// sorted top to bottom, then left to right. Empty when nothing looks like a receipt.
    /// </summary>
    public static List<DetectedPhotoRegion> DetectRegions(RgbaImage image, int dpi, ReceiptDetectorOptions? options = null) =>
        Find(image, dpi, options).Select(r => r.Region).ToList();

    /// <summary><see cref="DetectRegions"/>, with what each receipt's edges come from.</summary>
    public static List<ReceiptRegion> Find(RgbaImage image, int dpi, ReceiptDetectorOptions? options = null)
    {
        if (image.Width <= 0 || image.Height <= 0) return [];
        var gray = GrayImage.From(image, Math.Max(1, dpi));
        var found = Find(gray, options);
        double scale = gray.Scale > 0 ? gray.Scale : 1;
        double background = DocumentGeometry.BackgroundLuminance(gray) / 255.0;
        var regions = new List<ReceiptRegion>(found.Count);
        foreach (var receipt in found)
        {
            var r = receipt.Region;
            var coarse = new DetectedPhotoRegion(new PointD(r.Center.X / scale, r.Center.Y / scale),
                                                 new SizeD(r.Size.Width / scale, r.Size.Height / scale), r.AngleDegrees);
            // Paper edges are snapped at full resolution when that moves no edge far: on a dark lid
            // the snap is exact, on a white one it would wander into the paper and is not taken.
            var region = receipt.Basis == ReceiptBasis.Paper
                ? DocumentGeometry.Refined(coarse, image, background, DocumentGeometry.RefineTolerance / scale + 2)
                : coarse;
            regions.Add(new ReceiptRegion(region, receipt.Basis));
        }
        return regions;
    }

    /// <summary>
    /// The receipts on <paramref name="gray"/> (a scan's gray copy, normally at
    /// <see cref="GrayImage.AnalysisDpi"/>), in its pixels, sorted top to bottom, then left to right.
    /// </summary>
    public static List<ReceiptRegion> Find(GrayImage gray, ReceiptDetectorOptions? options = null)
    {
        options ??= new ReceiptDetectorOptions();
        int w = gray.Width, h = gray.Height;
        if (w < 16 || h < 16 || options.MaxReceipts <= 0) return [];
        double dpi = gray.Dpi > 0 ? gray.Dpi : GrayImage.AnalysisDpi;

        // 1. Marks: what differs from the lid.
        int lid = DocumentGeometry.BackgroundLuminance(gray);
        double limit = MarkContrast * 255;
        var mask = new byte[w * h];
        for (int i = 0; i < mask.Length; i++)
        {
            if (Math.Abs(gray.Pixels[i] - lid) > limit) mask[i] = 1;
        }

        // 2. Blocks: close (letters and lines run together), then open by one pixel (specks go).
        int close = Math.Max(2, (int)Math.Floor(CloseInches * dpi + 0.5));
        mask = MaskOps.Erode(MaskOps.Dilate(mask, w, h, close), w, h, close);
        mask = MaskOps.Dilate(MaskOps.Erode(mask, w, h, 1), w, h, 1);
        double minBlock = MinBlockSquareInches * dpi * dpi;
        var blocks = new List<Block>();
        foreach (var component in MaskOps.ConnectedComponents(mask, w, h))
        {
            if (component.Area < minBlock) continue;
            blocks.Add(Block.Of(component));
        }
        if (blocks.Count == 0) return [];
        // The sheet each block lies on, where the paper shows.
        if (!options.SingleReceipt)
        {
            var papers = PaperLabels(gray, dpi);
            foreach (var block in blocks)
            {
                block.Paper = papers[(block.MinY + block.MaxY) / 2 * w + (block.MinX + block.MaxX) / 2];
            }
        }

        // 3. Receipts: blocks in a column are one receipt; small blocks join the receipt beside them.
        List<Block> groups = options.SingleReceipt ? [Block.Union(blocks)] : Group(blocks, dpi);

        // 4. Each receipt's rectangle, size checked; the largest MaxReceipts.
        var candidates = new List<(Block Group, MinAreaRect Rect, List<PointD> Hull)>();
        foreach (var group in groups)
        {
            var hull = Geometry.ConvexHull(group.Points);
            var rect = Geometry.MinAreaRectOf(hull);
            if (!Sized(rect, dpi)) continue;
            candidates.Add((group, rect, hull));
        }
        candidates.Sort((a, b) => (b.Rect.Size.Width * b.Rect.Size.Height).CompareTo(a.Rect.Size.Width * a.Rect.Size.Height));
        if (candidates.Count > options.MaxReceipts) candidates.RemoveRange(options.MaxReceipts, candidates.Count - options.MaxReceipts);

        // 5. Each receipt's edges: its paper when that shows and holds all its print, else its print.
        var receipts = new List<ReceiptRegion>();
        foreach (var (group, rect, hull) in candidates)
        {
            receipts.Add(Edges(gray, group, rect, hull, dpi));
        }

        // Two blocks of one receipt (a wide blank gap between them) both find its paper: one region.
        var merged = PhotoDetector.MergeOverlapping(receipts.Select(r => r.Region).ToList());
        var sorted = PhotoDetector.SortRowMajor(merged);
        return sorted.Select(region =>
        {
            var match = receipts.FirstOrDefault(r => ReferenceEquals(r.Region, region));
            // A region made by merging two holds paper when either did.
            var basis = match?.Basis
                        ?? (receipts.Any(r => r.Basis == ReceiptBasis.Paper && Overlaps(r.Region, region))
                            ? ReceiptBasis.Paper : ReceiptBasis.Text);
            return new ReceiptRegion(region, basis);
        }).ToList();
    }

    /// <summary>
    /// The receipt's region: its paper, looked for around its print (and further when it is not
    /// found there: the paper may run on), when the paper is found as a sheet that holds all the
    /// print; else the print at the angle of its lines (or of its outline when the lines do not
    /// tell), with a margin.
    /// </summary>
    private static ReceiptRegion Edges(GrayImage gray, Block group, MinAreaRect rect, List<PointD> hull, double dpi)
    {
        GrayImage? first = null;
        foreach (double margin in SearchMarginsInches)
        {
            int m = (int)Math.Floor(margin * dpi + 0.5);
            int x0 = Math.Max(0, group.MinX - m), y0 = Math.Max(0, group.MinY - m);
            int x1 = Math.Min(gray.Width, group.MaxX + 1 + m), y1 = Math.Min(gray.Height, group.MaxY + 1 + m);
            var area = Crop(gray, x0, y0, x1 - x0, y1 - y0);
            if (area is null) break;
            first ??= area;
            var search = DocumentGeometry.FindPage(area, PageSearch);
            if (search.Page is { } page && !search.TouchesBorder)
            {
                var paper = new DetectedPhotoRegion(new PointD(page.Center.X + x0, page.Center.Y + y0), page.Size, page.AngleDegrees);
                if (Holds(paper, hull, PaperToleranceInches * dpi)) return new ReceiptRegion(paper, ReceiptBasis.Paper);
            }
            // Not found, or not all of it: the paper may run past the area searched (a blank tail,
            // wide margins), which also leaves paper in the area's outer ring. Look further.
        }

        double angle = rect.AngleDegrees;
        var layout = first is null ? null : DocumentGeometry.EstimateTextLayout(first);
        if (layout is { IsConfident: true } text && Math.Abs(text.SkewDegrees) <= DocumentGeometry.MaxTextSkewDegrees)
        {
            angle = text.SkewDegrees;
        }
        var around = DocumentGeometry.RectAtAngle(hull, angle);
        double pad = 2 * PaddingInches * dpi;
        return new ReceiptRegion(new DetectedPhotoRegion(around.Center,
                                                         new SizeD(around.Size.Width + pad, around.Size.Height + pad),
                                                         angle),
                                 ReceiptBasis.Text);
    }

    /// <summary>Whether every point lies inside <paramref name="region"/> grown by <paramref name="tolerance"/> pixels.</summary>
    private static bool Holds(DetectedPhotoRegion region, IReadOnlyList<PointD> points, double tolerance)
    {
        double a = region.AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double hw = region.Size.Width / 2 + tolerance, hh = region.Size.Height / 2 + tolerance;
        foreach (var p in points)
        {
            double dx = p.X - region.Center.X, dy = p.Y - region.Center.Y;
            double u = dx * c + dy * s, v = -dx * s + dy * c;
            if (Math.Abs(u) > hw || Math.Abs(v) > hh) return false;
        }
        return true;
    }

    /// <summary>Whether the centers of the two regions lie inside each other's rectangles.</summary>
    private static bool Overlaps(DetectedPhotoRegion a, DetectedPhotoRegion b) =>
        Holds(b, [a.Center], 0) || Holds(a, [b.Center], 0);

    /// <summary>
    /// The sheets of paper that show on <paramref name="gray"/> (scanned at <paramref name="dpi"/>): a
    /// label per pixel (1, 2, … per sheet, 0 where none shows). What differs from the lid by more than
    /// <see cref="PageSearch"/>'s contrast (or the lid's own spread, on a textured lid), after a 3 × 3
    /// median, opened so print and specks go, in pieces of at least <see cref="MinPaperSquareInches"/>;
    /// each piece is labelled row by row from its leftmost to its rightmost pixel.
    /// </summary>
    private static int[] PaperLabels(GrayImage gray, double dpi)
    {
        int w = gray.Width, h = gray.Height;
        var smooth = DocumentGeometry.Median3x3(gray);
        int ring = DocumentGeometry.RingWidth(w, h, dpi);
        var histogram = new int[256];
        int count = 0;
        for (int y = 0; y < h; y++)
        {
            bool edgeRow = y < ring || y >= h - ring;
            for (int x = 0; x < w; x++)
            {
                if (!edgeRow && x >= ring && x < w - ring) continue;
                histogram[smooth[y * w + x]]++;
                count++;
            }
        }
        int median = BackgroundMap.Percentile(histogram, count, 0.5);
        var deviations = new int[256];
        for (int v = 0; v < 256; v++) deviations[Math.Abs(v - median)] += histogram[v];
        int spread = BackgroundMap.Percentile(deviations, count, 0.5);
        double limit = Math.Max(PageSearch.PageContrast * 255, DocumentGeometry.BackdropSpread * spread);
        var mask = new byte[w * h];
        for (int i = 0; i < mask.Length; i++)
        {
            if (Math.Abs(smooth[i] - median) > limit) mask[i] = 1;
        }
        int open = Math.Max(1, (int)Math.Floor(DocumentGeometry.OpenRadius * dpi / GrayImage.AnalysisDpi + 0.5));
        mask = MaskOps.Dilate(MaskOps.Erode(mask, w, h, open), w, h, open);
        var labels = new int[w * h];
        double minPaper = MinPaperSquareInches * dpi * dpi;
        int label = 0;
        foreach (var component in MaskOps.ConnectedComponents(mask, w, h))
        {
            if (component.Area < minPaper) continue;
            label++;
            foreach (var (y, span) in component.Rows)
            {
                for (int x = span.MinX; x <= span.MaxX; x++) labels[y * w + x] = label;
            }
        }
        return labels;
    }

    /// <summary>Whether two groups may be one receipt: not when each lies on a sheet of its own.</summary>
    private static bool SamePaper(Block a, Block b) => a.Paper == 0 || b.Paper == 0 || a.Paper == b.Paper;

    /// <summary>The part (x, y, width, height) of <paramref name="gray"/>; null when empty.</summary>
    private static GrayImage? Crop(GrayImage gray, int x, int y, int width, int height)
    {
        if (width <= 0 || height <= 0) return null;
        var pixels = new byte[width * height];
        for (int row = 0; row < height; row++)
        {
            Array.Copy(gray.Pixels, (y + row) * gray.Width + x, pixels, row * width, width);
        }
        return new GrayImage(width, height, pixels, gray.Dpi, gray.Scale);
    }

    /// <summary>
    /// The receipts among <paramref name="blocks"/>: blocks one above the other, overlapping across
    /// by <see cref="ColumnOverlap"/> of the narrower and less than <see cref="ColumnGapInches"/>
    /// apart, joined until nothing changes; then each group too small to be a receipt joined to the
    /// nearest receipt-sized one less than <see cref="ColumnGapInches"/> away, or less than
    /// <see cref="SideGapInches"/> away beside it with at least half its height within the
    /// receipt's (a column of prices beside the items), or dropped. Groups on different sheets
    /// (<see cref="PaperLabels"/>) are never joined; a small group on a sheet joins the nearest
    /// receipt on the same sheet, however far.
    /// </summary>
    private static List<Block> Group(List<Block> blocks, double dpi)
    {
        double gap = ColumnGapInches * dpi, side = SideGapInches * dpi;
        var groups = new List<Block>(blocks);
        bool changed = true;
        while (changed)
        {
            changed = false;
            for (int i = 0; i < groups.Count && !changed; i++)
            {
                for (int j = i + 1; j < groups.Count && !changed; j++)
                {
                    var a = groups[i];
                    var b = groups[j];
                    int overlap = Math.Min(a.MaxX, b.MaxX) - Math.Max(a.MinX, b.MinX) + 1;
                    int narrower = Math.Min(a.MaxX - a.MinX + 1, b.MaxX - b.MinX + 1);
                    int apart = Math.Max(a.MinY, b.MinY) - Math.Min(a.MaxY, b.MaxY) - 1;
                    if (overlap < ColumnOverlap * narrower || apart >= gap || !SamePaper(a, b)) continue;
                    groups[i] = Block.Union([a, b]);
                    groups.RemoveAt(j);
                    changed = true;
                }
            }
        }
        var receipts = groups.Where(g => Sized(g, dpi)).ToList();
        foreach (var small in groups.Where(g => !Sized(g, dpi)))
        {
            int best = -1;
            double bestDistance = double.MaxValue;
            bool onItsSheet = small.Paper != 0 && receipts.Any(r => r.Paper == small.Paper);
            for (int k = 0; k < receipts.Count; k++)
            {
                var r = receipts[k];
                if (!SamePaper(r, small)) continue;
                int dx = Math.Max(0, Math.Max(r.MinX, small.MinX) - Math.Min(r.MaxX, small.MaxX) - 1);
                int dy = Math.Max(0, Math.Max(r.MinY, small.MinY) - Math.Min(r.MaxY, small.MaxY) - 1);
                double distance = Math.Max(dx, dy);
                int alongside = Math.Min(r.MaxY, small.MaxY) - Math.Max(r.MinY, small.MinY) + 1;
                bool beside = dy == 0 && 2 * alongside >= small.MaxY - small.MinY + 1 && dx < side;
                bool sameSheet = onItsSheet && r.Paper == small.Paper;
                if ((sameSheet || (!onItsSheet && (distance < gap || beside))) && distance < bestDistance)
                {
                    best = k;
                    bestDistance = distance;
                }
            }
            if (best >= 0) receipts[best] = Block.Union([receipts[best], small]);
        }
        return receipts;
    }

    /// <summary>
    /// Whether the group is the size of a receipt (<see cref="MinShortSideInches"/>,
    /// <see cref="MinLongSideInches"/>, <see cref="MinAreaSquareInches"/>), measured along its
    /// smallest rectangle, so a tilted column of prices is as narrow as it looks.
    /// </summary>
    private static bool Sized(Block group, double dpi) => Sized(Geometry.MinAreaRectOf(Geometry.ConvexHull(group.Points)), dpi);

    private static bool Sized(MinAreaRect rect, double dpi)
    {
        double shortSide = Math.Min(rect.Size.Width, rect.Size.Height) / dpi;
        double longSide = Math.Max(rect.Size.Width, rect.Size.Height) / dpi;
        return shortSide >= MinShortSideInches && longSide >= MinLongSideInches && shortSide * longSide >= MinAreaSquareInches;
    }

    /// <summary>
    /// Marks run together: their outline points (pixel corners of each row's ends), their box and the
    /// sheet they lie on (<see cref="PaperLabels"/>; 0 when no paper shows there).
    /// </summary>
    private sealed class Block
    {
        public readonly List<PointD> Points = [];
        public int MinX = int.MaxValue, MinY = int.MaxValue, MaxX = -1, MaxY = -1;
        public int Paper;

        public static Block Of(MaskComponent component)
        {
            var block = new Block();
            foreach (var (y, span) in component.Rows)
            {
                block.Points.Add(new PointD(span.MinX, y));
                block.Points.Add(new PointD(span.MinX, y + 1));
                block.Points.Add(new PointD(span.MaxX + 1, y));
                block.Points.Add(new PointD(span.MaxX + 1, y + 1));
                block.MinX = Math.Min(block.MinX, span.MinX);
                block.MaxX = Math.Max(block.MaxX, span.MaxX);
                block.MinY = Math.Min(block.MinY, y);
                block.MaxY = Math.Max(block.MaxY, y);
            }
            return block;
        }

        public static Block Union(IReadOnlyList<Block> blocks)
        {
            var union = new Block();
            foreach (var block in blocks)
            {
                union.Points.AddRange(block.Points);
                union.MinX = Math.Min(union.MinX, block.MinX);
                union.MaxX = Math.Max(union.MaxX, block.MaxX);
                union.MinY = Math.Min(union.MinY, block.MinY);
                union.MaxY = Math.Max(union.MaxY, block.MaxY);
                if (union.Paper == 0) union.Paper = block.Paper;
            }
            return union;
        }
    }

    /// <summary>
    /// The receipt cut out of <paramref name="image"/> and turned upright; outside the scan is white.
    /// Null when the region is empty.
    /// </summary>
    public static RgbaImage? Extract(RgbaImage image, DetectedPhotoRegion region) =>
        PhotoDetector.ExtractPhoto(image, region, deskew: true);

    /// <summary>
    /// Cut out, turned upright and made easy to read (<see cref="ReceiptEnhancer.Enhance"/>): what is
    /// saved of a receipt. Null when the region is empty.
    /// </summary>
    public static RgbaImage? ExtractEnhanced(RgbaImage image, DetectedPhotoRegion region, int dpi) =>
        Extract(image, region) is { } cut ? ReceiptEnhancer.Enhance(cut, dpi) : null;
}

/// <summary>
/// Makes faded thermal print easy to read: gray, the paper evened out to white and the print
/// darkened. Pure arithmetic on the image's gray copy, so both platforms give the same pixels.
/// <list type="number">
/// <item>The paper's brightness across the receipt (<see cref="BackgroundMap"/>): tiles of
/// <see cref="TileInches"/>, the <see cref="BackgroundPercentile"/> of each, the brightest of each
/// tile and its neighbors (a tile covered by print still gets the paper around it), never less than
/// <see cref="BlankPageDetector.DarkAreaDrop"/> below the middle tile (a dark logo stays dark).</item>
/// <item>Each pixel against the paper there: n = L / max(paper, <see cref="MinBackground"/>), at
/// most 1.</item>
/// <item>Stretched: the darkest print (the <see cref="BlackPercentile"/> of n, at most
/// <see cref="MaxBlackPoint"/>) becomes black and <see cref="WhitePoint"/> white, then
/// darkened by the power <see cref="Gamma"/>.</item>
/// </list>
/// </summary>
public static class ReceiptEnhancer
{
    /// <summary>The paper's brightness is measured in tiles of this many inches.</summary>
    public const double TileInches = 0.25;
    /// <summary>A tile's paper is this percentile of its pixels.</summary>
    public const double BackgroundPercentile = 0.9;
    /// <summary>The share of the paper's brightness that becomes white.</summary>
    public const double WhitePoint = 0.90;
    /// <summary>The share of pixels taken as the darkest print.</summary>
    public const double BlackPercentile = 0.01;
    /// <summary>The darkest print is taken as at most this share of the paper's brightness (a receipt with little print).</summary>
    public const double MaxBlackPoint = 0.6;
    /// <summary>The power the stretched value is raised to: below 1 lightens, above 1 darkens the print.</summary>
    public const double Gamma = 1.6;
    /// <summary>The paper's brightness is taken as at least this (0...1), so dark areas do not blow up.</summary>
    public const double MinBackground = 0.2;
    /// <summary>The steps n is counted in.</summary>
    public const int Levels = 1024;

    /// <summary>
    /// <paramref name="image"/> (a receipt, scanned at <paramref name="dpi"/>) made easy to read:
    /// gray (R = G = B), the same size.
    /// </summary>
    public static RgbaImage Enhance(RgbaImage image, int dpi)
    {
        var gray = GrayImage.Luma(image, Math.Max(1, dpi));
        int w = gray.Width, h = gray.Height;
        int tile = Math.Max(4, (int)Math.Floor(TileInches * Math.Max(1, dpi) + 0.5));
        var raw = BackgroundMap.Estimate(gray, 0, 0, w, h, tile, BackgroundPercentile)!;
        int floor = Math.Max(0, raw.MedianTile() - BlankPageDetector.DarkAreaDrop);
        var paper = raw.MaxSmoothed().ClampedBelow((byte)floor);

        var levels = new int[w * h];
        var histogram = new int[Levels + 1];
        double minBackground = MinBackground * 255;
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                double b = Math.Max(paper.ValueAt(x, y), minBackground);
                double n = Math.Min(1.0, gray.Pixels[y * w + x] / b);
                int k = (int)Math.Floor(n * Levels + 0.5);
                levels[y * w + x] = k;
                histogram[k]++;
            }
        }
        double lo = Math.Min(Percentile(histogram, w * h, BlackPercentile) / (double)Levels, MaxBlackPoint);
        double hi = WhitePoint;
        var lut = new byte[Levels + 1];
        for (int k = 0; k <= Levels; k++)
        {
            double v = Math.Clamp((k / (double)Levels - lo) / (hi - lo), 0, 1);
            lut[k] = (byte)Math.Floor(Math.Pow(v, Gamma) * 255 + 0.5);
        }
        var rgba = new byte[w * h * 4];
        for (int i = 0, o = 0; i < levels.Length; i++, o += 4)
        {
            byte value = lut[levels[i]];
            rgba[o] = value;
            rgba[o + 1] = value;
            rgba[o + 2] = value;
            rgba[o + 3] = 255;
        }
        return new RgbaImage(w, h, rgba);
    }

    /// <summary>The smallest level with at least ⌈fraction × count⌉ values at or below it.</summary>
    private static int Percentile(int[] histogram, int count, double fraction)
    {
        int rank = Math.Clamp((int)Math.Ceiling(fraction * count), 1, Math.Max(1, count));
        int seen = 0;
        for (int k = 0; k < histogram.Length; k++)
        {
            seen += histogram[k];
            if (seen >= rank) return k;
        }
        return histogram.Length - 1;
    }
}

/// <summary>
/// Reads the date a receipt was issued from its text (the OCR lines in reading order). Numeric dates
/// (ISO 2026-03-12, 12/03/2026, 03/12/2026, 12.03.2026, 12-03-26), dates with month names in English,
/// Turkish, German, French, Spanish, Italian, Portuguese and Dutch (12 Mar 2026, Mar 12, 2026,
/// 12-MAR-26, 12 Mart 2026, 12. März 2026, 12 de marzo de 2026), and Chinese, Japanese and Korean
/// dates (2026年3月12日). A date must exist and lie between ten years before today and tomorrow, which
/// rules out times, phone numbers, amounts and card expiry dates. The first date on a line that says
/// "date" (Date, Datum, Tarih, Fecha, Data…) wins; else the first date in reading order, leaving out
/// lines about validity (Exp, Valid until, Son kullanma…).
/// </summary>
public static partial class ReceiptDateExtractor
{
    /// <summary>A date at most this many years before today counts.</summary>
    public const int MaxAgeYears = 10;

    /// <summary>Month names and their usual abbreviations, folded (lower case, no accents), with their month.</summary>
    public static IReadOnlyDictionary<string, int> MonthNames { get; } = BuildMonthNames();

    /// <summary>Words of a line that gives the receipt's date (folded).</summary>
    public static IReadOnlyList<string> DateWords { get; } =
        ["date", "datum", "tarih", "tarihi", "fecha", "data", "dated", "issued"];

    /// <summary>Words of a line about something else's date: expiry, validity, returns (folded).</summary>
    public static IReadOnlyList<string> OtherDateWords { get; } =
        ["exp", "expiry", "expires", "expiration", "valid", "until", "gultig", "gecerli", "gecerlilik", "son kullanma", "skt",
         "best before", "use by", "return by", "retour"];

    private static Dictionary<string, int> BuildMonthNames()
    {
        string[][] months =
        [
            ["jan", "january", "januar", "janvier", "janv", "enero", "ene", "gennaio", "gen", "janeiro", "januari", "ocak", "oca"],
            ["feb", "february", "februar", "fevrier", "fev", "fevr", "febrero", "febbraio", "fevereiro", "februari", "subat", "sub"],
            ["mar", "march", "marz", "maerz", "mars", "marzo", "marco", "maart", "mrt", "mart"],
            ["apr", "april", "avril", "avr", "abril", "abr", "aprile", "nisan", "nis"],
            ["may", "mai", "mayo", "maggio", "mag", "maio", "mei", "mayis"],
            ["jun", "june", "juni", "juin", "junio", "giugno", "giu", "junho", "haziran", "haz"],
            ["jul", "july", "juli", "juillet", "juil", "julio", "luglio", "lug", "julho", "temmuz", "tem"],
            ["aug", "august", "aout", "agosto", "ago", "augustus", "agustos", "agu"],
            ["sep", "sept", "september", "septembre", "septiembre", "settembre", "set", "setembro", "eylul", "eyl"],
            ["oct", "october", "oktober", "okt", "octobre", "octubre", "ottobre", "ott", "outubro", "out", "ekim", "eki"],
            ["nov", "november", "novembre", "noviembre", "novembro", "kasim", "kas"],
            ["dec", "december", "dezember", "dez", "decembre", "diciembre", "dicembre", "dezembro", "aralik", "ara"],
        ];
        var names = new Dictionary<string, int>(StringComparer.Ordinal);
        for (int m = 0; m < months.Length; m++)
        {
            foreach (string name in months[m]) names[name] = m + 1;
        }
        return names;
    }

    /// <summary>
    /// The month names as a pattern's alternatives, longest first ("septiembre|...|mar|..."): the
    /// patterns that read a month name take only these, so a word that is not a month ("4 sat 18 apr
    /// 2026") never makes a match that hides the date after it.
    /// </summary>
    internal static string MonthAlternation { get; } =
        string.Join("|", MonthNames.Keys.OrderByDescending(name => name.Length).ThenBy(name => name, StringComparer.Ordinal));

    // ISO: 2026-03-12, 2026/3/5, 2026.03.12 (the same separator twice).
    [GeneratedRegex(@"(?<![0-9])((?:19|20)[0-9]{2})([-./]) ?([0-9]{1,2})\2 ?([0-9]{1,2})(?![0-9])(?![.,][0-9])", RegexOptions.CultureInvariant)]
    private static partial Regex IsoPattern();

    // Day and month as numbers: 12/03/2026, 12.03.26, 1-5-2026.
    [GeneratedRegex(@"(?<![0-9])(?<![0-9][-./])([0-9]{1,2})([-./]) ?([0-9]{1,2})\2 ?([0-9]{4}|[0-9]{2})(?![0-9])(?![.,][0-9])", RegexOptions.CultureInvariant)]
    private static partial Regex NumericPattern();

    // Day, month name, year: 12 Mar 2026, 12-MAR-26, 12. marz 2026, 1st january 2026, 12 de marzo de 2026.
    private static readonly Regex DayNamePattern = new(
        @"(?<![0-9])([0-9]{1,2})(?:st|nd|rd|th)?\.?[-./ ]{0,2}(?:de )?(" + MonthAlternation + @")\.?,?[-./ ]{0,2}(?:de )?((?:19|20)?[0-9]{2})(?![0-9])(?![.,][0-9])",
        RegexOptions.CultureInvariant);

    // Month name, day, year: Mar 12, 2026, march 12th 2026, dec. 3 2025 (four-digit year only).
    private static readonly Regex NameDayPattern = new(
        @"(?<![a-z])(" + MonthAlternation + @")\.? ?([0-9]{1,2})(?:st|nd|rd|th)?,? ?((?:19|20)[0-9]{2})(?![0-9])(?![.,][0-9])",
        RegexOptions.CultureInvariant);

    // Chinese, Japanese, Korean: 2026年3月12日, 2026년 3월 12일.
    [GeneratedRegex(@"((?:19|20)[0-9]{2}) ?[年년] ?([0-9]{1,2}) ?[月월] ?([0-9]{1,2})(?![0-9])", RegexOptions.CultureInvariant)]
    private static partial Regex CjkPattern();

    /// <summary>
    /// The receipt's date in <paramref name="lines"/> (its text in reading order); null when none is
    /// found. <paramref name="today"/> bounds the dates that count; <paramref name="preferDayFirst"/>
    /// reads 03/04/2026 as 3 April (else as 4 March) when nothing else tells: a part above 12 is the
    /// day, and dots (03.04.2026) always put the day first.
    /// </summary>
    public static DocumentDate? FindDate(IReadOnlyList<string> lines, DocumentDate today, bool preferDayFirst)
    {
        var earliest = today.AddingYears(-MaxAgeYears);
        int latest = today.DayNumber + 1;
        DocumentDate? first = null;
        foreach (string line in lines)
        {
            string folded = Fold(line);
            bool other = OtherDateWords.Any(word => ContainsWord(folded, word));
            DocumentDate? found = null;
            foreach (var date in DatesIn(folded, preferDayFirst))
            {
                if (date < earliest || date.DayNumber > latest) continue;
                found = date;
                break;
            }
            if (found is not { } candidate) continue;
            if (DateWords.Any(word => ContainsWord(folded, word)) && !other) return candidate;
            if (!other) first ??= candidate;
        }
        return first;
    }

    /// <summary>
    /// The dates written on one folded line (<see cref="Fold"/>), in the order they appear; the
    /// calendar check is done, the range check is not.
    /// </summary>
    internal static List<DocumentDate> DatesIn(string folded, bool preferDayFirst)
    {
        var found = new List<(int Index, DocumentDate Date)>();
        void Add(int index, int year, int month, int day)
        {
            if (DocumentDate.TryCreate(year, month, day) is { } date) found.Add((index, date));
        }
        foreach (Match m in IsoPattern().Matches(folded))
        {
            Add(m.Index, Number(m.Groups[1].Value), Number(m.Groups[3].Value), Number(m.Groups[4].Value));
        }
        foreach (Match m in CjkPattern().Matches(folded))
        {
            Add(m.Index, Number(m.Groups[1].Value), Number(m.Groups[2].Value), Number(m.Groups[3].Value));
        }
        foreach (Match m in NumericPattern().Matches(folded))
        {
            int a = Number(m.Groups[1].Value), b = Number(m.Groups[3].Value);
            int year = Year(m.Groups[4].Value);
            bool dayFirst = a > 12 ? true
                : b > 12 ? false
                : m.Groups[2].Value == "." || preferDayFirst;
            Add(m.Index, year, dayFirst ? b : a, dayFirst ? a : b);
        }
        foreach (Match m in DayNamePattern.Matches(folded))
        {
            if (MonthNames.TryGetValue(m.Groups[2].Value, out int month))
            {
                Add(m.Index, Year(m.Groups[3].Value), month, Number(m.Groups[1].Value));
            }
        }
        foreach (Match m in NameDayPattern.Matches(folded))
        {
            if (MonthNames.TryGetValue(m.Groups[1].Value, out int month))
            {
                Add(m.Index, Number(m.Groups[3].Value), month, Number(m.Groups[2].Value));
            }
        }
        // In the order they appear; at one place, the patterns' order.
        return found.Select((f, order) => (f.Index, order, f.Date))
                    .OrderBy(f => f.Index).ThenBy(f => f.order)
                    .Select(f => f.Date).ToList();
    }

    private static int Number(string digits) => int.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);

    /// <summary>A four-digit year as written; a two-digit one in this century.</summary>
    private static int Year(string digits) => digits.Length == 2 ? 2000 + Number(digits) : Number(digits);

    /// <summary>Whether <paramref name="word"/> stands in <paramref name="folded"/> with no letter right before or after it.</summary>
    private static bool ContainsWord(string folded, string word)
    {
        int at = 0;
        while ((at = folded.IndexOf(word, at, StringComparison.Ordinal)) >= 0)
        {
            bool before = at == 0 || !IsAsciiLetter(folded[at - 1]);
            int end = at + word.Length;
            bool after = end == folded.Length || !IsAsciiLetter(folded[end]);
            if (before && after) return true;
            at++;
        }
        return false;
    }

    private static bool IsAsciiLetter(char c) => c is >= 'a' and <= 'z';

    /// <summary>
    /// The line as the patterns read it: A–Z in lower case, the letters with accents and the
    /// Turkish letters without them (Ş → s, ı and İ → i, ğ → g), combining accents dropped, every
    /// kind of space a plain space; everything else as it is.
    /// </summary>
    public static string Fold(string line)
    {
        var builder = new StringBuilder(line.Length);
        foreach (char c in line)
        {
            if (c is >= 'A' and <= 'Z')
            {
                builder.Append((char)(c + 32));
                continue;
            }
            if (c is >= '̀' and <= 'ͯ') continue;
            if (c is '\t' or ' ' or ' ' or ' ' or '　') { builder.Append(' '); continue; }
            builder.Append(FoldedLetter(c) ?? c.ToString());
        }
        return builder.ToString();
    }

    private static string? FoldedLetter(char c) => c switch
    {
        'á' or 'à' or 'â' or 'ä' or 'ã' or 'å' or 'Á' or 'À' or 'Â' or 'Ä' or 'Ã' or 'Å' => "a",
        'ç' or 'Ç' => "c",
        'é' or 'è' or 'ê' or 'ë' or 'É' or 'È' or 'Ê' or 'Ë' => "e",
        'ğ' or 'Ğ' => "g",
        'í' or 'ì' or 'î' or 'ï' or 'ı' or 'Í' or 'Ì' or 'Î' or 'Ï' or 'İ' => "i",
        'ñ' or 'Ñ' => "n",
        'ó' or 'ò' or 'ô' or 'ö' or 'õ' or 'Ó' or 'Ò' or 'Ô' or 'Ö' or 'Õ' => "o",
        'ş' or 'Ş' => "s",
        'ú' or 'ù' or 'û' or 'ü' or 'Ú' or 'Ù' or 'Û' or 'Ü' => "u",
        _ => null,
    };

    /// <summary>
    /// Whether a short date pattern (.NET's ShortDatePattern, or the pattern the Mac's formatter
    /// gives for day, month and year) puts the day before the month: "dd.MM.yyyy" and "d/M/yyyy" do,
    /// "M/d/yyyy" and "yyyy-MM-dd" do not.
    /// </summary>
    public static bool PrefersDayFirst(string shortDatePattern)
    {
        int day = shortDatePattern.IndexOf('d'), month = shortDatePattern.IndexOf('M');
        return day >= 0 && (month < 0 || day < month);
    }
}

/// <summary>What the Receipts task shows and saves: titles, the date a file is named by, messages.</summary>
public static class Receipts
{
    /// <summary>"Found 4 receipts", "Found 1 receipt".</summary>
    public static string ReviewTitle(int found) => $"Found {found} receipt{(found == 1 ? "" : "s")}";

    /// <summary>
    /// The review's save button: "Save 3 Receipts", "Save 1 Receipt"; "Save as One PDF" when the
    /// receipts go into one PDF (<see cref="TaskOptions.ReceiptCombine"/>, several kept).
    /// </summary>
    public static string SaveTitle(int included, bool combine, OutputFormat format) =>
        Combines(combine, format, included)
            ? "Save as One PDF"
            : $"Save {included} Receipt{(included == 1 ? "" : "s")}";

    /// <summary>The receipts go into one PDF: asked for, saved as PDF, and more than one.</summary>
    public static bool Combines(bool combine, OutputFormat format, int count) =>
        combine && OutputFormats.PageFormat(format) == OutputFormat.Pdf && count > 1;

    /// <summary>
    /// Whether the files are named by the date printed on each receipt: asked for
    /// (<see cref="TaskOptions.ReceiptNameByDate"/>) and the naming template has {docdate}, the only
    /// place the date goes.
    /// </summary>
    public static bool NamesByDate(ScanSettings settings) =>
        settings.TaskOptions.ReceiptNameByDate && settings.NamingTemplate.Contains("{docdate}", StringComparison.Ordinal);

    /// <summary>
    /// Whether saving reads the receipts' text with OCR: for their date (<see cref="NamesByDate"/>),
    /// a searchable PDF, or the text beside it.
    /// </summary>
    public static bool ReadsText(ScanSettings settings) =>
        NamesByDate(settings)
        || (OutputFormats.PageFormat(settings.Format) == OutputFormat.Pdf && (settings.PdfSearchable || settings.Output.AlsoSaveText));

    /// <summary>
    /// The text of a receipt as the date is looked for in it: the OCR lines in reading order, on a
    /// receipt <paramref name="pixelWidth"/> × <paramref name="pixelHeight"/> pixels.
    /// </summary>
    public static IReadOnlyList<string> TextLines(IReadOnlyList<OcrLine> lines, int pixelWidth, int pixelHeight) =>
        OcrText.ReadingOrder(lines, Math.Max(1, pixelWidth), Math.Max(1, pixelHeight)).Select(l => l.Text).ToList();

    /// <summary>The date one PDF of several receipts is named by: the earliest found; null when none was.</summary>
    public static DocumentDate? CombinedDate(IEnumerable<DocumentDate?> dates)
    {
        DocumentDate? earliest = null;
        foreach (var date in dates)
        {
            if (date is { } d && (earliest is not { } e || d < e)) earliest = d;
        }
        return earliest;
    }

    /// <summary>
    /// After saving: "Saved 3 receipts: a.pdf, b.pdf, c.pdf", "Saved 3 receipts in one PDF: a.pdf",
    /// with ". No date was found on 1 of them; it is named by today's date." when receipts were to be
    /// named by their date (<paramref name="undated"/> of them were not). One PDF is named by the
    /// earliest date found, so it gets the note only when no receipt had a date.
    /// </summary>
    public static string SavedMessage(int count, IReadOnlyList<string> fileNames, bool combined, int undated)
    {
        string what = $"{count} receipt{(count == 1 ? "" : "s")}";
        string saved = combined ? $"Saved {what} in one PDF: {fileNames.FirstOrDefault()}" : $"Saved {what}: {string.Join(", ", fileNames)}";
        if (undated <= 0 || (combined && undated < count)) return saved;
        string note = combined ? "No date was found on them; the PDF is named by today's date."
            : count == 1 ? "No date was found on it; it is named by today's date."
            : undated == count ? "No date was found on them; they are named by today's date."
            : $"No date was found on {undated} of them; {(undated == 1 ? "it is" : "they are")} named by today's date.";
        return $"{saved}. {note}";
    }
}
