using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/ColorAnalysisTests.swift: the same pages, the same answers.

public class ColorAnalysisTests
{
    /// <summary>A 400 × 400 page (100 × 100 = 10 000 samples) of one color.</summary>
    private static RgbaImage Page(byte r, byte g, byte b) => RgbaImage.Filled(400, 400, r, g, b);

    private static void Paint(RgbaImage image, int x, int y, byte r, byte g, byte b)
    {
        int i = (y * image.Width + x) * 4;
        image.Pixels[i] = r;
        image.Pixels[i + 1] = g;
        image.Pixels[i + 2] = b;
    }

    /// <summary>Red on the first <paramref name="count"/> sampled pixels (every 4th pixel of every 4th row).</summary>
    private static RgbaImage WithRedSamples(int count)
    {
        var image = Page(250, 250, 250);
        for (int n = 0; n < count; n++)
        {
            Paint(image, n % 100 * ColorAnalysis.SampleStep, n / 100 * ColorAnalysis.SampleStep, 220, 30, 30);
        }
        return image;
    }

    [Fact]
    public void PureGrayPages_AreGray()
    {
        Assert.True(ColorAnalysis.IsEffectivelyGray(Page(255, 255, 255)));
        Assert.True(ColorAnalysis.IsEffectivelyGray(Page(0, 0, 0)));
        var ramp = Page(0, 0, 0);
        for (int y = 0; y < ramp.Height; y++)
        {
            for (int x = 0; x < ramp.Width; x++)
            {
                byte v = (byte)(x * 255 / (ramp.Width - 1));
                Paint(ramp, x, y, v, v, v);
            }
        }
        Assert.True(ColorAnalysis.IsEffectivelyGray(ramp));
    }

    [Fact]
    public void ScannerTintOnWhitePaper_IsStillGray()
    {
        // Warm paper: chroma 30, under the threshold of 32.
        Assert.True(ColorAnalysis.IsEffectivelyGray(Page(250, 240, 220)));
        Assert.False(ColorAnalysis.IsEffectivelyGray(Page(250, 240, 217))); // chroma 33
    }

    [Fact]
    public void AFewColoredSamples_StayGray_OnePercentIsColor()
    {
        Assert.True(ColorAnalysis.IsEffectivelyGray(WithRedSamples(5)));   // 0.05 %
        Assert.True(ColorAnalysis.IsEffectivelyGray(WithRedSamples(9)));   // 0.09 %
        Assert.False(ColorAnalysis.IsEffectivelyGray(WithRedSamples(10))); // 0.1 %
        Assert.False(ColorAnalysis.IsEffectivelyGray(WithRedSamples(100))); // 1 %
    }

    [Fact]
    public void AColoredBlock_IsColor_OffGridPixelsAreNotSampled()
    {
        // A 40 × 40 stamp: 1 % of the page.
        var stamp = Page(255, 255, 255);
        for (int y = 100; y < 140; y++)
        {
            for (int x = 200; x < 240; x++) Paint(stamp, x, y, 30, 60, 200);
        }
        Assert.False(ColorAnalysis.IsEffectivelyGray(stamp));

        // Color only between the sampled rows and columns is never looked at.
        var offGrid = Page(255, 255, 255);
        for (int y = 1; y < offGrid.Height; y += ColorAnalysis.SampleStep)
        {
            for (int x = 1; x < offGrid.Width; x += ColorAnalysis.SampleStep) Paint(offGrid, x, y, 255, 0, 0);
        }
        Assert.True(ColorAnalysis.IsEffectivelyGray(offGrid));
    }

    [Fact]
    public void TinyAndOddSizedPages()
    {
        Assert.True(ColorAnalysis.IsEffectivelyGray(RgbaImage.Filled(1, 1, 128, 128, 128)));
        Assert.False(ColorAnalysis.IsEffectivelyGray(RgbaImage.Filled(1, 1, 255, 0, 0)));
        var odd = RgbaImage.Filled(7, 5, 200, 200, 200);
        Paint(odd, 4, 4, 0, 0, 255); // sampled: (0|4, 0|4)
        Assert.False(ColorAnalysis.IsEffectivelyGray(odd));
    }

    [Fact]
    public void GrayPixels_UseRec601Luma()
    {
        var image = RgbaImage.Filled(6, 1, 0, 0, 0);
        Paint(image, 0, 0, 255, 0, 0);
        Paint(image, 1, 0, 0, 255, 0);
        Paint(image, 2, 0, 0, 0, 255);
        Paint(image, 3, 0, 255, 255, 255);
        Paint(image, 4, 0, 10, 20, 30);
        Paint(image, 5, 0, 128, 128, 128);
        Assert.Equal(new byte[] { 76, 150, 29, 255, 18, 128 }, ColorAnalysis.GrayPixels(image));
    }
}
