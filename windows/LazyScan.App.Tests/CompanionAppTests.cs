using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyScan.App.Services;
using LazyScan.App.Services.Companion;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// The phone link's Windows pieces: a phone's document as queue pages (decoded with WIC), the
// firewall and network readers (read only), and the certificate kept in the user's store. Windows
// only; the protocol and its loopback tests are in LazyScan.Core.Tests. DNS-SD is never
// exercised here: it would advertise on the real network.

/// <summary>
/// A test that adds a certificate and a key to a store of the user's own (named for the tests) and
/// removes them again. It runs where COMPLETESCANNER_CERT_STORE_TESTS=1 (CI); elsewhere it is
/// skipped, so a developer's certificate stores are left alone.
/// </summary>
public sealed class CertificateStoreFactAttribute : FactAttribute
{
    public CertificateStoreFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("COMPLETESCANNER_CERT_STORE_TESTS") != "1")
        {
            Skip = "Set COMPLETESCANNER_CERT_STORE_TESTS=1 to let this test use a certificate store of its own.";
        }
    }
}

public class CompanionAppTests
{
    private static RgbaImage Picture(int width, int height, byte red)
    {
        var pixels = new byte[width * height * 4];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = red;
            pixels[i + 1] = 40;
            pixels[i + 2] = 80;
            pixels[i + 3] = 255;
        }
        return new RgbaImage(width, height, pixels);
    }

    private static CompanionImage Jpeg(int width, int height, int dpi = 200) =>
        new(WpfImageCodec.EncodeJpeg(Picture(width, height, 200), dpi), CompanionImageFormat.Jpeg, width, height, dpi, ColorMode.Color);

    private static CompanionDocument Document() => new(
        "Receipt",
        [
            new CompanionPage(Jpeg(40, 60)) { RotationQuarterTurns = 1, Side = PageSide.Front, SheetIndex = 0 },
            new CompanionPage(Jpeg(40, 60)) { Side = PageSide.Back, SheetIndex = 0, Original = Jpeg(80, 100), Capture = Capture },
        ])
    {
        SuggestedName = "Lunch 2026-10-20",
    };

    /// <summary>What the phone's camera recorded about the second page: its corners in the 80 × 100 photo, an A4 scale.</summary>
    private static CaptureFacts Capture => new(
        new Quad(new PointD(10, 12), new PointD(70, 14), new PointD(68, 95), new PointD(8, 92)), 80, 100)
    {
        Scale = new CaptureScaleResult(CaptureScaleBasis.Paper, "a4", 5, 40, 60, 8.2677, 11.6929),
    };

    [Fact]
    public void PhoneDocument_BecomesQueuePages()
    {
        // Through the package format, as it arrives.
        var document = CompanionPackage.Read(CompanionPackage.Make(Document()));
        var pages = CompanionPages.ToScannedPages(document, CompanionTarget.New, queueHasPages: true, WpfImageCodec.Decode);
        Assert.Equal(2, pages.Count);
        Assert.All(pages, page => Assert.Equal(PageSource.Phone, page.Source));
        Assert.All(pages, page => Assert.Equal("From phone", PhotoImport.SourceLabel(page)));
        // The rotation the phone had still to apply is applied to the pixels.
        Assert.Equal((60, 40), (pages[0].Image.Width, pages[0].Image.Height));
        Assert.Equal(0, pages[0].RotationQuarterTurns);
        Assert.Equal(200, pages[0].Dpi);
        Assert.Equal((PageSide?)PageSide.Front, pages[0].Side);
        Assert.Equal(0, pages[0].SheetIndex);
        // A new document starts its own document in the queue, with its name.
        Assert.Equal(DocumentBreak.Split, pages[0].DocumentBreak);
        Assert.Equal("Lunch 2026-10-20", pages[0].DocumentLabel);
        Assert.Equal(DocumentBreak.Automatic, pages[1].DocumentBreak);
        // The page as photographed is its other version.
        Assert.True(pages[1].CanSwapVersions);
        Assert.Equal(GeometryBasis.Perspective, pages[1].Geometry?.Basis);
        Assert.Equal((80, 100), (pages[1].Alternate!.Image!.Width, pages[1].Alternate!.Image!.Height));
        Assert.Equal((40, 60), (pages[1].Image.Width, pages[1].Image.Height));
        Assert.Null(pages[0].Alternate);
        // What the phone's camera recorded comes with the page.
        Assert.Equal(Capture, pages[1].Capture);
        Assert.Null(pages[0].Capture);
    }

    [Fact]
    public void PhoneDocument_AddedToTheCurrentOneJoinsIt()
    {
        var pages = CompanionPages.ToScannedPages(Document(), CompanionTarget.Current, queueHasPages: true, WpfImageCodec.Decode);
        Assert.All(pages, page => Assert.Equal(DocumentBreak.Automatic, page.DocumentBreak));
        Assert.All(pages, page => Assert.Null(page.DocumentLabel));
        // Into an empty queue a new document needs no split, only its name.
        var first = CompanionPages.ToScannedPages(Document(), CompanionTarget.New, queueHasPages: false, WpfImageCodec.Decode)[0];
        Assert.Equal(DocumentBreak.Automatic, first.DocumentBreak);
        Assert.Equal("Lunch 2026-10-20", first.DocumentLabel);
    }

    [Fact]
    public void FirewallState_JudgesTheNetworksReceivedOn()
    {
        const string app = @"C:\Program Files\CompleteScanner\LazyScan.exe";
        // Allowed for Private at the firewall's question, which blocks Public; a public virtual switch is connected too.
        FirewallRule[] rules =
        [
            new("CompleteScanner", app, true, true, true, FirewallProfiles.Private, 6, "*"),
            new("CompleteScanner", app, true, false, true, FirewallProfiles.Public, 6, "*"),
        ];
        var state = new FirewallState(true, FirewallProfiles.Private | FirewallProfiles.Public, true, rules,
                                      FirewallProfiles.Domain | FirewallProfiles.Private | FirewallProfiles.Public);
        Assert.Equal(CompanionFirewallVerdict.Blocked, state.Verdict(app, 52731));
        Assert.Equal(CompanionFirewallVerdict.Allowed, state.Verdict(app, 52731, FirewallProfiles.Private));
        Assert.Empty(state.BlockingRules(app, FirewallProfiles.Private));
        Assert.Equal(CompanionFirewallVerdict.Blocked, state.Verdict(app, 52731, FirewallProfiles.Public));
        Assert.Equal(["CompleteScanner"], state.BlockingRules(app, FirewallProfiles.Public));
        // The firewall off for the profile received on.
        var privateOff = state with { EnabledProfiles = FirewallProfiles.Public };
        Assert.Equal(CompanionFirewallVerdict.Off, privateOff.Verdict(app, 52731, FirewallProfiles.Private));
        Assert.Empty(privateOff.BlockingRules(app, FirewallProfiles.Private));
        Assert.Equal(CompanionFirewallVerdict.Unknown, FirewallState.Unknown.Verdict(app, 52731, FirewallProfiles.Private));
        Assert.Empty(FirewallState.Unknown.BlockingRules(app));
    }

    [Fact]
    public void FirewallReader_ReadsWithoutChangingAnything()
    {
        // A program that has no rules: whatever the firewall says, nothing is about it.
        string path = Path.Combine(Path.GetTempPath(), "CompleteScanner-no-such-program-" + Guid.NewGuid().ToString("N") + ".exe");
        var state = FirewallReader.Read(path);
        Assert.Empty(state.Rules);
        if (state.Read)
        {
            Assert.Contains(state.Verdict(path, CompanionProtocol.DefaultPort),
                            new[] { CompanionFirewallVerdict.WillAsk, CompanionFirewallVerdict.Off });
        }
        else
        {
            Assert.Equal(CompanionFirewallVerdict.Unknown, state.Verdict(path, CompanionProtocol.DefaultPort));
        }
    }

    [Fact]
    public void NetworkSource_ReadsTheConnectedNetworks()
    {
        using var source = new WindowsNetworkSource();
        var networks = source.Networks();
        foreach (var network in networks)
        {
            Assert.StartsWith("{", network.Id);
            Assert.All(network.Interfaces, adapter => Assert.True(Guid.TryParse(adapter.AdapterId, out _)));
        }
    }

    [CertificateStoreFact]
    public async Task Certificate_IsKeptRenewedWithItsKeyAndServesTls()
    {
        const string storeName = "CompleteScannerTests";
        var store = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser);
        try
        {
            var first = store.Current();
            Assert.True(first.HasPrivateKey);
            using (var key = first.GetECDsaPublicKey())
            {
                Assert.Equal(256, key!.KeySize);
            }
            Assert.Equal(CompanionCertificateStore.FriendlyName, first.FriendlyName);
            byte[] pin = SpkiFingerprint.Of(first.RawData)!;
            // A second store object (the next app start) finds the same certificate.
            var again = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser).Current();
            Assert.Equal(first.Thumbprint, again.Thumbprint);

            // SChannel serves TLS with the stored key (an ephemeral one would fail here).
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var serve = Task.Run(async () =>
            {
                using var client = await listener.AcceptTcpClientAsync();
                await using var tls = new SslStream(client.GetStream());
                await tls.AuthenticateAsServerAsync(again, false, false);
            });
            using (var tcp = new TcpClient())
            {
                await tcp.ConnectAsync(IPAddress.Loopback, port);
                await using var tls = new SslStream(tcp.GetStream(), false,
                    (_, certificate, _, _) => certificate is not null && SpkiFingerprint.Matches(SpkiFingerprint.Of(certificate.GetRawCertData())!, pin));
                await tls.AuthenticateAsClientAsync("localhost");
                Assert.True(tls.IsAuthenticated);
            }
            await serve.WaitAsync(TimeSpan.FromSeconds(10));

            // Reset pairing: a new key, so the old pin no longer matches.
            var renewed = store.Renew();
            Assert.False(SpkiFingerprint.Matches(SpkiFingerprint.Of(renewed.RawData)!, pin));
            using var check = new X509Store(storeName, StoreLocation.CurrentUser);
            check.Open(OpenFlags.ReadOnly);
            Assert.Single(check.Certificates.Cast<X509Certificate2>(), c => c.FriendlyName == CompanionCertificateStore.FriendlyName);
        }
        finally
        {
            EmptyStore(storeName);
        }
    }

    [CertificateStoreFact]
    public void Certificate_KeepsTheOldOneWhenNoNewKeyCanBeMade()
    {
        const string storeName = "CompleteScannerTestsRenew";
        var store = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser);
        try
        {
            var first = store.Current();
            string keyName = KeyName(first)!;
            Assert.True(CngKey.Exists(keyName));

            // Reset pairing when no key can be made: it fails, and the old certificate and key stay.
            var makeKey = store.NewKey;
            store.NewKey = () => throw new CryptographicException("The key storage provider is not available.");
            Assert.Throws<CryptographicException>(() => store.Renew());
            Assert.Equal(first.Thumbprint, store.Current().Thumbprint);
            Assert.True(CngKey.Exists(keyName));
            var reopened = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser).Current();
            Assert.Equal(first.Thumbprint, reopened.Thumbprint);
            Assert.True(reopened.HasPrivateKey);

            // Once a key can be made, the reset replaces the certificate and deletes the old key.
            store.NewKey = makeKey;
            var renewed = store.Renew();
            Assert.NotEqual(first.Thumbprint, renewed.Thumbprint);
            Assert.Equal(renewed.Thumbprint, store.Current().Thumbprint);
            Assert.False(CngKey.Exists(keyName));
            using var check = new X509Store(storeName, StoreLocation.CurrentUser);
            check.Open(OpenFlags.ReadOnly);
            Assert.Single(check.Certificates.Cast<X509Certificate2>(), c => c.FriendlyName == CompanionCertificateStore.FriendlyName);
        }
        finally
        {
            EmptyStore(storeName);
        }
    }

    private static string? KeyName(X509Certificate2 certificate)
    {
        using var key = certificate.GetECDsaPrivateKey();
        return (key as ECDsaCng)?.Key.KeyName;
    }

    /// <summary>Removes every certificate and its key from the tests' own store.</summary>
    private static void EmptyStore(string storeName)
    {
        using var cleanup = new X509Store(storeName, StoreLocation.CurrentUser);
        cleanup.Open(OpenFlags.ReadWrite);
        foreach (var certificate in cleanup.Certificates.Cast<X509Certificate2>().ToList())
        {
            try
            {
                using var key = certificate.GetECDsaPrivateKey();
                if (key is ECDsaCng cng) cng.Key.Delete();
            }
            catch (CryptographicException)
            {
            }
            cleanup.Remove(certificate);
        }
    }
}
