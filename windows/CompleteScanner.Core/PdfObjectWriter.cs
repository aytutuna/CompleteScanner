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

    public void WriteBytes(ReadOnlySpan<byte> bytes)
    {
        _output.Write(bytes);
        Position += bytes.Length;
    }

    /// <summary>Text that is ASCII by construction (PDF syntax); anything else would be a bug.</summary>
    public void WriteAscii(string text) => WriteBytes(Encoding.ASCII.GetBytes(text));
}
