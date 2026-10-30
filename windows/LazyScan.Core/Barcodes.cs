using System.Globalization;
using System.Text;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/Barcodes.swift.

/// <summary>
/// The kinds of code read on scanned pages for splitting a stack at barcode or QR sheets
/// (<see cref="SplitMode.Barcode"/>). Other kinds are not looked for.
/// </summary>
public enum BarcodeSymbology
{
    QrCode,
    Code128,
    Code39,
    DataMatrix,
}

public static class BarcodeSymbologies
{
    /// <summary>Every kind read, in this order.</summary>
    public static IReadOnlyList<BarcodeSymbology> All { get; } =
        [BarcodeSymbology.QrCode, BarcodeSymbology.Code128, BarcodeSymbology.Code39, BarcodeSymbology.DataMatrix];

    /// <summary>"QR code", "Code 128", "Code 39", "Data Matrix".</summary>
    public static string Label(this BarcodeSymbology symbology) => symbology switch
    {
        BarcodeSymbology.QrCode => "QR code",
        BarcodeSymbology.Code128 => "Code 128",
        BarcodeSymbology.Code39 => "Code 39",
        BarcodeSymbology.DataMatrix => "Data Matrix",
        _ => symbology.ToString(),
    };
}

/// <summary>
/// A code read on a page: its kind, its text, and where it is (pixels, top-left origin; on the page
/// as it was read when it comes from <see cref="BarcodeSeparators.Read"/>, on the image read when
/// it comes from an <see cref="IBarcodeReader"/>).
/// </summary>
public sealed record BarcodeReading(BarcodeSymbology Symbology, string Text, RectD Bounds);

/// <summary>
/// Reads the barcodes and QR codes of the kinds in <see cref="BarcodeSymbologies.All"/> on a gray
/// image, with their bounds in that image's pixels. The platform does the reading: ZXing.Net in the
/// Windows app (<c>ZXingBarcodeReader</c>), Vision on the Mac (<c>VisionBarcodeReader</c>); tests use a
/// stand-in. Twin of the Mac's <c>BarcodeReader</c>.
/// </summary>
public interface IBarcodeReader
{
    /// <summary>Whether codes can be read at all.</summary>
    bool IsAvailable { get; }

    /// <summary>The codes on <paramref name="image"/>, in any order. Throws when reading fails; <paramref name="token"/> may stop it.</summary>
    IReadOnlyList<BarcodeReading> Read(GrayImage image, CancellationToken token);
}

/// <summary>
/// Barcode and QR separator sheets (<see cref="SplitMode.Barcode"/>): reading the codes on a page,
/// the first one in reading order, which codes split the stack (<see cref="SplittingCode"/>), and the
/// document name a code's text gives.
/// </summary>
public static class BarcodeSeparators
{
    /// <summary>
    /// Pages are read as gray at this resolution (box filter; a coarser scan is read as it is): fine
    /// enough for a 0.01 in bar, coarse enough that the scanner's noise is averaged out.
    /// </summary>
    public const int ReadingDpi = 200;

    /// <summary>
    /// The text a separator sheet's code starts with (<see cref="DocumentOptions.SplitBarcodePrefix"/>
    /// by default): only such a code makes a separator sheet, so the codes printed on the documents
    /// themselves (payment QR codes, order numbers) are not taken for one.
    /// </summary>
    public const string DefaultPrefix = "CS-SEP";

    /// <summary>
    /// The text of a separator sheet that gives no name (<see cref="QrSeparatorSheet"/> with no name,
    /// when the prefix is empty): the document after it is not named by it. Compared ignoring case.
    /// </summary>
    public const string UnnamedText = "SEPARATOR";

    /// <summary>The most characters of a code's text a note shows; a longer text is cut, ending with "…".</summary>
    public const int MaxNoteTextLength = 40;

    /// <summary>
    /// What <see cref="DocumentOptions.BarcodeStartsDocument"/> does, on and off, under its switch;
    /// off, with the codes that make a separator sheet (those starting with <paramref name="prefix"/>,
    /// <see cref="DefaultPrefix"/> when null; every code when it is empty).
    /// </summary>
    public static string StartsDocumentHint(bool on, string? prefix = null)
    {
        if (on)
        {
            return "Each page with a barcode or QR code is kept as the first page of a new document, named after the code's text: for documents that carry their own code, such as invoices.";
        }
        string start = Prefix(prefix ?? DefaultPrefix);
        return start.Length == 0
            ? "A sheet with a barcode or QR code is a separator sheet: it is left out, and the code's text names the document after it. Print QR separator sheets below, with a name or without."
            : $"A sheet whose barcode or QR code starts with “{start}” is a separator sheet: it is left out, and the rest of the code's text names the document after it. Other codes are ignored. Print QR separator sheets below, with a name or without.";
    }

    /// <summary>
    /// The one line under "Codes are on": what happens to the page or sheet with a code, kept as a
    /// document's first page (<paramref name="on"/>) or left out as a separator sheet.
    /// </summary>
    public static string StartsDocumentCaption(bool on) => on ? "Pages are kept" : "Sheets are left out";

    /// <summary>The prefix as it is compared: <paramref name="prefix"/> trimmed. Empty: every code makes a separator sheet.</summary>
    public static string Prefix(string? prefix) => (prefix ?? "").Trim();

    /// <summary>
    /// Whether <paramref name="text"/> starts with <paramref name="prefix"/> (<see cref="Prefix"/>), a–z
    /// matching A–Z, after any spaces and invisible characters it starts with (a byte-order mark).
    /// </summary>
    public static bool StartsWithPrefix(string text, string? prefix) =>
        AsciiUppercased(WithoutLeadingInvisibles(text)).StartsWith(AsciiUppercased(Prefix(prefix)), StringComparison.Ordinal);

    /// <summary><paramref name="text"/> without the spaces, control and format characters (a byte-order mark) it starts with.</summary>
    private static string WithoutLeadingInvisibles(string text)
    {
        int start = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (!Rune.IsWhiteSpace(rune) && category is not (UnicodeCategory.Format or UnicodeCategory.Control)) break;
            start += rune.Utf16SequenceLength;
        }
        return text[start..];
    }

    /// <summary>
    /// Whether <paramref name="reading"/> splits the stack under <paramref name="options"/>: with
    /// <see cref="DocumentOptions.BarcodeStartsDocument"/> every code does (its page starts a
    /// document); otherwise only a code starting with <see cref="DocumentOptions.SplitBarcodePrefix"/>
    /// (its sheet is a separator).
    /// </summary>
    public static bool Splits(BarcodeReading? reading, DocumentOptions options) =>
        reading is not null && (options.BarcodeStartsDocument || StartsWithPrefix(reading.Text, options.SplitBarcodePrefix));

    /// <summary>The first of <paramref name="readings"/> (reading order) that splits the stack (<see cref="Splits"/>); null when none does or the page was not read.</summary>
    public static BarcodeReading? SplittingCode(IReadOnlyList<BarcodeReading>? readings, DocumentOptions options) =>
        readings?.FirstOrDefault(r => Splits(r, options));

    /// <summary>
    /// The document name a splitting code gives: its text after <see cref="DocumentOptions.SplitBarcodePrefix"/>
    /// when it starts with it (a separator sheet's "CS-SEP Lease" names "Lease"), otherwise all of it,
    /// as <see cref="Label"/> makes it. Null for no text or nothing left.
    /// </summary>
    public static string? CodeLabel(string? text, DocumentOptions options)
    {
        if (text is null) return null;
        string prefix = Prefix(options.SplitBarcodePrefix);
        if (prefix.Length == 0 || !StartsWithPrefix(text, prefix)) return Label(text);
        return Label(WithoutLeadingInvisibles(text)[prefix.Length..]);
    }

    /// <summary>
    /// Whether <paramref name="page"/> is a separator sheet by its own code under <paramref name="options"/>:
    /// split at barcode or QR sheets, without <see cref="DocumentOptions.BarcodeStartsDocument"/>, and
    /// read with a code starting with the prefix. Such a page is never saved, so it is not turned upright.
    /// </summary>
    public static bool IsSeparatorPage(ScannedPage page, DocumentOptions options) =>
        options.SplitMode == SplitMode.Barcode && !options.BarcodeStartsDocument && SplittingCode(page.Barcodes, options) is not null;

    /// <summary><paramref name="image"/>, scanned at <paramref name="dpi"/>, as gray at <see cref="ReadingDpi"/>.</summary>
    public static GrayImage ReadingImage(RgbaImage image, int dpi) => GrayImage.From(image, dpi, ReadingDpi);

    /// <summary>
    /// The codes on <paramref name="image"/>, scanned at <paramref name="dpi"/>, read by
    /// <paramref name="reader"/> on its gray copy (<see cref="ReadingImage"/>), with their bounds in
    /// the page's pixels, in reading order (<see cref="InReadingOrder"/>).
    /// </summary>
    public static IReadOnlyList<BarcodeReading> Read(RgbaImage image, int dpi, IBarcodeReader reader, CancellationToken token)
    {
        var gray = ReadingImage(image, dpi);
        token.ThrowIfCancellationRequested();
        var found = reader.Read(gray, token);
        return InReadingOrder(found.Select(r => Scaled(r, 1 / gray.Scale)));
    }

    /// <summary>
    /// The codes on a queued page (<see cref="Read"/>), read on the pixels it holds (a preview once it
    /// is spooled, at the resolution that gives), with their bounds in its full-size pixels.
    /// </summary>
    public static IReadOnlyList<BarcodeReading> ReadPage(ScannedPage page, IBarcodeReader reader, CancellationToken token)
    {
        double ratio = PreviewRatio(page);
        int dpi = Math.Max(1, (int)Math.Round(page.Dpi / ratio, MidpointRounding.AwayFromZero));
        var found = Read(page.Image, dpi, reader, token);
        return ratio == 1 ? found : found.Select(r => Scaled(r, ratio)).ToList();
    }

    /// <summary>
    /// The codes on a page already queued, read again when the split at barcode or QR sheets is chosen
    /// after it was scanned: on <paramref name="spoolImage"/>, the page's full-resolution pixels from
    /// its spool file (as saved, before the user's turns, which are applied here), at the page's
    /// resolution, so small codes read as they do during the scan. Without it (no spool file, or one
    /// that can't be read) on the pixels the page holds (<see cref="ReadPage"/>); when those are a
    /// coarser preview and show no code, null: the page counts as not read, since a code too fine for
    /// the preview may be there.
    /// </summary>
    public static IReadOnlyList<BarcodeReading>? ReadQueuedPage(ScannedPage page, RgbaImage? spoolImage, IBarcodeReader reader,
                                                                CancellationToken token)
    {
        if (spoolImage is { } full)
        {
            int turns = ((page.RotationQuarterTurns % 4) + 4) % 4;
            return Read(turns == 0 ? full : ImagePipeline.Rotate(full, turns), page.Dpi, reader, token);
        }
        var found = ReadPage(page, reader, token);
        return found.Count == 0 && PreviewRatio(page) > 1 ? null : found;
    }

    /// <summary>How many times finer the page is than the pixels it holds: above 1 for a spooled page's preview.</summary>
    private static double PreviewRatio(ScannedPage page)
    {
        if (page.FullPixelSize is not { } full) return 1;
        double fullSide = Math.Max(full.Width, full.Height);
        double shown = Math.Max(page.Image.Width, page.Image.Height);
        return fullSide > shown ? fullSide / shown : 1;
    }

    /// <summary><paramref name="reading"/> with its bounds multiplied by <paramref name="factor"/>.</summary>
    private static BarcodeReading Scaled(BarcodeReading reading, double factor) => reading with
    {
        Bounds = new RectD(reading.Bounds.X * factor, reading.Bounds.Y * factor,
                           reading.Bounds.Width * factor, reading.Bounds.Height * factor),
    };

    /// <summary>
    /// <paramref name="readings"/> top to bottom, then left to right (by the top-left corner of their
    /// bounds; then by kind), without codes with no text and without a second reading of the same
    /// kind and text.
    /// </summary>
    public static IReadOnlyList<BarcodeReading> InReadingOrder(IEnumerable<BarcodeReading> readings)
    {
        var ordered = readings.Where(r => r.Text.Length > 0)
            .Select((r, i) => (Reading: r, Index: i))
            .OrderBy(e => e.Reading.Bounds.Y).ThenBy(e => e.Reading.Bounds.X)
            .ThenBy(e => (int)e.Reading.Symbology).ThenBy(e => e.Index);
        var result = new List<BarcodeReading>();
        foreach (var (reading, _) in ordered)
        {
            if (!result.Any(r => r.Symbology == reading.Symbology && r.Text == reading.Text)) result.Add(reading);
        }
        return result;
    }

    /// <summary>The first code of <paramref name="readings"/> (reading order); null when there is none or the page was not read.</summary>
    public static BarcodeReading? First(IReadOnlyList<BarcodeReading>? readings) =>
        readings is { Count: > 0 } ? readings[0] : null;

    /// <summary>
    /// The document name a code's text gives ({label}): invisible format characters (byte-order marks,
    /// zero-width spaces and joiners, bidi overrides and isolates) dropped, control characters and runs
    /// of spaces one space, the characters file names can't have (/ \ : * ? " &lt; &gt; |) a hyphen,
    /// then <see cref="DocumentSplitter.Cleaned"/> (trimmed, at most 100 characters). Null for no
    /// text, nothing left, or <see cref="UnnamedText"/>.
    /// </summary>
    public static string? Label(string? text)
    {
        if (text is null) return null;
        var builder = new StringBuilder(text.Length);
        bool space = false;
        foreach (var raw in text.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(raw);
            if (category == UnicodeCategory.Format) continue;
            int c = category == UnicodeCategory.Control ? ' ' : raw.Value;
            if (c is '/' or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|') c = '-';
            var rune = new Rune(c);
            if (Rune.IsWhiteSpace(rune))
            {
                space = true;
                continue;
            }
            if (space && builder.Length > 0) builder.Append(' ');
            space = false;
            builder.Append(rune.ToString());
        }
        string name = builder.ToString();
        if (AsciiUppercased(name) == UnnamedText) return null;
        return DocumentSplitter.Cleaned(name);
    }

    /// <summary>"QR code “Lease 2026”": the code's kind and text, the text cut to <see cref="MaxNoteTextLength"/> characters.</summary>
    public static string Describe(BarcodeReading reading)
    {
        string text = reading.Text;
        var elements = new StringInfo(text);
        if (elements.LengthInTextElements > MaxNoteTextLength)
        {
            text = elements.SubstringByTextElements(0, MaxNoteTextLength - 1) + "…";
        }
        return $"{reading.Symbology.Label()} “{text}”";
    }

    /// <summary><paramref name="text"/> with a–z made A–Z and every other character as it is.</summary>
    internal static string AsciiUppercased(string text)
    {
        var chars = text.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
        {
            if (chars[i] is >= 'a' and <= 'z') chars[i] = (char)(chars[i] - 32);
        }
        return new string(chars);
    }
}

/// <summary>
/// The modules of a QR code, without its quiet zone: <see cref="Size"/> × <see cref="Size"/>, row
/// by row from the top, true for a dark module. Made by the platform (<see cref="IQrEncoder"/>).
/// </summary>
public sealed class QrModules
{
    private readonly bool[] _dark;

    public QrModules(int size, bool[] dark)
    {
        if (size <= 0) throw new ArgumentOutOfRangeException(nameof(size), "A QR code has at least one module.");
        if (dark.Length != size * size) throw new ArgumentException($"Expected {size * size} modules, got {dark.Length}.", nameof(dark));
        Size = size;
        _dark = dark;
    }

    public int Size { get; }

    /// <summary>Whether the module in column <paramref name="x"/>, row <paramref name="y"/> is dark.</summary>
    public bool this[int x, int y] => _dark[y * Size + x];
}

/// <summary>
/// Makes the QR code of a separator sheet: Windows with ZXing.Net in the app (<c>ZXingQrEncoder</c>),
/// the Mac with Core Image (<c>CoreImageQrEncoder</c>). Twin of the Mac's <c>QrEncoder</c>.
/// </summary>
public interface IQrEncoder
{
    /// <summary>The QR code holding <paramref name="text"/> (UTF-8, error correction level M); null when it can't be made.</summary>
    QrModules? Encode(string text);
}

/// <summary>
/// The QR separator sheet to print for splitting at barcode or QR sheets: a QR code holding the
/// separator prefix and the name of the document it goes in front of (<see cref="Text"/>; the prefix
/// alone starts a document with no name), the name written under it and how to use the sheet, in the 5 × 7 dot type
/// of the patch-code sheet. Saved as a PDF or printed like the patch-code sheet
/// (<see cref="SeparatorSheet"/>). Twin of the Mac's <c>QrSeparatorSheet</c>.
/// </summary>
public static class QrSeparatorSheet
{
    /// <summary>The sheet's resolution.</summary>
    public const int Dpi = 300;

    /// <summary>The QR code is at most 2.5 in wide (with its quiet zone), its top 1.8 in from the top of the sheet.</summary>
    public const int CodeSideHundredths = 250, CodeTopHundredths = 180;

    /// <summary>
    /// The text of the sheet's code: <paramref name="prefix"/> (<see cref="BarcodeSeparators.Prefix"/>;
    /// <see cref="DocumentOptions.SplitBarcodePrefix"/>), a space and the name as a code's text gives it
    /// (<see cref="BarcodeSeparators.Label"/>): "CS-SEP Lease 2026"; the prefix alone with no name. With
    /// an empty prefix the name alone, or <see cref="BarcodeSeparators.UnnamedText"/>.
    /// </summary>
    public static string Text(string? name, string prefix = BarcodeSeparators.DefaultPrefix)
    {
        string start = BarcodeSeparators.Prefix(prefix);
        string? label = BarcodeSeparators.Label(name);
        if (start.Length == 0) return label ?? BarcodeSeparators.UnnamedText;
        return label is null ? start : $"{start} {label}";
    }

    /// <summary>
    /// <paramref name="text"/> in the sheet's type: accents dropped, a–z made A–Z, and every character
    /// the type does not have a question mark.
    /// </summary>
    public static string Caption(string text)
    {
        var builder = new StringBuilder();
        foreach (var rune in text.Normalize(NormalizationForm.FormD).EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark)
            {
                continue;
            }
            int value = rune.Value;
            if (value is >= 'a' and <= 'z') value -= 32;
            char c = value < 128 ? (char)value : '?';
            builder.Append(c == ' ' || PatchCodeDetector.HasGlyph(c) ? c : '?');
        }
        return builder.ToString();
    }

    /// <summary>
    /// The sheet, <paramref name="widthInches"/> × <paramref name="heightInches"/> at
    /// <paramref name="dpi"/>: white, "SEPARATOR SHEET" at the top, <paramref name="code"/> (the QR code
    /// of <see cref="Text"/>) in the middle, whole pixels per module, with its quiet zone, the name
    /// under it (<see cref="Caption"/>, made smaller or cut with "..." to fit) or that the document has
    /// no name, and how to use the sheet near the bottom.
    /// </summary>
    public static GrayImage Render(QrModules code, string? name, double widthInches, double heightInches, int dpi)
    {
        int w = Math.Max(1, (int)Math.Round(widthInches * dpi, MidpointRounding.AwayFromZero));
        int h = Math.Max(1, (int)Math.Round(heightInches * dpi, MidpointRounding.AwayFromZero));
        var pixels = new byte[w * h];
        Array.Fill(pixels, (byte)255);
        int title = Math.Max(1, Round(5, dpi));
        int body = Math.Max(1, Round(2, dpi));
        string? label = BarcodeSeparators.Label(name);

        PatchCodeDetector.DrawText(pixels, w, h, "SEPARATOR SHEET", Round(100, dpi), title);

        // The code with a quiet zone of four modules on every side.
        int side = Math.Max(1, Math.Min(Round(CodeSideHundredths, dpi), w - 2 * Round(100, dpi)));
        int module = Math.Max(1, side / (code.Size + 8));
        int codeSide = module * code.Size;
        int x0 = (w - codeSide) / 2;
        int y0 = Round(CodeTopHundredths, dpi) + 4 * module;
        for (int y = 0; y < code.Size; y++)
        {
            for (int x = 0; x < code.Size; x++)
            {
                if (code[x, y]) PatchCodeDetector.FillRect(pixels, w, h, x0 + x * module, y0 + y * module, module, module, 0);
            }
        }

        int top = y0 + codeSide + 4 * module + Round(30, dpi);
        if (label is not null)
        {
            PatchCodeDetector.DrawText(pixels, w, h, "THE NEXT DOCUMENT IS NAMED", top, body);
            top += 7 * body + Round(20, dpi);
            DrawCaption(pixels, w, h, Caption(label), top, dpi);
        }
        else
        {
            PatchCodeDetector.DrawText(pixels, w, h, "A NEW DOCUMENT STARTS AFTER THIS SHEET.", top, body);
        }
        PatchCodeDetector.DrawText(pixels, w, h,
                                   label is not null ? "PUT THIS SHEET IN FRONT OF THE DOCUMENT IT NAMES." : "PUT THIS SHEET IN FRONT OF EACH DOCUMENT.",
                                   h - Round(150, dpi), body);
        PatchCodeDetector.DrawText(pixels, w, h, "SPLIT INTO DOCUMENTS: AT BARCODE OR QR SHEETS.", h - Round(120, dpi), body);
        return new GrayImage(w, h, pixels, dpi);
    }

    /// <summary>
    /// <paramref name="caption"/> (in the sheet's type) centred with its top at <paramref name="top"/>:
    /// dots of 0.04 in, smaller down to 0.02 in to fit within 0.5 in of the sides, then cut, ending
    /// with "...". Returns the dot size used.
    /// </summary>
    internal static int DrawCaption(byte[] pixels, int w, int h, string caption, int top, int dpi)
    {
        int available = Math.Max(1, w - 2 * Round(50, dpi));
        int cell = Math.Max(1, Round(4, dpi));
        int smallest = Math.Max(1, Round(2, dpi));
        int Width(int count, int dots) => (count * 6 - 1) * dots;
        while (cell > smallest && Width(caption.Length, cell) > available) cell--;
        if (Width(caption.Length, cell) > available)
        {
            int fits = (available / cell + 1) / 6;
            caption = caption[..Math.Max(0, fits - 3)].TrimEnd() + "...";
        }
        PatchCodeDetector.DrawText(pixels, w, h, caption, top, cell);
        return cell;
    }

    /// <summary>"Separator sheet (QR code, Lease 2026, Letter)", or "Separator sheet (QR code, Letter)" with no name: the PDF's name, without its extension.</summary>
    public static string FileBaseName(string? name, PaperSize paper) =>
        BarcodeSeparators.Label(name) is { } label
            ? $"Separator sheet (QR code, {label}, {paper.Label()})"
            : $"Separator sheet (QR code, {paper.Label()})";

    /// <summary>The status after the PDF was saved.</summary>
    public static string SavedMessage(string fileName, string? name) =>
        BarcodeSeparators.Label(name) is { } label
            ? $"Saved the QR separator sheet for “{label}”: {fileName}. Print it and put it in front of that document; the document is named “{label}”."
            : $"Saved the QR separator sheet: {fileName}. Print as many as you need and put one in front of each document.";

    /// <summary>The status after the sheet was sent to <paramref name="printer"/>.</summary>
    public static string PrintedMessage(string printer, string? name) =>
        BarcodeSeparators.Label(name) is { } label
            ? $"Sent the QR separator sheet for “{label}” to {printer}. Put it in front of that document; the document is named “{label}”."
            : $"Sent the QR separator sheet to {printer}. Put one in front of each document; print more copies as you need them.";

    /// <summary>The print job's name.</summary>
    public const string JobName = "Separator sheet (QR code)";

    private static int Round(int hundredths, double dpi) => (int)Math.Round(hundredths * dpi / 100, MidpointRounding.AwayFromZero);
}

/// <summary>
/// Code 39, drawn without a library: the demo scanner's barcode separator sheets
/// (<c>MockBedRenderer.RenderBarcodeSeparatorSheet</c>) and the tests' synthetic pages. Each character
/// is five bars and four spaces, three of them wide; characters are '*'-framed and a narrow space
/// apart. Twin of the Mac's <c>Code39</c>.
/// </summary>
public static class Code39
{
    /// <summary>A wide bar or space is this many narrow ones.</summary>
    public const int WideRatio = 3;

    /// <summary>The bars of each character: bar, space, bar… nine elements, 1 for a wide one.</summary>
    private static readonly Dictionary<char, string> Patterns = new()
    {
        ['0'] = "000110100", ['1'] = "100100001", ['2'] = "001100001", ['3'] = "101100000",
        ['4'] = "000110001", ['5'] = "100110000", ['6'] = "001110000", ['7'] = "000100101",
        ['8'] = "100100100", ['9'] = "001100100", ['A'] = "100001001", ['B'] = "001001001",
        ['C'] = "101001000", ['D'] = "000011001", ['E'] = "100011000", ['F'] = "001011000",
        ['G'] = "000001101", ['H'] = "100001100", ['I'] = "001001100", ['J'] = "000011100",
        ['K'] = "100000011", ['L'] = "001000011", ['M'] = "101000010", ['N'] = "000010011",
        ['O'] = "100010010", ['P'] = "001010010", ['Q'] = "000000111", ['R'] = "100000110",
        ['S'] = "001000110", ['T'] = "000010110", ['U'] = "110000001", ['V'] = "011000001",
        ['W'] = "111000000", ['X'] = "010010001", ['Y'] = "110010000", ['Z'] = "011010000",
        ['-'] = "010000101", ['.'] = "110000100", [' '] = "011000100", ['$'] = "010101000",
        ['/'] = "010100010", ['+'] = "010001010", ['%'] = "000101010", ['*'] = "010010100",
    };

    /// <summary>Whether <paramref name="text"/> can be drawn: not empty, and only 0–9, A–Z, space and - . $ / + %.</summary>
    public static bool CanEncode(string text) => text.Length > 0 && text.All(c => c != '*' && Patterns.ContainsKey(c));

    /// <summary>
    /// The narrow modules of <paramref name="text"/> framed by '*', true for a bar: narrow elements one
    /// module, wide ones <see cref="WideRatio"/>, a narrow space between characters. Empty when
    /// <see cref="CanEncode"/> says no.
    /// </summary>
    public static IReadOnlyList<bool> Modules(string text)
    {
        if (!CanEncode(text)) return [];
        var modules = new List<bool>();
        string framed = "*" + text + "*";
        for (int i = 0; i < framed.Length; i++)
        {
            if (i > 0) modules.Add(false);
            string pattern = Patterns[framed[i]];
            for (int e = 0; e < pattern.Length; e++)
            {
                bool bar = e % 2 == 0;
                int width = pattern[e] == '1' ? WideRatio : 1;
                for (int k = 0; k < width; k++) modules.Add(bar);
            }
        }
        return modules;
    }

    /// <summary>
    /// A barcode separator sheet, <paramref name="widthInches"/> × <paramref name="heightInches"/> at
    /// <paramref name="dpi"/>: white, "SEPARATOR SHEET" at the top, <paramref name="text"/> in Code 39
    /// across the middle (narrow bars 0.02 in, thinner when it would not fit within 0.5 in of the
    /// sides, but never under a pixel; 0.8 in tall) and the text under it in the sheet's type. Text that
    /// can't be drawn gives the sheet without a code.
    /// </summary>
    public static GrayImage RenderSheet(string text, double widthInches, double heightInches, int dpi)
    {
        int w = Math.Max(1, (int)Math.Round(widthInches * dpi, MidpointRounding.AwayFromZero));
        int h = Math.Max(1, (int)Math.Round(heightInches * dpi, MidpointRounding.AwayFromZero));
        var pixels = new byte[w * h];
        Array.Fill(pixels, (byte)255);
        PatchCodeDetector.DrawText(pixels, w, h, "SEPARATOR SHEET", Round(100, dpi), Math.Max(1, Round(5, dpi)));
        var modules = Modules(text);
        int top = Round(180, dpi);
        int height = Math.Max(1, Round(80, dpi));
        if (modules.Count > 0)
        {
            int available = Math.Max(1, w - 2 * Round(50, dpi));
            int module = Math.Max(1, Math.Min(Round(2, dpi), available / modules.Count));
            int x0 = (w - module * modules.Count) / 2;
            for (int i = 0; i < modules.Count; i++)
            {
                if (modules[i]) PatchCodeDetector.FillRect(pixels, w, h, x0 + i * module, top, module, height, 0);
            }
        }
        QrSeparatorSheet.DrawCaption(pixels, w, h, QrSeparatorSheet.Caption(text), top + height + Round(30, dpi), dpi);
        PatchCodeDetector.DrawText(pixels, w, h, "A NEW DOCUMENT STARTS AFTER THIS SHEET.", h - Round(150, dpi), Math.Max(1, Round(2, dpi)));
        return new GrayImage(w, h, pixels, dpi);
    }

    private static int Round(int hundredths, double dpi) => (int)Math.Round(hundredths * dpi / 100, MidpointRounding.AwayFromZero);
}
