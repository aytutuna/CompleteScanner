using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/CornerHeatmapTests.swift: DocAligner's heatmaps read back into corners
// (CornerHeatmap), on heatmaps drawn here: a Gaussian spot per channel where the corner is, as the model
// draws them.

/// <summary>Four channels of <c>size</c> × <c>size</c> values, all 0 until spots are added.</summary>
internal sealed class DrawnHeatmap(int size)
{
    public int Size { get; } = size;
    public float[] Values { get; } = new float[size * size * 4];

    /// <summary>
    /// A Gaussian spot of <paramref name="peak"/> and <paramref name="sigma"/> (in values) centred on
    /// (<paramref name="x"/>, <paramref name="y"/>), in the values' own units (value i covers [i, i + 1)),
    /// added to <paramref name="channel"/>.
    /// </summary>
    public void Spot(int channel, double x, double y, double peak = 0.9, double sigma = 2)
    {
        for (int row = 0; row < Size; row++)
        {
            for (int column = 0; column < Size; column++)
            {
                double dx = column + 0.5 - x, dy = row + 0.5 - y;
                double value = peak * Math.Exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
                int index = channel * Size * Size + row * Size + column;
                Values[index] = Math.Max(Values[index], (float)value);
            }
        }
    }

    /// <summary>The highest value drawn in <paramref name="channel"/>. Spots centred between values peak lower than asked.</summary>
    public double Peak(int channel) => Values.AsSpan(channel * Size * Size, Size * Size).ToArray().Max();

    public double WeakestPeak => Math.Min(Math.Min(Peak(0), Peak(1)), Math.Min(Peak(2), Peak(3)));
}

public class CornerHeatmapTests
{
    private const int Size = 64;
    /// <summary>A page a little turned, its corners in the values' units.</summary>
    private static readonly PointD[] Page = [new(12, 10), new(50, 14), new(48, 56), new(9, 52)];

    private static DrawnHeatmap DrawnPage(double[]? peaks = null)
    {
        peaks ??= [0.9, 0.9, 0.9, 0.9];
        var heat = new DrawnHeatmap(Size);
        for (int channel = 0; channel < 4; channel++) heat.Spot(channel, Page[channel].X, Page[channel].Y, peaks[channel]);
        return heat;
    }

    [Fact]
    public void FourSpots_GiveTheCornersInOrder_AsSharesOfTheImage()
    {
        var heat = DrawnPage();
        var found = CornerHeatmap.Decode(heat.Values, Size, Size);
        Assert.NotNull(found);
        var corners = found.Quad.Corners;
        for (int index = 0; index < 4; index++)
        {
            Assert.Equal(Page[index].X, corners[index].X * Size, 0.01);
            Assert.Equal(Page[index].Y, corners[index].Y * Size, 0.01);
        }
        Assert.Equal(heat.WeakestPeak, found.Confidence, 1e-6);
    }

    [Fact]
    public void TheConfidence_IsTheWeakestChannelsPeak()
    {
        var heat = DrawnPage([0.95, 0.6, 0.8, 0.9]);
        var found = CornerHeatmap.Decode(heat.Values, Size, Size);
        Assert.NotNull(found);
        Assert.Equal(heat.Peak(1), found.Confidence, 1e-6);
    }

    [Fact]
    public void TheLargestBlob_WinsOverASmallerBrighterOne()
    {
        var heat = DrawnPage();
        // A small bright spot far from the top-left corner's wide one.
        heat.Spot(0, 40.5, 40.5, 1.0, 0.8);
        var found = CornerHeatmap.Decode(heat.Values, Size, Size);
        Assert.NotNull(found);
        Assert.Equal(12, found.Quad.TopLeft.X * Size, 0.01);
        Assert.Equal(10, found.Quad.TopLeft.Y * Size, 0.01);
        Assert.Equal(heat.WeakestPeak, found.Confidence, 1e-6);
    }

    [Fact]
    public void AnEmptyChannel_GivesNothing()
    {
        var heat = new DrawnHeatmap(Size);
        heat.Spot(0, 12, 10);
        heat.Spot(1, 50, 14);
        heat.Spot(3, 9, 52);
        Assert.Null(CornerHeatmap.Decode(heat.Values, Size, Size));
        // A channel whose values all stay under the threshold is as empty.
        heat.Spot(2, 48, 56, 0.25);
        Assert.Null(CornerHeatmap.Decode(heat.Values, Size, Size));
    }

    [Fact]
    public void CornersOutOfOrder_GiveNothing()
    {
        var heat = new DrawnHeatmap(Size);
        heat.Spot(0, 12, 10);
        heat.Spot(1, 48, 56);
        heat.Spot(2, 50, 14);
        heat.Spot(3, 9, 52);
        Assert.Null(CornerHeatmap.Decode(heat.Values, Size, Size));
    }

    [Fact]
    public void ASpotBetweenValues_IsFoundToAFractionOfAValue()
    {
        var heat = new DrawnHeatmap(Size);
        heat.Spot(0, 20.25, 10.75);
        heat.Spot(1, 50.6, 14.3);
        heat.Spot(2, 48, 56);
        heat.Spot(3, 9, 52);
        var found = CornerHeatmap.Decode(heat.Values, Size, Size);
        Assert.NotNull(found);
        Assert.Equal(20.25, found.Quad.TopLeft.X * Size, 0.1);
        Assert.Equal(10.75, found.Quad.TopLeft.Y * Size, 0.1);
        Assert.Equal(50.6, found.Quad.TopRight.X * Size, 0.1);
        Assert.Equal(14.3, found.Quad.TopRight.Y * Size, 0.1);
    }

    [Fact]
    public void ANonSquareHeatmap_IsReadAsSharesOfEachSide()
    {
        const int width = 32, height = 16;
        var values = new float[width * height * 4];
        (int X, int Y)[] spots = [(4, 3), (27, 3), (27, 12), (4, 12)];
        for (int channel = 0; channel < 4; channel++) values[channel * width * height + spots[channel].Y * width + spots[channel].X] = 0.8f;
        var found = CornerHeatmap.Decode(values, width, height);
        Assert.NotNull(found);
        Assert.Equal(4.5 / 32, found.Quad.TopLeft.X, 1e-9);
        Assert.Equal(3.5 / 16, found.Quad.TopLeft.Y, 1e-9);
        Assert.Equal(27.5 / 32, found.Quad.BottomRight.X, 1e-9);
        Assert.Equal(12.5 / 16, found.Quad.BottomRight.Y, 1e-9);
        Assert.Null(CornerHeatmap.Decode(values[..10], width, height));
    }
}
