using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using CompleteScanner.Core;
using Microsoft.Win32;

namespace CompleteScanner.App;

public partial class MainWindow : Window
{
    public AppViewModel ViewModel { get; }

    private bool _updatingUi;
    private Point? _marqueeStart;
    private int _seenSavedRevision;
    private bool _savedTabStale = true;
    private object? _boundPhotoBatch;

    public MainWindow()
    {
        InitializeComponent();
        ViewModel = new AppViewModel();
        ViewModel.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(RefreshFromViewModel);

        DeviceList.ItemsSource = ViewModel.Devices;
        PresetList.ItemsSource = ViewModel.Presets;
        PageList.ItemsSource = ViewModel.ScannedPages;
        HistoryView.Attach(ViewModel);
        SavedView.Attach(ViewModel, ShowError);

        ColorModeBox.ItemsSource = Enum.GetValues<ColorMode>().Select(m => m.Label());
        FormatBox.ItemsSource = Enum.GetValues<OutputFormat>().Select(f => f.Label());

        Loaded += (_, _) =>
        {
            PushSettingsToUi();
            ViewModel.Start();
        };
        Closing += MainWindow_Closing;
        // Flush any debounced settings write and remove this instance's page spill files.
        // Done here rather than in App.OnExit: Application.MainWindow is already null by then.
        Closed += (_, _) => ViewModel.Shutdown();
        SizeChanged += (_, _) => UpdatePane();
    }

    // MARK: - Side pane (full width, or an icon rail in narrow windows)

    /// <summary>Below this window width the side pane folds to an icon rail, leaving room for the preview.</summary>
    private const double CompactPaneBelowWidth = 900;
    private const double PaneWidth = 216;
    private const double RailWidth = 48;

    /// <summary>The side pane shows icons only; the item templates bind to this.</summary>
    public static readonly DependencyProperty IsPaneCompactProperty = DependencyProperty.Register(
        nameof(IsPaneCompact), typeof(bool), typeof(MainWindow), new PropertyMetadata(false));

    public bool IsPaneCompact
    {
        get => (bool)GetValue(IsPaneCompactProperty);
        private set => SetValue(IsPaneCompactProperty, value);
    }

    /// <summary>Whether the window was narrow at the last layout.</summary>
    private bool _narrow;
    /// <summary>The user expanded or folded the pane with its toggle; reset when the window crosses the threshold.</summary>
    private bool? _paneCompactChoice;
    /// <summary>The pane state last applied to the controls.</summary>
    private (bool Compact, bool Narrow)? _paneApplied;

    private void PaneToggle_Click(object sender, RoutedEventArgs e)
    {
        _paneCompactChoice = !IsPaneCompact;
        UpdatePane();
    }

    private void UpdatePane()
    {
        bool narrow = ActualWidth < CompactPaneBelowWidth;
        if (narrow != _narrow)
        {
            _narrow = narrow;
            _paneCompactChoice = null;
        }
        bool compact = _paneCompactChoice ?? narrow;
        if (_paneApplied == (compact, narrow)) return;
        _paneApplied = (compact, narrow);

        IsPaneCompact = compact;
        Sidebar.Width = compact ? RailWidth : PaneWidth;
        // The toggle is offered only where the pane folds on its own.
        PaneToggleButton.Visibility = narrow ? Visibility.Visible : Visibility.Collapsed;
        string toggleText = compact ? "Show scanner and preset names" : "Hide scanner and preset names";
        PaneToggleButton.ToolTip = toggleText;
        AutomationProperties.SetName(PaneToggleButton, toggleText);
        ScannersHeader.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ScannersHeader.Margin = narrow ? new Thickness(0, 0, 16, 0) : new Thickness(16, 8, 16, 6);
        PresetsHeader.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        PresetsDivider.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
            AppearanceButton.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            AppearanceButton.HorizontalContentAlignment = HorizontalAlignment.Center;
            AppearanceButton.ToolTip = "Appearance: light, dark, or follow Windows";
        }
        else
        {
            AppearanceButton.ClearValue(ContentControl.ContentTemplateProperty);
            AppearanceButton.HorizontalContentAlignment = HorizontalAlignment.Left;
            AppearanceButton.ToolTip = "Light, dark, or follow Windows";
        }
    }

    // MARK: - Closing

    /// <summary>The user agreed to quit (or nothing needed asking); let the window close.</summary>
    private bool _closeConfirmed;
    /// <summary>Waiting for a cancelled operation to wind down before closing.</summary>
    private bool _closeAfterWork;
    /// <summary>
    /// The "Quit now anyway?" prompt is open inside a Closing event. The window is closing
    /// meanwhile, so Close() must not be called; that handler completes the close instead.
    /// </summary>
    private bool _inClosingPrompt;

    /// <summary>
    /// Closing the window ends the process (unlike closing a window on macOS), which would cut
    /// a running export off before its rollback and temp-file cleanup could run, and would
    /// silently drop unsaved pages or photos. So: ask first, then cancel the operation, wait
    /// for it to finish its cleanup, and only then close.
    /// </summary>
    private async void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_closeConfirmed) return;
        if (_closeAfterWork)
        {
            // Closed again while waiting: offer to quit right away.
            MessageBoxResult force;
            _inClosingPrompt = true;
            try
            {
                force = MessageBox.Show(this,
                    "Still stopping the current operation. Quit now anyway? A file being written may be left incomplete.",
                    "CompleteScanner", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            }
            finally
            {
                _inClosingPrompt = false;
            }
            // If the operation wound down while the prompt was open, the quit the user
            // already agreed to goes ahead whatever the answer.
            if (force == MessageBoxResult.Yes || !_closeAfterWork) _closeConfirmed = true;
            else e.Cancel = true;
            return;
        }

        string? unsaved = UnsavedWorkDescription();
        if (ViewModel.IsBusy || unsaved is not null)
        {
            string message = ViewModel.IsBusy
                ? $"A scan or save is still running.{(unsaved is null ? "" : " " + unsaved)}\n\nStop it and quit?"
                : $"{unsaved}\n\nQuit anyway?";
            var answer = MessageBox.Show(this, message, "CompleteScanner", MessageBoxButton.YesNo,
                                         MessageBoxImage.Warning, MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }

        var pending = Task.WhenAll(ViewModel.CurrentOperation, SavedView.PendingWork);
        if (pending.IsCompleted)
        {
            _closeConfirmed = true;
            return;
        }
        e.Cancel = true;
        _closeAfterWork = true;
        if (ViewModel.IsBusy) ViewModel.CancelScan();
        try { await pending; } catch { /* each operation reports its own failure */ }
        _closeAfterWork = false;
        if (_closeConfirmed) return; // already force-closed meanwhile
        if (_inClosingPrompt) return; // the open prompt's Closing handler finishes the close
        _closeConfirmed = true;
        Close();
    }

    private string? UnsavedWorkDescription()
    {
        int pages = ViewModel.ScannedPages.Count;
        if (pages > 0)
        {
            return $"{pages} scanned page{(pages == 1 ? " is" : "s are")} still in the queue and not saved.";
        }
        if (ViewModel.ShowPhotoReview)
        {
            return "The detected photos have not been saved.";
        }
        return null;
    }

    // MARK: - ViewModel → UI

    private void RefreshFromViewModel()
    {
        StatusText.Text = ViewModel.StatusMessage;
        StatusText.ToolTip = ViewModel.StatusMessage;

        // Cancel is offered in every busy phase: scanning, processing, detection, OCR,
        // PDF writing and exports.
        BusyBar.Visibility = ViewModel.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Visibility = ViewModel.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.IsEnabled = ViewModel.IsBusy;
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
        SavePdfButton.Content = pageCount > 0 ? $"Save PDF ({pageCount} page{(pageCount == 1 ? "" : "s")})" : "Save PDF";
        // A narrow inspector trims the label; the tooltip keeps the full text.
        SavePdfButton.ToolTip = SavePdfButton.Content;
        SavePdfButton.IsEnabled = pageCount > 0 && !ViewModel.IsBusy;
        ClearButton.IsEnabled = pageCount > 0 && !ViewModel.IsBusy;
        QueueButtons.Visibility = ViewModel.Settings.Intent == ScanIntent.Document || pageCount > 0
            ? Visibility.Visible : Visibility.Collapsed;
        PageList.IsEnabled = !ViewModel.IsBusy;

        // As on macOS, the preview is of the flatbed: not offered while the feeder is the source.
        PreviewButton.IsEnabled = !ViewModel.IsBusy && ViewModel.Capabilities?.SupportsOverview != false
                                  && ViewModel.Settings.Source != ScanSource.DocumentFeeder;
        ScanButton.IsEnabled = !ViewModel.IsBusy;
        // As on macOS, the settings (and presets, which replace them) are frozen while an
        // operation runs: it works from a snapshot, and edits made meanwhile would not apply.
        Inspector.IsEnabled = !ViewModel.IsBusy;
        PresetList.IsEnabled = !ViewModel.IsBusy;
        PresetButtons.IsEnabled = !ViewModel.IsBusy;

        UpdateMarquee();
        SyncDeviceSelection();

        // Photo review overlay.
        PhotoReviewOverlay.Visibility = ViewModel.ShowPhotoReview ? Visibility.Visible : Visibility.Collapsed;
        // The review is modal (a sheet on macOS): nothing underneath is reachable, not even by keyboard.
        MainContent.IsEnabled = !ViewModel.ShowPhotoReview;
        if (!ReferenceEquals(_boundPhotoBatch, ViewModel.DetectedPhotos))
        {
            _boundPhotoBatch = ViewModel.DetectedPhotos;
            PhotoGrid.ItemsSource = ViewModel.DetectedPhotos;
        }
        if (ViewModel.ShowPhotoReview)
        {
            int found = ViewModel.DetectedPhotos.Count;
            int included = ViewModel.DetectedPhotos.Count(p => p.Photo.Included);
            ReviewTitle.Text = $"Detected {found} photo{(found == 1 ? "" : "s")}";
            ReviewSaveButton.Content = $"Save {included} Photo{(included == 1 ? "" : "s")}";
            PhotoGrid.IsEnabled = !ViewModel.IsBusy;
            // Saving nothing would discard the batch: discarding is the Discard button's job.
            ReviewSaveButton.IsEnabled = !ViewModel.IsBusy && included > 0;
            ReviewDiscardButton.IsEnabled = !ViewModel.IsBusy;
        }

        // The Saved tab re-reads the folder after every save (lazily, once it is visible).
        if (ViewModel.SavedRevision != _seenSavedRevision)
        {
            _seenSavedRevision = ViewModel.SavedRevision;
            _savedTabStale = true;
        }
        if (_savedTabStale && SavedTab.IsSelected)
        {
            _savedTabStale = false;
            SavedView.Reload();
        }
        HistoryView.Refresh();

        // Capabilities-driven pickers.
        SyncCapabilityPickers();

        // Errors surface once, in the InfoBar (the macOS app binds an alert to errorMessage).
        if (ViewModel.ErrorMessage is { } error)
        {
            ViewModel.ErrorMessage = null;
            ShowError(error);
        }
    }

    /// <summary>
    /// Shows an error in the InfoBar above the window content. It stays until dismissed; a newer
    /// error replaces the text. Screen readers are told through a live-region event.
    /// </summary>
    private void ShowError(string message)
    {
        InfoBarMessage.Text = message;
        InfoBar.Visibility = Visibility.Visible;
        var peer = UIElementAutomationPeer.FromElement(InfoBarText) ?? UIElementAutomationPeer.CreatePeerForElement(InfoBarText);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void InfoBarClose_Click(object sender, RoutedEventArgs e) => InfoBar.Visibility = Visibility.Collapsed;

    // MARK: - Appearance

    private void AppearanceButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = AppearanceButton,
            Placement = PlacementMode.Top,
        };
        foreach (var (appearance, label) in new[]
        {
            (AppAppearance.System, "Use system setting"),
            (AppAppearance.Light, "Light"),
            (AppAppearance.Dark, "Dark"),
        })
        {
            var item = new MenuItem
            {
                Header = label,
                IsCheckable = true,
                IsChecked = ThemeService.Appearance == appearance,
            };
            item.Click += (_, _) => ThemeService.Set(appearance);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    /// <summary>
    /// Show the connected (or connecting) scanner as selected in the sidebar. The view model
    /// picks devices on its own (at start-up, on hot-plug), and the list is rebuilt whenever
    /// devices come and go, so the selection is re-applied from the model on every refresh.
    /// </summary>
    private void SyncDeviceSelection()
    {
        var selected = ViewModel.Devices.FirstOrDefault(d => d.Id == ViewModel.SelectedDeviceId);
        if (ReferenceEquals(DeviceList.SelectedItem, selected)) return;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            DeviceList.SelectedItem = selected;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    private void SyncCapabilityPickers()
    {
        bool wasUpdating = _updatingUi;
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
            _updatingUi = wasUpdating;
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
            PushAdjustmentSliders();
            DescreenBox.IsChecked = s.Adjustments.Descreen;
            RestoreBox.IsChecked = s.Adjustments.RestoreFadedColors;
            ShowDestination(s.DestinationPath);
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
        // The four sliders are written only by Adjustment_Changed, and only for the slider
        // the user moved: re-deriving them here would round-trip every value through the
        // -100...100 scale (and clamp out-of-range preset values) on unrelated edits.
        s.Adjustments.Descreen = DescreenBox.IsChecked == true;
        s.Adjustments.RestoreFadedColors = RestoreBox.IsChecked == true;
        if (!string.IsNullOrWhiteSpace(DestinationBox.Text) && DestinationBox.Text != s.DestinationPath)
        {
            s.DestinationPath = DestinationBox.Text;
            _savedTabStale = true;
        }
        if (!string.IsNullOrWhiteSpace(TemplateBox.Text)) s.NamingTemplate = TemplateBox.Text;

        DocumentOptions.Visibility = s.Intent == ScanIntent.Document ? Visibility.Visible : Visibility.Collapsed;
        PhotoOptions.Visibility = s.Intent == ScanIntent.Photo ? Visibility.Visible : Visibility.Collapsed;
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
    }

    // MARK: - Adjustment sliders (centered -100...100 scale, see AdjustmentScale)

    private void PushAdjustmentSliders()
    {
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            var a = ViewModel.Settings.Adjustments;
            // Out-of-range model values (e.g. from an old preset) only pin the slider at its
            // end; the model keeps its value until the user moves that slider.
            BrightnessSlider.Value = AdjustmentScale.BrightnessToAmount(a.Brightness);
            ContrastSlider.Value = AdjustmentScale.ContrastToAmount(a.Contrast);
            SaturationSlider.Value = AdjustmentScale.SaturationToAmount(a.Saturation);
            SharpnessSlider.Value = AdjustmentScale.SharpnessToAmount(a.Sharpness);
            UpdateAdjustmentReadouts();
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    private void UpdateAdjustmentReadouts()
    {
        var a = ViewModel.Settings.Adjustments;
        BrightnessReadout.Text = AdjustmentScale.AmountText(AdjustmentScale.BrightnessToAmount(a.Brightness));
        ContrastReadout.Text = AdjustmentScale.AmountText(AdjustmentScale.ContrastToAmount(a.Contrast));
        SaturationReadout.Text = AdjustmentScale.AmountText(AdjustmentScale.SaturationToAmount(a.Saturation));
        SharpnessReadout.Text = AdjustmentScale.AmountText(AdjustmentScale.SharpnessToAmount(a.Sharpness));
        ResetSlidersButton.IsEnabled =
            !(a.Brightness == 0 && a.Contrast == 1 && a.Saturation == 1 && a.Sharpness == 0);
    }

    private void Adjustment_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingUi || !IsLoaded) return;
        var a = ViewModel.Settings.Adjustments;
        double amount = e.NewValue;
        if (sender == BrightnessSlider) a.Brightness = AdjustmentScale.BrightnessFromAmount(amount);
        else if (sender == ContrastSlider) a.Contrast = AdjustmentScale.ContrastFromAmount(amount);
        else if (sender == SaturationSlider) a.Saturation = AdjustmentScale.SaturationFromAmount(amount);
        else if (sender == SharpnessSlider) a.Sharpness = AdjustmentScale.SharpnessFromAmount(amount);
        UpdateAdjustmentReadouts();
        ViewModel.SettingsEdited();
    }

    private void ResetSliders_Click(object sender, RoutedEventArgs e)
    {
        var a = ViewModel.Settings.Adjustments;
        a.Brightness = 0;
        a.Contrast = 1;
        a.Saturation = 1;
        a.Sharpness = 0;
        PushAdjustmentSliders();
        ViewModel.SettingsEdited();
    }

    // MARK: - Buttons

    private void Preview_Click(object sender, RoutedEventArgs e) => _ = ViewModel.PerformOverview();
    private void Scan_Click(object sender, RoutedEventArgs e) => _ = ViewModel.PerformScan();
    private void SavePdf_Click(object sender, RoutedEventArgs e) => _ = ViewModel.SavePdf();
    private void ClearPages_Click(object sender, RoutedEventArgs e) => ViewModel.ClearPages();
    private void Cancel_Click(object sender, RoutedEventArgs e) => ViewModel.CancelScan();

    private void DeviceList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi) return;
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
            _savedTabStale = true;
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

    private void ShowDestination(string path)
    {
        DestinationBox.Text = path;
        DestinationBox.CaretIndex = path.Length;
    }

    /// <summary>
    /// Keep the end of a long path in view in the Save to box, so the folder name (the part that
    /// tells folders apart) shows rather than the drive and user folder. Runs whenever the text
    /// or the box's width changes, including after a theme switch re-creates its template, but
    /// not while the user is editing, where the caret decides what shows.
    /// </summary>
    private void DestinationBox_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (DestinationBox.IsKeyboardFocusWithin) return;
        if (e.ExtentWidthChange == 0 && e.ViewportWidthChange == 0) return;
        DestinationBox.ScrollToHorizontalOffset(Math.Max(0, e.ExtentWidth - e.ViewportWidth));
    }

    private void DestinationBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) =>
        DestinationBox.ScrollToHorizontalOffset(
            Math.Max(0, DestinationBox.ExtentWidth - DestinationBox.ViewportWidth));

    private void BrowseDestination_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose the save folder" };
        if (dialog.ShowDialog(this) == true)
        {
            ShowDestination(dialog.FolderName);
            ViewModel.Settings.DestinationPath = dialog.FolderName;
            _savedTabStale = true;
            ViewModel.SettingsEdited();
        }
    }

    // MARK: - Tabs

    private void MainTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Selection changes bubble up from lists and combo boxes inside the tabs.
        if (!ReferenceEquals(e.OriginalSource, MainTabs)) return;
        if (SavedTab.IsSelected)
        {
            _savedTabStale = false;
            SavedView.Reload();
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

    private void PageRotate_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is { } id) _ = ViewModel.RotatePage(id);
    }

    // MARK: - Photo review

    private void ReviewSave_Click(object sender, RoutedEventArgs e) => _ = ViewModel.SaveReviewedPhotos();
    private void ReviewCancel_Click(object sender, RoutedEventArgs e) => ViewModel.CancelPhotoReview();

    /// <summary>Keep toggled: the "Save N Photos" count follows.</summary>
    private void ReviewKeep_Click(object sender, RoutedEventArgs e) => RefreshFromViewModel();

    private void ReviewRotate_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: PhotoItem item })
        {
            item.RotateClockwise();
        }
    }

    private void ReviewCrop_Click(object sender, RoutedEventArgs e)
    {
        // One correction at a time: the editor must start from the photo's latest crop.
        if (ViewModel.IsBusy || ViewModel.IsRecropPending
            || sender is not FrameworkElement { DataContext: PhotoItem item }) return;
        if (ViewModel.PhotoSource(item.Photo) is not { } source)
        {
            ShowError("The original scan for this photo is no longer available.");
            return;
        }
        var editor = new PhotoCropEditorWindow(source, item.Photo.Region, ViewModel.Settings.PhotoAutoDeskew)
        {
            Owner = this,
        };
        if (editor.ShowDialog() == true && !editor.Region.Equals(item.Photo.Region))
        {
            _ = ViewModel.RecropPhoto(item.Photo.Id, editor.Region);
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

    /// <summary>
    /// Draw the marquee from the model's normalized selection over the displayed image, so it
    /// follows resizes and disappears whenever the selection is cleared (device switch) or
    /// there is no overview under it. A drag in progress draws itself.
    /// </summary>
    private void UpdateMarquee()
    {
        if (_marqueeStart is not null) return;
        if (ViewModel.SelectionRect is not { } selection || ViewModel.OverviewImage is null
            || DisplayedImageRect() is not { } imageRect)
        {
            SelectionMarquee.Visibility = Visibility.Collapsed;
            return;
        }
        Canvas.SetLeft(SelectionMarquee, imageRect.X + selection.MinX * imageRect.Width);
        Canvas.SetTop(SelectionMarquee, imageRect.Y + selection.MinY * imageRect.Height);
        SelectionMarquee.Width = Math.Abs(selection.Width) * imageRect.Width;
        SelectionMarquee.Height = Math.Abs(selection.Height) * imageRect.Height;
        SelectionMarquee.Visibility = Visibility.Visible;
    }

    private void CanvasHost_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateMarquee();
        // In a small stage the full empty state would wrap and clip: keep just the title and text.
        bool compact = CanvasHost.ActualWidth < 300 || CanvasHost.ActualHeight < 300;
        CanvasHintGlyph.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        CanvasHintTip.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        CanvasHintTitle.SetResourceReference(StyleProperty, compact ? "BodyStrongText" : "EmptyStateTitleStyle");
        CanvasHintTitle.HorizontalAlignment = HorizontalAlignment.Center;
    }

    private void Canvas_MouseDown(object sender, MouseButtonEventArgs e)
    {
        _marqueeStart = null;
        // The selection is a region of the flatbed, so it can only be drawn over the overview
        // (the bed) — never over a last scan, which may be a feeder page or an earlier crop.
        if (ViewModel.OverviewImage is null) return;
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

    /// <summary>
    /// The drag was cut off (Alt+Tab, a dialog popping up): abandon it, keep the previous
    /// selection and redraw it from the model.
    /// </summary>
    private void Canvas_LostMouseCapture(object sender, MouseEventArgs e)
    {
        if (_marqueeStart is null) return;
        _marqueeStart = null;
        UpdateMarquee();
    }

    private static Point ClampTo(Point p, Rect r) =>
        new(Math.Clamp(p.X, r.X, r.Right), Math.Clamp(p.Y, r.Y, r.Bottom));
}

/// <summary>Minimal modal text prompt (used for naming presets).</summary>
public sealed class PromptWindow : Window
{
    private readonly TextBox _textBox = new() { Margin = new Thickness(0, 8, 0, 16) };

    public string Value => _textBox.Text;

    public PromptWindow(string title, string message)
    {
        Title = title;
        Icon = AppIcon.Image;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        SetResourceReference(FontFamilyProperty, "TextFontFamily");

        var ok = new Button { Content = "OK", IsDefault = true, MinWidth = 88 };
        ok.SetResourceReference(StyleProperty, "AccentButtonStyle");
        ok.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = "Cancel", IsCancel = true,
            MinWidth = 88, Margin = new Thickness(8, 0, 0, 0),
        };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);

        var panel = new StackPanel { Margin = new Thickness(24) };
        var text = new TextBlock { Text = message };
        text.SetResourceReference(StyleProperty, "BodyText");
        panel.Children.Add(text);
        panel.Children.Add(_textBox);
        panel.Children.Add(buttons);
        Content = panel;

        Loaded += (_, _) => _textBox.Focus();
    }
}
