namespace LazyScan.Core;

/// <summary>A 2D point in double precision. Replaces CGPoint from the Swift core.</summary>
public readonly record struct PointD(double X, double Y)
{
    public static readonly PointD Zero = new(0, 0);
    public double DistanceTo(PointD other) =>
        Math.Sqrt((X - other.X) * (X - other.X) + (Y - other.Y) * (Y - other.Y));
}

/// <summary>A 2D size in double precision. Replaces CGSize.</summary>
public readonly record struct SizeD(double Width, double Height)
{
    public static readonly SizeD Zero = new(0, 0);
}

/// <summary>An axis-aligned rectangle in double precision. Replaces CGRect.</summary>
public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double MinX => Width >= 0 ? X : X + Width;
    public double MinY => Height >= 0 ? Y : Y + Height;
    public double MaxX => Width >= 0 ? X + Width : X;
    public double MaxY => Height >= 0 ? Y + Height : Y;

    /// <summary>Equivalent of CGRect.standardized: non-negative width/height.</summary>
    public RectD Standardized => new(MinX, MinY, Math.Abs(Width), Math.Abs(Height));

    public bool IsEmpty => Width <= 0 || Height <= 0;

    public RectD Intersection(RectD other)
    {
        var a = Standardized;
        var b = other.Standardized;
        double x1 = Math.Max(a.MinX, b.MinX), y1 = Math.Max(a.MinY, b.MinY);
        double x2 = Math.Min(a.MaxX, b.MaxX), y2 = Math.Min(a.MaxY, b.MaxY);
        if (x2 <= x1 || y2 <= y1) return new RectD(0, 0, 0, 0);
        return new RectD(x1, y1, x2 - x1, y2 - y1);
    }

    /// <summary>Equivalent of CGRect.integral: smallest integer-aligned rect containing this one.</summary>
    public RectD Integral
    {
        get
        {
            var s = Standardized;
            double x1 = Math.Floor(s.MinX), y1 = Math.Floor(s.MinY);
            double x2 = Math.Ceiling(s.MaxX), y2 = Math.Ceiling(s.MaxY);
            return new RectD(x1, y1, x2 - x1, y2 - y1);
        }
    }

    /// <summary>
    /// The four numbers only. The text records print by default would also hold <see cref="Standardized"/> and
    /// <see cref="Integral"/>, rectangles themselves, without end; records holding a rectangle
    /// print it through this.
    /// </summary>
    public override string ToString() =>
        string.Create(System.Globalization.CultureInfo.InvariantCulture, $"RectD {{ X = {X}, Y = {Y}, Width = {Width}, Height = {Height} }}");
}

/// <summary>
/// A rotated rectangle in image pixel coordinates (origin top-left, x right, y down).
///
/// <c>AngleDegrees</c> follows the <see cref="DetectedPhotoRegion"/> convention: it is applied with
/// the standard rotation matrix
///   ix = center.X + x*cos(a) - y*sin(a)
///   iy = center.Y + x*sin(a) + y*cos(a)
/// Because y grows DOWNWARD in image coordinates, a positive angle appears as a CLOCKWISE
/// rotation on screen. <see cref="Geometry.MinAreaRectOf"/> normalizes the angle to (-45, 45],
/// swapping width/height as needed.
/// </summary>
public struct MinAreaRect
{
    public PointD Center;
    public SizeD Size;
    public double AngleDegrees;

    public MinAreaRect(PointD center, SizeD size, double angleDegrees)
    {
        Center = center;
        Size = size;
        AngleDegrees = angleDegrees;
    }
}

/// <summary>
/// Pure geometry used by the photo detector: convex hull and minimum-area enclosing rectangle.
/// Behavior-for-behavior port of Sources/LazyScanKit/Pipeline/Geometry.swift.
/// </summary>
public static class Geometry
{
    /// <summary>
    /// Andrew monotone chain convex hull.
    ///
    /// Returns the hull vertices in counterclockwise order in the mathematical (y-up) sense —
    /// which appears clockwise on screen for top-left-origin/y-down image coordinates.
    /// Degenerate inputs: fewer than 3 distinct points return the distinct points themselves;
    /// collinear input returns the two extreme endpoints.
    /// </summary>
    public static List<PointD> ConvexHull(IReadOnlyList<PointD> points)
    {
        var pts = points.OrderBy(p => p.X).ThenBy(p => p.Y).ToList();
        var unique = new List<PointD>(pts.Count);
        foreach (var p in pts)
        {
            if (unique.Count == 0 || unique[^1] != p) unique.Add(p);
        }
        pts = unique;
        if (pts.Count < 3) return pts;

        var lower = new List<PointD>();
        foreach (var p in pts)
        {
            while (lower.Count >= 2 && CrossZ(lower[^2], lower[^1], p) <= 0)
                lower.RemoveAt(lower.Count - 1);
            lower.Add(p);
        }
        var upper = new List<PointD>();
        for (int i = pts.Count - 1; i >= 0; i--)
        {
            var p = pts[i];
            while (upper.Count >= 2 && CrossZ(upper[^2], upper[^1], p) <= 0)
                upper.RemoveAt(upper.Count - 1);
            upper.Add(p);
        }
        lower.RemoveAt(lower.Count - 1);
        upper.RemoveAt(upper.Count - 1);
        lower.AddRange(upper);
        return lower;
    }

    /// <summary>
    /// Minimum-area enclosing rectangle of a convex hull (rotating calipers: the optimal
    /// rectangle has one side collinear with a hull edge, so every hull edge direction is
    /// tried and all points are projected onto it).
    ///
    /// The returned angle is normalized to (-45, 45] per the <see cref="DetectedPhotoRegion"/>
    /// convention, swapping width and height for each 90° step removed. Degenerate inputs
    /// (empty, single point, all points coincident) return a zero-size rectangle; collinear
    /// points return a rectangle with one zero dimension.
    /// </summary>
    public static MinAreaRect MinAreaRectOf(IReadOnlyList<PointD> hull)
    {
        var pts = hull;
        if (pts.Count == 0) return new MinAreaRect(PointD.Zero, SizeD.Zero, 0);

        MinAreaRect? best = null;
        double bestArea = double.MaxValue;
        int n = pts.Count;
        for (int i = 0; i < n; i++)
        {
            var p0 = pts[i];
            var p1 = pts[(i + 1) % n];
            double ex = p1.X - p0.X, ey = p1.Y - p0.Y;
            double len = Math.Sqrt(ex * ex + ey * ey);
            if (len <= 1e-9) continue;
            // Unit edge direction (the candidate local x axis) and its normal (local y axis).
            double dx = ex / len, dy = ey / len;
            double nx = -dy, ny = dx;

            double minU = double.MaxValue, maxU = double.MinValue;
            double minV = double.MaxValue, maxV = double.MinValue;
            foreach (var p in pts)
            {
                double u = p.X * dx + p.Y * dy;
                double v = p.X * nx + p.Y * ny;
                if (u < minU) minU = u;
                if (u > maxU) maxU = u;
                if (v < minV) minV = v;
                if (v > maxV) maxV = v;
            }
            double w = maxU - minU, h = maxV - minV;
            double area = w * h;
            if (area < bestArea)
            {
                bestArea = area;
                double cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;
                best = new MinAreaRect(
                    new PointD(cu * dx + cv * nx, cu * dy + cv * ny),
                    new SizeD(w, h),
                    Math.Atan2(dy, dx) * 180 / Math.PI);
            }
        }

        if (best is not { } rect)
        {
            // Every "edge" had zero length: all points coincide.
            return new MinAreaRect(pts[0], SizeD.Zero, 0);
        }
        NormalizeAngle(ref rect);
        return rect;
    }

    /// <summary>z-component of (a - o) × (b - o). Positive = mathematical counterclockwise turn.</summary>
    private static double CrossZ(PointD o, PointD a, PointD b) =>
        (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);

    /// <summary>
    /// Bring the angle into (-45, 45]. A rectangle is unchanged by a 180° rotation, and a
    /// ±90° rotation maps to the same rectangle with width and height exchanged.
    /// </summary>
    private static void NormalizeAngle(ref MinAreaRect r)
    {
        // C# % on doubles truncates toward zero — same as Swift's truncatingRemainder.
        double a = r.AngleDegrees % 180;
        if (a > 90) a -= 180;
        else if (a <= -90) a += 180;
        if (a > 45)
        {
            a -= 90;
            r.Size = new SizeD(r.Size.Height, r.Size.Width);
        }
        else if (a <= -45)
        {
            a += 90;
            r.Size = new SizeD(r.Size.Height, r.Size.Width);
        }
        r.AngleDegrees = a;
    }
}
