namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/BookSplitter.swift: same constants, same steps.

/// <summary>Which way the gutter of an open book runs across a scan (<see cref="GutterResult"/>).</summary>
public enum GutterAxis
{
    /// <summary>Up and down the scan: the two pages lie side by side.</summary>
    Vertical,
    /// <summary>Across the scan: the two pages lie one above the other (the book lay sideways on the glass).</summary>
    Horizontal,
}

/// <summary>What showed where the gutter is.</summary>
public enum GutterKind
{
    /// <summary>The dark shadow along the spine, where the pages curve away from the glass.</summary>
    Shadow,
    /// <summary>The blank inner margins of the two pages, between their text.</summary>
    Margin,
    /// <summary>The user placed the cut.</summary>
    Manual,
}

/// <summary>Where a spread is cut into its two pages.</summary>
/// <param name="Axis">Which way the cut runs.</param>
/// <param name="Position">
/// Where the scan is cut, in its pixels from its left edge (<see cref="GutterAxis.Vertical"/>) or its top
/// edge (<see cref="GutterAxis.Horizontal"/>): one page is the pixels before it, the other the pixels
/// from it on. Between 1 and the length of the axis less 1.
/// </param>
/// <param name="Confidence">
/// How clear the gutter is: the depth of the shadow (its darkening, 0...1), or the length of the blank
/// margin as a share of the axis; 1 for a cut placed by the user.
/// </param>
/// <param name="Kind">What showed it.</param>
public sealed record GutterResult(GutterAxis Axis, int Position, double Confidence, GutterKind Kind)
{
    /// <summary>The cut's place along its axis on a scan <paramref name="width"/> × <paramref name="height"/>, 0...1.</summary>
    public double Fraction(int width, int height) =>
        (double)Position / Math.Max(1, Axis == GutterAxis.Vertical ? width : height);
}

/// <summary>
/// A page cut from a spread (<see cref="ScannedPage.Spread"/>; in memory only, never saved): the spread
/// it was cut from, which part of the scan it is, and where the scan was cut. Unsplitting and
/// splitting again start from the spread.
/// </summary>
/// <param name="SpreadId">The spread: the id of the page as scanned.</param>
/// <param name="Part">
/// 0 for the part before the cut (left, or top), 1 for the part after it (right, or bottom); null when
/// the spread was not split and the page is the whole spread.
/// </param>
/// <param name="Gutter">Where the spread was cut; null when it was not.</param>
/// <param name="Left">
/// Whether the page is the spread's left page, as worked out when the spread was cut
/// (<see cref="PageProcessor.ProcessSpread"/>): the page first in reading order then, or the other one
/// for a book read from right to left. Null when not recorded: then the part before the cut is the left
/// page (<see cref="IsLeft"/>).
/// </param>
public sealed record SpreadPart(Guid SpreadId, int? Part, GutterResult? Gutter, bool? Left = null)
{
    /// <summary>The page is a whole spread: it was not split (the spine was not found, or the user joined it).</summary>
    public bool IsWhole => Part is null;

    /// <summary>The page is the spread's left page (<see cref="Left"/>); it keeps its side wherever it is moved in the queue.</summary>
    public bool IsLeft => Left ?? Part == 0;
}

/// <summary>How the pages of a spread are turned and put in order (<see cref="BookSplitter.Split"/>).</summary>
/// <param name="RotationQuarterTurns">Quarter turns clockwise every page of the book is turned (the book lay sideways or upside down on the glass).</param>
/// <param name="RightToLeft">The book reads from right to left (Arabic, Hebrew, manga): the right page comes first.</param>
public sealed record BookSplitOptions(int RotationQuarterTurns = 0, bool RightToLeft = false)
{
    /// <summary>The options of <paramref name="settings"/> (<see cref="TaskOptions.BookRotationQuarterTurns"/>, <see cref="TaskOptions.BookRightToLeft"/>).</summary>
    public static BookSplitOptions Of(ScanSettings settings) =>
        new(BookSplitter.NormalizedTurns(settings.TaskOptions.BookRotationQuarterTurns), settings.TaskOptions.BookRightToLeft);
}

/// <summary>What the search for the gutter found along one axis, in the analysis image's pixels.</summary>
/// <param name="Axis">The axis searched.</param>
/// <param name="Center">The middle of the gutter (continuous coordinates: pixel i spans [i, i + 1)).</param>
/// <param name="Confidence">As <see cref="GutterResult.Confidence"/>.</param>
/// <param name="Kind">Shadow or margin.</param>
public sealed record GutterCandidate(GutterAxis Axis, double Center, double Confidence, GutterKind Kind);

/// <summary>
/// Split the facing pages of an open book or magazine scanned on the glass. The gutter is found on a
/// gray copy at the analysis resolution (<see cref="GrayImage.AnalysisDpi"/>, at most
/// <see cref="AnalysisMaxSide"/> pixels long), from two profiles along each axis over the middle of the
/// other one: the mean brightness, and the share of neighbouring pixels across it that differ by an ink
/// edge (text). The spine's shadow is a narrow, smooth dip in the brightness with no text in it; without
/// one, the gutter is the blank run between the text of the two pages. Cautious by design: the text
/// lines of a spread run across the gutter, a shadow needs text beside it and a margin text on both
/// sides, and anything unclear leaves the spread whole for the user to split by hand.
/// </summary>
public static class BookSplitter
{
    /// <summary>The longest side of the analysis image, in pixels.</summary>
    public const int AnalysisMaxSide = 1000;
    /// <summary>The profiles leave out this share of the other axis at each end (the book's edges, the lid).</summary>
    public const double BandFraction = 0.1;
    /// <summary>The profiles are smoothed over this many inches…</summary>
    public const double SmoothInches = 0.05;
    /// <summary>…and at least this many pixels.</summary>
    public const int MinSmoothPixels = 3;
    /// <summary>The gutter is looked for from this share of the axis…</summary>
    public const double SearchFrom = 0.25;
    /// <summary>…to this one.</summary>
    public const double SearchTo = 0.75;
    /// <summary>Two neighbouring pixels differing by more than this many gray levels are an ink edge.</summary>
    public const int InkStep = 24;
    /// <summary>
    /// The paper level of a scan: this share of the positions in the search window are darker. A high
    /// share, so the paper of the margins counts, not the text.
    /// </summary>
    public const double PaperLevelPercentile = 0.9;
    /// <summary>The shadow darkens the paper by at least this share of its brightness.</summary>
    public const double MinShadowDepth = 0.08;
    /// <summary>
    /// The shadow is at least this many inches wide where it darkens the paper by half the least depth (a
    /// page's edge alone is a thin line; inside a shadow it is part of the shadow)…
    /// </summary>
    public const double MinShadowWidthInches = 0.08;
    /// <summary>…and at most this share of the axis at half its own depth (a dark picture is wider).</summary>
    public const double MaxShadowWidthFraction = 0.12;
    /// <summary>
    /// The text level of a scan: this share of the positions along the axis hold less text. A high
    /// share, so a spread with one page blank (less than half of it text) still has one.
    /// </summary>
    public const double TextLevelPercentile = 0.8;
    /// <summary>At the bottom of the shadow there is at most this share of the text level.</summary>
    public const double ShadowInkFraction = 0.5;
    /// <summary>
    /// The pages of a spread mirror each other: with text on both sides, the shadow lies within this
    /// share of the axis of the middle of the spread's text (a dark picture or a crease inside one page
    /// does not).
    /// </summary>
    public const double ShadowSymmetryFraction = 0.12;
    /// <summary>With text on one side only (the facing page blank), the shadow is at least this deep.</summary>
    public const double OneSidedShadowDepth = 0.15;
    /// <summary>A stretch beside the gutter holds text when at least this share of the text level is there.</summary>
    public const double MarginInkFraction = 0.25;
    /// <summary>
    /// A margin is blank: less than this share of the text level (a line or two reaching into it, as
    /// ragged lines do, is not blank yet).
    /// </summary>
    public const double MarginBlankFraction = 0.1;
    /// <summary>
    /// The blank run between the pages' text is at least this many inches long: two inner margins,
    /// longer than the gap between the columns of one page.
    /// </summary>
    public const double MinMarginInches = 0.6;
    /// <summary>
    /// The pages of a spread mirror each other, so the blank run lies in the middle of the spread's
    /// text: its middle is at most this share of its length from the middle of the text (a centered
    /// title page facing a page of text is not).
    /// </summary>
    public const double MarginSymmetryFraction = 0.25;
    /// <summary>The blank run is paper: at least this share of the brightness around it (not a smooth picture).</summary>
    public const double MarginPaperFraction = 0.97;
    /// <summary>Text is looked for within this many inches beside the gutter…</summary>
    public const double SideInches = 1.5;
    /// <summary>…and is there when this share of that stretch holds some.</summary>
    public const double MinSideInk = 0.25;
    /// <summary>The bottom of a shadow: within this share of its depth from its darkest point.</summary>
    public const double BottomFraction = 0.1;
    /// <summary>
    /// Which way the text runs is judged with this many inches either side of a gutter blanked out: the
    /// gutter's own dark line, running along it, is no line of text.
    /// </summary>
    public const double LineCheckBandInches = 0.3;
    /// <summary>A gutter cutting the scan's longer side counts this many times its confidence (spreads are wider than tall).</summary>
    public const double LongSideBonus = 1.25;

    // MARK: - Finding the gutter

    /// <summary>
    /// Where <paramref name="image"/>, scanned at <paramref name="dpi"/>, holds the gutter of an open
    /// book, in its pixels; null when it is not clear (a single page, a picture across the middle, a
    /// dark background): the spread then stays whole.
    /// </summary>
    public static GutterResult? FindGutter(RgbaImage image, int dpi)
    {
        var gray = AnalysisImage(image, dpi);
        if (FindGutter(gray) is not { } found) return null;
        return AtScale(found, image.Width, image.Height, gray.Scale);
    }

    /// <summary>The gray copy the gutter is looked for in: the analysis resolution, at most <see cref="AnalysisMaxSide"/> long.</summary>
    public static GrayImage AnalysisImage(RgbaImage image, int dpi)
    {
        var gray = GrayImage.From(image, dpi);
        int longest = Math.Max(gray.Width, gray.Height);
        if (longest <= AnalysisMaxSide) return gray;
        double f = (double)AnalysisMaxSide / longest;
        int w = Math.Max(1, (int)Math.Round(gray.Width * f, MidpointRounding.AwayFromZero));
        int h = Math.Max(1, (int)Math.Round(gray.Height * f, MidpointRounding.AwayFromZero));
        return gray.Downsampled(w, h);
    }

    /// <summary>
    /// The gutter found on <paramref name="gray"/> (an analysis image), in its pixels: the clearer of
    /// the two axes (<see cref="Candidates"/>), the axis cutting the longer side counting
    /// <see cref="LongSideBonus"/> times; null when neither has one.
    /// </summary>
    public static GutterCandidate? FindGutter(GrayImage gray)
    {
        GutterCandidate? best = null;
        double bestScore = 0;
        foreach (var candidate in Candidates(gray))
        {
            bool longSide = candidate.Axis == GutterAxis.Vertical ? gray.Width > gray.Height : gray.Height > gray.Width;
            double score = candidate.Confidence * (longSide ? LongSideBonus : 1);
            if (best is null || score > bestScore)
            {
                best = candidate;
                bestScore = score;
            }
        }
        return best;
    }

    /// <summary>
    /// The gutter each axis holds, in the analysis image's pixels: the deepest shadow that passes, else
    /// the longest margin that passes, each only when the text does not run along it (the text of a
    /// spread runs across its gutter; <see cref="RunsAlongText"/>); nothing for an axis that has neither.
    /// Vertical first.
    /// </summary>
    public static IReadOnlyList<GutterCandidate> Candidates(GrayImage gray)
    {
        var found = new List<GutterCandidate>(2);
        foreach (var axis in new[] { GutterAxis.Vertical, GutterAxis.Horizontal })
        {
            var profile = Profile(gray, axis);
            if (FindShadow(profile, gray.Dpi) is { } shadow && !RunsAlongText(gray, shadow))
            {
                found.Add(shadow);
            }
            else if (FindMargin(profile, gray.Dpi) is { } margin && !RunsAlongText(gray, margin))
            {
                found.Add(margin);
            }
        }
        return found;
    }

    /// <summary>
    /// Whether the lines of text on <paramref name="gray"/> run along <paramref name="candidate"/>, judged
    /// with <see cref="LineCheckBandInches"/> either side of it blanked out to paper
    /// (<see cref="DocumentGeometry.EstimateTextLayout"/>): lines running down the page lie along a
    /// vertical cut, lines across it along a horizontal one. A section gap or a fold across a single
    /// page runs along its lines; a spine runs across them. Unclear text tells nothing.
    /// </summary>
    public static bool RunsAlongText(GrayImage gray, GutterCandidate candidate)
    {
        bool vertical = candidate.Axis == GutterAxis.Vertical;
        int length = vertical ? gray.Width : gray.Height;
        double band = LineCheckBandInches * gray.Dpi;
        int from = Math.Max(0, (int)Math.Floor(candidate.Center - band));
        int to = Math.Min(length, (int)Math.Ceiling(candidate.Center + band));
        var pixels = (byte[])gray.Pixels.Clone();
        byte paper = PaperValue(gray);
        for (int i = from; i < to; i++)
        {
            if (vertical)
            {
                for (int y = 0; y < gray.Height; y++) pixels[y * gray.Width + i] = paper;
            }
            else
            {
                Array.Fill(pixels, paper, i * gray.Width, gray.Width);
            }
        }
        var layout = DocumentGeometry.EstimateTextLayout(new GrayImage(gray.Width, gray.Height, pixels, gray.Dpi, gray.Scale));
        if (!layout.IsConfident) return false;
        return vertical ? layout.Axis == TextAxis.Vertical : layout.Axis == TextAxis.Horizontal;
    }

    /// <summary>The paper of <paramref name="gray"/>: the gray value that nine pixels in ten are no brighter than.</summary>
    private static byte PaperValue(GrayImage gray)
    {
        var counts = new int[256];
        foreach (byte v in gray.Pixels) counts[v]++;
        long target = (long)(0.9 * gray.Pixels.Length);
        long seen = 0;
        for (int v = 0; v < 256; v++)
        {
            seen += counts[v];
            if (seen >= target) return (byte)v;
        }
        return 255;
    }

    /// <summary>The brightness and text profiles along one axis (<see cref="Profile"/>).</summary>
    /// <param name="Brightness">The mean gray of each column (or row) over the middle band, smoothed.</param>
    /// <param name="Ink">The share of its pixels across the band that are an ink edge, smoothed.</param>
    public sealed record GutterProfile(GutterAxis Axis, double[] Brightness, double[] Ink)
    {
        public int Length => Brightness.Length;
    }

    /// <summary>
    /// The profiles along <paramref name="axis"/>: for each column (vertical) or row (horizontal) over the
    /// middle of the other axis (leaving out <see cref="BandFraction"/> at each end), the mean gray and
    /// the share of neighbouring pairs across the axis that differ by more than <see cref="InkStep"/>,
    /// both smoothed over <see cref="SmoothInches"/>.
    /// </summary>
    public static GutterProfile Profile(GrayImage gray, GutterAxis axis)
    {
        bool vertical = axis == GutterAxis.Vertical;
        int length = vertical ? gray.Width : gray.Height;
        int across = vertical ? gray.Height : gray.Width;
        int from = (int)Math.Floor(across * BandFraction);
        int to = Math.Max(from + 2, (int)Math.Ceiling(across * (1 - BandFraction)));
        to = Math.Min(to, across);
        from = Math.Max(0, Math.Min(from, to - 2));
        var brightness = new double[length];
        var ink = new double[length];
        var p = gray.Pixels;
        int w = gray.Width;
        for (int i = 0; i < length; i++)
        {
            long sum = 0;
            int edges = 0;
            for (int j = from; j < to; j++)
            {
                int value = vertical ? p[j * w + i] : p[i * w + j];
                sum += value;
                if (j + 1 < to)
                {
                    int next = vertical ? p[(j + 1) * w + i] : p[i * w + j + 1];
                    if (Math.Abs(next - value) > InkStep) edges++;
                }
            }
            brightness[i] = (double)sum / (to - from);
            ink[i] = to - from > 1 ? (double)edges / (to - from - 1) : 0;
        }
        int box = SmoothWidth(gray.Dpi);
        return new GutterProfile(axis, Smoothed(brightness, box), Smoothed(ink, box));
    }

    /// <summary>The smoothing box: <see cref="SmoothInches"/> at <paramref name="dpi"/>, at least <see cref="MinSmoothPixels"/>, odd.</summary>
    public static int SmoothWidth(double dpi)
    {
        int box = Math.Max(MinSmoothPixels, (int)Math.Round(SmoothInches * dpi, MidpointRounding.AwayFromZero));
        return box % 2 == 0 ? box + 1 : box;
    }

    /// <summary>The mean of each value and its neighbours in a box of <paramref name="box"/> (odd), the box cut short at the ends.</summary>
    public static double[] Smoothed(double[] values, int box)
    {
        int n = values.Length, half = box / 2;
        var prefix = new double[n + 1];
        for (int i = 0; i < n; i++) prefix[i + 1] = prefix[i] + values[i];
        var result = new double[n];
        for (int i = 0; i < n; i++)
        {
            int a = Math.Max(0, i - half), b = Math.Min(n, i + half + 1);
            result[i] = (prefix[b] - prefix[a]) / (b - a);
        }
        return result;
    }

    /// <summary>
    /// The deepest shadow in the search window that passes: a darkest point with nothing darker within
    /// half the widest shadow, at least <see cref="MinShadowDepth"/> darker than the paper beside it (the
    /// lower of the brightest points within that reach on either side, and no brighter than the window's
    /// <see cref="PaperLevelPercentile"/> percentile), a valley at least <see cref="MinShadowWidthInches"/>
    /// wide where it darkens the paper by half of <see cref="MinShadowDepth"/> and at most
    /// <see cref="MaxShadowWidthFraction"/> wide at half its own depth, no more than
    /// <see cref="ShadowInkFraction"/> of the text level at its bottom, and text beside it (within
    /// <see cref="SideInches"/>) on at least one side. Its centre is the middle of its
    /// bottom (within <see cref="BottomFraction"/> of its depth); with text on both sides of it (anywhere)
    /// that centre lies within <see cref="ShadowSymmetryFraction"/> of the axis of the middle of the
    /// spread's text, and with text on one side only the shadow is at least
    /// <see cref="OneSidedShadowDepth"/> deep. Null when none passes.
    /// </summary>
    public static GutterCandidate? FindShadow(GutterProfile profile, double dpi)
    {
        var m = profile.Brightness;
        var e = profile.Ink;
        int n = profile.Length;
        if (n < 8) return null;
        var (lo, hi) = Window(n);
        double paper = Percentile(m, lo, hi + 1, PaperLevelPercentile);
        if (paper <= 0) return null;
        double textLevel = TextLevel(e);
        double? textMiddle = TextMiddle(e, textLevel);
        int reach = Math.Max(1, (int)(MaxShadowWidthFraction * n / 2));
        double minWidth = MinShadowWidthInches * dpi, maxWidth = MaxShadowWidthFraction * n;
        GutterCandidate? best = null;
        for (int x = lo; x <= hi; x++)
        {
            // The darkest point around: nothing darker within reach, and the first of a flat bottom.
            bool lowest = true;
            for (int j = Math.Max(0, x - reach); j <= Math.Min(n - 1, x + reach) && lowest; j++)
            {
                if (m[j] < m[x] || (j < x && m[j] == m[x])) lowest = false;
            }
            if (!lowest) continue;
            // The paper beside the dip: the brightest within reach on either side, the lower of the two.
            double leftShoulder = 0, rightShoulder = 0;
            for (int j = Math.Max(0, x - reach); j < x; j++) leftShoulder = Math.Max(leftShoulder, m[j]);
            for (int j = x + 1; j <= Math.Min(n - 1, x + reach); j++) rightShoulder = Math.Max(rightShoulder, m[j]);
            double level = Math.Min(paper, Math.Min(leftShoulder, rightShoulder));
            if (level <= 0) continue;
            double depth = (level - m[x]) / level;
            if (depth < MinShadowDepth) continue;
            double half = m[x] + (level - m[x]) / 2;
            int left = x, right = x;
            while (left > 0 && m[left - 1] < half) left--;
            while (right < n - 1 && m[right + 1] < half) right++;
            // A dip that runs to the end of the profile is no valley.
            if (left == 0 || right == n - 1) continue;
            if (right - left + 1 > maxWidth) continue;
            // The width of the whole shadow, where it darkens the paper by half the least depth: a thin
            // dark line (the pages' edges) at its bottom does not make it narrow.
            double broad = level * (1 - MinShadowDepth / 2);
            int broadLeft = x, broadRight = x;
            while (broadLeft > 0 && m[broadLeft - 1] < broad) broadLeft--;
            while (broadRight < n - 1 && m[broadRight + 1] < broad) broadRight++;
            if (broadRight - broadLeft + 1 < minWidth) continue;
            if (e[x] > ShadowInkFraction * textLevel) continue;
            double floor = m[x] + BottomFraction * (level - m[x]);
            int bottomLeft = x, bottomRight = x;
            while (bottomLeft > 0 && m[bottomLeft - 1] <= floor) bottomLeft--;
            while (bottomRight < n - 1 && m[bottomRight + 1] <= floor) bottomRight++;
            double center = (bottomLeft + bottomRight + 1) / 2.0;
            if (!HasInk(e, left, -1, textLevel, dpi) && !HasInk(e, right, 1, textLevel, dpi)) continue;
            bool textBefore = HasText(e, 0, left, textLevel, dpi), textAfter = HasText(e, right + 1, n, textLevel, dpi);
            if (textBefore && textAfter)
            {
                if (textMiddle is not { } middle || Math.Abs(center - middle) > ShadowSymmetryFraction * n) continue;
            }
            else if (depth < OneSidedShadowDepth)
            {
                continue;
            }
            if (best is null || depth > best.Confidence)
            {
                best = new GutterCandidate(profile.Axis, center, depth, GutterKind.Shadow);
            }
        }
        return best;
    }

    /// <summary>
    /// The longest blank run between the pages' text that passes: text below
    /// <see cref="MarginBlankFraction"/> of the text level, at least <see cref="MinMarginInches"/> long, its
    /// middle in the search window and in the middle of the spread's text (within
    /// <see cref="MarginSymmetryFraction"/> of its length of the middle between the first and the last
    /// text), as bright as paper (<see cref="MarginPaperFraction"/> of the window's median), with text on
    /// both sides. Its centre is the middle of the run; its confidence the run's share of the axis. Null
    /// when none passes (or the scan holds no text).
    /// </summary>
    public static GutterCandidate? FindMargin(GutterProfile profile, double dpi)
    {
        var m = profile.Brightness;
        var e = profile.Ink;
        int n = profile.Length;
        if (n < 8) return null;
        double textLevel = TextLevel(e);
        if (textLevel <= 0) return null;
        var (lo, hi) = Window(n);
        double median = Median(m, lo, hi + 1);
        double threshold = MarginBlankFraction * textLevel;
        if (TextMiddle(e, textLevel) is not { } textMiddle) return null;
        int start = (int)Math.Round(n * BandFraction, MidpointRounding.AwayFromZero);
        int end = (int)Math.Round(n * (1 - BandFraction), MidpointRounding.AwayFromZero);
        GutterCandidate? best = null;
        int i = start;
        while (i < end)
        {
            if (e[i] >= threshold)
            {
                i++;
                continue;
            }
            int runStart = i;
            while (i < end && e[i] < threshold) i++;
            int runEnd = i - 1;
            int length = runEnd - runStart + 1;
            double center = (runStart + runEnd + 1) / 2.0;
            if (length < MinMarginInches * dpi || center < lo || center > hi + 1) continue;
            if (Math.Abs(center - textMiddle) > MarginSymmetryFraction * length) continue;
            double sum = 0;
            for (int k = runStart; k <= runEnd; k++) sum += m[k];
            if (sum / length < MarginPaperFraction * median) continue;
            if (!HasInk(e, runStart, -1, textLevel, dpi) || !HasInk(e, runEnd, 1, textLevel, dpi)) continue;
            double confidence = (double)length / n;
            if (best is null || confidence > best.Confidence)
            {
                best = new GutterCandidate(profile.Axis, center, confidence, GutterKind.Margin);
            }
        }
        return best;
    }

    /// <summary>
    /// The middle of the spread's text along the profile: halfway between its first and its last position
    /// holding text (<see cref="MarginInkFraction"/> of the text level); null when it holds none.
    /// </summary>
    private static double? TextMiddle(double[] ink, double textLevel)
    {
        if (textLevel <= 0) return null;
        double inked = MarginInkFraction * textLevel;
        int first = Array.FindIndex(ink, v => v >= inked), last = Array.FindLastIndex(ink, v => v >= inked);
        return first < 0 ? null : (first + last + 1) / 2.0;
    }

    /// <summary>The search window along an axis of <paramref name="n"/> pixels: <see cref="SearchFrom"/> to <see cref="SearchTo"/>, inclusive.</summary>
    private static (int Lo, int Hi) Window(int n) =>
        ((int)Math.Ceiling(n * SearchFrom), Math.Min(n - 1, (int)Math.Floor(n * SearchTo)));

    /// <summary>
    /// The text level of the profile over its middle (leaving out <see cref="BandFraction"/> at each end):
    /// its <see cref="TextLevelPercentile"/> percentile.
    /// </summary>
    private static double TextLevel(double[] ink)
    {
        int n = ink.Length;
        int a = (int)Math.Round(n * BandFraction, MidpointRounding.AwayFromZero);
        int b = Math.Min(n, Math.Max(a + 1, (int)Math.Round(n * (1 - BandFraction), MidpointRounding.AwayFromZero)));
        return Percentile(ink, a, b, TextLevelPercentile);
    }

    /// <summary>
    /// Whether the stretch of <see cref="SideInches"/> beside <paramref name="from"/> (before it for
    /// <paramref name="direction"/> −1, after it for 1) holds text: at least <see cref="MinSideInk"/> of it
    /// at or above <see cref="MarginInkFraction"/> of the text level.
    /// </summary>
    private static bool HasInk(double[] ink, int from, int direction, double textLevel, double dpi)
    {
        if (textLevel <= 0) return false;
        int span = Math.Max(1, (int)Math.Round(SideInches * dpi, MidpointRounding.AwayFromZero));
        double threshold = MarginInkFraction * textLevel;
        int counted = 0, inked = 0;
        for (int k = 1; k <= span; k++)
        {
            int i = from + direction * k;
            if (i < 0 || i >= ink.Length) break;
            counted++;
            if (ink[i] >= threshold) inked++;
        }
        return counted > 0 && inked >= MinSideInk * span;
    }

    /// <summary>
    /// Whether ink[from..to) holds text anywhere: at least as many positions at or above
    /// <see cref="MarginInkFraction"/> of the text level as <see cref="HasInk"/> asks for beside a gutter.
    /// </summary>
    private static bool HasText(double[] ink, int from, int to, double textLevel, double dpi)
    {
        if (textLevel <= 0) return false;
        double threshold = MarginInkFraction * textLevel;
        int span = Math.Max(1, (int)Math.Round(SideInches * dpi, MidpointRounding.AwayFromZero));
        int inked = 0;
        for (int i = Math.Max(0, from); i < Math.Min(ink.Length, to); i++)
        {
            if (ink[i] >= threshold) inked++;
        }
        return inked >= MinSideInk * span;
    }

    /// <summary>The value of values[from..to) that a share <paramref name="share"/> of them lie below (sorted, at that index); 0 when empty.</summary>
    private static double Percentile(double[] values, int from, int to, double share)
    {
        if (to <= from) return 0;
        var sorted = new double[to - from];
        Array.Copy(values, from, sorted, 0, sorted.Length);
        Array.Sort(sorted);
        return sorted[Math.Min(sorted.Length - 1, (int)(share * sorted.Length))];
    }

    /// <summary>The median of values[from..to) (the mean of the middle two for an even count); 0 when empty.</summary>
    private static double Median(double[] values, int from, int to)
    {
        if (to <= from) return 0;
        var sorted = new double[to - from];
        Array.Copy(values, from, sorted, 0, sorted.Length);
        Array.Sort(sorted);
        int c = sorted.Length;
        return c % 2 == 1 ? sorted[c / 2] : (sorted[c / 2 - 1] + sorted[c / 2]) / 2;
    }

    /// <summary>
    /// <paramref name="candidate"/> (on an analysis image <paramref name="scale"/> times the size of the
    /// scan) as a cut in the scan's pixels, kept at least one pixel from either end.
    /// </summary>
    public static GutterResult AtScale(GutterCandidate candidate, int width, int height, double scale)
    {
        int length = candidate.Axis == GutterAxis.Vertical ? width : height;
        double s = scale > 0 ? scale : 1;
        int position = (int)Math.Round(candidate.Center / s, MidpointRounding.AwayFromZero);
        return new GutterResult(candidate.Axis, ClampPosition(position, length), candidate.Confidence, candidate.Kind);
    }

    /// <summary>A cut the user placed: at <paramref name="fraction"/> (0...1) of the axis of a scan <paramref name="width"/> × <paramref name="height"/>.</summary>
    public static GutterResult Manual(GutterAxis axis, double fraction, int width, int height)
    {
        int length = axis == GutterAxis.Vertical ? width : height;
        double f = double.IsFinite(fraction) ? Math.Clamp(fraction, 0, 1) : 0.5;
        int position = (int)Math.Round(f * length, MidpointRounding.AwayFromZero);
        return new GutterResult(axis, ClampPosition(position, length), 1, GutterKind.Manual);
    }

    private static int ClampPosition(int position, int length) => Math.Clamp(position, 1, Math.Max(1, length - 1));

    // MARK: - Splitting

    /// <summary>
    /// The two parts of <paramref name="image"/> cut at <paramref name="gutter"/>, as they lie on the scan:
    /// left then right, or top then bottom. Together they are exactly the scan.
    /// </summary>
    public static (RgbaImage First, RgbaImage Second) Halves(RgbaImage image, GutterResult gutter)
    {
        bool vertical = gutter.Axis == GutterAxis.Vertical;
        int length = vertical ? image.Width : image.Height;
        int cut = ClampPosition(gutter.Position, length);
        var first = vertical
            ? image.Cropped(new RectD(0, 0, cut, image.Height))
            : image.Cropped(new RectD(0, 0, image.Width, cut));
        var second = vertical
            ? image.Cropped(new RectD(cut, 0, image.Width - cut, image.Height))
            : image.Cropped(new RectD(0, cut, image.Width, image.Height - cut));
        if (first is null || second is null) throw new ArgumentException("The scan is too small to split.", nameof(image));
        return (first, second);
    }

    /// <summary>
    /// The pages of <paramref name="image"/> cut at <paramref name="gutter"/>, each turned
    /// <paramref name="rotationQuarterTurns"/> quarter turns clockwise, in reading order: by where they lie
    /// once turned, left before right (right before left with <paramref name="rightToLeft"/>), top before
    /// bottom. Each keeps the scan's resolution, so its paper size is right.
    /// </summary>
    public static IReadOnlyList<RgbaImage> Split(RgbaImage image, GutterResult gutter, int rotationQuarterTurns, bool rightToLeft)
    {
        var (first, second) = Halves(image, gutter);
        int turns = NormalizedTurns(rotationQuarterTurns);
        var a = first.RotatedQuarterTurns(turns);
        var b = second.RotatedQuarterTurns(turns);
        return FirstPartLeads(gutter.Axis, turns, rightToLeft) ? [a, b] : [b, a];
    }

    /// <summary>
    /// Whether the part before the cut (left, or top, on the scan) comes first once the spread is turned
    /// <paramref name="quarterTurns"/> quarter turns clockwise: when it then lies on the left (on the right
    /// with <paramref name="rightToLeft"/>), or on top.
    /// </summary>
    public static bool FirstPartLeads(GutterAxis axis, int quarterTurns, bool rightToLeft)
    {
        // Clockwise, left goes to the top, the top to the right, the right to the bottom: 0 left, 1 top, 2 right, 3 bottom.
        int place = ((axis == GutterAxis.Vertical ? 0 : 1) + NormalizedTurns(quarterTurns)) % 4;
        return place switch
        {
            0 => !rightToLeft,
            2 => rightToLeft,
            1 => true,
            _ => false,
        };
    }

    /// <summary>
    /// The quarter turns clockwise the spread was turned in all to make its pages upright: the book's
    /// rotation, and the turn reading the pages' text gave them (<see cref="UprightTurn"/>) when the two
    /// agree, or when only one page was turned (the other unread, blank or unsure). Pages turned
    /// different ways tell nothing.
    /// </summary>
    public static int TotalTurns(int rotationQuarterTurns, UprightTurn? first, UprightTurn? second)
    {
        int? a = first is { Undone: false } ta ? ta.QuarterTurns : null;
        int? b = second is { Undone: false } tb ? tb.QuarterTurns : null;
        int extra = a == b ? a ?? 0
            : a is null ? b!.Value
            : b is null ? a.Value
            : 0;
        return NormalizedTurns(rotationQuarterTurns + extra);
    }

    /// <summary><paramref name="quarterTurns"/> as 0 to 3.</summary>
    public static int NormalizedTurns(int quarterTurns) => ((quarterTurns % 4) + 4) % 4;
}

/// <summary>What the page strip says about a page cut from a spread (<see cref="BookPages.Labels"/>).</summary>
/// <param name="Label">The badge: "2 · left", "2 · right", "2 · not split".</param>
/// <param name="Help">The badge spelled out for screen readers: "Spread 2, left page", "Spread 2, not split".</param>
public sealed record BookPageLabel(string Label, string Help);

/// <summary>
/// What the page strip, the status and the inspector say about books and magazines: a label on each page
/// cut from a spread, the page's split and join actions, and the notes after a scan or a split.
/// </summary>
public static class BookPages
{
    /// <summary>
    /// Scans with these settings capture one side of each sheet (<see cref="DocumentSides.Effective"/>
    /// is off): facing pages are split only then. The pages of a two-sided scan are paired by sheet and
    /// side, so they are kept as scanned.
    /// </summary>
    public static bool ScansOneSide(ScanSettings settings) => DocumentSides.Effective(settings, null) == DuplexMode.Off;

    /// <summary>The badge of a spread kept as one page; the page offers Split… next to it.</summary>
    public const string NotSplitBadge = "Not split";

    /// <summary>Why Split facing pages is greyed out while both sides of each sheet are scanned.</summary>
    public const string NotWithTwoSidedReason = "Not with two-sided";

    /// <summary>
    /// The badge and its spoken form for every page of the queue, in one pass: "2 · left" and "2 · right"
    /// ("Spread 2, left page") for the pages cut from the second spread in the queue, each page keeping
    /// the side it was given when the spread was cut (<see cref="SpreadPart.IsLeft"/>), wherever it is
    /// moved and whatever the reading order is set to later; "2 · not split" ("Spread 2, not split") for
    /// a spread kept whole; null for a page not scanned as part of a spread.
    /// </summary>
    public static IReadOnlyList<BookPageLabel?> Labels(IReadOnlyList<ScannedPage> pages)
    {
        var numbers = new Dictionary<Guid, int>();
        var result = new BookPageLabel?[pages.Count];
        for (int i = 0; i < pages.Count; i++)
        {
            if (pages[i].Spread is not { } part) continue;
            if (!numbers.TryGetValue(part.SpreadId, out int number))
            {
                number = numbers.Count + 1;
                numbers[part.SpreadId] = number;
            }
            if (part.IsWhole)
            {
                result[i] = new BookPageLabel($"{number} · not split", $"Spread {number}, not split");
                continue;
            }
            string side = part.IsLeft ? "left" : "right";
            result[i] = new BookPageLabel($"{number} · {side}", $"Spread {number}, {side} page");
        }
        return result;
    }

    /// <summary>The badge of the page at <paramref name="index"/> (<see cref="Labels"/>); null for a page not scanned as part of a spread.</summary>
    public static string? Label(IReadOnlyList<ScannedPage> pages, int index) =>
        index < 0 || index >= pages.Count || pages[index].Spread is null ? null : Labels(pages)[index]?.Label;

    /// <summary>The badge spelled out for screen readers ("Spread 2, left page").</summary>
    public static string? Help(IReadOnlyList<ScannedPage> pages, int index) =>
        index < 0 || index >= pages.Count || pages[index].Spread is null ? null : Labels(pages)[index]?.Help;

    /// <summary>
    /// The pages that take the place of a spread's pages in the queue when it is joined or split again:
    /// <paramref name="fresh"/> (<see cref="PageProcessor.ProcessSpread"/>), carrying what the user decided
    /// about <paramref name="queued"/> (the spread's pages in the queue, in queue order). When the spread
    /// was split and is split again, each new page replaces the queued page of the same part, with its
    /// document break, document name and keep or skip, and a part the user removed from the queue stays
    /// out. Otherwise (joined, or a whole spread split) every new page is used: the first takes the first
    /// queued page's document break and the first document name among them, and every one the keep or
    /// skip they share (automatic when they differ).
    /// </summary>
    public static IReadOnlyList<ScannedPage> ReplacementPages(IReadOnlyList<ScannedPage> queued, IReadOnlyList<ScannedPage> fresh)
    {
        if (queued.Count == 0) return fresh;
        static bool IsCut(ScannedPage page) => page.Spread is { Part: not null };
        if (queued.All(IsCut) && fresh.All(IsCut))
        {
            var kept = new List<ScannedPage>();
            foreach (var page in fresh)
            {
                if (queued.FirstOrDefault(old => old.Spread!.Part == page.Spread!.Part) is not { } old) continue;
                kept.Add(page.WithDocumentBreak(old.DocumentBreak).WithDocumentLabel(old.DocumentLabel).WithInclusion(old.Inclusion));
            }
            return kept;
        }
        var first = queued[0];
        var inclusion = queued.All(page => page.Inclusion == first.Inclusion) ? first.Inclusion : PageInclusion.Automatic;
        string? label = queued.Select(page => page.DocumentLabel).FirstOrDefault(name => name is not null);
        return fresh.Select((page, i) => i == 0
                ? page.WithDocumentBreak(first.DocumentBreak).WithDocumentLabel(label).WithInclusion(inclusion)
                : page.WithInclusion(inclusion))
            .ToList();
    }

    /// <summary>"Split this spread…" for a spread kept whole, "Change the split…" for a page cut from one; null for other pages.</summary>
    public static string? SplitActionLabel(ScannedPage page) => page.Spread switch
    {
        null => null,
        { IsWhole: true } => "Split this spread…",
        _ => "Change the split…",
    };

    /// <summary>"Join the two pages" for a page cut from a spread; null for other pages.</summary>
    public static string? JoinActionLabel(ScannedPage page) =>
        page.Spread is { IsWhole: false } ? "Join the two pages" : null;

    /// <summary>
    /// The status after a scan's pages were queued, when spreads were split or kept whole: " 2 spreads
    /// split into pages." and " The spine of 1 spread was not found: it was added as one page (Split… on
    /// it splits it)." (leading space; empty for no spread).
    /// </summary>
    public static string ScanNote(IEnumerable<ScannedPage> added)
    {
        var parts = added.Select(p => p.Spread).OfType<SpreadPart>().ToList();
        int split = parts.Where(p => !p.IsWhole).Select(p => p.SpreadId).Distinct().Count();
        int whole = parts.Where(p => p.IsWhole).Select(p => p.SpreadId).Distinct().Count();
        string note = split == 0 ? "" : $" {split} spread{(split == 1 ? "" : "s")} split into pages.";
        if (whole > 0)
        {
            note += whole == 1
                ? " The spine of 1 spread was not found: it was added as one page (Split… on it splits it)."
                : $" The spine of {whole} spreads was not found: they were added as one page each (Split… on one splits it).";
        }
        return note;
    }

    /// <summary>"Spread 2 is split into two pages." or "Spread 2 is one page again."</summary>
    public static string SplitNote(int spreadNumber, bool split) =>
        split ? $"Spread {spreadNumber} is split into two pages." : $"Spread {spreadNumber} is one page again.";

    /// <summary>The choices of the book's rotation (quarter turns clockwise), as the inspector lists them.</summary>
    public static IReadOnlyList<int> RotationChoices { get; } = [0, 1, 2, 3];

    /// <summary>"As scanned", "90° clockwise", "180°", "90° counterclockwise".</summary>
    public static string RotationLabel(int quarterTurns) => BookSplitter.NormalizedTurns(quarterTurns) switch
    {
        1 => "90° clockwise",
        2 => "180°",
        3 => "90° counterclockwise",
        _ => "As scanned",
    };

    /// <summary>
    /// The tooltip of "Split facing pages": why it is off for copies, receipts, scans saved at once and
    /// two-sided scans (those show <see cref="NotWithTwoSidedReason"/> next to it), else what it does.
    /// </summary>
    public static string Hint(ScanSettings settings)
    {
        var flow = TaskCatalog.FlowOf(settings);
        if (flow == TaskFlowKind.Copy) return "Copies print every page as scanned: spreads are not split.";
        if (flow == TaskFlowKind.ReceiptSplit) return "Receipts are found on the glass one by one.";
        if (!settings.DocumentMultiPage) return "Only for pages collected before saving: a scan saved at once is kept as scanned.";
        if (!ScansOneSide(settings)) return "Only for one side of each sheet: pages scanned on both sides are kept as scanned.";
        return "Each book scan becomes two pages, cut at the spine.";
    }
}
