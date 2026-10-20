using System.Text;
using CompleteScanner.Core;
using UglyToad.PdfPig;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Windows-side structural tests for the hand-rolled PDF writer (the macOS app delegates to
// CGContext's PDF engine until the port of this writer, so most of these have no Swift counterpart
// yet; MakePdfTwoPages ports OutputTests.test_makePDFTwoPages). They validate document structure
// and, through PdfPig (a test-only package), what a PDF reader gets out of the file: pages, the
// text layer in any script. Not pixel rendering — open the output in a viewer for a visual check.

public class PdfBuilderTests
{
    /// <summary>A tiny valid baseline JPEG (1x1 white) for structure tests.</summary>
    internal static readonly byte[] TinyJpeg =
    [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
        0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
        0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
        0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
        0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
        0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
        0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
        0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD0, 0xFF, 0xD9,
    ];

    private static PdfPageInput Page(IReadOnlyList<OcrLine>? lines = null, int dpi = 300) =>
        new(TinyJpeg, 100, 150, dpi, lines);

    [Fact]
    public void HeaderAndTrailerPresent()
    {
        byte[] pdf = PdfBuilder.Make([Page()]);
        string text = Encoding.Latin1.GetString(pdf);
        Assert.StartsWith("%PDF-1.4", text);
        Assert.EndsWith("%%EOF\n", text);
        Assert.Contains("startxref", text);
    }

    [Fact]
    public void PageCountMatches()
    {
        byte[] pdf = PdfBuilder.Make([Page(), Page(), Page()]);
        string text = Encoding.Latin1.GetString(pdf);
        Assert.Contains("/Count 3", text);
        Assert.Contains("/Im0", text);
        Assert.Contains("/Im2", text);
    }

    [Fact]
    public void MediaBoxIsPixelsOverDpiTimes72()
    {
        // 100 px / 300 dpi * 72 = 24 pt; 150 px -> 36 pt.
        byte[] pdf = PdfBuilder.Make([Page(dpi: 300)]);
        string text = Encoding.Latin1.GetString(pdf);
        Assert.Contains("/MediaBox [0 0 24 36]", text);
    }

    [Fact]
    public void InvisibleTextLayerEmittedForOcrLines()
    {
        var lines = new List<OcrLine>
        {
            new("hello world", new RectD(0.1, 0.8, 0.5, 0.05), 0.95f),
        };
        byte[] pdf = PdfBuilder.Make([Page(lines)]);
        string text = Encoding.Latin1.GetString(pdf);
        Assert.Contains("3 Tr", text);                  // invisible text rendering mode
        Assert.Contains("<00680065006C006C006F00200077006F0072006C0064> Tj", text); // UTF-16 code units
        Assert.Contains("/Subtype /Type0 /BaseFont /GlyphLessFont /Encoding /Identity-H", text);
        Assert.DoesNotContain("Helvetica", text);
    }

    [Fact]
    public void NoTextLayerWithoutOcrLines()
    {
        byte[] pdf = PdfBuilder.Make([Page()]);
        string text = Encoding.Latin1.GetString(pdf);
        Assert.DoesNotContain("3 Tr", text);
        Assert.DoesNotContain("BT", text.Split("stream")[^1]); // no stray text operators
        // No page has text: the font is left out altogether.
        Assert.DoesNotContain("/Font", text);
        Assert.Contains("1 0 obj\n<</Type /Catalog /Pages 2 0 R>>", text);
        Assert.Contains("3 0 obj\n<</Type /Page /Parent 2 0 R", text);
    }

    [Fact]
    public void TextNeedsNoEscaping_ItIsWrittenAsHex()
    {
        var lines = new List<OcrLine>
        {
            new("a(b)c\\d", new RectD(0.1, 0.5, 0.4, 0.05), 0.9f),
        };
        byte[] pdf = PdfBuilder.Make([Page(lines)]);
        string text = Encoding.Latin1.GetString(pdf);
        Assert.Contains("<00610028006200290063005C0064> Tj", text);
        using var document = PdfDocument.Open(pdf);
        Assert.Equal("a(b)c\\d", document.GetPage(1).Text);
    }

    [Fact]
    public void XrefOffsetsPointAtObjects()
    {
        byte[] pdf = PdfBuilder.Make([Page()]);
        string text = Encoding.Latin1.GetString(pdf);

        // startxref points at the xref table.
        int startxrefIdx = text.LastIndexOf("startxref", StringComparison.Ordinal);
        long xrefOffset = long.Parse(text[(startxrefIdx + "startxref".Length)..]
            .Trim().Split('\n')[0]);
        Assert.Equal("xref", text.Substring((int)xrefOffset, 4));

        // Every in-use entry must point at "<n> 0 obj".
        int entriesStart = text.IndexOf("xref", (int)xrefOffset, StringComparison.Ordinal);
        var lines = text[entriesStart..].Split('\n');
        int objectNumber = 0;
        foreach (var line in lines.Skip(2)) // skip "xref" and "0 N"
        {
            if (!line.EndsWith("n ")) { if (objectNumber > 0) break; objectNumber++; continue; }
            long offset = long.Parse(line[..10]);
            Assert.Equal($"{objectNumber} 0 obj", text.Substring((int)offset, $"{objectNumber} 0 obj".Length));
            objectNumber++;
        }
    }

    // MARK: - Port of OutputTests.test_makePDFTwoPages

    [Fact]
    public void MakePdfTwoPages()
    {
        var pages = new[]
        {
            new PdfPageInput(TinyJpeg, 400, 300, 100, null),
            new PdfPageInput(TinyJpeg, 400, 300, 100, null),
        };
        string text = Encoding.Latin1.GetString(PdfBuilder.Make(pages));
        Assert.Contains("/Count 2", text);
        // 400 px / 100 dpi * 72 = 288 pt; 300 px / 100 dpi * 72 = 216 pt.
        Assert.Equal(2, CountOccurrences(text, "/MediaBox [0 0 288 216]"));
    }

    private static int CountOccurrences(string text, string needle)
    {
        int count = 0;
        for (int i = text.IndexOf(needle, StringComparison.Ordinal); i >= 0;
             i = text.IndexOf(needle, i + needle.Length, StringComparison.Ordinal))
        {
            count++;
        }
        return count;
    }

    // MARK: - Page rotation at save (PreparePage)

    /// <summary>Gray image with a red pixel at the top-left corner.</summary>
    private static RgbaImage Marked(int width, int height)
    {
        var image = RgbaImage.Filled(width, height, 128, 128, 128);
        image.Pixels[0] = 255;
        image.Pixels[1] = 0;
        image.Pixels[2] = 0;
        return image;
    }

    private static bool IsRed(RgbaImage image, int x, int y)
    {
        int i = (y * image.Width + x) * 4;
        return image.Pixels[i] == 255 && image.Pixels[i + 1] == 0 && image.Pixels[i + 2] == 0;
    }

    /// <summary>MediaBox of a one-page PDF built from a prepared page (72 dpi: points = pixels).</summary>
    private static string MediaBoxOf(PdfBuilder.PreparedPage prepared)
    {
        var input = new PdfPageInput(TinyJpeg, prepared.PixelWidth, prepared.PixelHeight, 72, null);
        string text = Encoding.Latin1.GetString(PdfBuilder.Make([input]));
        int start = text.IndexOf("/MediaBox [", StringComparison.Ordinal);
        return text[start..(text.IndexOf(']', start) + 1)];
    }

    [Theory]
    [InlineData(1)]
    [InlineData(3)]
    [InlineData(-1)]
    [InlineData(5)]
    public void OddTurnsSwapPageWidthAndHeight(int turns)
    {
        var spool = Marked(40, 20);
        var page = new ScannedPage(spool, 72, ColorMode.Color) { RotationQuarterTurns = turns };
        var prepared = PdfBuilder.PreparePage(page, spool);
        Assert.Equal(20, prepared.Image.Width);
        Assert.Equal(40, prepared.Image.Height);
        Assert.Equal("/MediaBox [0 0 20 40]", MediaBoxOf(prepared));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(2)]
    [InlineData(4)]
    public void EvenTurnsKeepPageWidthAndHeight(int turns)
    {
        var spool = Marked(40, 20);
        var page = new ScannedPage(spool, 72, ColorMode.Color) { RotationQuarterTurns = turns };
        var prepared = PdfBuilder.PreparePage(page, spool);
        Assert.Equal("/MediaBox [0 0 40 20]", MediaBoxOf(prepared));
        if (turns % 4 == 0) Assert.Same(spool, prepared.Image); // 4 turns = no rotation at all
        else Assert.True(IsRed(prepared.Image, 39, 19), "180°: top-left lands bottom-right");
    }

    [Fact]
    public void SpoolImageIsRotatedClockwiseAndUsesRecordedSize()
    {
        // Spooled page: in-memory preview at half resolution, full pixels in the spool.
        var full = Marked(40, 20);
        var preview = Marked(20, 10);
        var page = new ScannedPage(preview, 72, ColorMode.Color, filePath: "spool.png",
                                   fullPixelSize: new SizeD(40, 20)).RotatedClockwise();
        Assert.Equal(1, page.RotationQuarterTurns);

        var prepared = PdfBuilder.PreparePage(page, full);
        Assert.Equal(20, prepared.Image.Width);
        Assert.Equal(40, prepared.Image.Height);
        Assert.True(IsRed(prepared.Image, 19, 0), "clockwise: top-left lands top-right");
        Assert.Equal("/MediaBox [0 0 20 40]", MediaBoxOf(prepared));
    }

    [Fact]
    public void MissingSpoolFallsBackWithoutDoubleRotation()
    {
        var preview = Marked(20, 10);
        var page = new ScannedPage(preview, 72, ColorMode.Color, filePath: "missing.png",
                                   fullPixelSize: new SizeD(40, 20)).RotatedClockwise();

        var prepared = PdfBuilder.PreparePage(page, spoolImage: null);
        // The in-memory image already carries the rotation: used as-is.
        Assert.Same(page.Image, prepared.Image);
        Assert.Equal(10, prepared.Image.Width);
        Assert.Equal(20, prepared.Image.Height);
        // The recorded (pre-rotation) full size is swapped for the odd turn.
        Assert.Equal("/MediaBox [0 0 20 40]", MediaBoxOf(prepared));
    }

    [Fact]
    public void UnspooledPageUsesInMemoryImage()
    {
        var image = Marked(40, 20);
        var page = new ScannedPage(image, 72, ColorMode.Color).RotatedClockwise();
        var prepared = PdfBuilder.PreparePage(page, spoolImage: null);
        Assert.Same(page.Image, prepared.Image);
        Assert.Equal("/MediaBox [0 0 20 40]", MediaBoxOf(prepared));
    }

    // MARK: - Image XObject size comes from the JPEG

    /// <summary>
    /// Hand-assembled JPEG header (Core has no encoder): SOI, APP0 JFIF, optionally an APP1
    /// EXIF segment whose payload contains a decoy SOF0 and EOI, DQT, DHT, fill bytes, the
    /// frame header with the given marker and size, then SOS, a little scan data and EOI.
    /// Only the marker structure is real — enough for the header parser and the PDF writer.
    /// </summary>
    private static byte[] SyntheticJpeg(int width, int height, byte sofMarker = 0xC0, bool withExif = false)
    {
        var bytes = new List<byte> { 0xFF, 0xD8 };
        void Segment(byte marker, params byte[] payload)
        {
            int length = payload.Length + 2;
            bytes.AddRange([0xFF, marker, (byte)(length >> 8), (byte)length]);
            bytes.AddRange(payload);
        }
        Segment(0xE0, [.. "JFIF\0"u8, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
        if (withExif)
        {
            // A decoy frame header (and EOI) inside the APP1 payload: only a length-driven
            // walk skips it; a naive scan for FF C0 would report 4095 x 4095.
            Segment(0xE1, [.. "Exif\0\0"u8, 0x4D, 0x4D, 0x00, 0x2A,
                           0xFF, 0xC0, 0x00, 0x11, 0x08, 0x0F, 0xFF, 0x0F, 0xFF, 0x03,
                           0xFF, 0xD9, 0x00, 0x00]);
        }
        Segment(0xDB, [0x00, .. Enumerable.Repeat((byte)1, 64)]);
        Segment(0xC4, [0x00, .. Enumerable.Repeat((byte)0, 16), 0x00]);
        bytes.AddRange([0xFF, 0xFF]); // fill bytes before the next marker are legal
        Segment(sofMarker, [0x08, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width,
                            0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
        Segment(0xDA, [0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00]);
        bytes.AddRange([0x12, 0x34, 0xFF, 0x00, 0x56, 0xFF, 0xD9]);
        return [.. bytes];
    }

    [Theory]
    [InlineData((byte)0xC0, false)] // baseline
    [InlineData((byte)0xC0, true)]
    [InlineData((byte)0xC1, true)]  // extended sequential
    [InlineData((byte)0xC2, false)] // progressive
    [InlineData((byte)0xC2, true)]
    public void JpegSizeIsReadFromFrameHeader(byte sofMarker, bool withExif)
    {
        Assert.True(PdfBuilder.TryReadJpegSize(SyntheticJpeg(1275, 1650, sofMarker, withExif),
                                               out int width, out int height));
        Assert.Equal(1275, width);
        Assert.Equal(1650, height);
    }

    [Fact]
    public void JpegSizeOfRealBaselineJpeg()
    {
        Assert.True(PdfBuilder.TryReadJpegSize(TinyJpeg, out int width, out int height));
        Assert.Equal((1, 1), (width, height));
    }

    [Fact]
    public void JpegHeaderReadsTheComponentCount()
    {
        Assert.True(PdfBuilder.TryReadJpegHeader(TinyJpeg, out _, out _, out int gray));
        Assert.Equal(1, gray);
        Assert.True(PdfBuilder.TryReadJpegHeader(SyntheticJpeg(640, 480, 0xC2, withExif: true),
                                                 out int width, out int height, out int color));
        Assert.Equal((640, 480, 3), (width, height, color));
    }

    [Fact]
    public void GrayJpegIsEmbeddedAsDeviceGray()
    {
        // TinyJpeg has one component: a gray page image.
        string image = ImageDictionaryOf(Encoding.Latin1.GetString(PdfBuilder.Make([Page()])));
        Assert.Contains("/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", image);
        Assert.DoesNotContain("DeviceRGB", image);
    }

    [Fact]
    public void ColorJpegIsEmbeddedAsDeviceRgb_AndBothKindsMix()
    {
        var color = new PdfPageInput(SyntheticJpeg(100, 150), 100, 150, 300, null);
        string text = Encoding.Latin1.GetString(PdfBuilder.Make([color, Page(), color]));
        Assert.Contains("/ColorSpace /DeviceRGB", ImageDictionaryOf(text));
        Assert.Equal(2, text.Split("/ColorSpace /DeviceRGB").Length - 1);
        Assert.Equal(1, text.Split("/ColorSpace /DeviceGray").Length - 1);
    }

    [Fact]
    public void UnreadableJpegIsDeclaredRgb()
    {
        var page = new PdfPageInput([0xFF, 0xD8, 0xFF, 0xD9], 100, 150, 300, null);
        Assert.Contains("/ColorSpace /DeviceRGB", ImageDictionaryOf(Encoding.Latin1.GetString(PdfBuilder.Make([page]))));
    }

    [Fact]
    public void MalformedJpegHeadersAreRejected()
    {
        var good = SyntheticJpeg(640, 480, withExif: true);
        int sofIndex = Enumerable.Range(0, good.Length - 1)
            .Last(i => good[i] == 0xFF && good[i + 1] == 0xC0); // the real frame header, after the decoy
        Assert.False(PdfBuilder.TryReadJpegSize([], out _, out _));
        Assert.False(PdfBuilder.TryReadJpegSize("%PDF-1.4"u8.ToArray(), out _, out _));
        Assert.False(PdfBuilder.TryReadJpegSize(good.AsSpan(0, sofIndex + 6), out _, out _)); // truncated frame header
        Assert.False(PdfBuilder.TryReadJpegSize(good.AsSpan(0, 30), out _, out _));          // truncated APP1
        Assert.False(PdfBuilder.TryReadJpegSize(SyntheticJpeg(640, 0), out _, out _));       // height via DNL
        // Scan data before any frame header.
        byte[] scanFirst = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10];
        Assert.False(PdfBuilder.TryReadJpegSize(scanFirst, out _, out _));
    }

    private static string ImageDictionaryOf(string pdf)
    {
        int start = pdf.IndexOf("/Subtype /Image", StringComparison.Ordinal);
        return pdf[start..pdf.IndexOf(">>", start, StringComparison.Ordinal)];
    }

    [Fact]
    public void XObjectUsesJpegSizeWhileMediaBoxUsesPageSize()
    {
        // A letter page at 600 dpi (5100 x 6600) whose JPEG is only a 1275 x 1650 preview.
        var page = new PdfPageInput(SyntheticJpeg(1275, 1650, 0xC2, withExif: true), 5100, 6600, 600, null);
        string text = Encoding.Latin1.GetString(PdfBuilder.Make([page]));
        string image = ImageDictionaryOf(text);
        Assert.Contains("/Width 1275 /Height 1650", image);
        Assert.Contains("/MediaBox [0 0 612 792]", text);
        Assert.Contains("612 0 0 792 0 0 cm", text); // the image is stretched over the whole page
    }

    [Fact]
    public void UnreadableJpegFallsBackToPagePixelSize()
    {
        var page = new PdfPageInput([0xFF, 0xD8, 0xFF, 0xD9], 100, 150, 300, null);
        string image = ImageDictionaryOf(Encoding.Latin1.GetString(PdfBuilder.Make([page])));
        Assert.Contains("/Width 100 /Height 150", image);
    }

    [Fact]
    public void MissingSpoolPageDeclaresPreviewSizedImageOnFullSizePage()
    {
        // The missing-spool fallback hands back the preview pixels with the FULL page size;
        // the encoded preview's true size must be what the image XObject declares.
        var preview = Marked(20, 10);
        var page = new ScannedPage(preview, 72, ColorMode.Color, filePath: "missing.png",
                                   fullPixelSize: new SizeD(40, 20)).RotatedClockwise();
        var prepared = PdfBuilder.PreparePage(page, spoolImage: null);
        var jpeg = SyntheticJpeg(prepared.Image.Width, prepared.Image.Height);
        var input = new PdfPageInput(jpeg, prepared.PixelWidth, prepared.PixelHeight, 72, null);
        string text = Encoding.Latin1.GetString(PdfBuilder.Make([input]));
        Assert.Contains("/Width 10 /Height 20", ImageDictionaryOf(text));
        Assert.Contains("/MediaBox [0 0 20 40]", text);
    }

    // MARK: - Cancellation

    [Fact]
    public void CancelledBeforeFirstPageThrowsCancelled()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var error = Assert.Throws<ScanException>(() => PdfBuilder.Make([Page()], null, cts.Token));
        Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
    }

    [Fact]
    public void CancellationIsCheckedBeforeEachPage()
    {
        using var cts = new CancellationTokenSource();
        var messages = new List<string>();
        void Progress(string message)
        {
            messages.Add(message);
            cts.Cancel(); // cancel while page 1 is being written
        }
        var error = Assert.Throws<ScanException>(() =>
            PdfBuilder.Make([Page(), Page(), Page()], Progress, cts.Token));
        Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
        Assert.Single(messages); // page 2 was never started
    }

    [Fact]
    public void UncancelledTokenWritesWholeDocument()
    {
        using var cts = new CancellationTokenSource();
        string text = Encoding.Latin1.GetString(PdfBuilder.Make([Page(), Page()], null, cts.Token));
        Assert.Contains("/Count 2", text);
        Assert.EndsWith("%%EOF\n", text);
    }

    private static string MakeTempDirectory()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"PdfBuilderTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void WriteFileProducesCompletePdfWithoutLeftovers()
    {
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            PdfBuilder.WriteFile([Page(), Page()], path);
            string text = Encoding.Latin1.GetString(File.ReadAllBytes(path));
            Assert.StartsWith("%PDF-1.4", text);
            Assert.EndsWith("%%EOF\n", text);
            Assert.Equal([path], Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void WriteFileHidesTempFileButNotTheResult()
    {
        if (!OperatingSystem.IsWindows()) return; // the Hidden attribute is Windows-only
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            var tempAttributes = new List<FileAttributes>();
            PdfBuilder.WriteFile([Page(), Page()], path, _ =>
            {
                foreach (string file in Directory.GetFiles(dir, ".*.pdf.tmp"))
                    tempAttributes.Add(File.GetAttributes(file));
            });
            Assert.Equal(2, tempAttributes.Count); // one temp file, seen once per page
            Assert.All(tempAttributes, a => Assert.True(a.HasFlag(FileAttributes.Hidden), $"temp file: {a}"));
            Assert.False(File.GetAttributes(path).HasFlag(FileAttributes.Hidden));
            Assert.Equal([path], Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void WriteFileReplacingExistingFileLeavesItVisible()
    {
        if (!OperatingSystem.IsWindows()) return;
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            File.WriteAllText(path, "previous");
            PdfBuilder.WriteFile([Page()], path);
            Assert.StartsWith("%PDF-1.4", File.ReadAllText(path));
            Assert.False(File.GetAttributes(path).HasFlag(FileAttributes.Hidden));
            Assert.Equal([path], Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void CancelledWriteFileLeavesNoPartialOutput()
    {
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            using var cts = new CancellationTokenSource();
            var error = Assert.Throws<ScanException>(() =>
                PdfBuilder.WriteFile([Page(), Page()], path, _ => cts.Cancel(), cts.Token));
            Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
            Assert.Empty(Directory.GetFiles(dir)); // neither the target nor the temp file
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void CancelledWriteFileKeepsExistingDestination()
    {
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            File.WriteAllText(path, "previous");
            using var cts = new CancellationTokenSource();
            cts.Cancel();
            Assert.Throws<ScanException>(() => PdfBuilder.WriteFile([Page()], path, null, cts.Token));
            Assert.Equal("previous", File.ReadAllText(path));
            Assert.Equal([path], Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void WriteNewFileUsesTheFreeNameAsIs()
    {
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            string written = PdfBuilder.WriteNewFile([Page(), Page()], path);
            Assert.Equal(path, written);
            Assert.StartsWith("%PDF-1.4", File.ReadAllText(path));
            Assert.Equal([path], Directory.GetFiles(dir));
            if (OperatingSystem.IsWindows())
                Assert.False(File.GetAttributes(path).HasFlag(FileAttributes.Hidden));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void WriteNewFileNeverReplacesAFileThatClaimedTheNameMeanwhile()
    {
        string dir = MakeTempDirectory();
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            // Another writer takes the name while this PDF is being built.
            string written = PdfBuilder.WriteNewFile([Page()], path,
                _ => { if (!File.Exists(path)) File.WriteAllText(path, "other writer"); });
            Assert.Equal(Path.Combine(dir, "out 2.pdf"), written);
            Assert.Equal("other writer", File.ReadAllText(path));
            Assert.StartsWith("%PDF-1.4", File.ReadAllText(written));
            Assert.Equal(new[] { path, written }.Order(), Directory.GetFiles(dir).Order());
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void CancelledWriteNewFileLeavesNoPartialOutput()
    {
        string dir = MakeTempDirectory();
        try
        {
            using var cts = new CancellationTokenSource();
            Assert.Throws<ScanException>(() =>
                PdfBuilder.WriteNewFile([Page(), Page()], Path.Combine(dir, "out.pdf"), _ => cts.Cancel(), cts.Token));
            Assert.Empty(Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
