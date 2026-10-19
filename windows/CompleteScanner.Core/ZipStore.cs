using System.Text;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/ZipStore.swift: the same bytes for the same entries.

/// <summary>One file in a zip package: its path inside the package ("word/document.xml") and its bytes.</summary>
public sealed record ZipStoreEntry(string Name, byte[] Data);

/// <summary>
/// A minimal zip writer for the Word document (<see cref="DocxWriter"/>): every entry stored
/// uncompressed (Word and LibreOffice read stored entries), dated 1980-01-01, in the order given,
/// with a CRC-32 per entry. Written by hand rather than with System.IO.Compression so the Mac
/// (whose Foundation has no zip writer) writes the very same bytes. No zip64: a package must stay
/// under 4 GB and 65,535 entries.
/// </summary>
public static class ZipStore
{
    /// <summary>The CRC-32 of zip and PNG (polynomial 0xEDB88320, reflected; "123456789" gives 0xCBF43926).</summary>
    public static uint Crc32(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (byte b in data)
        {
            crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }
        return crc ^ 0xFFFFFFFF;
    }

    /// <summary>The zip package holding <paramref name="entries"/>, in that order.</summary>
    public static byte[] Make(IReadOnlyList<ZipStoreEntry> entries)
    {
        if (entries.Count > ushort.MaxValue) throw new ArgumentException("Too many entries for a zip without zip64.", nameof(entries));
        using var output = new MemoryStream();
        using var central = new MemoryStream();
        foreach (var entry in entries)
        {
            byte[] name = Encoding.UTF8.GetBytes(entry.Name);
            bool utf8Name = entry.Name.Any(c => c > 0x7F);
            ushort flags = (ushort)(utf8Name ? 0x0800 : 0);
            uint crc = Crc32(entry.Data);
            long offset = output.Position;
            if (offset > uint.MaxValue || (long)entry.Data.Length > uint.MaxValue)
            {
                throw new ArgumentException("The package is too large for a zip without zip64.", nameof(entries));
            }

            // Local file header.
            WriteUInt32(output, 0x04034B50);
            WriteUInt16(output, VersionNeeded);
            WriteUInt16(output, flags);
            WriteUInt16(output, 0); // stored
            WriteUInt16(output, DosTime);
            WriteUInt16(output, DosDate);
            WriteUInt32(output, crc);
            WriteUInt32(output, (uint)entry.Data.Length);
            WriteUInt32(output, (uint)entry.Data.Length);
            WriteUInt16(output, (ushort)name.Length);
            WriteUInt16(output, 0); // no extra field
            output.Write(name);
            output.Write(entry.Data);

            // Its central directory record.
            WriteUInt32(central, 0x02014B50);
            WriteUInt16(central, VersionMadeBy);
            WriteUInt16(central, VersionNeeded);
            WriteUInt16(central, flags);
            WriteUInt16(central, 0);
            WriteUInt16(central, DosTime);
            WriteUInt16(central, DosDate);
            WriteUInt32(central, crc);
            WriteUInt32(central, (uint)entry.Data.Length);
            WriteUInt32(central, (uint)entry.Data.Length);
            WriteUInt16(central, (ushort)name.Length);
            WriteUInt16(central, 0); // extra field
            WriteUInt16(central, 0); // comment
            WriteUInt16(central, 0); // disk number
            WriteUInt16(central, 0); // internal attributes
            WriteUInt32(central, 0); // external attributes
            WriteUInt32(central, (uint)offset);
            central.Write(name);
        }

        long centralOffset = output.Position;
        central.Position = 0;
        central.CopyTo(output);
        long centralSize = output.Position - centralOffset;
        if (output.Position > uint.MaxValue) throw new ArgumentException("The package is too large for a zip without zip64.", nameof(entries));

        // End of central directory.
        WriteUInt32(output, 0x06054B50);
        WriteUInt16(output, 0); // this disk
        WriteUInt16(output, 0); // the disk the directory starts on
        WriteUInt16(output, (ushort)entries.Count);
        WriteUInt16(output, (ushort)entries.Count);
        WriteUInt32(output, (uint)centralSize);
        WriteUInt32(output, (uint)centralOffset);
        WriteUInt16(output, 0); // no comment
        return output.ToArray();
    }

    /// <summary>1.0: stored entries need nothing newer.</summary>
    private const ushort VersionNeeded = 10;
    /// <summary>2.0, MS-DOS attributes.</summary>
    private const ushort VersionMadeBy = 20;
    /// <summary>00:00:00.</summary>
    private const ushort DosTime = 0;
    /// <summary>1980-01-01, the earliest date a zip can hold: the same bytes on every save.</summary>
    private const ushort DosDate = (0 << 9) | (1 << 5) | 1;

    private static readonly uint[] Table = MakeTable();

    private static uint[] MakeTable()
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

    private static void WriteUInt16(Stream stream, ushort value)
    {
        stream.WriteByte((byte)value);
        stream.WriteByte((byte)(value >> 8));
    }

    private static void WriteUInt32(Stream stream, uint value)
    {
        stream.WriteByte((byte)value);
        stream.WriteByte((byte)(value >> 8));
        stream.WriteByte((byte)(value >> 16));
        stream.WriteByte((byte)(value >> 24));
    }
}
