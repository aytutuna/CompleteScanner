using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>A page in the queue strip, wrapped with its display thumbnail.</summary>
public sealed class PageItem(ScannedPage page)
{
    /// <summary>Long side of a strip thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 240;

    public ScannedPage Page { get; } = page;
    /// <summary>Built from the (already rotated) in-memory image; construct off the UI thread.</summary>
    public BitmapSource Thumbnail { get; } = WpfImageCodec.ToThumbnail(page.Image, ThumbnailMaxSide);
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

    public ObservableCollection<ScannerInfo> Devices { get; } = [];

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
    /// <summary>Bumped whenever files are written to the destination folder (drives the Saved tab).</summary>
    public int SavedRevision { get; private set; }

    public ObservableCollection<Preset> Presets { get; } = [];

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
    private readonly Dispatcher _dispatcher;
    /// <summary>Where queued document pages are spilled to disk (this process's own folder).</summary>
    private readonly PageSpool _spool;
    private IScannerSession? _session;
    private bool _userPickedDevice;
    /// <summary>
    /// A real scanner appeared, or the selected one went away, during an operation/review;
    /// re-evaluate the selection afterwards.
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
                        IOcrService? ocrService = null)
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
        Settings = SettingsStore.Load() ?? new ScanSettings();
        _backends = backends ?? [new Scanning.WiaScannerBackend(),
                                 new Scanning.EsclScannerBackend(),
                                 new MockScannerBackend()];
        _presetStore = new PresetStore();
        _ocrService = ocrService ?? new WindowsOcrService();
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
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    /// <summary>Call after mutating Settings from the UI: debounced persist + live preview refresh.</summary>
    public void SettingsEdited()
    {
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
        // Remove partial files an export cut off by a crash left in the destination folder.
        string folder = DestinationFolder;
        _ = Task.Run(() => SavedFiles.SweepStaleTempFiles(folder, SavedFiles.StaleTempFileAge));
    }

    private void MergeDevices()
    {
        Devices.Clear();
        foreach (var backend in _backends)
        {
            foreach (var device in backend.Devices) Devices.Add(device);
        }

        if (SelectedDeviceId is { } sel)
        {
            if (Devices.All(d => d.Id != sel))
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
            else if (!_userPickedDevice && PreferredDefaultDevice() is { } real
                     && Devices.First(d => d.Id == sel).IsDemo
                     && !Devices.First(d => d.Id == real).IsDemo)
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
        NotifyAll();
    }

    /// <summary>Re-evaluate a deferred automatic device switch once nothing is in progress.</summary>
    private void EndOfWork()
    {
        if (!_autoSwitchDeferred || IsBusy || ShowPhotoReview) return;
        _autoSwitchDeferred = false;
        MergeDevices();
    }

    private string? PreferredDefaultDevice() =>
        (Devices.FirstOrDefault(d => !d.IsDemo) ?? Devices.FirstOrDefault())?.Id;

    /// <summary>Device selection driven by the user (sidebar click).</summary>
    public void UserSelectDevice(string? id)
    {
        _userPickedDevice = true;
        SelectDevice(id);
    }

    private void SelectDevice(string? id)
    {
        // Ignore re-clicks on a device that is already connected or connecting.
        if (id == SelectedDeviceId && (_session != null || !_switchTask.IsCompleted)) return;
        SelectedDeviceId = id;
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
            await SwitchSession(id);
        }
    }

    private async Task SwitchSession(string? id)
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
        string name = Devices.FirstOrDefault(d => d.Id == id)?.Name ?? "scanner";
        StatusMessage = $"Connecting to {name}…";
        NotifyAll();
        try
        {
            var session = await backend.OpenSessionAsync(id);
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
            var caps = await session.GetCapabilitiesAsync();
            Capabilities = caps;
            Settings.Resolution = caps.NearestResolution(Settings.Resolution);
            if (!caps.Sources.Contains(Settings.Source))
            {
                Settings.Source = caps.Sources.FirstOrDefault(ScanSource.Flatbed);
            }
            StatusMessage = $"Ready — {session.Info.Name}";
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            StatusMessage = $"Could not connect to {name}.";
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
        var selection = s.Source == ScanSource.Flatbed ? SelectionRect : null;
        return RunExclusive(async token =>
        {
            StatusMessage = "Scanning…";
            NotifyAll();
            var raw = await session.PerformScanAsync(s, selection);
            // Discard results that arrive after the user switched devices.
            if (_switchGeneration != generation) return;
            if (raw.Count == 0) throw ScanException.ScanFailed("The scanner returned no pages.");
            // A feeder batch cut short (a jam, a dropped connection) still returns its pages;
            // once they are handled the user is told the stack was not finished.
            var stop = session.LastScanStop;
            token.ThrowIfCancellationRequested();
            StatusMessage = "Processing…";
            NotifyAll();
            // Pixel-heavy work runs off the UI thread so the window stays live; the token is
            // checked between pages.
            var processed = await Task.Run(() =>
            {
                var result = new List<ScannedPage>();
                foreach (var page in raw)
                {
                    token.ThrowIfCancellationRequested();
                    if (s.Adjustments.IsIdentity && s.ColorMode == ColorMode.Color)
                    {
                        result.Add(page);
                        continue;
                    }
                    var adjusted = ImagePipeline.Apply(s.Adjustments, page.Image, s.ColorMode);
                    result.Add(new ScannedPage(adjusted, page.Dpi, s.ColorMode, page.Id, page.CreatedAt));
                }
                return result;
            }, token);
            if (_switchGeneration != generation) return;
            token.ThrowIfCancellationRequested();

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

            switch (s.Intent)
            {
                case ScanIntent.Document:
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
                        SetLastScan(rawPreview);
                        int n = processed.Count;
                        StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")} — {ScannedPages.Count} in queue. Scan more or Save PDF.";
                    }
                    else
                    {
                        SetLastScan(rawPreview);
                        await SaveImmediately(processed, s, token);
                    }
                    break;
                case ScanIntent.Photo:
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
                    ShowPhotoReview = found.Count > 0;
                    if (!ShowPhotoReview) _photoSourceImages = [];
                    StatusMessage = $"Found {found.Count} photo{(found.Count == 1 ? "" : "s")} on the bed.";
                    break;
            }
            if (stop is not null) ErrorMessage = stop.Message(raw.Count);
            NotifyAll();
        });
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
            var pages = ScannedPages.Select(p => p.Page).ToList();
            if (pages.Count == 0) return;
            StatusMessage = s.PdfSearchable ? "Running OCR and building PDF…" : "Building PDF…";
            NotifyAll();
            string path = await WritePdfAtomically(pages, s, OutputPath(s, "pdf"), token);
            MarkSaved([path]);
            DeleteSpoolFiles(pages);
            ScannedPages.Clear();
            StatusMessage = $"Saved {pages.Count}-page PDF: {Path.GetFileName(path)}";
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
        StatusMessage = $"Saved {string.Join(", ", saved.Select(Path.GetFileName))}";
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
            StatusMessage = $"Saved {saved.Count} photo{(saved.Count == 1 ? "" : "s")} to {s.DestinationPath}";
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
            // The page may have been removed (or the queue saved) meanwhile.
            int index = ScannedPages.IndexOf(item);
            if (index < 0) return;
            ScannedPages[index] = rotated;
            NotifyAll();
        }
    }

    public void ClearPages()
    {
        if (IsBusy) return;
        DeleteSpoolFiles(ScannedPages.Select(p => p.Page));
        ScannedPages.Clear();
        StatusMessage = "Page queue cleared.";
        NotifyAll();
    }

    // MARK: Presets

    public void ApplyPreset(Preset preset)
    {
        var s = preset.Settings.Clone();
        if (Capabilities is { } caps)
        {
            s.Resolution = caps.NearestResolution(s.Resolution);
            if (!caps.Sources.Contains(s.Source)) s.Source = caps.Sources.FirstOrDefault(ScanSource.Flatbed);
        }
        Settings = s;
        SettingsEdited();
        StatusMessage = $"Applied preset “{preset.Name}”.";
        NotifyAll();
    }

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
            return new ScannedPage(preview, page.Dpi, page.ColorMode, page.Id, page.CreatedAt,
                                   path, new SizeD(page.Image.Width, page.Image.Height));
        }).ToList();
    }

    /// <summary>
    /// OCR (when searchable) + JPEG-encode each page, then write the PDF through
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
            byte[] jpeg = await Task.Run(() => WpfImageCodec.EncodeJpeg(image, page.Dpi), token);
            inputs.Add(new PdfPageInput(jpeg, prepared.PixelWidth, prepared.PixelHeight, page.Dpi, lines));
        }

        StatusMessage = "Writing PDF…";
        NotifyAll();
        return await Task.Run(() => PdfBuilder.WriteNewFile(inputs, path, progress: null, token), token);
    }

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
            .BaseFilename(NextCounter(), DateTime.Now, s.Intent, index);
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
        }
        _operationCts = null;
        Progress = null;
        IsBusy = false;
        NotifyAll();
        EndOfWork();
    }
}
