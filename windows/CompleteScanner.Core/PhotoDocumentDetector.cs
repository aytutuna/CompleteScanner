namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/PhotoDocumentDetector.swift: the same steps, constants
// and arithmetic in the same order (integers for the blur and the gradient, + − × ÷ and square
// roots on doubles, no trigonometry: the angle table is built from two constants), and every sort
// with a tie-break, so both platforms find the same corners.

/// <summary>Why <see cref="PhotoDocumentDetector.Detect"/> returned no page.</summary>
public enum PhotoDocumentRejection
{
    /// <summary>A page was found.</summary>
    None,
    /// <summary>Nothing in the photo looks like the outline of a sheet.</summary>
    NothingFound,
    /// <summary>The page runs off the photo: a corner lies outside the frame, or an edge along its border.</summary>
    CutOff,
    /// <summary>Two different sheets of about the same size are equally likely.</summary>
    Ambiguous,
    /// <summary>Something sheet-like was seen, but not clearly enough to trust.</summary>
    LowConfidence,
}

/// <summary>Options of <see cref="PhotoDocumentDetector"/>; the defaults are its constants.</summary>
public sealed record PhotoDocumentOptions
{
    /// <summary>The photo is analysed with its long side at most this many pixels.</summary>
    public int AnalysisLongSide { get; init; } = PhotoDocumentDetector.AnalysisLongSide;
    /// <summary>The page covers at least this share of the photo.</summary>
    public double MinAreaShare { get; init; } = PhotoDocumentDetector.MinAreaShare;
    /// <summary>A page is taken when its score reaches this (0...1).</summary>
    public double AcceptScore { get; init; } = PhotoDocumentDetector.AcceptScore;
    /// <summary>…and every edge's own score reaches this.</summary>
    public double MinSideScore { get; init; } = PhotoDocumentDetector.MinSideScore;
    /// <summary>A page's shape matches a known size within this share.</summary>
    public double PaperAspectTolerance { get; init; } = PerspectiveCorrector.PaperAspectTolerance;

    public static PhotoDocumentOptions Default { get; } = new();
}

/// <summary>What <see cref="PhotoDocumentDetector.Detect"/> found.</summary>
/// <param name="Quad">The page's corners in the photo's pixels (see <see cref="Core.Quad"/>); null when none was taken.</param>
/// <param name="Confidence">The page's score, 0...1 (0 when nothing was found).</param>
/// <param name="Rejection">Why no page was taken, or <see cref="PhotoDocumentRejection.None"/>.</param>
/// <param name="Candidate">
/// The best outline seen when none was taken (cut off, ambiguous, unclear), in the photo's pixels,
/// for a live view's hint ("move back"); null when nothing was seen.
/// </param>
/// <param name="Aspect">The page's shape (<see cref="PerspectiveCorrector.EstimateAspect"/>) when a page was taken.</param>
/// <param name="Paper">The known size the page's shape matches, if any.</param>
public sealed record PhotoDocumentDetection(Quad? Quad, double Confidence, PhotoDocumentRejection Rejection,
                                            Quad? Candidate, AspectEstimate? Aspect, PaperMatch? Paper)
{
    public bool Found => Quad is not null;

    public static PhotoDocumentDetection Nothing { get; } =
        new(null, 0, PhotoDocumentRejection.NothingFound, null, null, null);
}

/// <summary>
/// Finds the four corners of a sheet of paper in a camera photo: a page seen at an angle (any
/// convex quadrilateral, not only a turned rectangle) on a table that may be textured, dark,
/// light or close to the paper's own color, with the phone's shadow, uneven light and glare.
///
/// The photo is analysed at <see cref="AnalysisLongSide"/> px: each color channel is smoothed
/// (1-4-6-4-1 both ways) and the strongest channel's gradient kept, so an edge between colors of
/// the same brightness still shows. Two kinds of candidate outlines are made: straight edges
/// found by a Hough transform on the thinned edges (each edge pixel votes within 4° of its own
/// direction, less when crowded by others as in print), refitted to their edge pixels and
/// combined in pairs of near-parallel opposite sides; and the largest regions that stand out
/// from the frame's border color or are brighter than the rest (Otsu, at half resolution),
/// whose convex hull gives the four-cornered shape of largest area. Every outline is scored on
/// its four edges (<see cref="SideScore"/>: the share of points along each edge where the
/// gradient across it, of the edge's sign, stands out from the texture outside; the color
/// difference between just inside and just outside; whether the edge runs on past its
/// corners), its corner angles, its shape (<see cref="PerspectiveCorrector.EstimateAspect"/>; a
/// known paper size earns a small bonus), its size and whether its edges share one polarity;
/// the best are refitted to the edge points along them with sub-pixel precision, then tried
/// with each edge swapped for another straight edge. A page is taken only when it scores at
/// least <see cref="AcceptScore"/> with every edge at least <see cref="MinSideScore"/>, lies
/// wholly in the frame, and no different sheet scores nearly as well: of near-identical
/// outlines the outer one is taken (a card's edge rather than the picture printed on it), of
/// two sheets one inside or across the other the better-scoring one (the sheet on top, seen
/// whole), of two sheets apart the larger when it is at least <see cref="LargerPageRatio"/>
/// times the other, and none (<see cref="PhotoDocumentRejection.Ambiguous"/>) when they are of
/// about the same size; otherwise none is returned, with the reason.
/// </summary>
public static class PhotoDocumentDetector
{
    /// <summary>The photo is analysed with its long side at most this many pixels.</summary>
    public const int AnalysisLongSide = 1000;
    /// <summary>The page covers at least this share of the photo.</summary>
    public const double MinAreaShare = 0.05;
    /// <summary>…and at most this share.</summary>
    public const double MaxAreaShare = 0.995;
    /// <summary>A page is taken when its score reaches this.</summary>
    public const double AcceptScore = 0.55;
    /// <summary>…and every edge's own score reaches this.</summary>
    public const double MinSideScore = 0.35;
    /// <summary>Below the acceptance, an outline scoring at least this is reported as an unclear candidate.</summary>
    public const double CandidateScore = 0.25;
    /// <summary>A pixel is an edge when its gradient is at least this many levels per pixel (after smoothing).</summary>
    public const double EdgeThreshold = 3.0;
    /// <summary>An edge pixel's vote in the Hough transform is its gradient, at most this.</summary>
    public const double VoteCap = 20;
    /// <summary>Each edge pixel votes for directions within this many degrees of its own.</summary>
    public const int HoughWindow = 4;
    /// <summary>An edge pixel's Hough vote counts less the more edge pixels lie within this many pixels of it…</summary>
    public const int IsolationRadius = 4;
    /// <summary>…down to this share (1.5 − 2.5 × the share of edge pixels around it, at most 1).</summary>
    public const double IsolationFloor = 0.25;
    /// <summary>At most this many straight edges are combined into outlines…</summary>
    public const int MaxLines = 28;
    /// <summary>…and this many are tried in place of an edge of the best outlines (<see cref="SwapKeep"/> of them), within 30° of it (|cos| at least <see cref="SwapMinCos"/>).</summary>
    public const int SwapLines = 60;
    public const int SwapKeep = 4;
    public const double SwapMinCos = 0.866;
    /// <summary>A swapped-in edge scoring this much less than the edge it replaces is not tried further.</summary>
    public const double SwapSideMargin = 0.2;
    /// <summary>
    /// The search near an edge (<see cref="CorridorLines"/>): edge pixels at most this many px
    /// outside its neighbors' lines, directions within <see cref="CorridorBins"/>° of it, the
    /// <see cref="CorridorPeaks"/> strongest lines and the <see cref="CorridorOutermost"/> outermost.
    /// </summary>
    public const double CorridorMargin = 3;
    /// <summary>Only an edge scoring below this is searched near (a stronger one is taken as found).</summary>
    public const double CorridorBelow = 0.95;
    public const int CorridorBins = 15;
    /// <summary>…and no deeper inside the outline than this share of its depth there.</summary>
    public const double CorridorDepth = 0.3;
    public const int CorridorPeaks = 8;
    public const int CorridorOutermost = 2;
    /// <summary>An outermost line is offered only with at least this share of the strongest one's votes.</summary>
    public const double CorridorOutermostShare = 0.15;
    /// <summary>A straight edge needs votes worth at least this share of the frame's short side at <see cref="EdgeThreshold"/>.</summary>
    public const double MinLineShare = 0.08;
    /// <summary>Opposite sides of an outline differ in direction by at most 40° (|cos| at least this).</summary>
    public const double OppositeMinCos = 0.766;
    /// <summary>Corners of an outline are between 40° and 140° (|cos| at most this).</summary>
    public const double MaxCornerCos = 0.766;
    /// <summary>Corners between 60° and 120° (|cos| at most this) cost nothing; sharper ones cost up to half the score.</summary>
    public const double FreeCornerCos = 0.5;
    /// <summary>Corners of candidate outlines may lie this share of the frame outside it (a sheet cut off by the frame).</summary>
    public const double OutsideShare = 0.25;
    /// <summary>A corner more than this many analysis pixels outside the frame cuts the page off.</summary>
    public const double CutOffTolerance = 1.0;
    /// <summary>
    /// Edge points nearer the frame's border than this many analysis pixels are not measured: an
    /// edge lying there is where the frame cuts the page off (a page's own edge further in is).
    /// </summary>
    public const double BorderBand = 2.0;
    /// <summary>Points sampled along each edge when scoring (fewer when screening line combinations).</summary>
    public const int ScoreSamples = 48;
    public const int ScreenSamples = 12;
    /// <summary>Distinct outlines kept after screening the line combinations, and refitted after scoring.</summary>
    public const int ScreenKeep = 30;
    public const int RefineKeep = 8;
    /// <summary>An edge that runs on past its corners loses up to this share of its score…</summary>
    public const double ExtensionPenalty = 0.6;
    /// <summary>…judged over this share of its length beyond each corner, and at least <see cref="ExtensionMin"/> px.</summary>
    public const double ExtensionShare = 0.2;
    public const double ExtensionMin = 8;
    /// <summary>An edge point must be this many times stronger than the texture <see cref="TextureNear"/> to <see cref="TextureFar"/> px outside the edge.</summary>
    public const double TextureRatio = 2.0;
    public const int TextureNear = 4;
    public const int TextureFar = 7;
    /// <summary>A refit keeps the sign of the gradient found within this many pixels of the outline as it is.</summary>
    public const int PolarityReach = 2;
    /// <summary>An edge point counts when the gradient within this many pixels across the edge is strong enough.</summary>
    public const int SupportReach = 2;
    /// <summary>The color difference across an edge (mean of R, G, B levels) that counts in full…</summary>
    public const double ContrastFull = 16;
    /// <summary>…and the share of an edge's support that counts with no difference at all (a line drawn on the table, a seam between planks).</summary>
    public const double ContrastFloor = 0.25;
    /// <summary>Shapes up to this long-over-short ratio are plausible; longer ones cost up to half the score until <see cref="MaxLongOverShort"/>.</summary>
    public const double PlainLongOverShort = 4;
    public const double MaxLongOverShort = 8;
    /// <summary>
    /// An outline whose edges do not all have the same polarity (outside darker on some, brighter
    /// on others) counts this share of its score: a sheet's edges all face the same table.
    /// </summary>
    public const double MixedPolarityFactor = 0.75;
    /// <summary>A partial outline (one edge outside the frame, unscored) counts this share of its score.</summary>
    public const double PartialFactor = 0.9;
    /// <summary>The score bonus for a shape that matches a known paper size.</summary>
    public const double PaperBonus = 0.04;
    /// <summary>The score bonus for an outline near the hint (a previous frame's page)…</summary>
    public const double HintBonus = 0.05;
    /// <summary>…within this share of the frame's diagonal.</summary>
    public const double HintShare = 0.05;
    /// <summary>Of two near-identical outlines the outer one is kept when it scores at most this much less.</summary>
    public const double OuterMargin = 0.1;
    /// <summary>Two outlines are different sheets when their corners are this share of the diagonal apart on average.</summary>
    public const double DistinctShare = 0.08;
    /// <summary>Screened line combinations closer than this share of the diagonal are the same.</summary>
    public const double ScreenDuplicateShare = 0.005;
    /// <summary>Outlines closer than this share of the diagonal are the same outline.</summary>
    public const double DuplicateShare = 0.02;
    /// <summary>Another sheet scoring within this of the best makes the choice uncertain…</summary>
    public const double AmbiguityMargin = 0.1;
    /// <summary>…unless it overlaps the best (the best, on top, stays) or one is at least this many times the other's area (the larger is taken).</summary>
    public const double LargerPageRatio = 1.4;
    /// <summary>The outline of a region is simplified to at most this many corners before the largest quad is sought.</summary>
    public const int MaxHullVertices = 40;
    /// <summary>A region must differ from the border color by at least this many levels.</summary>
    public const int MinRegionContrast = 14;

    // cos and sin of 0°, 1°, …, 180°, built by turning (1, 0) by one degree at a time.
    private const double Cos1 = 0.99984769515639127;
    private const double Sin1 = 0.017452406437283512;
    private static readonly double[] CosTable = BuildTable(true);
    private static readonly double[] SinTable = BuildTable(false);

    private static double[] BuildTable(bool cosine)
    {
        var c = new double[181];
        var s = new double[181];
        c[0] = 1;
        s[0] = 0;
        for (int k = 1; k <= 180; k++)
        {
            c[k] = c[k - 1] * Cos1 - s[k - 1] * Sin1;
            s[k] = s[k - 1] * Cos1 + c[k - 1] * Sin1;
        }
        return cosine ? c : s;
    }

    /// <summary>
    /// The page in <paramref name="image"/>, or none with the reason. <paramref name="hint"/>, a
    /// page found in a previous video frame (in this photo's pixels), is tried as an outline of its
    /// own and favors outlines near it.
    /// </summary>
    public static PhotoDocumentDetection Detect(RgbaImage image, Quad? hint = null, PhotoDocumentOptions? options = null)
    {
        var o = options ?? PhotoDocumentOptions.Default;
        int longSide = Math.Max(image.Width, image.Height);
        var small = image;
        if (longSide > o.AnalysisLongSide && o.AnalysisLongSide > 0)
        {
            double s = (double)o.AnalysisLongSide / longSide;
            int aw = Math.Max(1, (int)Math.Round(image.Width * s, MidpointRounding.AwayFromZero));
            int ah = Math.Max(1, (int)Math.Round(image.Height * s, MidpointRounding.AwayFromZero));
            small = image.Resized(aw, ah);
        }
        if (small.Width < 16 || small.Height < 16) return PhotoDocumentDetection.Nothing;
        double toFullX = (double)image.Width / small.Width, toFullY = (double)image.Height / small.Height;
        Quad? smallHint = hint is { } h ? h.Scaled(1 / toFullX, 1 / toFullY) : null;

        var field = Field.Build(small);
        var found = Decide(field, Pool(field, smallHint, o), o);
        Quad? quad = found.Quad?.Scaled(toFullX, toFullY);
        Quad? candidate = found.Candidate?.Scaled(toFullX, toFullY);
        AspectEstimate? aspect = null;
        PaperMatch? paper = null;
        if (quad is { } q)
        {
            var estimate = PerspectiveCorrector.EstimateAspect(q, image.Width, image.Height);
            aspect = estimate;
            paper = PerspectiveCorrector.MatchPaper(estimate.LongOverShort, o.PaperAspectTolerance);
        }
        return new PhotoDocumentDetection(quad, found.Confidence, found.Rejection, candidate, aspect, paper);
    }

    // MARK: - The analysis image

    /// <summary>The smoothed colors and the gradient of the analysis image.</summary>
    internal sealed class Field
    {
        public int W, H;
        /// <summary>Smoothed channels, 256 × the level.</summary>
        public int[] R = [], G = [], B = [];
        /// <summary>The strongest channel's gradient, in levels per pixel (0 on the outermost pixels).</summary>
        public double[] Gx = [], Gy = [], Mag = [];

        public double Diagonal => Math.Sqrt((double)W * W + (double)H * H);

        public static Field Build(RgbaImage image)
        {
            int w = image.Width, h = image.Height;
            var f = new Field { W = w, H = h };
            f.R = Smooth(image.Pixels, w, h, 0);
            f.G = Smooth(image.Pixels, w, h, 1);
            f.B = Smooth(image.Pixels, w, h, 2);
            f.Gx = new double[w * h];
            f.Gy = new double[w * h];
            f.Mag = new double[w * h];
            for (int y = 1; y < h - 1; y++)
            {
                for (int x = 1; x < w - 1; x++)
                {
                    int i = y * w + x;
                    int bestX = 0, bestY = 0;
                    long bestM = -1;
                    for (int c = 0; c < 3; c++)
                    {
                        var ch = c == 0 ? f.R : c == 1 ? f.G : f.B;
                        int gx = (ch[i - w + 1] + 2 * ch[i + 1] + ch[i + w + 1]) - (ch[i - w - 1] + 2 * ch[i - 1] + ch[i + w - 1]);
                        int gy = (ch[i + w - 1] + 2 * ch[i + w] + ch[i + w + 1]) - (ch[i - w - 1] + 2 * ch[i - w] + ch[i - w + 1]);
                        long m = (long)gx * gx + (long)gy * gy;
                        if (m > bestM)
                        {
                            bestM = m;
                            bestX = gx;
                            bestY = gy;
                        }
                    }
                    double dx = bestX / 2048.0, dy = bestY / 2048.0;
                    f.Gx[i] = dx;
                    f.Gy[i] = dy;
                    f.Mag[i] = Math.Sqrt(dx * dx + dy * dy);
                }
            }
            return f;
        }

        /// <summary>Channel <paramref name="channel"/> smoothed by 1-4-6-4-1 across and down (edges repeated): 256 × the level.</summary>
        private static int[] Smooth(byte[] rgba, int w, int h, int channel)
        {
            // Each row smoothed across into rows 2...h+1 of a buffer padded by two repeated rows above and below.
            var row = new int[w + 4];
            var across = new int[w * (h + 4)];
            for (int y = 0; y < h; y++)
            {
                int src = y * w;
                for (int x = 0; x < w; x++) row[x + 2] = rgba[(src + x) * 4 + channel];
                row[0] = row[2];
                row[1] = row[2];
                row[w + 2] = row[w + 1];
                row[w + 3] = row[w + 1];
                int dst = (y + 2) * w;
                for (int x = 0; x < w; x++) across[dst + x] = row[x] + 4 * row[x + 1] + 6 * row[x + 2] + 4 * row[x + 3] + row[x + 4];
            }
            Array.Copy(across, 2 * w, across, 0, w);
            Array.Copy(across, 2 * w, across, w, w);
            Array.Copy(across, (h + 1) * w, across, (h + 2) * w, w);
            Array.Copy(across, (h + 1) * w, across, (h + 3) * w, w);
            var output = new int[w * h];
            for (int y = 0; y < h; y++)
            {
                int a = y * w, b = a + w, c = b + w, d = c + w, e = d + w;
                for (int x = 0; x < w; x++) output[a + x] = across[a + x] + 4 * across[b + x] + 6 * across[c + x] + 4 * across[d + x] + across[e + x];
            }
            return output;
        }

        /// <summary>The gradient at a continuous point, bilinear between pixel centers (clamped inside the gradient's area).</summary>
        public (double Gx, double Gy) GradientAt(double x, double y)
        {
            double fx = x - 0.5, fy = y - 0.5;
            double cx = Math.Clamp(fx, 1, W - 2.000001), cy = Math.Clamp(fy, 1, H - 2.000001);
            double x0f = Math.Floor(cx), y0f = Math.Floor(cy);
            int x0 = (int)x0f, y0 = (int)y0f;
            double tx = cx - x0f, ty = cy - y0f;
            int i = y0 * W + x0;
            double gx = (Gx[i] * (1 - tx) + Gx[i + 1] * tx) * (1 - ty) + (Gx[i + W] * (1 - tx) + Gx[i + W + 1] * tx) * ty;
            double gy = (Gy[i] * (1 - tx) + Gy[i + 1] * tx) * (1 - ty) + (Gy[i + W] * (1 - tx) + Gy[i + W + 1] * tx) * ty;
            return (gx, gy);
        }
    }

    /// <summary>A straight line n · p = Rho with a unit normal.</summary>
    internal readonly record struct Line(double Nx, double Ny, double Rho)
    {
        public double Distance(double x, double y) => Nx * x + Ny * y - Rho;

        public static Line Through(PointD p, PointD q)
        {
            double dx = q.X - p.X, dy = q.Y - p.Y;
            double len = Math.Sqrt(dx * dx + dy * dy);
            double nx = dy / len, ny = -dx / len;
            return new Line(nx, ny, nx * p.X + ny * p.Y);
        }

        public static PointD? Intersect(Line a, Line b)
        {
            double det = a.Nx * b.Ny - a.Ny * b.Nx;
            if (Math.Abs(det) < 1e-9) return null;
            return new PointD((a.Rho * b.Ny - b.Rho * a.Ny) / det, (a.Nx * b.Rho - b.Nx * a.Rho) / det);
        }
    }

    // MARK: - Finding the page

    /// <summary>An outline's score; <see cref="Partial"/> when one edge lies outside the frame or along its border (<see cref="BorderBand"/>), unscored.</summary>
    private readonly record struct Score(double Total, double Edge, double MinSide, bool Valid, bool Partial = false);

    private sealed class Candidate(Quad quad, int order)
    {
        public Quad Quad = quad;
        public Score Score;
        public readonly int Order = order;
    }

    private readonly record struct Found(Quad? Quad, double Confidence, PhotoDocumentRejection Rejection, Quad? Candidate);

    /// <summary>The scored outlines of the analysis image, best first (for tests and tuning): quad, score, edge score, weakest edge.</summary>
    internal static List<(Quad Quad, double Total, double Edge, double MinSide)> Explain(RgbaImage analysisImage, Quad? hint = null, PhotoDocumentOptions? options = null)
    {
        var f = Field.Build(analysisImage);
        var list = new List<(Quad, double, double, double)>();
        foreach (var c in Pool(f, hint, options ?? PhotoDocumentOptions.Default)) list.Add((c.Quad, c.Score.Total, c.Score.Edge, c.Score.MinSide));
        return list;
    }

    /// <summary>How <paramref name="quad"/> scores on the analysis image (for tests and tuning): the score, the edge score and each edge's own.</summary>
    internal static (double Total, double Edge, double MinSide, double[] Sides) ScoreOf(RgbaImage analysisImage, Quad quad, PhotoDocumentOptions? options = null)
    {
        var f = Field.Build(analysisImage);
        var score = ScoreQuad(f, quad, ScoreSamples, null, options ?? PhotoDocumentOptions.Default);
        var sides = new double[4];
        for (int i = 0; i < 4; i++) sides[i] = SideScore(f, quad, i, ScoreSamples) is { } side ? side.Value * side.Sign : 0;
        return (score.Total, score.Edge, score.MinSide, sides);
    }

    /// <summary>Every candidate outline, scored, refitted, best first, without repeats.</summary>
    private static List<Candidate> Pool(Field f, Quad? hint, PhotoDocumentOptions o)
    {
        double diag = f.Diagonal;
        var pool = new List<Candidate>();
        int order = 0;

        // Straight edges combined into outlines, screened with a few samples per edge.
        var edges = FindEdges(f);
        var allLines = FindLines(f, edges, SwapLines);
        var lines = allLines.Count > MaxLines ? allLines.GetRange(0, MaxLines) : allLines;
        var screened = new List<Candidate>();
        foreach (var q in LineQuads(f, lines, o))
        {
            var c = new Candidate(q, order++);
            c.Score = ScoreQuad(f, q, ScreenSamples, hint, o);
            if (c.Score.Valid) screened.Add(c);
        }
        SortByScore(screened);
        var kept = new List<Candidate>();
        foreach (var c in screened)
        {
            if (kept.Count >= ScreenKeep) break;
            bool repeat = false;
            foreach (var k in kept)
            {
                if (CornerDistance(c.Quad, k.Quad) < ScreenDuplicateShare * diag)
                {
                    repeat = true;
                    break;
                }
            }
            if (!repeat) kept.Add(c);
        }
        foreach (var c in kept)
        {
            c.Score = ScoreQuad(f, c.Quad, ScoreSamples, hint, o);
            if (c.Score.Valid) pool.Add(c);
        }

        // Regions standing out from the table, refined to their edges first (their outline is rough).
        double regionReach = Math.Max(4, Math.Round(0.02 * diag));
        foreach (var q in RegionQuads(f, o))
        {
            var refined = RefineQuad(f, q, regionReach);
            if (refined is { } r) refined = RefineQuad(f, r, 2) ?? r;
            var c = new Candidate(refined ?? q, order++);
            c.Score = ScoreQuad(f, c.Quad, ScoreSamples, hint, o);
            if (c.Score.Valid) pool.Add(c);
        }

        // The previous frame's page.
        if (hint is { } hq && hq.IsConvex)
        {
            var refined = RefineQuad(f, hq, regionReach);
            if (refined is { } r) refined = RefineQuad(f, r, 2) ?? r;
            var c = new Candidate(refined ?? hq, order++);
            c.Score = ScoreQuad(f, c.Quad, ScoreSamples, hint, o);
            if (c.Score.Valid) pool.Add(c);
        }

        // The best outlines refitted to their edges.
        SortByScore(pool);
        var distinct = Distinct(pool, DuplicateShare * diag);
        var ranked = new List<Candidate>();
        for (int i = 0; i < distinct.Count; i++)
        {
            var c = distinct[i];
            ranked.Add(c);
            if (i >= RefineKeep) continue;
            if (RefineQuad(f, c.Quad, 3) is { } refined)
            {
                var r = new Candidate(refined, c.Order);
                r.Score = ScoreQuad(f, refined, ScoreSamples, hint, o);
                if (r.Score.Valid && r.Score.Total >= c.Score.Total) ranked[^1] = r;
            }
        }
        SortByScore(ranked);
        ranked = Distinct(ranked, DuplicateShare * diag);

        // The best outlines with an edge swapped for another straight edge where that scores better
        // (an outline that took a line printed on the page, or missed a weak edge).
        int count = ranked.Count;
        for (int i = 0; i < count && i < SwapKeep; i++)
        {
            var swapped = SwapSides(f, ranked[i], allLines, edges, hint, o);
            if (ReferenceEquals(swapped, ranked[i])) continue;
            if (RefineQuad(f, swapped.Quad, 3) is { } refined)
            {
                var r = new Candidate(refined, swapped.Order);
                r.Score = ScoreQuad(f, refined, ScoreSamples, hint, o);
                if (r.Score.Valid && r.Score.Total >= swapped.Score.Total) swapped = r;
            }
            ranked.Add(swapped);
        }
        SortByScore(ranked);
        ranked = Distinct(ranked, DuplicateShare * diag);
        SortByScore(ranked);
        return ranked;
    }

    /// <summary>
    /// <paramref name="c"/> with one edge at a time replaced by another straight edge running within
    /// 30° of it, while that scores better (two rounds at most): one of the image's straight edges
    /// or one found near that edge (<see cref="CorridorLines"/>, a weak edge the print elsewhere
    /// outvoted); <paramref name="c"/> itself when no swap helps.
    /// </summary>
    private static Candidate SwapSides(Field f, Candidate c, List<Line> globalLines, EdgeSet edges, Quad? hint, PhotoDocumentOptions o)
    {
        var best = c;
        double frame = (double)f.W * f.H;
        double minX = -OutsideShare * f.W, maxX = (1 + OutsideShare) * f.W;
        double minY = -OutsideShare * f.H, maxY = (1 + OutsideShare) * f.H;
        for (int round = 0; round < 2; round++)
        {
            var q = best.Quad;
            var sides = new Line[4];
            for (int i = 0; i < 4; i++) sides[i] = Line.Through(q[i], q[i + 1]);
            Candidate? roundBest = null;
            double bar = best.Score.Total;
            for (int side = 0; side < 4; side++)
            {
                double held = SideScore(f, q, side, ScreenSamples)?.Value ?? 0;
                var lines = new List<Line>(globalLines);
                if (held < CorridorBelow) lines.AddRange(CorridorLines(f, edges, q, side));
                foreach (var line in lines)
                {
                    if (Math.Abs(line.Nx * sides[side].Nx + line.Ny * sides[side].Ny) < SwapMinCos) continue;
                    if (Line.Intersect(sides[(side + 3) & 3], line) is not { } a) continue;
                    if (Line.Intersect(line, sides[(side + 1) & 3]) is not { } b) continue;
                    if (a.X < minX || a.X > maxX || a.Y < minY || a.Y > maxY || b.X < minX || b.X > maxX || b.Y < minY || b.Y > maxY) continue;
                    var corners = q.Corners;
                    corners[side] = a;
                    corners[(side + 1) & 3] = b;
                    var candidate = new Quad(corners[0], corners[1], corners[2], corners[3]);
                    if (!candidate.IsConvex) continue;
                    double share = candidate.Area / frame;
                    if (share < o.MinAreaShare || share > MaxAreaShare) continue;
                    // The new edge itself first: much weaker than the one it replaces, it cannot help.
                    if ((SideScore(f, candidate, side, ScreenSamples)?.Value ?? 0) < held - SwapSideMargin) continue;
                    var screen = ScoreQuad(f, candidate, ScreenSamples, hint, o);
                    if (!screen.Valid || screen.Total <= bar - 0.1) continue;
                    var score = ScoreQuad(f, candidate, ScoreSamples, hint, o);
                    if (!score.Valid || score.Total <= bar + 1e-9) continue;
                    bar = score.Total;
                    roundBest = new Candidate(Quad.FromCorners(corners), c.Order) { Score = score };
                }
            }
            if (roundBest is null) break;
            best = roundBest;
        }
        return best;
    }

    /// <summary>The choice among the scored outlines (best first), as the class summary says.</summary>
    private static Found Decide(Field f, List<Candidate> pool, PhotoDocumentOptions o)
    {
        if (pool.Count == 0) return new Found(null, 0, PhotoDocumentRejection.NothingFound, null);
        double diag = f.Diagonal;
        var accepted = new List<Candidate>();
        foreach (var c in pool)
        {
            if (c.Score.Total >= o.AcceptScore && c.Score.MinSide >= o.MinSideScore) accepted.Add(c);
        }
        if (accepted.Count == 0)
        {
            var best = pool[0];
            if (best.Score.Total < CandidateScore) return new Found(null, 0, PhotoDocumentRejection.NothingFound, null);
            return new Found(null, 0, PhotoDocumentRejection.LowConfidence, best.Quad);
        }
        var top = accepted[0];
        if (!top.Quad.IsInside(f.W, f.H, -CutOffTolerance) || top.Score.Partial)
        {
            return new Found(null, 0, PhotoDocumentRejection.CutOff, top.Quad);
        }
        var chosen = top;
        for (int i = 1; i < accepted.Count; i++)
        {
            var other = accepted[i];
            if (other.Score.Total < top.Score.Total - AmbiguityMargin) break;
            if (!other.Quad.IsInside(f.W, f.H, -CutOffTolerance) || other.Score.Partial) continue;
            double tolerance = DuplicateShare * diag;
            if (CornerDistance(other.Quad, chosen.Quad) < DistinctShare * diag)
            {
                // The same sheet: its outer outline (a card's edge rather than the picture on it) when about as good.
                if (other.Score.Total >= chosen.Score.Total - OuterMargin && ContainsAll(other.Quad, chosen.Quad, 1.0)) chosen = other;
                continue;
            }
            // One inside the other or overlapping it (a sheet on a larger one, a frame printed on the
            // page, a sheet lying across another): the better one, fully seen, stays.
            if (ContainsAll(chosen.Quad, other.Quad, tolerance) || ContainsAll(other.Quad, chosen.Quad, tolerance)) continue;
            if (!Separated(chosen.Quad, other.Quad, 0)) continue;
            double a = chosen.Quad.Area, b = other.Quad.Area;
            if (Math.Max(a, b) >= LargerPageRatio * Math.Min(a, b))
            {
                if (b > a) chosen = other;
                continue;
            }
            return new Found(null, 0, PhotoDocumentRejection.Ambiguous, top.Quad);
        }
        return new Found(chosen.Quad, Math.Clamp(chosen.Score.Total, 0, 1), PhotoDocumentRejection.None, null);
    }

    /// <summary>A straight line (one of their edges' lines) runs between the two convex outlines, at least <paramref name="gap"/> from both.</summary>
    internal static bool Separated(Quad a, Quad b, double gap)
    {
        for (int pass = 0; pass < 2; pass++)
        {
            var p = pass == 0 ? a : b;
            var o = pass == 0 ? b : a;
            for (int i = 0; i < 4; i++)
            {
                var s = p[i];
                var e = p[i + 1];
                double len = s.DistanceTo(e);
                if (len <= 0) continue;
                bool all = true;
                for (int j = 0; j < 4 && all; j++)
                {
                    var c = o[j];
                    double outside = ((e.X - s.X) * (s.Y - c.Y) - (e.Y - s.Y) * (s.X - c.X)) / len;
                    if (outside < gap) all = false;
                }
                if (all) return true;
            }
        }
        return false;
    }

    private static bool ContainsAll(Quad outer, Quad inner, double tolerance)
    {
        for (int i = 0; i < 4; i++)
        {
            if (!outer.Contains(inner[i], tolerance)) return false;
        }
        return true;
    }

    /// <summary>The mean distance between the corners of two outlines, whichever corner each starts from.</summary>
    internal static double CornerDistance(Quad a, Quad b)
    {
        double best = double.MaxValue;
        for (int shift = 0; shift < 4; shift++)
        {
            double sum = 0;
            for (int i = 0; i < 4; i++) sum += a[i].DistanceTo(b[i + shift]);
            best = Math.Min(best, sum / 4);
        }
        return best;
    }

    private static void SortByScore(List<Candidate> list) =>
        list.Sort((a, b) => a.Score.Total != b.Score.Total ? b.Score.Total.CompareTo(a.Score.Total) : a.Order.CompareTo(b.Order));

    /// <summary>
    /// The outlines (best first) without those within <paramref name="radius"/> of a better one; of
    /// such near-identical outlines the one kept is the outer one when it scores within
    /// <see cref="OuterMargin"/> of the best (a page's edge rather than a bar printed just inside it).
    /// </summary>
    private static List<Candidate> Distinct(List<Candidate> sorted, double radius)
    {
        var kept = new List<Candidate>();
        var best = new List<double>();
        foreach (var c in sorted)
        {
            int duplicate = -1;
            for (int k = 0; k < kept.Count; k++)
            {
                if (CornerDistance(c.Quad, kept[k].Quad) < radius)
                {
                    duplicate = k;
                    break;
                }
            }
            if (duplicate < 0)
            {
                kept.Add(c);
                best.Add(c.Score.Total);
                continue;
            }
            var held = kept[duplicate];
            if (c.Score.Total >= best[duplicate] - OuterMargin && c.Quad.Area > held.Quad.Area
                && ContainsAll(c.Quad, held.Quad, 1.0))
            {
                kept[duplicate] = c;
            }
        }
        return kept;
    }

    // MARK: - Scoring

    /// <summary>
    /// How much an outline looks like a sheet's: its edges (<see cref="SideScore"/>), half on
    /// average and half on the weakest, times its corner angles, its shape and its size, plus
    /// the bonuses for a known paper size and for lying near the hint. An edge outside
    /// the frame or along its border is left out and the outline is partial (a sheet the frame cuts off), its score
    /// times <see cref="PartialFactor"/>; edges of mixed polarity cost <see cref="MixedPolarityFactor"/>. Not valid
    /// (and 0) for an outline that is not convex, has a corner outside 40°–140°, a shape beyond
    /// <see cref="MaxLongOverShort"/>, a size outside the limits, or two edges outside the frame.
    /// </summary>
    private static Score ScoreQuad(Field f, Quad q, int samples, Quad? hint, PhotoDocumentOptions o)
    {
        var invalid = new Score(0, 0, 0, false);
        if (!q.IsConvex) return invalid;
        double frame = (double)f.W * f.H;
        double share = q.Area / frame;
        if (share < o.MinAreaShare || share > MaxAreaShare) return invalid;
        double shape = 1;
        for (int i = 0; i < 4; i++)
        {
            var p = q[i + 3];
            var c = q[i];
            var n = q[i + 1];
            double ax = p.X - c.X, ay = p.Y - c.Y, bx = n.X - c.X, by = n.Y - c.Y;
            double la = Math.Sqrt(ax * ax + ay * ay), lb = Math.Sqrt(bx * bx + by * by);
            if (la < 4 || lb < 4) return invalid;
            double cos = Math.Abs(ax * bx + ay * by) / (la * lb);
            if (cos > MaxCornerCos) return invalid;
            if (cos > FreeCornerCos) shape *= 1 - 0.5 * (cos - FreeCornerCos) / (MaxCornerCos - FreeCornerCos);
        }
        var estimate = PerspectiveCorrector.EstimateAspect(q, f.W, f.H);
        double ratio = estimate.LongOverShort;
        if (!(ratio <= MaxLongOverShort)) return invalid;
        double aspectFactor = ratio <= PlainLongOverShort
            ? 1
            : 1 - 0.5 * (ratio - PlainLongOverShort) / (MaxLongOverShort - PlainLongOverShort);
        double sizeFactor = 0.85 + 0.15 * Math.Min(1, share / 0.3);

        double sum = 0, min = double.MaxValue;
        int covered = 0, brighter = 0;
        for (int i = 0; i < 4; i++)
        {
            if (SideScore(f, q, i, samples) is not { } side) continue;
            sum += side.Value;
            min = Math.Min(min, side.Value);
            covered++;
            if (side.Sign > 0) brighter++;
        }
        if (covered < 3) return invalid;
        double edge = 0.5 * (sum / covered) + 0.5 * min;
        double total = edge * shape * aspectFactor * sizeFactor;
        if (covered < 4) total *= PartialFactor;
        if (brighter != 0 && brighter != covered) total *= MixedPolarityFactor;
        if (PerspectiveCorrector.MatchPaper(ratio, o.PaperAspectTolerance) is not null) total += PaperBonus;
        if (hint is { } h && CornerDistance(q, h) <= HintShare * f.Diagonal) total += HintBonus;
        return new Score(total, edge, min, true, covered < 4);
    }

    /// <summary>
    /// How clearly edge <paramref name="index"/> of <paramref name="q"/> is a sheet's edge, 0...1;
    /// null when it lies outside the frame or along its border (<see cref="BorderBand"/>). Its support (<see cref="MeasureSide"/>) times
    /// <see cref="ContrastFloor"/> plus the rest in proportion to its contrast (full at
    /// <see cref="ContrastFull"/>), less up to <see cref="ExtensionPenalty"/> of that when the edge
    /// runs on past its corners (its support over <see cref="ExtensionShare"/> of its length beyond
    /// each end, the mean of the two, from 0.15 to 0.6): a sheet's edges end at its corners, a seam
    /// between planks, a line of the grain or the side of a page cut short by a line printed on it
    /// does not.
    /// </summary>
    private static (double Value, double Sign)? SideScore(Field f, Quad q, int index, int samples)
    {
        var p = q[index];
        var e = q[index + 1];
        var m = MeasureSide(f, p, e, samples);
        if (!m.Covered) return null;
        double value = m.Support * (ContrastFloor + (1 - ContrastFloor) * Math.Min(1, m.Contrast / ContrastFull));
        double len = p.DistanceTo(e);
        double ext = Math.Max(ExtensionMin, ExtensionShare * len);
        double ux = (e.X - p.X) / len, uy = (e.Y - p.Y) / len;
        int extSamples = Math.Max(6, samples / 4);
        var before = MeasureSide(f, new PointD(p.X - ux * ext, p.Y - uy * ext), p, extSamples);
        var after = MeasureSide(f, e, new PointD(e.X + ux * ext, e.Y + uy * ext), extSamples);
        double through = 0;
        int ends = 0;
        if (before.Covered)
        {
            through += before.Support;
            ends++;
        }
        if (after.Covered)
        {
            through += after.Support;
            ends++;
        }
        if (ends == 0) return (value, m.Sign);
        through /= ends;
        return (value * (1 - ExtensionPenalty * Math.Clamp((through - 0.15) / 0.45, 0, 1)), m.Sign);
    }

    /// <summary>What <see cref="MeasureSide"/> finds along an edge; <see cref="Sign"/> is +1 when the outside is brighter, −1 when darker.</summary>
    private readonly record struct SideMeasure(double Support, double Contrast, bool Covered, double Sign = 0);

    /// <summary>
    /// At <paramref name="samples"/> points along the edge (6 % to 94 %) at least
    /// <see cref="BorderBand"/> px inside the frame: the gradient across the edge at offsets within
    /// <see cref="SupportReach"/> px. The edge's sign and offset are those with the largest sum; a
    /// point supports the edge when, at that offset or one pixel either side, the gradient of that
    /// sign is at least <see cref="EdgeThreshold"/> and <see cref="TextureRatio"/> times the texture
    /// outside the edge (the median along the edge of the mean gradient <see cref="TextureNear"/> to
    /// <see cref="TextureFar"/> px outside, of the points where some of that strip lies in the
    /// frame; none when it lies outside everywhere: a page's edge stands out from the table's
    /// texture, a grain line or a seam does not). The contrast is the mean color difference (R, G,
    /// B levels) between 4 + 0.4 % of the diagonal px inside and outside, nearer where the frame
    /// ends first. Covered when at least a quarter of the points are measured.
    /// </summary>
    private static SideMeasure MeasureSide(Field f, PointD p, PointD q, int samples)
    {
        double dx = q.X - p.X, dy = q.Y - p.Y;
        double len = Math.Sqrt(dx * dx + dy * dy);
        if (len < 1) return new SideMeasure(0, 0, false);
        double ux = dx / len, uy = dy / len;
        double nx = uy, ny = -ux; // outward for a clockwise outline
        double offset = 4 + 0.004 * f.Diagonal;
        int w = f.W, h = f.H;
        const int r = SupportReach, span = 2 * r + 1;
        Span<double> g = samples <= 64 ? stackalloc double[64 * span] : new double[samples * span];
        Span<double> texture = samples <= 64 ? stackalloc double[64] : new double[samples];
        Span<bool> used = samples <= 64 ? stackalloc bool[64] : new bool[samples];
        Span<bool> textured = samples <= 64 ? stackalloc bool[64] : new bool[samples];
        Span<double> pos = stackalloc double[span];
        Span<double> neg = stackalloc double[span];
        used.Clear();
        textured.Clear();
        pos.Clear();
        neg.Clear();
        int inFrame = 0, texturedCount = 0;
        double contrastSum = 0;
        for (int s = 0; s < samples; s++)
        {
            double t = 0.06 + 0.88 * (s + 0.5) / samples;
            double x = p.X + dx * t, y = p.Y + dy * t;
            if (!(x >= BorderBand && y >= BorderBand && x <= w - BorderBand && y <= h - BorderBand)) continue;
            used[s] = true;
            inFrame++;
            for (int k = -r; k <= r; k++)
            {
                int i = PixelIndex(f, x + nx * k, y + ny * k);
                double v = f.Gx[i] * nx + f.Gy[i] * ny;
                g[s * span + k + r] = v;
                if (v > 0) pos[k + r] += v;
                else neg[k + r] -= v;
            }
            // The texture strip where it lies within the gradient's area (not the outermost pixels).
            double tex = 0;
            int probes = 0;
            for (int k = TextureNear; k <= TextureFar; k++)
            {
                double fx = Math.Floor(x + nx * k), fy = Math.Floor(y + ny * k);
                if (fx < 1 || fy < 1 || fx > w - 2 || fy > h - 2) continue;
                int i = (int)fy * w + (int)fx;
                tex += Math.Abs(f.Gx[i] * nx + f.Gy[i] * ny);
                probes++;
            }
            if (probes > 0)
            {
                texture[s] = tex / probes;
                textured[s] = true;
                texturedCount++;
            }
            double inner = ProbeReach(f, x, y, -nx, -ny, offset), outer = ProbeReach(f, x, y, nx, ny, offset);
            int a = PixelIndex(f, x - nx * inner, y - ny * inner);
            int b = PixelIndex(f, x + nx * outer, y + ny * outer);
            int diff = Math.Abs(f.R[a] - f.R[b]) + Math.Abs(f.G[a] - f.G[b]) + Math.Abs(f.B[a] - f.B[b]);
            contrastSum += diff / 768.0;
        }
        if (inFrame == 0 || inFrame * 4 < samples) return new SideMeasure(0, 0, false);
        int bestK = 0;
        double sign = 1, bestSum = -1;
        for (int k = 0; k < span; k++)
        {
            if (pos[k] > bestSum)
            {
                bestSum = pos[k];
                bestK = k;
                sign = 1;
            }
            if (neg[k] > bestSum)
            {
                bestSum = neg[k];
                bestK = k;
                sign = -1;
            }
        }
        double level = 0;
        if (texturedCount > 0)
        {
            Span<double> levels = texturedCount <= 64 ? stackalloc double[64] : new double[texturedCount];
            levels = levels[..texturedCount];
            for (int s = 0, n = 0; s < samples; s++)
            {
                if (textured[s]) levels[n++] = texture[s];
            }
            levels.Sort();
            level = levels[texturedCount / 2];
        }
        int support = 0;
        for (int s = 0; s < samples; s++)
        {
            if (!used[s]) continue;
            double e = double.MinValue;
            for (int k = Math.Max(0, bestK - 1); k <= Math.Min(span - 1, bestK + 1); k++) e = Math.Max(e, sign * g[s * span + k]);
            if (e >= EdgeThreshold && e >= TextureRatio * level) support++;
        }
        return new SideMeasure((double)support / inFrame, contrastSum / inFrame, true, sign);
    }

    /// <summary>The index of the analysis pixel holding the continuous point (x, y), clamped into the frame.</summary>
    private static int PixelIndex(Field f, double x, double y)
    {
        int px = (int)Math.Clamp(Math.Floor(x), 0, f.W - 1);
        int py = (int)Math.Clamp(Math.Floor(y), 0, f.H - 1);
        return py * f.W + px;
    }

    /// <summary>
    /// How far from (x, y) along the unit direction (ux, uy) a probe can go, at most
    /// <paramref name="limit"/>, and stay half a pixel short of where the frame ends (0 at least).
    /// </summary>
    private static double ProbeReach(Field f, double x, double y, double ux, double uy, double limit)
    {
        double room = double.MaxValue;
        if (ux > 0) room = Math.Min(room, (f.W - x) / ux);
        else if (ux < 0) room = Math.Min(room, x / -ux);
        if (uy > 0) room = Math.Min(room, (f.H - y) / uy);
        else if (uy < 0) room = Math.Min(room, y / -uy);
        return Math.Max(0, Math.Min(limit, room - 0.5));
    }

    // MARK: - Straight edges

    /// <summary>The thinned edge pixels of the analysis image, with what the line searches need.</summary>
    internal sealed class EdgeSet
    {
        public int Count;
        /// <summary>Pixel centers.</summary>
        public double[] X = [], Y = [];
        /// <summary>Unit gradients, turned to point down (or right when level).</summary>
        public double[] Nx = [], Ny = [];
        /// <summary>Hough votes: the gradient up to <see cref="VoteCap"/>, less when crowded.</summary>
        public double[] Weight = [];
        /// <summary>Direction bins (0...179), and the pixels by bin: those of bin k are <see cref="Order"/>[<see cref="Start"/>[k]] to Order[Start[k + 1] - 1].</summary>
        public int[] Bin = [], Start = [], Order = [];
    }

    /// <summary>
    /// The edge pixels: gradients of at least <see cref="EdgeThreshold"/> thinned to their ridge
    /// (larger than the neighbor behind across the gradient, at least the one ahead), each with its
    /// direction and its vote: its gradient up to <see cref="VoteCap"/>, times 1.5 − 2.5 × the share
    /// of edge pixels within <see cref="IsolationRadius"/> px (between <see cref="IsolationFloor"/>
    /// and 1), so print, dense with edges, counts less than a sheet's lone edge.
    /// </summary>
    internal static EdgeSet FindEdges(Field f)
    {
        int w = f.W, h = f.H;
        var edges = new List<int>();
        var isEdge = new byte[w * h];
        for (int y = 1; y < h - 1; y++)
        {
            for (int x = 1; x < w - 1; x++)
            {
                int i = y * w + x;
                double m = f.Mag[i];
                if (m < EdgeThreshold) continue;
                double ax = Math.Abs(f.Gx[i]), ay = Math.Abs(f.Gy[i]);
                int a, b;
                if (ay <= ax * 0.41421356) { a = i - 1; b = i + 1; }
                else if (ax <= ay * 0.41421356) { a = i - w; b = i + w; }
                else if (f.Gx[i] * f.Gy[i] > 0) { a = i - w - 1; b = i + w + 1; }
                else { a = i - w + 1; b = i + w - 1; }
                if (m > f.Mag[a] && m >= f.Mag[b])
                {
                    edges.Add(i);
                    isEdge[i] = 1;
                }
            }
        }

        // The count of edge pixels in every rectangle, from a summed-area table.
        int stride = w + 1;
        var integral = new int[stride * (h + 1)];
        for (int y = 0; y < h; y++)
        {
            int run = 0;
            for (int x = 0; x < w; x++)
            {
                run += isEdge[y * w + x];
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + run;
            }
        }

        int ne = edges.Count;
        var es = new EdgeSet
        {
            Count = ne,
            X = new double[ne],
            Y = new double[ne],
            Nx = new double[ne],
            Ny = new double[ne],
            Weight = new double[ne],
            Bin = new int[ne],
        };
        for (int e = 0; e < ne; e++)
        {
            int i = edges[e];
            int x = i % w, y = i / w;
            double m = f.Mag[i];
            double nx = f.Gx[i] / m, ny = f.Gy[i] / m;
            if (ny < 0 || (ny == 0 && nx < 0))
            {
                nx = -nx;
                ny = -ny;
            }
            es.X[e] = x + 0.5;
            es.Y[e] = y + 0.5;
            es.Nx[e] = nx;
            es.Ny[e] = ny;
            es.Bin[e] = AngleBin(nx) % 180;
            int x0 = Math.Max(0, x - IsolationRadius), x1 = Math.Min(w, x + IsolationRadius + 1);
            int y0 = Math.Max(0, y - IsolationRadius), y1 = Math.Min(h, y + IsolationRadius + 1);
            int crowd = integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0] + integral[y0 * stride + x0];
            double density = (double)crowd / ((x1 - x0) * (y1 - y0));
            es.Weight[e] = Math.Min(m, VoteCap) * Math.Clamp(1.5 - 2.5 * density, IsolationFloor, 1);
        }

        // The edge pixels by direction (in the order found within each bin), for refitting.
        var start = new int[181];
        for (int e = 0; e < ne; e++) start[es.Bin[e] + 1]++;
        for (int k = 0; k < 180; k++) start[k + 1] += start[k];
        var fill = new int[180];
        var order = new int[ne];
        for (int e = 0; e < ne; e++)
        {
            int k = es.Bin[e];
            order[start[k] + fill[k]] = e;
            fill[k]++;
        }
        es.Start = start;
        es.Order = order;
        return es;
    }

    /// <summary>
    /// The straight edges of the analysis image, strongest first: the edge pixels vote in a Hough
    /// transform (1° by 1 px, within <see cref="HoughWindow"/>° of their own direction, their
    /// <see cref="EdgeSet.Weight"/>); each peak (a local maximum over ±2° and ±4 px) is refitted
    /// to the edge pixels within 2.5 px of it that face within 12° of its way, and repeats (within
    /// 3° and 6 px) are dropped. At most <paramref name="maxLines"/>, from at most three times as
    /// many peaks.
    /// </summary>
    internal static List<Line> FindLines(Field f, EdgeSet es, int maxLines)
    {
        int w = f.W, h = f.H;
        int maxRho = (int)Math.Ceiling(f.Diagonal) + 1;
        int nr = 2 * maxRho + 1;
        var acc = new double[180 * nr];
        for (int e = 0; e < es.Count; e++)
        {
            int k = es.Bin[e];
            double weight = es.Weight[e];
            for (int d = -HoughWindow; d <= HoughWindow; d++)
            {
                int kk = ((k + d) % 180 + 180) % 180;
                double rho = es.X[e] * CosTable[kk] + es.Y[e] * SinTable[kk];
                int ri = (int)Math.Floor(rho + 0.5) + maxRho;
                acc[kk * nr + ri] += weight;
            }
        }
        var peaks = Peaks(acc, 180, nr, MinLineShare * Math.Min(w, h) * EdgeThreshold);
        var lines = new List<Line>();
        int tried = 0;
        foreach (var peak in peaks)
        {
            if (lines.Count >= maxLines || tried >= 3 * maxLines) break;
            tried++;
            int k = peak.Index / nr, r = peak.Index % nr;
            var line = new Line(CosTable[k], SinTable[k], r - maxRho);
            line = RefitLine(es, k, line) ?? line;
            if (!IsRepeat(lines, line)) lines.Add(line);
        }
        return lines;
    }

    /// <summary>
    /// Lines that could be edge <paramref name="side"/> of <paramref name="q"/>: a Hough transform
    /// of the edge pixels between the lines of its two neighboring edges (at most
    /// <see cref="CorridorMargin"/> px outside either), no deeper inside the outline than
    /// <see cref="CorridorDepth"/> of its depth there, facing within 20° of the edge's normal, for directions within
    /// <see cref="CorridorBins"/>° of the edge's; the <see cref="CorridorPeaks"/> strongest peaks
    /// and the <see cref="CorridorOutermost"/> outermost others, refitted, without repeats.
    /// </summary>
    internal static List<Line> CorridorLines(Field f, EdgeSet es, Quad q, int side)
    {
        var result = new List<Line>();
        var p0 = q[side];
        var p1 = q[side + 1];
        if (p0.DistanceTo(p1) < 4) return result;
        var edge = Line.Through(p0, p1);
        var before = Line.Through(q[side + 3], q[side]);
        var after = Line.Through(q[side + 1], q[side + 2]);
        double mx = (q[side + 2].X + q[side + 3].X) / 2, my = (q[side + 2].Y + q[side + 3].Y) / 2;
        double depth = -edge.Distance(mx, my);
        double nx = edge.Nx, ny = edge.Ny;
        if (ny < 0 || (ny == 0 && nx < 0))
        {
            nx = -nx;
            ny = -ny;
        }
        int k0 = AngleBin(nx) % 180;
        var members = new List<int>();
        for (int e = 0; e < es.Count; e++)
        {
            double x = es.X[e], y = es.Y[e];
            if (before.Distance(x, y) > CorridorMargin || after.Distance(x, y) > CorridorMargin) continue;
            if (edge.Distance(x, y) < -CorridorDepth * depth) continue;
            double c = es.Nx[e] * edge.Nx + es.Ny[e] * edge.Ny;
            if (c < 0.94 && c > -0.94) continue;
            members.Add(e);
        }
        if (members.Count < 10) return result;
        // Each member votes for the directions within HoughWindow of its own (d, relative to the
        // edge's bin k0, within ±CorridorBins); first the distances they reach, so the accumulator
        // spans only those, with room for the peak search.
        int span = 2 * CorridorBins + 1;
        var first = new int[members.Count];
        var last = new int[members.Count];
        int lowest = int.MaxValue, highest = int.MinValue;
        for (int m = 0; m < members.Count; m++)
        {
            int e = members[m];
            int rel = es.Bin[e] - k0;
            if (rel > 90) rel -= 180;
            if (rel < -90) rel += 180;
            first[m] = Math.Max(-CorridorBins, rel - HoughWindow);
            last[m] = Math.Min(CorridorBins, rel + HoughWindow);
            for (int d = first[m]; d <= last[m]; d++)
            {
                int kk = ((k0 + d) % 180 + 180) % 180;
                int ri = (int)Math.Floor(es.X[e] * CosTable[kk] + es.Y[e] * SinTable[kk] + 0.5);
                lowest = Math.Min(lowest, ri);
                highest = Math.Max(highest, ri);
            }
        }
        if (lowest > highest) return result;
        int maxRho = -lowest + 5;
        int nr = highest - lowest + 11;
        var acc = new double[span * nr];
        for (int m = 0; m < members.Count; m++)
        {
            int e = members[m];
            double x = es.X[e], y = es.Y[e];
            for (int d = first[m]; d <= last[m]; d++)
            {
                int kk = ((k0 + d) % 180 + 180) % 180;
                double rho = x * CosTable[kk] + y * SinTable[kk];
                int ri = (int)Math.Floor(rho + 0.5) + maxRho;
                acc[(d + CorridorBins) * nr + ri] += es.Weight[e];
            }
        }
        var peaks = Peaks(acc, span, nr, 10 * EdgeThreshold);
        // The strongest peaks, and the outermost ones (a sheet's edge lies outside the print on it):
        // how far out each crosses the normal through the edge's midpoint.
        double cx = (p0.X + p1.X) / 2, cy = (p0.Y + p1.Y) / 2;
        var outward = new List<(double Offset, int Rank)>();
        for (int i = 0; i < peaks.Count; i++)
        {
            int d = peaks[i].Index / nr - CorridorBins, r = peaks[i].Index % nr;
            int kk = ((k0 + d) % 180 + 180) % 180;
            double den = CosTable[kk] * edge.Nx + SinTable[kk] * edge.Ny;
            if (Math.Abs(den) < 1e-6) continue;
            outward.Add(((r - maxRho - (CosTable[kk] * cx + SinTable[kk] * cy)) / den, i));
        }
        outward.Sort((a, b) => a.Offset != b.Offset ? b.Offset.CompareTo(a.Offset) : a.Rank.CompareTo(b.Rank));
        var chosen = new List<int>();
        for (int i = 0; i < peaks.Count && chosen.Count < CorridorPeaks; i++) chosen.Add(i);
        double strongest = peaks.Count > 0 ? peaks[0].Votes : 0;
        for (int i = 0, added = 0; i < outward.Count && added < CorridorOutermost; i++)
        {
            if (chosen.Contains(outward[i].Rank) || peaks[outward[i].Rank].Votes < CorridorOutermostShare * strongest) continue;
            chosen.Add(outward[i].Rank);
            added++;
        }
        foreach (int index in chosen)
        {
            var peak = peaks[index];
            int d = peak.Index / nr - CorridorBins, r = peak.Index % nr;
            int kk = ((k0 + d) % 180 + 180) % 180;
            var line = new Line(CosTable[kk], SinTable[kk], r - maxRho);
            var points = new List<PointD>();
            foreach (int e in members)
            {
                double dist = line.Nx * es.X[e] + line.Ny * es.Y[e] - line.Rho;
                if (dist > 2.5 || dist < -2.5) continue;
                double c = es.Nx[e] * line.Nx + es.Ny[e] * line.Ny;
                if (c < 0.978 && c > -0.978) continue;
                points.Add(new PointD(es.X[e], es.Y[e]));
            }
            if (points.Count >= 10) line = FitLine(points);
            if (!IsRepeat(result, line)) result.Add(line);
        }
        return result;
    }

    /// <summary>
    /// The local maxima of a Hough accumulator (<paramref name="bins"/> directions by
    /// <paramref name="nr"/> distances) of at least <paramref name="minVotes"/>: no neighbor within
    /// two directions and four distances is larger (or equal and earlier); strongest first, the
    /// earlier on a tie.
    /// </summary>
    private static List<(double Votes, int Index)> Peaks(double[] acc, int bins, int nr, double minVotes)
    {
        var peaks = new List<(double Votes, int Index)>();
        for (int k = 0; k < bins; k++)
        {
            for (int r = 0; r < nr; r++)
            {
                int idx = k * nr + r;
                double v = acc[idx];
                if (v < minVotes) continue;
                bool isMax = true;
                for (int dk = -2; dk <= 2 && isMax; dk++)
                {
                    int kk = k + dk;
                    if (kk < 0 || kk >= bins) continue;
                    for (int dr = -4; dr <= 4; dr++)
                    {
                        int rr = r + dr;
                        if (rr < 0 || rr >= nr || (dk == 0 && dr == 0)) continue;
                        int n = kk * nr + rr;
                        double nv = acc[n];
                        if (nv > v || (nv == v && n < idx))
                        {
                            isMax = false;
                            break;
                        }
                    }
                }
                if (isMax) peaks.Add((v, idx));
            }
        }
        peaks.Sort((a, b) => a.Votes != b.Votes ? b.Votes.CompareTo(a.Votes) : a.Index.CompareTo(b.Index));
        return peaks;
    }

    /// <summary>A line within 3° and 6 px of one in <paramref name="lines"/>.</summary>
    private static bool IsRepeat(List<Line> lines, Line line)
    {
        foreach (var l in lines)
        {
            double dot = l.Nx * line.Nx + l.Ny * line.Ny;
            double rhoDiff = dot >= 0 ? Math.Abs(l.Rho - line.Rho) : Math.Abs(l.Rho + line.Rho);
            if (Math.Abs(dot) >= 0.9986 && rhoDiff <= 6) return true;
        }
        return false;
    }

    /// <summary>The bin (0...180) of the angle whose cosine is nearest <paramref name="nx"/>.</summary>
    private static int AngleBin(double nx)
    {
        int lo = 0, hi = 180;
        while (hi - lo > 1)
        {
            int mid = (lo + hi) / 2;
            if (CosTable[mid] >= nx) lo = mid;
            else hi = mid;
        }
        return CosTable[lo] - nx <= nx - CosTable[hi] ? lo : hi;
    }

    /// <summary>
    /// The line fitted to the edge pixels within 2.5 px of <paramref name="line"/> (of direction
    /// bin <paramref name="bin"/>) whose gradient is within 12° of its normal, looked for in the
    /// bins within 13° of it; null when fewer than 10.
    /// </summary>
    private static Line? RefitLine(EdgeSet es, int bin, Line line)
    {
        var points = new List<PointD>();
        for (int d = -13; d <= 13; d++)
        {
            int k = ((bin + d) % 180 + 180) % 180;
            for (int j = es.Start[k]; j < es.Start[k + 1]; j++)
            {
                int e = es.Order[j];
                double dist = line.Nx * es.X[e] + line.Ny * es.Y[e] - line.Rho;
                if (dist > 2.5 || dist < -2.5) continue;
                double c = es.Nx[e] * line.Nx + es.Ny[e] * line.Ny;
                if (c < 0.978 && c > -0.978) continue;
                points.Add(new PointD(es.X[e], es.Y[e]));
            }
        }
        if (points.Count < 10) return null;
        return FitLine(points);
    }

    /// <summary>
    /// Outlines made of the straight edges: two pairs of near-parallel edges (within 40°, at least
    /// 15 % of the short side apart), the pairs crossing at 40° or more; the four crossings,
    /// clockwise, with every corner at most <see cref="OutsideShare"/> of the frame outside it.
    /// </summary>
    private static List<Quad> LineQuads(Field f, List<Line> lines, PhotoDocumentOptions o)
    {
        var quads = new List<Quad>();
        int n = lines.Count;
        double minGap = 0.15 * Math.Min(f.W, f.H);
        var pairs = new List<(int A, int B)>();
        for (int i = 0; i < n; i++)
        {
            for (int j = i + 1; j < n; j++)
            {
                double dot = lines[i].Nx * lines[j].Nx + lines[i].Ny * lines[j].Ny;
                if (Math.Abs(dot) < OppositeMinCos) continue;
                // The gap between the two lines at the frame's center.
                double cx = f.W / 2.0, cy = f.H / 2.0;
                var pa = Project(lines[i], cx, cy);
                double gap = Math.Abs(lines[j].Distance(pa.X, pa.Y));
                if (gap < minGap) continue;
                pairs.Add((i, j));
            }
        }
        double minX = -OutsideShare * f.W, maxX = (1 + OutsideShare) * f.W;
        double minY = -OutsideShare * f.H, maxY = (1 + OutsideShare) * f.H;
        double frame = (double)f.W * f.H;
        for (int p = 0; p < pairs.Count; p++)
        {
            for (int r = p + 1; r < pairs.Count; r++)
            {
                var (a, b) = pairs[p];
                var (c, d) = pairs[r];
                if (a == c || a == d || b == c || b == d) continue;
                double cross = Math.Abs(lines[a].Nx * lines[c].Nx + lines[a].Ny * lines[c].Ny);
                if (cross > MaxCornerCos) continue;
                if (Line.Intersect(lines[a], lines[c]) is not { } p0) continue;
                if (Line.Intersect(lines[c], lines[b]) is not { } p1) continue;
                if (Line.Intersect(lines[b], lines[d]) is not { } p2) continue;
                if (Line.Intersect(lines[d], lines[a]) is not { } p3) continue;
                PointD[] corners = [p0, p1, p2, p3];
                bool inside = true;
                foreach (var pt in corners)
                {
                    if (pt.X < minX || pt.X > maxX || pt.Y < minY || pt.Y > maxY) inside = false;
                }
                if (!inside) continue;
                var q = Quad.FromCorners(corners);
                if (!q.IsConvex) continue;
                double share = q.Area / frame;
                if (share < o.MinAreaShare || share > MaxAreaShare) continue;
                quads.Add(q);
            }
        }
        return quads;
    }

    private static PointD Project(Line l, double x, double y)
    {
        double d = l.Distance(x, y);
        return new PointD(x - l.Nx * d, y - l.Ny * d);
    }

    // MARK: - Regions

    /// <summary>
    /// Outlines of the regions that stand out, found at half the analysis resolution (2 × 2
    /// means): pixels whose color differs from the median color of the frame's border (3 % of the
    /// short side) by more than an Otsu threshold (at least <see cref="MinRegionContrast"/>), and
    /// pixels brighter than the Otsu threshold of the brightness; each mask opened by one pixel,
    /// its two largest parts of at least the least page size taken, each part's convex hull
    /// simplified to <see cref="MaxHullVertices"/> corners and the four of them enclosing the
    /// largest area kept, in analysis pixels.
    /// </summary>
    private static List<Quad> RegionQuads(Field f, PhotoDocumentOptions o)
    {
        int fw = f.W, w = f.W / 2, h = f.H / 2, count = w * h;
        var quads = new List<Quad>();
        var cr = new int[count];
        var cg = new int[count];
        var cb = new int[count];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int a = 2 * y * fw + 2 * x, b = a + fw;
                int i = y * w + x;
                cr[i] = (f.R[a] + f.R[a + 1] + f.R[b] + f.R[b + 1]) >> 10;
                cg[i] = (f.G[a] + f.G[a + 1] + f.G[b] + f.G[b + 1]) >> 10;
                cb[i] = (f.B[a] + f.B[a + 1] + f.B[b] + f.B[b + 1]) >> 10;
            }
        }
        int ring = Math.Max(2, (int)Math.Round(0.03 * Math.Min(w, h), MidpointRounding.AwayFromZero));
        var hr = new int[256];
        var hg = new int[256];
        var hb = new int[256];
        int ringCount = 0;
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                if (x >= ring && x < w - ring && y >= ring && y < h - ring) continue;
                int i = y * w + x;
                hr[cr[i]]++;
                hg[cg[i]]++;
                hb[cb[i]]++;
                ringCount++;
            }
        }
        int mr = BackgroundMap.Percentile(hr, ringCount, 0.5);
        int mg = BackgroundMap.Percentile(hg, ringCount, 0.5);
        int mb = BackgroundMap.Percentile(hb, ringCount, 0.5);

        var distance = new int[count];
        var luma = new int[count];
        var hd = new int[256];
        var hl = new int[256];
        for (int i = 0; i < count; i++)
        {
            int r = cr[i], g = cg[i], b = cb[i];
            int d = Math.Max(Math.Abs(r - mr), Math.Max(Math.Abs(g - mg), Math.Abs(b - mb)));
            distance[i] = d;
            hd[d]++;
            int l = (299 * r + 587 * g + 114 * b + 500) / 1000;
            luma[i] = l;
            hl[l]++;
        }
        int td = Math.Max(MinRegionContrast, Otsu(hd, count));
        int tl = Otsu(hl, count);
        for (int pass = 0; pass < 2; pass++)
        {
            var mask = new byte[count];
            int set = 0;
            for (int i = 0; i < count; i++)
            {
                bool on = pass == 0 ? distance[i] > td : luma[i] > tl;
                if (on)
                {
                    mask[i] = 1;
                    set++;
                }
            }
            if (set < o.MinAreaShare * count || set > 0.97 * count) continue;
            mask = MaskOps.Dilate(MaskOps.Erode(mask, w, h, 1), w, h, 1);
            var parts = MaskOps.ConnectedComponents(mask, w, h);
            var big = new List<(int Area, int Index)>();
            for (int i = 0; i < parts.Count; i++)
            {
                if (parts[i].Area >= o.MinAreaShare * count) big.Add((parts[i].Area, i));
            }
            big.Sort((a, b) => a.Area != b.Area ? b.Area.CompareTo(a.Area) : a.Index.CompareTo(b.Index));
            for (int k = 0; k < big.Count && k < 2; k++)
            {
                var part = parts[big[k].Index];
                var points = new List<PointD>();
                foreach (var (y, span) in part.Rows)
                {
                    points.Add(new PointD(2 * span.MinX, 2 * y));
                    points.Add(new PointD(2 * (span.MaxX + 1), 2 * y));
                    points.Add(new PointD(2 * span.MinX, 2 * (y + 1)));
                    points.Add(new PointD(2 * (span.MaxX + 1), 2 * (y + 1)));
                }
                var hull = Simplify(Geometry.ConvexHull(points), MaxHullVertices);
                if (LargestQuad(hull) is { } q) quads.Add(q);
            }
        }
        return quads;
    }

    /// <summary>The Otsu threshold of a 256-level histogram: values above it are the brighter class.</summary>
    internal static int Otsu(int[] histogram, int total)
    {
        double sumAll = 0;
        for (int v = 0; v < 256; v++) sumAll += (double)v * histogram[v];
        double sumB = 0, best = -1;
        long wB = 0;
        int threshold = 0;
        for (int t = 0; t < 256; t++)
        {
            wB += histogram[t];
            if (wB == 0) continue;
            long wF = total - wB;
            if (wF == 0) break;
            sumB += (double)t * histogram[t];
            double mB = sumB / wB, mF = (sumAll - sumB) / wF;
            double between = (double)wB * wF * (mB - mF) * (mB - mF);
            if (between > best)
            {
                best = between;
                threshold = t;
            }
        }
        return threshold;
    }

    /// <summary>A convex polygon cut to at most <paramref name="max"/> corners by dropping, one at a time, the corner whose triangle with its neighbors is smallest (the first on a tie).</summary>
    internal static List<PointD> Simplify(List<PointD> polygon, int max)
    {
        var p = new List<PointD>(polygon);
        while (p.Count > max)
        {
            int n = p.Count, worst = 0;
            double smallest = double.MaxValue;
            for (int i = 0; i < n; i++)
            {
                var a = p[(i + n - 1) % n];
                var b = p[i];
                var c = p[(i + 1) % n];
                double area = Math.Abs((b.X - a.X) * (c.Y - a.Y) - (b.Y - a.Y) * (c.X - a.X));
                if (area < smallest)
                {
                    smallest = area;
                    worst = i;
                }
            }
            p.RemoveAt(worst);
        }
        return p;
    }

    /// <summary>The four corners of a convex polygon that enclose the largest area, as a quad; null for fewer than four corners.</summary>
    internal static Quad? LargestQuad(List<PointD> hull)
    {
        int n = hull.Count;
        if (n < 4) return null;
        double best = -1;
        int ba = 0, bb = 0, bc = 0, bd = 0;
        for (int a = 0; a < n; a++)
        {
            for (int c = a + 2; c < n; c++)
            {
                if (n - (c - a) < 2) continue;
                double best1 = -1, best2 = -1;
                int b1 = -1, d1 = -1;
                for (int b = a + 1; b < c; b++)
                {
                    double t = Math.Abs(Cross(hull[a], hull[b], hull[c]));
                    if (t > best1)
                    {
                        best1 = t;
                        b1 = b;
                    }
                }
                for (int d = c + 1; d < a + n; d++)
                {
                    var pd = hull[d % n];
                    double t = Math.Abs(Cross(hull[c], pd, hull[a]));
                    if (t > best2)
                    {
                        best2 = t;
                        d1 = d % n;
                    }
                }
                if (b1 < 0 || d1 < 0) continue;
                double area = best1 + best2;
                if (area > best)
                {
                    best = area;
                    ba = a;
                    bb = b1;
                    bc = c;
                    bd = d1;
                }
            }
        }
        if (best <= 0) return null;
        var q = Quad.FromCorners([hull[ba], hull[bb], hull[bc], hull[bd]]);
        return q.IsConvex ? q : null;
    }

    private static double Cross(PointD o, PointD a, PointD b) => (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);

    // MARK: - Refitting an outline to its edges

    /// <summary>
    /// The outline with each edge refitted to the edge points within <paramref name="reach"/> px
    /// across it (<see cref="RefitSide"/>; an edge with too few keeps its line, at most one), the
    /// corners where the new edges cross; null when fewer than three edges refit, the result is not
    /// convex, or a corner moved more than twice the reach and 2 px.
    /// </summary>
    internal static Quad? RefineQuad(Field f, Quad q, double reach)
    {
        var lines = new Line[4];
        int refit = 0;
        for (int i = 0; i < 4; i++)
        {
            var p0 = q[i];
            var p1 = q[i + 1];
            if (p0.DistanceTo(p1) < 4) return null;
            if (RefitSide(f, p0, p1, reach) is { } line)
            {
                lines[i] = line;
                refit++;
            }
            else
            {
                lines[i] = Line.Through(p0, p1);
            }
        }
        if (refit < 3) return null;
        var corners = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            if (Line.Intersect(lines[(i + 3) & 3], lines[i]) is not { } c) return null;
            corners[i] = c;
        }
        var result = new Quad(corners[0], corners[1], corners[2], corners[3]);
        if (!result.IsConvex) return null;
        for (int i = 0; i < 4; i++)
        {
            if (result[i].DistanceTo(q[i]) > 2 * reach + 2) return null;
        }
        return result;
    }

    /// <summary>
    /// The edge from <paramref name="p"/> to <paramref name="q"/> refitted: at points every 2 px
    /// along it (8 % to 92 %), the gradient across it within <paramref name="reach"/> px of the
    /// sign that prevails within <see cref="PolarityReach"/> px of the edge as it is, the
    /// strongest (nearer ones favored: one at the reach counts half), placed to a fraction of a
    /// pixel by a parabola through its neighbors; those of at least <see cref="EdgeThreshold"/>
    /// fitted by <see cref="FitLine"/>. Null when fewer than a third of the points (and 6) are found.
    /// </summary>
    private static Line? RefitSide(Field f, PointD p, PointD q, double reach)
    {
        double dx = q.X - p.X, dy = q.Y - p.Y;
        double len = Math.Sqrt(dx * dx + dy * dy);
        if (!(len >= 1) || len > 1e6) return null;
        double ux = dx / len, uy = dy / len;
        double nx = uy, ny = -ux;
        int r = (int)Math.Ceiling(reach);
        int span = 2 * r + 1;
        int samples = Math.Clamp((int)(len / 2), 8, 300);
        var values = new double[samples * span];
        var usable = new bool[samples];
        var xs = new double[samples];
        var ys = new double[samples];
        double sumPos = 0, sumNeg = 0;
        double lo = 1.5, hiX = f.W - 1.5, hiY = f.H - 1.5;
        for (int s = 0; s < samples; s++)
        {
            double t = 0.08 + 0.84 * (s + 0.5) / samples;
            double x = p.X + dx * t, y = p.Y + dy * t;
            xs[s] = x;
            ys[s] = y;
            double ex0 = x - nx * r, ey0 = y - ny * r, ex1 = x + nx * r, ey1 = y + ny * r;
            if (ex0 < lo || ey0 < lo || ex1 < lo || ey1 < lo || ex0 > hiX || ex1 > hiX || ey0 > hiY || ey1 > hiY) continue;
            usable[s] = true;
            double bestPos = 0, bestNeg = 0;
            for (int k = -r; k <= r; k++)
            {
                var (gx, gy) = f.GradientAt(x + nx * k, y + ny * k);
                double g = gx * nx + gy * ny;
                values[s * span + k + r] = g;
                if (k < -PolarityReach || k > PolarityReach) continue;
                if (g > bestPos) bestPos = g;
                if (-g > bestNeg) bestNeg = -g;
            }
            sumPos += bestPos;
            sumNeg += bestNeg;
        }
        double sign = sumPos >= sumNeg ? 1 : -1;
        var points = new List<PointD>();
        for (int s = 0; s < samples; s++)
        {
            if (!usable[s]) continue;
            // The strongest response of that sign, nearer ones favored (a full-strength edge at the
            // reach counts half), so a stronger parallel edge further off does not pull the line.
            int best = -1;
            double bestWeighted = 0;
            for (int k = 0; k < span; k++)
            {
                double v = sign * values[s * span + k];
                if (v < EdgeThreshold) continue;
                double weighted = v * (1 - 0.5 * Math.Abs(k - r) / (r + 1.0));
                if (weighted > bestWeighted)
                {
                    bestWeighted = weighted;
                    best = k;
                }
            }
            if (best < 0) continue;
            double bestValue = sign * values[s * span + best];
            double delta = 0;
            if (best > 0 && best < span - 1)
            {
                double a = sign * values[s * span + best - 1], c = sign * values[s * span + best + 1];
                double den = a - 2 * bestValue + c;
                if (den < 0) delta = Math.Clamp(0.5 * (a - c) / den, -0.5, 0.5);
            }
            double off = best - r + delta;
            points.Add(new PointD(xs[s] + nx * off, ys[s] + ny * off));
        }
        if (points.Count < Math.Max(6, samples / 3)) return null;
        return FitLine(points);
    }

    /// <summary>
    /// The total-least-squares line through <paramref name="points"/>, refitted twice without the
    /// points farther from it than 2.5 times the median distance (and 0.75 px).
    /// </summary>
    internal static Line FitLine(List<PointD> points)
    {
        var current = points;
        var line = Fit(current);
        for (int pass = 0; pass < 2; pass++)
        {
            var distances = new double[current.Count];
            for (int i = 0; i < current.Count; i++) distances[i] = Math.Abs(line.Distance(current[i].X, current[i].Y));
            var sorted = (double[])distances.Clone();
            Array.Sort(sorted);
            double limit = Math.Max(0.75, 2.5 * sorted[sorted.Length / 2]);
            var kept = new List<PointD>();
            for (int i = 0; i < current.Count; i++)
            {
                if (distances[i] <= limit) kept.Add(current[i]);
            }
            if (kept.Count < 4 || kept.Count == current.Count) break;
            current = kept;
            line = Fit(current);
        }
        return line;
    }

    private static Line Fit(List<PointD> points)
    {
        double mx = 0, my = 0;
        foreach (var p in points)
        {
            mx += p.X;
            my += p.Y;
        }
        mx /= points.Count;
        my /= points.Count;
        double sxx = 0, sxy = 0, syy = 0;
        foreach (var p in points)
        {
            double dx = p.X - mx, dy = p.Y - my;
            sxx += dx * dx;
            sxy += dx * dy;
            syy += dy * dy;
        }
        // The direction of largest spread: the eigenvector of the larger eigenvalue.
        double half = (sxx - syy) / 2;
        double lambda = (sxx + syy) / 2 + Math.Sqrt(half * half + sxy * sxy);
        double ax = lambda - syy, ay = sxy;
        double bx = sxy, by = lambda - sxx;
        double dirX, dirY;
        if (Math.Abs(ax) + Math.Abs(ay) >= Math.Abs(bx) + Math.Abs(by))
        {
            dirX = ax;
            dirY = ay;
        }
        else
        {
            dirX = bx;
            dirY = by;
        }
        double len = Math.Sqrt(dirX * dirX + dirY * dirY);
        if (len == 0)
        {
            dirX = 1;
            dirY = 0;
            len = 1;
        }
        double nx = -dirY / len, ny = dirX / len;
        return new Line(nx, ny, nx * mx + ny * my);
    }
}
