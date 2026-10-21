using System.Security.Cryptography.X509Certificates;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/EsclFixtures.swift: both suites read the same files in
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
        ("certificate-rsa2048.pem", "4ad3ab48789a9c2f6b9b8cb55503d2bdf9fa889488beca7137476c0e1bb4e4e9",
         "CN=CompleteScanner test scanner RSA-2048"),
        ("certificate-p256.pem", "61010433c5795ff33b96976a6bc6f2aa324a36b7182a1ddcab4d234744fe7d6c",
         "CN=CompleteScanner test scanner P-256"),
        ("certificate-p384.pem", "ef13555c8bd3534a2726779408e4e0c0ed39733864f463517d6181263f2fe199",
         "CN=CompleteScanner test scanner P-384"),
    ];

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
