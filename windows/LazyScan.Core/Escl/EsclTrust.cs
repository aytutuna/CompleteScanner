using System.Globalization;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Escl/EsclTrust.swift (the store, the validator's rules and the
// same escl-trust.json keys; the TLS hook and X509Certificate2 stay platform-specific).
//
// Trust for eSCL over HTTPS (_uscans). Scanners make their own certificates, which Windows
// cannot check, so a scanner's certificate is trusted the first time the app connects to it
// (trust on first use) and pinned: its public key (SPKI) SHA-256 is kept in
// %APPDATA%\CompleteScanner\escl-trust.json, and a scanner that later shows a different key
// is refused with a clear warning until the user trusts the new one.

/// <summary>What the trust store says about a certificate a scanner presented.</summary>
public enum EsclTrustVerdict
{
    /// <summary>Neither this certificate nor the scanner has been trusted before.</summary>
    Unknown,
    /// <summary>The certificate is trusted (pinned, or valid for Windows).</summary>
    Trusted,
    /// <summary>The scanner was trusted with a different certificate.</summary>
    Changed,
    /// <summary>The scanner presented no certificate that could be pinned.</summary>
    Invalid,
}

/// <summary>One trusted scanner certificate (an entry of escl-trust.json).</summary>
public sealed class EsclTrustedCertificate
{
    /// <summary>SHA-256 of the certificate's public key (SubjectPublicKeyInfo), lowercase hex.</summary>
    public string Fingerprint { get; set; } = "";
    /// <summary>The scanner's UUID (<see cref="EsclTxtRecord.UuidKey"/>); "" when it was not known.</summary>
    public string DeviceUuid { get; set; } = "";
    /// <summary>Where the certificate was seen ("host:port", see <see cref="ScannerAddress.Authority"/>).</summary>
    public List<string> Addresses { get; set; } = [];
    /// <summary>The scanner's name when it was trusted (for people reading the file).</summary>
    public string Name { get; set; } = "";
    /// <summary>When the user trusted it.</summary>
    public DateTimeOffset? Trusted { get; set; }
}

/// <summary>The contents of escl-trust.json.</summary>
public sealed class EsclTrustFile
{
    public List<EsclTrustedCertificate> Certificates { get; set; } = [];
}

/// <summary>
/// The trusted scanner certificates (escl-trust.json), safe to use from any thread. The file
/// is re-read for every check and before every write, since several windows of the app may
/// share it; certificates trusted while the file could not be written stay trusted for the
/// rest of the session. It follows the settings-file rules (CONTRACTS.md, rule 6).
/// </summary>
public sealed class EsclTrustStore
{
    /// <summary>Addresses remembered per certificate; the oldest are dropped beyond this.</summary>
    private const int MaxAddresses = 8;

    private readonly string _path;
    private readonly object _gate = new();
    private EsclTrustFile _file;
    /// <summary>Certificates trusted (and the address they were trusted at) that are not in the file yet: its last write failed.</summary>
    private readonly List<(EsclTrustedCertificate Pin, string Address)> _unsaved = [];

    public EsclTrustStore() : this(StoreFiles.DefaultDirectory) { }

    /// <summary>Keeps escl-trust.json in <paramref name="directory"/> instead of %APPDATA% (tests, harnesses).</summary>
    public EsclTrustStore(string directory)
    {
        _path = Path.Combine(directory, "escl-trust.json");
        _file = StoreFiles.Load<EsclTrustFile>(_path) ?? new EsclTrustFile();
    }

    /// <summary>
    /// Whether <paramref name="fingerprint"/> may be trusted for the scanner with
    /// <paramref name="deviceUuid"/> (null when unknown) at <paramref name="authority"/>.
    /// A pinned public key is trusted wherever it shows up (only the scanner holds its private
    /// key); the address it was reached at, and the scanner's UUID when the pin did not have
    /// one, are remembered. Otherwise, a scanner trusted before with another key — the same
    /// UUID, or, when either UUID is unknown, the same address — is
    /// <see cref="EsclTrustVerdict.Changed"/> (<paramref name="previous"/> is that entry). A
    /// pinned key that claims the UUID of a scanner trusted with another key is Changed too:
    /// a key vouches only for the scanner it was trusted for.
    /// </summary>
    public EsclTrustVerdict Check(string fingerprint, string? deviceUuid, string authority,
                                  out EsclTrustedCertificate? previous)
    {
        previous = null;
        if (fingerprint.Length == 0) return EsclTrustVerdict.Invalid;
        string uuid = EsclTxtRecord.UuidKey(deviceUuid) ?? "";
        string address = authority.ToLowerInvariant();
        lock (_gate)
        {
            Reload();
            if (_file.Certificates.FirstOrDefault(c => c.Fingerprint == fingerprint) is { } pinned)
            {
                if (uuid.Length > 0 && pinned.DeviceUuid != uuid
                    && _file.Certificates.FirstOrDefault(c => c.DeviceUuid == uuid) is { } other)
                {
                    previous = other;
                    return EsclTrustVerdict.Changed;
                }
                bool learned = false;
                if (pinned.DeviceUuid.Length == 0 && uuid.Length > 0)
                {
                    pinned.DeviceUuid = uuid;
                    learned = true;
                }
                if (!pinned.Addresses.Contains(address))
                {
                    pinned.Addresses.Add(address);
                    if (pinned.Addresses.Count > MaxAddresses) pinned.Addresses.RemoveAt(0);
                    learned = true;
                }
                if (learned) Save();
                return EsclTrustVerdict.Trusted;
            }
            previous = _file.Certificates.FirstOrDefault(c => SameScanner(c, uuid, address));
            return previous is null ? EsclTrustVerdict.Unknown : EsclTrustVerdict.Changed;
        }
    }

    /// <summary>
    /// Trusts <paramref name="fingerprint"/> for a scanner, replacing whatever was trusted for
    /// that scanner before (see <see cref="Check"/>), and saves the file.
    /// </summary>
    public void Trust(string fingerprint, string? deviceUuid, string authority, string name)
    {
        if (fingerprint.Length == 0) throw new ArgumentException("No certificate to trust.", nameof(fingerprint));
        string uuid = EsclTxtRecord.UuidKey(deviceUuid) ?? "";
        string address = authority.ToLowerInvariant();
        lock (_gate)
        {
            Reload();
            _unsaved.RemoveAll(u => Replaces(u.Pin, fingerprint, uuid, address));
            _file.Certificates.RemoveAll(c => Replaces(c, fingerprint, uuid, address));
            var pin = new EsclTrustedCertificate
            {
                Fingerprint = fingerprint,
                DeviceUuid = uuid,
                Addresses = [address],
                Name = name,
                Trusted = DateTimeOffset.Now,
            };
            _file.Certificates.Add(pin);
            if (!Save()) _unsaved.Add((pin, address));
        }
    }

    /// <summary>
    /// Re-reads the file (under <see cref="_gate"/>): another window of the app may have trusted
    /// or replaced a certificate meanwhile, and writing the copy loaded earlier would undo that.
    /// Certificates trusted here that could not be saved are applied to it again.
    /// </summary>
    private void Reload()
    {
        var file = StoreFiles.Load<EsclTrustFile>(_path) ?? _file;
        foreach (var (pin, address) in _unsaved)
        {
            if (file.Certificates.Contains(pin)) continue;
            file.Certificates.RemoveAll(c => Replaces(c, pin.Fingerprint, pin.DeviceUuid, address));
            file.Certificates.Add(pin);
        }
        _file = file;
    }

    /// <summary>Writes the file (under <see cref="_gate"/>); false when it could not be written.</summary>
    private bool Save()
    {
        if (!StoreFiles.Write(_file, _path)) return false;
        _unsaved.Clear();
        return true;
    }

    /// <summary>Whether trusting <paramref name="fingerprint"/> for that scanner replaces <paramref name="entry"/>.</summary>
    private static bool Replaces(EsclTrustedCertificate entry, string fingerprint, string uuid, string address) =>
        entry.Fingerprint == fingerprint || SameScanner(entry, uuid, address);

    /// <summary>The trusted certificates (copies).</summary>
    public IReadOnlyList<EsclTrustedCertificate> Certificates
    {
        get
        {
            lock (_gate)
            {
                return [.. _file.Certificates.Select(c => new EsclTrustedCertificate
                {
                    Fingerprint = c.Fingerprint,
                    DeviceUuid = c.DeviceUuid,
                    Addresses = [.. c.Addresses],
                    Name = c.Name,
                    Trusted = c.Trusted,
                })];
            }
        }
    }

    private static bool SameScanner(EsclTrustedCertificate entry, string uuid, string address) =>
        uuid.Length > 0 && entry.DeviceUuid.Length > 0
            ? entry.DeviceUuid == uuid
            : entry.Addresses.Contains(address);
}

/// <summary>A scanner's certificate was refused: not trusted yet, changed, or unusable.</summary>
public sealed class EsclCertificateException : Exception
{
    public EsclTrustVerdict Verdict { get; }
    public string DeviceName { get; }
    /// <summary>The scanner's UUID as known when connecting; null when unknown.</summary>
    public string? DeviceUuid { get; }
    /// <summary>"host:port" the certificate was presented at.</summary>
    public string Authority { get; }
    /// <summary>SPKI SHA-256 of the presented certificate, lowercase hex ("" when there was none).</summary>
    public string Fingerprint { get; }
    /// <summary>The previously trusted certificate, for <see cref="EsclTrustVerdict.Changed"/>.</summary>
    public EsclTrustedCertificate? Previous { get; }
    /// <summary>The certificate's subject, e.g. "CN=HPA1B2C3"; "" when there was none.</summary>
    public string Subject { get; }

    public EsclCertificateException(EsclTrustVerdict verdict, string deviceName, string? deviceUuid, string authority,
                                    string fingerprint, string subject, EsclTrustedCertificate? previous = null)
        : base(MessageFor(verdict, deviceName))
    {
        Verdict = verdict;
        DeviceName = deviceName;
        DeviceUuid = deviceUuid;
        Authority = authority;
        Fingerprint = fingerprint;
        Subject = subject;
        Previous = previous;
    }

    /// <summary>The certificate can be trusted by the user (it exists and can be pinned).</summary>
    public bool CanTrust => (Verdict is EsclTrustVerdict.Unknown or EsclTrustVerdict.Changed) && Fingerprint.Length > 0;

    private static string MessageFor(EsclTrustVerdict verdict, string name) => verdict switch
    {
        EsclTrustVerdict.Changed =>
            $"The security certificate of {name} has changed since you trusted it, so Lazy Scan did not connect. "
            + "A firmware update or a reset of the scanner can change it, but so can another device pretending to be your scanner.",
        EsclTrustVerdict.Invalid =>
            $"{name} did not present a usable security certificate, so Lazy Scan did not connect.",
        _ => $"{name} uses a security certificate that has not been trusted yet, so Lazy Scan did not connect.",
    };
}

/// <summary>Fingerprints of scanner certificates.</summary>
public static class EsclCertificates
{
    /// <summary>SHA-256 of the certificate's SubjectPublicKeyInfo, lowercase hex (the key, not the whole certificate, is pinned).</summary>
    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexStringLower(SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo()));

    /// <summary>"AB:CD:…" for people to compare; groups of <paramref name="bytesPerLine"/> bytes per line when positive.</summary>
    public static string Format(string fingerprint, int bytesPerLine = 0)
    {
        var pairs = Enumerable.Range(0, fingerprint.Length / 2)
            .Select(i => fingerprint.Substring(i * 2, 2).ToUpperInvariant()).ToList();
        if (bytesPerLine <= 0) return string.Join(':', pairs);
        return string.Join('\n', pairs.Chunk(bytesPerLine).Select(line => string.Join(':', line)));
    }
}

/// <summary>
/// Checks the certificates one scanner presents, against <see cref="EsclTrustStore"/>. A
/// certificate Windows accepts (valid chain, matching name) is trusted as is; any other is
/// trusted only when pinned, or, for <paramref name="firstUse"/>, provisionally until
/// <see cref="RememberDevice"/>. A refusal is kept for <see cref="TakeRejection"/>, since
/// HttpClient reports it only as a failed connection. Safe to use from any thread.
/// </summary>
/// <param name="firstUse">
/// The fingerprint of a certificate the store does not know (<see cref="EsclTrustVerdict.Unknown"/>)
/// that may be used to ask the scanner who it is: it is accepted without being pinned, and
/// <see cref="RememberDevice"/> pins it once the scanner's UUID shows it is not another key
/// for a scanner trusted before (trust on first use).
/// </param>
public sealed class EsclCertificateValidator(EsclTrustStore store, string? deviceUuid, string deviceName,
                                             string? firstUse = null)
{
    /// <summary>A certificate accepted, where, and whether it was pinned or only accepted as <see cref="_firstUse"/>.</summary>
    private sealed record Accepted(string Fingerprint, string Authority, string Subject, bool Pinned);

    private readonly object _gate = new();
    private EsclCertificateException? _rejection;
    /// <summary>The certificate accepted last.</summary>
    private Accepted? _accepted;
    private string? _firstUse = firstUse;

    public string DeviceName { get; } = deviceName;
    public string? DeviceUuid { get; } = deviceUuid;

    /// <summary>The TLS check for a request to <paramref name="requestUri"/>.</summary>
    public bool Validate(Uri? requestUri, X509Certificate2? certificate, SslPolicyErrors errors)
    {
        if (errors == SslPolicyErrors.None && certificate is not null) return true;
        string authority = requestUri is null ? "" : AuthorityOf(requestUri);
        if (certificate is null)
        {
            Interlocked.Exchange(ref _rejection, new EsclCertificateException(
                EsclTrustVerdict.Invalid, DeviceName, DeviceUuid, authority, "", ""));
            return false;
        }
        string fingerprint = EsclCertificates.Fingerprint(certificate);
        var verdict = store.Check(fingerprint, DeviceUuid, authority, out var previous);
        lock (_gate)
        {
            if (verdict == EsclTrustVerdict.Trusted
                || (verdict == EsclTrustVerdict.Unknown && fingerprint == _firstUse))
            {
                _accepted = new Accepted(fingerprint, authority, certificate.Subject, verdict == EsclTrustVerdict.Trusted);
                return true;
            }
        }
        Interlocked.Exchange(ref _rejection, new EsclCertificateException(
            verdict, DeviceName, DeviceUuid, authority, fingerprint, certificate.Subject, previous));
        return false;
    }

    /// <summary>
    /// Checks the certificate the scanner was reached through against the UUID it reported
    /// (its capabilities). A pinned certificate learns the UUID when it did not have it yet: a
    /// certificate trusted for an address added by hand then also identifies the scanner when
    /// discovery finds it. A <c>firstUse</c> certificate is pinned now, with the UUID. Throws
    /// <see cref="EsclCertificateException"/> (<see cref="EsclTrustVerdict.Changed"/>, nothing
    /// pinned or learned) when another certificate is trusted for that scanner.
    /// </summary>
    public void RememberDevice(string? deviceUuid)
    {
        Accepted? accepted;
        lock (_gate) accepted = _accepted;
        if (accepted is null || (accepted.Pinned && deviceUuid is null)) return;
        string? uuid = deviceUuid ?? DeviceUuid;
        var verdict = store.Check(accepted.Fingerprint, uuid, accepted.Authority, out var previous);
        if (verdict == EsclTrustVerdict.Changed)
        {
            throw new EsclCertificateException(EsclTrustVerdict.Changed, DeviceName, uuid, accepted.Authority,
                                               accepted.Fingerprint, accepted.Subject, previous);
        }
        if (accepted.Pinned) return;
        if (verdict == EsclTrustVerdict.Unknown) store.Trust(accepted.Fingerprint, uuid, accepted.Authority, DeviceName);
        lock (_gate)
        {
            _firstUse = null;
            _accepted = accepted with { Pinned = true };
        }
    }

    /// <summary>The last refusal, cleared by reading it; null when nothing was refused since.</summary>
    public EsclCertificateException? TakeRejection() => Interlocked.Exchange(ref _rejection, null);

    /// <summary>A handler whose TLS connections are checked by this validator.</summary>
    public HttpMessageHandler CreateHandler() => new HttpClientHandler
    {
        ServerCertificateCustomValidationCallback = (request, certificate, _, errors) =>
            Validate(request.RequestUri, certificate, errors),
    };

    /// <summary>"host:port" of a request, in the form <see cref="ScannerAddress.Authority"/> uses.</summary>
    internal static string AuthorityOf(Uri uri)
    {
        string host = uri.HostNameType == UriHostNameType.IPv6 ? "[" + uri.DnsSafeHost + "]" : uri.DnsSafeHost;
        return $"{host.ToLowerInvariant()}:{uri.Port.ToString(CultureInfo.InvariantCulture)}";
    }
}
