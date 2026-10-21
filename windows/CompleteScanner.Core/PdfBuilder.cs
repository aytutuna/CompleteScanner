using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>
/// A page image as a PDF stores it: a JPEG (<see cref="PdfJpegImage"/>) or CCITT G4 data
/// (<see cref="PdfCcittImage"/>). The image may be smaller than the page (a downsampled image,
/// or a preview used when the full-resolution spool file is missing); it is stretched across it.
/// </summary>
/// <param name="Data">The stored bytes.</param>
public abstract record PdfImageData(byte[] Data);

/// <summary>
/// A JPEG, embedded with /DCTDecode. Its dimensions and color space are read from the JPEG
/// itself; a one-component JPEG is embedded as /DeviceGray, anything else as /DeviceRGB.
/// </summary>
public sealed record PdfJpegImage(byte[] Data) : PdfImageData(Data);

/// <summary>
/// A black &amp; white image as CCITT G4 data (<see cref="CcittG4Encoder"/>), embedded as a 1-bit
/// /DeviceGray image with /CCITTFaxDecode (/K -1, /BlackIs1 false: black pixels decode to 0).
/// </summary>
/// <param name="Width">Image width in pixels (/Columns).</param>
/// <param name="Height">Image height in pixels (/Rows).</param>
public sealed record PdfCcittImage(byte[] Data, int Width, int Height) : PdfImageData(Data)
{
    /// <summary>
    /// The page encoded as G4, black where its luma is below <see cref="Bilevel.Threshold"/>
    /// (<see cref="Bilevel.Pack(RgbaImage)"/>).
    /// </summary>
    public static PdfCcittImage Encode(RgbaImage image) =>
        new(CcittG4Encoder.Encode(image), image.Width, image.Height);
}

/// <summary>One page to be written into a PDF.</summary>
/// <param name="Image">The page image (see <see cref="PdfImageData"/>).</param>
/// <param name="PixelWidth">Full-resolution page width in pixels (sizes the media box).</param>
/// <param name="PixelHeight">Full-resolution page height in pixels (sizes the media box).</param>
/// <param name="Dpi">Scan resolution; the PDF page is sized pixels / dpi × 72 points.</param>
/// <param name="OcrLines">
/// Recognized text to embed as an invisible selectable layer, or null for a plain image page.
/// Bounding boxes are normalized with a BOTTOM-LEFT origin (see <see cref="OcrLine"/>).
/// </param>
public sealed record PdfPageInput(PdfImageData Image, int PixelWidth, int PixelHeight, int Dpi,
                                  IReadOnlyList<OcrLine>? OcrLines)
{
    /// <summary>A page whose image is the JPEG <paramref name="jpegData"/> (<see cref="PdfJpegImage"/>).</summary>
    public PdfPageInput(byte[] jpegData, int pixelWidth, int pixelHeight, int dpi, IReadOnlyList<OcrLine>? ocrLines)
        : this(new PdfJpegImage(jpegData), pixelWidth, pixelHeight, dpi, ocrLines)
    {
    }

    /// <summary>The stored image bytes: the JPEG of a JPEG page, the G4 data of a CCITT page.</summary>
    public byte[] JpegData => Image.Data;
}

/// <summary>
/// Minimal, dependency-free PDF writer for scanned pages (its object level has a Swift twin,
/// Sources/CompleteScannerKit/Output/PDFWriter.swift, which the Mac uses for documents with black
/// &amp; white pages; it draws its other PDFs with CGContext's PDF engine in PDFBuilder.swift). It
/// writes PDF 1.4, PDF/A-2b for keeping, or a PDF 1.7 file that opens only with a password
/// (AES-256), as <see cref="PdfWriteOptions"/> ask.
///
/// Each page carries one full-page image XObject: a JPEG (/DeviceRGB, or /DeviceGray for a
/// one-component JPEG) or, for black &amp; white pages, a 1-bit /DeviceGray CCITT G4 image
/// (<see cref="PdfCcittImage"/>); when OCR lines are provided they are drawn with text rendering mode 3
/// (invisible) in the embedded <see cref="GlyphlessFont"/>, horizontally scaled (Tz) so each
/// line's selectable text spans the same width as the printed words. The text is written as
/// UTF-16 code units, so every script survives: selecting, searching and copying give back
/// the recognized text as it was read.
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

    /// <summary>Build the PDF in memory (<paramref name="options"/>: see <see cref="Write"/>).</summary>
    public static byte[] Make(IReadOnlyList<PdfPageInput> pages, Action<string>? progress = null,
                              CancellationToken cancellationToken = default, PdfWriteOptions? options = null)
    {
        using var stream = new MemoryStream();
        Write(pages, stream, progress, cancellationToken, options);
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
                                 CancellationToken cancellationToken = default,
                                 PdfWriteOptions? options = null) =>
        WriteThroughTempFile(pages, path, progress, cancellationToken, options, tmp =>
        {
            File.Move(tmp, path, overwrite: true);
            return path;
        });

    /// <summary>
    /// <see cref="WriteFile"/> for a NEW export: an existing file is never replaced. When
    /// <paramref name="path"/> is taken by the time the PDF is finished (another writer may
    /// have claimed the name while it was being built), the next free " 2", " 3", … name is
    /// used (see <see cref="NamingTemplate.MoveToFreePath"/>). Returns the path written.
    /// When <paramref name="options"/> title the document with the requested file's name
    /// (its name without the extension) and the file ends up under another name, the file is
    /// rewritten in place titled with the name it got, so the title always names the file; if
    /// that rewrite fails, the file keeps the requested title (it is complete and valid).
    /// </summary>
    public static string WriteNewFile(IReadOnlyList<PdfPageInput> pages, string path,
                                      Action<string>? progress = null,
                                      CancellationToken cancellationToken = default,
                                      PdfWriteOptions? options = null)
    {
        string written = WriteThroughTempFile(pages, path, progress, cancellationToken, options,
                                              tmp => NamingTemplate.MoveToFreePath(tmp, path));
        string requestedName = Path.GetFileNameWithoutExtension(path);
        string writtenName = Path.GetFileNameWithoutExtension(written);
        if (options?.Title is { } title && title == requestedName && writtenName != requestedName)
        {
            // The file is already saved: the retitling is not cancelled half-way, and a failure
            // leaves the saved file as it is.
            try
            {
                WriteFile(pages, written, progress: null, CancellationToken.None,
                          options with { Title = writtenName });
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return written;
    }

    private static string WriteThroughTempFile(IReadOnlyList<PdfPageInput> pages, string path,
                                               Action<string>? progress,
                                               CancellationToken cancellationToken,
                                               PdfWriteOptions? options,
                                               Func<string, string> moveIntoPlace)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        string tmp = Path.Combine(directory, $".{Guid.NewGuid()}.pdf.tmp");
        try
        {
            using (var stream = File.Create(tmp))
            {
                SetHidden(tmp, true);
                Write(pages, stream, progress, cancellationToken, options);
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
    internal static void SetHidden(string path, bool hidden)
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
    /// for an all-or-nothing file). <paramref name="options"/> (null: a plain PDF) choose
    /// PDF/A-2b and carry its title, date and file identifier, or protect the file with a
    /// password; options asking for both are refused (<see cref="ArgumentException"/>): PDF/A
    /// forbids encryption.
    /// <para>
    /// Objects are numbered in a fixed order: 1 Catalog, 2 Pages; when any page has text, the six
    /// objects of the text layer's font (Type0 font, CIDFont, FontDescriptor, FontFile2,
    /// CIDToGIDMap, ToUnicode); for PDF/A, the Info dictionary, the XMP Metadata and the sRGB
    /// profile; for a protected file, the Encrypt dictionary; then Page, Image and Contents for
    /// each page.
    /// </para>
    /// <para>
    /// A protected file is PDF 1.7 with Adobe's extension level 8 declared in the catalog (what
    /// AES-256 readers look for), every stream and string encrypted with its own random file key
    /// (<see cref="PdfEncryption"/>), and /Encrypt and /ID in the trailer.
    /// </para>
    /// </summary>
    public static void Write(IReadOnlyList<PdfPageInput> pages, Stream output, Action<string>? progress = null,
                             CancellationToken cancellationToken = default, PdfWriteOptions? options = null)
    {
        options ??= PdfWriteOptions.Standard;
        bool archival = options.IsArchival;
        if (archival && options.IsProtected) throw new ArgumentException(PdfA.CannotProtectNote, nameof(options));
        bool hasText = pages.Any(p => p.OcrLines is { Count: > 0 });
        // The text layer's character codes: characters beyond the BMP get theirs from every line.
        var codes = GlyphlessCodes.For(pages.SelectMany(p => p.OcrLines ?? []).Select(l => l.Text ?? ""));
        // A protected file gets its own random file key; it is wiped once the file is written.
        using var encryption = options.Protection is { } protection ? PdfEncryption.Create(protection, options.Random) : null;
        var w = new PdfObjectWriter(output, encryption);
        w.WriteHeader(archival || encryption is not null ? "1.7" : "1.4");

        int next = 3;
        int fontObject = hasText ? next : 0;
        if (hasText) next += 6;
        int infoObject = archival ? next : 0, metadataObject = infoObject + 1, profileObject = infoObject + 2;
        if (archival) next += 3;
        int encryptObject = encryption is not null ? next++ : 0;
        int firstPageObject = next;
        int ObjPage(int i) => firstPageObject + i * 3;
        int ObjImage(int i) => firstPageObject + 1 + i * 3;
        int ObjContents(int i) => firstPageObject + 2 + i * 3;

        // 1: Catalog
        w.WriteObject(1, archival
            ? $"<</Type /Catalog /Pages 2 0 R /Metadata {metadataObject} 0 R /OutputIntents {PdfA.OutputIntents(profileObject)}>>"
            : encryption is not null
                ? "<</Type /Catalog /Pages 2 0 R /Extensions <</ADBE <</BaseVersion /1.7 /ExtensionLevel 8>>>>>>"
                : "<</Type /Catalog /Pages 2 0 R>>");

        // 2: Pages
        var kids = new StringBuilder();
        for (int i = 0; i < pages.Count; i++)
        {
            if (i > 0) kids.Append(' ');
            kids.Append(ObjPage(i)).Append(" 0 R");
        }
        w.WriteObject(2, $"<</Type /Pages /Kids [{kids}] /Count {pages.Count}>>");

        if (hasText) WriteTextFont(w, fontObject, codes);

        if (archival)
        {
            var date = options.CreationDate ?? DateTimeOffset.Now;
            date = date.AddTicks(-(date.Ticks % TimeSpan.TicksPerSecond)); // whole seconds, as both dates are written
            string? title = options.Title is { } t ? PdfA.CleanTitle(t) : null;
            w.WriteObject(infoObject, PdfA.InfoDictionary(title, date));
            w.WriteStream(metadataObject, "/Type /Metadata /Subtype /XML", PdfA.Xmp(title, date));
            w.WriteStream(profileObject, "/N 3", PdfA.SrgbProfile);
        }

        if (encryption is not null) w.WriteObject(encryptObject, encryption.Dictionary);

        for (int i = 0; i < pages.Count; i++)
        {
            if (cancellationToken.IsCancellationRequested) throw ScanException.Cancelled();
            progress?.Invoke($"Writing page {i + 1} of {pages.Count}…");
            WritePage(w, ObjPage(i), ObjImage(i), ObjContents(i), "2 0 R", i, pages[i], fontObject, codes, "");
        }

        string trailer = "/Root 1 0 R";
        if (archival)
        {
            byte[] id = options.DocumentId is { Length: 16 } given ? given : Guid.NewGuid().ToByteArray();
            string hex = Convert.ToHexString(id);
            trailer += $" /Info {infoObject} 0 R /ID [<{hex}> <{hex}>]";
        }
        else if (encryption is not null)
        {
            // PDF 2.0 asks for the identifier whenever a file is encrypted.
            byte[] id = options.DocumentId is { Length: 16 } given ? given : new byte[16];
            if (options.DocumentId is not { Length: 16 }) (options.Random ?? RandomNumberGenerator.Fill)(id);
            string hex = Convert.ToHexString(id);
            trailer += $" /Encrypt {encryptObject} 0 R /ID [<{hex}> <{hex}>]";
        }
        w.Finish(trailer);
    }

    /// <summary>
    /// One page's three objects: the page (child of <paramref name="parent"/>, its image named
    /// "Im{index}", the font <paramref name="fontObject"/> as /F1 when it has text, then
    /// <paramref name="extraEntries"/> at the end of its dictionary), the image XObject and the
    /// content stream. Shared by <see cref="Write"/> and <see cref="PdfAppender"/>.
    /// </summary>
    internal static void WritePage(PdfObjectWriter w, int pageObject, int imageObject, int contentsObject, string parent,
                                   int index, PdfPageInput page, int fontObject, GlyphlessCodes codes, string extraEntries)
    {
        // PDF media box in points: pixels / dpi × 72.
        double dpi = Math.Max(page.Dpi, 1);
        double widthPts = page.PixelWidth / dpi * 72.0;
        double heightPts = page.PixelHeight / dpi * 72.0;
        bool pageHasText = page.OcrLines is { Count: > 0 };

        string fontResource = pageHasText ? $" /Font <</F1 {fontObject} 0 R>>" : "";
        w.WriteObject(pageObject,
            $"<</Type /Page /Parent {parent} /MediaBox [0 0 {F(widthPts)} {F(heightPts)}] " +
            $"/Resources <</XObject <</Im{index} {imageObject} 0 R>>{fontResource}>> " +
            $"/Contents {contentsObject} 0 R{extraEntries}>>");

        // The XObject must declare the image's own dimensions, which differ from the page's
        // pixel size when only a preview was available or the image was downsampled; the
        // content stream's cm scales the unit-square image onto the full media box either way.
        w.WriteStream(imageObject, ImageEntries(page), page.Image.Data);

        w.WriteStream(contentsObject, "", BuildContentStream(index, widthPts, heightPts, page.OcrLines, codes));
    }

    /// <summary>
    /// The image XObject's dictionary entries (before /Length). A JPEG declares its own frame
    /// size, and /DeviceGray when it has one component; one that cannot be read keeps the
    /// earlier assumption of an RGB image the size of the page. G4 data is a 1-bit gray image.
    /// </summary>
    internal static string ImageEntries(PdfPageInput page)
    {
        if (page.Image is PdfCcittImage g4)
        {
            return $"/Type /XObject /Subtype /Image /Width {g4.Width} /Height {g4.Height} " +
                   "/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode " +
                   $"/DecodeParms <</K -1 /Columns {g4.Width} /Rows {g4.Height} /BlackIs1 false>>";
        }
        if (!TryReadJpegHeader(page.Image.Data, out int imageWidth, out int imageHeight, out int components))
        {
            imageWidth = page.PixelWidth;
            imageHeight = page.PixelHeight;
            components = 3;
        }
        string colorSpace = components == 1 ? "/DeviceGray" : "/DeviceRGB";
        return $"/Type /XObject /Subtype /Image /Width {imageWidth} /Height {imageHeight} " +
               $"/ColorSpace {colorSpace} /BitsPerComponent 8 /Filter /DCTDecode";
    }

    /// <summary>
    /// The text layer's font, objects <paramref name="first"/> to first + 5: a Type0 font with
    /// Identity-H encoding (two-byte codes, see <see cref="GlyphlessCodes"/>) over a CIDFontType2
    /// whose every glyph is <see cref="GlyphlessFont"/>'s empty, half-em-wide glyph 1, embedded,
    /// with a ToUnicode map giving each code back as its character (<paramref name="codes"/>).
    /// The descriptor's /Descent is -1, not the program's 0: macOS' PDFKit reads no text at all
    /// from a font whose descriptor and hhea table both give a descent of 0.
    /// </summary>
    internal static void WriteTextFont(PdfObjectWriter w, int first, GlyphlessCodes codes)
    {
        int cidFont = first + 1, descriptor = first + 2, program = first + 3, cidToGid = first + 4, toUnicode = first + 5;
        string name = GlyphlessFont.FontName;
        w.WriteObject(first,
            $"<</Type /Font /Subtype /Type0 /BaseFont /{name} /Encoding /Identity-H " +
            $"/DescendantFonts [{cidFont} 0 R] /ToUnicode {toUnicode} 0 R>>");
        w.WriteObject(cidFont,
            $"<</Type /Font /Subtype /CIDFontType2 /BaseFont /{name} " +
            $"/CIDSystemInfo <</Registry {w.AsciiString("Adobe")} /Ordering {w.AsciiString("Identity")} /Supplement 0>> " +
            $"/FontDescriptor {descriptor} 0 R /DW {GlyphlessFont.GlyphWidth} /CIDToGIDMap {cidToGid} 0 R>>");
        w.WriteObject(descriptor,
            $"<</Type /FontDescriptor /FontName /{name} /Flags 5 " +
            $"/FontBBox [0 0 {GlyphlessFont.GlyphWidth} {GlyphlessFont.UnitsPerEm}] /ItalicAngle 0 " +
            $"/Ascent {GlyphlessFont.UnitsPerEm} /Descent -1 /CapHeight {GlyphlessFont.UnitsPerEm} /StemV 80 " +
            $"/FontFile2 {program} 0 R>>");
        byte[] font = GlyphlessFont.Program;
        w.WriteStream(program, $"/Length1 {font.Length}", font);
        w.WriteStream(cidToGid, "/Filter /FlateDecode", GlyphlessFont.CidToGidMap);
        w.WriteStream(toUnicode, "", Encoding.ASCII.GetBytes(codes.ToUnicodeCMap()));
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
                                             IReadOnlyList<OcrLine>? lines, GlyphlessCodes codes)
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
                if (TextLayerLine(line, codes, widthPts, heightPts) is not { } placed) continue;
                sb.Append($"/F1 {F(placed.FontSize)} Tf\n");
                sb.Append($"{F(placed.HorizontalScale * 100)} Tz\n");
                sb.Append($"1 0 0 1 {F(placed.X)} {F(placed.Baseline)} Tm\n");
                sb.Append(codes.HexString(line.Text)).Append(" Tj\n");
            }
            sb.Append("ET\n");
        }

        // Pure ASCII: the text is written as hex.
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    /// <summary>
    /// Where one OCR line's invisible text goes, in points: the font size is the box's height and
    /// the baseline its bottom edge (the glyphless font's ascent is a full em and its descent
    /// none, so a selection covers the box), stretched across the box's width by the horizontal
    /// scale (Tz / 100, clamped to 0.2–5).
    /// </summary>
    internal readonly record struct PlacedLine(double FontSize, double HorizontalScale, double X, double Baseline);

    /// <summary>The placement of <paramref name="line"/> on a page of the given size; null for an empty line or box.</summary>
    internal static PlacedLine? TextLayerLine(OcrLine line, GlyphlessCodes codes, double widthPts, double heightPts)
    {
        if (string.IsNullOrEmpty(line.Text)) return null;
        var box = line.BoundingBox.Standardized;
        double targetWidth = box.Width * widthPts;
        double fontSize = box.Height * heightPts;
        if (fontSize <= 0 || targetWidth <= 0) return null;
        double measuredWidth = GlyphlessFont.TextWidth(codes.Codes(line.Text).Count, fontSize);
        double scale = Math.Clamp(targetWidth / measuredWidth, 0.2, 5.0);
        return new PlacedLine(fontSize, scale, box.MinX * widthPts, box.MinY * heightPts);
    }

    /// <summary>Culture-invariant number formatting — PDF syntax requires '.' decimals.</summary>
    internal static string F(double value) => value.ToString("0.####", CultureInfo.InvariantCulture);
}
