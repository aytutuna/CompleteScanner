namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/PatchCodeDetector.swift.

/// <summary>
/// The six patch codes of document scanners: four parallel bars, two wide and two narrow, in an
/// order that names the code. Separator sheets carry one (Patch T by convention). A sheet fed the
/// other way round reads its code backwards (<see cref="PatchCodes.Reversed"/>), so every code
/// counts as a separator; the code itself is only shown.
/// </summary>
public enum PatchCode
{
    Patch1,
    Patch2,
    Patch3,
    Patch4,
    Patch6,
    PatchT,
}

public static class PatchCodes
{
    /// <summary>Every code.</summary>
    public static IReadOnlyList<PatchCode> All { get; } =
        [PatchCode.Patch1, PatchCode.Patch2, PatchCode.Patch3, PatchCode.Patch4, PatchCode.Patch6, PatchCode.PatchT];

    /// <summary>"Patch 1" … "Patch 6", "Patch T".</summary>
    public static string Label(this PatchCode code) => code switch
    {
        PatchCode.Patch1 => "Patch 1",
        PatchCode.Patch2 => "Patch 2",
        PatchCode.Patch3 => "Patch 3",
        PatchCode.Patch4 => "Patch 4",
        PatchCode.Patch6 => "Patch 6",
        PatchCode.PatchT => "Patch T",
        _ => code.ToString(),
    };

    /// <summary>
    /// The bars in reading order (top to bottom, or left to right), true for a wide bar: 1 = wide
    /// wide narrow narrow, 2 = wide narrow narrow wide, 3 = wide narrow wide narrow, 4 = narrow wide
    /// wide narrow, 6 = narrow narrow wide wide, T = narrow wide narrow wide.
    /// </summary>
    public static IReadOnlyList<bool> Bars(this PatchCode code) => code switch
    {
        PatchCode.Patch1 => [true, true, false, false],
        PatchCode.Patch2 => [true, false, false, true],
        PatchCode.Patch3 => [true, false, true, false],
        PatchCode.Patch4 => [false, true, true, false],
        PatchCode.Patch6 => [false, false, true, true],
        _ => [false, true, false, true],
    };

    /// <summary>The code of four bars in reading order (true: wide); null unless exactly two are wide.</summary>
    public static PatchCode? FromBars(bool first, bool second, bool third, bool fourth)
    {
        foreach (var code in All)
        {
            var bars = code.Bars();
            if (bars[0] == first && bars[1] == second && bars[2] == third && bars[3] == fourth) return code;
        }
        return null;
    }

    /// <summary>The code read from the other end: 1 and 6, 3 and T swap; 2 and 4 read the same.</summary>
    public static PatchCode Reversed(this PatchCode code)
    {
        var bars = code.Bars();
        return FromBars(bars[3], bars[2], bars[1], bars[0]) ?? code;
    }
}

/// <summary>
/// A patch code found on a page: the code as read, whether its bars run down the page (the sheet
/// lay sideways) rather than across it, and where its bars are (analysis pixels, top-left origin).
/// <paramref name="Length"/> is how far along the bars it was read, in analysis pixels.
/// </summary>
public sealed record PatchCodeHit(PatchCode Code, bool VerticalBars, RectD Bounds, int Length);

/// <summary>
/// Finds patch codes on scanned pages, and draws the separator sheet the app prints. Works on the
/// page's gray copy at the analysis resolution (<see cref="GrayImage.AnalysisDpi"/>), integer
/// arithmetic only, so both platforms find the same codes.
///
/// A patch code is read like a one-dimensional barcode, along lines that cross its bars (the
/// columns of the page for bars running across it, the rows for bars running down it): the ink
/// (darker than half the paper, the page's 90th percentile) along a line gives runs, and four
/// runs in a row match when each is narrow (0.05–0.12 in) or wide (0.15–0.26 in), exactly two are
/// wide, the gaps between them are 0.05–0.12 in and nothing is printed for 0.3 in before and after
/// them. A line read this way does not care about a slant of a few degrees. Matches on
/// neighbouring lines that agree on the code and move by at most 0.02 in from one line to the next
/// are one code; it counts when it is read over at least 1.5 in of its length, on at least half the
/// lines it spans (a speck breaks a few lines). Text, tables and rules do not read this way: their
/// strokes are thinner, closer together or have no quiet zone around them.
/// </summary>
public static class PatchCodeDetector
{
    // Sizes in hundredths of an inch (whole numbers, so both platforms compute the same pixels).

    /// <summary>The printed bars: narrow 0.08 in, wide 0.20 in, gaps 0.08 in.</summary>
    public const int NarrowBarHundredths = 8, WideBarHundredths = 20, GapHundredths = 8;

    /// <summary>What reads as a narrow bar, a wide bar and a gap: printing and scanning widen or thin them.</summary>
    public const int MinNarrowHundredths = 5, MaxNarrowHundredths = 12;
    public const int MinWideHundredths = 15, MaxWideHundredths = 26;
    public const int MinGapHundredths = 5, MaxGapHundredths = 12;

    /// <summary>Nothing printed this far before the first bar and after the last.</summary>
    public const int QuietZoneHundredths = 30;

    /// <summary>A code is read over at least this length of its bars.</summary>
    public const int MinLengthHundredths = 150;

    /// <summary>How far a code may move from one line to the next (a slant), and the lines a speck may break.</summary>
    public const int MaxStepHundredths = 2, MaxBreakHundredths = 6;

    /// <summary>A code is read on at least this share of the lines it spans.</summary>
    public const double MinCoverage = 0.5;

    /// <summary>The separator sheet: bars 6 in long (less on narrow paper), 1 in from the top and the bottom edge.</summary>
    public const int SheetBarLengthHundredths = 600, SheetMarginHundredths = 100;

    /// <summary>The pixels of <paramref name="hundredths"/> of an inch at <paramref name="dpi"/>, rounded down / up / to nearest.</summary>
    private static int Floor(int hundredths, double dpi) => (int)Math.Floor(hundredths * dpi / 100);
    private static int Ceiling(int hundredths, double dpi) => (int)Math.Ceiling(hundredths * dpi / 100);
    private static int Round(int hundredths, double dpi) => (int)Math.Round(hundredths * dpi / 100, MidpointRounding.AwayFromZero);

    /// <summary>The patch code on <paramref name="image"/>, scanned at <paramref name="dpi"/>; null when there is none.</summary>
    public static PatchCodeHit? Detect(RgbaImage image, int dpi) => Detect(GrayImage.From(image, dpi));

    /// <summary>
    /// The patch code on the page, read at the analysis resolution (a finer image is reduced to it
    /// first); null when there is none. Bars across the page are tried first; the longer of the
    /// two readings wins.
    /// </summary>
    public static PatchCodeHit? Detect(GrayImage gray)
    {
        var g = gray.Dpi > GrayImage.AnalysisDpi ? gray.AtResolution(GrayImage.AnalysisDpi) : gray;
        int w = g.Width, h = g.Height;
        if (w < 2 || h < 2) return null;
        var histogram = new int[256];
        foreach (byte value in g.Pixels) histogram[value]++;
        int paper = BackgroundMap.Percentile(histogram, g.Pixels.Length, 0.9);
        var ink = new bool[w * h];
        for (int i = 0; i < ink.Length; i++) ink[i] = g.Pixels[i] * 2 < paper;

        var limits = new Limits(g.Dpi);
        var across = Read(ink, w, h, lineIsRow: false, limits);
        var down = Read(ink, w, h, lineIsRow: true, limits);
        Chain? best = across;
        bool vertical = false;
        if (down is { } d && (best is null || d.Length > best.Length))
        {
            best = d;
            vertical = true;
        }
        if (best is null) return null;
        // Lines are columns for bars across the page (positions are rows), rows for bars down it.
        var bounds = vertical
            ? new RectD(best.MinStart, best.FirstLine, best.MaxEnd - best.MinStart, best.Length)
            : new RectD(best.FirstLine, best.MinStart, best.Length, best.MaxEnd - best.MinStart);
        return new PatchCodeHit(best.Code, vertical, bounds, best.Length);
    }

    /// <summary>The detector's sizes in pixels at one resolution.</summary>
    private sealed class Limits(double dpi)
    {
        public int MinNarrow { get; } = Floor(MinNarrowHundredths, dpi);
        public int MaxNarrow { get; } = Ceiling(MaxNarrowHundredths, dpi);
        public int MinWide { get; } = Floor(MinWideHundredths, dpi);
        public int MaxWide { get; } = Ceiling(MaxWideHundredths, dpi);
        public int MinGap { get; } = Floor(MinGapHundredths, dpi);
        public int MaxGap { get; } = Ceiling(MaxGapHundredths, dpi);
        public int Quiet { get; } = Round(QuietZoneHundredths, dpi);
        public int MinLength { get; } = Math.Max(1, Round(MinLengthHundredths, dpi));
        public int MaxStep { get; } = Math.Max(1, Round(MaxStepHundredths, dpi));
        public int MaxBreak { get; } = Math.Max(1, Round(MaxBreakHundredths, dpi));
    }

    /// <summary>A code read on neighbouring lines.</summary>
    private sealed class Chain(PatchCode code, int line, int start, int end)
    {
        public PatchCode Code { get; } = code;
        public int FirstLine { get; } = line;
        public int LastLine { get; set; } = line;
        public int LastStart { get; set; } = start;
        public int MinStart { get; set; } = start;
        public int MaxEnd { get; set; } = end;
        public int Count { get; set; } = 1;
        public int Length => LastLine - FirstLine + 1;
    }

    /// <summary>
    /// The longest code read along the columns (<paramref name="lineIsRow"/> false: bars across the
    /// page) or the rows (true: bars down it); null when none is long and dense enough.
    /// </summary>
    private static Chain? Read(bool[] ink, int w, int h, bool lineIsRow, Limits limits)
    {
        int lines = lineIsRow ? h : w;
        int length = lineIsRow ? w : h;
        var chains = new List<Chain>();
        var runStarts = new List<int>();
        var runEnds = new List<int>();
        for (int line = 0; line < lines; line++)
        {
            runStarts.Clear();
            runEnds.Clear();
            int runStart = -1;
            for (int pos = 0; pos < length; pos++)
            {
                bool isInk = lineIsRow ? ink[line * w + pos] : ink[pos * w + line];
                if (isInk && runStart < 0)
                {
                    runStart = pos;
                }
                else if (!isInk && runStart >= 0)
                {
                    runStarts.Add(runStart);
                    runEnds.Add(pos);
                    runStart = -1;
                }
            }
            if (runStart >= 0)
            {
                runStarts.Add(runStart);
                runEnds.Add(length);
            }
            for (int i = 0; i + 3 < runStarts.Count; i++)
            {
                if (Match(runStarts, runEnds, i, length, limits) is not { } code) continue;
                int start = runStarts[i], end = runEnds[i + 3];
                Chain? found = null;
                foreach (var chain in chains)
                {
                    if (chain.Code == code && chain.LastLine < line && line - chain.LastLine <= limits.MaxBreak + 1
                        && Math.Abs(start - chain.LastStart) <= limits.MaxStep)
                    {
                        found = chain;
                        break;
                    }
                }
                if (found is null)
                {
                    chains.Add(new Chain(code, line, start, end));
                    continue;
                }
                found.LastLine = line;
                found.LastStart = start;
                found.MinStart = Math.Min(found.MinStart, start);
                found.MaxEnd = Math.Max(found.MaxEnd, end);
                found.Count += 1;
            }
        }
        Chain? best = null;
        foreach (var chain in chains)
        {
            if (chain.Length < limits.MinLength || chain.Count < MinCoverage * chain.Length) continue;
            if (best is null || chain.Length > best.Length) best = chain;
        }
        return best;
    }

    /// <summary>The code of the four runs from run <paramref name="i"/> on, when they read as one; else null.</summary>
    private static PatchCode? Match(List<int> starts, List<int> ends, int i, int length, Limits limits)
    {
        var wide = new bool[4];
        for (int k = 0; k < 4; k++)
        {
            int width = ends[i + k] - starts[i + k];
            if (width >= limits.MinWide && width <= limits.MaxWide) wide[k] = true;
            else if (width < limits.MinNarrow || width > limits.MaxNarrow) return null;
            if (k > 0)
            {
                int gap = starts[i + k] - ends[i + k - 1];
                if (gap < limits.MinGap || gap > limits.MaxGap) return null;
            }
        }
        // Nothing printed before the first bar and after the last (the page's edge counts as quiet).
        int before = i > 0 ? starts[i] - ends[i - 1] : int.MaxValue;
        int after = i + 4 < starts.Count ? starts[i + 4] - ends[i + 3] : int.MaxValue;
        if (before < limits.Quiet || after < limits.Quiet) return null;
        return PatchCodes.FromBars(wide[0], wide[1], wide[2], wide[3]);
    }

    // MARK: - The separator sheet

    /// <summary>
    /// The separator sheet to print, <paramref name="widthInches"/> × <paramref name="heightInches"/>
    /// at <paramref name="dpi"/>: white, with <paramref name="code"/> in black bars across the sheet
    /// 1 in from the top and again 1 in from the bottom, turned half a turn there, so the sheet
    /// reads the same code fed either way round; and in the middle "SEPARATOR SHEET", the code and
    /// how to use and print it. Printed at real size, its bars have the standard widths.
    /// </summary>
    public static GrayImage RenderSheet(PatchCode code, double widthInches, double heightInches, int dpi)
    {
        int w = Math.Max(1, (int)Math.Round(widthInches * dpi, MidpointRounding.AwayFromZero));
        int h = Math.Max(1, (int)Math.Round(heightInches * dpi, MidpointRounding.AwayFromZero));
        var pixels = new byte[w * h];
        Array.Fill(pixels, (byte)255);

        int narrow = Math.Max(1, Round(NarrowBarHundredths, dpi));
        int wide = Math.Max(1, Round(WideBarHundredths, dpi));
        int gap = Math.Max(1, Round(GapHundredths, dpi));
        int margin = Round(SheetMarginHundredths, dpi);
        int barLength = Math.Min(Round(SheetBarLengthHundredths, dpi), w - 2 * Round(50, dpi));
        barLength = Math.Max(1, barLength);
        int x0 = (w - barLength) / 2;
        var bars = code.Bars();

        // Near the top, read top to bottom.
        int y = margin;
        foreach (bool isWide in bars)
        {
            int thickness = isWide ? wide : narrow;
            FillRect(pixels, w, h, x0, y, barLength, thickness, 0);
            y += thickness + gap;
        }
        // Near the bottom, half a turn round: read bottom to top.
        y = h - margin;
        foreach (bool isWide in bars)
        {
            int thickness = isWide ? wide : narrow;
            FillRect(pixels, w, h, x0, y - thickness, barLength, thickness, 0);
            y -= thickness + gap;
        }

        // The words, centred, around the middle of the sheet.
        int middle = h / 2;
        int title = Math.Max(1, Round(5, dpi));
        int body = Math.Max(1, Round(2, dpi));
        DrawText(pixels, w, h, "SEPARATOR SHEET", middle - Round(80, dpi), title);
        DrawText(pixels, w, h, code.Label().ToUpperInvariant(), middle - Round(20, dpi), title);
        DrawText(pixels, w, h, "PUT THIS SHEET IN FRONT OF EACH DOCUMENT.", middle + Round(50, dpi), body);
        DrawText(pixels, w, h, "PRINT AT ACTUAL SIZE (100%). DO NOT SHRINK.", middle + Round(80, dpi), body);
        return new GrayImage(w, h, pixels, dpi);
    }

    /// <summary>
    /// Fills the rectangle at (<paramref name="x"/>, <paramref name="y"/>), <paramref name="rw"/> ×
    /// <paramref name="rh"/> pixels, with <paramref name="value"/>, clipped to the sheet. Also used by
    /// the barcode sheets (<see cref="QrSeparatorSheet"/>, <see cref="Code39"/>).
    /// </summary>
    internal static void FillRect(byte[] pixels, int w, int h, int x, int y, int rw, int rh, byte value)
    {
        for (int py = Math.Max(0, y); py < Math.Min(h, y + rh); py++)
        {
            for (int px = Math.Max(0, x); px < Math.Min(w, x + rw); px++) pixels[py * w + px] = value;
        }
    }

    /// <summary>
    /// <paramref name="text"/> in the sheet's 5 × 7 type, each dot <paramref name="cell"/> pixels,
    /// a dot's space between letters, centred across the sheet with its top at <paramref name="top"/>.
    /// Characters the type does not have are spaces. Also used by the barcode sheets.
    /// </summary>
    internal static void DrawText(byte[] pixels, int w, int h, string text, int top, int cell)
    {
        int width = (text.Length * 6 - 1) * cell;
        int x = (w - width) / 2;
        foreach (char c in text)
        {
            if (Glyphs.TryGetValue(c, out var glyph))
            {
                for (int row = 0; row < 7; row++)
                {
                    for (int col = 0; col < 5; col++)
                    {
                        if (glyph[row * 5 + col] == '1') FillRect(pixels, w, h, x + col * cell, top + row * cell, cell, cell, 0);
                    }
                }
            }
            x += 6 * cell;
        }
    }

    /// <summary>Whether the sheet's type has <paramref name="c"/>.</summary>
    internal static bool HasGlyph(char c) => Glyphs.ContainsKey(c);

    /// <summary>The sheet's type: 5 × 7 dots per character, rows top to bottom.</summary>
    private static readonly Dictionary<char, string> Glyphs = new()
    {
        ['A'] = "01110100011000111111100011000110001",
        ['B'] = "11110100011000111110100011000111110",
        ['C'] = "01110100011000010000100001000101110",
        ['D'] = "11110100011000110001100011000111110",
        ['E'] = "11111100001000011110100001000011111",
        ['F'] = "11111100001000011110100001000010000",
        ['G'] = "01110100011000010111100011000101111",
        ['H'] = "10001100011000111111100011000110001",
        ['I'] = "01110001000010000100001000010001110",
        ['J'] = "00111000100001000010000101001001100",
        ['K'] = "10001100101010011000101001001010001",
        ['L'] = "10000100001000010000100001000011111",
        ['M'] = "10001110111010110101100011000110001",
        ['N'] = "10001100011100110101100111000110001",
        ['O'] = "01110100011000110001100011000101110",
        ['P'] = "11110100011000111110100001000010000",
        ['Q'] = "01110100011000110001101011001001101",
        ['R'] = "11110100011000111110101001001010001",
        ['S'] = "01111100001000001110000010000111110",
        ['T'] = "11111001000010000100001000010000100",
        ['U'] = "10001100011000110001100011000101110",
        ['V'] = "10001100011000110001100010101000100",
        ['W'] = "10001100011000110101101011010101010",
        ['X'] = "10001100010101000100010101000110001",
        ['Y'] = "10001100010101000100001000010000100",
        ['Z'] = "11111000010001000100010001000011111",
        ['0'] = "01110100011001110101110011000101110",
        ['1'] = "00100011000010000100001000010001110",
        ['2'] = "01110100010000100010001000100011111",
        ['3'] = "11111000100010000010000011000101110",
        ['4'] = "00010001100101010010111110001000010",
        ['5'] = "11111100001111000001000011000101110",
        ['6'] = "00110010001000011110100011000101110",
        ['7'] = "11111000010001000100010000100001000",
        ['8'] = "01110100011000101110100011000101110",
        ['9'] = "01110100011000101111000010001001100",
        ['.'] = "00000000000000000000000000110001100",
        ['('] = "00010001000100001000010000010000010",
        [')'] = "01000001000001000010000100010001000",
        ['%'] = "11000110010001000100010001001100011",
        ['-'] = "00000000000000011111000000000000000",
        ['?'] = "01110100010000100010001000000000100",
        [':'] = "00000011000110000000011000110000000",
        ['/'] = "00000000010001000100010001000000000",
        ['_'] = "00000000000000000000000000000011111",
        ['#'] = "01010010101111101010111110101001010",
        ['+'] = "00000001000010011111001000010000000",
        [','] = "00000000000000000000011000010001000",
        ['&'] = "01100100101010001000101011001001101",
        ['\''] = "01100001000100000000000000000000000",
        ['!'] = "00100001000010000100001000000000100",
    };
}

/// <summary>
/// The separator sheet as a PDF to print (<see cref="PatchCodeDetector.RenderSheet"/>): Patch T on
/// the paper usual where the user lives, saved in the scans folder, for any printer, here or
/// elsewhere. Twin of the Mac's <c>SeparatorSheet</c>.
/// </summary>
public static class SeparatorSheet
{
    /// <summary>The code on the sheet.</summary>
    public const PatchCode Code = PatchCode.PatchT;

    /// <summary>The sheet's resolution.</summary>
    public const int Dpi = 300;

    /// <summary>Letter or A4: the paper usual in <paramref name="regionCode"/> (<see cref="PaperSizes.DefaultForRegion"/>).</summary>
    public static PaperSize Paper(string? regionCode) => PaperSizes.DefaultForRegion(regionCode);

    /// <summary>"Separator sheet (Patch T, Letter)": the PDF's name, without its extension.</summary>
    public static string FileBaseName(PaperSize paper) => $"Separator sheet ({Code.Label()}, {paper.Label()})";

    /// <summary>The status after the PDF was saved.</summary>
    public static string SavedMessage(string fileName) =>
        $"Saved the separator sheet: {fileName}. Print it at actual size (100%), as many as you need, and put one in front of each document after the first.";
}
