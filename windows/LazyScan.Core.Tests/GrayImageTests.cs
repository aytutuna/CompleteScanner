using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/GrayImageTests.swift: GrayImage and BackgroundMap, same
// cases, same bytes.

public class GrayImageTests
{
    [Fact]
    public void From_UsesRoundedRec601Luma()
    {
        var rgba = new byte[] { 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
        var gray = GrayImage.Luma(new RgbaImage(4, 1, rgba));
        Assert.Equal(new byte[] { 76, 150, 29, 255 }, gray.Pixels);
        Assert.Equal((100.0, 1.0), (gray.Dpi, gray.Scale));
    }

    [Fact]
    public void Downsampled_AveragesTheCoveredPixels_RoundingDown()
    {
        var gray = new GrayImage(4, 2, [0, 10, 20, 31, 40, 50, 60, 70], dpi: 200);
        var half = gray.Downsampled(2, 1);
        Assert.Equal(new byte[] { 25, 45 }, half.Pixels);
        Assert.Equal((100.0, 0.5), (half.Dpi, half.Scale));
        Assert.Equal(new byte[] { 15, 30 }, new GrayImage(3, 1, [10, 20, 40]).Downsampled(2, 1).Pixels);
        Assert.Same(gray, gray.Downsampled(4, 2));
        Assert.Same(gray, gray.Downsampled(9, 9));
    }

    [Fact]
    public void Downsampled_MatchesRgbaImageResized()
    {
        var rng = new TestPages.Rng(77);
        var pixels = new byte[37 * 23];
        for (int i = 0; i < pixels.Length; i++) pixels[i] = (byte)rng.Below(256);
        var gray = new GrayImage(37, 23, pixels);
        var rgba = gray.ToRgba();
        foreach (var (w, h) in new[] { (10, 7), (36, 22), (1, 1), (19, 23) })
        {
            Assert.Equal(GrayImage.Luma(rgba.Resized(w, h)).Pixels, gray.Downsampled(w, h).Pixels);
        }
    }

    [Fact]
    public void FromAScan_IsAtTheAnalysisResolution()
    {
        var scan = TestPages.Enlarged(new GrayImage(3, 2, [0, 50, 100, 150, 200, 250]), 3);
        var gray = GrayImage.From(scan, 300);
        Assert.Equal((3, 2, 100.0), (gray.Width, gray.Height, gray.Dpi));
        Assert.Equal(1.0 / 3, gray.Scale, 12);
        Assert.Equal(new byte[] { 0, 50, 100, 150, 200, 250 }, gray.Pixels);
        // No finer than the analysis resolution: kept as it is.
        var coarse = GrayImage.From(scan, 75);
        Assert.Equal((9, 6, 75.0, 1.0), (coarse.Width, coarse.Height, coarse.Dpi, coarse.Scale));
        Assert.Same(coarse, coarse.AtResolution(100));
    }

    [Fact]
    public void Indexer_FilledAndToRgba()
    {
        var gray = GrayImage.Filled(2, 2, 9);
        Assert.Equal(new byte[] { 9, 9, 9, 9 }, gray.Pixels);
        var image = new GrayImage(2, 1, [3, 4]);
        Assert.Equal(4, image[1, 0]);
        Assert.Equal(new byte[] { 3, 3, 3, 255, 4, 4, 4, 255 }, image.ToRgba().Pixels);
        Assert.Throws<ArgumentException>(() => new GrayImage(2, 2, new byte[3]));
    }

    // MARK: - BackgroundMap

    [Fact]
    public void Percentile_IsTheSmallestValueWithEnoughBelowIt()
    {
        var histogram = new int[256];
        for (int v = 0; v < 10; v++) histogram[v] = 1;
        Assert.Equal(8, BackgroundMap.Percentile(histogram, 10, 0.9));
        Assert.Equal(4, BackgroundMap.Percentile(histogram, 10, 0.5));
        Assert.Equal(9, BackgroundMap.Percentile(histogram, 10, 1.0));
        Assert.Equal(0, BackgroundMap.Percentile(histogram, 10, 0));
    }

    [Fact]
    public void Estimate_TilesTheAreaWithWholeTiles()
    {
        // 100 × 50: left half 200, right half 100, with a dark speck in each half.
        var pixels = new byte[100 * 50];
        for (int y = 0; y < 50; y++)
        {
            for (int x = 0; x < 100; x++) pixels[y * 100 + x] = (byte)(x < 50 ? 200 : 100);
        }
        pixels[10 * 100 + 10] = 0;
        pixels[10 * 100 + 60] = 0;
        var gray = new GrayImage(100, 50, pixels);
        var map = BackgroundMap.Estimate(gray, 0, 0, 100, 50, 50)!;
        Assert.Equal((2, 1), (map.Columns, map.Rows));
        Assert.Equal(new byte[] { 200, 100 }, map.Tiles);
        // Tiles of 30 over 100 × 50: three of 33–34 across, one down.
        var odd = BackgroundMap.Estimate(gray, 0, 0, 100, 50, 30)!;
        Assert.Equal((3, 1), (odd.Columns, odd.Rows));
        Assert.Equal(new byte[] { 200, 200, 100 }, odd.Tiles);
        // The area is clamped to the image; an empty one has no map.
        var clamped = BackgroundMap.Estimate(gray, 50, -5, 80, 80, 25)!;
        Assert.Equal((50, 0, 50, 50, 2, 2), (clamped.X, clamped.Y, clamped.Width, clamped.Height, clamped.Columns, clamped.Rows));
        Assert.Null(BackgroundMap.Estimate(gray, 100, 0, 10, 10, 5));
    }

    [Fact]
    public void ValueAt_InterpolatesBetweenTileCenters()
    {
        var pixels = new byte[100 * 50];
        for (int y = 0; y < 50; y++)
        {
            for (int x = 0; x < 100; x++) pixels[y * 100 + x] = (byte)(x < 50 ? 200 : 100);
        }
        var map = BackgroundMap.Estimate(new GrayImage(100, 50, pixels), 0, 0, 100, 50, 50)!;
        Assert.Equal(200, map.ValueAt(0, 0));
        Assert.Equal(200, map.ValueAt(24, 49));
        Assert.Equal(199, map.ValueAt(25, 0), 9);   // center 25.5 is 0.5 px past the first tile's center (25)
        Assert.Equal(151, map.ValueAt(49, 0), 9);
        Assert.Equal(149, map.ValueAt(50, 0), 9);
        Assert.Equal(100, map.ValueAt(75, 0));
        Assert.Equal(100, map.ValueAt(99, 49));
        Assert.Equal(100, map.ValueAt(500, 500)); // outside: the nearest edge of the area
    }

    [Fact]
    public void MaxSmoothed_TakesTheBrightestNeighbor_ClampedBelow_RaisesTheFloor()
    {
        // 3 × 3 tiles of 10 px with values 10, 20, … 90 row by row.
        var pixels = new byte[30 * 30];
        for (int y = 0; y < 30; y++)
        {
            for (int x = 0; x < 30; x++) pixels[y * 30 + x] = (byte)(10 * (1 + (y / 10) * 3 + x / 10));
        }
        var map = BackgroundMap.Estimate(new GrayImage(30, 30, pixels), 0, 0, 30, 30, 10)!;
        Assert.Equal(new byte[] { 10, 20, 30, 40, 50, 60, 70, 80, 90 }, map.Tiles);
        Assert.Equal(50, map.MedianTile());
        Assert.Equal(new byte[] { 50, 60, 60, 80, 90, 90, 80, 90, 90 }, map.MaxSmoothed().Tiles);
        Assert.Equal(new byte[] { 10, 10, 20, 10, 10, 20, 40, 40, 50 }, map.MinSmoothed().Tiles);
        Assert.Equal(new byte[] { 45, 45, 45, 45, 50, 60, 70, 80, 90 }, map.ClampedBelow(45).Tiles);
        Assert.Equal(new byte[] { 10, 20, 30, 40, 50, 60, 70, 80, 90 }, map.Tiles); // unchanged
    }

    [Fact]
    public void InkMask_MarksPixelsClearlyDarkerThanThePaper()
    {
        // Paper 200: 141 is 70.5 % of it (not ink), 139 is 69.5 % (ink).
        var pixels = Enumerable.Repeat((byte)200, 40 * 40).ToArray();
        pixels[5 * 40 + 5] = 141;
        pixels[5 * 40 + 6] = 139;
        pixels[30 * 40 + 30] = 0;
        var gray = new GrayImage(40, 40, pixels);
        var map = BackgroundMap.Estimate(gray, 0, 0, 40, 40, 20)!;
        var mask = map.InkMask(gray, 0.30);
        Assert.Equal(2, mask.Count(b => b == 1));
        Assert.Equal(1, mask[5 * 40 + 6]);
        Assert.Equal(1, mask[30 * 40 + 30]);
        Assert.Equal(0, mask[5 * 40 + 5]);
        // A map of part of the image: the mask covers that part only.
        var part = BackgroundMap.Estimate(gray, 20, 20, 20, 20, 10)!;
        var partMask = part.InkMask(gray, 0.30);
        Assert.Equal(400, partMask.Length);
        Assert.Equal(1, partMask[10 * 20 + 10]);
        Assert.Equal(1, partMask.Count(b => b == 1));
    }
}
