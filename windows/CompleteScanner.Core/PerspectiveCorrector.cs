namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/PerspectiveCorrector.swift: + − × ÷ and square roots
// on doubles in the same order, rounding halves to even as RgbaImage's bilinear sampler does, so
// the same photo and quad give the same bytes on both platforms.

/// <summary>The shape of the sheet a quad shows, worked out from the photo (<see cref="PerspectiveCorrector.EstimateAspect(Quad, double, double)"/>).</summary>
/// <param name="WidthOverHeight">The sheet's width (top edge) over its height (left edge), as it lies in the photo.</param>
/// <param name="FocalLength">
/// The camera's focal length in pixels that explains the quad, when the quad says (a sheet seen
/// at an angle); null when it does not (seen straight on, or the quad fits no camera centered on
/// the photo), and the shape then comes from the edge lengths.
/// </param>
public readonly record struct AspectEstimate(double WidthOverHeight, double? FocalLength)
{
    /// <summary>The long side over the short side (at least 1).</summary>
    public double LongOverShort => WidthOverHeight >= 1 ? WidthOverHeight : 1 / WidthOverHeight;
}

/// <summary>A known sheet whose shape matched (<see cref="PerspectiveCorrector.MatchPaper"/>).</summary>
/// <param name="Size">The size taken for the match. A4 stands for every √2 sheet (A4, A5, A6).</param>
/// <param name="LongOverShort">That size's long side over its short side.</param>
public sealed record PaperMatch(PaperSize Size, double LongOverShort);

/// <summary>How the corrected page is resampled.</summary>
public enum Supersampling
{
    /// <summary>Four samples per pixel when the page is made smaller than the photo shows it (by more than 1.25), one otherwise.</summary>
    Auto,
    /// <summary>One bicubic sample per pixel.</summary>
    Off,
    /// <summary>Four bicubic samples per pixel (2 × 2), averaged.</summary>
    On,
}

/// <summary>Options of <see cref="PerspectiveCorrector"/>.</summary>
public sealed record PerspectiveOptions
{
    /// <summary>The output size, when the caller knows it (both or neither); otherwise it comes from the quad.</summary>
    public int? OutputWidth { get; init; }
    public int? OutputHeight { get; init; }
    /// <summary>
    /// The longest output side; 0 for no limit of the caller's own (the output is still kept within
    /// <see cref="PerspectiveCorrector.MaxPhotoDiagonals"/> of the photo and <see cref="PerspectiveCorrector.MaxOutputSide"/>).
    /// </summary>
    public int MaxLongSide { get; init; }
    /// <summary>A sheet's shape matches a known size within this share (<see cref="PerspectiveCorrector.PaperAspectTolerance"/>).</summary>
    public double PaperAspectTolerance { get; init; } = PerspectiveCorrector.PaperAspectTolerance;
    /// <summary>Snap the shape to a known size when it matches.</summary>
    public bool SnapToPaper { get; init; } = true;
    public Supersampling Supersample { get; init; } = Supersampling.Auto;
    /// <summary>The color of what lies outside the photo (opaque).</summary>
    public byte FillR { get; init; } = 255;
    public byte FillG { get; init; } = 255;
    public byte FillB { get; init; } = 255;

    public static PerspectiveOptions Default { get; } = new();
}

/// <summary>What <see cref="PerspectiveCorrector.Plan"/> decided.</summary>
/// <param name="Width">Output width in pixels.</param>
/// <param name="Height">Output height in pixels.</param>
/// <param name="OutputToSource">Maps an output point (continuous pixels) to the photo.</param>
/// <param name="WidthOverHeight">The shape used for the output.</param>
/// <param name="Paper">The known size the shape snapped to, if any.</param>
/// <param name="Dpi">
/// The resolution of the output when <see cref="Paper"/> is known (output pixels per inch of
/// that size); null otherwise (callers use <see cref="PerspectiveCorrector.NominalDpi"/>).
/// </param>
/// <param name="Supersampled">Four samples per pixel are taken.</param>
public sealed record PerspectivePlan(int Width, int Height, Homography OutputToSource, double WidthOverHeight,
                                     PaperMatch? Paper, double? Dpi, bool Supersampled);

/// <summary>A page made upright (<see cref="PerspectiveCorrector.Correct"/>).</summary>
public sealed record PerspectiveCorrection(RgbaImage Image, PerspectivePlan Plan);

/// <summary>
/// Turns the page a quad outlines in a photo into an upright rectangle: the homography from the
/// output rectangle to the quad, the output size from the quad (the longer of each pair of
/// opposite edges, so the nearer edge keeps its pixels) and the sheet's shape (a known paper
/// size when it matches, else the camera's view of the quad, else the edge lengths), then
/// bicubic (Catmull-Rom) resampling, with 2 × 2 supersampling when the page is made smaller.
/// </summary>
public static class PerspectiveCorrector
{
    /// <summary>A shape matches a known size when the long-over-short ratios differ by at most this share (3 %).</summary>
    public const double PaperAspectTolerance = 0.03;
    /// <summary>The resolution taken for a page whose size is unknown.</summary>
    public const double NominalDpi = 200;
    /// <summary>A focal length explains a quad only between these multiples of the photo's diagonal…</summary>
    public const double MinFocalDiagonals = 0.3;
    /// <summary>…and this many.</summary>
    public const double MaxFocalDiagonals = 4.0;
    /// <summary>Supersampling (Auto) starts when an output pixel covers more than this many photo pixels across.</summary>
    public const double SupersampleAbove = 1.25;
    /// <summary>The output's long side is at most this many times the photo's diagonal (a corner dragged far outside the photo)…</summary>
    public const double MaxPhotoDiagonals = 2.0;
    /// <summary>
    /// …and at most this many pixels, so that any output's RGBA bytes fit in one array (23170² × 4
    /// is less than <see cref="Array.MaxLength"/>); a size given by the caller beyond it has no plan.
    /// </summary>
    public const int MaxOutputSide = 23170;

    /// <summary>The sizes a camera page is matched against, in this order (the nearest wins).</summary>
    public static IReadOnlyList<PaperSize> MatchedSizes { get; } = [PaperSize.A4, PaperSize.Letter, PaperSize.Legal, PaperSize.IdCard];

    /// <summary>
    /// The shape of the flat rectangle seen as <paramref name="quad"/> in a photo of
    /// <paramref name="imageWidth"/> × <paramref name="imageHeight"/> taken by a camera centered on
    /// the photo with square pixels (Zhang and He, "Whiteboard scanning and image enhancement",
    /// 2007). When the quad is seen straight on, or no focal length between
    /// <see cref="MinFocalDiagonals"/> and <see cref="MaxFocalDiagonals"/> diagonals explains it,
    /// the shape is the mean of the opposite edge lengths' ratio.
    /// </summary>
    public static AspectEstimate EstimateAspect(Quad quad, double imageWidth, double imageHeight)
    {
        double fallback = EdgeAspect(quad);
        if (Rays(quad, imageWidth, imageHeight) is not { } r) return new AspectEstimate(fallback, null);
        double n2x = r.N2X, n2y = r.N2Y, n2z = r.N2Z, n3x = r.N3X, n3y = r.N3Y, n3z = r.N3Z;
        double diagonal = Math.Sqrt(imageWidth * imageWidth + imageHeight * imageHeight);
        double zz = n2z * n3z;
        // Seen straight on (opposite edges parallel), the camera's distance cannot be told.
        double scale = Math.Abs(n2x) + Math.Abs(n2y) + Math.Abs(n3x) + Math.Abs(n3y);
        if (Math.Abs(n2z) * diagonal > 1e-3 * scale || Math.Abs(n3z) * diagonal > 1e-3 * scale)
        {
            double f2 = -(n2x * n3x + n2y * n3y) / zz;
            if (zz != 0 && f2 > 0 && double.IsFinite(f2))
            {
                double f = Math.Sqrt(f2);
                if (f >= MinFocalDiagonals * diagonal && f <= MaxFocalDiagonals * diagonal)
                {
                    double num = n2x * n2x + n2y * n2y + f2 * n2z * n2z;
                    double den = n3x * n3x + n3y * n3y + f2 * n3z * n3z;
                    if (num > 0 && den > 0) return new AspectEstimate(Math.Sqrt(num / den), f);
                }
            }
        }
        return new AspectEstimate(fallback, null);
    }

    /// <summary>
    /// The shape of the flat rectangle seen as <paramref name="quad"/> by a camera of known
    /// <paramref name="focalLength"/> (in pixels of this photo) centered on the photo with square
    /// pixels: the construction of <see cref="EstimateAspect(Quad, double, double)"/> with the focal
    /// length given rather than worked out, so a sheet tilted about an axis along one of its edges
    /// (where the quad alone tells no focal length) gets its shape as well. A focal length that is not
    /// a positive number gives <see cref="EstimateAspect(Quad, double, double)"/>; a quad that gives
    /// no shape the mean of the opposite edge lengths' ratio (with no focal length).
    /// </summary>
    public static AspectEstimate EstimateAspect(Quad quad, double imageWidth, double imageHeight, double focalLength)
    {
        if (!(focalLength > 0) || !double.IsFinite(focalLength)) return EstimateAspect(quad, imageWidth, imageHeight);
        double fallback = EdgeAspect(quad);
        if (Rays(quad, imageWidth, imageHeight) is not { } r) return new AspectEstimate(fallback, null);
        double f2 = focalLength * focalLength;
        double num = r.N2X * r.N2X + r.N2Y * r.N2Y + f2 * r.N2Z * r.N2Z;
        double den = r.N3X * r.N3X + r.N3Y * r.N3Y + f2 * r.N3Z * r.N3Z;
        if (num > 0 && den > 0 && double.IsFinite(num / den)) return new AspectEstimate(Math.Sqrt(num / den), focalLength);
        return new AspectEstimate(fallback, null);
    }

    /// <summary>
    /// The known size (<see cref="MatchedSizes"/>) whose long-over-short ratio is nearest to
    /// <paramref name="longOverShort"/>, when within <paramref name="tolerance"/> of it (as a share
    /// of the size's ratio); null otherwise.
    /// </summary>
    public static PaperMatch? MatchPaper(double longOverShort, double tolerance = PaperAspectTolerance)
    {
        PaperMatch? best = null;
        double bestDiff = double.MaxValue;
        foreach (var size in MatchedSizes)
        {
            if (PaperSizes.Inches(size) is not { } inches) continue;
            double ratio = Math.Max(inches.Width, inches.Height) / Math.Min(inches.Width, inches.Height);
            double diff = Math.Abs(longOverShort - ratio) / ratio;
            if (diff <= tolerance && diff < bestDiff)
            {
                bestDiff = diff;
                best = new PaperMatch(size, ratio);
            }
        }
        return best;
    }

    /// <summary>
    /// The output size, the map and the resolution for the page <paramref name="quad"/> outlines
    /// in a photo of <paramref name="imageWidth"/> × <paramref name="imageHeight"/>. The long side
    /// taken from the quad is cut to <see cref="PerspectiveOptions.MaxLongSide"/>,
    /// <see cref="MaxPhotoDiagonals"/> of the photo's diagonal and <see cref="MaxOutputSide"/>. Null
    /// for a quad that is not convex, a photo without pixels, or an output size given beyond
    /// <see cref="MaxOutputSide"/>.
    /// </summary>
    public static PerspectivePlan? Plan(Quad quad, int imageWidth, int imageHeight, PerspectiveOptions? options = null)
    {
        var o = options ?? PerspectiveOptions.Default;
        if (!quad.IsConvex || imageWidth <= 0 || imageHeight <= 0) return null;
        double top = quad.EdgeLength(0), right = quad.EdgeLength(1), bottom = quad.EdgeLength(2), left = quad.EdgeLength(3);
        double w0 = Math.Max(top, bottom), h0 = Math.Max(left, right);
        var estimate = EstimateAspect(quad, imageWidth, imageHeight);
        double aspect = estimate.WidthOverHeight;
        PaperMatch? paper = o.SnapToPaper ? MatchPaper(estimate.LongOverShort, o.PaperAspectTolerance) : null;
        if (paper is not null) aspect = aspect >= 1 ? paper.LongOverShort : 1 / paper.LongOverShort;

        int width, height;
        if (o.OutputWidth is { } fw && o.OutputHeight is { } fh && fw > 0 && fh > 0)
        {
            width = fw;
            height = fh;
        }
        else
        {
            double longSide = Math.Max(w0, h0);
            if (o.MaxLongSide > 0) longSide = Math.Min(longSide, o.MaxLongSide);
            double photoDiagonal = Math.Sqrt((double)imageWidth * imageWidth + (double)imageHeight * imageHeight);
            longSide = Math.Min(longSide, Math.Min(MaxPhotoDiagonals * photoDiagonal, MaxOutputSide));
            double wd, hd;
            if (aspect >= 1)
            {
                wd = longSide;
                hd = longSide / aspect;
            }
            else
            {
                hd = longSide;
                wd = longSide * aspect;
            }
            if (!double.IsFinite(wd) || !double.IsFinite(hd)) return null;
            width = Math.Max(1, (int)Math.Floor(wd + 0.5));
            height = Math.Max(1, (int)Math.Floor(hd + 0.5));
        }
        if (!FitsOutput(width, height)) return null;
        if (Homography.RectToQuad(width, height, quad) is not { } map) return null;

        double? dpi = null;
        if (paper is not null && PaperSizes.Inches(paper.Size) is { } inches)
        {
            dpi = Math.Max(width, height) / Math.Max(inches.Width, inches.Height);
        }
        bool supersample = o.Supersample switch
        {
            Supersampling.On => true,
            Supersampling.Off => false,
            _ => w0 > width * SupersampleAbove || h0 > height * SupersampleAbove,
        };
        return new PerspectivePlan(width, height, map, (double)width / height, paper, dpi, supersample);
    }

    /// <summary><paramref name="image"/> resampled as <paramref name="plan"/> says.</summary>
    public static RgbaImage Warp(RgbaImage image, PerspectivePlan plan, PerspectiveOptions? options = null)
    {
        var o = options ?? PerspectiveOptions.Default;
        int w = plan.Width, h = plan.Height;
        if (!FitsOutput(w, h)) throw new ArgumentException($"A {w} × {h} output is not possible.", nameof(plan));
        var output = new byte[w * h * 4];
        var m = plan.OutputToSource;
        var acc = new double[4];
        for (int oy = 0; oy < h; oy++)
        {
            for (int ox = 0; ox < w; ox++)
            {
                int di = (oy * w + ox) * 4;
                if (plan.Supersampled)
                {
                    acc[0] = 0; acc[1] = 0; acc[2] = 0; acc[3] = 0;
                    for (int s = 0; s < 4; s++)
                    {
                        double px = ox + ((s & 1) == 0 ? 0.25 : 0.75);
                        double py = oy + ((s >> 1) == 0 ? 0.25 : 0.75);
                        Accumulate(image, m, px, py, acc, o);
                    }
                    output[di] = RoundByte(acc[0] / 4);
                    output[di + 1] = RoundByte(acc[1] / 4);
                    output[di + 2] = RoundByte(acc[2] / 4);
                    output[di + 3] = RoundByte(acc[3] / 4);
                }
                else
                {
                    acc[0] = 0; acc[1] = 0; acc[2] = 0; acc[3] = 0;
                    Accumulate(image, m, ox + 0.5, oy + 0.5, acc, o);
                    output[di] = RoundByte(acc[0]);
                    output[di + 1] = RoundByte(acc[1]);
                    output[di + 2] = RoundByte(acc[2]);
                    output[di + 3] = RoundByte(acc[3]);
                }
            }
        }
        return new RgbaImage(w, h, output);
    }

    /// <summary>The page <paramref name="quad"/> outlines, upright; null for a quad that is not convex.</summary>
    public static PerspectiveCorrection? Correct(RgbaImage image, Quad quad, PerspectiveOptions? options = null)
    {
        if (Plan(quad, image.Width, image.Height, options) is not { } plan) return null;
        return new PerspectiveCorrection(Warp(image, plan, options), plan);
    }

    /// <summary>
    /// Adds the Catmull-Rom sample (4 × 4 taps, a = −0.5) of the photo at output point (px, py)
    /// (continuous) to acc: pixel centers at i + 0.5, outside the photo the fill color. Near 1:1 a
    /// bilinear tap halfway between pixels averages them, which greys out one-pixel strokes of fine print.
    /// </summary>
    private static void Accumulate(RgbaImage image, Homography m, double px, double py, double[] acc, PerspectiveOptions o)
    {
        double w = m.M20 * px + m.M21 * py + m.M22;
        double sx = (m.M00 * px + m.M01 * py + m.M02) / w - 0.5;
        double sy = (m.M10 * px + m.M11 * py + m.M12) / w - 0.5;
        if (!double.IsFinite(sx) || !double.IsFinite(sy) || sx < -2 || sy < -2 || sx > image.Width + 1 || sy > image.Height + 1)
        {
            acc[0] += o.FillR;
            acc[1] += o.FillG;
            acc[2] += o.FillB;
            acc[3] += 255;
            return;
        }
        double fx0 = Math.Floor(sx), fy0 = Math.Floor(sy);
        int x0 = (int)fx0 - 1, y0 = (int)fy0 - 1;
        Span<double> kx = stackalloc double[4];
        Span<double> ky = stackalloc double[4];
        CatmullRom(sx - fx0, kx);
        CatmullRom(sy - fy0, ky);
        var pixels = image.Pixels;
        int iw = image.Width, ih = image.Height;
        bool inside = x0 >= 0 && y0 >= 0 && x0 + 3 < iw && y0 + 3 < ih;
        for (int j = 0; j < 4; j++)
        {
            int cy = y0 + j;
            for (int i = 0; i < 4; i++)
            {
                int cx = x0 + i;
                double weight = kx[i] * ky[j];
                if (inside || (cx >= 0 && cx < iw && cy >= 0 && cy < ih))
                {
                    int si = (cy * iw + cx) * 4;
                    acc[0] += weight * pixels[si];
                    acc[1] += weight * pixels[si + 1];
                    acc[2] += weight * pixels[si + 2];
                    acc[3] += weight * pixels[si + 3];
                }
                else
                {
                    acc[0] += weight * o.FillR;
                    acc[1] += weight * o.FillG;
                    acc[2] += weight * o.FillB;
                    acc[3] += weight * 255;
                }
            }
        }
    }

    /// <summary>
    /// The Catmull-Rom weights of the taps at −1, 0, 1 and 2 from the pixel <paramref name="t"/>
    /// (0 to 1) before the point; at t = 0 they are exactly 0, 1, 0, 0.
    /// </summary>
    private static void CatmullRom(double t, Span<double> k)
    {
        k[0] = ((-0.5 * t + 1) * t - 0.5) * t;
        k[1] = (1.5 * t - 2.5) * t * t + 1;
        k[2] = ((-1.5 * t + 2) * t + 0.5) * t;
        k[3] = (0.5 * t - 0.5) * t * t;
    }

    /// <summary>An output of <paramref name="width"/> × <paramref name="height"/> can be made: both sides 1 to <see cref="MaxOutputSide"/>.</summary>
    private static bool FitsOutput(int width, int height) =>
        width >= 1 && height >= 1 && width <= MaxOutputSide && height <= MaxOutputSide;

    /// <summary>Rounded to the nearest byte, halves to even (as <see cref="RgbaImage"/>'s sampler), clamped.</summary>
    private static byte RoundByte(double value) => (byte)Math.Clamp(Math.Round(value, MidpointRounding.ToEven), 0, 255);

    /// <summary>Zhang and He's n2 and n3: the directions of the rectangle's top and left edges in camera space.</summary>
    private readonly record struct PlaneRays(double N2X, double N2Y, double N2Z, double N3X, double N3Y, double N3Z);

    /// <summary>
    /// The edge directions (<see cref="PlaneRays"/>) of the rectangle seen as <paramref name="quad"/>,
    /// up to the focal length, for a camera centered on the photo; null when the quad gives none.
    /// </summary>
    private static PlaneRays? Rays(Quad quad, double imageWidth, double imageHeight)
    {
        double cx = imageWidth / 2, cy = imageHeight / 2;
        // m1 top-left, m2 top-right, m3 bottom-left, m4 bottom-right, centered, homogeneous.
        double m1x = quad.TopLeft.X - cx, m1y = quad.TopLeft.Y - cy;
        double m2x = quad.TopRight.X - cx, m2y = quad.TopRight.Y - cy;
        double m3x = quad.BottomLeft.X - cx, m3y = quad.BottomLeft.Y - cy;
        double m4x = quad.BottomRight.X - cx, m4y = quad.BottomRight.Y - cy;
        // (m1 × m4): the cross product of (m1x, m1y, 1) and (m4x, m4y, 1).
        var c14 = Cross(m1x, m1y, 1, m4x, m4y, 1);
        var c24 = Cross(m2x, m2y, 1, m4x, m4y, 1);
        var c34 = Cross(m3x, m3y, 1, m4x, m4y, 1);
        double k2den = Dot(c24, m3x, m3y, 1), k3den = Dot(c34, m2x, m2y, 1);
        if (k2den == 0 || k3den == 0) return null;
        double k2 = Dot(c14, m3x, m3y, 1) / k2den;
        double k3 = Dot(c14, m2x, m2y, 1) / k3den;
        return new PlaneRays(k2 * m2x - m1x, k2 * m2y - m1y, k2 - 1, k3 * m3x - m1x, k3 * m3y - m1y, k3 - 1);
    }

    /// <summary>The mean of the top and bottom edges over the mean of the left and right edges (1 for a quad without height).</summary>
    private static double EdgeAspect(Quad quad)
    {
        double top = quad.EdgeLength(0), right = quad.EdgeLength(1), bottom = quad.EdgeLength(2), left = quad.EdgeLength(3);
        double sides = (left + right) / 2;
        return sides > 0 ? (top + bottom) / 2 / sides : 1;
    }

    private static (double X, double Y, double Z) Cross(double ax, double ay, double az, double bx, double by, double bz) =>
        (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx);

    private static double Dot((double X, double Y, double Z) a, double bx, double by, double bz) =>
        a.X * bx + a.Y * by + a.Z * bz;
}
