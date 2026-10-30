namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/SpineShadow.swift: same constants, same steps and the
// same arithmetic (no library functions beyond + − × ÷), so a page gives the same bytes on both platforms.

/// <summary>An edge of a page.</summary>
public enum PageEdge
{
    Left,
    Top,
    Right,
    Bottom,
}

/// <summary>What softening the spine's shadow did to a page (<see cref="ScannedPage.SpineShadow"/>; in memory only).</summary>
/// <param name="Edge">The page's edge along the spine.</param>
/// <param name="Depth">How much the shadow darkened the paper where it was deepest, 0...1 (0.3: to 70 %).</param>
/// <param name="WidthInches">How far from the edge the shadow reached.</param>
/// <param name="MaxGain">The most any pixel was brightened by (a factor, at most <see cref="SpineShadow.MaxGain"/>).</param>
/// <param name="ProtectedFraction">The share of the band along the spine left as it was because it holds a picture.</param>
public sealed record SpineShadowResult(PageEdge Edge, double Depth, double WidthInches, double MaxGain, double ProtectedFraction);

/// <summary>
/// The spine's shadow measured on a page's gray copy (<see cref="SpineShadow.Estimate"/>): the gain of every
/// analysis pixel of the band along the edge, in the band's own frame: row v runs along the edge (from the
/// left or top end of the page), column u away from it (0 at the edge).
/// </summary>
public sealed class SpineShadowModel
{
    /// <summary>The page's edge along the spine.</summary>
    public PageEdge Edge { get; }
    /// <summary>Analysis pixels from the edge to the far side of the page (the page's width or height).</summary>
    public int Extent { get; }
    /// <summary>Analysis pixels along the edge.</summary>
    public int Length { get; }
    /// <summary>Analysis pixels from the edge the band reaches; every pixel beyond keeps its value.</summary>
    public int Band { get; }
    /// <summary>The factor each band pixel is brightened by (1 or more): <see cref="Length"/> rows of <see cref="Band"/>.</summary>
    public double[] Gains { get; }
    /// <summary>1 where the band holds a picture (left as it is), 0 elsewhere: <see cref="Length"/> rows of <see cref="Band"/>.</summary>
    public byte[] Pictures { get; }
    /// <summary>What was found, for the page.</summary>
    public SpineShadowResult Result { get; }

    public SpineShadowModel(PageEdge edge, int extent, int length, int band, double[] gains, byte[] pictures, SpineShadowResult result)
    {
        Edge = edge;
        Extent = extent;
        Length = length;
        Band = band;
        Gains = gains;
        Pictures = pictures;
        Result = result;
    }
}

/// <summary>A page with its spine's shadow softened, and what was done.</summary>
public sealed record SpineShadowCorrection(RgbaImage Image, SpineShadowResult Result);

/// <summary>
/// Softens the shadow along the spine on a page cut from a book or magazine spread. The shadow is measured
/// from the paper itself, on a gray copy at the analysis resolution: in blocks of rows along the spine, the
/// paper's brightness at every distance from the edge (a high percentile, so the paper between the text
/// counts and not the ink), divided by the paper's brightness past the shadow. A block whose paper does not
/// look like the shadow of its neighbours (a picture, a tint, the scanner lid) takes the shadow of the
/// blocks beside it; the shadow is smoothed across rows and along the edge. Every pixel is then divided by
/// the shadow there, with a cap: paper comes back to white, and ink keeps its share of the paper's
/// brightness, so text keeps its contrast. Pictures beside the spine (large dark or mid-tone areas, not the
/// thin strokes of text) are left as they are, with a soft border. Page curvature is not corrected.
/// </summary>
public static class SpineShadow
{
    /// <summary>The band along the edge the shadow is looked for in, at most this many inches wide…</summary>
    public const double BandInches = 1.5;
    /// <summary>…and at most half the page.</summary>
    public const double MaxBandFraction = 0.5;
    /// <summary>A page whose band would be narrower than this many inches is left alone.</summary>
    public const double MinBandInches = 0.25;
    /// <summary>The paper's own brightness is read on this many inches just past the band.</summary>
    public const double ReferenceInches = 0.4;
    /// <summary>The rows along the edge are measured in blocks this many inches long…</summary>
    public const double BlockInches = 0.3;
    /// <summary>…and at least this many pixels.</summary>
    public const int MinBlockRows = 4;
    /// <summary>The paper's brightness in a cell (3 columns of a block): this share of its pixels are darker.</summary>
    public const double PaperPercentile = 0.9;
    /// <summary>A page whose paper is darker than this gray level is left alone.</summary>
    public const int MinPaper = 96;
    /// <summary>A block whose paper differs from the page's by more than this share takes the page's.</summary>
    public const double PaperTolerance = 0.1;
    /// <summary>
    /// A block shows the spine's shadow when its paper is darker near the edge (by <see cref="MinDepth"/>, within
    /// <see cref="MaxDeepestInches"/>) and back to within this share of the paper over the last quarter of the band…
    /// </summary>
    public const double FadeTolerance = 0.05;
    /// <summary>
    /// …and at least this share of the blocks along the edge, and <see cref="MinShadowedBlocks"/>, show it (a book
    /// can cover only part of the glass; the rest is the lid).
    /// </summary>
    public const double MinShadowedShare = 0.3;
    /// <summary>The fewest blocks that must show the shadow.</summary>
    public const int MinShadowedBlocks = 2;
    /// <summary>
    /// A cell is shadowed paper when it is within this share of the paper's brightness of the shadow those
    /// blocks agree on (their median)…
    /// </summary>
    public const double ConsensusTolerance = 0.05;
    /// <summary>…plus this share of the shadow's depth there (shadows are deeper at one end of the spine than the other).</summary>
    public const double ConsensusSpread = 0.4;
    /// <summary>The shadow is softened when it darkens the paper by at least this share…</summary>
    public const double MinDepth = 0.04;
    /// <summary>
    /// …it is deepest within this many inches of the edge (a spine's shadow fades away from the spine), and
    /// it has faded before the end of the band (something dark all across the band is no shadow).
    /// </summary>
    public const double MaxDeepestInches = 0.25;
    /// <summary>Paper darkened by less than this share is left alone (noise, the last trace of the shadow).</summary>
    public const double DeadZone = 0.02;
    /// <summary>
    /// A shadow fades gradually: from a quarter of the way back to the paper to within <see cref="DeadZone"/>
    /// of it takes at least this many inches (a tint or a bar printed along the spine comes back in a step).
    /// </summary>
    public const double MinFadeInches = 0.04;
    /// <summary>No pixel is brightened more than this many times (the fold itself can be nearly black).</summary>
    public const double MaxGain = 2.5;
    /// <summary>The gain eases to none over the last this many inches of the band.</summary>
    public const double TaperInches = 0.2;
    /// <summary>A pixel darker than this share of the shadowed paper there may be part of a picture…</summary>
    public const double PictureLevel = 0.85;
    /// <summary>…once thin strokes (text, lines) are taken away: the mask is opened with this many inches…</summary>
    public const double OpenInches = 0.02;
    /// <summary>…the parts of a picture split by its light areas are joined across this many inches…</summary>
    public const double CloseInches = 0.05;
    /// <summary>…and a picture covers at least a square this many inches on a side; its box is left alone.</summary>
    public const double MinPictureInches = 0.3;
    /// <summary>Beyond a picture's box, the gain fades in over twice this many inches.</summary>
    public const double FeatherInches = 0.03;

    /// <summary>
    /// The edge of a page cut from a spread that ran along the spine: the edge of the cut (the right edge
    /// of a left page, the bottom edge of a top page…), turned with the page by the book's rotation
    /// (<paramref name="rotationQuarterTurns"/> clockwise). Null for a page not cut from a spread, or a whole one.
    /// </summary>
    public static PageEdge? GutterEdge(SpreadPart? spread, int rotationQuarterTurns)
    {
        if (spread is not { Part: { } part, Gutter: { } gutter }) return null;
        var edge = gutter.Axis == GutterAxis.Vertical
            ? part == 0 ? PageEdge.Right : PageEdge.Left
            : part == 0 ? PageEdge.Bottom : PageEdge.Top;
        return Turned(edge, rotationQuarterTurns);
    }

    /// <summary>Where <paramref name="edge"/> lies once the page is turned <paramref name="quarterTurns"/> clockwise.</summary>
    public static PageEdge Turned(PageEdge edge, int quarterTurns) =>
        (PageEdge)(((int)edge + BookSplitter.NormalizedTurns(quarterTurns)) % 4);

    /// <summary>The tooltip of "Soften spine shadow", on (<paramref name="on"/>) or off: what it does.</summary>
    public static string Hint(bool on) => "Lightens the dark band along the spine";

    /// <summary>
    /// <paramref name="image"/> (scanned at <paramref name="dpi"/>) with the shadow along <paramref name="edge"/>
    /// softened, and what was done; null when there is no shadow to soften (or the page is too small or dark).
    /// </summary>
    public static SpineShadowCorrection? Soften(RgbaImage image, int dpi, PageEdge edge)
    {
        var gray = GrayImage.From(image, dpi);
        if (Estimate(gray, edge) is not { } model) return null;
        return new SpineShadowCorrection(Apply(image, model), model.Result);
    }

    /// <summary>
    /// The shadow along <paramref name="edge"/> of <paramref name="gray"/> (a page's gray copy, at most the
    /// analysis resolution), as the gain of every pixel of the band along it; null when the paper there is
    /// not darkened by at least <see cref="MinDepth"/>, or the page is too small or too dark.
    /// </summary>
    public static SpineShadowModel? Estimate(GrayImage gray, PageEdge edge)
    {
        double dpi = gray.Dpi;
        bool alongX = edge is PageEdge.Left or PageEdge.Right;
        int extent = alongX ? gray.Width : gray.Height;
        int length = alongX ? gray.Height : gray.Width;
        int band = Math.Min(Pixels(BandInches, dpi), (int)(extent * MaxBandFraction));
        int reference = Math.Min(Pixels(ReferenceInches, dpi), extent - band);
        if (band < Pixels(MinBandInches, dpi) || reference < 1) return null;
        int span = band + reference;
        var strip = Oriented(gray, edge, span);
        int blockRows = Math.Max(MinBlockRows, Pixels(BlockInches, dpi));
        int blocks = Math.Max(1, length / blockRows);

        // The paper's brightness in every cell: a block of rows, three columns.
        var level = new double[blocks * span];
        var histogram = new int[256];
        for (int j = 0; j < blocks; j++)
        {
            int r0 = j * length / blocks, r1 = (j + 1) * length / blocks;
            for (int u = 0; u < span; u++)
            {
                Array.Clear(histogram);
                int c0 = Math.Max(0, u - 1), c1 = Math.Min(span - 1, u + 1);
                for (int r = r0; r < r1; r++)
                {
                    int row = r * span;
                    for (int c = c0; c <= c1; c++) histogram[strip[row + c]]++;
                }
                level[j * span + u] = BackgroundMap.Percentile(histogram, (r1 - r0) * (c1 - c0 + 1), PaperPercentile);
            }
        }

        // The paper of each block, past the shadow: the upper quartile of the reference stretch. A block
        // whose reference is no paper (a picture, the lid) takes the page's.
        var paper = new double[blocks];
        var stretch = new double[reference];
        for (int j = 0; j < blocks; j++)
        {
            Array.Copy(level, j * span + band, stretch, 0, reference);
            Array.Sort(stretch);
            paper[j] = stretch[reference * 3 / 4];
        }
        double pagePaper = Sorted(paper)[blocks / 2];
        if (pagePaper < MinPaper) return null;
        for (int j = 0; j < blocks; j++)
        {
            if (paper[j] < pagePaper * (1 - PaperTolerance) || paper[j] > pagePaper * (1 + PaperTolerance)) paper[j] = pagePaper;
        }
        paper = RunningMedian(paper, 2);

        // How much of the paper's light is left in each cell.
        var share = new double[blocks * band];
        for (int j = 0; j < blocks; j++)
        {
            for (int u = 0; u < band; u++) share[j * band + u] = Math.Min(1.0, level[j * span + u] / paper[j]);
        }
        // The blocks that show the spine's shadow: darker near the edge, paper again at the far side of the
        // band (not a picture or a tint running across it, not the lid beside the book). The shadow they
        // agree on is their median.
        int near = Math.Min(band, Pixels(MaxDeepestInches, dpi)), fadeFrom = band - band / 4;
        var shadowed = new List<int>();
        for (int j = 0; j < blocks; j++)
        {
            double darkest = 1;
            for (int u = 0; u < near; u++) darkest = Math.Min(darkest, share[j * band + u]);
            bool faded = true;
            for (int u = fadeFrom; u < band; u++)
            {
                if (share[j * band + u] < 1 - FadeTolerance) faded = false;
            }
            if (1 - darkest >= MinDepth && faded) shadowed.Add(j);
        }
        if (shadowed.Count < Math.Max(MinShadowedBlocks, (int)Math.Ceiling(blocks * MinShadowedShare))) return null;
        var consensus = new double[band];
        var column = new double[shadowed.Count];
        for (int u = 0; u < band; u++)
        {
            for (int k = 0; k < shadowed.Count; k++) column[k] = share[shadowed[k] * band + u];
            Array.Sort(column);
            consensus[u] = column[shadowed.Count / 2];
        }
        var profile = Smoothed(consensus);
        double deepest = 1;
        int deepestAt = 0, reach = 0;
        for (int u = 0; u < band; u++)
        {
            if (profile[u] < deepest)
            {
                deepest = profile[u];
                deepestAt = u;
            }
            if (profile[u] < 1 - DeadZone) reach = u + 1;
        }
        double depth = 1 - deepest;
        if (depth < MinDepth || deepestAt >= Pixels(MaxDeepestInches, dpi) || reach >= band) return null;
        // A shadow fades gradually; a tint or a bar printed all along the spine comes back to the paper in a
        // step, and is no shadow.
        int quarterBack = reach;
        for (int u = deepestAt; u < reach; u++)
        {
            if (profile[u] >= deepest + depth / 4)
            {
                quarterBack = u;
                break;
            }
        }
        if (reach - quarterBack < Pixels(MinFadeInches, dpi)) return null;

        // Cells that are shadowed paper. A cell darker than the shadow allows is no paper, and neither is
        // anything between it and the edge (a picture or a tint reaching the spine): those take the shadow
        // of the blocks beside them. A lighter cell (less shadow, the lid, a hole) keeps its own.
        var paperCell = new bool[blocks * band];
        for (int j = 0; j < blocks; j++)
        {
            bool darkFurther = false;
            for (int u = band - 1; u >= 0; u--)
            {
                double tolerance = ConsensusTolerance + ConsensusSpread * (1 - consensus[u]);
                double difference = share[j * band + u] - consensus[u];
                if (difference < -tolerance) darkFurther = true;
                paperCell[j * band + u] = !darkFurther;
            }
        }
        var shadow = new double[blocks * band];
        for (int u = 0; u < band; u++)
        {
            for (int j = 0; j < blocks; j++)
            {
                if (paperCell[j * band + u])
                {
                    shadow[j * band + u] = share[j * band + u];
                    continue;
                }
                int before = j - 1, after = j + 1;
                while (before >= 0 && !paperCell[before * band + u]) before--;
                while (after < blocks && !paperCell[after * band + u]) after++;
                double value;
                if (before >= 0 && after < blocks)
                {
                    double a = share[before * band + u], b = share[after * band + u];
                    value = a + (b - a) * (j - before) / (after - before);
                }
                else if (before >= 0) value = share[before * band + u];
                else if (after < blocks) value = share[after * band + u];
                else value = consensus[u];
                shadow[j * band + u] = value;
            }
        }
        // Smooth across the rows (twice), then along the edge's distance.
        shadow = SmoothedRows(SmoothedRows(shadow, blocks, band), blocks, band);
        shadow = SmoothedColumns(shadow, blocks, band);

        // The gain of each cell: the paper back to white, capped, easing out at the far side of the band.
        int taper = Pixels(TaperInches, dpi);
        var cellGain = new double[blocks * band];
        for (int j = 0; j < blocks; j++)
        {
            for (int u = 0; u < band; u++)
            {
                double light = shadow[j * band + u];
                double gain = light <= 0 ? MaxGain : Math.Clamp((1 - DeadZone) / light, 1.0, MaxGain);
                double ease = Math.Min(1.0, (double)(band - u) / taper);
                cellGain[j * band + u] = 1 + (gain - 1) * ease;
            }
        }

        // Every band pixel: the cells interpolated between block centres along the edge; pictures left alone.
        var (first, second, weight) = Interpolation(length, blocks);
        var pictures = new byte[length * band];
        for (int v = 0; v < length; v++)
        {
            int j0 = first[v], j1 = second[v];
            double f = weight[v];
            double paperHere = paper[j0] + (paper[j1] - paper[j0]) * f;
            for (int u = 0; u < band; u++)
            {
                double s0 = shadow[j0 * band + u], s1 = shadow[j1 * band + u];
                double expected = paperHere * (s0 + (s1 - s0) * f);
                if (strip[v * span + u] < PictureLevel * expected) pictures[v * band + u] = 1;
            }
        }
        pictures = PictureAreas(pictures, band, length, dpi);
        var protection = Feathered(pictures, band, length, Pixels(FeatherInches, dpi));
        var gains = new double[length * band];
        double maxGain = 1;
        int protectedPixels = 0;
        for (int v = 0; v < length; v++)
        {
            int j0 = first[v], j1 = second[v];
            double f = weight[v];
            for (int u = 0; u < band; u++)
            {
                double g0 = cellGain[j0 * band + u], g1 = cellGain[j1 * band + u];
                double gain = g0 + (g1 - g0) * f;
                int i = v * band + u;
                gain = 1 + (gain - 1) * (1 - protection[i]);
                gains[i] = gain;
                if (gain > maxGain) maxGain = gain;
                if (pictures[i] != 0) protectedPixels++;
            }
        }
        var result = new SpineShadowResult(edge, depth, reach / dpi, maxGain, (double)protectedPixels / (length * band));
        return new SpineShadowModel(edge, extent, length, band, gains, pictures, result);
    }

    /// <summary>
    /// <paramref name="image"/> with every pixel in the model's band brightened by its gain (each of red,
    /// green and blue multiplied, rounded, at most 255; alpha kept): the model's band pixels interpolated
    /// (bilinear) at the image's resolution, easing to no gain past the band. A pixel whose nearest model
    /// pixel is on a picture's box (<see cref="SpineShadowModel.Pictures"/>) keeps its value; on an image finer
    /// than the model, so does one whose nearest model pixel is beside a box (the picture's edge may lie in it).
    /// </summary>
    public static RgbaImage Apply(RgbaImage image, SpineShadowModel model)
    {
        bool alongX = model.Edge is PageEdge.Left or PageEdge.Right;
        int w = image.Width, h = image.Height;
        int extent = alongX ? w : h;
        int length = alongX ? h : w;
        // Analysis pixels per image pixel, away from the edge and along it.
        double scaleU = (double)model.Extent / extent;
        double scaleV = (double)model.Length / length;
        int band = model.Band;
        int reach = Math.Min(extent, (int)((band + 1) / scaleU) + 1);
        var u0s = new int[reach];
        var u1s = new int[reach];
        var fus = new double[reach];
        var nearestUs = new int[reach];
        for (int uf = 0; uf < reach; uf++)
        {
            double ua = (uf + 0.5) * scaleU - 0.5;
            if (ua <= 0)
            {
                u0s[uf] = 0; u1s[uf] = 0; fus[uf] = 0; nearestUs[uf] = 0;
            }
            else
            {
                int k = (int)ua;
                u0s[uf] = k; u1s[uf] = k + 1; fus[uf] = ua - k;   // column `band` and beyond: no gain
                nearestUs[uf] = (int)(ua + 0.5);
            }
        }
        var pixels = (byte[])image.Pixels.Clone();
        var gains = model.Gains;
        // On a finer image, a picture's edge can fall inside an analysis pixel that is lighter than the picture
        // and so outside its box: the boxes are grown by one analysis pixel, so that edge keeps its pixels too.
        var pictures = scaleU < 1 || scaleV < 1 ? MaskOps.Dilate(model.Pictures, band, model.Length, 1) : model.Pictures;
        for (int vf = 0; vf < length; vf++)
        {
            double va = (vf + 0.5) * scaleV - 0.5;
            int v0, v1, nearestV;
            double fv;
            if (va <= 0)
            {
                v0 = 0; v1 = 0; fv = 0; nearestV = 0;
            }
            else if (va >= model.Length - 1)
            {
                v0 = model.Length - 1; v1 = model.Length - 1; fv = 0; nearestV = model.Length - 1;
            }
            else
            {
                v0 = (int)va; v1 = v0 + 1; fv = va - v0; nearestV = (int)(va + 0.5);
            }
            for (int uf = 0; uf < reach; uf++)
            {
                int a = u0s[uf], b = u1s[uf];
                if (a >= band) break;
                // A pixel of a picture's box (grown on a finer image) keeps its value, whatever the gain beside it.
                int nearestU = nearestUs[uf];
                if (nearestU < band && pictures[nearestV * band + nearestU] != 0) continue;
                double g00 = gains[v0 * band + a], g10 = gains[v1 * band + a];
                double g01 = b < band ? gains[v0 * band + b] : 1.0;
                double g11 = b < band ? gains[v1 * band + b] : 1.0;
                double top = g00 + (g01 - g00) * fus[uf];
                double bottom = g10 + (g11 - g10) * fus[uf];
                double gain = top + (bottom - top) * fv;
                if (gain <= 1) continue;
                int x, y;
                switch (model.Edge)
                {
                    case PageEdge.Left: x = uf; y = vf; break;
                    case PageEdge.Right: x = w - 1 - uf; y = vf; break;
                    case PageEdge.Top: x = vf; y = uf; break;
                    default: x = vf; y = h - 1 - uf; break;
                }
                int i = (y * w + x) * 4;
                for (int c = 0; c < 3; c++)
                {
                    int value = (int)(pixels[i + c] * gain + 0.5);
                    pixels[i + c] = (byte)(value > 255 ? 255 : value);
                }
            }
        }
        return new RgbaImage(w, h, pixels);
    }

    // MARK: - Helpers

    /// <summary>Inches as whole pixels at <paramref name="dpi"/>, rounded, at least 1.</summary>
    private static int Pixels(double inches, double dpi) => Math.Max(1, (int)(inches * dpi + 0.5));

    /// <summary>
    /// The first <paramref name="span"/> columns of <paramref name="gray"/> away from <paramref name="edge"/>,
    /// as rows along it: pixel (u, v) at v × span + u is u pixels from the edge, v along it from its left
    /// or top end.
    /// </summary>
    private static byte[] Oriented(GrayImage gray, PageEdge edge, int span)
    {
        int w = gray.Width, h = gray.Height;
        int length = edge is PageEdge.Left or PageEdge.Right ? h : w;
        var output = new byte[length * span];
        for (int v = 0; v < length; v++)
        {
            for (int u = 0; u < span; u++)
            {
                int index = edge switch
                {
                    PageEdge.Left => v * w + u,
                    PageEdge.Right => v * w + (w - 1 - u),
                    PageEdge.Top => u * w + v,
                    _ => (h - 1 - u) * w + v,
                };
                output[v * span + u] = gray.Pixels[index];
            }
        }
        return output;
    }

    private static double[] Sorted(double[] values)
    {
        var copy = (double[])values.Clone();
        Array.Sort(copy);
        return copy;
    }

    /// <summary>Each value replaced by the median of itself and <paramref name="radius"/> values either side (fewer at the ends; the upper middle of an even count).</summary>
    private static double[] RunningMedian(double[] values, int radius)
    {
        int n = values.Length;
        var output = new double[n];
        for (int i = 0; i < n; i++)
        {
            int from = Math.Max(0, i - radius), to = Math.Min(n - 1, i + radius);
            var window = new double[to - from + 1];
            Array.Copy(values, from, window, 0, window.Length);
            Array.Sort(window);
            output[i] = window[window.Length / 2];
        }
        return output;
    }

    /// <summary>The 1-2-1 filter, the end values repeated.</summary>
    private static double[] Smoothed(double[] values)
    {
        int n = values.Length;
        var output = new double[n];
        for (int i = 0; i < n; i++)
        {
            double before = values[Math.Max(0, i - 1)], after = values[Math.Min(n - 1, i + 1)];
            output[i] = (before + 2 * values[i] + after) / 4;
        }
        return output;
    }

    /// <summary>The 1-2-1 filter down each column of a rows × columns grid (across the blocks), the end rows repeated.</summary>
    private static double[] SmoothedRows(double[] grid, int rows, int columns)
    {
        var output = new double[grid.Length];
        for (int j = 0; j < rows; j++)
        {
            int above = Math.Max(0, j - 1) * columns, below = Math.Min(rows - 1, j + 1) * columns, here = j * columns;
            for (int u = 0; u < columns; u++)
            {
                output[here + u] = (grid[above + u] + 2 * grid[here + u] + grid[below + u]) / 4;
            }
        }
        return output;
    }

    /// <summary>The 1-2-1 filter along each row of a rows × columns grid (away from the edge), the end columns repeated.</summary>
    private static double[] SmoothedColumns(double[] grid, int rows, int columns)
    {
        var output = new double[grid.Length];
        for (int j = 0; j < rows; j++)
        {
            int row = j * columns;
            for (int u = 0; u < columns; u++)
            {
                double before = grid[row + Math.Max(0, u - 1)], after = grid[row + Math.Min(columns - 1, u + 1)];
                output[row + u] = (before + 2 * grid[row + u] + after) / 4;
            }
        }
        return output;
    }

    /// <summary>
    /// For each of <paramref name="length"/> rows split into <paramref name="blocks"/> blocks (as the
    /// cells were): the blocks whose centres surround the row's centre and the second one's weight; the
    /// nearest block beyond the outer centres.
    /// </summary>
    private static (int[] First, int[] Second, double[] Weight) Interpolation(int length, int blocks)
    {
        var first = new int[length];
        var second = new int[length];
        var weight = new double[length];
        var centers = new double[blocks];
        for (int t = 0; t < blocks; t++)
        {
            int start = t * length / blocks, end = (t + 1) * length / blocks;
            centers[t] = (start + end) / 2.0;
        }
        int k = 0;
        for (int p = 0; p < length; p++)
        {
            double c = p + 0.5;
            while (k < blocks - 1 && centers[k + 1] <= c) k++;
            if (c <= centers[0])
            {
                first[p] = 0; second[p] = 0; weight[p] = 0;
            }
            else if (k >= blocks - 1)
            {
                first[p] = blocks - 1; second[p] = blocks - 1; weight[p] = 0;
            }
            else
            {
                first[p] = k; second[p] = k + 1;
                weight[p] = (c - centers[k]) / (centers[k + 1] - centers[k]);
            }
        }
        return (first, second, weight);
    }

    /// <summary>
    /// The pictures among the dark pixels of the band: the mask opened (thin strokes of text and lines
    /// gone) and closed (a picture's parts joined across its light areas, the band's sides counting as
    /// set), then the box around each part at least <see cref="MinPictureInches"/> square in area (printed
    /// pictures are rectangles; a light corner of one is still inside its box).
    /// </summary>
    private static byte[] PictureAreas(byte[] dark, int width, int height, double dpi)
    {
        int open = Pixels(OpenInches, dpi), close = Pixels(CloseInches, dpi);
        var opened = MaskOps.Dilate(MaskOps.Erode(dark, width, height, open), width, height, open);
        var closed = MaskOps.Erode(MaskOps.Dilate(opened, width, height, close), width, height, close, outsideSet: true);
        int side = Pixels(MinPictureInches, dpi);
        int minArea = side * side;
        var output = new byte[width * height];
        foreach (var component in MaskOps.ConnectedComponents(closed, width, height))
        {
            if (component.Area < minArea) continue;
            int top = height, bottom = -1, left = width, right = -1;
            foreach (var (row, extent) in component.Rows)
            {
                top = Math.Min(top, row);
                bottom = Math.Max(bottom, row);
                left = Math.Min(left, extent.MinX);
                right = Math.Max(right, extent.MaxX);
            }
            for (int y = top; y <= bottom; y++)
            {
                for (int x = left; x <= right; x++) output[y * width + x] = 1;
            }
        }
        return output;
    }

    /// <summary>
    /// How much each pixel is left alone, 0...1: 1 on a picture's box, fading to 0 over the
    /// 2 × <paramref name="radius"/> pixels beyond it (the mask grown by <paramref name="radius"/>, then averaged
    /// over a square of 2 × radius + 1, clipped to the band). <see cref="Apply"/> keeps the box itself hard at
    /// the image's resolution.
    /// </summary>
    private static double[] Feathered(byte[] mask, int width, int height, int radius)
    {
        var grown = MaskOps.Dilate(mask, width, height, radius);
        // Summed-area table of the grown mask.
        var sums = new int[(width + 1) * (height + 1)];
        for (int y = 0; y < height; y++)
        {
            int rowSum = 0;
            for (int x = 0; x < width; x++)
            {
                rowSum += grown[y * width + x];
                sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + rowSum;
            }
        }
        var output = new double[width * height];
        for (int y = 0; y < height; y++)
        {
            int y0 = Math.Max(0, y - radius), y1 = Math.Min(height, y + radius + 1);
            for (int x = 0; x < width; x++)
            {
                int x0 = Math.Max(0, x - radius), x1 = Math.Min(width, x + radius + 1);
                int total = sums[y1 * (width + 1) + x1] - sums[y0 * (width + 1) + x1]
                            - sums[y1 * (width + 1) + x0] + sums[y0 * (width + 1) + x0];
                output[y * width + x] = (double)total / ((y1 - y0) * (x1 - x0));
            }
        }
        return output;
    }
}
