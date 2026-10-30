using System.Globalization;
using LazyScan.Core;
using Windows.Devices.Enumeration;

namespace LazyScan.App.Scanning;

/// <summary>
/// Finds network scanners that announce eSCL over DNS-SD (_uscan._tcp, and _uscans._tcp for
/// HTTPS) through Windows' own mDNS stack: a DeviceWatcher over association-endpoint services
/// with the DNS-SD protocol id. Nothing listens on port 5353 itself, so there is no firewall
/// prompt, and no package is needed. Services come and go as Windows reports them.
/// </summary>
internal sealed class EsclDiscovery : IDisposable
{
    /// <summary>The DNS-SD protocol of association-endpoint services.</summary>
    private const string DnssdProtocolId = "{4526e8c1-8aac-4153-9b16-55e86ada0e54}";

    private const string HostNameProperty = "System.Devices.Dnssd.HostName";
    private const string InstanceNameProperty = "System.Devices.Dnssd.InstanceName";
    private const string PortNumberProperty = "System.Devices.Dnssd.PortNumber";
    private const string ServiceNameProperty = "System.Devices.Dnssd.ServiceName";
    private const string TextAttributesProperty = "System.Devices.Dnssd.TextAttributes";
    private const string IpAddressProperty = "System.Devices.IpAddress";

    private static readonly string[] RequestedProperties =
        [HostNameProperty, InstanceNameProperty, PortNumberProperty, ServiceNameProperty,
         TextAttributesProperty, IpAddressProperty];

    /// <summary>The two service types: plain eSCL and eSCL over TLS.</summary>
    private static readonly (string ServiceName, bool Secure)[] ServiceTypes =
        [("_uscans._tcp", true), ("_uscan._tcp", false)];

    private readonly object _gate = new();
    private readonly Dictionary<string, Found> _found = [];
    /// <summary>
    /// Services kept from before <see cref="Restart"/> that the new watcher of their type has not
    /// reported again yet; those it has not reported by the end of its first pass are gone.
    /// </summary>
    private readonly HashSet<string> _carried = [];
    private readonly List<Browse> _browses = [];
    private SynchronizationContext? _context;
    private bool _changePosted;
    private string? _failure;

    /// <summary>A service as found: what Windows reported (null for one added by a harness) and the service read from it.</summary>
    private sealed record Found(DeviceInformation? Info, bool Secure, EsclService Service);

    /// <summary>One watcher, for one service type.</summary>
    private sealed class Browse(DeviceWatcher watcher, bool secure)
    {
        public DeviceWatcher Watcher { get; } = watcher;
        public bool Secure { get; } = secure;
        /// <summary>Its first pass is complete.</summary>
        public bool Completed { get; set; }
        /// <summary>Windows stopped it.</summary>
        public bool Aborted { get; set; }
    }

    /// <summary>The services changed. Raised on the synchronization context <see cref="Start"/> was called on.</summary>
    public event Action? Changed;

    /// <summary>One line on how browsing goes, for the device diagnostics.</summary>
    public string Status
    {
        get
        {
            lock (_gate)
            {
                if (_failure is not null) return $"unavailable ({_failure})";
                if (_browses.Count == 0) return "off";
                string pass = _browses.All(b => b.Completed) ? "first pass complete" : "first pass running";
                return $"browsing, {pass}, {_found.Count} service(s)";
            }
        }
    }

    /// <summary>How browsing goes, for the troubleshooter; <see cref="Failure"/> says why it is unavailable.</summary>
    public DiscoveryStatus State
    {
        get
        {
            lock (_gate)
            {
                if (_failure is not null) return DiscoveryStatus.Unavailable;
                if (_browses.Count == 0) return DiscoveryStatus.Off;
                return _browses.All(b => b.Completed) ? DiscoveryStatus.Running : DiscoveryStatus.Searching;
            }
        }
    }

    /// <summary>Why browsing is unavailable, as Windows put it; null while it works.</summary>
    public string? Failure
    {
        get
        {
            lock (_gate)
            {
                return _failure;
            }
        }
    }

    /// <summary>The services currently known.</summary>
    public IReadOnlyList<EsclService> Services
    {
        get
        {
            lock (_gate)
            {
                return [.. _found.Values.Select(entry => entry.Service)];
            }
        }
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_browses.Count > 0) return;
            _context = SynchronizationContext.Current;
            StartMissing();
        }
        PostChanged();
    }

    /// <summary>
    /// Starts again the search for each service type whose watcher Windows stopped (or that would
    /// not start); a watcher that works is left alone. What was found is kept: the services of a
    /// restarted type stay listed until its new watcher has made its first pass, and only those
    /// it did not find again are dropped then. Does nothing while every watcher works.
    /// </summary>
    public void Restart()
    {
        lock (_gate)
        {
            if (_failure is null && _browses.Count == ServiceTypes.Length) return;
            _context ??= SynchronizationContext.Current;
            var aborted = _browses.Where(b => b.Aborted).ToList();
            foreach (var browse in aborted) _browses.Remove(browse);
            StopWatchers(aborted);
            StartMissing();
        }
        PostChanged();
    }

    /// <summary>Creates and starts a watcher for each service type that has none. Call under the lock.</summary>
    private void StartMissing()
    {
        _failure = null;
        var started = new List<Browse>();
        try
        {
            foreach (var (serviceName, secure) in ServiceTypes)
            {
                if (_browses.Any(b => b.Secure == secure)) continue;
                // Its services found so far stay until the new watcher's first pass is complete.
                foreach (var (id, entry) in _found)
                {
                    if (entry.Secure == secure) _carried.Add(id);
                }
                string aqs = $"System.Devices.AepService.ProtocolId:=\"{DnssdProtocolId}\" AND "
                             + "System.Devices.Dnssd.Domain:=\"local\" AND "
                             + $"System.Devices.Dnssd.ServiceName:=\"{serviceName}\"";
                var watcher = DeviceInformation.CreateWatcher(aqs, RequestedProperties,
                                                              DeviceInformationKind.AssociationEndpointService);
                var browse = new Browse(watcher, secure);
                watcher.Added += (_, info) => OnAdded(browse, info);
                watcher.Updated += (_, update) => OnUpdated(browse, update);
                watcher.Removed += (_, update) => OnRemoved(browse, update);
                watcher.EnumerationCompleted += (_, _) => OnEnumerationCompleted(browse);
                watcher.Stopped += (_, _) => OnStopped(browse);
                started.Add(browse);
                _browses.Add(browse);
            }
            foreach (var browse in started) browse.Watcher.Start();
        }
        catch (Exception e)
        {
            // Without the watcher, scanners can still be added by address.
            _failure = e.Message;
            foreach (var browse in started) _browses.Remove(browse);
            StopWatchers(started);
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            var stopping = _browses.ToList();
            _browses.Clear();
            StopWatchers(stopping);
            _found.Clear();
            _carried.Clear();
            _failure = null;
        }
        PostChanged();
    }

    public void Dispose() => Stop();

    /// <summary>
    /// A service as if a watcher had reported it, for harnesses: a stand-in for a scanner on the
    /// network, listed until <see cref="Stop"/>.
    /// </summary>
    internal void AddService(EsclService service)
    {
        lock (_gate)
        {
            _found[service.Id] = new Found(null, service.Secure, service);
            _carried.Remove(service.Id);
        }
        PostChanged();
    }

    /// <summary>Stops watchers already forgotten, so their Stopped events are not taken for Windows aborting them.</summary>
    private static void StopWatchers(IEnumerable<Browse> stopping)
    {
        foreach (var browse in stopping)
        {
            try
            {
                if (browse.Watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted)
                {
                    browse.Watcher.Stop();
                }
            }
            catch (Exception)
            {
                // Already stopping or aborted.
            }
        }
    }

    private void OnAdded(Browse browse, DeviceInformation info)
    {
        lock (_gate)
        {
            if (!_browses.Contains(browse)) return; // stopped or replaced
            _found[info.Id] = new Found(info, browse.Secure, ToService(info, browse.Secure));
            _carried.Remove(info.Id);
        }
        PostChanged();
    }

    private void OnUpdated(Browse browse, DeviceInformationUpdate update)
    {
        lock (_gate)
        {
            if (!_browses.Contains(browse)) return;
            if (!_found.TryGetValue(update.Id, out var entry) || entry.Info is null) return;
            entry.Info.Update(update);
            _found[update.Id] = entry with { Service = ToService(entry.Info, entry.Secure) };
        }
        PostChanged();
    }

    private void OnRemoved(Browse browse, DeviceInformationUpdate update)
    {
        bool removed;
        lock (_gate)
        {
            if (!_browses.Contains(browse)) return;
            removed = _found.Remove(update.Id);
            _carried.Remove(update.Id);
        }
        if (removed) PostChanged();
    }

    /// <summary>A watcher's first pass is complete: services kept from before a restart that it did not find again are gone.</summary>
    private void OnEnumerationCompleted(Browse browse)
    {
        lock (_gate)
        {
            if (!_browses.Contains(browse)) return;
            browse.Completed = true;
            foreach (string id in _carried.Where(id => _found.TryGetValue(id, out var entry) && entry.Secure == browse.Secure).ToList())
            {
                _found.Remove(id);
                _carried.Remove(id);
            }
        }
        PostChanged();
    }

    /// <summary>A watcher ended without being stopped here (Windows aborted it): say so in the diagnostics.</summary>
    private void OnStopped(Browse browse)
    {
        lock (_gate)
        {
            if (!_browses.Contains(browse)) return; // stopped by Stop() or Restart()
            browse.Aborted = true;
            _failure = $"the Windows device watcher stopped ({browse.Watcher.Status})";
        }
        PostChanged();
    }

    /// <summary>Raises <see cref="Changed"/> once on the start context for any burst of watcher events.</summary>
    private void PostChanged()
    {
        SynchronizationContext? context;
        lock (_gate)
        {
            if (_changePosted) return;
            _changePosted = true;
            context = _context;
        }
        void Raise(object? _)
        {
            lock (_gate) _changePosted = false;
            Changed?.Invoke();
        }
        if (context is null) Raise(null);
        else context.Post(Raise, null);
    }

    private static EsclService ToService(DeviceInformation info, bool secure)
    {
        var properties = info.Properties;
        object? Get(string key) => properties.TryGetValue(key, out object? value) ? value : null;
        string instance = Get(InstanceNameProperty) as string is { Length: > 0 } name ? name : info.Name;
        // The service type the watcher matched; the property says the same when present.
        if (Get(ServiceNameProperty) is string serviceName)
        {
            secure = serviceName.StartsWith("_uscans.", StringComparison.OrdinalIgnoreCase);
        }
        int port = 0;
        try
        {
            if (Get(PortNumberProperty) is { } value) port = Convert.ToInt32(value, CultureInfo.InvariantCulture);
        }
        catch (Exception)
        {
            port = 0; // unusable: the service is skipped
        }
        return new EsclService(info.Id, instance, secure, Get(HostNameProperty) as string,
                               Strings(Get(IpAddressProperty)), port, Strings(Get(TextAttributesProperty)));
    }

    private static IReadOnlyList<string> Strings(object? value) => value switch
    {
        string[] array => array,
        string single => [single],
        IEnumerable<string> list => [.. list],
        _ => [],
    };
}
