using LazyScan.Core;

namespace LazyScan.App.Scanning.Twain;

/// <summary>
/// Scanners whose TWAIN drivers are installed only for 32-bit programs, which this 64-bit app
/// cannot load itself. They are reached through a small 32-bit helper process
/// (LazyScan.TwainHelper.exe, <see cref="TwainHelperProcess"/>): the same scan logic
/// (<see cref="TwainScanLoop"/> in <see cref="TwainScannerSession"/>) runs here against a
/// transport that forwards each TWAIN call to the helper (<see cref="RemoteTwainTransport"/>).
///
/// The helper is started only when such a driver is installed (a C:\Windows\twain_32 data
/// source without a twain_64 counterpart), once per app session, and again after it crashed or
/// stopped answering. A listing that fails for a reason that may pass (the helper was slow to
/// start, the Data Source Manager would not open) is tried again on the same slow backoff as
/// <see cref="TwainScannerBackend"/>, and one that finishes after its time limit is still used.
/// Its sources are listed as TWAIN connections named "… (32-bit driver)",
/// leaving out those a 64-bit driver also offers and the WIA bridge
/// (<see cref="TwainHelperSources.Usable"/>); <see cref="DeviceMerge"/> joins them to the other
/// connections of the same scanner and ranks them last.
///
/// Experimental, untested against real 32-bit drivers: checked with the helper's stand-in
/// scanners only (LazyScan.App.Tests, TwainHelperTests).
/// </summary>
public sealed class Twain32ScannerBackend : IScannerBackend, IBackendDiagnostics, IScannerBackendDiagnostics, IDisposable
{
    public event Action? DevicesChanged;

    private readonly TwainScannerBackend? _sixtyFourBit;
    private readonly Func<IReadOnlyList<string>> _thirtyTwoBitOnlyFiles;
    private readonly TwainHelperProcess _helper;
    private readonly TwainHelperTimeouts _timeouts;
    private readonly TimeSpan _connectTimeout;
    private readonly Lazy<TwainThread> _thread = new(() => new TwainThread());
    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    /// <summary>Everything the helper's Data Source Manager listed last time.</summary>
    private List<TwainHelperSource> _listed = [];
    private string? _statusDetail;
    /// <summary>Why the helper cannot run at all, as of the last listing (<see cref="TwainHelperProcess.PermanentFailure"/>).</summary>
    private string? _cannotRun;
    private SynchronizationContext? _context;
    private int _generation;
    private bool _browsing;
    private volatile bool _disposed;
    /// <summary>Failed listings in a row (see <see cref="RetryDelays"/>).</summary>
    private int _failedListings;
    /// <summary>The generation a retry is waiting for, if any (a listing that overran reports Failed twice).</summary>
    private int? _retryPending;

    /// <summary>Waits before listing again after a failed listing; the last one repeats.</summary>
    internal IReadOnlyList<TimeSpan> RetryDelays { get; init; } =
        [TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(5)];

    /// <summary>Whether the helper works, as of the last listing.</summary>
    public TwainHelperStatus Status { get; private set; } = TwainHelperStatus.Unknown;

    public string? DiagnosticsReport { get; private set; }

    /// <param name="sixtyFourBit">The in-process backend: sources it lists are not listed again here.</param>
    public Twain32ScannerBackend(TwainScannerBackend? sixtyFourBit = null)
        : this(sixtyFourBit, TwainHelperOptions.Default, TwainScannerBackend.ThirtyTwoBitOnlySources)
    {
    }

    /// <param name="thirtyTwoBitOnlyFiles">The drivers installed only for 32-bit programs; the helper starts only when there are any.</param>
    internal Twain32ScannerBackend(TwainScannerBackend? sixtyFourBit, TwainHelperOptions options,
                                   Func<IReadOnlyList<string>> thirtyTwoBitOnlyFiles)
    {
        _sixtyFourBit = sixtyFourBit;
        _thirtyTwoBitOnlyFiles = thirtyTwoBitOnlyFiles;
        _helper = new TwainHelperProcess(options);
        _timeouts = options.Limits;
        _connectTimeout = options.ConnectTimeout;
        if (_sixtyFourBit is not null) _sixtyFourBit.DevicesChanged += OnSixtyFourBitChanged;
    }

    internal TwainThread Worker => _thread.Value;

    /// <summary>The helper's process id while it runs (diagnostics and tests).</summary>
    internal int? HelperProcessId => _helper.ProcessId;

    /// <summary>
    /// Longest wait for a call that may first have to start the helper: its own worst case
    /// (connecting, the handshake, then the call) and a margin for starting the process.
    /// </summary>
    private TimeSpan StartingLimit(TimeSpan call) => _connectTimeout + _timeouts.Hello + call + TimeSpan.FromSeconds(10);

    /// <summary>The helper's Data Source Manager lists a driver the app can use (the 64-bit backend may list it too).</summary>
    private bool Reached => Status == TwainHelperStatus.Available && TwainHelperSources.Usable(_listed, []).Count > 0;

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

    /// <summary>
    /// The troubleshooter's Refresh: lists again unless the helper reaches a driver (one may have
    /// been installed or repaired), forgetting why it could not run (a runtime may have been installed).
    /// </summary>
    public void Rescan()
    {
        if (!_browsing || Status == TwainHelperStatus.Unknown || Reached) return;
        _helper.Retry();
        _ = Enumerate(_generation);
    }

    /// <summary>
    /// What the helper adds to the troubleshooter's view. When it reaches a driver, the 32-bit
    /// drivers are no longer a problem (which file a source came from is not known, so all of
    /// them), its sources count as TWAIN drivers, and TWAIN counts as working even without a
    /// 64-bit Data Source Manager. Otherwise the drivers stay a problem, with why the helper does
    /// not reach them (<see cref="TwainDiagnostics.HelperProblem"/>).
    /// </summary>
    public DiscoverySnapshot AddStatus(DiscoverySnapshot snapshot)
    {
        if (Status is TwainHelperStatus.NotNeeded or TwainHelperStatus.Unknown) return snapshot;
        if (!Reached)
        {
            return snapshot.ThirtyTwoBitOnlyDrivers.Count == 0
                ? snapshot
                : snapshot with { ThirtyTwoBitHelperProblem = TwainDiagnostics.HelperProblem(Status, _cannotRun, reachedAny: false) };
        }
        return snapshot with
        {
            ThirtyTwoBitOnlyDrivers = [],
            TwainDriverCount = snapshot.TwainDriverCount + _devices.Count,
            Twain = _devices.Count > 0 ? TwainStatus.Available : snapshot.Twain,
        };
    }

    private async Task Enumerate(int generation)
    {
        IReadOnlyList<string> files;
        try
        {
            files = _thirtyTwoBitOnlyFiles();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN helper: looking for 32-bit drivers failed: {e.Message}");
            files = [];
        }
        if (files.Count == 0)
        {
            // Nothing to reach: the helper is not started.
            Publish(generation, TwainHelperStatus.NotNeeded, null, [], cannotRun: null);
            return;
        }
        TwainHelperSourceList list;
        try
        {
            // A listing that overran is still published when it finally returns.
            list = await Worker.RunAsync(ListOnTwainThread, StartingLimit(_timeouts.ListSources),
                                         whenAbandoned: late => Publish(generation, late)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN helper: listing the 32-bit drivers failed: {e.Message}");
            Publish(generation, TwainHelperStatus.Failed, e.Message, [], _helper.PermanentFailure);
            return;
        }
        Publish(generation, list);
    }

    /// <summary>Takes in what the helper's Data Source Manager listed (internal for tests).</summary>
    internal void Publish(int generation, TwainHelperSourceList list)
    {
        var status = list.Availability switch
        {
            TwainAvailability.Available => TwainHelperStatus.Available,
            TwainAvailability.NoDataSourceManager => TwainHelperStatus.NoDataSourceManager,
            _ => TwainHelperStatus.Failed,
        };
        string? detail = status == TwainHelperStatus.Failed
            ? "the helper started, but its TWAIN Data Source Manager would not open"
            : null;
        Publish(generation, status, detail, [.. list.Sources], cannotRun: null);
    }

    /// <summary>Lists the helper's sources; a helper that has nothing to offer is stopped again.</summary>
    private TwainHelperSourceList ListOnTwainThread()
    {
        var connection = _helper.Connect();
        var reply = connection.Request(new TwainHelperListSources(), _timeouts.ListSources);
        var list = reply switch
        {
            TwainHelperSourceList found => found,
            TwainHelperFailure failure => throw failure.Error.ToException(),
            _ => throw ScanException.SessionFailed($"the 32-bit TWAIN helper answered with {reply.Type}."),
        };
        if (list.Availability != TwainAvailability.Available || TwainHelperSources.Usable(list.Sources, []).Count == 0)
        {
            _helper.Shutdown();
        }
        return list;
    }

    private void Publish(int generation, TwainHelperStatus status, string? detail, List<TwainHelperSource> sources,
                         string? cannotRun)
    {
        Post(() =>
        {
            if (generation != _generation) return;
            // A failure reported late does not replace a listing that worked in the meantime.
            if (status == TwainHelperStatus.Failed && Reached) return;
            Status = status;
            _statusDetail = detail;
            _cannotRun = cannotRun;
            _listed = sources;
            Rebuild(force: true);
            // Trying again cannot help a helper that cannot run at all; Refresh can, after a fix.
            if (status != TwainHelperStatus.Failed) _failedListings = 0;
            else if (cannotRun is null) RetryLater(generation);
        });
    }

    /// <summary>Lists again after a failed listing, waiting longer each time.</summary>
    private void RetryLater(int generation)
    {
        if (_disposed || _retryPending == generation) return;
        _retryPending = generation;
        var delay = RetryDelays[Math.Min(_failedListings, RetryDelays.Count - 1)];
        _failedListings++;
        _ = Task.Delay(delay).ContinueWith(_ => Post(() =>
        {
            if (_retryPending == generation) _retryPending = null;
            if (_disposed || generation != _generation || Status != TwainHelperStatus.Failed) return;
            _ = Enumerate(generation);
        }), TaskScheduler.Default);
    }

    private void OnSixtyFourBitChanged() => Post(() =>
    {
        if (_browsing) Rebuild(force: false);
    });

    /// <summary>The device list from the helper's sources, without those the 64-bit backend lists.</summary>
    private void Rebuild(bool force)
    {
        var sixtyFourBit = _sixtyFourBit?.Devices.Where(d => d.Backend == "twain").Select(d => d.Name).ToList() ?? [];
        var usable = Status == TwainHelperStatus.Available ? TwainHelperSources.Usable(_listed, sixtyFourBit) : [];
        var found = usable.Select(TwainHelperSources.Info).ToList();
        DiagnosticsReport = TwainDiagnostics.HelperReport(Status, _statusDetail, [.. _listed.Select(s => s.Name)],
                                                          usable.Select(s => s.Name).ToHashSet());
        if (!force && _devices.SequenceEqual(found)) return;
        _devices.Clear();
        _devices.AddRange(found);
        // Raised even when the list is unchanged after a listing, so the diagnostics are written.
        DevicesChanged?.Invoke();
    }

    private void Post(Action action)
    {
        if (_context is { } context) context.Post(_ => action(), null);
        else lock (_devices) action();
    }

    public async Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        string name = TwainHelperSources.SourceName(deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        var transport = new RemoteTwainTransport(_helper.Connect, name, _timeouts);
        // A source that opens after the time limit has nobody to use it: close it at once.
        await Worker.RunAsync(() =>
        {
            transport.Open();
            return transport;
        }, StartingLimit(_timeouts.Open), whenAbandoned: late => late.Close());
        var session = new TwainScannerSession(info, Worker, transport, transport.Close);
        transport.ProgressHandler = progress => session.ProgressHandler?.Invoke(progress);
        return session;
    }

    /// <summary>Ends the helper (the app is closing).</summary>
    public void Dispose()
    {
        _disposed = true;
        if (_sixtyFourBit is not null) _sixtyFourBit.DevicesChanged -= OnSixtyFourBitChanged;
        _helper.Dispose();
    }
}
