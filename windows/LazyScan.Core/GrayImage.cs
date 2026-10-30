namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/GrayImage.swift: same arithmetic, so the same
// pixels give the same bytes on both platforms.

/// <summary>
/// An 8-bit luminance bitmap: row-major, top-left origin, y down, one byte per pixel (0 = black).
/// The page analyses (blank pages, and later page edges, separator sheets and receipts) work on
/// it at a fixed analysis resolution (<see cref="AnalysisDpi"/>), so their pixel constants mean
/// the same physical size on every scan.
/// </summary>
public sealed class GrayImage
{
    /// <summary>The resolution the page analyses work at.</summary>
    public const int AnalysisDpi = 100;

    public int Width { get; }
    public int Height { get; }
    /// <summary>Length = Width * Height.</summary>
    public byte[] Pixels { get; }
    /// <summary>The resolution of these pixels, in dots per inch.</summary>
    public double Dpi { get; }
    /// <summary>
    /// These pixels per pixel of the image they were made from (below 1 when downsampled):
    /// multiply a source coordinate by it to land here, divide to go back.
    /// </summary>
    public double Scale { get; }

    public GrayImage(int width, int height, byte[] pixels, double dpi = AnalysisDpi, double scale = 1)
    {
        if (width <= 0 || height <= 0)
            throw new ArgumentOutOfRangeException(nameof(width), "Image dimensions must be positive.");
        if (pixels.Length != width * height)
            throw new ArgumentException($"Pixel buffer must be {width * height} bytes, got {pixels.Length}.", nameof(pixels));
        Width = width;
        Height = height;
        Pixels = pixels;
        Dpi = dpi;
        Scale = scale;
    }

    /// <summary>A width x height image of one gray value.</summary>
    public static GrayImage Filled(int width, int height, byte value, double dpi = AnalysisDpi)
    {
        var pixels = new byte[width * height];
        Array.Fill(pixels, value);
        return new GrayImage(width, height, pixels, dpi);
    }

    /// <summary>The pixel at (x, y).</summary>
    public byte this[int x, int y] => Pixels[y * Width + x];

    /// <summary>
    /// <paramref name="image"/> as gray at its own size: Rec. 601 luma, rounded
    /// (<see cref="ColorAnalysis.GrayPixels(RgbaImage)"/>).
    /// </summary>
    public static GrayImage Luma(RgbaImage image, double dpi = AnalysisDpi) =>
        new(image.Width, image.Height, ColorAnalysis.GrayPixels(image), dpi);

    /// <summary>
    /// <paramref name="image"/>, scanned at <paramref name="sourceDpi"/>, as gray at
    /// <paramref name="analysisDpi"/>: the luma of every pixel, then a box filter (each gray
    /// pixel is the mean of the pixels it covers). An image no finer than
    /// <paramref name="analysisDpi"/> is kept at its own resolution.
    /// </summary>
    public static GrayImage From(RgbaImage image, int sourceDpi, int analysisDpi = AnalysisDpi)
    {
        var full = Luma(image, Math.Max(1, sourceDpi));
        return full.AtResolution(analysisDpi);
    }

    /// <summary>
    /// This image at <paramref name="dpi"/> (box filter); itself when it is no finer. The
    /// <see cref="Scale"/> of the result maps back to the image this one was made from.
    /// </summary>
    public GrayImage AtResolution(int dpi)
    {
        if (dpi <= 0 || Dpi <= dpi) return this;
        int w = Math.Max(1, (int)Math.Round(Width * dpi / Dpi, MidpointRounding.AwayFromZero));
        int h = Math.Max(1, (int)Math.Round(Height * dpi / Dpi, MidpointRounding.AwayFromZero));
        var small = Downsampled(w, h);
        return new GrayImage(small.Width, small.Height, small.Pixels, dpi, Scale * w / Width);
    }

    /// <summary>
    /// A smaller copy: each pixel is the mean (rounded down) of the source rectangle it covers,
    /// the same box filter as <see cref="RgbaImage.Resized"/>. Sizes not smaller than this one
    /// on both axes return this image.
    /// </summary>
    public GrayImage Downsampled(int newWidth, int newHeight)
    {
        if (newWidth <= 0 || newHeight <= 0)
            throw new ArgumentOutOfRangeException(nameof(newWidth), "Target dimensions must be positive.");
        if (newWidth >= Width && newHeight >= Height) return this;
        newWidth = Math.Min(newWidth, Width);
        newHeight = Math.Min(newHeight, Height);

        var output = new byte[newWidth * newHeight];
        double xRatio = (double)Width / newWidth;
        double yRatio = (double)Height / newHeight;
        // The source columns of each destination column, worked out once.
        var x0s = new int[newWidth];
        var x1s = new int[newWidth];
        for (int dx = 0; dx < newWidth; dx++)
        {
            x0s[dx] = (int)(dx * xRatio);
            x1s[dx] = Math.Max(x0s[dx] + 1, Math.Min(Width, (int)Math.Ceiling((dx + 1) * xRatio)));
        }
        for (int dy = 0; dy < newHeight; dy++)
        {
            int sy0 = (int)(dy * yRatio);
            int sy1 = Math.Max(sy0 + 1, Math.Min(Height, (int)Math.Ceiling((dy + 1) * yRatio)));
            for (int dx = 0; dx < newWidth; dx++)
            {
                int sx0 = x0s[dx], sx1 = x1s[dx];
                long sum = 0;
                for (int sy = sy0; sy < sy1; sy++)
                {
                    int row = sy * Width;
                    for (int sx = sx0; sx < sx1; sx++) sum += Pixels[row + sx];
                }
                long count = (long)(sy1 - sy0) * (sx1 - sx0);
                output[dy * newWidth + dx] = (byte)(sum / count);
            }
        }
        return new GrayImage(newWidth, newHeight, output, Dpi * newWidth / Width, Scale * newWidth / Width);
    }

    /// <summary>The image as opaque RGBA (R = G = B = the gray value), for display and saving.</summary>
    public RgbaImage ToRgba()
    {
        var rgba = new byte[Width * Height * 4];
        for (int p = 0, i = 0; p < Pixels.Length; p++, i += 4)
        {
            rgba[i] = Pixels[p];
            rgba[i + 1] = Pixels[p];
            rgba[i + 2] = Pixels[p];
            rgba[i + 3] = 255;
        }
        return new RgbaImage(Width, Height, rgba);
    }
}
