using System.Net.NetworkInformation;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/EsclDiscoveryTests.swift (same cases; the TXT record is the
// shared fixture Tests/Fixtures/Escl/txt-hp.txt). Covers what discovery hands over: TXT records, the
// addresses users type, and how a scanner's DNS-SD services become one endpoint.

public class EsclDiscoveryTests
{
    // MARK: - TXT records

    /// <summary>A TXT record in the shape HP all-in-ones advertise.</summary>
    private static string[] HpTxt => EsclFixtures.Lines(EsclFixtures.HpTxtFile);

    [Fact]
    public void TxtRecordReadsTheEsclKeys()
    {
        var txt = EsclTxtRecord.Parse(HpTxt);
        Assert.Equal("eSCL", txt.ResourcePath);
        Assert.Equal("HP Color LaserJet MFP M479fdw", txt.Model);
        Assert.Equal("564e4333-4230-3538-3930-a0b3cce51a2b", txt.Uuid);
        Assert.Equal("http://HPA1B2C3.local./#hId-pgAirPrint", txt.AdminUrl);
        Assert.Equal("2.63", txt.Version);
        Assert.Equal("Office", txt.Note);
        Assert.True(txt.Duplex);
        Assert.Equal(["platen", "adf"], txt.InputSources);
        Assert.Equal(["color", "grayscale", "binary"], txt.ColorSpaces);
        Assert.Equal(["application/pdf", "image/jpeg"], txt.DocumentFormats);
    }

    [Fact]
    public void TxtRecordDefaultsAndOddEntries()
    {
        var empty = EsclTxtRecord.Parse([]);
        Assert.Equal("eSCL", empty.ResourcePath);
        Assert.Null(empty.Model);
        Assert.Null(empty.Uuid);
        Assert.Null(empty.Duplex);
        Assert.Empty(empty.InputSources);

        var odd = EsclTxtRecord.Parse(
        [
            "RS=/scan/",          // keys ignore case; slashes are trimmed
            "ty=First", "ty=Second", // only the first occurrence counts
            "duplex=f", "flag", "=novalue", "is=Platen, ADF ,platen",
        ]);
        Assert.Equal("scan", odd.ResourcePath);
        Assert.Equal("First", odd.Model);
        Assert.False(odd.Duplex);
        Assert.Equal(["platen", "adf"], odd.InputSources);

        // A present but empty rs means the root of the host.
        Assert.Equal("", EsclTxtRecord.Parse(["rs="]).ResourcePath);
        Assert.Null(EsclTxtRecord.Parse(["duplex=maybe"]).Duplex);
    }

    [Theory]
    [InlineData("564E4333-4230-3538-3930-A0B3CCE51A2B", "564e4333423035383930a0b3cce51a2b")]
    [InlineData("urn:uuid:564e4333-4230-3538-3930-a0b3cce51a2b", "564e4333423035383930a0b3cce51a2b")]
    [InlineData("{564e4333-4230-3538-3930-a0b3cce51a2b}", "564e4333423035383930a0b3cce51a2b")]
    [InlineData("  ", null)]
    [InlineData(null, null)]
    public void UuidKeysCompareTheFormsDevicesUse(string? uuid, string? key)
    {
        Assert.Equal(key, EsclTxtRecord.UuidKey(uuid));
    }

    // MARK: - Addresses users type

    [Theory]
    [InlineData("192.168.1.50", false, "192.168.1.50", 80, "eSCL", "192.168.1.50", "http://192.168.1.50/eSCL/")]
    [InlineData(" 192.168.001.050 ", false, "192.168.1.50", 80, "eSCL", "192.168.1.50", "http://192.168.1.50/eSCL/")]
    [InlineData("Scanner.Local", false, "scanner.local", 80, "eSCL", "scanner.local", "http://scanner.local/eSCL/")]
    [InlineData("epson.local:8080", false, "epson.local", 8080, "eSCL", "epson.local:8080", "http://epson.local:8080/eSCL/")]
    [InlineData("http://192.168.1.50", false, "192.168.1.50", 80, "eSCL", "192.168.1.50", "http://192.168.1.50/eSCL/")]
    [InlineData("https://10.0.0.7", true, "10.0.0.7", 443, "eSCL", "https://10.0.0.7", "https://10.0.0.7/eSCL/")]
    [InlineData("https://10.0.0.7:8443/eSCL/", true, "10.0.0.7", 8443, "eSCL", "https://10.0.0.7:8443", "https://10.0.0.7:8443/eSCL/")]
    [InlineData("http://host:9090/scan/v2", false, "host", 9090, "scan/v2", "http://host:9090/scan/v2", "http://host:9090/scan/v2/")]
    [InlineData("http://10.0.0.7/eSCL/ScannerCapabilities", false, "10.0.0.7", 80, "eSCL", "10.0.0.7", "http://10.0.0.7/eSCL/")]
    [InlineData("10.0.0.7/eSCL", false, "10.0.0.7", 80, "eSCL", "10.0.0.7", "http://10.0.0.7/eSCL/")]
    [InlineData("[fe80::1%12]:8080", false, "fe80::1%12", 8080, "eSCL", "[fe80::1%12]:8080", "http://[fe80::1]:8080/eSCL/")]
    [InlineData("2001:DB8::5", false, "2001:db8::5", 80, "eSCL", "[2001:db8::5]", "http://[2001:db8::5]/eSCL/")]
    [InlineData("[2001:db8::5]", false, "2001:db8::5", 80, "eSCL", "[2001:db8::5]", "http://[2001:db8::5]/eSCL/")]
    [InlineData("https://[2001:db8::5]:9443", true, "2001:db8::5", 9443, "eSCL", "https://[2001:db8::5]:9443", "https://[2001:db8::5]:9443/eSCL/")]
    public void AddressesParseAndNormalize(string text, bool secure, string host, int port, string path,
                                           string canonical, string baseUri)
    {
        Assert.True(ScannerAddress.TryParse(text, out var address, out string error), error);
        Assert.Equal(secure, address!.Secure);
        Assert.Equal(host, address.Host);
        Assert.Equal(port, address.Port);
        Assert.Equal(path, address.ResourcePath);
        Assert.Equal(canonical, address.ToString());
        Assert.Equal(baseUri, address.BaseUri.AbsoluteUri);
        // The canonical text reads back as the same address.
        Assert.Equal(address, ScannerAddress.Parse(canonical));
    }

    [Fact]
    public void ZonedIPv6AddressesStayUsable()
    {
        var address = ScannerAddress.Parse("[fe80::1%12]:8080");
        var uri = new Uri(address.BaseUri, "ScannerCapabilities");
        Assert.Equal(System.UriHostNameType.IPv6, uri.HostNameType);
        Assert.Equal("fe80::1%12", uri.DnsSafeHost);
        Assert.Equal(8080, uri.Port);
        Assert.Equal("[fe80::1%12]:8080", address.Authority);
    }

    /// <summary>The loopback interface's name, as the system's interface-name lookup takes it.</summary>
    private static string LoopbackName =>
        OperatingSystem.IsWindows() ? "loopback_0" : OperatingSystem.IsMacOS() ? "lo0" : "lo";

    [Fact]
    public void NamedZonesReadAsTheirInterfaceIndex()
    {
        int index = NetworkInterface.IPv6LoopbackInterfaceIndex;
        Assert.True(index > 0);
        var address = ScannerAddress.Parse($"[fe80::1%{LoopbackName}]:8080");
        Assert.Equal($"fe80::1%{index}", address.Host);
        Assert.Equal($"[fe80::1%{index}]:8080", address.ToString());
        Assert.Equal(address, ScannerAddress.Parse(address.ToString()));
        Assert.Equal($"fe80::1%{index}", ScannerAddress.Parse($"http://[fe80::1%{LoopbackName}]:8080").Host);
        // A zone of 0 or none at all is no zone; one that names no interface is refused, not dropped.
        Assert.Equal("fe80::1", ScannerAddress.Parse("[fe80::1%0]").Host);
        Assert.Equal("fe80::1", ScannerAddress.Parse("[fe80::1%]").Host);
        Assert.False(ScannerAddress.TryParse("[fe80::1%nosuch0]", out _, out _));
    }

    [Theory]
    [InlineData("", "Enter the scanner's IP address or host name.")]
    [InlineData("   ", "Enter the scanner's IP address or host name.")]
    [InlineData("192.168.1", "\"192.168.1\" is not a valid IP address or host name.")]
    [InlineData("300.1.1.1", "\"300.1.1.1\" is not a valid IP address or host name.")]
    [InlineData("scanner:0", "The port must be a number from 1 to 65535.")]
    [InlineData("scanner:70000", "The port must be a number from 1 to 65535.")]
    [InlineData("scanner:http", "The port must be a number from 1 to 65535.")]
    [InlineData("my scanner", "An address cannot contain spaces.")]
    [InlineData("ftp://10.0.0.7", "Use an address that starts with http:// or https://, or just the IP address or host name.")]
    [InlineData("http://user:pw@10.0.0.7", "Leave out the user name and password; scanners do not need them.")]
    [InlineData("[fe80::1", "An IPv6 address in brackets needs its closing \"]\".")]
    [InlineData("[fe80::1]x", "That is not a valid address.")]
    [InlineData("bad_host!", "\"bad_host!\" is not a valid IP address or host name.")]
    [InlineData("[fe80::1%nosuch0]", "\"fe80::1%nosuch0\" is not a valid IP address or host name.")]
    [InlineData("fe80::1%99999999999", "\"fe80::1%99999999999\" is not a valid IP address or host name.")]
    [InlineData("http://[fe80::1%nosuch0]:8080", "That is not a valid address.")]
    public void BadAddressesSayWhatIsWrong(string text, string message)
    {
        Assert.False(ScannerAddress.TryParse(text, out var address, out string error));
        Assert.Null(address);
        Assert.Equal(message, error);
        Assert.Equal(message, Assert.Throws<FormatException>(() => ScannerAddress.Parse(text)).Message);
    }

    [Fact]
    public void AddressesCompareByTheirCanonicalForm()
    {
        Assert.Equal(ScannerAddress.Parse("http://SCANNER.local:80/eSCL"), ScannerAddress.Parse("scanner.local"));
        Assert.NotEqual(ScannerAddress.Parse("https://scanner.local"), ScannerAddress.Parse("scanner.local"));
        Assert.NotEqual(ScannerAddress.Parse("scanner.local:8080"), ScannerAddress.Parse("scanner.local"));
        Assert.Null(ScannerAddress.Create(false, "host", 0, "eSCL"));
        Assert.Null(ScannerAddress.Create(false, "not a host", 80, "eSCL"));
        Assert.Equal("http://host/", ScannerAddress.Create(false, "host", 80, "")!.BaseUri.AbsoluteUri);
    }

    // MARK: - Services → endpoints

    private static EsclService Service(string instance, bool secure, string[] addresses, string[] txt,
                                       int port = 0, string? host = "HPA1B2C3.local") =>
        new($"id-{instance}-{secure}", instance, secure, host, addresses, port == 0 ? (secure ? 443 : 80) : port, txt);

    [Fact]
    public void BothServicesOfOneScannerMergeHttpsFirst()
    {
        var endpoints = EsclEndpoint.Choose(
        [
            Service("HP M479 (A1B2C3)", secure: false, ["fe80::1", "192.168.1.20", "2001:db8::20"], HpTxt),
            Service("HP M479 (A1B2C3)", secure: true, ["192.168.1.20"], HpTxt),
        ]);
        var endpoint = Assert.Single(endpoints);
        Assert.Equal("uuid:564e4333423035383930a0b3cce51a2b", endpoint.Key);
        Assert.Equal("HP Color LaserJet MFP M479fdw", endpoint.Name);
        Assert.Equal("564e4333-4230-3538-3930-a0b3cce51a2b", endpoint.Uuid);
        // HTTPS first; IPv4, then the host name, then IPv6; link-local without a zone skipped.
        Assert.Equal(
        [
            "https://192.168.1.20", "https://hpa1b2c3.local",
            "192.168.1.20", "hpa1b2c3.local", "[2001:db8::20]",
        ], endpoint.Addresses.Select(a => a.ToString()));
    }

    [Fact]
    public void EndpointsKeepTheResourcePathPortAndZonedAddresses()
    {
        var endpoint = Assert.Single(EsclEndpoint.Choose(
        [
            Service("Canon", secure: false, ["fe80::5%7"], ["rs=/scan", "ty=Canon MF743C"], port: 8080, host: null),
        ]));
        Assert.Equal("name:canon", endpoint.Key);
        Assert.Null(endpoint.Uuid);
        var address = Assert.Single(endpoint.Addresses);
        Assert.Equal("http://[fe80::5]:8080/scan/", address.BaseUri.AbsoluteUri);
        Assert.Equal("fe80::5%7", address.BaseUri.DnsSafeHost);
    }

    [Fact]
    public void AddressesWhoseZoneNamesNoInterfaceAreSkipped()
    {
        var endpoint = Assert.Single(EsclEndpoint.Choose(
        [
            Service("Canon", secure: false, ["fe80::5%nosuch0", "2001:db8::9%nosuch0", $"fe80::6%{LoopbackName}"],
                    ["ty=Canon MF743C"], host: null),
        ]));
        Assert.Equal([$"[fe80::6%{NetworkInterface.IPv6LoopbackInterfaceIndex}]"], endpoint.Addresses.Select(a => a.ToString()));
    }

    [Fact]
    public void ScannersStayApartAndUnusableServicesAreDropped()
    {
        string[] other = ["ty=Epson ET-4850", "UUID=cfe92100-67c4-11d4-a45f-f8d0273e1a0b"];
        var endpoints = EsclEndpoint.Choose(
        [
            Service("HP", secure: false, ["192.168.1.20"], HpTxt),
            Service("Epson", secure: false, ["192.168.1.30"], other),
            Service("Broken port", secure: false, ["192.168.1.40"], ["ty=X"], port: 70000),
            Service("No address", secure: false, ["fe80::9"], ["ty=Y"], host: null),
            // The _uscans service of the HP without a UUID of its own: the instance name ties it.
            Service("HP", secure: true, ["192.168.1.20"], ["ty=HP Color LaserJet MFP M479fdw"]),
        ]);
        Assert.Equal(["HP Color LaserJet MFP M479fdw", "Epson ET-4850"], endpoints.Select(e => e.Name));
        Assert.Equal("https://192.168.1.20", endpoints[0].Addresses[0].ToString());
        Assert.Equal("uuid:cfe9210067c411d4a45ff8d0273e1a0b", endpoints[1].Key);
    }

    [Fact]
    public void WithoutAModelTheInstanceNameIsTheName()
    {
        var endpoint = Assert.Single(EsclEndpoint.Choose([Service("Office scanner", false, ["10.0.0.9"], [])]));
        Assert.Equal("Office scanner", endpoint.Name);
        Assert.Equal("eSCL", endpoint.Txt.ResourcePath);
    }
}
