using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using LazyScan.Core;
using Microsoft.Win32;

namespace LazyScan.App;

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
        if (ViewModel.NetworkScanners is { } network) network.ConfirmCertificate = ConfirmCertificate;

        DeviceList.ItemsSource = ViewModel.Devices;
        PresetList.ItemsSource = ViewModel.Presets;
        PageList.ItemsSource = ViewModel.ScannedPages;
        // Screen readers name each page by its place and side: when items are made, and after
        // any change to the queue once layout has caught up (a removed page renumbers the rest).
        PageList.ItemContainerGenerator.StatusChanged += (_, _) =>
        {
            if (PageList.ItemContainerGenerator.Status == GeneratorStatus.ContainersGenerated) NamePageItems();
        };
        ViewModel.ScannedPages.CollectionChanged += (_, _) =>
            Dispatcher.InvokeAsync(NamePageItems, System.Windows.Threading.DispatcherPriority.Loaded);
        HistoryView.Attach(ViewModel);
        SavedView.Attach(ViewModel, ShowError);
        StartView.Attach(ViewModel);
        StartView.TaskChosen += StartTask;
        StartView.PresetChosen += StartPreset;
        AskDiscardIdCard = AskDiscardIdCardInDialog;
        StartView.GoToScanRequested += () => ShowScanScreen();
        StartView.AddToPdfRequested += StartAddingToPdf;
        // A first run opens on the start screen; later runs open where scanning happens, with
        // the task (and its banner) the user had last.
        MainTabs.SelectedItem = ViewModel.IsFirstRun ? StartTab : ScanTab;

        ColorModeBox.ItemsSource = Enum.GetValues<ColorMode>().Select(m => m.Label());
        FormatBox.ItemsSource = OutputFormats.Offered(ViewModel.Settings.Intent).Select(f => f.Label()).ToList();
        BuildPdfSizeSegments();
        ArchivalBox.Content = PdfA.OptionLabel;
        ArchivalBox.ToolTip = PdfA.OptionHint;
        ProtectBox.Content = PdfProtection.OptionLabel;
        ProtectBox.ToolTip = PdfProtection.OptionHint;
        WordPageImagesBox.Content = DocxWriter.PageImagesLabel;
        SetUpInspectorSections();
        // A protected PDF's password is asked for at save time, over this window.
        ViewModel.AskPdfPassword = () => PdfPasswordWindow.Ask(this);
        SetUpAddToPdf();
        SetUpImport();
        SetUpPhone();
        BuildBlankSensitivitySegments();
        BuildSplitChoices();
        BuildBookChoices();
        AfterSaveBox.ItemsSource = AfterSaveItems();
        ReviewAfterSaveBox.ItemsSource = AfterSaveItems();
        foreach (var binding in Enum.GetValues<DuplexBinding>())
        {
            BackBindingBox.Items.Add(new ComboBoxItem { Content = binding.Label(), Tag = binding });
        }
        foreach (var paper in IdCardPapers.All)
        {
            IdCardPaperBox.Items.Add(new ComboBoxItem { Content = ViewModel.IdCardPaperChoiceLabel(paper), Tag = paper });
        }
        // The card is a picture: a PDF or an image.
        foreach (var format in Enum.GetValues<OutputFormat>().Where(f => OutputFormats.PageFormat(f) == f))
        {
            IdCardFormatBox.Items.Add(new ComboBoxItem { Content = format.Label(), Tag = format });
        }
        BuildCopyCountItems();

        Loaded += (_, _) =>
        {
            PushSettingsToUi();
            ViewModel.Start();
            // Receives from paired phones on trusted networks; nothing listens while no phone is paired.
            ViewModel.StartCompanionIfPaired();
            // Opened from File Explorer: the .lsdoc is offered on its bar.
            OpenCommandLinePackage();
            _ = Task.Run(Services.FileAssociation.RegisterForCurrentUser);
            if (StartTab.IsSelected) StartView.FocusDefaultCard();
        };
        // A printer added or removed while the app was in the background (in Windows Settings, say)
        // is seen when the window is back in front.
        Activated += (_, _) =>
        {
            if (IsLoaded) ViewModel.PrintersMayHaveChanged();
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
        AddScannerButton.Visibility = compact || ViewModel.NetworkScanners is null ? Visibility.Collapsed : Visibility.Visible;
        TroubleshootButton.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        UpdateEmptyDevicesHint();
        ScannersHeader.Margin = narrow ? new Thickness(0, 0, 16, 0) : new Thickness(16, 8, 16, 6);
        PresetsHeader.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        PresetsDivider.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
            AppearanceButton.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            AppearanceButton.HorizontalContentAlignment = HorizontalAlignment.Center;
            AppearanceButton.ToolTip = "Appearance: light, dark, or follow Windows";
            PhoneButton.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            PhoneButton.HorizontalContentAlignment = HorizontalAlignment.Center;
            PhoneButton.ToolTip = "Phone: send documents from your phone to this PC";
        }
        else
        {
            AppearanceButton.ClearValue(ContentControl.ContentTemplateProperty);
            AppearanceButton.HorizontalContentAlignment = HorizontalAlignment.Left;
            AppearanceButton.ToolTip = "Light, dark, or follow Windows";
            PhoneButton.ClearValue(ContentControl.ContentTemplateProperty);
            PhoneButton.HorizontalContentAlignment = HorizontalAlignment.Left;
            PhoneButton.ToolTip = "Send documents from your phone to this PC";
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
                    "Lazy Scan", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
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
            var answer = MessageBox.Show(this, message, "Lazy Scan", MessageBoxButton.YesNo,
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
        if (ViewModel.HasIdCardCaptures)
        {
            return "The ID card has not been saved.";
        }
        return null;
    }

    // MARK: - ViewModel → UI

    private void RefreshFromViewModel()
    {
        SyncStatusLine();

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
        // After a preview, until an area is selected: the preview can be dragged over.
        DragChip.Visibility = ViewModel.OverviewImage is not null && ViewModel.SelectionRect is null && !ViewModel.IsBusy
                              && ViewModel.CanvasBitmap is not null
            ? Visibility.Visible : Visibility.Collapsed;

        int pageCount = ViewModel.ScannedPages.Count;
        var queued = ViewModel.ScannedPages.Select(item => item.Page).ToList();
        // Pages flagged blank (with Skip blank pages on), separator sheets and pages skipped by hand
        // are left out when saving; a split queue is saved as several files ("Save 3 PDFs").
        var savePlan = SavePlan.Make(queued, ViewModel.Settings.Document);
        int saveCount = savePlan.PageCount;
        PageStrip.Visibility = pageCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        PageStripLabel.Text = DocumentSplitter.QueueSummary(queued, ViewModel.Settings.Document);
        SyncSaveButton(savePlan, pageCount);
        LastPdfSizeText.Text = ViewModel.LastPdfSizeText;
        LastPdfSizeText.Visibility = ViewModel.LastPdfSizeText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearButton.IsEnabled = pageCount > 0 && !ViewModel.IsBusy;
        // The ID card and receipts are saved from their reviews, and a copy goes to the printer: none uses the page queue.
        QueueButtons.Visibility = (ViewModel.Settings.Intent == ScanIntent.Document && !ViewModel.IsIdCardFlow && !ViewModel.IsCopyFlow
                                   && !ViewModel.IsReceiptFlow)
                                  || pageCount > 0
            ? Visibility.Visible : Visibility.Collapsed;
        // The target row belongs to Save: it goes when the queue's buttons do.
        AppendTargetRow.Visibility = ViewModel.AppendTarget is not null ? QueueButtons.Visibility : Visibility.Collapsed;
        PageList.IsEnabled = !ViewModel.IsBusy;

        // As on macOS, the preview is of the flatbed: not offered while the feeder is the source.
        string? previewReason = ViewModel.PreviewUnavailableReason;
        PreviewButton.IsEnabled = !ViewModel.IsBusy && previewReason is null;
        // The tooltip also shows while the button is greyed out (ShowOnDisabled), so it says why.
        string previewHint = previewReason ?? "Quick look at the whole glass";
        PreviewButton.ToolTip = previewHint;
        AutomationProperties.SetHelpText(PreviewButton, previewHint);
        // Scan has a tooltip only while it waits for the scanner.
        string? notConnected = NotConnectedHint();
        ScanButton.IsEnabled = !ViewModel.IsBusy && ViewModel.IsConnected;
        ScanButton.ToolTip = notConnected;
        AutomationProperties.SetHelpText(ScanButton, notConnected ?? "");
        ScanButton.Content = ViewModel.PrimaryActionLabel;
        SyncTaskBanner();
        SyncCopyOptions();
        SyncReceiptOptions();
        SyncSplitOptions();
        SyncBookOptions();
        SyncImportOptions();
        SyncInspectorSections();
        SyncSelectedArea();
        StartView.Refresh();
        // As on macOS, the settings (and presets, which replace them) are frozen while an
        // operation runs: it works from a snapshot, and edits made meanwhile would not apply.
        Inspector.IsEnabled = !ViewModel.IsBusy;
        PresetList.IsEnabled = !ViewModel.IsBusy;
        PresetButtons.IsEnabled = !ViewModel.IsBusy;
        // So is the scanner list: picking another scanner would cancel the scan.
        string? busyHint = ViewModel.IsBusy ? "Wait for the scan to finish" : null;
        DeviceList.IsEnabled = !ViewModel.IsBusy;
        DeviceList.ToolTip = busyHint;
        AutomationProperties.SetHelpText(DeviceList, busyHint ?? "");
        // While a side of an ID card is held, the mode and the source stay as they are: changing
        // them would end the task and drop the card. Leaving the task or picking another scanner
        // asks first.
        bool cardHeld = ViewModel.HasIdCardCaptures;
        string? cardHint = cardHeld ? IdCardHeldHint : null;
        ModeTrack.IsEnabled = SourceBox.IsEnabled = !cardHeld;
        ModeTrack.ToolTip = cardHint;
        // The source's plain name ("Document feeder") with what it stands for on hover: "(ADF)".
        SourceBox.ToolTip = cardHint ?? ViewModel.Settings.Source.Hint();
        AutomationProperties.SetHelpText(ModeTrack, cardHint ?? "");
        AutomationProperties.SetHelpText(SourceBox, cardHint ?? ViewModel.Settings.Source.Hint());

        UpdateMarquee();
        SyncDeviceSelection();
        SyncDriverWindowOption();
        // A page's badge is part of its name, and the badges follow the blank-page settings.
        NamePageItems();

        // Photo review overlay.
        PhotoReviewOverlay.Visibility = ViewModel.ShowPhotoReview ? Visibility.Visible : Visibility.Collapsed;
        // The reviews are modal (sheets on macOS): nothing underneath is reachable, not even by keyboard.
        MainContent.IsEnabled = !ViewModel.ShowPhotoReview && !ViewModel.ShowIdCardReview;
        SyncIdCardReview();
        if (!ReferenceEquals(_boundPhotoBatch, ViewModel.DetectedPhotos))
        {
            _boundPhotoBatch = ViewModel.DetectedPhotos;
            PhotoGrid.ItemsSource = ViewModel.DetectedPhotos;
        }
        if (ViewModel.ShowPhotoReview)
        {
            int found = ViewModel.DetectedPhotos.Count;
            int included = ViewModel.DetectedPhotos.Count(p => p.Photo.Included);
            ReviewTitle.Text = ViewModel.ReviewTitle;
            ReviewSaveButton.Content = ViewModel.ReviewSaveTitle;
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
        SyncSavedBar();
        SyncPackageBar();

        // Capabilities-driven pickers.
        SyncCapabilityPickers();

        // Errors surface once, in the InfoBar (the macOS app binds an alert to errorMessage).
        if (ViewModel.ErrorMessage is { } error)
        {
            ViewModel.ErrorMessage = null;
            // A scanner that would not connect or scan: the bar offers the troubleshooter.
            bool troubleshoot = ViewModel.ErrorSuggestsTroubleshooter;
            ViewModel.ErrorSuggestsTroubleshooter = false;
            ShowError(error);
            if (troubleshoot) InfoBarTroubleshootButton.Visibility = Visibility.Visible;
        }
        UpdateEmptyDevicesHint();
    }

    /// <summary>
    /// The sidebar's empty state (the troubleshooter and adding by address) while no scanner but
    /// the demo scanner is listed; not in the icon rail, where the header buttons are hidden too.
    /// </summary>
    private void UpdateEmptyDevicesHint()
    {
        EmptyDevicesHint.Visibility = !ViewModel.HasRealDevices && !IsPaneCompact ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>
    /// Shows an error in the InfoBar above the window content: a title naming the scanner's problem
    /// ("Paper jam") and what to do (<see cref="ScannerProblems.Notice"/>), the whole message as its
    /// tooltip. It stays until dismissed; a newer error replaces the text. Screen readers are told
    /// through a live-region event. The bar's Troubleshoot button is hidden; only a scanner error from
    /// the view model shows it again.
    /// </summary>
    private void ShowError(string message)
    {
        var notice = ScannerProblems.Notice(message);
        InfoBarTitle.Text = notice.Title;
        InfoBarMessage.Text = notice.Message;
        bool shortened = notice.Message != message.Trim();
        InfoBarText.ToolTip = shortened ? message : null;
        AutomationProperties.SetHelpText(InfoBarText, shortened ? message : "");
        InfoBarTroubleshootButton.Visibility = Visibility.Collapsed;
        InfoBar.Visibility = Visibility.Visible;
        var peer = UIElementAutomationPeer.FromElement(InfoBarText) ?? UIElementAutomationPeer.CreatePeerForElement(InfoBarText);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void InfoBarClose_Click(object sender, RoutedEventArgs e) => InfoBar.Visibility = Visibility.Collapsed;

    // MARK: - The bar after a save

    /// <summary>The paths the bar shows; a new list means a new save, which is announced.</summary>
    private IReadOnlyList<string>? _shownSavedPaths;

    /// <summary>
    /// The bar above the window content after a save: what was saved and the actions for it
    /// (Open only for one file; Open with and Email are in More).
    /// </summary>
    private void SyncSavedBar()
    {
        if (ViewModel.SavedBarPaths is not { } paths)
        {
            if (SavedBar.IsKeyboardFocusWithin) FocusMainAction();
            SavedBar.Visibility = Visibility.Collapsed;
            _shownSavedPaths = null;
            return;
        }
        bool isNew = !ReferenceEquals(paths, _shownSavedPaths);
        _shownSavedPaths = paths;
        // The file (or how many and where); its size and the full paths are the tooltip.
        SavedBarMessage.Text = SavedBarLine(paths, ViewModel.SavedBarNoun);
        SavedBarText.ToolTip = paths.Count == 1
            ? $"{ViewModel.SavedBarText}{Environment.NewLine}{paths[0]}"
            : string.Join(Environment.NewLine, paths);
        AutomationProperties.SetName(SavedBarText, $"Saved {ViewModel.SavedBarText}");
        var offered = ViewModel.SavedBarActions;
        foreach (var button in SavedBarButtons.Children.OfType<Button>())
        {
            if (button.Tag is not string tag) continue;
            var action = Enum.Parse<FileAction>(tag);
            button.Visibility = offered.Contains(action) ? Visibility.Visible : Visibility.Collapsed;
            button.ToolTip = action == FileAction.Share ? "Send by email or to an app" : FileActionMenu.Hint(action, paths.Count);
        }
        SavedBar.Visibility = Visibility.Visible;
        if (isNew) AnnounceWhenShown(SavedBarText);
    }

    private void SavedBarAction_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tag } && ViewModel.SavedBarPaths is { } paths)
        {
            ViewModel.RunFileAction(Enum.Parse<FileAction>(tag), paths);
        }
    }

    /// <summary>More: every action for the saved files (Open with and Email are only here).</summary>
    private void SavedBarMore_Click(object sender, RoutedEventArgs e)
    {
        if (BuildSavedBarMenu() is { } menu) FileActionMenu.ShowBelow(menu, SavedMoreButton);
    }

    /// <summary>The bar's More menu; null without saved files.</summary>
    internal ContextMenu? BuildSavedBarMenu()
    {
        if (ViewModel.SavedBarPaths is not { } paths) return null;
        return FileActionMenu.Build(ViewModel.SavedBarActions, paths.Count, action => ViewModel.RunFileAction(action, paths));
    }

    private void SavedBarClose_Click(object sender, RoutedEventArgs e)
    {
        // The bar goes away with the focused button: give the focus to the main action first.
        FocusMainAction();
        ViewModel.DismissSavedBar();
    }

    /// <summary>
    /// The bar's line after "Saved ·": the file's name, or "3 photos · Scans" for several, named by
    /// what was saved (<paramref name="noun"/>: "photos" only when every file is an image).
    /// </summary>
    /// <param name="noun">What the save wrote: "photos", "receipts" or "files".</param>
    internal static string SavedBarLine(IReadOnlyList<string> paths, string noun = "files")
    {
        if (paths.Count == 1) return System.IO.Path.GetFileName(paths[0]);
        bool images = paths.All(p => System.IO.Path.GetExtension(p).ToLowerInvariant() is ".jpg" or ".jpeg" or ".png" or ".tif" or ".tiff");
        if (noun == "photos" && !images) noun = "files";
        string folder = paths.Count > 0 ? System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(paths[0]) ?? "") : "";
        string what = $"{paths.Count} {noun}";
        return folder.Length > 0 ? $"{what} · {folder}" : what;
    }

    /// <summary>Below this bar width (a window under about 1000 DIPs) the action buttons show only their glyphs.</summary>
    private const double SavedBarCompactBelowWidth = 984;

    private void SavedBar_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!e.WidthChanged) return;
        bool compact = e.NewSize.Width < SavedBarCompactBelowWidth;
        foreach (var button in SavedBarButtons.Children.OfType<Button>().Where(b => b.Tag is string))
        {
            if (compact)
            {
                button.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
                button.Padding = new Thickness(8, 5, 8, 6);
                AutomationProperties.SetName(button, button.Content as string ?? "");
            }
            else
            {
                button.ClearValue(ContentControl.ContentTemplateProperty);
                button.ClearValue(PaddingProperty);
            }
        }
    }

    /// <summary>Keyboard focus to the screen's main action, when a focused bar goes away.</summary>
    private void FocusMainAction()
    {
        if (ViewModel.ShowPhotoReview && ReviewSaveButton.IsEnabled) ReviewSaveButton.Focus();
        else if (ViewModel.ShowIdCardReview && IdCardSaveButton.IsEnabled) IdCardSaveButton.Focus();
        else if (ScanTab.IsSelected && ScanButton.IsEnabled) ScanButton.Focus();
        else MainTabs.Focus();
    }

    // MARK: - After saving

    /// <summary>The after-save choices, in their order, with what each does as its tooltip.</summary>
    private static List<ComboBoxItem> AfterSaveItems() =>
        Enum.GetValues<AfterSaveAction>()
            .Select(action => new ComboBoxItem { Content = action.Label(), Tag = action, ToolTip = action.Hint() })
            .ToList();

    private static void SelectAfterSave(ComboBox box, AfterSaveAction action)
    {
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (AfterSaveAction)item.Tag == action);
        AutomationProperties.SetHelpText(box, action.Hint());
    }

    /// <summary>The inspector's and the photo review's "After saving": one setting, two places.</summary>
    private void AfterSave_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || sender is not ComboBox { SelectedItem: ComboBoxItem { Tag: AfterSaveAction action } }) return;
        ViewModel.Settings.Output.AfterSave = action;
        _updatingUi = true;
        try
        {
            SelectAfterSave(AfterSaveBox, action);
            SelectAfterSave(ReviewAfterSaveBox, action);
        }
        finally
        {
            _updatingUi = false;
        }
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
    }

    // MARK: - Tasks

    /// <summary>Title of the banner that guides turning a stack over by hand without a task.</summary>
    internal const string TurningOverTitle = "Two-sided scanning";

    /// <summary>
    /// The banner above the stage: the active task, or turning a stack over by hand, and what to
    /// do now; hidden when nothing is guided. Fronts scanned without moving on to the backs (the
    /// feeder stopped early) offer "Done with fronts". While the backs are due it offers keeping
    /// the fronts only and, before any back is scanned, scanning more fronts; when the counts did
    /// not pair up, scanning the backs again or combining the pages as they are.
    /// </summary>
    private void SyncTaskBanner()
    {
        var task = ViewModel.ActiveTaskDefinition;
        bool turningOver = ViewModel.IsTurningOverByHand;
        if (task is null && !turningOver)
        {
            TaskBanner.Visibility = Visibility.Collapsed;
            CanvasHintTitle.Visibility = Visibility.Visible;
            CanvasHintBody.Text = ViewModel.Settings.Source == ScanSource.DocumentFeeder ? ShortText.LoadFeeder : ShortText.PlaceOriginal;
            CanvasHintBody.Visibility = Visibility.Visible;
            return;
        }
        string title = task?.Title ?? TurningOverTitle;
        string name = task is null ? title : $"Task: {title}";
        bool sameTaskShown = TaskBanner.Visibility == Visibility.Visible && AutomationProperties.GetName(TaskBannerGroup) == name;
        // While a review shows its own title (photos, receipts, the ID card), the banner's guidance is
        // for the next scan: it is hidden under the review, keeping its place so nothing moves.
        bool reviewShown = ViewModel.ShowPhotoReview || ViewModel.ShowIdCardReview;
        TaskBanner.Visibility = reviewShown ? Visibility.Hidden : Visibility.Visible;
        TaskBannerGlyph.Text = TaskIcons.Glyph(task?.IconKey ?? "twoSided");
        var flow = ViewModel.Flow;
        var step = flow?.Current is { } current ? TaskCatalog.ShownStep(current, ViewModel.Settings) : null;
        TaskBannerTitle.Text = title;
        // A task of several steps: where it is, as "Front · Back · Check" with the current step stressed.
        if (flow is { StepCount: > 1 } && step is not null)
        {
            SetStepIndicator(flow);
            TaskBannerSteps.Visibility = Visibility.Visible;
            AutomationProperties.SetName(TaskBannerSteps,
                $"{title}, step {flow.StepIndex + 1} of {flow.StepCount}: {step.Title.ToLowerInvariant()}");
        }
        else
        {
            TaskBannerSteps.Visibility = Visibility.Collapsed;
        }
        // The step's short line on screen; its fuller guidance behind the ⓘ. Screen readers get both.
        string prompt = step?.Prompt ?? task?.Subtitle ?? DuplexMode.Manual.Hint();
        string help = step?.Help ?? "";
        string spoken = step?.FullPrompt ?? prompt;
        bool promptChanged = TaskBannerPrompt.Text != prompt;
        TaskBannerPrompt.Text = prompt;
        AutomationProperties.SetName(TaskBannerPrompt, spoken);
        TaskBannerInfo.Label = title;
        TaskBannerInfo.InfoText = help;
        TaskBannerInfo.Visibility = help.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(TaskBannerGroup, name);
        AutomationProperties.SetHelpText(TaskBannerGroup, spoken);
        // A new step of the same task (the backs after the fronts) is read out.
        if (sameTaskShown && promptChanged) AnnounceWhenShown(TaskBannerPrompt);

        // Without a task the close button stops turning stacks over by hand.
        string exitName = task is not null ? "Leave the task" : "Scan one side only";
        AutomationProperties.SetName(ExitTaskButton, exitName);
        ExitTaskButton.ToolTip = task is not null
            ? "Leave the task (settings stay)"
            : "Scan one side of each sheet";
        // Not while a scan runs: its result belongs to the task's steps.
        ExitTaskButton.IsEnabled = !ViewModel.IsBusy;

        bool awaitingBacks = ViewModel.AwaitingBacks;
        bool finishFronts = ViewModel.CanFinishFronts;
        SidesActions.Visibility = awaitingBacks || finishFronts ? Visibility.Visible : Visibility.Collapsed;
        FinishFrontsButton.Visibility = finishFronts ? Visibility.Visible : Visibility.Collapsed;
        MoreFrontsButton.Visibility = ViewModel.CanScanMoreFronts ? Visibility.Visible : Visibility.Collapsed;
        KeepFrontsButton.Visibility = awaitingBacks ? Visibility.Visible : Visibility.Collapsed;
        string? mismatch = awaitingBacks ? ViewModel.SidesMismatch : null;
        string notice = mismatch is null
            ? ""
            : $"{mismatch}. Scan the rest of the back sides, scan them again, or combine the pages as they are.";
        bool noticeChanged = SidesNoticeText.Text != notice;
        SidesNoticeText.Text = notice;
        SidesNotice.Visibility = mismatch is null ? Visibility.Collapsed : Visibility.Visible;
        CombineSidesButton.Visibility = mismatch is null ? Visibility.Collapsed : Visibility.Visible;
        ScanBacksAgainButton.Visibility = mismatch is null ? Visibility.Collapsed : Visibility.Visible;
        SidesActions.IsEnabled = !ViewModel.IsBusy;
        if (mismatch is not null && noticeChanged) AnnounceWhenShown(SidesNoticeText);

        // The back of an ID card may be left out: "Skip back side". (The backs of a stack turned
        // over by hand are left out with Keep fronts only.)
        bool skippable = ViewModel.CanSkipStep;
        StepActions.Visibility = skippable ? Visibility.Visible : Visibility.Collapsed;
        StepActions.IsEnabled = !ViewModel.IsBusy;
        if (skippable)
        {
            SkipStepButton.Content = step!.Id == IdCardSteps.BackStepId ? IdCardSteps.SkipBackLabel : $"Skip {step.Title.ToLowerInvariant()}";
            SkipStepButton.ToolTip = "Nothing is printed on the back: save the front only";
        }
        // The empty stage's title and line say what the banner and the status line say: hidden while
        // the banner shows (the import link stays).
        CanvasHintTitle.Visibility = Visibility.Collapsed;
        CanvasHintBody.Visibility = Visibility.Collapsed;
    }

    /// <summary>
    /// "Front · Back · Check": each step in a word (<see cref="TaskStep.Word"/>), the current one bold in
    /// the accent color.
    /// </summary>
    private void SetStepIndicator(TaskFlow flow)
    {
        TaskBannerSteps.Inlines.Clear();
        for (int i = 0; i < flow.StepCount; i++)
        {
            if (i > 0) TaskBannerSteps.Inlines.Add(new System.Windows.Documents.Run(" · "));
            string word = flow.Steps[i].Word;
            var run = new System.Windows.Documents.Run(word);
            if (i == flow.StepIndex)
            {
                run.FontWeight = FontWeights.SemiBold;
                run.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "AccentTextFillColorPrimaryBrush");
            }
            TaskBannerSteps.Inlines.Add(run);
        }
    }

    private void SkipStep_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SkipStep();
        RefreshFromViewModel();
        FocusMainAction();
    }

    // MARK: - ID card review

    /// <summary>Whether the ID card review was open at the last refresh (to move focus into it once).</summary>
    private bool _idCardReviewShown;

    /// <summary>
    /// The ID card review: each side with its turn and the note about its crop, a missing back with
    /// a way to scan it, the page both go on with what it holds and whether it is at real size, and
    /// the paper, format and side-image choices (the same settings as the inspector's).
    /// </summary>
    private void SyncIdCardReview()
    {
        bool shown = ViewModel.ShowIdCardReview;
        IdCardReviewOverlay.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown)
        {
            _idCardReviewShown = false;
            IdCardFrontImage.Source = null;
            IdCardBackImage.Source = null;
            IdCardPageImage.Source = null;
            return;
        }
        var front = ViewModel.IdCardFront;
        var back = ViewModel.IdCardBack;
        IdCardFrontImage.Source = front?.Thumbnail;
        IdCardFrontTurn.Angle = front?.RotationDegrees ?? 0;
        IdCardBackImage.Source = back?.Thumbnail;
        IdCardBackTurn.Angle = back?.RotationDegrees ?? 0;
        IdCardFrontNoteText.Text = ViewModel.IdCardFrontNote ?? "";
        IdCardFrontNotice.Visibility = ViewModel.IdCardFrontNote is null ? Visibility.Collapsed : Visibility.Visible;
        IdCardBackNoteText.Text = ViewModel.IdCardBackNote ?? "";
        IdCardBackNotice.Visibility = back is not null && ViewModel.IdCardBackNote is not null ? Visibility.Visible : Visibility.Collapsed;
        IdCardBackWell.Visibility = back is null ? Visibility.Collapsed : Visibility.Visible;
        IdCardNoBack.Visibility = back is null ? Visibility.Visible : Visibility.Collapsed;
        IdCardBackRotateButton.Visibility = IdCardBackCropButton.Visibility = IdCardBackRetakeButton.Visibility =
            back is null ? Visibility.Collapsed : Visibility.Visible;
        IdCardSwapButton.Visibility = back is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(IdCardBackCard, back is null ? "Back side: none" : "Back side");

        IdCardPageImage.Source = ViewModel.IdCardPreview;
        IdCardLayoutText.Text = ViewModel.IdCardLayoutCaption;
        IdCardSizeText.Text = ViewModel.IdCardSizeWarning ?? "";
        IdCardSizeNotice.Visibility = ViewModel.IdCardSizeWarning is null ? Visibility.Collapsed : Visibility.Visible;

        var s = ViewModel.Settings;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            // Automatic follows the default printer's paper, read after the window opened.
            foreach (var item in IdCardPaperBox.Items.Cast<ComboBoxItem>())
            {
                string label = ViewModel.IdCardPaperChoiceLabel((IdCardPaper)item.Tag);
                if (!Equals(item.Content, label)) item.Content = label;
            }
            IdCardPaperBox.SelectedItem = IdCardPaperBox.Items.Cast<ComboBoxItem>().First(i => (IdCardPaper)i.Tag == s.TaskOptions.IdCardPaper);
            var cardFormat = OutputFormats.PageFormat(s.Format);
            IdCardFormatBox.SelectedItem = IdCardFormatBox.Items.Cast<ComboBoxItem>().First(i => (OutputFormat)i.Tag == cardFormat);
            IdCardSidesBox.IsChecked = s.TaskOptions.IdCardSaveSidesAsImages;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
        var savedAs = OutputFormats.PageFormat(s.Format);
        IdCardSaveButton.Content = savedAs == OutputFormat.Pdf ? "Save PDF" : $"Save {savedAs.Label()}";
        AutomationProperties.SetHelpText(IdCardSaveButton,
            $"Save {(back is null ? "the front" : "both sides")} on one {ViewModel.IdCardPaperSize.Label()} page");

        bool busy = ViewModel.IsBusy;
        IdCardSaveButton.IsEnabled = !busy && front is not null;
        IdCardDiscardButton.IsEnabled = !busy;
        SyncIdCardPrint(busy);
        IdCardPaperBox.IsEnabled = IdCardFormatBox.IsEnabled = IdCardSidesBox.IsEnabled = !busy;
        IdCardFrontCard.IsEnabled = IdCardBackCard.IsEnabled = IdCardSwapButton.IsEnabled = !busy;
        IdCardFrontCropButton.IsEnabled = IdCardBackCropButton.IsEnabled = !ViewModel.IsRecropPending;
        if (!_idCardReviewShown)
        {
            _idCardReviewShown = true;
            Dispatcher.BeginInvoke(() =>
            {
                if (IdCardSaveButton.IsEnabled) IdCardSaveButton.Focus();
            }, System.Windows.Threading.DispatcherPriority.Loaded);
        }
    }

    private static PageSide SideOf(object sender) =>
        sender is FrameworkElement { Tag: "back" } ? PageSide.Back : PageSide.Front;

    private void IdCardSave_Click(object sender, RoutedEventArgs e) => _ = ViewModel.SaveIdCard();

    private void IdCardDiscard_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.DiscardIdCard();
        RefreshFromViewModel();
        FocusMainAction();
    }

    private void IdCardRotate_Click(object sender, RoutedEventArgs e) => ViewModel.RotateIdCardSide(SideOf(sender));

    private void IdCardSwap_Click(object sender, RoutedEventArgs e) => ViewModel.SwapIdCardSides();

    /// <summary>Scans a side again (or the back after all): the review closes and the Scan button takes over.</summary>
    private void IdCardRetake_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.RetakeIdCardSide(SideOf(sender));
        RefreshFromViewModel();
        Dispatcher.BeginInvoke(FocusMainAction, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// <summary>Fixes a side's crop in the crop editor, on the scan it was cut from.</summary>
    private void IdCardCrop_Click(object sender, RoutedEventArgs e)
    {
        var side = SideOf(sender);
        var item = side == PageSide.Front ? ViewModel.IdCardFront : ViewModel.IdCardBack;
        if (ViewModel.IsBusy || ViewModel.IsRecropPending || item is null) return;
        if (ViewModel.IdCardSource(side) is not { } source)
        {
            ShowError("The scan of this side is no longer available.");
            return;
        }
        var editor = new PhotoCropEditorWindow(source, item.Photo.Region, deskew: true) { Owner = this };
        if (editor.ShowDialog() == true && !editor.Region.Equals(item.Photo.Region))
        {
            _ = ViewModel.RecropIdCardSide(side, editor.Region);
        }
    }

    private void IdCardPaper_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || IdCardPaperBox.SelectedItem is not ComboBoxItem { Tag: IdCardPaper paper }) return;
        ViewModel.SetIdCardPaper(paper);
    }

    private void IdCardFormat_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || IdCardFormatBox.SelectedItem is not ComboBoxItem { Tag: OutputFormat format }) return;
        if (ViewModel.Settings.Format == format) return;
        // The same setting as the inspector's Format.
        ViewModel.Settings.Format = format;
        ViewModel.SettingsEdited();
        PushSettingsToUi();
        RefreshFromViewModel();
    }

    private void IdCardSides_Click(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetIdCardSaveSidesAsImages(IdCardSidesBox.IsChecked == true);
    }

    /// <summary>
    /// Names the items of the page strip for screen readers: "Page 3, Sheet 2, back". The badge
    /// and tooltip inside an item are not read, and an item is otherwise named after its type.
    /// </summary>
    private void NamePageItems()
    {
        for (int i = 0; i < PageList.Items.Count; i++)
        {
            if (PageList.Items[i] is PageItem item
                && PageList.ItemContainerGenerator.ContainerFromIndex(i) is ListBoxItem container)
            {
                AutomationProperties.SetName(container, item.AccessibleName(i + 1));
            }
        }
    }

    private void FinishFronts_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.FinishFronts();
        RefreshFromViewModel();
        FocusMainAction();
    }

    private void MoreFronts_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.ScanMoreFronts();
        RefreshFromViewModel();
        FocusMainAction();
    }

    private void CombineSides_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.CombineSidesAnyway();
        RefreshFromViewModel();
        FocusMainAction();
    }

    private void ScanBacksAgain_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.ScanBacksAgain();
        RefreshFromViewModel();
        FocusMainAction();
    }

    private void KeepFronts_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.KeepFrontsOnly();
        RefreshFromViewModel();
        FocusMainAction();
    }

    /// <summary>
    /// Tells screen readers that a live region changed, once layout has run: the element may
    /// only just have been shown (a tab switch). Nothing is raised if it is not on screen by then.
    /// </summary>
    private void AnnounceWhenShown(FrameworkElement element)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (!element.IsVisible) return;
            var peer = UIElementAutomationPeer.FromElement(element) ?? UIElementAutomationPeer.CreatePeerForElement(element);
            peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }, System.Windows.Threading.DispatcherPriority.ContextIdle);
    }

    /// <summary>Below this banner width, Change task shows only its glyph (its name stays in the tooltip and for screen readers).</summary>
    private const double BannerCompactBelowWidth = 520;
    /// <summary>Below this banner width, the task glyph is left out too, leaving the text the room.</summary>
    private const double BannerMinimalBelowWidth = 340;

    /// <summary>A narrow stage (small window, wide inspector) keeps the banner's text readable.</summary>
    private void TaskBanner_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!e.WidthChanged) return;
        double width = e.NewSize.Width;
        bool compact = width < BannerCompactBelowWidth;
        if (compact)
        {
            ChangeTaskButton.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            ChangeTaskButton.Padding = new Thickness(8, 5, 8, 6);
        }
        else
        {
            ChangeTaskButton.ClearValue(ContentControl.ContentTemplateProperty);
            ChangeTaskButton.ClearValue(PaddingProperty);
        }
        bool minimal = width < BannerMinimalBelowWidth;
        TaskBannerBadge.Visibility = minimal ? Visibility.Collapsed : Visibility.Visible;
        TaskBannerTexts.Margin = new Thickness(minimal ? 0 : 12, 0, 0, 0);
    }

    /// <summary>A task card was picked: set it up and go to the scan screen.</summary>
    private void StartTask(ScanTask task)
    {
        if (ViewModel.IsBusy || !ConfirmDropIdCard()) return;
        if (!ViewModel.StartTask(task)) return;
        ViewModel.ClearAppendTarget();
        OpenSectionFor(task);
        PushSettingsToUi();
        ShowScanScreen();
    }

    /// <summary>
    /// Asks before something that can end the ID card task (leaving it, picking a task, a preset
    /// or another scanner) while a side of the card is held and not saved. Discard drops the card
    /// and goes on (true); Cancel keeps it (false). True at once when no side is held. Refused
    /// (false) while an operation runs: the card cannot be discarded then.
    /// </summary>
    private bool ConfirmDropIdCard()
    {
        if (ViewModel.IsBusy) return false;
        if (!ViewModel.HasIdCardCaptures) return true;
        if (!AskDiscardIdCard() || ViewModel.IsBusy) return false;
        ViewModel.DiscardIdCard();
        return true;
    }

    /// <summary>Why the mode and the source cannot be changed while a side of an ID card is held.</summary>
    private const string IdCardHeldHint =
        "The ID card task needs the flatbed in Document mode. Save or discard the card, or leave the task, to change this.";

    /// <summary>The question <see cref="ConfirmDropIdCard"/> asks: true to discard the card.</summary>
    private Func<bool> AskDiscardIdCard;

    private bool AskDiscardIdCardInDialog() =>
        MessageBox.Show(this, "The ID card has not been saved. Its scanned sides will be discarded.\n\nDiscard the ID card?",
                        "Lazy Scan", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No)
        == MessageBoxResult.Yes;

    /// <summary>A preset card was picked: apply it and go to the scan screen.</summary>
    private void StartPreset(Preset preset)
    {
        if (ViewModel.IsBusy || !ConfirmDropIdCard()) return;
        ViewModel.ApplyPreset(preset);
        ViewModel.ClearAppendTarget();
        PushSettingsToUi();
        _savedTabStale = true;
        ShowScanScreen();
    }

    /// <summary>Opens the scan screen with keyboard focus on its main action.</summary>
    private void ShowScanScreen()
    {
        ScanTab.IsSelected = true;
        RefreshFromViewModel();
        // After the tab's content is laid out, so the button can take focus.
        Dispatcher.BeginInvoke(FocusMainAction, System.Windows.Threading.DispatcherPriority.Loaded);
        // Focus lands on the Scan button, outside the banner, so the task is announced ("Task: Photos").
        if (ViewModel.ActiveTaskDefinition is not null) AnnounceWhenShown(TaskBannerGroup);
    }

    private void ChangeTask_Click(object sender, RoutedEventArgs e)
    {
        StartTab.IsSelected = true;
        Dispatcher.BeginInvoke(StartView.FocusDefaultCard, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private void ExitTask_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.IsBusy) return;
        if (ViewModel.ActiveTask is not null)
        {
            if (!ConfirmDropIdCard()) return;
            ViewModel.ExitTask();
        }
        else
        {
            ViewModel.ScanOneSideOnly();
        }
        PushSettingsToUi();
        RefreshFromViewModel();
        FocusMainAction();
    }

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

    /// <summary>
    /// Why Scan and Preview are off while no scanner is connected: the selected one is still
    /// connecting, it would not connect, or none is selected. Null once it is connected.
    /// </summary>
    private string? NotConnectedHint()
    {
        if (ViewModel.IsConnected) return null;
        if (ViewModel.SelectedDeviceId is not { } id) return "No scanner selected.";
        string name = ViewModel.Devices.FirstOrDefault(d => d.Id == id)?.Name ?? "the scanner";
        return ViewModel.IsConnecting ? $"Connecting to {name}…" : $"Not connected to {name}. Choose it in the list again to retry.";
    }

    /// <summary>
    /// The TWAIN "own settings window" switch: shown only for connections that have one,
    /// fixed on when the driver cannot scan without it.
    /// </summary>
    private void SyncDriverWindowOption()
    {
        bool available = ViewModel.HasDriverWindowOption;
        DriverWindowOptions.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
        if (!available) return;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            DriverWindowBox.IsChecked = ViewModel.UseDriverWindow;
            DriverWindowBox.IsEnabled = !ViewModel.DriverWindowRequired;
            DriverWindowReason.Visibility = ViewModel.DriverWindowRequired ? Visibility.Visible : Visibility.Collapsed;
            string hint = ViewModel.DriverWindowRequired
                ? "This scanner's driver always shows its own window; resolution, color and area are chosen there."
                : ViewModel.UseDriverWindow
                    ? "Scan opens the driver's window; resolution, color and area are chosen there."
                    : "Scan with the settings above, without the driver's window.";
            DriverWindowBox.ToolTip = "Resolution, color and area are chosen in the driver's window";
            AutomationProperties.SetHelpText(DriverWindowBox, hint);
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    private void DriverWindow_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetUseDriverWindow(DriverWindowBox.IsChecked == true);
        RefreshFromViewModel();
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
            SyncSidesOptions();
            SyncPaperSizeOptions();
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    // MARK: - Sides and paper size

    /// <summary>The reasons the sides choices were last built with, so unchanged items are not rebuilt.</summary>
    private string? _sidesSignature;
    /// <summary>The source and area the paper sizes were last built for.</summary>
    private string? _paperSignature;

    /// <summary>
    /// The sides choice: shown for scanners with a feeder, usable while the feeder is the
    /// source. "Both sides" is greyed out (with the reason) on a feeder that scans one side, and
    /// turning over by hand when the settings cannot guide it (photos, or each scan saved at
    /// once). Call with <see cref="_updatingUi"/> set.
    /// </summary>
    private void SyncSidesOptions()
    {
        var s = ViewModel.Settings;
        var caps = ViewModel.Capabilities;
        bool hasFeeder = caps?.Sources.Contains(ScanSource.DocumentFeeder) ?? false;
        SidesOptions.Visibility = hasFeeder ? Visibility.Visible : Visibility.Collapsed;
        if (!hasFeeder) return;
        bool feeder = s.Source == ScanSource.DocumentFeeder;
        string? bothReason = caps is { SupportsDuplex: false } ? DocumentSides.OneSidedFeederReason : null;
        string? manualReason = DocumentSides.ManualUnavailableReason(s);
        string signature = $"{bothReason}\u001f{manualReason}";
        if (signature != _sidesSignature)
        {
            _sidesSignature = signature;
            SidesBox.Items.Clear();
            foreach (var mode in Enum.GetValues<DuplexMode>())
            {
                string? reason = mode switch
                {
                    DuplexMode.Both => bothReason,
                    DuplexMode.Manual => manualReason,
                    _ => null,
                };
                var item = new ComboBoxItem
                {
                    Content = mode.Label(),
                    Tag = mode,
                    IsEnabled = reason is null,
                    ToolTip = reason ?? mode.Hint(),
                };
                ToolTipService.SetShowOnDisabled(item, true);
                AutomationProperties.SetHelpText(item, reason ?? mode.Hint());
                SidesBox.Items.Add(item);
            }
        }
        SidesBox.SelectedItem = SidesBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (DuplexMode)i.Tag == s.Duplex);
        SidesBox.IsEnabled = feeder;
        // On the flatbed of a scanner with a feeder: greyed out, with the reason next to it.
        SidesHint.Text = feeder ? "" : DocumentSides.NeedsFeederReason;
        SidesReason.Visibility = feeder ? Visibility.Collapsed : Visibility.Visible;
        string sidesHelp = !feeder ? DocumentSides.FeederOnlyReason
            : s.Duplex == DuplexMode.Manual && manualReason is not null ? manualReason
            : s.Duplex == DuplexMode.Off && bothReason is not null ? $"{s.Duplex.Hint()} {bothReason}"
            : s.Duplex.Hint();
        SidesBox.ToolTip = sidesHelp;
        AutomationProperties.SetHelpText(SidesBox, feeder ? sidesHelp : $"{DocumentSides.NeedsFeederReason}. {sidesHelp}");
        BackBindingOptions.Visibility = feeder && s.Duplex != DuplexMode.Off ? Visibility.Visible : Visibility.Collapsed;
        BackBindingBox.SelectedItem = BackBindingBox.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(i => (DuplexBinding)i.Tag == s.BackBinding);
    }

    /// <summary>
    /// The paper sizes, Automatic and the usual size where the user lives first. Sizes larger
    /// than the glass or the feeder (whichever is the source) are greyed out with the reason.
    /// Call with <see cref="_updatingUi"/> set.
    /// </summary>
    private void SyncPaperSizeOptions()
    {
        var s = ViewModel.Settings;
        var caps = ViewModel.Capabilities;
        SizeD? area = caps is null ? null
            : s.Source == ScanSource.DocumentFeeder ? caps.FeederSizeInches : caps.FlatbedSizeInches;
        string signature = $"{s.Source}\u001f{area}\u001f{ViewModel.IsCopyFlow}";
        if (signature != _paperSignature)
        {
            _paperSignature = signature;
            PaperSizeBox.Items.Clear();
            foreach (var size in PaperSizes.DisplayOrder(RegionInfo.CurrentRegion.TwoLetterISORegionName))
            {
                bool fits = PaperSizes.Fits(size, area);
                string tip = !fits ? PaperSizes.DoesNotFitReason(s.Source)
                    : size == PaperSize.Auto && ViewModel.IsCopyFlow ? PrintText.CopyPaperHint(size, s.Source)
                    : PaperSizes.Hint(size, s.Source);
                // A size larger than the glass or the feeder stays listed, greyed out with why after its name.
                string content = size == PaperSize.Auto ? size.Label() : $"{size.Label()}  ({size.Detail()})";
                var item = new ComboBoxItem
                {
                    Content = fits ? content : $"{content} · {tip}",
                    Tag = size,
                    IsEnabled = fits,
                    ToolTip = fits ? tip : null,
                };
                ToolTipService.SetShowOnDisabled(item, true);
                AutomationProperties.SetHelpText(item, tip);
                PaperSizeBox.Items.Add(item);
            }
        }
        PaperSizeBox.SelectedItem = PaperSizeBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (PaperSize)i.Tag == s.PaperSize);
        AutomationProperties.SetHelpText(PaperSizeBox,
            ViewModel.IsCopyFlow ? PrintText.CopyPaperHint(s.PaperSize, s.Source) : PaperSizes.Hint(s.PaperSize, s.Source));
    }

    private void Sides_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        var s = ViewModel.Settings;
        if (SidesBox.SelectedItem is ComboBoxItem { Tag: DuplexMode mode }) s.Duplex = mode;
        if (BackBindingBox.SelectedItem is ComboBoxItem { Tag: DuplexBinding binding }) s.BackBinding = binding;
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
    }

    private void PaperSize_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        if (PaperSizeBox.SelectedItem is ComboBoxItem { Tag: PaperSize size }) ViewModel.Settings.PaperSize = size;
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
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
            SyncFormatChoices();
            MultiPageBox.IsChecked = s.DocumentMultiPage;
            SearchableBox.IsChecked = s.PdfSearchable;
            AlsoSaveTextBox.IsChecked = s.Output.AlsoSaveText;
            WordPageImagesBox.IsChecked = s.Output.WordPageImages;
            // The two exclude each other; a settings file with both on gets the password.
            ProtectBox.IsChecked = s.Output.Protect;
            ArchivalBox.IsChecked = s.Output.Archival && !s.Output.Protect;
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
            foreach (var segment in PdfSizeSegments.Children.OfType<RadioButton>())
            {
                segment.IsChecked = (PdfSizePreset)segment.Tag == s.Output.PdfSize;
            }
            SelectAfterSave(AfterSaveBox, s.Output.AfterSave);
            SelectAfterSave(ReviewAfterSaveBox, s.Output.AfterSave);
            SkipBlankBox.IsChecked = s.Document.RemoveBlankPages;
            foreach (var segment in BlankSensitivitySegments.Children.OfType<RadioButton>())
            {
                segment.IsChecked = (BlankSensitivity)segment.Tag == s.Document.BlankSensitivity;
            }
            AutoCropBox.IsChecked = s.Document.AutoCrop;
            AutoStraightenBox.IsChecked = s.Document.AutoStraighten;
            AutoRotateBox.IsChecked = s.Document.AutoRotate;
            SyncPdfSizeOptions();
            SyncBlankPageOptions();
            SyncGeometryOptions();
            SyncAutoRotateOptions();
            SyncAdjustmentOptions();
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
        s.DocumentMultiPage = MultiPageBox.IsChecked == true;
        s.PdfSearchable = SearchableBox.IsChecked == true;
        s.Output.AlsoSaveText = AlsoSaveTextBox.IsChecked == true;
        s.Output.WordPageImages = WordPageImagesBox.IsChecked == true;
        s.Output.Protect = ProtectBox.IsChecked == true;
        s.Output.Archival = ArchivalBox.IsChecked == true && !s.Output.Protect;
        if (PdfSizeSegments.Children.OfType<RadioButton>().FirstOrDefault(b => b.IsChecked == true) is { Tag: PdfSizePreset size })
        {
            s.Output.PdfSize = size;
        }
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
        // After the edit: a change the Copy task does not fit ends it, which turns these switches on;
        // a change that ends the Receipts task offers Word and text again.
        SyncFormatChoices();
        SyncPdfSizeOptions();
        SyncBlankPageOptions();
        SyncGeometryOptions();
        SyncAutoRotateOptions();
        SyncAdjustmentOptions();
        RefreshFromViewModel();
    }

    // MARK: - Blank pages

    /// <summary>One text segment per sensitivity, least first; each names what counts as blank on hover and for screen readers.</summary>
    private void BuildBlankSensitivitySegments()
    {
        foreach (var level in BlankSensitivities.DisplayOrder)
        {
            var segment = new RadioButton
            {
                Content = level.Label(),
                Tag = level,
                ToolTip = level.Hint(),
                Style = (Style)FindResource("SegmentedTextItemStyle"),
            };
            AutomationProperties.SetHelpText(segment, level.Hint());
            segment.Checked += BlankPages_Changed;
            BlankSensitivitySegments.Children.Add(segment);
        }
        BlankSensitivitySegments.Columns = BlankSensitivities.DisplayOrder.Count;
    }

    /// <summary>
    /// The blank-page check runs on pages collected in the queue only, where flagged pages can be
    /// seen and kept: with each scan saved at once, and for copies, the switch is off and says why.
    /// </summary>
    private void SyncBlankPageOptions()
    {
        var s = ViewModel.Settings;
        var flow = TaskCatalog.FlowOf(s);
        bool copy = flow == TaskFlowKind.Copy;
        bool receipts = flow == TaskFlowKind.ReceiptSplit;
        bool collecting = PageProcessor.ChecksBlankPages(s);
        // One-sided at blank sheets, every blank page is a separator: the switch has no say.
        bool separators = collecting && DocumentSplitter.BlankPagesAreSeparators(s.Document, ViewModel.EffectiveDuplex);
        SkipBlankBox.IsEnabled = collecting && !separators;
        PagesReason.Visibility = collecting ? Visibility.Collapsed : Visibility.Visible;
        SkipBlankReason.Visibility = separators ? Visibility.Visible : Visibility.Collapsed;
        string hint = copy
            ? "Copies print every page as scanned: blank pages are not left out."
            : receipts
            ? "Receipts are found on the glass and checked before saving: there are no blank pages to leave out."
            : separators
            ? DocumentSplitter.BlankPagesAreSeparatorsHint
            : collecting
            ? s.Document.RemoveBlankPages
                ? "Blank pages are marked in the page strip and left out when you save. Click Keep on a page to save it."
                : "Blank pages are marked in the page strip. Click Skip on a page to leave it out."
            : "Only for pages collected before saving: a scan saved at once keeps every page.";
        // What the switch does is its tooltip; the full explanation (and why it is greyed out) its help text.
        SkipBlankBox.ToolTip = separators ? DocumentSplitter.BlankPagesAreSeparatorsHint
            : "Blank pages are left out. Click Keep on a page to save it.";
        AutomationProperties.SetHelpText(SkipBlankBox, hint);
        // What counts as blank shows while it decides something: whenever collected pages are checked
        // for blanks. High warns to check the flagged pages.
        BlankSensitivityOptions.Visibility = BlankSensitivityApplies(s) ? Visibility.Visible : Visibility.Collapsed;
        BlankHighNotice.Visibility = s.Document.BlankSensitivity == BlankSensitivity.High ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>
    /// What counts as blank matters whenever pages collected in the queue are checked for blanks
    /// (<see cref="PageProcessor.ChecksBlankPages"/>), Skip blank on or off: it decides which pages the
    /// strip flags "Looks blank" (and offers to skip), which are left out while blank pages are skipped,
    /// and which sheets split the stack at blank sheets.
    /// </summary>
    internal static bool BlankSensitivityApplies(ScanSettings settings) => PageProcessor.ChecksBlankPages(settings);

    private void BlankPages_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        var document = ViewModel.Settings.Document;
        document.RemoveBlankPages = SkipBlankBox.IsChecked == true;
        if (BlankSensitivitySegments.Children.OfType<RadioButton>().FirstOrDefault(b => b.IsChecked == true) is { Tag: BlankSensitivity level })
        {
            document.BlankSensitivity = level;
        }
        SyncBlankPageOptions();
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
    }

    /// <summary>
    /// Crop and straighten run on pages collected in the queue only, where a changed page shows a
    /// swap button: with each scan saved at once, and for copies, the switches are off and say why.
    /// </summary>
    private void SyncGeometryOptions()
    {
        var s = ViewModel.Settings;
        var flow = TaskCatalog.FlowOf(s);
        bool copy = flow == TaskFlowKind.Copy;
        bool receipts = flow == TaskFlowKind.ReceiptSplit;
        bool collecting = PageProcessor.ChecksBlankPages(s);
        AutoCropBox.IsEnabled = collecting;
        AutoStraightenBox.IsEnabled = collecting;
        string hint = copy
            ? "Copies print every page as scanned: pages are not cropped or straightened."
            : receipts
            ? "Each receipt is cut out along its paper, or around its print, and turned straight on its own."
            : !collecting
            ? "Only for pages collected before saving: a scan saved at once is kept as scanned."
            : (s.Document.AutoCrop, s.Document.AutoStraighten) switch
            {
                (true, true) => "Pages are cut out of the scanner background and turned straight when that is clear. Click the arrow on a page to see it as scanned.",
                (true, false) => "Pages are cut out of the scanner background when that is clear. Click the arrow on a page to see it as scanned.",
                (false, true) => "Pages that lie at a slant are turned straight when that is clear. Click the arrow on a page to see it as scanned.",
                _ => "Cut each page out of the scanner background, and turn pages that lie at a slant.",
            };
        foreach (var box in new[] { AutoCropBox, AutoStraightenBox })
        {
            AutomationProperties.SetHelpText(box, hint);
        }
    }

    private void Geometry_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        var document = ViewModel.Settings.Document;
        document.AutoCrop = AutoCropBox.IsChecked == true;
        document.AutoStraighten = AutoStraightenBox.IsChecked == true;
        SyncGeometryOptions();
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
    }

    /// <summary>
    /// Turning pages upright runs on pages collected in the queue only, where a turned page shows an
    /// undo button, and needs a text recognition language: otherwise the switch is off and says why.
    /// </summary>
    private void SyncAutoRotateOptions()
    {
        var s = ViewModel.Settings;
        bool collecting = PageProcessor.ChecksBlankPages(s);
        bool available = ViewModel.CanTurnPagesUpright;
        AutoRotateBox.IsEnabled = collecting && available;
        string hint = PageTurns.Hint(s, available);
        // Greyed out for want of a text recognition language: the reason shows next to it.
        bool missingLanguage = collecting && !available;
        AutoRotateHint.Text = missingLanguage ? hint : "";
        AutoRotateReason.Visibility = missingLanguage ? Visibility.Visible : Visibility.Collapsed;
        AutoRotateBox.ToolTip = hint;
        AutomationProperties.SetHelpText(AutoRotateBox, hint);
    }

    private void AutoRotate_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.Settings.Document.AutoRotate = AutoRotateBox.IsChecked == true;
        SyncAutoRotateOptions();
        ViewModel.SettingsEdited();
        RefreshFromViewModel();
    }

    private async void PageUpright_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        await ViewModel.TogglePageUpright(id);
        RefreshFromViewModel();
        // The page was replaced (its pixels turned): its new container takes the focus, so the
        // keyboard stays on the page.
        int index = IndexOfPage(id);
        if (index >= 0 && PageList.ItemContainerGenerator.ContainerFromIndex(index) is ListBoxItem container)
        {
            container.Focus();
        }
    }

    private async void PageGeometry_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        await ViewModel.TogglePageGeometry(id);
        RefreshFromViewModel();
        // The page was replaced (its pixels changed): its new container takes the focus, so the
        // keyboard stays on the page. It may also have been removed while its other version was read.
        int index = IndexOfPage(id);
        if (index >= 0 && PageList.ItemContainerGenerator.ContainerFromIndex(index) is ListBoxItem container)
        {
            container.Focus();
        }
    }

    private int IndexOfPage(Guid id)
    {
        for (int i = 0; i < ViewModel.ScannedPages.Count; i++)
        {
            if (ViewModel.ScannedPages[i].Page.Id == id) return i;
        }
        return -1;
    }

    private void PageToggle_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        ViewModel.TogglePageInclusion(id);
        RefreshFromViewModel();
        // The page keeps its container, so the button keeps the focus. A page skipped by hand that
        // goes back to what the setting says may have no button left: its page takes the focus,
        // so it stays in the strip.
        if (sender is Button { Visibility: not Visibility.Visible } button
            && ItemsControl.ContainerFromElement(PageList, button) is ListBoxItem container)
        {
            container.Focus();
        }
    }

    // MARK: - PDF size

    /// <summary>One text segment per PDF size, largest first; each names what it does for screen readers and on hover.</summary>
    private void BuildPdfSizeSegments()
    {
        foreach (var size in PdfSizePresets.DisplayOrder)
        {
            var segment = new RadioButton
            {
                Content = size.Label(),
                Tag = size,
                ToolTip = size.Hint(),
                Style = (Style)FindResource("SegmentedTextItemStyle"),
            };
            AutomationProperties.SetHelpText(segment, $"{size.Hint()}. {size.Detail()}");
            segment.Checked += Setting_Changed;
            PdfSizeSegments.Children.Add(segment);
        }
        PdfSizeSegments.Columns = PdfSizePresets.DisplayOrder.Count;
    }

    /// <summary>
    /// The size choice is shown for PDF output, with the chosen size's hint under it, and for the
    /// page pictures of a Word document (the switch above it), which are stored at that size. The
    /// text beside a PDF can be asked for whenever a save of document pages writes a PDF: the ID
    /// card's and a copy's PDFs are saved without it, so there the switch is off and says why.
    /// </summary>
    private void SyncPdfSizeOptions()
    {
        var s = ViewModel.Settings;
        var flow = TaskCatalog.FlowOf(s);
        bool receipts = flow == TaskFlowKind.ReceiptSplit;
        // Receipts and the ID card are saved as a PDF or an image: a Word or text format left from before
        // saves PDFs.
        bool pageOnly = InspectorSections.SavesPageFormat(s);
        var shownFormat = pageOnly ? OutputFormats.PageFormat(s.Format) : s.Format;
        bool documents = s.Intent == ScanIntent.Document;
        bool word = documents && shownFormat == OutputFormat.Word;
        bool pdf = documents && shownFormat == OutputFormat.Pdf;
        WordOptions.Visibility = word ? Visibility.Visible : Visibility.Collapsed;
        string pageImagesHint = DocxWriter.PageImagesHint(s.Output.WordPageImages);
        WordPageImagesBox.ToolTip = pageImagesHint;
        AutomationProperties.SetHelpText(WordPageImagesBox, pageImagesHint);
        PdfSizeOptions.Visibility = pdf || (word && s.Output.WordPageImages) ? Visibility.Visible : Visibility.Collapsed;
        PdfSizeLabel.Text = pdf ? "PDF size" : "Page image size";
        AutomationProperties.SetName(PdfSizeTrack, PdfSizeLabel.Text);
        AutomationProperties.SetHelpText(PdfSizeTrack, $"{s.Output.PdfSize.Hint()}. {s.Output.PdfSize.Detail()}");
        bool savesPdf = pageOnly ? OutputFormats.PageFormat(s.Format) == OutputFormat.Pdf : OutputFormats.SavesPdf(s.Format, s.DocumentMultiPage);
        AlsoSaveTextBox.IsEnabled = savesPdf && (flow == TaskFlowKind.DocumentQueue || receipts);
        // Receipts are saved from their review, and the ID card from its own: collecting pages does
        // nothing for them. The text layer of the copy's and the ID card's PDF is never made.
        bool idCard = flow == TaskFlowKind.IdCard;
        MultiPageBox.Visibility = receipts || idCard ? Visibility.Collapsed : Visibility.Visible;
        // Shown whenever the save writes a PDF that can carry text: a queue of JPEG pages saves one too.
        SearchableBox.Visibility = WritesPdf(s) && flow != TaskFlowKind.Copy && !idCard ? Visibility.Visible : Visibility.Collapsed;
        string hint = flow switch
        {
            TaskFlowKind.IdCard => "Not for ID cards: the card is saved as a picture, without its text.",
            TaskFlowKind.Copy => "Not for copies: the PDF of a copy is saved without its text.",
            TaskFlowKind.ReceiptSplit when savesPdf => "Writes the text of each receipt beside its PDF, in a .txt file with the same name.",
            _ when savesPdf => "Writes the text of the pages beside each PDF, in a .txt file with the same name.",
            _ => "Only for PDFs: Word and text files are the text already, and images have none.",
        };
        AutomationProperties.SetHelpText(AlsoSaveTextBox, hint);
        SyncPdfProtectionOptions();
    }

    /// <summary>
    /// Archival PDF and the password exclude each other: while one is on, the other is greyed out
    /// and the note under them (and the greyed switch's tooltip) says why.
    /// </summary>
    private void SyncPdfProtectionOptions()
    {
        var output = ViewModel.Settings.Output;
        bool protect = output.Protect, archival = output.Archival && !protect;
        ArchivalBox.IsEnabled = !protect;
        ProtectBox.IsEnabled = !archival;
        // The greyed-out one shows why next to it, with a lock; screen readers hear the reason first.
        ArchivalReason.Visibility = protect ? Visibility.Visible : Visibility.Collapsed;
        ProtectReason.Visibility = archival ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetHelpText(ArchivalBox,
            protect ? $"{PdfA.NotWithPasswordReason}. {PdfA.CannotProtectNote}" : PdfA.OptionHelp);
        AutomationProperties.SetHelpText(ProtectBox,
            archival ? $"{PdfProtection.NotWithArchivalReason}. {PdfA.CannotProtectNote}" : PdfProtection.OptionHelp);
    }

    /// <summary>
    /// The formats the mode offers (<see cref="OutputFormats.Offered"/>), with the format a save
    /// uses chosen: photos are saved as an image, so a PDF or text format shows as JPEG there
    /// (the setting itself is kept for documents). Receipts and the ID card are saved as a PDF or an
    /// image (<see cref="OutputFormats.PageFormat"/>): Word and text are not offered, and show as PDF.
    /// </summary>
    private void SyncFormatChoices()
    {
        var s = ViewModel.Settings;
        bool pageOnly = InspectorSections.SavesPageFormat(s);
        var offered = OutputFormats.Offered(s.Intent).Where(f => !pageOnly || OutputFormats.PageFormat(f) == f).ToList();
        var labels = offered.Select(f => f.Label()).ToList();
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            if (FormatBox.ItemsSource is not IEnumerable<string> current || !current.SequenceEqual(labels))
            {
                FormatBox.ItemsSource = labels;
            }
            var shown = offered.Contains(s.Format) ? s.Format
                : pageOnly ? OutputFormats.PageFormat(s.Format)
                : OutputFormats.ImageFormatOrJpeg(s.Format);
            FormatBox.SelectedItem = shown.Label();
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    /// <summary>A format picked in the inspector: the only place the setting is read from the box.</summary>
    private void Format_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || FormatBox.SelectedItem is not string label) return;
        var format = Enum.GetValues<OutputFormat>().FirstOrDefault(v => v.Label() == label);
        if (ViewModel.Settings.Format == format) return;
        ViewModel.Settings.Format = format;
        Setting_Changed(sender, e);
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

    /// <summary>
    /// Saturation and Restore faded colors work in color only: a grayscale or black and white scan is
    /// turned gray right after them (<see cref="ImagePipeline.Apply"/>), so they are off and say why.
    /// </summary>
    private void SyncAdjustmentOptions()
    {
        bool color = ViewModel.Settings.ColorMode == ColorMode.Color;
        SaturationSlider.IsEnabled = color;
        RestoreBox.IsEnabled = color;
        ColorReason.Visibility = color ? Visibility.Collapsed : Visibility.Visible;
        string? tip = color ? null
            : "Saturation and Restore faded colors change nothing on a grayscale or black-and-white scan. Choose Color under Scanner.";
        SaturationSlider.ToolTip = tip;
        RestoreBox.ToolTip = tip;
        AutomationProperties.SetHelpText(SaturationSlider, tip ?? "");
        AutomationProperties.SetHelpText(RestoreBox, tip ?? "");
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
        if (DeviceList.SelectedItem is DeviceRow row && row.Id != ViewModel.SelectedDeviceId)
        {
            // A scanner without a flatbed ends the ID card task, and a scanner's sources are known
            // only once it is open, so any switch asks while a side is held. Cancel selects the
            // scanner in use again.
            if (ViewModel.HasIdCardCaptures && !ConfirmDropIdCard())
            {
                SyncDeviceSelection();
                return;
            }
            ViewModel.UserSelectDevice(row.Id);
        }
    }

    /// <summary>
    /// Clicking the selected scanner again while it is not connected (it was off, or did not answer)
    /// opens it again, which SelectionChanged never reports. Handled on the press, before the list
    /// selects, so a scanner picked by this very click is not opened twice.
    /// </summary>
    private void DeviceList_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is not UIElement source
            || ItemsControl.ContainerFromElement(DeviceList, source) is not ListBoxItem { DataContext: DeviceRow row } item
            || row.Id != ViewModel.SelectedDeviceId || ViewModel.IsConnected || ViewModel.IsConnecting)
        {
            return;
        }
        // Not from the row's "via" button, which opens the connection menu.
        for (DependencyObject? node = source; node != item; node = System.Windows.Media.VisualTreeHelper.GetParent(node))
        {
            if (node is null or ButtonBase) return;
        }
        ViewModel.UserSelectDevice(row.Id);
    }

    /// <summary>The "via WIA" button of a scanner reached several ways: choose the connection.</summary>
    private void ConnectionButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: DeviceRow row } button) return;
        var menu = BuildConnectionMenu(row);
        menu.PlacementTarget = button;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    /// <summary>
    /// The keyboard (Shift+F10, Menu key) and right-click route to the same menu: the row's
    /// placeholder context menu is replaced as it opens with the connection menu, followed by
    /// the network addresses added by hand that reach the scanner (to remove them). Rows with
    /// neither get no menu.
    /// </summary>
    private void DeviceList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source
            && ItemsControl.ContainerFromElement(DeviceList, source) is ListBoxItem { DataContext: DeviceRow row } item
            && BuildDeviceMenu(row) is { } menu)
        {
            item.ContextMenu = menu;
        }
        else
        {
            e.Handled = true;
        }
    }

    /// <summary>A row's context menu (see <see cref="DeviceList_ContextMenuOpening"/>); null when it has nothing to offer.</summary>
    internal ContextMenu? BuildDeviceMenu(DeviceRow row)
    {
        var addresses = ViewModel.NetworkScanners is { } network
            ? row.Group.Members.SelectMany(m => network.ManualAddresses(m.Id)).Distinct().ToList()
            : [];
        if (!row.HasConnectionChoice && addresses.Count == 0) return null;
        var menu = row.HasConnectionChoice ? BuildConnectionMenu(row) : new ContextMenu();
        if (addresses.Count > 0 && menu.Items.Count > 0) menu.Items.Add(new Separator());
        foreach (var address in addresses)
        {
            var item = new MenuItem
            {
                Header = $"Remove address {address}",
                ToolTip = "Stop looking for a scanner at this address. A scanner that is also found automatically stays listed.",
            };
            item.Click += (_, _) => ViewModel.NetworkScanners?.RemoveAddress(address);
            menu.Items.Add(item);
        }
        return menu;
    }

    // MARK: - Network scanners

    /// <summary>
    /// "Why isn't my scanner listed?": the troubleshooter, from the Scanners header, the empty
    /// list and an error about a scanner. It follows the app while open.
    /// </summary>
    private void Troubleshoot_Click(object sender, RoutedEventArgs e)
    {
        if (sender == InfoBarTroubleshootButton) InfoBar.Visibility = Visibility.Collapsed;
        new TroubleshooterWindow(ViewModel) { Owner = this }.ShowDialog();
    }

    /// <summary>"Add scanner by address": the dialog checks and adds it; it is then selected.</summary>
    private void AddScanner_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.NetworkScanners is not { } network) return;
        var dialog = new AddScannerWindow(network) { Owner = this };
        if (dialog.ShowDialog() == true && dialog.DeviceId is { } id)
        {
            ViewModel.SelectAddedDevice(id);
        }
    }

    /// <summary>
    /// Asked by the network connection when a scanner presents a certificate that is new or
    /// has changed since it was trusted.
    /// </summary>
    private Task<bool> ConfirmCertificate(EsclCertificateException certificate)
    {
        var dialog = new CertificateTrustWindow(certificate, CertificateTrustWindow.ConnectAction);
        if (IsVisible) dialog.Owner = this;
        return Task.FromResult(dialog.ShowDialog() == true);
    }

    /// <summary>
    /// Automatic, then one item per connection to the scanner (the name that connection
    /// reports in its tooltip). The saved choice is checked; Automatic when there is none.
    /// </summary>
    internal ContextMenu BuildConnectionMenu(DeviceRow row)
    {
        var menu = new ContextMenu();
        var automatic = new MenuItem
        {
            Header = "Automatic",
            ToolTip = "Use the best available connection",
            IsCheckable = true,
            IsChecked = row.ChosenConnection is null,
        };
        automatic.Click += (_, _) => ChooseConnection(row, null);
        menu.Items.Add(automatic);
        menu.Items.Add(new Separator());
        foreach (var member in row.Group.Members)
        {
            string connection = DeviceMerge.ConnectionId(member);
            var item = new MenuItem
            {
                Header = DeviceMerge.ConnectionLabel(member),
                ToolTip = member.Name,
                IsCheckable = true,
                IsChecked = string.Equals(row.ChosenConnection, connection, StringComparison.OrdinalIgnoreCase),
            };
            item.Click += (_, _) => ChooseConnection(row, connection);
            menu.Items.Add(item);
        }
        return menu;
    }

    private void ChooseConnection(DeviceRow row, string? connection)
    {
        // Another scanner's connection opens it at once; the selected one's waits for the card.
        if (row.Id != ViewModel.SelectedDeviceId && ViewModel.HasIdCardCaptures && !ConfirmDropIdCard()) return;
        ViewModel.ChooseConnection(row.Group.Key, connection);
    }

    private void PresetList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (PresetList.SelectedItem is Preset preset)
        {
            if (!ConfirmDropIdCard()) return;
            ViewModel.ApplyPreset(preset);
            ViewModel.ClearAppendTarget();
            PushSettingsToUi();
            _savedTabStale = true;
        }
    }

    private void SavePreset_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new PromptWindow("Save preset", placeholder: "Preset name", okLabel: "Save") { Owner = this };
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
        // The Copy card needs a printer: one installed meanwhile makes it available.
        if (StartTab.IsSelected && IsLoaded) ViewModel.PrintersMayHaveChanged();
        if (SavedTab.IsSelected)
        {
            _savedTabStale = false;
            SavedView.Reload();
        }
    }

    // MARK: - Page strip

    private static Guid? PageIdOf(object sender) =>
        sender is FrameworkElement { Tag: Guid id } ? id : null;

    /// <summary>Copy Text in a page's menu: its text, read with OCR, on the clipboard.</summary>
    private async void PageCopyText_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        await ViewModel.CopyPageText(id);
        RefreshFromViewModel();
    }

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
        // Receipts are always cut out upright.
        var editor = new PhotoCropEditorWindow(source, item.Photo.Region, ViewModel.IsReceiptReview || ViewModel.Settings.PhotoAutoDeskew)
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
            RefreshFromViewModel();
            return;
        }
        ViewModel.SelectionRect = new RectD(
            (rect.X - imageRect.X) / imageRect.Width,
            (rect.Y - imageRect.Y) / imageRect.Height,
            rect.Width / imageRect.Width,
            rect.Height / imageRect.Height);
        RefreshFromViewModel();
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

/// <summary>Minimal modal text prompt (used for naming presets); OK stays off while the box is blank.</summary>
public sealed class PromptWindow : Window
{
    private readonly TextBox _textBox = new();

    public string Value => _textBox.Text;

    /// <param name="title">The window's title.</param>
    /// <param name="message">A line above the box; none when null.</param>
    /// <param name="placeholder">What the empty box says (and its accessible name).</param>
    /// <param name="okLabel">The default button's label.</param>
    public PromptWindow(string title, string? message = null, string? placeholder = null, string okLabel = "OK")
    {
        Title = title;
        Icon = AppIcon.Image;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        SetResourceReference(FontFamilyProperty, "TextFontFamily");

        var ok = new Button { Content = okLabel, IsDefault = true, IsEnabled = false, MinWidth = 88 };
        ok.SetResourceReference(StyleProperty, "AccentButtonStyle");
        ok.Click += (_, _) => DialogResult = true;
        _textBox.TextChanged += (_, _) => ok.IsEnabled = _textBox.Text.Trim().Length > 0;
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
        if (message is not null)
        {
            var text = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
            text.SetResourceReference(StyleProperty, "BodyText");
            panel.Children.Add(text);
        }
        var box = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        box.Children.Add(_textBox);
        if (placeholder is not null)
        {
            var hint = new TextBlock { Text = placeholder };
            hint.SetResourceReference(StyleProperty, "PlaceholderText");
            box.Children.Add(hint);
            Placeholders.Attach(_textBox, hint);
            System.Windows.Automation.AutomationProperties.SetName(_textBox, placeholder);
        }
        panel.Children.Add(box);
        panel.Children.Add(buttons);
        Content = panel;

        Loaded += (_, _) => _textBox.Focus();
    }
}
