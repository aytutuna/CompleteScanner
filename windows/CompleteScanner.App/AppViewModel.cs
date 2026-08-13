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
    public ScannedPage Page { get; } = page;
    public BitmapSource Thumbnail { get; } = WpfImageCodec.ToBitmapSource(page.Image);
}

/// <summary>A detected photo in the review grid, wrapped with its display thumbnail.</summary>
public sealed class PhotoItem(DetectedPhoto photo) : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public DetectedPhoto Photo { get; } = photo;
    public BitmapSource Thumbnail { get; } = WpfImageCodec.ToBitmapSource(photo.Image);

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
/// Central controller: owns backends, the open scanner session, settings, scan results, and
/// every user-triggered operation. All UI binds to this object. Port of
/// Sources/CompleteScannerKit/App/AppState.swift — the orchestration logic (device merging,
/// generation-guarded switching, scan flows, page spooling, atomic PDF saves) carries over
/// unchanged; only the change-notification plumbing is WPF-flavored.
/// </summary>
public sealed class AppViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// Where document pages are spilled to disk while they wait in the queue, so a long
    /// high-dpi batch doesn't hold gigabytes of pixels in memory.
    /// </summary>
    private static readonly string PageSpoolDirectory =
        Path.Combine(Path.GetTempPath(), "CompleteScanner-pages");

    // MARK: Published state

    public ObservableCollection<ScannerInfo> Devices { get; } = [];

    public string? SelectedDeviceId { get; private set; }
    public ScannerCapabilities? Capabilities { get; private set; }
    public ScanSettings Settings { get; private set; }

    /// <summary>Low-res preview of the full bed; the selection marquee is only valid over this image.</summary>
    public RgbaImage? OverviewImage { get; private set; }
    /// <summary>The most recent full scan (shown in the canvas when there is no overview).</summary>
    public RgbaImage? LastScanImage { get; private set; }
    /// <summary>Normalized (0...1) crop rect within the flatbed, origin top-left. null = full bed.</summary>
    public RectD? SelectionRect { get; set; }

    public ObservableCollection<PageItem> ScannedPages { get; } = [];
    public List<PhotoItem> DetectedPhotos { get; private set; } = [];
    public bool ShowPhotoReview { get; private set; }

    public bool IsBusy { get; private set; }
    public ScanProgress? Progress { get; private set; }
    public string StatusMessage { get; private set; } = "Looking for scanners…";
    public string? ErrorMessage { get; set; }
    public List<string> LastSavedPaths { get; private set; } = [];

    public ObservableCollection<Preset> Presets { get; } = [];

    /// <summary>Image shown in the preview canvas.</summary>
    public RgbaImage? CanvasImage => OverviewImage ?? LastScanImage;
    public BitmapSource? CanvasBitmap { get; private set; }

    public static readonly int[] FallbackResolutions = [75, 150, 200, 300, 600, 1200];

    // MARK: Private

    private readonly IReadOnlyList<IScannerBackend> _backends;
    private readonly PresetStore _presetStore;
    private readonly IOcrService _ocrService;
    private readonly Dispatcher _dispatcher;
    private IScannerSession? _session;
    private bool _userPickedDevice;
    /// <summary>
    /// Device switches are serialized through this chain; concurrent clicks must never
    /// interleave open/close on hardware sessions.
    /// </summary>
    private Task _switchTask = Task.CompletedTask;
    private int _switchGeneration;
    private DispatcherTimer? _settingsSaveTimer;
    private int _counterFallback;

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
        // Clear page spill files left behind by a previous run.
        try { Directory.Delete(PageSpoolDirectory, recursive: true); } catch { /* best effort */ }
        Directory.CreateDirectory(PageSpoolDirectory);
    }

    private void NotifyAll()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    /// <summary>Call after mutating Settings from the UI: debounced persist.</summary>
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
                _userPickedDevice = false;
                SelectDevice(PreferredDefaultDevice());
            }
            else if (!_userPickedDevice && PreferredDefaultDevice() is { } real
                     && Devices.First(d => d.Id == sel).IsDemo
                     && !Devices.First(d => d.Id == real).IsDemo)
            {
                // A real scanner appeared while we were auto-parked on the demo device.
                SelectDevice(real);
            }
        }
        else if (PreferredDefaultDevice() is { } def)
        {
            SelectDevice(def);
        }
        NotifyAll();
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
        UpdateCanvas();

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
        string name = _devices.FirstOrDefault(d => d.Id == id)?.Name ?? "scanner";
        StatusMessage = $"Connecting to {name}…";
        NotifyAll();
        try
        {
            var session = await backend.OpenSessionAsync(id);
            if (SelectedDeviceId != id) { await session.CloseAsync(); return; }
            session.ProgressHandler = p => _dispatcher.BeginInvoke(() =>
            {
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

    public void PerformOverview()
    {
        if (_session is not { } session) { NoDevice(); return; }
        int generation = _switchGeneration;
        RunExclusive(async () =>
        {
            StatusMessage = "Scanning overview…";
            NotifyAll();
            var image = await session.PerformOverviewScanAsync(Settings);
            // Discard results that arrive after the user switched devices.
            if (_switchGeneration != generation) return;
            OverviewImage = image;
            StatusMessage = "Overview ready — drag on the preview to select an area, then Scan.";
            UpdateCanvas();
        });
    }

    public void PerformScan()
    {
        if (_session is not { } session) { NoDevice(); return; }
        int generation = _switchGeneration;
        RunExclusive(async () =>
        {
            StatusMessage = "Scanning…";
            NotifyAll();
            var raw = await session.PerformScanAsync(
                Settings, Settings.Source == ScanSource.Flatbed ? SelectionRect : null);
            if (_switchGeneration != generation) return;
            if (raw.Count == 0) throw ScanException.ScanFailed("The scanner returned no pages.");
            var s = Settings.Clone();
            StatusMessage = "Processing…";
            NotifyAll();
            // Pixel-heavy work runs off the UI thread so the window stays live.
            var processed = await Task.Run(() => raw.Select(page =>
            {
                if (s.Adjustments.IsIdentity && s.ColorMode == ColorMode.Color) return page;
                var adjusted = ImagePipeline.Apply(s.Adjustments, page.Image, s.ColorMode);
                return new ScannedPage(adjusted, page.Dpi, s.ColorMode, page.Id, page.CreatedAt);
            }).ToList());
            if (_switchGeneration != generation) return;

            switch (s.Intent)
            {
                case ScanIntent.Document:
                    if (s.DocumentMultiPage)
                    {
                        // Spill full-resolution pages to disk; keep only previews in the queue.
                        var spooled = await Task.Run(() => SpoolPages(processed));
                        if (_switchGeneration != generation)
                        {
                            DeleteSpoolFiles(spooled);
                            return;
                        }
                        ScannedPages.AddRange(spooled.Select(p => new PageItem(p)));
                        LastScanImage = spooled.LastOrDefault()?.Image;
                        int n = processed.Count;
                        StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")} — {ScannedPages.Count} in queue. Scan more or Save PDF.";
                    }
                    else
                    {
                        LastScanImage = processed.LastOrDefault()?.Image;
                        await SaveImmediately(processed);
                    }
                    break;
                case ScanIntent.Photo:
                    // Full resolution here: the detection overlay maps source-pixel
                    // coordinates onto this image.
                    LastScanImage = processed.LastOrDefault()?.Image;
                    var found = await Task.Run(() =>
                        processed.SelectMany(p => SplitPhotos(p, s)).ToList());
                    if (_switchGeneration != generation) return;
                    DetectedPhotos = found.Select(p => new PhotoItem(p)).ToList();
                    ShowPhotoReview = found.Count > 0;
                    StatusMessage = $"Found {found.Count} photo{(found.Count == 1 ? "" : "s")} on the bed.";
                    break;
            }
            UpdateCanvas();
        });
    }

    private static List<DetectedPhoto> SplitPhotos(ScannedPage page, ScanSettings s)
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
            if (PhotoDetector.ExtractPhoto(page.Image, region, s.PhotoAutoDeskew) is { } image)
            {
                photos.Add(new DetectedPhoto(region, image, page.Dpi));
            }
        }
        return photos;
    }

    private static DetectedPhoto WholePagePhoto(ScannedPage page)
    {
        double w = page.Image.Width, h = page.Image.Height;
        var region = new DetectedPhotoRegion(new PointD(w / 2, h / 2), new SizeD(w, h), 0);
        return new DetectedPhoto(region, page.Image, page.Dpi);
    }

    public void CancelScan() => _session?.CancelScan();

    // MARK: Saving

    public void SavePdf()
    {
        if (ScannedPages.Count == 0) return;
        var pages = ScannedPages.Select(p => p.Page).ToList();
        var s = Settings.Clone();
        RunExclusive(async () =>
        {
            StatusMessage = s.PdfSearchable ? "Running OCR and building PDF…" : "Building PDF…";
            NotifyAll();
            string path = OutputPath("pdf");
            await WritePdfAtomically(pages, s, path);
            LastSavedPaths = [path];
            DeleteSpoolFiles(pages);
            ScannedPages.Clear();
            StatusMessage = $"Saved {pages.Count}-page PDF: {Path.GetFileName(path)}";
        });
    }

    /// <summary>Used when DocumentMultiPage is off: write each scan to disk as soon as it lands.</summary>
    private async Task SaveImmediately(List<ScannedPage> pages)
    {
        var s = Settings;
        var saved = new List<string>();
        if (s.Format == OutputFormat.Pdf)
        {
            string path = OutputPath("pdf");
            await WritePdfAtomically(pages, s, path);
            saved = [path];
        }
        else
        {
            foreach (var page in pages)
            {
                string path = OutputPath(s.Format.FileExtension());
                await Task.Run(() =>
                    WpfImageCodec.Save(page.Image, path, s.Format, page.Dpi, s.JpegQuality));
                saved.Add(path);
            }
        }
        LastSavedPaths = saved;
        StatusMessage = $"Saved {string.Join(", ", saved.Select(Path.GetFileName))}";
    }

    public void SaveReviewedPhotos()
    {
        var photos = DetectedPhotos.Where(p => p.Photo.Included).Select(p => p.Photo).ToList();
        if (photos.Count == 0) { CancelPhotoReview(); return; }
        var s = Settings.Clone();
        var format = s.Format == OutputFormat.Pdf ? OutputFormat.Jpeg : s.Format;
        RunExclusive(async () =>
        {
            var saved = new List<string>();
            for (int index = 0; index < photos.Count; index++)
            {
                var photo = photos[index];
                string path = OutputPath(format.FileExtension(), index + 1);
                await Task.Run(() =>
                {
                    var image = photo.RotationQuarterTurns == 0
                        ? photo.Image
                        : ImagePipeline.Rotate(photo.Image, photo.RotationQuarterTurns);
                    WpfImageCodec.Save(image, path, format, photo.Dpi, s.JpegQuality);
                });
                saved.Add(path);
            }
            LastSavedPaths = saved;
            DetectedPhotos = [];
            ShowPhotoReview = false;
            StatusMessage = $"Saved {saved.Count} photo{(saved.Count == 1 ? "" : "s")} to {s.DestinationPath}";
        });
    }

    public void CancelPhotoReview()
    {
        DetectedPhotos = [];
        ShowPhotoReview = false;
        StatusMessage = "Photo batch discarded.";
        NotifyAll();
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

    // MARK: Helpers

    private void UpdateCanvas()
    {
        CanvasBitmap = CanvasImage is { } image ? WpfImageCodec.ToBitmapSource(image) : null;
        NotifyAll();
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
    private static List<ScannedPage> SpoolPages(List<ScannedPage> pages)
    {
        Directory.CreateDirectory(PageSpoolDirectory);
        return pages.Select(page =>
        {
            string path = Path.Combine(PageSpoolDirectory, $"{page.Id}.png");
            try
            {
                WpfImageCodec.Save(page.Image, path, OutputFormat.Png, page.Dpi, 1.0);
            }
            catch
            {
                return page;
            }
            var preview = MakePreview(page.Image, 1600);
            return new ScannedPage(preview, page.Dpi, page.ColorMode, page.Id, page.CreatedAt,
                                   path, new SizeD(page.Image.Width, page.Image.Height));
        }).ToList();
    }

    private static RgbaImage MakePreview(RgbaImage image, int maxSide)
    {
        int longSide = Math.Max(image.Width, image.Height);
        if (longSide <= maxSide) return image;
        double scale = (double)maxSide / longSide;
        return image.Resized(Math.Max(1, (int)(image.Width * scale)),
                             Math.Max(1, (int)(image.Height * scale)));
    }

    /// <summary>
    /// OCR (when searchable) + JPEG-encode each page, then write the PDF to a hidden temp
    /// name and move it into place, so a failed or interrupted build never leaves a
    /// truncated PDF at the destination.
    /// </summary>
    private async Task WritePdfAtomically(List<ScannedPage> pages, ScanSettings s, string path)
    {
        var inputs = new List<PdfPageInput>();
        for (int i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            // Spilled pages hold only a preview in memory — reload the full-resolution
            // pixels one page at a time.
            var image = await Task.Run(() => FullResolutionImage(page));
            IReadOnlyList<OcrLine>? lines = null;
            if (s.PdfSearchable)
            {
                StatusMessage = $"OCR page {i + 1} of {pages.Count}…";
                NotifyAll();
                // If OCR fails for a page, the PDF is still produced without a text layer.
                try { lines = await _ocrService.RecognizeLinesAsync(image, s.OcrLanguages); }
                catch { lines = null; }
            }
            byte[] jpeg = await Task.Run(() => WpfImageCodec.EncodeJpeg(image, page.Dpi));
            int pixelWidth = page.FullPixelSize is { } full ? (int)full.Width : image.Width;
            int pixelHeight = page.FullPixelSize is { } fullH ? (int)fullH.Height : image.Height;
            inputs.Add(new PdfPageInput(jpeg, pixelWidth, pixelHeight, page.Dpi, lines));
        }

        string tmp = Path.Combine(Path.GetDirectoryName(path)!, $".{Guid.NewGuid()}.pdf.tmp");
        try
        {
            await Task.Run(() =>
            {
                using var stream = File.Create(tmp);
                PdfBuilder.Write(inputs, stream);
            });
            File.Move(tmp, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw;
        }
    }

    private static RgbaImage FullResolutionImage(ScannedPage page)
    {
        if (page.FilePath is null) return page.Image;
        try
        {
            return WpfImageCodec.Load(page.FilePath);
        }
        catch
        {
            // Missing/unreadable spill file: fall back to the in-memory image rather than
            // failing the whole save.
            return page.Image;
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

    private string DestinationDirectory()
    {
        string path = Environment.ExpandEnvironmentVariables(Settings.DestinationPath);
        Directory.CreateDirectory(path);
        return path;
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

    private string OutputPath(string fileExtension, int? index = null)
    {
        string dir = DestinationDirectory();
        string baseName = new NamingTemplate(Settings.NamingTemplate)
            .BaseFilename(NextCounter(), DateTime.Now, Settings.Intent, index);
        return NamingTemplate.UniquePath(dir, baseName, fileExtension);
    }

    /// <summary>Run one long operation at a time; surface errors; manage busy state.</summary>
    private async void RunExclusive(Func<Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        NotifyAll();
        try
        {
            await operation();
        }
        catch (ScanException e) when (e.Kind == ScanErrorKind.Cancelled)
        {
            StatusMessage = "Cancelled.";
        }
        catch (OperationCanceledException)
        {
            StatusMessage = "Cancelled.";
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            StatusMessage = "Ready.";
        }
        Progress = null;
        IsBusy = false;
        NotifyAll();
    }
}
