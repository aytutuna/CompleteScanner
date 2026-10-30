using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyScan.App.Services;
using LazyScan.Core;

namespace LazyScan.App;

/// <summary>What the split dialog was closed with.</summary>
public enum SpreadSplitChoice
{
    /// <summary>Cut the spread at <see cref="SpreadSplitWindow.Fraction"/> along <see cref="SpreadSplitWindow.Axis"/>.</summary>
    Split,
    /// <summary>Keep the spread as one page.</summary>
    KeepWhole,
}

/// <summary>
/// Splitting a spread by hand (twin of the Mac's SpreadSplitView): the spread as scanned with the cut
/// drawn across it; a click or drag on the spread, the slider or the arrow keys move the cut, and the
/// pages lie side by side or one above the other. The caller splits or joins the spread with the result.
/// </summary>
public partial class SpreadSplitWindow : Window
{
    /// <summary>Space around the spread on the stage, in view units.</summary>
    private const double FrameInset = 20;
    /// <summary>One arrow key press moves the cut this share of the spread; with Shift, ten times as much.</summary>
    private const double KeyStep = 0.002;

    private readonly int _width;
    private readonly int _height;
    /// <summary>Where the spread is drawn on the stage.</summary>
    private Rect _frame;
    private bool _dragging;
    private bool _syncing;

    /// <summary>Which way the cut runs.</summary>
    public GutterAxis Axis { get; private set; }

    /// <summary>Where the cut is, along <see cref="Axis"/> (0...1 of the spread).</summary>
    public double Fraction { get; private set; }

    /// <summary>What the dialog was closed with; null when it was cancelled.</summary>
    public SpreadSplitChoice? Choice { get; private set; }

    public SpreadSplitWindow(SpreadEditorSource source)
    {
        InitializeComponent();
        _width = source.Preview.Width;
        _height = source.Preview.Height;
        Axis = source.Axis;
        Fraction = Math.Clamp(source.Fraction, CutSlider.Minimum, CutSlider.Maximum);
        DisplayImage.Source = WpfImageCodec.ToBitmapSource(source.Preview);
        Title = $"Split spread {source.SpreadNumber}";
        TitleText.Text = Title;
        // A spread kept whole is already one page; a split one can be joined here too.
        KeepWholeButton.Visibility = source.IsSplit ? Visibility.Visible : Visibility.Collapsed;
        SplitButton.Content = source.IsSplit ? "Split here" : "Split";
        _syncing = true;
        SideBySideButton.IsChecked = Axis == GutterAxis.Vertical;
        StackedButton.IsChecked = Axis == GutterAxis.Horizontal;
        CutSlider.Value = Fraction;
        _syncing = false;
        Loaded += (_, _) =>
        {
            // The cut takes the arrow keys right away.
            Host.Focus();
            LayoutStage();
        };
    }

    private void Host_SizeChanged(object sender, SizeChangedEventArgs e) => LayoutStage();

    /// <summary>The spread fitted into the stage, and the cut drawn across it.</summary>
    private void LayoutStage()
    {
        double availableW = Math.Max(1, Host.ActualWidth - 2 * FrameInset);
        double availableH = Math.Max(1, Host.ActualHeight - 2 * FrameInset);
        double scale = Math.Min(availableW / _width, availableH / _height);
        double w = _width * scale, h = _height * scale;
        _frame = new Rect((Host.ActualWidth - w) / 2, (Host.ActualHeight - h) / 2, w, h);
        Canvas.SetLeft(DisplayImage, _frame.X);
        Canvas.SetTop(DisplayImage, _frame.Y);
        DisplayImage.Width = w;
        DisplayImage.Height = h;
        DrawCut();
    }

    private void DrawCut()
    {
        if (Axis == GutterAxis.Vertical)
        {
            double x = _frame.X + Fraction * _frame.Width;
            (CutLine.X1, CutLine.Y1, CutLine.X2, CutLine.Y2) = (x, _frame.Top - 8, x, _frame.Bottom + 8);
        }
        else
        {
            double y = _frame.Y + Fraction * _frame.Height;
            (CutLine.X1, CutLine.Y1, CutLine.X2, CutLine.Y2) = (_frame.Left - 8, y, _frame.Right + 8, y);
        }
        string place = $"{Math.Round(Fraction * 100)}% from the {(Axis == GutterAxis.Vertical ? "left" : "top")}";
        System.Windows.Automation.AutomationProperties.SetItemStatus(Host, place);
    }

    /// <summary>The cut moved to <paramref name="fraction"/> of the spread, kept within the slider's range.</summary>
    private void MoveCut(double fraction)
    {
        Fraction = Math.Clamp(fraction, CutSlider.Minimum, CutSlider.Maximum);
        _syncing = true;
        CutSlider.Value = Fraction;
        _syncing = false;
        DrawCut();
    }

    private void MoveCutTo(Point point)
    {
        if (_frame.Width <= 0 || _frame.Height <= 0) return;
        MoveCut(Axis == GutterAxis.Vertical
            ? (point.X - _frame.X) / _frame.Width
            : (point.Y - _frame.Y) / _frame.Height);
    }

    private void Host_MouseDown(object sender, MouseButtonEventArgs e)
    {
        Host.Focus();
        _dragging = Host.CaptureMouse();
        MoveCutTo(e.GetPosition(Host));
    }

    private void Host_MouseMove(object sender, MouseEventArgs e)
    {
        if (_dragging && e.LeftButton == MouseButtonState.Pressed) MoveCutTo(e.GetPosition(Host));
    }

    private void Host_MouseUp(object sender, MouseButtonEventArgs e)
    {
        _dragging = false;
        Host.ReleaseMouseCapture();
    }

    /// <summary>A drag ends when the mouse is taken away too (another window, a prompt), not only when the button is let go.</summary>
    private void Host_LostMouseCapture(object sender, MouseEventArgs e) => _dragging = false;

    private void Host_KeyDown(object sender, KeyEventArgs e)
    {
        double step = KeyStep * ((Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? 10 : 1);
        double? move = (Axis, e.Key) switch
        {
            (GutterAxis.Vertical, Key.Left) or (GutterAxis.Horizontal, Key.Up) => -step,
            (GutterAxis.Vertical, Key.Right) or (GutterAxis.Horizontal, Key.Down) => step,
            _ => null,
        };
        if (move is not { } delta) return;
        MoveCut(Fraction + delta);
        e.Handled = true;
    }

    private void CutSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_syncing || !IsInitialized) return;
        Fraction = CutSlider.Value;
        DrawCut();
    }

    private void Axis_Changed(object sender, RoutedEventArgs e)
    {
        if (_syncing) return;
        Axis = StackedButton.IsChecked == true ? GutterAxis.Horizontal : GutterAxis.Vertical;
        DrawCut();
    }

    private void Split_Click(object sender, RoutedEventArgs e)
    {
        Choice = SpreadSplitChoice.Split;
        DialogResult = true;
    }

    private void KeepWhole_Click(object sender, RoutedEventArgs e)
    {
        Choice = SpreadSplitChoice.KeepWhole;
        DialogResult = true;
    }
}
