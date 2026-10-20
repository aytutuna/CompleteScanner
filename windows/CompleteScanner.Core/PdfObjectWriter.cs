using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>
/// The byte-level layer of the PDF writer: the header, numbered objects with their byte offsets,
/// streams, and the classic cross-reference table and trailer. It knows nothing about pages or
/// fonts (<see cref="PdfBuilder"/> decides what the objects are and how they are numbered), and
/// it never holds more than one object in memory: everything goes straight to the stream.
/// Objects may be written in any order, but every number from 1 to the highest one used must be
/// written before <see cref="Finish"/>. With an <see cref="Encryption"/>, every stream's data and
/// every string made by <see cref="AsciiString"/> is encrypted as it is written; the dictionaries
/// themselves (and so the /Encrypt dictionary, written as a plain object) are not.
/// </summary>
public sealed class PdfObjectWriter
{
    private readonly Stream _output;
    private readonly List<long> _offsets = []; // _offsets[i] = byte offset of object i + 1; -1 = not written yet

    /// <param name="output">Where the file goes.</param>
    /// <param name="encryption">How strings and streams are encrypted (null: they are not).</param>
    public PdfObjectWriter(Stream output, PdfEncryption? encryption = null)
    {
        _output = output;
        Encryption = encryption;
    }

    /// <summary>
    /// A writer for an incremental update: <paramref name="position"/> bytes of the file are
    /// already there (the original, and the end of line after it), so object offsets count from
    /// there. Objects are numbered from the original's next free number on (and the ones it
    /// replaces keep theirs); <see cref="FinishUpdate"/> or <see cref="FinishUpdateStream"/> lists
    /// only the objects written here.
    /// </summary>
    public PdfObjectWriter(Stream output, long position)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(position);
        _output = output;
        Position = position;
    }

    private readonly Dictionary<int, int> _generations = []; // object number → generation, when not 0

    /// <summary>What encrypts the file's strings and streams; null for an open file.</summary>
    public PdfEncryption? Encryption { get; }

    /// <summary>Bytes written so far: the offset the next byte lands at.</summary>
    public long Position { get; private set; }

    /// <summary>
    /// "%PDF-{version}" and the comment line of four bytes above 127 that marks the file as
    /// binary (PDF/A asks for it; transfer programs leave such files alone).
    /// </summary>
    public void WriteHeader(string version)
    {
        WriteAscii($"%PDF-{version}\n");
        WriteBytes([(byte)'%', 0xE2, 0xE3, 0xCF, 0xD3, (byte)'\n']);
    }

    /// <summary>Record where object <paramref name="number"/> starts and write "n 0 obj".</summary>
    public void BeginObject(int number)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(number, 1);
        while (_offsets.Count < number) _offsets.Add(-1);
        if (_offsets[number - 1] >= 0) throw new InvalidOperationException($"Object {number} was already written.");
        _offsets[number - 1] = Position;
        WriteAscii($"{number} 0 obj\n");
    }

    /// <summary>
    /// "n g obj" for an object an update replaces, which keeps its generation
    /// <paramref name="generation"/> (an update never writes encrypted files: none are opened).
    /// </summary>
    public void BeginObject(int number, int generation)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(generation);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(generation, 65535);
        if (generation == 0)
        {
            BeginObject(number);
            return;
        }
        ArgumentOutOfRangeException.ThrowIfLessThan(number, 1);
        while (_offsets.Count < number) _offsets.Add(-1);
        if (_offsets[number - 1] >= 0) throw new InvalidOperationException($"Object {number} was already written.");
        _offsets[number - 1] = Position;
        _generations[number] = generation;
        WriteAscii($"{number} {generation} obj\n");
    }

    /// <summary>Close the object begun last.</summary>
    public void EndObject() => WriteAscii("endobj\n");

    /// <summary>A whole object whose value is <paramref name="value"/> (a dictionary, an array, ...).</summary>
    public void WriteObject(int number, string value)
    {
        BeginObject(number);
        WriteAscii(value);
        WriteAscii("\n");
        EndObject();
    }

    /// <summary>A whole object with generation <paramref name="generation"/> (see <see cref="BeginObject(int, int)"/>).</summary>
    public void WriteObject(int number, int generation, string value)
    {
        BeginObject(number, generation);
        WriteAscii(value);
        WriteAscii("\n");
        EndObject();
    }

    /// <summary>
    /// A stream object: "&lt;&lt;{entries} /Length n&gt;&gt;", the data between "stream" and
    /// "endstream", each keyword on a line of its own. <paramref name="entries"/> are the
    /// dictionary's other entries ("" for none); the length is always added last. The data is
    /// encrypted first when the file is (the length is then the encrypted data's).
    /// </summary>
    public void WriteStream(int number, string entries, ReadOnlySpan<byte> data)
    {
        if (Encryption is { } encryption) data = encryption.Encrypt(data);
        BeginObject(number);
        string separator = entries.Length > 0 ? " " : "";
        WriteAscii($"<<{entries}{separator}/Length {data.Length}>>\nstream\n");
        WriteBytes(data);
        WriteAscii("\nendstream\n");
        EndObject();
    }

    /// <summary>
    /// A string in an object's dictionary: "(text)" with \, ( and ) escaped in an open file, the
    /// encrypted bytes as a hex string in an encrypted one. <paramref name="text"/> is ASCII.
    /// </summary>
    public string AsciiString(string text)
    {
        if (!Ascii.IsValid(text)) throw new ArgumentException("PDF syntax strings are ASCII.", nameof(text));
        if (Encryption is { } encryption) return $"<{Convert.ToHexString(encryption.Encrypt(Encoding.ASCII.GetBytes(text)))}>";
        return "(" + text.Replace(@"\", @"\\").Replace("(", @"\(").Replace(")", @"\)") + ")";
    }

    /// <summary>
    /// The cross-reference table of every object written, then the trailer with
    /// <paramref name="trailerEntries"/> after /Size (e.g. "/Root 1 0 R"), "startxref" and
    /// "%%EOF". Throws when an object number below the highest one was never written.
    /// </summary>
    public void Finish(string trailerEntries)
    {
        int missing = _offsets.IndexOf(-1);
        if (missing >= 0) throw new InvalidOperationException($"Object {missing + 1} was never written.");
        long xrefStart = Position;
        var table = new StringBuilder();
        table.Append($"xref\n0 {_offsets.Count + 1}\n");
        table.Append("0000000000 65535 f \n");
        foreach (long offset in _offsets)
        {
            table.Append(offset.ToString("D10", CultureInfo.InvariantCulture)).Append(" 00000 n \n");
        }
        WriteAscii(table.ToString());
        WriteAscii($"trailer\n<</Size {_offsets.Count + 1} {trailerEntries}>>\nstartxref\n{xrefStart}\n%%EOF\n");
        _output.Flush();
    }

    /// <summary>
    /// An incremental update's classic cross-reference section: "xref", one subsection per run of
    /// consecutive objects written here (no entry 0: the original's free list stands), then the
    /// trailer with <paramref name="trailerEntries"/> (the caller's /Size, /Prev, /Root, ...),
    /// "startxref" and "%%EOF".
    /// </summary>
    public void FinishUpdate(string trailerEntries)
    {
        long xrefStart = Position;
        var table = new StringBuilder("xref\n");
        foreach (var (first, count) in WrittenRuns())
        {
            table.Append(CultureInfo.InvariantCulture, $"{first} {count}\n");
            for (int n = first; n < first + count; n++)
            {
                table.Append(_offsets[n - 1].ToString("D10", CultureInfo.InvariantCulture)).Append(' ')
                     .Append(GenerationOf(n).ToString("D5", CultureInfo.InvariantCulture)).Append(" n \n");
            }
        }
        WriteAscii(table.ToString());
        WriteAscii($"trailer\n<<{trailerEntries}>>\nstartxref\n{xrefStart}\n%%EOF\n");
        _output.Flush();
    }

    /// <summary>
    /// An incremental update's cross-reference stream, object <paramref name="number"/> (written
    /// last, listing itself too): uncompressed, /W [1 w 2] with w the bytes the largest offset
    /// needs (at least 4), /Index the runs of objects written here, then
    /// <paramref name="dictionaryEntries"/> (the caller's /Size, /Prev, /Root, ...), "startxref"
    /// and "%%EOF".
    /// </summary>
    public void FinishUpdateStream(int number, string dictionaryEntries)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(number, 1);
        while (_offsets.Count < number) _offsets.Add(-1);
        if (_offsets[number - 1] >= 0) throw new InvalidOperationException($"Object {number} was already written.");
        long xrefStart = Position;
        _offsets[number - 1] = xrefStart; // listed in its own data
        int offsetWidth = 4;
        while (offsetWidth < 8 && xrefStart >= 1L << (offsetWidth * 8)) offsetWidth++;
        var runs = WrittenRuns();
        var data = new MemoryStream();
        foreach (var (first, count) in runs)
        {
            for (int n = first; n < first + count; n++)
            {
                data.WriteByte(1);
                long offset = _offsets[n - 1];
                for (int b = offsetWidth - 1; b >= 0; b--) data.WriteByte((byte)(offset >> (b * 8)));
                int generation = GenerationOf(n);
                data.WriteByte((byte)(generation >> 8));
                data.WriteByte((byte)generation);
            }
        }
        string index = string.Join(' ', runs.Select(r => $"{r.First} {r.Count}"));
        byte[] bytes = data.ToArray();
        WriteAscii($"{number} 0 obj\n<</Type /XRef /W [1 {offsetWidth} 2] /Index [{index}] {dictionaryEntries} /Length {bytes.Length}>>\nstream\n");
        WriteBytes(bytes);
        WriteAscii("\nendstream\nendobj\n");
        WriteAscii($"startxref\n{xrefStart}\n%%EOF\n");
        _output.Flush();
    }

    /// <summary>The objects written, as runs of consecutive numbers (first, count).</summary>
    private List<(int First, int Count)> WrittenRuns()
    {
        var runs = new List<(int First, int Count)>();
        for (int i = 0; i < _offsets.Count; i++)
        {
            if (_offsets[i] < 0) continue;
            int first = i + 1;
            int count = 0;
            while (i < _offsets.Count && _offsets[i] >= 0)
            {
                count++;
                i++;
            }
            runs.Add((first, count));
        }
        return runs;
    }

    private int GenerationOf(int number) => _generations.TryGetValue(number, out int g) ? g : 0;

    public void WriteBytes(ReadOnlySpan<byte> bytes)
    {
        _output.Write(bytes);
        Position += bytes.Length;
    }

    /// <summary>Text that is ASCII by construction (PDF syntax); anything else would be a bug.</summary>
    public void WriteAscii(string text) => WriteBytes(Encoding.ASCII.GetBytes(text));
}
