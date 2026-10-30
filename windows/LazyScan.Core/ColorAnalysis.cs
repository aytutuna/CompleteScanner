namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/ColorAnalysis.swift: same constants, same
// sampling, same luma weights.

/// <summary>Color facts about a page, used to store pages scanned in color as gray when they have no color.</summary>
public static class ColorAnalysis
{
    /// <summary>Every <c>SampleStep</c>-th pixel of every <c>SampleStep</c>-th row is looked at.</summary>
    public const int SampleStep = 4;

    /// <summary>A sample is colored when max(R, G, B) − min(R, G, B) is above this.</summary>
    public const int ChromaThreshold = 32;

    /// <summary>
    /// The page is gray when fewer than this share of the samples are colored. The limit is
    /// low on purpose, so a small stamp, signature in blue ink or highlighter mark keeps the
    /// page in color.
    /// </summary>
    public const double MaxColoredFraction = 0.001;

    /// <summary>
    /// True when the page has (next to) no color: a document scanned in color that would look
    /// the same stored in gray. The scanner's slight tint on white paper (chroma up to
    /// <see cref="ChromaThreshold"/>) does not count as color.
    /// </summary>
    public static bool IsEffectivelyGray(RgbaImage image) =>
        IsEffectivelyGray(image.Pixels, image.Width, image.Height);

    /// <summary><see cref="IsEffectivelyGray(RgbaImage)"/> on a raw RGBA8 buffer (row-major, 4 bytes per pixel).</summary>
    public static bool IsEffectivelyGray(ReadOnlySpan<byte> rgba, int width, int height)
    {
        long samples = 0, colored = 0;
        for (int y = 0; y < height; y += SampleStep)
        {
            int row = y * width * 4;
            for (int x = 0; x < width; x += SampleStep)
            {
                int i = row + x * 4;
                int r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
                int chroma = Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b));
                samples++;
                if (chroma > ChromaThreshold) colored++;
            }
        }
        return samples > 0 && colored < MaxColoredFraction * samples;
    }

    /// <summary>
    /// The page as 8-bit gray (one byte per pixel, row-major): Rec. 601 luma
    /// 0.299 R + 0.587 G + 0.114 B, rounded — the weights the image pipeline uses.
    /// </summary>
    public static byte[] GrayPixels(RgbaImage image) => GrayPixels(image.Pixels, image.Width, image.Height);

    /// <summary><see cref="GrayPixels(RgbaImage)"/> on a raw RGBA8 buffer.</summary>
    public static byte[] GrayPixels(ReadOnlySpan<byte> rgba, int width, int height)
    {
        var gray = new byte[width * height];
        for (int p = 0, i = 0; p < gray.Length; p++, i += 4)
        {
            // Integer form of the luma weights (×1000), rounded half up.
            int y = (299 * rgba[i] + 587 * rgba[i + 1] + 114 * rgba[i + 2] + 500) / 1000;
            gray[p] = (byte)Math.Min(255, y);
        }
        return gray;
    }
}
