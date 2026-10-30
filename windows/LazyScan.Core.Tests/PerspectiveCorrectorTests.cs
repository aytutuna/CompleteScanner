using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/PerspectiveCorrectorTests.swift: the same photos and quads, the
// same corrected bytes (pinned by checksum in both suites).

public class PerspectiveCorrectorTests
{
    private static Quad RoundTripQuad => PhotoScenes.RoundTripMap.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight);

    /// <summary>The mean absolute difference of R, G and B, leaving out <paramref name="border"/> px all around.</summary>
    private static double MeanDifference(RgbaImage a, RgbaImage b, int border)
    {
        Assert.Equal(a.Width, b.Width);
        Assert.Equal(a.Height, b.Height);
        long sum = 0, count = 0;
        for (int y = border; y < a.Height - border; y++)
        {
            for (int x = border; x < a.Width - border; x++)
            {
                int i = (y * a.Width + x) * 4;
                for (int c = 0; c < 3; c++) sum += Math.Abs(a.Pixels[i + c] - b.Pixels[i + c]);
                count += 3;
            }
        }
        return (double)sum / count;
    }

    [Fact]
    public void CorrectingAWarpedSheetGivesItBack()
    {
        var sheet = PhotoScenes.SheetImage(PhotoScenes.BlockRaster(0x9A6E000C));
        var options = new PerspectiveOptions { OutputWidth = PhotoScenes.PageWidth, OutputHeight = PhotoScenes.PageHeight, Supersample = Supersampling.On };
        var corrected = PerspectiveCorrector.Correct(PhotoScenes.RoundTripScene(), RoundTripQuad, options)!;
        Assert.Equal(PhotoScenes.PageWidth, corrected.Image.Width);
        Assert.Equal(PhotoScenes.PageHeight, corrected.Image.Height);
        double difference = MeanDifference(sheet, corrected.Image, 2);
        Assert.True(difference <= 6, $"mean difference {difference:0.00}");
        // Every block's center is its own color.
        for (int by = 5; by < PhotoScenes.PageHeight; by += 10)
        {
            for (int bx = 5; bx < PhotoScenes.PageWidth; bx += 10)
            {
                int i = (by * PhotoScenes.PageWidth + bx) * 4;
                for (int c = 0; c < 3; c++) Assert.InRange(corrected.Image.Pixels[i + c] - sheet.Pixels[i + c], -6, 6);
            }
        }
    }

    [Fact]
    public void CorrectedBytesAreTheSameOnBothPlatforms()
    {
        var forced = new PerspectiveOptions { OutputWidth = PhotoScenes.PageWidth, OutputHeight = PhotoScenes.PageHeight, Supersample = Supersampling.On };
        Assert.Equal(0xF8DE2BA5u, PhotoScenes.Checksum(PerspectiveCorrector.Correct(PhotoScenes.RoundTripScene(), RoundTripQuad, forced)!.Image));
        var single = forced with { Supersample = Supersampling.Off };
        Assert.Equal(0x99509981u, PhotoScenes.Checksum(PerspectiveCorrector.Correct(PhotoScenes.RoundTripScene(), RoundTripQuad, single)!.Image));
        var wood = PerspectiveCorrector.Correct(PhotoScenes.WoodScene(), PhotoScenes.WoodMap.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight))!;
        Assert.Equal(235, wood.Image.Width);
        Assert.Equal(333, wood.Image.Height);
        Assert.Equal(PaperSize.A4, wood.Plan.Paper!.Size);
        Assert.Equal(0x32B36A66u, PhotoScenes.Checksum(wood.Image));
    }

    [Fact]
    public void TheOutputTakesTheLongerEdgesAndNeverMore()
    {
        var quad = new Quad(new PointD(100, 100), new PointD(300, 120), new PointD(320, 400), new PointD(90, 380));
        var plan = PerspectiveCorrector.Plan(quad, 1000, 1000, new PerspectiveOptions { SnapToPaper = false })!;
        double longest = Math.Max(Math.Max(quad.EdgeLength(0), quad.EdgeLength(2)), Math.Max(quad.EdgeLength(1), quad.EdgeLength(3)));
        Assert.Equal((int)Math.Floor(longest + 0.5), Math.Max(plan.Width, plan.Height));
        Assert.Null(plan.Paper);
        Assert.Null(plan.Dpi);
        var capped = PerspectiveCorrector.Plan(quad, 1000, 1000, new PerspectiveOptions { SnapToPaper = false, MaxLongSide = 100 })!;
        Assert.Equal(100, Math.Max(capped.Width, capped.Height));
        Assert.True(capped.Supersampled);
        var single = PerspectiveCorrector.Plan(quad, 1000, 1000, new PerspectiveOptions { SnapToPaper = false, MaxLongSide = 100, Supersample = Supersampling.Off })!;
        Assert.False(single.Supersampled);
    }

    [Fact]
    public void AKnownPaperSizeSetsTheShapeAndTheResolution()
    {
        // An A4 sheet tilted 25° in a 3000 × 4000 photo: the output is √2 and about as large as the near edge.
        var view = CameraView(210, 297, 25, -10, 4, 420, 3100, 3000, 4000);
        var plan = PerspectiveCorrector.Plan(view, 3000, 4000)!;
        Assert.Equal(PaperSize.A4, plan.Paper!.Size);
        Assert.InRange((double)plan.Height / plan.Width, 1.410, 1.418);
        Assert.InRange(plan.Dpi!.Value, plan.Height / 11.6929 - 0.01, plan.Height / 11.6929 + 0.01);
    }

    [Fact]
    public void OutsideThePhotoIsFilled()
    {
        var image = RgbaImage.Filled(100, 100, 10, 20, 30);
        var quad = new Quad(new PointD(-50, 0), new PointD(50, 0), new PointD(50, 100), new PointD(-50, 100));
        var result = PerspectiveCorrector.Correct(image, quad, new PerspectiveOptions { FillR = 255, FillG = 0, FillB = 0, SnapToPaper = false })!;
        Assert.Equal(100, result.Image.Width);
        var left = result.Image.Pixels.AsSpan(10 * 4 * 100 + 10 * 4, 4).ToArray();
        var right = result.Image.Pixels.AsSpan(10 * 4 * 100 + 90 * 4, 4).ToArray();
        Assert.Equal(new byte[] { 255, 0, 0, 255 }, left);
        Assert.Equal(new byte[] { 10, 20, 30, 255 }, right);
    }

    [Fact]
    public void OnePixelStripesKeepTheirContrastAtOneToOne()
    {
        // Black and white columns one pixel wide, read a quarter pixel off at 1:1: Catmull-Rom gives
        // 40 and 215; bilinear would give 0.25 · 255 and 0.75 · 255, 64 and 191.
        const int size = 40;
        var p = new byte[size * size * 4];
        Array.Fill(p, (byte)255);
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x += 2)
            {
                int i = (y * size + x) * 4;
                p[i] = 0;
                p[i + 1] = 0;
                p[i + 2] = 0;
            }
        }
        var stripes = new RgbaImage(size, size, p);
        var quad = new Quad(new PointD(0.25, 0), new PointD(size + 0.25, 0), new PointD(size + 0.25, size), new PointD(0.25, size));
        var result = PerspectiveCorrector.Correct(stripes, quad, new PerspectiveOptions { OutputWidth = size, OutputHeight = size, SnapToPaper = false })!;
        Assert.False(result.Plan.Supersampled);
        int dark = 255, light = 0;
        for (int x = 4; x < size - 4; x++)
        {
            int value = result.Image.Pixels[(size / 2 * size + x) * 4];
            Assert.Equal(x % 2 == 0 ? 40 : 215, value);
            dark = Math.Min(dark, value);
            light = Math.Max(light, value);
        }
        Assert.True(light - dark > 191 - 64);
    }

    [Fact]
    public void AQuadFarOutsideThePhotoGivesABoundedOutput()
    {
        // A corner editor's quad a million pixels across on a 4000 × 3000 photo: the long side is cut
        // to twice the photo's diagonal (10000 px), and the output can be made.
        var huge = new Quad(new PointD(0, 0), new PointD(1e6, 0), new PointD(1e6, 1e6), new PointD(0, 1e6));
        var plan = PerspectiveCorrector.Plan(huge, 4000, 3000, new PerspectiveOptions { SnapToPaper = false })!;
        Assert.Equal(10000, plan.Width);
        Assert.Equal(10000, plan.Height);
        Assert.True(plan.Supersampled);
        // Even larger photos stop at MaxOutputSide, whose RGBA bytes still fit in one array.
        var vast = new Quad(new PointD(0, 0), new PointD(1e19, 0), new PointD(1e19, 1e19), new PointD(0, 1e19));
        var capped = PerspectiveCorrector.Plan(vast, 100000, 100000, new PerspectiveOptions { SnapToPaper = false })!;
        Assert.Equal(PerspectiveCorrector.MaxOutputSide, capped.Width);
        Assert.True((long)capped.Width * capped.Height * 4 <= Array.MaxLength);
        // A size the caller gives beyond the limit, or a photo without pixels, has no plan.
        var square = new Quad(new PointD(10, 10), new PointD(90, 10), new PointD(90, 90), new PointD(10, 90));
        Assert.Null(PerspectiveCorrector.Plan(square, 100, 100, new PerspectiveOptions { OutputWidth = 50000, OutputHeight = 50000 }));
        Assert.Null(PerspectiveCorrector.Plan(square, 0, 0));
        // A small photo with a quad dragged outside it: the output stays near the photo's size.
        var dragged = new Quad(new PointD(-500, -400), new PointD(600, -300), new PointD(700, 900), new PointD(-450, 800));
        var near = PerspectiveCorrector.Plan(dragged, 100, 100, new PerspectiveOptions { SnapToPaper = false })!;
        Assert.True(Math.Max(near.Width, near.Height) <= 283, $"{near.Width} × {near.Height}");
    }

    [Fact]
    public void ANonConvexQuadIsRefused()
    {
        var bowtie = new Quad(new PointD(0, 0), new PointD(10, 10), new PointD(10, 0), new PointD(0, 10));
        Assert.Null(PerspectiveCorrector.Correct(RgbaImage.Filled(20, 20, 0, 0, 0), bowtie));
    }

    private static Quad CameraView(double w, double h, double tiltX, double tiltY, double turn, double distance, double f, double cw, double ch)
    {
        double ax = tiltX * Math.PI / 180, ay = tiltY * Math.PI / 180, az = turn * Math.PI / 180;
        var corners = new List<PointD>();
        foreach (var (u, v) in new[] { (-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2) })
        {
            double x = u * Math.Cos(az) - v * Math.Sin(az), y = u * Math.Sin(az) + v * Math.Cos(az), z = 0;
            double y1 = y * Math.Cos(ax) - z * Math.Sin(ax), z1 = y * Math.Sin(ax) + z * Math.Cos(ax);
            double x2 = x * Math.Cos(ay) + z1 * Math.Sin(ay), z2 = -x * Math.Sin(ay) + z1 * Math.Cos(ay);
            z2 += distance;
            corners.Add(new PointD(cw / 2 + f * x2 / z2, ch / 2 + f * y1 / z2));
        }
        return Quad.FromCorners(corners);
    }
}
