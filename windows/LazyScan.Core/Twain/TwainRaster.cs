using System.Buffers.Binary;

namespace LazyScan.Core;

/// <summary>
/// What a TWAIN source says about the image it is about to transfer (DAT_IMAGEINFO).
/// </summary>
/// <param name="Width">Pixels per row; zero or negative when the source does not know yet.</param>
/// <param name="Height">Rows; zero or negative (-1 in TWAIN) when the length is only known at the end, as with feeders that detect the sheet's length.</param>
/// <param name="PixelType">A <see cref="TwainPixelTypes"/> value.</param>
/// <param name="BitsPerPixel">1 for black &amp; white, 8 for gray, 24 for color.</param>
/// <param name="XResolution">Dots per inch across; zero when unknown.</param>
/// <param name="Compression">A TWCP value; the assembler reads only <see cref="TwainCompression.None"/>.</param>
/// <param name="Planar">Color planes sent one after the other; the assembler reads only interleaved (chunky) samples.</param>
public sealed record TwainImageInfo(int Width, int Height, int PixelType, int BitsPerPixel,
                                    double XResolution = 0, double YResolution = 0,
                                    int Compression = TwainCompression.None, bool Planar = false);

/// <summary>
/// One block of a memory transfer (DAT_IMAGEMEMXFER): <paramref name="Rows"/> rows of
/// <paramref name="Columns"/> pixels placed at (<paramref name="XOffset"/>, <paramref name="YOffset"/>),
/// <paramref name="BytesPerRow"/> bytes apart in <paramref name="Data"/>. Usually a full-width
/// strip; tiles use the offsets.
/// </summary>
public sealed record TwainStrip(int Columns, int Rows, int XOffset, int YOffset, int BytesPerRow, byte[] Data,
                                int Compression = TwainCompression.None);

/// <summary>
/// Builds one page from the strips of a TWAIN memory transfer. Reads 1-bit black &amp; white
/// (packed, most significant bit first unless told otherwise), 8-bit gray and 24-bit RGB,
/// uncompressed and interleaved, honoring ICAP_PIXELFLAVOR for the first two. Pixels no strip
/// covered stay white. When the source announced the size, strips are written straight into
/// the page; otherwise they are kept until <see cref="ToImage"/> knows how big it is.
/// </summary>
public sealed class TwainImageAssembler
{
    private readonly TwainImageInfo _info;
    private readonly bool _vanilla;
    private readonly bool _msbFirst;
    private readonly byte[]? _pixels;
    private readonly List<TwainStrip>? _pending;

    /// <exception cref="NotSupportedException">The format is not one <see cref="TwainRaster.CanAssemble(TwainImageInfo)"/> accepts.</exception>
    public TwainImageAssembler(TwainImageInfo info, int pixelFlavor = TwainPixelFlavors.Chocolate, bool msbFirst = true)
    {
        if (!TwainRaster.CanAssemble(info))
        {
            throw new NotSupportedException(
                $"The scanner sent an image format this app cannot read (pixel type {info.PixelType}, "
                + $"{info.BitsPerPixel} bits per pixel, compression {info.Compression}{(info.Planar ? ", planar" : "")}).");
        }
        _info = info;
        _vanilla = pixelFlavor == TwainPixelFlavors.Vanilla;
        _msbFirst = msbFirst;
        if (info.Width > 0 && info.Height > 0)
        {
            _pixels = TwainRaster.WhitePixels(info.Width, info.Height);
        }
        else
        {
            _pending = [];
        }
    }

    /// <summary>At least one strip with pixels arrived.</summary>
    public bool HasData { get; private set; }

    /// <summary>
    /// Every row of an image of announced size arrived. Images of unknown length are never
    /// known to be complete before the source moves on.
    /// </summary>
    public bool IsComplete => _info.Height > 0 && _rowsCovered >= _info.Height;

    private int _rowsCovered;

    /// <exception cref="FormatException">The strip is compressed.</exception>
    public void Add(TwainStrip strip)
    {
        if (strip.Compression != TwainCompression.None)
        {
            throw new FormatException("The scanner sent a compressed strip this app cannot read.");
        }
        if (strip.Rows <= 0 || strip.Columns <= 0 || strip.Data.Length == 0) return;
        HasData = true;
        int bytesPerRow = strip.BytesPerRow > 0 ? strip.BytesPerRow : TwainRaster.MinimumBytesPerRow(strip.Columns, _info.BitsPerPixel);
        int rowsCarried = (int)Math.Min(strip.Rows, ((long)strip.Data.Length + bytesPerRow - 1) / bytesPerRow);
        if (strip.YOffset <= _rowsCovered) _rowsCovered = Math.Max(_rowsCovered, strip.YOffset + rowsCarried);
        if (_pixels is not null) Blit(_pixels, _info.Width, _info.Height, strip);
        else _pending!.Add(strip);
    }

    /// <summary>The page assembled so far.</summary>
    /// <exception cref="InvalidOperationException">No strip arrived (see <see cref="HasData"/>).</exception>
    public RgbaImage ToImage()
    {
        if (!HasData) throw new InvalidOperationException("No image data arrived.");
        if (_pixels is not null) return new RgbaImage(_info.Width, _info.Height, _pixels);
        int width = _info.Width > 0 ? _info.Width : _pending!.Max(s => s.XOffset + s.Columns);
        int height = _info.Height > 0 ? _info.Height : _pending!.Max(s => s.YOffset + s.Rows);
        TwainRaster.CheckSize(width, height);
        var pixels = TwainRaster.WhitePixels(width, height);
        foreach (var strip in _pending!) Blit(pixels, width, height, strip);
        return new RgbaImage(width, height, pixels);
    }

    private void Blit(byte[] pixels, int width, int height, TwainStrip strip)
    {
        byte[] data = strip.Data;
        int bytesPerRow = strip.BytesPerRow > 0 ? strip.BytesPerRow : TwainRaster.MinimumBytesPerRow(strip.Columns, _info.BitsPerPixel);
        for (int row = 0; row < strip.Rows; row++)
        {
            int y = strip.YOffset + row;
            if (y < 0) continue;
            if (y >= height) break;
            long start = (long)row * bytesPerRow;
            if (start >= data.Length) break;
            int src = (int)start;
            int dst = (y * width) * 4;
            for (int column = 0; column < strip.Columns; column++)
            {
                int x = strip.XOffset + column;
                if (x < 0) continue;
                if (x >= width) break;
                int o = dst + x * 4;
                switch (_info.BitsPerPixel)
                {
                    case 1:
                    {
                        int index = src + (column >> 3);
                        if (index >= data.Length) goto NextRow;
                        int shift = _msbFirst ? 7 - (column & 7) : column & 7;
                        bool set = ((data[index] >> shift) & 1) != 0;
                        // Chocolate: a zero bit is black. Vanilla: a zero bit is white.
                        byte value = set != _vanilla ? (byte)255 : (byte)0;
                        pixels[o] = pixels[o + 1] = pixels[o + 2] = value;
                        break;
                    }
                    case 8:
                    {
                        int index = src + column;
                        if (index >= data.Length) goto NextRow;
                        byte value = _vanilla ? (byte)(255 - data[index]) : data[index];
                        pixels[o] = pixels[o + 1] = pixels[o + 2] = value;
                        break;
                    }
                    default: // 24-bit RGB
                    {
                        int index = src + column * 3;
                        if (index + 2 >= data.Length) goto NextRow;
                        pixels[o] = data[index];
                        pixels[o + 1] = data[index + 1];
                        pixels[o + 2] = data[index + 2];
                        break;
                    }
                }
            }
        NextRow:;
        }
    }
}

/// <summary>Pixel conversions for TWAIN transfers.</summary>
public static class TwainRaster
{
    /// <summary>Largest page accepted, in pixels (about 23 000 × 23 000): keeps a corrupt header from allocating gigabytes.</summary>
    public const long MaxPixels = int.MaxValue / 4;

    /// <summary>Whether <see cref="TwainImageAssembler"/> reads strips of this format.</summary>
    public static bool CanAssemble(TwainImageInfo info) =>
        info.Compression == TwainCompression.None && !info.Planar && CanAssemble(info.PixelType, info.BitsPerPixel);

    /// <summary>1-bit black &amp; white, 8-bit gray or 24-bit RGB.</summary>
    public static bool CanAssemble(int pixelType, int bitsPerPixel) => (pixelType, bitsPerPixel) switch
    {
        (TwainPixelTypes.BlackWhite, 1) => true,
        (TwainPixelTypes.Gray, 8) => true,
        (TwainPixelTypes.Rgb, 24) => true,
        _ => false,
    };

    /// <summary>Bits per pixel of a pixel type at an ICAP_BITDEPTH (bits per sample): RGB has three samples.</summary>
    public static int BitsPerPixel(int pixelType, int bitDepth) =>
        pixelType == TwainPixelTypes.Rgb ? bitDepth * 3 : bitDepth;

    internal static int MinimumBytesPerRow(int columns, int bitsPerPixel) =>
        (int)(((long)columns * bitsPerPixel + 7) / 8);

    internal static void CheckSize(int width, int height)
    {
        if (width <= 0 || height <= 0 || (long)width * height > MaxPixels)
        {
            throw new FormatException($"The scanner sent an image of an impossible size ({width} × {height}).");
        }
    }

    internal static byte[] WhitePixels(int width, int height)
    {
        CheckSize(width, height);
        var pixels = new byte[width * height * 4];
        Array.Fill(pixels, (byte)255);
        return pixels;
    }

    /// <summary>The parts of a device-independent bitmap, from its header.</summary>
    private readonly record struct BitmapLayout(int HeaderSize, int Width, int Height, bool TopDown, int BitCount,
                                                bool BitFields, int PixelsPerMeter, int MasksSize, int PaletteCount,
                                                long TableSize, long Stride)
    {
        /// <summary>Where the color table starts: after the header and, with a 40-byte header, the bit-field masks.</summary>
        public int PaletteStart => HeaderSize + MasksSize;
        /// <summary>
        /// After the color table: the palette of 1, 4 and 8-bit bitmaps, or the optional table of
        /// a 24 or 32-bit one (biClrUsed entries, never used for decoding).
        /// </summary>
        public long PixelStart => PaletteStart + TableSize;
        public long Length => PixelStart + Stride * Height;
    }

    /// <summary>Largest bitmap header accepted (BITMAPV5HEADER is 124 bytes).</summary>
    private const int MaxBitmapHeader = 1024;

    private static BitmapLayout ReadLayout(ReadOnlySpan<byte> h)
    {
        if (h.Length < 40) throw new FormatException("The bitmap is too short.");
        int headerSize = BinaryPrimitives.ReadInt32LittleEndian(h);
        if (headerSize < 40 || headerSize > MaxBitmapHeader) throw new FormatException($"Unsupported bitmap header ({headerSize} bytes).");
        int width = BinaryPrimitives.ReadInt32LittleEndian(h[4..]);
        int rawHeight = BinaryPrimitives.ReadInt32LittleEndian(h[8..]);
        int bitCount = BinaryPrimitives.ReadUInt16LittleEndian(h[14..]);
        int compression = BinaryPrimitives.ReadInt32LittleEndian(h[16..]);
        int pixelsPerMeter = BinaryPrimitives.ReadInt32LittleEndian(h[24..]);
        int colorsUsed = BinaryPrimitives.ReadInt32LittleEndian(h[32..]);
        if (rawHeight == int.MinValue) throw new FormatException("The bitmap has an impossible height.");
        int height = Math.Abs(rawHeight);
        CheckSize(width, height);

        const int BiRgb = 0, BiBitfields = 3;
        bool bitFields = compression == BiBitfields;
        if (bitFields)
        {
            if (bitCount != 32) throw new FormatException($"Unsupported bitmap: {bitCount}-bit with bit fields.");
        }
        else if (compression != BiRgb)
        {
            throw new FormatException($"Unsupported bitmap compression {compression}.");
        }
        if (bitCount is not (1 or 4 or 8 or 24 or 32)) throw new FormatException($"Unsupported bitmap: {bitCount} bits per pixel.");
        int paletteCount = bitCount <= 8 ? (colorsUsed > 0 ? Math.Min(colorsUsed, 1 << bitCount) : 1 << bitCount) : 0;
        // A 24 or 32-bit bitmap may still carry a color table (biClrUsed entries, a palette for
        // displays that need one): its pixels come after it.
        long tableSize = bitCount <= 8 ? paletteCount * 4L : Math.Max(colorsUsed, 0) * 4L;
        return new BitmapLayout(
            HeaderSize: headerSize,
            Width: width,
            Height: height,
            TopDown: rawHeight < 0,
            BitCount: bitCount,
            BitFields: bitFields,
            PixelsPerMeter: pixelsPerMeter,
            // The three masks follow a 40-byte header; the larger V4/V5 headers hold them.
            MasksSize: bitFields && headerSize == 40 ? 12 : 0,
            PaletteCount: paletteCount,
            TableSize: tableSize,
            Stride: (((long)width * bitCount) + 31) / 32 * 4);
    }

    /// <summary>
    /// The length of a device-independent bitmap without the "BM" file header (header,
    /// bit-field masks, color table and rows), from the first 40 bytes of its header: what to
    /// copy out of a native transfer, whatever its biSizeImage says (it may be 0).
    /// </summary>
    /// <exception cref="FormatException">Not a bitmap <see cref="DecodeBitmap"/> reads.</exception>
    public static long BitmapLength(ReadOnlySpan<byte> header) => ReadLayout(header).Length;

    /// <summary>
    /// Reads a native transfer: a Windows device-independent bitmap, with or without the
    /// 14-byte "BM" file header in front. Accepts 40-byte and larger (V4, V5) headers; 1, 4
    /// and 8 bits per pixel with a color table, 24-bit BGR, and 32-bit BGRX (plain or with the
    /// standard bit-field masks), the last two with or without an optional color table, which
    /// is skipped; rows bottom-up or top-down. A file header's pixel offset is
    /// used only when it lies past the header, masks and color table (some writers leave the
    /// masks out of it).
    /// </summary>
    /// <param name="xResolution">Horizontal dots per inch from the header; 0 when it has none.</param>
    /// <exception cref="FormatException">Not a bitmap this reader understands, or cut short.</exception>
    public static RgbaImage DecodeBitmap(ReadOnlySpan<byte> data, out double xResolution)
    {
        int header = 0;
        long? pixelOffset = null;
        if (data.Length >= 14 && data[0] == (byte)'B' && data[1] == (byte)'M')
        {
            header = 14;
            pixelOffset = BinaryPrimitives.ReadUInt32LittleEndian(data[10..]);
        }
        if (data.Length < header + 40) throw new FormatException("The bitmap is too short.");
        var h = data[header..];
        var layout = ReadLayout(h);
        if (layout.HeaderSize > h.Length) throw new FormatException($"Unsupported bitmap header ({layout.HeaderSize} bytes).");
        int width = layout.Width, height = layout.Height, bitCount = layout.BitCount, paletteCount = layout.PaletteCount;
        bool topDown = layout.TopDown;
        if (layout.BitFields)
        {
            const int maskStart = 40;
            if (h.Length < maskStart + 12) throw new FormatException("The bitmap is too short.");
            uint red = BinaryPrimitives.ReadUInt32LittleEndian(h[maskStart..]);
            uint green = BinaryPrimitives.ReadUInt32LittleEndian(h[(maskStart + 4)..]);
            uint blue = BinaryPrimitives.ReadUInt32LittleEndian(h[(maskStart + 8)..]);
            if (red != 0x00FF0000 || green != 0x0000FF00 || blue != 0x000000FF)
            {
                throw new FormatException("Unsupported bitmap: unusual bit-field masks.");
            }
        }

        int paletteStart = layout.PaletteStart;
        if (paletteCount > 0 && h.Length < paletteStart + paletteCount * 4) throw new FormatException("The bitmap's color table is cut short.");
        long start = pixelOffset is { } offset && offset - header >= layout.PixelStart ? offset - header : layout.PixelStart;
        long stride = layout.Stride;
        if (start + stride * height > h.Length) throw new FormatException("The bitmap's pixels are cut short.");

        var palette = new byte[Math.Max(paletteCount, 1) * 3];
        for (int i = 0; i < paletteCount; i++)
        {
            int p = paletteStart + i * 4;
            palette[i * 3] = h[p + 2];
            palette[i * 3 + 1] = h[p + 1];
            palette[i * 3 + 2] = h[p];
        }

        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            int sourceRow = topDown ? y : height - 1 - y;
            var row = h.Slice((int)(start + sourceRow * stride), (int)stride);
            int o = y * width * 4;
            for (int x = 0; x < width; x++, o += 4)
            {
                switch (bitCount)
                {
                    case 24:
                        pixels[o] = row[x * 3 + 2];
                        pixels[o + 1] = row[x * 3 + 1];
                        pixels[o + 2] = row[x * 3];
                        break;
                    case 32:
                        pixels[o] = row[x * 4 + 2];
                        pixels[o + 1] = row[x * 4 + 1];
                        pixels[o + 2] = row[x * 4];
                        break;
                    default:
                    {
                        int index = bitCount switch
                        {
                            1 => (row[x >> 3] >> (7 - (x & 7))) & 1,
                            4 => (row[x >> 1] >> ((x & 1) == 0 ? 4 : 0)) & 0x0F,
                            _ => row[x],
                        };
                        if (index >= paletteCount)
                        {
                            // An index past the color table: treat it as a gray level.
                            byte gray = (byte)(index * 255 / ((1 << bitCount) - 1));
                            pixels[o] = pixels[o + 1] = pixels[o + 2] = gray;
                        }
                        else
                        {
                            pixels[o] = palette[index * 3];
                            pixels[o + 1] = palette[index * 3 + 1];
                            pixels[o + 2] = palette[index * 3 + 2];
                        }
                        break;
                    }
                }
                pixels[o + 3] = 255;
            }
        }
        xResolution = layout.PixelsPerMeter > 0 ? Math.Round(layout.PixelsPerMeter * 0.0254) : 0;
        return new RgbaImage(width, height, pixels);
    }
}
