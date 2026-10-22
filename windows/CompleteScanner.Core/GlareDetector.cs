namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/GlareDetector.swift: the same cells, rules and numbers.

/// <summary>
/// How much of a card or a glossy print a camera saw blown out by a reflection
/// (<see cref="GlareDetector.Measure"/>): the share of the measured cells whose every channel is
/// clipped, and the share the largest patch of them, joined side by side, covers.
/// </summary>
public readonly record struct GlareReading(double ClippedShare, double LargestBlobShare)
{
    /// <summary>A patch of glare large enough to hide what is printed under it (<see cref="GlareDetector.MinBlobShare"/>).</summary>
    public bool HasGlare => LargestBlobShare >= GlareDetector.MinBlobShare;

    /// <summary>Nothing measured, or no clipped cell.</summary>
    public static GlareReading None => new(0, 0);
}

/// <summary>
/// Finds glare on a card or a glossy print in a camera photo: a light reflected off a laminate,
/// a hologram or a print's gloss saturates the camera, so a patch of the object turns white in
/// every channel. The area measured is the object's outline (a <see cref="Quad"/>, or the whole
/// picture), less a band along its edges (<see cref="InsetShare"/> of its shorter side), where
/// the table and the edge's own highlight would count. It is cut into cells of k × k pixels, k the
/// whole number that brings the area's longer side to at most <see cref="AnalysisLongSide"/>
/// cells; a cell counts when its center lies in that inner outline, and is clipped when the mean
/// of each of its channels (integer sums, rounded half up) is at least <see cref="ClipLevel"/>.
/// Clipped cells side by side (four neighbours) are one patch; the reading is the share of the
/// counted cells clipped and the share the largest patch covers, and there is glare when that is
/// at least <see cref="MinBlobShare"/>: white specks in the print (a highlight in a portrait, the
/// dots of a pattern) stay below it. A light card whose white is not blown out (below the clip
/// level) has none. Measured on the photo as taken, before any clean-up stretches its whites.
/// </summary>
public static class GlareDetector
{
    /// <summary>A cell is clipped when the mean of each of its channels is at least this (0 to 255).</summary>
    public const int ClipLevel = 250;
    /// <summary>Glare: the largest clipped patch covers at least this share of the measured cells.</summary>
    public const double MinBlobShare = 0.01;
    /// <summary>The band along the outline's edges left out, as a share of its shorter side.</summary>
    public const double InsetShare = 0.04;
    /// <summary>The area is cut into at most this many cells along its longer side.</summary>
    public const int AnalysisLongSide = 400;

    /// <summary>The camera's one line when a card was taken with glare on it.</summary>
    public const string Hint = "Tilt to avoid glare";

    /// <summary>The glare on <paramref name="image"/> inside <paramref name="region"/> (its pixels; null: the whole picture).</summary>
    public static GlareReading Measure(RgbaImage image, Quad? region = null)
    {
        int width = image.Width, height = image.Height;
        if (width <= 0 || height <= 0) return GlareReading.None;
        var outline = region ?? new Quad(new PointD(0, 0), new PointD(width, 0), new PointD(width, height), new PointD(0, height));
        if (!outline.IsConvex) return GlareReading.None;
        var corners = outline.Corners;
        double minX = corners[0].X, maxX = corners[0].X, minY = corners[0].Y, maxY = corners[0].Y;
        for (int i = 1; i < 4; i++)
        {
            minX = Math.Min(minX, corners[i].X);
            maxX = Math.Max(maxX, corners[i].X);
            minY = Math.Min(minY, corners[i].Y);
            maxY = Math.Max(maxY, corners[i].Y);
        }
        if (!(double.IsFinite(minX) && double.IsFinite(maxX) && double.IsFinite(minY) && double.IsFinite(maxY)))
            return GlareReading.None;
        int x0 = Math.Max(0, (int)Math.Floor(minX));
        int y0 = Math.Max(0, (int)Math.Floor(minY));
        int x1 = Math.Min(width, (int)Math.Ceiling(maxX));
        int y1 = Math.Min(height, (int)Math.Ceiling(maxY));
        if (x1 <= x0 || y1 <= y0) return GlareReading.None;
        int areaWidth = x1 - x0, areaHeight = y1 - y0;
        int longSide = Math.Max(areaWidth, areaHeight);
        int k = Math.Max(1, (longSide + AnalysisLongSide - 1) / AnalysisLongSide);
        int columns = (areaWidth + k - 1) / k;
        int rows = (areaHeight + k - 1) / k;
        double across = (outline.EdgeLength(0) + outline.EdgeLength(2)) / 2;
        double down = (outline.EdgeLength(1) + outline.EdgeLength(3)) / 2;
        double inset = InsetShare * Math.Min(across, down);

        // 0: not measured, 1: measured, 2: measured and clipped.
        var cells = new byte[columns * rows];
        int counted = 0, clipped = 0;
        var pixels = image.Pixels;
        for (int row = 0; row < rows; row++)
        {
            int cy0 = y0 + row * k;
            int cy1 = Math.Min(cy0 + k, y1);
            for (int column = 0; column < columns; column++)
            {
                int cx0 = x0 + column * k;
                int cx1 = Math.Min(cx0 + k, x1);
                var center = new PointD((cx0 + cx1) / 2.0, (cy0 + cy1) / 2.0);
                if (!outline.Contains(center, -inset)) continue;
                long sumR = 0, sumG = 0, sumB = 0;
                for (int y = cy0; y < cy1; y++)
                {
                    int p = (y * width + cx0) * 4;
                    for (int x = cx0; x < cx1; x++)
                    {
                        sumR += pixels[p];
                        sumG += pixels[p + 1];
                        sumB += pixels[p + 2];
                        p += 4;
                    }
                }
                long n = (long)(cx1 - cx0) * (cy1 - cy0);
                long meanR = (sumR + n / 2) / n, meanG = (sumG + n / 2) / n, meanB = (sumB + n / 2) / n;
                counted++;
                if (meanR >= ClipLevel && meanG >= ClipLevel && meanB >= ClipLevel)
                {
                    cells[row * columns + column] = 2;
                    clipped++;
                }
                else
                {
                    cells[row * columns + column] = 1;
                }
            }
        }
        if (counted == 0) return GlareReading.None;
        int largest = LargestPatch(cells, columns, rows);
        return new GlareReading((double)clipped / counted, (double)largest / counted);
    }

    /// <summary>Whether <paramref name="image"/> shows glare inside <paramref name="region"/> (<see cref="GlareReading.HasGlare"/>).</summary>
    public static bool HasGlare(RgbaImage image, Quad? region = null) => Measure(image, region).HasGlare;

    /// <summary>The cells of the largest patch of clipped cells (value 2) joined side by side, found in row-major order.</summary>
    private static int LargestPatch(byte[] cells, int columns, int rows)
    {
        var seen = new bool[cells.Length];
        var stack = new List<int>();
        int largest = 0;
        for (int start = 0; start < cells.Length; start++)
        {
            if (cells[start] != 2 || seen[start]) continue;
            seen[start] = true;
            stack.Add(start);
            int size = 0;
            while (stack.Count > 0)
            {
                int index = stack[^1];
                stack.RemoveAt(stack.Count - 1);
                size++;
                int column = index % columns, row = index / columns;
                if (column > 0) Visit(index - 1);
                if (column < columns - 1) Visit(index + 1);
                if (row > 0) Visit(index - columns);
                if (row < rows - 1) Visit(index + columns);
            }
            largest = Math.Max(largest, size);
        }
        return largest;

        void Visit(int neighbour)
        {
            if (cells[neighbour] != 2 || seen[neighbour]) return;
            seen[neighbour] = true;
            stack.Add(neighbour);
        }
    }
}
