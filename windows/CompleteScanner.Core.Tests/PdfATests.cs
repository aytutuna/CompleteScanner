using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using CompleteScanner.Core;
using UglyToad.PdfPig;
using Xunit;

namespace CompleteScanner.Core.Tests;

// PDF/A-2b output and the Unicode text layer, checked in the bytes and, through PdfPig (a
// test-only package), as a PDF reader sees them. No Swift twin yet: the Mac's PDF writer port
// (CONTRACTS.md, M19) brings one, which must write the same bytes (the pinned SHA-256 below).

public class PdfATests
{
    private static readonly DateTimeOffset Date = new(2026, 10, 19, 21, 30, 5, TimeSpan.FromHours(3));
    private static readonly byte[] Id = [.. Enumerable.Range(0xA0, 16).Select(i => (byte)i)];
    private const string IdHex = "A0A1A2A3A4A5A6A7A8A9AAABACADAEAF";

    private static PdfWriteOptions Archival(string? title = "Tapu belgesi — Çağrı") => new()
    {
        Conformance = PdfConformance.PdfA2b,
        Title = title,
        CreationDate = Date,
        DocumentId = Id,
    };

    /// <summary>Recognized lines in several scripts, top to bottom, each with its own box.</summary>
    private static readonly string[] Scripts =
    [
        "Çağrı Işık İzmir'de öğün şüpheli ılık su içti", // Turkish: ç ğ ı İ ö ş ü
        "ÇĞIİÖŞÜ çğıiöşü",
        "Καλημέρα κόσμε",                               // Greek
        "Привет, мир",                                  // Cyrillic
        "مرحبا بالعالم",                                // Arabic
        "שלום עולם",                                    // Hebrew
        "日本語のテキストと中文 𠀋",                       // Japanese and Chinese, with an ideograph beyond the BMP
        "नमस्ते दुनिया",                                  // Devanagari
        "Naïve café — 25 € 📄",                          // Latin with symbols outside Latin-1 and the BMP
    ];

    private static List<OcrLine> ScriptLines() =>
        [.. Scripts.Select((text, i) => new OcrLine(text, new RectD(0.1, 0.9 - i * 0.09, 0.8, 0.05), 0.9f))];

    private static PdfPageInput Page(IReadOnlyList<OcrLine>? lines = null) =>
        new(PdfBuilderTests.TinyJpeg, 2550, 3300, 300, lines); // US Letter at 300 dpi: 612 × 792 pt

    private static string Latin1(byte[] pdf) => Encoding.Latin1.GetString(pdf);

    // MARK: - Dates, strings, titles

    [Fact]
    public void Dates_AreWrittenTheSameInBothPlaces()
    {
        Assert.Equal("D:20261019213005+03'00'", PdfA.PdfDate(Date));
        Assert.Equal("2026-10-19T21:30:05+03:00", PdfA.XmpDate(Date));
        var west = new DateTimeOffset(2026, 1, 2, 3, 4, 5, new TimeSpan(-5, -30, 0));
        Assert.Equal("D:20260102030405-05'30'", PdfA.PdfDate(west));
        Assert.Equal("2026-01-02T03:04:05-05:30", PdfA.XmpDate(west));
        var utc = new DateTimeOffset(2026, 12, 31, 23, 59, 59, TimeSpan.Zero);
        Assert.Equal("D:20261231235959+00'00'", PdfA.PdfDate(utc));
        Assert.Equal("2026-12-31T23:59:59+00:00", PdfA.XmpDate(utc));
    }

    [Fact]
    public void TextString_IsLiteralForAscii_Utf16OtherwiseWithItsByteOrderMark()
    {
        Assert.Equal("(Scan 2026-10-19 1)", PdfA.TextString("Scan 2026-10-19 1"));
        Assert.Equal(@"(a\(b\)\\c)", PdfA.TextString(@"a(b)\c"));
        Assert.Equal("<FEFF00C70061011F00720131>", PdfA.TextString("Çağrı"));
        Assert.Equal("<FEFFD83DDCC4>", PdfA.TextString("\U0001F4C4"));
        Assert.Equal("()", PdfA.TextString(""));
    }

    [Fact]
    public void CleanTitle_DropsWhatXmlCannotHold()
    {
        Assert.Equal("ABC\U0001F4C4 ı", PdfA.CleanTitle("A\u0001B\uD800C\U0001F4C4\u007F ￾ı\uDC00"));
        Assert.Equal("Tapu belgesi — Çağrı", PdfA.CleanTitle("Tapu belgesi — Çağrı"));
    }

    [Fact]
    public void InfoDictionary_HasTheTitleProducerAndDates()
    {
        Assert.Equal("<</Title (Scan 1) /Producer (CompleteScanner) /Creator (CompleteScanner) " +
                     "/CreationDate (D:20261019213005+03'00') /ModDate (D:20261019213005+03'00')>>",
                     PdfA.InfoDictionary("Scan 1", Date));
        Assert.DoesNotContain("/Title", PdfA.InfoDictionary(null, Date));
    }

    [Fact]
    public void Xmp_IsWellFormed_AndNamesPdfA2b()
    {
        byte[] xmp = PdfA.Xmp("Fatura <özel> & \"ek\"", Date);
        Assert.False(xmp.AsSpan().StartsWith(Encoding.UTF8.Preamble)); // no byte order mark before the packet
        string text = Encoding.UTF8.GetString(xmp);
        Assert.StartsWith("<?xpacket begin=\"﻿\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>", text);
        Assert.EndsWith("<?xpacket end=\"w\"?>", text);
        var root = XDocument.Parse(text).Root!;
        XNamespace pdfaid = "http://www.aiim.org/pdfa/ns/id/", dc = "http://purl.org/dc/elements/1.1/",
                   xmpNs = "http://ns.adobe.com/xap/1.0/", pdf = "http://ns.adobe.com/pdf/1.3/",
                   xml = XNamespace.Xml;
        Assert.Equal("2", root.Descendants(pdfaid + "part").Single().Value);
        Assert.Equal("B", root.Descendants(pdfaid + "conformance").Single().Value);
        var title = root.Descendants(dc + "title").Single().Descendants().Single(e => e.Name.LocalName == "li");
        Assert.Equal("Fatura <özel> & \"ek\"", title.Value);
        Assert.Equal("x-default", title.Attribute(xml + "lang")!.Value);
        foreach (string date in new[] { "CreateDate", "ModifyDate", "MetadataDate" })
        {
            Assert.Equal("2026-10-19T21:30:05+03:00", root.Descendants(xmpNs + date).Single().Value);
        }
        Assert.Equal("CompleteScanner", root.Descendants(xmpNs + "CreatorTool").Single().Value);
        Assert.Equal("CompleteScanner", root.Descendants(pdf + "Producer").Single().Value);
        Assert.Empty(XDocument.Parse(Encoding.UTF8.GetString(PdfA.Xmp(null, Date))).Descendants(dc + "title"));
    }

    [Fact]
    public void SrgbProfile_IsTheCc0IccV2DisplayProfile()
    {
        byte[] icc = PdfA.SrgbProfile;
        Assert.Equal(736, icc.Length);
        Assert.Equal(736, (icc[0] << 24) | (icc[1] << 16) | (icc[2] << 8) | icc[3]); // size in the header
        Assert.Equal((2, 0x10), (icc[8], icc[9]));                                   // version 2.1
        Assert.Equal("mntr", Encoding.ASCII.GetString(icc, 12, 4));                  // display device
        Assert.Equal("RGB ", Encoding.ASCII.GetString(icc, 16, 4));
        Assert.Equal("XYZ ", Encoding.ASCII.GetString(icc, 20, 4));
        Assert.Equal("acsp", Encoding.ASCII.GetString(icc, 36, 4));
        Assert.Contains("CC0", Encoding.ASCII.GetString(icc));
        Assert.Equal("AF4EFE28F6D311799865F325BA39184A2E978B113CA74124D60AF7DE22B105F4",
                     Convert.ToHexString(SHA256.HashData(icc)));
    }

    [Fact]
    public void WriteOptions_FollowTheArchivalSetting()
    {
        var output = new OutputOptions();
        Assert.Equal(PdfConformance.Standard, PdfWriteOptions.For(output, "Scan 1").Conformance);
        Assert.Equal(PdfConformance.Standard, new PdfWriteOptions().Conformance);
        Assert.Equal(PdfConformance.Standard, Enum.GetValues<PdfConformance>()[0]);
        output.Archival = true;
        var options = PdfWriteOptions.For(output, "Scan 1");
        Assert.Equal((PdfConformance.PdfA2b, "Scan 1", true), (options.Conformance, options.Title, options.IsArchival));
        Assert.Null(options.CreationDate);
        Assert.Null(options.DocumentId);
    }

    // MARK: - The archival file

    [Fact]
    public void Archival_HeaderTrailerAndCatalog()
    {
        byte[] pdf = PdfBuilder.Make([Page(ScriptLines())], options: Archival());
        string text = Latin1(pdf);
        Assert.StartsWith("%PDF-1.7\n%", text);
        Assert.True(pdf.Skip(10).Take(4).All(b => b > 127), "binary comment");
        Assert.EndsWith("%%EOF\n", text);
        Assert.Contains($"/Root 1 0 R /Info 9 0 R /ID [<{IdHex}> <{IdHex}>]>>", text);
        Assert.DoesNotContain("/Encrypt", text);
        Assert.DoesNotContain("/Interpolate", text);
        Assert.DoesNotContain("LZWDecode", text);
        // Fixed numbering: 1 Catalog, 2 Pages, 3-8 the font, 9 Info, 10 Metadata, 11 profile, then the page.
        Assert.Contains("1 0 obj\n<</Type /Catalog /Pages 2 0 R /Metadata 10 0 R /OutputIntents " +
                        "[<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) " +
                        "/Info (sRGB IEC61966-2.1) /DestOutputProfile 11 0 R>>]>>\nendobj\n", text);
        Assert.Contains("2 0 obj\n<</Type /Pages /Kids [12 0 R] /Count 1>>", text);
        Assert.Contains("3 0 obj\n<</Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont /Encoding /Identity-H " +
                        "/DescendantFonts [4 0 R] /ToUnicode 8 0 R>>", text);
        Assert.Contains("4 0 obj\n<</Type /Font /Subtype /CIDFontType2 /BaseFont /GlyphLessFont " +
                        "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> " +
                        "/FontDescriptor 5 0 R /DW 500 /CIDToGIDMap 7 0 R>>", text);
        Assert.Contains("5 0 obj\n<</Type /FontDescriptor /FontName /GlyphLessFont /Flags 5 /FontBBox [0 0 500 1000] " +
                        "/ItalicAngle 0 /Ascent 1000 /Descent 0 /CapHeight 1000 /StemV 80 /FontFile2 6 0 R>>", text);
        Assert.Contains($"6 0 obj\n<</Length1 {GlyphlessFont.Program.Length} /Length {GlyphlessFont.Program.Length}>>\nstream\n", text);
        Assert.Contains($"7 0 obj\n<</Filter /FlateDecode /Length {GlyphlessFont.CidToGidMap.Length}>>\nstream\n", text);
        Assert.Contains("9 0 obj\n<</Title <FEFF", text);
        // The metadata is not compressed; the profile is the sRGB one with three components.
        int xmpLength = PdfA.Xmp(PdfA.CleanTitle("Tapu belgesi — Çağrı"), Date).Length;
        Assert.Contains($"10 0 obj\n<</Type /Metadata /Subtype /XML /Length {xmpLength}>>\nstream\n<?xpacket", text);
        Assert.Contains("11 0 obj\n<</N 3 /Length 736>>\nstream\n", text);
        Assert.Contains("12 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " +
                        "/Resources <</XObject <</Im0 13 0 R>> /Font <</F1 3 0 R>>>> /Contents 14 0 R>>", text);
        AssertXrefPointsAtEveryObject(text, 14);
    }

    [Fact]
    public void Archival_WithoutText_HasNoFont_AndNumbersOnFromThree()
    {
        string text = Latin1(PdfBuilder.Make([Page(), Page()], options: Archival(title: null)));
        Assert.DoesNotContain("/Font", text);
        Assert.Contains("/Metadata 4 0 R", text);
        Assert.Contains("/DestOutputProfile 5 0 R", text);
        Assert.Contains("3 0 obj\n<</Producer (CompleteScanner)", text);
        Assert.Contains("/Kids [6 0 R 9 0 R] /Count 2", text);
        Assert.Contains("/Info 3 0 R /ID", text);
        AssertXrefPointsAtEveryObject(text, 11);
    }

    [Fact]
    public void Standard_IsUnchanged_NoMetadataIntentOrId()
    {
        string text = Latin1(PdfBuilder.Make([Page(ScriptLines())]));
        Assert.StartsWith("%PDF-1.4\n", text);
        Assert.DoesNotContain("/Metadata", text);
        Assert.DoesNotContain("/OutputIntents", text);
        Assert.DoesNotContain("/ID", text);
        Assert.DoesNotContain("/Info", text);
        Assert.Contains("trailer\n<</Size 12 /Root 1 0 R>>", text);
        Assert.Contains("9 0 obj\n<</Type /Page", text);
        AssertXrefPointsAtEveryObject(text, 11);
    }

    [Fact]
    public void Archival_OpensWithMatchingMetadata()
    {
        byte[] pdf = PdfBuilder.Make([Page(ScriptLines())], options: Archival());
        using var document = PdfDocument.Open(pdf);
        Assert.Equal(1.7, document.Version, 3);
        Assert.False(document.IsEncrypted);
        Assert.Equal(1, document.NumberOfPages);
        var info = document.Information;
        Assert.Equal("Tapu belgesi — Çağrı", info.Title);
        Assert.Equal(("CompleteScanner", "CompleteScanner"), (info.Producer, info.Creator));
        Assert.Equal(("D:20261019213005+03'00'", "D:20261019213005+03'00'"), (info.CreationDate, info.ModifiedDate));

        Assert.True(document.TryGetXmpMetadata(out var metadata));
        // The packet is UTF-8, as XMP and PDF/A ask (PdfPig's own GetXDocument reads it as Latin-1).
        var root = XDocument.Parse(Encoding.UTF8.GetString([.. metadata.GetXmlBytes()])).Root!;
        XNamespace dc = "http://purl.org/dc/elements/1.1/", xmp = "http://ns.adobe.com/xap/1.0/",
                   pdfNs = "http://ns.adobe.com/pdf/1.3/", pdfaid = "http://www.aiim.org/pdfa/ns/id/";
        Assert.Equal(("2", "B"), (root.Descendants(pdfaid + "part").Single().Value,
                                  root.Descendants(pdfaid + "conformance").Single().Value));
        // Each XMP property says what the information dictionary says.
        Assert.Equal(info.Title, root.Descendants(dc + "title").Single().Value);
        Assert.Equal(info.Producer, root.Descendants(pdfNs + "Producer").Single().Value);
        Assert.Equal(info.Creator, root.Descendants(xmp + "CreatorTool").Single().Value);
        Assert.Equal(info.GetCreatedDateTimeOffset(), DateTimeOffset.Parse(root.Descendants(xmp + "CreateDate").Single().Value));
        Assert.Equal(info.GetModifiedDateTimeOffset(), DateTimeOffset.Parse(root.Descendants(xmp + "ModifyDate").Single().Value));
        Assert.Equal(Date, info.GetCreatedDateTimeOffset());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void TextLayer_GivesBackEveryScript(bool archival)
    {
        byte[] pdf = PdfBuilder.Make([Page(ScriptLines())], options: archival ? Archival() : null);
        using var document = PdfDocument.Open(pdf);
        var page = document.GetPage(1);
        Assert.Equal(string.Concat(Scripts), page.Text);
        Assert.All(page.Letters, letter => Assert.Contains(GlyphlessFont.FontName, letter.FontName));
        foreach (string line in Scripts) Assert.Contains(line, page.Text);
    }

    [Fact]
    public void TextLayer_LinesSitInTheirBoxes()
    {
        // A line 0.8 of the page wide at x 0.1 and 0.05 tall at y 0.5 (bottom-left origin) on Letter.
        var line = new OcrLine("Şehir İçi ığdır", new RectD(0.1, 0.5, 0.8, 0.05), 0.9f);
        byte[] pdf = PdfBuilder.Make([Page([line])]);
        using var document = PdfDocument.Open(pdf);
        var letters = document.GetPage(1).Letters;
        Assert.Equal(line.Text.Length, letters.Count);
        Assert.Equal(61.2, letters[0].StartBaseLine.X, 2);                 // 0.1 × 612
        Assert.Equal(396.0, letters[0].StartBaseLine.Y, 2);                // 0.5 × 792: the baseline is the box's bottom
        Assert.Equal(550.8, letters[^1].EndBaseLine.X, 1);                 // 0.9 × 612: the text spans the box
        Assert.Equal(39.6, letters[0].PointSize, 1);                       // 0.05 × 792
        string content = Latin1(pdf);
        Assert.Contains("/F1 39.6 Tf\n", content);
        Assert.Contains("1 0 0 1 61.2 396 Tm\n", content);
        // 15 code units × 0.5 em × 39.6 pt = 297 pt measured; 489.6 pt wanted.
        Assert.Contains("164.8485 Tz\n", content);
    }

    [Fact]
    public void TextLayer_ScaleIsClamped_AndEmptyLinesAreSkipped()
    {
        var lines = new List<OcrLine>
        {
            new("x", new RectD(0, 0.5, 1, 0.01), 0.9f),                       // far too wide: 5×
            new("a very long line squeezed into a tiny box", new RectD(0, 0.4, 0.01, 0.05), 0.9f), // 0.2×
            new("", new RectD(0, 0.3, 0.5, 0.05), 0.9f),
            new("flat", new RectD(0, 0.2, 0.5, 0), 0.9f),
        };
        string content = Latin1(PdfBuilder.Make([Page(lines)]));
        Assert.Contains("500 Tz\n", content);
        Assert.Contains("20 Tz\n", content);
        Assert.Equal(2, content.Split(" Tj\n").Length - 1);
    }

    // MARK: - Golden bytes

    [Fact]
    public void Archival_SameInputSameBytes_RandomIdOtherwise()
    {
        var pages = new[] { Page(ScriptLines()) };
        Assert.Equal(PdfBuilder.Make(pages, options: Archival()), PdfBuilder.Make(pages, options: Archival()));
        var undated = Archival() with { DocumentId = null };
        string first = Latin1(PdfBuilder.Make(pages, options: undated));
        string second = Latin1(PdfBuilder.Make(pages, options: undated));
        Assert.NotEqual(TrailerId(first), TrailerId(second));
        Assert.Equal(32, TrailerId(first).Length);
    }

    private static string TrailerId(string pdf)
    {
        int start = pdf.IndexOf("/ID [<", StringComparison.Ordinal) + "/ID [<".Length;
        return pdf[start..pdf.IndexOf('>', start)];
    }

    [Fact]
    public void Archival_GoldenBytes()
    {
        // One Letter page with a Turkish line, dated and identified: the Mac's writer port must match.
        var line = new OcrLine("Çağrı Işık İzmir'de öğün şüpheli", new RectD(0.1, 0.8, 0.6, 0.04), 0.9f);
        byte[] pdf = PdfBuilder.Make([Page([line])], options: Archival("Tapu belgesi — Çağrı"));
        Assert.Equal(11496, pdf.Length);
        Assert.Equal("6A264EF615EC82AFF45E74066288D6AD2274B83A6529B02F914E5D074954AA33", Convert.ToHexString(SHA256.HashData(pdf)));
    }

    [Fact]
    public void Standard_GoldenBytes()
    {
        var line = new OcrLine("Çağrı Işık İzmir'de öğün şüpheli", new RectD(0.1, 0.8, 0.6, 0.04), 0.9f);
        byte[] pdf = PdfBuilder.Make([Page([line]), Page()]);
        Assert.Equal(9865, pdf.Length);
        Assert.Equal("BC4C14E0219F0842DD5DCCF79918C9C5CC4B634954C927C3783635249FA3A779", Convert.ToHexString(SHA256.HashData(pdf)));
    }

    // MARK: - Files

    [Fact]
    public void WriteNewFile_WritesTheArchivalFile()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"PdfATests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "Arşiv.pdf");
            string written = PdfBuilder.WriteNewFile([Page(ScriptLines())], path, options: Archival());
            Assert.Equal(path, written);
            Assert.Equal(PdfBuilder.Make([Page(ScriptLines())], options: Archival()), File.ReadAllBytes(path));
            Assert.Equal([path], Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void WriteNewFile_TitlesTheFileWithTheNameItGot()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"PdfATests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "Scan 2026-10-19 1.pdf");
            // Another writer takes the name while this PDF is being built.
            string written = PdfBuilder.WriteNewFile([Page(ScriptLines())], path,
                _ => { if (!File.Exists(path)) File.WriteAllText(path, "other writer"); },
                options: Archival("Scan 2026-10-19 1"));
            Assert.Equal(Path.Combine(dir, "Scan 2026-10-19 1 2.pdf"), written);
            Assert.Equal("other writer", File.ReadAllText(path));
            Assert.Equal(PdfBuilder.Make([Page(ScriptLines())], options: Archival("Scan 2026-10-19 1 2")),
                         File.ReadAllBytes(written));
            using (var document = PdfDocument.Open(written))
                Assert.Equal("Scan 2026-10-19 1 2", document.Information.Title);
            Assert.Equal(new[] { path, written }.Order(), Directory.GetFiles(dir).Order());
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void WriteNewFile_KeepsATitleThatIsNotTheFileName()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"PdfATests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "out.pdf");
            File.WriteAllText(path, "other writer");
            string written = PdfBuilder.WriteNewFile([Page()], path, options: Archival("Own title"));
            Assert.Equal(Path.Combine(dir, "out 2.pdf"), written);
            Assert.Equal(PdfBuilder.Make([Page()], options: Archival("Own title")), File.ReadAllBytes(written));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    // MARK: - The object writer

    [Fact]
    public void ObjectWriter_WritesObjectsStreamsAndTheTable()
    {
        using var stream = new MemoryStream();
        var w = new PdfObjectWriter(stream);
        w.WriteHeader("1.4");
        w.WriteStream(2, "", "abc"u8);
        w.WriteObject(1, "<</Type /Catalog>>");
        w.Finish("/Root 1 0 R");
        string text = Latin1(stream.ToArray());
        Assert.Equal("%PDF-1.4\n%âãÏÓ\n" +
                     "2 0 obj\n<</Length 3>>\nstream\nabc\nendstream\nendobj\n" +
                     "1 0 obj\n<</Type /Catalog>>\nendobj\n" +
                     "xref\n0 3\n0000000000 65535 f \n0000000065 00000 n \n0000000015 00000 n \n" +
                     "trailer\n<</Size 3 /Root 1 0 R>>\nstartxref\n99\n%%EOF\n", text);
    }

    [Fact]
    public void ObjectWriter_RefusesGapsAndRepeats()
    {
        var w = new PdfObjectWriter(new MemoryStream());
        w.WriteObject(2, "null");
        Assert.Throws<InvalidOperationException>(() => w.WriteObject(2, "null"));
        Assert.Throws<ArgumentOutOfRangeException>(() => w.BeginObject(0));
        Assert.Throws<InvalidOperationException>(() => w.Finish("/Root 1 0 R"));
    }

    // MARK: - Helpers

    /// <summary>Every xref entry points at its "n 0 obj"; the table has <paramref name="objects"/> objects.</summary>
    private static void AssertXrefPointsAtEveryObject(string text, int objects)
    {
        int startxref = text.LastIndexOf("startxref\n", StringComparison.Ordinal) + "startxref\n".Length;
        int xref = int.Parse(text[startxref..text.IndexOf('\n', startxref)]);
        Assert.StartsWith($"xref\n0 {objects + 1}\n0000000000 65535 f \n", text[xref..]);
        string[] entries = text[xref..].Split('\n')[3..(3 + objects)];
        for (int n = 1; n <= objects; n++)
        {
            int offset = int.Parse(entries[n - 1][..10]);
            Assert.StartsWith($"{n} 0 obj\n", text[offset..]);
        }
    }
}
