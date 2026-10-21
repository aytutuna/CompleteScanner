using System.Net;
using System.Net.Sockets;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Escl/EsclEndpoint.swift: the same rules and tests on both platforms.

/// <summary>
/// One DNS-SD service instance of a network scanner, as the operating system reports it:
/// _uscan._tcp (<paramref name="Secure"/> false) or _uscans._tcp (true).
/// </summary>
/// <param name="Id">The system's id for the service instance.</param>
/// <param name="InstanceName">e.g. "HP Color LaserJet MFP M479fdw (A1B2C3)".</param>
/// <param name="HostName">e.g. "HPA1B2C3.local"; null when not reported.</param>
/// <param name="Addresses">
/// IP addresses as text, e.g. "192.168.1.20", "fe80::1%12" (the zone as an interface index or
/// name; an address whose zone names no interface here is skipped).
/// </param>
/// <param name="TextAttributes">TXT record entries ("key=value").</param>
public sealed record EsclService(string Id, string InstanceName, bool Secure, string? HostName,
                                 IReadOnlyList<string> Addresses, int Port, IReadOnlyList<string> TextAttributes);

/// <summary>
/// A discovered network scanner: its _uscan and _uscans services merged, with the addresses to
/// connect through in the order to try them.
/// </summary>
public sealed class EsclEndpoint
{
    /// <summary>"uuid:" + <see cref="EsclTxtRecord.UuidKey"/>, or "name:" + the instance name (lowercase) without a UUID.</summary>
    public required string Key { get; init; }
    /// <summary>The model from the TXT record, else the service instance name.</summary>
    public required string Name { get; init; }
    /// <summary>The TXT record of the first service (the secure one when both are advertised).</summary>
    public required EsclTxtRecord Txt { get; init; }
    /// <summary>
    /// Where to connect, best first: every HTTPS address before every HTTP one, and within
    /// each, IPv4 addresses, then the host name, then IPv6 addresses.
    /// </summary>
    public required IReadOnlyList<ScannerAddress> Addresses { get; init; }

    /// <summary>The device UUID from the TXT record, as advertised; null when there is none.</summary>
    public string? Uuid => Txt.Uuid;

    /// <summary>
    /// Groups services by device (TXT UUID; services without one by instance name, which the
    /// _uscan and _uscans instances of one device share) and orders each device's addresses:
    /// HTTPS first (a failed TLS handshake falls back to the HTTP ones), IPv4 before the
    /// .local host name (which needs another lookup), IPv6 last. IPv6 link-local addresses
    /// without a zone (%interface) cannot be connected to and are skipped. Devices keep the
    /// order their first service was listed in; devices left without an address are dropped.
    /// </summary>
    public static IReadOnlyList<EsclEndpoint> Choose(IEnumerable<EsclService> services)
    {
        var list = services.Where(s => s.Port is >= 1 and <= 65535).ToList();
        var parsed = list.Select(s => (Service: s, Txt: EsclTxtRecord.Parse(s.TextAttributes))).ToList();
        var uuidByInstance = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (service, txt) in parsed)
        {
            if (EsclTxtRecord.UuidKey(txt.Uuid) is { } uuid) uuidByInstance.TryAdd(service.InstanceName, uuid);
        }

        var groups = new List<(string Key, List<(EsclService Service, EsclTxtRecord Txt)> Members)>();
        foreach (var entry in parsed)
        {
            string key = EsclTxtRecord.UuidKey(entry.Txt.Uuid) is { } uuid ? "uuid:" + uuid
                : uuidByInstance.TryGetValue(entry.Service.InstanceName, out var shared) ? "uuid:" + shared
                : "name:" + entry.Service.InstanceName.ToLowerInvariant();
            var group = groups.FirstOrDefault(g => g.Key == key);
            if (group.Members is null) groups.Add((key, [entry]));
            else group.Members.Add(entry);
        }

        var endpoints = new List<EsclEndpoint>();
        foreach (var (key, members) in groups)
        {
            var ordered = members.OrderByDescending(m => m.Service.Secure).ToList(); // stable: secure first
            var addresses = new List<ScannerAddress>();
            foreach (var (service, txt) in ordered)
            {
                foreach (string host in Hosts(service))
                {
                    if (ScannerAddress.Create(service.Secure, host, service.Port, txt.ResourcePath) is { } address
                        && !addresses.Contains(address))
                    {
                        addresses.Add(address);
                    }
                }
            }
            if (addresses.Count == 0) continue;
            var first = ordered[0];
            endpoints.Add(new EsclEndpoint
            {
                Key = key,
                Name = ordered.Select(m => m.Txt.Model).FirstOrDefault(m => m is not null) ?? first.Service.InstanceName,
                Txt = first.Txt,
                Addresses = addresses,
            });
        }
        return endpoints;
    }

    /// <summary>One service's hosts to try: IPv4 addresses, the host name, then usable IPv6 addresses.</summary>
    private static IEnumerable<string> Hosts(EsclService service)
    {
        var v4 = new List<string>();
        var v6 = new List<string>();
        foreach (string text in service.Addresses)
        {
            string trimmed = text?.Trim() ?? "";
            if (!IPAddress.TryParse(trimmed, out var ip)) continue;
            if (ip.AddressFamily == AddressFamily.InterNetwork) v4.Add(ip.ToString());
            else if (ScannerAddress.ParseIPv6(trimmed) is { } zoned && (!zoned.IsIPv6LinkLocal || zoned.ScopeId != 0))
            {
                v6.Add(zoned.ToString());
            }
        }
        foreach (string ip in v4) yield return ip;
        if (!string.IsNullOrWhiteSpace(service.HostName)) yield return service.HostName.Trim();
        foreach (string ip in v6) yield return ip;
    }
}
