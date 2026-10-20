namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/Homography.swift: + − × ÷ on doubles in the same
// order, so the same quad gives the same matrix, bit for bit, on both platforms.

/// <summary>
/// A plane-to-plane projective map (3 × 3, row-major): (x, y) goes to
/// ((M00 x + M01 y + M02) / w, (M10 x + M11 y + M12) / w) with w = M20 x + M21 y + M22.
/// Coordinates are continuous pixels (see <see cref="Quad"/>).
/// </summary>
public readonly record struct Homography(
    double M00, double M01, double M02,
    double M10, double M11, double M12,
    double M20, double M21, double M22)
{
    public static Homography Identity { get; } = new(1, 0, 0, 0, 1, 0, 0, 0, 1);

    /// <summary>Where <paramref name="p"/> lands (infinite or NaN when it maps to the line at infinity).</summary>
    public PointD Map(PointD p)
    {
        double w = M20 * p.X + M21 * p.Y + M22;
        return new PointD((M00 * p.X + M01 * p.Y + M02) / w, (M10 * p.X + M11 * p.Y + M12) / w);
    }

    /// <summary>The homogeneous weight w at <paramref name="p"/>: positive on the side of the plane that is seen.</summary>
    public double Weight(PointD p) => M20 * p.X + M21 * p.Y + M22;

    /// <summary>The determinant of the matrix.</summary>
    public double Determinant =>
        M00 * (M11 * M22 - M12 * M21) - M01 * (M10 * M22 - M12 * M20) + M02 * (M10 * M21 - M11 * M20);

    /// <summary>The map back (the adjugate over the determinant); null when the matrix is singular.</summary>
    public Homography? Inverse()
    {
        double det = Determinant;
        if (det == 0 || !double.IsFinite(det)) return null;
        return new Homography(
            (M11 * M22 - M12 * M21) / det, (M02 * M21 - M01 * M22) / det, (M01 * M12 - M02 * M11) / det,
            (M12 * M20 - M10 * M22) / det, (M00 * M22 - M02 * M20) / det, (M02 * M10 - M00 * M12) / det,
            (M10 * M21 - M11 * M20) / det, (M01 * M20 - M00 * M21) / det, (M00 * M11 - M01 * M10) / det);
    }

    /// <summary><paramref name="a"/> × <paramref name="b"/>: the map that applies <paramref name="b"/> first, then <paramref name="a"/>.</summary>
    public static Homography Multiply(Homography a, Homography b) => new(
        a.M00 * b.M00 + a.M01 * b.M10 + a.M02 * b.M20,
        a.M00 * b.M01 + a.M01 * b.M11 + a.M02 * b.M21,
        a.M00 * b.M02 + a.M01 * b.M12 + a.M02 * b.M22,
        a.M10 * b.M00 + a.M11 * b.M10 + a.M12 * b.M20,
        a.M10 * b.M01 + a.M11 * b.M11 + a.M12 * b.M21,
        a.M10 * b.M02 + a.M11 * b.M12 + a.M12 * b.M22,
        a.M20 * b.M00 + a.M21 * b.M10 + a.M22 * b.M20,
        a.M20 * b.M01 + a.M21 * b.M11 + a.M22 * b.M21,
        a.M20 * b.M02 + a.M21 * b.M12 + a.M22 * b.M22);

    /// <summary>
    /// The map of the unit square onto <paramref name="quad"/>: (0, 0) to the top-left corner,
    /// (1, 0) top-right, (1, 1) bottom-right, (0, 1) bottom-left (Heckbert's closed form). Null
    /// when three corners are in line.
    /// </summary>
    public static Homography? SquareToQuad(Quad quad)
    {
        double x0 = quad.TopLeft.X, y0 = quad.TopLeft.Y;
        double x1 = quad.TopRight.X, y1 = quad.TopRight.Y;
        double x2 = quad.BottomRight.X, y2 = quad.BottomRight.Y;
        double x3 = quad.BottomLeft.X, y3 = quad.BottomLeft.Y;
        double sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
        double dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2;
        double den = dx1 * dy2 - dx2 * dy1;
        if (den == 0 || !double.IsFinite(den)) return null;
        double g = (sx * dy2 - dx2 * sy) / den;
        double h = (dx1 * sy - sx * dy1) / den;
        var m = new Homography(
            x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
            y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
            g, h, 1);
        double det = m.Determinant;
        return det == 0 || !double.IsFinite(det) ? null : m;
    }

    /// <summary>
    /// The map of the upright rectangle (0, 0)–(<paramref name="width"/>, <paramref name="height"/>)
    /// onto <paramref name="quad"/>, corner to corner; null for a degenerate quad or size.
    /// </summary>
    public static Homography? RectToQuad(double width, double height, Quad quad)
    {
        if (!(width > 0) || !(height > 0)) return null;
        if (SquareToQuad(quad) is not { } s) return null;
        return new Homography(
            s.M00 / width, s.M01 / height, s.M02,
            s.M10 / width, s.M11 / height, s.M12,
            s.M20 / width, s.M21 / height, s.M22);
    }

    /// <summary>The map of <paramref name="quad"/> onto the upright rectangle (0, 0)–(<paramref name="width"/>, <paramref name="height"/>).</summary>
    public static Homography? QuadToRect(Quad quad, double width, double height) =>
        RectToQuad(width, height, quad)?.Inverse();

    /// <summary>
    /// The map that takes each of four points <paramref name="from"/> to the matching point of
    /// <paramref name="to"/>, by solving the eight equations (Gaussian elimination with partial
    /// pivoting), M22 = 1. Null when no such map exists (three points in line).
    /// </summary>
    public static Homography? FromCorrespondences(IReadOnlyList<PointD> from, IReadOnlyList<PointD> to)
    {
        if (from.Count != 4 || to.Count != 4) throw new ArgumentException("Four points each.");
        var a = new double[8, 9];
        for (int i = 0; i < 4; i++)
        {
            double x = from[i].X, y = from[i].Y, u = to[i].X, v = to[i].Y;
            int r = 2 * i;
            a[r, 0] = x; a[r, 1] = y; a[r, 2] = 1; a[r, 3] = 0; a[r, 4] = 0; a[r, 5] = 0;
            a[r, 6] = -u * x; a[r, 7] = -u * y; a[r, 8] = u;
            a[r + 1, 0] = 0; a[r + 1, 1] = 0; a[r + 1, 2] = 0; a[r + 1, 3] = x; a[r + 1, 4] = y; a[r + 1, 5] = 1;
            a[r + 1, 6] = -v * x; a[r + 1, 7] = -v * y; a[r + 1, 8] = v;
        }
        for (int col = 0; col < 8; col++)
        {
            int pivot = col;
            double best = Math.Abs(a[col, col]);
            for (int r = col + 1; r < 8; r++)
            {
                double value = Math.Abs(a[r, col]);
                if (value > best)
                {
                    best = value;
                    pivot = r;
                }
            }
            if (!(best > 1e-12)) return null;
            if (pivot != col)
            {
                for (int k = 0; k < 9; k++) (a[col, k], a[pivot, k]) = (a[pivot, k], a[col, k]);
            }
            for (int r = col + 1; r < 8; r++)
            {
                double f = a[r, col] / a[col, col];
                if (f == 0) continue;
                for (int k = col; k < 9; k++) a[r, k] -= f * a[col, k];
            }
        }
        var h = new double[8];
        for (int r = 7; r >= 0; r--)
        {
            double sum = a[r, 8];
            for (int k = r + 1; k < 8; k++) sum -= a[r, k] * h[k];
            h[r] = sum / a[r, r];
        }
        var m = new Homography(h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1);
        double det = m.Determinant;
        return det == 0 || !double.IsFinite(det) ? null : m;
    }
}
