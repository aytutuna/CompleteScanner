using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Output/PDFReaderLite.swift: the same layouts, limits, refusals
// and error texts.

/// <summary>
/// Just enough of a PDF reader to add pages to an existing file (<see cref="PdfAppender"/>): the
/// cross-reference data — classic tables and cross-reference streams (with their PNG predictors),
/// every earlier revision through /Prev, the hybrid files' /XRefStm — objects stored on their own
/// or inside object streams, the trailer, the catalog and the page tree, and a few facts about the
/// file (encrypted, signed, PDF/A). It reads the bytes where the cross-reference data says objects
/// are and refuses a file whose data does not hold up (<see cref="PdfReadException"/>): it never
/// guesses or repairs. Page contents, fonts and images are never read.
/// </summary>
public sealed class PdfReaderLite : IDisposable
{
    /// <summary>Longest /Prev chain followed (a loop is caught before that).</summary>
    private const int MaxSections = 4096;
    /// <summary>Deepest page tree walked (a cycle is caught before that).</summary>
    private const int MaxTreeDepth = 256;
    /// <summary>
    /// The highest object number a PDF may use (ISO 32000-1 Annex C): a file whose cross-reference
    /// data goes past it is refused, and an update never numbers an object above it.
    /// </summary>
    internal const int MaxObjectNumber = 8_388_607;

    private enum EntryKind { Free, InUse, Compressed }

    /// <summary>One cross-reference entry: in use at an offset, in an object stream at an index, or free.</summary>
    private readonly record struct Entry(EntryKind Kind, long Offset, int Generation, int StreamNumber, int Index);

    private readonly Stream? _ownedStream;
    private readonly PdfBytes _bytes;
    private readonly Dictionary<int, Entry> _entries = [];
    private readonly Dictionary<int, PdfObject> _objects = [];
    private readonly Dictionary<int, (byte[] Data, Dictionary<int, long> Offsets, List<int> Order)> _objectStreams = [];
    private readonly HashSet<int> _resolving = [];
    private List<PdfReference>? _pages;

    /// <summary>Opens <paramref name="path"/> for reading (others may read it meanwhile, not write it).</summary>
    public static PdfReaderLite Open(string path)
    {
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            return new PdfReaderLite(stream, leaveOpen: false);
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    /// <summary>A PDF in memory.</summary>
    public PdfReaderLite(byte[] pdf) : this(new PdfArrayBytes(pdf), null) { }

    /// <summary>
    /// A PDF read from a seekable stream, a block at a time; disposed with the reader unless
    /// <paramref name="leaveOpen"/>.
    /// </summary>
    public PdfReaderLite(Stream stream, bool leaveOpen = false) : this(new PdfStreamBytes(stream), leaveOpen ? null : stream) { }

    private PdfReaderLite(PdfBytes bytes, Stream? owned)
    {
        _bytes = bytes;
        _ownedStream = owned;
        Version = ReadHeader();
        StartXref = FindStartXref();
        LoadCrossReferences();
        if (Trailer["Encrypt"] is { } encrypt && encrypt is not PdfNull)
        {
            IsEncrypted = true;
            return; // nothing else can be read without the key
        }
        if (Trailer["Root"] is not PdfReference root) throw PdfReadException.Damaged("The trailer names no catalog (/Root).");
        Root = root;
        if (Resolve(root) is not PdfDictionary catalog) throw PdfReadException.Damaged("The catalog is not a dictionary.");
        Catalog = catalog;
        if (catalog["Pages"] is not PdfReference pages) throw PdfReadException.Damaged("The catalog has no page tree (/Pages).");
        PagesRoot = pages;
        if (Resolve(pages) is not PdfDictionary pagesDictionary) throw PdfReadException.Damaged("The page tree's root is not a dictionary.");
        PagesRootDictionary = pagesDictionary;
        // New pages are added to the root's /Kids: a root that is a page itself has none.
        if (Resolve(pagesDictionary["Kids"]) is not PdfArray) throw PdfReadException.Damaged("The page tree's root has no /Kids.");
        _pages = WalkPageTree(pages);
    }

    public void Dispose() => _ownedStream?.Dispose();

    // MARK: - What the file is

    /// <summary>The bytes in the file; an update starts after them.</summary>
    public long Length => _bytes.Length;

    /// <summary>The header's version, "1.4" in "%PDF-1.4".</summary>
    public string Version { get; }

    /// <summary>Where the newest cross-reference section starts (the last "startxref" value).</summary>
    public long StartXref { get; }

    /// <summary>The newest section is a cross-reference stream, so an update writes one too.</summary>
    public bool XrefIsStream { get; private set; }

    /// <summary>Where the newest section's /Prev points (the section before it); null for a file never updated.</summary>
    public long? LatestPrev { get; private set; }

    /// <summary>Some section is a classic table that also points at a cross-reference stream (/XRefStm).</summary>
    public bool IsHybrid { get; private set; }

    /// <summary>Cross-reference sections read: 1 for a file never updated, one more per incremental update.</summary>
    public int SectionCount { get; private set; }

    /// <summary>Some objects are stored inside object streams.</summary>
    public bool HasObjectStreams => _entries.Values.Any(e => e.Kind == EntryKind.Compressed);

    /// <summary>The file has an /Encrypt dictionary; nothing past the trailer is read then.</summary>
    public bool IsEncrypted { get; }

    /// <summary>
    /// The first object number an update can use: the trailer's /Size, or one past the highest
    /// number any section lists when that is higher.
    /// </summary>
    public int NextObjectNumber { get; private set; }

    /// <summary>The pages in reading order; 0 for an encrypted file.</summary>
    public int PageCount => _pages?.Count ?? 0;

    /// <summary>
    /// The file is signed: its form says signatures exist (/SigFlags bit 1) or the catalog carries
    /// signature permissions (/Perms). Adding pages keeps the signed revision intact, but viewers
    /// show the signature as followed by changes. Read when asked (throws <see cref="PdfReadException"/>).
    /// </summary>
    public bool IsSigned
    {
        get
        {
            if (Catalog is null) return false;
            if (Resolve(Catalog["Perms"]) is PdfDictionary { Entries.Count: > 0 }) return true;
            return Resolve(Catalog["AcroForm"]) is PdfDictionary form
                   && Resolve(form["SigFlags"]) is PdfNumber { Integer: { } flags } && (flags & 1) != 0;
        }
    }

    /// <summary>
    /// The file is certified: its catalog's /Perms has a /DocMDP signature. No certification
    /// allows adding pages (ISO 32000-1 12.8.2.2), so viewers show it as no longer valid after.
    /// </summary>
    public bool IsCertified =>
        Catalog is not null && Resolve(Catalog["Perms"]) is PdfDictionary perms && Resolve(perms["DocMDP"]) is not null;

    /// <summary>The PDF/A part its XMP metadata claims (1, 2, 3, 4), or null when it claims none.</summary>
    public int? PdfAPart => PdfAIdentification().Part;

    /// <summary>The PDF/A conformance level its metadata claims ("A", "B", "U"), or null.</summary>
    public string? PdfAConformance => PdfAIdentification().Conformance;

    /// <summary>
    /// The number of components of the PDF/A output intent's profile (3 for RGB, 4 for CMYK, 1 for
    /// gray); null without one.
    /// </summary>
    public int? OutputIntentComponents
    {
        get
        {
            if (Catalog is null || Resolve(Catalog["OutputIntents"]) is not PdfArray intents) return null;
            foreach (var item in intents.Items)
            {
                if (Resolve(item) is not PdfDictionary intent) continue;
                if (Resolve(intent["S"]) is not PdfName { Value: "GTS_PDFA1" }) continue;
                if (Resolve(intent["DestOutputProfile"]) is PdfStream profile
                    && Resolve(profile.Dictionary["N"]) is PdfNumber { Integer: { } n })
                {
                    return (int)n;
                }
            }
            return null;
        }
    }

    // MARK: - Objects (for PdfAppender and the tests)

    /// <summary>The newest trailer, with /Root, /Info and /ID taken from an older one when the newest lacks them.</summary>
    internal PdfDictionary Trailer { get; private set; } = new();

    internal PdfReference? Root { get; }
    internal PdfDictionary? Catalog { get; }
    internal PdfReference? PagesRoot { get; }
    internal PdfDictionary? PagesRootDictionary { get; }

    /// <summary>The page objects in reading order.</summary>
    internal IReadOnlyList<PdfReference> Pages => _pages ?? [];

    /// <summary>The object an indirect reference points to (null when it is free or missing: PDF's null).</summary>
    internal PdfObject? Resolve(PdfObject? value)
    {
        int hops = 0;
        while (value is PdfReference reference)
        {
            if (++hops > 32) throw PdfReadException.Damaged("References point at each other.");
            value = Get(reference.Number);
        }
        return value is PdfNull ? null : value;
    }

    /// <summary>Object <paramref name="number"/> as the newest revision has it; null when free or not listed.</summary>
    internal PdfObject? Get(int number)
    {
        if (_objects.TryGetValue(number, out var cached)) return cached;
        if (!_entries.TryGetValue(number, out var entry) || entry.Kind == EntryKind.Free) return null;
        if (!_resolving.Add(number)) throw PdfReadException.Damaged($"Object {number} refers to itself.");
        try
        {
            var value = entry.Kind == EntryKind.InUse ? ReadObjectAt(entry.Offset, number) : ReadCompressed(number, entry);
            _objects[number] = value;
            return value;
        }
        finally
        {
            _resolving.Remove(number);
        }
    }

    /// <summary>The generation the newest revision gives object <paramref name="number"/>.</summary>
    internal int GenerationOf(int number) => _entries.TryGetValue(number, out var e) && e.Kind == EntryKind.InUse ? e.Generation : 0;

    /// <summary>The file's byte at <paramref name="position"/>; -1 outside it.</summary>
    internal int ByteAt(long position) => _bytes[position];

    /// <summary>A stream's data, its filters undone.</summary>
    internal byte[] DecodedData(PdfStream stream) =>
        PdfFilters.Decode(RawData(stream), Resolve(stream.Dictionary["Filter"]), Resolve(stream.Dictionary["DecodeParms"]));

    // MARK: - Header and startxref

    private string ReadHeader()
    {
        // The header must be the file's first bytes: an update's offsets count from byte 0, and a
        // file with something before its header counts them from elsewhere.
        byte[] head = _bytes.Read(0, 16);
        string text = Encoding.Latin1.GetString(head);
        if (!text.StartsWith("%PDF-", StringComparison.Ordinal))
        {
            byte[] more = _bytes.Read(0, 1024);
            if (Encoding.Latin1.GetString(more).Contains("%PDF-", StringComparison.Ordinal))
            {
                throw new PdfReadException(PdfReadProblem.Unsupported, "The file has bytes before its %PDF header.");
            }
            throw new PdfReadException(PdfReadProblem.NotPdf, "The file does not start with %PDF.");
        }
        var match = Regex.Match(text, @"^%PDF-(\d\.\d)");
        return match.Success ? match.Groups[1].Value : "";
    }

    private long FindStartXref()
    {
        // The last "startxref" in the file's last few KB.
        int tailLength = (int)Math.Min(_bytes.Length, 4096);
        long tailStart = _bytes.Length - tailLength;
        string tail = Encoding.Latin1.GetString(_bytes.Read(tailStart, tailLength));
        int at = tail.LastIndexOf("startxref", StringComparison.Ordinal);
        if (at < 0) throw PdfReadException.Damaged("No startxref at the end of the file (it may be cut short).");
        if (tail.IndexOf("%%EOF", at, StringComparison.Ordinal) < 0) throw PdfReadException.Damaged("No %%EOF after startxref (the file may be cut short).");
        var lexer = new PdfLexer(_bytes, tailStart + at + "startxref".Length);
        long? offset = lexer.TryReadUnsigned();
        if (offset is null || offset <= 0 || offset >= _bytes.Length) throw PdfReadException.Damaged("startxref does not point into the file.");
        return offset.Value;
    }

    // MARK: - Cross-reference sections

    private void LoadCrossReferences()
    {
        var visited = new HashSet<long>();
        long? offset = StartXref;
        bool newest = true;
        int highest = 0;
        var trailer = new PdfDictionary();
        while (offset is { } at)
        {
            if (!visited.Add(at)) throw PdfReadException.Damaged("The cross-reference sections point back at each other (/Prev).");
            if (visited.Count > MaxSections) throw PdfReadException.Damaged("Too many cross-reference sections.");
            var (dictionary, isStream, sectionHighest) = ReadSection(at);
            highest = Math.Max(highest, sectionHighest);
            if (newest)
            {
                XrefIsStream = isStream;
                trailer = dictionary.Copy();
                newest = false;
            }
            else
            {
                // Entries a newer trailer lacks come from the older one.
                foreach (string key in new[] { "Root", "Info", "ID", "Encrypt" })
                {
                    if (!trailer.ContainsKey(key) && dictionary[key] is { } value) trailer[key] = value;
                }
            }
            if (dictionary["Size"] is PdfNumber { Integer: { } size })
            {
                if (size - 1 > MaxObjectNumber) throw PdfReadException.Damaged($"/Size {size} is past PDF's highest object number ({MaxObjectNumber}).");
                highest = (int)Math.Max(highest, size - 1);
            }
            SectionCount++;
            offset = dictionary["Prev"] switch
            {
                null => null,
                PdfNumber { Integer: { } prev } when prev > 0 && prev < _bytes.Length => prev,
                _ => throw PdfReadException.Damaged("/Prev does not point into the file."),
            };
            if (SectionCount == 1) LatestPrev = offset;
        }
        Trailer = trailer;
        NextObjectNumber = highest + 1;
    }

    /// <summary>One section at <paramref name="offset"/>: its entries (newer ones already read win), its trailer dictionary.</summary>
    private (PdfDictionary Trailer, bool IsStream, int Highest) ReadSection(long offset)
    {
        var lexer = new PdfLexer(_bytes, offset);
        lexer.SkipWhiteSpace();
        long start = lexer.Position;
        if (lexer.ReadKeyword() == "xref")
        {
            var section = new Dictionary<int, Entry>();
            int highest = ReadTable(lexer, section);
            lexer.SkipWhiteSpace();
            if (lexer.ReadKeyword() != "trailer") throw PdfReadException.Damaged("A cross-reference table has no trailer.");
            if (lexer.ReadObject(allowStream: false) is not PdfDictionary trailer) throw PdfReadException.Damaged("The trailer is not a dictionary.");
            // A hybrid file: the classic table's objects, then the ones only its stream lists
            // (the table gives those as free, or not at all).
            if (trailer["XRefStm"] is { } streamOffset)
            {
                if (streamOffset is not PdfNumber { Integer: { } so } || so <= 0 || so >= _bytes.Length) throw PdfReadException.Damaged("/XRefStm does not point into the file.");
                IsHybrid = true;
                var streamSection = new Dictionary<int, Entry>();
                var (_, streamHighest) = ReadStreamSection(so, streamSection);
                highest = Math.Max(highest, streamHighest);
                foreach (var (number, entry) in streamSection)
                {
                    if (!section.TryGetValue(number, out var listed) || listed.Kind == EntryKind.Free) section[number] = entry;
                }
            }
            Merge(section);
            return (trailer, false, highest);
        }
        lexer.Position = start;
        var entries = new Dictionary<int, Entry>();
        var (dictionary, h) = ReadStreamSection(start, entries);
        Merge(entries);
        return (dictionary, true, h);
    }

    /// <summary>Entries of an older section count only where no newer one has spoken.</summary>
    private void Merge(Dictionary<int, Entry> section)
    {
        foreach (var (number, entry) in section) _entries.TryAdd(number, entry);
    }

    /// <summary>A classic table's subsections ("first count", then count lines of "offset generation n|f").</summary>
    private int ReadTable(PdfLexer lexer, Dictionary<int, Entry> section)
    {
        int highest = 0;
        while (true)
        {
            long save = lexer.Position;
            long? first = lexer.TryReadUnsigned();
            if (first is null)
            {
                lexer.Position = save;
                return highest;
            }
            long? count = lexer.TryReadUnsigned();
            if (count is null) throw PdfReadException.Damaged("A cross-reference subsection header is not two numbers.");
            if (first + count > MaxObjectNumber + 1L) throw PdfReadException.Damaged($"A cross-reference subsection goes past PDF's highest object number ({MaxObjectNumber}).");
            for (long i = 0; i < count; i++)
            {
                long? entryOffset = lexer.TryReadUnsigned();
                long? generation = entryOffset is null ? null : lexer.TryReadUnsigned();
                string kind = generation is null ? "" : lexer.ReadKeyword();
                if (entryOffset is null || generation is null || kind is not ("n" or "f") || generation > 65535)
                {
                    throw PdfReadException.Damaged($"Cross-reference entry {first + i} is not \"offset generation n|f\".");
                }
                int number = (int)(first.Value + i);
                // Object 0 is the head of the free list, whatever a table says.
                if (number == 0) continue;
                var entry = kind == "n"
                    ? new Entry(EntryKind.InUse, entryOffset.Value, (int)generation.Value, 0, 0)
                    : new Entry(EntryKind.Free, 0, (int)generation.Value, 0, 0);
                if (kind == "n" && (entryOffset <= 0 || entryOffset >= _bytes.Length)) throw PdfReadException.Damaged($"Object {number} is listed outside the file.");
                section.TryAdd(number, entry);
                if (kind == "n") highest = Math.Max(highest, number);
            }
        }
    }

    /// <summary>A cross-reference stream (/Type /XRef) at <paramref name="offset"/>: its entries and its dictionary.</summary>
    private (PdfDictionary Dictionary, int Highest) ReadStreamSection(long offset, Dictionary<int, Entry> section)
    {
        var lexer = new PdfLexer(_bytes, offset);
        lexer.ReadObjectHeader();
        if (lexer.ReadObject() is not PdfStream stream || stream.Dictionary["Type"] is not PdfName { Value: "XRef" })
        {
            throw PdfReadException.Damaged("startxref points at neither a cross-reference table nor a cross-reference stream.");
        }
        var dictionary = stream.Dictionary;
        // A cross-reference stream's own entries are direct: nothing can be looked up yet.
        if (dictionary["W"] is not PdfArray { Items.Count: 3 } w || w.Items.Any(i => i is not PdfNumber { Integer: >= 0 and <= 8 }))
        {
            throw PdfReadException.Damaged("A cross-reference stream's /W is not three field widths.");
        }
        int[] widths = [.. w.Items.Select(i => (int)((PdfNumber)i).Integer!.Value)];
        if (dictionary["Size"] is not PdfNumber { Integer: { } size } || size < 0) throw PdfReadException.Damaged("A cross-reference stream has no /Size.");
        if (size - 1 > MaxObjectNumber) throw PdfReadException.Damaged($"/Size {size} is past PDF's highest object number ({MaxObjectNumber}).");
        var index = dictionary["Index"] is PdfArray indexArray
            ? indexArray.Items.Select(i => i is PdfNumber { Integer: { } n } && n >= 0 ? n : throw PdfReadException.Damaged("A cross-reference stream's /Index is not numbers.")).ToList()
            : new List<long> { 0, size };
        if (index.Count % 2 != 0) throw PdfReadException.Damaged("A cross-reference stream's /Index has an odd count.");
        if (dictionary["Length"] is not PdfNumber { Integer: { } length } || length < 0) throw PdfReadException.Damaged("A cross-reference stream's /Length is not a number.");
        byte[] raw = StreamData(stream.DataOffset, length);
        byte[] data = PdfFilters.Decode(raw, dictionary["Filter"], dictionary["DecodeParms"]);
        int entryLength = widths.Sum();
        if (entryLength == 0) throw PdfReadException.Damaged("A cross-reference stream's entries are empty.");
        int highest = 0;
        int at = 0;
        for (int k = 0; k < index.Count; k += 2)
        {
            long first = index[k], count = index[k + 1];
            if (first + count > MaxObjectNumber + 1L) throw PdfReadException.Damaged($"A cross-reference stream's /Index goes past PDF's highest object number ({MaxObjectNumber}).");
            for (long i = 0; i < count; i++)
            {
                if (at + entryLength > data.Length) throw PdfReadException.Damaged("A cross-reference stream is shorter than its /Index says.");
                // A missing first field means type 1.
                long type = widths[0] == 0 ? 1 : Field(data, at, widths[0]);
                long second = Field(data, at + widths[0], widths[1]);
                long third = Field(data, at + widths[0] + widths[1], widths[2]);
                at += entryLength;
                int number = (int)(first + i);
                if (number == 0) continue;
                Entry entry;
                switch (type)
                {
                    case 0:
                        entry = new Entry(EntryKind.Free, 0, (int)Math.Min(third, 65535), 0, 0);
                        break;
                    case 1:
                        if (second <= 0 || second >= _bytes.Length) throw PdfReadException.Damaged($"Object {number} is listed outside the file.");
                        entry = new Entry(EntryKind.InUse, second, (int)Math.Min(third, 65535), 0, 0);
                        highest = Math.Max(highest, number);
                        break;
                    case 2:
                        if (second <= 0 || second > int.MaxValue) throw PdfReadException.Damaged($"Object {number} is listed in an object stream that cannot exist.");
                        entry = new Entry(EntryKind.Compressed, 0, 0, (int)second, (int)Math.Min(third, int.MaxValue));
                        highest = Math.Max(highest, number);
                        break;
                    default:
                        // Types a later PDF version may add read as null (7.5.8.3).
                        continue;
                }
                section.TryAdd(number, entry);
            }
        }
        return (dictionary, highest);
    }

    private static long Field(byte[] data, int at, int width)
    {
        long value = 0;
        for (int i = 0; i < width; i++) value = (value << 8) | data[at + i];
        return value;
    }

    // MARK: - Objects

    private PdfObject ReadObjectAt(long offset, int number)
    {
        var lexer = new PdfLexer(_bytes, offset);
        var (found, _) = lexer.ReadObjectHeader();
        if (found != number) throw PdfReadException.Damaged($"Object {number} is listed at byte {offset}, where object {found} is.");
        return lexer.ReadObject();
    }

    private PdfObject ReadCompressed(int number, Entry entry)
    {
        if (!_objectStreams.TryGetValue(entry.StreamNumber, out var objectStream))
        {
            if (Get(entry.StreamNumber) is not PdfStream stream || stream.Dictionary["Type"] is not PdfName { Value: "ObjStm" })
            {
                throw PdfReadException.Damaged($"Object {number} is listed in object {entry.StreamNumber}, which is not an object stream.");
            }
            if (Resolve(stream.Dictionary["N"]) is not PdfNumber { Integer: { } n } || n < 0
                || Resolve(stream.Dictionary["First"]) is not PdfNumber { Integer: { } first } || first < 0)
            {
                throw PdfReadException.Damaged($"Object stream {entry.StreamNumber} has no /N or /First.");
            }
            byte[] data = DecodedData(stream);
            var header = new PdfLexer(new PdfArrayBytes(data));
            var offsets = new Dictionary<int, long>();
            var order = new List<int>();
            for (long i = 0; i < n; i++)
            {
                long? objectNumber = header.TryReadUnsigned();
                long? relative = objectNumber is null ? null : header.TryReadUnsigned();
                if (objectNumber is null || relative is null || objectNumber > int.MaxValue || first + relative >= data.Length)
                {
                    throw PdfReadException.Damaged($"Object stream {entry.StreamNumber}'s header is not {n} pairs of numbers.");
                }
                offsets.TryAdd((int)objectNumber.Value, first + relative.Value);
                order.Add((int)objectNumber.Value);
            }
            objectStream = (data, offsets, order);
            _objectStreams[entry.StreamNumber] = objectStream;
        }
        // The index says where; the header's number must agree (or the object is found by number).
        long at = entry.Index < objectStream.Order.Count && objectStream.Order[entry.Index] == number
            ? objectStream.Offsets[number]
            : objectStream.Offsets.TryGetValue(number, out long found) ? found
            : throw PdfReadException.Damaged($"Object {number} is not in object stream {entry.StreamNumber}.");
        var lexer = new PdfLexer(new PdfArrayBytes(objectStream.Data), at);
        return lexer.ReadObject(allowStream: false);
    }

    /// <summary>A stream's bytes as stored: /Length of them, which must be followed by "endstream".</summary>
    private byte[] RawData(PdfStream stream)
    {
        if (Resolve(stream.Dictionary["Length"]) is not PdfNumber { Integer: { } length } || length < 0)
        {
            throw PdfReadException.Damaged("A stream's /Length is not a number.");
        }
        return StreamData(stream.DataOffset, length);
    }

    private byte[] StreamData(long start, long length)
    {
        if (start + length > _bytes.Length || length > int.MaxValue) throw PdfReadException.Damaged("A stream runs past the end of the file.");
        var lexer = new PdfLexer(_bytes, start + length);
        lexer.SkipWhiteSpace();
        if (lexer.ReadKeyword() != "endstream") throw PdfReadException.Damaged($"A stream's /Length ({length}) does not end at \"endstream\".");
        return _bytes.Read(start, (int)length);
    }

    // MARK: - Page tree

    private List<PdfReference> WalkPageTree(PdfReference root)
    {
        var pages = new List<PdfReference>();
        var visited = new HashSet<int>();
        Walk(root, 0);
        return pages;

        void Walk(PdfReference node, int depth)
        {
            if (depth > MaxTreeDepth) throw PdfReadException.Damaged("The page tree is too deep.");
            if (!visited.Add(node.Number)) throw PdfReadException.Damaged("The page tree has a loop.");
            if (Resolve(node) is not PdfDictionary dictionary) throw PdfReadException.Damaged($"Page tree node {node.Number} is not a dictionary.");
            string? type = (Resolve(dictionary["Type"]) as PdfName)?.Value;
            var kids = Resolve(dictionary["Kids"]);
            // A node with kids is an intermediate node, whatever its /Type says (some writers omit it).
            if (type == "Pages" || (type is null && kids is PdfArray))
            {
                if (kids is not PdfArray array) throw PdfReadException.Damaged($"Page tree node {node.Number} has no /Kids.");
                foreach (var kid in array.Items)
                {
                    if (kid is not PdfReference reference) throw PdfReadException.Damaged($"Page tree node {node.Number} has a kid that is not a reference.");
                    Walk(reference, depth + 1);
                }
                return;
            }
            if (type is "Page" or null)
            {
                pages.Add(node);
                return;
            }
            throw PdfReadException.Damaged($"Page tree node {node.Number} is a /{type}.");
        }
    }

    // MARK: - PDF/A identification

    private (int? Part, string? Conformance)? _pdfA;

    private (int? Part, string? Conformance) PdfAIdentification()
    {
        if (_pdfA is { } known) return known;
        (int?, string?) result = (null, null);
        try
        {
            if (Catalog is not null && Resolve(Catalog["Metadata"]) is PdfStream metadata)
            {
                result = ReadPdfAId(DecodedData(metadata));
            }
        }
        catch (PdfReadException)
        {
            // Metadata that cannot be read claims nothing.
        }
        _pdfA = result;
        return result;
    }

    private const string PdfAIdNamespace = "http://www.aiim.org/pdfa/ns/id/";

    /// <summary>pdfaid:part and pdfaid:conformance from XMP, as attributes or elements.</summary>
    internal static (int? Part, string? Conformance) ReadPdfAId(byte[] xmp)
    {
        string text = Encoding.UTF8.GetString(xmp);
        string? part = null, conformance = null;
        try
        {
            int start = text.IndexOf("<x:xmpmeta", StringComparison.Ordinal);
            if (start < 0) start = text.IndexOf("<rdf:RDF", StringComparison.Ordinal);
            int end = text.LastIndexOf("</x:xmpmeta>", StringComparison.Ordinal);
            string xml = start >= 0 && end > start ? text[start..(end + "</x:xmpmeta>".Length)] : start >= 0 ? text[start..] : text;
            var document = XDocument.Parse(xml);
            XNamespace ns = PdfAIdNamespace;
            foreach (var element in document.Descendants())
            {
                part ??= element.Attribute(ns + "part")?.Value;
                conformance ??= element.Attribute(ns + "conformance")?.Value;
                if (element.Name == ns + "part") part ??= element.Value;
                if (element.Name == ns + "conformance") conformance ??= element.Value;
            }
        }
        catch (System.Xml.XmlException)
        {
            // Not well-formed: claims nothing.
        }
        int? number = int.TryParse(part?.Trim(), out int p) ? p : null;
        string? level = string.IsNullOrWhiteSpace(conformance) ? null : conformance.Trim().ToUpperInvariant();
        return (number, number is null ? null : level);
    }
}
