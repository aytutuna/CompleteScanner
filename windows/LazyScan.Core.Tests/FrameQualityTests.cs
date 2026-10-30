using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/FrameQualityTests.swift: the same frames, the same readings (to
// the last bit: integer sums divided once), recomputed by an independent model of the description.

public class FrameQualityTests
{
    [Fact]
    public void TheFramesAreTheSharedPixels()
    {
        Assert.Equal(0x44CA3AC5u, PhotoScenes.Checksum(QualityFrames.Frame()));
        Assert.Equal(0x4DC7DDC5u, PhotoScenes.Checksum(QualityFrames.Frame(printed: false)));
        Assert.Equal(0x1EB25E85u, PhotoScenes.Checksum(QualityFrames.Frame(printed: false, blur: 2)));
        Assert.Equal(0xCA5C90C9u, PhotoScenes.Checksum(QualityFrames.Frame(blur: 2)));
        Assert.Equal(0xCCACDE45u, PhotoScenes.Checksum(QualityFrames.Frame(dim: 40)));
    }

    [Fact]
    public void TheReadingsAreTakenOverThePage()
    {
        var print = FrameQuality.Measure(QualityFrames.Frame(), QualityFrames.Sheet);
        Assert.Equal(8481.175490779298, print.Sharpness, 9);
        Assert.Equal(172.04818560380727, print.Brightness, 9);
        var whole = FrameQuality.Measure(QualityFrames.Frame());
        Assert.Equal(3013.975159875271, whole.Sharpness, 9);
        Assert.Equal(112.88583333333334, whole.Brightness, 9);
        var blank = FrameQuality.Measure(QualityFrames.Frame(printed: false), QualityFrames.Sheet);
        Assert.Equal(689.5895300416419, blank.Sharpness, 9);
        Assert.Equal(195.2177275431291, blank.Brightness, 9);
        var blurred = FrameQuality.Measure(QualityFrames.Frame(printed: false, blur: 2), QualityFrames.Sheet);
        Assert.Equal(13.418652532892908, blurred.Sharpness, 9);
        Assert.Equal(195.2177275431291, blurred.Brightness, 9);
        var dim = FrameQuality.Measure(QualityFrames.Frame(dim: 40), QualityFrames.Sheet);
        Assert.Equal(189.7358715050565, dim.Sharpness, 9);
        Assert.Equal(26.668054729327782, dim.Brightness, 9);
    }

    [Fact]
    public void ASharpLitPageIsGood_ABlurredOneBlurry_ADarkOneDark()
    {
        static CaptureQuality Judged(RgbaImage frame)
        {
            var reading = FrameQuality.Measure(frame, QualityFrames.Sheet);
            return CaptureStability.Judge(reading.Sharpness, reading.Brightness);
        }
        Assert.Equal(CaptureQuality.Good, Judged(QualityFrames.Frame()));
        // A blank page is sharp by its own edges.
        Assert.Equal(CaptureQuality.Good, Judged(QualityFrames.Frame(printed: false)));
        Assert.Equal(CaptureQuality.Blurry, Judged(QualityFrames.Frame(printed: false, blur: 2)));
        Assert.Equal(CaptureQuality.Dark, Judged(QualityFrames.Frame(dim: 40)));
    }

    [Fact]
    public void TheAreaIsThePagesBoxWithAMargin()
    {
        Assert.Equal((78, 38, 242, 202), FrameQuality.Area(QualityFrames.Sheet, 320, 240));
        var tilted = new Quad(new PointD(10.5, -4), new PointD(300.2, 20), new PointD(330, 230.1), new PointD(4, 250));
        Assert.Equal((2, 0, 320, 240), FrameQuality.Area(tilted, 320, 240));
        var inside = new Quad(new PointD(100.4, 50.6), new PointD(150, 50.6), new PointD(150, 90.2), new PointD(100.4, 90.2));
        Assert.Equal((98, 48, 152, 93), FrameQuality.Area(inside, 320, 240));
        Assert.Equal((0, 0, 320, 240), FrameQuality.Area(null, 320, 240));
        // Nothing of it in the frame, or not a number: the whole frame.
        var outside = new Quad(new PointD(400, 300), new PointD(500, 300), new PointD(500, 400), new PointD(400, 400));
        Assert.Equal((0, 0, 320, 240), FrameQuality.Area(outside, 320, 240));
        var broken = new Quad(new PointD(double.NaN, 0), new PointD(10, 0), new PointD(10, 10), new PointD(0, 10));
        Assert.Equal((0, 0, 320, 240), FrameQuality.Area(broken, 320, 240));
    }

    [Fact]
    public void TheSharpnessIsTheVarianceOfTheLaplacian()
    {
        // One bright pixel in the middle of 5 × 5: over the 3 × 3 inner pixels the Laplacian is 400 at the
        // middle, −100 at its four neighbors and 0 at the corners: mean 0, variance 200000 / 9.
        var pixels = new byte[25];
        pixels[12] = 100;
        var reading = FrameQuality.Measure(new GrayImage(5, 5, pixels));
        Assert.Equal(200000.0 / 9.0, reading.Sharpness, 9);
        Assert.Equal(4.0, reading.Brightness, 9);
        // A flat frame has none; a frame too small for a neighborhood has none either.
        Assert.Equal(0, FrameQuality.Measure(GrayImage.Filled(8, 6, 90)).Sharpness);
        Assert.Equal(0, FrameQuality.Measure(GrayImage.Filled(2, 2, 90)).Sharpness);
        Assert.Equal(90, FrameQuality.Measure(GrayImage.Filled(2, 2, 90)).Brightness);
    }

    [Fact]
    public void TheShutterFiresOnlyWhenThePageIsSteadySharpAndLit()
    {
        // The sheet held still (±1 px) through a scripted sequence at 10 frames a second: blurred while the
        // camera focuses (frames 0–11), then too dark (12–17), then sharp and lit (18–29), then the same page
        // still there (30–39), then moved away and held still again (40–59). Each frame is measured as the
        // camera's frames are, over the page found.
        var blurred = QualityFrames.Frame(printed: false, blur: 2);
        var dark = QualityFrames.Frame(dim: 40);
        var sharp = QualityFrames.Frame();
        var stability = new CaptureStability();
        var fired = new List<int>();
        var log = new List<CaptureDecision>();
        for (int i = 0; i < 60; i++)
        {
            var frame = i < 12 ? blurred : i < 18 ? dark : sharp;
            double dx = (i % 2 == 0 ? 1 : -1) + (i >= 40 ? 70 : 0);
            var quad = new Quad(
                new PointD(QualityFrames.Sheet.TopLeft.X + dx, QualityFrames.Sheet.TopLeft.Y),
                new PointD(QualityFrames.Sheet.TopRight.X + dx, QualityFrames.Sheet.TopRight.Y),
                new PointD(QualityFrames.Sheet.BottomRight.X + dx, QualityFrames.Sheet.BottomRight.Y),
                new PointD(QualityFrames.Sheet.BottomLeft.X + dx, QualityFrames.Sheet.BottomLeft.Y));
            var reading = FrameQuality.Measure(frame, quad);
            var decision = stability.Update(new CaptureObservation(quad, 0.9, i * 100.0, QualityFrames.Width, QualityFrames.Height)
            {
                Sharpness = reading.Sharpness,
                Brightness = reading.Brightness,
            });
            log.Add(decision);
            if (decision.ShouldCapture) fired.Add(i);
        }
        // Held still from frame 1, long enough by frame 7: blurred and then dark, it waits; the first sharp,
        // lit frame is taken; the same page is not taken again; moved 70 px (more than 15 % of the 400 px
        // diagonal), it is a new page: steady from 41, taken at 47.
        Assert.Equal(new[] { 18, 47 }, fired);
        Assert.Equal(CaptureQuality.Blurry, log[7].Quality);
        Assert.Equal(CaptureState.Steadying, log[11].State);
        Assert.Equal(1, log[11].Progress);
        Assert.Equal(CaptureQuality.Dark, log[12].Quality);
        Assert.Equal(CaptureState.Steadying, log[17].State);
        Assert.Equal(CaptureState.Captured, log[30].State);
    }
}
