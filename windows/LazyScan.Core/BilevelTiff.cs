using System.Buffers.Binary;

namespace LazyScan.Core;

// The Mac's twin is Sources/CompleteScannerKit/Output/BilevelTIFF.swift, which writes the same
// bytes (see CONTRACTS.md, "CCITT G4 for black & white pages").

/// <summary>One page of a black &amp; white TIFF: the page and its resolution.</summary>
public sealed record BilevelTiffPage(RgbaImage Image, int Dpi);

/// <summary>
/// Black &amp; white TIFF files compressed with CCITT G4 (compression 4), one page or several:
/// little-endian, each page one strip of <see cref="CcittG4Encoder"/> data followed by its
/// image file directory, 1 bit per pixel, WhiteIsZero (as fax images are stored), the
/// resolution in pixels per inch. Several pages are marked as pages of one document
/// (NewSubfileType 2, PageNumber n of count). Pixels are black where their luma is below
/// <see cref="Bilevel.Threshold"/>.
/// </summary>
public static class BilevelTiff
{
    /// <summary>Whether a page saved as <paramref name="format"/> in <paramref name="mode"/> is written here: black &amp; white TIFFs.</summary>
    public static bool Applies(OutputFormat format, ColorMode mode) =>
        format == OutputFormat.Tiff && mode == ColorMode.BlackWhite;

    /// <summary>A one-page file.</summary>
    public static byte[] Make(RgbaImage image, int dpi) => Make([new BilevelTiffPage(image, dpi)]);

    /// <summary>A file with every page, in order.</summary>
    public static byte[] Make(IReadOnlyList<BilevelTiffPage> pages)
    {
        if (pages.Count == 0) throw new ArgumentException("A TIFF needs at least one page.", nameof(pages));
        using var output = new MemoryStream();
        output.Write("II*\0"u8);
        output.Write(new byte[4]); // the first directory's offset, filled in below
        long linkOffset = 4;
        bool multiPage = pages.Count > 1;
        var link = new byte[4];
        for (int index = 0; index < pages.Count; index++)
        {
            var page = pages[index];
            byte[] strip = CcittG4Encoder.Encode(page.Image);
            long stripOffset = output.Position;
            output.Write(strip);
            if (output.Position % 2 == 1) output.WriteByte(0); // directories start on a word boundary

            var entries = new List<(ushort Tag, ushort Type, uint Count, uint Value)>();
            if (multiPage) entries.Add((254, Long, 1, 2));           // NewSubfileType: a page of a document
            entries.Add((256, Long, 1, (uint)page.Image.Width));     // ImageWidth
            entries.Add((257, Long, 1, (uint)page.Image.Height));    // ImageLength
            entries.Add((258, Short, 1, 1));                         // BitsPerSample
            entries.Add((259, Short, 1, 4));                         // Compression: CCITT T.6
            entries.Add((262, Short, 1, 0));                         // PhotometricInterpretation: WhiteIsZero
            entries.Add((273, Long, 1, checked((uint)stripOffset))); // StripOffsets
            entries.Add((277, Short, 1, 1));                         // SamplesPerPixel
            entries.Add((278, Long, 1, (uint)page.Image.Height));    // RowsPerStrip: one strip
            entries.Add((279, Long, 1, (uint)strip.Length));         // StripByteCounts
            entries.Add((282, Rational, 1, 0));                      // XResolution (value after the directory)
            entries.Add((283, Rational, 1, 0));                      // YResolution
            entries.Add((293, Long, 1, 0));                          // T6Options: no uncompressed mode
            entries.Add((296, Short, 1, 2));                         // ResolutionUnit: inch
            if (multiPage)
            {
                // PageNumber: two shorts, this page (from 0) and the page count.
                entries.Add((297, Short, 2, (uint)index | ((uint)pages.Count << 16)));
            }

            long directory = output.Position;
            long resolution = directory + 2 + entries.Count * 12 + 4; // two rationals after the directory
            var bytes = new byte[2 + entries.Count * 12 + 4 + 16];
            BinaryPrimitives.WriteUInt16LittleEndian(bytes, (ushort)entries.Count);
            for (int e = 0; e < entries.Count; e++)
            {
                var (tag, type, count, value) = entries[e];
                var entry = bytes.AsSpan(2 + e * 12, 12);
                BinaryPrimitives.WriteUInt16LittleEndian(entry, tag);
                BinaryPrimitives.WriteUInt16LittleEndian(entry[2..], type);
                BinaryPrimitives.WriteUInt32LittleEndian(entry[4..], count);
                if (type == Rational) value = checked((uint)(resolution + (tag == 282 ? 0 : 8)));
                if (type == Short && count == 1) BinaryPrimitives.WriteUInt16LittleEndian(entry[8..], (ushort)value);
                else BinaryPrimitives.WriteUInt32LittleEndian(entry[8..], value); // a long, two shorts, an offset
            }
            // The next directory's offset (0 for the last) is written when it is known.
            uint dpi = (uint)Math.Max(page.Dpi, 1);
            var rationals = bytes.AsSpan(2 + entries.Count * 12 + 4);
            BinaryPrimitives.WriteUInt32LittleEndian(rationals, dpi);
            BinaryPrimitives.WriteUInt32LittleEndian(rationals[4..], 1);
            BinaryPrimitives.WriteUInt32LittleEndian(rationals[8..], dpi);
            BinaryPrimitives.WriteUInt32LittleEndian(rationals[12..], 1);
            output.Write(bytes);

            long end = output.Position;
            output.Position = linkOffset;
            BinaryPrimitives.WriteUInt32LittleEndian(link, checked((uint)directory));
            output.Write(link);
            output.Position = end;
            linkOffset = directory + 2 + entries.Count * 12;
        }
        return output.ToArray();
    }

    private const ushort Short = 3, Long = 4, Rational = 5;
}
