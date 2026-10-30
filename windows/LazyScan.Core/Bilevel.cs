namespace LazyScan.Core;

// The Mac's twin is Sources/CompleteScannerKit/Pipeline/Bilevel.swift (the same packing); see
// CONTRACTS.md, "CCITT G4 for black & white pages".

/// <summary>
/// Black &amp; white pages as one bit per pixel, the form CCITT G4 (<see cref="CcittG4Encoder"/>)
/// encodes: rows top to bottom, each starting on a byte boundary (<see cref="Stride"/> bytes),
/// pixels left to right from the most significant bit, <b>0 = black, 1 = white</b> (a 1-bit
/// /DeviceGray image with /BlackIs1 false). The bits past the last pixel of a row are 1.
/// </summary>
public static class Bilevel
{
    /// <summary>A pixel whose luma (<see cref="ColorAnalysis.GrayPixels(RgbaImage)"/>) is below this is black.</summary>
    public const int Threshold = 128;

    /// <summary>Bytes per packed row.</summary>
    public static int Stride(int width) => (width + 7) / 8;

    /// <summary>
    /// The page as packed bits: luma (Rec. 601, rounded as in <see cref="ColorAnalysis.GrayPixels(RgbaImage)"/>)
    /// below <see cref="Threshold"/> is black. A page the black &amp; white mode made (every pixel
    /// 0 or 255) keeps every pixel; a downsampled one is thresholded again.
    /// </summary>
    public static byte[] Pack(RgbaImage image) => Pack(image.Pixels, image.Width, image.Height);

    /// <summary><see cref="Pack(RgbaImage)"/> on a raw RGBA8 buffer (row-major, 4 bytes per pixel).</summary>
    public static byte[] Pack(ReadOnlySpan<byte> rgba, int width, int height)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(width);
        ArgumentOutOfRangeException.ThrowIfNegative(height);
        if (rgba.Length < (long)width * height * 4)
            throw new ArgumentException($"Pixel buffer must be {(long)width * height * 4} bytes, got {rgba.Length}.", nameof(rgba));
        int stride = Stride(width);
        var packed = new byte[stride * height];
        packed.AsSpan().Fill(0xFF);
        for (int y = 0; y < height; y++)
        {
            int row = y * stride;
            int i = y * width * 4;
            for (int x = 0; x < width; x++, i += 4)
            {
                // Integer luma (×1000), rounded half up: the weights GrayPixels uses.
                int luma = (299 * rgba[i] + 587 * rgba[i + 1] + 114 * rgba[i + 2] + 500) / 1000;
                if (luma < Threshold) packed[row + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return packed;
    }

    /// <summary>Whether pixel (<paramref name="x"/>, <paramref name="y"/>) of a packed image is black.</summary>
    public static bool IsBlack(ReadOnlySpan<byte> packed, int width, int x, int y) =>
        (packed[y * Stride(width) + (x >> 3)] & (0x80 >> (x & 7))) == 0;

    /// <summary>A packed image as an opaque RGBA image: black (0, 0, 0) and white (255, 255, 255).</summary>
    public static RgbaImage Unpack(ReadOnlySpan<byte> packed, int width, int height)
    {
        int stride = Stride(width);
        if (packed.Length < stride * height)
            throw new ArgumentException($"Packed buffer must be {stride * height} bytes, got {packed.Length}.", nameof(packed));
        var pixels = new byte[width * height * 4];
        for (int y = 0, i = 0; y < height; y++)
        {
            int row = y * stride;
            for (int x = 0; x < width; x++, i += 4)
            {
                byte v = (packed[row + (x >> 3)] & (0x80 >> (x & 7))) == 0 ? (byte)0 : (byte)255;
                pixels[i] = v;
                pixels[i + 1] = v;
                pixels[i + 2] = v;
                pixels[i + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }
}
