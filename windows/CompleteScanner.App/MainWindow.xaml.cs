using System.ComponentModel;
using System.Globalization;
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
        StartView.GoToScanRequested += () => ShowScanScreen();
        // A first run opens on the start screen; later runs open where scanning happens, with
        // the task (and its banner) the user had last.
        MainTabs.SelectedItem = ViewModel.IsFirstRun ? StartTab : ScanTab;

        ColorModeBox.ItemsSource = Enum.GetValues<ColorMode>().Select(m => m.Label());
        FormatBox.ItemsSource = Enum.GetValues<OutputFormat>().Select(f => f.Label());
        BuildPdfSizeSegments();
        BuildBlankSensitivitySegments();
        AfterSaveBox.ItemsSource = AfterSaveItems();
        ReviewAfterSaveBox.ItemsSource = AfterSaveItems();
        foreach (var binding in Enum.GetValues<DuplexBinding>())
        {
            BackBindingBox.Items.Add(new ComboBoxItem { Content = binding.Label(), Tag = binding });
        }

        Loaded += (_, _) =>
        {
            PushSettingsToUi();
            ViewModel.Start();
            if (StartTab.IsSelected) StartView.FocusDefaultCard();
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
        var queued = ViewModel.ScannedPages.Select(item => item.Page).ToList();
        // Pages flagged blank (with Skip blank pages on) or skipped by hand are left out when saving.
        int saveCount = PageFilter.PagesToSave(queued, ViewModel.Settings.Document).Count;
        PageStrip.Visibility = pageCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        PageStripLabel.Text = PageFilter.QueueSummary(queued, ViewModel.Settings.Document);
        SavePdfButton.Content = saveCount > 0 ? $"Save PDF ({saveCount} page{(saveCount == 1 ? "" : "s")})" : "Save PDF";
        // A narrow inspector trims the label; the tooltip keeps the full text.
        SavePdfButton.ToolTip = pageCount > 0 && saveCount == 0 ? PageFilter.NothingToSaveMessage : SavePdfButton.Content;
        ToolTipService.SetShowOnDisabled(SavePdfButton, true);
        SavePdfButton.IsEnabled = saveCount > 0 && !ViewModel.IsBusy;
        LastPdfSizeText.Text = ViewModel.LastPdfSizeText;
        LastPdfSizeText.Visibility = ViewModel.LastPdfSizeText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearButton.IsEnabled = pageCount > 0 && !ViewModel.IsBusy;
        QueueButtons.Visibility = ViewModel.Settings.Intent == ScanIntent.Document || pageCount > 0
            ? Visibility.Visible : Visibility.Collapsed;
        PageList.IsEnabled = !ViewModel.IsBusy;

        // As on macOS, the preview is of the flatbed: not offered while the feeder is the source.
        PreviewButton.IsEnabled = !ViewModel.IsBusy && ViewModel.Capabilities?.SupportsOverview != false
                                  && ViewModel.Settings.Source != ScanSource.DocumentFeeder;
        ScanButton.IsEnabled = !ViewModel.IsBusy;
        ScanButton.Content = ViewModel.PrimaryActionLabel;
        SyncTaskBanner();
        StartView.Refresh();
        // As on macOS, the settings (and presets, which replace them) are frozen while an
        // operation runs: it works from a snapshot, and edits made meanwhile would not apply.
        Inspector.IsEnabled = !ViewModel.IsBusy;
        PresetList.IsEnabled = !ViewModel.IsBusy;
        PresetButtons.IsEnabled = !ViewModel.IsBusy;

        UpdateMarquee();
        SyncDeviceSelection();
        SyncDriverWindowOption();
        // A page's badge is part of its name, and the badges follow the blank-page settings.
        NamePageItems();

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
        SyncSavedBar();

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
        EmptyAddScannerLink.IsEnabled = ViewModel.NetworkScanners is not null;
    }

    /// <summary>
    /// Shows an error in the InfoBar above the window content. It stays until dismissed; a newer
    /// error replaces the text. Screen readers are told through a live-region event. The bar's
    /// Troubleshoot button is hidden; only a scanner error from the view model shows it again.
    /// </summary>
    private void ShowError(string message)
    {
        InfoBarMessage.Text = message;
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
        SavedBarMessage.Text = ViewModel.SavedBarText;
        SavedBarText.ToolTip = string.Join(Environment.NewLine, paths);
        var offered = ViewModel.SavedBarActions;
        foreach (var button in SavedBarButtons.Children.OfType<Button>())
        {
            if (button.Tag is not string tag) continue;
            var action = Enum.Parse<FileAction>(tag);
            button.Visibility = offered.Contains(action) ? Visibility.Visible : Visibility.Collapsed;
            button.ToolTip = FileActionMenu.Hint(action, paths.Count);
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

    /// <summary>Below this bar width the action buttons show only their glyphs.</summary>
    private const double SavedBarCompactBelowWidth = 760;

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
        box.ToolTip = action.Hint();
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
            return;
        }
        string title = task?.Title ?? TurningOverTitle;
        string name = task is null ? title : $"Task: {title}";
        bool sameTaskShown = TaskBanner.Visibility == Visibility.Visible && AutomationProperties.GetName(TaskBannerGroup) == name;
        TaskBanner.Visibility = Visibility.Visible;
        TaskBannerGlyph.Text = TaskIcons.Glyph(task?.IconKey ?? "twoSided");
        var flow = ViewModel.Flow;
        var step = flow?.Current;
        TaskBannerTitle.Text = flow is { StepCount: > 1 } && step is not null
            ? $"{title} · Step {flow.StepIndex + 1} of {flow.StepCount}: {step.Title}"
            : title;
        string prompt = step?.Prompt ?? task?.Subtitle ?? DuplexMode.Manual.Hint();
        bool promptChanged = TaskBannerPrompt.Text != prompt;
        TaskBannerPrompt.Text = prompt;
        AutomationProperties.SetName(TaskBannerGroup, name);
        // A new step of the same task (the backs after the fronts) is read out.
        if (sameTaskShown && promptChanged) AnnounceWhenShown(TaskBannerPrompt);

        // Without a task the close button stops turning stacks over by hand.
        string exitName = task is not null ? "Leave the task" : "Scan one side only";
        AutomationProperties.SetName(ExitTaskButton, exitName);
        ExitTaskButton.ToolTip = task is not null
            ? "Leave the task. Its settings stay, without the guidance."
            : "Stop turning stacks over by hand: scan one side of each sheet.";

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
    }

    /// <summary>
    /// Names the items of the page strip for screen readers: "Page 3, Sheet 2 · back". The badge
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
        ScanButton.Focus();
    }

    private void MoreFronts_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.ScanMoreFronts();
        RefreshFromViewModel();
        ScanButton.Focus();
    }

    private void CombineSides_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.CombineSidesAnyway();
        RefreshFromViewModel();
        ScanButton.Focus();
    }

    private void ScanBacksAgain_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.ScanBacksAgain();
        RefreshFromViewModel();
        ScanButton.Focus();
    }

    private void KeepFronts_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.KeepFrontsOnly();
        RefreshFromViewModel();
        ScanButton.Focus();
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
        if (!ViewModel.StartTask(task)) return;
        PushSettingsToUi();
        ShowScanScreen();
    }

    /// <summary>A preset card was picked: apply it and go to the scan screen.</summary>
    private void StartPreset(Preset preset)
    {
        if (ViewModel.IsBusy) return;
        ViewModel.ApplyPreset(preset);
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
        Dispatcher.BeginInvoke(() =>
        {
            if (ScanButton.IsEnabled) ScanButton.Focus();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
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
        if (ViewModel.ActiveTask is not null) ViewModel.ExitTask();
        else ViewModel.ScanOneSideOnly();
        PushSettingsToUi();
        RefreshFromViewModel();
        ScanButton.Focus();
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
            DriverWindowHint.Text = ViewModel.DriverWindowRequired
                ? "This scanner's driver always shows its own window; resolution, color and area are chosen there."
                : ViewModel.UseDriverWindow
                    ? "Scan opens the driver's window; resolution, color and area are chosen there."
                    : "Scan with the settings above, without the driver's window.";
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
        SidesHint.Text = !feeder ? DocumentSides.FeederOnlyReason
            : s.Duplex == DuplexMode.Manual && manualReason is not null ? manualReason
            : s.Duplex == DuplexMode.Off && bothReason is not null ? $"{s.Duplex.Hint()} {bothReason}"
            : s.Duplex.Hint();
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
        string signature = $"{s.Source}\u001f{area}";
        if (signature != _paperSignature)
        {
            _paperSignature = signature;
            PaperSizeBox.Items.Clear();
            foreach (var size in PaperSizes.DisplayOrder(RegionInfo.CurrentRegion.TwoLetterISORegionName))
            {
                bool fits = PaperSizes.Fits(size, area);
                string tip = fits ? PaperSizes.Hint(size, s.Source) : PaperSizes.DoesNotFitReason(s.Source);
                var item = new ComboBoxItem
                {
                    Content = size == PaperSize.Auto ? size.Label() : $"{size.Label()}  ({size.Detail()})",
                    Tag = size,
                    IsEnabled = fits,
                    ToolTip = tip,
                };
                ToolTipService.SetShowOnDisabled(item, true);
                AutomationProperties.SetHelpText(item, tip);
                PaperSizeBox.Items.Add(item);
            }
        }
        PaperSizeBox.SelectedItem = PaperSizeBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (PaperSize)i.Tag == s.PaperSize);
        PaperSizeHint.Text = PaperSizes.Hint(s.PaperSize, s.Source);
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
            SyncPdfSizeOptions();
            SyncBlankPageOptions();
            SyncGeometryOptions();
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
        SyncPdfSizeOptions();
        SyncBlankPageOptions();
        SyncGeometryOptions();
        ViewModel.SettingsEdited();
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
    /// seen and kept: with each scan saved at once the switch is off and says why.
    /// </summary>
    private void SyncBlankPageOptions()
    {
        var s = ViewModel.Settings;
        bool collecting = s.DocumentMultiPage;
        SkipBlankBox.IsEnabled = collecting;
        string hint = collecting
            ? s.Document.RemoveBlankPages
                ? "Blank pages are marked in the page strip and left out when you save. Click Keep on a page to save it."
                : "Blank pages are marked in the page strip. Click Skip on a page to leave it out."
            : "Only for pages collected before saving: a scan saved at once keeps every page.";
        SkipBlankHint.Text = hint;
        SkipBlankBox.ToolTip = hint;
        AutomationProperties.SetHelpText(SkipBlankBox, hint);
        BlankSensitivityOptions.Visibility = collecting ? Visibility.Visible : Visibility.Collapsed;
        BlankSensitivityHint.Text = s.Document.BlankSensitivity.Hint();
    }

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
    /// swap button: with each scan saved at once the switches are off and say why.
    /// </summary>
    private void SyncGeometryOptions()
    {
        var s = ViewModel.Settings;
        bool collecting = s.DocumentMultiPage;
        AutoCropBox.IsEnabled = collecting;
        AutoStraightenBox.IsEnabled = collecting;
        string hint = !collecting
            ? "Only for pages collected before saving: a scan saved at once is kept as scanned."
            : (s.Document.AutoCrop, s.Document.AutoStraighten) switch
            {
                (true, true) => "Pages are cut out of the scanner background and turned straight when that is clear. Click the arrow on a page to see it as scanned.",
                (true, false) => "Pages are cut out of the scanner background when that is clear. Click the arrow on a page to see it as scanned.",
                (false, true) => "Pages that lie at a slant are turned straight when that is clear. Click the arrow on a page to see it as scanned.",
                _ => "Cut each page out of the scanner background, and turn pages that lie at a slant.",
            };
        GeometryHint.Text = hint;
        foreach (var box in new[] { AutoCropBox, AutoStraightenBox })
        {
            box.ToolTip = hint;
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
            AutomationProperties.SetHelpText(segment, size.Hint());
            segment.Checked += Setting_Changed;
            PdfSizeSegments.Children.Add(segment);
        }
        PdfSizeSegments.Columns = PdfSizePresets.DisplayOrder.Count;
    }

    /// <summary>The size choice is shown for PDF output only, with the chosen size's hint under it.</summary>
    private void SyncPdfSizeOptions()
    {
        var s = ViewModel.Settings;
        PdfSizeOptions.Visibility = s.Intent == ScanIntent.Document && s.Format == OutputFormat.Pdf
            ? Visibility.Visible : Visibility.Collapsed;
        PdfSizeHint.Text = s.Output.PdfSize.Hint();
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
        if (DeviceList.SelectedItem is DeviceRow row && row.Id != ViewModel.SelectedDeviceId)
        {
            ViewModel.UserSelectDevice(row.Id);
        }
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
        automatic.Click += (_, _) => ViewModel.ChooseConnection(row.Group.Key, null);
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
            item.Click += (_, _) => ViewModel.ChooseConnection(row.Group.Key, connection);
            menu.Items.Add(item);
        }
        return menu;
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
