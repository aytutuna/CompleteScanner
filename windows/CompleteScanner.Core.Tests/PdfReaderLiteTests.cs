using System.Text;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The reader the appender stands on: PDF syntax, the filters it undoes, every way the
// cross-reference data can be laid out, the page tree, and the files it refuses. The Swift twins
// have the same cases: PDFSyntaxTests.swift (syntax and filters) and PDFReaderLiteTests.swift.

public class PdfReaderLiteTests
{
    private static PdfObject Parse(string text) => new PdfLexer(new PdfArrayBytes(Encoding.Latin1.GetBytes(text))).ReadObject();

    // MARK: - Syntax

    [Fact]
    public void Lexer_ReadsEveryKindOfValue()
    {
        var dictionary = Assert.IsType<PdfDictionary>(Parse(
            "<</Name /A#20B#23 /Int -12 /Real +.5 /Ref 12 3 R /Array [1 2 3 0 R true false null] % comment\n" +
            "/Literal (a(b)c\\)\\\\\\101\\n\\\r\nx) /Hex <48 65 6c6C 6>>>"));
        Assert.Equal("A B#", Assert.IsType<PdfName>(dictionary["Name"]).Value);
        Assert.Equal(-12, Assert.IsType<PdfNumber>(dictionary["Int"]).Integer);
        var real = Assert.IsType<PdfNumber>(dictionary["Real"]);
        Assert.Equal(0.5, real.Value);
        Assert.Null(real.Integer);
        var reference = Assert.IsType<PdfReference>(dictionary["Ref"]);
        Assert.Equal((12, 3), (reference.Number, reference.Generation));
        var array = Assert.IsType<PdfArray>(dictionary["Array"]);
        Assert.Collection(array.Items,
            item => Assert.Equal(1, Assert.IsType<PdfNumber>(item).Integer),
            item => Assert.Equal(2, Assert.IsType<PdfNumber>(item).Integer),
            item => Assert.Equal(3, Assert.IsType<PdfReference>(item).Number),
            item => Assert.True(Assert.IsType<PdfBoolean>(item).Value),
            item => Assert.False(Assert.IsType<PdfBoolean>(item).Value),
            item => Assert.IsType<PdfNull>(item));
        Assert.Equal("a(b)c)\\A\nx", Encoding.Latin1.GetString(Assert.IsType<PdfString>(dictionary["Literal"]).Bytes));
        var hex = Assert.IsType<PdfString>(dictionary["Hex"]);
        Assert.True(hex.IsHex);
        Assert.Equal("Hell`", Encoding.Latin1.GetString(hex.Bytes));
    }

    [Fact]
    public void Values_WriteBackAsTheSameValues()
    {
        const string text = "<</A#20B /x /S (a\\(b\\)\\\\c\ré) /H <00FF> /N -.5 /R 4 0 R /Arr [/a 1 [2]] /D <</In true>>>>";
        string written = Parse(text).ToString();
        Assert.Equal("<</A#20B /x /S (a\\(b\\)\\\\c\\n\\351) /H <00FF> /N -.5 /R 4 0 R /Arr [/a 1 [2]] /D <</In true>>>>", written);
        Assert.Equal(written, Parse(written).ToString());
    }

    [Fact]
    public void Lexer_RefusesWhatIsNotAnObject()
    {
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Parse("<</A (open")).Problem);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Parse("<</A 1 2>>")).Problem);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Parse("[1 2")).Problem);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => Parse("1.2.3")).Problem);
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => Parse(new string('[', 500))).Problem);
    }

    // MARK: - Filters

    [Fact]
    public void PngPredictors_UndoEveryRowFilter()
    {
        // Two rows of three bytes, one byte per pixel: None, Sub, Up, Average, Paeth.
        byte[] rows = [10, 20, 30, 15, 25, 40];
        byte[] Encode(int type)
        {
            var output = new List<byte>();
            byte[] previous = [0, 0, 0];
            for (int r = 0; r < 2; r++)
            {
                output.Add((byte)type);
                for (int i = 0; i < 3; i++)
                {
                    int x = rows[r * 3 + i], a = i > 0 ? rows[r * 3 + i - 1] : 0, b = previous[i], c = i > 0 ? previous[i - 1] : 0;
                    int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
                    int predicted = type switch
                    {
                        0 => 0, 1 => a, 2 => b, 3 => (a + b) / 2,
                        _ => pa <= pb && pa <= pc ? a : pb <= pc ? b : c,
                    };
                    output.Add((byte)(x - predicted));
                }
                previous = rows[(r * 3)..(r * 3 + 3)];
            }
            return [.. output];
        }
        var parameters = Assert.IsType<PdfDictionary>(Parse("<</Predictor 15 /Columns 3>>"));
        for (int type = 0; type <= 4; type++) Assert.Equal(rows, PdfFilters.Predict(Encode(type), parameters));
        // TIFF predictor 2: each byte after the first of a row is the difference from the one before.
        var tiff = Assert.IsType<PdfDictionary>(Parse("<</Predictor 2 /Columns 3>>"));
        Assert.Equal(rows, PdfFilters.Predict([10, 10, 10, 15, 10, 15], tiff));
    }

    [Fact]
    public void Filters_InflateFlate_RefuseOthers()
    {
        byte[] data = Encoding.ASCII.GetBytes("hello hello hello");
        Assert.Equal(data, PdfFilters.Decode(PdfFixture.Deflate(data), new PdfName("FlateDecode"), null));
        byte[] wrong = PdfFixture.Deflate(data);
        wrong[^1] ^= 1; // the Adler-32
        Assert.Equal(PdfReadProblem.Damaged,
                     Assert.Throws<PdfReadException>(() => PdfFilters.Decode(wrong, new PdfName("FlateDecode"), null)).Problem);
        Assert.Equal(data, PdfFilters.Decode(data, null, null));
        Assert.Equal(PdfReadProblem.Unsupported,
                     Assert.Throws<PdfReadException>(() => PdfFilters.Decode(data, new PdfName("LZWDecode"), null)).Problem);
        Assert.Equal(PdfReadProblem.Damaged,
                     Assert.Throws<PdfReadException>(() => PdfFilters.Decode([0xFF, 0xFF, 0xFF, 0xFF], new PdfName("FlateDecode"), null)).Problem);
    }

    // MARK: - Cross-reference layouts

    [Fact]
    public void Classic_ReadsTheTreeAndTheTrailer()
    {
        var reader = new PdfReaderLite(PdfFixture.Classic());
        Assert.Equal("1.4", reader.Version);
        Assert.Equal(2, reader.PageCount);
        Assert.Equal(1, reader.SectionCount);
        Assert.Null(reader.LatestPrev);
        Assert.False(reader.XrefIsStream);
        Assert.False(reader.IsHybrid);
        Assert.False(reader.HasObjectStreams);
        Assert.False(reader.IsEncrypted);
        Assert.False(reader.IsSigned);
        Assert.Null(reader.PdfAPart);
        Assert.Equal(9, reader.NextObjectNumber);
        Assert.Equal([3, 4], reader.Pages.Select(p => p.Number));
        Assert.Equal(new PdfReference(8, 0), reader.Trailer["Info"]);
    }

    [Theory]
    [InlineData("\r\n", true)]
    [InlineData("\r", true)]
    [InlineData("\n", false)]
    public void Classic_ReadsAnyEndOfLine_AndAFileWithoutAFinalOne(string newline, bool finalNewline)
    {
        var reader = new PdfReaderLite(PdfFixture.Classic(newline, finalNewline));
        Assert.Equal(2, reader.PageCount);
    }

    [Fact]
    public void AlreadyUpdated_TheNewestRevisionWins()
    {
        byte[] pdf = PdfFixture.AlreadyUpdated();
        var reader = new PdfReaderLite(pdf);
        Assert.Equal(2, reader.SectionCount);
        Assert.Equal(PdfFixture.StartXrefOf(PdfFixture.Classic()), reader.LatestPrev);
        Assert.Equal([3, 4, 9], reader.Pages.Select(p => p.Number));
        Assert.Equal(11, reader.NextObjectNumber);
        // Root and Info come from the newest trailer; the /ID only the first one has.
        Assert.IsType<PdfArray>(reader.Trailer["ID"]);
        Assert.Equal(3, Assert.IsType<PdfNumber>(Assert.IsType<PdfDictionary>(reader.Get(2))["Count"]).Integer);
    }

    [Theory]
    [InlineData(true, 12)]
    [InlineData(true, 10)]
    [InlineData(false, 12)]
    public void ObjectStreams_ReadsCompressedObjects(bool flate, int predictor)
    {
        var reader = new PdfReaderLite(PdfFixture.ObjectStreams(flate, predictor));
        Assert.True(reader.XrefIsStream);
        Assert.True(reader.HasObjectStreams);
        Assert.Equal("1.5", reader.Version);
        Assert.Equal(2, reader.PageCount);
        Assert.Equal(12, reader.NextObjectNumber);
        Assert.Equal("Font", Assert.IsType<PdfName>(Assert.IsType<PdfDictionary>(reader.Get(7))["Type"]).Value);
    }

    [Fact]
    public void Hybrid_FindsWhatOnlyTheStreamLists()
    {
        var reader = new PdfReaderLite(PdfFixture.Hybrid());
        Assert.True(reader.IsHybrid);
        Assert.False(reader.XrefIsStream);
        Assert.Equal(2, reader.PageCount);
        Assert.IsType<PdfDictionary>(reader.Get(1));
        Assert.IsType<PdfStream>(reader.Get(5));
    }

    [Fact]
    public void PageTree_NestedNodesAndIndirectKids_InReadingOrder()
    {
        Assert.Equal([4, 5, 6], new PdfReaderLite(PdfFixture.Nested()).Pages.Select(p => p.Number));
        var indirect = new PdfReaderLite(PdfFixture.IndirectKids());
        Assert.Equal(1, indirect.PageCount);
        Assert.Equal(1, indirect.GenerationOf(2));
    }

    [Fact]
    public void OurOwnFiles_ReadBack()
    {
        var page = new PdfPageInput(PdfBuilderTests.TinyJpeg, 100, 150, 300, [new OcrLine("Çağrı", new RectD(0.1, 0.1, 0.5, 0.1), 1)]);
        var plain = new PdfReaderLite(PdfBuilder.Make([page, page, page]));
        Assert.Equal(3, plain.PageCount);
        var archival = new PdfReaderLite(PdfBuilder.Make([page], options: new PdfWriteOptions { Conformance = PdfConformance.PdfA2b }));
        Assert.Equal((2, "B"), (archival.PdfAPart, archival.PdfAConformance));
        Assert.Equal(3, archival.OutputIntentComponents);
        using var protection = new PdfProtection("pw");
        var encrypted = new PdfReaderLite(PdfBuilder.Make([page], options: new PdfWriteOptions { Protection = protection }));
        Assert.True(encrypted.IsEncrypted);
        Assert.Equal(0, encrypted.PageCount);
    }

    [Fact]
    public void ReadsFromAStream_AFewBlocksAtATime()
    {
        var page = new PdfPageInput(new byte[200_000], 100, 150, 300, null);
        byte[] pdf = PdfBuilder.Make([page, page, page]);
        using var reader = new PdfReaderLite(new MemoryStream(pdf), leaveOpen: false);
        Assert.Equal(3, reader.PageCount);
        Assert.Equal(pdf.Length, reader.Length);
    }

    // MARK: - Facts

    [Fact]
    public void Signed_BySignatureFlagsOrPermissions()
    {
        Assert.True(new PdfReaderLite(PdfFixture.WithCatalog("/AcroForm <</Fields [] /SigFlags 3>>")).IsSigned);
        Assert.True(new PdfReaderLite(PdfFixture.WithCatalog("/Perms <</DocMDP 4 0 R>>", f => f.Obj(4, "<<>>"))).IsSigned);
        Assert.False(new PdfReaderLite(PdfFixture.WithCatalog("/AcroForm <</Fields [] /SigFlags 2>>")).IsSigned);
    }

    [Fact]
    public void Certified_ByADocMDPSignatureOnly()
    {
        var certified = new PdfReaderLite(PdfFixture.WithCatalog("/Perms 4 0 R", f => f.Obj(4, "<</DocMDP 5 0 R>>").Obj(5, "<</Type /Sig>>")));
        Assert.True(certified.IsCertified);
        Assert.True(certified.IsSigned);
        var usageRights = new PdfReaderLite(PdfFixture.WithCatalog("/Perms <</UR3 4 0 R>>", f => f.Obj(4, "<<>>")));
        Assert.False(usageRights.IsCertified);
        Assert.True(usageRights.IsSigned);
        Assert.False(new PdfReaderLite(PdfFixture.WithCatalog("/AcroForm <</Fields [] /SigFlags 3>>")).IsCertified);
        Assert.False(new PdfReaderLite(PdfFixture.Classic()).IsCertified);
    }

    [Fact]
    public void ObjectsReadWhenAskedFor_ThrowWhenTheyDoNotHoldUp()
    {
        // The page tree reads fine; the form's entry points at another object.
        byte[] pdf = Replace(PdfFixture.WithCatalog("/AcroForm 4 0 R", f => f.Obj(4, "<</Fields [] /SigFlags 3>>")), "4 0 obj", "5 0 obj");
        var reader = new PdfReaderLite(pdf);
        Assert.Equal(1, reader.PageCount);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => reader.IsSigned).Problem);
    }

    [Fact]
    public void PdfA_ReadFromTheMetadata()
    {
        var a1 = new PdfReaderLite(PdfFixture.PdfA(1, "A"));
        Assert.Equal((1, "A"), (a1.PdfAPart, a1.PdfAConformance));
        var compressed = new PdfReaderLite(PdfFixture.PdfA(3, "u", components: 4, compressedXmp: true));
        Assert.Equal((3, "U"), (compressed.PdfAPart, compressed.PdfAConformance));
        Assert.Equal(4, compressed.OutputIntentComponents);
        Assert.Equal((2, "B"), PdfReaderLite.ReadPdfAId(PdfFixture.Xmp(2, "B", asElements: true)));
        Assert.Equal((null, null), PdfReaderLite.ReadPdfAId(Encoding.UTF8.GetBytes("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><broken")));
        Assert.Null(new PdfReaderLite(PdfFixture.Classic()).PdfAPart);
    }

    // MARK: - Refused

    private static PdfReadProblem Refused(byte[] pdf) => Assert.Throws<PdfReadException>(() => new PdfReaderLite(pdf)).Problem;

    private static byte[] Replace(byte[] pdf, string from, string to)
    {
        string text = Encoding.Latin1.GetString(pdf);
        Assert.Contains(from, text);
        return Encoding.Latin1.GetBytes(text.Replace(from, to));
    }

    [Fact]
    public void Refuses_NotAPdf_AndBytesBeforeTheHeader()
    {
        Assert.Equal(PdfReadProblem.NotPdf, Refused(Encoding.ASCII.GetBytes("hello, this is text")));
        Assert.Equal(PdfReadProblem.Unsupported, Refused([.. Encoding.ASCII.GetBytes("junk\n"), .. PdfFixture.Classic()]));
    }

    [Fact]
    public void Refuses_ATruncatedFile()
    {
        byte[] pdf = PdfFixture.Classic();
        Assert.Equal(PdfReadProblem.Damaged, Refused(pdf[..(pdf.Length / 2)]));
        Assert.Equal(PdfReadProblem.Damaged, Refused(pdf[..^8]));
    }

    [Fact]
    public void Refuses_OffsetsThatDoNotHoldUp()
    {
        byte[] pdf = PdfFixture.Classic();
        long xref = PdfFixture.StartXrefOf(pdf);
        // startxref off by one byte into the table.
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(pdf, $"startxref\n{xref}", $"startxref\n{xref + 1}")));
        // An object listed where another one is.
        string text = Encoding.Latin1.GetString(pdf);
        string catalogEntry = $"{text.IndexOf("1 0 obj", StringComparison.Ordinal):D10} 00000 n";
        string pagesEntry = $"{text.IndexOf("2 0 obj", StringComparison.Ordinal):D10} 00000 n";
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(pdf, catalogEntry, pagesEntry)));
    }

    [Fact]
    public void Refuses_APrevLoop()
    {
        byte[] pdf = PdfFixture.AlreadyUpdated();
        long first = PdfFixture.StartXrefOf(PdfFixture.Classic());
        long last = PdfFixture.StartXrefOf(pdf);
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(pdf, $"/Prev {first}", $"/Prev {last}")));
    }

    [Fact]
    public void Refuses_APageTreeLoop_AndAMissingTree()
    {
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(PdfFixture.Classic(), "/Kids [3 0 R 4 0 R]", "/Kids [2 0 R 4 0 R]")));
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(PdfFixture.Classic(), "/Pages 2 0 R>>", "/Pagez 2 0 R>>")));
    }

    [Fact]
    public void Refuses_ATreeWhoseRootIsAPage()
    {
        var f = new PdfFixture();
        f.Obj(1, "<</Type /Catalog /Pages 3 0 R>>");
        f.Obj(3, "<</Type /Page /MediaBox [0 0 612 792] /Resources <<>>>>");
        f.Table("/Size 4 /Root 1 0 R");
        var e = Assert.Throws<PdfReadException>(() => new PdfReaderLite(f.ToArray()));
        Assert.Equal(PdfReadProblem.Damaged, e.Problem);
        Assert.Equal("The page tree's root has no /Kids.", e.Message);
        // A root without /Type still counts as a node when it has kids.
        Assert.Equal(1, new PdfReaderLite(Replace(PdfFixture.WithCatalog(""), "<</Type /Pages /Kids", "<<             /Kids")).PageCount);
    }

    [Fact]
    public void Refuses_ObjectNumbersPastPdfsLimit()
    {
        byte[] pdf = PdfFixture.WithCatalog("");
        Assert.Equal(8_388_608, new PdfReaderLite(Replace(pdf, "/Size 6 ", "/Size 8388608 ")).NextObjectNumber);
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(pdf, "/Size 6 ", "/Size 8388609 ")));
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(pdf, "/Size 6 ", "/Size 2147483647 ")));
        // A table subsection that runs past it.
        Assert.Contains("highest object number", Assert.Throws<PdfReadException>(() => new PdfReaderLite(Replace(pdf, "xref\n0 4\n", "xref\n8388605 4\n"))).Message);
        // A cross-reference stream's /Size and /Index.
        byte[] streams = PdfFixture.ObjectStreams();
        Assert.Equal(PdfReadProblem.Damaged, Refused(Replace(streams, "/Size 12 ", "/Size 8388609 ")));
        Assert.Contains("highest object number", Assert.Throws<PdfReadException>(() => new PdfReaderLite(Replace(streams, "/Index [0 ", "/Index [8388605 "))).Message);
    }

    [Fact]
    public void Refuses_AStreamFilterItCannotUndo()
    {
        byte[] pdf = PdfFixture.ObjectStreams();
        Assert.Equal(PdfReadProblem.Unsupported, Refused(Replace(pdf, "/Filter /FlateDecode /DecodeParms", "/Filter /LZWDecode /DecodeParms")));
    }

    [Fact]
    public void Encrypted_IsReported_NotRead()
    {
        byte[] pdf = PdfFixture.WithCatalog("", f => f.Obj(4, "<</Filter /Standard /V 2 /R 3>>"));
        var reader = new PdfReaderLite(Replace(pdf, "/Size 6 /Root 1 0 R", "/Size 6 /Root 1 0 R /Encrypt 4 0 R"));
        Assert.True(reader.IsEncrypted);
        Assert.Equal(0, reader.PageCount);
    }
}
