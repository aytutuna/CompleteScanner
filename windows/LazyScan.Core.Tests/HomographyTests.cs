using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/HomographyTests.swift: the quad, homography and sheet-shape math.

public class HomographyTests
{
    private static readonly Quad Tilted = new(new PointD(105, 90), new PointD(258, 86), new PointD(310, 418), new PointD(48, 414));

    private static void Near(PointD expected, PointD actual, double tolerance)
    {
        Assert.True(expected.DistanceTo(actual) <= tolerance, $"expected ({expected.X}, {expected.Y}), got ({actual.X}, {actual.Y})");
    }

    [Fact]
    public void SquareToQuadMapsTheUnitSquareOntoTheCorners()
    {
        var m = Homography.SquareToQuad(Tilted)!.Value;
        Near(Tilted.TopLeft, m.Map(new PointD(0, 0)), 1e-9);
        Near(Tilted.TopRight, m.Map(new PointD(1, 0)), 1e-9);
        Near(Tilted.BottomRight, m.Map(new PointD(1, 1)), 1e-9);
        Near(Tilted.BottomLeft, m.Map(new PointD(0, 1)), 1e-9);
    }

    [Fact]
    public void RectToQuadAndQuadToRectUndoEachOther()
    {
        var forward = Homography.RectToQuad(210, 297, Tilted)!.Value;
        var back = Homography.QuadToRect(Tilted, 210, 297)!.Value;
        Near(Tilted.BottomRight, forward.Map(new PointD(210, 297)), 1e-9);
        var rng = new TestPages.Rng(0x40A0A001);
        for (int i = 0; i < 50; i++)
        {
            var p = new PointD(rng.Below(2100) / 10.0, rng.Below(2970) / 10.0);
            Near(p, back.Map(forward.Map(p)), 1e-9);
        }
    }

    [Fact]
    public void SolvingTheEquationsGivesTheClosedForm()
    {
        var closed = Homography.RectToQuad(210, 297, Tilted)!.Value;
        var solved = Homography.FromCorrespondences(
            [new PointD(0, 0), new PointD(210, 0), new PointD(210, 297), new PointD(0, 297)], Tilted.Corners)!.Value;
        var rng = new TestPages.Rng(0x40A0A002);
        for (int i = 0; i < 50; i++)
        {
            var p = new PointD(rng.Below(2100) / 10.0, rng.Below(2970) / 10.0);
            Near(closed.Map(p), solved.Map(p), 1e-7);
        }
    }

    [Fact]
    public void InverseAndProductCompose()
    {
        var a = Homography.RectToQuad(100, 100, Tilted)!.Value;
        var b = new Homography(1.5, 0.2, 10, -0.1, 0.9, 5, 0.0004, -0.0002, 1);
        var ab = Homography.Multiply(a, b);
        var inverse = ab.Inverse()!.Value;
        var p = new PointD(37.5, 61.25);
        Near(a.Map(b.Map(p)), ab.Map(p), 1e-9);
        Near(p, inverse.Map(ab.Map(p)), 1e-9);
        Near(p, Homography.Multiply(ab, inverse).Map(p), 1e-9);
        Near(p, Homography.Identity.Map(p), 0);
    }

    [Fact]
    public void ThreeCornersInLineHaveNoMap()
    {
        var flat = new Quad(new PointD(0, 0), new PointD(10, 0), new PointD(20, 0), new PointD(5, 10));
        Assert.Null(Homography.FromCorrespondences(flat.Corners, Tilted.Corners));
        Assert.Null(new Homography(1, 2, 3, 2, 4, 6, 0, 0, 1).Inverse());
        Assert.Null(Homography.RectToQuad(0, 10, Tilted));
    }

    [Fact]
    public void CornersAreNamedClockwiseFromTheTopLeft()
    {
        // Counterclockwise, starting at the bottom-right corner.
        var q = Quad.FromCorners([Tilted.BottomRight, Tilted.TopRight, Tilted.TopLeft, Tilted.BottomLeft]);
        Assert.Equal(Tilted, q);
        Assert.True(q.IsConvex);
        Assert.True(q.SignedArea > 0);
        // A diamond: the top edge is the higher of the two upper edges' midpoints, the left one on a tie.
        var diamond = Quad.FromCorners([new PointD(50, 0), new PointD(100, 50), new PointD(50, 100), new PointD(0, 50)]);
        Assert.Equal(new PointD(0, 50), diamond.TopLeft);
        Assert.Equal(new PointD(50, 0), diamond.TopRight);
    }

    [Fact]
    public void QuadMeasures()
    {
        var square = new Quad(new PointD(0, 0), new PointD(10, 0), new PointD(10, 10), new PointD(0, 10));
        Assert.Equal(100, square.Area);
        Assert.Equal(new PointD(5, 5), square.Centroid);
        Assert.True(square.Contains(new PointD(5, 5)));
        Assert.False(square.Contains(new PointD(11, 5)));
        Assert.True(square.Contains(new PointD(11, 5), 1.5));
        Assert.True(square.IsInside(10, 10));
        Assert.False(square.IsInside(9, 10));
        var bowtie = new Quad(new PointD(0, 0), new PointD(10, 10), new PointD(10, 0), new PointD(0, 10));
        Assert.False(bowtie.IsConvex);
        Assert.Equal(5, square.MaxCornerDistance(square.Scaled(1.5, 1)), 9);
    }

    /// <summary>The corners of a w × h rectangle seen by a pinhole camera (focal f, centered on a cw × ch photo).</summary>
    private static Quad CameraView(double w, double h, double tiltX, double tiltY, double turn, double distance, double f, double cw, double ch)
    {
        double ax = tiltX * Math.PI / 180, ay = tiltY * Math.PI / 180, az = turn * Math.PI / 180;
        var corners = new List<PointD>();
        foreach (var (u, v) in new[] { (-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2) })
        {
            // Turn in the plane, tilt about x, then about y, then push away from the camera.
            double x = u * Math.Cos(az) - v * Math.Sin(az), y = u * Math.Sin(az) + v * Math.Cos(az), z = 0;
            double y1 = y * Math.Cos(ax) - z * Math.Sin(ax), z1 = y * Math.Sin(ax) + z * Math.Cos(ax);
            double x2 = x * Math.Cos(ay) + z1 * Math.Sin(ay), z2 = -x * Math.Sin(ay) + z1 * Math.Cos(ay);
            z2 += distance;
            corners.Add(new PointD(cw / 2 + f * x2 / z2, ch / 2 + f * y1 / z2));
        }
        return Quad.FromCorners(corners);
    }

    [Fact]
    public void TheSheetsShapeIsRecoveredFromATiltedView()
    {
        // An A4 sheet tilted 30° and 15°, turned 10°, by a camera with a 900 px focal length.
        var view = CameraView(210, 297, 30, 15, 10, 520, 900, 1200, 1600);
        var estimate = PerspectiveCorrector.EstimateAspect(view, 1200, 1600);
        Assert.NotNull(estimate.FocalLength);
        Assert.InRange(estimate.FocalLength!.Value, 891, 909);
        Assert.InRange(estimate.LongOverShort, 1.414 * 0.995, 1.414 * 1.005);
        Assert.Equal(PaperSize.A4, PerspectiveCorrector.MatchPaper(estimate.LongOverShort)!.Size);

        // An ID card tilted 35°.
        var card = CameraView(85.6, 53.98, 35, 0, 5, 160, 1000, 1500, 2000);
        var cardEstimate = PerspectiveCorrector.EstimateAspect(card, 1500, 2000);
        Assert.InRange(cardEstimate.LongOverShort, 1.586 * 0.99, 1.586 * 1.01);
        Assert.Equal(PaperSize.IdCard, PerspectiveCorrector.MatchPaper(cardEstimate.LongOverShort)!.Size);
    }

    [Fact]
    public void ASheetSeenStraightOnTakesItsEdgeLengths()
    {
        var straight = new Quad(new PointD(100, 100), new PointD(400, 100), new PointD(400, 300), new PointD(100, 300));
        var estimate = PerspectiveCorrector.EstimateAspect(straight, 800, 600);
        Assert.Null(estimate.FocalLength);
        Assert.Equal(1.5, estimate.WidthOverHeight, 9);
    }

    [Fact]
    public void PaperSizesMatchWithinThreePercent()
    {
        Assert.Equal(PaperSize.A4, PerspectiveCorrector.MatchPaper(1.40)!.Size);
        Assert.Equal(PaperSize.Letter, PerspectiveCorrector.MatchPaper(1.30)!.Size);
        Assert.Equal(PaperSize.Legal, PerspectiveCorrector.MatchPaper(1.64)!.Size);
        Assert.Equal(PaperSize.IdCard, PerspectiveCorrector.MatchPaper(1.59)!.Size);
        Assert.Null(PerspectiveCorrector.MatchPaper(1.50));
        Assert.Null(PerspectiveCorrector.MatchPaper(2.5));
        Assert.Null(PerspectiveCorrector.MatchPaper(1.0));
    }
}
