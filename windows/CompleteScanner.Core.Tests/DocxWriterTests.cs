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
