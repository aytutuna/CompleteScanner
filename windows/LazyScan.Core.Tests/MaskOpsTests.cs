using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/MaskOpsTests.swift. MaskOps was moved out of
// PhotoDetector; these tests prove it still does exactly what PhotoDetector's private copies did
// (kept below, verbatim, as the reference) and that photo detection gives the same regions.

public class MaskOpsTests
{
    // MARK: - Reference implementations (PhotoDetector's private code before the move)

    private static byte[] ReferenceDilate(byte[] mask, int w, int h, int r)
    {
        var tmp = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                byte v = 0;
                int lo = Math.Max(0, x - r), hi = Math.Min(w - 1, x + r);
                for (int xx = lo; xx <= hi; xx++)
                {
                    if (mask[row + xx] == 1) { v = 1; break; }
                }
                tmp[row + x] = v;
            }
        }
        var output = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte v = 0;
                int lo = Math.Max(0, y - r), hi = Math.Min(h - 1, y + r);
                for (int yy = lo; yy <= hi; yy++)
                {
                    if (tmp[yy * w + x] == 1) { v = 1; break; }
                }
                output[y * w + x] = v;
            }
        }
        return output;
    }

    private static byte[] ReferenceErode(byte[] mask, int w, int h, int r)
    {
        var tmp = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                byte v = (byte)((x - r >= 0 && x + r < w) ? 1 : 0);
                if (v == 1)
                {
                    for (int xx = x - r; xx <= x + r; xx++)
                    {
                        if (mask[row + xx] == 0) { v = 0; break; }
                    }
                }
                tmp[row + x] = v;
            }
        }
        var output = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte v = (byte)((y - r >= 0 && y + r < h) ? 1 : 0);
                if (v == 1)
                {
                    for (int yy = y - r; yy <= y + r; yy++)
                    {
                        if (tmp[yy * w + x] == 0) { v = 0; break; }
                    }
                }
                output[y * w + x] = v;
            }
        }
        return output;
    }

    private sealed class ReferenceComponent
    {
        public int Area;
        public readonly Dictionary<int, (int MinX, int MaxX)> Rows = [];
    }

    private static List<ReferenceComponent> ReferenceConnectedComponents(byte[] mask, int width, int height)
    {
        var visited = new bool[mask.Length];
        var components = new List<ReferenceComponent>();
        var stack = new Stack<int>();
        for (int start = 0; start < mask.Length; start++)
        {
            if (mask[start] != 1 || visited[start]) continue;
            var comp = new ReferenceComponent();
            visited[start] = true;
            stack.Clear();
            stack.Push(start);
            while (stack.Count > 0)
            {
                int idx = stack.Pop();
                int x = idx % width, y = idx / width;
                comp.Area += 1;
                if (comp.Rows.TryGetValue(y, out var span))
                    comp.Rows[y] = (Math.Min(span.MinX, x), Math.Max(span.MaxX, x));
                else
                    comp.Rows[y] = (x, x);
                if (x > 0 && mask[idx - 1] == 1 && !visited[idx - 1]) { visited[idx - 1] = true; stack.Push(idx - 1); }
                if (x < width - 1 && mask[idx + 1] == 1 && !visited[idx + 1]) { visited[idx + 1] = true; stack.Push(idx + 1); }
                if (y > 0 && mask[idx - width] == 1 && !visited[idx - width]) { visited[idx - width] = true; stack.Push(idx - width); }
                if (y < height - 1 && mask[idx + width] == 1 && !visited[idx + width]) { visited[idx + width] = true; stack.Push(idx + width); }
            }
            components.Add(comp);
        }
        return components;
    }

    // MARK: - Fixtures

    /// <summary>A random mask, about <paramref name="percent"/> % set, in blobs and specks.</summary>
    private static byte[] RandomMask(int w, int h, int percent, uint seed)
    {
        var rng = new TestPages.Rng(seed);
        var mask = new byte[w * h];
        for (int i = 0; i < mask.Length; i++) mask[i] = (byte)(rng.Below(100) < percent ? 1 : 0);
        return mask;
    }

    private static readonly (int W, int H, int Percent, uint Seed)[] Masks =
    [
        (1, 1, 50, 1), (7, 1, 50, 2), (1, 9, 50, 3), (13, 11, 30, 4), (64, 48, 10, 5),
        (64, 48, 50, 6), (64, 48, 85, 7), (101, 37, 60, 8), (5, 5, 100, 9), (5, 5, 0, 10),
    ];

    [Fact]
    public void Erode_OutsideSet_KeepsTheEdgeOfARegionAgainstTheBorder()
    {
        // A 6 x 4 block in the top left corner of a 10 x 8 mask.
        var mask = new byte[80];
        for (int y = 0; y < 4; y++)
        {
            for (int x = 0; x < 6; x++) mask[y * 10 + x] = 1;
        }
        var kept = new byte[80];
        var shrunk = new byte[80];
        for (int y = 0; y < 8; y++)
        {
            for (int x = 0; x < 10; x++)
            {
                // Outside set: it shrinks only on the sides facing the inside of the mask.
                kept[y * 10 + x] = (byte)(x < 5 && y < 3 ? 1 : 0);
                // Outside clear (the default): it shrinks along the border too.
                shrunk[y * 10 + x] = (byte)(x >= 1 && x < 5 && y >= 1 && y < 3 ? 1 : 0);
            }
        }
        Assert.Equal(kept, MaskOps.Erode(mask, 10, 8, 1, outsideSet: true));
        Assert.Equal(shrunk, MaskOps.Erode(mask, 10, 8, 1));
    }

    // MARK: - Equivalence

    [Fact]
    public void DilateAndErode_MatchTheCodeTheyWereMovedFrom()
    {
        foreach (var (w, h, percent, seed) in Masks)
        {
            var mask = RandomMask(w, h, percent, seed);
            foreach (int r in new[] { 0, 1, 2, 3, 7 })
            {
                Assert.Equal(ReferenceDilate(mask, w, h, r), MaskOps.Dilate(mask, w, h, r));
                Assert.Equal(ReferenceErode(mask, w, h, r), MaskOps.Erode(mask, w, h, r));
            }
            // PhotoDetector's close and open.
            Assert.Equal(ReferenceErode(ReferenceDilate(mask, w, h, 2), w, h, 2),
                         MaskOps.Erode(MaskOps.Dilate(mask, w, h, 2), w, h, 2));
            Assert.Equal(ReferenceDilate(ReferenceErode(mask, w, h, 1), w, h, 1),
                         MaskOps.Dilate(MaskOps.Erode(mask, w, h, 1), w, h, 1));
        }
    }

    [Fact]
    public void ConnectedComponents_MatchTheCodeTheyWereMovedFrom_InOrder()
    {
        foreach (var (w, h, percent, seed) in Masks)
        {
            var mask = RandomMask(w, h, percent, seed);
            var expected = ReferenceConnectedComponents(mask, w, h);
            var actual = MaskOps.ConnectedComponents(mask, w, h);
            Assert.Equal(expected.Count, actual.Count);
            for (int i = 0; i < expected.Count; i++)
            {
                Assert.Equal(expected[i].Area, actual[i].Area);
                Assert.Equal(expected[i].Rows.ToList(), actual[i].Rows.ToList());
            }
        }
    }

    [Fact]
    public void ComponentAreas_AreTheAreasOfTheComponents()
    {
        foreach (var (w, h, percent, seed) in Masks)
        {
            var mask = RandomMask(w, h, percent, seed);
            Assert.Equal(MaskOps.ConnectedComponents(mask, w, h).Select(c => c.Area), MaskOps.ComponentAreas(mask, w, h));
            Assert.Equal(mask.Count(b => b == 1), MaskOps.ComponentAreas(mask, w, h).Sum());
            var eight = MaskOps.ComponentAreas(mask, w, h, eightConnected: true);
            Assert.Equal(mask.Count(b => b == 1), eight.Sum());
            Assert.True(eight.Count <= MaskOps.ComponentAreas(mask, w, h).Count);
        }
    }

    [Fact]
    public void Components_AreFourConnected()
    {
        // Diagonal neighbors are separate components; a plus sign is one.
        byte[] diagonal = [1, 0, 0, 1];
        Assert.Equal([1, 1], MaskOps.ComponentAreas(diagonal, 2, 2));
        Assert.Equal([2], MaskOps.ComponentAreas(diagonal, 2, 2, eightConnected: true));
        byte[] antiDiagonal = [0, 1, 1, 0];
        Assert.Equal([2], MaskOps.ComponentAreas(antiDiagonal, 2, 2, eightConnected: true));
        // A one-pixel staircase is one 8-connected mark, one 4-connected component per pixel.
        var staircase = new byte[6 * 6];
        for (int i = 0; i < 6; i++) staircase[i * 6 + i] = 1;
        Assert.Equal([6], MaskOps.ComponentAreas(staircase, 6, 6, eightConnected: true));
        Assert.Equal(6, MaskOps.ComponentAreas(staircase, 6, 6).Count);
        byte[] plus = [0, 1, 0, 1, 1, 1, 0, 1, 0];
        Assert.Equal([5], MaskOps.ComponentAreas(plus, 3, 3));
        var rows = MaskOps.ConnectedComponents(plus, 3, 3)[0].Rows;
        Assert.Equal([(0, (1, 1)), (1, (0, 2)), (2, (1, 1))], rows.OrderBy(r => r.Key).Select(r => (r.Key, r.Value)));
    }

    [Fact]
    public void ErodeShrinksAtTheBorders_DilateDoesNotGrowPastThem()
    {
        var full = Enumerable.Repeat((byte)1, 25).ToArray();
        var eroded = MaskOps.Erode(full, 5, 5, 1);
        Assert.Equal(9, eroded.Count(b => b == 1));
        Assert.Equal(0, eroded[0]);
        Assert.Equal(1, eroded[12]);
        var dot = new byte[25];
        dot[12] = 1;
        Assert.Equal(9, MaskOps.Dilate(dot, 5, 5, 1).Count(b => b == 1));
        Assert.Equal(25, MaskOps.Dilate(dot, 5, 5, 2).Count(b => b == 1));
    }

    // MARK: - Photo detection is unchanged

    /// <summary>
    /// The regions PhotoDetector found on the demo bed before MaskOps was moved out of it, to the
    /// last bit (center x, center y, width, height, angle).
    /// </summary>
    [Theory]
    [InlineData(75, new[]
    {
        187.49999999999997, 172.49999999999997, 301, 226, -11.996899307923579,
        472.49999999999983, 449.99999999999983, 226, 226, 2.9931320059790636,
        217.5, 712.5, 262, 187, 17.00285263875736,
    })]
    [InlineData(150, new[]
    {
        375.1096214226424, 345.05968790136143, 600, 450, -11.993348723586978,
        944.9414410300901, 900.0435082872929, 450, 450, 3.0127875041833505,
        435.0669896028266, 1424.9350367423474, 525, 375, 16.97549946792975,
    })]
    public void PhotoDetector_FindsExactlyTheRegionsItFoundBefore(int dpi, double[] expected)
    {
        var bed = MockBedRenderer.RenderBed(dpi, ScanIntent.Photo);
        var regions = PhotoDetector.DetectRegions(bed, dpi);
        var actual = regions.SelectMany(r => new[] { r.Center.X, r.Center.Y, r.Size.Width, r.Size.Height, r.AngleDegrees });
        Assert.Equal(expected, actual);
    }
}
