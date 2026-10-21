using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Escl/ScannerAddress.swift: the same rules and tests on both platforms.

/// <summary>
/// Where an eSCL scanner answers: scheme, host, port and resource path. Parsed from what a
/// user types ("192.168.1.50", "scanner.local:8080", "https://10.0.0.7", "[fe80::1%12]:80",
/// "http://host:8080/eSCL") and written back in one canonical form, the text kept in
/// escl-hosts.json.
/// </summary>
public sealed class ScannerAddress : IEquatable<ScannerAddress>
{
    /// <summary>HTTPS (eSCL over TLS, _uscans) instead of plain HTTP.</summary>
    public bool Secure { get; }
    /// <summary>Host name (lowercase) or IP address; IPv6 without brackets, with its zone (%12) when it has one.</summary>
    public string Host { get; }
    public int Port { get; }
    /// <summary>The eSCL resource path below the host, without slashes ("eSCL" unless given).</summary>
    public string ResourcePath { get; }

    private ScannerAddress(bool secure, string host, int port, string resourcePath)
    {
        Secure = secure;
        Host = host;
        Port = port;
        ResourcePath = resourcePath;
    }

    public int DefaultPort => Secure ? 443 : 80;

    private bool IsIPv6 => Host.Contains(':');

    /// <summary>
    /// The host as written in a URL: IPv6 in brackets. A zone stays "%12" rather than RFC 6874's
    /// "%2512": System.Uri reads the zone unescaped (and leaves it out of AbsoluteUri).
    /// </summary>
    private string UriHost => IsIPv6 ? "[" + Host + "]" : Host;

    /// <summary>"host:port" (IPv6 in brackets), lowercase: identifies the endpoint, e.g. for certificate trust.</summary>
    public string Authority => $"{(IsIPv6 ? "[" + Host + "]" : Host)}:{Port.ToString(CultureInfo.InvariantCulture)}";

    /// <summary>The eSCL root, ending in a slash so relative paths ("ScannerCapabilities") resolve below it.</summary>
    public Uri BaseUri =>
        new($"{(Secure ? "https" : "http")}://{UriHost}:{Port.ToString(CultureInfo.InvariantCulture)}/"
            + (ResourcePath.Length > 0 ? Uri.EscapeDataString(ResourcePath).Replace("%2F", "/") + "/" : ""));

    /// <summary>
    /// The canonical text: the bare host for the plain default ("192.168.1.50"), "host:port"
    /// for plain HTTP on another port, otherwise a URL ("https://10.0.0.7",
    /// "http://host:8080/scan"). Parsing it gives an equal address, except for a resource at
    /// the root of the host, which only a discovered service can name (it reads back as /eSCL).
    /// </summary>
    public override string ToString()
    {
        string bracketed = IsIPv6 ? "[" + Host + "]" : Host;
        if (!Secure && ResourcePath == "eSCL")
        {
            return Port == 80 ? bracketed : $"{bracketed}:{Port.ToString(CultureInfo.InvariantCulture)}";
        }
        string text = (Secure ? "https://" : "http://") + bracketed;
        if (Port != DefaultPort) text += ":" + Port.ToString(CultureInfo.InvariantCulture);
        if (ResourcePath != "eSCL") text += "/" + ResourcePath;
        return text;
    }

    public bool Equals(ScannerAddress? other) =>
        other is not null && string.Equals(ToString(), other.ToString(), StringComparison.OrdinalIgnoreCase);

    public override bool Equals(object? obj) => Equals(obj as ScannerAddress);

    public override int GetHashCode() => StringComparer.OrdinalIgnoreCase.GetHashCode(ToString());

    /// <summary>An address from its parts (a discovered service); null when the host is not usable.</summary>
    public static ScannerAddress? Create(bool secure, string host, int port, string resourcePath)
    {
        if (port is < 1 or > 65535) return null;
        string? normalized = NormalizeHost(host.Trim().TrimStart('[').TrimEnd(']'));
        return normalized is null ? null : new ScannerAddress(secure, normalized, port, resourcePath.Trim('/'));
    }

    /// <summary>Parses an address; throws <see cref="FormatException"/> with a user-facing message.</summary>
    public static ScannerAddress Parse(string text) =>
        TryParse(text, out var address, out string error) ? address! : throw new FormatException(error);

    /// <summary>
    /// Parses what a user typed. Accepted: an IPv4 or IPv6 address or host name, optionally
    /// with a port ("host:8080", "[fe80::1]:8080"), or an http(s) URL with an optional port and
    /// resource path (a trailing "/ScannerCapabilities" is dropped). Plain addresses mean HTTP
    /// on port 80 at /eSCL. <paramref name="error"/> says what is wrong, for the user.
    /// </summary>
    public static bool TryParse(string? text, out ScannerAddress? address, out string error)
    {
        address = null;
        error = "";
        string value = text?.Trim() ?? "";
        if (value.Length == 0)
        {
            error = "Enter the scanner's IP address or host name.";
            return false;
        }
        if (value.Any(char.IsWhiteSpace))
        {
            error = "An address cannot contain spaces.";
            return false;
        }

        bool hasScheme = value.Contains("://", StringComparison.Ordinal);
        // "192.168.1.5/eSCL": a path without a scheme means plain HTTP.
        if (!hasScheme && value.Contains('/')) return TryParse("http://" + value, out address, out error);
        if (hasScheme) return TryParseUrl(value, out address, out error);

        string host;
        string? port = null;
        if (value.StartsWith('['))
        {
            int close = value.IndexOf(']');
            if (close < 0)
            {
                error = "An IPv6 address in brackets needs its closing \"]\".";
                return false;
            }
            host = value[1..close];
            string rest = value[(close + 1)..];
            if (rest.Length > 0)
            {
                if (!rest.StartsWith(':'))
                {
                    error = "That is not a valid address.";
                    return false;
                }
                port = rest[1..];
            }
        }
        else if (value.Count(c => c == ':') >= 2)
        {
            host = value; // a bare IPv6 address: no port
        }
        else
        {
            int colon = value.IndexOf(':');
            host = colon < 0 ? value : value[..colon];
            if (colon >= 0) port = value[(colon + 1)..];
        }

        int portNumber = 80;
        if (port is not null && !TryPort(port, out portNumber))
        {
            error = "The port must be a number from 1 to 65535.";
            return false;
        }
        if (NormalizeHost(host) is not { } normalized)
        {
            error = $"\"{host}\" is not a valid IP address or host name.";
            return false;
        }
        address = new ScannerAddress(secure: false, normalized, portNumber, "eSCL");
        return true;
    }

    private static bool TryParseUrl(string value, out ScannerAddress? address, out string error)
    {
        address = null;
        error = "";
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Host.Length == 0)
        {
            error = "That is not a valid address.";
            return false;
        }
        bool secure;
        if (uri.Scheme == Uri.UriSchemeHttp) secure = false;
        else if (uri.Scheme == Uri.UriSchemeHttps) secure = true;
        else
        {
            error = "Use an address that starts with http:// or https://, or just the IP address or host name.";
            return false;
        }
        if (uri.UserInfo.Length > 0)
        {
            error = "Leave out the user name and password; scanners do not need them.";
            return false;
        }
        if (NormalizeHost(uri.DnsSafeHost) is not { } host)
        {
            error = uri.HostNameType == UriHostNameType.IPv6
                ? "That is not a valid address."
                : $"\"{uri.Host}\" is not a valid IP address or host name.";
            return false;
        }
        string path = Uri.UnescapeDataString(uri.AbsolutePath).Trim('/');
        const string capabilities = "ScannerCapabilities";
        if (path.Equals(capabilities, StringComparison.OrdinalIgnoreCase)) path = "";
        else if (path.EndsWith("/" + capabilities, StringComparison.OrdinalIgnoreCase))
        {
            path = path[..^(capabilities.Length + 1)];
        }
        address = new ScannerAddress(secure, host, uri.Port, path.Length == 0 ? "eSCL" : path);
        return true;
    }

    private static bool TryPort(string text, out int port) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out port) && port is >= 1 and <= 65535;

    /// <summary>
    /// A host name in lowercase or an IP address in its standard form (IPv6 keeps its zone);
    /// null when it is neither.
    /// </summary>
    private static string? NormalizeHost(string host)
    {
        if (host.Length == 0) return null;
        if (host.Contains(':')) return ParseIPv6(host)?.ToString().ToLowerInvariant();
        if (host.All(c => char.IsAsciiDigit(c) || c == '.'))
        {
            // Digits and dots only: it has to be a complete dotted IPv4 address ("192.168.1"
            // would otherwise pass as a host name, and IPAddress would read it as 192.168.0.1).
            string[] parts = host.Split('.');
            return parts.Length == 4 && parts.All(p => p.Length is > 0 and <= 3 && int.Parse(p, CultureInfo.InvariantCulture) <= 255)
                ? string.Join('.', parts.Select(p => int.Parse(p, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)))
                : null;
        }
        return Uri.CheckHostName(host) == UriHostNameType.Dns ? host.TrimEnd('.').ToLowerInvariant() : null;
    }

    /// <summary>
    /// An IPv6 address with an optional zone, an interface number ("fe80::1%12") or the name of an
    /// interface on this device, read as its number; null when it is not one, or when its zone is
    /// neither (IPAddress reads such a zone as none, and a link-local address without its interface
    /// cannot be reached).
    /// </summary>
    internal static IPAddress? ParseIPv6(string text)
    {
        if (!IPAddress.TryParse(text, out var ip) || ip.AddressFamily != AddressFamily.InterNetworkV6) return null;
        int percent = text.IndexOf('%');
        if (percent >= 0 && ip.ScopeId == 0)
        {
            string zone = text[(percent + 1)..];
            bool isZero = uint.TryParse(zone, NumberStyles.None, CultureInfo.InvariantCulture, out uint number) && number == 0;
            if (zone.Length > 0 && !isZero) return null;
        }
        return ip;
    }
}
