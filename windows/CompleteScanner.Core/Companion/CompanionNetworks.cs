using System.Net;
using System.Net.Sockets;

namespace CompleteScanner.Core;

// Which networks the desktop receives on (Windows: the Network List Manager's networks). C# only:
// the Mac server (later) has no network categories and gets its own rule.

/// <summary>How Windows treats a network (NLM_NETWORK_CATEGORY).</summary>
public enum CompanionNetworkCategory
{
    Public,
    Private,
    /// <summary>A work network whose domain Windows has authenticated.</summary>
    Domain,
}

/// <summary>One address of an interface and the length of its subnet's prefix.</summary>
public sealed record LocalSubnet(IPAddress Address, int PrefixLength)
{
    /// <summary>Whether <paramref name="address"/> is in this subnet.</summary>
    public bool Contains(IPAddress address)
    {
        var a = Normalize(address);
        var b = Normalize(Address);
        if (a.AddressFamily != b.AddressFamily) return false;
        byte[] x = a.GetAddressBytes(), y = b.GetAddressBytes();
        int bits = Math.Clamp(PrefixLength, 0, x.Length * 8);
        for (int i = 0; i < x.Length && bits > 0; i++, bits -= 8)
        {
            int mask = bits >= 8 ? 0xFF : (0xFF << (8 - bits)) & 0xFF;
            if ((x[i] & mask) != (y[i] & mask)) return false;
        }
        return true;
    }

    internal static IPAddress Normalize(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
}

/// <summary>A network adapter of a connected network: its interface index and addresses.</summary>
public sealed record CompanionNetworkInterface(int Index, string AdapterId, IReadOnlyList<LocalSubnet> Addresses)
{
    public bool Equals(CompanionNetworkInterface? other) =>
        other is not null && Index == other.Index && AdapterId == other.AdapterId && Addresses.SequenceEqual(other.Addresses);

    public override int GetHashCode() => HashCode.Combine(Index, AdapterId, Addresses.Count);
}

/// <summary>A connected network as Windows names and categorizes it, with its adapters.</summary>
/// <param name="Id">The Network List Manager's id of the network (stable while Windows remembers it).</param>
/// <param name="Name">Its name ("Home Wi-Fi", "eduroam").</param>
public sealed record CompanionNetwork(string Id, string Name, CompanionNetworkCategory Category,
                                      IReadOnlyList<CompanionNetworkInterface> Interfaces)
{
    public bool Equals(CompanionNetwork? other) =>
        other is not null && Id == other.Id && Name == other.Name && Category == other.Category
        && Interfaces.SequenceEqual(other.Interfaces);

    public override int GetHashCode() => HashCode.Combine(Id, Name, Category, Interfaces.Count);
}

/// <summary>Why the desktop receives on a network, or that it does not.</summary>
public enum NetworkTrust
{
    /// <summary>Public or work network the user has not approved: nothing listens or is advertised there.</summary>
    NotTrusted,
    /// <summary>Windows treats it as Private.</summary>
    Private,
    /// <summary>The user chose "Allow receiving on this network".</summary>
    Approved,
}

/// <summary>A network the user approved for receiving (an entry of companion-networks.json).</summary>
public sealed class ApprovedNetwork
{
    public string Id { get; set; } = "";
    /// <summary>Its name when approved, for people reading the file and the list in the app.</summary>
    public string Name { get; set; } = "";
    public DateTimeOffset? Approved { get; set; }
}

/// <summary>The contents of companion-networks.json.</summary>
public sealed class ApprovedNetworksFile
{
    public List<ApprovedNetwork> Networks { get; set; } = [];
}

/// <summary>
/// The networks the user approved for receiving from phones (companion-networks.json in the
/// settings folder, rule 6 of CONTRACTS.md), by the Network List Manager's network id. Re-read for
/// every check, so another window's change counts at once. Safe to use from any thread.
/// </summary>
public sealed class TrustedNetworkStore
{
    public const string FileName = "companion-networks.json";

    private readonly string _path;
    private readonly object _gate = new();
    private ApprovedNetworksFile _file;
    /// <summary>Approvals withdrawn in this session: never trusted again, whatever the file says.</summary>
    private readonly HashSet<string> _revoked = [];

    public TrustedNetworkStore() : this(StoreFiles.DefaultDirectory) { }

    public TrustedNetworkStore(string directory)
    {
        _path = Path.Combine(directory, FileName);
        _file = StoreFiles.Load<ApprovedNetworksFile>(_path) ?? new ApprovedNetworksFile();
    }

    /// <summary>Raised after a network was approved or its approval withdrawn.</summary>
    public event EventHandler? Changed;

    public IReadOnlyList<ApprovedNetwork> Approved
    {
        get
        {
            lock (_gate)
            {
                Reload();
                return [.. _file.Networks.Where(n => !_revoked.Contains(n.Id))
                                         .Select(n => new ApprovedNetwork { Id = n.Id, Name = n.Name, Approved = n.Approved })];
            }
        }
    }

    public bool IsApproved(string networkId)
    {
        if (networkId.Length == 0) return false;
        lock (_gate)
        {
            Reload();
            return !_revoked.Contains(networkId) && _file.Networks.Any(n => n.Id == networkId);
        }
    }

    /// <summary>Approves <paramref name="network"/> for receiving; false when that could not be saved (it is not approved then).</summary>
    public bool Approve(CompanionNetwork network, DateTimeOffset now)
    {
        if (network.Id.Length == 0) return false;
        lock (_gate)
        {
            Reload();
            var previous = _file.Networks;
            _file.Networks = [.. previous.Where(n => n.Id != network.Id),
                              new ApprovedNetwork { Id = network.Id, Name = network.Name, Approved = now }];
            if (!StoreFiles.Write(_file, _path))
            {
                _file.Networks = previous;
                return false;
            }
            _revoked.Remove(network.Id);
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Withdraws the approval of <paramref name="networkId"/>; it holds for this session even when the file cannot be written.</summary>
    public void Revoke(string networkId)
    {
        lock (_gate)
        {
            Reload();
            _revoked.Add(networkId);
            if (_file.Networks.RemoveAll(n => n.Id == networkId) > 0) StoreFiles.Write(_file, _path);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Reload() => _file = StoreFiles.Load<ApprovedNetworksFile>(_path) ?? _file;
}

/// <summary>The rule for which networks the desktop receives on, and which peers it answers.</summary>
public static class TrustedNetworkPolicy
{
    /// <summary>
    /// Private networks are trusted; any other (Public, or a work domain network) only when the user
    /// approved it by its id.
    /// </summary>
    public static NetworkTrust Trust(CompanionNetwork network, Func<string, bool> isApproved) =>
        network.Category == CompanionNetworkCategory.Private ? NetworkTrust.Private
        : network.Id.Length > 0 && isApproved(network.Id) ? NetworkTrust.Approved
        : NetworkTrust.NotTrusted;

    /// <summary>
    /// The addresses to listen on: every address of every adapter of a trusted network, never one
    /// of an untrusted network (an adapter shared by both is left out). Each address once, IPv4 first.
    /// </summary>
    public static IReadOnlyList<LocalSubnet> ListenAddresses(IReadOnlyList<CompanionNetwork> networks, Func<string, bool> isApproved)
    {
        var untrustedAdapters = networks.Where(n => Trust(n, isApproved) == NetworkTrust.NotTrusted)
                                        .SelectMany(n => n.Interfaces).Select(i => i.AdapterId).ToHashSet();
        var addresses = new List<LocalSubnet>();
        foreach (var network in networks.Where(n => Trust(n, isApproved) != NetworkTrust.NotTrusted))
        {
            foreach (var adapter in network.Interfaces.Where(i => !untrustedAdapters.Contains(i.AdapterId)))
            {
                foreach (var subnet in adapter.Addresses)
                {
                    if (!addresses.Any(a => a.Address.Equals(subnet.Address))) addresses.Add(subnet);
                }
            }
        }
        return [.. addresses.OrderBy(a => a.Address.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)];
    }

    /// <summary>
    /// Whether a connection from <paramref name="remote"/> is answered: from this computer, a
    /// private, link-local, shared (100.64.0.0/10) or unique-local address, or an address in the
    /// subnet of an address the desktop listens on (networks that give their devices public
    /// addresses). Anything else is closed before TLS starts.
    /// </summary>
    public static bool IsAllowedPeer(IPAddress remote, IReadOnlyList<LocalSubnet> listening)
    {
        var address = LocalSubnet.Normalize(remote);
        return IsLocalAddress(address) || listening.Any(subnet => subnet.Contains(address));
    }

    /// <summary>Loopback, RFC 1918, link-local, shared address space, unique-local.</summary>
    public static bool IsLocalAddress(IPAddress remote)
    {
        var address = LocalSubnet.Normalize(remote);
        if (IPAddress.IsLoopback(address)) return true;
        byte[] b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return b[0] == 10
                   || (b[0] == 172 && (b[1] & 0xF0) == 16)
                   || (b[0] == 192 && b[1] == 168)
                   || (b[0] == 169 && b[1] == 254)
                   || (b[0] == 100 && (b[1] & 0xC0) == 64);
        }
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] & 0xFE) == 0xFC;
        }
        return false;
    }
}
