using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/QuadRefinerTests.swift: outlines put 1 % of the diagonal off the
// pages of the synthetic photos (PhotoScenes), or 2 % too large, moved back onto their edges; a page on a
// sheet whose edges lie just outside it; and a table with no page.

public class QuadRefinerTests
{
    private static readonly double Diagonal = Math.Sqrt(PhotoScenes.Width * PhotoScenes.Width + PhotoScenes.Height * PhotoScenes.Height);

    private static Quad Truth(PhotoScenes.IntHomography map) => map.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight);

    /// <summary><paramref name="quad"/> with every corner moved 1 % of the diagonal, each its own way (four patterns).</summary>
    private static Quad Off(Quad quad, int pattern)
    {
        var corners = quad.Corners;
        var moved = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            double angle = i * 1.7 + pattern * 2.3;
            moved[i] = new PointD(corners[i].X + 0.01 * Diagonal * Math.Cos(angle), corners[i].Y + 0.01 * Diagonal * Math.Sin(angle));
        }
        return new Quad(moved[0], moved[1], moved[2], moved[3]);
    }

    /// <summary><paramref name="quad"/> with every corner moved 2 % of the diagonal away from its middle.</summary>
    private static Quad Grown(Quad quad)
    {
        var c = quad.Centroid;
        var corners = quad.Corners;
        var moved = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            double dx = corners[i].X - c.X, dy = corners[i].Y - c.Y;
            double len = Math.Sqrt(dx * dx + dy * dy);
            moved[i] = new PointD(corners[i].X + 0.02 * Diagonal * dx / len, corners[i].Y + 0.02 * Diagonal * dy / len);
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
        // The page's own outline is backed by its edges all round; one 2 % too large is not. Inward the whole
        // band is searched, outward a third of it.
        Assert.True(QuadRefiner.SupportOf(photo, truth) >= 0.95);
        var grown = Grown(truth);
        Assert.True(QuadRefiner.SupportOf(photo, grown) < 0.7);
        var starts = new List<Quad>();
        // Not where growing it crosses the frame's edge (the pages near the frame's border).
        if (grown.IsInside(photo.Width, photo.Height)) starts.Add(grown);
        for (int pattern = 0; pattern < 4; pattern++) starts.Add(Off(truth, pattern));
        for (int pattern = 0; pattern < starts.Count; pattern++)
        {
            var start = starts[pattern];
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
        // Moved straight down 1 %: the header bar's top edge lies nearer than the page's top edge.
        var photo = PhotoScenes.DarkScene();
        var truth = Truth(PhotoScenes.DarkMap);
        var start = truth with
        {
            TopLeft = new PointD(truth.TopLeft.X, truth.TopLeft.Y + 0.01 * Diagonal),
            TopRight = new PointD(truth.TopRight.X, truth.TopRight.Y + 0.01 * Diagonal),
        };
        var result = QuadRefiner.Refine(photo, start);
        Assert.True(result.Quad.MaxCornerDistance(truth) <= 0.003 * Diagonal, result.Quad.ToString());
    }

    /// <summary>An upright page (231 × 327 px) at (60, 50).</summary>
    private static readonly PhotoScenes.IntHomography Upright = new(1100000, 0, 60L * 1048576, 0, 1100000, 50L * 1048576, 0, 0, 1048576);

    /// <summary>
    /// The upright page on a plain sheet of one color reaching 9 to 18 px beyond it on every side (within the
    /// band, beyond its outward reach), on a dark desk.
    /// </summary>
    private static RgbaImage OnASheet(byte r, byte g, byte b)
    {
        var folder = new PhotoScenes.IntHomography(1205862, 0, 48L * 1048576, 0, 1205862, 38L * 1048576, 0, 0, 1048576);
        var plain = new byte[PhotoScenes.PageWidth * PhotoScenes.PageHeight * 3];
        for (int i = 0; i < plain.Length; i += 3)
        {
            plain[i] = r;
            plain[i + 1] = g;
            plain[i + 2] = b;
        }
        return PhotoScenes.Scene(PhotoScenes.Backdrop.Dark, 0x3D00D010, new PhotoScenes.Lighting(0, 0, null, null),
            new PhotoScenes.Sheet(plain, PhotoScenes.PageWidth, PhotoScenes.PageHeight, folder),
            new PhotoScenes.Sheet(PhotoScenes.PageRaster(0x9A6E0010), PhotoScenes.PageWidth, PhotoScenes.PageHeight, Upright));
    }

    [Fact]
    public void APageAlreadyOnItsEdgesIsNotPushedOntoAFolderUnderIt()
    {
        var photo = OnASheet(200, 170, 110);
        var truth = Truth(Upright);
        var result = QuadRefiner.Refine(photo, truth);
        Assert.True(result.Quad.MaxCornerDistance(truth) <= 0.5, result.Quad.ToString());
        Assert.True(result.Support >= 0.95, $"support {result.Support:0.00}");
    }

    [Fact]
    public void AnEquallySharpEdgeJustOutsideDoesNotTakeTheSide()
    {
        // A gray card under the page: its edges are as sharp as the page's. Vision's outline 2 px inside the
        // page (backed by nothing within reach) moves onto the page's edges, not the card's.
        var photo = OnASheet(128, 128, 128);
        var truth = Truth(Upright);
        var inside = new Quad(new PointD(truth.TopLeft.X + 2, truth.TopLeft.Y + 2), new PointD(truth.TopRight.X - 2, truth.TopRight.Y + 2),
            new PointD(truth.BottomRight.X - 2, truth.BottomRight.Y - 2), new PointD(truth.BottomLeft.X + 2, truth.BottomLeft.Y - 2));
        var result = QuadRefiner.Refine(photo, inside);
        Assert.True(result.Refined);
        Assert.True(result.Quad.MaxCornerDistance(truth) <= 1, result.Quad.ToString());
        Assert.True(result.Support >= 0.95, $"support {result.Support:0.00}");
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
