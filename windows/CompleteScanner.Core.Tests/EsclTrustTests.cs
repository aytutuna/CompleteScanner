using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// eSCL only (see EsclTests): no Swift counterpart (the Mac connects through ImageCaptureCore).
// Certificate pinning for eSCL over HTTPS, the escl-trust.json and escl-hosts.json files, and
// one end-to-end check through a real TLS connection to a loopback server.

[Collection(WallClockCollection.Name)]
public sealed class EsclTrustTests : IDisposable
{
    private const string Uuid = "564e4333-4230-3538-3930-a0b3cce51a2b";
    private const string OtherUuid = "cfe92100-67c4-11d4-a45f-f8d0273e1a0b";
    private readonly string _directory;

    public EsclTrustTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "CompleteScannerTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private static X509Certificate2 SelfSigned(string subject)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest($"CN={subject}", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var ephemeral = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        // Reloaded from PKCS#12: Windows' TLS stack cannot serve a certificate with an ephemeral key.
        return X509CertificateLoader.LoadPkcs12(ephemeral.Export(X509ContentType.Pfx), null);
    }

    private static string Fingerprint(int n) => new string((char)('a' + n), 64);

    // MARK: - Trust store

    [Fact]
    public void FirstUseIsUnknownThenTrustedEverywhere()
    {
        var store = new EsclTrustStore(_directory);
        Assert.Equal(EsclTrustVerdict.Unknown, store.Check(Fingerprint(0), Uuid, "192.168.1.20:443", out var previous));
        Assert.Null(previous);

        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(0), Uuid, "192.168.1.20:443", out _));
        // The pinned key is trusted at another address too (DHCP), and that address is remembered.
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(0), null, "HPA1B2C3.local:443", out _));
        var entry = Assert.Single(new EsclTrustStore(_directory).Certificates);
        Assert.Equal(Fingerprint(0), entry.Fingerprint);
        Assert.Equal("564e4333423035383930a0b3cce51a2b", entry.DeviceUuid);
        Assert.Equal(["192.168.1.20:443", "hpa1b2c3.local:443"], entry.Addresses);
        Assert.Equal("HP M479", entry.Name);
        Assert.NotNull(entry.Trusted);
    }

    [Fact]
    public void ANewKeyForATrustedScannerIsAChange()
    {
        var store = new EsclTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");

        // Same UUID, anywhere.
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(1), Uuid.ToUpperInvariant(), "10.0.0.5:443", out var previous));
        Assert.Equal(Fingerprint(0), previous?.Fingerprint);
        // Same address, UUID unknown (an address added by hand).
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(1), null, "192.168.1.20:443", out _));
        // Same address but another scanner's UUID: a different device took the address.
        Assert.Equal(EsclTrustVerdict.Unknown, store.Check(Fingerprint(1), OtherUuid, "192.168.1.20:443", out _));
        // Another port is another endpoint.
        Assert.Equal(EsclTrustVerdict.Unknown, store.Check(Fingerprint(1), null, "192.168.1.20:8443", out _));
        Assert.Equal(EsclTrustVerdict.Invalid, store.Check("", Uuid, "192.168.1.20:443", out _));
    }

    [Fact]
    public void TrustingTheNewKeyReplacesTheOldOne()
    {
        var store = new EsclTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");
        store.Trust(Fingerprint(5), null, "10.0.0.9:443", "Other scanner");
        store.Trust(Fingerprint(1), Uuid, "192.168.1.20:443", "HP M479");

        var reloaded = new EsclTrustStore(_directory);
        Assert.Equal([Fingerprint(5), Fingerprint(1)], reloaded.Certificates.Select(c => c.Fingerprint));
        Assert.Equal(EsclTrustVerdict.Trusted, reloaded.Check(Fingerprint(1), Uuid, "192.168.1.20:443", out _));
        Assert.Equal(EsclTrustVerdict.Changed, reloaded.Check(Fingerprint(0), Uuid, "192.168.1.20:443", out _));
        Assert.Throws<ArgumentException>(() => reloaded.Trust("", Uuid, "x:1", "x"));
    }

    [Fact]
    public void LearningAnAddressKeepsWhatAnotherWindowTrusted()
    {
        const string scannerS = "192.168.1.20:443", scannerY = "192.168.1.30:443";
        var setup = new EsclTrustStore(_directory);
        setup.Trust(Fingerprint(0), Uuid, scannerS, "S");
        setup.Trust(Fingerprint(3), OtherUuid, scannerY, "Y");

        // Two windows of the app, each with the file as it was when it started.
        var windowA = new EsclTrustStore(_directory);
        var windowB = new EsclTrustStore(_directory);
        // B trusts S's new certificate, and a scanner A has never seen.
        windowB.Trust(Fingerprint(1), Uuid, scannerS, "S");
        windowB.Trust(Fingerprint(4), null, "10.0.0.7:443", "X");

        // A reaches Y at a new address (DHCP): the address is learned without undoing B's changes.
        Assert.Equal(EsclTrustVerdict.Trusted, windowA.Check(Fingerprint(3), OtherUuid, "192.168.1.31:443", out _));
        var reloaded = new EsclTrustStore(_directory);
        Assert.Equal([Fingerprint(3), Fingerprint(1), Fingerprint(4)], reloaded.Certificates.Select(c => c.Fingerprint));
        Assert.Equal(["192.168.1.30:443", "192.168.1.31:443"],
                     reloaded.Certificates.Single(c => c.Fingerprint == Fingerprint(3)).Addresses);

        // A also sees B's pins: S's new key is trusted, the old one is a change.
        var windowA2 = new EsclTrustStore(_directory);
        var stale = new EsclTrustStore(_directory);
        windowB.Trust(Fingerprint(2), Uuid, scannerS, "S");
        Assert.Equal(EsclTrustVerdict.Trusted, stale.Check(Fingerprint(2), Uuid, scannerS, out _));
        Assert.Equal(EsclTrustVerdict.Changed, windowA2.Check(Fingerprint(1), Uuid, scannerS, out var previous));
        Assert.Equal(Fingerprint(2), previous?.Fingerprint);
        Assert.Equal(EsclTrustVerdict.Trusted, windowA.Check(Fingerprint(4), null, "10.0.0.7:443", out _));
    }

    [Fact]
    public void APinnedKeyDoesNotVouchForAnotherScannersUuid()
    {
        var store = new EsclTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");
        // Pinned for an address added by hand, the scanner's UUID not known yet.
        store.Trust(Fingerprint(1), null, "hp.local:443", "hp.local");
        store.Trust(Fingerprint(2), OtherUuid, "10.0.0.9:443", "Other");

        // The key pinned by address claims the trusted scanner's UUID: a change, nothing learned.
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(1), Uuid, "hp.local:443", out var previous));
        Assert.Equal(Fingerprint(0), previous?.Fingerprint);
        Assert.Equal("", new EsclTrustStore(_directory).Certificates.Single(c => c.Fingerprint == Fingerprint(1)).DeviceUuid);
        // Another scanner's key claiming it, at the trusted scanner's own address too.
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(2), Uuid, "192.168.1.20:443", out previous));
        Assert.Equal(Fingerprint(0), previous?.Fingerprint);

        // Without a UUID, or with its own, a pinned key is still trusted anywhere.
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(1), null, "hp.local:443", out _));
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(2), OtherUuid, "10.0.0.10:443", out _));
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(0), Uuid, "10.0.0.11:443", out _));
        // A UUID nobody holds is learned.
        const string ThirdUuid = "e3248000-80ce-11db-8000-30055c773bcf";
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(1), ThirdUuid, "hp.local:443", out _));
        Assert.Equal("e324800080ce11db800030055c773bcf",
                     new EsclTrustStore(_directory).Certificates.Single(c => c.Fingerprint == Fingerprint(1)).DeviceUuid);

        // Trusting the key for the scanner it claims replaces that scanner's pin.
        store.Trust(Fingerprint(2), Uuid, "192.168.1.20:443", "HP M479");
        Assert.Equal([Fingerprint(1), Fingerprint(2)], new EsclTrustStore(_directory).Certificates.Select(c => c.Fingerprint));
    }

    [Fact]
    public void TrustedCertificatesStayTrustedWhenTheFileCannotBeWritten()
    {
        string path = Path.Combine(_directory, "escl-trust.json");
        var store = new EsclTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "S");

        // Writes fail from here on (the temporary file cannot be created); the file still reads.
        Directory.CreateDirectory(path + ".tmp");
        store.Trust(Fingerprint(1), OtherUuid, "192.168.1.30:443", "Y");
        Assert.Equal([Fingerprint(0)], new EsclTrustStore(_directory).Certificates.Select(c => c.Fingerprint));
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(1), OtherUuid, "192.168.1.30:443", out _));
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(1), null, "192.168.1.31:443", out _));
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(5), OtherUuid, "10.0.0.5:443", out var previous));
        Assert.Equal(Fingerprint(1), previous?.Fingerprint);

        // Another window changes the file meanwhile: its pins count, and the unsaved one is kept.
        File.WriteAllText(path, $$"""
            {"certificates": [
              {"fingerprint": "{{Fingerprint(0)}}", "deviceUuid": "564e4333423035383930a0b3cce51a2b", "addresses": ["192.168.1.20:443"], "name": "S"},
              {"fingerprint": "{{Fingerprint(4)}}", "deviceUuid": "", "addresses": ["10.0.0.7:443"], "name": "X"}
            ]}
            """);
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(4), null, "10.0.0.7:443", out _));
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(1), OtherUuid, "192.168.1.30:443", out _));

        // A later trust for the same scanner replaces the unsaved one, which does not come back.
        store.Trust(Fingerprint(2), OtherUuid, "192.168.1.30:443", "Y");
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(1), OtherUuid, "192.168.1.30:443", out previous));
        Assert.Equal(Fingerprint(2), previous?.Fingerprint);

        // Once the file can be written, the next write saves what was not saved.
        Directory.Delete(path + ".tmp");
        Assert.Equal(EsclTrustVerdict.Trusted, store.Check(Fingerprint(2), OtherUuid, "192.168.1.32:443", out _));
        var reloaded = new EsclTrustStore(_directory);
        Assert.Equal([Fingerprint(0), Fingerprint(4), Fingerprint(2)], reloaded.Certificates.Select(c => c.Fingerprint));
        Assert.Equal(["192.168.1.30:443", "192.168.1.32:443"],
                     reloaded.Certificates.Single(c => c.Fingerprint == Fingerprint(2)).Addresses);
    }

    [Fact]
    public void AnUndecodableTrustFileIsKeptAside()
    {
        string path = Path.Combine(_directory, "escl-trust.json");
        File.WriteAllText(path, "{ not json");
        var store = new EsclTrustStore(_directory);
        Assert.Empty(store.Certificates);
        Assert.Single(Directory.GetFiles(_directory, "escl-trust.unreadable-*.json"));

        // A field of the wrong type resets only that field.
        File.WriteAllText(path, $$"""
            {"certificates": [{"fingerprint": "{{Fingerprint(2)}}", "deviceUuid": 42, "addresses": ["a:1"], "name": "Kept"}]}
            """);
        var entry = Assert.Single(new EsclTrustStore(_directory).Certificates);
        Assert.Equal(Fingerprint(2), entry.Fingerprint);
        Assert.Equal("", entry.DeviceUuid);
        Assert.Equal("Kept", entry.Name);
    }

    [Fact]
    public void FingerprintsArePublicKeyHashesFormattedForPeople()
    {
        using var certificate = SelfSigned("FakeScanner");
        string fingerprint = EsclCertificates.Fingerprint(certificate);
        Assert.Equal(64, fingerprint.Length);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo())), fingerprint);
        Assert.Equal("AB:CD:01", EsclCertificates.Format("abcd01"));
        Assert.Equal("AA:BB\nCC", EsclCertificates.Format("aabbcc", bytesPerLine: 2));
    }

    // MARK: - Validator

    [Fact]
    public void TheValidatorTrustsWindowsValidCertificatesAndPinnedOnes()
    {
        using var certificate = SelfSigned("FakeScanner");
        var store = new EsclTrustStore(_directory);
        var validator = new EsclCertificateValidator(store, Uuid, "Fake MFP");
        var uri = new Uri("https://192.168.1.20/eSCL/ScannerCapabilities");

        Assert.True(validator.Validate(uri, certificate, SslPolicyErrors.None));
        Assert.Null(validator.TakeRejection());

        Assert.False(validator.Validate(uri, certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        var rejection = validator.TakeRejection();
        Assert.NotNull(rejection);
        Assert.Equal(EsclTrustVerdict.Unknown, rejection.Verdict);
        Assert.True(rejection.CanTrust);
        Assert.Equal("192.168.1.20:443", rejection.Authority);
        Assert.Equal("CN=FakeScanner", rejection.Subject);
        Assert.Equal(EsclCertificates.Fingerprint(certificate), rejection.Fingerprint);
        Assert.Equal("Fake MFP uses a security certificate that has not been trusted yet, so CompleteScanner did not connect.",
                     rejection.Message);
        Assert.Null(validator.TakeRejection()); // taken once

        store.Trust(rejection.Fingerprint, rejection.DeviceUuid, rejection.Authority, "Fake MFP");
        Assert.True(validator.Validate(uri, certificate,
                                       SslPolicyErrors.RemoteCertificateChainErrors | SslPolicyErrors.RemoteCertificateNameMismatch));

        Assert.False(validator.Validate(uri, null, SslPolicyErrors.RemoteCertificateNotAvailable));
        var missing = validator.TakeRejection()!;
        Assert.Equal(EsclTrustVerdict.Invalid, missing.Verdict);
        Assert.False(missing.CanTrust);
    }

    [Fact]
    public void APinMadeByAddressLearnsTheScannersUuid()
    {
        using var certificate = SelfSigned("FakeScanner");
        var store = new EsclTrustStore(_directory);
        string fingerprint = EsclCertificates.Fingerprint(certificate);
        store.Trust(fingerprint, null, "10.0.0.7:443", "10.0.0.7");
        var validator = new EsclCertificateValidator(store, deviceUuid: null, "10.0.0.7");
        validator.RememberDevice(Uuid); // nothing accepted yet: nothing to learn
        Assert.Equal("", Assert.Single(store.Certificates).DeviceUuid);

        Assert.True(validator.Validate(new Uri("https://10.0.0.7/eSCL/"), certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        validator.RememberDevice(Uuid);
        Assert.Equal("564e4333423035383930a0b3cce51a2b", Assert.Single(new EsclTrustStore(_directory).Certificates).DeviceUuid);
        // Discovery later finds the scanner by its UUID at another address, with another key.
        Assert.Equal(EsclTrustVerdict.Changed, store.Check(Fingerprint(3), Uuid, "192.168.1.20:443", out _));
    }

    [Fact]
    public void AuthoritiesMatchTheAddressForm()
    {
        Assert.Equal("[fe80::1%12]:8080",
                     EsclCertificateValidator.AuthorityOf(ScannerAddress.Parse("[fe80::1%12]:8080").BaseUri));
        Assert.Equal("scanner.local:443", EsclCertificateValidator.AuthorityOf(new Uri("https://Scanner.Local/eSCL/")));
        Assert.Equal(ScannerAddress.Parse("https://10.0.0.7:8443").Authority,
                     EsclCertificateValidator.AuthorityOf(ScannerAddress.Parse("https://10.0.0.7:8443").BaseUri));
    }

    // MARK: - Through a real TLS connection

    /// <summary>A loopback HTTPS server that answers every request with the capabilities fixture.</summary>
    private sealed class TlsScanner : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        private int _requests;

        public TlsScanner(X509Certificate2 certificate)
        {
            Certificate = certificate;
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _ = Serve();
        }

        public X509Certificate2 Certificate { get; set; }
        public int Port { get; }
        public int Requests => Volatile.Read(ref _requests);

        private async Task Serve()
        {
            while (!_stop.IsCancellationRequested)
            {
                TcpClient tcp;
                try
                {
                    tcp = await _listener.AcceptTcpClientAsync(_stop.Token);
                }
                catch (Exception)
                {
                    return;
                }
                _ = Handle(tcp);
            }
        }

        private async Task Handle(TcpClient tcp)
        {
            using (tcp)
            {
                try
                {
                    using var tls = new SslStream(tcp.GetStream());
                    await tls.AuthenticateAsServerAsync(Certificate);
                    var request = new StringBuilder();
                    var buffer = new byte[4096];
                    while (!request.ToString().Contains("\r\n\r\n", StringComparison.Ordinal))
                    {
                        int read = await tls.ReadAsync(buffer);
                        if (read == 0) return;
                        request.Append(Encoding.ASCII.GetString(buffer, 0, read));
                    }
                    Interlocked.Increment(ref _requests);
                    byte[] body = Encoding.UTF8.GetBytes(EsclTests.PlatenAndDuplexAdf);
                    await tls.WriteAsync(Encoding.ASCII.GetBytes(
                        $"HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n"));
                    await tls.WriteAsync(body);
                    await tls.FlushAsync();
                }
                catch (Exception)
                {
                    // The client refused the certificate.
                }
            }
        }

        public void Dispose()
        {
            _stop.Cancel();
            _listener.Stop();
        }
    }

    private static EsclClient Connect(EsclTrustStore store, int port, string? uuid) =>
        Connect(new EsclCertificateValidator(store, uuid, "Fake MFP"), port);

    private static EsclClient Connect(EsclCertificateValidator validator, int port)
    {
        var address = ScannerAddress.Parse($"https://127.0.0.1:{port}");
        return new EsclClient(address.BaseUri, validator.CreateHandler(), _ => throw new NotSupportedException(),
                              "Fake MFP", validator);
    }

    [Fact]
    public async Task AFirstUseCertificateIsPinnedOnlyOnceItsUuidIsChecked()
    {
        using var certificate = SelfSigned("FakeScanner");
        using var server = new TlsScanner(certificate);
        string fingerprint = EsclCertificates.Fingerprint(certificate);
        string authority = $"127.0.0.1:{server.Port}";
        var store = new EsclTrustStore(_directory);
        // The scanner the server claims to be (its capabilities report Uuid) is trusted with another key, elsewhere.
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");

        // Reached at an address it was never seen at, without its UUID: the key is new.
        using var plain = Connect(store, server.Port, uuid: null);
        var unknown = await Assert.ThrowsAsync<EsclCertificateException>(() => plain.GetCapabilitiesAsync());
        Assert.Equal(EsclTrustVerdict.Unknown, unknown.Verdict);
        Assert.Equal(0, server.Requests);

        // Used to ask who it is: it reports the trusted scanner's UUID, so it is a change and is not pinned.
        var validator = new EsclCertificateValidator(store, deviceUuid: null, authority, firstUse: fingerprint);
        using (var client = Connect(validator, server.Port))
        {
            var caps = await client.GetCapabilitiesAsync();
            var changed = Assert.Throws<EsclCertificateException>(() => validator.RememberDevice(caps.Uuid));
            Assert.Equal(EsclTrustVerdict.Changed, changed.Verdict);
            Assert.Equal(Fingerprint(0), changed.Previous?.Fingerprint);
            Assert.Equal(fingerprint, changed.Fingerprint);
            Assert.Equal(authority, changed.Authority);
            Assert.Equal(caps.Uuid, changed.DeviceUuid);
            Assert.True(changed.CanTrust);
        }
        Assert.Equal([Fingerprint(0)], new EsclTrustStore(_directory).Certificates.Select(c => c.Fingerprint));
        Assert.Equal(EsclTrustVerdict.Unknown, store.Check(fingerprint, null, authority, out _));
        // Another certificate than the one allowed is still refused.
        using (var otherClient = Connect(new EsclCertificateValidator(store, null, authority, firstUse: Fingerprint(7)), server.Port))
        {
            var refused = await Assert.ThrowsAsync<EsclCertificateException>(() => otherClient.GetCapabilitiesAsync());
            Assert.Equal(EsclTrustVerdict.Unknown, refused.Verdict);
        }
        Assert.Equal(1, server.Requests);

        // Trusting it for that scanner (the user confirmed the change) replaces the old pin.
        store.Trust(fingerprint, Uuid, authority, "HP M479");
        Assert.Equal([fingerprint], store.Certificates.Select(c => c.Fingerprint));

        // A scanner nobody trusted yet: pinned with its UUID once it answered.
        string fresh = Path.Combine(_directory, "fresh");
        var freshStore = new EsclTrustStore(fresh);
        var firstUse = new EsclCertificateValidator(freshStore, null, authority, firstUse: fingerprint);
        using (var client = Connect(firstUse, server.Port))
        {
            var caps = await client.GetCapabilitiesAsync();
            Assert.Empty(freshStore.Certificates);
            firstUse.RememberDevice(caps.Uuid);
        }
        var pin = Assert.Single(new EsclTrustStore(fresh).Certificates);
        Assert.Equal(fingerprint, pin.Fingerprint);
        Assert.Equal("564e4333423035383930a0b3cce51a2b", pin.DeviceUuid);
        Assert.Equal([authority], pin.Addresses);
    }

    [Fact]
    public async Task HttpsConnectsOnlyOnceTheCertificateIsTrustedAndRefusesAChangedOne()
    {
        using var first = SelfSigned("FakeScanner");
        using var second = SelfSigned("FakeScanner");
        using var server = new TlsScanner(first);
        var store = new EsclTrustStore(_directory);

        using (var client = Connect(store, server.Port, Uuid))
        {
            var unknown = await Assert.ThrowsAsync<EsclCertificateException>(() => client.GetCapabilitiesAsync());
            Assert.Equal(EsclTrustVerdict.Unknown, unknown.Verdict);
            Assert.Equal(EsclCertificates.Fingerprint(first), unknown.Fingerprint);
            Assert.Equal($"127.0.0.1:{server.Port}", unknown.Authority);
            Assert.Equal(0, server.Requests); // nothing was sent to an untrusted scanner
            store.Trust(unknown.Fingerprint, Uuid, unknown.Authority, "Fake MFP");
        }

        using (var client = Connect(store, server.Port, Uuid))
        {
            var caps = await client.GetCapabilitiesAsync();
            Assert.Equal("HP Color LaserJet MFP M479fdw", caps.MakeAndModel);
            Assert.Equal(1, server.Requests);
        }

        server.Certificate = second;
        using (var client = Connect(new EsclTrustStore(_directory), server.Port, Uuid))
        {
            var changed = await Assert.ThrowsAsync<EsclCertificateException>(() => client.GetCapabilitiesAsync());
            Assert.Equal(EsclTrustVerdict.Changed, changed.Verdict);
            Assert.Equal(EsclCertificates.Fingerprint(first), changed.Previous?.Fingerprint);
            Assert.StartsWith("The security certificate of Fake MFP has changed since you trusted it", changed.Message);
            Assert.Equal(1, server.Requests);
        }
    }

    // MARK: - Addresses added by hand (escl-hosts.json)

    [Fact]
    public void HostListAddsCanonicalAddressesOnce()
    {
        var hosts = new EsclHostList(_directory);
        Assert.Empty(hosts.Load());
        Assert.True(hosts.Add(ScannerAddress.Parse("http://192.168.1.50:80/eSCL")));
        Assert.False(hosts.Add(ScannerAddress.Parse("192.168.1.50")));
        Assert.True(hosts.Add(ScannerAddress.Parse("https://10.0.0.7")));
        Assert.Equal(["192.168.1.50", "https://10.0.0.7"], hosts.LoadEntries());
        Assert.True(hosts.Remove(ScannerAddress.Parse("192.168.1.50")));
        Assert.False(hosts.Remove(ScannerAddress.Parse("192.168.1.50")));
        Assert.Equal(["https://10.0.0.7"], hosts.LoadEntries());
    }

    [Fact]
    public void HandWrittenHostEntriesKeepWorking()
    {
        var hosts = new EsclHostList(_directory);
        File.WriteAllText(hosts.FilePath, """["192.168.1.50", "epson.local:8080", "not an address", "192.168.1.50"]""");
        Assert.Equal(["192.168.1.50", "epson.local:8080"], hosts.Load().Select(a => a.ToString()));
        // Adding keeps the other entries, including the one that is not an address.
        Assert.True(hosts.Add(ScannerAddress.Parse("10.0.0.9")));
        Assert.Equal(["192.168.1.50", "epson.local:8080", "not an address", "192.168.1.50", "10.0.0.9"], hosts.LoadEntries());
    }

    [Fact]
    public void AnUndecodableHostListIsKeptAside()
    {
        var hosts = new EsclHostList(_directory);
        File.WriteAllText(hosts.FilePath, """{"hosts": ["192.168.1.50"]}""");
        Assert.Empty(hosts.Load());
        Assert.Single(Directory.GetFiles(_directory, "escl-hosts.unreadable-*.json"));
        Assert.True(hosts.Add(ScannerAddress.Parse("10.0.0.9")));
        Assert.Equal(["10.0.0.9"], hosts.LoadEntries());
    }
}
