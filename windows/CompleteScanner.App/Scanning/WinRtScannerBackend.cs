using System.IO;
using System.Windows.Media.Imaging;
using CompleteScanner.App.Services;
using CompleteScanner.Core;
using Windows.Devices.Enumeration;
using Windows.Devices.Scanners;
using Windows.Graphics.Printing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace CompleteScanner.App.Scanning;

/// <summary>
/// WIA scanners reached through Windows Scan (Windows.Devices.Scanners, the WinRT
/// <see cref="ImageScanner"/> API over the same WIA 2.0 drivers): a backup to the WIA Automation
/// connection (<see cref="WiaScannerBackend"/>), never a replacement. Its entries join the WIA
/// ones of the same scanner in one row (<see cref="DeviceMerge"/>) and rank after every other
/// connection, so it is used when the user picks "Windows Scan (backup)" in the row's connection
/// chooser, or when it is the only connection left to the scanner (WIA Automation lists nothing,
/// for example).
///
/// Scanners are found by a <see cref="DeviceWatcher"/> on <see cref="ImageScanner.GetDeviceSelector"/>,
/// so scanners plugged in or out are followed without polling. The API works in this unpackaged
/// app (no package identity or capability is needed to list scanners or open one); should
/// Windows refuse it (no package identity, access denied, the API missing from the edition),
/// the connection lists nothing and devices.txt says why (<see cref="WindowsScanErrors.UnavailableToThisApp"/>).
/// The decisions (capabilities, the scan request, errors) are in Core (<c>WindowsScan.cs</c>).
///
/// Experimental, untested against hardware: checked on a PC without a scanner (the watcher's
/// first pass completes with no devices; opening a device that is not there is reported as an
/// offline scanner).
/// </summary>
public sealed class WinRtScannerBackend : IScannerBackend, IBackendDiagnostics, IScannerBackendDiagnostics, IDisposable
{
    public event Action? DevicesChanged;

    private readonly object _gate = new();
    private readonly Func<string> _scratchRoot;
    /// <summary>The devices the watcher reported, in the order it reported them (under <see cref="_gate"/>).</summary>
    private readonly List<DeviceInformation> _found = [];
    /// <summary>The sources each device reported when a session read them, by device-list id (under <see cref="_gate"/>).</summary>
    private readonly Dictionary<string, IReadOnlyList<WindowsScanSourceFacts>> _facts = [];
    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    private DeviceWatcher? _watcher;
    private SynchronizationContext? _context;
    private bool _browsing;
    private bool _changePosted;
    private WindowsScanStatus _status = WindowsScanStatus.Off;
    private string? _note;
    /// <summary>Windows stopped the watcher on its own; Refresh starts it again.</summary>
    private bool _aborted;
    /// <summary>The status and note the last <see cref="DevicesChanged"/> went out with.</summary>
    private (WindowsScanStatus, string?) _published = (WindowsScanStatus.Off, null);
    /// <summary>Bumped whenever a session records what a device reported (under <see cref="_gate"/>).</summary>
    private int _factsVersion;
    /// <summary>The <see cref="_factsVersion"/> the last <see cref="DevicesChanged"/> went out with.</summary>
    private int _publishedFactsVersion;
    /// <summary>Whether a refusal from opening a device hides the connection (under <see cref="_gate"/>).</summary>
    private readonly WindowsScanAccess _access = new();

    /// <param name="scratchRoot">
    /// The app's private page spool folder: each scan writes its files to a new folder inside it
    /// and deletes it once the pages are read. Never one of the user's folders.
    /// </param>
    public WinRtScannerBackend(Func<string> scratchRoot)
    {
        _scratchRoot = scratchRoot;
    }

    /// <summary>How the watcher is doing (diagnostics and harnesses).</summary>
    public WindowsScanStatus Status
    {
        get
        {
            lock (_gate) return _status;
        }
    }

    /// <summary>What the diagnostics say beside the status: why the connection is hidden, or that the watcher stopped.</summary>
    public string? Note
    {
        get
        {
            lock (_gate) return _note;
        }
    }

    public string? DiagnosticsReport
    {
        get
        {
            lock (_gate)
            {
                return WindowsScanDiagnostics.Report(_status, _note, [.. _devices], new Dictionary<string, IReadOnlyList<WindowsScanSourceFacts>>(_facts));
            }
        }
    }

    public void StartBrowsing()
    {
        lock (_gate)
        {
            if (_browsing) return;
            _browsing = true;
            _context = SynchronizationContext.Current;
            StartWatcher();
        }
        PostChanged();
    }

    public void StopBrowsing()
    {
        lock (_gate)
        {
            _browsing = false;
            StopWatcher();
            _found.Clear();
            _status = WindowsScanStatus.Off;
            _note = null;
            _aborted = false;
        }
        PostChanged();
    }

    public void Dispose() => StopBrowsing();

    /// <summary>Windows Scan adds no check of its own to the troubleshooter; its state is in devices.txt.</summary>
    public DiscoverySnapshot AddStatus(DiscoverySnapshot snapshot) => snapshot;

    /// <summary>The troubleshooter's Refresh: starts the watcher again when Windows stopped it or it would not start.</summary>
    public void Rescan()
    {
        lock (_gate)
        {
            if (!_browsing || (_watcher is not null && !_aborted)) return;
            StopWatcher();
            _found.Clear();
            StartWatcher();
        }
        PostChanged();
    }

    /// <summary>Creates and starts the watcher. Call under the lock.</summary>
    private void StartWatcher()
    {
        _aborted = false;
        _note = null;
        _access.Restart();
        DeviceWatcher? watcher = null;
        try
        {
            watcher = DeviceInformation.CreateWatcher(ImageScanner.GetDeviceSelector());
            var created = watcher;
            created.Added += (_, info) => OnAdded(created, info);
            created.Updated += (_, update) => OnUpdated(created, update);
            created.Removed += (_, update) => OnRemoved(created, update);
            created.EnumerationCompleted += (_, _) => OnEnumerationCompleted(created);
            created.Stopped += (_, _) => OnStopped(created);
            _watcher = created;
            _status = WindowsScanStatus.Searching;
            created.Start();
        }
        catch (Exception e)
        {
            _watcher = null;
            StopQuietly(watcher);
            _status = WindowsScanStatus.Unavailable;
            _note = WindowsScanErrors.UnavailableToThisApp(e.HResult)
                ? WindowsScanErrors.UnavailableNote(e.HResult, e.Message)
                : $"the Windows device watcher would not start ({e.GetType().Name} 0x{unchecked((uint)e.HResult):X8}: {e.Message.Trim()})";
            System.Diagnostics.Trace.TraceWarning($"Windows Scan: {_note}");
        }
    }

    /// <summary>Stops and forgets the watcher, so its Stopped event is not taken for Windows aborting it. Call under the lock.</summary>
    private void StopWatcher()
    {
        var watcher = _watcher;
        _watcher = null;
        StopQuietly(watcher);
    }

    private static void StopQuietly(DeviceWatcher? watcher)
    {
        if (watcher is null) return;
        try
        {
            if (watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted) watcher.Stop();
        }
        catch (Exception)
        {
            // Already stopping or aborted.
        }
    }

    /// <summary>
    /// Hides the connection: Windows refused the API to this app (found when a device is opened).
    /// Its entries leave the list, so the rows fall back to their other connections.
    /// </summary>
    internal void MarkUnavailable(Exception error)
    {
        lock (_gate)
        {
            StopWatcher();
            _found.Clear();
            _status = WindowsScanStatus.Unavailable;
            _note = WindowsScanErrors.UnavailableNote(error.HResult, error.Message);
            System.Diagnostics.Trace.TraceWarning($"Windows Scan: {_note}");
        }
        PostChanged();
    }

    /// <summary>
    /// Keeps what a session read about a device's sources for devices.txt (any thread), and
    /// raises <see cref="DevicesChanged"/> so the file is written again with them.
    /// </summary>
    internal void RecordFacts(string deviceId, IReadOnlyList<WindowsScanSourceFacts> facts)
    {
        lock (_gate)
        {
            _facts[deviceId] = facts;
            _factsVersion++;
        }
        PostChanged();
    }

    private void OnAdded(DeviceWatcher watcher, DeviceInformation info)
    {
        lock (_gate)
        {
            if (watcher != _watcher) return;
            _found.RemoveAll(d => d.Id == info.Id);
            if (info.IsEnabled) _found.Add(info);
        }
        PostChanged();
    }

    private void OnUpdated(DeviceWatcher watcher, DeviceInformationUpdate update)
    {
        lock (_gate)
        {
            if (watcher != _watcher) return;
            var info = _found.FirstOrDefault(d => d.Id == update.Id);
            if (info is null) return;
            info.Update(update);
            if (!info.IsEnabled) _found.Remove(info);
        }
        PostChanged();
    }

    private void OnRemoved(DeviceWatcher watcher, DeviceInformationUpdate update)
    {
        lock (_gate)
        {
            if (watcher != _watcher) return;
            if (_found.RemoveAll(d => d.Id == update.Id) == 0) return;
        }
        PostChanged();
    }

    private void OnEnumerationCompleted(DeviceWatcher watcher)
    {
        lock (_gate)
        {
            if (watcher != _watcher) return;
            _status = WindowsScanStatus.Running;
        }
        PostChanged();
    }

    /// <summary>The watcher ended without being stopped here (Windows aborted it): what it found stays listed, and devices.txt says so.</summary>
    private void OnStopped(DeviceWatcher watcher)
    {
        lock (_gate)
        {
            if (watcher != _watcher) return;
            _aborted = true;
            _note = $"the Windows device watcher stopped ({watcher.Status}); Refresh in the troubleshooter starts it again";
        }
        PostChanged();
    }

    /// <summary>Rebuilds the list once on the start context for any burst of watcher events.</summary>
    private void PostChanged()
    {
        SynchronizationContext? context;
        lock (_gate)
        {
            if (_changePosted) return;
            _changePosted = true;
            context = _context;
        }
        if (context is null) Rebuild(null);
        else context.Post(Rebuild, null);
    }

    private void Rebuild(object? _)
    {
        List<ScannerInfo> found;
        bool statusChanged;
        bool factsChanged;
        lock (_gate)
        {
            _changePosted = false;
            found = _status == WindowsScanStatus.Unavailable
                ? []
                : [.. _found.Select(info => WindowsScanConnection.Info(info.Id, info.Name))];
            statusChanged = _published != (_status, _note);
            _published = (_status, _note);
            factsChanged = _publishedFactsVersion != _factsVersion;
            _publishedFactsVersion = _factsVersion;
            if (!statusChanged && !factsChanged && _devices.SequenceEqual(found)) return;
            _devices.Clear();
            _devices.AddRange(found);
        }
        // Raised for a new status or newly read sources too, so devices.txt is written again.
        DevicesChanged?.Invoke();
    }

    public async Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        string windowsId = WindowsScanConnection.DeviceId(deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        var scanner = await OpenScannerAsync(windowsId, info.Name, error => Refused(windowsId, error)).ConfigureAwait(true);
        lock (_gate) _access.Opened();
        return new WinRtScannerSession(info, scanner, _scratchRoot, facts => RecordFacts(info.Id, facts));
    }

    /// <summary>
    /// Opening the device <paramref name="windowsId"/> was refused (<see cref="WindowsScanErrors.UnavailableToThisApp"/>):
    /// hides the connection when <see cref="WindowsScanAccess"/> takes the refusal for the API's,
    /// and says whether it did. Otherwise only that device fails.
    /// </summary>
    internal bool Refused(string windowsId, Exception error)
    {
        bool hides;
        lock (_gate) hides = _access.HidesConnection(windowsId, error.HResult, _found.Select(d => d.Id));
        if (hides) MarkUnavailable(error);
        else System.Diagnostics.Trace.TraceWarning($"Windows Scan: opening {windowsId} was refused (0x{unchecked((uint)error.HResult):X8}); the other scanners stay listed");
        return hides;
    }

    /// <summary>
    /// Opens a device by its Windows id, on the thread pool (the session makes every call from
    /// there, in one apartment). Failures become <see cref="ScanException"/>s (a device that is not
    /// there: an offline scanner). A refusal of the API itself is passed to <paramref name="refused"/>
    /// first, which says whether it hid the connection; the error says Windows Scan is not
    /// available only then, otherwise it is that device's failure.
    /// </summary>
    internal static async Task<ImageScanner> OpenScannerAsync(string windowsId, string name, Func<Exception, bool> refused)
    {
        ImageScanner? scanner;
        try
        {
            scanner = await Task.Run(async () => await ImageScanner.FromIdAsync(windowsId)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            bool hidden = WindowsScanErrors.UnavailableToThisApp(e.HResult) && refused(e);
            throw WindowsScanErrors.ToScanException(e.HResult, e.Message, opening: hidden);
        }
        return scanner ?? throw ScanException.DeviceUnavailable($"{name} is no longer connected.");
    }
}

/// <summary>
/// An open Windows Scan connection. Every call to the device runs on the thread pool. The device
/// opened, so the API works for this app: no error from here on hides the connection.
/// </summary>
/// <param name="scratchRoot">The private folder scans write their files under.</param>
/// <param name="recordFacts">Receives the device's sources once they are read (for devices.txt).</param>
internal sealed class WinRtScannerSession(ScannerInfo info, ImageScanner scanner, Func<string> scratchRoot,
                                          Action<IReadOnlyList<WindowsScanSourceFacts>> recordFacts) : IScannerSession
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }

    private volatile ScanStop? _lastScanStop;
    public ScanStop? LastScanStop => _lastScanStop;

    /// <summary>-1 unknown, 0 one side, 1 both sides.</summary>
    private volatile int _lastScanDuplex = -1;
    public bool? LastScanDuplex => _lastScanDuplex < 0 ? null : _lastScanDuplex == 1;

    private readonly object _gate = new();
    private CancellationTokenSource? _scan;
    private bool _factsRead;
    private WindowsScanSourceFacts? _flatbed;
    private WindowsScanSourceFacts? _feeder;
    /// <summary>The feeder's page size, orientation and area before the session first set any (each null when unreadable).</summary>
    private FeederArea? _feederDefaults;

    private readonly record struct FeederArea(PrintMediaSize? PageSize, PrintOrientation? Orientation, Windows.Foundation.Rect? Region);

    public Task<ScannerCapabilities> GetCapabilitiesAsync() => Run(_ =>
    {
        ReadFacts(force: true);
        return Task.FromResult(WindowsScanCapabilities.Map(_flatbed, _feeder));
    }, CancellationToken.None);

    public Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        var token = BeginScan();
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        return Run(async cancel =>
        {
            ReadFacts(force: false);
            if (_flatbed is not { } flatbed) throw ScanException.Unsupported("This scanner has no flatbed to preview.");
            var plan = WindowsScanRequest.Overview(flatbed);
            Apply(plan);
            if (flatbed.PreviewSupported && await PreviewAsync(cancel) is { } preview) return preview;
            // No preview of its own (or it failed): a quick low-resolution scan instead.
            var pages = await ScanFilesAsync(plan, feeder: false, cancel);
            return pages.Count > 0 ? pages[0].Image : throw ScanException.ScanFailed("The scanner did not return any image data.");
        }, token);
    }

    public Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _lastScanStop = null;
        _lastScanDuplex = -1;
        var token = BeginScan();
        ProgressHandler?.Invoke(new ScanProgress("Scanning…"));
        return Run<IReadOnlyList<ScannedPage>>(async cancel =>
        {
            ReadFacts(force: false);
            bool feeder = settings.Source == ScanSource.DocumentFeeder;
            if (!feeder && _flatbed is null && _feeder is not null)
            {
                throw ScanException.Unsupported("This scanner has no flatbed; scan from its document feeder.");
            }
            var plan = WindowsScanRequest.Plan(settings, feeder ? null : selection, feeder ? _feeder : _flatbed);
            int reportedDpi = Apply(plan);
            // Whether the driver took two-sided feeding, so the app knows what the pages are.
            if (feeder && settings.Duplex == DuplexMode.Both)
            {
                _lastScanDuplex = plan.Duplex && Read(() => scanner.FeederConfiguration.Duplex, false) ? 1 : 0;
            }
            var frames = await ScanFilesAsync(plan, feeder, cancel);
            if (frames.Count == 0)
            {
                throw feeder
                    ? ScanException.ForProblem(ScannerProblem.FeederEmpty)
                    : ScanException.ScanFailed("The scanner did not return any image data.");
            }
            // The resolution sets each page's size on paper: when the driver does not say what it
            // scanned at (a device that configures itself), the file's own is better than the one asked for.
            return [.. frames.Select(frame => new ScannedPage(frame.Image, WindowsScanRequest.PageDpi(reportedDpi, frame.DpiX, plan.Dpi),
                                                              settings.ColorMode))];
        }, token);
    }

    public void CancelScan()
    {
        lock (_gate) _scan?.Cancel();
    }

    public Task CloseAsync()
    {
        CancelScan();
        return Task.CompletedTask;
    }

    /// <summary>A new cancellation source for the scan starting now; the previous one is let go.</summary>
    private CancellationToken BeginScan()
    {
        var next = new CancellationTokenSource();
        CancellationTokenSource? previous;
        lock (_gate)
        {
            previous = _scan;
            _scan = next;
        }
        previous?.Dispose();
        return next.Token;
    }

    /// <summary>Runs <paramref name="work"/> on the thread pool, turning what Windows throws into <see cref="ScanException"/>s.</summary>
    private Task<T> Run<T>(Func<CancellationToken, Task<T>> work, CancellationToken token) => Task.Run(async () =>
    {
        try
        {
            return await work(token).ConfigureAwait(false);
        }
        catch (ScanException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw ScanException.Cancelled();
        }
        catch (Exception e)
        {
            if (token.IsCancellationRequested) throw ScanException.Cancelled();
            throw WindowsScanErrors.ToScanException(e.HResult, e.Message);
        }
    });

    // MARK: - Capabilities

    /// <summary>
    /// Reads what the device's flatbed and feeder report (once, unless <paramref name="force"/>).
    /// A device that cannot say which sources it has fails (it is most likely gone); a source
    /// whose settings cannot be read is left out.
    /// </summary>
    private void ReadFacts(bool force)
    {
        if (_factsRead && !force) return;
        bool hasFlatbed = scanner.IsScanSourceSupported(ImageScannerScanSource.Flatbed);
        bool hasFeeder = scanner.IsScanSourceSupported(ImageScannerScanSource.Feeder);
        _flatbed = hasFlatbed ? Read<WindowsScanSourceFacts?>(FlatbedFacts, null) : null;
        _feeder = hasFeeder ? Read<WindowsScanSourceFacts?>(FeederFacts, null) : null;
        _factsRead = true;
        recordFacts([.. new[] { _flatbed, _feeder }.OfType<WindowsScanSourceFacts>()]);
    }

    private WindowsScanSourceFacts FlatbedFacts()
    {
        var c = scanner.FlatbedConfiguration;
        return new WindowsScanSourceFacts
        {
            Source = ScanSource.Flatbed,
            MinDpi = Read(() => (double)c.MinResolution.DpiX, 0),
            MaxDpi = Read(() => (double)c.MaxResolution.DpiX, 0),
            OpticalDpi = Read(() => (double)c.OpticalResolution.DpiX, 0),
            MinScanAreaInches = Read(() => Inches(c.MinScanArea), SizeD.Zero),
            MaxScanAreaInches = Read(() => Inches(c.MaxScanArea), SizeD.Zero),
            ColorModes = Supported<ImageScannerColorMode, WindowsScanColorMode>(c.IsColorModeSupported),
            Formats = Supported<ImageScannerFormat, WindowsScanFormat>(c.IsFormatSupported),
            PreviewSupported = Read(() => scanner.IsPreviewSupported(ImageScannerScanSource.Flatbed), false),
        };
    }

    private WindowsScanSourceFacts FeederFacts()
    {
        var c = scanner.FeederConfiguration;
        return new WindowsScanSourceFacts
        {
            Source = ScanSource.DocumentFeeder,
            MinDpi = Read(() => (double)c.MinResolution.DpiX, 0),
            MaxDpi = Read(() => (double)c.MaxResolution.DpiX, 0),
            OpticalDpi = Read(() => (double)c.OpticalResolution.DpiX, 0),
            MinScanAreaInches = Read(() => Inches(c.MinScanArea), SizeD.Zero),
            MaxScanAreaInches = Read(() => Inches(c.MaxScanArea), SizeD.Zero),
            ColorModes = Supported<ImageScannerColorMode, WindowsScanColorMode>(c.IsColorModeSupported),
            Formats = Supported<ImageScannerFormat, WindowsScanFormat>(c.IsFormatSupported),
            PreviewSupported = Read(() => scanner.IsPreviewSupported(ImageScannerScanSource.Feeder), false),
            CanScanDuplex = Read(() => c.CanScanDuplex, false),
            CanAutoDetectPageSize = Read(() => c.CanAutoDetectPageSize, false),
            PageSizes = [.. PaperSizes.All.Where(size => MediaSize(size) is { } media
                                                      && Read(() => c.IsPageSizeSupported(media, PrintOrientation.Portrait), false))],
        };
    }

    /// <summary>The WinRT media size for a paper size (<see cref="WindowsScanRequest.MediaSizeName"/>); null for Automatic.</summary>
    internal static PrintMediaSize? MediaSize(PaperSize size) =>
        WindowsScanRequest.MediaSizeName(size) is { } name && Enum.TryParse<PrintMediaSize>(name, out var media) ? media : null;

    /// <summary>The members of a WinRT enum <paramref name="isSupported"/> accepts, as their Core mirror (same values).</summary>
    private static List<TCore> Supported<TWinRt, TCore>(Func<TWinRt, bool> isSupported)
        where TWinRt : struct, Enum where TCore : struct, Enum =>
        [.. Enum.GetValues<TWinRt>().Where(value => Read(() => isSupported(value), false))
                .Select(value => (TCore)Enum.ToObject(typeof(TCore), Convert.ToInt32(value)))];

    private static SizeD Inches(Windows.Foundation.Size size) => new(size.Width, size.Height);

    /// <summary>A value the driver may refuse to report: <paramref name="fallback"/> then.</summary>
    private static T Read<T>(Func<T> read, T fallback)
    {
        try
        {
            return read();
        }
        catch (Exception)
        {
            return fallback;
        }
    }

    // MARK: - Scanning

    /// <summary>
    /// Sets the plan on the source's configuration; a setting the driver refuses is left as it
    /// is. Returns the resolution the driver reports it scans at; 0 when it reports none (a device
    /// that configures itself is not asked anything).
    /// </summary>
    private int Apply(WindowsScanPlan plan)
    {
        var resolution = new ImageScannerResolution { DpiX = plan.Dpi, DpiY = plan.Dpi };
        switch (plan.Source)
        {
            case WindowsScanSource.Flatbed:
            {
                var c = scanner.FlatbedConfiguration;
                if (plan.Format is { } format) Set(() => c.Format = (ImageScannerFormat)(int)format);
                if (plan.ColorMode is { } color) Set(() => c.ColorMode = (ImageScannerColorMode)(int)color);
                Set(() => c.DesiredResolution = resolution);
                if (plan.RegionInches is { } region) Set(() => c.SelectedScanRegion = Rect(region));
                return Actual(() => c.ActualResolution);
            }
            case WindowsScanSource.Feeder:
            {
                var c = scanner.FeederConfiguration;
                // Read before the session sets anything on the feeder.
                var defaults = _feederDefaults ??= new FeederArea(Read<PrintMediaSize?>(() => c.PageSize, null),
                                                                  Read<PrintOrientation?>(() => c.PageOrientation, null),
                                                                  Read<Windows.Foundation.Rect?>(() => c.SelectedScanRegion, null));
                if (plan.Format is { } format) Set(() => c.Format = (ImageScannerFormat)(int)format);
                if (plan.ColorMode is { } color) Set(() => c.ColorMode = (ImageScannerColorMode)(int)color);
                Set(() => c.DesiredResolution = resolution);
                // Every sheet in the feeder.
                Set(() => c.MaxNumberOfPages = 0);
                if (Read(() => c.CanScanDuplex, false)) Set(() => c.Duplex = plan.Duplex);
                // The feeder keeps an area from an earlier scan of the session: every plan states
                // one. One that cannot (the feeder's size is unknown) puts back the feeder's own
                // page size and area, the area last since a page size sets one, before measuring.
                if (!plan.SetsFeederArea)
                {
                    if (defaults.PageSize is { } ownSize) Set(() => c.PageSize = ownSize);
                    if (defaults.Orientation is { } ownOrientation) Set(() => c.PageOrientation = ownOrientation);
                    if (defaults.Region is { } ownArea) Set(() => c.SelectedScanRegion = ownArea);
                }
                if (plan.RegionFirst && plan.RegionInches is { } whole) Set(() => c.SelectedScanRegion = Rect(whole));
                if (plan.AutoDetectPageSize is { } detect) Set(() => c.AutoDetectPageSize = detect);
                if (plan.PageSize is { } size && MediaSize(size) is { } media)
                {
                    Set(() => c.PageSize = media);
                    Set(() => c.PageOrientation = PrintOrientation.Portrait);
                }
                if (!plan.RegionFirst && plan.RegionInches is { } region) Set(() => c.SelectedScanRegion = Rect(region));
                return Actual(() => c.ActualResolution);
            }
            default:
                return 0;
        }
    }

    private static Windows.Foundation.Rect Rect(RectD inches) => new(inches.X, inches.Y, inches.Width, inches.Height);

    /// <summary>The resolution the driver reports; 0 when it cannot be read.</summary>
    private static int Actual(Func<ImageScannerResolution> read) => WindowsScanRequest.Dpi(Read(() => (double)read().DpiX, 0));

    private static void Set(Action set)
    {
        try
        {
            set();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"Windows Scan: the scanner refused a setting: {e.Message.Trim()}");
        }
    }

    /// <summary>The device's own quick preview of the glass; null when it reports that it failed.</summary>
    private async Task<RgbaImage?> PreviewAsync(CancellationToken cancel)
    {
        using var stream = new InMemoryRandomAccessStream();
        var result = await scanner.ScanPreviewToStreamAsync(ImageScannerScanSource.Flatbed, stream).AsTask(cancel).ConfigureAwait(false);
        if (!result.Succeeded) return null;
        stream.Seek(0);
        using var copy = new MemoryStream();
        using (var read = stream.AsStreamForRead()) await read.CopyToAsync(copy, cancel).ConfigureAwait(false);
        return WpfImageCodec.Decode(copy.ToArray());
    }

    /// <summary>A page read back from a scanned file, with the horizontal resolution the file records.</summary>
    private readonly record struct ScannedFrame(RgbaImage Image, double DpiX);

    /// <summary>
    /// Scans with <paramref name="plan"/>'s source into a new folder in the private spool and reads
    /// the pages back, deleting the folder afterwards. A feeder batch that fails partway keeps the
    /// sheets already written (<see cref="WindowsScanRequest.AfterFailure"/>) and records why it
    /// stopped in <see cref="LastScanStop"/>. A folder that cannot be made is a failed scan.
    /// </summary>
    private async Task<List<ScannedFrame>> ScanFilesAsync(WindowsScanPlan plan, bool feeder, CancellationToken cancel)
    {
        string folder = Path.Combine(scratchRoot(), "winrt-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(folder);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw FolderFailed(e);
        }
        try
        {
            StorageFolder storage;
            try
            {
                storage = await StorageFolder.GetFolderFromPathAsync(folder).AsTask(cancel).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
            {
                throw FolderFailed(e);
            }
            // Windows counts the files written: pages, two of them per sheet when both sides are scanned.
            var progress = new Progress<uint>(count => ProgressHandler?.Invoke(new ScanProgress($"Transferred page {count}…")));
            ImageScannerScanResult result;
            try
            {
                result = await scanner.ScanFilesToFolderAsync((ImageScannerScanSource)(int)plan.Source, storage)
                                      .AsTask(cancel, progress).ConfigureAwait(false);
            }
            catch (Exception e) when (feeder && e is not OperationCanceledException && !cancel.IsCancellationRequested)
            {
                var error = WindowsScanErrors.ToScanException(e.HResult, e.Message);
                var kept = ReadableFiles(folder);
                switch (WindowsScanRequest.AfterFailure(error, kept.Count))
                {
                    case WindowsScanFailureOutcome.Finished:
                        return kept;
                    case WindowsScanFailureOutcome.Stopped:
                        _lastScanStop = ScanStop.From(error);
                        return kept;
                    default:
                        throw error;
                }
            }
            if (cancel.IsCancellationRequested) throw ScanException.Cancelled();
            var images = new List<ScannedFrame>();
            foreach (var file in result.ScannedFiles)
            {
                try
                {
                    images.AddRange(LoadFrames(file.Path));
                }
                catch (Exception e) when (e is IOException or NotSupportedException or FileFormatException
                                              or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
                {
                    throw ScanException.ScanFailed($"the scanned page could not be read ({e.Message.Trim()}).");
                }
            }
            return images;
        }
        finally
        {
            try
            {
                Directory.Delete(folder, recursive: true);
            }
            catch (Exception)
            {
                // Best effort: the page spool removes it when the app closes.
            }
        }
    }

    /// <summary>The app's own scan folder could not be made or opened: a failed scan, which says nothing about Windows Scan.</summary>
    private static ScanException FolderFailed(Exception e) =>
        ScanException.ScanFailed($"the app could not prepare its temporary folder for the scan ({e.Message.Trim()}).");

    /// <summary>The pages of the files a failed batch left behind, in scan order, without the one cut off.</summary>
    private static List<ScannedFrame> ReadableFiles(string folder)
    {
        var images = new List<ScannedFrame>();
        List<string> names;
        try
        {
            names = WindowsScanRequest.FileOrder(Directory.EnumerateFiles(folder).Select(Path.GetFileName).OfType<string>());
        }
        catch (Exception)
        {
            return images;
        }
        foreach (string name in names)
        {
            try
            {
                images.AddRange(LoadFrames(Path.Combine(folder, name)));
            }
            catch (Exception)
            {
                // A file the failure cut off.
            }
        }
        return images;
    }

    /// <summary>Every page of an image file: one for PNG, JPEG and BMP, each frame of a multi-page TIFF.</summary>
    private static List<ScannedFrame> LoadFrames(string path)
    {
        using var stream = File.OpenRead(path);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return [.. decoder.Frames.Select(frame => new ScannedFrame(WpfImageCodec.FromBitmapSource(frame), frame.DpiX))];
    }
}
