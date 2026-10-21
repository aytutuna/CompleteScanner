using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/PerspectiveWarpTests.swift: the same fixture photos, quads and
// sizes, the same warped bytes (pinned by checksum and sample pixels in both suites, and recomputed
// by an independent model of the algorithm when the constants change).

public class PerspectiveWarpTests
{
    /// <summary>The golden fixture: a w × h photo whose every byte comes from integer arithmetic on (x, y).</summary>
    internal static RgbaImage Fixture(int w, int h)
    {
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                p[i] = (byte)((x * 37 + y * 11) % 256);
                p[i + 1] = (byte)((x / 4 + y / 4) % 2 == 0 ? 40 + (x * 3) % 160 : 220 - (y * 5) % 120);
                p[i + 2] = (byte)((x * y + 3 * x + 7 * y) % 256);
                p[i + 3] = 255;
            }
        }
        return new RgbaImage(w, h, p);
    }

    private static Quad Q(double x0, double y0, double x1, double y1, double x2, double y2, double x3, double y3) =>
        new(new PointD(x0, y0), new PointD(x1, y1), new PointD(x2, y2), new PointD(x3, y3));

    private static byte[] Pixel(RgbaImage image, int x, int y)
    {
        int i = (y * image.Width + x) * 4;
        return image.Pixels[i..(i + 4)];
    }

    /// <summary>A 300 × 400 page: soft color ramps, a checkerboard of 15 px squares in blue and four black 7 × 7 dots centered 24.5 px in from each corner.</summary>
    private static RgbaImage DottedPage()
    {
        const int w = 300, h = 400;
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                p[i] = (byte)(230 - x * 60 / w);
                p[i + 1] = (byte)(220 - y * 80 / h);
                p[i + 2] = (byte)(120 + (x / 15 + y / 15) % 2 * 80);
                p[i + 3] = 255;
            }
        }
        foreach (var (cx, cy) in DotCenters)
        {
            for (int y = (int)cy - 3; y <= (int)cy + 3; y++)
            {
                for (int x = (int)cx - 3; x <= (int)cx + 3; x++)
                {
                    int i = (y * w + x) * 4;
                    p[i] = 0;
                    p[i + 1] = 0;
                    p[i + 2] = 0;
                }
            }
        }
        return new RgbaImage(w, h, p);
    }

    private static readonly (double X, double Y)[] DotCenters = [(24.5, 24.5), (275.5, 24.5), (275.5, 375.5), (24.5, 375.5)];

    /// <summary>The page's place in the 640 × 480 photo of the round trip.</summary>
    private static readonly Quad PhotoQuad = Q(130.5, 60.25, 470, 95.5, 500.75, 430, 95, 400.5);

    /// <summary>The centroid of the pixels darker than 60 (by their darkness) within <paramref name="radius"/> px of (cx, cy), in continuous pixels.</summary>
    private static PointD DarkCentroid(RgbaImage image, double cx, double cy, int radius)
    {
        double sx = 0, sy = 0, sw = 0;
        for (int y = Math.Max(0, (int)cy - radius); y <= Math.Min(image.Height - 1, (int)cy + radius); y++)
        {
            for (int x = Math.Max(0, (int)cx - radius); x <= Math.Min(image.Width - 1, (int)cx + radius); x++)
            {
                int i = (y * image.Width + x) * 4;
                int luma = (image.Pixels[i] * 299 + image.Pixels[i + 1] * 587 + image.Pixels[i + 2] * 114) / 1000;
                if (luma >= 60) continue;
                double weight = 60 - luma;
                sx += weight * (x + 0.5);
                sy += weight * (y + 0.5);
                sw += weight;
            }
        }
        Assert.True(sw > 0, $"no dot near ({cx}, {cy})");
        return new PointD(sx / sw, sy / sw);
    }

    /// <summary>The peak signal-to-noise ratio of R, G and B in dB, leaving out <paramref name="border"/> px all around.</summary>
    internal static double Psnr(RgbaImage a, RgbaImage b, int border)
    {
        Assert.Equal(a.Width, b.Width);
        Assert.Equal(a.Height, b.Height);
        double sum = 0;
        long count = 0;
        for (int y = border; y < a.Height - border; y++)
        {
            for (int x = border; x < a.Width - border; x++)
            {
                int i = (y * a.Width + x) * 4;
                for (int c = 0; c < 3; c++)
                {
                    double d = a.Pixels[i + c] - b.Pixels[i + c];
                    sum += d * d;
                }
                count += 3;
            }
        }
        double mse = sum / count;
        return mse == 0 ? 99 : 10 * Math.Log10(255.0 * 255.0 / mse);
    }

    // MARK: - Golden bytes, the same on both platforms

    [Fact]
    public void WarpedBytesAreTheSameOnBothPlatforms()
    {
        var supersampled = PerspectiveWarp.Warp(Fixture(96, 72), Q(10.25, 6.5, 85.75, 12, 80.5, 66.25, 6, 60.75), 40, 30)!;
        Assert.Equal(0x4F042AE9u, PhotoScenes.Checksum(supersampled));
        Assert.Equal(new byte[] { 206, 157, 155, 255 }, Pixel(supersampled, 0, 0));
        Assert.Equal(new byte[] { 69, 129, 71, 255 }, Pixel(supersampled, 7, 5));
        Assert.Equal(new byte[] { 216, 173, 70, 255 }, Pixel(supersampled, 19, 13));

        var prefiltered = PerspectiveWarp.Warp(Fixture(240, 180), Q(20.5, 15.25, 220, 30.75, 205.25, 170.5, 12, 150), 48, 36)!;
        Assert.Equal(0x97396FCAu, PhotoScenes.Checksum(prefiltered));
        Assert.Equal(new byte[] { 154, 128, 102, 255 }, Pixel(prefiltered, 0, 0));
        Assert.Equal(new byte[] { 146, 162, 136, 255 }, Pixel(prefiltered, 7, 5));
        Assert.Equal(new byte[] { 138, 194, 140, 255 }, Pixel(prefiltered, 19, 13));

        var enlarged = PerspectiveWarp.Warp(Fixture(32, 24), Q(-4, -3, 30, 1, 36, 26, 2, 22), 50, 40)!;
        Assert.Equal(0x8B045C82u, PhotoScenes.Checksum(enlarged));
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, Pixel(enlarged, 0, 0));
        Assert.Equal(new byte[] { 59, 44, 9, 255 }, Pixel(enlarged, 7, 5));
        Assert.Equal(new byte[] { 215, 188, 148, 255 }, Pixel(enlarged, 19, 13));
    }

    [Fact]
    public void ThePrefilterStartsAboveTwiceSmallerAndTakesTheWholePart()
    {
        var quad = Q(20.5, 15.25, 220, 30.75, 205.25, 170.5, 12, 150);
        Assert.Equal(4, PerspectiveWarp.PrefilterFactor(quad, 48, 36));
        Assert.Equal(1, PerspectiveWarp.PrefilterFactor(quad, 120, 90));
        Assert.Equal(2, PerspectiveWarp.PrefilterFactor(quad, 90, 60));
        Assert.Equal(1, PerspectiveWarp.PrefilterFactor(quad, 400, 300));
        Assert.Equal(1, PerspectiveWarp.PrefilterFactor(quad, 0, 36));
        // Exactly twice smaller is not more than twice.
        var square = Q(0, 0, 100, 0, 100, 100, 0, 100);
        Assert.Equal(1, PerspectiveWarp.PrefilterFactor(square, 50, 50));
        Assert.Equal(2, PerspectiveWarp.PrefilterFactor(square, 49, 49));
        Assert.Equal(3, PerspectiveWarp.PrefilterFactor(square, 33, 50));
    }

    [Fact]
    public void BoxReducedAveragesWholeAndEdgeBlocksRoundingHalfUp()
    {
        // 5 × 3, blocks of 2: a 3 × 2 result whose last column and row hold fewer pixels.
        var p = new byte[5 * 3 * 4];
        for (int i = 0; i < 15; i++)
        {
            p[i * 4] = (byte)(i * 10);
            p[i * 4 + 1] = (byte)(i % 2);
            p[i * 4 + 2] = 255;
            p[i * 4 + 3] = (byte)(i == 0 ? 0 : 255);
        }
        var reduced = PerspectiveWarp.BoxReduced(new RgbaImage(5, 3, p), 2);
        Assert.Equal(3, reduced.Width);
        Assert.Equal(2, reduced.Height);
        // Block (0, 0): pixels 0, 1, 5, 6 → R (0 + 10 + 50 + 60) / 4 = 30, G (0 + 1 + 1 + 0) / 4 = 0.5 → 1, A 765 / 4 = 191.25 → 191.
        Assert.Equal(new byte[] { 30, 1, 255, 191 }, Pixel(reduced, 0, 0));
        // Block (2, 0): pixels 4 and 9 → R 65, G (0 + 1) / 2 → 1.
        Assert.Equal(new byte[] { 65, 1, 255, 255 }, Pixel(reduced, 2, 0));
        // Block (1, 1): pixels 12 and 13 → R 125, G 0.5 → 1.
        Assert.Equal(new byte[] { 125, 1, 255, 255 }, Pixel(reduced, 1, 1));
        // Block (2, 1): pixel 14 alone.
        Assert.Equal(new byte[] { 140, 0, 255, 255 }, Pixel(reduced, 2, 1));
        var image = Fixture(7, 5);
        Assert.Same(image, PerspectiveWarp.BoxReduced(image, 1));
    }

    [Fact]
    public void WithoutPrefilterTheWarpIsTheCorrectorsOwn()
    {
        var photo = Fixture(96, 72);
        var quad = Q(10.25, 6.5, 85.75, 12, 80.5, 66.25, 6, 60.75);
        var options = new PerspectiveOptions { OutputWidth = 40, OutputHeight = 30, SnapToPaper = false };
        var plan = PerspectiveCorrector.Plan(quad, 96, 72, options)!;
        Assert.Equal(PerspectiveCorrector.Warp(photo, plan, options).Pixels, PerspectiveWarp.Warp(photo, quad, 40, 30)!.Pixels);
        var dark = new PerspectiveOptions { FillR = 10, FillG = 20, FillB = 30 };
        var filled = PerspectiveWarp.Warp(Fixture(32, 24), Q(-4, -3, 30, 1, 36, 26, 2, 22), 50, 40, dark)!;
        Assert.Equal(new byte[] { 10, 20, 30, 255 }, Pixel(filled, 0, 0));
    }

    [Fact]
    public void NoWarpForAnOutlineThatIsNotConvexOrASizeOutOfRange()
    {
        var photo = Fixture(32, 24);
        Assert.Null(PerspectiveWarp.Warp(photo, Q(0, 0, 30, 0, 10, 5, 0, 20), 10, 10));
        Assert.Null(PerspectiveWarp.Warp(photo, Q(0, 20, 30, 20, 30, 0, 0, 0), 10, 10)); // counterclockwise
        Assert.Null(PerspectiveWarp.Warp(photo, Q(0, 0, 30, 0, 30, 20, 0, 20), 0, 10));
        Assert.Null(PerspectiveWarp.Warp(photo, Q(0, 0, 30, 0, 30, 20, 0, 20), 10, PerspectiveCorrector.MaxOutputSide + 1));
    }

    // MARK: - Round trip

    [Fact]
    public void APagePhotographedAndWarpedBackKeepsItsCornersAndLooks()
    {
        var page = DottedPage();
        var toPhoto = Homography.RectToQuad(300, 400, PhotoQuad)!.Value;
        var back = toPhoto.Inverse()!.Value;
        // The photo: every photo pixel looks up the page through the inverse map (dark table around it).
        var photoCorners = Quad.FromCorners([back.Map(new PointD(0, 0)), back.Map(new PointD(640, 0)),
                                             back.Map(new PointD(640, 480)), back.Map(new PointD(0, 480))]);
        Assert.True(photoCorners.IsConvex);
        var table = new PerspectiveOptions { FillR = 40, FillG = 40, FillB = 40 };
        var photo = PerspectiveWarp.Warp(page, photoCorners, 640, 480, table)!;

        // The page's corners land where the map says, within 1 px.
        foreach (var (x, y) in DotCenters)
        {
            var expected = toPhoto.Map(new PointD(x, y));
            var found = DarkCentroid(photo, expected.X, expected.Y, 8);
            Assert.True(found.DistanceTo(expected) <= 1, $"photo dot at ({found.X:0.00}, {found.Y:0.00}), expected ({expected.X:0.00}, {expected.Y:0.00})");
        }

        // Warped back along the page's corners, it is the page again.
        var recovered = PerspectiveWarp.Warp(photo, PhotoQuad, 300, 400)!;
        double psnr = Psnr(page, recovered, 3);
        Assert.True(psnr >= 30, $"PSNR {psnr:0.00} dB");
        foreach (var (x, y) in DotCenters)
        {
            var found = DarkCentroid(recovered, x, y, 8);
            Assert.True(found.DistanceTo(new PointD(x, y)) <= 1, $"page dot at ({found.X:0.00}, {found.Y:0.00}), expected ({x}, {y})");
        }
    }

    [Fact]
    public void APageMadeMuchSmallerIsAveragedNotAliased()
    {
        // A fine 2 px checkerboard seen 4 times larger than the output: averaged it is an even gray.
        const int w = 400, h = 300;
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                byte v = (byte)((x / 2 + y / 2) % 2 == 0 ? 30 : 230);
                p[i] = v;
                p[i + 1] = v;
                p[i + 2] = v;
                p[i + 3] = 255;
            }
        }
        var photo = new RgbaImage(w, h, p);
        var quad = Q(10, 10, 390, 18, 385, 290, 14, 284);
        var warped = PerspectiveWarp.Warp(photo, quad, 90, 66)!;
        Assert.Equal(4, PerspectiveWarp.PrefilterFactor(quad, 90, 66));
        var plain = PerspectiveCorrector.Warp(photo, PerspectiveCorrector.Plan(quad, w, h,
            new PerspectiveOptions { OutputWidth = 90, OutputHeight = 66, SnapToPaper = false })!);
        var gray = RgbaImage.Filled(90, 66, 130, 130, 130);
        double prefilteredPsnr = Psnr(gray, warped, 2), plainPsnr = Psnr(gray, plain, 2);
        Assert.True(prefilteredPsnr >= 30, $"prefiltered PSNR {prefilteredPsnr:0.00} dB");
        Assert.True(prefilteredPsnr > plainPsnr + 6, $"prefiltered {prefilteredPsnr:0.00} dB, plain {plainPsnr:0.00} dB");
    }
}
