namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/MultiQuadPicker.swift: the same filters, order and numbers.

/// <summary>An outline a finder proposed (Vision's rectangles, a page finder), with how sure it is (0 to 1).</summary>
public sealed record QuadCandidate(Quad Quad, double Confidence);

/// <summary>What <see cref="MultiQuadPicker"/> keeps (<see cref="MultiQuadPicker.OptionsFor"/> gives each kind's).</summary>
public sealed record MultiQuadOptions
{
    /// <summary>The shape's long side over its short side (<see cref="CaptureScale.Aspect"/>) is at least this…</summary>
    public double MinLongOverShort { get; init; } = 1;
    /// <summary>…and at most this.</summary>
    public double MaxLongOverShort { get; init; } = 2;
    /// <summary>The outline covers at least this share of the photo…</summary>
    public double MinAreaFraction { get; init; }
    /// <summary>…and at most this.</summary>
    public double MaxAreaFraction { get; init; } = 1;
    /// <summary>Two outlines sharing more than this share of their joint area (intersection over union) are one object: the surer stays.</summary>
    public double MaxOverlap { get; init; } = MultiQuadPicker.MaxOverlap;
    /// <summary>At most this many outlines are kept.</summary>
    public int MaxCount { get; init; } = 1;
}

/// <summary>
/// Picks the objects in one camera shot (several receipts or photos, a card, a page) from the
/// outlines a finder proposed: each named and checked for a convex outline, kept when its size and
/// shape fit the kind of object, dropped when it is the only object inside a larger outline of the
/// right size and shape (a picture printed on a photo, a logo on a receipt), while a larger outline
/// holding several separate objects that cover at least <see cref="MinBackgroundCoverage"/> of it is
/// the background and dropped instead (an album page, a sheet under receipts; only when more than one
/// object is wanted; small features inside one object, such as windows in a print's picture, leave
/// the object whole), then taken surest first (larger, then earlier, on a tie)
/// unless it overlaps one already taken by more than <see cref="MultiQuadOptions.MaxOverlap"/>, up to
/// <see cref="MultiQuadOptions.MaxCount"/>, and returned in reading order: rows from the top, left to
/// right in each (<see cref="PhotoDetector"/>'s row grouping on their bounding boxes).
/// </summary>
public static class MultiQuadPicker
{
    /// <summary>Two outlines overlapping by more than this (intersection over union) are the same object.</summary>
    public const double MaxOverlap = 0.3;
    /// <summary>An outline is inside another when each of its corners is at most this many pixels outside it.</summary>
    public const double InsideTolerance = 2;
    /// <summary>
    /// An outline holding several separate objects is the background behind them only when they cover at
    /// least this share of it: prints on an album page and receipts on a sheet cover a fifth to a third,
    /// windows in the picture on a print far less.
    /// </summary>
    public const double MinBackgroundCoverage = 0.15;
    /// <summary>The ID-1 card's long side over its short side (85.6 / 53.98 mm).</summary>
    public const double IdCardLongOverShort = 3.370 / 2.125;
    /// <summary>A card's shape may differ from <see cref="IdCardLongOverShort"/> by this much.</summary>
    public const double IdCardShapeSlack = 0.12;

    /// <summary>
    /// What is kept for <paramref name="kind"/>: receipts long and narrow (short over long side 0.12 to
    /// 0.8) and at least 0.5 % of the photo, up to 6; photos up to twice as long as wide and at least
    /// 1 % of the photo, up to 8; one card of the ID-1 shape (± <see cref="IdCardShapeSlack"/>) of at
    /// least 2 %; one document page up to Legal's shape and more (2.0) of at least 10 %.
    /// </summary>
    public static MultiQuadOptions OptionsFor(CaptureKind kind) => kind switch
    {
        CaptureKind.Receipt => new MultiQuadOptions
        {
            MinLongOverShort = 1 / 0.8, MaxLongOverShort = 1 / 0.12, MinAreaFraction = 0.005, MaxAreaFraction = 0.9, MaxCount = 6,
        },
        CaptureKind.Photo => new MultiQuadOptions
        {
            MinLongOverShort = 1, MaxLongOverShort = 2, MinAreaFraction = 0.01, MaxAreaFraction = 0.95, MaxCount = 8,
        },
        CaptureKind.IdCard => new MultiQuadOptions
        {
            MinLongOverShort = IdCardLongOverShort - IdCardShapeSlack, MaxLongOverShort = IdCardLongOverShort + IdCardShapeSlack,
            MinAreaFraction = 0.02, MaxAreaFraction = 1, MaxCount = 1,
        },
        _ => new MultiQuadOptions
        {
            MinLongOverShort = 1, MaxLongOverShort = 2, MinAreaFraction = 0.1, MaxAreaFraction = 1, MaxCount = 1,
        },
    };

    /// <summary>The outlines of the <paramref name="kind"/> objects among <paramref name="candidates"/>, in reading order.</summary>
    public static IReadOnlyList<Quad> Pick(IReadOnlyList<QuadCandidate> candidates, int imageWidth, int imageHeight, CaptureKind kind) =>
        Pick(candidates, imageWidth, imageHeight, OptionsFor(kind));

    /// <summary>The outlines among <paramref name="candidates"/> that <paramref name="options"/> keep, in reading order.</summary>
    public static IReadOnlyList<Quad> Pick(IReadOnlyList<QuadCandidate> candidates, int imageWidth, int imageHeight,
                                           MultiQuadOptions options)
    {
        if (imageWidth <= 0 || imageHeight <= 0 || options.MaxCount <= 0) return [];
        double photoArea = (double)imageWidth * imageHeight;

        // Outlines of the right size and shape, with their input order.
        var fitting = new List<(Quad Quad, double Confidence, double Area, int Index)>();
        for (int i = 0; i < candidates.Count; i++)
        {
            var quad = Quad.FromCorners(candidates[i].Quad.Corners);
            if (!quad.IsConvex) continue;
            double area = quad.Area;
            double fraction = area / photoArea;
            if (fraction < options.MinAreaFraction || fraction > options.MaxAreaFraction) continue;
            double shape = CaptureScale.Aspect(quad, imageWidth, imageHeight).LongOverShort;
            if (shape < options.MinLongOverShort || shape > options.MaxLongOverShort) continue;
            double confidence = double.IsFinite(candidates[i].Confidence) ? candidates[i].Confidence : 0;
            fitting.Add((quad, confidence, area, i));
        }

        // Outlines nest: each hangs under the smallest larger one holding it (the earlier on a tie).
        int n = fitting.Count;
        var parent = new int[n];
        for (int i = 0; i < n; i++)
        {
            parent[i] = -1;
            for (int j = 0; j < n; j++)
            {
                if (j == i || fitting[j].Area <= fitting[i].Area || !Inside(fitting[i].Quad, fitting[j].Quad)) continue;
                if (parent[i] < 0 || fitting[j].Area < fitting[parent[i]].Area) parent[i] = j;
            }
        }

        // Folded from the smallest up: an outline is the background behind what it holds (an album page,
        // a sheet under receipts) when it holds several separate objects covering enough of it, unless
        // only one object is wanted; otherwise it is one object (a print and the picture on it, a print
        // and the windows of the house it shows).
        var smallestFirst = new List<int>(n);
        for (int i = 0; i < n; i++) smallestFirst.Add(i);
        smallestFirst.Sort((a, b) =>
        {
            int byArea = fitting[a].Area.CompareTo(fitting[b].Area);
            return byArea != 0 ? byArea : a.CompareTo(b);
        });
        var held = new List<int>[n];
        for (int i = 0; i < n; i++) held[i] = [];
        var objects = new List<int>[n];
        foreach (int i in smallestFirst)
        {
            objects[i] = options.MaxCount > 1 && IsBackground(fitting, held[i], fitting[i].Area, options.MaxOverlap) ? held[i] : [i];
            if (parent[i] >= 0) held[parent[i]].AddRange(objects[i]);
        }
        var outer = new List<(Quad Quad, double Confidence, double Area, int Index)>();
        for (int i = 0; i < n; i++)
        {
            if (parent[i] >= 0) continue;
            foreach (int k in objects[i]) outer.Add(fitting[k]);
        }

        // Surest first; an outline overlapping one taken is the same object.
        outer.Sort((a, b) =>
        {
            int byConfidence = b.Confidence.CompareTo(a.Confidence);
            if (byConfidence != 0) return byConfidence;
            int byArea = b.Area.CompareTo(a.Area);
            return byArea != 0 ? byArea : a.Index.CompareTo(b.Index);
        });
        var taken = new List<Quad>();
        foreach (var item in outer)
        {
            if (taken.Count >= options.MaxCount) break;
            bool overlaps = false;
            foreach (var kept in taken)
            {
                if (Overlap(item.Quad, kept) > options.MaxOverlap)
                {
                    overlaps = true;
                    break;
                }
            }
            if (!overlaps) taken.Add(item.Quad);
        }
        return InReadingOrder(taken);
    }

    /// <summary>The share of their joint area two convex outlines have in common (intersection over union, 0 to 1).</summary>
    public static double Overlap(Quad a, Quad b)
    {
        double shared = a.IntersectionArea(b);
        double union = a.Area + b.Area - shared;
        return union > 0 ? shared / union : 0;
    }

    /// <summary>
    /// <paramref name="held"/> are objects laid on an outline of <paramref name="containerArea"/>, not
    /// features inside one object: at least two of them are separate (taken surest first, one overlapping
    /// one counted by more than <paramref name="maxOverlap"/> is the same object) and those cover at least
    /// <see cref="MinBackgroundCoverage"/> of the outline.
    /// </summary>
    private static bool IsBackground(List<(Quad Quad, double Confidence, double Area, int Index)> fitting, List<int> held,
                                     double containerArea, double maxOverlap)
    {
        if (held.Count < 2) return false;
        var surest = new List<int>(held);
        surest.Sort((a, b) =>
        {
            int byConfidence = fitting[b].Confidence.CompareTo(fitting[a].Confidence);
            if (byConfidence != 0) return byConfidence;
            int byArea = fitting[b].Area.CompareTo(fitting[a].Area);
            return byArea != 0 ? byArea : fitting[a].Index.CompareTo(fitting[b].Index);
        });
        var counted = new List<Quad>();
        double covered = 0;
        foreach (int k in surest)
        {
            bool same = false;
            foreach (var quad in counted)
            {
                if (Overlap(fitting[k].Quad, quad) > maxOverlap)
                {
                    same = true;
                    break;
                }
            }
            if (same) continue;
            counted.Add(fitting[k].Quad);
            covered += fitting[k].Area;
        }
        return counted.Count >= 2 && covered >= MinBackgroundCoverage * containerArea;
    }

    /// <summary>Every corner of <paramref name="inner"/> lies in <paramref name="outer"/>, or at most <see cref="InsideTolerance"/> outside it.</summary>
    private static bool Inside(Quad inner, Quad outer)
    {
        for (int i = 0; i < 4; i++)
        {
            if (!outer.Contains(inner[i], InsideTolerance)) return false;
        }
        return true;
    }

    /// <summary><paramref name="quads"/> in rows from the top, left to right in each, by their bounding boxes.</summary>
    private static IReadOnlyList<Quad> InReadingOrder(List<Quad> quads)
    {
        if (quads.Count <= 1) return quads;
        var regions = new List<DetectedPhotoRegion>(quads.Count);
        var byRegion = new Dictionary<Guid, Quad>(quads.Count);
        foreach (var quad in quads)
        {
            double minX = quad[0].X, maxX = quad[0].X, minY = quad[0].Y, maxY = quad[0].Y;
            for (int i = 1; i < 4; i++)
            {
                minX = Math.Min(minX, quad[i].X);
                maxX = Math.Max(maxX, quad[i].X);
                minY = Math.Min(minY, quad[i].Y);
                maxY = Math.Max(maxY, quad[i].Y);
            }
            var region = new DetectedPhotoRegion(new PointD((minX + maxX) / 2, (minY + maxY) / 2), new SizeD(maxX - minX, maxY - minY), 0);
            regions.Add(region);
            byRegion[region.Id] = quad;
        }
        var sorted = PhotoDetector.SortRowMajor(regions);
        var ordered = new List<Quad>(sorted.Count);
        foreach (var region in sorted) ordered.Add(byRegion[region.Id]);
        return ordered;
    }
}
