using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/RgbaImageTests.swift: the Swift RgbaImage is a port of this
// type, and both must give these exact bytes.

public class RgbaImageTests
{
    /// <summary>An image whose red channel holds the given values, green and blue 0, opaque.</summary>
    private static RgbaImage Reds(int width, int height, params byte[] reds)
    {
        var pixels = new byte[width * height * 4];
        for (int i = 0; i < reds.Length; i++)
        {
            pixels[i * 4] = reds[i];
            pixels[i * 4 + 3] = 255;
        }
        return new RgbaImage(width, height, pixels);
    }

    private static byte[] RedsOf(RgbaImage image) =>
        Enumerable.Range(0, image.Width * image.Height).Select(i => image.Pixels[i * 4]).ToArray();

    [Fact]
    public void Filled_IsOpaqueAndOneColor()
    {
        var image = RgbaImage.Filled(2, 1, 10, 20, 30);
        Assert.Equal(new byte[] { 10, 20, 30, 255, 10, 20, 30, 255 }, image.Pixels);
    }

    [Fact]
    public void Constructor_RejectsWrongSizes()
    {
        Assert.Throws<ArgumentException>(() => new RgbaImage(2, 2, new byte[15]));
        Assert.Throws<ArgumentOutOfRangeException>(() => new RgbaImage(0, 2, []));
    }

    [Fact]
    public void Resized_Minifying_AveragesTheCoveredPixels_RoundingDown()
    {
        // 4 × 2 → 2 × 1: each output pixel is the mean of a 2 × 2 block.
        var image = Reds(4, 2, 0, 10, 20, 31, 40, 50, 60, 70);
        Assert.Equal(new byte[] { 25, 45 }, RedsOf(image.Resized(2, 1)));
        // 3 × 1 → 2 × 1: the blocks overlap (columns 0–1 and 1–2).
        Assert.Equal(new byte[] { 15, 30 }, RedsOf(Reds(3, 1, 10, 20, 40).Resized(2, 1)));
        // Alpha is averaged too.
        Assert.Equal(255, image.Resized(2, 1).Pixels[3]);
    }

    [Fact]
    public void Resized_Magnifying_IsBilinear_WithWhiteOutside_AndRoundsHalfToEven()
    {
        // 2 × 1 → 4 × 1: samples at x = -0.25, 0.25, 0.75, 1.25.
        var pixels = new byte[] { 0, 10, 0, 255, 2, 20, 0, 255 };
        var image = new RgbaImage(2, 1, pixels).Resized(4, 1);
        Assert.Equal(new byte[] { 64, 0, 2, 65 }, RedsOf(image));          // 0.5 → 0, 1.5 → 2
        Assert.Equal(new byte[] { 71, 12, 18, 79 },
                     Enumerable.Range(0, 4).Select(i => image.Pixels[i * 4 + 1]).ToArray()); // 12.5 → 12, 17.5 → 18
        Assert.Equal(new byte[] { 64, 0, 0, 64 },
                     Enumerable.Range(0, 4).Select(i => image.Pixels[i * 4 + 2]).ToArray());
    }

    [Fact]
    public void Resized_SameSize_IsTheSameImage()
    {
        var image = Reds(2, 2, 1, 2, 3, 4);
        Assert.Same(image, image.Resized(2, 2));
    }

    [Fact]
    public void RotatedQuarterTurns_TurnsClockwise()
    {
        // 2 wide × 3 tall:  0 1 / 2 3 / 4 5
        var image = Reds(2, 3, 0, 1, 2, 3, 4, 5);
        var once = image.RotatedQuarterTurns(1);
        Assert.Equal((3, 2), (once.Width, once.Height));
        Assert.Equal(new byte[] { 4, 2, 0, 5, 3, 1 }, RedsOf(once));
        Assert.Equal(new byte[] { 5, 4, 3, 2, 1, 0 }, RedsOf(image.RotatedQuarterTurns(2)));
        Assert.Equal(new byte[] { 1, 3, 5, 0, 2, 4 }, RedsOf(image.RotatedQuarterTurns(3)));
        Assert.Equal(RedsOf(image.RotatedQuarterTurns(3)), RedsOf(image.RotatedQuarterTurns(-1)));
        Assert.Same(image, image.RotatedQuarterTurns(4));
    }

    [Fact]
    public void Cropped_ClampsToTheImage_AndRoundsOutward()
    {
        var image = Reds(3, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8);
        Assert.Equal(new byte[] { 4, 5, 7, 8 }, RedsOf(image.Cropped(new RectD(1, 1, 2, 2))!));
        Assert.Equal(new byte[] { 0, 1, 3, 4 }, RedsOf(image.Cropped(new RectD(0.5, 0.5, 1, 1))!));
        Assert.Equal(new byte[] { 8 }, RedsOf(image.Cropped(new RectD(2, 2, 5, 5))!));
        Assert.Null(image.Cropped(new RectD(3, 0, 2, 2)));
    }

    [Fact]
    public void ExtractRotated_UprightRegion_CopiesThePixels()
    {
        var image = Reds(3, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8);
        var same = image.ExtractRotated(new PointD(1.5, 1.5), new SizeD(3, 3), 0)!;
        Assert.Equal(image.Pixels, same.Pixels);
        // A region a quarter turn clockwise comes out turned back: the image a quarter turn counterclockwise.
        var turned = image.ExtractRotated(new PointD(1.5, 1.5), new SizeD(3, 3), 90)!;
        Assert.Equal(RedsOf(image.RotatedQuarterTurns(3)), RedsOf(turned));
        // Outside the image: the fill color.
        var outside = image.ExtractRotated(new PointD(10, 10), new SizeD(1, 1), 0, 7, 8, 9)!;
        Assert.Equal(new byte[] { 7, 8, 9, 255 }, outside.Pixels);
        Assert.Null(image.ExtractRotated(new PointD(1, 1), new SizeD(0.4, 2), 0));
    }

    [Fact]
    public void Clone_IsIndependent()
    {
        var image = Reds(1, 1, 9);
        var copy = image.Clone();
        copy.Pixels[0] = 1;
        Assert.Equal(9, image.Pixels[0]);
    }
}
