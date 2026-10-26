using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/QuadRefinerTests.swift: outlines put 2 % of the diagonal off the
// pages of the synthetic photos (PhotoScenes) and moved back onto their edges, and a table with no page.

public class QuadRefinerTests
{
    private static readonly double Diagonal = Math.Sqrt(PhotoScenes.Width * PhotoScenes.Width + PhotoScenes.Height * PhotoScenes.Height);

    private static Quad Truth(PhotoScenes.IntHomography map) => map.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight);

    /// <summary><paramref name="quad"/> with every corner moved 2 % of the diagonal, each its own way (four patterns).</summary>
    private static Quad Off(Quad quad, int pattern)
    {
        var corners = quad.Corners;
        var moved = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            double angle = i * 1.7 + pattern * 2.3;
            moved[i] = new PointD(corners[i].X + 0.02 * Diagonal * Math.Cos(angle), corners[i].Y + 0.02 * Diagonal * Math.Sin(angle));
        }
        return new Quad(moved[0], moved[1], moved[2], moved[3]);
    }

    public static TheoryData<string> Pages => ["wood", "dark", "light", "similar", "roundTrip", "bottomGap", "rightGap"];

    private static (RgbaImage Photo, Quad Truth) Scene(string name) => name switch
    {
        "wood" => (PhotoScenes.WoodScene(), Truth(PhotoScenes.WoodMap)),
        "dark" => (PhotoScenes.DarkScene(), Truth(PhotoScenes.DarkMap)),
        "light" => (PhotoScenes.LightScene(), Truth(PhotoScenes.LightMap)),
        "similar" => (PhotoScenes.SimilarScene(), Truth(PhotoScenes.SimilarMap)),
        "roundTrip" => (PhotoScenes.RoundTripScene(), Truth(PhotoScenes.RoundTripMap)),
        "bottomGap" => (PhotoScenes.BottomGapScene(8), Truth(PhotoScenes.BottomGapMap(8))),
        _ => (PhotoScenes.RightGapScene(4), Truth(PhotoScenes.RightGapMap(4))),
    };

    [Theory]
    [MemberData(nameof(Pages))]
    public void AnOutlineOffThePageIsMovedBackOntoItsEdges(string name)
    {
        var (photo, truth) = Scene(name);
        // The page's own outline is backed by its edges all round; one 2 % off is not.
        Assert.True(QuadRefiner.SupportOf(photo, truth) >= 0.95);
        for (int pattern = 0; pattern < 4; pattern++)
        {
            var start = Off(truth, pattern);
            Assert.True(QuadRefiner.SupportOf(photo, start) < 0.7, $"pattern {pattern}");
            var result = QuadRefiner.Refine(photo, start);
            Assert.True(result.Refined, $"pattern {pattern}");
            double error = result.Quad.MaxCornerDistance(truth);
            Assert.True(error <= 0.003 * Diagonal, $"pattern {pattern}: corner error {error:0.00} px, refined to {result.Quad}");
            Assert.True(result.Support >= 0.95, $"pattern {pattern}: support {result.Support:0.00}");
        }
    }

    [Fact]
    public void AHeaderBarJustInsideThePageDoesNotPullItsTopEdge()
    {
        // Moved straight down 2 %: the header bar's edges lie nearer than the page's top edge.
        var photo = PhotoScenes.DarkScene();
        var truth = Truth(PhotoScenes.DarkMap);
        var start = truth with
        {
            TopLeft = new PointD(truth.TopLeft.X, truth.TopLeft.Y + 0.02 * Diagonal),
            TopRight = new PointD(truth.TopRight.X, truth.TopRight.Y + 0.02 * Diagonal),
        };
        var result = QuadRefiner.Refine(photo, start);
        Assert.True(result.Quad.MaxCornerDistance(truth) <= 0.003 * Diagonal, result.Quad.ToString());
    }

    [Fact]
    public void ATableWithNoPageLeavesTheOutlineAlone()
    {
        var photo = PhotoScenes.PlainScene();
        var start = Off(Truth(PhotoScenes.WoodMap), 0);
        var result = QuadRefiner.Refine(photo, start);
        Assert.False(result.Refined);
        Assert.Equal(start, result.Quad);
        Assert.True(result.Support < 0.2, $"support {result.Support:0.00}");
    }

    [Fact]
    public void ALargePhotoIsSearchedSmall_andTheCornersComeBackInItsPixels()
    {
        // The wood scene three times as large (1080 × 1440): searched at 1000 px long, answered in its own pixels.
        var small = PhotoScenes.WoodScene();
        var photo = small.Resized(small.Width * 3, small.Height * 3);
        var truth = Truth(PhotoScenes.WoodMap).Scaled(3, 3);
        var result = QuadRefiner.Refine(photo, Off(truth, 1));
        Assert.True(result.Refined);
        Assert.True(result.Quad.MaxCornerDistance(truth) <= 0.003 * 3 * Diagonal, result.Quad.ToString());
    }
}
