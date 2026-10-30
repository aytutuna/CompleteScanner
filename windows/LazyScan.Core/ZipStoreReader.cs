using System.Text;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Output/ZipStoreReader.swift: the same checks, in the same
// order, with the same error kinds and messages.

/// <summary>Why <see cref="ZipStoreReader"/> refused an archive.</summary>
public enum ZipReadErrorKind
{
    /// <summary>Not a zip, cut short, or its records disagree (gaps, overlaps, bad signatures, several disks).</summary>
    Corrupt,
    /// <summary>An entry is compressed (Deflate or any other method): only stored entries are read.</summary>
    UnsupportedMethod,
    /// <summary>An entry is encrypted (traditional, strong or AES encryption).</summary>
    Encrypted,
    /// <summary>The archive or an entry uses ZIP64, which <see cref="ZipStore"/> never writes.</summary>
    Zip64,
    /// <summary>An entry keeps its sizes in a data descriptor after its data.</summary>
    DataDescriptor,
    /// <summary>An entry's name could escape a folder or is not plain text (see <see cref="ZipStoreReader.IsSafeName"/>).</summary>
    UnsafeName,
    /// <summary>Two entries have the same name, ignoring case.</summary>
    DuplicateName,
    /// <summary>An entry is marked as a link, device or other special file.</summary>
    SpecialFile,
    /// <summary>More entries than <see cref="ZipReadLimits.MaxEntries"/>.</summary>
    TooManyEntries,
    /// <summary>An entry, all entries together, or the central directory are past their limit.</summary>
    TooLarge,
    /// <summary>An entry's sizes disagree with each other or with its local header (a zip bomb's trick).</summary>
    SizeMismatch,
    /// <summary>An entry's data does not match its CRC-32.</summary>
    CrcMismatch,
}

/// <summary>An archive <see cref="ZipStoreReader"/> refuses: what is wrong, and the entry it is about.</summary>
public sealed class ZipReadException : IOException
{
    public ZipReadException(ZipReadErrorKind kind, string message, string? entryName = null) : base(message)
    {
        Kind = kind;
        EntryName = entryName;
    }

    public ZipReadErrorKind Kind { get; }

    /// <summary>The entry the error is about, when it is about one.</summary>
    public string? EntryName { get; }
}

/// <summary>
/// The limits <see cref="ZipStoreReader"/> holds an archive to, checked from its directory before
/// any entry is read. <see cref="Standard"/> suits scanned documents.
/// </summary>
public sealed record ZipReadLimits
{
    /// <summary>4096 entries, 256 MB per entry, 512 MB in all, names of up to 255 bytes, a central directory of up to 64 MB.</summary>
    public static ZipReadLimits Standard { get; } = new();

    public int MaxEntries { get; init; } = 4096;
    public long MaxEntryBytes { get; init; } = 256L * 1024 * 1024;
    public long MaxTotalBytes { get; init; } = 512L * 1024 * 1024;
    public int MaxNameBytes { get; init; } = 255;

    /// <summary>The largest central directory read (<see cref="ZipStoreReader.MaxCentralDirectoryBytes"/> by default).</summary>
    public int MaxDirectoryBytes { get; init; } = ZipStoreReader.MaxCentralDirectoryBytes;
}

/// <summary>One file in an archive <see cref="ZipStoreReader"/> opened: its name, its size and where its data is.</summary>
/// <param name="DataOffset">Where its bytes start in the archive.</param>
public sealed record ZipStoreReaderEntry(string Name, long Size, uint Crc32, long DataOffset);

/// <summary>
/// Reads the zip archives <see cref="ZipStore"/> writes, and archives of stored (uncompressed)
/// entries from other tools, refusing anything it cannot read safely with a
/// <see cref="ZipReadException"/>. Opening checks the whole directory and every local header:
/// compressed, encrypted, ZIP64 and data-descriptor entries, unsafe or duplicate names, links and
/// special files, entries past the <see cref="ZipReadLimits"/>, sizes that disagree, and entries
/// that do not follow one another exactly from the start of the archive to its directory (no gaps,
/// no overlaps, nothing before or between them). Entries are then read one at a time from the
/// stream, their CRC-32 checked; the archive is never loaded whole. Folder entries ("pages/") are
/// checked and left out of <see cref="Entries"/>. Not thread-safe.
/// </summary>
public sealed class ZipStoreReader : IDisposable
{
    /// <summary>The largest central directory read by default (64 MB; see <see cref="ZipReadLimits.MaxDirectoryBytes"/>).</summary>
    public const int MaxCentralDirectoryBytes = 64 * 1024 * 1024;

    private readonly Stream _stream;
    private readonly bool _leaveOpen;
    private readonly Dictionary<string, ZipStoreReaderEntry> _byName;

    private ZipStoreReader(Stream stream, bool leaveOpen, IReadOnlyList<ZipStoreReaderEntry> entries)
    {
        _stream = stream;
        _leaveOpen = leaveOpen;
        Entries = entries;
        _byName = entries.ToDictionary(e => e.Name, StringComparer.Ordinal);
    }

    /// <summary>The archive's files in directory order, without folder entries.</summary>
    public IReadOnlyList<ZipStoreReaderEntry> Entries { get; }

    /// <summary>Opens the archive in <paramref name="stream"/>, which must be readable and seekable.</summary>
    public static ZipStoreReader Open(Stream stream, ZipReadLimits? limits = null, bool leaveOpen = false)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (!stream.CanRead || !stream.CanSeek) throw new ArgumentException("The stream must be readable and seekable.", nameof(stream));
        try
        {
            return new ZipStoreReader(stream, leaveOpen, ReadDirectory(stream, limits ?? ZipReadLimits.Standard));
        }
        catch
        {
            if (!leaveOpen) stream.Dispose();
            throw;
        }
    }

    /// <summary>Opens the archive held in <paramref name="data"/>.</summary>
    public static ZipStoreReader Open(byte[] data, ZipReadLimits? limits = null) =>
        Open(new MemoryStream(data, writable: false), limits);

    /// <summary>Opens the archive at <paramref name="path"/>, read from the file as entries are read.</summary>
    public static ZipStoreReader OpenFile(string path, ZipReadLimits? limits = null) =>
        Open(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920), limits);

    /// <summary>Every file of the archive in <paramref name="data"/> with its bytes, CRC-checked.</summary>
    public static IReadOnlyList<ZipStoreEntry> ReadAll(byte[] data, ZipReadLimits? limits = null)
    {
        using var reader = Open(data, limits);
        return [.. reader.Entries.Select(e => new ZipStoreEntry(e.Name, reader.Read(e)))];
    }

    /// <summary>The file named exactly <paramref name="name"/>, or null.</summary>
    public ZipStoreReaderEntry? Find(string name) => _byName.GetValueOrDefault(name);

    /// <summary>The bytes of <paramref name="entry"/>, after checking their CRC-32.</summary>
    public byte[] Read(ZipStoreReaderEntry entry)
    {
        if (entry.Size > Array.MaxLength) throw Error(ZipReadErrorKind.TooLarge, entry.Name);
        var data = new byte[entry.Size];
        using var output = new MemoryStream(data, writable: true);
        CopyTo(entry, output);
        return data;
    }

    /// <summary>
    /// Writes the bytes of <paramref name="entry"/> to <paramref name="destination"/> a piece at a
    /// time and checks their CRC-32 at the end; when that throws, what was written must be discarded.
    /// </summary>
    public void CopyTo(ZipStoreReaderEntry entry, Stream destination)
    {
        if (!_byName.TryGetValue(entry.Name, out var own) || own != entry)
        {
            throw new ArgumentException("The entry is not one of this archive's.", nameof(entry));
        }
        var buffer = new byte[(int)Math.Min(Math.Max(entry.Size, 1), 81920)];
        uint crc = 0xFFFFFFFF;
        long left = entry.Size;
        _stream.Position = entry.DataOffset;
        while (left > 0)
        {
            int count = (int)Math.Min(left, buffer.Length);
            ReadExactly(_stream, buffer.AsSpan(0, count));
            crc = Crc32Update(crc, buffer.AsSpan(0, count));
            destination.Write(buffer, 0, count);
            left -= count;
        }
        if ((crc ^ 0xFFFFFFFF) != entry.Crc32) throw Error(ZipReadErrorKind.CrcMismatch, entry.Name);
    }

    public void Dispose()
    {
        if (!_leaveOpen) _stream.Dispose();
    }

    /// <summary>
    /// Whether <paramref name="name"/> is safe as a path inside a folder: 1 to
    /// <paramref name="maxNameBytes"/> bytes of UTF-8, no control characters (NUL included), no
    /// backslash or colon (so no drive letters or Windows streams), not starting with "/", and
    /// made of "/"-separated parts that are neither empty, "." nor "..", and do not end with a dot
    /// or a space (which Windows drops). A folder's name ends with one "/".
    /// </summary>
    public static bool IsSafeName(string name, int maxNameBytes = 255)
    {
        if (!IsPairedSurrogates(name)) return false;
        int bytes = Encoding.UTF8.GetByteCount(name);
        if (bytes == 0 || bytes > maxNameBytes) return false;
        foreach (char c in name)
        {
            if (c < 0x20 || c == 0x7F || c == '\\' || c == ':') return false;
        }
        if (name[0] == '/') return false;
        string path = name.EndsWith('/') ? name[..^1] : name;
        foreach (string part in path.Split('/'))
        {
            if (part.Length == 0 || part == "." || part == "..") return false;
            if (part[^1] == '.' || part[^1] == ' ') return false;
        }
        return true;
    }

    /// <summary>The form two names are compared in for <see cref="ZipReadErrorKind.DuplicateName"/>.</summary>
    internal static string DuplicateKey(string name)
    {
        string path = name.EndsWith('/') ? name[..^1] : name;
        return path.Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    /// <summary>The most characters (Unicode scalars) of an entry name a message shows.</summary>
    public const int DisplayNameLimit = 80;

    private const char Ellipsis = (char)0x2026, Replacement = (char)0xFFFD;

    /// <summary>
    /// <paramref name="name"/> made safe to show in a message: control characters (C0, DEL, C1),
    /// line and paragraph separators and the invisible marks that reorder text (U+061C, U+200E,
    /// U+200F, U+202A to U+202E, U+2066 to U+2069) become U+FFFD, as does a lone surrogate, and a
    /// name of more than <see cref="DisplayNameLimit"/> scalars is cut to that many followed by
    /// "…". The twin of Swift's `ZipStoreReader.displayName`.
    /// </summary>
    public static string DisplayName(string name)
    {
        var shown = new StringBuilder(Math.Min(name.Length, DisplayNameLimit * 2) + 1);
        int count = 0;
        foreach (Rune rune in name.EnumerateRunes())
        {
            if (count == DisplayNameLimit)
            {
                shown.Append(Ellipsis);
                break;
            }
            if (IsHiddenOrControl(rune.Value)) shown.Append(Replacement);
            else shown.Append(rune.ToString());
            count++;
        }
        return shown.ToString();
    }

    private static bool IsHiddenOrControl(int v) =>
        v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x061C || v == 0x200E || v == 0x200F
        || (v >= 0x2028 && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069);

    /// <summary>
    /// The message for <paramref name="kind"/>; the twin of Swift's `ZipStoreReader.message(_:entryName:limits:)`.
    /// The entry name is shown through <see cref="DisplayName"/>.
    /// </summary>
    public static string Message(ZipReadErrorKind kind, string? entryName = null, ZipReadLimits? limits = null)
    {
        limits ??= ZipReadLimits.Standard;
        string name = $"\"{DisplayName(entryName ?? "")}\"";
        return kind switch
        {
            ZipReadErrorKind.Corrupt => "The archive is damaged or cut short.",
            ZipReadErrorKind.UnsupportedMethod => $"{name} is compressed. Only archives of uncompressed (stored) entries can be read.",
            ZipReadErrorKind.Encrypted => $"{name} is encrypted. Encrypted archives cannot be read.",
            ZipReadErrorKind.Zip64 => "The archive uses ZIP64 (for archives past 4 GB or 65,535 entries), which is not supported.",
            ZipReadErrorKind.DataDescriptor => $"{name} keeps its sizes after its data (a data descriptor), which is not supported.",
            ZipReadErrorKind.UnsafeName => $"The archive holds an entry with an unsafe name ({name}).",
            ZipReadErrorKind.DuplicateName => $"The archive holds {name} more than once.",
            ZipReadErrorKind.SpecialFile => $"{name} is a link or a special file, not a plain file.",
            ZipReadErrorKind.TooManyEntries => $"The archive holds more than {limits.MaxEntries} entries.",
            ZipReadErrorKind.TooLarge => entryName is null
                ? $"The archive's contents are larger than {Megabytes(limits.MaxTotalBytes)} MB."
                : $"{name} is larger than {Megabytes(limits.MaxEntryBytes)} MB.",
            ZipReadErrorKind.SizeMismatch => $"{name} declares sizes that do not match its data.",
            ZipReadErrorKind.CrcMismatch => $"{name} is damaged: its checksum does not match its data.",
            _ => "The archive cannot be read.",
        };
    }

    // ---- Directory ----

    private const uint LocalSignature = 0x04034B50, CentralSignature = 0x02014B50, EndSignature = 0x06054B50;
    private const uint Zip64LocatorSignature = 0x07064B50;
    private const int LocalHeaderSize = 30, CentralRecordSize = 46, EndRecordSize = 22, Zip64LocatorSize = 20;
    private const ushort Zip64ExtraId = 0x0001, AesExtraId = 0x9901;
    private const ushort FlagEncrypted = 0x0001, FlagDataDescriptor = 0x0008, FlagStrongEncryption = 0x0040,
                         FlagMaskedHeader = 0x2000;
    private const ushort MethodStored = 0, MethodAes = 99;

    private sealed record Record(string Name, byte[] NameBytes, ushort Flags, ushort Method, uint Crc, uint Size,
                                 long LocalOffset, bool IsFolder);

    private static List<ZipStoreReaderEntry> ReadDirectory(Stream stream, ZipReadLimits limits)
    {
        long length = stream.Length;
        if (length < EndRecordSize) throw Error(ZipReadErrorKind.Corrupt);

        // The end record: the last signature whose comment ends exactly at the end of the file.
        int tail = (int)Math.Min(length, EndRecordSize + ushort.MaxValue);
        byte[] end = ReadAt(stream, length - tail, tail);
        int at = -1;
        for (int i = tail - EndRecordSize; i >= 0; i--)
        {
            if (U32(end, i) == EndSignature && i + EndRecordSize + U16(end, i + 20) == tail)
            {
                at = i;
                break;
            }
        }
        if (at < 0) throw Error(ZipReadErrorKind.Corrupt);
        long endOffset = length - tail + at;
        if (endOffset >= Zip64LocatorSize && U32(ReadAt(stream, endOffset - Zip64LocatorSize, 4), 0) == Zip64LocatorSignature)
        {
            throw Error(ZipReadErrorKind.Zip64);
        }
        ushort disk = U16(end, at + 4), directoryDisk = U16(end, at + 6);
        ushort onDisk = U16(end, at + 8), count = U16(end, at + 10);
        uint directorySize = U32(end, at + 12), directoryOffset = U32(end, at + 16);
        if (disk == 0xFFFF || directoryDisk == 0xFFFF || onDisk == 0xFFFF || count == 0xFFFF
            || directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF)
        {
            throw Error(ZipReadErrorKind.Zip64);
        }
        if (disk != 0 || directoryDisk != 0 || onDisk != count) throw Error(ZipReadErrorKind.Corrupt);
        if (count > limits.MaxEntries) throw Error(ZipReadErrorKind.TooManyEntries, limits: limits);
        if ((long)directoryOffset + directorySize != endOffset) throw Error(ZipReadErrorKind.Corrupt);
        if (directorySize > limits.MaxDirectoryBytes) throw Error(ZipReadErrorKind.TooLarge, limits: limits);
        if (directorySize < (long)count * CentralRecordSize) throw Error(ZipReadErrorKind.Corrupt);

        byte[] directory = ReadAt(stream, directoryOffset, (int)directorySize);
        var records = new List<Record>(count);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        long total = 0;
        int p = 0;
        for (int k = 0; k < count; k++)
        {
            if (p + CentralRecordSize > directory.Length || U32(directory, p) != CentralSignature)
            {
                throw Error(ZipReadErrorKind.Corrupt);
            }
            ushort madeBy = U16(directory, p + 4);
            ushort flags = U16(directory, p + 8), method = U16(directory, p + 10);
            uint crc = U32(directory, p + 16), compressed = U32(directory, p + 20), size = U32(directory, p + 24);
            int nameLength = U16(directory, p + 28), extraLength = U16(directory, p + 30), commentLength = U16(directory, p + 32);
            ushort startDisk = U16(directory, p + 34);
            uint external = U32(directory, p + 38), localOffset = U32(directory, p + 42);
            int next = p + CentralRecordSize + nameLength + extraLength + commentLength;
            if (next > directory.Length) throw Error(ZipReadErrorKind.Corrupt);
            byte[] nameBytes = directory.AsSpan(p + CentralRecordSize, nameLength).ToArray();
            string shownName = Encoding.UTF8.GetString(nameBytes);
            var extras = Extras(directory.AsSpan(p + CentralRecordSize + nameLength, extraLength));

            if ((flags & (FlagEncrypted | FlagStrongEncryption | FlagMaskedHeader)) != 0 || method == MethodAes
                || extras.Contains(AesExtraId))
            {
                throw Error(ZipReadErrorKind.Encrypted, shownName);
            }
            if ((flags & FlagDataDescriptor) != 0) throw Error(ZipReadErrorKind.DataDescriptor, shownName);
            if (extras.Contains(Zip64ExtraId) || compressed == 0xFFFFFFFF || size == 0xFFFFFFFF
                || localOffset == 0xFFFFFFFF || startDisk == 0xFFFF)
            {
                throw Error(ZipReadErrorKind.Zip64, shownName);
            }
            if (method != MethodStored) throw Error(ZipReadErrorKind.UnsupportedMethod, shownName);
            if (compressed != size) throw Error(ZipReadErrorKind.SizeMismatch, shownName);
            if (startDisk != 0) throw Error(ZipReadErrorKind.Corrupt, shownName);

            string? name = DecodeName(nameBytes);
            if (name is null || nameBytes.Length > limits.MaxNameBytes || !IsSafeName(name, limits.MaxNameBytes))
            {
                throw Error(ZipReadErrorKind.UnsafeName, shownName);
            }
            bool folder = name.EndsWith('/');
            if (IsSpecial(madeBy, external, folder)) throw Error(ZipReadErrorKind.SpecialFile, name);
            if (folder && size != 0) throw Error(ZipReadErrorKind.SizeMismatch, name);
            if (!seen.Add(DuplicateKey(name))) throw Error(ZipReadErrorKind.DuplicateName, name);
            if (size > limits.MaxEntryBytes) throw Error(ZipReadErrorKind.TooLarge, name, limits);
            total += size;
            if (total > limits.MaxTotalBytes) throw Error(ZipReadErrorKind.TooLarge, limits: limits);

            records.Add(new Record(name, nameBytes, flags, method, crc, size, localOffset, folder));
            p = next;
        }
        if (p != directory.Length) throw Error(ZipReadErrorKind.Corrupt);

        // The local headers: each agrees with its record, and the entries follow one another
        // from the start of the archive to its directory.
        var entries = new Dictionary<Record, ZipStoreReaderEntry>(ReferenceEqualityComparer.Instance);
        long expected = 0;
        foreach (var record in records.OrderBy(r => r.LocalOffset))
        {
            if (record.LocalOffset != expected) throw Error(ZipReadErrorKind.Corrupt, record.Name);
            if (record.LocalOffset + LocalHeaderSize > directoryOffset) throw Error(ZipReadErrorKind.Corrupt, record.Name);
            byte[] header = ReadAt(stream, record.LocalOffset, LocalHeaderSize);
            if (U32(header, 0) != LocalSignature) throw Error(ZipReadErrorKind.Corrupt, record.Name);
            ushort flags = U16(header, 6), method = U16(header, 8);
            uint crc = U32(header, 14), compressed = U32(header, 18), size = U32(header, 22);
            int nameLength = U16(header, 26), extraLength = U16(header, 28);
            long dataOffset = record.LocalOffset + LocalHeaderSize + nameLength + extraLength;
            if (dataOffset > directoryOffset) throw Error(ZipReadErrorKind.Corrupt, record.Name);
            byte[] nameAndExtra = ReadAt(stream, record.LocalOffset + LocalHeaderSize, nameLength + extraLength);
            var extras = Extras(nameAndExtra.AsSpan(nameLength, extraLength));
            if (extras.Contains(AesExtraId)) throw Error(ZipReadErrorKind.Encrypted, record.Name);
            if (extras.Contains(Zip64ExtraId)) throw Error(ZipReadErrorKind.Zip64, record.Name);
            if (compressed != record.Size || size != record.Size) throw Error(ZipReadErrorKind.SizeMismatch, record.Name);
            if (flags != record.Flags || method != record.Method || crc != record.Crc
                || !nameAndExtra.AsSpan(0, nameLength).SequenceEqual(record.NameBytes))
            {
                throw Error(ZipReadErrorKind.Corrupt, record.Name);
            }
            expected = dataOffset + record.Size;
            if (expected > directoryOffset) throw Error(ZipReadErrorKind.SizeMismatch, record.Name);
            entries[record] = new ZipStoreReaderEntry(record.Name, record.Size, record.Crc, dataOffset);
        }
        if (expected != directoryOffset) throw Error(ZipReadErrorKind.Corrupt);
        return [.. records.Where(r => !r.IsFolder).Select(r => entries[r])];
    }

    /// <summary>
    /// Whether the external attributes mark a link, device or other special file: a Unix file
    /// type other than a regular file or a folder (or a folder type on a file name), or MS-DOS
    /// attributes for a folder on a file name, a reparse point (Windows links) or a device.
    /// </summary>
    private static bool IsSpecial(ushort madeBy, uint external, bool folder)
    {
        int host = madeBy >> 8;
        if (host == 3 || host == 19)
        {
            uint type = (external >> 16) & 0xF000;
            if (type != 0 && type != 0x8000 && type != 0x4000) return true;
            if (type == 0x4000 && !folder) return true;
            if (type == 0x8000 && folder) return true;
        }
        if ((external & 0x10) != 0 && !folder) return true;
        return (external & (0x400 | 0x40)) != 0;
    }

    /// <summary>The ids of an extra field's blocks; a field whose blocks do not add up is corrupt.</summary>
    private static HashSet<ushort> Extras(ReadOnlySpan<byte> extra)
    {
        var ids = new HashSet<ushort>();
        int p = 0;
        while (p < extra.Length)
        {
            if (p + 4 > extra.Length) throw Error(ZipReadErrorKind.Corrupt);
            ushort id = (ushort)(extra[p] | (extra[p + 1] << 8));
            int size = extra[p + 2] | (extra[p + 3] << 8);
            if (p + 4 + size > extra.Length) throw Error(ZipReadErrorKind.Corrupt);
            ids.Add(id);
            p += 4 + size;
        }
        return ids;
    }

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>The name as strict UTF-8 (ASCII included); null when it is not valid UTF-8.</summary>
    private static string? DecodeName(byte[] bytes)
    {
        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static bool IsPairedSurrogates(string name)
    {
        for (int i = 0; i < name.Length; i++)
        {
            if (char.IsHighSurrogate(name[i]) && i + 1 < name.Length && char.IsLowSurrogate(name[i + 1])) i++;
            else if (char.IsSurrogate(name[i])) return false;
        }
        return true;
    }

    private static long Megabytes(long bytes) => bytes / (1024 * 1024);

    private static ZipReadException Error(ZipReadErrorKind kind, string? entryName = null, ZipReadLimits? limits = null) =>
        new(kind, Message(kind, entryName, limits), entryName);

    private static byte[] ReadAt(Stream stream, long offset, int count)
    {
        if (offset < 0 || offset + count > stream.Length) throw Error(ZipReadErrorKind.Corrupt);
        var buffer = new byte[count];
        stream.Position = offset;
        ReadExactly(stream, buffer);
        return buffer;
    }

    private static void ReadExactly(Stream stream, Span<byte> buffer)
    {
        try
        {
            stream.ReadExactly(buffer);
        }
        catch (EndOfStreamException)
        {
            throw Error(ZipReadErrorKind.Corrupt);
        }
    }

    private static ushort U16(byte[] b, int i) => (ushort)(b[i] | (b[i + 1] << 8));

    private static uint U32(byte[] b, int i) => (uint)(b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24));

    private static readonly uint[] CrcTable = MakeCrcTable();

    private static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            }
            table[n] = c;
        }
        return table;
    }

    private static uint Crc32Update(uint crc, ReadOnlySpan<byte> data)
    {
        foreach (byte b in data)
        {
            crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }
        return crc;
    }
}
