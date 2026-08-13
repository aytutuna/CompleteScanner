using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Windows-side additions pinning the geometry primitives the detector builds on
// (the Swift suite exercises these indirectly through PhotoDetectorTests).

public class GeometryTests
{
    [Fact]
    public void ConvexHullOfSquareKeepsCorners()
    {
        var points = new List<PointD>
        {
            new(0, 0), new(10, 0), new(10, 10), new(0, 10),
            new(5, 5), new(2, 3), new(7, 8), // interior points must be discarded
        };
        var hull = Geometry.ConvexHull(points);
        Assert.Equal(4, hull.Count);
        Assert.Contains(new PointD(0, 0), hull);
        Assert.Contains(new PointD(10, 0), hull);
        Assert.Contains(new PointD(10, 10), hull);
        Assert.Contains(new PointD(0, 10), hull);
    }

    [Fact]
    public void ConvexHullDegenerateInputs()
    {
        Assert.Empty(Geometry.ConvexHull(new List<PointD>()));
        Assert.Single(Geometry.ConvexHull(new List<PointD> { new(3, 4) }));
        // Collinear points reduce to the two extreme endpoints.
        var hull = Geometry.ConvexHull(new List<PointD> { new(0, 0), new(5, 5), new(10, 10) });
        Assert.Equal(2, hull.Count);
        Assert.Contains(new PointD(0, 0), hull);
        Assert.Contains(new PointD(10, 10), hull);
    }

    [Fact]
    public void MinAreaRectOfAxisAlignedRectangle()
    {
        var hull = Geometry.ConvexHull(new List<PointD>
        {
            new(10, 20), new(110, 20), new(110, 70), new(10, 70),
        });
        var rect = Geometry.MinAreaRectOf(hull);
        Assert.Equal(60, rect.Center.X, 3);
        Assert.Equal(45, rect.Center.Y, 3);
        Assert.Equal(100, rect.Size.Width, 3);
        Assert.Equal(50, rect.Size.Height, 3);
        Assert.Equal(0, Math.Abs(rect.AngleDegrees), 3);
    }

    [Fact]
    public void MinAreaRectRecoversRotation()
    {
        // A 200x100 rectangle rotated by 30° (clockwise on screen, y-down convention).
        var region = new DetectedPhotoRegion(new PointD(300, 250), new SizeD(200, 100), 30);
        var rect = Geometry.MinAreaRectOf(Geometry.ConvexHull(region.Corners()));
        Assert.Equal(300, rect.Center.X, 3);
        Assert.Equal(250, rect.Center.Y, 3);
        Assert.Equal(200, rect.Size.Width, 2);
        Assert.Equal(100, rect.Size.Height, 2);
        Assert.Equal(30, rect.AngleDegrees, 2);
    }

    [Fact]
    public void MinAreaRectAngleNormalizedInto45Range()
    {
        // A rectangle at 60° must come back as -30° with width/height swapped.
        var region = new DetectedPhotoRegion(new PointD(0, 0), new SizeD(200, 100), 60);
        var rect = Geometry.MinAreaRectOf(Geometry.ConvexHull(region.Corners()));
        Assert.True(rect.AngleDegrees > -45 && rect.AngleDegrees <= 45,
                    $"angle {rect.AngleDegrees} outside (-45, 45]");
        Assert.Equal(100, rect.Size.Width, 2);
        Assert.Equal(200, rect.Size.Height, 2);
        Assert.Equal(-30, rect.AngleDegrees, 2);
    }

    [Fact]
    public void RegionCornersFollowConvention()
    {
        // Unrotated: TL, TR, BR, BL around the center.
        var region = new DetectedPhotoRegion(new PointD(50, 40), new SizeD(20, 10), 0);
        var corners = region.Corners();
        Assert.Equal(new PointD(40, 35), corners[0]);
        Assert.Equal(new PointD(60, 35), corners[1]);
        Assert.Equal(new PointD(60, 45), corners[2]);
        Assert.Equal(new PointD(40, 45), corners[3]);
    }
}
