using System.Security.Cryptography.X509Certificates;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/EsclFixtures.swift: both suites read the same files in
// Tests/Fixtures/Escl (copied next to this assembly by the project file), so the eSCL cases on the two
// platforms cannot drift apart.

/// <summary>The shared eSCL fixtures.</summary>
internal static class EsclFixtures
{
    /// <summary>An all-in-one: platen plus a feeder that scans both sides; discrete resolutions.</summary>
    public const string PlatenAndDuplexAdfFile = "capabilities-platen-duplex-adf.xml";
    /// <summary>A sheet-fed document scanner: feeder only, a resolution range, long-paper height.</summary>
    public const string FeederOnlyFile = "capabilities-feeder-only.xml";
    /// <summary>A flatbed-only scanner with no sizes, modes or formats listed.</summary>
    public const string BarePlatenFile = "capabilities-bare-platen.xml";
    /// <summary>Duplex announced only through AdfOptions.</summary>
    public const string DuplexOptionFile = "capabilities-duplex-option.xml";
    /// <summary>The ScanSettings document of a full-platen color scan of <see cref="PlatenAndDuplexAdfFile"/>.</summary>
    public const string PlatenColorRequestFile = "request-platen-color.xml";
    /// <summary>The ScanSettings document of a two-sided color feeder scan of <see cref="PlatenAndDuplexAdfFile"/>.</summary>
    public const string FeederTwoSidedRequestFile = "request-feeder-two-sided.xml";
    /// <summary>A TXT record in the shape HP all-in-ones advertise, one "key=value" entry per line.</summary>
    public const string HpTxtFile = "txt-hp.txt";

    /// <summary>Self-signed scanner certificates (PEM) and the SHA-256 of their SubjectPublicKeyInfo.</summary>
    public static readonly (string File, string Fingerprint, string Subject)[] Certificates =
    [
        ("certificate-rsa2048.pem", "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c",
         "CN=Lazy Scan test scanner RSA-2048"),
        ("certificate-p256.pem", "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4",
         "CN=Lazy Scan test scanner P-256"),
        ("certificate-p384.pem", "c287be8b8476f2aaa5d6f61eee6f4a7b062c89222ad861abc1265383e5f8d9bb",
         "CN=Lazy Scan test scanner P-384"),
    ];

    /// <summary>
    /// Two self-signed identities (certificate and private key, PKCS #12, password
    /// <see cref="LoopbackPassword"/>) and the SHA-256 of their SubjectPublicKeyInfo: the Swift suite's
    /// loopback HTTPS scanner serves them (EsclLoopbackTests.swift). Test fixtures only; no app ships a key.
    /// </summary>
    public static readonly (string File, string Fingerprint)[] LoopbackIdentities =
    [
        ("tls-scanner-a.p12", "68046922b1fd313907e2971191b98293b5bc61bd6e85a4b1cd03b679bb8883eb"),
        ("tls-scanner-b.p12", "db3aaa683e331d9399fc88ea6b47cf91ba78becdfd5e00e8d61a2b63e5faa5dd"),
    ];

    /// <summary>The password of the <see cref="LoopbackIdentities"/> files.</summary>
    public const string LoopbackPassword = "LazyScan-test";

    /// <summary>The folder the fixtures are copied to.</summary>
    public static string Directory => Path.Combine(AppContext.BaseDirectory, "Fixtures", "Escl");

    /// <summary>A fixture's path.</summary>
    public static string PathOf(string name) => Path.Combine(Directory, name);

    /// <summary>A text fixture with "\n" line breaks, whatever a checkout did to them.</summary>
    public static string Text(string name) => File.ReadAllText(PathOf(name)).Replace("\r\n", "\n");

    /// <summary>A text fixture's non-empty lines.</summary>
    public static string[] Lines(string name) => [.. Text(name).Split('\n').Where(line => line.Length > 0)];

    /// <summary>The DER bytes of a PEM certificate fixture.</summary>
    public static byte[] CertificateDer(string name)
    {
        string body = string.Concat(Text(name).Split('\n').Where(line => line.Length > 0 && !line.StartsWith("-----", StringComparison.Ordinal)));
        return Convert.FromBase64String(body);
    }

    /// <summary>A PEM certificate fixture, loaded by .NET.</summary>
    public static X509Certificate2 Certificate(string name) => X509CertificateLoader.LoadCertificate(CertificateDer(name));

    public static string PlatenAndDuplexAdf => Text(PlatenAndDuplexAdfFile);
    public static string FeederOnly => Text(FeederOnlyFile);
    public static string BarePlaten => Text(BarePlatenFile);
    public static string DuplexOption => Text(DuplexOptionFile);
}
