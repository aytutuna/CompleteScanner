using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// The corner editor of a photo of a document whose page was not found clearly
/// (<see cref="PhotoImport.Plan(RgbaImage)"/>): the whole photo with the page's four corners, each
/// dragged on its own onto a corner of the page (a magnifier shows the photo around the corner being
/// moved), or moved with the arrow keys. Use corners cuts the page out along them, Use whole
/// photo takes the photo as it is, and Skip leaves the photo out. Built like the crop editor
/// (<see cref="PhotoCropEditorWindow"/>); the Mac's twin is UI/PhotoCornersEditorView.swift.
///
/// Coordinates: <see cref="Corners"/> are in the photo's pixels (top-left origin, y down); the view
/// maps them onto the letterboxed display frame with a scale and an offset. The display bitmap is a
/// downsampled copy, so all mapping goes through the photo's size.
/// </summary>
public partial class PhotoCornersWindow : Window
{
    /// <summary>Long side of the displayed (downsampled) photo.</summary>
    private const int DisplayMaxSide = 2200;
    /// <summary>Corner grab radius, in view units.</summary>
    private const double HandleHitRadius = 16;
    private const double HandleSize = 14;
    private const double SelectedHandleSize = 18;
    private const double FrameInset = 20;
    /// <summary>How much larger the magnifier shows the photo than the stage does.</summary>
    private const double LoupeZoom = 3;
    /// <summary>The gap between the corner and the magnifier's edge, in view units.</summary>
    private const double LoupeGap = 18;

    private readonly RgbaImage _photo;
    private readonly Quad _start;
    private readonly Ellipse[] _handles = new Ellipse[4];
    private readonly ImageBrush _loupeBrush = new() { ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill };
    /// <summary>The corner being dragged, if any.</summary>
    private int? _dragging;
    /// <summary>The corner the arrow keys move (0 top-left … 3 bottom-left, as placed).</summary>
    private int _selected;
    /// <summary>The magnifier is shown: while a corner is dragged or moved with the keys.</summary>
    private bool _showLoupe;

    /// <summary>The corners as placed, in the photo's pixels.</summary>
    public Quad Corners { get; private set; }

    /// <summary>What the user chose; <see cref="PhotoCornersAnswer.Skip"/> until a button is pressed.</summary>
    public PhotoCornersAnswer Answer { get; private set; } = PhotoCornersAnswer.Skip;

    /// <summary>Done once the photo is on the stage (or could not be shown), for checks that render the window off screen.</summary>
    internal Task Ready { get; }

    public PhotoCornersWindow(PhotoCornersRequest request)
    {
        InitializeComponent();
        _photo = request.Photo;
        _start = request.Plan.Corners;
        Corners = _start;
        Title = PhotoImport.EditorTitle;
        TitleText.Text = PhotoImport.EditorTitle;
        string reason = PhotoImport.ReasonText(request.Plan.Reason);
        ReasonText.Text = reason;
        ReasonPanel.Visibility = reason.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        // What to do on screen; the keys behind the ⓘ.
        HelpText.Text = PhotoImport.EditorHelp;
        KeyboardInfoButton.InfoText = PhotoImport.EditorKeys;
        // "Photo 2 of 3"; the file's name is the tooltip.
        CounterText.Text = PhotoImport.Counter(request.Number, request.Count, request.FileName);
        CounterText.ToolTip = request.FileName;
        AutomationProperties.SetName(CounterText, PhotoImport.CounterName(request.Number, request.Count, request.FileName));
        WholePhotoButton.Content = PhotoImport.WholePhotoLabel;
        SkipButton.Content = PhotoImport.SkipLabel;
        UseButton.Content = PhotoImport.UseCornersLabel;
        AutomationProperties.SetHelpText(Host, $"{PhotoImport.EditorHelp} {PhotoImport.EditorKeys}");
        LoupeLens.Fill = _loupeBrush;
        for (int i = 0; i < 4; i++)
        {
            _handles[i] = new Ellipse { IsHitTestVisible = false };
            // Theme brushes, so the handles follow the accent color, light/dark and high contrast.
            _handles[i].SetResourceReference(Shape.FillProperty, "AccentFillColorDefaultBrush");
            _handles[i].SetResourceReference(Shape.StrokeProperty, "TextOnAccentFillColorPrimaryBrush");
            Host.Children.Insert(Host.Children.IndexOf(Loupe), _handles[i]);
        }
        Ready = ShowPhotoAsync();
        // The corners take the arrow keys right away.
        Loaded += (_, _) => Host.Focus();
    }

    /// <summary>
    /// Shows the editor over <paramref name="owner"/> and returns the user's choice; closing it is
    /// Skip.
    /// </summary>
    public static PhotoCornersAnswer Ask(Window owner, PhotoCornersRequest request)
    {
        var window = new PhotoCornersWindow(request) { Owner = owner };
        return window.ShowDialog() == true ? window.Answer : PhotoCornersAnswer.Skip;
    }

    /// <summary>Downsamples the photo off the UI thread (it can be tens of megapixels) and puts it on the stage.</summary>
    private async Task ShowPhotoAsync()
    {
        try
        {
            var display = await Task.Run(() => WpfImageCodec.ToThumbnail(_photo, DisplayMaxSide));
            DisplayImage.Source = display;
            _loupeBrush.ImageSource = display;
            LoadingText.Visibility = Visibility.Collapsed;
        }
        catch (Exception e)
        {
            LoadingText.Text = $"The photo could not be shown: {e.Message}";
        }
        UpdateOverlay();
    }

    // MARK: - Geometry

    /// <summary>Aspect-fit frame of the photo inside the stage.</summary>
    private Rect FittedFrame()
    {
        double bw = Host.ActualWidth - FrameInset * 2;
        double bh = Host.ActualHeight - FrameInset * 2;
        if (bw <= 0 || bh <= 0) return new Rect(FrameInset, FrameInset, 0, 0);
        double pw = Math.Max(_photo.Width, 1), ph = Math.Max(_photo.Height, 1);
        double scale = Math.Min(bw / pw, bh / ph);
        double w = pw * scale, h = ph * scale;
        return new Rect(FrameInset + (bw - w) / 2, FrameInset + (bh - h) / 2, w, h);
    }

    private Point ViewPoint(PointD image, Rect frame) =>
        new(frame.X + image.X / Math.Max(_photo.Width, 1) * frame.Width,
            frame.Y + image.Y / Math.Max(_photo.Height, 1) * frame.Height);

    private PointD ImagePoint(Point view, Rect frame) =>
        frame.Width <= 0 || frame.Height <= 0
            ? new PointD(0, 0)
            : new PointD((view.X - frame.X) / frame.Width * _photo.Width,
                         (view.Y - frame.Y) / frame.Height * _photo.Height);

    // MARK: - Drawing

    private void UpdateOverlay()
    {
        var frame = FittedFrame();
        Canvas.SetLeft(DisplayImage, frame.X);
        Canvas.SetTop(DisplayImage, frame.Y);
        DisplayImage.Width = frame.Width;
        DisplayImage.Height = frame.Height;
        LoadingText.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(LoadingText, Host.ActualWidth / 2 - LoadingText.DesiredSize.Width / 2);
        Canvas.SetTop(LoadingText, Host.ActualHeight / 2 - LoadingText.DesiredSize.Height / 2);

        var corners = Corners.Corners.Select(c => ViewPoint(c, frame)).ToArray();
        Outline.Points = new PointCollection(corners);
        for (int i = 0; i < 4; i++)
        {
            bool selected = i == _selected;
            double size = selected ? SelectedHandleSize : HandleSize;
            _handles[i].Width = size;
            _handles[i].Height = size;
            _handles[i].StrokeThickness = selected ? 3 : 2;
            Canvas.SetLeft(_handles[i], corners[i].X - size / 2);
            Canvas.SetTop(_handles[i], corners[i].Y - size / 2);
        }
        bool shown = DisplayImage.Source is not null && frame.Width > 0 && frame.Height > 0;
        OutsideDim.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (shown)
        {
            var page = new PathGeometry([new PathFigure(corners[0], [new PolyLineSegment(corners[1..], true)], true)]);
            OutsideDim.Data = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(frame), page);
        }
        UpdateLoupe(frame, corners);
        UseButton.IsEnabled = PhotoImport.CanUseCorners(Corners);
        ResetButton.IsEnabled = Corners != _start;
    }

    /// <summary>
    /// The magnifier over the selected corner's surroundings, placed beside the corner away from the
    /// page's middle (so it covers neither the corner nor the page's edges there), kept on the stage.
    /// </summary>
    private void UpdateLoupe(Rect frame, Point[] corners)
    {
        if (!_showLoupe || DisplayImage.Source is not BitmapSource display || frame.Width <= 0)
        {
            Loupe.Visibility = Visibility.Collapsed;
            return;
        }
        var corner = corners[_selected];
        // The photo around the corner, in the display bitmap's units: what the stage shows on
        // the loupe's width, divided by the zoom.
        double size = Loupe.Width;
        double perView = display.Width / frame.Width;
        double span = size / LoupeZoom * perView;
        double cx = (corner.X - frame.X) * perView, cy = (corner.Y - frame.Y) * perView;
        _loupeBrush.Viewbox = new Rect(cx - span / 2, cy - span / 2, span, span);

        var middle = new Point(corners.Average(p => p.X), corners.Average(p => p.Y));
        double dx = corner.X >= middle.X ? 1 : -1, dy = corner.Y >= middle.Y ? 1 : -1;
        double reach = size / 2 + LoupeGap;
        Point Place(double sx, double sy) => new(corner.X + sx * reach - size / 2, corner.Y + sy * reach - size / 2);
        bool Fits(Point p) => p.X >= 0 && p.Y >= 0 && p.X + size <= Host.ActualWidth && p.Y + size <= Host.ActualHeight;
        var place = new[] { Place(dx, dy), Place(-dx, dy), Place(dx, -dy), Place(-dx, -dy) }.FirstOrDefault(Fits, Place(-dx, -dy));
        Canvas.SetLeft(Loupe, place.X);
        Canvas.SetTop(Loupe, place.Y);
        Loupe.Visibility = Visibility.Visible;
    }

    private void Host_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateOverlay();

    // MARK: - Dragging

    /// <summary>The corner whose handle is under <paramref name="view"/>, the nearest when handles overlap.</summary>
    private int? HandleAt(Point view, Rect frame)
    {
        int? best = null;
        double bestDistance = HandleHitRadius;
        for (int i = 0; i < 4; i++)
        {
            double distance = (ViewPoint(Corners[i], frame) - view).Length;
            if (distance <= bestDistance)
            {
                bestDistance = distance;
                best = i;
            }
        }
        return best;
    }

    private void Host_MouseDown(object sender, MouseButtonEventArgs e)
    {
        Host.Focus();
        if (HandleAt(e.GetPosition(Host), FittedFrame()) is not { } corner)
        {
            _showLoupe = false;
            UpdateOverlay();
            return;
        }
        _dragging = corner;
        _selected = corner;
        _showLoupe = true;
        Host.CaptureMouse();
        UpdateOverlay();
        e.Handled = true;
    }

    private void Host_MouseMove(object sender, MouseEventArgs e)
    {
        var frame = FittedFrame();
        var pointer = e.GetPosition(Host);
        if (_dragging is not { } corner)
        {
            Host.Cursor = HandleAt(pointer, frame) is not null ? Cursors.Hand : null;
            return;
        }
        // The mouse is captured, so the pointer can leave the photo: the corner stays on its edge.
        Corners = PhotoImport.MovedCorner(Corners, corner, ImagePoint(pointer, frame), _photo.Width, _photo.Height);
        UpdateOverlay();
    }

    private void Host_MouseUp(object sender, MouseButtonEventArgs e)
    {
        _dragging = null;
        _showLoupe = false;
        if (Host.IsMouseCaptured) Host.ReleaseMouseCapture();
        UpdateOverlay();
    }

    private void Host_LostMouseCapture(object sender, MouseEventArgs e)
    {
        _dragging = null;
        _showLoupe = false;
        UpdateOverlay();
    }

    // MARK: - Keyboard

    /// <summary>
    /// Keys 1 to 4 select a corner (top-left, top-right, bottom-right, bottom-left as placed); the
    /// arrow keys move it one display pixel, ten with Shift. The magnifier shows it while it moves.
    /// </summary>
    private void Host_KeyDown(object sender, KeyEventArgs e)
    {
        if (_dragging is not null) return;
        int? pick = e.Key switch
        {
            Key.D1 or Key.NumPad1 => 0,
            Key.D2 or Key.NumPad2 => 1,
            Key.D3 or Key.NumPad3 => 2,
            Key.D4 or Key.NumPad4 => 3,
            _ => null,
        };
        if (pick is { } corner)
        {
            _selected = corner;
            _showLoupe = true;
            UpdateOverlay();
            e.Handled = true;
            return;
        }
        int dx = e.Key switch { Key.Left => -1, Key.Right => 1, _ => 0 };
        int dy = e.Key switch { Key.Up => -1, Key.Down => 1, _ => 0 };
        if (dx == 0 && dy == 0) return;
        var frame = FittedFrame();
        double step = frame.Width > 0 ? Math.Max(1, _photo.Width / frame.Width) : 1;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) step *= 10;
        var at = Corners[_selected];
        Corners = PhotoImport.MovedCorner(Corners, _selected, new PointD(at.X + dx * step, at.Y + dy * step), _photo.Width, _photo.Height);
        _showLoupe = true;
        UpdateOverlay();
        e.Handled = true;
    }

    // MARK: - Buttons

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        Corners = _start;
        UpdateOverlay();
    }

    private void WholePhoto_Click(object sender, RoutedEventArgs e)
    {
        Answer = new PhotoCornersAnswer(PhotoCornersChoice.WholePhoto);
        DialogResult = true;
    }

    private void Skip_Click(object sender, RoutedEventArgs e) => Answer = PhotoCornersAnswer.Skip;

    private void Use_Click(object sender, RoutedEventArgs e)
    {
        if (!PhotoImport.CanUseCorners(Corners)) return;
        Answer = new PhotoCornersAnswer(PhotoCornersChoice.UseCorners, Corners);
        DialogResult = true;
    }

    /// <summary>For checks that drive the editor without a pointer: selects corner <paramref name="index"/> and shows the magnifier there.</summary>
    internal void ShowMagnifierAt(int index)
    {
        _selected = index & 3;
        _showLoupe = true;
        UpdateOverlay();
    }
}
