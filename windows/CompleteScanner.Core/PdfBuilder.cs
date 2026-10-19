using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>One page to be written into a PDF.</summary>
/// <param name="JpegData">
/// JPEG bytes for the page image (embedded via DCTDecode). The image XObject's dimensions
/// and color space are read from the JPEG itself, so it may be smaller than the page (a
/// downsampled image, or a preview used when the full-resolution spool file is missing) and
/// is stretched across the page; a one-component JPEG is embedded as /DeviceGray.
/// </param>
/// <param name="PixelWidth">Full-resolution page width in pixels (sizes the media box).</param>
/// <param name="PixelHeight">Full-resolution page height in pixels (sizes the media box).</param>
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
/// Each page carries one full-page JPEG XObject (/DeviceRGB, or /DeviceGray for a
/// one-component JPEG); when OCR lines are provided they are drawn
/// with text rendering mode 3 (invisible) in Helvetica, horizontally scaled (Tz) so each
/// line's selectable text spans the same width as the printed words — the same trick the
/// macOS version performs with CoreText. Text is emitted in WinAnsi encoding; characters
/// outside it degrade to '?' in the invisible layer (the visible page is unaffected).
/// </summary>
public static class PdfBuilder
{
    /// <summary>
    /// The pixels and recorded dimensions of one queued page, ready to be OCR'd and
    /// JPEG-encoded into a <see cref="PdfPageInput"/>, with the user's page rotation applied.
    /// </summary>
    /// <param name="Image">Page pixels, already showing <see cref="ScannedPage.RotationQuarterTurns"/>.</param>
    /// <param name="PixelWidth">Width for the media box (full-resolution, post-rotation).</param>
    /// <param name="PixelHeight">Height for the media box (full-resolution, post-rotation).</param>
    public sealed record PreparedPage(RgbaImage Image, int PixelWidth, int PixelHeight);

    /// <summary>
    /// Resolve the image and media-box dimensions for one queued page — the per-page head of
    /// the Swift PDFBuilder loop. Spilled pages hold only a preview in memory, so the caller
    /// reloads the full-resolution UNROTATED pixels from <see cref="ScannedPage.FilePath"/>
    /// and passes them as <paramref name="spoolImage"/> (null when the page was never spooled
    /// or the file is missing/unreadable). The media box comes from the recorded
    /// full-resolution size, so the physical page size stays correct even when only the
    /// preview pixels are available.
    /// </summary>
    public static PreparedPage PreparePage(ScannedPage page, RgbaImage? spoolImage)
    {
        int turns = ((page.RotationQuarterTurns % 4) + 4) % 4;
        bool swapsAxes = turns % 2 == 1;
        if (spoolImage is { } full)
        {
            // The spool file is unrotated; apply the user's page rotation now, and
            // swap the recorded dimensions for odd quarter turns.
            var image = turns == 0 ? full : ImagePipeline.Rotate(full, turns);
            int rawWidth = page.FullPixelSize is { } size ? (int)size.Width : full.Width;
            int rawHeight = page.FullPixelSize is { } sizeH ? (int)sizeH.Height : full.Height;
            return new PreparedPage(image, swapsAxes ? rawHeight : rawWidth,
                                    swapsAxes ? rawWidth : rawHeight);
        }
        // Missing/unreadable spill file (or the page was never spooled): fall back to the
        // in-memory image, which ALREADY carries the rotation.
        if (page.FullPixelSize is { } recorded)
        {
            // Recorded pre-rotation full-resolution size: swap for odd turns.
            return new PreparedPage(page.Image,
                                    swapsAxes ? (int)recorded.Height : (int)recorded.Width,
                                    swapsAxes ? (int)recorded.Width : (int)recorded.Height);
        }
        return new PreparedPage(page.Image, page.Image.Width, page.Image.Height);
    }

    /// <summary>Build the PDF in memory.</summary>
    public static byte[] Make(IReadOnlyList<PdfPageInput> pages, Action<string>? progress = null,
                              CancellationToken cancellationToken = default)
    {
        using var stream = new MemoryStream();
        Write(pages, stream, progress, cancellationToken);
        return stream.ToArray();
    }

    /// <summary>
    /// Write the PDF to a temporary file next to <paramref name="path"/> and move it into
    /// place, so a failed or cancelled build never leaves a truncated PDF at the destination
    /// (an existing file there is replaced only on success). The temporary file is named
    /// ".{guid}.pdf.tmp" (dot-hidden on macOS/Linux) and, on Windows, also carries the
    /// Hidden attribute while it is being written; the attribute is cleared before the move,
    /// so the finished PDF is always visible.
    /// </summary>
    public static void WriteFile(IReadOnlyList<PdfPageInput> pages, string path,
                                 Action<string>? progress = null,
                                 CancellationToken cancellationToken = default) =>
        WriteThroughTempFile(pages, path, progress, cancellationToken, tmp =>
        {
            File.Move(tmp, path, overwrite: true);
            return path;
        });

    /// <summary>
    /// <see cref="WriteFile"/> for a NEW export: an existing file is never replaced. When
    /// <paramref name="path"/> is taken by the time the PDF is finished (another writer may
    /// have claimed the name while it was being built), the next free " 2", " 3", … name is
    /// used (see <see cref="NamingTemplate.MoveToFreePath"/>). Returns the path written.
    /// </summary>
    public static string WriteNewFile(IReadOnlyList<PdfPageInput> pages, string path,
                                      Action<string>? progress = null,
                                      CancellationToken cancellationToken = default) =>
        WriteThroughTempFile(pages, path, progress, cancellationToken,
                             tmp => NamingTemplate.MoveToFreePath(tmp, path));

    private static string WriteThroughTempFile(IReadOnlyList<PdfPageInput> pages, string path,
                                               Action<string>? progress,
                                               CancellationToken cancellationToken,
                                               Func<string, string> moveIntoPlace)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        string tmp = Path.Combine(directory, $".{Guid.NewGuid()}.pdf.tmp");
        try
        {
            using (var stream = File.Create(tmp))
            {
                SetHidden(tmp, true);
                Write(pages, stream, progress, cancellationToken);
            }
            // Clear Hidden first: the move carries the source's attributes to the destination.
            SetHidden(tmp, false);
            string written = moveIntoPlace(tmp);
            SetHidden(written, false); // in case clearing the temp file's attribute failed
            return written;
        }
        catch
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw;
        }
    }

    /// <summary>
    /// Best-effort toggle of the Windows Hidden attribute (other platforms hide by the
    /// leading dot alone, so this is a no-op there). Never throws: a temp file that stays
    /// visible is cosmetic, not a reason to fail the save.
    /// </summary>
    private static void SetHidden(string path, bool hidden)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            var attributes = File.GetAttributes(path);
            var updated = hidden ? attributes | FileAttributes.Hidden : attributes & ~FileAttributes.Hidden;
            if (updated == 0) updated = FileAttributes.Normal;
            if (updated != attributes) File.SetAttributes(path, updated);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Cosmetic only.
        }
    }

    /// <summary>
    /// Stream the PDF to <paramref name="output"/> — never holds the whole document in memory.
    /// <paramref name="cancellationToken"/> is polled before each page; cancellation aborts
    /// with <see cref="ScanException"/> (<see cref="ScanErrorKind.Cancelled"/>), leaving
    /// <paramref name="output"/> holding an incomplete document (use <see cref="WriteFile"/>
    /// for an all-or-nothing file).
    /// </summary>
    public static void Write(IReadOnlyList<PdfPageInput> pages, Stream output, Action<string>? progress = null,
                             CancellationToken cancellationToken = default)
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
            if (cancellationToken.IsCancellationRequested) throw ScanException.Cancelled();
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

            // The XObject must declare the JPEG's own dimensions, which differ from the page's
            // pixel size when only a preview was available; the content stream's cm scales
            // the unit-square image onto the full media box either way.
            // A gray JPEG (one component) must be declared /DeviceGray; anything unreadable
            // keeps the earlier assumption of an RGB image the size of the page.
            if (!TryReadJpegHeader(page.JpegData, out int imageWidth, out int imageHeight, out int components))
            {
                imageWidth = page.PixelWidth;
                imageHeight = page.PixelHeight;
                components = 3;
            }
            string colorSpace = components == 1 ? "/DeviceGray" : "/DeviceRGB";
            BeginObj(ObjImage(i));
            w.WriteAscii($"<</Type /XObject /Subtype /Image /Width {imageWidth} " +
                         $"/Height {imageHeight} /ColorSpace {colorSpace} /BitsPerComponent 8 " +
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

    // MARK: - JPEG header

    /// <summary>The frame size of a JPEG (see <see cref="TryReadJpegHeader"/>).</summary>
    internal static bool TryReadJpegSize(ReadOnlySpan<byte> jpeg, out int width, out int height) =>
        TryReadJpegHeader(jpeg, out width, out height, out _);

    /// <summary>
    /// Read the frame size and component count (1 = gray, 3 = color) from a JPEG's
    /// start-of-frame segment (SOF0 baseline, SOF1, SOF2 progressive, or any other SOFn).
    /// Walks the marker segments from SOI by their length fields — so APPn payloads (EXIF,
    /// ICC, thumbnails) that happen to contain marker-like bytes are skipped — and gives up at
    /// SOS/EOI or on any malformed or truncated segment. Twin of
    /// <c>PDFImageEncoding.readJPEGHeader</c> on macOS.
    /// </summary>
    internal static bool TryReadJpegHeader(ReadOnlySpan<byte> jpeg, out int width, out int height,
                                           out int components)
    {
        width = 0;
        height = 0;
        components = 0;
        if (jpeg.Length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return false;
        int pos = 2;
        while (pos < jpeg.Length)
        {
            if (jpeg[pos] != 0xFF) return false;
            // Any number of 0xFF fill bytes may precede a marker code.
            while (pos < jpeg.Length && jpeg[pos] == 0xFF) pos++;
            if (pos >= jpeg.Length) return false;
            byte marker = jpeg[pos++];

            // Standalone markers carry no length: TEM, RSTn, SOI.
            if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
            // Scan data or the end of the image before any frame header: no size to be had.
            if (marker == 0xDA || marker == 0xD9 || marker == 0x00) return false;

            if (pos + 2 > jpeg.Length) return false;
            int length = (jpeg[pos] << 8) | jpeg[pos + 1];
            if (length < 2 || pos + length > jpeg.Length) return false;

            // SOF0...SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
            bool isFrame = marker >= 0xC0 && marker <= 0xCF &&
                           marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
            if (isFrame)
            {
                // Length(2) precision(1) height(2) width(2) components(1) ...
                if (length < 8) return false;
                height = (jpeg[pos + 3] << 8) | jpeg[pos + 4];
                width = (jpeg[pos + 5] << 8) | jpeg[pos + 6];
                components = jpeg[pos + 7];
                // Height 0 means "defined later by DNL"; treat it as unknown.
                return width > 0 && height > 0 && components > 0;
            }
            pos += length;
        }
        return false;
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
