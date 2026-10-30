namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/FrameQuality.swift: the same integer sums, so the same
// frame gives the same readings on both platforms.

/// <summary>A live frame's readings (<see cref="FrameQuality.Measure(GrayImage, Quad?)"/>).</summary>
/// <param name="Sharpness">The variance of the luma's 4-neighbour Laplacian over the area: high for crisp edges and print, low when blurred.</param>
/// <param name="Brightness">The mean luma over the area, 0...255.</param>
public readonly record struct FrameQualityReading(double Sharpness, double Brightness);

/// <summary>
/// How sharp and how bright a live camera frame is, for the automatic shutter
/// (<see cref="CaptureStability.Judge"/>): measured on the small frame the page search reads, over
/// the page's bounding box widened by <see cref="Margin"/> pixels and kept within the frame (so the
/// page's own edges are in it, and a blank page still has something to be sharp), or the whole frame
/// when no page is given. Sharpness is the variance of 4·p − (up + down + left + right) over the
/// area's pixels that have all four neighbours in the frame; brightness the mean luma
/// (<see cref="ColorAnalysis.GrayPixels(RgbaImage)"/>) over the area. Both come from integer sums,
/// divided once.
/// </summary>
public static class FrameQuality
{
    /// <summary>The page's bounding box is widened by this many pixels each way.</summary>
    public const int Margin = 2;

    /// <summary>The readings of <paramref name="frame"/> over <paramref name="region"/> (see the type).</summary>
    public static FrameQualityReading Measure(RgbaImage frame, Quad? region = null) =>
        Measure(GrayImage.Luma(frame), region);

    /// <summary>The readings of <paramref name="gray"/> over <paramref name="region"/> (see the type).</summary>
    public static FrameQualityReading Measure(GrayImage gray, Quad? region = null)
    {
        int w = gray.Width, h = gray.Height;
        var (x0, y0, x1, y1) = Area(region, w, h);
        var pixels = gray.Pixels;
        long sum = 0, count = 0;
        for (int y = y0; y < y1; y++)
        {
            int row = y * w;
            for (int x = x0; x < x1; x++) sum += pixels[row + x];
            count += x1 - x0;
        }
        double brightness = count > 0 ? (double)sum / count : 0;

        long lapSum = 0, lapSquares = 0, n = 0;
        int ly0 = Math.Max(y0, 1), ly1 = Math.Min(y1, h - 1);
        int lx0 = Math.Max(x0, 1), lx1 = Math.Min(x1, w - 1);
        for (int y = ly0; y < ly1; y++)
        {
            int row = y * w;
            for (int x = lx0; x < lx1; x++)
            {
                int i = row + x;
                long l = 4 * pixels[i] - pixels[i - w] - pixels[i + w] - pixels[i - 1] - pixels[i + 1];
                lapSum += l;
                lapSquares += l * l;
                n++;
            }
        }
        double sharpness = 0;
        if (n > 0)
        {
            double mean = (double)lapSum / n;
            sharpness = Math.Max(0, (double)lapSquares / n - mean * mean);
        }
        return new FrameQualityReading(sharpness, brightness);
    }

    /// <summary>
    /// The area measured, as pixel bounds [x0, x1) × [y0, y1): the quad's bounding box widened by
    /// <see cref="Margin"/> (its sides rounded outwards) and kept within the frame; the whole frame
    /// without a quad, or with one that leaves nothing of the frame.
    /// </summary>
    public static (int X0, int Y0, int X1, int Y1) Area(Quad? region, int width, int height)
    {
        if (region is not { } quad) return (0, 0, width, height);
        double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
        for (int i = 0; i < 4; i++)
        {
            var p = quad[i];
            if (!double.IsFinite(p.X) || !double.IsFinite(p.Y)) return (0, 0, width, height);
            minX = Math.Min(minX, p.X);
            minY = Math.Min(minY, p.Y);
            maxX = Math.Max(maxX, p.X);
            maxY = Math.Max(maxY, p.Y);
        }
        int x0 = (int)Math.Clamp(Math.Floor(minX) - Margin, 0, width);
        int y0 = (int)Math.Clamp(Math.Floor(minY) - Margin, 0, height);
        int x1 = (int)Math.Clamp(Math.Ceiling(maxX) + Margin, 0, width);
        int y1 = (int)Math.Clamp(Math.Ceiling(maxY) + Margin, 0, height);
        if (x1 <= x0 || y1 <= y0) return (0, 0, width, height);
        return (x0, y0, x1, y1);
    }
}
