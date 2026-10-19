using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// A page in the queue strip, wrapped with its display thumbnail and what the strip says about
/// it under the current blank-page settings (<see cref="Options"/>).
/// </summary>
public sealed class PageItem : INotifyPropertyChanged
{
    /// <summary>Long side of a strip thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 240;

    public event PropertyChangedEventHandler? PropertyChanged;

    private DocumentOptions _options;
    private ScannedPage _page;

    /// <summary>Builds the thumbnail from the (already rotated) in-memory image; construct off the UI thread.</summary>
    public PageItem(ScannedPage page) : this(page, WpfImageCodec.ToThumbnail(page.Image, ThumbnailMaxSide)) { }

    /// <summary>
    /// The page with a thumbnail already made: the same pixels with other page facts (its side
    /// and sheet, kept or skipped).
    /// </summary>
    public PageItem(ScannedPage page, BitmapSource thumbnail, DocumentOptions? options = null)
    {
        _page = page;
        Thumbnail = thumbnail;
        _options = options?.Clone() ?? new DocumentOptions();
    }

    /// <summary>
    /// The page. Its facts (kept or skipped) change in place, so the strip keeps the item's
    /// container, and with it the keyboard focus on the item's Keep or Skip button.
    /// </summary>
    public ScannedPage Page
    {
        get => _page;
        set
        {
            if (ReferenceEquals(_page, value)) return;
            _page = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    public BitmapSource Thumbnail { get; }

    /// <summary>The blank-page settings the strip shows the page with; the view model keeps it current.</summary>
    public DocumentOptions Options
    {
        get => _options;
        set
        {
            if (_options.Equals(value)) return;
            _options = value.Clone();
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    /// <summary>"Sheet 2 · back" for a page of a two-sided stack; null for other pages.</summary>
    public string? SideLabel => DocumentSides.SideLabel(Page.Side, Page.SheetIndex);

    /// <summary>"Blank, skipped", "Skipped", "Looks blank", or null (<see cref="PageFilter.Badge"/>).</summary>
    public string? BlankBadge => PageFilter.Badge(Page, _options);

    /// <summary>Saving the queue leaves this page out.</summary>
    public bool IsExcluded => PageFilter.IsExcluded(Page, _options);

    /// <summary>What the page's one-click button does ("Keep this page", "Skip this page"); null when it has none.</summary>
    public string? ToggleLabel => PageFilter.ToggleLabel(Page, _options);

    /// <summary>The button's short text: "Keep" for a left-out page, "Skip" otherwise.</summary>
    public string? ToggleText => ToggleLabel is null ? null : IsExcluded ? "Keep" : "Skip";

    /// <summary>The page's name for screen readers: "Page 3, Sheet 2 · back, Blank, skipped", or "Page 3".</summary>
    /// <param name="number">The page's position in the queue, from 1.</param>
    public string AccessibleName(int number)
    {
        string name = SideLabel is { } label ? $"Page {number}, {label}" : $"Page {number}";
        return BlankBadge is { } badge ? $"{name}, {badge}" : name;
    }
}

/// <summary>A detected photo in the review grid, wrapped with its display thumbnail.</summary>
public sealed class PhotoItem : INotifyPropertyChanged
{
    /// <summary>Long side of a review thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 400;

    public event PropertyChangedEventHandler? PropertyChanged;

    public PhotoItem(DetectedPhoto photo, BitmapSource? thumbnail = null)
    {
        Photo = photo;
        Thumbnail = thumbnail ?? WpfImageCodec.ToThumbnail(photo.Image, ThumbnailMaxSide);
    }

    public DetectedPhoto Photo { get; }
    public BitmapSource Thumbnail { get; }

    public bool Included
    {
        get => Photo.Included;
        set
        {
            Photo.Included = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Included)));
        }
    }

    public void RotateClockwise()
    {
        Photo.RotationQuarterTurns = (Photo.RotationQuarterTurns + 1) % 4;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RotationDegrees)));
    }

    public double RotationDegrees => Photo.RotationQuarterTurns * 90;
}

/// <summary>
/// A scanner in the sidebar: one row per physical scanner, however many connections reach it
/// (WIA, TWAIN, network). <see cref="Info"/> is the entry the row stands for: the connection
/// in use while the scanner is selected, otherwise the one it would connect through.
/// </summary>
public sealed class DeviceRow(ScannerInfo info, DeviceGroup group, string? chosenConnection)
{
    public ScannerInfo Info { get; } = info;
    public DeviceGroup Group { get; } = group;
    /// <summary>The connection the user chose for this scanner (<see cref="DeviceMerge.ConnectionId"/>); null = Automatic.</summary>
    public string? ChosenConnection { get; } = chosenConnection;

    public string Id => Info.Id;
    public string Name => Info.Name;
    public string Transport => Info.Transport;
    public bool IsDemo => Info.IsDemo;
    /// <summary>More than one connection reaches the scanner, so the row offers a choice.</summary>
    public bool HasConnectionChoice => Group.Members.Count > 1;
    public string ConnectionLabel => DeviceMerge.ConnectionLabel(Info);
    /// <summary>The row's second line: how the scanner is reached.</summary>
    public string Caption =>
        IsDemo ? "Demo (no hardware)"
        : HasConnectionChoice ? $"via {ConnectionLabel}"
        // TWAIN lists installed drivers, so a scanner reached only that way is named for its driver.
        : Info.Backend == "twain" ? "TWAIN driver"
        : ConnectionLabel;
    public string ConnectionChooserName => $"Connection for {Name}: {ConnectionLabel}";

    /// <summary>Equal for rows that look and behave the same, so an unchanged list is not rebuilt.</summary>
    internal string Signature =>
        string.Join('\u001f', [Info.Id, Info.Name, Info.Transport, Group.Key, ChosenConnection ?? "",
                               .. Group.Members.Select(m => m.Id)]);
}

/// <summary>One card in the Scans tab: a history entry plus its display bitmap.</summary>
public sealed class HistoryItem(ScanHistoryEntry entry, BitmapSource thumbnail)
{
    /// <summary>
    /// Stand-in thumbnail for the metadata-only entries the app keeps: the preview pixels
    /// live once, in <see cref="Thumbnail"/>.
    /// </summary>
    public static readonly RgbaImage NoPixels = new(1, 1, new byte[4]);

    /// <summary>Metadata of the scan; its <see cref="ScanHistoryEntry.Thumbnail"/> is <see cref="NoPixels"/>.</summary>
    public ScanHistoryEntry Entry { get; } = entry;
    public BitmapSource Thumbnail { get; } = thumbnail;

    public string Summary => $"{Entry.Intent.Label()} · {Entry.Dpi} dpi";
    public string PixelSizeText => $"{(int)Entry.PixelSize.Width} × {(int)Entry.PixelSize.Height} px";
    public string TimeText => Entry.Date.ToString("T");
    public string DetailText =>
        $"{Summary} · {PixelSizeText} · {Entry.Date:d} {Entry.Date:T}";
}

/// <summary>
/// Central controller: owns backends, the open scanner session, settings, scan results, and
/// every user-triggered operation. All UI binds to this object. Port of
/// Sources/CompleteScannerKit/App/AppState.swift — the orchestration logic (device merging,
/// generation-guarded switching, scan flows, page spooling, atomic saves, cooperative
/// cancellation, scan history, live preview) carries over; only the change-notification
/// plumbing is WPF-flavored. Must be created and used on a Dispatcher thread.
/// </summary>
public sealed class AppViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Long side of the retained raw scan the live preview renders from.</summary>
    public const int CanvasPreviewMaxSide = 2600;

    /// <summary>Slider edits are coalesced: a render starts once they pause this long.</summary>
    private static readonly TimeSpan CanvasRenderDebounce = TimeSpan.FromMilliseconds(80);

    // MARK: Published state

    /// <summary>The sidebar's scanners: one row per physical scanner (see <see cref="DeviceMerge"/>).</summary>
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    /// <summary>Every backend entry grouped by physical scanner, in sidebar order.</summary>
    public IReadOnlyList<DeviceGroup> DeviceGroups { get; private set; } = [];

    public string? SelectedDeviceId { get; private set; }
    public ScannerCapabilities? Capabilities { get; private set; }
    public ScanSettings Settings { get; private set; }

    /// <summary>Low-res preview of the full bed; the selection marquee is only valid over this image.</summary>
    public RgbaImage? OverviewImage { get; private set; }
    /// <summary>
    /// Downsampled RAW copy (≤ <see cref="CanvasPreviewMaxSide"/>) of the most recent scan;
    /// the canvas renders it through the CURRENT adjustments, so slider edits show without
    /// rescanning. Pages already queued keep the settings they were scanned with.
    /// </summary>
    public RgbaImage? LastScanImage { get; private set; }
    /// <summary>Normalized (0...1) crop rect within the flatbed, origin top-left. null = full bed.</summary>
    public RectD? SelectionRect { get; set; }

    public ObservableCollection<PageItem> ScannedPages { get; } = [];
    /// <summary>The open photo batch; replaced wholesale per scan, items replaced on re-crop.</summary>
    public ObservableCollection<PhotoItem> DetectedPhotos { get; private set; } = [];
    public bool ShowPhotoReview { get; private set; }

    /// <summary>This session's scans, newest first (small previews only) — the Scans tab.</summary>
    public ObservableCollection<HistoryItem> History { get; } = [];

    public bool IsBusy { get; private set; }
    public ScanProgress? Progress { get; private set; }
    public string StatusMessage { get; private set; } = "Looking for scanners…";
    public string? ErrorMessage { get; set; }
    public List<string> LastSavedPaths { get; private set; } = [];
    /// <summary>Size of the PDF saved last in this session, in bytes; null before the first one.</summary>
    public long? LastPdfBytes { get; private set; }
    /// <summary>"Last PDF: 412 KB", shown under the PDF size choice; empty before the first PDF.</summary>
    public string LastPdfSizeText => LastPdfBytes is { } bytes ? $"Last PDF: {SavedFiles.SizeText(bytes)}" : "";
    /// <summary>Bumped whenever files are written to the destination folder (drives the Saved tab).</summary>
    public int SavedRevision { get; private set; }

    /// <summary>
    /// The files of the last save, offered with their actions (open, share, copy, …) in the bar
    /// above the window content; null once the bar is dismissed or the next scan starts.
    /// </summary>
    public IReadOnlyList<string>? SavedBarPaths { get; private set; }
    /// <summary>What the bar says was saved: "Scan 2026-10-19 3.pdf (412 KB)", or "3 files in Scans".</summary>
    public string SavedBarText { get; private set; } = "";

    public ObservableCollection<Preset> Presets { get; } = [];

    /// <summary>No settings were saved before this start: the app opens on the start screen.</summary>
    public bool IsFirstRun { get; }

    /// <summary>The task the settings are set up for (picked on the start screen); null for settings chosen by hand.</summary>
    public ScanTask? ActiveTask => Settings.Task;

    public TaskDefinition? ActiveTaskDefinition => ActiveTask is { } task ? TaskCatalog.Definition(task) : null;

    /// <summary>
    /// Where the user is in the guided steps: the active task's, or turning a stack over by
    /// hand (<see cref="DocumentSides.ManualSteps"/>); null when nothing is guided.
    /// </summary>
    public TaskFlow? Flow { get; private set; }
    /// <summary>What <see cref="Flow"/> was made for: a task, or (Manual) turning the stack over by hand.</summary>
    private (ScanTask? Task, bool Manual) _flowKey;

    /// <summary>Caption of the Scan button: the current step's action ("Scan page"), or "Scan".</summary>
    public string PrimaryActionLabel => Flow?.Current?.PrimaryActionLabel ?? "Scan";

    /// <summary>The steps guide turning a stack over by hand: fronts, then backs.</summary>
    public bool IsTurningOverByHand => Flow is not null && _flowKey.Manual;

    /// <summary>Turning over by hand, the backs are next (or were scanned and did not pair up).</summary>
    public bool AwaitingBacks => IsTurningOverByHand && Flow?.Current?.Id == DocumentSides.BacksStepId;

    /// <summary>
    /// Turning over by hand, fronts are in the queue but the stack was not turned over yet (the
    /// feeder stopped early, or more fronts were asked for): <see cref="FinishFronts"/> moves on
    /// to the backs.
    /// </summary>
    public bool CanFinishFronts =>
        IsTurningOverByHand && Flow?.Current?.Id == DocumentSides.FrontsStepId && QueuedCaptures(DocumentSides.FrontsStepId) > 0;

    /// <summary>
    /// The backs are due but none was scanned yet: <see cref="ScanMoreFronts"/> goes back to the
    /// fronts, for a stack larger than the feeder holds.
    /// </summary>
    public bool CanScanMoreFronts => AwaitingBacks && QueuedCaptures(DocumentSides.BacksStepId) == 0;

    /// <summary>
    /// The fronts and backs of a stack turned over by hand did not pair up, e.g. "3 fronts but 2
    /// backs"; null otherwise. The user scans the backs again, combines the pages as they are,
    /// or keeps the fronts only.
    /// </summary>
    public string? SidesMismatch { get; private set; }

    /// <summary>How the next scan captures the sheets (one side, both, or turned over by hand).</summary>
    public DuplexMode EffectiveDuplex => DocumentSides.Effective(Settings, Capabilities);

    /// <summary>The start screen's task cards, with what the connected scanner can do.</summary>
    public IReadOnlyList<TaskCardItem> TaskCards =>
        TaskCatalog.All.Select(definition => new TaskCardItem(
            definition,
            TaskCatalog.Availability(definition.Task, Capabilities),
            ActiveTask == definition.Task,
            TaskCatalog.Summary(SettingsAdapter.Adapt(TaskCatalog.Apply(definition.Task, new ScanSettings()),
                                                      Capabilities).Settings))).ToList();

    /// <summary>Image shown in the preview canvas (before live adjustments).</summary>
    public RgbaImage? CanvasImage => OverviewImage ?? LastScanImage;
    /// <summary><see cref="CanvasImage"/> rendered through the current adjustments.</summary>
    public BitmapSource? CanvasBitmap { get; private set; }
    /// <summary>True while a live-preview render is scheduled or running.</summary>
    public bool IsCanvasRenderPending => _renderTimer.IsEnabled || _renderInFlight;

    /// <summary>The destination folder with environment variables expanded.</summary>
    public string DestinationFolder => Environment.ExpandEnvironmentVariables(Settings.DestinationPath);

    public static readonly int[] FallbackResolutions = [75, 150, 200, 300, 600, 1200];

    // MARK: Private

    private readonly IReadOnlyList<IScannerBackend> _backends;
    private readonly PresetStore _presetStore;
    private readonly IOcrService _ocrService;
    /// <summary>Opens, shows, shares and copies saved files through Windows (a stand-in in tests).</summary>
    private readonly IFileActions _fileActions;
    private readonly Dispatcher _dispatcher;
    /// <summary>Where queued document pages are spilled to disk (this process's own folder).</summary>
    private readonly PageSpool _spool;
    private IScannerSession? _session;
    private bool _userPickedDevice;
    /// <summary>The user's connection choice per scanner (<see cref="AppPreferences.PreferredConnection"/>).</summary>
    private readonly Dictionary<string, string> _preferredConnection;
    /// <summary>Devices that scan through their driver's own window (<see cref="AppPreferences.TwainDriverWindow"/>).</summary>
    private readonly HashSet<string> _driverWindowDevices;
    /// <summary>The backend entry of the selected device, kept so its scanner is found again when that entry goes away.</summary>
    private ScannerInfo? _selectedEntry;
    /// <summary>
    /// Devices whose certificate changed and was not trusted this session (refused when the app
    /// opened them on its own, or declined by the user): never selected automatically again,
    /// so only the user choosing one asks about its certificate.
    /// </summary>
    private readonly HashSet<string> _certificateRefused = [];
    /// <summary>The device diagnostics last written (see <see cref="WriteDeviceDiagnostics"/>).</summary>
    private string _lastDeviceReport = "";
    /// <summary>Reads the WIA service and the network for the troubleshooter; opens Settings and copies (a stand-in in tests).</summary>
    private readonly ISystemDiagnostics _system;
    /// <summary>The WIA service and network as last read (<see cref="ReadSystemStateAsync"/>); Unknown until then.</summary>
    private (ServiceStatus Wia, NetworkStatus Network) _systemState;
    /// <summary>The last failed connection or scan, for the troubleshooter; cleared by the next one that works.</summary>
    private ScannerFailure? _lastFailure;
    /// <summary>
    /// A real scanner appeared, the selected one went away, or another connection to it became
    /// the preferred one, during an operation/review; re-evaluate the selection afterwards.
    /// </summary>
    private bool _autoSwitchDeferred;
    /// <summary>
    /// Device switches are serialized through this chain; concurrent clicks must never
    /// interleave open/close on hardware sessions.
    /// </summary>
    private Task _switchTask = Task.CompletedTask;
    private int _switchGeneration;
    private DispatcherTimer? _settingsSaveTimer;
    private int _counterFallback;
    /// <summary>The current exclusive operation's cancellation (null when idle).</summary>
    private CancellationTokenSource? _operationCts;
    private Task _currentOperation = Task.CompletedTask;
    /// <summary>Core-side history list (authoritative order/cap); <see cref="History"/> mirrors it.</summary>
    private readonly List<ScanHistoryEntry> _history = [];
    private readonly Dictionary<Guid, HistoryItem> _historyItems = [];
    /// <summary>
    /// Full-resolution sources of the current photo batch, keyed by scanned-page id and
    /// retained only while the photo review is open, so manual crop corrections can
    /// re-extract each photo from the correct sheet at full quality.
    /// </summary>
    private Dictionary<Guid, RgbaImage> _photoSourceImages = [];
    /// <summary>Page rotations run in order (rapid clicks accumulate instead of racing).</summary>
    private Task _pageRotateChain = Task.CompletedTask;
    /// <summary>In-flight re-crops; saving the batch waits for them first.</summary>
    private Task _recropChain = Task.CompletedTask;

    // Live preview.
    private readonly DispatcherTimer _renderTimer;
    private int _canvasRevision;
    private CanvasRenderKey? _renderedKey;
    private bool _renderInFlight;
    private bool _renderQueued;

    private readonly record struct CanvasRenderKey(int Revision, AdjustmentSettings Adjustments, ColorMode ColorMode);

    public AppViewModel(IReadOnlyList<IScannerBackend>? backends = null,
                        IOcrService? ocrService = null,
                        IFileActions? fileActions = null,
                        ISystemDiagnostics? systemDiagnostics = null)
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
        var saved = SettingsStore.Load();
        IsFirstRun = saved is null;
        // A task saved last time is still active: its banner comes back with the settings.
        Settings = saved ?? new ScanSettings();
        SyncTaskFlow();
        _backends = backends ?? [new Scanning.WiaScannerBackend(),
                                 new Scanning.EsclScannerBackend(),
                                 new Scanning.Twain.TwainScannerBackend(),
                                 // The demo's second sheet has a blank back, to show blank pages being flagged.
                                 new MockScannerBackend { FeederBlankBackSheets = [1] }];
        _presetStore = new PresetStore();
        var preferences = AppPreferencesStore.Load();
        // A null value can only come from a hand-edited file; it means no choice.
        _preferredConnection = preferences.PreferredConnection
            .Where(pair => pair.Value is not null)
            .ToDictionary(pair => pair.Key, pair => pair.Value);
        _driverWindowDevices = [.. preferences.TwainDriverWindow.Where(id => id is not null)];
        _ocrService = ocrService ?? new WindowsOcrService();
        _fileActions = fileActions ?? new WindowsFileActions(MainWindowHandle);
        _system = systemDiagnostics ?? new WindowsSystemDiagnostics();
        foreach (var preset in _presetStore.Load()) Presets.Add(preset);
        _renderTimer = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher) { Interval = CanvasRenderDebounce };
        _renderTimer.Tick += (_, _) =>
        {
            _renderTimer.Stop();
            StartCanvasRender();
        };
        // Clears the spill files of earlier runs, never those of another running instance.
        _spool = new PageSpool();
    }

    /// <summary>
    /// Completes when the current exclusive operation (scan, export, PDF build) has finished,
    /// including its cleanup; already completed when idle. Never faults.
    /// </summary>
    public Task CurrentOperation => _currentOperation;

    /// <summary>On app exit: flush settings and remove this process's page spill files.</summary>
    public void Shutdown()
    {
        FlushSettings();
        _spool.Dispose();
    }

    private void NotifyAll()
    {
        SyncPageOptions();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    /// <summary>The page strip shows every page under the current blank-page settings.</summary>
    private void SyncPageOptions()
    {
        foreach (var item in ScannedPages) item.Options = Settings.Document;
    }

    /// <summary>Call after mutating Settings from the UI: debounced persist + live preview refresh.</summary>
    public void SettingsEdited()
    {
        // A feeder that scans one side turns two-sided scanning into turning over by hand.
        if (Settings.Duplex == DuplexMode.Both && EffectiveDuplex == DuplexMode.Manual) Settings.Duplex = DuplexMode.Manual;
        SyncTaskFlow();
        // The page strip's badges follow the blank-page settings.
        SyncPageOptions();
        _settingsSaveTimer?.Stop();
        _settingsSaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        var snapshot = Settings.Clone();
        _settingsSaveTimer.Tick += (_, _) =>
        {
            _settingsSaveTimer?.Stop();
            SettingsStore.Save(snapshot);
        };
        _settingsSaveTimer.Start();
        RequestCanvasRender(debounce: true);
    }

    /// <summary>Flush the debounced settings write on app exit.</summary>
    public void FlushSettings()
    {
        _settingsSaveTimer?.Stop();
        SettingsStore.Save(Settings);
    }

    // MARK: Devices

    public void Start()
    {
        foreach (var backend in _backends)
        {
            backend.DevicesChanged += () => _dispatcher.BeginInvoke(MergeDevices);
            backend.StartBrowsing();
        }
        MergeDevices();
        // The troubleshooter's part of devices.txt needs the WIA service and the network.
        _ = ReadSystemStateAsync();
        // Remove partial files an export cut off by a crash left in the destination folder.
        string folder = DestinationFolder;
        _ = Task.Run(() => SavedFiles.SweepStaleTempFiles(folder, SavedFiles.StaleTempFileAge));
    }

    /// <summary>
    /// Rebuilds the scanner list from every backend: entries for the same physical scanner are
    /// grouped (<see cref="DeviceMerge.Group"/>) and the selection follows its scanner. When
    /// another connection to the selected scanner becomes the preferred one (a better one
    /// appeared, the user chose one, or the one in use went away), the session moves to it.
    /// </summary>
    private void MergeDevices()
    {
        var entries = _backends.SelectMany(b => b.Devices).ToList();
        DeviceGroups = DeviceMerge.Group(entries, DeviceMerge.WindowsRanking, _preferredConnection);
        WriteDeviceDiagnostics();

        if (SelectedDeviceId is { } sel)
        {
            if (entries.FirstOrDefault(d => d.Id == sel) is { } current) _selectedEntry = current;
            var group = GroupOfSelection(sel);
            // When the connection in use went away and only TWAIN still lists the scanner, it
            // was most likely unplugged or turned off (TWAIN lists installed drivers): treat
            // it as gone rather than opening its driver.
            if (group is not null && TwainOnly(group) && group.Members.All(m => m.Id != sel)) group = null;
            if (group is null)
            {
                // The device went away (unplugged, powered off). Switching would discard a
                // running operation or an open photo review, whose pixels no longer need the
                // scanner, so wait for those to end (EndOfWork re-runs this merge).
                if (IsBusy || ShowPhotoReview)
                {
                    _autoSwitchDeferred = true;
                }
                else
                {
                    _userPickedDevice = false;
                    SelectDevice(PreferredDefaultDevice());
                }
            }
            else if (group.Primary.Id != sel)
            {
                // Same scanner, another connection: the same deferral rules apply. The user's
                // pick of this scanner stands.
                if (IsBusy || ShowPhotoReview) _autoSwitchDeferred = true;
                else SelectDevice(group.Primary.Id);
            }
            else if (!_userPickedDevice && PreferredDefaultDevice() is { } real
                     && group.Primary.IsDemo
                     && DeviceGroups.First(g => g.Primary.Id == real).Primary is { IsDemo: false })
            {
                // A real scanner appeared while we were auto-parked on the demo device. Switching
                // would discard a running operation or an open photo review, so wait for those
                // to end (EndOfWork re-runs this merge).
                if (IsBusy || ShowPhotoReview) _autoSwitchDeferred = true;
                else SelectDevice(real);
            }
        }
        else if (PreferredDefaultDevice() is { } def)
        {
            SelectDevice(def);
        }
        RefreshDeviceRows();
        NotifyAll();
    }

    /// <summary>Re-evaluate a deferred automatic device switch once nothing is in progress.</summary>
    private void EndOfWork()
    {
        if (!_autoSwitchDeferred || IsBusy || ShowPhotoReview) return;
        _autoSwitchDeferred = false;
        MergeDevices();
    }

    /// <summary>
    /// The first real scanner (else the demo device), through its preferred connection. A
    /// scanner only TWAIN reaches is never chosen on its own: TWAIN lists installed drivers,
    /// not connected scanners, and opening the driver of one that is off or gone can show the
    /// driver's own error messages and fails anyway. It is opened only when the user picks it.
    /// Nor is a scanner whose changed certificate was not trusted (<see cref="_certificateRefused"/>).
    /// </summary>
    private string? PreferredDefaultDevice() =>
        (DeviceGroups.FirstOrDefault(g => !g.Primary.IsDemo && !TwainOnly(g) && !_certificateRefused.Contains(g.Primary.Id))
         ?? DeviceGroups.FirstOrDefault(g => g.Primary.IsDemo))?.Primary.Id;

    private static bool TwainOnly(DeviceGroup group) => group.Members.All(m => m.Backend == "twain");

    /// <summary>
    /// The scanner the selected device belongs to: the group listing it, or, when that entry
    /// went away, the group holding another connection to the same scanner.
    /// </summary>
    private DeviceGroup? GroupOfSelection(string id) =>
        DeviceGroups.FirstOrDefault(g => g.Members.Any(m => m.Id == id))
        ?? (_selectedEntry is { } entry && entry.Id == id
            ? DeviceGroups.FirstOrDefault(g => g.Members.Any(m => DeviceMerge.SameDevice(m, entry)))
            : null);

    /// <summary>
    /// One row per scanner; the selected scanner's row shows the connection in use (until a
    /// deferred switch moves it), the others the connection they would use.
    /// </summary>
    private void RefreshDeviceRows()
    {
        string? sel = SelectedDeviceId;
        var rows = DeviceGroups.Select(group =>
        {
            var shown = group.Members.FirstOrDefault(m => m.Id == sel) ?? group.Primary;
            string? chosen = _preferredConnection.TryGetValue(group.Key, out var connection)
                             && group.Members.Any(m => string.Equals(DeviceMerge.ConnectionId(m), connection,
                                                                     StringComparison.OrdinalIgnoreCase))
                ? connection : null;
            return new DeviceRow(shown, group, chosen);
        }).ToList();
        if (rows.Select(r => r.Signature).SequenceEqual(Devices.Select(r => r.Signature))) return;
        Devices.Clear();
        foreach (var row in rows) Devices.Add(row);
    }

    /// <summary>
    /// The user chose how to reach a scanner (<see cref="DeviceMerge.ConnectionId"/>, or null
    /// for Automatic). The choice is saved, and the scanner is selected through it. For the
    /// selected scanner, a running operation or open photo review is not discarded: the switch
    /// waits for it to end, like any other connection change (see <see cref="MergeDevices"/>).
    /// </summary>
    public void ChooseConnection(string groupKey, string? connectionId)
    {
        if (connectionId is null) _preferredConnection.Remove(groupKey);
        else _preferredConnection[groupKey] = connectionId;
        AppPreferencesStore.Update(preferences =>
        {
            if (connectionId is null) preferences.PreferredConnection.Remove(groupKey);
            else preferences.PreferredConnection[groupKey] = connectionId;
        });
        MergeDevices();
        if (DeviceGroups.FirstOrDefault(g => g.Key == groupKey) is not { } group) return;
        bool selectedScanner = SelectedDeviceId is { } sel && GroupOfSelection(sel)?.Key == groupKey;
        if (selectedScanner && (IsBusy || ShowPhotoReview))
        {
            // MergeDevices deferred the switch; EndOfWork makes it.
            _userPickedDevice = true;
            return;
        }
        UserSelectDevice(group.Primary.Id);
    }

    /// <summary>
    /// The network (eSCL) connection: adds scanners by address and asks before trusting a
    /// scanner's certificate. null when the app runs without it.
    /// </summary>
    public Scanning.EsclScannerBackend? NetworkScanners => _backends.OfType<Scanning.EsclScannerBackend>().FirstOrDefault();

    /// <summary>
    /// A scanner was just added by address (<paramref name="deviceId"/>): list it, and select
    /// it unless an operation or the photo review is in progress, which a switch would end.
    /// </summary>
    public void SelectAddedDevice(string deviceId)
    {
        MergeDevices();
        if (DeviceGroups.FirstOrDefault(g => g.Members.Any(m => m.Id == deviceId)) is not { } group) return;
        if (IsBusy || ShowPhotoReview) return;
        UserSelectDevice(group.Primary.Id);
    }

    /// <summary>The connected scanner can scan through its driver's own settings window (TWAIN).</summary>
    public bool HasDriverWindowOption => _session is Scanning.IDriverWindowOption;

    /// <summary>The connected scanner cannot scan without its driver's window, so it is always used.</summary>
    public bool DriverWindowRequired => _session is Scanning.IDriverWindowOption { DriverWindowOptional: false };

    /// <summary>Scans go through the driver's own settings window.</summary>
    public bool UseDriverWindow =>
        _session is Scanning.IDriverWindowOption option && (option.UseDriverWindow || !option.DriverWindowOptional);

    /// <summary>
    /// The user's choice for the connected scanner: scan through its driver's own window, or
    /// with the app's settings. Remembered per connection (<see cref="AppPreferences.TwainDriverWindow"/>).
    /// </summary>
    public void SetUseDriverWindow(bool use)
    {
        if (_session is not Scanning.IDriverWindowOption option) return;
        option.UseDriverWindow = use;
        string id = _session.Info.Id;
        bool changed = use ? _driverWindowDevices.Add(id) : _driverWindowDevices.Remove(id);
        if (changed)
        {
            AppPreferencesStore.Update(preferences =>
            {
                preferences.TwainDriverWindow.RemoveAll(entry => entry == id);
                if (use) preferences.TwainDriverWindow.Add(id);
            });
        }
        NotifyAll();
    }

    /// <summary>
    /// Writes the raw device names, how they were grouped, what each connection reports and the
    /// troubleshooter's checks to %LOCALAPPDATA%\CompleteScanner\Logs\devices.txt whenever they
    /// change, so the names real drivers report can be collected to tune <see cref="DeviceMerge"/>
    /// and a user's setup can be read from one file. Best effort.
    /// </summary>
    private void WriteDeviceDiagnostics()
    {
        string report = DiagnosticsText(TroubleshootSnapshot());
        if (report == _lastDeviceReport) return;
        _lastDeviceReport = report;
        try
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                         "CompleteScanner", "Logs");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "devices.txt"), report);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not write the device diagnostics: {e.Message}");
        }
    }

    // MARK: Troubleshooter ("Why isn't my scanner listed?")

    /// <summary>A scanner other than the demo scanner is listed; without one the sidebar offers the troubleshooter.</summary>
    public bool HasRealDevices => DeviceGroups.Any(group => !group.Primary.IsDemo);

    /// <summary>The last failed connection or scan (null after one that worked).</summary>
    public ScannerFailure? LastFailure => _lastFailure;

    /// <summary>
    /// <see cref="ErrorMessage"/> is about a scanner that would not connect or scan, so the
    /// error bar offers the troubleshooter. The window clears it when it shows the error.
    /// </summary>
    public bool ErrorSuggestsTroubleshooter { get; set; }

    /// <summary>
    /// What the troubleshooter looks at now: the scanners listed, the last failure, the WIA
    /// service and network as last read, and what each connection adds
    /// (<see cref="IScannerBackendDiagnostics"/>). Read <see cref="ReadSystemStateAsync"/> first
    /// for a fresh service and network state.
    /// </summary>
    public DiscoverySnapshot TroubleshootSnapshot()
    {
        var snapshot = new DiscoverySnapshot
        {
            Platform = TroubleshootPlatform.Windows,
            Devices = [.. DeviceGroups.Select(group => group.Primary)],
            Network = _systemState.Network,
            WiaService = _systemState.Wia,
            LastFailure = _lastFailure,
        };
        return _backends.OfType<IScannerBackendDiagnostics>().Aggregate(snapshot, (s, backend) => backend.AddStatus(s));
    }

    /// <summary>
    /// Reads the WIA service and the network off the UI thread (the network list can be slow to
    /// answer), then rewrites devices.txt when that changes it. Only reads; never changes either.
    /// </summary>
    public async Task ReadSystemStateAsync()
    {
        var system = _system;
        try
        {
            _systemState = await Task.Run(() => (system.WiaService(), system.Network()));
        }
        catch (Exception e)
        {
            // A stand-in that throws: keep what was read before.
            System.Diagnostics.Trace.TraceWarning($"Could not read the system's state: {e.Message}");
        }
        WriteDeviceDiagnostics();
    }

    /// <summary>
    /// The troubleshooter's Refresh: every connection that can looks for scanners again
    /// (<see cref="IScannerBackendDiagnostics.Rescan"/>); the list updates as they answer.
    /// </summary>
    public void RefreshScanners()
    {
        foreach (var backend in _backends.OfType<IScannerBackendDiagnostics>()) backend.Rescan();
        _ = ReadSystemStateAsync();
    }

    /// <summary>
    /// The text of devices.txt and of Copy diagnostics: how the device list was grouped, what
    /// each connection reports, then the troubleshooter's checks for <paramref name="snapshot"/>.
    /// </summary>
    public string DiagnosticsText(DiscoverySnapshot snapshot) =>
        DeviceMerge.DiagnosticsReport(DeviceGroups)
        + string.Concat(_backends.OfType<Scanning.IBackendDiagnostics>()
                                 .Select(b => b.DiagnosticsReport)
                                 .Where(text => !string.IsNullOrEmpty(text)))
        + "\n" + Troubleshooter.Report(snapshot, Troubleshooter.Diagnose(snapshot));

    /// <summary>Copies <see cref="DiagnosticsText"/> to the clipboard; a refusal is reported in <see cref="ErrorMessage"/>.</summary>
    public bool CopyDiagnostics(DiscoverySnapshot snapshot)
    {
        try
        {
            _system.CopyText(DiagnosticsText(snapshot));
            return true;
        }
        catch (Exception e)
        {
            ErrorMessage = $"Copy diagnostics did not work: {FileActionErrors.Describe(e)}";
            NotifyAll();
            return false;
        }
    }

    /// <summary>
    /// Opens the Windows Settings page an action names (Printers &amp; scanners, or Network &amp;
    /// internet); a refusal is reported in <see cref="ErrorMessage"/>. Nothing is changed there.
    /// </summary>
    public bool OpenSystemSettings(TroubleshootAction action)
    {
        try
        {
            _system.OpenSettings(action);
            return true;
        }
        catch (Exception e)
        {
            ErrorMessage = $"{Troubleshooter.Label(action, TroubleshootPlatform.Windows)} did not work: {FileActionErrors.Describe(e)}";
            NotifyAll();
            return false;
        }
    }

    /// <summary>Keeps a failed connection or scan for the troubleshooter (errors that say nothing about the scanner are skipped).</summary>
    private void RecordFailure(string deviceName, Exception error)
    {
        if (Troubleshooter.FailureFrom(deviceName, error) is not { } failure) return;
        _lastFailure = failure;
        // Set right after the error it explains, so the error bar offers the troubleshooter.
        ErrorSuggestsTroubleshooter = true;
        WriteDeviceDiagnostics();
    }

    private void ClearFailure()
    {
        if (_lastFailure is null) return;
        _lastFailure = null;
        WriteDeviceDiagnostics();
    }

    /// <summary>Device selection driven by the user (sidebar click).</summary>
    public void UserSelectDevice(string? id)
    {
        _userPickedDevice = true;
        SelectDevice(id, interactive: true);
    }

    /// <param name="interactive">
    /// The user chose the device just now, so opening it may ask them something (a network
    /// scanner's changed certificate). Automatic selections never ask.
    /// </param>
    private void SelectDevice(string? id, bool interactive = false)
    {
        // Ignore re-clicks on a device that is already connected or connecting.
        if (id == SelectedDeviceId && (_session != null || !_switchTask.IsCompleted)) return;
        SelectedDeviceId = id;
        _selectedEntry = id is null ? null
            : DeviceGroups.SelectMany(g => g.Members).FirstOrDefault(m => m.Id == id) ?? _selectedEntry;
        RefreshDeviceRows();
        _switchGeneration += 1;
        int generation = _switchGeneration;
        var previous = _switchTask;
        _switchTask = RunSwitch();
        NotifyAll();
        return;

        async Task RunSwitch()
        {
            await previous;
            if (_switchGeneration != generation) return;
            await SwitchSession(id, interactive);
        }
    }

    private async Task SwitchSession(string? id, bool interactive)
    {
        if (_session is { } old)
        {
            old.ProgressHandler = null;
            // Abort any in-flight scan so its results can't land after the switch.
            old.CancelScan();
            await old.CloseAsync();
        }
        _session = null;
        Capabilities = null;
        // The preview, marquee and detections belong to the previous device's bed.
        OverviewImage = null;
        LastScanImage = null;
        SelectionRect = null;
        DetectedPhotos = [];
        ShowPhotoReview = false;
        _photoSourceImages = [];
        CanvasImageChanged();

        if (id is null)
        {
            StatusMessage = "No scanner selected.";
            NotifyAll();
            return;
        }
        var backend = _backends.FirstOrDefault(b => b.Devices.Any(d => d.Id == id));
        if (backend is null)
        {
            StatusMessage = "Scanner is no longer available.";
            NotifyAll();
            return;
        }
        string name = DeviceGroups.SelectMany(g => g.Members).FirstOrDefault(d => d.Id == id)?.Name ?? "scanner";
        StatusMessage = $"Connecting to {name}…";
        NotifyAll();
        try
        {
            var session = backend is Scanning.EsclScannerBackend network
                ? await network.OpenSessionAsync(id, interactive)
                : await backend.OpenSessionAsync(id);
            _certificateRefused.Remove(id);
            if (SelectedDeviceId != id) { await session.CloseAsync(); return; }
            session.ProgressHandler = p => _dispatcher.BeginInvoke(() =>
            {
                // Progress is posted, so a report can arrive after its operation finished (a
                // backend that reports and completes synchronously always does). It would put
                // a stale "Scanning…" over the outcome in the status bar: drop it.
                if (!IsBusy) return;
                Progress = p;
                if (!string.IsNullOrEmpty(p.Message)) StatusMessage = p.Message;
                NotifyAll();
            });
            _session = session;
            // Before reading the capabilities: when that fails (the scanner is off), the session
            // stays and a later scan reads them itself, still with the user's choice.
            if (session is Scanning.IDriverWindowOption option)
            {
                option.UseDriverWindow = _driverWindowDevices.Contains(session.Info.Id);
            }
            var caps = await session.GetCapabilitiesAsync();
            Capabilities = caps;
            ClearFailure();
            var adapted = SettingsAdapter.Adapt(Settings, caps);
            Settings = adapted.Settings;
            // A task the scanner cannot do (the feeder task on a flatbed) ends here.
            SyncTaskFlow();
            StatusMessage = WithNotes($"Ready — {session.Info.Name}", adapted.Notes);
        }
        catch (EsclCertificateException e) when (e.CanTrust)
        {
            // The certificate changed and was not trusted. Not chosen on its own again this
            // session; when the app had chosen it, it moves on to another scanner, and choosing
            // this one in the list shows the certificate.
            _certificateRefused.Add(id);
            StatusMessage = $"Could not connect to {name}.";
            RecordFailure(name, e);
            if (interactive)
            {
                ErrorMessage = e.Message;
            }
            else
            {
                ErrorMessage = e.Message + " To review the new certificate, choose the scanner in the list.";
                if (!_userPickedDevice)
                {
                    _ = _dispatcher.BeginInvoke(() =>
                    {
                        if (!_userPickedDevice && SelectedDeviceId == id && !IsBusy && !ShowPhotoReview)
                        {
                            SelectDevice(PreferredDefaultDevice());
                        }
                    });
                }
            }
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            StatusMessage = $"Could not connect to {name}.";
            RecordFailure(name, e);
        }
        NotifyAll();
    }

    // MARK: Scanning

    public Task PerformOverview()
    {
        if (_session is not { } session) { NoDevice(); return Task.CompletedTask; }
        // The preview shows the flatbed; a feeder scan would ignore a selection drawn on it.
        if (Settings.Source == ScanSource.DocumentFeeder)
        {
            StatusMessage = "Preview needs the flatbed. Choose Flatbed as the source to preview.";
            NotifyAll();
            return Task.CompletedTask;
        }
        int generation = _switchGeneration;
        // The backend reads the settings on its own thread: hand it a snapshot, never the
        // live object the inspector edits.
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            StatusMessage = "Scanning overview…";
            NotifyAll();
            var image = await session.PerformOverviewScanAsync(s);
            // Discard results that arrive after the user switched devices.
            if (_switchGeneration != generation) return;
            ClearFailure();
            token.ThrowIfCancellationRequested();
            OverviewImage = image;
            StatusMessage = "Overview ready — drag on the preview to select an area, then Scan.";
            CanvasImageChanged();
        });
    }

    public Task PerformScan()
    {
        if (_session is not { } session) { NoDevice(); return Task.CompletedTask; }
        int generation = _switchGeneration;
        // One snapshot for the whole operation: the backend reads it on its own thread (and
        // again to tag each page), and processing, history and saving must all agree with
        // what was actually scanned.
        var s = Settings.Clone();
        // The backend is asked for a two-sided scan only when its feeder can do one; turning
        // the stack over by hand scans one side at a time, and the steps say which.
        var sides = DocumentSides.Effective(s, Capabilities);
        s.Duplex = sides;
        PageSide? manualSide = sides == DuplexMode.Manual && IsTurningOverByHand && Flow?.Current is { } step
            ? step.Id == DocumentSides.BacksStepId ? PageSide.Back : PageSide.Front
            : null;
        // The flatbed scans the selection, else the paper size's part of the glass.
        var selection = s.Source == ScanSource.Flatbed
            ? SelectionRect ?? (Capabilities is { } caps ? PaperSizes.FlatbedSelection(s.PaperSize, caps.FlatbedSizeInches) : null)
            : null;
        return RunExclusive(async token =>
        {
            StatusMessage = "Scanning…";
            // The bar of the previous save makes way for the new scan.
            SavedBarPaths = null;
            NotifyAll();
            var scanned = await session.PerformScanAsync(s, selection);
            // Discard results that arrive after the user switched devices.
            if (_switchGeneration != generation) return;
            if (scanned.Count == 0) throw ScanException.ScanFailed("The scanner returned no pages.");
            ClearFailure();
            // A feeder batch cut short (a jam, a dropped connection) still returns its pages;
            // once they are handled the user is told the stack was not finished.
            var stop = session.LastScanStop;
            // A scanner that fell back to one side (its feeder or driver could not scan both, or
            // its capabilities were never read) delivered one side of each sheet.
            bool twoSided = sides == DuplexMode.Both && session.LastScanDuplex != false;
            token.ThrowIfCancellationRequested();
            StatusMessage = "Processing…";
            NotifyAll();
            // The clean-up stage: two-sided pages in reading order with their sides marked and the
            // backs turned upright, then the blank-page check and the adjustments. Pixel-heavy
            // work runs off the UI thread so the window stays live; the token is checked between
            // pages and steps.
            var arrangement = twoSided ? ScanArrangement.TwoSided
                : manualSide == PageSide.Back ? ScanArrangement.TurnedOverBacks
                : manualSide == PageSide.Front ? ScanArrangement.TurnedOverFronts
                : ScanArrangement.AsScanned;
            var processor = PageProcessor.ForScan(s, arrangement);
            var cleaned = await Task.Run(() => processor.Process(scanned, token), token);
            if (_switchGeneration != generation) return;
            token.ThrowIfCancellationRequested();
            var raw = cleaned.Arranged;
            var processed = cleaned.Pages.ToList();
            // " 2 look blank and will be skipped." after the pages added to the queue.
            string blankNote = PageFilter.ScanNote(processed, s.Document);

            // The canvas shows the RAW scan through the live adjustments (only a downsampled
            // copy is retained), and every scanned page is recorded in the session history.
            var (rawPreview, historyItems) = await Task.Run(() =>
            {
                var preview = ScanHistory.MakePreview(raw[^1].Image, CanvasPreviewMaxSide);
                var entries = ScanHistory.MakeEntries(raw, s.Intent, DateTime.Now);
                // The cards only display the bitmap: keep metadata-only entries so each
                // preview's pixels are held once, not twice.
                var items = entries
                    .Select(e => new HistoryItem(
                        new ScanHistoryEntry(e.Date, e.Intent, e.Dpi, HistoryItem.NoPixels, e.PixelSize, e.Id),
                        WpfImageCodec.ToBitmapSource(e.Thumbnail)))
                    .ToList();
                return (preview, items);
            }, token);
            if (_switchGeneration != generation) return;
            token.ThrowIfCancellationRequested();
            RecordHistory(historyItems);

            switch (TaskCatalog.FlowOf(s))
            {
                case TaskFlowKind.DocumentQueue:
                    if (s.DocumentMultiPage)
                    {
                        // Spill full-resolution pages to disk; keep only previews in the queue.
                        string spoolDirectory = _spool.Directory;
                        var spooled = await Task.Run(() =>
                            SpoolPages(processed, spoolDirectory).Select(p => new PageItem(p)).ToList());
                        if (_switchGeneration != generation || token.IsCancellationRequested)
                        {
                            DeleteSpoolFiles(spooled.Select(p => p.Page));
                            if (_switchGeneration != generation) return;
                            token.ThrowIfCancellationRequested();
                        }
                        foreach (var item in spooled) ScannedPages.Add(item);
                        RecordCaptures(spooled.Select(item => item.Page.Id));
                        SetLastScan(rawPreview);
                        int n = processed.Count;
                        if (manualSide is { } scannedSide)
                        {
                            AfterTurnedOverScan(scannedSide, n, stopped: stop is not null);
                        }
                        else if (twoSided)
                        {
                            int sheets = processed.Select(p => p.SheetIndex).Distinct().Count();
                            StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")} from {sheets} sheet{(sheets == 1 ? "" : "s")}, both sides — {ScannedPages.Count} in queue. Scan more or Save PDF.";
                        }
                        else if (sides == DuplexMode.Both)
                        {
                            StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")}, one side of each sheet: the scanner did not scan both sides — {ScannedPages.Count} in queue. Scan more or Save PDF.";
                        }
                        else
                        {
                            StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")} — {ScannedPages.Count} in queue. Scan more or Save PDF.";
                        }
                        StatusMessage += blankNote;
                    }
                    else
                    {
                        SetLastScan(rawPreview);
                        await SaveImmediately(processed, s, token);
                        RecordCaptures(processed.Select(page => page.Id));
                    }
                    break;
                case TaskFlowKind.PhotoSplit:
                    SetLastScan(rawPreview);
                    StatusMessage = "Detecting photos…";
                    NotifyAll();
                    var found = await Task.Run(() =>
                    {
                        var all = new List<PhotoItem>();
                        foreach (var page in processed)
                        {
                            token.ThrowIfCancellationRequested();
                            all.AddRange(SplitPhotos(page, s, token).Select(p => new PhotoItem(p)));
                        }
                        return all;
                    }, token);
                    if (_switchGeneration != generation) return;
                    token.ThrowIfCancellationRequested();
                    // Keep every sheet's full-resolution source while the review is open so
                    // manual crop corrections can re-extract from the correct page.
                    _photoSourceImages = processed.ToDictionary(p => p.Id, p => p.Image);
                    DetectedPhotos = new ObservableCollection<PhotoItem>(found);
                    RecordCaptures(found.Select(item => item.Photo.Id));
                    ShowPhotoReview = found.Count > 0;
                    if (!ShowPhotoReview) _photoSourceImages = [];
                    StatusMessage = $"Found {found.Count} photo{(found.Count == 1 ? "" : "s")} on the bed.";
                    break;
            }
            if (stop is not null) ErrorMessage = stop.Message(raw.Count);
            if (Capabilities is null) await ReadCapabilitiesAfterScan(session, generation);
            NotifyAll();
        });
    }

    /// <summary>
    /// The capabilities could not be read on connect (the scanner was off, say) yet a scan just
    /// worked: read them now, so the inspector shows what the scanner can do and the next scan
    /// knows whether its feeder scans both sides. Still unknown when that fails too.
    /// </summary>
    private async Task ReadCapabilitiesAfterScan(IScannerSession session, int generation)
    {
        ScannerCapabilities caps;
        try
        {
            caps = await session.GetCapabilitiesAsync();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return;
        }
        if (_switchGeneration != generation || !ReferenceEquals(_session, session) || Capabilities is not null) return;
        Capabilities = caps;
        var adapted = SettingsAdapter.Adapt(Settings, caps);
        Settings = adapted.Settings;
        SyncTaskFlow();
        StatusMessage = WithNotes(StatusMessage, adapted.Notes);
    }

    private static List<DetectedPhoto> SplitPhotos(ScannedPage page, ScanSettings s, CancellationToken token)
    {
        if (!s.PhotoAutoSplit) return [WholePagePhoto(page)];
        var options = new PhotoDetectorOptions
        {
            MinPhotoSideInches = s.PhotoMinSideInches,
            EdgeInsetPixels = s.PhotoCropInsetPixels,
        };
        var regions = PhotoDetector.DetectRegions(page.Image, page.Dpi, options);
        if (regions.Count == 0) return [WholePagePhoto(page)];
        var photos = new List<DetectedPhoto>();
        foreach (var region in regions)
        {
            token.ThrowIfCancellationRequested();
            if (PhotoDetector.ExtractPhoto(page.Image, region, s.PhotoAutoDeskew) is { } image)
            {
                photos.Add(new DetectedPhoto(region, image, page.Dpi, sourcePageId: page.Id));
            }
        }
        return photos;
    }

    private static DetectedPhoto WholePagePhoto(ScannedPage page)
    {
        double w = page.Image.Width, h = page.Image.Height;
        var region = new DetectedPhotoRegion(new PointD(w / 2, h / 2), new SizeD(w, h), 0);
        return new DetectedPhoto(region, page.Image, page.Dpi, sourcePageId: page.Id);
    }

    /// <summary>
    /// Cancel whatever is running: the hardware if it is mid-scan, AND the software phases
    /// (processing, photo detection, OCR, PDF build, exports) — either may be the one running.
    /// </summary>
    public void CancelScan()
    {
        _session?.CancelScan();
        _operationCts?.Cancel();
    }

    // MARK: Saving

    public Task SavePdf()
    {
        if (ScannedPages.Count == 0) return Task.CompletedTask;
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            // Let page rotations that were clicked before the save land first.
            await Settled(_pageRotateChain);
            var queued = ScannedPages.Select(p => p.Page).ToList();
            if (queued.Count == 0) return;
            // Pages flagged in the strip (blank, or skipped by hand) are left out now, and only now.
            var pages = PageFilter.PagesToSave(queued, s.Document);
            if (pages.Count == 0)
            {
                ErrorMessage = PageFilter.NothingToSaveMessage;
                StatusMessage = PageFilter.QueueSummary(queued, s.Document) + ".";
                return;
            }
            StatusMessage = s.PdfSearchable ? "Running OCR and building PDF…" : "Building PDF…";
            NotifyAll();
            string path = await WritePdfAtomically(pages, s, OutputPath(s, "pdf"), token);
            MarkSaved([path]);
            DeleteSpoolFiles(queued);
            ScannedPages.Clear();
            ResetFlow();
            int skipped = queued.Count - pages.Count;
            string left = skipped == 0 ? "" : $" — {skipped} skipped page{(skipped == 1 ? " was" : "s were")} left out";
            StatusMessage = $"Saved {pages.Count}-page PDF: {Path.GetFileName(path)}{PdfSizeSuffix()}{left}";
            RunAfterSave(s.Output.AfterSave, [path]);
        });
    }

    /// <summary>
    /// Used when DocumentMultiPage is off: write each scan to disk as soon as it lands. The
    /// pages are held nowhere else, so the files are the only full-resolution copy: a failure
    /// or Cancel part-way keeps every file already written and reports the partial result.
    /// </summary>
    private async Task SaveImmediately(List<ScannedPage> pages, ScanSettings s, CancellationToken token)
    {
        var saved = new List<string>();
        if (s.Format == OutputFormat.Pdf)
        {
            saved = [await WritePdfAtomically(pages, s, OutputPath(s, "pdf"), token)];
        }
        else
        {
            try
            {
                foreach (var page in pages)
                {
                    token.ThrowIfCancellationRequested();
                    string path = OutputPath(s, s.Format.FileExtension());
                    saved.Add(await Task.Run(() =>
                        WpfImageCodec.SaveAsNew(page.Image, path, s.Format, page.Dpi, s.JpegQuality)));
                }
            }
            catch (Exception e) when (saved.Count > 0)
            {
                MarkSaved(saved);
                string kept = $"{saved.Count} of {pages.Count} pages ({string.Join(", ", saved.Select(Path.GetFileName))})";
                if (IsCancellation(e))
                {
                    StatusMessage = $"Cancelled — saved {kept}.";
                    return;
                }
                throw new IOException($"Saved {kept}; the rest could not be written: {e.Message}", e);
            }
        }
        MarkSaved(saved);
        StatusMessage = $"Saved {string.Join(", ", saved.Select(Path.GetFileName))}" +
                        (s.Format == OutputFormat.Pdf ? PdfSizeSuffix() : "");
        RunAfterSave(s.Output.AfterSave, saved);
    }

    public Task SaveReviewedPhotos()
    {
        if (!DetectedPhotos.Any(p => p.Photo.Included)) { CancelPhotoReview(); return Task.CompletedTask; }
        var s = Settings.Clone();
        var format = s.Format == OutputFormat.Pdf ? OutputFormat.Jpeg : s.Format;
        return RunExclusive(async token =>
        {
            // A crop correction applied just before saving must be in the files.
            await Settled(_recropChain);
            var photos = DetectedPhotos.Where(p => p.Photo.Included).Select(p => p.Photo).ToList();
            if (photos.Count == 0) return;
            var saved = new List<string>();
            await WriteImagesRollingBack(saved, async () =>
            {
                for (int index = 0; index < photos.Count; index++)
                {
                    token.ThrowIfCancellationRequested();
                    var photo = photos[index];
                    string path = OutputPath(s, format.FileExtension(), index + 1);
                    StatusMessage = $"Saving photo {index + 1} of {photos.Count}…";
                    NotifyAll();
                    saved.Add(await Task.Run(() =>
                    {
                        var image = photo.RotationQuarterTurns == 0
                            ? photo.Image
                            : ImagePipeline.Rotate(photo.Image, photo.RotationQuarterTurns);
                        return WpfImageCodec.SaveAsNew(image, path, format, photo.Dpi, s.JpegQuality);
                    }));
                }
            });
            MarkSaved(saved);
            DetectedPhotos = [];
            ShowPhotoReview = false;
            _photoSourceImages = [];
            ResetFlow();
            StatusMessage = $"Saved {saved.Count} photo{(saved.Count == 1 ? "" : "s")} to {s.DestinationPath}";
            RunAfterSave(s.Output.AfterSave, saved);
        });
    }

    /// <summary>
    /// Run a multi-file export of the photo review as all-or-nothing: if it is cancelled or
    /// fails part-way, the files it already wrote are removed again, so the batch leaves
    /// nothing behind and can simply be retried from the review (which stays open) without
    /// duplicates. Once every file is written the export counts as done, even if Cancel
    /// arrives at that moment.
    /// </summary>
    private static async Task WriteImagesRollingBack(List<string> written, Func<Task> export)
    {
        try
        {
            await export();
        }
        catch
        {
            foreach (string path in written)
            {
                try { File.Delete(path); } catch { /* best effort */ }
            }
            written.Clear();
            throw;
        }
    }

    public void CancelPhotoReview()
    {
        DetectedPhotos = [];
        ShowPhotoReview = false;
        _photoSourceImages = [];
        ResetFlow();
        StatusMessage = "Photo batch discarded.";
        NotifyAll();
        EndOfWork();
    }

    // MARK: Photo crop correction

    /// <summary>The full-resolution page a detected photo was extracted from (null once the review is closed).</summary>
    public RgbaImage? PhotoSource(DetectedPhoto photo) =>
        photo.SourcePageId is { } id && _photoSourceImages.TryGetValue(id, out var image) ? image : null;

    /// <summary>
    /// Manual crop correction from the review: re-extract one photo from its full-resolution
    /// source page with a user-adjusted region (image pixel coordinates, top-left origin).
    /// The extraction runs off the UI thread; the photo keeps its id, inclusion and rotation.
    /// Returns false when nothing changed (busy, review closed, or extraction failed).
    /// </summary>
    public Task<bool> RecropPhoto(Guid id, DetectedPhotoRegion region)
    {
        if (IsBusy) return Task.FromResult(false);
        var item = DetectedPhotos.FirstOrDefault(p => p.Photo.Id == id);
        if (item is null || PhotoSource(item.Photo) is not { } source) return Task.FromResult(false);
        // Defensive cap (the editor already keeps crops on the page): a region far larger
        // than the page would only allocate a huge, mostly blank image.
        double diagonal = Math.Sqrt((double)source.Width * source.Width + (double)source.Height * source.Height);
        if (!(region.Size.Width >= 1 && region.Size.Height >= 1
              && region.Size.Width <= diagonal && region.Size.Height <= diagonal))
        {
            return Task.FromResult(false);
        }
        var batch = DetectedPhotos;
        bool deskew = Settings.PhotoAutoDeskew;
        var edited = new DetectedPhotoRegion(region.Center, region.Size, region.AngleDegrees, region.Id);
        // Re-crops apply strictly in the order they were requested.
        var previous = _recropChain;
        var task = Run();
        _recropChain = Settled(task);
        NotifyAll();
        return task;

        async Task<bool> Run()
        {
            await Settled(previous);
            StatusMessage = "Updating crop…";
            NotifyAll();
            (RgbaImage, BitmapSource)? result;
            try
            {
                result = await Task.Run(() =>
                {
                    var image = PhotoDetector.ExtractPhoto(source, edited, deskew);
                    return image is null
                        ? ((RgbaImage, BitmapSource)?)null
                        : (image, WpfImageCodec.ToThumbnail(image, PhotoItem.ThumbnailMaxSide));
                });
            }
            catch (Exception e)
            {
                ErrorMessage = $"The crop could not be applied: {e.Message}";
                StatusMessage = "Ready.";
                NotifyAll();
                return false;
            }
            // The batch may have been saved, discarded or replaced meanwhile.
            if (!ReferenceEquals(batch, DetectedPhotos)) return false;
            int index = IndexOfPhoto(id);
            if (index < 0) return false;
            if (result is not { } r)
            {
                StatusMessage = "That crop could not be extracted.";
                NotifyAll();
                return false;
            }
            // Rebuild from the CURRENT item so Keep/rotate changes made meanwhile survive.
            var current = DetectedPhotos[index];
            DetectedPhotos[index] = new PhotoItem(current.Photo.Recropped(edited, r.Item1), r.Item2);
            StatusMessage = "Crop updated.";
            NotifyAll();
            return true;
        }
    }

    /// <summary>True while a crop correction is still being extracted.</summary>
    public bool IsRecropPending => !_recropChain.IsCompleted;

    /// <summary>A task that completes when <paramref name="task"/> does, but never faults.</summary>
    private static async Task Settled(Task task)
    {
        try { await task; } catch { /* reported by the operation itself */ }
    }

    private int IndexOfPhoto(Guid id)
    {
        for (int i = 0; i < DetectedPhotos.Count; i++)
        {
            if (DetectedPhotos[i].Photo.Id == id) return i;
        }
        return -1;
    }

    // MARK: Page queue

    public void RemovePage(Guid id)
    {
        // Never mutate the queue (or unlink spool files) while a save is reading from it.
        if (IsBusy) return;
        var item = ScannedPages.FirstOrDefault(p => p.Page.Id == id);
        if (item is null) return;
        DeleteSpoolFiles([item.Page]);
        ScannedPages.Remove(item);
        NotifyAll();
    }

    public void MovePage(Guid id, int offset)
    {
        if (IsBusy) return;
        int idx = -1;
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            if (ScannedPages[i].Page.Id == id) { idx = i; break; }
        }
        if (idx < 0) return;
        int newIdx = idx + offset;
        if (newIdx < 0 || newIdx >= ScannedPages.Count) return;
        ScannedPages.Move(idx, newIdx);
        NotifyAll();
    }

    /// <summary>
    /// Rotate a queued page 90° clockwise. The in-memory preview (and its strip thumbnail)
    /// turns right away; the full-resolution spool file stays untouched and the accumulated
    /// rotation is applied when the PDF is written. Rotations are chained so rapid clicks
    /// accumulate in order.
    /// </summary>
    public Task RotatePage(Guid id)
    {
        if (IsBusy) return Task.CompletedTask;
        var previous = _pageRotateChain;
        var task = Run();
        _pageRotateChain = Settled(task);
        return task;

        async Task Run()
        {
            await Settled(previous);
            var item = ScannedPages.FirstOrDefault(p => p.Page.Id == id);
            if (item is null) return;
            PageItem rotated;
            try
            {
                rotated = await Task.Run(() => new PageItem(item.Page.RotatedClockwise()));
            }
            catch (Exception e)
            {
                ErrorMessage = $"The page could not be rotated: {e.Message}";
                NotifyAll();
                return;
            }
            // The page may have been removed (or the queue saved) meanwhile. It may also have been
            // kept or skipped, or put in order with its stack: the turned pixels take the page's
            // facts as they are now.
            int index = IndexOfPage(id);
            if (index < 0) return;
            var current = ScannedPages[index].Page;
            ScannedPages[index] = new PageItem(rotated.Page.CopyMeta(current), rotated.Thumbnail, Settings.Document);
            NotifyAll();
        }
    }

    private int IndexOfPage(Guid id)
    {
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            if (ScannedPages[i].Page.Id == id) return i;
        }
        return -1;
    }

    /// <summary>
    /// One click on a queued page's Keep or Skip button: the page is saved or left out, whatever
    /// the blank-page setting says; a second click goes back to what the setting says.
    /// </summary>
    public void TogglePageInclusion(Guid id)
    {
        if (IsBusy) return;
        int index = IndexOfPage(id);
        if (index < 0) return;
        var item = ScannedPages[index];
        var page = item.Page.WithInclusion(PageFilter.Toggled(item.Page, Settings.Document));
        // Updated in place, not replaced: a replaced item gets a new container in the strip,
        // and the Keep or Skip button the user pressed (and its keyboard focus) goes with the old one.
        item.Options = Settings.Document;
        item.Page = page;
        string summary = PageFilter.QueueSummary([.. ScannedPages.Select(p => p.Page)], Settings.Document);
        StatusMessage = PageFilter.IsExcluded(page, Settings.Document)
            ? $"Page {index + 1} will be left out when you save. {summary}."
            : $"Page {index + 1} will be saved. {summary}.";
        NotifyAll();
    }

    public void ClearPages()
    {
        if (IsBusy) return;
        DeleteSpoolFiles(ScannedPages.Select(p => p.Page));
        ScannedPages.Clear();
        ResetFlow();
        StatusMessage = "Page queue cleared.";
        NotifyAll();
    }

    // MARK: Presets

    /// <summary>
    /// Replaces the settings with the preset's, fitted to the connected scanner. A preset saved
    /// while a task was active brings that task (and its banner) back.
    /// </summary>
    public void ApplyPreset(Preset preset)
    {
        var adapted = SettingsAdapter.Adapt(preset.Settings, Capabilities);
        Settings = adapted.Settings;
        SettingsEdited();
        StatusMessage = WithNotes($"Applied preset “{preset.Name}”.", adapted.Notes);
        NotifyAll();
    }

    // MARK: Tasks

    /// <summary>
    /// Sets everything up for a task picked on the start screen: its settings are laid over the
    /// current ones (the destination folder is kept) and fitted to the connected scanner, and
    /// its guided steps start. Refused (false) while an operation runs, or when the connected
    /// scanner cannot do the task (the reason is shown).
    /// </summary>
    public bool StartTask(ScanTask task)
    {
        if (IsBusy) return false;
        var availability = TaskCatalog.Availability(task, Capabilities);
        if (!availability.IsAvailable)
        {
            ErrorMessage = availability.Reason;
            NotifyAll();
            return false;
        }
        var adapted = SettingsAdapter.Adapt(TaskCatalog.Apply(task, Settings), Capabilities);
        Settings = adapted.Settings;
        Flow = null;
        SettingsEdited();
        StatusMessage = WithNotes($"Ready for “{TaskCatalog.Definition(task).Title}”.", adapted.Notes);
        NotifyAll();
        return true;
    }

    /// <summary>
    /// Leaves the active task: the settings stay as they are, without the task's banner, so
    /// the scan screen is back to plain settings.
    /// </summary>
    public void ExitTask()
    {
        if (Settings.TaskId is null) return;
        Settings.TaskId = null;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>
    /// Stops turning stacks over by hand (the close button of its banner without a task):
    /// feeder scans are one-sided again. Pages already in the queue stay.
    /// </summary>
    public void ScanOneSideOnly()
    {
        if (IsBusy || Settings.Duplex == DuplexMode.Off) return;
        Settings.Duplex = DuplexMode.Off;
        SettingsEdited();
        StatusMessage = "Scanning one side of each sheet.";
        NotifyAll();
    }

    /// <summary>
    /// Keeps the guided steps in line with the settings: a task the settings no longer fit
    /// (the mode was changed by hand, or the scanner lacks the task's source) ends; turning
    /// stacks over by hand gets its own steps (<see cref="TaskCatalog.GuidedSteps"/>), whatever
    /// the task; an active task gets its steps. A task id this version does not know stays
    /// stored, without steps. Steps already under way are kept while they still apply.
    /// </summary>
    private void SyncTaskFlow()
    {
        if (Settings.Task is { } task && !TaskCatalog.Fits(task, Settings)) Settings.TaskId = null;
        bool manual = DocumentSides.UsesManualSteps(Settings, Capabilities);
        (ScanTask?, bool) key = manual ? (null, true) : (Settings.Task, false);
        if (TaskCatalog.GuidedSteps(Settings, Capabilities) is not { } steps)
        {
            Flow = null;
            _flowKey = default;
            SidesMismatch = null;
        }
        else if (Flow is null || _flowKey != key)
        {
            Flow = new TaskFlow(steps);
            _flowKey = key;
            SidesMismatch = null;
        }
    }

    /// <summary>Back to the first step with nothing captured; a stack's count mismatch goes with it.</summary>
    private void ResetFlow()
    {
        Flow?.Reset();
        SidesMismatch = null;
    }

    // MARK: Turning a stack over by hand

    /// <summary>
    /// After a scan of a stack turned over by hand: the fronts move the steps on to the backs,
    /// unless the feeder stopped early (<paramref name="stopped"/>, a jam): then the steps stay
    /// at the fronts so the rest of them can be scanned (<see cref="FinishFronts"/> moves on).
    /// The backs put the stack in reading order when they pair up with the fronts, otherwise
    /// the mismatch is shown (<see cref="SidesMismatch"/>).
    /// </summary>
    private void AfterTurnedOverScan(PageSide side, int count, bool stopped)
    {
        if (Flow is null) return;
        if (side == PageSide.Front)
        {
            if (stopped)
            {
                StatusMessage = $"Scanned {count} front side{(count == 1 ? "" : "s")} before the feeder stopped. {MoreFrontsPrompt}";
                return;
            }
            Flow.Advance();
            StatusMessage = $"Scanned {count} front side{(count == 1 ? "" : "s")}. Turn the stack over and scan the back sides.";
            return;
        }
        CollateTurnedOverStack(combineAnyway: false);
    }

    /// <summary>What to do while the fronts are scanned a part at a time.</summary>
    private const string MoreFrontsPrompt =
        "Load the sheets not scanned yet and scan more fronts; once every front is scanned, choose Done with fronts.";

    /// <summary>Every front is scanned: on to the backs (after a batch cut short, or more fronts).</summary>
    public void FinishFronts()
    {
        if (IsBusy || !CanFinishFronts || Flow is null) return;
        int fronts = QueuedCaptures(DocumentSides.FrontsStepId);
        Flow.Advance();
        StatusMessage = $"{fronts} front side{(fronts == 1 ? "" : "s")} scanned. Turn the stack over and scan the back sides.";
        NotifyAll();
    }

    /// <summary>
    /// Back to the fronts before any back was scanned, keeping the fronts scanned so far: for a
    /// stack larger than the feeder holds, scanned a part at a time.
    /// </summary>
    public void ScanMoreFronts()
    {
        if (IsBusy || !CanScanMoreFronts || Flow is null) return;
        // Retake makes the fronts the current step; the fronts already scanned are kept, in order.
        foreach (var id in Flow.Retake(DocumentSides.FrontsStepId)) Flow.Record(DocumentSides.FrontsStepId, id);
        SidesMismatch = null;
        StatusMessage = MoreFrontsPrompt;
        NotifyAll();
    }

    /// <summary>How many captures of a step are still in the queue.</summary>
    private int QueuedCaptures(string stepId)
    {
        if (Flow is null) return 0;
        var queued = ScannedPages.Select(item => item.Page.Id).ToHashSet();
        return Flow.Captures(stepId).Count(queued.Contains);
    }

    /// <summary>
    /// Puts the fronts and backs of the stack in reading order in the queue, unless their counts
    /// differ and <paramref name="combineAnyway"/> is false: then the mismatch is shown and the
    /// steps stay at the backs.
    /// </summary>
    private void CollateTurnedOverStack(bool combineAnyway)
    {
        if (Flow is null) return;
        var collation = DocumentSides.CollateQueue([.. ScannedPages.Select(item => item.Page.Id)],
                                                   Flow.Captures(DocumentSides.FrontsStepId),
                                                   Flow.Captures(DocumentSides.BacksStepId));
        var counts = collation.Interleave;
        if (counts.Mismatch && !combineAnyway)
        {
            SidesMismatch = counts.MismatchMessage;
            StatusMessage = $"{SidesMismatch}. Scan the rest of the back sides, scan them again, or combine the pages as they are.";
            return;
        }
        var items = ScannedPages.ToDictionary(item => item.Page.Id);
        var ordered = collation.Order.Select(id => collation.Positions.TryGetValue(id, out var position)
            ? new PageItem(items[id].Page.WithSide(position.Side, position.SheetIndex), items[id].Thumbnail)
            : items[id]).ToList();
        ScannedPages.Clear();
        foreach (var item in ordered) ScannedPages.Add(item);
        ResetFlow();
        int sheets = Math.Max(counts.Fronts, counts.Backs);
        int pages = counts.Fronts + counts.Backs;
        StatusMessage = $"Put {sheets} sheet{(sheets == 1 ? "" : "s")} in order ({pages} page{(pages == 1 ? "" : "s")}) — {ScannedPages.Count} in queue. Scan another stack or Save PDF.";
    }

    /// <summary>The backs did not pair up with the fronts, but the pages are combined as they are (the extra pages at the end).</summary>
    public void CombineSidesAnyway()
    {
        if (IsBusy || !AwaitingBacks) return;
        CollateTurnedOverStack(combineAnyway: true);
        NotifyAll();
    }

    /// <summary>The back sides scanned so far leave the queue, to be scanned again.</summary>
    public void ScanBacksAgain()
    {
        if (IsBusy || !AwaitingBacks || Flow is null) return;
        RemoveQueuedPages(Flow.Retake(DocumentSides.BacksStepId));
        SidesMismatch = null;
        StatusMessage = "Load the turned-over stack in the feeder again and scan the back sides.";
        NotifyAll();
    }

    /// <summary>
    /// The stack stays one-sided: the backs scanned so far leave the queue, the fronts stay
    /// (in scan order), and the next scan starts a new stack.
    /// </summary>
    public void KeepFrontsOnly()
    {
        if (IsBusy || !AwaitingBacks || Flow is null) return;
        RemoveQueuedPages(Flow.Captures(DocumentSides.BacksStepId));
        int fronts = Flow.Captures(DocumentSides.FrontsStepId).Count(id => ScannedPages.Any(item => item.Page.Id == id));
        ResetFlow();
        StatusMessage = $"Kept {fronts} front side{(fronts == 1 ? "" : "s")} — {ScannedPages.Count} in queue. Scan another stack or Save PDF.";
        NotifyAll();
    }

    private void RemoveQueuedPages(IReadOnlyCollection<Guid> ids)
    {
        if (ids.Count == 0) return;
        var set = ids.ToHashSet();
        var removed = ScannedPages.Where(item => set.Contains(item.Page.Id)).ToList();
        DeleteSpoolFiles(removed.Select(item => item.Page));
        foreach (var item in removed) ScannedPages.Remove(item);
    }

    /// <summary>Notes the current step of the active task what a scan produced (page or photo ids).</summary>
    private void RecordCaptures(IEnumerable<Guid> ids)
    {
        if (Flow?.Current is not { } step) return;
        foreach (var id in ids) Flow.Record(step.Id, id);
    }

    private static string WithNotes(string message, IReadOnlyList<SettingsNote> notes) =>
        notes.Count == 0 ? message : $"{message} {string.Join(" ", notes.Select(n => n.Message))}";

    public void SaveCurrentAsPreset(string name)
    {
        string trimmed = name.Trim();
        if (trimmed.Length == 0) return;
        Presets.Add(new Preset(trimmed, Settings.Clone()));
        _presetStore.Save([.. Presets]);
        NotifyAll();
    }

    public void DeletePreset(Guid id)
    {
        if (Presets.FirstOrDefault(p => p.Id == id) is { } preset) Presets.Remove(preset);
        _presetStore.Save([.. Presets]);
        NotifyAll();
    }

    // MARK: Live preview

    private void SetLastScan(RgbaImage preview)
    {
        LastScanImage = preview;
        CanvasImageChanged();
    }

    /// <summary>The overview or last scan was replaced: re-render right away.</summary>
    private void CanvasImageChanged()
    {
        _canvasRevision++;
        RequestCanvasRender(debounce: false);
    }

    private CanvasRenderKey CurrentRenderKey() =>
        new(_canvasRevision, Settings.Adjustments.Clone(), Settings.ColorMode);

    /// <summary>
    /// Schedule a render of <see cref="CanvasImage"/> through the current adjustments. Slider
    /// edits are debounced; only one render runs at a time and a result that a newer edit
    /// has superseded is dropped.
    /// </summary>
    private void RequestCanvasRender(bool debounce)
    {
        if (CanvasImage is null)
        {
            _renderTimer.Stop();
            _renderedKey = null;
            if (CanvasBitmap is not null)
            {
                CanvasBitmap = null;
                NotifyAll();
            }
            return;
        }
        if (_renderedKey == CurrentRenderKey() && !_renderInFlight)
        {
            _renderTimer.Stop();
            return;
        }
        _renderTimer.Stop();
        if (debounce) _renderTimer.Start();
        else StartCanvasRender();
    }

    private async void StartCanvasRender()
    {
        if (_renderInFlight)
        {
            _renderQueued = true;
            return;
        }
        if (CanvasImage is not { } baseImage) return;
        var key = CurrentRenderKey();
        if (key == _renderedKey) return;
        _renderInFlight = true;
        BitmapSource? rendered = null;
        try
        {
            rendered = await Task.Run(() =>
            {
                var down = ScanHistory.MakePreview(baseImage, CanvasPreviewMaxSide);
                var adjusted = ImagePipeline.Apply(key.Adjustments, down, key.ColorMode);
                return WpfImageCodec.ToBitmapSource(adjusted);
            });
        }
        catch
        {
            // A failed preview render just leaves the previous one up.
        }
        finally
        {
            _renderInFlight = false;
        }
        bool current = key == CurrentRenderKey() && ReferenceEquals(baseImage, CanvasImage);
        if (current && rendered is not null)
        {
            CanvasBitmap = rendered;
            _renderedKey = key;
            NotifyAll();
        }
        if (_renderQueued || !current)
        {
            _renderQueued = false;
            if (CanvasImage is null) RequestCanvasRender(debounce: false);
            else if (CurrentRenderKey() != _renderedKey && !_renderTimer.IsEnabled) StartCanvasRender();
        }
    }

    // MARK: Helpers

    private void RecordHistory(List<HistoryItem> items)
    {
        foreach (var item in items) _historyItems[item.Entry.Id] = item;
        ScanHistory.Record(_history, items.Select(i => i.Entry).ToList());
        var keep = _history.Select(e => e.Id).ToHashSet();
        foreach (var stale in _historyItems.Keys.Where(k => !keep.Contains(k)).ToList())
        {
            _historyItems.Remove(stale);
        }
        History.Clear();
        foreach (var entry in _history) History.Add(_historyItems[entry.Id]);
    }

    private void MarkSaved(List<string> paths)
    {
        LastSavedPaths = paths;
        SavedRevision++;
        SavedBarPaths = paths.Count > 0 ? [.. paths] : null;
        SavedBarText = SavedSummary(paths);
    }

    /// <summary>"Scan 3.pdf (412 KB)" for one file (the size for PDFs), "3 files in Scans" for several.</summary>
    private string SavedSummary(IReadOnlyList<string> paths)
    {
        if (paths.Count == 1)
        {
            bool pdf = Path.GetExtension(paths[0]).Equals(".pdf", StringComparison.OrdinalIgnoreCase);
            return Path.GetFileName(paths[0]) + (pdf ? PdfSizeSuffix() : "");
        }
        string folder = paths.Count > 0 ? Path.GetFileName(Path.GetDirectoryName(paths[0]) ?? "") : "";
        return folder.Length > 0 ? $"{paths.Count} files in {folder}" : $"{paths.Count} files";
    }

    // MARK: Saved files: open, share, copy

    /// <summary>The main window's handle, for the share window and the Open with dialog; zero without one.</summary>
    private static IntPtr MainWindowHandle() =>
        Application.Current?.MainWindow is { } window ? new WindowInteropHelper(window).Handle : IntPtr.Zero;

    /// <summary>Hides the bar of the last save.</summary>
    public void DismissSavedBar()
    {
        if (SavedBarPaths is null) return;
        SavedBarPaths = null;
        NotifyAll();
    }

    /// <summary>The actions the bar offers for the last save's files.</summary>
    public IReadOnlyList<FileAction> SavedBarActions => SaveActions.Offered(SavedBarPaths?.Count ?? 0);

    /// <summary>
    /// Opens, shows, shares, emails or copies saved files (the Saved tab and the bar after a
    /// save). Nothing leaves the PC here: sharing and email open the share window, where the
    /// user picks where the files go. A file that is gone, or an action Windows refuses, is
    /// reported in the InfoBar. Open and Open with use the first file. Returns whether the
    /// action was carried out.
    /// </summary>
    public bool RunFileAction(FileAction action, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return false;
        var missing = paths.Where(path => !File.Exists(path)).ToList();
        if (missing.Count > 0)
        {
            ErrorMessage = missing.Count == 1
                ? $"{Path.GetFileName(missing[0])} is no longer in its folder. It may have been moved, renamed or deleted."
                : $"{missing.Count} of the files are no longer in their folder. They may have been moved, renamed or deleted.";
            NotifyAll();
            return false;
        }
        try
        {
            switch (action)
            {
                case FileAction.Open:
                    _fileActions.Open(paths[0]);
                    break;
                case FileAction.OpenWith:
                    _fileActions.OpenWith(paths[0]);
                    break;
                case FileAction.Reveal:
                    _fileActions.Reveal(paths);
                    break;
                case FileAction.Share:
                    Send(SaveActions.ShareRoute(_fileActions.SendProbe), paths);
                    break;
                case FileAction.Email:
                    Send(SaveActions.EmailRoute(_fileActions.SendProbe), paths);
                    break;
                case FileAction.Copy:
                    var content = SaveActions.ClipboardContentFor(paths);
                    _fileActions.Copy(content);
                    StatusMessage = paths.Count == 1
                        ? $"Copied {Path.GetFileName(paths[0])}{(content.ImageFile is null ? "" : " and its picture")} to the clipboard."
                        : $"Copied {paths.Count} files to the clipboard.";
                    break;
            }
        }
        catch (Exception e)
        {
            ErrorMessage = $"{action.Label().TrimEnd('…')} did not work: {FileActionErrors.Describe(e)}";
            NotifyAll();
            return false;
        }
        NotifyAll();
        return true;
    }

    private void Send(SendRoute route, IReadOnlyList<string> paths)
    {
        switch (route)
        {
            case SendRoute.Compose:
                _fileActions.ComposeEmail(paths);
                break;
            case SendRoute.ShareSheet:
                _fileActions.Share(paths, SaveActions.ShareTitle(paths));
                break;
            case SendRoute.ShowInFolder:
                _fileActions.Reveal(paths);
                StatusMessage = SaveActions.ShowInFolderMessage;
                break;
        }
    }

    /// <summary>
    /// The after-save action of the settings the files were saved with, once a save has
    /// finished (never after a cancelled or partial one). A refusal is reported; the save stands.
    /// </summary>
    private void RunAfterSave(AfterSaveAction action, IReadOnlyList<string> saved)
    {
        if (SaveActions.Plan(action, saved) is { } step) RunFileAction(step.FileAction, step.Paths);
    }

    private void NoDevice()
    {
        ErrorMessage = "No scanner is connected. Select a device in the sidebar (or use the Demo Scanner).";
        NotifyAll();
    }

    /// <summary>
    /// Write each full-resolution page to a spool PNG and return queue entries that carry
    /// only a preview in memory. A page whose spill fails is kept fully in memory instead.
    /// </summary>
    private static List<ScannedPage> SpoolPages(List<ScannedPage> pages, string spoolDirectory)
    {
        Directory.CreateDirectory(spoolDirectory);
        return pages.Select(page =>
        {
            string path = Path.Combine(spoolDirectory, $"{page.Id}.png");
            try
            {
                WpfImageCodec.Save(page.Image, path, OutputFormat.Png, page.Dpi, 1.0);
            }
            catch
            {
                return page;
            }
            var preview = ScanHistory.MakePreview(page.Image, 1600);
            return page.WithImage(preview, filePath: path, fullPixelSize: new SizeD(page.Image.Width, page.Image.Height));
        }).ToList();
    }

    /// <summary>
    /// OCR (when searchable) + JPEG-encode each page as the PDF size plans it, then write the PDF through
    /// PdfBuilder.WriteNewFile, which builds it under a hidden temp name and moves it into
    /// place — a failed, interrupted or cancelled build never leaves a truncated PDF at the
    /// destination, and an existing file is never replaced. The token is checked before
    /// every page and passed to the writer. Returns the path written.
    /// </summary>
    private async Task<string> WritePdfAtomically(List<ScannedPage> pages, ScanSettings s, string path,
                                                  CancellationToken token)
    {
        var inputs = new List<PdfPageInput>();
        for (int i = 0; i < pages.Count; i++)
        {
            token.ThrowIfCancellationRequested();
            var page = pages[i];
            // Spilled pages hold only a preview in memory — reload the full-resolution
            // pixels one page at a time; PreparePage applies the page's rotation.
            var prepared = await Task.Run(() => PdfBuilder.PreparePage(page, SpoolImage(page)), token);
            var image = prepared.Image;
            IReadOnlyList<OcrLine>? lines = null;
            if (s.PdfSearchable)
            {
                StatusMessage = $"OCR page {i + 1} of {pages.Count}…";
                NotifyAll();
                // If OCR fails for a page, the PDF is still produced without a text layer.
                // Cancel stops waiting at once (the recognizer has no cancellation of its own;
                // its late result is simply ignored).
                try { lines = await _ocrService.RecognizeLinesAsync(image).WaitAsync(token); }
                catch (OperationCanceledException) { throw; }
                catch { lines = null; }
            }
            // The PDF size decides how the page is stored (PdfImageEncoding): OCR above has
            // read the full pixels; the stored image may be downsampled and gray. The page
            // keeps its physical size either way.
            byte[] jpeg = await Task.Run(() =>
            {
                int imageDpi = PdfImageEncoding.EffectiveDpi(image.Width, prepared.PixelWidth, page.Dpi);
                var plan = PdfImageEncoding.Plan(page.ColorMode, imageDpi, s.Output.PdfSize, image);
                var stored = PdfImageEncoding.Downsample(image, imageDpi, plan);
                return WpfImageCodec.EncodeJpeg(stored, plan.TargetDpi, plan.Quality, plan.IsGray);
            }, token);
            inputs.Add(new PdfPageInput(jpeg, prepared.PixelWidth, prepared.PixelHeight, page.Dpi, lines));
        }

        StatusMessage = "Writing PDF…";
        NotifyAll();
        string written = await Task.Run(() => PdfBuilder.WriteNewFile(inputs, path, progress: null, token), token);
        try { LastPdfBytes = new FileInfo(written).Length; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { LastPdfBytes = null; }
        return written;
    }

    /// <summary>" (412 KB)" after the name of the PDF just saved, or nothing when its size is unknown.</summary>
    private string PdfSizeSuffix() => LastPdfBytes is { } bytes ? $" ({SavedFiles.SizeText(bytes)})" : "";

    /// <summary>
    /// The full-resolution UNROTATED pixels from the page's spill file, or null when the page
    /// was never spooled (or the file is unreadable) — PdfBuilder.PreparePage then falls back
    /// to the in-memory image, which already carries any user rotation.
    /// </summary>
    private static RgbaImage? SpoolImage(ScannedPage page)
    {
        if (page.FilePath is null) return null;
        try
        {
            return WpfImageCodec.Load(page.FilePath);
        }
        catch
        {
            return null;
        }
    }

    private static void DeleteSpoolFiles(IEnumerable<ScannedPage> pages)
    {
        foreach (var page in pages)
        {
            if (page.FilePath is { } path)
            {
                try { File.Delete(path); } catch { /* best effort */ }
            }
        }
    }

    private int NextCounter()
    {
        // The macOS app keeps the counter in UserDefaults; here a tiny file next to the
        // presets serves the same purpose.
        string counterPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "CompleteScanner", "counter.txt");
        try
        {
            int value = File.Exists(counterPath) ? int.Parse(File.ReadAllText(counterPath).Trim()) : 0;
            value += 1;
            Directory.CreateDirectory(Path.GetDirectoryName(counterPath)!);
            File.WriteAllText(counterPath, value.ToString());
            return value;
        }
        catch
        {
            return ++_counterFallback;
        }
    }

    /// <summary>
    /// A free file name in the snapshot's destination folder. It is only a proposal: the
    /// writers move into place without replacing and pick the next free name if another
    /// file took this one meanwhile.
    /// </summary>
    private string OutputPath(ScanSettings s, string fileExtension, int? index = null)
    {
        string dir = Environment.ExpandEnvironmentVariables(s.DestinationPath);
        Directory.CreateDirectory(dir);
        string baseName = new NamingTemplate(s.NamingTemplate)
            .BaseFilename(new NamingContext(NextCounter(), DateTime.Now, s.Intent)
            {
                Index = index,
                Task = TaskCatalog.Infer(s),
            });
        return NamingTemplate.UniquePath(dir, baseName, fileExtension);
    }

    private static bool IsCancellation(Exception e) =>
        e is OperationCanceledException || e is ScanException { Kind: ScanErrorKind.Cancelled };

    /// <summary>
    /// Run one long operation at a time; surface errors; manage busy state. The operation
    /// receives a token that Cancel trips; it must check it between heavy work units. The
    /// returned task never faults.
    /// </summary>
    private Task RunExclusive(Func<CancellationToken, Task> operation)
    {
        if (IsBusy) return Task.CompletedTask;
        _currentOperation = RunExclusiveCore(operation);
        return _currentOperation;
    }

    private async Task RunExclusiveCore(Func<CancellationToken, Task> operation)
    {
        IsBusy = true;
        using var cts = new CancellationTokenSource();
        _operationCts = cts;
        NotifyAll();
        try
        {
            await operation(cts.Token);
        }
        catch (Exception e) when (IsCancellation(e))
        {
            StatusMessage = "Cancelled.";
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            StatusMessage = "Ready.";
            // A scan the scanner refused (busy, offline, ...) is what the troubleshooter explains.
            if (e is ScanException && _session is { } session) RecordFailure(session.Info.Name, e);
        }
        _operationCts = null;
        Progress = null;
        IsBusy = false;
        NotifyAll();
        EndOfWork();
    }
}
