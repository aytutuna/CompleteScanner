namespace LazyScan.Core;

public sealed class PhotoDetectorOptions
{
    public double MinPhotoSideInches { get; set; } = 1.0;
    public int MaxPhotoCount { get; set; } = 20;
    /// <summary>Pixels (at full scan resolution) shaved off each edge of the detected rect before extraction.</summary>
    public int EdgeInsetPixels { get; set; } = 0;
}

/// <summary>
/// Finds distinct photos lying on a flatbed scan. Step-for-step port of
/// Sources/LazyScanKit/Pipeline/PhotoDetector.swift; the numbered stages below
/// match the Swift source so the two implementations can be diffed side by side.
/// </summary>
public static class PhotoDetector
{
    /// <summary>
    /// Find distinct photos lying on a flatbed scan. Regions are in full-resolution pixel
    /// coordinates of <paramref name="image"/>, sorted top-to-bottom then left-to-right.
    /// </summary>
    public static List<DetectedPhotoRegion> DetectRegions(RgbaImage image, int dpi,
                                                          PhotoDetectorOptions? options = null)
    {
        options ??= new PhotoDetectorOptions();
        int fullW = image.Width, fullH = image.Height;
        if (fullW <= 0 || fullH <= 0 || options.MaxPhotoCount <= 0) return [];

        // 1. Downsample to at most 1000 px on the long side; only ever iterate these pixels.
        double scale = Math.Min(1.0, 1000.0 / Math.Max(fullW, fullH));
        int dw = Math.Max(1, (int)Math.Round(fullW * scale, MidpointRounding.AwayFromZero));
        int dh = Math.Max(1, (int)Math.Round(fullH * scale, MidpointRounding.AwayFromZero));
        // Exact per-axis scales after rounding, used when mapping back to full resolution.
        double sx = (double)dw / fullW;
        double sy = (double)dh / fullH;
        var rgba = image.Resized(dw, dh).Pixels;

        // 2. Per-pixel luminance and saturation in 0...1.
        int count = dw * dh;
        var lum = new float[count];
        var sat = new float[count];
        for (int i = 0; i < count; i++)
        {
            float r = rgba[i * 4] / 255f;
            float g = rgba[i * 4 + 1] / 255f;
            float b = rgba[i * 4 + 2] / 255f;
            lum[i] = 0.299f * r + 0.587f * g + 0.114f * b;
            sat[i] = Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b));
        }

        // 3. Background estimate: median luminance of the outer 2% border ring.
        int ring = Math.Max(1, (int)Math.Round(Math.Min(dw, dh) * 0.02, MidpointRounding.AwayFromZero));
        var border = new List<float>(4 * ring * (dw + dh));
        for (int y = 0; y < dh; y++)
        {
            bool edgeRow = y < ring || y >= dh - ring;
            for (int x = 0; x < dw; x++)
            {
                if (edgeRow || x < ring || x >= dw - ring)
                    border.Add(lum[y * dw + x]);
            }
        }
        border.Sort();
        float background = border.Count == 0 ? 1f : border[border.Count / 2];

        // 4. Foreground mask.
        var mask = new byte[count];
        for (int i = 0; i < count; i++)
        {
            if (Math.Abs(lum[i] - background) > 0.09f || sat[i] > 0.13f)
                mask[i] = 1;
        }

        // 5. Close (seal photo interiors that match the background), then a light open (drop speckle).
        mask = MaskOps.Erode(MaskOps.Dilate(mask, dw, dh, 2), dw, dh, 2);
        mask = MaskOps.Dilate(MaskOps.Erode(mask, dw, dh, 1), dw, dh, 1);

        // 6. Connected components.
        var components = MaskOps.ConnectedComponents(mask, dw, dh);

        // 7 + 8. Filter components, then fit min-area rectangles.
        double minSidePx = options.MinPhotoSideInches * Math.Max(dpi, 1) * scale;
        double minArea = minSidePx * minSidePx * 0.5;
        var fitted = new List<MinAreaRect>();
        foreach (var component in components)
        {
            if (component.Area < minArea) continue;
            // Per-row extremes as pixel-corner points: enough for an exact convex hull,
            // and a W-pixel-wide run measures a width of exactly W.
            var pts = new List<PointD>(component.Rows.Count * 4);
            foreach (var (y, span) in component.Rows)
            {
                pts.Add(new PointD(span.MinX, y));
                pts.Add(new PointD(span.MinX, y + 1));
                pts.Add(new PointD(span.MaxX + 1, y));
                pts.Add(new PointD(span.MaxX + 1, y + 1));
            }
            var rect = Geometry.MinAreaRectOf(Geometry.ConvexHull(pts));
            double rectArea = rect.Size.Width * rect.Size.Height;
            if (rectArea <= 0 || component.Area / rectArea < 0.45) continue;
            fitted.Add(rect);
        }

        // 9. Map back to full resolution and cap at the largest MaxPhotoCount.
        double sizeScale = (sx + sy) / 2;
        var regions = fitted.Select(r => new DetectedPhotoRegion(
            new PointD(r.Center.X / sx, r.Center.Y / sy),
            new SizeD(r.Size.Width / sizeScale, r.Size.Height / sizeScale),
            r.AngleDegrees)).ToList();
        regions.Sort((a, b) =>
            (b.Size.Width * b.Size.Height).CompareTo(a.Size.Width * a.Size.Height));
        if (regions.Count > options.MaxPhotoCount)
            regions.RemoveRange(options.MaxPhotoCount, regions.Count - options.MaxPhotoCount);

        // 10. Merge near-duplicates.
        regions = MergeOverlapping(regions);

        // 11. Snap each region to the true photo edges at FULL resolution. The low-res
        // mask bleeds a few pixels at the borders — visible as background slivers around
        // extracted photos — and its loose threshold can shave off a photo's white print
        // border; both are corrected here.
        regions = regions.Select(r => RefineRegion(r, image, background) ?? r).ToList();

        // 12. Apply the edge inset and sort row-major.
        if (options.EdgeInsetPixels > 0)
        {
            double shrink = options.EdgeInsetPixels * 2.0;
            foreach (var region in regions)
            {
                region.Size = new SizeD(Math.Max(1, region.Size.Width - shrink),
                                        Math.Max(1, region.Size.Height - shrink));
            }
        }
        return SortRowMajor(regions);
    }

    /// <summary>Crop (and if <paramref name="deskew"/>, rotate to upright) one region out of the source scan.</summary>
    public static RgbaImage? ExtractPhoto(RgbaImage image, DetectedPhotoRegion region, bool deskew)
    {
        if (image.Width <= 0 || image.Height <= 0) return null;

        if (!deskew)
        {
            return image.Cropped(region.BoundingBox());
        }

        // The region lives in top-left-origin/y-down image coordinates — the same space
        // RgbaImage uses — so unlike the Swift/CG version no coordinate flip is needed:
        // sampling the source through the region's own corner mapping lands the region
        // axis-aligned and centered in the output.
        return image.ExtractRotated(region.Center, region.Size, region.AngleDegrees);
    }

    // MARK: - Full-resolution edge refinement

    /// <summary>
    /// Re-fit one detected region against the full-resolution pixels.
    ///
    /// The region (plus a margin) is rendered upright, then each side is scanned from the
    /// outside for the first row/column that is not background. The background test is
    /// deliberately much tighter than the detection threshold: a photo's white print
    /// border usually differs only slightly from the bed glass, and the faint edge shadow
    /// a lying photo casts differs clearly — so borders are kept while bed background is
    /// trimmed exactly. Returns null (caller keeps the unrefined region) when the result
    /// would be degenerate.
    /// </summary>
    internal static DetectedPhotoRegion? RefineRegion(DetectedPhotoRegion region, RgbaImage image,
                                                      double backgroundLuminance)
    {
        double bg = backgroundLuminance;
        double margin = Math.Max(24.0, 0.05 * Math.Min(region.Size.Width, region.Size.Height));
        int cw = (int)Math.Round(region.Size.Width + 2 * margin, MidpointRounding.AwayFromZero);
        int ch = (int)Math.Round(region.Size.Height + 2 * margin, MidpointRounding.AwayFromZero);
        if (cw < 8 || ch < 8 || (long)cw * ch > 60_000_000) return null;
        var rgba = RasterizeRotated(image, region.Center, region.AngleDegrees, cw, ch, bg);
        if (rgba is null) return null;

        const double lumTolerance = 0.035;
        const double satTolerance = 0.06;
        bool IsBackground(int index)
        {
            double r = rgba[index * 4] / 255.0;
            double g = rgba[index * 4 + 1] / 255.0;
            double b = rgba[index * 4 + 2] / 255.0;
            double lum = 0.299 * r + 0.587 * g + 0.114 * b;
            double sat = Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b));
            return Math.Abs(lum - bg) < lumTolerance && sat < satTolerance;
        }
        // A line is still "background" while ≥92% of its pixels are (tolerates dust).
        const double backgroundShare = 0.92;
        bool RowIsBackground(int y)
        {
            int count = 0;
            for (int x = 0; x < cw; x++) if (IsBackground(y * cw + x)) count++;
            return count >= backgroundShare * cw;
        }
        bool ColumnIsBackground(int x)
        {
            int count = 0;
            for (int y = 0; y < ch; y++) if (IsBackground(y * cw + x)) count++;
            return count >= backgroundShare * ch;
        }

        // Each side starts at the ORIGINAL detected edge (index `m` from the buffer
        // border): first trim inward over background lines (removes bed slivers), then
        // grow outward across contiguous non-background lines (recovers white print
        // borders and edge shadows). Growth stops at the first background line, so a
        // neighboring photo inside the margin ring — always separated by a background
        // gap — is never absorbed.
        int m = (int)Math.Round(margin, MidpointRounding.AwayFromZero);
        int top = Math.Min(m, ch - 1);
        while (top < ch - 1 && RowIsBackground(top)) top++;
        while (top > 0 && !RowIsBackground(top - 1)) top--;
        int bottom = Math.Max(ch - 1 - m, top);
        while (bottom > top && RowIsBackground(bottom)) bottom--;
        while (bottom < ch - 1 && !RowIsBackground(bottom + 1)) bottom++;
        int left = Math.Min(m, cw - 1);
        while (left < cw - 1 && ColumnIsBackground(left)) left++;
        while (left > 0 && !ColumnIsBackground(left - 1)) left--;
        int right = Math.Max(cw - 1 - m, left);
        while (right > left && ColumnIsBackground(right)) right--;
        while (right < cw - 1 && !ColumnIsBackground(right + 1)) right++;

        double newW = right - left + 1;
        double newH = bottom - top + 1;
        // Safety: keep the original detection if refinement collapsed (glare, unusual
        // bed color) — better a slightly loose crop than a destroyed one.
        if (newW < 8 || newH < 8 || newW * newH < 0.3 * (region.Size.Width * region.Size.Height))
            return null;

        // Center shift in the upright frame, rotated back into image coordinates.
        double dx = (left + right + 1) / 2.0 - cw / 2.0;
        double dy = (top + bottom + 1) / 2.0 - ch / 2.0;
        double a = region.AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        var center = new PointD(region.Center.X + dx * c - dy * s,
                                region.Center.Y + dx * s + dy * c);
        return new DetectedPhotoRegion(center, new SizeD(newW, newH), region.AngleDegrees);
    }

    /// <summary>
    /// Render the rotated region upright into an RGBA8 buffer (rows top-to-bottom), the same
    /// transform <see cref="ExtractPhoto"/> uses; areas outside the source are filled with
    /// the bed's background gray so they read as background during refinement.
    /// </summary>
    private static byte[]? RasterizeRotated(RgbaImage image, PointD center, double angleDegrees,
                                            int width, int height, double fillGray)
    {
        byte gray = (byte)Math.Clamp(Math.Round(fillGray * 255), 0, 255);
        return image.ExtractRotated(center, new SizeD(width, height), angleDegrees,
                                    gray, gray, gray)?.Pixels;
    }

    // MARK: - Merging and ordering

    /// <summary>
    /// Merge any two regions whose rotated-rect intersection area exceeds 0.6 of the
    /// smaller rect's area, replacing them with the min-area rect of their joint hull.
    /// </summary>
    internal static List<DetectedPhotoRegion> MergeOverlapping(List<DetectedPhotoRegion> input)
    {
        var regions = new List<DetectedPhotoRegion>(input);
        bool merged = true;
        while (merged && regions.Count > 1)
        {
            merged = false;
            for (int i = 0; i < regions.Count && !merged; i++)
            {
                for (int j = i + 1; j < regions.Count && !merged; j++)
                {
                    var a = regions[i];
                    var b = regions[j];
                    double areaA = a.Size.Width * a.Size.Height;
                    double areaB = b.Size.Width * b.Size.Height;
                    double smaller = Math.Min(areaA, areaB);
                    if (smaller <= 0) continue;
                    double inter = PolygonArea(ClipPolygon(a.Corners(), b.Corners()));
                    if (inter / smaller <= 0.6) continue;
                    var joint = new List<PointD>(a.Corners());
                    joint.AddRange(b.Corners());
                    var rect = Geometry.MinAreaRectOf(Geometry.ConvexHull(joint));
                    regions[i] = new DetectedPhotoRegion(rect.Center, rect.Size, rect.AngleDegrees);
                    regions.RemoveAt(j);
                    merged = true;
                }
            }
        }
        return regions;
    }

    /// <summary>
    /// Sort top-to-bottom then left-to-right, grouping into rows with a tolerance of
    /// half the mean region height.
    /// </summary>
    internal static List<DetectedPhotoRegion> SortRowMajor(List<DetectedPhotoRegion> regions)
    {
        if (regions.Count <= 1) return regions;
        double meanHeight = regions.Sum(r => r.Size.Height) / regions.Count;
        double tolerance = Math.Max(1.0, meanHeight / 2);
        var byY = regions.OrderBy(r => r.Center.Y).ToList();
        var rows = new List<List<DetectedPhotoRegion>>();
        var currentRow = new List<DetectedPhotoRegion>();
        double rowY = 0.0;
        foreach (var region in byY)
        {
            if (currentRow.Count == 0 || region.Center.Y - rowY <= tolerance)
            {
                if (currentRow.Count == 0) rowY = region.Center.Y;
                currentRow.Add(region);
            }
            else
            {
                rows.Add(currentRow);
                currentRow = [region];
                rowY = region.Center.Y;
            }
        }
        if (currentRow.Count > 0) rows.Add(currentRow);
        return rows.SelectMany(row => row.OrderBy(r => r.Center.X)).ToList();
    }

    // MARK: - Convex polygon intersection (Sutherland–Hodgman)

    /// <summary>Unsigned area of a simple polygon (shoelace formula).</summary>
    private static double PolygonArea(IReadOnlyList<PointD> pts)
    {
        if (pts.Count < 3) return 0;
        double sum = 0;
        for (int i = 0; i < pts.Count; i++)
        {
            var a = pts[i];
            var b = pts[(i + 1) % pts.Count];
            sum += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(sum) / 2;
    }

    /// <summary>
    /// Clip a convex <paramref name="subject"/> polygon by a convex <paramref name="clip"/>
    /// polygon whose vertices are in mathematically counterclockwise order (which
    /// <see cref="DetectedPhotoRegion.Corners"/> is).
    /// </summary>
    private static List<PointD> ClipPolygon(IReadOnlyList<PointD> subject, IReadOnlyList<PointD> clip)
    {
        if (clip.Count < 3) return [];
        var output = new List<PointD>(subject);
        for (int i = 0; i < clip.Count; i++)
        {
            if (output.Count == 0) break;
            var a = clip[i];
            var b = clip[(i + 1) % clip.Count];

            bool Inside(PointD p) =>
                (b.X - a.X) * (p.Y - a.Y) - (b.Y - a.Y) * (p.X - a.X) >= 0;

            PointD Intersect(PointD p, PointD q)
            {
                double a1 = b.Y - a.Y, b1 = a.X - b.X;
                double c1 = a1 * a.X + b1 * a.Y;
                double a2 = q.Y - p.Y, b2 = p.X - q.X;
                double c2 = a2 * p.X + b2 * p.Y;
                double det = a1 * b2 - a2 * b1;
                if (Math.Abs(det) <= 1e-12) return p;
                return new PointD((c1 * b2 - c2 * b1) / det, (a1 * c2 - a2 * c1) / det);
            }

            var input = output;
            output = [];
            for (int k = 0; k < input.Count; k++)
            {
                var current = input[k];
                var previous = input[(k + input.Count - 1) % input.Count];
                if (Inside(current))
                {
                    if (!Inside(previous)) output.Add(Intersect(previous, current));
                    output.Add(current);
                }
                else if (Inside(previous))
                {
                    output.Add(Intersect(previous, current));
                }
            }
        }
        return output;
    }
}
