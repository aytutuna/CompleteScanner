namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/PerspectiveWarp.swift: integer box averages and the
// corrector's sampler (+ − × ÷ on doubles in the same order, halves rounded to even), so the same
// photo, quad and size give the same bytes on both platforms.

/// <summary>
/// The reference warp of camera pages: the page <see cref="Quad"/> outlines in a photo, made into an
/// upright <c>width × height</c> rectangle. When the page is made more than
/// <see cref="PrefilterAbove"/> times smaller than the photo shows it, the photo is first averaged
/// down in k × k blocks (k the whole part of that factor, <see cref="PrefilterFactor"/>), so no
/// detail is skipped over; then <see cref="PerspectiveCorrector.Warp"/> samples it bicubically
/// (Catmull-Rom), 2 × 2 per pixel when the page is still made smaller by more than
/// <see cref="PerspectiveCorrector.SupersampleAbove"/>. Faster platform paths (Core Image on the
/// iPhone) are checked against it.
/// </summary>
public static class PerspectiveWarp
{
    /// <summary>The photo is averaged down first when the page is made smaller than this.</summary>
    public const double PrefilterAbove = 2.0;

    /// <summary>
    /// How many photo pixels across each block averaged before sampling holds: the whole part of how
    /// many times smaller the page is made (the longer of each pair of opposite edges against
    /// <paramref name="width"/> and <paramref name="height"/>) when that is more than
    /// <see cref="PrefilterAbove"/>; 1 otherwise, and for a size without pixels.
    /// </summary>
    public static int PrefilterFactor(Quad quad, int width, int height)
    {
        if (width < 1 || height < 1) return 1;
        double w0 = Math.Max(quad.EdgeLength(0), quad.EdgeLength(2));
        double h0 = Math.Max(quad.EdgeLength(1), quad.EdgeLength(3));
        double shrink = Math.Max(w0 / width, h0 / height);
        if (!(shrink > PrefilterAbove) || !double.IsFinite(shrink)) return 1;
        return (int)Math.Min(Math.Floor(shrink), PerspectiveCorrector.MaxOutputSide);
    }

    /// <summary>
    /// <paramref name="image"/> averaged in <paramref name="factor"/> × <paramref name="factor"/>
    /// blocks from its top-left corner: ⌈W / k⌉ × ⌈H / k⌉ pixels, each the mean of the pixels of its
    /// block inside the image (the last row and column may hold fewer), rounded half up in integers.
    /// A factor of 1 or less gives the image itself.
    /// </summary>
    public static RgbaImage BoxReduced(RgbaImage image, int factor)
    {
        if (factor <= 1) return image;
        int w = image.Width, h = image.Height;
        int rw = (w + factor - 1) / factor, rh = (h + factor - 1) / factor;
        var output = new byte[rw * rh * 4];
        var pixels = image.Pixels;
        for (int oy = 0; oy < rh; oy++)
        {
            int y0 = oy * factor, y1 = Math.Min(h, y0 + factor);
            for (int ox = 0; ox < rw; ox++)
            {
                int x0 = ox * factor, x1 = Math.Min(w, x0 + factor);
                long r = 0, g = 0, b = 0, a = 0;
                for (int y = y0; y < y1; y++)
                {
                    int si = (y * w + x0) * 4;
                    for (int x = x0; x < x1; x++)
                    {
                        r += pixels[si];
                        g += pixels[si + 1];
                        b += pixels[si + 2];
                        a += pixels[si + 3];
                        si += 4;
                    }
                }
                long count = (long)(y1 - y0) * (x1 - x0);
                long half = count / 2;
                int di = (oy * rw + ox) * 4;
                output[di] = (byte)((r + half) / count);
                output[di + 1] = (byte)((g + half) / count);
                output[di + 2] = (byte)((b + half) / count);
                output[di + 3] = (byte)((a + half) / count);
            }
        }
        return new RgbaImage(rw, rh, output);
    }

    /// <summary>
    /// The page <paramref name="quad"/> outlines in <paramref name="image"/> (its corners in the
    /// image's continuous pixels, clockwise from the top-left), upright at
    /// <paramref name="width"/> × <paramref name="height"/>: averaged down first by
    /// <see cref="PrefilterFactor"/> (the quad scaled by 1 / k with it), then sampled as
    /// <see cref="PerspectiveCorrector.Warp"/> does with <paramref name="options"/>' supersampling and
    /// fill color (its size and paper options do not apply). Null for a quad that is not convex or a
    /// size outside 1 to <see cref="PerspectiveCorrector.MaxOutputSide"/>.
    /// </summary>
    public static RgbaImage? Warp(RgbaImage image, Quad quad, int width, int height, PerspectiveOptions? options = null)
    {
        var o = options ?? PerspectiveOptions.Default;
        if (!quad.IsConvex || width < 1 || height < 1
            || width > PerspectiveCorrector.MaxOutputSide || height > PerspectiveCorrector.MaxOutputSide)
        {
            return null;
        }
        int factor = PrefilterFactor(quad, width, height);
        var source = image;
        var sourceQuad = quad;
        if (factor > 1)
        {
            source = BoxReduced(image, factor);
            double scale = 1.0 / factor;
            sourceQuad = quad.Scaled(scale, scale);
        }
        var planOptions = o with { OutputWidth = width, OutputHeight = height, SnapToPaper = false, MaxLongSide = 0 };
        if (PerspectiveCorrector.Plan(sourceQuad, source.Width, source.Height, planOptions) is not { } plan) return null;
        return PerspectiveCorrector.Warp(source, plan, planOptions);
    }
}
