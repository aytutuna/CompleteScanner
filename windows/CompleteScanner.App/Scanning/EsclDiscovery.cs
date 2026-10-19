using System.Globalization;
using CompleteScanner.Core;
using Windows.Devices.Enumeration;

namespace CompleteScanner.App.Scanning;

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
    private readonly Dictionary<string, (DeviceInformation Info, bool Secure)> _found = [];
    private readonly List<DeviceWatcher> _watchers = [];
    private SynchronizationContext? _context;
    private bool _changePosted;
    private int _completedPasses;
    private string? _failure;

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
                if (_watchers.Count == 0) return "off";
                string pass = _completedPasses >= _watchers.Count ? "first pass complete" : "first pass running";
                return $"browsing, {pass}, {_found.Count} service(s)";
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
                return [.. _found.Values.Select(entry => ToService(entry.Info, entry.Secure))];
            }
        }
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_watchers.Count > 0) return;
            _context = SynchronizationContext.Current;
            _failure = null;
            _completedPasses = 0;
            try
            {
                foreach (var (serviceName, secure) in ServiceTypes)
                {
                    string aqs = $"System.Devices.AepService.ProtocolId:=\"{DnssdProtocolId}\" AND "
                                 + "System.Devices.Dnssd.Domain:=\"local\" AND "
                                 + $"System.Devices.Dnssd.ServiceName:=\"{serviceName}\"";
                    var watcher = DeviceInformation.CreateWatcher(aqs, RequestedProperties,
                                                                  DeviceInformationKind.AssociationEndpointService);
                    watcher.Added += (_, info) => OnAdded(info, secure);
                    watcher.Updated += (_, update) => OnUpdated(update);
                    watcher.Removed += (_, update) => OnRemoved(update);
                    watcher.EnumerationCompleted += (_, _) => OnEnumerationCompleted();
                    watcher.Stopped += (sender, _) => OnStopped(sender);
                    _watchers.Add(watcher);
                }
                foreach (var watcher in _watchers) watcher.Start();
            }
            catch (Exception e)
            {
                // Without the watcher, scanners can still be added by address.
                _failure = e.Message;
                StopWatchers();
            }
        }
        PostChanged();
    }

    public void Stop()
    {
        lock (_gate)
        {
            StopWatchers();
            _found.Clear();
        }
        PostChanged();
    }

    public void Dispose() => Stop();

    private void StopWatchers()
    {
        // Forgotten first, so their Stopped events are not taken for Windows aborting them.
        var stopping = _watchers.ToList();
        _watchers.Clear();
        foreach (var watcher in stopping)
        {
            try
            {
                if (watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted)
                {
                    watcher.Stop();
                }
            }
            catch (Exception)
            {
                // Already stopping or aborted.
            }
        }
    }

    private void OnAdded(DeviceInformation info, bool secure)
    {
        lock (_gate)
        {
            if (_watchers.Count == 0) return;
            _found[info.Id] = (info, secure);
        }
        PostChanged();
    }

    private void OnUpdated(DeviceInformationUpdate update)
    {
        lock (_gate)
        {
            if (!_found.TryGetValue(update.Id, out var entry)) return;
            entry.Info.Update(update);
        }
        PostChanged();
    }

    private void OnRemoved(DeviceInformationUpdate update)
    {
        bool removed;
        lock (_gate) removed = _found.Remove(update.Id);
        if (removed) PostChanged();
    }

    private void OnEnumerationCompleted()
    {
        lock (_gate) _completedPasses++;
        PostChanged();
    }

    /// <summary>A watcher ended without being stopped here (Windows aborted it): say so in the diagnostics.</summary>
    private void OnStopped(DeviceWatcher watcher)
    {
        lock (_gate)
        {
            if (!_watchers.Contains(watcher)) return; // stopped by Stop()
            _failure = $"the Windows device watcher stopped ({watcher.Status})";
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
