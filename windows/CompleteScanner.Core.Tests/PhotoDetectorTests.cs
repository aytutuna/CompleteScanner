using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Port of Tests/CompleteScannerTests/PhotoDetectorTests.swift. The synthetic flatbed is
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
}
