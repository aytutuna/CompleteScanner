using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>One page to be written into a PDF.</summary>
/// <param name="JpegData">Baseline JPEG bytes for the page image (embedded via DCTDecode).</param>
/// <param name="PixelWidth">Image width in pixels.</param>
/// <param name="PixelHeight">Image height in pixels.</param>
/// <param name="Dpi">Scan resolution; the PDF page is sized pixels / dpi × 72 points.</param>
/// <param name="OcrLines">
/// Recognized text to embed as an invisible selectable layer, or null for a plain image page.
/// Bounding boxes are normalized with a BOTTOM-LEFT origin (see <see cref="OcrLine"/>).
/// </param>
public sealed record PdfPageInput(byte[] JpegData, int PixelWidth, int PixelHeight, int Dpi,
                                  IReadOnlyList<OcrLine>? OcrLines);

/// <summary>
/// Minimal, dependency-free PDF 1.4 writer for scanned pages, ported from
/// Sources/CompleteScannerKit/Output/PDFBuilder.swift (which uses CGContext's PDF engine).
///
/// Each page carries one full-page JPEG XObject; when OCR lines are provided they are drawn
/// with text rendering mode 3 (invisible) in Helvetica, horizontally scaled (Tz) so each
/// line's selectable text spans the same width as the printed words — the same trick the
/// macOS version performs with CoreText. Text is emitted in WinAnsi encoding; characters
/// outside it degrade to '?' in the invisible layer (the visible page is unaffected).
/// </summary>
public static class PdfBuilder
{
    /// <summary>Build the PDF in memory.</summary>
    public static byte[] Make(IReadOnlyList<PdfPageInput> pages, Action<string>? progress = null)
    {
        using var stream = new MemoryStream();
        Write(pages, stream, progress);
        return stream.ToArray();
    }

    /// <summary>Stream the PDF to <paramref name="output"/> — never holds the whole document in memory.</summary>
    public static void Write(IReadOnlyList<PdfPageInput> pages, Stream output, Action<string>? progress = null)
    {
        var w = new CountingWriter(output);
        var offsets = new List<long>(); // offsets[i] = byte offset of object i+1

        w.WriteAscii("%PDF-1.4\n");
        w.WriteBytes([(byte)'%', 0xE2, 0xE3, 0xCF, 0xD3, (byte)'\n']); // binary marker

        // Object layout: 1 Catalog, 2 Pages, 3 Font, then per page i: Page, Image, Contents.
        int ObjPage(int i) => 4 + i * 3;
        int ObjImage(int i) => 5 + i * 3;
        int ObjContents(int i) => 6 + i * 3;

        void BeginObj(int number)
        {
            while (offsets.Count < number) offsets.Add(0);
            offsets[number - 1] = w.Position;
            w.WriteAscii($"{number} 0 obj\n");
        }

        // 1: Catalog
        BeginObj(1);
        w.WriteAscii("<</Type /Catalog /Pages 2 0 R>>\nendobj\n");

        // 2: Pages
        BeginObj(2);
        var kids = new StringBuilder();
        for (int i = 0; i < pages.Count; i++)
        {
            if (i > 0) kids.Append(' ');
            kids.Append(ObjPage(i)).Append(" 0 R");
        }
        w.WriteAscii($"<</Type /Pages /Kids [{kids}] /Count {pages.Count}>>\nendobj\n");

        // 3: Font (standard-14 Helvetica: no embedding needed)
        BeginObj(3);
        w.WriteAscii("<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>\nendobj\n");

        for (int i = 0; i < pages.Count; i++)
        {
            progress?.Invoke($"Writing page {i + 1} of {pages.Count}…");
            var page = pages[i];
            // PDF media box in points: pixels / dpi × 72.
            double dpi = Math.Max(page.Dpi, 1);
            double widthPts = page.PixelWidth / dpi * 72.0;
            double heightPts = page.PixelHeight / dpi * 72.0;

            BeginObj(ObjPage(i));
            w.WriteAscii($"<</Type /Page /Parent 2 0 R /MediaBox [0 0 {F(widthPts)} {F(heightPts)}] " +
                         $"/Resources <</XObject <</Im{i} {ObjImage(i)} 0 R>> /Font <</F1 3 0 R>>>> " +
                         $"/Contents {ObjContents(i)} 0 R>>\nendobj\n");

            BeginObj(ObjImage(i));
            w.WriteAscii($"<</Type /XObject /Subtype /Image /Width {page.PixelWidth} " +
                         $"/Height {page.PixelHeight} /ColorSpace /DeviceRGB /BitsPerComponent 8 " +
                         $"/Filter /DCTDecode /Length {page.JpegData.Length}>>\nstream\n");
            w.WriteBytes(page.JpegData);
            w.WriteAscii("\nendstream\nendobj\n");

            byte[] content = BuildContentStream(i, widthPts, heightPts, page.OcrLines);
            BeginObj(ObjContents(i));
            w.WriteAscii($"<</Length {content.Length}>>\nstream\n");
            w.WriteBytes(content);
            w.WriteAscii("\nendstream\nendobj\n");
        }

        // xref + trailer
        long xrefStart = w.Position;
        w.WriteAscii($"xref\n0 {offsets.Count + 1}\n");
        w.WriteAscii("0000000000 65535 f \n");
        foreach (long offset in offsets)
        {
            w.WriteAscii(offset.ToString("D10", CultureInfo.InvariantCulture) + " 00000 n \n");
        }
        w.WriteAscii($"trailer\n<</Size {offsets.Count + 1} /Root 1 0 R>>\nstartxref\n{xrefStart}\n%%EOF\n");
        output.Flush();
    }

    // MARK: - Content stream

    private static byte[] BuildContentStream(int pageIndex, double widthPts, double heightPts,
                                             IReadOnlyList<OcrLine>? lines)
    {
        var sb = new StringBuilder();
        // Draw the page image across the full media box.
        sb.Append($"q\n{F(widthPts)} 0 0 {F(heightPts)} 0 0 cm\n/Im{pageIndex} Do\nQ\n");

        if (lines is { Count: > 0 })
        {
            // Invisible text layer: mode 3 = neither fill nor stroke, but selectable/searchable.
            // OCR boxes are normalized with a bottom-left origin — the same origin as PDF user
            // space — so they map straight into points with no flip.
            sb.Append("BT\n3 Tr\n");
            foreach (var line in lines)
            {
                if (string.IsNullOrEmpty(line.Text)) continue;
                var box = line.BoundingBox.Standardized;
                double x = box.MinX * widthPts;
                double y = box.MinY * heightPts;
                double targetWidth = box.Width * widthPts;
                double boxHeightPts = box.Height * heightPts;

                double fontSize = boxHeightPts * 0.85;
                if (fontSize <= 0 || targetWidth <= 0) continue;

                double measuredWidth = HelveticaWidth(line.Text) / 1000.0 * fontSize;
                if (measuredWidth <= 0) continue;
                double scaleX = Math.Clamp(targetWidth / measuredWidth, 0.2, 5.0);

                // Baseline sits a little above the box bottom so descenders line up
                // (Helvetica's descender is 207/1000 of the em).
                double baselineY = y + 0.207 * fontSize;

                sb.Append($"/F1 {F(fontSize)} Tf\n");
                sb.Append($"{F(scaleX * 100)} Tz\n");
                sb.Append($"1 0 0 1 {F(x)} {F(baselineY)} Tm\n");
                sb.Append('(').Append(EscapePdfText(line.Text)).Append(") Tj\n");
            }
            sb.Append("ET\n");
        }

        // Latin-1 keeps 128–255 as single bytes for WinAnsi (close enough for invisible text).
        return Encoding.Latin1.GetBytes(sb.ToString());
    }

    private static string EscapePdfText(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '(': sb.Append("\\("); break;
                case ')': sb.Append("\\)"); break;
                case '\r': sb.Append("\\r"); break;
                case '\n': sb.Append("\\n"); break;
                default: sb.Append(c <= 255 ? c : '?'); break;
            }
        }
        return sb.ToString();
    }

    /// <summary>Culture-invariant number formatting — PDF syntax requires '.' decimals.</summary>
    private static string F(double value) => value.ToString("0.####", CultureInfo.InvariantCulture);

    // MARK: - Helvetica metrics (AFM widths, 1000-unit em)

    /// <summary>Sum of Helvetica AFM widths for the string, in 1000-unit em space.</summary>
    private static double HelveticaWidth(string text)
    {
        double total = 0;
        foreach (char c in text)
        {
            total += c >= 32 && c < 32 + HelveticaWidths.Length ? HelveticaWidths[c - 32] : 556;
        }
        return total;
    }

    /// <summary>Standard Helvetica AFM widths for ASCII 32..126.</summary>
    private static readonly short[] HelveticaWidths =
    [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, // sp..'/'
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 0..'?'
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // @..O
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // P.._
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // `..o
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,      // p..~
    ];

    // MARK: - Counting writer

    /// <summary>Wraps the output stream and tracks the byte position for the xref table.</summary>
    private sealed class CountingWriter(Stream stream)
    {
        public long Position { get; private set; }

        public void WriteBytes(byte[] bytes)
        {
            stream.Write(bytes, 0, bytes.Length);
            Position += bytes.Length;
        }

        public void WriteAscii(string text) => WriteBytes(Encoding.ASCII.GetBytes(text));
    }
}
