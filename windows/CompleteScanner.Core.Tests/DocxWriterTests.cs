using System.IO.Compression;
using System.Text;
using System.Xml.Linq;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/DocxWriterTests.swift: the same cases. The Mac has no
// zip reader, so its tests read the package with a small reader of their own; here
// System.IO.Compression.ZipArchive opens it, as Word's own reader would.

public class ZipStoreTests
{
    [Fact]
    public void Crc32_KnownValues()
    {
        Assert.Equal(0u, ZipStore.Crc32([]));
        Assert.Equal(0xCBF43926u, ZipStore.Crc32("123456789"u8));
        Assert.Equal(0x414FA339u, ZipStore.Crc32("The quick brown fox jumps over the lazy dog"u8));
        Assert.Equal(0xD202EF8Du, ZipStore.Crc32(new byte[] { 0 }));
    }

    [Fact]
    public void Make_ExactBytesOfOneEntry()
    {
        byte[] zip = ZipStore.Make([new ZipStoreEntry("a.txt", "hi"u8.ToArray())]);
        uint crc = ZipStore.Crc32("hi"u8);
        var expected = new List<byte>();
        void U16(int v) { expected.Add((byte)v); expected.Add((byte)(v >> 8)); }
        void U32(uint v) { for (int i = 0; i < 4; i++) expected.Add((byte)(v >> (8 * i))); }
        // Local header, name, data.
        U32(0x04034B50); U16(10); U16(0); U16(0); U16(0); U16(0x21); U32(crc); U32(2); U32(2); U16(5); U16(0);
        expected.AddRange("a.txt"u8.ToArray());
        expected.AddRange("hi"u8.ToArray());
        // Central directory at 37.
        U32(0x02014B50); U16(20); U16(10); U16(0); U16(0); U16(0); U16(0x21); U32(crc); U32(2); U32(2); U16(5);
        U16(0); U16(0); U16(0); U16(0); U32(0); U32(0);
        expected.AddRange("a.txt"u8.ToArray());
        // End of central directory: one entry, 51 bytes of directory at 37.
        U32(0x06054B50); U16(0); U16(0); U16(1); U16(1); U32(51); U32(37); U16(0);
        Assert.Equal(expected.ToArray(), zip);
    }

    [Fact]
    public void Make_OpensWithZipArchive_EntriesInOrder()
    {
        byte[] big = Enumerable.Range(0, 70_000).Select(i => (byte)(i * 7)).ToArray();
        byte[] zip = ZipStore.Make(
        [
            new ZipStoreEntry("[Content_Types].xml", "<x/>"u8.ToArray()),
            new ZipStoreEntry("dir/empty.bin", []),
            new ZipStoreEntry("dir/big.bin", big),
            new ZipStoreEntry("naïve.txt", "é"u8.ToArray()),
        ]);
        using var archive = new ZipArchive(new MemoryStream(zip), ZipArchiveMode.Read);
        Assert.Equal(["[Content_Types].xml", "dir/empty.bin", "dir/big.bin", "naïve.txt"], archive.Entries.Select(e => e.FullName));
        Assert.Equal(big, Read(archive, "dir/big.bin"));
        Assert.Empty(Read(archive, "dir/empty.bin"));
        Assert.Equal("é", Encoding.UTF8.GetString(Read(archive, "naïve.txt")));
        Assert.All(archive.Entries, e => Assert.Equal(e.Length, e.CompressedLength));
        Assert.Equal(new DateTime(1980, 1, 1), archive.Entries[0].LastWriteTime.DateTime);
    }

    [Fact]
    public void PackageSize_IsTheLengthMakeWrites()
    {
        ZipStoreEntry[][] cases =
        [
            [],
            [new ZipStoreEntry("a.txt", "hi"u8.ToArray())],
            [
                new ZipStoreEntry("[Content_Types].xml", "<x/>"u8.ToArray()),
                new ZipStoreEntry("dir/empty.bin", []),
                new ZipStoreEntry("dir/big.bin", new byte[70_000]),
                new ZipStoreEntry("naïve.txt", "é"u8.ToArray()),
            ],
        ];
        foreach (var entries in cases)
        {
            Assert.Equal(ZipStore.Make(entries).LongLength, ZipStore.PackageSize(entries));
        }
        Assert.Equal(22L, ZipStore.PackageSize([]));
        Assert.Equal(110L, ZipStore.PackageSize([new ZipStoreEntry("a.txt", "hi"u8.ToArray())]));
    }

    internal static byte[] Read(ZipArchive archive, string name)
    {
        using var stream = archive.GetEntry(name)!.Open();
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        return copy.ToArray();
    }
}

public class DocxWriterTests
{
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static readonly XNamespace ContentTypes = "http://schemas.openxmlformats.org/package/2006/content-types";
    private static readonly XNamespace Relationships = "http://schemas.openxmlformats.org/package/2006/relationships";

    private static OcrLine L(string text, double left, double top, double width, double height = 20) =>
        OcrFixtures.Line(text, left, top, width, height);

    private static (ZipArchive Archive, XDocument Document) Open(byte[] docx)
    {
        var archive = new ZipArchive(new MemoryStream(docx), ZipArchiveMode.Read);
        var document = XDocument.Parse(Encoding.UTF8.GetString(ZipStoreTests.Read(archive, "word/document.xml")));
        return (archive, document);
    }

    private static List<string> ParagraphTexts(XDocument document) =>
        document.Root!.Element(W + "body")!.Elements(W + "p")
            .Select(p => string.Concat(p.Descendants().Select(e =>
                e.Name == W + "t" ? e.Value : e.Name == W + "tab" ? "\t" : e.Name == W + "br" ? "\n" : "")))
            .ToList();

    [Fact]
    public void Make_IsAWordPackage_WithTheRequiredPartsAndRelationships()
    {
        byte[] docx = DocxWriter.Make(TextExportTests.SamplePages());
        Assert.Equal("PK\u0003\u0004", Encoding.ASCII.GetString(docx, 0, 4));
        var (archive, document) = Open(docx);
        using (archive)
        {
            Assert.Equal(["[Content_Types].xml", "_rels/.rels", "word/document.xml"], archive.Entries.Select(e => e.FullName));

            var types = XDocument.Parse(Encoding.UTF8.GetString(ZipStoreTests.Read(archive, "[Content_Types].xml"))).Root!;
            Assert.Equal(ContentTypes + "Types", types.Name);
            Assert.Equal("application/vnd.openxmlformats-package.relationships+xml",
                         types.Elements(ContentTypes + "Default").Single(d => (string?)d.Attribute("Extension") == "rels")
                             .Attribute("ContentType")!.Value);
            Assert.Equal("application/xml",
                         types.Elements(ContentTypes + "Default").Single(d => (string?)d.Attribute("Extension") == "xml")
                             .Attribute("ContentType")!.Value);
            Assert.Equal("application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
                         types.Elements(ContentTypes + "Override").Single(o => (string?)o.Attribute("PartName") == "/word/document.xml")
                             .Attribute("ContentType")!.Value);

            var relationships = XDocument.Parse(Encoding.UTF8.GetString(ZipStoreTests.Read(archive, "_rels/.rels"))).Root!;
            var main = Assert.Single(relationships.Elements(Relationships + "Relationship"));
            Assert.Equal("http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
                         main.Attribute("Type")!.Value);
            Assert.Equal("word/document.xml", main.Attribute("Target")!.Value);
            Assert.Equal("rId1", main.Attribute("Id")!.Value);

            Assert.Equal(W + "document", document.Root!.Name);
            var body = document.Root.Element(W + "body")!;
            Assert.Equal(W + "sectPr", body.Elements().Last().Name);
        }
    }

    [Fact]
    public void Make_OneParagraphPerParagraph_NewPageForEachPage()
    {
        var (archive, document) = Open(DocxWriter.Make(TextExportTests.SamplePages()));
        using (archive)
        {
            Assert.Equal(["Café menu", "Soupe à l'oignon\t4,50 €\n東京 ラーメン\t9.00", "This line is forwarding the rest.",
                          "שלום עולם", "Fish & Chips <b>"],
                         ParagraphTexts(document));
            var paragraphs = document.Root!.Element(W + "body")!.Elements(W + "p").ToList();
            Assert.Equal([false, false, false, true, false],
                         paragraphs.Select(p => p.Element(W + "pPr")?.Element(W + "pageBreakBefore") is not null));
            // Text keeps its spaces; a tab is a tab element between two pieces of text, and the
            // rows of a table are lines of one paragraph.
            Assert.All(paragraphs.SelectMany(p => p.Descendants(W + "t")),
                       t => Assert.Equal("preserve", t.Attribute(XNamespace.Xml + "space")!.Value));
            Assert.Equal(8, paragraphs.SelectMany(p => p.Descendants(W + "t")).Count());
            Assert.Equal(2, paragraphs[1].Descendants(W + "tab").Count());
            Assert.Single(paragraphs[1].Descendants(W + "br"));
        }
    }

    [Fact]
    public void DocumentXml_EscapesMarkup_AndLeavesOutWhatXmlCannotHold()
    {
        var page = OcrFixtures.Page(L("A & B <tag> \"q\" 'a'", 50, 100, 600));
        string xml = DocxWriter.DocumentXml([page]);
        Assert.Contains("<w:t xml:space=\"preserve\">A &amp; B &lt;tag&gt; \"q\" 'a'</w:t>", xml);
        Assert.Equal("A &amp; B &lt;tag&gt;", DocxWriter.EscapeXml("A & B <tag>"));
        Assert.Equal("ab\tc", DocxWriter.EscapeXml("a\u0001b\u0008\tc\uFFFE\uFFFF"));
        Assert.Equal("x😀y", DocxWriter.EscapeXml("x😀y"));
        Assert.Equal("xy", DocxWriter.EscapeXml("x\uD800y"));
        Assert.Equal("\n\r", DocxWriter.EscapeXml("\n\r"));
        Assert.Contains("<w:p><w:r><w:t xml:space=\"preserve\">a</w:t><w:tab/><w:t xml:space=\"preserve\">b</w:t><w:br/>"
                        + "<w:t xml:space=\"preserve\">c</w:t><w:tab/><w:t xml:space=\"preserve\">d</w:t></w:r></w:p>",
                        DocxWriter.DocumentXml([OcrFixtures.Page(L("a", 50, 100, 50), L("b", 500, 100, 50),
                                                                 L("c", 50, 130, 50), L("d", 500, 130, 50))]));
        Assert.Equal(["A & B <tag> \"q\" 'a'"], ParagraphTexts(XDocument.Parse(xml)));
    }

    [Fact]
    public void Make_UnicodeRoundTrip()
    {
        string[] samples = ["東京都の天気は晴れ", "שלום עולם", "مرحبا بالعالم", "Ελληνικά", "emoji 😀 ok", "Ǆemal ﬁne"];
        var pages = samples.Select(text => OcrFixtures.Page(L(text, 50, 100, 500))).ToList();
        var (archive, document) = Open(DocxWriter.Make(pages));
        using (archive)
        {
            Assert.Equal(samples, ParagraphTexts(document));
        }
    }

    [Fact]
    public void PageSize_FromTheFirstPage_InTwips_WithOneInchMargins()
    {
        var a4 = new OcrPage([], 595.28, 841.89);
        string xml = DocxWriter.DocumentXml([a4, new OcrPage([], 1000, 300)]);
        Assert.Contains("<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" "
                        + "w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>", xml);
        Assert.Equal((15840, 12240), DocxWriter.PageSizeTwips(new OcrPage([], 792, 612)));
        Assert.Contains("<w:pgSz w:w=\"15840\" w:h=\"12240\" w:orient=\"landscape\"/>",
                        DocxWriter.DocumentXml([new OcrPage([], 792, 612)]));
        // Without a page: US Letter. Outside Word's range: kept within it.
        Assert.Equal((12240, 15840), DocxWriter.PageSizeTwips(null));
        Assert.Equal((31680, 144), DocxWriter.PageSizeTwips(new OcrPage([], 5000, 1)));
        // A receipt-sized page gets margins an eighth of its width.
        Assert.Equal(540, DocxWriter.MarginTwips(4320, 20000));
        Assert.Equal(1440, DocxWriter.MarginTwips(12240, 15840));
    }

    [Fact]
    public void EmptyPages_StillGiveAParagraphEach()
    {
        var (archive, document) = Open(DocxWriter.Make([OcrFixtures.Page(), OcrFixtures.Page()]));
        using (archive)
        {
            Assert.Equal(["", ""], ParagraphTexts(document));
        }
        Assert.Equal(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:body><w:p></w:p><w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" "
            + "w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>",
            DocxWriter.DocumentXml([]));
    }

    [Fact]
    public void Make_Fingerprint_MatchesTheMac()
    {
        // The same numbers in DocxWriterTests.swift: both platforms write the same package.
        byte[] docx = DocxWriter.Make(TextExportTests.SamplePages());
        Assert.Equal((1964, 0x0F9BA5A4u), (docx.Length, ZipStore.Crc32(docx)));
        Assert.Equal(DocxWriter.Make(TextExportTests.SamplePages()), docx);
    }
}

/// <summary>
/// The page pictures both test suites put in Word documents, as hex: a 16 × 12 gray JPEG and a
/// 16 × 12 one-bit PNG, black where (x + y) is a multiple of 3 (both written once by WIC; the
/// same strings are in DocxWriterTests.swift).
/// </summary>
internal static class DocxFixtures
{
    public const string JpegHex =
        "FFD8FFE000104A46494600010101012C012C0000FFDB00430006040506050406060506070706080A" +
        "100A0A09090A140E0F0C1017141818171416161A1D251F1A1B231C1616202C20232627292A29191F" +
        "2D302D283025282928FFC0000B08000C001001011100FFC4001F0000010501010101010100000000" +
        "000000000102030405060708090A0BFFC400B5100002010303020403050504040000017D01020300" +
        "041105122131410613516107227114328191A1082342B1C11552D1F02433627282090A161718191A" +
        "25262728292A3435363738393A434445464748494A535455565758595A636465666768696A737475" +
        "767778797A838485868788898A92939495969798999AA2A3A4A5A6A7A8A9AAB2B3B4B5B6B7B8B9BA" +
        "C2C3C4C5C6C7C8C9CAD2D3D4D5D6D7D8D9DAE1E2E3E4E5E6E7E8E9EAF1F2F3F4F5F6F7F8F9FAFFDA" +
        "0008010100003F00E13E1B685FEABE4F4AF6BF166B7FF0807C38BCD560F97529B16761F2E7F7EE0E" +
        "1B9561F2A867C30C1D9B73C8AE73E1B59C3FBAF97D2B9FFDA4A5925F1FF8774D77CD95BE982E228F" +
        "68F96492575739C64E4451F04E06DE3A9CFF00FFD9";

    public const string PngHex =
        "89504E470D0A1A0A0000000D49484452000000100000000C0100000000439C002C00000001735247" +
        "4200AECE1CE90000000467414D410000B18F0BFC6105000000097048597300002E2300002E230178" +
        "A53F76000000144944415418D363C8DDC6703B9761DB6D06DC0C0019EB0FF11F837D3C0000000049" +
        "454E44AE426082";

    public static byte[] Jpeg => Convert.FromHexString(JpegHex);
    public static byte[] Png => Convert.FromHexString(PngHex);

    public static DocxPicture JpegPicture => new(Jpeg, DocxPictureFormat.Jpeg);
    public static DocxPicture PngPicture => new(Png, DocxPictureFormat.Png);

    /// <summary>Whether the fixture PNG's pixel (x, y) is black.</summary>
    public static bool PngIsBlack(int x, int y) => (x + y) % 3 == 0;
}

/// <summary>A PNG read without any image library: its chunks (CRC-32 checked), header and unfiltered rows.</summary>
internal sealed record PngImage(int Width, int Height, int BitDepth, int ColorType, byte[] Rows, int Stride)
{
    public static PngImage Decode(byte[] png)
    {
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, png[..8]);
        int pos = 8, width = 0, height = 0, depth = 0, colorType = 0;
        using var idat = new MemoryStream();
        while (true)
        {
            int length = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(pos));
            string type = Encoding.ASCII.GetString(png, pos + 4, 4);
            var body = png.AsSpan(pos + 8, length);
            uint crc = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(pos + 8 + length));
            Assert.Equal(crc, ZipStore.Crc32(png.AsSpan(pos + 4, length + 4)));
            if (type == "IHDR")
            {
                width = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(body);
                height = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(body[4..]);
                depth = body[8];
                colorType = body[9];
                Assert.Equal(0, body[12]); // not interlaced
            }
            if (type == "IDAT") idat.Write(body);
            pos += 12 + length;
            if (type == "IEND") break;
        }
        int channels = colorType switch { 0 => 1, 2 => 3, 3 => 1, 4 => 2, _ => 4 };
        int stride = (width * channels * depth + 7) / 8, bpp = Math.Max(1, channels * depth / 8);
        idat.Position = 0;
        using var inflated = new MemoryStream();
        using (var zlib = new ZLibStream(idat, CompressionMode.Decompress)) zlib.CopyTo(inflated);
        byte[] raw = inflated.ToArray();
        Assert.Equal(height * (stride + 1), raw.Length);
        var rows = new byte[height * stride];
        for (int y = 0; y < height; y++)
        {
            int filter = raw[y * (stride + 1)];
            for (int i = 0; i < stride; i++)
            {
                int x = raw[y * (stride + 1) + 1 + i];
                int a = i >= bpp ? rows[y * stride + i - bpp] : 0;
                int b = y > 0 ? rows[(y - 1) * stride + i] : 0;
                int c = i >= bpp && y > 0 ? rows[(y - 1) * stride + i - bpp] : 0;
                int predicted = filter switch
                {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => (a + b) / 2,
                    4 => Paeth(a, b, c),
                    _ => throw new InvalidDataException($"filter {filter}"),
                };
                rows[y * stride + i] = (byte)(x + predicted);
            }
        }
        return new PngImage(width, height, depth, colorType, rows, stride);
    }

    /// <summary>A one-bit gray pixel: 0 is black.</summary>
    public bool IsBlack(int x, int y) => (Rows[y * Stride + (x >> 3)] & (0x80 >> (x & 7))) == 0;

    private static int Paeth(int a, int b, int c)
    {
        int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }
}

public class DocxWriterPictureTests
{
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static readonly XNamespace WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
    private static readonly XNamespace A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private static readonly XNamespace Pic = "http://schemas.openxmlformats.org/drawingml/2006/picture";
    private static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace ContentTypes = "http://schemas.openxmlformats.org/package/2006/content-types";
    private static readonly XNamespace Relationships = "http://schemas.openxmlformats.org/package/2006/relationships";

    private static XDocument Part(ZipArchive archive, string name) =>
        XDocument.Parse(Encoding.UTF8.GetString(ZipStoreTests.Read(archive, name)));

    private static List<XElement> Paragraphs(XDocument document) =>
        document.Root!.Element(W + "body")!.Elements(W + "p").ToList();

    private static string Text(XElement paragraph) =>
        string.Concat(paragraph.Descendants().Select(e =>
            e.Name == W + "t" ? e.Value : e.Name == W + "tab" ? "\t" : e.Name == W + "br" ? "\n" : ""));

    [Fact]
    public void Make_WithPageImages_HasTheMediaPartsRelationshipsAndContentTypes()
    {
        byte[] docx = DocxWriter.Make(TextExportTests.SamplePages(), [DocxFixtures.JpegPicture, DocxFixtures.PngPicture]);
        using var archive = new ZipArchive(new MemoryStream(docx), ZipArchiveMode.Read);
        Assert.Equal(["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                      "word/media/image1.jpeg", "word/media/image2.png"],
                     archive.Entries.Select(e => e.FullName));

        var types = Part(archive, "[Content_Types].xml").Root!;
        string? Default(string extension) => (string?)types.Elements(ContentTypes + "Default")
            .SingleOrDefault(d => (string?)d.Attribute("Extension") == extension)?.Attribute("ContentType");
        Assert.Equal("image/jpeg", Default("jpeg"));
        Assert.Equal("image/png", Default("png"));
        Assert.Equal("application/xml", Default("xml"));
        Assert.Equal("application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
                     (string?)types.Elements(ContentTypes + "Override").Single().Attribute("ContentType"));

        // Each picture of the document points at its part through the document's relationships.
        var relationships = Part(archive, "word/_rels/document.xml.rels").Root!.Elements(Relationships + "Relationship").ToList();
        Assert.Equal(["rId1", "rId2"], relationships.Select(r => (string)r.Attribute("Id")!));
        Assert.All(relationships, r => Assert.Equal(DocxWriter.ImageRelationshipType, (string)r.Attribute("Type")!));
        Assert.Equal(["media/image1.jpeg", "media/image2.png"], relationships.Select(r => (string)r.Attribute("Target")!));
        Assert.All(relationships, r => Assert.NotNull(archive.GetEntry("word/" + (string)r.Attribute("Target")!)));

        var document = Part(archive, "word/document.xml");
        var inlines = document.Descendants(WP + "inline").ToList();
        Assert.Equal(2, inlines.Count);
        Assert.Equal(["rId1", "rId2"], document.Descendants(A + "blip").Select(b => (string)b.Attribute(R + "embed")!));
        Assert.Equal(["1", "2"], inlines.Select(i => (string)i.Element(WP + "docPr")!.Attribute("id")!));
        foreach (var inline in inlines)
        {
            // The paper is square (1000 pt) with 1-inch margins: each square page fills the space inside them.
            var extent = inline.Element(WP + "extent")!;
            Assert.Equal(("10871200", "10871200"), ((string)extent.Attribute("cx")!, (string)extent.Attribute("cy")!));
            var picture = inline.Element(A + "graphic")!.Element(A + "graphicData")!.Element(Pic + "pic")!;
            var ext = picture.Element(Pic + "spPr")!.Element(A + "xfrm")!.Element(A + "ext")!;
            Assert.Equal(((string)extent.Attribute("cx")!, (string)extent.Attribute("cy")!),
                         ((string)ext.Attribute("cx")!, (string)ext.Attribute("cy")!));
        }

        // The pictures are the bytes given, and they decode.
        byte[] jpeg = ZipStoreTests.Read(archive, "word/media/image1.jpeg");
        Assert.Equal(DocxFixtures.Jpeg, jpeg);
        Assert.True(PdfBuilder.TryReadJpegHeader(jpeg, out int jpegWidth, out int jpegHeight, out int components));
        Assert.Equal((16, 12, 1), (jpegWidth, jpegHeight, components));
        byte[] png = ZipStoreTests.Read(archive, "word/media/image2.png");
        Assert.Equal(DocxFixtures.Png, png);
        var decoded = PngImage.Decode(png);
        Assert.Equal((16, 12, 1, 0), (decoded.Width, decoded.Height, decoded.BitDepth, decoded.ColorType));
        for (int y = 0; y < 12; y++)
        {
            for (int x = 0; x < 16; x++) Assert.Equal(DocxFixtures.PngIsBlack(x, y), decoded.IsBlack(x, y));
        }
    }

    [Fact]
    public void Make_WithPageImages_EachPagePictureThenItsText()
    {
        byte[] docx = DocxWriter.Make(TextExportTests.SamplePages(), [DocxFixtures.JpegPicture, DocxFixtures.PngPicture]);
        using var archive = new ZipArchive(new MemoryStream(docx), ZipArchiveMode.Read);
        var paragraphs = Paragraphs(Part(archive, "word/document.xml"));
        Assert.Equal(["", "Café menu", "Soupe à l'oignon\t4,50 €\n東京 ラーメン\t9.00", "This line is forwarding the rest.",
                      "", "שלום עולם", "Fish & Chips <b>"],
                     paragraphs.Select(Text));
        Assert.Equal([true, false, false, false, true, false, false],
                     paragraphs.Select(p => p.Descendants(W + "drawing").Any()));
        // The second page starts at its picture; the text after a picture never breaks the page itself.
        Assert.Equal([false, false, false, false, true, false, false],
                     paragraphs.Select(p => p.Element(W + "pPr")?.Element(W + "pageBreakBefore") is not null));
    }

    [Fact]
    public void DocumentXml_PictureParagraph_ExactMarkup()
    {
        var letter = new OcrPage([], 612, 792);
        string xml = DocxWriter.DocumentXml([letter], [DocxFixtures.JpegPicture]);
        Assert.Equal(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
            + " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
            + " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
            + " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
            + " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>"
            + "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"center\"/></w:pPr>"
            + "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent cx=\"5943600\" cy=\"7691717\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            + "<wp:docPr id=\"1\" name=\"Page 1\" descr=\"Page 1 as scanned\"/>"
            + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"1\" name=\"image1.jpeg\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"5943600\" cy=\"7691717\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
            + "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" "
            + "w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>",
            xml);
        Assert.Equal(W + "document", XDocument.Parse(xml).Root!.Name);
    }

    [Fact]
    public void PictureSize_RealSize_OrShrunkInsideTheMargins_KeepingItsShape()
    {
        // US Letter paper: 8.5 × 11 in with 1-inch margins leaves 6.5 × 9 in (5943600 × 8229600 EMU).
        Assert.Equal((5943600L, 7691717L), DocxWriter.PictureSizeEmu(new OcrPage([], 612, 792), 12240, 15840));
        // A landscape page on portrait paper: as wide as the margins allow.
        Assert.Equal((5943600L, 4592781L), DocxWriter.PictureSizeEmu(new OcrPage([], 792, 612), 12240, 15840));
        // A long, narrow receipt: as tall as the margins allow.
        Assert.Equal((822960L, 8229600L), DocxWriter.PictureSizeEmu(new OcrPage([], 216, 2160), 12240, 15840));
        // A small page keeps its real size (3 × 5 in), never enlarged.
        Assert.Equal((2743200L, 4572000L), DocxWriter.PictureSizeEmu(new OcrPage([], 216, 360), 12240, 15840));
        // A page that is its paper (a receipt-sized paper, margins an eighth of its width) fits inside the margins.
        Assert.Equal((2057400L, 3429000L), DocxWriter.PictureSizeEmu(new OcrPage([], 216, 360), 4320, 7200));
        // No size: the space inside the margins. A huge page is still shrunk to fit.
        Assert.Equal((5943600L, 8229600L), DocxWriter.PictureSizeEmu(new OcrPage([], 0, 792), 12240, 15840));
        Assert.Equal((5943600L, 8229600L), DocxWriter.PictureSizeEmu(new OcrPage([], double.NaN, 792), 12240, 15840));
        Assert.Equal((5943600L, 5943600L), DocxWriter.PictureSizeEmu(new OcrPage([], 1e300, 1e300), 12240, 15840));
        Assert.Equal(914400L, 72 * DocxWriter.EmuPerPoint);
        Assert.Equal(914400L, DocxWriter.TwipsPerInch * DocxWriter.EmuPerTwip);
    }

    [Fact]
    public void Make_WithoutPictures_IsTheTextOnlyPackage()
    {
        var pages = TextExportTests.SamplePages();
        byte[] textOnly = DocxWriter.Make(pages);
        Assert.Equal(textOnly, DocxWriter.Make(pages, []));
        Assert.Equal(textOnly, DocxWriter.Make(pages, [null, null]));
        Assert.Equal(textOnly, DocxWriter.Make(pages, null));
        Assert.Equal(DocxWriter.ContentTypesXml, DocxWriter.PackageContentTypesXml([]));
        // Pictures past the last page are left out.
        Assert.Equal(DocxWriter.Make([OcrFixtures.Page()]), DocxWriter.Make([OcrFixtures.Page()], [null, DocxFixtures.PngPicture]));
    }

    [Fact]
    public void Make_SomePagesWithPictures_NumbersThePicturesInOrder()
    {
        var pages = new[]
        {
            OcrFixtures.Page(OcrFixtures.Line("One", 50, 100, 200)), OcrFixtures.Page(), OcrFixtures.Page(),
        };
        byte[] docx = DocxWriter.Make(pages, [DocxFixtures.PngPicture, null, DocxFixtures.PngPicture]);
        using var archive = new ZipArchive(new MemoryStream(docx), ZipArchiveMode.Read);
        Assert.Equal(["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                      "word/media/image1.png", "word/media/image2.png"],
                     archive.Entries.Select(e => e.FullName));
        var types = Part(archive, "[Content_Types].xml").Root!;
        Assert.Equal(["rels", "xml", "png"], types.Elements(ContentTypes + "Default").Select(d => (string)d.Attribute("Extension")!));
        var paragraphs = Paragraphs(Part(archive, "word/document.xml"));
        // Page 1: picture and text; page 2: an empty paragraph starting the page; page 3: its picture alone.
        Assert.Equal(["", "One", "", ""], paragraphs.Select(Text));
        Assert.Equal([true, false, false, true], paragraphs.Select(p => p.Descendants(W + "drawing").Any()));
        Assert.Equal([false, false, true, true],
                     paragraphs.Select(p => p.Element(W + "pPr")?.Element(W + "pageBreakBefore") is not null));
        var docPr = paragraphs[3].Descendants(WP + "docPr").Single();
        Assert.Equal(("2", "Page 3", "Page 3 as scanned"),
                     ((string)docPr.Attribute("id")!, (string)docPr.Attribute("name")!, (string)docPr.Attribute("descr")!));
        Assert.Equal("image2.png", (string)paragraphs[3].Descendants(Pic + "cNvPr").Single().Attribute("name")!);
    }

    [Fact]
    public void PictureFormat_FollowsThePdfSizePlan_AndNames()
    {
        foreach (var size in Enum.GetValues<PdfSizePreset>())
        {
            Assert.Equal(DocxPictureFormat.Png, DocxWriter.PictureFormat(PdfImageEncoding.Plan(ColorMode.BlackWhite, 300, size, false)));
            Assert.Equal(DocxPictureFormat.Jpeg, DocxWriter.PictureFormat(PdfImageEncoding.Plan(ColorMode.Grayscale, 300, size, false)));
            Assert.Equal(DocxPictureFormat.Jpeg, DocxWriter.PictureFormat(PdfImageEncoding.Plan(ColorMode.Color, 300, size, true)));
            Assert.Equal(DocxPictureFormat.Jpeg, DocxWriter.PictureFormat(PdfImageEncoding.Plan(ColorMode.Color, 300, size, false)));
        }
        Assert.Equal("image1.jpeg", DocxWriter.MediaName(1, DocxPictureFormat.Jpeg));
        Assert.Equal("image12.png", DocxWriter.MediaName(12, DocxPictureFormat.Png));
        Assert.Equal(("jpeg", "image/jpeg"), (DocxWriter.PictureExtension(DocxPictureFormat.Jpeg), DocxWriter.PictureContentType(DocxPictureFormat.Jpeg)));
        Assert.Equal(("png", "image/png"), (DocxWriter.PictureExtension(DocxPictureFormat.Png), DocxWriter.PictureContentType(DocxPictureFormat.Png)));
        Assert.Equal("Include page images", DocxWriter.PageImagesLabel);
        Assert.Equal("Each page as scanned, then its text you can edit. The pictures are stored at the size chosen below.",
                     DocxWriter.PageImagesHint(true));
        Assert.Equal("Only the text you can edit: the pictures of the pages are left out.", DocxWriter.PageImagesHint(false));
    }

    [Fact]
    public void Make_WithPageImages_Fingerprint_MatchesTheMac()
    {
        // The same numbers in DocxWriterTests.swift: both platforms write the same package.
        byte[] docx = DocxWriter.Make(TextExportTests.SamplePages(), [DocxFixtures.JpegPicture, DocxFixtures.PngPicture]);
        Assert.Equal((5482, 0x8708C7FCu), (docx.Length, ZipStore.Crc32(docx)));
        Assert.Equal(DocxWriter.Make(TextExportTests.SamplePages(), [DocxFixtures.JpegPicture, DocxFixtures.PngPicture]), docx);
        // The fixtures themselves, so a change to them shows here first.
        Assert.Equal((421, 127), (DocxFixtures.Jpeg.Length, DocxFixtures.Png.Length));
        Assert.Equal((0x58549185u, 0xA6733A06u), (ZipStore.Crc32(DocxFixtures.Jpeg), ZipStore.Crc32(DocxFixtures.Png)));
    }

    [Fact]
    public void PackageSize_IsTheLengthMakeWrites()
    {
        var pages = TextExportTests.SamplePages();
        Assert.Equal(DocxWriter.Make(pages).LongLength, DocxWriter.PackageSize(pages));
        Assert.Equal(5482L, DocxWriter.PackageSize(pages, [DocxFixtures.JpegPicture, DocxFixtures.PngPicture]));
        var three = new[] { OcrFixtures.Page(OcrFixtures.Line("One", 50, 100, 200)), OcrFixtures.Page(), OcrFixtures.Page() };
        DocxPicture?[] some = [DocxFixtures.PngPicture, null, DocxFixtures.JpegPicture];
        Assert.Equal(DocxWriter.Make(three, some).LongLength, DocxWriter.PackageSize(three, some));
    }

    [Fact]
    public void PackageSize_PastTheLimit_IsTold_WithoutWritingThePackage()
    {
        // 64 MiB shared by every page: 29 pictures fit in 2 GB, 30 do not.
        var picture = new DocxPicture(new byte[1 << 26], DocxPictureFormat.Jpeg);
        var pages = Enumerable.Range(0, 30).Select(_ => OcrFixtures.Page()).ToArray();
        Assert.True(DocxWriter.PackageSize(pages[..29], Enumerable.Repeat<DocxPicture?>(picture, 29).ToArray()) <= DocxWriter.MaxPackageBytes);
        Assert.True(DocxWriter.PackageSize(pages, Enumerable.Repeat<DocxPicture?>(picture, 30).ToArray()) > DocxWriter.MaxPackageBytes);
        // The limit is within what a zip without zip64 and one .NET array hold.
        Assert.True(DocxWriter.MaxPackageBytes < uint.MaxValue);
        Assert.True(DocxWriter.MaxPackageBytes <= Array.MaxLength);
        Assert.Equal("The Word document would be larger than 2 GB, too large to write. Save fewer pages in each document, "
                     + "choose a smaller page image size, or turn off \"Include page images\".", DocxWriter.TooLargeMessage);
    }
}
