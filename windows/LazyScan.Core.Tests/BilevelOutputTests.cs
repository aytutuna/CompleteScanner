using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using LazyScan.Core;
using UglyToad.PdfPig;
using Xunit;

namespace LazyScan.Core.Tests;

// Black & white pages in the files the app writes: CCITT G4 images in every kind of PDF (plain,
// PDF/A, protected, pages added to an existing PDF) and G4 TIFFs of one or several pages. PdfPig
// (test-only) decodes the PDF images; WIC decodes the TIFFs and Windows.Data.Pdf renders the PDFs
// in LazyScan.App.Tests/BilevelOutputTests.cs. The Mac's twin (Tests/CompleteScannerTests/
// BilevelOutputTests.swift) has the plain-PDF and TIFF cases with the same golden values (see
// CONTRACTS.md, "CCITT G4 for black & white pages").

public class BilevelOutputTests
{
    /// <summary>The blank-page tests' text page (850 × 1100) as the black &amp; white mode makes it.</summary>
    private static RgbaImage TextPage() =>
        ImagePipeline.Apply(new AdjustmentSettings(), TestPages.TextPage().ToRgba(), ColorMode.BlackWhite);

    private static PdfPageInput G4Page(RgbaImage image, int dpi = 100, IReadOnlyList<OcrLine>? lines = null) =>
        new(PdfCcittImage.Encode(image), image.Width, image.Height, dpi, lines);

    private static string Latin1(byte[] data) => Encoding.Latin1.GetString(data);

    /// <summary>The page's one image, decoded by PdfPig, as packed rows.</summary>
    private static byte[] DecodedImage(PdfDocument document, int page)
    {
        var image = document.GetPage(page).GetImages().Single();
        Assert.Equal(1, image.BitsPerComponent);
        Assert.True(image.TryGetBytesAsMemory(out var bytes));
        return bytes.ToArray();
    }

    // MARK: - PDF

    [Fact]
    public void Pdf_G4Page_DeclaresA1BitGrayCcittImage()
    {
        var image = TextPage();
        var g4 = PdfCcittImage.Encode(image);
        byte[] pdf = PdfBuilder.Make([new PdfPageInput(g4, image.Width, image.Height, 100, null)]);
        string text = Latin1(pdf);
        Assert.Contains($"/Type /XObject /Subtype /Image /Width 850 /Height 1100 /ColorSpace /DeviceGray /BitsPerComponent 1 " +
                        $"/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 850 /Rows 1100 /BlackIs1 false>> /Length {g4.Data.Length}>>\nstream\n",
                        text);
        Assert.Contains("/MediaBox [0 0 612 792]", text); // 850 × 1100 px at 100 dpi: Letter
        int start = text.IndexOf("/CCITTFaxDecode", StringComparison.Ordinal);
        int data = text.IndexOf("stream\n", start, StringComparison.Ordinal) + "stream\n".Length;
        Assert.True(pdf.AsSpan(data, g4.Data.Length).SequenceEqual(g4.Data));
        Assert.DoesNotContain("/DCTDecode", text);
        Assert.StartsWith("%PDF-1.4", text);

        using var document = PdfDocument.Open(pdf);
        Assert.Equal(Bilevel.Pack(image), DecodedImage(document, 1));
    }

    [Fact]
    public void Pdf_MixesJpegAndG4Pages_AndATextLayer()
    {
        var image = TextPage();
        var line = new OcrLine("Siyah beyaz sayfa — Çağrı", new RectD(0.1, 0.8, 0.6, 0.03), 0.9f);
        byte[] pdf = PdfBuilder.Make(
        [
            new PdfPageInput(PdfBuilderTests.TinyJpeg, 850, 1100, 100, null),
            G4Page(image, lines: [line]),
        ]);
        using var document = PdfDocument.Open(pdf);
        Assert.Equal(2, document.NumberOfPages);
        Assert.Equal(8, document.GetPage(1).GetImages().Single().BitsPerComponent);
        Assert.Equal(Bilevel.Pack(image), DecodedImage(document, 2));
        Assert.Equal(line.Text, document.GetPage(2).Text);
    }

    [Fact]
    public void Pdf_ByteArrayConstructor_IsAJpegPage()
    {
        var page = new PdfPageInput(PdfBuilderTests.TinyJpeg, 100, 150, 300, null);
        Assert.IsType<PdfJpegImage>(page.Image);
        Assert.Same(PdfBuilderTests.TinyJpeg, page.JpegData);
        var g4 = new PdfCcittImage([1, 2, 3], 10, 4);
        Assert.Same(g4.Data, new PdfPageInput(g4, 10, 4, 300, null).JpegData);
    }

    [Fact]
    public void PdfA_WithAG4Page_KeepsItsStructure()
    {
        var image = TextPage();
        var options = new PdfWriteOptions { Conformance = PdfConformance.PdfA2b, Title = "Siyah beyaz",
                                            CreationDate = new DateTimeOffset(2026, 10, 20, 9, 30, 0, TimeSpan.FromHours(3)),
                                            DocumentId = new byte[16] };
        byte[] pdf = PdfBuilder.Make([G4Page(image)], options: options);
        string text = Latin1(pdf);
        Assert.StartsWith("%PDF-1.7", text);
        Assert.Contains("/OutputIntents", text);
        Assert.Contains("/Filter /CCITTFaxDecode", text);
        using var document = PdfDocument.Open(pdf, new ParsingOptions { UseLenientParsing = false });
        Assert.Equal(Bilevel.Pack(image), DecodedImage(document, 1));
    }

    [Fact]
    public void Protected_G4Page_DecodesWithThePassword()
    {
        var image = TextPage();
        using var protection = new PdfProtection("Şifre 2026");
        var g4 = PdfCcittImage.Encode(image);
        byte[] pdf = PdfBuilder.Make([new PdfPageInput(g4, image.Width, image.Height, 100, null)],
                                     options: new PdfWriteOptions { Protection = protection });
        // The stream is encrypted: IV + AES blocks with PKCS#7 padding.
        Assert.Contains($"/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 850 /Rows 1100 /BlackIs1 false>> /Length {(g4.Data.Length / 16 + 2) * 16}>>",
                        Latin1(pdf));
        using var document = PdfDocument.Open(pdf, new ParsingOptions { Password = "Şifre 2026" });
        Assert.True(document.IsEncrypted);
        Assert.Equal(Bilevel.Pack(image), DecodedImage(document, 1));
    }

    [Fact]
    public void Appended_G4Page_IsReadBack()
    {
        var image = TextPage();
        byte[] original = PdfBuilder.Make([new PdfPageInput(PdfBuilderTests.TinyJpeg, 850, 1100, 100, null)]);
        byte[] appended = PdfAppender.Append(original, [G4Page(image)]);
        Assert.True(appended.AsSpan(0, original.Length).SequenceEqual(original));
        Assert.Contains("/Filter /CCITTFaxDecode", Latin1(appended[original.Length..]));
        using var document = PdfDocument.Open(appended, new ParsingOptions { UseLenientParsing = false });
        Assert.Equal(2, document.NumberOfPages);
        Assert.Equal(Bilevel.Pack(image), DecodedImage(document, 2));
    }

    [Fact]
    public void Pdf_G4AndJpegPages_GoldenBytes()
    {
        // A plain PDF: the 37 × 23 checkerboard as a G4 page at 100 dpi with a Turkish line, then a
        // JPEG page. The Mac's twin (PDFWriterTests) must write the same bytes.
        byte[] checker = CcittG4Encoder.Encode(CcittG4EncoderTests.Packed(37, 23, (x, y) => ((x + y) & 1) == 0), 37, 23);
        var line = new OcrLine("Siyah beyaz — Çağrı", new RectD(0.1, 0.5, 0.8, 0.2), 0.9f);
        byte[] pdf = PdfBuilder.Make(
        [
            new PdfPageInput(new PdfCcittImage(checker, 37, 23), 37, 23, 100, [line]),
            new PdfPageInput(PdfBuilderTests.TinyJpeg, 850, 1100, 100, null),
        ]);
        Assert.Equal(9892, pdf.Length);
        Assert.Equal("75ED330CDE6CE4BA0D554F7F9C17EA81D2648A3C39E3C5141EBAA73138D4EF29", Convert.ToHexString(SHA256.HashData(pdf)));
    }

    [Fact]
    public void Pdf_G4_TakesAFractionOfABitPerPixel()
    {
        // The text page as a 1-bit G4 image: under one bit for every five pixels.
        var image = TextPage();
        int g4 = PdfCcittImage.Encode(image).Data.Length;
        Assert.InRange(g4, 1000, image.Width * image.Height / 40); // bytes, so 1/5 bit per pixel at most
    }

    // MARK: - TIFF

    private static (Dictionary<int, (int Type, uint Count, uint Value)> Entries, uint Next) Directory(byte[] tiff, uint offset)
    {
        int count = BinaryPrimitives.ReadUInt16LittleEndian(tiff.AsSpan((int)offset));
        var entries = new Dictionary<int, (int, uint, uint)>();
        int previous = -1;
        for (int e = 0; e < count; e++)
        {
            var entry = tiff.AsSpan((int)offset + 2 + e * 12, 12);
            int tag = BinaryPrimitives.ReadUInt16LittleEndian(entry);
            Assert.True(tag > previous, "entries in ascending tag order");
            previous = tag;
            int type = BinaryPrimitives.ReadUInt16LittleEndian(entry[2..]);
            uint n = BinaryPrimitives.ReadUInt32LittleEndian(entry[4..]);
            uint value = type == 3 && n == 1 ? BinaryPrimitives.ReadUInt16LittleEndian(entry[8..]) : BinaryPrimitives.ReadUInt32LittleEndian(entry[8..]);
            entries[tag] = (type, n, value);
        }
        Assert.Equal(0u, offset % 2);
        return (entries, BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan((int)offset + 2 + count * 12)));
    }

    private static uint Rational(byte[] tiff, uint offset, out uint denominator)
    {
        denominator = BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan((int)offset + 4));
        return BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan((int)offset));
    }

    [Fact]
    public void Tiff_OnePage_IsAG4StripWithItsResolution()
    {
        var image = TextPage();
        byte[] tiff = BilevelTiff.Make(image, 300);
        Assert.Equal("II*\0"u8.ToArray(), tiff[..4]);
        var (entries, next) = Directory(tiff, BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan(4)));
        Assert.Equal(0u, next);
        Assert.Equal(new[] { 256, 257, 258, 259, 262, 273, 277, 278, 279, 282, 283, 293, 296 }, entries.Keys.Order());
        Assert.Equal(850u, entries[256].Value);
        Assert.Equal(1100u, entries[257].Value);
        Assert.Equal(1u, entries[258].Value);
        Assert.Equal(4u, entries[259].Value);   // CCITT T.6
        Assert.Equal(0u, entries[262].Value);   // WhiteIsZero
        Assert.Equal(1u, entries[277].Value);
        Assert.Equal(1100u, entries[278].Value); // one strip
        Assert.Equal(0u, entries[293].Value);
        Assert.Equal(2u, entries[296].Value);   // inch
        Assert.Equal(300u, Rational(tiff, entries[282].Value, out uint d1));
        Assert.Equal(1u, d1);
        Assert.Equal(300u, Rational(tiff, entries[283].Value, out uint d2));
        Assert.Equal(1u, d2);
        byte[] g4 = CcittG4Encoder.Encode(image);
        Assert.Equal((uint)g4.Length, entries[279].Value);
        Assert.Equal(8u, entries[273].Value);
        Assert.True(tiff.AsSpan(8, g4.Length).SequenceEqual(g4));
        Assert.Equal(17852, tiff.Length); // 8 + 17666 + 162 + 16
        Assert.Equal("EF4F98A030BB642AB198F3FAE98EEE6CD088E24B986A769FCD0EEE92255CA38D", Convert.ToHexString(SHA256.HashData(tiff)));
        // The gray text page thresholded at 128 has the same bits as its black & white page, so the
        // Mac's twin, whose image pipeline is Core Image's, builds the same file from the gray page.
        Assert.Equal(tiff, BilevelTiff.Make(TestPages.TextPage().ToRgba(), 300));
    }

    [Fact]
    public void Tiff_SeveralPages_AreChainedAsPagesOfOneDocument()
    {
        var text = TextPage();
        var small = CcittG4EncoderTests.Image(13, 7, (x, y) => (x + y) % 3 == 0);
        var black = RgbaImage.Filled(9, 2, 0, 0, 0);
        byte[] tiff = BilevelTiff.Make([new(text, 100), new(small, 300), new(black, 600)]);
        uint offset = BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan(4));
        var pages = new[] { (Image: text, Dpi: 100u), (Image: small, Dpi: 300u), (Image: black, Dpi: 600u) };
        for (int i = 0; i < pages.Length; i++)
        {
            Assert.NotEqual(0u, offset);
            var (entries, next) = Directory(tiff, offset);
            var (image, dpi) = pages[i];
            Assert.Equal(2u, entries[254].Value);                         // a page of a document
            Assert.Equal((uint)i | (3u << 16), entries[297].Value);       // page i of 3
            Assert.Equal((3, 2u), (entries[297].Type, entries[297].Count));
            Assert.Equal((uint)image.Width, entries[256].Value);
            Assert.Equal((uint)image.Height, entries[257].Value);
            Assert.Equal(dpi, Rational(tiff, entries[282].Value, out _));
            byte[] g4 = CcittG4Encoder.Encode(image);
            Assert.Equal((uint)g4.Length, entries[279].Value);
            Assert.True(tiff.AsSpan((int)entries[273].Value, g4.Length).SequenceEqual(g4));
            offset = next;
        }
        Assert.Equal(0u, offset);
        Assert.Throws<ArgumentException>(() => BilevelTiff.Make([]));
    }

    [Fact]
    public void Tiff_AppliesToBlackAndWhiteTiffsOnly()
    {
        Assert.True(BilevelTiff.Applies(OutputFormat.Tiff, ColorMode.BlackWhite));
        Assert.False(BilevelTiff.Applies(OutputFormat.Tiff, ColorMode.Grayscale));
        Assert.False(BilevelTiff.Applies(OutputFormat.Tiff, ColorMode.Color));
        Assert.False(BilevelTiff.Applies(OutputFormat.Png, ColorMode.BlackWhite));
        Assert.False(BilevelTiff.Applies(OutputFormat.Pdf, ColorMode.BlackWhite));
    }
}
