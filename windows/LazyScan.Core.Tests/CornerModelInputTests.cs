using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/CornerModelInputTests.swift: the same photos and the same expected
// numbers, compared exactly, so both platforms are known to give a corner model the same input.

public class CornerModelInputTests
{
    private const int Plane = CornerModelInput.Side * CornerModelInput.Side;

    /// <summary>A <paramref name="width"/> × <paramref name="height"/> photo whose pixel (x, y) is <paramref name="color"/>(x, y) (red, green, blue), opaque.</summary>
    private static RgbaImage Photo(int width, int height, Func<int, int, (int R, int G, int B)> color)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var (r, g, b) = color(x, y);
                int i = (y * width + x) * 4;
                pixels[i] = (byte)r;
                pixels[i + 1] = (byte)g;
                pixels[i + 2] = (byte)b;
                pixels[i + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>The input's value in <paramref name="channel"/> (0 blue, 1 green, 2 red) at (x, y).</summary>
    private static float Value(float[] input, int channel, int x, int y) => input[channel * Plane + y * CornerModelInput.Side + x];

    [Fact]
    public void TheInputIsBlueGreenAndRedPlanesFromZeroToOne()
    {
        var input = CornerModelInput.Make(RgbaImage.Filled(300, 200, 255, 128, 0));
        Assert.Equal(3 * 256 * 256, input.Length);
        foreach (var (x, y) in new[] { (0, 0), (255, 0), (17, 93), (255, 255) })
        {
            Assert.Equal(0f, Value(input, 0, x, y));
            Assert.Equal((float)(128.0 / 255), Value(input, 1, x, y));
            Assert.Equal(1f, Value(input, 2, x, y));
        }
    }

    [Fact]
    public void HalvingTakesTheMeanOfEachPairOfPixels()
    {
        // 512 wide: input column x reads photo columns 2x and 2x + 1 half and half; 256 high: rows 1 to 1.
        var input = CornerModelInput.Make(Photo(512, 256, (x, y) => (x & 255, y, 0)));
        Assert.Equal((float)(20.5 / 255), Value(input, 2, 10, 7));
        Assert.Equal((float)(254.5 / 255), Value(input, 2, 127, 7));
        Assert.Equal((float)(0.5 / 255), Value(input, 2, 128, 7));
        Assert.Equal((float)(144.5 / 255), Value(input, 2, 200, 7));
        Assert.Equal((float)(7.0 / 255), Value(input, 1, 10, 7));
        Assert.Equal(1f, Value(input, 1, 10, 255));
    }

    [Fact]
    public void EnlargingBlendsTheNearestPixelsAndClampsAtTheEdges()
    {
        // 2 × 2: red 0 on the left and 255 on the right, green 0 at the top and 255 at the bottom.
        var input = CornerModelInput.Make(Photo(2, 2, (x, y) => (255 * x, 255 * y, 0)));
        Assert.Equal(0f, Value(input, 2, 0, 0));
        Assert.Equal(0f, Value(input, 2, 63, 0));
        Assert.Equal((float)(0.99609375 / 255), Value(input, 2, 64, 0));
        Assert.Equal((float)(128.49609375 / 255), Value(input, 2, 128, 0));
        Assert.Equal(1f, Value(input, 2, 255, 0));
        Assert.Equal((float)(128.49609375 / 255), Value(input, 1, 0, 128));
        Assert.Equal(1f, Value(input, 1, 0, 255));
    }

    [Fact]
    public void AnOddSizedPhotoGivesTheSameNumbersOnBothPlatforms()
    {
        var input = CornerModelInput.Make(Photo(300, 200, (x, y) => ((x * 7 + y * 3) & 255, (x * y) & 255, (x + 2 * y) & 255)));
        Assert.Equal(0.00033700981293804944f, input[0]);
        Assert.Equal(0.00493259821087122f, input[1]);
        Assert.Equal(0.16829043626785278f, input[255]);
        Assert.Equal(0.7822610139846802f, input[25637]);
        Assert.Equal(0.4466605484485626f, input[131071]);
        Assert.Equal(0.30775123834609985f, input[163969]);
        double sum = 0;
        foreach (float v in input) sum += v;
        Assert.Equal(96996.50867031487, sum);
    }
}
