using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Port of Tests/LazyScanTests/PhotoDetectorTests.swift. The synthetic flatbed is
// rendered in pure C# (the Swift version used CoreGraphics), with the same geometry, colors,
// and tolerances — this suite is the cross-platform conformance contract for the detector.

public class PhotoDetectorTests
{
    // MARK: - Synthetic flatbed helpers

    /// <summary>One rectangle "photo" laid on the synthetic flatbed.</summary>
    private readonly record struct BedPhoto(PointD Center, SizeD Size, double AngleDegrees,
                                            (double R, double G, double B) Color);

    /// <summary>8.5 x 11 inches at 150 dpi.</summary>
    private const int BedWidthPx = 1275;
    private const int BedHeightPx = 1650;

    /// <summary>
    /// Renders a flatbed scan: light-gray background (0.96) with saturated filled rectangles,
    /// each rotated about its center. Drawing happens in the same convention as
    /// DetectedPhotoRegion: pixels, origin top-left, positive angle = clockwise on screen.
    /// </summary>
    private static RgbaImage RenderBed(IReadOnlyList<BedPhoto> photos,
                                       int width = BedWidthPx, int height = BedHeightPx)
    {
        byte bg = (byte)Math.Round(0.96 * 255);
        var image = RgbaImage.Filled(width, height, bg, bg, bg);

        foreach (var photo in photos)
        {
            double angle = photo.AngleDegrees * Math.PI / 180;
            double cos = Math.Cos(angle), sin = Math.Sin(angle);
            double hw = photo.Size.Width / 2, hh = photo.Size.Height / 2;
            byte r = (byte)Math.Round(photo.Color.R * 255);
            byte g = (byte)Math.Round(photo.Color.G * 255);
            byte b = (byte)Math.Round(photo.Color.B * 255);

            double halfDiag = Math.Sqrt(hw * hw + hh * hh);
            int minX = Math.Max(0, (int)(photo.Center.X - halfDiag));
            int maxX = Math.Min(width - 1, (int)Math.Ceiling(photo.Center.X + halfDiag));
            int minY = Math.Max(0, (int)(photo.Center.Y - halfDiag));
            int maxY = Math.Min(height - 1, (int)Math.Ceiling(photo.Center.Y + halfDiag));

            for (int py = minY; py <= maxY; py++)
            {
                for (int px = minX; px <= maxX; px++)
                {
                    double dx = px + 0.5 - photo.Center.X;
                    double dy = py + 0.5 - photo.Center.Y;
                    // Inverse rotation into the photo's local frame.
                    double lx = dx * cos + dy * sin;
                    double ly = -dx * sin + dy * cos;
                    if (Math.Abs(lx) > hw || Math.Abs(ly) > hh) continue;
                    int pi = (py * width + px) * 4;
                    image.Pixels[pi] = r;
                    image.Pixels[pi + 1] = g;
                    image.Pixels[pi + 2] = b;
                }
            }
        }
        return image;
    }

    private static (int R, int G, int B, int A) PixelRgba(RgbaImage image, int x, int y)
    {
        int i = (y * image.Width + x) * 4;
        return (image.Pixels[i], image.Pixels[i + 1], image.Pixels[i + 2], image.Pixels[i + 3]);
    }

    private static DetectedPhotoRegion? NearestRegion(PointD center, IReadOnlyList<DetectedPhotoRegion> regions) =>
        regions.MinBy(r => r.Center.DistanceTo(center));

    /// <summary>Angular difference folded into the (-45, 45] convention (mod 90).</summary>
    private static double AngleDelta(double a, double b)
    {
        double d = (a - b) % 90;
        if (d > 45) d -= 90;
        if (d < -45) d += 90;
        return Math.Abs(d);
    }

    /// <summary>The standard three-photo bed used by several tests.</summary>
    private static readonly BedPhoto[] ThreePhotos =
    [
        new(new PointD(300, 350), new SizeD(450, 300), -15, (0.80, 0.12, 0.12)),
        new(new PointD(900, 400), new SizeD(350, 350), 0, (0.10, 0.25, 0.80)),
        new(new PointD(550, 1150), new SizeD(500, 350), 20, (0.10, 0.60, 0.18)),
    ];

    // MARK: - Tests

    [Fact]
    public void DetectsThreePhotos()
    {
        var bed = RenderBed(ThreePhotos);
        var regions = PhotoDetector.DetectRegions(bed, 150);
        Assert.Equal(3, regions.Count);

        foreach (var expected in ThreePhotos)
        {
            var match = NearestRegion(expected.Center, regions);
            Assert.NotNull(match);
            Assert.True(match!.Center.DistanceTo(expected.Center) <= 25,
                        $"Center {match.Center} too far from expected {expected.Center}");
            Assert.True(Math.Abs(match.Size.Width - expected.Size.Width) <= expected.Size.Width * 0.08,
                        $"Width {match.Size.Width} off for photo at {expected.Center}");
            Assert.True(Math.Abs(match.Size.Height - expected.Size.Height) <= expected.Size.Height * 0.08,
                        $"Height {match.Size.Height} off for photo at {expected.Center}");
            // The 0° square has a 90° orientation ambiguity — skip its angle assert.
            if (expected.Size.Width != expected.Size.Height)
            {
                Assert.True(AngleDelta(match.AngleDegrees, expected.AngleDegrees) <= 2.5,
                            $"Angle {match.AngleDegrees}° too far from {expected.AngleDegrees}°");
            }
        }
    }

    [Fact]
    public void ExtractUpright()
    {
        var bed = RenderBed(ThreePhotos);
        var regions = PhotoDetector.DetectRegions(bed, 150);
        var expected = ThreePhotos[0]; // the -15° red photo
        var region = NearestRegion(expected.Center, regions);
        Assert.NotNull(region);
        Assert.True(region!.Center.DistanceTo(expected.Center) <= 25);

        var extracted = PhotoDetector.ExtractPhoto(bed, region, deskew: true);
        Assert.NotNull(extracted);
        Assert.True(Math.Abs(extracted!.Width - region.Size.Width) <= region.Size.Width * 0.05);
        Assert.True(Math.Abs(extracted.Height - region.Size.Height) <= region.Size.Height * 0.05);

        // Center pixel must be the photo's fill color: (0.80, 0.12, 0.12) -> (204, 31, 31).
        var px = PixelRgba(extracted, extracted.Width / 2, extracted.Height / 2);
        Assert.True(Math.Abs(px.R - 204) <= 40, $"Red channel was {px.R}");
        Assert.True(Math.Abs(px.G - 31) <= 40, $"Green channel was {px.G}");
        Assert.True(Math.Abs(px.B - 31) <= 40, $"Blue channel was {px.B}");
    }

    [Fact]
    public void SinglePhotoFullBed()
    {
        var photo = new BedPhoto(new PointD(637, 825), new SizeD(600, 420), 10, (0.85, 0.55, 0.10));
        var bed = RenderBed([photo]);
        var regions = PhotoDetector.DetectRegions(bed, 150);
        Assert.Single(regions);
        var region = regions[0];
        Assert.True(region.Center.DistanceTo(photo.Center) <= 25);
        Assert.True(Math.Abs(region.Size.Width - photo.Size.Width) <= photo.Size.Width * 0.08);
        Assert.True(Math.Abs(region.Size.Height - photo.Size.Height) <= photo.Size.Height * 0.08);
    }

    [Fact]
    public void EmptyBedReturnsNothing()
    {
        var bed = RenderBed([]);
        var regions = PhotoDetector.DetectRegions(bed, 150);
        Assert.Empty(regions);
    }

    [Fact]
    public void MinSizeFilter()
    {
        // 100x100 px at 150 dpi is 0.67", below the 1.0" minimum — it must be dropped.
        var keeper = new BedPhoto(new PointD(300, 350), new SizeD(450, 300), -15, (0.80, 0.12, 0.12));
        var scrap = new BedPhoto(new PointD(900, 1300), new SizeD(100, 100), 0, (0.20, 0.15, 0.75));
        var bed = RenderBed([keeper, scrap]);

        var options = new PhotoDetectorOptions { MinPhotoSideInches = 1.0 };
        var regions = PhotoDetector.DetectRegions(bed, 150, options);
        Assert.Single(regions);
        Assert.True(regions[0].Center.DistanceTo(keeper.Center) <= 25,
                    "Surviving region should be the large photo");
    }

    // MARK: - Full-resolution edge refinement (step 11)
    //
    // Windows-side tests: the Swift suite exercises refinement only through the tests
    // above. The synthetic bed has hard, pixel-exact edges, so an axis-aligned photo's
    // true extent is known to the pixel.

    /// <summary>The bed's luminance as the detector measures it (0.96 → byte 245).</summary>
    private const double BedLuminance = 245 / 255.0;

    private static readonly (double R, double G, double B) Red = (0.80, 0.12, 0.12);

    [Fact]
    public void RefineTrimsBedSlivers()
    {
        var photo = new BedPhoto(new PointD(600, 700), new SizeD(400, 300), 0, Red);
        var bed = RenderBed([photo]);
        // A loose, off-center fit: ~15 px of bed on every side, more on two.
        var loose = new DetectedPhotoRegion(new PointD(606, 694), new SizeD(430, 330), 0);

        var refined = PhotoDetector.RefineRegion(loose, bed, BedLuminance);
        Assert.NotNull(refined);
        Assert.True(Math.Abs(refined!.Size.Width - 400) <= 1, $"width {refined.Size.Width}");
        Assert.True(Math.Abs(refined.Size.Height - 300) <= 1, $"height {refined.Size.Height}");
        Assert.True(refined.Center.DistanceTo(photo.Center) <= 1, $"center {refined.Center}");
        Assert.Equal(0, refined.AngleDegrees);
    }

    [Fact]
    public void RefineGrowsTightFitToPhotoEdges()
    {
        var photo = new BedPhoto(new PointD(600, 700), new SizeD(400, 300), 0, Red);
        var bed = RenderBed([photo]);
        var tight = new DetectedPhotoRegion(new PointD(597, 703), new SizeD(380, 284), 0);

        var refined = PhotoDetector.RefineRegion(tight, bed, BedLuminance);
        Assert.NotNull(refined);
        Assert.True(Math.Abs(refined!.Size.Width - 400) <= 1, $"width {refined.Size.Width}");
        Assert.True(Math.Abs(refined.Size.Height - 300) <= 1, $"height {refined.Size.Height}");
        Assert.True(refined.Center.DistanceTo(photo.Center) <= 1, $"center {refined.Center}");
    }

    [Fact]
    public void RefineMapsCenterShiftThroughRotation()
    {
        // A rotated photo fitted with the right angle but an off-center, loose rect: the
        // upright-frame shift must be rotated back into image coordinates.
        var photo = new BedPhoto(new PointD(640, 800), new SizeD(420, 300), 20, Red);
        var bed = RenderBed([photo]);
        var loose = new DetectedPhotoRegion(new PointD(652, 790), new SizeD(450, 330), 20);

        var refined = PhotoDetector.RefineRegion(loose, bed, BedLuminance);
        Assert.NotNull(refined);
        Assert.True(refined!.Center.DistanceTo(photo.Center) <= 1.5, $"center {refined.Center}");
        Assert.True(Math.Abs(refined.Size.Width - 420) <= 2, $"width {refined.Size.Width}");
        Assert.True(Math.Abs(refined.Size.Height - 300) <= 2, $"height {refined.Size.Height}");
    }

    [Fact]
    public void ExtractRotatedMapsPixelCentersExactly()
    {
        // Region coordinates are continuous (pixel i spans [i, i+1)), so an integer-aligned,
        // unrotated region must reproduce the source pixels exactly — no half-pixel blur.
        var source = new RgbaImage(20, 12, [.. Enumerable.Range(0, 20 * 12 * 4).Select(i => (byte)(i * 37 % 251))]);
        var whole = source.ExtractRotated(new PointD(10, 6), new SizeD(20, 12), 0);
        Assert.NotNull(whole);
        Assert.Equal(source.Pixels, whole!.Pixels);

        // A single pixel (5, 3) is the region centered at (5.5, 3.5).
        var one = source.ExtractRotated(new PointD(5.5, 3.5), new SizeD(1, 1), 0)!;
        Assert.Equal(source.Pixels.AsSpan((3 * 20 + 5) * 4, 3).ToArray(), one.Pixels.AsSpan(0, 3).ToArray());
    }

    [Theory]
    [InlineData(300.5, 10.5, 301, 11)]
    [InlineData(2.5, 4.5, 3, 5)]
    [InlineData(2.49, 0.5, 2, 1)]
    public void ExtractRotatedRoundsHalfSizesAwayFromZero(double width, double height,
                                                         int expectedWidth, int expectedHeight)
    {
        // Swift's extractPhoto sizes its output with .rounded() (halves away from zero);
        // banker's rounding would give 300 x 10 and 2 x 4 (and nothing at all for 0.5).
        var source = RgbaImage.Filled(400, 40, 90, 90, 90);
        var extracted = source.ExtractRotated(new PointD(200, 20), new SizeD(width, height), 0);
        Assert.NotNull(extracted);
        Assert.Equal(expectedWidth, extracted!.Width);
        Assert.Equal(expectedHeight, extracted.Height);

        var photo = PhotoDetector.ExtractPhoto(source, new DetectedPhotoRegion(new PointD(200, 20),
                                               new SizeD(width, height), 0), deskew: true);
        Assert.Equal(expectedWidth, photo!.Width);
    }

    [Fact]
    public void RefineKeepsOriginalWhenRegionIsBackground()
    {
        var bed = RenderBed([]);
        var region = new DetectedPhotoRegion(new PointD(600, 700), new SizeD(400, 300), 0);
        Assert.Null(PhotoDetector.RefineRegion(region, bed, BedLuminance));
    }

    [Fact]
    public void DetectedAxisAlignedPhotoIsPixelExact()
    {
        var photo = new BedPhoto(new PointD(600, 700), new SizeD(400, 300), 0, Red);
        var regions = PhotoDetector.DetectRegions(RenderBed([photo]), 150);
        Assert.Single(regions);
        Assert.True(Math.Abs(regions[0].Size.Width - 400) <= 1, $"width {regions[0].Size.Width}");
        Assert.True(Math.Abs(regions[0].Size.Height - 300) <= 1, $"height {regions[0].Size.Height}");
        Assert.True(regions[0].Center.DistanceTo(photo.Center) <= 1, $"center {regions[0].Center}");
    }

    [Fact]
    public void RefinementKeepsWhitePrintBorder()
    {
        // A dark print with a 16 px pure-white border. The white differs from the 0.96 bed
        // by only ~0.04 luminance — below the detection threshold, so the low-res mask finds
        // just the dark interior; refinement must grow the region out over the border.
        var border = new BedPhoto(new PointD(600, 700), new SizeD(432, 332), 0, (1.0, 1.0, 1.0));
        var interior = new BedPhoto(new PointD(600, 700), new SizeD(400, 300), 0, (0.15, 0.20, 0.35));
        var regions = PhotoDetector.DetectRegions(RenderBed([border, interior]), 150);
        Assert.Single(regions);
        Assert.True(Math.Abs(regions[0].Size.Width - 432) <= 2, $"width {regions[0].Size.Width}");
        Assert.True(Math.Abs(regions[0].Size.Height - 332) <= 2, $"height {regions[0].Size.Height}");
        Assert.True(regions[0].Center.DistanceTo(border.Center) <= 1.5, $"center {regions[0].Center}");
    }

    [Fact]
    public void RefinementDoesNotAbsorbNeighborAcrossGap()
    {
        // Two prints 12 px apart — inside each other's 24 px refinement margin, but
        // separated by a clean background gap.
        var left = new BedPhoto(new PointD(400, 600), new SizeD(400, 300), 0, Red);
        var right = new BedPhoto(new PointD(812, 600), new SizeD(400, 300), 0, (0.10, 0.25, 0.80));
        var regions = PhotoDetector.DetectRegions(RenderBed([left, right]), 150);
        Assert.Equal(2, regions.Count);
        foreach (var expected in new[] { left, right })
        {
            var match = NearestRegion(expected.Center, regions)!;
            Assert.True(Math.Abs(match.Size.Width - 400) <= 1, $"width {match.Size.Width} at {expected.Center}");
            Assert.True(Math.Abs(match.Size.Height - 300) <= 1, $"height {match.Size.Height} at {expected.Center}");
            Assert.True(match.Center.DistanceTo(expected.Center) <= 1, $"center {match.Center}");
        }

        // A deliberately loose fit whose edge ends inside the gap (x 600...612), with the
        // neighbor well within the margin ring, still stops at the gap.
        var loose = new DetectedPhotoRegion(new PointD(404, 600), new SizeD(412, 320), 0);
        var refined = PhotoDetector.RefineRegion(loose, RenderBed([left, right]), BedLuminance);
        Assert.NotNull(refined);
        Assert.True(Math.Abs(refined!.Size.Width - 400) <= 1, $"width {refined.Size.Width}");
        Assert.True(refined.Center.DistanceTo(left.Center) <= 1, $"center {refined.Center}");
    }
}
