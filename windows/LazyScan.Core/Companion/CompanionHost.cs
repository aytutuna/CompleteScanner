using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;

namespace LazyScan.Core;

/// <summary>The networks this computer is connected to, and when they change (Windows: the Network List Manager).</summary>
public interface ICompanionNetworkSource
{
    /// <summary>The connected networks with their adapters. Any thread; never throws (empty when unknown).</summary>
    IReadOnlyList<CompanionNetwork> Networks();

    /// <summary>Raised (on any thread) when a network connects, disconnects, or changes category or addresses.</summary>
    event EventHandler? Changed;
}

/// <summary>A DNS-SD service to advertise on one interface.</summary>
/// <param name="InstanceName">The service instance's name (the computer's name).</param>
/// <param name="HostName">The host name its address record uses ("AYTU-PC.local").</param>
/// <param name="InterfaceIndex">The interface to advertise on, and only there.</param>
/// <param name="Address">The interface's IPv4 address for the host record; null for none.</param>
public sealed record DnsSdRegistration(string InstanceName, string HostName, int Port, int InterfaceIndex, IPAddress? Address,
                                       IReadOnlyList<KeyValuePair<string, string>> Txt)
{
    public string ServiceType => CompanionProtocol.ServiceType;

    public bool Equals(DnsSdRegistration? other) =>
        other is not null && InstanceName == other.InstanceName && HostName == other.HostName && Port == other.Port
        && InterfaceIndex == other.InterfaceIndex && Equals(Address, other.Address) && Txt.SequenceEqual(other.Txt);

    public override int GetHashCode() => HashCode.Combine(InstanceName, Port, InterfaceIndex);
}

/// <summary>Advertises the companion service by DNS-SD (Windows: DnsServiceRegister); tests stand in for it.</summary>
public interface IDnsSdAdvertiser
{
    /// <summary>Starts advertising; disposing the result withdraws it. Throws when the system refuses.</summary>
    IDisposable Register(DnsSdRegistration registration);
}

/// <summary>Advertises nothing (no DNS-SD; phones use the address from the pairing code).</summary>
public sealed class NoDnsSdAdvertiser : IDnsSdAdvertiser
{
    public IDisposable Register(DnsSdRegistration registration) => new Nothing();

    private sealed class Nothing : IDisposable
    {
        public void Dispose() { }
    }
}

/// <summary>Whether the desktop receives from phones, or why not.</summary>
public enum CompanionListenState
{
    /// <summary>No phone is paired and no pairing code is shown: nothing listens.</summary>
    Off,
    /// <summary>Not connected to any network.</summary>
    Offline,
    /// <summary>Connected, but to no network the desktop receives on.</summary>
    NoTrustedNetwork,
    Listening,
    /// <summary>Listening failed (see <see cref="CompanionHostStatus.Error"/>).</summary>
    Failed,
    /// <summary>Another instance of the app receives (set by the app, never by the host).</summary>
    Elsewhere,
}

/// <summary>What the host is doing, and on which networks.</summary>
public sealed record CompanionHostStatus(CompanionListenState State, IReadOnlyList<CompanionNetworkState> Networks,
                                         IReadOnlyList<IPEndPoint> Endpoints, string? Error = null)
{
    public static CompanionHostStatus Initial { get; } = new(CompanionListenState.Off, [], []);

    /// <summary>The port listened on; 0 when not listening.</summary>
    public int Port => Endpoints.Count > 0 ? Endpoints[0].Port : 0;

    public bool Equals(CompanionHostStatus? other) =>
        other is not null && State == other.State && Networks.SequenceEqual(other.Networks)
        && Endpoints.SequenceEqual(other.Endpoints) && Error == other.Error;

    public override int GetHashCode() => HashCode.Combine(State, Networks.Count, Endpoints.Count, Error);
}

/// <summary>How the host listens and advertises.</summary>
public sealed record CompanionHostOptions
{
    /// <summary>The port tried first (after the one used last); 0 lets the system pick.</summary>
    public int PreferredPort { get; init; } = CompanionProtocol.DefaultPort;
    public string InstanceName { get; init; } = Environment.MachineName;
    public string HostName { get; init; } = Environment.MachineName + ".local";
    /// <summary>The desktop's id for the TXT record, asked for when advertising starts.</summary>
    public Func<string> DesktopId { get; init; } = () => "";
    public CompanionServerOptions Server { get; init; } = new();
    /// <summary>The clock the server's rate limits read (the router's).</summary>
    public Func<DateTimeOffset> Clock { get; init; } = () => DateTimeOffset.UtcNow;
}

/// <summary>
/// Starts and stops the companion server as the networks change: it listens only while it is
/// wanted (a phone is paired, or a pairing code is shown) and only on the addresses of trusted
/// networks (<see cref="TrustedNetworkPolicy"/>), and advertises by DNS-SD only on those networks'
/// interfaces and only while listening. When the last trusted network goes away (or turns Public
/// without approval) the server stops and every advertisement is withdrawn. Refreshes run one at a
/// time; call <see cref="RefreshAsync"/> whenever something it depends on changed.
/// </summary>
public sealed class CompanionHost : IAsyncDisposable
{
    private readonly Func<X509Certificate2> _certificate;
    private readonly CompanionRouter _router;
    private readonly CompanionRateLimiter _limiter;
    private readonly ICompanionNetworkSource _networks;
    private readonly Func<string, bool> _isApproved;
    private readonly IDnsSdAdvertiser _advertiser;
    private readonly Func<bool> _wanted;
    private readonly CompanionHostOptions _options;
    private readonly SemaphoreSlim _refresh = new(1, 1);
    private readonly Dictionary<int, (DnsSdRegistration Registration, IDisposable Handle)> _advertised = [];
    private CompanionServer? _server;
    private IReadOnlyList<LocalSubnet> _listening = [];
    private int _lastPort;
    private bool _disposed;

    public CompanionHost(Func<X509Certificate2> certificate, CompanionRouter router, CompanionRateLimiter limiter,
                         ICompanionNetworkSource networks, Func<string, bool> isApproved, IDnsSdAdvertiser advertiser,
                         Func<bool> wanted, CompanionHostOptions? options = null)
    {
        _certificate = certificate;
        _router = router;
        _limiter = limiter;
        _networks = networks;
        _isApproved = isApproved;
        _advertiser = advertiser;
        _wanted = wanted;
        _options = options ?? new CompanionHostOptions();
        _networks.Changed += Networks_Changed;
    }

    public CompanionHostStatus Status { get; private set; } = CompanionHostStatus.Initial;

    /// <summary>Raised (on the refreshing thread) when <see cref="Status"/> changed.</summary>
    public event EventHandler? StatusChanged;

    /// <summary>What is advertised now, by interface (tests, diagnostics).</summary>
    public IReadOnlyList<DnsSdRegistration> Advertised
    {
        get
        {
            lock (_advertised) return [.. _advertised.Values.Select(v => v.Registration)];
        }
    }

    /// <summary>Checks the networks and what is wanted, then starts, moves or stops the server and the advertisements.</summary>
    public async Task RefreshAsync(bool restart = false)
    {
        await _refresh.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed) return;
            var networks = _networks.Networks();
            var states = networks.Select(n => new CompanionNetworkState(n, TrustedNetworkPolicy.Trust(n, _isApproved))).ToList();
            var addresses = TrustedNetworkPolicy.ListenAddresses(networks, _isApproved);
            var state = !_wanted() ? CompanionListenState.Off
                        : networks.Count == 0 ? CompanionListenState.Offline
                        : addresses.Count == 0 ? CompanionListenState.NoTrustedNetwork
                        : CompanionListenState.Listening;
            string? error = null;
            if (state != CompanionListenState.Listening)
            {
                await StopServerAsync().ConfigureAwait(false);
            }
            else if (restart || _server is null || !SameAddresses(_listening, addresses))
            {
                await StopServerAsync().ConfigureAwait(false);
                error = Start(addresses);
                if (error is not null) state = CompanionListenState.Failed;
            }
            UpdateAdvertisements(state == CompanionListenState.Listening ? states : []);
            var status = new CompanionHostStatus(state, states, _server?.LocalEndpoints ?? [], error);
            if (!status.Equals(Status))
            {
                Status = status;
                StatusChanged?.Invoke(this, EventArgs.Empty);
            }
        }
        finally
        {
            _refresh.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        _networks.Changed -= Networks_Changed;
        await _refresh.WaitAsync().ConfigureAwait(false);
        try
        {
            _disposed = true;
            await StopServerAsync().ConfigureAwait(false);
            UpdateAdvertisements([]);
        }
        finally
        {
            _refresh.Release();
        }
    }

    private async void Networks_Changed(object? sender, EventArgs e)
    {
        try
        {
            await RefreshAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            System.Diagnostics.Trace.TraceError($"Could not follow a network change: {error}");
        }
    }

    /// <summary>Starts the server on <paramref name="addresses"/>; null when it listens, else why not.</summary>
    private string? Start(IReadOnlyList<LocalSubnet> addresses)
    {
        X509Certificate2 certificate;
        try
        {
            certificate = _certificate();
        }
        catch (Exception e) when (e is System.Security.Cryptography.CryptographicException or IOException
                                      or UnauthorizedAccessException or InvalidOperationException)
        {
            return $"The security certificate could not be made or read: {e.Message}";
        }
        var listening = addresses;
        var options = _options.Server with { AllowPeer = remote => TrustedNetworkPolicy.IsAllowedPeer(remote, listening) };
        var ports = new[] { _lastPort, _options.PreferredPort, 0 }.Where((p, i) => i == 2 || p > 0).Distinct().ToList();
        SocketException? failure = null;
        foreach (int port in ports)
        {
            var server = new CompanionServer(certificate, _router, _limiter, options, _options.Clock);
            try
            {
                var bound = server.Start([.. addresses.Select(a => new IPEndPoint(a.Address, port))]);
                _server = server;
                _listening = addresses;
                _lastPort = bound[0].Port;
                return null;
            }
            catch (SocketException e)
            {
                failure = e;
                if (e.SocketErrorCode is not (SocketError.AddressAlreadyInUse or SocketError.AccessDenied)) break;
            }
        }
        return $"Windows did not let Lazy Scan listen for phones ({failure?.Message}).";
    }

    private async Task StopServerAsync()
    {
        if (_server is { } server)
        {
            _server = null;
            _listening = [];
            await server.StopAsync().ConfigureAwait(false);
        }
    }

    /// <summary>Advertises on each interface of a trusted network (and withdraws everything else).</summary>
    private void UpdateAdvertisements(IReadOnlyList<CompanionNetworkState> states)
    {
        var wanted = new Dictionary<int, DnsSdRegistration>();
        int port = _server?.LocalEndpoints.FirstOrDefault()?.Port ?? 0;
        if (port > 0)
        {
            string desktopId = _options.DesktopId();
            var untrusted = states.Where(s => s.Trust == NetworkTrust.NotTrusted)
                                  .SelectMany(s => s.Network.Interfaces).Select(i => i.AdapterId).ToHashSet();
            foreach (var adapter in states.Where(s => s.Trust != NetworkTrust.NotTrusted).SelectMany(s => s.Network.Interfaces))
            {
                if (untrusted.Contains(adapter.AdapterId) || adapter.Index <= 0 || wanted.ContainsKey(adapter.Index)) continue;
                var ipv4 = adapter.Addresses.Select(a => a.Address).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
                wanted[adapter.Index] = new DnsSdRegistration(
                    _options.InstanceName, _options.HostName, port, adapter.Index, ipv4,
                    [new(CompanionProtocol.TxtVersionKey, CompanionProtocol.Version.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                     new(CompanionProtocol.TxtIdKey, desktopId)]);
            }
        }
        lock (_advertised)
        {
            foreach (var (index, current) in _advertised.ToList())
            {
                if (wanted.TryGetValue(index, out var registration) && registration.Equals(current.Registration)) continue;
                _advertised.Remove(index);
                Withdraw(current.Handle);
            }
            foreach (var (index, registration) in wanted)
            {
                if (_advertised.ContainsKey(index)) continue;
                try
                {
                    _advertised[index] = (registration, _advertiser.Register(registration));
                }
                catch (Exception e)
                {
                    // Phones still find the desktop by the address from the pairing code.
                    System.Diagnostics.Trace.TraceWarning($"Could not advertise the companion service: {e.Message}");
                }
            }
        }
    }

    private static void Withdraw(IDisposable handle)
    {
        try
        {
            handle.Dispose();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not withdraw the companion advertisement: {e.Message}");
        }
    }

    private static bool SameAddresses(IReadOnlyList<LocalSubnet> a, IReadOnlyList<LocalSubnet> b) =>
        a.Select(s => s.Address).ToHashSet().SetEquals(b.Select(s => s.Address));
}
