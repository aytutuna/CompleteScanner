using System.IO.Compression;
using System.Text;

namespace CompleteScanner.Core.Tests;

/// <summary>
/// Small PDFs written by hand, byte by byte, for the reader and the appender: the layouts other
/// PDF writers use and ours does not — cross-reference streams with PNG predictors, objects inside
/// object streams, files already updated (/Prev), hybrid files (/XRefStm), page trees with inherited
/// attributes, nested nodes or an indirect /Kids — and broken or refused ones.
/// </summary>
internal sealed class PdfFixture
{
    private readonly MemoryStream _out = new();
    private readonly SortedDictionary<int, (long Offset, int Generation)> _section = [];
    private readonly SortedDictionary<int, (int Stream, int Index)> _compressed = [];

    public PdfFixture(string version = "1.4", string? newline = null)
    {
        Newline = newline ?? "\n";
        Raw($"%PDF-{version}{Newline}");
        Bytes([(byte)'%', 0xE2, 0xE3, 0xCF, 0xD3]);
        Raw(Newline);
    }

    public string Newline { get; }
    public long Position => _out.Position;

    public PdfFixture Raw(string text)
    {
        Bytes(Encoding.Latin1.GetBytes(text));
        return this;
    }

    public PdfFixture Bytes(byte[] bytes)
    {
        _out.Write(bytes);
        return this;
    }

    /// <summary>"n g obj body endobj", listed in the next cross-reference section.</summary>
    public PdfFixture Obj(int number, string body, int generation = 0)
    {
        _section[number] = (Position, generation);
        Raw($"{number} {generation} obj{Newline}{body}{Newline}endobj{Newline}");
        return this;
    }

    public PdfFixture Stream(int number, string entries, byte[] data, int generation = 0)
    {
        _section[number] = (Position, generation);
        Raw($"{number} {generation} obj{Newline}<<{entries} /Length {data.Length}>>{Newline}stream\r\n");
        Bytes(data);
        Raw($"{Newline}endstream{Newline}endobj{Newline}");
        return this;
    }

    /// <summary>An object stream holding <paramref name="objects"/> (Flate-compressed unless told not to).</summary>
    public PdfFixture ObjectStream(int number, (int Number, string Body)[] objects, bool flate = true)
    {
        var header = new StringBuilder();
        var body = new StringBuilder();
        for (int i = 0; i < objects.Length; i++)
        {
            header.Append($"{objects[i].Number} {body.Length} ");
            body.Append(objects[i].Body).Append('\n');
            _compressed[objects[i].Number] = (number, i);
        }
        string first = header.ToString();
        byte[] data = Encoding.Latin1.GetBytes(first + body);
        return Stream(number, $"/Type /ObjStm /N {objects.Length} /First {first.Length}{(flate ? " /Filter /FlateDecode" : "")}",
                      flate ? Deflate(data) : data);
    }

    /// <summary>A classic table of the objects written since the last section, its trailer, startxref and %%EOF. Returns its offset.</summary>
    public long Table(string trailerEntries, bool withZero = true, (int Number, int Generation)[]? free = null)
    {
        long at = Position;
        var entries = new SortedDictionary<int, string>();
        if (withZero) entries[0] = "0000000000 65535 f";
        foreach (var (n, (offset, generation)) in _section) entries[n] = $"{offset:D10} {generation:D5} n";
        foreach (var (n, generation) in free ?? []) entries[n] = $"0000000000 {generation:D5} f";
        var text = new StringBuilder($"xref{Newline}");
        foreach (var run in Runs(entries.Keys))
        {
            text.Append($"{run.First} {run.Count}{Newline}");
            for (int n = run.First; n < run.First + run.Count; n++) text.Append(entries[n]).Append(Newline.Length == 2 ? Newline : " " + Newline);
        }
        text.Append($"trailer{Newline}<<{trailerEntries}>>{Newline}startxref{Newline}{at}{Newline}%%EOF{Newline}");
        Raw(text.ToString());
        _section.Clear();
        return at;
    }

    /// <summary>
    /// A cross-reference stream, object <paramref name="number"/>, of the objects written (and put in
    /// object streams) since the last section and itself, /W [1 2 1] or wider, Flate with the PNG
    /// Up predictor unless told otherwise; then startxref and %%EOF unless <paramref name="end"/> is false. Returns its offset.
    /// </summary>
    public long XrefStream(int number, string entries, bool flate = true, int predictor = 12, int offsetWidth = 2,
                           bool end = true, (int Number, int Generation)[]? free = null, string? filter = null)
    {
        long at = Position;
        _section[number] = (at, 0);
        var rows = new SortedDictionary<int, byte[]>();
        foreach (var (n, (offset, generation)) in _section) rows[n] = Row(1, offset, generation, offsetWidth);
        foreach (var (n, (stream, at2)) in _compressed) rows[n] = Row(2, stream, at2, offsetWidth);
        foreach (var (n, generation) in free ?? []) rows[n] = Row(0, 0, generation, offsetWidth);
        int width = 1 + offsetWidth + 1;
        var raw = new MemoryStream();
        foreach (var row in rows.Values) raw.Write(row);
        byte[] data = raw.ToArray();
        string parameters = "";
        if (flate && predictor >= 10)
        {
            data = PngUp(data, width);
            parameters = $" /DecodeParms <</Predictor {predictor} /Columns {width}>>";
        }
        if (flate) data = Deflate(data);
        string index = string.Join(' ', Runs(rows.Keys).Select(r => $"{r.First} {r.Count}"));
        string filterEntry = filter ?? (flate ? " /Filter /FlateDecode" : "");
        _section.Clear();
        _compressed.Clear();
        Stream(number, $"/Type /XRef /W [1 {offsetWidth} 1] /Index [{index}]{filterEntry}{parameters} {entries}", data);
        _section.Clear();
        if (end) Raw($"startxref{Newline}{at}{Newline}%%EOF{Newline}");
        return at;
    }

    public byte[] ToArray() => _out.ToArray();

    private static byte[] Row(int type, long second, int third, int width)
    {
        var row = new byte[2 + width];
        row[0] = (byte)type;
        for (int b = 0; b < width; b++) row[1 + b] = (byte)(second >> ((width - 1 - b) * 8));
        row[1 + width] = (byte)third;
        return row;
    }

    /// <summary>PNG "Up" on every row (filter byte 2), as cross-reference streams usually are.</summary>
    internal static byte[] PngUp(byte[] data, int columns)
    {
        var output = new MemoryStream();
        var previous = new byte[columns];
        for (int at = 0; at < data.Length; at += columns)
        {
            output.WriteByte(2);
            for (int i = 0; i < columns; i++)
            {
                byte value = data[at + i];
                output.WriteByte((byte)(value - previous[i]));
                previous[i] = value;
            }
        }
        return output.ToArray();
    }

    internal static byte[] Deflate(byte[] data)
    {
        using var output = new MemoryStream();
        using (var z = new ZLibStream(output, CompressionLevel.Optimal, leaveOpen: true)) z.Write(data);
        return output.ToArray();
    }

    private static IEnumerable<(int First, int Count)> Runs(IEnumerable<int> numbers)
    {
        int first = -1, count = 0;
        foreach (int n in numbers)
        {
            if (count > 0 && n == first + count)
            {
                count++;
                continue;
            }
            if (count > 0) yield return (first, count);
            first = n;
            count = 1;
        }
        if (count > 0) yield return (first, count);
    }

    // MARK: - The corpus

    /// <summary>A content stream that draws nothing but says which page it is.</summary>
    private static byte[] Content(string label) => Encoding.ASCII.GetBytes($"BT /F1 12 Tf 72 72 Td ({label}) Tj ET");

    private const string Font = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>";

    /// <summary>Two pages, a classic table, never updated (PDF 1.4).</summary>
    public static byte[] Classic(string? newline = null, bool finalNewline = true)
    {
        var f = new PdfFixture("1.4", newline);
        f.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        f.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>");
        f.Obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</Font <</F1 7 0 R>>>> /Contents 5 0 R>>");
        f.Obj(4, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources <</Font <</F1 7 0 R>>>> /Contents 6 0 R>>");
        f.Stream(5, "", Content("one"));
        f.Stream(6, "", Content("two"));
        f.Obj(7, Font);
        f.Obj(8, "<</Producer (Fixture)>>");
        f.Table("/Size 9 /Root 1 0 R /Info 8 0 R /ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>]");
        byte[] bytes = f.ToArray();
        if (!finalNewline)
        {
            int end = bytes.Length;
            while (bytes[end - 1] is 10 or 13) end--;
            bytes = bytes[..end];
        }
        return bytes;
    }

    /// <summary><see cref="Classic"/> already updated once by another writer: a third page, object 6 freed, the tree rewritten.</summary>
    public static byte[] AlreadyUpdated()
    {
        byte[] original = Classic();
        long previous = StartXrefOf(original);
        var f = new PdfFixture();
        f._out.SetLength(0);
        f.Bytes(original);
        f.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 9 0 R] /Count 3>>");
        f.Obj(9, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources <<>> /Contents 10 0 R>>");
        f.Stream(10, "", Content("three"));
        f.Table($"/Size 11 /Root 1 0 R /Info 8 0 R /Prev {previous}", withZero: false);
        return f.ToArray();
    }

    /// <summary>PDF 1.5 with a cross-reference stream (Flate, PNG Up) and the catalog, tree and pages in an object stream.</summary>
    public static byte[] ObjectStreams(bool flateObjectStream = true, int predictor = 12)
    {
        var f = new PdfFixture("1.5");
        f.Stream(5, "", Content("one"));
        f.Stream(6, "", Content("two"));
        f.ObjectStream(10,
        [
            (1, "<</Type /Catalog /Pages 2 0 R>>"),
            (2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>"),
            (3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</Font <</F1 7 0 R>>>> /Contents 5 0 R>>"),
            (4, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources <</Font <</F1 7 0 R>>>> /Contents 6 0 R>>"),
            (7, Font),
        ], flateObjectStream);
        f.XrefStream(11, "/Size 12 /Root 1 0 R /ID [<A0A1A2A3A4A5A6A7A8A9AAABACADAEAF> <A0A1A2A3A4A5A6A7A8A9AAABACADAEAF>]",
                     predictor: predictor, free: [(0, 255)]);
        return f.ToArray();
    }

    /// <summary>
    /// A hybrid file: a classic table lists the content streams and says the objects in the
    /// object stream are free; its trailer's /XRefStm points at a stream that lists them.
    /// </summary>
    public static byte[] Hybrid()
    {
        var f = new PdfFixture("1.5");
        f.Stream(5, "", Content("one"));
        f.Stream(6, "", Content("two"));
        f.Obj(7, Font);
        f.ObjectStream(10,
        [
            (1, "<</Type /Catalog /Pages 2 0 R>>"),
            (2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>"),
            (3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</Font <</F1 7 0 R>>>> /Contents 5 0 R>>"),
            (4, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources <</Font <</F1 7 0 R>>>> /Contents 6 0 R>>"),
        ]);
        // The stream section lists only what a PDF 1.4 reader cannot find: the compressed objects.
        var classic = new SortedDictionary<int, (long, int)>(f._section);
        f._section.Clear();
        long stream = f.XrefStream(11, "/Size 12", end: false);
        foreach (var entry in classic) f._section[entry.Key] = entry.Value;
        f.Table($"/Size 12 /Root 1 0 R /XRefStm {stream}", free: [(1, 0), (2, 0), (3, 0), (4, 0), (11, 0)]);
        return f.ToArray();
    }

    /// <summary>The root passes /MediaBox, /CropBox, /Rotate and /Resources down; the pages say none of their own.</summary>
    public static byte[] Inherited()
    {
        var f = new PdfFixture();
        f.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        f.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300] /CropBox [10 10 190 290] /Rotate 90 /Resources <</Font <</F1 7 0 R>>>>>>");
        f.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>");
        f.Stream(5, "", Content("one"));
        f.Obj(7, Font);
        f.Table("/Size 8 /Root 1 0 R");
        return f.ToArray();
    }

    /// <summary>A root with an intermediate node holding two pages, then a page of its own; /Kids of the inner node is an indirect array.</summary>
    public static byte[] Nested()
    {
        var f = new PdfFixture();
        f.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        f.Obj(2, "<</Type /Pages /Kids [3 0 R 6 0 R] /Count 3>>");
        f.Obj(3, "<</Type /Pages /Parent 2 0 R /Kids 9 0 R /Count 2>>");
        f.Obj(9, "[4 0 R 5 0 R]");
        f.Obj(4, "<</Type /Page /Parent 3 0 R /MediaBox [0 0 100 100] /Resources <<>>>>");
        f.Obj(5, "<</Type /Page /Parent 3 0 R /MediaBox [0 0 200 200] /Resources <<>>>>");
        f.Obj(6, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources <<>>>>");
        f.Obj(7, "<<>>");
        f.Obj(8, "<<>>");
        f.Table("/Size 10 /Root 1 0 R");
        return f.ToArray();
    }

    /// <summary>The root's /Kids is an indirect array and its /Count an indirect number; the root is generation 1.</summary>
    public static byte[] IndirectKids()
    {
        var f = new PdfFixture();
        f.Obj(1, "<</Type /Catalog /Pages 2 1 R>>");
        f.Obj(2, "<</Type /Pages /Kids 4 0 R /Count 5 0 R /Odd#20Name (a\\(b\\)c\\\\ \\r end) /Hex <4142> /Real -.5>>", generation: 1);
        f.Obj(3, "<</Type /Page /Parent 2 1 R /MediaBox [0 0 612 792] /Resources <<>>>>");
        f.Obj(4, "[3 0 R]");
        f.Obj(5, "1");
        f.Table("/Size 6 /Root 1 0 R");
        return f.ToArray();
    }

    /// <summary>A one-page file whose catalog adds <paramref name="catalogEntries"/> and objects 4 and up (<paramref name="extra"/>).</summary>
    public static byte[] WithCatalog(string catalogEntries, Action<PdfFixture>? extra = null, string version = "1.4")
    {
        var f = new PdfFixture(version);
        f.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalogEntries}>>");
        f.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>");
        f.Obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <<>>>>");
        extra?.Invoke(f);
        f.Table("/Size 6 /Root 1 0 R /ID [<0F0E0D0C0B0A09080706050403020100> <0F0E0D0C0B0A09080706050403020100>]");
        return f.ToArray();
    }

    /// <summary>XMP saying pdfaid part and conformance, as attributes (or as elements).</summary>
    public static byte[] Xmp(int part, string conformance, bool asElements = false)
    {
        string id = asElements
            ? $"<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"><pdfaid:part>{part}</pdfaid:part><pdfaid:conformance>{conformance}</pdfaid:conformance></rdf:Description>"
            : $"<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"{part}\" pdfaid:conformance=\"{conformance}\"/>";
        return Encoding.UTF8.GetBytes(
            "<?xpacket begin=\"﻿\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" +
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
            id + "</rdf:RDF></x:xmpmeta>\n<?xpacket end=\"w\"?>");
    }

    /// <summary>A file claiming PDF/A <paramref name="part"/><paramref name="conformance"/> with an output intent of <paramref name="components"/> components.</summary>
    public static byte[] PdfA(int part, string conformance, int components = 3, bool compressedXmp = false) =>
        WithCatalog("/Metadata 4 0 R /OutputIntents [<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (x) /DestOutputProfile 5 0 R>>]", f =>
        {
            byte[] xmp = Xmp(part, conformance);
            f.Stream(4, "/Type /Metadata /Subtype /XML" + (compressedXmp ? " /Filter /FlateDecode" : ""), compressedXmp ? Deflate(xmp) : xmp);
            f.Stream(5, $"/N {components}", [1, 2, 3]);
        });

    /// <summary>The value after the last "startxref".</summary>
    public static long StartXrefOf(byte[] pdf)
    {
        string text = Encoding.Latin1.GetString(pdf);
        int at = text.LastIndexOf("startxref", StringComparison.Ordinal) + "startxref".Length;
        return long.Parse(text[at..].Trim().Split('\n', '\r')[0].Trim());
    }
}
