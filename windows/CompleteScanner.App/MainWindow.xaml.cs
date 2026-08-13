using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CompleteScanner.Core;
using Microsoft.Win32;

namespace CompleteScanner.App;

public partial class MainWindow : Window
{
    public AppViewModel ViewModel { get; }

    private bool _updatingUi;
    private Point? _marqueeStart;

    public MainWindow()
    {
        InitializeComponent();
        ViewModel = new AppViewModel();
        ViewModel.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(RefreshFromViewModel);

        DeviceList.ItemsSource = ViewModel.Devices;
        PresetList.ItemsSource = ViewModel.Presets;
        PageList.ItemsSource = ViewModel.ScannedPages;

        ColorModeBox.ItemsSource = Enum.GetValues<ColorMode>().Select(m => m.Label());
        FormatBox.ItemsSource = Enum.GetValues<OutputFormat>().Select(f => f.Label());

        Loaded += (_, _) =>
        {
            PushSettingsToUi();
            ViewModel.Start();
        };
    }

    // MARK: - ViewModel → UI

    private void RefreshFromViewModel()
    {
        StatusText.Text = ViewModel.StatusMessage;

        BusyBar.Visibility = ViewModel.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Visibility = ViewModel.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        if (ViewModel.Progress?.Fraction is { } fraction)
        {
            BusyBar.IsIndeterminate = false;
            BusyBar.Value = fraction * 100;
        }
        else
        {
            BusyBar.IsIndeterminate = ViewModel.IsBusy;
        }

        CanvasImage.Source = ViewModel.CanvasBitmap;
        CanvasHint.Visibility = ViewModel.CanvasBitmap is null ? Visibility.Visible : Visibility.Collapsed;

        int pageCount = ViewModel.ScannedPages.Count;
        PageStrip.Visibility = pageCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        PageStripLabel.Text = $"{pageCount} page{(pageCount == 1 ? "" : "s")} in queue";
        SavePdfButton.Content = pageCount > 0 ? $"Save PDF ({pageCount} pages)" : "Save PDF";
        SavePdfButton.IsEnabled = pageCount > 0 && !ViewModel.IsBusy;
        ClearButton.IsEnabled = pageCount > 0 && !ViewModel.IsBusy;

        PreviewButton.IsEnabled = !ViewModel.IsBusy && ViewModel.Capabilities?.SupportsOverview != false;
        ScanButton.IsEnabled = !ViewModel.IsBusy;

        // Photo review overlay.
        PhotoReviewOverlay.Visibility = ViewModel.ShowPhotoReview ? Visibility.Visible : Visibility.Collapsed;
        if (ViewModel.ShowPhotoReview)
        {
            PhotoGrid.ItemsSource = ViewModel.DetectedPhotos;
            int included = ViewModel.DetectedPhotos.Count(p => p.Photo.Included);
            ReviewTitle.Text = $"Detected {ViewModel.DetectedPhotos.Count} photos — untick any false positives";
            ReviewSaveButton.Content = $"Save {included} Photo{(included == 1 ? "" : "s")}";
        }

        // Capabilities-driven pickers.
        SyncCapabilityPickers();

        // Errors surface once, as a dialog (the macOS app binds an alert to errorMessage).
        if (ViewModel.ErrorMessage is { } error)
        {
            ViewModel.ErrorMessage = null;
            MessageBox.Show(this, error, "CompleteScanner", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void SyncCapabilityPickers()
    {
        _updatingUi = true;
        try
        {
            var resolutions = ViewModel.Capabilities?.SupportedResolutions ?? [.. AppViewModel.FallbackResolutions];
            if (!ResolutionBox.ItemsSource?.Cast<int>().SequenceEqual(resolutions) ?? true)
            {
                ResolutionBox.ItemsSource = resolutions;
            }
            ResolutionBox.SelectedItem = ViewModel.Settings.Resolution;

            var sources = ViewModel.Capabilities?.Sources ?? [ScanSource.Flatbed];
            var sourceLabels = sources.Select(s => s.Label()).ToList();
            if (!SourceBox.ItemsSource?.Cast<string>().SequenceEqual(sourceLabels) ?? true)
            {
                SourceBox.ItemsSource = sourceLabels;
            }
            SourceBox.SelectedItem = ViewModel.Settings.Source.Label();
        }
        finally
        {
            _updatingUi = false;
        }
    }

    private void PushSettingsToUi()
    {
        _updatingUi = true;
        try
        {
            var s = ViewModel.Settings;
            ModeDocument.IsChecked = s.Intent == ScanIntent.Document;
            ModePhotos.IsChecked = s.Intent == ScanIntent.Photo;
            ColorModeBox.SelectedItem = s.ColorMode.Label();
            FormatBox.SelectedItem = s.Format.Label();
            MultiPageBox.IsChecked = s.DocumentMultiPage;
            SearchableBox.IsChecked = s.PdfSearchable;
            AutoSplitBox.IsChecked = s.PhotoAutoSplit;
            DeskewBox.IsChecked = s.PhotoAutoDeskew;
            AutoEnhanceBox.IsChecked = s.Adjustments.AutoEnhance;
            BrightnessSlider.Value = s.Adjustments.Brightness;
            ContrastSlider.Value = s.Adjustments.Contrast;
            SaturationSlider.Value = s.Adjustments.Saturation;
            SharpnessSlider.Value = s.Adjustments.Sharpness;
            DescreenBox.IsChecked = s.Adjustments.Descreen;
            RestoreBox.IsChecked = s.Adjustments.RestoreFadedColors;
            DestinationBox.Text = s.DestinationPath;
            TemplateBox.Text = s.NamingTemplate;
            DocumentOptions.Visibility = s.Intent == ScanIntent.Document ? Visibility.Visible : Visibility.Collapsed;
            PhotoOptions.Visibility = s.Intent == ScanIntent.Photo ? Visibility.Visible : Visibility.Collapsed;
            SyncCapabilityPickers();
        }
        finally
        {
            _updatingUi = false;
        }
    }

    // MARK: - UI → ViewModel

    private void Setting_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        var s = ViewModel.Settings;
        s.Intent = ModePhotos.IsChecked == true ? ScanIntent.Photo : ScanIntent.Document;
        if (SourceBox.SelectedItem is string sourceLabel)
        {
            s.Source = Enum.GetValues<ScanSource>().FirstOrDefault(v => v.Label() == sourceLabel);
        }
        if (ResolutionBox.SelectedItem is int dpi) s.Resolution = dpi;
        if (ColorModeBox.SelectedItem is string colorLabel)
        {
            s.ColorMode = Enum.GetValues<ColorMode>().FirstOrDefault(v => v.Label() == colorLabel);
        }
        if (FormatBox.SelectedItem is string formatLabel)
        {
            s.Format = Enum.GetValues<OutputFormat>().FirstOrDefault(v => v.Label() == formatLabel);
        }
        s.DocumentMultiPage = MultiPageBox.IsChecked == true;
        s.PdfSearchable = SearchableBox.IsChecked == true;
        s.PhotoAutoSplit = AutoSplitBox.IsChecked == true;
        s.PhotoAutoDeskew = DeskewBox.IsChecked == true;
        s.Adjustments.AutoEnhance = AutoEnhanceBox.IsChecked == true;
        s.Adjustments.Brightness = BrightnessSlider.Value;
        s.Adjustments.Contrast = ContrastSlider.Value;
        s.Adjustments.Saturation = SaturationSlider.Value;
        s.Adjustments.Sharpness = SharpnessSlider.Value;
        s.Adjustments.Descreen = DescreenBox.IsChecked == true;
        s.Adjustments.RestoreFadedColors = RestoreBox.IsChecked == true;
        if (!string.IsNullOrWhiteSpace(DestinationBox.Text)) s.DestinationPath = DestinationBox.Text;
        if (!string.IsNullOrWhiteSpace(TemplateBox.Text)) s.NamingTemplate = TemplateBox.Text;

        DocumentOptions.Visibility = s.Intent == ScanIntent.Document ? Visibility.Visible : Visibility.Collapsed;
        PhotoOptions.Visibility = s.Intent == ScanIntent.Photo ? Visibility.Visible : Visibility.Collapsed;
        ViewModel.SettingsEdited();
    }

    // MARK: - Buttons

    private void Preview_Click(object sender, RoutedEventArgs e) => ViewModel.PerformOverview();
    private void Scan_Click(object sender, RoutedEventArgs e) => ViewModel.PerformScan();
    private void SavePdf_Click(object sender, RoutedEventArgs e) => ViewModel.SavePdf();
    private void ClearPages_Click(object sender, RoutedEventArgs e) => ViewModel.ClearPages();
    private void Cancel_Click(object sender, RoutedEventArgs e) => ViewModel.CancelScan();

    private void DeviceList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DeviceList.SelectedItem is ScannerInfo info && info.Id != ViewModel.SelectedDeviceId)
        {
            ViewModel.UserSelectDevice(info.Id);
        }
    }

    private void PresetList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (PresetList.SelectedItem is Preset preset)
        {
            ViewModel.ApplyPreset(preset);
            PushSettingsToUi();
        }
    }

    private void SavePreset_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new PromptWindow("Save Preset", "Name for the current settings:") { Owner = this };
        if (dialog.ShowDialog() == true && dialog.Value.Trim().Length > 0)
        {
            ViewModel.SaveCurrentAsPreset(dialog.Value);
        }
    }

    private void DeletePreset_Click(object sender, RoutedEventArgs e)
    {
        if (PresetList.SelectedItem is Preset preset)
        {
            ViewModel.DeletePreset(preset.Id);
        }
    }

    private void BrowseDestination_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose the save folder" };
        if (dialog.ShowDialog(this) == true)
        {
            DestinationBox.Text = dialog.FolderName;
            ViewModel.Settings.DestinationPath = dialog.FolderName;
            ViewModel.SettingsEdited();
        }
    }

    // MARK: - Page strip

    private static Guid? PageIdOf(object sender) =>
        sender is FrameworkElement { Tag: Guid id } ? id : null;

    private void PageLeft_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is { } id) ViewModel.MovePage(id, -1);
    }

    private void PageRight_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is { } id) ViewModel.MovePage(id, +1);
    }

    private void PageRemove_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is { } id) ViewModel.RemovePage(id);
    }

    // MARK: - Photo review

    private void ReviewSave_Click(object sender, RoutedEventArgs e) => ViewModel.SaveReviewedPhotos();
    private void ReviewCancel_Click(object sender, RoutedEventArgs e) => ViewModel.CancelPhotoReview();

    private void ReviewRotate_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: PhotoItem item })
        {
            item.RotateClockwise();
        }
    }

    // MARK: - Selection marquee
    //
    // The marquee is drawn in CanvasHost coordinates and converted to a normalized
    // (0...1, top-left origin) rect over the displayed image — the convention
    // IScannerSession.PerformScanAsync expects.

    /// <summary>The rectangle the letterboxed (Stretch=Uniform) image occupies inside CanvasHost.</summary>
    private Rect? DisplayedImageRect()
    {
        if (CanvasImage.Source is not { } source) return null;
        double margin = CanvasImage.Margin.Left;
        double cw = CanvasHost.ActualWidth - margin * 2;
        double ch = CanvasHost.ActualHeight - margin * 2;
        if (cw <= 0 || ch <= 0) return null;
        double scale = Math.Min(cw / source.Width, ch / source.Height);
        double dw = source.Width * scale, dh = source.Height * scale;
        return new Rect(margin + (cw - dw) / 2, margin + (ch - dh) / 2, dw, dh);
    }

    private void Canvas_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (DisplayedImageRect() is not { } imageRect) return;
        var p = e.GetPosition(CanvasHost);
        if (!imageRect.Contains(p)) return;
        _marqueeStart = p;
        CanvasHost.CaptureMouse();
    }

    private void Canvas_MouseMove(object sender, MouseEventArgs e)
    {
        if (_marqueeStart is not { } start || DisplayedImageRect() is not { } imageRect) return;
        var p = ClampTo(e.GetPosition(CanvasHost), imageRect);
        var rect = new Rect(start, p);
        SelectionMarquee.Visibility = Visibility.Visible;
        Canvas.SetLeft(SelectionMarquee, rect.X);
        Canvas.SetTop(SelectionMarquee, rect.Y);
        SelectionMarquee.Width = rect.Width;
        SelectionMarquee.Height = rect.Height;
    }

    private void Canvas_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_marqueeStart is not { } start) return;
        _marqueeStart = null;
        CanvasHost.ReleaseMouseCapture();
        if (DisplayedImageRect() is not { } imageRect) return;

        var p = ClampTo(e.GetPosition(CanvasHost), imageRect);
        var rect = new Rect(start, p);
        // A tiny drag clears the selection back to the full bed.
        if (rect.Width < 8 || rect.Height < 8)
        {
            SelectionMarquee.Visibility = Visibility.Collapsed;
            ViewModel.SelectionRect = null;
            return;
        }
        ViewModel.SelectionRect = new RectD(
            (rect.X - imageRect.X) / imageRect.Width,
            (rect.Y - imageRect.Y) / imageRect.Height,
            rect.Width / imageRect.Width,
            rect.Height / imageRect.Height);
    }

    private static Point ClampTo(Point p, Rect r) =>
        new(Math.Clamp(p.X, r.X, r.Right), Math.Clamp(p.Y, r.Y, r.Bottom));
}

/// <summary>Minimal modal text prompt (used for naming presets).</summary>
public sealed class PromptWindow : Window
{
    private readonly TextBox _textBox = new() { Margin = new Thickness(0, 8, 0, 12) };

    public string Value => _textBox.Text;

    public PromptWindow(string title, string message)
    {
        Title = title;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;

        var ok = new Button { Content = "OK", IsDefault = true, Padding = new Thickness(16, 4, 16, 4) };
        ok.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = "Cancel", IsCancel = true,
            Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0),
        };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);

        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = message });
        panel.Children.Add(_textBox);
        panel.Children.Add(buttons);
        Content = panel;

        Loaded += (_, _) => _textBox.Focus();
    }
}
