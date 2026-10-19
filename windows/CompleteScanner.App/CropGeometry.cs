using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// Pure geometry of the photo crop editor (port of the helpers in
/// UI/PhotoCropEditorView.swift). Everything is in source-image pixel coordinates: origin
/// top-left, x right, y down — the DetectedPhotoRegion convention — so WPF's y-down view
/// space maps onto it with a plain scale and offset, no flip.
/// </summary>
public static class CropGeometry
{
    /// <summary>Smallest crop side the editor allows, in source pixels.</summary>
    public const double MinSide = 24;

    /// <summary>
    /// Resize <paramref name="region"/> so that <paramref name="fixedCorner"/> stays put and
    /// the dragged corner follows <paramref name="dragged"/>: the drag vector is expressed in
    /// the region's rotated frame; its absolute components become the new width/height and
    /// the center moves to the middle of the diagonal. The angle is unchanged.
    /// </summary>
    public static void Resize(DetectedPhotoRegion region, PointD dragged, PointD fixedCorner)
    {
        double a = region.AngleDegrees * Math.PI / 180;
        var ux = new PointD(Math.Cos(a), Math.Sin(a));   // local +x axis in image coords
        var uy = new PointD(-Math.Sin(a), Math.Cos(a));  // local +y axis
        double vx = dragged.X - fixedCorner.X;
        double vy = dragged.Y - fixedCorner.Y;
        double lx = vx * ux.X + vy * ux.Y;
        double ly = vx * uy.X + vy * uy.Y;
        lx = lx < 0 ? Math.Min(lx, -MinSide) : Math.Max(lx, MinSide);
        ly = ly < 0 ? Math.Min(ly, -MinSide) : Math.Max(ly, MinSide);
        region.Size = new SizeD(Math.Abs(lx), Math.Abs(ly));
        region.Center = new PointD(fixedCorner.X + (ux.X * lx + uy.X * ly) / 2,
                                   fixedCorner.Y + (ux.Y * lx + uy.Y * ly) / 2);
    }

    /// <summary>
    /// Keyboard resize: change the size of <paramref name="region"/> by
    /// (<paramref name="dx"/>, <paramref name="dy"/>) along its own axes, keeping the first
    /// corner fixed as if the opposite corner were dragged. Shrinking stops at
    /// <see cref="MinSide"/> instead of flipping past the fixed corner, and the moved corner
    /// stays on the page.
    /// </summary>
    public static void ResizeBy(DetectedPhotoRegion region, double dx, double dy,
                                double pageWidth, double pageHeight)
    {
        var corners = region.Corners();
        double a = region.AngleDegrees * Math.PI / 180;
        double lx = Math.Max(region.Size.Width + dx, MinSide) - region.Size.Width;
        double ly = Math.Max(region.Size.Height + dy, MinSide) - region.Size.Height;
        var dragged = new PointD(corners[2].X + Math.Cos(a) * lx - Math.Sin(a) * ly,
                                 corners[2].Y + Math.Sin(a) * lx + Math.Cos(a) * ly);
        Resize(region, ClampToPage(dragged, pageWidth, pageHeight), corners[0]);
    }

    /// <summary>True when <paramref name="p"/> lies inside the convex polygon <paramref name="corners"/>.</summary>
    public static bool PointInsidePolygon(PointD p, IReadOnlyList<PointD> corners)
    {
        if (corners.Count < 3) return false;
        double sign = 0;
        for (int i = 0; i < corners.Count; i++)
        {
            var a = corners[i];
            var b = corners[(i + 1) % corners.Count];
            double cross = (b.X - a.X) * (p.Y - a.Y) - (b.Y - a.Y) * (p.X - a.X);
            if (cross != 0)
            {
                if (sign == 0) sign = cross > 0 ? 1 : -1;
                else if ((cross > 0 ? 1.0 : -1.0) != sign) return false;
            }
        }
        return true;
    }

    /// <summary><paramref name="p"/> clamped into the page rectangle [0, width] x [0, height].</summary>
    public static PointD ClampToPage(PointD p, double width, double height) =>
        new(Math.Clamp(p.X, 0, width), Math.Clamp(p.Y, 0, height));

    /// <summary>
    /// Move <paramref name="region"/> (without resizing) so its bounding box stays on the page;
    /// a crop wider/taller than the page is centered on that axis.
    /// </summary>
    public static void KeepOnPage(DetectedPhotoRegion region, double width, double height)
    {
        var box = region.BoundingBox();
        double hx = box.Width / 2, hy = box.Height / 2;
        double cx = box.Width >= width ? width / 2 : Math.Clamp(region.Center.X, hx, width - hx);
        double cy = box.Height >= height ? height / 2 : Math.Clamp(region.Center.Y, hy, height - hy);
        region.Center = new PointD(cx, cy);
    }

    public static DetectedPhotoRegion Copy(DetectedPhotoRegion region) =>
        new(region.Center, region.Size, region.AngleDegrees, region.Id);
}
