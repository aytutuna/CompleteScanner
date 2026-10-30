using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Port of Tests/LazyScanTests/ImagePipelineTests.swift.

public class ImagePipelineTests
{
    // MARK: - Helpers

    /// <summary>Deterministic RGB gradient: r ramps with x, g with y, b with x+y.</summary>
    private static RgbaImage MakeGradientImage(int width = 64, int height = 64)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                pixels[i] = (byte)(x * 255 / (width - 1));
                pixels[i + 1] = (byte)(y * 255 / (height - 1));
                pixels[i + 2] = (byte)((x + y) * 255 / (width + height - 2));
                pixels[i + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>Mid-gray image with a 3x3 red marker in the top-left corner (pixel coordinates).</summary>
    private static RgbaImage MakeMarkerImage(int width, int height)
    {
        var image = RgbaImage.Filled(width, height, 128, 128, 128);
        for (int y = 0; y < 3; y++)
        {
            for (int x = 0; x < 3; x++)
            {
                int i = (y * width + x) * 4;
                image.Pixels[i] = 255;
                image.Pixels[i + 1] = 0;
                image.Pixels[i + 2] = 0;
            }
        }
        return image;
    }

    private static (int R, int G, int B) Pixel(RgbaImage image, int x, int y)
    {
        int i = (y * image.Width + x) * 4;
        return (image.Pixels[i], image.Pixels[i + 1], image.Pixels[i + 2]);
    }

    /// <summary>Mean and standard deviation of Rec.601 luminance over all pixels (0...255 scale).</summary>
    private static (double Mean, double StdDev) LuminanceStats(RgbaImage image)
    {
        int count = image.Width * image.Height;
        var values = new double[count];
        for (int i = 0; i < count; i++)
        {
            values[i] = 0.299 * image.Pixels[i * 4] + 0.587 * image.Pixels[i * 4 + 1]
                      + 0.114 * image.Pixels[i * 4 + 2];
        }
        double mean = values.Average();
        double variance = values.Sum(v => (v - mean) * (v - mean)) / count;
        return (mean, Math.Sqrt(variance));
    }

    // MARK: - Tests

    [Fact]
    public void BrightnessRaisesMeanLuminance()
    {
        var input = MakeGradientImage();
        var settings = new AdjustmentSettings { Brightness = 0.5 };
        var output = ImagePipeline.Apply(settings, input, ColorMode.Color);
        Assert.Equal(input.Width, output.Width);
        Assert.Equal(input.Height, output.Height);
        Assert.True(LuminanceStats(output).Mean > LuminanceStats(input).Mean + 10,
                    "brightness +0.5 must raise mean luminance");
    }

    [Fact]
    public void ContrastRaisesStdDev()
    {
        var input = MakeGradientImage();
        var settings = new AdjustmentSettings { Contrast = 2.0 };
        var output = ImagePipeline.Apply(settings, input, ColorMode.Color);
        Assert.True(LuminanceStats(output).StdDev > LuminanceStats(input).StdDev * 1.2,
                    "contrast 2.0 must widen the luminance distribution");
    }

    [Fact]
    public void IdentityReturnsUnchangedPixels()
    {
        var input = MakeGradientImage();
        var output = ImagePipeline.Apply(new AdjustmentSettings(), input, ColorMode.Color);
        if (ReferenceEquals(output, input)) return; // returning the same instance is explicitly allowed
        Assert.Equal(input.Width, output.Width);
        Assert.Equal(input.Height, output.Height);
        Assert.Equal(input.Pixels, output.Pixels);
    }

    [Fact]
    public void GrayscaleMakesChannelsEqual()
    {
        var input = MakeGradientImage();
        var output = ImagePipeline.Apply(new AdjustmentSettings(), input, ColorMode.Grayscale);
        int maxDelta = 0;
        for (int i = 0; i < output.Pixels.Length; i += 4)
        {
            int r = output.Pixels[i], g = output.Pixels[i + 1], b = output.Pixels[i + 2];
            maxDelta = Math.Max(maxDelta, Math.Max(Math.Abs(r - g), Math.Max(Math.Abs(g - b), Math.Abs(r - b))));
        }
        Assert.True(maxDelta <= 2, $"grayscale output must have r==g==b (±2), max delta {maxDelta}");
    }

    [Fact]
    public void BlackWhiteBinarizes()
    {
        var input = MakeGradientImage();
        var output = ImagePipeline.Apply(new AdjustmentSettings(), input, ColorMode.BlackWhite);
        int maxMidDistance = 0;
        for (int i = 0; i < output.Pixels.Length; i += 4)
        {
            for (int c = 0; c < 3; c++)
            {
                int v = output.Pixels[i + c];
                maxMidDistance = Math.Max(maxMidDistance, Math.Min(v, 255 - v));
            }
        }
        Assert.True(maxMidDistance <= 6, $"blackWhite output must be ~0 or ~255 everywhere, got {maxMidDistance}");
    }

    [Fact]
    public void RotateOneQuarterTurnClockwise()
    {
        var input = MakeMarkerImage(64, 32);
        var output = ImagePipeline.Rotate(input, 1);
        Assert.Equal(32, output.Width);
        Assert.Equal(64, output.Height);

        // Clockwise: source top-left lands at the destination's top-right.
        // Probe (width-2, 1), which maps back to source (1, 1) inside the red marker.
        var probe = Pixel(output, output.Width - 2, 1);
        Assert.True(probe.R > 200, $"expected the red marker at the top-right; got {probe}");
        Assert.True(probe.G < 80, $"expected the red marker at the top-right; got {probe}");
        Assert.True(probe.B < 80, $"expected the red marker at the top-right; got {probe}");
    }

    [Fact]
    public void RotateZeroKeepsDimensions()
    {
        var input = MakeGradientImage(64, 32);
        var output = ImagePipeline.Rotate(input, 0);
        Assert.Equal(64, output.Width);
        Assert.Equal(32, output.Height);
    }

    // MARK: - Negative sharpness = soften (Windows-side; the Swift suite has no soften test)

    /// <summary>8x8-pixel black/white checkerboard: maximal local contrast.</summary>
    private static RgbaImage MakeCheckerboard(int width = 64, int height = 64)
    {
        var image = RgbaImage.Filled(width, height, 0, 0, 0);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                if (((x / 8) + (y / 8)) % 2 == 0) continue;
                int i = (y * width + x) * 4;
                image.Pixels[i] = 255;
                image.Pixels[i + 1] = 255;
                image.Pixels[i + 2] = 255;
            }
        }
        return image;
    }

    private static RgbaImage Soften(RgbaImage input, double sharpness) =>
        ImagePipeline.Apply(new AdjustmentSettings { Sharpness = sharpness }, input, ColorMode.Color);

    [Fact]
    public void SoftenReducesEdgeContrast()
    {
        var input = MakeCheckerboard();
        var output = Soften(input, -1);
        Assert.Equal(input.Width, output.Width);
        Assert.Equal(input.Height, output.Height);
        double before = LuminanceStats(input).StdDev;
        double after = LuminanceStats(output).StdDev;
        Assert.True(after < before * 0.8, $"softening must reduce contrast: stddev {before:F1} -> {after:F1}");
        // Pixels at a block edge move toward the middle.
        var edge = Pixel(output, 7, 3);   // white/black boundary at x = 8
        Assert.InRange(edge.R, 20, 235);
    }

    [Fact]
    public void SoftenZeroIsIdentity()
    {
        var input = MakeCheckerboard();
        var output = Soften(input, 0);
        Assert.Equal(input.Pixels, output.Pixels);
    }

    [Fact]
    public void SoftenIsMonotonicInMagnitudeAndClampsAtTwo()
    {
        var input = MakeCheckerboard();
        double[] stdDevs = [.. new[] { -0.25, -0.5, -1.0, -2.0 }.Select(s => LuminanceStats(Soften(input, s)).StdDev)];
        for (int i = 1; i < stdDevs.Length; i++)
        {
            Assert.True(stdDevs[i] < stdDevs[i - 1],
                        $"stronger softening must blur more: {string.Join(", ", stdDevs.Select(v => v.ToString("F2")))}");
        }
        // The blur radius is min(-s, 2) * 2, so anything below -2 equals -2.
        Assert.Equal(Soften(input, -2).Pixels, Soften(input, -3).Pixels);
    }

    [Fact]
    public void SoftenClampsAtEdgesWithoutDarkening()
    {
        // Edge-clamped blur of a flat image is the image itself — no dark/transparent border.
        var input = RgbaImage.Filled(40, 30, 200, 120, 40);
        var output = Soften(input, -2);
        int maxDelta = 0;
        for (int i = 0; i < output.Pixels.Length; i++)
            maxDelta = Math.Max(maxDelta, Math.Abs(output.Pixels[i] - input.Pixels[i]));
        Assert.True(maxDelta <= 1, $"flat image must stay flat under the blur, max delta {maxDelta}");
    }

    [Fact]
    public void NegativeSharpnessIsNotIdentity()
    {
        Assert.False(new AdjustmentSettings { Sharpness = -0.5 }.IsIdentity);
    }

    [Fact]
    public void VanishinglySmallSofteningLeavesImageUnchanged()
    {
        // A hand-edited settings file can hold a sharpness so close to zero that 2σ²
        // underflows; that must not turn the kernel into NaN (a black page).
        var input = MakeCheckerboard();
        var output = Soften(input, -1e-170);
        Assert.Equal(input.Pixels, output.Pixels);
    }
}
