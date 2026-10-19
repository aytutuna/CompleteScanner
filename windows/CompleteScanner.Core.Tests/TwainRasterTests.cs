using System.Buffers.Binary;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// TWAIN is Windows-only: no Swift counterpart (macOS reaches these scanners through
// ImageCaptureCore).

public class TwainRasterTests
{
    private static (byte R, byte G, byte B, byte A) Pixel(RgbaImage image, int x, int y)
    {
        int o = (y * image.Width + x) * 4;
        return (image.Pixels[o], image.Pixels[o + 1], image.Pixels[o + 2], image.Pixels[o + 3]);
    }

    private static TwainStrip Strip(int columns, int rows, int yOffset, int bytesPerRow, params byte[] data) =>
        new(columns, rows, 0, yOffset, bytesPerRow, data);

    // MARK: - Memory strips

    [Fact]
    public void OneBit_Chocolate_ZeroIsBlack_MostSignificantBitFirst()
    {
        var info = new TwainImageInfo(10, 1, TwainPixelTypes.BlackWhite, 1);
        var assembler = new TwainImageAssembler(info);
        // 1010 0000 | 01xx xxxx: padded to 4 bytes per row.
        assembler.Add(Strip(10, 1, 0, 4, 0b1010_0000, 0b0100_0000, 0, 0));
        var image = assembler.ToImage();
        Assert.Equal((255, 255, 255, 255), Pixel(image, 0, 0));
        Assert.Equal((0, 0, 0, 255), Pixel(image, 1, 0));
        Assert.Equal((255, 255, 255, 255), Pixel(image, 2, 0));
        Assert.Equal((0, 0, 0, 255), Pixel(image, 3, 0));
        Assert.Equal((0, 0, 0, 255), Pixel(image, 8, 0));
        Assert.Equal((255, 255, 255, 255), Pixel(image, 9, 0));
    }

    [Fact]
    public void OneBit_Vanilla_ZeroIsWhite_LeastSignificantBitFirst()
    {
        var info = new TwainImageInfo(4, 1, TwainPixelTypes.BlackWhite, 1);
        var assembler = new TwainImageAssembler(info, TwainPixelFlavors.Vanilla, msbFirst: false);
        assembler.Add(Strip(4, 1, 0, 1, 0b0000_0001));
        var image = assembler.ToImage();
        Assert.Equal((0, 0, 0, 255), Pixel(image, 0, 0));
        Assert.Equal((255, 255, 255, 255), Pixel(image, 1, 0));
        Assert.Equal((255, 255, 255, 255), Pixel(image, 3, 0));
    }

    [Fact]
    public void Gray_StripsAreStackedAndVanillaInverts()
    {
        var info = new TwainImageInfo(2, 3, TwainPixelTypes.Gray, 8);
        var chocolate = new TwainImageAssembler(info);
        chocolate.Add(Strip(2, 2, 0, 4, 10, 20, 0, 0, 30, 40, 0, 0));
        chocolate.Add(Strip(2, 1, 2, 2, 50, 60));
        var image = chocolate.ToImage();
        Assert.Equal((10, 10, 10, 255), Pixel(image, 0, 0));
        Assert.Equal((40, 40, 40, 255), Pixel(image, 1, 1));
        Assert.Equal((60, 60, 60, 255), Pixel(image, 1, 2));

        var vanilla = new TwainImageAssembler(info, TwainPixelFlavors.Vanilla);
        vanilla.Add(Strip(2, 1, 0, 2, 0, 255));
        var inverted = vanilla.ToImage();
        Assert.Equal((255, 255, 255, 255), Pixel(inverted, 0, 0));
        Assert.Equal((0, 0, 0, 255), Pixel(inverted, 1, 0));
        // Rows no strip covered stay white.
        Assert.Equal((255, 255, 255, 255), Pixel(inverted, 0, 2));
    }

    [Fact]
    public void Rgb_IsReadInRgbOrder_AndTilesUseTheirOffsets()
    {
        var info = new TwainImageInfo(3, 2, TwainPixelTypes.Rgb, 24);
        var assembler = new TwainImageAssembler(info);
        assembler.Add(new TwainStrip(1, 1, 2, 1, 3, [1, 2, 3]));
        assembler.Add(new TwainStrip(2, 1, 0, 0, 6, [10, 20, 30, 40, 50, 60]));
        var image = assembler.ToImage();
        Assert.Equal((10, 20, 30, 255), Pixel(image, 0, 0));
        Assert.Equal((40, 50, 60, 255), Pixel(image, 1, 0));
        Assert.Equal((1, 2, 3, 255), Pixel(image, 2, 1));
        Assert.Equal((255, 255, 255, 255), Pixel(image, 0, 1));
    }

    [Fact]
    public void UnknownLength_GrowsWithTheStrips()
    {
        var info = new TwainImageInfo(2, -1, TwainPixelTypes.Gray, 8);
        var assembler = new TwainImageAssembler(info);
        Assert.False(assembler.HasData);
        assembler.Add(Strip(2, 2, 0, 2, 1, 2, 3, 4));
        assembler.Add(Strip(2, 1, 2, 2, 5, 6));
        Assert.True(assembler.HasData);
        var image = assembler.ToImage();
        Assert.Equal(2, image.Width);
        Assert.Equal(3, image.Height);
        Assert.Equal((6, 6, 6, 255), Pixel(image, 1, 2));
    }

    [Fact]
    public void ShortOrOversizedStrips_AreClippedNotFatal()
    {
        var info = new TwainImageInfo(2, 1, TwainPixelTypes.Gray, 8);
        var assembler = new TwainImageAssembler(info);
        // Claims 3 rows of 3 columns but carries only 2 bytes.
        assembler.Add(Strip(3, 3, 0, 3, 7, 8));
        var image = assembler.ToImage();
        Assert.Equal((7, 7, 7, 255), Pixel(image, 0, 0));
        Assert.Equal((8, 8, 8, 255), Pixel(image, 1, 0));
    }

    [Theory]
    [InlineData(TwainPixelTypes.Gray, 16, TwainCompression.None, false)]
    [InlineData(TwainPixelTypes.Rgb, 48, TwainCompression.None, false)]
    [InlineData(TwainPixelTypes.Rgb, 24, 6, false)] // JPEG
    [InlineData(TwainPixelTypes.Rgb, 24, TwainCompression.None, true)]
    [InlineData(3, 8, TwainCompression.None, false)] // palette
    public void UnsupportedFormats_AreRefused(int pixelType, int bitsPerPixel, int compression, bool planar)
    {
        var info = new TwainImageInfo(4, 4, pixelType, bitsPerPixel, Compression: compression, Planar: planar);
        Assert.False(TwainRaster.CanAssemble(info));
        Assert.Throws<NotSupportedException>(() => new TwainImageAssembler(info));
    }

    [Fact]
    public void CompressedStrip_IsRefused()
    {
        var assembler = new TwainImageAssembler(new TwainImageInfo(2, 1, TwainPixelTypes.Gray, 8));
        Assert.Throws<FormatException>(() => assembler.Add(new TwainStrip(2, 1, 0, 0, 2, [1, 2], Compression: 5)));
    }

    [Fact]
    public void NoStrips_HasNoImage()
    {
        var assembler = new TwainImageAssembler(new TwainImageInfo(2, 1, TwainPixelTypes.Gray, 8));
        Assert.False(assembler.HasData);
        Assert.Throws<InvalidOperationException>(assembler.ToImage);
    }

    [Theory]
    [InlineData(TwainPixelTypes.BlackWhite, 1, 1)]
    [InlineData(TwainPixelTypes.Gray, 8, 8)]
    [InlineData(TwainPixelTypes.Rgb, 8, 24)]
    public void BitsPerPixel_CountsThreeSamplesForRgb(int pixelType, int bitDepth, int expected)
    {
        Assert.Equal(expected, TwainRaster.BitsPerPixel(pixelType, bitDepth));
    }

    // MARK: - Native bitmaps

    /// <summary>A bitmap: 40-byte header, optional color table, rows padded to 4 bytes, bottom-up unless <paramref name="topDown"/>.</summary>
    private static byte[] Bitmap(int width, int height, int bitCount, byte[][] rowsTopToBottom, byte[][]? palette = null,
                                 bool topDown = false, bool fileHeader = false, int pixelsPerMeter = 11811,
                                 int compression = 0, uint[]? masks = null)
    {
        int stride = (width * bitCount + 31) / 32 * 4;
        int paletteBytes = (palette?.Length ?? 0) * 4;
        int maskBytes = masks is null ? 0 : 12;
        int prefix = fileHeader ? 14 : 0;
        int pixelStart = prefix + 40 + maskBytes + paletteBytes;
        var data = new byte[pixelStart + stride * height];
        if (fileHeader)
        {
            data[0] = (byte)'B';
            data[1] = (byte)'M';
            BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(2), data.Length);
            BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(10), pixelStart);
        }
        var h = data.AsSpan(prefix);
        BinaryPrimitives.WriteInt32LittleEndian(h, 40);
        BinaryPrimitives.WriteInt32LittleEndian(h[4..], width);
        BinaryPrimitives.WriteInt32LittleEndian(h[8..], topDown ? -height : height);
        BinaryPrimitives.WriteUInt16LittleEndian(h[12..], 1);
        BinaryPrimitives.WriteUInt16LittleEndian(h[14..], (ushort)bitCount);
        BinaryPrimitives.WriteInt32LittleEndian(h[16..], compression);
        BinaryPrimitives.WriteInt32LittleEndian(h[24..], pixelsPerMeter);
        BinaryPrimitives.WriteInt32LittleEndian(h[28..], pixelsPerMeter);
        BinaryPrimitives.WriteInt32LittleEndian(h[32..], palette?.Length ?? 0);
        int at = 40;
        if (masks is not null)
        {
            foreach (uint mask in masks)
            {
                BinaryPrimitives.WriteUInt32LittleEndian(h[at..], mask);
                at += 4;
            }
        }
        foreach (var entry in palette ?? [])
        {
            h[at] = entry[2];     // blue
            h[at + 1] = entry[1]; // green
            h[at + 2] = entry[0]; // red
            at += 4;
        }
        for (int y = 0; y < height; y++)
        {
            int row = topDown ? y : height - 1 - y;
            rowsTopToBottom[y].CopyTo(data, pixelStart + row * stride);
        }
        return data;
    }

    [Fact]
    public void Bitmap24_BottomUpBgr_WithFileHeader()
    {
        byte[] data = Bitmap(2, 2, 24,
            [[3, 2, 1, 6, 5, 4], [9, 8, 7, 12, 11, 10]], fileHeader: true);
        var image = TwainRaster.DecodeBitmap(data, out double dpi);
        Assert.Equal(2, image.Width);
        Assert.Equal(2, image.Height);
        Assert.Equal((1, 2, 3, 255), Pixel(image, 0, 0));
        Assert.Equal((4, 5, 6, 255), Pixel(image, 1, 0));
        Assert.Equal((7, 8, 9, 255), Pixel(image, 0, 1));
        Assert.Equal(300, dpi);
    }

    [Fact]
    public void Bitmap24_TopDown_WithoutFileHeader()
    {
        byte[] data = Bitmap(1, 2, 24, [[3, 2, 1], [6, 5, 4]], topDown: true, pixelsPerMeter: 0);
        var image = TwainRaster.DecodeBitmap(data, out double dpi);
        Assert.Equal((1, 2, 3, 255), Pixel(image, 0, 0));
        Assert.Equal((4, 5, 6, 255), Pixel(image, 0, 1));
        Assert.Equal(0, dpi);
    }

    [Fact]
    public void Bitmap1_UsesItsColorTable()
    {
        // A scanner's black & white DIB: index 0 white, index 1 black.
        byte[] data = Bitmap(3, 1, 1, [[0b0100_0000]], palette: [[255, 255, 255], [0, 0, 0]]);
        var image = TwainRaster.DecodeBitmap(data, out _);
        Assert.Equal((255, 255, 255, 255), Pixel(image, 0, 0));
        Assert.Equal((0, 0, 0, 255), Pixel(image, 1, 0));
        Assert.Equal((255, 255, 255, 255), Pixel(image, 2, 0));
    }

    [Fact]
    public void Bitmap4And8_UseTheirColorTables()
    {
        byte[] four = Bitmap(2, 1, 4, [[0x10]], palette: [[9, 9, 9], [200, 100, 50]]);
        var image4 = TwainRaster.DecodeBitmap(four, out _);
        Assert.Equal((200, 100, 50, 255), Pixel(image4, 0, 0));
        Assert.Equal((9, 9, 9, 255), Pixel(image4, 1, 0));

        var grays = Enumerable.Range(0, 256).Select(i => new[] { (byte)i, (byte)i, (byte)i }).ToArray();
        byte[] eight = Bitmap(2, 1, 8, [[0, 200]], palette: grays);
        var image8 = TwainRaster.DecodeBitmap(eight, out _);
        Assert.Equal((0, 0, 0, 255), Pixel(image8, 0, 0));
        Assert.Equal((200, 200, 200, 255), Pixel(image8, 1, 0));
    }

    [Fact]
    public void Bitmap32_PlainAndWithStandardBitFields()
    {
        byte[] plain = Bitmap(1, 1, 32, [[3, 2, 1, 0]]);
        Assert.Equal((1, 2, 3, 255), Pixel(TwainRaster.DecodeBitmap(plain, out _), 0, 0));
        byte[] fields = Bitmap(1, 1, 32, [[3, 2, 1, 0]], compression: 3, masks: [0x00FF0000, 0x0000FF00, 0x000000FF]);
        Assert.Equal((1, 2, 3, 255), Pixel(TwainRaster.DecodeBitmap(fields, out _), 0, 0));
    }

    [Fact]
    public void Bitmap_CutShortOrUnsupported_IsRefused()
    {
        byte[] full = Bitmap(4, 4, 24, [new byte[12], new byte[12], new byte[12], new byte[12]]);
        Assert.Throws<FormatException>(() => TwainRaster.DecodeBitmap(full.AsSpan(0, full.Length - 1), out _));
        Assert.Throws<FormatException>(() => TwainRaster.DecodeBitmap(new byte[10], out _));
        byte[] rle = Bitmap(1, 1, 8, [[0]], palette: [[0, 0, 0]], compression: 1);
        Assert.Throws<FormatException>(() => TwainRaster.DecodeBitmap(rle, out _));
        byte[] oddMasks = Bitmap(1, 1, 32, [[0, 0, 0, 0]], compression: 3, masks: [0xFF, 0xFF00, 0xFF0000]);
        Assert.Throws<FormatException>(() => TwainRaster.DecodeBitmap(oddMasks, out _));
        byte[] huge = Bitmap(1, 1, 24, [new byte[3]]);
        BinaryPrimitives.WriteInt32LittleEndian(huge.AsSpan(4), 1_000_000);
        BinaryPrimitives.WriteInt32LittleEndian(huge.AsSpan(8), 1_000_000);
        Assert.Throws<FormatException>(() => TwainRaster.DecodeBitmap(huge, out _));
    }

    private static readonly uint[] StandardMasks = [0x00FF0000, 0x0000FF00, 0x000000FF];

    [Fact]
    public void Bitmap32_BitFields_WithAFileHeaderWhoseOffsetLeavesOutTheMasks()
    {
        // NTwain's file header for a native transfer puts the pixels at 14 + 40: the masks
        // would be read as the first three pixels and every row would shift.
        byte[] data = Bitmap(4, 2, 32, [[1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0],
                                        [13, 14, 15, 0, 16, 17, 18, 0, 19, 20, 21, 0, 22, 23, 24, 0]],
                             fileHeader: true, compression: 3, masks: StandardMasks);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(10), 14 + 40);
        var image = TwainRaster.DecodeBitmap(data, out _);
        Assert.Equal((3, 2, 1, 255), Pixel(image, 0, 0));
        Assert.Equal((12, 11, 10, 255), Pixel(image, 3, 0));
        Assert.Equal((15, 14, 13, 255), Pixel(image, 0, 1));
        Assert.Equal((24, 23, 22, 255), Pixel(image, 3, 1));
    }

    [Fact]
    public void Bitmap_FileHeaderOffsetPastTheColorTable_IsUsed()
    {
        // A writer may leave a gap before the pixels.
        byte[] plain = Bitmap(1, 1, 24, [[3, 2, 1]], fileHeader: true);
        var gapped = new byte[plain.Length + 4];
        plain.AsSpan(0, 54).CopyTo(gapped);
        plain.AsSpan(54).CopyTo(gapped.AsSpan(58));
        BinaryPrimitives.WriteInt32LittleEndian(gapped.AsSpan(10), 58);
        Assert.Equal((1, 2, 3, 255), Pixel(TwainRaster.DecodeBitmap(gapped, out _), 0, 0));
    }

    /// <summary>A 1 × 1 32-bit bit-field bitmap with a 124-byte V5 header (the masks inside it), no file header.</summary>
    private static byte[] V5Bitmap(byte blue, byte green, byte red)
    {
        var data = new byte[124 + 4];
        BinaryPrimitives.WriteInt32LittleEndian(data, 124);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(4), 1);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(8), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(12), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(14), 32);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(16), 3);
        for (int i = 0; i < 3; i++) BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(40 + i * 4), StandardMasks[i]);
        data[124] = blue;
        data[125] = green;
        data[126] = red;
        return data;
    }

    [Fact]
    public void Bitmap32_V5Header_IsRead()
    {
        Assert.Equal((30, 20, 10, 255), Pixel(TwainRaster.DecodeBitmap(V5Bitmap(10, 20, 30), out _), 0, 0));
    }

    [Fact]
    public void BitmapLength_CountsHeaderMasksColorTableAndPaddedRows()
    {
        // From the header alone, so a native transfer is copied whole even when biSizeImage is 0.
        byte[] rgb = Bitmap(2, 3, 24, [new byte[6], new byte[6], new byte[6]]);
        Assert.Equal(40 + 8 * 3, TwainRaster.BitmapLength(rgb.AsSpan(0, 40)));
        byte[] gray = Bitmap(5, 2, 8, [new byte[5], new byte[5]], palette: [[0, 0, 0], [255, 255, 255]]);
        Assert.Equal(40 + 2 * 4 + 8 * 2, TwainRaster.BitmapLength(gray.AsSpan(0, 40)));
        byte[] grayFullTable = Bitmap(5, 2, 8, [new byte[5], new byte[5]]);
        Assert.Equal(40 + 256 * 4 + 8 * 2, TwainRaster.BitmapLength(grayFullTable.AsSpan(0, 40)));
        byte[] fields = Bitmap(3, 1, 32, [new byte[12]], compression: 3, masks: StandardMasks);
        Assert.Equal(40 + 12 + 12, TwainRaster.BitmapLength(fields.AsSpan(0, 40)));
        Assert.Equal(124 + 4, TwainRaster.BitmapLength(V5Bitmap(0, 0, 0).AsSpan(0, 40)));
        // Each of these lengths is exactly what the decoder needs.
        Assert.Equal(rgb.Length, TwainRaster.BitmapLength(rgb));
        Assert.Equal(fields.Length, TwainRaster.BitmapLength(fields));

        Assert.Throws<FormatException>(() => TwainRaster.BitmapLength(new byte[39]));
        byte[] rle = Bitmap(1, 1, 8, [[0]], palette: [[0, 0, 0]], compression: 1);
        Assert.Throws<FormatException>(() => TwainRaster.BitmapLength(rle));
        byte[] badHeader = (byte[])rgb.Clone();
        BinaryPrimitives.WriteInt32LittleEndian(badHeader, 12);
        Assert.Throws<FormatException>(() => TwainRaster.BitmapLength(badHeader));
    }

    [Fact]
    public void Bitmap24And32_WithAnOptionalColorTable_SkipTheTable()
    {
        // biClrUsed > 0 on a 24 or 32-bit bitmap: a table the pixels follow, not a palette to decode with.
        var table = Enumerable.Range(0, 256).Select(i => new[] { (byte)i, (byte)(255 - i), (byte)7 }).ToArray();
        byte[][] rows = [[3, 2, 1, 6, 5, 4], [9, 8, 7, 12, 11, 10]];
        byte[] rgb = Bitmap(2, 2, 24, rows, palette: table);
        Assert.Equal(40 + 256 * 4 + 8 * 2, TwainRaster.BitmapLength(rgb.AsSpan(0, 40)));
        Assert.Equal(rgb.Length, TwainRaster.BitmapLength(rgb));
        foreach (var data in new[] { rgb, Bitmap(2, 2, 24, rows, palette: table, fileHeader: true) })
        {
            var image = TwainRaster.DecodeBitmap(data, out _);
            Assert.Equal((1, 2, 3, 255), Pixel(image, 0, 0));
            Assert.Equal((4, 5, 6, 255), Pixel(image, 1, 0));
            Assert.Equal((7, 8, 9, 255), Pixel(image, 0, 1));
            Assert.Equal((10, 11, 12, 255), Pixel(image, 1, 1));
        }
        // The pixels need the whole table in front of them: one byte short is refused, not shifted.
        Assert.Throws<FormatException>(() => TwainRaster.DecodeBitmap(rgb.AsSpan(0, rgb.Length - 1), out _));

        byte[] fields = Bitmap(1, 1, 32, [[3, 2, 1, 0]], palette: table[..3], compression: 3, masks: StandardMasks);
        Assert.Equal(40 + 12 + 3 * 4 + 4, TwainRaster.BitmapLength(fields.AsSpan(0, 40)));
        Assert.Equal((1, 2, 3, 255), Pixel(TwainRaster.DecodeBitmap(fields, out _), 0, 0));
        byte[] plain = Bitmap(1, 1, 32, [[3, 2, 1, 0]], palette: table[..5]);
        Assert.Equal(40 + 5 * 4 + 4, TwainRaster.BitmapLength(plain.AsSpan(0, 40)));
        Assert.Equal((1, 2, 3, 255), Pixel(TwainRaster.DecodeBitmap(plain, out _), 0, 0));
    }
}
