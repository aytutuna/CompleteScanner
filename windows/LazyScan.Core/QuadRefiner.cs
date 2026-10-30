namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/QuadRefiner.swift: the same search and numbers.

/// <summary>
/// What <see cref="QuadRefiner.Refine"/> made of an outline: the corners (refined, or the outline as
/// given when no refinement was taken), whether they were refined, and the outline's edge support:
/// the share of its weakest side backed by a clear edge (0...1).
/// </summary>
public readonly record struct QuadRefinement(Quad Quad, bool Refined, double Support);

/// <summary>
/// Moves each side of a page outline found roughly (Vision's, the page search's) onto the photo's edge.
/// Within <see cref="Band"/> of the diagonal either side of a side, every straight line is scored by the
/// points along the side where it passes a ridge of the gradient across it (either sign, at least
/// <see cref="PhotoDocumentDetector.EdgeThreshold"/>), so a faint edge along the whole side counts as
/// much as a dark one; of the lines scoring at least <see cref="OuterShare"/> of the best, the outermost
/// is the page's edge (a header bar or a ruled line just inside it scores as well). That line is then
/// fitted to a fraction of a pixel at the points where its edge is clear. A side whose edge is clear at
/// fewer than <see cref="MinSideSupport"/> of its points keeps its place. The corners are where the four
/// lines cross; the refinement is taken only when at least one side moved, the outline stays convex, no
/// corner moved more than twice the band and its sides lie on stronger gradient, all told, than the
/// outline given. The photo is searched at most
/// <see cref="PhotoDocumentDetector.AnalysisLongSide"/> px long, as the page search sees it.
/// </summary>
public static class QuadRefiner
{
    /// <summary>How far either side of a side its edge is looked for: a share of the photo's diagonal.</summary>
    public const double Band = 0.03;
    /// <summary>Points along each side, from 10 % to 90 % of it (clear of the corners).</summary>
    public const int Samples = 48;
    /// <summary>A side's line is taken when its edge is clear at this share of its points.</summary>
    public const double MinSideSupport = 0.5;
    /// <summary>A point backs a side when the edge lies within this many analysis pixels of it.</summary>
    public const double SupportReach = 1.5;
    /// <summary>Of the lines scoring at least this share of the best, the outermost is the edge.</summary>
    public const double OuterShare = 0.7;
    /// <summary>
    /// How far outside the side as given, as a share of the band, a line may win for being outermost; one
    /// further out wins only as the best line.
    /// </summary>
    public const double OuterReach = 1.0 / 3;

    /// <summary><paramref name="quad"/> (the photo's pixels) moved onto the edges of <paramref name="image"/>, with its support.</summary>
    public static QuadRefinement Refine(RgbaImage image, Quad quad)
    {
        var (field, toFullX, toFullY) = Analysis(image);
        if (field is null) return new QuadRefinement(quad, false, 0);
        var q = quad.Scaled(1 / toFullX, 1 / toFullY);
        double reach = Band * field.Diagonal;
        double outward = q.SignedArea >= 0 ? 1 : -1;
        var lines = new PhotoDocumentDetector.Line[4];
        int moved = 0;
        for (int i = 0; i < 4; i++)
        {
            if (FitSide(field, q[i], q[i + 1], reach, outward) is { } line)
            {
                lines[i] = line;
                moved++;
            }
            else if (q[i].DistanceTo(q[i + 1]) >= 1)
            {
                lines[i] = PhotoDocumentDetector.Line.Through(q[i], q[i + 1]);
            }
            else
            {
                return new QuadRefinement(quad, false, 0);
            }
        }
        var given = Backing(field, q);
        if (moved > 0 && Crossings(lines) is { } result && result.IsConvex && Within(result, q, 2 * reach))
        {
            // Only an outline lying on its edges better than the one given: a page already on its edges is not
            // moved onto another edge near it.
            var found = Backing(field, result);
            if (found.Fit > given.Fit) return new QuadRefinement(result.Scaled(toFullX, toFullY), true, found.Shares.Min());
        }
        return new QuadRefinement(quad, false, given.Shares.Min());
    }

    /// <summary>The edge support of <paramref name="quad"/> (the photo's pixels) in <paramref name="image"/>, as <see cref="Refine"/> reports it.</summary>
    internal static double SupportOf(RgbaImage image, Quad quad)
    {
        var (field, toFullX, toFullY) = Analysis(image);
        return field is null ? 0 : Backing(field, quad.Scaled(1 / toFullX, 1 / toFullY)).Shares.Min();
    }

    private static (PhotoDocumentDetector.Field? Field, double ToFullX, double ToFullY) Analysis(RgbaImage image)
    {
        int longSide = Math.Max(image.Width, image.Height);
        var small = image;
        if (longSide > PhotoDocumentDetector.AnalysisLongSide)
        {
            double s = (double)PhotoDocumentDetector.AnalysisLongSide / longSide;
            int aw = Math.Max(1, (int)Math.Round(image.Width * s, MidpointRounding.AwayFromZero));
            int ah = Math.Max(1, (int)Math.Round(image.Height * s, MidpointRounding.AwayFromZero));
            small = image.Resized(aw, ah);
        }
        if (small.Width < 16 || small.Height < 16) return (null, 1, 1);
        return (PhotoDocumentDetector.Field.Build(small), (double)image.Width / small.Width, (double)image.Height / small.Height);
    }

    private static Quad? Crossings(PhotoDocumentDetector.Line[] lines)
    {
        var corners = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            if (PhotoDocumentDetector.Line.Intersect(lines[(i + 3) & 3], lines[i]) is not { } c) return null;
            corners[i] = c;
        }
        return new Quad(corners[0], corners[1], corners[2], corners[3]);
    }

    private static bool Within(Quad a, Quad b, double limit)
    {
        for (int i = 0; i < 4; i++)
        {
            if (!(a[i].DistanceTo(b[i]) <= limit)) return false;
        }
        return true;
    }

    /// <summary>
    /// The edge near the side from <paramref name="p"/> to <paramref name="q"/> (<paramref name="outward"/>:
    /// 1 when the outline runs clockwise on screen, so the side's left normal points out), as the class
    /// summary says: at each point the strongest response within 2 px of the line chosen, placed by a
    /// parabola, fitted by <see cref="PhotoDocumentDetector.FitLine"/>. Null when too few points are clear.
    /// </summary>
    private static PhotoDocumentDetector.Line? FitSide(PhotoDocumentDetector.Field f, PointD p, PointD q, double reach, double outward)
    {
        double dx = q.X - p.X, dy = q.Y - p.Y;
        double len = Math.Sqrt(dx * dx + dy * dy);
        if (!(len >= 8) || len > 1e6) return null;
        double nx = dy / len, ny = -dx / len;
        int r = Math.Max(2, (int)Math.Ceiling(reach));
        int span = 2 * r + 1;
        const int n = Samples;
        var values = new double[n * span];
        var xs = new double[n];
        var ys = new double[n];
        var inside = new bool[n];
        int used = 0;
        for (int s = 0; s < n; s++)
        {
            double t = 0.1 + 0.8 * (s + 0.5) / n;
            double x = p.X + dx * t, y = p.Y + dy * t;
            xs[s] = x;
            ys[s] = y;
            if (!InField(f, x, y)) continue;
            inside[s] = true;
            used++;
            for (int k = 0; k < span; k++)
            {
                double ox = x + nx * (k - r), oy = y + ny * (k - r);
                if (!InField(f, ox, oy)) continue;
                var g = f.GradientAt(ox, oy);
                values[s * span + k] = g.Gx * nx + g.Gy * ny;
            }
        }
        if (used * 4 < n) return null;

        // Each ridge marked a pixel either way, so a line drawn through whole pixels still passes it.
        var hits = new bool[2 * n * span];
        for (int side = 0; side < 2; side++)
        {
            double sign = side == 0 ? -1 : 1;
            for (int s = 0; s < n; s++)
            {
                if (!inside[s]) continue;
                for (int k = 1; k < span - 1; k++)
                {
                    double v = sign * values[s * span + k];
                    if (v < PhotoDocumentDetector.EdgeThreshold) continue;
                    if (v < sign * values[s * span + k - 1] || v < sign * values[s * span + k + 1]) continue;
                    for (int d = k - 1; d <= k + 1; d++) hits[(side * n + s) * span + d] = true;
                }
            }
        }
        var counts = new int[2 * span * span];
        var strengths = new double[2 * span * span];
        int bestCount = 0, bestIndex = -1, bestNear = int.MaxValue;
        for (int side = 0; side < 2; side++)
        {
            double sign = side == 0 ? -1 : 1;
            for (int a = 0; a < span; a++)
            {
                for (int b = 0; b < span; b++)
                {
                    int count = 0;
                    double strength = 0;
                    for (int s = 0; s < n; s++)
                    {
                        if (!inside[s]) continue;
                        int k = (int)Math.Round(a + (b - a) * (double)s / (n - 1), MidpointRounding.AwayFromZero);
                        if (!hits[(side * n + s) * span + k]) continue;
                        count++;
                        strength += Math.Min(sign * values[s * span + k], PhotoDocumentDetector.VoteCap);
                    }
                    int index = (side * span + a) * span + b;
                    counts[index] = count;
                    strengths[index] = strength;
                    // The best line: the most points, the nearer to the side as given on a tie.
                    int near = Math.Abs(a - r) + Math.Abs(b - r);
                    if (count > bestCount || (count == bestCount && near < bestNear))
                    {
                        bestCount = count;
                        bestIndex = index;
                        bestNear = near;
                    }
                }
            }
        }
        if (bestCount < Math.Max(6, MinSideSupport * used)) return null;
        double bestSign = 1, bestOut = double.NegativeInfinity, bestScore = 0, bestStrength = 0;
        int bestStart = r, bestEnd = r;
        double outReach = 2 * r * OuterReach;
        for (int side = 0; side < 2; side++)
        {
            for (int a = 0; a < span; a++)
            {
                for (int b = 0; b < span; b++)
                {
                    int index = (side * span + a) * span + b;
                    int count = counts[index];
                    if (count < OuterShare * bestCount) continue;
                    double outness = outward * (a + b - 2 * r);
                    if (outness > outReach && index != bestIndex) continue;
                    if (outness > bestOut || (outness == bestOut && (count > bestScore || (count == bestScore && strengths[index] > bestStrength))))
                    {
                        bestOut = outness;
                        bestScore = count;
                        bestStrength = strengths[index];
                        bestSign = side == 0 ? -1 : 1;
                        bestStart = a;
                        bestEnd = b;
                    }
                }
            }
        }

        var points = new List<PointD>();
        for (int s = 0; s < n; s++)
        {
            if (!inside[s]) continue;
            int centre = (int)Math.Round(bestStart + (bestEnd - bestStart) * (double)s / (n - 1), MidpointRounding.AwayFromZero);
            int at = -1;
            double top = 0;
            for (int k = Math.Max(0, centre - 2); k <= Math.Min(span - 1, centre + 2); k++)
            {
                double v = bestSign * values[s * span + k];
                if (v >= PhotoDocumentDetector.EdgeThreshold && v > top)
                {
                    top = v;
                    at = k;
                }
            }
            if (at < 0) continue;
            double delta = 0;
            if (at > 0 && at < span - 1)
            {
                double before = bestSign * values[s * span + at - 1], after = bestSign * values[s * span + at + 1];
                double den = before - 2 * top + after;
                if (den < 0) delta = Math.Clamp(0.5 * (before - after) / den, -0.5, 0.5);
            }
            double off = at - r + delta;
            points.Add(new PointD(xs[s] + nx * off, ys[s] + ny * off));
        }
        if (points.Count < Math.Max(6, MinSideSupport * used)) return null;
        return PhotoDocumentDetector.FitLine(points);
    }

    /// <summary>
    /// How well edges back <paramref name="q"/> (analysis pixels). <c>Shares</c>: the share of each side
    /// backed by an edge: at each of its points inside the frame, the gradient across it within
    /// <see cref="SupportReach"/> px, of the sign that prevails along the side, at least
    /// <see cref="PhotoDocumentDetector.EdgeThreshold"/>. <c>Fit</c>: the sides' sum of that gradient right on
    /// the side (up to <see cref="PhotoDocumentDetector.VoteCap"/>, as a share of it, the mean over the
    /// points). A side with fewer than a quarter of its points inside the frame backs nothing.
    /// </summary>
    private static (double[] Shares, double Fit) Backing(PhotoDocumentDetector.Field f, Quad q)
    {
        var shares = new double[4];
        double fit = 0;
        for (int i = 0; i < 4; i++)
        {
            var p = q[i];
            var e = q[i + 1];
            double dx = e.X - p.X, dy = e.Y - p.Y;
            double len = Math.Sqrt(dx * dx + dy * dy);
            if (!(len >= 1)) continue;
            double nx = dy / len, ny = -dx / len;
            var pos = new double[Samples];
            var neg = new double[Samples];
            var onSide = new double[Samples];
            int used = 0;
            double sumPos = 0, sumNeg = 0;
            for (int s = 0; s < Samples; s++)
            {
                double t = 0.1 + 0.8 * (s + 0.5) / Samples;
                double x = p.X + dx * t, y = p.Y + dy * t;
                if (!InField(f, x, y))
                {
                    pos[s] = neg[s] = -1;
                    continue;
                }
                used++;
                for (double k = -SupportReach; k <= SupportReach; k += 0.5)
                {
                    var g = f.GradientAt(x + nx * k, y + ny * k);
                    double v = g.Gx * nx + g.Gy * ny;
                    pos[s] = Math.Max(pos[s], v);
                    neg[s] = Math.Max(neg[s], -v);
                    if (k == 0) onSide[s] = v;
                }
                sumPos += pos[s];
                sumNeg += neg[s];
            }
            if (used * 4 < Samples) continue;
            double sign = sumPos >= sumNeg ? 1 : -1;
            var side = sign > 0 ? pos : neg;
            int backed = 0;
            double on = 0;
            for (int s = 0; s < Samples; s++)
            {
                if (side[s] >= PhotoDocumentDetector.EdgeThreshold) backed++;
                if (side[s] >= 0) on += Math.Clamp(sign * onSide[s], 0, PhotoDocumentDetector.VoteCap);
            }
            shares[i] = (double)backed / used;
            fit += on / (PhotoDocumentDetector.VoteCap * used);
        }
        return (shares, fit);
    }

    /// <summary>Whether (x, y) lies where the gradient is measured (not the outermost pixels).</summary>
    private static bool InField(PhotoDocumentDetector.Field f, double x, double y) =>
        x >= 1.5 && y >= 1.5 && x <= f.W - 1.5 && y <= f.H - 1.5;
}
