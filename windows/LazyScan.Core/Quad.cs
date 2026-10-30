namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/Quad.swift: the same arithmetic in the same order.

/// <summary>
/// Four corners of a page seen in a photo, in image pixels (origin top-left, x right, y down,
/// continuous: pixel (i, j) covers [i, i + 1) × [j, j + 1), its center is (i + 0.5, j + 0.5)).
/// The corners run clockwise on screen. <see cref="FromCorners"/> names them: the top edge is
/// the edge whose midpoint is highest in the image (the smaller x on a tie), and
/// <see cref="TopLeft"/> is its first corner going clockwise. The names say where the corners
/// are in the image, not which way up the page's text reads. Near the turn where two edges'
/// midpoints are equally high (a W × H sheet turned by atan(H / W)), a slight turn names the
/// corners from the next edge: to tell whether two quads are the same outline, compare them from
/// every starting corner (<see cref="CaptureStability.Movement"/>), not corner by corner.
/// </summary>
public readonly record struct Quad(PointD TopLeft, PointD TopRight, PointD BottomRight, PointD BottomLeft)
{
    /// <summary>The corners clockwise from <see cref="TopLeft"/>: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.</summary>
    public PointD this[int index] => (index & 3) switch
    {
        0 => TopLeft,
        1 => TopRight,
        2 => BottomRight,
        _ => BottomLeft,
    };

    /// <summary>The corners clockwise from <see cref="TopLeft"/>.</summary>
    public PointD[] Corners => [TopLeft, TopRight, BottomRight, BottomLeft];

    /// <summary>The shoelace sum: positive when the corners run clockwise on screen (y down).</summary>
    public double SignedArea
    {
        get
        {
            double sum = 0;
            for (int i = 0; i < 4; i++)
            {
                var a = this[i];
                var b = this[i + 1];
                sum += a.X * b.Y - b.X * a.Y;
            }
            return sum / 2;
        }
    }

    /// <summary>The area enclosed, in square pixels.</summary>
    public double Area => Math.Abs(SignedArea);

    /// <summary>
    /// Every corner turns the same way (clockwise on screen) and no three corners are in line:
    /// a real outline of a flat sheet.
    /// </summary>
    public bool IsConvex
    {
        get
        {
            for (int i = 0; i < 4; i++)
            {
                var a = this[i];
                var b = this[i + 1];
                var c = this[i + 2];
                double cross = (b.X - a.X) * (c.Y - b.Y) - (b.Y - a.Y) * (c.X - b.X);
                if (!(cross > 0)) return false;
            }
            return true;
        }
    }

    /// <summary>The mean of the four corners.</summary>
    public PointD Centroid => new((TopLeft.X + TopRight.X + BottomRight.X + BottomLeft.X) / 4,
                                  (TopLeft.Y + TopRight.Y + BottomRight.Y + BottomLeft.Y) / 4);

    /// <summary>The length of edge <paramref name="index"/>: 0 top, 1 right, 2 bottom, 3 left.</summary>
    public double EdgeLength(int index) => this[index].DistanceTo(this[index + 1]);

    /// <summary>Every coordinate multiplied: x by <paramref name="sx"/>, y by <paramref name="sy"/>.</summary>
    public Quad Scaled(double sx, double sy) =>
        new(new PointD(TopLeft.X * sx, TopLeft.Y * sy), new PointD(TopRight.X * sx, TopRight.Y * sy),
            new PointD(BottomRight.X * sx, BottomRight.Y * sy), new PointD(BottomLeft.X * sx, BottomLeft.Y * sy));

    /// <summary>The largest distance between corresponding corners.</summary>
    public double MaxCornerDistance(Quad other)
    {
        double worst = 0;
        for (int i = 0; i < 4; i++) worst = Math.Max(worst, this[i].DistanceTo(other[i]));
        return worst;
    }

    /// <summary>The mean distance between corresponding corners.</summary>
    public double MeanCornerDistance(Quad other)
    {
        double sum = 0;
        for (int i = 0; i < 4; i++) sum += this[i].DistanceTo(other[i]);
        return sum / 4;
    }

    /// <summary>
    /// Every corner lies within the image of <paramref name="width"/> × <paramref name="height"/>,
    /// at least <paramref name="margin"/> pixels from its edges (a negative margin allows that much outside).
    /// </summary>
    public bool IsInside(double width, double height, double margin = 0)
    {
        for (int i = 0; i < 4; i++)
        {
            var p = this[i];
            if (p.X < margin || p.Y < margin || p.X > width - margin || p.Y > height - margin) return false;
        }
        return true;
    }

    /// <summary>
    /// <paramref name="point"/> lies inside the outline or within <paramref name="tolerance"/>
    /// pixels outside it. The quad must be convex.
    /// </summary>
    public bool Contains(PointD point, double tolerance = 0)
    {
        for (int i = 0; i < 4; i++)
        {
            var a = this[i];
            var b = this[i + 1];
            double len = a.DistanceTo(b);
            if (len <= 0) return false;
            // Distance of the point outside edge a→b (positive outside for a clockwise quad).
            double outside = ((b.X - a.X) * (a.Y - point.Y) - (b.Y - a.Y) * (a.X - point.X)) / len;
            if (outside > tolerance) return false;
        }
        return true;
    }

    /// <summary>
    /// The area this outline and <paramref name="other"/> share, in square pixels (both convex and
    /// clockwise): this quad clipped by each edge of the other in turn (Sutherland–Hodgman).
    /// </summary>
    public double IntersectionArea(Quad other)
    {
        var polygon = new List<PointD>(Corners);
        for (int i = 0; i < 4 && polygon.Count > 0; i++)
        {
            var a = other[i];
            var b = other[i + 1];
            var input = polygon;
            polygon = new List<PointD>(input.Count + 1);
            for (int k = 0; k < input.Count; k++)
            {
                var current = input[k];
                var previous = input[(k + input.Count - 1) % input.Count];
                double sc = (b.X - a.X) * (current.Y - a.Y) - (b.Y - a.Y) * (current.X - a.X);
                double sp = (b.X - a.X) * (previous.Y - a.Y) - (b.Y - a.Y) * (previous.X - a.X);
                if (sc >= 0)
                {
                    if (sp < 0) polygon.Add(Crossing(previous, current, sp, sc));
                    polygon.Add(current);
                }
                else if (sp >= 0)
                {
                    polygon.Add(Crossing(previous, current, sp, sc));
                }
            }
        }
        if (polygon.Count < 3) return 0;
        double sum = 0;
        for (int i = 0; i < polygon.Count; i++)
        {
            var p = polygon[i];
            var q = polygon[(i + 1) % polygon.Count];
            sum += p.X * q.Y - q.X * p.Y;
        }
        return Math.Abs(sum) / 2;
    }

    /// <summary>Where segment p→q crosses the clipping line, from the two ends' signed distances to it.</summary>
    private static PointD Crossing(PointD p, PointD q, double sp, double sq)
    {
        double t = sp / (sp - sq);
        return new PointD(p.X + (q.X - p.X) * t, p.Y + (q.Y - p.Y) * t);
    }

    /// <summary>
    /// Four corners in any order around the outline (either direction) as a quad: turned
    /// clockwise on screen when they run the other way, and started at the top-left corner (the
    /// first corner of the edge whose midpoint is highest; the smaller midpoint x on a tie).
    /// </summary>
    public static Quad FromCorners(IReadOnlyList<PointD> corners)
    {
        if (corners.Count != 4) throw new ArgumentException("A quad has four corners.", nameof(corners));
        var p = new PointD[4];
        for (int i = 0; i < 4; i++) p[i] = corners[i];
        double sum = 0;
        for (int i = 0; i < 4; i++) sum += p[i].X * p[(i + 1) & 3].Y - p[(i + 1) & 3].X * p[i].Y;
        if (sum < 0)
        {
            (p[1], p[3]) = (p[3], p[1]);
        }
        int start = 0;
        double bestY = double.MaxValue, bestX = double.MaxValue;
        for (int i = 0; i < 4; i++)
        {
            var a = p[i];
            var b = p[(i + 1) & 3];
            double my = (a.Y + b.Y) / 2, mx = (a.X + b.X) / 2;
            if (my < bestY || (my == bestY && mx < bestX))
            {
                bestY = my;
                bestX = mx;
                start = i;
            }
        }
        return new Quad(p[start], p[(start + 1) & 3], p[(start + 2) & 3], p[(start + 3) & 3]);
    }

    /// <summary>The four numbers of each corner, for test messages.</summary>
    public override string ToString() => string.Create(System.Globalization.CultureInfo.InvariantCulture,
        $"Quad {{ ({TopLeft.X:0.##}, {TopLeft.Y:0.##}) ({TopRight.X:0.##}, {TopRight.Y:0.##}) ({BottomRight.X:0.##}, {BottomRight.Y:0.##}) ({BottomLeft.X:0.##}, {BottomLeft.Y:0.##}) }}");
}
