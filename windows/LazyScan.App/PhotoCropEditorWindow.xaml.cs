using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LazyScan.App.Services;
using LazyScan.Core;

namespace LazyScan.App;

/// <summary>
/// Manual crop correction for one detected photo (port of UI/PhotoCropEditorView.swift):
/// shows the whole source page with the photo's rotated crop rectangle; corners drag to
/// resize against the fixed opposite corner, and dragging inside moves the crop. On Apply
/// the caller re-extracts the photo from the full-resolution source using <see cref="Region"/>.
///
/// Coordinates: <see cref="Region"/> is in full-resolution source pixels (top-left origin,
/// y down); the view maps it onto the letterboxed display frame with a scale + offset. The
/// display bitmap is only a downsampled copy, so all mapping goes through the SOURCE size.
/// </summary>
public partial class PhotoCropEditorWindow : Window
{
    /// <summary>Long side of the displayed (downsampled) page.</summary>
    private const int DisplayMaxSide = 2200;
    /// <summary>Corner grab radius, in view units.</summary>
    private const double HandleHitRadius = 14;
    private const double HandleSize = 14;
    private const double FrameInset = 20;

    private readonly RgbaImage _source;
    private readonly DetectedPhotoRegion _original;
    private readonly Ellipse[] _handles = new Ellipse[4];
    private DragMode? _drag;

    /// <summary>The crop being edited, in full-resolution source pixel coordinates.</summary>
    public DetectedPhotoRegion Region { get; }

    private abstract record DragMode;
    /// <summary>Dragging a corner; <paramref name="Fixed"/> is the opposite corner (image coords).</summary>
    private sealed record CornerDrag(PointD Fixed) : DragMode;
    private sealed record MoveDrag(PointD OriginalCenter, PointD StartImagePoint) : DragMode;

    /// <param name="deskew">
    /// The batch's auto-straighten setting. Without deskew the extraction crops the region's
    /// axis-aligned bounding box, so the editor edits exactly that box (angle 0) — what you
    /// frame is what you get.
    /// </param>
    public PhotoCropEditorWindow(RgbaImage source, DetectedPhotoRegion region, bool deskew)
    {
        InitializeComponent();
        _source = source;
        var start = CropGeometry.Copy(region);
        if (!deskew && start.AngleDegrees != 0)
        {
            var box = start.BoundingBox();
            start = new DetectedPhotoRegion(new PointD(box.X + box.Width / 2, box.Y + box.Height / 2),
                                            new SizeD(box.Width, box.Height), 0, region.Id);
        }
        _original = CropGeometry.Copy(start);
        Region = CropGeometry.Copy(start);
        for (int i = 0; i < 4; i++)
        {
            _handles[i] = new Ellipse
            {
                Width = HandleSize,
                Height = HandleSize,
                StrokeThickness = 2,
                IsHitTestVisible = false,
            };
            // Theme brushes, so the handles follow the accent color, light/dark and high contrast.
            _handles[i].SetResourceReference(Shape.FillProperty, "AccentFillColorDefaultBrush");
            _handles[i].SetResourceReference(Shape.StrokeProperty, "TextOnAccentFillColorPrimaryBrush");
            Host.Children.Add(_handles[i]);
        }
        Loaded += async (_, _) =>
        {
            // The crop takes the arrow keys right away.
            Host.Focus();
            // Downsample off the UI thread: the source can be hundreds of megapixels.
            try
            {
                var display = await Task.Run(() => WpfImageCodec.ToThumbnail(_source, DisplayMaxSide));
                DisplayImage.Source = display;
                LoadingText.Visibility = Visibility.Collapsed;
            }
            catch (Exception e)
            {
                LoadingText.Text = $"The page could not be shown: {e.Message}";
            }
            UpdateLayoutOverlay();
        };
    }

    // MARK: - Geometry

    /// <summary>Aspect-fit frame of the source page inside the editor viewport.</summary>
    private Rect FittedFrame()
    {
        double bw = Host.ActualWidth - FrameInset * 2;
        double bh = Host.ActualHeight - FrameInset * 2;
        if (bw <= 0 || bh <= 0) return new Rect(FrameInset, FrameInset, 0, 0);
        double pw = Math.Max(_source.Width, 1), ph = Math.Max(_source.Height, 1);
        double scale = Math.Min(bw / pw, bh / ph);
        double w = pw * scale, h = ph * scale;
        return new Rect(FrameInset + (bw - w) / 2, FrameInset + (bh - h) / 2, w, h);
    }

    private Point ViewPoint(PointD image, Rect frame) =>
        new(frame.X + image.X / Math.Max(_source.Width, 1) * frame.Width,
            frame.Y + image.Y / Math.Max(_source.Height, 1) * frame.Height);

    private PointD ImagePoint(Point view, Rect frame) =>
        frame.Width <= 0 || frame.Height <= 0
            ? new PointD(0, 0)
            : new PointD((view.X - frame.X) / frame.Width * _source.Width,
                         (view.Y - frame.Y) / frame.Height * _source.Height);

    // MARK: - Drawing

    private void UpdateLayoutOverlay()
    {
        var frame = FittedFrame();
        Canvas.SetLeft(DisplayImage, frame.X);
        Canvas.SetTop(DisplayImage, frame.Y);
        DisplayImage.Width = frame.Width;
        DisplayImage.Height = frame.Height;
        LoadingText.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(LoadingText, Host.ActualWidth / 2 - LoadingText.DesiredSize.Width / 2);
        Canvas.SetTop(LoadingText, Host.ActualHeight / 2 - LoadingText.DesiredSize.Height / 2);

        var corners = Region.Corners().Select(c => ViewPoint(c, frame)).ToArray();
        CropOutline.Points = new PointCollection(corners);
        for (int i = 0; i < 4; i++)
        {
            Canvas.SetLeft(_handles[i], corners[i].X - HandleSize / 2);
            Canvas.SetTop(_handles[i], corners[i].Y - HandleSize / 2);
        }
        UpdateDimAndGrid(frame, corners);
        SizeCaption.Text = $"{Region.Size.Width:0} × {Region.Size.Height:0} px";
        AngleCaption.Text = $"{Region.AngleDegrees:0.0}°";
        ResetButton.IsEnabled = !Region.Equals(_original);
    }

    /// <summary>
    /// Dims the page outside the crop and draws rule-of-thirds guides inside it. Both are only
    /// shown once the page is on screen; until then there is nothing to dim.
    /// </summary>
    private void UpdateDimAndGrid(Rect frame, Point[] corners)
    {
        bool shown = DisplayImage.Source is not null && frame.Width > 0 && frame.Height > 0;
        OutsideDim.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        // Guides on a crop only a few dozen pixels across are clutter, not help.
        bool roomy = (corners[1] - corners[0]).Length >= 72 && (corners[3] - corners[0]).Length >= 72;
        ThirdsGrid.Visibility = shown && roomy ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;

        var crop = new PathGeometry([new PathFigure(corners[0], [new PolyLineSegment(corners[1..], true)], true)]);
        OutsideDim.Data = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(frame), crop);

        // Corners run around the rectangle, so edges 0-1 / 3-2 and 0-3 / 1-2 face each other.
        static Point Lerp(Point a, Point b, double t) => new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);
        var grid = new GeometryGroup();
        foreach (double t in new[] { 1.0 / 3, 2.0 / 3 })
        {
            grid.Children.Add(new LineGeometry(Lerp(corners[0], corners[1], t), Lerp(corners[3], corners[2], t)));
            grid.Children.Add(new LineGeometry(Lerp(corners[0], corners[3], t), Lerp(corners[1], corners[2], t)));
        }
        ThirdsGrid.Data = grid;
    }

    /// <summary>
    /// Pointer feedback while not dragging: a diagonal resize cursor over a corner (matching that
    /// corner's direction, also for rotated crops), the move cursor inside the frame.
    /// </summary>
    private void UpdateHoverCursor(Point pointer)
    {
        var frame = FittedFrame();
        var corners = Region.Corners();
        var center = ViewPoint(Region.Center, frame);
        foreach (var corner in corners)
        {
            var view = ViewPoint(corner, frame);
            if ((view - pointer).Length <= HandleHitRadius)
            {
                var d = view - center;
                Host.Cursor = d.X * d.Y >= 0 ? Cursors.SizeNWSE : Cursors.SizeNESW;
                return;
            }
        }
        Host.Cursor = CropGeometry.PointInsidePolygon(ImagePoint(pointer, frame), corners) ? Cursors.SizeAll : null;
    }

    private void Host_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateLayoutOverlay();

    // MARK: - Dragging

    private void Host_MouseDown(object sender, MouseButtonEventArgs e)
    {
        Host.Focus();
        var frame = FittedFrame();
        var start = e.GetPosition(Host);
        var corners = Region.Corners();
        _drag = null;
        for (int i = 0; i < 4; i++)
        {
            var corner = ViewPoint(corners[i], frame);
            if ((corner - start).Length <= HandleHitRadius)
            {
                _drag = new CornerDrag(corners[(i + 2) % 4]);
                break;
            }
        }
        if (_drag is null && CropGeometry.PointInsidePolygon(ImagePoint(start, frame), corners))
        {
            _drag = new MoveDrag(Region.Center, ImagePoint(start, frame));
        }
        if (_drag is not null)
        {
            Host.CaptureMouse();
            e.Handled = true;
        }
    }

    private void Host_MouseMove(object sender, MouseEventArgs e)
    {
        if (_drag is null)
        {
            UpdateHoverCursor(e.GetPosition(Host));
            return;
        }
        var frame = FittedFrame();
        // The mouse is captured, so the pointer can leave the page (or the window): keep the
        // crop on the page instead of letting it grow into a huge, mostly blank region.
        var now = CropGeometry.ClampToPage(ImagePoint(e.GetPosition(Host), frame), _source.Width, _source.Height);
        switch (_drag)
        {
            case CornerDrag corner:
                CropGeometry.Resize(Region, now, corner.Fixed);
                break;
            case MoveDrag move:
                Region.Center = new PointD(move.OriginalCenter.X + (now.X - move.StartImagePoint.X),
                                           move.OriginalCenter.Y + (now.Y - move.StartImagePoint.Y));
                CropGeometry.KeepOnPage(Region, _source.Width, _source.Height);
                break;
        }
        UpdateLayoutOverlay();
    }

    private void Host_MouseUp(object sender, MouseButtonEventArgs e)
    {
        _drag = null;
        if (Host.IsMouseCaptured) Host.ReleaseMouseCapture();
    }

    private void Host_LostMouseCapture(object sender, MouseEventArgs e) => _drag = null;

    // MARK: - Keyboard

    /// <summary>
    /// Arrow keys move the crop; Ctrl+arrow keys resize it along its own axes with the first
    /// corner fixed (like dragging the opposite corner). A step is one display pixel; Shift
    /// makes it ten. The same page clamping as dragging applies.
    /// </summary>
    private void Host_KeyDown(object sender, KeyEventArgs e)
    {
        if (_drag is not null) return;
        int dx = e.Key switch { Key.Left => -1, Key.Right => 1, _ => 0 };
        int dy = e.Key switch { Key.Up => -1, Key.Down => 1, _ => 0 };
        if (dx == 0 && dy == 0) return;
        var frame = FittedFrame();
        double step = frame.Width > 0 ? Math.Max(1, _source.Width / frame.Width) : 1;
        var modifiers = Keyboard.Modifiers;
        if (modifiers.HasFlag(ModifierKeys.Shift)) step *= 10;
        if (modifiers.HasFlag(ModifierKeys.Control))
        {
            CropGeometry.ResizeBy(Region, dx * step, dy * step, _source.Width, _source.Height);
        }
        else
        {
            Region.Center = new PointD(Region.Center.X + dx * step, Region.Center.Y + dy * step);
            CropGeometry.KeepOnPage(Region, _source.Width, _source.Height);
        }
        UpdateLayoutOverlay();
        e.Handled = true;
    }

    // MARK: - Buttons

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        Region.Center = _original.Center;
        Region.Size = _original.Size;
        Region.AngleDegrees = _original.AngleDegrees;
        UpdateLayoutOverlay();
    }

    private void Apply_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
