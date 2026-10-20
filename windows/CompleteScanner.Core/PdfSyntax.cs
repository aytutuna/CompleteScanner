using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace CompleteScanner.Core;

// The object syntax of an existing PDF, as PdfReaderLite reads it and PdfAppender writes back the
// few objects it changes: the values (ISO 32000-1 7.3), a lexer over the file's bytes, the
// FlateDecode filter with its PNG and TIFF predictors (7.4.4), and the way each value is written
// again. Strings and names keep their bytes, numbers their text, so a dictionary written back says
// exactly what it said.

/// <summary>A PDF value: null, boolean, number, name, string, array, dictionary, reference or stream.</summary>
internal abstract class PdfObject
{
    /// <summary>The value in PDF syntax, as <see cref="PdfAppender"/> writes it into an update.</summary>
    public abstract void WriteTo(StringBuilder output);

    public override string ToString()
    {
        var sb = new StringBuilder();
        WriteTo(sb);
        return sb.ToString();
    }
}

internal sealed class PdfNull : PdfObject
{
    public static readonly PdfNull Instance = new();
    private PdfNull() { }
    public override void WriteTo(StringBuilder output) => output.Append("null");
}

internal sealed class PdfBoolean(bool value) : PdfObject
{
    public bool Value { get; } = value;
    public override void WriteTo(StringBuilder output) => output.Append(Value ? "true" : "false");
}

/// <summary>An integer or a real, kept as it was written ("-.5", "4.", "0012").</summary>
internal sealed class PdfNumber : PdfObject
{
    public PdfNumber(string text)
    {
        Text = text;
        Value = double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : 0;
        IsInteger = text.IndexOf('.') < 0;
    }

    public PdfNumber(long value) : this(value.ToString(CultureInfo.InvariantCulture)) { }

    public string Text { get; }
    public double Value { get; }
    public bool IsInteger { get; }

    /// <summary>The integer value; null for a real or one out of range.</summary>
    public long? Integer => IsInteger && long.TryParse(Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long v) ? v : null;

    public override void WriteTo(StringBuilder output) => output.Append(Text);
}

/// <summary>A name: its bytes once #xx escapes are undone, one char per byte (Latin-1).</summary>
internal sealed class PdfName(string value) : PdfObject
{
    public string Value { get; } = value;

    public override void WriteTo(StringBuilder output)
    {
        output.Append('/');
        foreach (char c in Value)
        {
            // Regular characters as they are; '#', delimiters, white space and anything outside
            // printable ASCII as #xx.
            if (c > 0x20 && c < 0x7F && c != '#' && !PdfLexer.IsDelimiter((byte)c)) output.Append(c);
            else output.Append('#').Append(((int)c & 0xFF).ToString("X2", CultureInfo.InvariantCulture));
        }
    }

    public override bool Equals(object? obj) => obj is PdfName other && other.Value == Value;
    public override int GetHashCode() => Value.GetHashCode(StringComparison.Ordinal);
}

/// <summary>A string's bytes, and whether it was written in hex.</summary>
internal sealed class PdfString(byte[] bytes, bool isHex) : PdfObject
{
    public byte[] Bytes { get; } = bytes;
    public bool IsHex { get; } = isHex;

    public override void WriteTo(StringBuilder output)
    {
        if (IsHex)
        {
            output.Append('<').Append(Convert.ToHexString(Bytes)).Append('>');
            return;
        }
        output.Append('(');
        foreach (byte b in Bytes)
        {
            switch (b)
            {
                case (byte)'\\': output.Append(@"\\"); break;
                case (byte)'(': output.Append(@"\("); break;
                case (byte)')': output.Append(@"\)"); break;
                // A bare CR in a literal string reads back as LF: escape it to keep the byte.
                case (byte)'\r': output.Append(@"\r"); break;
                case (byte)'\n': output.Append(@"\n"); break;
                default:
                    if (b < 0x20 || b >= 0x7F) output.Append('\\').Append(Convert.ToString(b, 8).PadLeft(3, '0'));
                    else output.Append((char)b);
                    break;
            }
        }
        output.Append(')');
    }
}

internal sealed class PdfArray(List<PdfObject> items) : PdfObject
{
    public List<PdfObject> Items { get; } = items;

    public override void WriteTo(StringBuilder output)
    {
        output.Append('[');
        for (int i = 0; i < Items.Count; i++)
        {
            if (i > 0) output.Append(' ');
            Items[i].WriteTo(output);
        }
        output.Append(']');
    }
}

/// <summary>A dictionary, its entries in the order they were written (a repeated key: the last one counts).</summary>
internal sealed class PdfDictionary : PdfObject
{
    private readonly List<KeyValuePair<string, PdfObject>> _entries = [];

    public IReadOnlyList<KeyValuePair<string, PdfObject>> Entries => _entries;

    public PdfObject? this[string key]
    {
        get
        {
            for (int i = _entries.Count - 1; i >= 0; i--)
            {
                if (_entries[i].Key == key) return _entries[i].Value;
            }
            return null;
        }
        set
        {
            int index = _entries.FindLastIndex(e => e.Key == key);
            if (value is null)
            {
                _entries.RemoveAll(e => e.Key == key);
            }
            else if (index >= 0)
            {
                _entries[index] = new(key, value);
            }
            else
            {
                _entries.Add(new(key, value));
            }
        }
    }

    public bool ContainsKey(string key) => _entries.Exists(e => e.Key == key);

    public void Add(string key, PdfObject value) => _entries.Add(new(key, value));

    /// <summary>A copy whose entries can be changed without changing this one (the values are shared).</summary>
    public PdfDictionary Copy()
    {
        var copy = new PdfDictionary();
        foreach (var entry in _entries) copy._entries.Add(entry);
        return copy;
    }

    public override void WriteTo(StringBuilder output)
    {
        output.Append("<<");
        // The last of repeated keys only, where it was written.
        for (int i = 0; i < _entries.Count; i++)
        {
            var (key, value) = _entries[i];
            if (_entries.FindLastIndex(e => e.Key == key) != i) continue;
            new PdfName(key).WriteTo(output);
            output.Append(' ');
            value.WriteTo(output);
            output.Append(i < _entries.Count - 1 ? " " : "");
        }
        output.Append(">>");
    }
}

/// <summary>An indirect reference, "12 0 R".</summary>
internal sealed class PdfReference(int number, int generation) : PdfObject
{
    public int Number { get; } = number;
    public int Generation { get; } = generation;

    public override void WriteTo(StringBuilder output) =>
        output.Append(Number.ToString(CultureInfo.InvariantCulture)).Append(' ')
              .Append(Generation.ToString(CultureInfo.InvariantCulture)).Append(" R");

    public override bool Equals(object? obj) => obj is PdfReference other && other.Number == Number && other.Generation == Generation;
    public override int GetHashCode() => HashCode.Combine(Number, Generation);
}

/// <summary>
/// A stream: its dictionary and where its data starts in the bytes it was read from. Its length
/// may be an indirect object, so the reader works the data out (<see cref="PdfReaderLite"/>).
/// </summary>
internal sealed class PdfStream(PdfDictionary dictionary, long dataOffset) : PdfObject
{
    public PdfDictionary Dictionary { get; } = dictionary;
    public long DataOffset { get; } = dataOffset;

    /// <summary>Streams are never written back (an update only adds new ones).</summary>
    public override void WriteTo(StringBuilder output) =>
        throw new InvalidOperationException("A stream is written only as an indirect object.");
}

/// <summary>The bytes a lexer reads: a whole array, or a seekable file read in blocks as needed.</summary>
internal abstract class PdfBytes
{
    public abstract long Length { get; }

    /// <summary>The byte at <paramref name="position"/>; -1 past the end.</summary>
    public abstract int this[long position] { get; }

    /// <summary>Up to <paramref name="count"/> bytes from <paramref name="position"/> (fewer at the end).</summary>
    public abstract byte[] Read(long position, int count);
}

internal sealed class PdfArrayBytes(byte[] bytes) : PdfBytes
{
    private readonly byte[] _bytes = bytes;
    public override long Length => _bytes.Length;
    public override int this[long position] => position >= 0 && position < _bytes.Length ? _bytes[position] : -1;

    public override byte[] Read(long position, int count)
    {
        if (position < 0 || position >= _bytes.Length || count <= 0) return [];
        int n = (int)Math.Min(count, _bytes.Length - position);
        return _bytes.AsSpan((int)position, n).ToArray();
    }
}

/// <summary>A seekable stream read through a few cached 64 KB blocks, so a large file is never read whole.</summary>
internal sealed class PdfStreamBytes : PdfBytes
{
    private const int BlockSize = 1 << 16;
    private const int CachedBlocks = 16;
    private readonly Stream _stream;
    private readonly Dictionary<long, byte[]> _blocks = [];
    private readonly LinkedList<long> _recent = new();

    public PdfStreamBytes(Stream stream)
    {
        if (!stream.CanSeek || !stream.CanRead) throw new ArgumentException("The PDF must be read from a seekable stream.", nameof(stream));
        _stream = stream;
        Length = stream.Length;
    }

    public override long Length { get; }

    public override int this[long position]
    {
        get
        {
            if (position < 0 || position >= Length) return -1;
            var block = Block(position / BlockSize);
            int index = (int)(position % BlockSize);
            return index < block.Length ? block[index] : -1;
        }
    }

    public override byte[] Read(long position, int count)
    {
        if (position < 0 || position >= Length || count <= 0) return [];
        int n = (int)Math.Min(count, Length - position);
        var result = new byte[n];
        int done = 0;
        while (done < n)
        {
            long at = position + done;
            var block = Block(at / BlockSize);
            int index = (int)(at % BlockSize);
            if (index >= block.Length) break;
            int take = Math.Min(n - done, block.Length - index);
            Buffer.BlockCopy(block, index, result, done, take);
            done += take;
        }
        return done == n ? result : result[..done];
    }

    private byte[] Block(long number)
    {
        if (_blocks.TryGetValue(number, out var cached))
        {
            _recent.Remove(number);
            _recent.AddFirst(number);
            return cached;
        }
        long start = number * BlockSize;
        int size = (int)Math.Min(BlockSize, Length - start);
        var block = new byte[Math.Max(size, 0)];
        _stream.Position = start;
        _stream.ReadExactly(block);
        _blocks[number] = block;
        _recent.AddFirst(number);
        if (_recent.Count > CachedBlocks)
        {
            _blocks.Remove(_recent.Last!.Value);
            _recent.RemoveLast();
        }
        return block;
    }
}

/// <summary>A file the reader cannot use: what is wrong, for the message the user sees.</summary>
public enum PdfReadProblem
{
    /// <summary>Not a PDF at all (no "%PDF-" header).</summary>
    NotPdf,
    /// <summary>The cross-reference data or an object is not where or what it should be.</summary>
    Damaged,
    /// <summary>The file is encrypted (it has an /Encrypt dictionary).</summary>
    Encrypted,
    /// <summary>The file uses something this reader does not handle (a filter other than Flate, say).</summary>
    Unsupported,
}

/// <summary>Thrown by <see cref="PdfReaderLite"/>; the message is technical, <see cref="Problem"/> says what kind.</summary>
public sealed class PdfReadException(PdfReadProblem problem, string detail) : Exception(detail)
{
    public PdfReadProblem Problem { get; } = problem;

    internal static PdfReadException Damaged(string detail) => new(PdfReadProblem.Damaged, detail);
}

/// <summary>
/// Tokens and objects from PDF bytes (ISO 32000-1 7.2, 7.3): white space and comments skipped,
/// names with #xx escapes, literal strings with their escapes and nested parentheses, hex
/// strings, numbers, "n g R" references, arrays, dictionaries and the start of a stream's data.
/// </summary>
internal sealed class PdfLexer(PdfBytes bytes, long position = 0)
{
    /// <summary>Deeper nesting than this is refused rather than risking the stack.</summary>
    private const int MaxDepth = 200;

    public PdfBytes Bytes { get; } = bytes;
    public long Position { get; set; } = position;

    public static bool IsWhiteSpace(int b) => b is 0 or 9 or 10 or 12 or 13 or 32;

    public static bool IsDelimiter(int b) => b is '(' or ')' or '<' or '>' or '[' or ']' or '{' or '}' or '/' or '%';

    private static bool IsRegular(int b) => b >= 0 && !IsWhiteSpace(b) && !IsDelimiter(b);

    private int Peek(long offset = 0) => Bytes[Position + offset];

    /// <summary>Skips white space and comments.</summary>
    public void SkipWhiteSpace()
    {
        while (true)
        {
            int b = Peek();
            if (IsWhiteSpace(b))
            {
                Position++;
            }
            else if (b == '%')
            {
                while (Peek() is not (-1 or 10 or 13)) Position++;
            }
            else
            {
                return;
            }
        }
    }

    /// <summary>The next run of regular characters ("obj", "123", "true"); empty at a delimiter or the end.</summary>
    public string ReadKeyword()
    {
        SkipWhiteSpace();
        var sb = new StringBuilder();
        while (IsRegular(Peek()))
        {
            sb.Append((char)Peek());
            Position++;
        }
        return sb.ToString();
    }

    /// <summary>A non-negative integer token, or null (the position is then where it was).</summary>
    public long? TryReadUnsigned()
    {
        long start = Position;
        SkipWhiteSpace();
        long value = 0;
        int digits = 0;
        while (Peek() is >= '0' and <= '9')
        {
            if (value > (long.MaxValue - 9) / 10) { Position = start; return null; }
            value = value * 10 + (Peek() - '0');
            Position++;
            digits++;
        }
        if (digits == 0 || IsRegular(Peek()))
        {
            Position = start;
            return null;
        }
        return value;
    }

    /// <summary>"n g obj" at the current position; the object's number and generation.</summary>
    public (int Number, int Generation) ReadObjectHeader()
    {
        long? number = TryReadUnsigned();
        long? generation = number is null ? null : TryReadUnsigned();
        if (number is null || generation is null || number > int.MaxValue || generation > 65535 || ReadKeyword() != "obj")
        {
            throw PdfReadException.Damaged($"No object header at byte {Position}.");
        }
        return ((int)number.Value, (int)generation.Value);
    }

    /// <summary>
    /// One object; a dictionary followed by "stream" becomes a <see cref="PdfStream"/> whose data
    /// starts after the keyword's end of line.
    /// </summary>
    public PdfObject ReadObject(bool allowStream = true) => ReadObject(0, allowStream);

    private PdfObject ReadObject(int depth, bool allowStream)
    {
        if (depth > MaxDepth) throw new PdfReadException(PdfReadProblem.Unsupported, "Objects are nested too deeply.");
        SkipWhiteSpace();
        int b = Peek();
        switch (b)
        {
            case -1:
                throw PdfReadException.Damaged("The file ends inside an object.");
            case '/':
                Position++;
                return new PdfName(ReadNameBody());
            case '(':
                Position++;
                return new PdfString(ReadLiteralBody(), isHex: false);
            case '[':
            {
                Position++;
                var items = new List<PdfObject>();
                while (true)
                {
                    SkipWhiteSpace();
                    if (Peek() == ']') { Position++; break; }
                    if (Peek() == -1) throw PdfReadException.Damaged("An array is not closed.");
                    items.Add(ReadObject(depth + 1, allowStream: false));
                }
                return new PdfArray(items);
            }
            case '<' when Peek(1) == '<':
            {
                Position += 2;
                var dictionary = new PdfDictionary();
                while (true)
                {
                    SkipWhiteSpace();
                    if (Peek() == '>' && Peek(1) == '>') { Position += 2; break; }
                    if (Peek() != '/') throw PdfReadException.Damaged($"A dictionary key is not a name at byte {Position}.");
                    Position++;
                    string key = ReadNameBody();
                    SkipWhiteSpace();
                    // A key without a value before the end (seen in the wild) reads as null.
                    PdfObject value = Peek() == '>' && Peek(1) == '>' ? PdfNull.Instance : ReadObject(depth + 1, allowStream: false);
                    dictionary.Add(key, value);
                }
                if (allowStream && AtStreamKeyword(out long dataStart)) return new PdfStream(dictionary, dataStart);
                return dictionary;
            }
            case '<':
                Position++;
                return new PdfString(ReadHexBody(), isHex: true);
        }
        if (b is (>= '0' and <= '9') or '+' or '-' or '.')
        {
            string number = ReadKeyword();
            if (!IsNumber(number)) throw PdfReadException.Damaged($"\"{number}\" is not a number.");
            // "n g R": an integer, another, then R.
            if (number.All(char.IsAsciiDigit))
            {
                long save = Position;
                long? generation = TryReadUnsigned();
                if (generation is not null && ReadKeyword() == "R" && int.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out int n) && generation <= 65535)
                {
                    return new PdfReference(n, (int)generation.Value);
                }
                Position = save;
            }
            return new PdfNumber(number);
        }
        string keyword = ReadKeyword();
        return keyword switch
        {
            "true" => new PdfBoolean(true),
            "false" => new PdfBoolean(false),
            "null" => PdfNull.Instance,
            "" => throw PdfReadException.Damaged($"Unexpected '{(char)b}' at byte {Position}."),
            _ => throw PdfReadException.Damaged($"Unexpected \"{keyword}\" at byte {Position}."),
        };
    }

    private static bool IsNumber(string text)
    {
        if (text.Length == 0) return false;
        int i = text[0] is '+' or '-' ? 1 : 0;
        bool digits = false, dot = false;
        for (; i < text.Length; i++)
        {
            if (char.IsAsciiDigit(text[i])) digits = true;
            else if (text[i] == '.' && !dot) dot = true;
            else return false;
        }
        return digits;
    }

    /// <summary>After a dictionary: "stream" and its end of line (CRLF or LF; a lone CR is tolerated).</summary>
    private bool AtStreamKeyword(out long dataStart)
    {
        dataStart = 0;
        long save = Position;
        SkipWhiteSpace();
        if (ReadKeyword() != "stream")
        {
            Position = save;
            return false;
        }
        if (Peek() == 13 && Peek(1) == 10) Position += 2;
        else if (Peek() is 10 or 13) Position++;
        dataStart = Position;
        return true;
    }

    private string ReadNameBody()
    {
        var sb = new StringBuilder();
        while (IsRegular(Peek()))
        {
            int c = Peek();
            if (c == '#' && HexValue(Peek(1)) is int high && HexValue(Peek(2)) is int low)
            {
                sb.Append((char)(high * 16 + low));
                Position += 3;
                continue;
            }
            sb.Append((char)c);
            Position++;
        }
        return sb.ToString();
    }

    private byte[] ReadLiteralBody()
    {
        var bytes = new List<byte>();
        int depth = 1;
        while (true)
        {
            int c = Peek();
            if (c == -1) throw PdfReadException.Damaged("A string is not closed.");
            Position++;
            if (c == '\\')
            {
                int e = Peek();
                if (e == -1) throw PdfReadException.Damaged("A string is not closed.");
                Position++;
                switch (e)
                {
                    case 'n': bytes.Add(10); break;
                    case 'r': bytes.Add(13); break;
                    case 't': bytes.Add(9); break;
                    case 'b': bytes.Add(8); break;
                    case 'f': bytes.Add(12); break;
                    case 13:
                        if (Peek() == 10) Position++; // a line continued: nothing
                        break;
                    case 10:
                        break;
                    case >= '0' and <= '7':
                    {
                        int value = e - '0';
                        for (int k = 0; k < 2 && Peek() is >= '0' and <= '7'; k++)
                        {
                            value = value * 8 + (Peek() - '0');
                            Position++;
                        }
                        bytes.Add((byte)value);
                        break;
                    }
                    default:
                        bytes.Add((byte)e); // \( \) \\ and any other character stand for themselves
                        break;
                }
                continue;
            }
            if (c == '(') depth++;
            if (c == ')' && --depth == 0) break;
            // An end of line inside a string reads as LF (7.3.4.2).
            if (c == 13)
            {
                if (Peek() == 10) Position++;
                bytes.Add(10);
                continue;
            }
            bytes.Add((byte)c);
        }
        return [.. bytes];
    }

    private byte[] ReadHexBody()
    {
        var bytes = new List<byte>();
        int? high = null;
        while (true)
        {
            int c = Peek();
            if (c == -1) throw PdfReadException.Damaged("A hex string is not closed.");
            Position++;
            if (c == '>') break;
            if (IsWhiteSpace(c)) continue;
            if (HexValue(c) is not int digit) throw PdfReadException.Damaged($"'{(char)c}' in a hex string.");
            if (high is int h)
            {
                bytes.Add((byte)(h * 16 + digit));
                high = null;
            }
            else
            {
                high = digit;
            }
        }
        if (high is int last) bytes.Add((byte)(last * 16)); // an odd last digit is followed by 0
        return [.. bytes];
    }

    private static int? HexValue(int c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'A' and <= 'F' => c - 'A' + 10,
        >= 'a' and <= 'f' => c - 'a' + 10,
        _ => null,
    };
}

/// <summary>The filters the reader can undo for the streams it reads (cross-reference and object streams, metadata).</summary>
internal static class PdfFilters
{
    /// <summary>
    /// The data of a stream with its filters undone: none, or FlateDecode (with a /DecodeParms
    /// predictor). Anything else is <see cref="PdfReadProblem.Unsupported"/>.
    /// </summary>
    public static byte[] Decode(byte[] data, PdfObject? filter, PdfObject? parameters)
    {
        List<string> filters = filter switch
        {
            null or PdfNull => [],
            PdfName name => [name.Value],
            PdfArray array => array.Items.Select(i => (i as PdfName)?.Value ?? "").ToList(),
            _ => throw PdfReadException.Damaged("A stream's /Filter is not a name."),
        };
        List<PdfDictionary?> parameterList = parameters switch
        {
            PdfArray array => array.Items.Select(i => i as PdfDictionary).ToList(),
            PdfDictionary dictionary => [dictionary],
            _ => [],
        };
        for (int i = 0; i < filters.Count; i++)
        {
            var decodeParms = i < parameterList.Count ? parameterList[i] : null;
            data = filters[i] switch
            {
                "FlateDecode" or "Fl" => Predict(Inflate(data), decodeParms),
                _ => throw new PdfReadException(PdfReadProblem.Unsupported, $"The /{filters[i]} filter is not supported."),
            };
        }
        return data;
    }

    /// <summary>zlib data inflated; raw deflate data (no zlib header) is accepted too.</summary>
    public static byte[] Inflate(byte[] data)
    {
        try
        {
            using var input = new MemoryStream(data);
            using var z = new ZLibStream(input, CompressionMode.Decompress);
            using var output = new MemoryStream();
            z.CopyTo(output);
            return output.ToArray();
        }
        catch (InvalidDataException)
        {
            try
            {
                using var input = new MemoryStream(data);
                using var d = new DeflateStream(input, CompressionMode.Decompress);
                using var output = new MemoryStream();
                d.CopyTo(output);
                return output.ToArray();
            }
            catch (InvalidDataException e)
            {
                throw PdfReadException.Damaged($"A compressed stream does not inflate: {e.Message}");
            }
        }
    }

    /// <summary>Undoes a /Predictor: 2 (TIFF, 8 bits per component) or 10–15 (PNG, each row with its own filter byte).</summary>
    public static byte[] Predict(byte[] data, PdfDictionary? parameters)
    {
        int predictor = Int(parameters?["Predictor"], 1);
        if (predictor <= 1) return data;
        int colors = Math.Max(1, Int(parameters?["Colors"], 1));
        int bitsPerComponent = Math.Max(1, Int(parameters?["BitsPerComponent"], 8));
        int columns = Math.Max(1, Int(parameters?["Columns"], 1));
        int bytesPerPixel = Math.Max(1, colors * bitsPerComponent / 8);
        int rowLength = (colors * bitsPerComponent * columns + 7) / 8;
        if (predictor == 2)
        {
            if (bitsPerComponent != 8) throw new PdfReadException(PdfReadProblem.Unsupported, "TIFF predictor with other than 8 bits per component.");
            var output = (byte[])data.Clone();
            for (int row = 0; row + rowLength <= output.Length; row += rowLength)
            {
                for (int i = bytesPerPixel; i < rowLength; i++) output[row + i] = (byte)(output[row + i] + output[row + i - bytesPerPixel]);
            }
            return output;
        }
        if (predictor < 10) throw new PdfReadException(PdfReadProblem.Unsupported, $"Predictor {predictor} is not supported.");
        var result = new MemoryStream();
        var previous = new byte[rowLength];
        var current = new byte[rowLength];
        for (int at = 0; at < data.Length; at += rowLength + 1)
        {
            int type = data[at];
            int available = Math.Min(rowLength, data.Length - at - 1);
            Array.Clear(current);
            Array.Copy(data, at + 1, current, 0, Math.Max(available, 0));
            for (int i = 0; i < rowLength; i++)
            {
                int left = i >= bytesPerPixel ? current[i - bytesPerPixel] : 0;
                int up = previous[i];
                int upLeft = i >= bytesPerPixel ? previous[i - bytesPerPixel] : 0;
                current[i] = type switch
                {
                    0 => current[i],
                    1 => (byte)(current[i] + left),
                    2 => (byte)(current[i] + up),
                    3 => (byte)(current[i] + (left + up) / 2),
                    4 => (byte)(current[i] + Paeth(left, up, upLeft)),
                    _ => throw PdfReadException.Damaged($"PNG row filter {type} does not exist."),
                };
            }
            result.Write(current, 0, Math.Max(available, 0));
            (previous, current) = (current, previous);
        }
        return result.ToArray();
    }

    private static int Paeth(int a, int b, int c)
    {
        int p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    private static int Int(PdfObject? value, int fallback) =>
        value is PdfNumber { Integer: { } n } && n is >= int.MinValue and <= int.MaxValue ? (int)n : fallback;
}
