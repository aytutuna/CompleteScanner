using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services.Companion;

/// <summary>
/// The networks this PC is connected to, as the Network List Manager (COM, no administrator
/// rights) names and categorizes them, each with its adapters' interface indexes and addresses
/// (System.Net.NetworkInformation, matched by adapter id). Changes are seen from Windows'
/// address-change events and, since a network turning Private or Public changes no address, from a
/// check every <see cref="PollInterval"/>. Only reads; never changes a network setting.
/// </summary>
public sealed class WindowsNetworkSource : ICompanionNetworkSource, IDisposable
{
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan Settle = TimeSpan.FromSeconds(1);

    private readonly Timer _poll;
    private readonly Timer _settle;
    private readonly object _gate = new();
    private string _signature = "";
    private bool _disposed;

    public WindowsNetworkSource()
    {
        _poll = new Timer(_ => CheckForChange(), null, PollInterval, PollInterval);
        _settle = new Timer(_ => CheckForChange(), null, Timeout.Infinite, Timeout.Infinite);
        NetworkChange.NetworkAddressChanged += Network_Changed;
        NetworkChange.NetworkAvailabilityChanged += Network_Changed;
        _signature = Signature(Networks());
    }

    public event EventHandler? Changed;

    public IReadOnlyList<CompanionNetwork> Networks()
    {
        try
        {
            var adapters = Adapters();
            return [.. ConnectedNetworks().Select(n => new CompanionNetwork(
                n.Id, n.Name, n.Category,
                [.. n.AdapterIds.Select(id => adapters.TryGetValue(id, out var adapter) ? adapter : null)
                                .Where(adapter => adapter is not null)
                                .Select(adapter => adapter!)]))];
        }
        catch (Exception e)
        {
            // Never throws: no network known means nothing listens.
            Trace.TraceWarning($"Could not read the networks: {e.Message}");
            return [];
        }
    }

    public void Dispose()
    {
        lock (_gate) _disposed = true;
        NetworkChange.NetworkAddressChanged -= Network_Changed;
        NetworkChange.NetworkAvailabilityChanged -= Network_Changed;
        _poll.Dispose();
        _settle.Dispose();
    }

    /// <summary>Windows reports address changes in bursts: look once they have settled.</summary>
    private void Network_Changed(object? sender, EventArgs e)
    {
        lock (_gate)
        {
            if (!_disposed) _settle.Change(Settle, Timeout.InfiniteTimeSpan);
        }
    }

    private void CheckForChange()
    {
        string signature = Signature(Networks());
        lock (_gate)
        {
            if (_disposed || signature == _signature) return;
            _signature = signature;
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static string Signature(IReadOnlyList<CompanionNetwork> networks) =>
        string.Join("|", networks.Select(n => $"{n.Id}/{n.Category}/{n.Name}/" + string.Join(",",
            n.Interfaces.Select(i => $"{i.Index}:" + string.Join(";", i.Addresses.Select(a => $"{a.Address}/{a.PrefixLength}"))))));

    /// <summary>Each up adapter by its id (the GUID in NetworkInterface.Id), with its usable unicast addresses.</summary>
    private static Dictionary<Guid, CompanionNetworkInterface> Adapters()
    {
        var adapters = new Dictionary<Guid, CompanionNetworkInterface>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up || !Guid.TryParse(adapter.Id, out var id)) continue;
            var properties = adapter.GetIPProperties();
            int index = 0;
            if (adapter.Supports(NetworkInterfaceComponent.IPv4)) index = properties.GetIPv4Properties()?.Index ?? 0;
            if (index == 0 && adapter.Supports(NetworkInterfaceComponent.IPv6)) index = properties.GetIPv6Properties()?.Index ?? 0;
            var addresses = properties.UnicastAddresses
                .Where(a => a.Address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6
                            && a.DuplicateAddressDetectionState == DuplicateAddressDetectionState.Preferred)
                .Select(a => new LocalSubnet(a.Address, a.PrefixLength))
                .ToList();
            adapters[id] = new CompanionNetworkInterface(index, adapter.Id, addresses);
        }
        return adapters;
    }

    private sealed record NlmNetwork(string Id, string Name, CompanionNetworkCategory Category, List<Guid> AdapterIds);

    /// <summary>The connected networks from the Network List Manager, with their adapters' ids.</summary>
    private static List<NlmNetwork> ConnectedNetworks()
    {
        var result = new List<NlmNetwork>();
        INetworkListManager? manager = null;
        IEnumNetworks? networks = null;
        try
        {
            var type = Type.GetTypeFromCLSID(NetworkListManagerClsid, throwOnError: false);
            if (type is null) return result;
            manager = (INetworkListManager)Activator.CreateInstance(type)!;
            networks = manager.GetNetworks(NlmEnumNetworkConnected);
            while (networks.Next(1, out var network, out int fetched) == 0 && fetched == 1 && network is not null)
            {
                IEnumNetworkConnections? connections = null;
                try
                {
                    var category = WindowsSystemStatus.Network(network.GetCategory()) switch
                    {
                        NetworkStatus.PrivateNetwork => CompanionNetworkCategory.Private,
                        NetworkStatus.DomainNetwork => CompanionNetworkCategory.Domain,
                        _ => CompanionNetworkCategory.Public,
                    };
                    var adapterIds = new List<Guid>();
                    connections = network.GetNetworkConnections();
                    while (connections.Next(1, out var connection, out int got) == 0 && got == 1 && connection is not null)
                    {
                        try
                        {
                            adapterIds.Add(connection.GetAdapterId());
                        }
                        finally
                        {
                            Marshal.ReleaseComObject(connection);
                        }
                    }
                    result.Add(new NlmNetwork(network.GetNetworkId().ToString("B"), network.GetName(), category, adapterIds));
                }
                finally
                {
                    if (connections is not null) Marshal.ReleaseComObject(connections);
                    Marshal.ReleaseComObject(network);
                }
            }
        }
        finally
        {
            if (networks is not null) Marshal.ReleaseComObject(networks);
            if (manager is not null) Marshal.ReleaseComObject(manager);
        }
        return result;
    }

    // MARK: - Network List Manager (netlistmgr.h). Only reading members are called; the others are
    // declared because the interfaces are called through their vtables, in header order.

    private static readonly Guid NetworkListManagerClsid = new("DCB00C01-570F-4A9B-8D69-199FDBA5723B");
    private const int NlmEnumNetworkConnected = 0x01;

    [ComImport, Guid("DCB00000-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkListManager
    {
        IEnumNetworks GetNetworks(int flags);
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetwork(Guid networkId);
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnections();
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnection(Guid connectionId);
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
    }

    [ComImport, Guid("DCB00003-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface IEnumNetworks
    {
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNewEnum();
        [PreserveSig] int Next(int count, out INetwork? network, out int fetched);
    }

    [ComImport, Guid("DCB00002-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetwork
    {
        [return: MarshalAs(UnmanagedType.BStr)] string GetName();
        void SetName([MarshalAs(UnmanagedType.BStr)] string name);
        [return: MarshalAs(UnmanagedType.BStr)] string GetDescription();
        void SetDescription([MarshalAs(UnmanagedType.BStr)] string description);
        Guid GetNetworkId();
        int GetDomainType();
        IEnumNetworkConnections GetNetworkConnections();
        void GetTimeCreatedAndConnected(out uint lowCreated, out uint highCreated, out uint lowConnected, out uint highConnected);
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        int GetConnectivity();
        int GetCategory();
    }

    [ComImport, Guid("DCB00006-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface IEnumNetworkConnections
    {
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNewEnum();
        [PreserveSig] int Next(int count, out INetworkConnection? connection, out int fetched);
    }

    [ComImport, Guid("DCB00005-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkConnection
    {
        INetwork GetNetwork();
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        int GetConnectivity();
        Guid GetConnectionId();
        Guid GetAdapterId();
        int GetDomainType();
    }
}
