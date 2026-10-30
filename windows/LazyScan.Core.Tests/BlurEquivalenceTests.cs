using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Equivalence tests for the optimized blur kernels in ImagePipeline: each one must produce
// exactly the same doubles as the straightforward implementation it replaced (kept below,
// verbatim, as the reference).

public class BlurEquivalenceTests
{
    // MARK: - Reference implementations (the original single-threaded, clamp-per-tap code)

    private static void ReferenceGaussianBlur(double[] channel, int w, int h, double sigma)
    {
        if (sigma <= 0) return;
        int k = Math.Max(1, (int)Math.Ceiling(3 * sigma));
        var kernel = new double[2 * k + 1];
        double sum = 0;
        for (int i = -k; i <= k; i++)
        {
            kernel[i + k] = Math.Exp(-(i * i) / (2 * sigma * sigma));
            sum += kernel[i + k];
        }
        for (int i = 0; i < kernel.Length; i++) kernel[i] /= sum;

        var tmp = new double[channel.Length];
        // Horizontal.
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                double acc = 0;
                for (int i = -k; i <= k; i++)
                    acc += kernel[i + k] * channel[row + Math.Clamp(x + i, 0, w - 1)];
                tmp[row + x] = acc;
            }
        }
        // Vertical.
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                double acc = 0;
                for (int i = -k; i <= k; i++)
                    acc += kernel[i + k] * tmp[Math.Clamp(y + i, 0, h - 1) * w + x];
                channel[y * w + x] = acc;
            }
        }
    }

    private static void ReferenceBlurPass(double[] channel, int w, int h)
    {
        var tmp = new double[channel.Length];
        // Horizontal.
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                double left = channel[row + Math.Max(0, x - 1)];
                double mid = channel[row + x];
                double right = channel[row + Math.Min(w - 1, x + 1)];
                tmp[row + x] = (left + 2 * mid + right) / 4;
            }
        }
        // Vertical.
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                double up = tmp[Math.Max(0, y - 1) * w + x];
                double mid = tmp[y * w + x];
                double down = tmp[Math.Min(h - 1, y + 1) * w + x];
                channel[y * w + x] = (up + 2 * mid + down) / 4;
            }
        }
    }

    // MARK: - Helpers

    /// <summary>Deterministic pseudo-random channel, including values outside 0...1.</summary>
    private static double[] NoiseChannel(int w, int h, uint seed)
    {
        var channel = new double[w * h];
        for (int i = 0; i < channel.Length; i++)
        {
            seed = seed * 1664525 + 1013904223;
            channel[i] = (seed >> 8) / (double)(1 << 24) * 1.4 - 0.2;
        }
        return channel;
    }

    private static void AssertBitIdentical(double[] expected, double[] actual, string context)
    {
        Assert.Equal(expected.Length, actual.Length);
        for (int i = 0; i < expected.Length; i++)
        {
            if (BitConverter.DoubleToInt64Bits(expected[i]) != BitConverter.DoubleToInt64Bits(actual[i]))
                Assert.Fail($"{context}: index {i} differs: expected {expected[i]:R}, got {actual[i]:R}");
        }
    }

    public static TheoryData<int, int> Sizes => new()
    {
        { 1, 1 }, { 3, 5 }, { 5, 3 }, { 1, 40 }, { 40, 1 }, { 2, 2 },
        { 24, 25 }, { 64, 48 }, { 257, 131 }, { 600, 500 },
    };

    // MARK: - Tests

    [Theory]
    [MemberData(nameof(Sizes))]
    public void GaussianBlurMatchesReferenceBitForBit(int w, int h)
    {
        foreach (double sigma in new[] { 1e-4, 0.3, 0.5, 1.0, 1.7, 2.5, 4.0 })
        {
            var expected = NoiseChannel(w, h, (uint)(w * 31 + h));
            var actual = (double[])expected.Clone();
            ReferenceGaussianBlur(expected, w, h, sigma);
            ImagePipeline.GaussianBlur(actual, w, h, sigma);
            AssertBitIdentical(expected, actual, $"{w}x{h} sigma {sigma}");
        }
    }

    [Theory]
    [MemberData(nameof(Sizes))]
    public void GaussianBlurWithSharedScratchMatchesReference(int w, int h)
    {
        // One scratch buffer reused across channels (and deliberately dirty) must not leak
        // state from one channel into the next.
        var scratch = new double[w * h];
        Array.Fill(scratch, double.NaN);
        for (uint channelIndex = 0; channelIndex < 3; channelIndex++)
        {
            var expected = NoiseChannel(w, h, 7 + channelIndex);
            var actual = (double[])expected.Clone();
            ReferenceGaussianBlur(expected, w, h, 4.0);
            ImagePipeline.GaussianBlur(actual, w, h, 4.0, scratch);
            AssertBitIdentical(expected, actual, $"{w}x{h} channel {channelIndex}");
        }
    }

    [Theory]
    [MemberData(nameof(Sizes))]
    public void BlurPassMatchesReferenceBitForBit(int w, int h)
    {
        var scratch = new double[w * h];
        Array.Fill(scratch, double.NaN);
        for (uint channelIndex = 0; channelIndex < 3; channelIndex++)
        {
            var expected = NoiseChannel(w, h, 99 + channelIndex);
            var actual = (double[])expected.Clone();
            ReferenceBlurPass(expected, w, h);
            ImagePipeline.BlurPass(actual, w, h, channelIndex == 0 ? null : scratch);
            AssertBitIdentical(expected, actual, $"{w}x{h} channel {channelIndex}");
        }
    }

    [Fact]
    public void GaussianBlurIgnoresSigmasTooSmallToRepresent()
    {
        // 2σ² underflows to zero here; the blur must leave the channel untouched rather
        // than fill it with NaN.
        var channel = NoiseChannel(16, 9, 3);
        var original = (double[])channel.Clone();
        ImagePipeline.GaussianBlur(channel, 16, 9, 2e-170);
        AssertBitIdentical(original, channel, "tiny sigma");
        ImagePipeline.GaussianBlur(channel, 16, 9, double.NaN);
        AssertBitIdentical(original, channel, "NaN sigma");
    }
}
