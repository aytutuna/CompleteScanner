using System.IO;
using LazyScan.Core;
using TwainException = LazyScan.Core.TwainException;

namespace LazyScan.App.Scanning.Twain;

/// <summary>
/// Scanners whose drivers speak TWAIN, through NTwain on a thread of their own
/// (<see cref="TwainThread"/>), so a driver that hangs never blocks the UI.
/// 64-bit: this process can load only 64-bit data sources (C:\Windows\twain_64); drivers
/// installed only in 32-bit form are reached through the 32-bit helper instead
/// (<see cref="Twain32ScannerBackend"/>).
///
/// TWAIN lists installed drivers, not connected scanners: a scanner that is off or unplugged
/// is still listed, and connecting to it reports it offline (CAP_DEVICEONLINE); the app
/// therefore never connects to a TWAIN-only scanner on its own. Without a
/// TWAIN Data Source Manager (TWAINDSM.dll, installed by scanner drivers and never shipped
/// with the app) the backend lists nothing and says why in the diagnostics.
///
/// Experimental, untested against real TWAIN drivers (see <see cref="NTwainDriver"/>).
/// </summary>
public sealed class TwainScannerBackend : IScannerBackend, IBackendDiagnostics, IScannerBackendDiagnostics
{
    /// <summary>Longest wait for the driver list (the data source manager loads every driver to ask its name).</summary>
    internal static readonly TimeSpan EnumerateTimeout = TimeSpan.FromSeconds(60);
    /// <summary>Longest wait for a driver to open (some show a message first, e.g. "scanner not found").</summary>
    internal static readonly TimeSpan OpenTimeout = TimeSpan.FromSeconds(60);
    /// <summary>Longest wait for a driver to report what it offers.</summary>
    internal static readonly TimeSpan CapabilitiesTimeout = TimeSpan.FromSeconds(60);
    /// <summary>
    /// Longest wait for a scan to get going: an earlier scan finishing its stop, disabling a
    /// source left enabled, negotiating and, without the driver's window, enabling (where a
    /// driver may show a message box). With the window, the user's time in it has no limit.
    /// </summary>
    internal static readonly TimeSpan ScanStartTimeout = TimeSpan.FromSeconds(90);
    /// <summary>Longest wait for a source to close.</summary>
    internal static readonly TimeSpan CloseTimeout = TimeSpan.FromSeconds(60);
    /// <summary>Waits before listing the drivers again after a failed listing; the last one repeats.</summary>
    private static readonly TimeSpan[] RetryDelays =
        [TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(5)];

    public event Action? DevicesChanged;

    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    private readonly Lazy<TwainThread> _thread = new(() => new TwainThread());
    /// <summary>The process-wide TWAIN session; only touched on the TWAIN thread.</summary>
    private readonly NTwainSessionHost _host = new();
    private SynchronizationContext? _context;
    /// <summary>Bumped by every Start/StopBrowsing; results of an older enumeration are dropped.</summary>
    private int _generation;
    private bool _browsing;
    /// <summary>Failed listings in a row (see <see cref="RetryDelays"/>).</summary>
    private int _failedListings;
    /// <summary>
    /// The generation a retry is waiting for, if any: a listing that failed after its time limit
    /// reports Failed twice (once on the time limit, once when it returns), and one retry covers both.
    /// </summary>
    private int? _retryPending;

    /// <summary>Whether TWAIN could be used, as of the last enumeration.</summary>
    public TwainAvailability Availability { get; private set; } = TwainAvailability.Unknown;

    public string? DiagnosticsReport { get; private set; }

    /// <summary>Driver files installed only for 32-bit apps, as of the last listing.</summary>
    private IReadOnlyList<string> _thirtyTwoBitOnly = [];

    /// <summary>The troubleshooter's view: whether TWAIN works, its drivers, and the 32-bit-only ones.</summary>
    public DiscoverySnapshot AddStatus(DiscoverySnapshot snapshot) => snapshot with
    {
        Twain = Availability switch
        {
            TwainAvailability.Available => TwainStatus.Available,
            TwainAvailability.NoDataSourceManager => TwainStatus.NotInstalled,
            TwainAvailability.Failed => TwainStatus.Failed,
            _ => TwainStatus.Unknown,
        },
        TwainDriverCount = _devices.Count,
        ThirtyTwoBitOnlyDrivers = _thirtyTwoBitOnly,
    };

    /// <summary>
    /// The troubleshooter's Refresh: lists the drivers again when TWAIN was missing or would not
    /// open. While TWAIN works the list stays as it is (TWAIN has no plug-and-play events, and
    /// listing again could disturb a scanner in use).
    /// </summary>
    public void Rescan()
    {
        if (!_browsing || Availability is TwainAvailability.Available or TwainAvailability.Unknown) return;
        _ = Enumerate(_generation);
    }

    internal TwainThread Worker => _thread.Value;

    /// <summary>
    /// Lists the installed drivers once (TWAIN has no plug-and-play events; drivers change only
    /// when installed, and one installed while the app runs appears after a restart). A listing
    /// that fails (the data source manager would not open, or a driver held it up past
    /// <see cref="EnumerateTimeout"/>) is tried again on a slow backoff, and a listing that
    /// finishes after its time limit is still used.
    /// </summary>
    public void StartBrowsing()
    {
        if (_browsing) return;
        _browsing = true;
        _context = SynchronizationContext.Current;
        _generation++;
        _failedListings = 0;
        _ = Enumerate(_generation);
    }

    public void StopBrowsing()
    {
        _browsing = false;
        _generation++;
        if (_devices.Count == 0) return;
        _devices.Clear();
        DevicesChanged?.Invoke();
    }

    private async Task Enumerate(int generation)
    {
        (TwainAvailability Availability, List<ScannerInfo> Sources, List<string> ThirtyTwoBitOnly) found;
        try
        {
            // A listing that overran is still published when it finally returns.
            found = await Worker.RunAsync(EnumerateOnTwainThread, EnumerateTimeout,
                                          whenAbandoned: late => Publish(generation, late)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN: listing the drivers failed: {e.Message}");
            found = (TwainAvailability.Failed, [], []);
        }
        Publish(generation, found);
    }

    private void Publish(int generation, (TwainAvailability Availability, List<ScannerInfo> Sources, List<string> ThirtyTwoBitOnly) found)
    {
        Post(() =>
        {
            if (generation != _generation) return;
            // A failure reported late does not replace a listing that worked in the meantime.
            if (found.Availability == TwainAvailability.Failed && Availability == TwainAvailability.Available) return;
            Availability = found.Availability;
            _thirtyTwoBitOnly = found.ThirtyTwoBitOnly;
            DiagnosticsReport = TwainDiagnostics.Report(found.Availability, [.. found.Sources.Select(s => s.Name)],
                                                        found.ThirtyTwoBitOnly);
            _devices.Clear();
            _devices.AddRange(found.Sources);
            // Raised even when the list is unchanged, so the diagnostics are written.
            DevicesChanged?.Invoke();
            if (found.Availability == TwainAvailability.Failed) RetryLater(generation);
            else _failedListings = 0;
        });
    }

    /// <summary>Lists the drivers again after a failed listing, waiting longer each time.</summary>
    private void RetryLater(int generation)
    {
        if (_retryPending == generation) return;
        _retryPending = generation;
        var delay = RetryDelays[Math.Min(_failedListings, RetryDelays.Length - 1)];
        _failedListings++;
        _ = Task.Delay(delay).ContinueWith(_ => Post(() =>
        {
            if (_retryPending == generation) _retryPending = null;
            if (generation != _generation || Availability != TwainAvailability.Failed) return;
            _ = Enumerate(generation);
        }), TaskScheduler.Default);
    }

    private void Post(Action action)
    {
        if (_context is { } context) context.Post(_ => action(), null);
        else lock (_devices) action();
    }

    private (TwainAvailability, List<ScannerInfo>, List<string>) EnumerateOnTwainThread()
    {
        var thirtyTwoBitOnly = ThirtyTwoBitOnlySources();
        var availability = _host.EnsureSession();
        if (availability != TwainAvailability.Available) return (availability, [], thirtyTwoBitOnly);
        var sources = _host.Sources()
            .Where(source => !string.IsNullOrWhiteSpace(source.Name))
            .Select(source => new ScannerInfo($"twain:{source.Name}", source.Name.Trim(), "TWAIN", Backend: "twain",
                                              Model: WiaScannerBackend.ModelOf(source.Manufacturer, source.Name)))
            .DistinctBy(info => info.Id)
            .ToList();
        return (availability, sources, thirtyTwoBitOnly);
    }

    /// <summary>Drivers installed only for 32-bit programs (C:\Windows\twain_32 files without a twain_64 counterpart).</summary>
    internal static List<string> ThirtyTwoBitOnlySources()
    {
        try
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            return TwainDiagnostics.ThirtyTwoBitOnlySources(DataSourceFiles(Path.Combine(windows, "twain_32")),
                                                            DataSourceFiles(Path.Combine(windows, "twain_64")));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }

        static IEnumerable<string> DataSourceFiles(string root) =>
            Directory.Exists(root)
                ? Directory.EnumerateFiles(root, "*.ds", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })
                    .Select(path => Path.GetRelativePath(root, path))
                    .ToList()
                : [];
    }

    public async Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        if (Availability == TwainAvailability.NoDataSourceManager)
        {
            throw ScanException.DeviceUnavailable(TwainDiagnostics.NoDataSourceManagerMessage);
        }
        string name = deviceId["twain:".Length..];
        // A source that opens after the time limit has nobody to use it: close it at once.
        var driver = await Worker.RunAsync(() => _host.Open(name), OpenTimeout, whenAbandoned: late => late.Close());
        return new TwainScannerSession(info, Worker, driver, driver.Close);
    }
}

/// <summary>An open TWAIN data source. All driver calls are queued to the backend's <see cref="TwainThread"/>.</summary>
/// <param name="driver">The open source (<see cref="NTwainDriver"/> in the app).</param>
/// <param name="close">Closes the source; run on the TWAIN thread.</param>
internal sealed class TwainScannerSession(ScannerInfo info, TwainThread thread, ITwainTransport driver, Action close)
    : IScannerSession, IDriverWindowOption
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }

    /// <summary>Written on the TWAIN thread before the scan task completes, read after it.</summary>
    private volatile ScanStop? _lastScanStop;
    public ScanStop? LastScanStop => _lastScanStop;

    /// <summary>Cleared on the calling thread when a scan starts, set there once its pages are in.</summary>
    private bool? _lastScanDuplex;
    public bool? LastScanDuplex => _lastScanDuplex;

    private TwainDeviceCaps? _caps;
    /// <summary>Set once a memory transfer came in a format the app cannot read.</summary>
    private volatile bool _preferNative;
    private CancellationTokenSource? _scanCancellation;
    private bool _closed;

    /// <summary>Longest wait for a scan to get going (<see cref="TwainScannerBackend.ScanStartTimeout"/>).</summary>
    internal TimeSpan StartTimeout { get; init; } = TwainScannerBackend.ScanStartTimeout;

    public bool DriverWindowOptional => _caps?.UIControllable ?? true;
    public bool UseDriverWindow { get; set; }

    public async Task<ScannerCapabilities> GetCapabilitiesAsync()
    {
        var caps = await ReadCapabilities();
        return TwainScanRequests.Capabilities(caps);
    }

    private async Task<TwainDeviceCaps> ReadCapabilities()
    {
        var caps = await thread.RunAsync(() =>
        {
            try
            {
                return driver.ReadCapabilities();
            }
            catch (TwainException e)
            {
                throw TwainErrors.ToScanException(e);
            }
        }, TwainScannerBackend.CapabilitiesTimeout);
        // TWAIN lists installed drivers: the scanner itself may be off or unplugged.
        if (caps.Online == false) throw ScanException.ForProblem(ScannerProblem.Offline, "TWAIN CAP_DEVICEONLINE");
        _caps = caps;
        return caps;
    }

    public async Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        var caps = _caps ?? await ReadCapabilities();
        if (!caps.HasFlatbed) throw ScanException.Unsupported("This scanner has no flatbed to preview.");
        if (!caps.UIControllable)
        {
            throw ScanException.Unsupported("This scanner's driver always shows its own window, so it cannot preview.");
        }
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        var pages = (await Acquire(TwainScanRequests.ForOverview(caps, _preferNative))).PagesOrThrow();
        _lastScanStop = null;
        return pages[0].Image;
    }

    public async Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _lastScanStop = null;
        _lastScanDuplex = null;
        var caps = _caps ?? await ReadCapabilities();
        var request = TwainScanRequests.ForScan(settings, selection, caps, UseDriverWindow, _preferNative);
        ProgressHandler?.Invoke(new ScanProgress(request.ShowDriverWindow
            ? "Choose the settings in the scanner's window, then start the scan there…"
            : "Scanning…"));
        var result = await Acquire(request);
        var pages = result.PagesOrThrow();
        // Two-sided only when the source confirmed it (TwainScanResult.Duplex); a feeder
        // without CAP_DUPLEX is not asked (TwainScanRequests.ForScan).
        if (request.Feeder && settings.Duplex == DuplexMode.Both) _lastScanDuplex = result.Duplex;
        return pages.Select(page => new ScannedPage(page.Image, page.Dpi, page.ColorMode)).ToList();
    }

    /// <summary>
    /// Runs one acquisition on the TWAIN thread. Getting the scan going has a time limit
    /// (<see cref="StartTimeout"/>; a driver can block there behind a message box), after
    /// which the scan loop's own limits apply. Cancelling returns at once; the scan loop then
    /// stops the source in the background (the next call waits its turn behind it). The result
    /// carries the pages or the error (<see cref="TwainScanResult.PagesOrThrow"/>).
    /// </summary>
    private async Task<TwainScanResult> Acquire(TwainScanRequest request)
    {
        var cancellation = new CancellationTokenSource();
        var previous = Interlocked.Exchange(ref _scanCancellation, cancellation);
        previous?.Cancel();
        var token = cancellation.Token;
        TwainScanResult result;
        try
        {
            result = await thread.RunWithStartLimitAsync(started =>
            {
                // A source left enabled by a scan whose driver got stuck has to be disabled first.
                if (!driver.Disable(TwainLoopTimeouts.Default.Stop)) throw TwainThread.NotResponding();
                return TwainScanLoop.Run(driver, request, TwainLoopTimeouts.Default, token,
                                         progress => ProgressHandler?.Invoke(progress), started);
            }, StartTimeout, token);
        }
        catch
        {
            // A scan given up on must not go on unseen once the driver answers: it stops as soon as it starts.
            cancellation.Cancel();
            throw;
        }
        if (result.UseNativeTransfers) _preferNative = true;
        if (result.Stop is { } stop) _lastScanStop = stop;
        return result;
    }

    public void CancelScan() => _scanCancellation?.Cancel();

    /// <summary>
    /// Queues closing the source and returns at once: a stuck driver must not hold up
    /// switching scanners. Whatever the TWAIN thread does next waits until the close is done.
    /// </summary>
    public Task CloseAsync()
    {
        if (_closed) return Task.CompletedTask;
        _closed = true;
        CancelScan();
        _ = CloseOnTwainThread();
        return Task.CompletedTask;
    }

    private async Task CloseOnTwainThread()
    {
        try
        {
            // A close that hangs wedges the thread, so later TWAIN calls say "not responding" at once.
            await thread.RunAsync(() =>
            {
                close();
                return true;
            }, TwainScannerBackend.CloseTimeout);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN: closing the source failed: {e.Message}");
        }
    }
}
