using System.Text;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/OCRText.swift: same rules, same numbers, same text.

/// <summary>
/// The recognized text of one page: the lines as the OCR engine returned them and the page's
/// size in points (any unit works, as long as width and height share it: it only sets how far
/// across counts against how far down).
/// </summary>
public sealed record OcrPage(IReadOnlyList<OcrLine> Lines, double WidthPoints, double HeightPoints)
{
    /// <summary>A page <paramref name="pixelWidth"/> × <paramref name="pixelHeight"/> pixels scanned at <paramref name="dpi"/>.</summary>
    public static OcrPage Of(IReadOnlyList<OcrLine> lines, int pixelWidth, int pixelHeight, int dpi)
    {
        double scale = 72.0 / Math.Max(dpi, 1);
        return new OcrPage(lines, pixelWidth * scale, pixelHeight * scale);
    }
}

/// <summary>Lines of text that belong together, in reading order.</summary>
public sealed record OcrParagraph(IReadOnlyList<OcrLine> Lines)
{
    /// <summary>The lines as running text, keeping the line breaks that mean something (<see cref="OcrText.ParagraphText"/>).</summary>
    public string Text => OcrText.ParagraphText(Lines);
}

/// <summary>
/// Turns the lines an OCR engine found on a page into text a person reads: in reading order,
/// split into paragraphs. Shared by the text file, the Word document and Copy Text.
///
/// Reading order: the page is cut along an empty gap, across or down, again and again (a
/// recursive X-Y cut): first along the widest gap across the page when it is at least
/// <see cref="BlockGap"/> line heights tall (between blocks: the upper one is read first), else
/// along the widest gap down the page when it is at least <see cref="ColumnGap"/> line heights
/// wide and the two sides are columns of text, two lines or more each (the left one first),
/// else along any gap across the page. The two sides are a table instead (dishes and their
/// prices) when most lines on each side share their row with a line on the other side and the
/// gap is at least as wide as the narrower side's lines: a table is read row by row. Lines that
/// share a row and have no wide gap between them are one line of text, read left to right;
/// pieces of one row further apart (a price after a dish, a cell of a table) are kept on the
/// row, separated by a tab.
///
/// Paragraphs: a new one starts where the text jumps up (the next column), where the gap above
/// a line is clearly wider than the usual gap (the smaller of the page's median gap and the gaps
/// next to it), where its left edge moves by more than a fifth of the page, and where a line is
/// indented against the one before; lines centred on each other (a heading, a letterhead) are
/// neither indented nor moved. In a paragraph's text a line that wrapped is joined to the next
/// with a space, and a line that ends short (an address, a list, a table's row) keeps its break.
/// </summary>
public static class OcrText
{
    /// <summary>A gap down the page this many line heights wide separates columns, and pieces of one row.</summary>
    public const double ColumnGap = 2.0;
    /// <summary>A gap across the page this many line heights tall separates blocks before columns are looked for.</summary>
    public const double BlockGap = 1.5;
    /// <summary>Side by side, row by row, with a gap at least this share of the narrower side's line width: a table.</summary>
    public const double TableGapShare = 1.0;
    /// <summary>Lines overlapping by this share of the lower one's height are on the same row.</summary>
    public const double SameRowOverlap = 0.5;
    /// <summary>A gap above a line wider than this many line heights (at least) starts a paragraph.</summary>
    public const double ParagraphGap = 0.75;
    /// <summary>…or wider than this many times the usual gap between lines.</summary>
    public const double ParagraphGapFactor = 1.5;
    /// <summary>A line starting this many line heights right of the one before is indented: a new paragraph.</summary>
    public const double IndentLines = 1.0;
    /// <summary>A left edge moving by this share of the page width starts a paragraph.</summary>
    public const double LeftEdgeShift = 0.2;
    /// <summary>A line ending this share of the page width before the paragraph's longest line keeps its line break.</summary>
    public const double ShortLineShare = 0.15;
    /// <summary>Lines whose centres are this many line heights apart, or less, are centred on each other.</summary>
    public const double CentredLines = 0.25;
    /// <summary>A line starting this many line heights above the one before jumps to the next column.</summary>
    public const double JumpLines = 0.5;
    /// <summary>What separates the pieces of one row that are far apart.</summary>
    public const string CellSeparator = "\t";

    // MARK: Reading order

    /// <summary>
    /// The lines in reading order. Lines of one row become one line (its box is theirs together,
    /// its confidence their lowest); empty lines are dropped. <paramref name="pageWidth"/> and
    /// <paramref name="pageHeight"/> are the page's size in any one unit.
    /// </summary>
    public static IReadOnlyList<OcrLine> ReadingOrder(IReadOnlyList<OcrLine> lines, double pageWidth = 1,
                                                     double pageHeight = 1)
    {
        double w = pageWidth > 0 ? pageWidth : 1, h = pageHeight > 0 ? pageHeight : 1;
        var items = new List<Item>();
        foreach (var line in lines)
        {
            string text = CleanLine(line.Text);
            var box = line.BoundingBox.Standardized;
            if (text.Length == 0 || box.Width <= 0 || box.Height <= 0) continue;
            items.Add(new Item(line with { Text = text }, items.Count, box.MinX * w, (1 - box.MaxY) * h,
                               box.MaxX * w, (1 - box.MinY) * h));
        }
        var output = new List<OcrLine>();
        Cut(items, output);
        return output;
    }

    /// <summary>The paragraphs of a page: its lines in reading order, then split.</summary>
    public static IReadOnlyList<OcrParagraph> Paragraphs(OcrPage page) =>
        Paragraphs(ReadingOrder(page.Lines, page.WidthPoints, page.HeightPoints), page.WidthPoints, page.HeightPoints);

    /// <summary>
    /// <paramref name="ordered"/> (lines already in reading order, as <see cref="ReadingOrder"/>
    /// returns them) split into paragraphs; the order is kept.
    /// </summary>
    public static IReadOnlyList<OcrParagraph> Paragraphs(IReadOnlyList<OcrLine> ordered, double pageWidth = 1,
                                                         double pageHeight = 1)
    {
        double w = pageWidth > 0 ? pageWidth : 1, h = pageHeight > 0 ? pageHeight : 1;
        var items = new List<Item>();
        foreach (var line in ordered)
        {
            var box = line.BoundingBox.Standardized;
            items.Add(new Item(line, items.Count, box.MinX * w, (1 - box.MaxY) * h, box.MaxX * w, (1 - box.MinY) * h));
        }
        var paragraphs = new List<OcrParagraph>();
        if (items.Count == 0) return paragraphs;

        double lineHeight = Median(items.Select(i => i.Height));
        // gaps[i]: from line i - 1 down to line i. The page's usual gap is the median of those
        // going down the page.
        var gaps = new double[items.Count];
        for (int i = 1; i < items.Count; i++) gaps[i] = items[i].Top - items[i - 1].Bottom;
        var positive = gaps.Skip(1).Where(g => g > 0).ToList();
        double pageGap = positive.Count > 0 ? Median(positive) : 0;

        var current = new List<OcrLine> { items[0].Line };
        for (int i = 1; i < items.Count; i++)
        {
            var previous = items[i - 1];
            var item = items[i];
            // The usual gap here: the page's, or the smaller gap next to this one when that is less
            // (a page with many short paragraphs has a median gap as wide as a paragraph break).
            double usualGap = pageGap;
            if (i > 1 && gaps[i - 1] > 0) usualGap = Math.Min(usualGap, gaps[i - 1]);
            if (i + 1 < items.Count && gaps[i + 1] > 0) usualGap = Math.Min(usualGap, gaps[i + 1]);
            double breakGap = Math.Max(ParagraphGap * lineHeight, ParagraphGapFactor * usualGap);
            // Centred on each other (a heading, a letterhead): not indented, not moved.
            bool centred = Math.Abs((item.Left + item.Right) - (previous.Left + previous.Right)) / 2
                           <= CentredLines * lineHeight;
            bool starts = item.Top < previous.Top - JumpLines * lineHeight
                          || gaps[i] > breakGap
                          || (!centred && Math.Abs(item.Left - previous.Left) > LeftEdgeShift * w)
                          || (!centred && item.Left - previous.Left > IndentLines * lineHeight);
            if (starts)
            {
                paragraphs.Add(new OcrParagraph(current));
                current = [];
            }
            current.Add(item.Line);
        }
        paragraphs.Add(new OcrParagraph(current));
        return paragraphs;
    }

    // MARK: Text

    /// <summary>
    /// The text of a paragraph's lines: a line that wrapped (it reaches to within
    /// <see cref="ShortLineShare"/> of the page width of the paragraph's longest line) is joined to
    /// the next by a space, or without the hyphen of a word broken over the two
    /// (<see cref="JoinLines"/>); a line that ends short, and a table's row (a line holding a
    /// <see cref="CellSeparator"/>), keep their line break ("\n").
    /// </summary>
    public static string ParagraphText(IReadOnlyList<OcrLine> lines)
    {
        if (lines.Count == 0) return "";
        double right = lines.Max(l => l.BoundingBox.Standardized.MaxX);
        var sb = new StringBuilder();
        string? previous = null;
        double previousRight = 0;
        foreach (var line in lines)
        {
            string text = line.Text.Trim();
            if (text.Length == 0) continue;
            if (previous is null)
            {
                sb.Append(text);
            }
            else if (previous.Contains(CellSeparator, StringComparison.Ordinal)
                     || text.Contains(CellSeparator, StringComparison.Ordinal)
                     || previousRight < right - ShortLineShare)
            {
                sb.Append('\n').Append(text);
            }
            else if (sb.Length >= 2 && sb[^1] == '-' && char.IsLetter(sb[^2]) && char.IsLower(text[0]))
            {
                sb.Length -= 1;
                sb.Append(text);
            }
            else
            {
                sb.Append(' ').Append(text);
            }
            previous = text;
            previousRight = line.BoundingBox.Standardized.MaxX;
        }
        return sb.ToString();
    }

    /// <summary>
    /// The lines of a paragraph as running text: joined by spaces, and a word broken over two
    /// lines ("forward-" then "ing") joined again ("forwarding").
    /// </summary>
    public static string JoinLines(IReadOnlyList<string> lines)
    {
        var sb = new StringBuilder();
        foreach (string raw in lines)
        {
            string line = raw.Trim();
            if (line.Length == 0) continue;
            if (sb.Length == 0)
            {
                sb.Append(line);
            }
            else if (sb.Length >= 2 && sb[^1] == '-' && char.IsLetter(sb[^2]) && char.IsLower(line[0]))
            {
                sb.Length -= 1;
                sb.Append(line);
            }
            else
            {
                sb.Append(' ').Append(line);
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// The text of one page: one line of text per line on the page, a blank line between
    /// paragraphs, no line break at the end; empty when nothing was recognized.
    /// </summary>
    public static string PageText(OcrPage page) =>
        string.Join("\n\n", Paragraphs(page).Select(p => string.Join("\n", p.Lines.Select(l => l.Text))));

    /// <summary>
    /// The text of a document (<see cref="TextExport"/>): each page's <see cref="PageText"/>, two
    /// blank lines between pages, and a line break at the end; empty when no page has text.
    /// Line breaks are "\n" only.
    /// </summary>
    public static string PlainText(IReadOnlyList<OcrPage> pages)
    {
        var texts = pages.Select(PageText).ToList();
        if (texts.All(t => t.Length == 0)) return "";
        return string.Join("\n\n\n", texts) + "\n";
    }

    /// <summary>
    /// One line of OCR text made safe to write: line breaks and other control characters become
    /// spaces (a tab stays), runs of spaces one space, no space at either end.
    /// </summary>
    public static string CleanLine(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (c == '\t') sb.Append(c);
            else if (char.IsControl(c) || c == '\u2028' || c == '\u2029') sb.Append(' ');
            else sb.Append(c);
        }
        var cleaned = new StringBuilder(sb.Length);
        foreach (char c in sb.ToString())
        {
            if (c == ' ' && (cleaned.Length == 0 || cleaned[^1] == ' ')) continue;
            cleaned.Append(c);
        }
        return cleaned.ToString().Trim(' ', '\t');
    }

    // MARK: X-Y cut

    /// <summary>A line with its place in the engine's list (the last tie-break of every sort) and its box in page units, origin top-left.</summary>
    private readonly record struct Item(OcrLine Line, int Index, double Left, double Top, double Right, double Bottom)
    {
        public double Height => Bottom - Top;
    }

    private static void Cut(List<Item> items, List<OcrLine> output)
    {
        if (items.Count == 0) return;
        if (items.Count == 1 || IsOneRow(items))
        {
            output.Add(JoinRow(items));
            return;
        }
        double lineHeight = Median(items.Select(i => i.Height));

        // The widest gap across the page (between blocks) and down the page (between columns).
        var byTop = items.OrderBy(i => i.Top).ThenBy(i => i.Left).ThenBy(i => i.Index).ToList();
        var (gapY, splitY) = WidestGap(byTop, i => i.Top, i => i.Bottom);
        var byLeft = items.OrderBy(i => i.Left).ThenBy(i => i.Top).ThenBy(i => i.Index).ToList();
        var (gapX, splitX) = WidestGap(byLeft, i => i.Left, i => i.Right);

        if (gapY >= BlockGap * lineHeight)
        {
            Cut(byTop.GetRange(0, splitY), output);
            Cut(byTop.GetRange(splitY, byTop.Count - splitY), output);
            return;
        }
        if (gapX >= ColumnGap * lineHeight)
        {
            var left = byLeft.GetRange(0, splitX);
            var right = byLeft.GetRange(splitX, byLeft.Count - splitX);
            // A lone line on one side is a heading's neighbour or a cell, not a column.
            if (left.Count >= 2 && right.Count >= 2 && !IsTable(left, right, gapX))
            {
                Cut(left, output);
                Cut(right, output);
                return;
            }
        }
        if (gapY > 0)
        {
            Cut(byTop.GetRange(0, splitY), output);
            Cut(byTop.GetRange(splitY, byTop.Count - splitY), output);
            return;
        }

        // No gap across the page: a table whose rows touch, or lines that overlap a little (a
        // slanted page). Sort them into rows.
        foreach (var row in Rows(byTop)) output.Add(JoinRow(row));
    }

    /// <summary>
    /// The widest empty gap along one axis of <paramref name="sorted"/> (sorted by its start):
    /// its width and the index of the first item after it; (0, 0) when the items overlap all the way.
    /// </summary>
    private static (double Gap, int Split) WidestGap(List<Item> sorted, Func<Item, double> start, Func<Item, double> end)
    {
        double best = 0;
        int split = 0;
        double reach = end(sorted[0]);
        for (int i = 1; i < sorted.Count; i++)
        {
            double gap = start(sorted[i]) - reach;
            if (gap > best)
            {
                best = gap;
                split = i;
            }
            reach = Math.Max(reach, end(sorted[i]));
        }
        return (best, split);
    }

    /// <summary>
    /// The two sides of a gap down the page are a table, read row by row, rather than two columns:
    /// more than half the lines on each side share their row with a line on the other side, and the
    /// gap is at least <see cref="TableGapShare"/> of the narrower side's typical line width (the
    /// gutter between columns of text, or beside a letterhead's list of names, is narrow next to
    /// their lines; the gap before a column of prices is wide).
    /// </summary>
    private static bool IsTable(List<Item> left, List<Item> right, double gap)
    {
        static bool MostlyPaired(List<Item> side, List<Item> other) =>
            2 * side.Count(item => other.Any(o => SameRow(item, o))) > side.Count;
        double narrower = Math.Min(Median(left.Select(i => i.Right - i.Left)), Median(right.Select(i => i.Right - i.Left)));
        return MostlyPaired(left, right) && MostlyPaired(right, left) && gap >= TableGapShare * narrower;
    }

    /// <summary>Two lines share at least <see cref="SameRowOverlap"/> of the lower one's height.</summary>
    private static bool SameRow(Item a, Item b) =>
        Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top) >= SameRowOverlap * Math.Min(a.Height, b.Height);

    /// <summary>Every line overlaps one band across the page by <see cref="SameRowOverlap"/> of the lowest line's height.</summary>
    private static bool IsOneRow(List<Item> items)
    {
        double top = items.Max(i => i.Top);
        double bottom = items.Min(i => i.Bottom);
        double lowest = items.Min(i => i.Height);
        return bottom - top >= SameRowOverlap * lowest;
    }

    /// <summary>
    /// Lines that overlap each other a little, sorted into rows: a line joins the row it shares
    /// enough height with and no width; rows top to bottom.
    /// </summary>
    private static List<List<Item>> Rows(List<Item> byTop)
    {
        var rows = new List<List<Item>>();
        foreach (var item in byTop)
        {
            List<Item>? home = null;
            foreach (var row in rows)
            {
                bool sameRow = row.All(other =>
                    SameRow(other, item) && (item.Right <= other.Left || item.Left >= other.Right));
                if (sameRow)
                {
                    home = row;
                    break;
                }
            }
            if (home is null) rows.Add([item]);
            else home.Add(item);
        }
        return rows.OrderBy(r => r.Min(i => i.Top)).ThenBy(r => r[0].Index).ToList();
    }

    /// <summary>One row's lines left to right as one line: a space between them, a tab across a wide gap.</summary>
    private static OcrLine JoinRow(List<Item> row)
    {
        if (row.Count == 1) return row[0].Line;
        var sorted = row.OrderBy(i => i.Left).ThenBy(i => i.Index).ToList();
        double lineHeight = Median(sorted.Select(i => i.Height));
        var sb = new StringBuilder(sorted[0].Line.Text);
        double reach = sorted[0].Right;
        for (int i = 1; i < sorted.Count; i++)
        {
            sb.Append(sorted[i].Left - reach >= ColumnGap * lineHeight ? CellSeparator : " ");
            sb.Append(sorted[i].Line.Text);
            reach = Math.Max(reach, sorted[i].Right);
        }
        double minX = sorted.Min(i => i.Line.BoundingBox.Standardized.MinX);
        double minY = sorted.Min(i => i.Line.BoundingBox.Standardized.MinY);
        double maxX = sorted.Max(i => i.Line.BoundingBox.Standardized.MaxX);
        double maxY = sorted.Max(i => i.Line.BoundingBox.Standardized.MaxY);
        float confidence = sorted.Min(i => i.Line.Confidence);
        return new OcrLine(sb.ToString(), new RectD(minX, minY, maxX - minX, maxY - minY), confidence);
    }

    /// <summary>The middle value (the mean of the two middle ones for an even count); 0 for none.</summary>
    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.OrderBy(v => v).ToList();
        if (sorted.Count == 0) return 0;
        int mid = sorted.Count / 2;
        return sorted.Count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
    }
}
