using System.Net.Http;
using System.Text;
using LazyScan.App.Services;
using LazyScan.Core;

namespace LazyScan.App.Scanning;

/// <summary>
/// Driverless network scanners over eSCL (AirScan), the protocol the macOS app reaches through
/// ImageCaptureCore's Bonjour support. Scanners are found two ways:
/// <list type="bullet">
/// <item>automatically, by DNS-SD (<see cref="EsclDiscovery"/>: _uscan._tcp and _uscans._tcp);</item>
/// <item>by address: the "Add scanner by address" dialog, which writes
/// %APPDATA%\Lazy Scan\escl-hosts.json (<see cref="EsclHostList"/>; entries written by
/// hand keep working).</item>
/// </list>
/// A scanner found both ways is one entry (matched by its eSCL UUID, which is also its
/// hardware id for <see cref="DeviceMerge"/>). HTTPS addresses are tried before plain ones;
/// a scanner's certificate is trusted the first time the app connects to it and pinned in
/// escl-trust.json (<see cref="EsclTrustStore"/>), and a changed certificate is refused with a
/// warning unless the user, having chosen the scanner, trusts the new one
/// (<see cref="ConfirmCertificate"/>). The protocol itself (Core: Escl/*.cs)
/// is tested there; this class finds devices and opens sessions.
///
/// ⚠ EXPERIMENTAL, UNTESTED AGAINST HARDWARE: checked against a local fake eSCL server.
/// </summary>
public sealed class EsclScannerBackend : IScannerBackend, IBackendDiagnostics, IScannerBackendDiagnostics
{
    /// <summary>How often addresses that did not answer are tried again while browsing (harnesses shorten it).</summary>
    internal TimeSpan ReprobeInterval { get; set; } = TimeSpan.FromSeconds(60);

    public event Action? DevicesChanged;

    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    /// <summary>
    /// Asks the user whether to trust a scanner certificate that changed since it was trusted;
    /// true trusts it. Called on the UI thread while a scanner the user chose is being opened
    /// (<see cref="OpenSessionAsync(string, bool)"/>). Without it, such scanners do not connect.
    /// </summary>
    public Func<EsclCertificateException, Task<bool>>? ConfirmCertificate { get; set; }

    private readonly EsclHostList _hosts;
    private readonly EsclTrustStore _trust;
    private readonly EsclDiscovery? _discovery;
    private readonly EsclClientOptions? _clientOptions;
    private readonly Func<byte[], RgbaImage> _decode;

    /// <summary>What the last check of each address added by hand found.</summary>
    private readonly Dictionary<ScannerAddress, ManualHost> _manual = [];
    /// <summary>Counts adds and removals per address, so a check that ran meanwhile is not applied.</summary>
    private readonly Dictionary<ScannerAddress, int> _manualEdits = [];
    private IReadOnlyList<EsclEndpoint> _discovered = [];
    private List<EsclDevice> _records = [];
    private string? _lastSignature;
    private int _browseGeneration;
    private bool _browsing;

    /// <summary>A scanner as listed: the addresses to reach it through, best first.</summary>
    private sealed record EsclDevice(ScannerInfo Info, string? Uuid, IReadOnlyList<ScannerAddress> Addresses,
                                     IReadOnlyList<ScannerAddress> ManualAddresses);

    /// <summary>An address added by hand and what answered there.</summary>
    private sealed class ManualHost(ScannerAddress address)
    {
        public ScannerAddress Address { get; } = address;
        /// <summary>The scanner answered (or presented a certificate to confirm): it is listed.</summary>
        public bool Listed { get; set; }
        public string? Name { get; set; }
        public string? Uuid { get; set; }
        /// <summary>Why it is not listed, for the diagnostics.</summary>
        public string? Problem { get; set; }
    }

    public EsclScannerBackend() : this(new EsclHostList(), new EsclTrustStore(), discover: true)
    {
    }

    /// <param name="hosts">The addresses added by hand (tests and harnesses point it elsewhere).</param>
    /// <param name="trust">The trusted certificates.</param>
    /// <param name="discover">Browse DNS-SD for scanners.</param>
    /// <param name="clientOptions">Timeouts and retry timing; null = defaults.</param>
    internal EsclScannerBackend(EsclHostList hosts, EsclTrustStore trust, bool discover,
                                EsclClientOptions? clientOptions = null)
    {
        _hosts = hosts;
        _trust = trust;
        _clientOptions = clientOptions;
        _decode = WpfImageCodec.Decode;
        if (discover)
        {
            _discovery = new EsclDiscovery();
            _discovery.Changed += () =>
            {
                _discovered = EsclEndpoint.Choose(_discovery.Services);
                Rebuild();
            };
        }
    }

    public void StartBrowsing()
    {
        if (_browsing) return;
        _browsing = true;
        int generation = ++_browseGeneration;
        _discovery?.Start();
        _ = ProbeManualHostsAsync(generation);
    }

    public void StopBrowsing()
    {
        _browsing = false;
        _browseGeneration++;
        _discovery?.Stop();
        _discovered = [];
        _manual.Clear();
        Rebuild();
    }

    // MARK: - Addresses added by hand

    /// <summary>
    /// Checks every address in escl-hosts.json, then keeps re-checking the ones that do not
    /// answer (and any added to the file meanwhile) every <see cref="ReprobeInterval"/>, so a
    /// scanner that was off at start appears once it is on. Ends when every address answers
    /// or browsing stops.
    /// </summary>
    private async Task ProbeManualHostsAsync(int generation)
    {
        bool onlyUnlisted = false;
        while (true)
        {
            var addresses = _hosts.Load();
            // Entries removed from the file since the last check go away.
            foreach (var gone in _manual.Keys.Where(a => !addresses.Contains(a)).ToList()) _manual.Remove(gone);
            var toCheck = addresses
                .Where(a => !onlyUnlisted || !_manual.TryGetValue(a, out var known) || !known.Listed)
                .ToList();
            var checks = toCheck.Select(a => (Address: a, Edit: EditOf(a), Check: ProbeAddressAsync(a))).ToList();
            foreach (var (address, edit, check) in checks)
            {
                var result = await check;
                if (generation != _browseGeneration) return;
                // Added again or removed (the dialog, the row menu) while this check ran: that is newer.
                if (EditOf(address) != edit) continue;
                _manual[address] = ToManualHost(address, result);
            }
            Rebuild();
            if (!_manual.Values.Any(h => !h.Listed)) return;
            await Task.Delay(ReprobeInterval);
            if (generation != _browseGeneration) return;
            onlyUnlisted = true;
        }
    }

    /// <summary>How often <paramref name="address"/> was added or removed (only compared, never reset).</summary>
    private int EditOf(ScannerAddress address) => _manualEdits.GetValueOrDefault(address);

    private void Edited(ScannerAddress address) => _manualEdits[address] = EditOf(address) + 1;

    /// <summary>
    /// <see cref="CheckAddressAsync(ScannerAddress, CancellationToken)"/> for an address in
    /// escl-hosts.json. A certificate seen for the first time is trusted, as on any first
    /// connection (see <see cref="OpenSessionAsync(string, bool)"/>), so the scanner is listed
    /// under its own name and UUID and joins its discovered entry; but when the UUID it reports
    /// belongs to a scanner trusted with another certificate, nothing is trusted and the
    /// address is listed as that scanner's, with the changed certificate to confirm.
    /// </summary>
    private async Task<EsclAddressCheck> ProbeAddressAsync(ScannerAddress address)
    {
        var result = await CheckAddressAsync(address, CancellationToken.None);
        if (result.Certificate is not { Verdict: EsclTrustVerdict.Unknown, CanTrust: true } certificate) return result;
        return await CheckAddressAsync(address, certificate.Fingerprint, CancellationToken.None);
    }

    private static ManualHost ToManualHost(ScannerAddress address, EsclAddressCheck result)
    {
        // A changed certificate still lists the scanner (choosing it asks the user), under the
        // UUID it was trusted with, so it stays one entry with its discovered one. (The name
        // in the pin is often just the address, so it is not used.)
        var previous = result.Certificate is { CanTrust: true } certificate ? certificate.Previous : null;
        return new ManualHost(address)
        {
            Listed = result.Capabilities is not null || result.Certificate is { CanTrust: true },
            Name = result.Capabilities?.MakeAndModel,
            Uuid = result.Capabilities?.Uuid ?? (previous?.DeviceUuid is { Length: > 0 } uuid ? uuid : null),
            Problem = result.Capabilities is not null ? null : result.Certificate?.Message ?? result.Error,
        };
    }

    /// <summary>
    /// Asks <paramref name="address"/> for its capabilities: what the "Add scanner by address"
    /// dialog checks before adding it. Never throws, except when cancelled.
    /// </summary>
    public Task<EsclAddressCheck> CheckAddressAsync(ScannerAddress address, CancellationToken token) =>
        CheckAddressAsync(address, firstUse: null, token);

    /// <summary>
    /// <see cref="CheckAddressAsync(ScannerAddress, CancellationToken)"/>, trusting
    /// <paramref name="firstUse"/>, the fingerprint of a certificate an earlier check found
    /// <see cref="EsclTrustVerdict.Unknown"/>, once the UUID the scanner reports shows it is
    /// not a changed certificate (otherwise the result is that <see cref="EsclTrustVerdict.Changed"/>
    /// certificate, and nothing is trusted).
    /// </summary>
    public async Task<EsclAddressCheck> CheckAddressAsync(ScannerAddress address, string? firstUse, CancellationToken token)
    {
        var validator = new EsclCertificateValidator(_trust, deviceUuid: null, address.ToString(), firstUse);
        using var client = NewClient(address, validator, address.ToString());
        try
        {
            var capabilities = await client.GetCapabilitiesAsync(token);
            validator.RememberDevice(capabilities.Uuid);
            return new EsclAddressCheck(address, capabilities, null, null);
        }
        catch (EsclCertificateException e)
        {
            return new EsclAddressCheck(address, null, e, null);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or FormatException)
        {
            string reason = e switch
            {
                FormatException => "it answered, but not like an eSCL scanner",
                OperationCanceledException => "it did not answer in time",
                HttpRequestException { StatusCode: { } status } => $"it answered HTTP {(int)status}",
                _ => e.Message,
            };
            return new EsclAddressCheck(address, null, null, $"No scanner answered at {address} ({reason}).");
        }
    }

    /// <summary>
    /// Adds a checked address to escl-hosts.json and lists its scanner. Returns the device id
    /// the scanner is listed under.
    /// </summary>
    public string AddAddress(ScannerAddress address, EsclCapabilities capabilities)
    {
        _hosts.Add(address);
        Edited(address);
        _manual[address] = new ManualHost(address)
        {
            Listed = true,
            Name = capabilities.MakeAndModel,
            Uuid = capabilities.Uuid,
        };
        Rebuild();
        return _records.First(r => r.ManualAddresses.Contains(address)).Info.Id;
    }

    /// <summary>The addresses added by hand that reach the scanner listed as <paramref name="deviceId"/>.</summary>
    public IReadOnlyList<ScannerAddress> ManualAddresses(string deviceId) =>
        _records.FirstOrDefault(r => r.Info.Id == deviceId)?.ManualAddresses ?? [];

    /// <summary>Removes an address from escl-hosts.json; its scanner stays listed while discovery still finds it.</summary>
    public void RemoveAddress(ScannerAddress address)
    {
        _hosts.Remove(address);
        Edited(address);
        _manual.Remove(address);
        Rebuild();
    }

    /// <summary>Trusts the certificate a check or connection was refused for.</summary>
    public void TrustCertificate(EsclCertificateException certificate, string? deviceUuid, string name)
    {
        _trust.Trust(certificate.Fingerprint, deviceUuid ?? certificate.DeviceUuid, certificate.Authority, name);
    }

    // MARK: - The device list

    /// <summary>
    /// One entry per scanner: discovered ones in discovery order, then the addresses added by
    /// hand (an address that reaches a discovered scanner, by UUID, joins its entry and is
    /// tried after the discovered addresses).
    /// </summary>
    private void Rebuild()
    {
        var records = new List<EsclDevice>();
        foreach (var endpoint in _discovered)
        {
            string id = "escl:" + (EsclTxtRecord.UuidKey(endpoint.Uuid) ?? endpoint.Key);
            if (records.Any(r => r.Info.Id == id)) continue;
            var info = new ScannerInfo(id, endpoint.Name, "Network", Backend: "escl",
                                       Model: endpoint.Txt.Model, HardwareId: endpoint.Uuid);
            records.Add(new EsclDevice(info, endpoint.Uuid, endpoint.Addresses, []));
        }
        foreach (var host in _manual.Values.Where(h => h.Listed))
        {
            string? uuidKey = EsclTxtRecord.UuidKey(host.Uuid);
            int index = uuidKey is null ? -1
                : records.FindIndex(r => EsclTxtRecord.UuidKey(r.Uuid) == uuidKey);
            if (index >= 0)
            {
                var found = records[index];
                // The scanner's own name (its capabilities) over the advertised one.
                var info = host.Name is { } name ? found.Info with { Name = name, Model = name } : found.Info;
                var addresses = found.Addresses.ToList();
                if (!addresses.Contains(host.Address)) addresses.Add(host.Address);
                records[index] = found with
                {
                    Info = info,
                    Addresses = addresses,
                    ManualAddresses = [.. found.ManualAddresses, host.Address],
                };
                continue;
            }
            string id = "escl:" + (uuidKey ?? host.Address.ToString());
            if (records.Any(r => r.Info.Id == id)) continue;
            records.Add(new EsclDevice(
                new ScannerInfo(id, host.Name ?? host.Address.Host, "Network", Backend: "escl",
                                Model: host.Name, HardwareId: host.Uuid),
                host.Uuid, [host.Address], [host.Address]));
        }
        _records = records;

        // Raised when the list or the diagnostics change (devices.txt is written from them).
        string signature = string.Join('\u001e', records.Select(r => r.Info.ToString())) + '\u001d' + DiagnosticsReport;
        if (signature == _lastSignature) return;
        _lastSignature = signature;
        _devices.Clear();
        _devices.AddRange(records.Select(r => r.Info));
        DevicesChanged?.Invoke();
    }

    // MARK: - Sessions

    /// <summary>A connection the app opens on its own: a changed certificate is not asked about (see <see cref="OpenSessionAsync(string, bool)"/>).</summary>
    public Task<IScannerSession> OpenSessionAsync(string deviceId) => OpenSessionAsync(deviceId, interactive: false);

    /// <summary>
    /// Connects through the scanner's addresses in order. A certificate seen for the first time
    /// is trusted and pinned (trust on first use) once the UUID the scanner reports shows it is
    /// not another certificate for a scanner trusted before. A certificate that changed since
    /// it was trusted is shown to the user (<see cref="ConfirmCertificate"/>) only when
    /// <paramref name="interactive"/>, i.e. the user just chose this scanner; the app never asks
    /// unprompted. Once trusted, the same address is tried again. A refused certificate fails
    /// the connection: it never falls back to a plain HTTP address, since anyone between the
    /// app and the scanner could cause that. Throws <see cref="ScanException"/>, or the
    /// <see cref="EsclCertificateException"/>.
    /// </summary>
    public async Task<IScannerSession> OpenSessionAsync(string deviceId, bool interactive)
    {
        var record = _records.FirstOrDefault(r => r.Info.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        var failures = new List<string>();
        foreach (var address in record.Addresses)
        {
            string? firstUse = null;
            bool trustedHere = false;
            while (true)
            {
                var validator = new EsclCertificateValidator(_trust, record.Uuid, record.Info.Name, firstUse);
                var client = NewClient(address, validator, record.Info.Name);
                try
                {
                    var caps = await client.GetCapabilitiesAsync();
                    validator.RememberDevice(caps.Uuid);
                    return new EsclScannerSession(record.Info, client, caps);
                }
                catch (EsclCertificateException e)
                {
                    client.Dispose();
                    if (e.CanTrust && e.Verdict == EsclTrustVerdict.Unknown && firstUse is null)
                    {
                        firstUse = e.Fingerprint;
                        continue;
                    }
                    // Trusting the same address twice in a row means the pin did not take: stop.
                    if (!trustedHere && e.CanTrust && e.Verdict == EsclTrustVerdict.Changed
                        && interactive && ConfirmCertificate is { } confirm && await confirm(e))
                    {
                        TrustCertificate(e, record.Uuid, record.Info.Name);
                        trustedHere = true;
                        continue;
                    }
                    throw;
                }
                catch (Exception e) when (e is HttpRequestException or OperationCanceledException or FormatException)
                {
                    client.Dispose();
                    failures.Add($"{address}: {(e is OperationCanceledException ? "no answer in time" : e.Message)}");
                    break;
                }
            }
        }
        throw ScanException.SessionFailed($"{record.Info.Name} did not answer ({string.Join("; ", failures)}).");
    }

    private EsclClient NewClient(ScannerAddress address, EsclCertificateValidator validator, string name) =>
        new(address.BaseUri, validator.CreateHandler(), _decode, name, validator, _clientOptions);

    // MARK: - Diagnostics

    /// <summary>
    /// The troubleshooter's view: how the automatic search goes, how many scanners it found,
    /// and each address added by hand that has been checked, with why nothing answers there.
    /// </summary>
    public DiscoverySnapshot AddStatus(DiscoverySnapshot snapshot) => snapshot with
    {
        Discovery = _discovery?.State ?? DiscoveryStatus.Unknown,
        DiscoveryDetail = _discovery?.Failure,
        DiscoveredCount = _discovered.Count,
        ManualHosts = [.. snapshot.ManualHosts,
                       .. _manual.Values.Select(host => new ManualHostStatus(host.Address.ToString(), host.Listed, host.Problem))],
    };

    /// <summary>
    /// The troubleshooter's Refresh: checks every address added by hand again now (the regular
    /// re-check of those that do not answer continues from there) and restarts an automatic
    /// search that Windows stopped or would not start (<see cref="EsclDiscovery.Restart"/>).
    /// Scanners already found stay listed meanwhile, and a search that works is left alone.
    /// </summary>
    public void Rescan()
    {
        if (!_browsing) return;
        _discovery?.Restart();
        // A new generation ends the previous check loop, which this one replaces.
        int generation = ++_browseGeneration;
        _ = ProbeManualHostsAsync(generation);
    }

    public string? DiagnosticsReport
    {
        get
        {
            var text = new StringBuilder();
            if (_discovery is not null)
            {
                text.Append($"eSCL network discovery (DNS-SD _uscan/_uscans): {_discovery.Status}\n");
                foreach (var service in _discovery.Services)
                {
                    var txt = EsclTxtRecord.Parse(service.TextAttributes);
                    text.Append($"  {(service.Secure ? "_uscans" : "_uscan")} \"{service.InstanceName}\" "
                                + $"host=\"{service.HostName ?? ""}\" port={service.Port} "
                                + $"addresses=\"{string.Join(",", service.Addresses)}\" ty=\"{txt.Model ?? ""}\" "
                                + $"uuid=\"{txt.Uuid ?? ""}\" rs=\"{txt.ResourcePath}\"\n");
                }
            }
            if (_manual.Count > 0)
            {
                text.Append("eSCL addresses added by hand:\n");
                foreach (var host in _manual.Values)
                {
                    text.Append($"  {host.Address}: "
                                + (host.Listed ? $"listed as \"{host.Name ?? host.Address.Host}\"" : $"not listed ({host.Problem})")
                                + "\n");
                }
            }
            return text.Length == 0 ? null : text.ToString();
        }
    }
}

/// <summary>The outcome of checking an address for an eSCL scanner; exactly one of the three is set.</summary>
/// <param name="Capabilities">The scanner answered.</param>
/// <param name="Certificate">The scanner's certificate needs the user's confirmation (or cannot be used).</param>
/// <param name="Error">Nothing usable answered; the text says so, for the user.</param>
public sealed record EsclAddressCheck(ScannerAddress Address, EsclCapabilities? Capabilities,
                                      EsclCertificateException? Certificate, string? Error);
