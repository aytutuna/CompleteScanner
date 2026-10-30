using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/GlareDetectorTests.swift: the same cards, readings and answers.
// The readings are pinned to an independent model of GlareDetector's description.

/// <summary>
/// Made-up cards for the glare tests, drawn pixel by pixel the same way on both platforms: 428 × 270
/// (an ID-1 card at about 127 dpi), a blue-grey ground, a photo box and six lines of print; glare is a
/// white ellipse (center (300, 120), radii 70 × 40) with a half-light halo around it; specks are 2 × 2
/// white dots every 30 px on two rows; the edge is a white strip 6 px wide along the left side.
/// </summary>
internal static class GlareCards
{
    public const int Width = 428, Height = 270;

    public static RgbaImage Card(byte r = 214, byte g = 220, byte b = 226, bool glare = false, bool specks = false,
                                 bool edge = false)
    {
        var pixels = new byte[Width * Height * 4];
        const long rx = 70, ry = 40, cx = 300, cy = 120;
        long r4 = 4 * rx * rx * ry * ry;
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < Width; x++)
            {
                int cr = r, cg = g, cb = b;
                if (x >= 24 && x < 124 && y >= 60 && y < 200) (cr, cg, cb) = (150, 130, 120);
                for (int i = 0; i < 6; i++)
                {
                    int top = 70 + 24 * i;
                    if (x >= 150 && x < 400 && y >= top && y < top + 8) (cr, cg, cb) = (40, 44, 52);
                }
                if (glare)
                {
                    long dx = 2 * x + 1 - 2 * cx, dy = 2 * y + 1 - 2 * cy;
                    long d = dx * dx * ry * ry + dy * dy * rx * rx;
                    if (d <= r4) (cr, cg, cb) = (255, 255, 255);
                    else if (d <= 2 * r4) (cr, cg, cb) = ((cr + 256) / 2, (cg + 256) / 2, (cb + 256) / 2);
                }
                if (specks && (y == 20 || y == 21 || y == 240 || y == 241) && x >= 10 && (x - 10) % 30 < 2)
                    (cr, cg, cb) = (255, 255, 255);
                if (edge && x < 6) (cr, cg, cb) = (255, 255, 255);
                int p = (y * Width + x) * 4;
                pixels[p] = (byte)cr;
                pixels[p + 1] = (byte)cg;
                pixels[p + 2] = (byte)cb;
                pixels[p + 3] = 255;
            }
        }
        return new RgbaImage(Width, Height, pixels);
    }

    /// <summary>FNV-1a over the RGBA bytes.</summary>
    public static uint Checksum(RgbaImage image)
    {
        uint hash = 0x811C9DC5;
        foreach (byte value in image.Pixels)
        {
            hash ^= value;
            hash *= 0x01000193;
        }
        return hash;
    }

    public static Quad Rect(double x0, double y0, double x1, double y1) =>
        new(new PointD(x0, y0), new PointD(x1, y0), new PointD(x1, y1), new PointD(x0, y1));
}

public class GlareDetectorTests
{
    [Fact]
    public void TheCardsAreTheSameOnBothPlatforms()
    {
        Assert.Equal(0x0CE717C5u, GlareCards.Checksum(GlareCards.Card()));
        Assert.Equal(0x17657405u, GlareCards.Checksum(GlareCards.Card(glare: true)));
        Assert.Equal(0x6BF09B45u, GlareCards.Checksum(GlareCards.Card(specks: true)));
        Assert.Equal(0xD428B625u, GlareCards.Checksum(GlareCards.Card(edge: true)));
        Assert.Equal(0xC0761E05u, GlareCards.Checksum(GlareCards.Card(236, 238, 240)));
        Assert.Equal(0xF39EE005u, GlareCards.Checksum(GlareCards.Card(glare: true, specks: true, edge: true)));
    }

    [Fact]
    public void ACardWithoutAReflectionHasNoGlare()
    {
        Assert.Equal(GlareReading.None, GlareDetector.Measure(GlareCards.Card()));
        Assert.False(GlareDetector.HasGlare(GlareCards.Card()));
        // A light card whose white is not blown out.
        Assert.Equal(GlareReading.None, GlareDetector.Measure(GlareCards.Card(236, 238, 240)));
    }

    [Fact]
    public void AWhitePatchOnTheCardIsGlare()
    {
        var reading = GlareDetector.Measure(GlareCards.Card(glare: true));
        Assert.Equal(0.08509803921568627, reading.ClippedShare, 12);
        Assert.Equal(0.08509803921568627, reading.LargestBlobShare, 12);
        Assert.True(reading.HasGlare);
        Assert.True(GlareDetector.HasGlare(GlareCards.Card(glare: true)));
        Assert.Equal("Tilt to avoid glare", GlareDetector.Hint);
    }

    [Fact]
    public void WhiteSpecksAndTheEdgeAreNotGlare()
    {
        var specks = GlareDetector.Measure(GlareCards.Card(specks: true));
        Assert.Equal(0.0010980392156862745, specks.ClippedShare, 12);
        Assert.Equal(3.9215686274509805e-05, specks.LargestBlobShare, 12);
        Assert.False(specks.HasGlare);
        // A white strip along the edge lies in the band left out.
        Assert.Equal(GlareReading.None, GlareDetector.Measure(GlareCards.Card(edge: true)));
        // All three: the specks count as clipped, the largest patch is the glare's.
        var all = GlareDetector.Measure(GlareCards.Card(glare: true, specks: true, edge: true));
        Assert.Equal(0.08619607843137254, all.ClippedShare, 12);
        Assert.Equal(0.08509803921568627, all.LargestBlobShare, 12);
        Assert.True(all.HasGlare);
    }

    [Fact]
    public void OnlyTheOutlineGivenIsMeasured()
    {
        var card = GlareCards.Card(glare: true);
        Assert.Equal(GlareReading.None, GlareDetector.Measure(card, GlareCards.Rect(0, 0, 214, 270)));
        var right = GlareDetector.Measure(card, GlareCards.Rect(214, 0, 428, 270));
        Assert.Equal(0.1780855199222546, right.ClippedShare, 12);
        Assert.Equal(0.1780855199222546, right.LargestBlobShare, 12);
        var tilted = new Quad(new PointD(190, 30), new PointD(410, 60), new PointD(390, 230), new PointD(170, 200));
        var reading = GlareDetector.Measure(card, tilted);
        Assert.Equal(0.2681216850576114, reading.ClippedShare, 12);
        Assert.Equal(0.2681216850576114, reading.LargestBlobShare, 12);
        // An outline that crosses itself, or lies outside the picture, measures nothing.
        var bowTie = new Quad(new PointD(0, 0), new PointD(428, 270), new PointD(428, 0), new PointD(0, 270));
        Assert.Equal(GlareReading.None, GlareDetector.Measure(card, bowTie));
        Assert.Equal(GlareReading.None, GlareDetector.Measure(card, GlareCards.Rect(500, 300, 600, 400)));
    }

    [Fact]
    public void ALargePhotoIsMeasuredInCells()
    {
        // 1284 × 810: three times the card, so cells of 4 × 4 pixels (1284 / 400 rounded up), the same glare.
        var small = GlareCards.Card(glare: true);
        var large = new byte[small.Width * 3 * small.Height * 3 * 4];
        for (int y = 0; y < small.Height * 3; y++)
        {
            for (int x = 0; x < small.Width * 3; x++)
            {
                Array.Copy(small.Pixels, ((y / 3) * small.Width + x / 3) * 4, large, (y * small.Width * 3 + x) * 4, 4);
            }
        }
        var reading = GlareDetector.Measure(new RgbaImage(small.Width * 3, small.Height * 3, large));
        Assert.True(reading.HasGlare);
        Assert.InRange(reading.LargestBlobShare, 0.08, 0.09);
    }
}
