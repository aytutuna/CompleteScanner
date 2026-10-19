using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// The Scans tab: every scan of this session, newest first, as preview cards; click a card
/// to enlarge it. History holds small previews only — full pixels live in the page queue,
/// the photo review or the saved files. Port of UI/ScanHistoryView.swift.
/// </summary>
public partial class ScanHistoryView : UserControl
{
    /// <summary>Clock the cards' relative times ("5 min ago") are measured against.</summary>
    public static readonly DependencyProperty NowProperty = DependencyProperty.Register(
        nameof(Now), typeof(DateTime), typeof(ScanHistoryView), new PropertyMetadata(default(DateTime)));

    private AppViewModel? _viewModel;
    private HistoryItem? _newest;
    private readonly DispatcherTimer _clock;

    public ScanHistoryView()
    {
        InitializeComponent();
        Now = DateTime.Now;
        // Ticks only while the tab is on screen.
        _clock = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(30) };
        _clock.Tick += (_, _) => Now = DateTime.Now;
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible)
            {
                Now = DateTime.Now;
                _clock.Start();
            }
            else
            {
                _clock.Stop();
            }
        };
    }

    public DateTime Now
    {
        get => (DateTime)GetValue(NowProperty);
        set => SetValue(NowProperty, value);
    }

    public void Attach(AppViewModel viewModel)
    {
        _viewModel = viewModel;
        Cards.ItemsSource = viewModel.History;
        Refresh();
    }

    /// <summary>Show the empty state or the cards.</summary>
    public void Refresh()
    {
        int count = _viewModel?.History.Count ?? 0;
        bool empty = count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        CardsPanel.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        CountText.Text = count == 1
            ? "1 scan. Select it to enlarge it."
            : $"{count} scans, newest first. Select one to enlarge it.";

        // A new scan arrived: re-measure so it reads "Just now" rather than against a stale clock.
        var newest = empty ? null : _viewModel!.History[0];
        if (!ReferenceEquals(newest, _newest))
        {
            _newest = newest;
            Now = DateTime.Now;
        }
    }

    /// <summary>The scroll viewport changed width (resize, scrollbar shown or hidden): re-centre the grid.</summary>
    private void CardsScroller_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.ViewportWidthChange != 0) UpdateInsets();
    }

    /// <summary>
    /// Centre the card grid: split the width left over after the last whole column between
    /// both sides, and line the header up with the grid's left and right edges.
    /// </summary>
    private void UpdateInsets()
    {
        var (cards, header) = GridInsets.For(CardsScroller.ViewportWidth);
        Cards.Margin = new Thickness(cards.Left, 0, cards.Right, 12);
        Header.Margin = new Thickness(header.Left, 16, header.Right, 8);
    }

    private void Thumbnail_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: HistoryItem item }) return;
        var entry = item.Entry;
        var window = new ImagePreviewWindow(
            item.Thumbnail,
            entry.Intent.Label(),
            entry.Intent == ScanIntent.Photo ? "\uEB9F" : "\uE8A5",
            $"{entry.Dpi} dpi · {item.PixelSizeText} · {entry.Date:d} {entry.Date:t}")
        {
            Owner = Window.GetWindow(this),
        };
        window.ShowDialog();
    }
}

/// <summary>
/// Card time line: "Just now" or "12 min ago" next to the clock time while recent, then the
/// clock time alone (with "Yesterday" or the date once the day has changed).
/// Values: the scan's <see cref="DateTime"/> and the current time.
/// </summary>
public sealed class ScanTimeConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture)
    {
        if (values.Length < 2 || values[0] is not DateTime date || values[1] is not DateTime now) return "";
        return Format(date, now, culture);
    }

    public static string Format(DateTime date, DateTime now, CultureInfo culture)
    {
        string time = date.ToString("t", culture);
        var age = now - date;
        if (date.Date == now.Date || age < TimeSpan.FromHours(1))
        {
            if (age < TimeSpan.FromMinutes(1)) return $"Just now · {time}";
            if (age < TimeSpan.FromHours(1)) return $"{(int)age.TotalMinutes} min ago · {time}";
            return time;
        }
        if (date.Date == now.Date.AddDays(-1)) return $"Yesterday · {time}";
        return $"{date.ToString("d", culture)} · {time}";
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

/// <summary>
/// Modal enlarged view of one image: a title and metadata header, the image on a neutral
/// stage, Fit / Zoom in (button or double-click; zoomed, the preview shows at its own pixel
/// size and scrolls) and Close (Esc or Enter).
/// </summary>
public sealed class ImagePreviewWindow : Window
{
    private readonly Image _picture;
    private readonly ScrollViewer _scroller;
    private readonly Button _zoomButton;
    private bool _zoomed;

    public ImagePreviewWindow(ImageSource image, string title, string? glyph, string details)
    {
        Title = "Scan";
        Icon = AppIcon.Image;
        Width = 760;
        Height = 640;
        MinWidth = 400;
        MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        SetResourceReference(FontFamilyProperty, "TextFontFamily");

        // Header: intent glyph, title, metadata.
        var titleText = new TextBlock { Text = title, TextWrapping = TextWrapping.NoWrap };
        titleText.SetResourceReference(StyleProperty, "SubtitleText");
        var detailsText = new TextBlock
        {
            Text = details,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            ToolTip = details,
            Margin = new Thickness(0, 2, 0, 0),
        };
        detailsText.SetResourceReference(StyleProperty, "CaptionText");
        var headerText = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        headerText.Children.Add(titleText);
        headerText.Children.Add(detailsText);

        var header = new DockPanel { Margin = new Thickness(20, 12, 20, 8) };
        if (glyph is not null)
        {
            var glyphText = new TextBlock { Text = glyph, FontSize = 24, Margin = new Thickness(0, 0, 14, 0) };
            glyphText.SetResourceReference(StyleProperty, "GlyphText");
            glyphText.SetResourceReference(ForegroundProperty, "AccentTextFillColorPrimaryBrush");
            DockPanel.SetDock(glyphText, Dock.Left);
            header.Children.Add(glyphText);
        }
        header.Children.Add(headerText);
        DockPanel.SetDock(header, Dock.Top);

        // Footer: zoom on the left, Close on the right.
        var close = new Button
        {
            Content = "Close",
            IsCancel = true,
            IsDefault = true,
            MinWidth = 96,
        };
        close.Click += (_, _) => Close();
        DockPanel.SetDock(close, Dock.Right);

        _zoomButton = new Button { HorizontalAlignment = HorizontalAlignment.Left };
        _zoomButton.SetResourceReference(StyleProperty, "IconTextButtonStyle");
        _zoomButton.Click += (_, _) => SetZoomed(!_zoomed);

        var footer = new DockPanel { Margin = new Thickness(12, 4, 12, 12), LastChildFill = true };
        footer.Children.Add(close);
        footer.Children.Add(_zoomButton);
        DockPanel.SetDock(footer, Dock.Bottom);

        // Stage: the image with a page shadow on a neutral surface; scrolls at actual size.
        _picture = new Image
        {
            Source = image,
            Margin = new Thickness(16),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        RenderOptions.SetBitmapScalingMode(_picture, BitmapScalingMode.HighQuality);
        _picture.SetResourceReference(EffectProperty, "PageShadow");
        _picture.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount != 2) return;
            SetZoomed(!_zoomed);
            e.Handled = true;
        };

        _scroller = new ScrollViewer { Content = _picture, Focusable = false };
        var stage = new Border { Margin = new Thickness(12, 0, 12, 4), Child = _scroller };
        stage.SetResourceReference(StyleProperty, "StageStyle");

        var root = new DockPanel();
        root.Children.Add(header);
        root.Children.Add(footer);
        root.Children.Add(stage);
        Content = root;

        SetZoomed(false);
    }

    private void SetZoomed(bool zoomed)
    {
        _zoomed = zoomed;
        _picture.Stretch = zoomed ? Stretch.None : Stretch.Uniform;
        var scroll = zoomed ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled;
        _scroller.HorizontalScrollBarVisibility = scroll;
        _scroller.VerticalScrollBarVisibility = scroll;
        _picture.ToolTip = zoomed ? "Double-click to fit to the window" : "Double-click to zoom in";
        _zoomButton.Content = zoomed ? "Fit to window" : "Zoom in";
        global::CompleteScanner.App.Icon.SetGlyph(_zoomButton, zoomed ? "\uE9A6" : "\uE8A3");
        _zoomButton.ToolTip = zoomed
            ? "Scale the image to fit the window"
            : "Show the preview at full size and scroll around it";
    }
}
