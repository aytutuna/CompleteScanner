using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;

namespace LazyScan.Core;

/// <summary>Where the companion keeps its files and what the platform provides.</summary>
public sealed record CompanionServiceOptions
{
    /// <summary>The settings folder (companion-devices.json, companion-networks.json).</summary>
    public required string SettingsDirectory { get; init; }
    /// <summary>The folder of the inbox and outbox ("Inbox", "Outbox" inside it).</summary>
    public required string DataDirectory { get; init; }
    /// <summary>The desktop's certificate with its private key (made on first use by the app).</summary>
    public required Func<X509Certificate2> Certificate { get; init; }
    /// <summary>Makes a new certificate with a new key (Reset pairing); null when the platform cannot.</summary>
    public Func<X509Certificate2>? RenewCertificate { get; init; }
    public required ICompanionNetworkSource Networks { get; init; }
    public IDnsSdAdvertiser Advertiser { get; init; } = new NoDnsSdAdvertiser();
    public Func<DateTimeOffset> Clock { get; init; } = () => DateTimeOffset.UtcNow;
    public string DesktopName { get; init; } = Environment.MachineName;
    public int PreferredPort { get; init; } = CompanionProtocol.DefaultPort;
    public CompanionServerOptions Server { get; init; } = new();
}

/// <summary>
/// The desktop's companion, put together: the paired phones and approved networks, the inbox and
/// outbox, the server's requests and the host that listens only while it is wanted (a phone is
/// paired, a pairing code is shown, or a phone that presented the code waits for the user's answer)
/// and only on trusted networks, and the cloud sync folder phones put documents in when they cannot
/// reach it (C2, <see cref="SyncFolderWatcher"/>), watched while the service runs. The app adds the platform's
/// pieces (certificate, networks, DNS-SD) and its window; everything here runs without a screen,
/// so the tests drive it end to end over loopback.
/// </summary>
public sealed class CompanionService : IAsyncDisposable
{
    private readonly CompanionServiceOptions _options;
    private readonly object _gate = new();
    private X509Certificate2? _certificate;
    private PairingSession? _pairing;
    private CancellationTokenSource? _pairingTimer;
    private SyncFolderWatcher? _syncWatcher;

    public CompanionService(CompanionServiceOptions options)
    {
        _options = options;
        Devices = new PairedDeviceStore(options.SettingsDirectory);
        TrustedNetworks = new TrustedNetworkStore(options.SettingsDirectory);
        Inbox = new CompanionInbox(Path.Combine(options.DataDirectory, "Inbox"));
        Outbox = new CompanionOutbox(Path.Combine(options.DataDirectory, "Outbox"));
        Limiter = new CompanionRateLimiter();
        Router = new CompanionRouter(Devices, Inbox, Outbox, Limiter, options.Clock)
        {
            DesktopName = () => options.DesktopName,
            // The session as it is (used or expired too), so a phone is told why its code no longer works.
            CurrentPairing = () =>
            {
                lock (_gate) return _pairing;
            },
        };
        Host = new CompanionHost(Certificate, Router, Limiter, options.Networks, TrustedNetworks.IsApproved, options.Advertiser,
                                 IsWanted, new CompanionHostOptions
                                 {
                                     PreferredPort = options.PreferredPort,
                                     InstanceName = options.DesktopName,
                                     HostName = options.DesktopName + ".local",
                                     DesktopId = () => Devices.DesktopId,
                                     Server = options.Server,
                                     Clock = options.Clock,
                                 });
        Router.DevicePaired += (_, device) =>
        {
            // The session is used now; it stays, so the code's token is answered as used.
            lock (_gate) _pairingTimer?.Cancel();
            DevicePaired?.Invoke(this, device);
            Changed?.Invoke(this, EventArgs.Empty);
        };
        Router.PackageReceived += (_, e) => PackageReceived?.Invoke(this, e);
        Router.DeviceRemoved += (_, _) => _ = RefreshQuietlyAsync();
        // A declined (or cut off) pairing no longer keeps the host listening.
        Router.ApprovalSettled += (_, _) => _ = RefreshQuietlyAsync();
        Host.StatusChanged += (_, _) => Changed?.Invoke(this, EventArgs.Empty);
        Devices.Changed += (_, _) => _ = RefreshQuietlyAsync();
        TrustedNetworks.Changed += (_, _) => _ = RefreshQuietlyAsync();
    }

    public PairedDeviceStore Devices { get; }
    public TrustedNetworkStore TrustedNetworks { get; }
    public CompanionInbox Inbox { get; }
    public CompanionOutbox Outbox { get; }
    public CompanionRateLimiter Limiter { get; }
    public CompanionRouter Router { get; }
    public CompanionHost Host { get; }

    public CompanionHostStatus Status => Host.Status;

    /// <summary>The pairing session open now; null when none is (closed, used, or expired).</summary>
    public PairingSession? Pairing
    {
        get
        {
            lock (_gate)
            {
                return _pairing?.StateAt(_options.Clock()) == PairingSessionState.Open ? _pairing : null;
            }
        }
    }

    /// <summary>
    /// A phone presented the pairing code and waits for the user's answer. Its session is used
    /// (<see cref="Pairing"/> is null), but the host keeps listening until the answer is in.
    /// </summary>
    public bool AwaitingApproval => Router.AwaitingApproval > 0;

    /// <summary>Raised (on any thread) when the status, the paired phones, the networks or the pairing changed.</summary>
    public event EventHandler? Changed;

    /// <summary>A phone was paired (on the request's thread).</summary>
    public event EventHandler<PairedDevice>? DevicePaired;

    /// <summary>
    /// A paired phone sent a document (on the request's thread), or put it in the sync folder (on a
    /// pool thread). Release it from <see cref="Inbox"/> once imported.
    /// </summary>
    public event EventHandler<CompanionPackageReceivedEventArgs>? PackageReceived;

    /// <summary>A file in the sync folder could not be read: the message for the status, once per file.</summary>
    public event EventHandler<string>? SyncFolderProblem;

    /// <summary>The cloud sync folder (C2); null when none is chosen.</summary>
    public string? SyncFolder => Devices.SyncFolder;

    /// <summary>The certificate's fingerprint (the pin phones keep).</summary>
    public byte[] Fingerprint => SpkiFingerprint.Of(Certificate().RawData)
                                 ?? throw new InvalidOperationException("The certificate cannot be read.");

    /// <summary>
    /// Starts following the networks: listens if a phone is paired and a trusted network is
    /// connected; watches the sync folder when one is chosen.
    /// </summary>
    public Task StartAsync()
    {
        WatchSyncFolder();
        return Host.RefreshAsync();
    }

    public Task RefreshAsync() => Host.RefreshAsync();

    /// <summary>
    /// Opens a pairing session (replacing an open one) and starts listening for it. Returns the
    /// pairing code to show; null when the desktop cannot listen now (<see cref="Status"/> says
    /// why). The session is then closed again: nothing listens for a code nobody can see.
    /// </summary>
    public async Task<PairingUri?> OpenPairingAsync()
    {
        CancellationTokenSource timer;
        lock (_gate)
        {
            _pairing?.Close();
            _pairingTimer?.Cancel();
            _pairing = new PairingSession(_options.Clock());
            _pairingTimer = timer = new CancellationTokenSource();
        }
        // When the code expires, the host stops listening again if no phone is paired.
        _ = Task.Delay(PairingSession.Lifetime + TimeSpan.FromSeconds(1), timer.Token)
                .ContinueWith(_ => RefreshQuietlyAsync(), TaskContinuationOptions.OnlyOnRanToCompletion);
        await Host.RefreshAsync().ConfigureAwait(false);
        var code = PairingCode();
        if (code is null)
        {
            // Not listening, so nothing needs stopping, and the status keeps its reason (no network,
            // no trusted network, or why listening failed) for the window to show.
            lock (_gate)
            {
                if (_pairingTimer == timer)
                {
                    _pairing?.Close();
                    _pairing = null;
                    timer.Cancel();
                }
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return code;
    }

    /// <summary>The code for the open pairing session at the addresses listened on now; null when there is none.</summary>
    public PairingUri? PairingCode()
    {
        var session = Pairing;
        var status = Host.Status;
        if (session is null || status.State != CompanionListenState.Listening || status.Port == 0) return null;
        return new PairingUri(Devices.DesktopId, PairingName(_options.DesktopName), SpkiFingerprint.Text(Fingerprint),
                              CodeAddresses(status.Endpoints), status.Port, session.Token);
    }

    /// <summary>Closes the pairing session; the host stops listening if no phone is paired.</summary>
    public async Task ClosePairingAsync()
    {
        lock (_gate)
        {
            _pairing?.Close();
            _pairing = null;
            _pairingTimer?.Cancel();
        }
        await Host.RefreshAsync().ConfigureAwait(false);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Unpairs a phone and deletes what waited for it; it gets 401 from now on.</summary>
    public async Task RemoveDeviceAsync(string id)
    {
        Devices.Remove(id);
        Outbox.RemoveDevice(id);
        await Host.RefreshAsync().ConfigureAwait(false);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Unpairs every phone and makes a new certificate with a new key, so a phone that kept the old
    /// pin can no longer connect; phones pair again with a new code.
    /// </summary>
    /// <remarks>
    /// The new certificate is made first: when that fails (the exception is passed on), nothing
    /// was changed and every phone stays paired.
    /// </remarks>
    public async Task ResetPairingAsync()
    {
        var renewed = _options.RenewCertificate?.Invoke();
        lock (_gate)
        {
            if (renewed is not null) _certificate = renewed;
            _pairing?.Close();
            _pairing = null;
            _pairingTimer?.Cancel();
        }
        foreach (var device in Devices.Devices) Outbox.RemoveDevice(device.Id);
        Devices.RemoveAll();
        await Host.RefreshAsync(restart: true).ConfigureAwait(false);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Chooses the cloud sync folder (null: none) and watches it from now on; false when that could not be saved.</summary>
    public bool SetSyncFolder(string? path)
    {
        if (!Devices.SetSyncFolder(path)) return false;
        WatchSyncFolder();
        return true;
    }

    /// <summary>Approves <paramref name="network"/> for receiving, or withdraws that; false when the approval could not be saved.</summary>
    public async Task<bool> SetNetworkApprovedAsync(CompanionNetwork network, bool approved)
    {
        bool saved = true;
        if (approved) saved = TrustedNetworks.Approve(network, _options.Clock());
        else TrustedNetworks.Revoke(network.Id);
        await Host.RefreshAsync().ConfigureAwait(false);
        Changed?.Invoke(this, EventArgs.Empty);
        return saved;
    }

    /// <summary>The checks for the phone window, with the firewall's verdict the app read.</summary>
    public CompanionSnapshot Snapshot(CompanionFirewallVerdict firewall = CompanionFirewallVerdict.Unknown,
                                      IReadOnlyList<string>? blockingRules = null)
    {
        var status = Host.Status;
        var networks = status.Networks.Count > 0 || status.State != CompanionListenState.Off
            ? status.Networks
            : [.. _options.Networks.Networks().Select(n => new CompanionNetworkState(n, TrustedNetworkPolicy.Trust(n, TrustedNetworks.IsApproved)))];
        return new CompanionSnapshot
        {
            Networks = networks,
            Listen = status.State,
            Port = status.Port,
            ListenError = status.Error,
            Firewall = firewall,
            BlockingRules = blockingRules ?? [],
            PairedCount = Devices.Count,
            PairingOpen = Pairing is not null || AwaitingApproval,
            SyncFolderChosen = Devices.SyncFolder is not null,
            PhonesQuietFor = Devices.Devices.Max(d => d.LastSeen) is { } seen ? _options.Clock() - seen : null,
        };
    }

    public async ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            _pairingTimer?.Cancel();
            _syncWatcher?.Dispose();
            _syncWatcher = null;
        }
        await Host.DisposeAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// The addresses a pairing code carries: IPv4 first, then IPv6 except link-local (its zone is
    /// this computer's), at most <see cref="PairingUri.MaxAddresses"/>.
    /// </summary>
    public static IReadOnlyList<string> CodeAddresses(IReadOnlyList<IPEndPoint> endpoints) =>
        [.. endpoints.Select(e => e.Address)
                     .Where(a => a.AddressFamily == AddressFamily.InterNetwork
                                 || (a.AddressFamily == AddressFamily.InterNetworkV6 && !a.IsIPv6LinkLocal))
                     .OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
                     .Select(a => a.AddressFamily == AddressFamily.InterNetworkV6 ? new IPAddress(a.GetAddressBytes()).ToString() : a.ToString())
                     .Distinct()
                     .Take(PairingUri.MaxAddresses)];

    /// <summary>The desktop's name as a code carries it: cleaned and cut to fit; "Computer" when nothing is left.</summary>
    public static string PairingName(string name)
    {
        string clean = PairedDeviceStore.CleanName(name);
        return clean.Length > 0 ? clean : "Computer";
    }

    /// <summary>Watches the folder chosen now, and no other.</summary>
    private void WatchSyncFolder()
    {
        string? folder = Devices.SyncFolder;
        lock (_gate)
        {
            if (_syncWatcher?.Folder == folder) return;
            _syncWatcher?.Dispose();
            _syncWatcher = null;
            if (folder is null) return;
            _syncWatcher = new SyncFolderWatcher(folder, Devices, Inbox);
            _syncWatcher.PackageReceived += (_, e) => PackageReceived?.Invoke(this, e);
            _syncWatcher.Problem += (_, message) => SyncFolderProblem?.Invoke(this, message);
            _syncWatcher.Start();
        }
    }

    private bool IsWanted() => Devices.Count > 0 || Pairing is not null || AwaitingApproval;

    private X509Certificate2 Certificate()
    {
        lock (_gate) return _certificate ??= _options.Certificate();
    }

    private async Task RefreshQuietlyAsync()
    {
        try
        {
            await Host.RefreshAsync().ConfigureAwait(false);
            Changed?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceError($"Could not update the companion: {e}");
        }
    }
}
