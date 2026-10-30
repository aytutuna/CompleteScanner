using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/PhotoDocumentDetectorTests.swift: the same synthetic photos
// (PhotoScenes, byte-identical, checked by checksum) and the same expectations.

public class PhotoDocumentDetectorTests
{
    /// <summary>1 % of the photo's diagonal (360 × 480: 6 px).</summary>
    private static readonly double Tolerance = 0.01 * Math.Sqrt(PhotoScenes.Width * PhotoScenes.Width + PhotoScenes.Height * PhotoScenes.Height);

    private static Quad Expected(PhotoScenes.IntHomography map) => map.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight);

    private static void AssertFound(PhotoDocumentDetection result, Quad expected, double tolerance)
    {
        Assert.True(result.Quad is not null, $"no page: {result.Rejection}, candidate {result.Candidate}");
        Assert.Equal(PhotoDocumentRejection.None, result.Rejection);
        double error = result.Quad!.Value.MaxCornerDistance(expected);
        Assert.True(error <= tolerance, $"corner error {error:0.00} px > {tolerance:0.00}: found {result.Quad}, expected {expected}");
        Assert.True(result.Confidence >= PhotoDocumentDetector.AcceptScore, $"confidence {result.Confidence}");
    }

    [Fact]
    public void ScenesAreTheSameOnBothPlatforms()
    {
        Assert.Equal(0x5D456758u, PhotoScenes.Checksum(PhotoScenes.WoodScene()));
        Assert.Equal(0x37A28CB9u, PhotoScenes.Checksum(PhotoScenes.DarkScene()));
        Assert.Equal(0xE9BED0A0u, PhotoScenes.Checksum(PhotoScenes.LightScene()));
        Assert.Equal(0xB26BD827u, PhotoScenes.Checksum(PhotoScenes.SimilarScene()));
        Assert.Equal(0xB93EAFBAu, PhotoScenes.Checksum(PhotoScenes.NoPageScene()));
        Assert.Equal(0x488C62C7u, PhotoScenes.Checksum(PhotoScenes.PlainScene()));
        Assert.Equal(0xB990DDDAu, PhotoScenes.Checksum(PhotoScenes.CutOffScene()));
        Assert.Equal(0x231A4514u, PhotoScenes.Checksum(PhotoScenes.OverlapScene()));
        Assert.Equal(0x999E64F6u, PhotoScenes.Checksum(PhotoScenes.TwoPagesScene()));
        Assert.Equal(0xB97E5292u, PhotoScenes.Checksum(PhotoScenes.RoundTripScene()));
        Assert.Equal(0x2A264F0Eu, PhotoScenes.Checksum(PhotoScenes.BottomGapScene(3)));
        Assert.Equal(0x1C63A221u, PhotoScenes.Checksum(PhotoScenes.BottomGapScene(5)));
        Assert.Equal(0xE83DD873u, PhotoScenes.Checksum(PhotoScenes.BottomGapScene(8)));
        Assert.Equal(0x7DC6FC59u, PhotoScenes.Checksum(PhotoScenes.BottomGapScene(-15)));
        Assert.Equal(0xCDB3F5EFu, PhotoScenes.Checksum(PhotoScenes.RightGapScene(4)));
    }

    [Fact]
    public void FindsAPageOnAWoodenTable()
    {
        AssertFound(PhotoDocumentDetector.Detect(PhotoScenes.WoodScene()), Expected(PhotoScenes.WoodMap), Tolerance);
    }

    [Fact]
    public void FindsAPageOnADarkDeskWithGlareOnItsEdge()
    {
        AssertFound(PhotoDocumentDetector.Detect(PhotoScenes.DarkScene()), Expected(PhotoScenes.DarkMap), Tolerance);
    }

    [Fact]
    public void FindsAPageOnALightDeskInThePhonesShadow()
    {
        AssertFound(PhotoDocumentDetector.Detect(PhotoScenes.LightScene()), Expected(PhotoScenes.LightMap), Tolerance);
    }

    [Fact]
    public void FindsAPageOnATableOfNearlyItsColor()
    {
        AssertFound(PhotoDocumentDetector.Detect(PhotoScenes.SimilarScene()), Expected(PhotoScenes.SimilarMap), Tolerance);
    }

    [Fact]
    public void FindsNothingWhereThereIsNoPage()
    {
        foreach (var scene in new[] { PhotoScenes.NoPageScene(), PhotoScenes.PlainScene() })
        {
            var result = PhotoDocumentDetector.Detect(scene);
            Assert.Null(result.Quad);
            Assert.Equal(0, result.Confidence);
            Assert.Contains(result.Rejection, new[] { PhotoDocumentRejection.NothingFound, PhotoDocumentRejection.LowConfidence });
        }
    }

    [Fact]
    public void RefusesAPageCutOffByTheFrame()
    {
        var result = PhotoDocumentDetector.Detect(PhotoScenes.CutOffScene());
        Assert.Null(result.Quad);
        Assert.Equal(PhotoDocumentRejection.CutOff, result.Rejection);
        Assert.NotNull(result.Candidate);
        Assert.False(result.Candidate!.Value.IsInside(PhotoScenes.Width, PhotoScenes.Height));
    }

    [Fact]
    public void FindsAPageWhoseEdgeLiesCloseToTheFramesBorder()
    {
        // 3 to 8 px of table between the page and the frame's border: every corner is in the frame.
        foreach (int gap in new[] { 3, 5, 8 })
        {
            var result = PhotoDocumentDetector.Detect(PhotoScenes.BottomGapScene(gap));
            AssertFound(result, Expected(PhotoScenes.BottomGapMap(gap)), Tolerance);
        }
        AssertFound(PhotoDocumentDetector.Detect(PhotoScenes.RightGapScene(4)), Expected(PhotoScenes.RightGapMap(4)), Tolerance);
    }

    [Fact]
    public void RefusesAPageRunningOffTheBottomOfTheFrame()
    {
        var result = PhotoDocumentDetector.Detect(PhotoScenes.BottomGapScene(-15));
        Assert.Null(result.Quad);
        Assert.Equal(PhotoDocumentRejection.CutOff, result.Rejection);
        Assert.NotNull(result.Candidate);
    }

    [Fact]
    public void TakesTheLargerOfTwoOverlappingPages()
    {
        AssertFound(PhotoDocumentDetector.Detect(PhotoScenes.OverlapScene()), Expected(PhotoScenes.TopMap), Tolerance);
    }

    [Fact]
    public void RefusesTwoPagesOfTheSameSize()
    {
        var result = PhotoDocumentDetector.Detect(PhotoScenes.TwoPagesScene());
        Assert.Null(result.Quad);
        Assert.Equal(PhotoDocumentRejection.Ambiguous, result.Rejection);
        Assert.NotNull(result.Candidate);
    }

    [Fact]
    public void AnalysesASmallerCopyAndAnswersInThePhotosPixels()
    {
        // The photo enlarged twice, analysed at 240 px: the corners come back in the large photo's pixels.
        var scene = PhotoScenes.WoodScene();
        var large = new RgbaImage(scene.Width * 2, scene.Height * 2, new byte[scene.Width * scene.Height * 16]);
        for (int y = 0; y < large.Height; y++)
        {
            for (int x = 0; x < large.Width; x++)
            {
                Array.Copy(scene.Pixels, ((y / 2) * scene.Width + x / 2) * 4, large.Pixels, (y * large.Width + x) * 4, 4);
            }
        }
        var options = new PhotoDocumentOptions { AnalysisLongSide = 240 };
        var result = PhotoDocumentDetector.Detect(large, null, options);
        AssertFound(result, Expected(PhotoScenes.WoodMap).Scaled(2, 2), 2 * Tolerance);
    }

    [Fact]
    public void AHintFromThePreviousFrameKeepsThePage()
    {
        var expected = Expected(PhotoScenes.LightMap);
        var plain = PhotoDocumentDetector.Detect(PhotoScenes.LightScene());
        var hint = new Quad(
            new PointD(expected.TopLeft.X + 4, expected.TopLeft.Y - 3), new PointD(expected.TopRight.X - 3, expected.TopRight.Y + 4),
            new PointD(expected.BottomRight.X + 2, expected.BottomRight.Y + 3), new PointD(expected.BottomLeft.X - 4, expected.BottomLeft.Y - 2));
        var hinted = PhotoDocumentDetector.Detect(PhotoScenes.LightScene(), hint);
        AssertFound(hinted, expected, Tolerance);
        Assert.True(hinted.Confidence >= plain.Confidence, $"{hinted.Confidence} < {plain.Confidence}");
    }

    [Fact]
    public void OtsuSplitsTwoLevels()
    {
        var histogram = new int[256];
        histogram[40] = 300;
        histogram[45] = 200;
        histogram[200] = 400;
        histogram[210] = 100;
        int t = PhotoDocumentDetector.Otsu(histogram, 1000);
        Assert.InRange(t, 45, 199);
    }

    [Fact]
    public void ALineIsFittedPastAnOutlier()
    {
        var points = new List<PointD>();
        for (int i = 0; i < 20; i++) points.Add(new PointD(10 + 5 * i, 20 + 2.5 * i + (i % 2 == 0 ? 0.3 : -0.3)));
        points.Add(new PointD(50, 90));
        var line = PhotoDocumentDetector.FitLine(points);
        // y = 20 + 0.5 (x - 10): every inlier within half a pixel of the line.
        for (int i = 0; i < 20; i++) Assert.True(Math.Abs(line.Distance(points[i].X, points[i].Y)) < 0.5);
        Assert.True(Math.Abs(line.Distance(50, 90)) > 40);
    }

    [Fact]
    public void TheLargestQuadOfAnOutlineIsItsRectangle()
    {
        // A rectangle with its corners slightly cut, as a mask's hull comes out.
        var hull = new List<PointD>
        {
            new(10, 12), new(12, 10), new(98, 10), new(100, 12), new(100, 58), new(98, 60), new(12, 60), new(10, 58),
        };
        var quad = PhotoDocumentDetector.LargestQuad(PhotoDocumentDetector.Simplify(hull, 40))!.Value;
        Assert.True(quad.IsConvex);
        Assert.InRange(quad.Area, 4300, 4500);
        Assert.Equal(3, PhotoDocumentDetector.Simplify(hull, 3).Count);
    }

    [Fact]
    public void CornerDistanceIgnoresWhichCornerComesFirst()
    {
        var q = Expected(PhotoScenes.WoodMap);
        var turned = new Quad(q.TopRight, q.BottomRight, q.BottomLeft, q.TopLeft);
        Assert.Equal(0, PhotoDocumentDetector.CornerDistance(q, turned), 9);
        Assert.True(PhotoDocumentDetector.Separated(q, q.Scaled(1, 1).Scaled(0.5, 0.5), 0) == false);
        var apart = new Quad(new PointD(400, 0), new PointD(500, 0), new PointD(500, 100), new PointD(400, 100));
        Assert.True(PhotoDocumentDetector.Separated(q, apart, 5));
    }

    [Fact]
    public void ThePagesShapeIsReported()
    {
        var result = PhotoDocumentDetector.Detect(PhotoScenes.WoodScene());
        Assert.NotNull(result.Aspect);
        Assert.InRange(result.Aspect!.Value.LongOverShort, 1.2, 1.6);
    }
}
