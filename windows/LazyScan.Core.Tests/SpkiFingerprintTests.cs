using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/SpkiFingerprintTests.swift (same vectors; the scanner
// certificates are the shared fixtures in Tests/Fixtures/Escl). C#-only case:
// MatchesDotNetSubjectPublicKeyInfo (makes certificates with CertificateRequest, which Swift lacks).

/// <summary>Test vectors both platforms check: a P-256 certificate made once with OpenSSL.</summary>
internal static class CompanionVectors
{
    public const string CertificateBase64 =
        "MIIBkTCCATegAwIBAgICEjQwCgYIKoZIzj0EAwIwJzElMCMGA1UEAwwcQ29tcGxldGVTY2FubmVyIHRlc3QgZGVza3RvcDAeFw0yNjEwMjAxOTU5NTNaFw0zNjEwMTcxOTU5NTNaMCcxJTAjBgNVBAMMHENvbXBsZXRlU2Nhbm5lciB0ZXN0IGRlc2t0b3AwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASrFvbVkah5L96QuAcjfzhKh5b5hdfmc1MRk26RaZyQtBDiRCQ/QbohqBmuTVtFspZZ8tZf5ZT9mBLd4/FLOgX1o1MwUTAdBgNVHQ4EFgQUiiMmYf4nZVZXg4OUTPJYUS+BLcMwHwYDVR0jBBgwFoAUiiMmYf4nZVZXg4OUTPJYUS+BLcMwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiAeCEetpwei5JEtTio+5qel6xpNUsEYkjtlBJFSAJ2ivwIhAOmF6fkUCL0pHwOZjRTiC490wmrDm7BUTzY+08uYp/3z";

    public const string SpkiHex =
        "3059301306072a8648ce3d020106082a8648ce3d03010703420004ab16f6d591a8792fde90b807237f384a8796f985d7e6735311936e91699c90b410e244243f41ba21a819ae4d5b45b29659f2d65fe594fd9812dde3f14b3a05f5";

    public const string FingerprintHex = "4754937b5f808034d63d5120e93859f11f43efe07081d3bab47996730943312e";
    public const string FingerprintText = "R1STe1-AgDTWPVEg6ThZ8R9D7-BwgdO6tHmWcwlDMS4";
    public const string CheckCode = "725115";

    public static byte[] Certificate => Convert.FromBase64String(CertificateBase64);
    public static byte[] Fingerprint => Convert.FromHexString(FingerprintHex);

    /// <summary>The bytes 0, 1, 2, … as a device secret, its SHA-256 and its text.</summary>
    public static byte[] Secret => [.. Enumerable.Range(0, 32).Select(i => (byte)i)];
    public const string SecretHash = "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd";
    public const string SecretText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

    /// <summary>The bytes 0…15 as a pairing token, and its text.</summary>
    public static byte[] Token => [.. Enumerable.Range(0, 16).Select(i => (byte)i)];
    public const string TokenText = "AAECAwQFBgcICQoLDA0ODw";
}

public class SpkiFingerprintTests
{
    [Fact]
    public void SharedCertificate_HasTheSharedFingerprint()
    {
        var spki = SpkiFingerprint.SubjectPublicKeyInfo(CompanionVectors.Certificate);
        Assert.NotNull(spki);
        Assert.Equal(CompanionVectors.SpkiHex, Convert.ToHexStringLower(spki));
        var fingerprint = SpkiFingerprint.Of(CompanionVectors.Certificate);
        Assert.NotNull(fingerprint);
        Assert.Equal(CompanionVectors.FingerprintHex, SpkiFingerprint.Hex(fingerprint));
        Assert.Equal(CompanionVectors.FingerprintText, SpkiFingerprint.Text(fingerprint));
        Assert.Equal(CompanionVectors.FingerprintHex, SpkiFingerprint.Hex(SpkiFingerprint.OfSubjectPublicKeyInfo(spki)));
    }

    [Fact]
    public void SharedScannerCertificates_HaveTheSharedFingerprints()
    {
        // RSA-2048, P-256 and P-384, the key types scanners use; the same vectors as eSCL pinning.
        foreach (var (file, fingerprint, subject) in EsclFixtures.Certificates)
        {
            byte[] der = EsclFixtures.CertificateDer(file);
            var digest = SpkiFingerprint.Of(der);
            Assert.NotNull(digest);
            Assert.Equal(fingerprint, SpkiFingerprint.Hex(digest));
            using var certificate = EsclFixtures.Certificate(file);
            Assert.Equal(subject, certificate.Subject);
            Assert.Equal(certificate.PublicKey.ExportSubjectPublicKeyInfo(), SpkiFingerprint.SubjectPublicKeyInfo(der));
            Assert.Equal(fingerprint, EsclCertificates.Fingerprint(certificate));
        }
    }

    [Fact]
    public void P256Point_RebuildsTheSubjectPublicKeyInfo()
    {
        byte[] spki = Convert.FromHexString(CompanionVectors.SpkiHex);
        byte[] point = spki[^SpkiFingerprint.P256PointByteCount..];
        Assert.Equal(spki, SpkiFingerprint.P256SubjectPublicKeyInfo(point));
        Assert.Equal(spki[..26], SpkiFingerprint.P256Prefix.ToArray());
        Assert.Null(SpkiFingerprint.P256SubjectPublicKeyInfo(point[..64]));
        var compressed = (byte[])point.Clone();
        compressed[0] = 0x02;
        Assert.Null(SpkiFingerprint.P256SubjectPublicKeyInfo(compressed));
    }

    [Fact]
    public void CheckCode_IsSixDigitsOfTheFingerprint()
    {
        Assert.Equal(CompanionVectors.CheckCode, SpkiFingerprint.CheckCode(CompanionVectors.Fingerprint));
        Assert.Equal("725 115", SpkiFingerprint.FormatCheckCode(CompanionVectors.CheckCode));
        Assert.Equal("000000", SpkiFingerprint.CheckCode(new byte[32]));
        // 0x000F4240 = 1,000,000 → 0; 0x000F4241 → 1, with leading zeros.
        Assert.Equal("000001", SpkiFingerprint.CheckCode([0x00, 0x0F, 0x42, 0x41, .. new byte[28]]));
        Assert.Equal("", SpkiFingerprint.CheckCode([1, 2, 3]));
        Assert.Equal("12345", SpkiFingerprint.FormatCheckCode("12345"));
    }

    [Fact]
    public void Matches_ComparesWholeFingerprints()
    {
        var fingerprint = CompanionVectors.Fingerprint;
        Assert.True(SpkiFingerprint.Matches(fingerprint, (byte[])fingerprint.Clone()));
        var other = (byte[])fingerprint.Clone();
        other[31] ^= 1;
        Assert.False(SpkiFingerprint.Matches(fingerprint, other));
        Assert.False(SpkiFingerprint.Matches(fingerprint[..31], fingerprint[..31]));
        Assert.False(SpkiFingerprint.Matches([], []));
    }

    [Fact]
    public void MalformedCertificates_HaveNoFingerprint()
    {
        byte[] good = CompanionVectors.Certificate;
        Assert.Null(SpkiFingerprint.Of([]));
        Assert.Null(SpkiFingerprint.Of([0x30]));
        Assert.Null(SpkiFingerprint.Of(good[..100]));
        Assert.Null(SpkiFingerprint.Of(good[..^1]));
        Assert.Null(SpkiFingerprint.Of([.. good, 0x00]));
        Assert.Null(SpkiFingerprint.Of(With(good, 0, 0x31)));                 // not a SEQUENCE
        Assert.Null(SpkiFingerprint.Of(With(good, 1, 0x80)));                 // indefinite length
        Assert.Null(SpkiFingerprint.Of(With(good, 1, 0x85)));                 // a length of five bytes
        Assert.Null(SpkiFingerprint.Of([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])); // longer than the data
        Assert.Null(SpkiFingerprint.Of(With(good, 4, 0x31)));                 // tbsCertificate not a SEQUENCE
        Assert.Null(SpkiFingerprint.Of(With(good, 13, 0x04)));                // serial number not an INTEGER
        Assert.Null(SpkiFingerprint.Of(With(good, 3, 0x1F)));                 // a length that is not the data's
        Assert.Null(SpkiFingerprint.Of(With(good, 8, 0xBF)));                 // a high tag number
    }

    [Fact]
    public void MatchesDotNetSubjectPublicKeyInfo()
    {
        using var ec = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var ecCertificate = new CertificateRequest("CN=EC", ec, HashAlgorithmName.SHA256)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        using var rsa = RSA.Create(2048);
        using var rsaCertificate = new CertificateRequest("CN=RSA", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        foreach (var certificate in new[] { ecCertificate, rsaCertificate })
        {
            Assert.Equal(certificate.PublicKey.ExportSubjectPublicKeyInfo(), SpkiFingerprint.SubjectPublicKeyInfo(certificate.RawData));
            Assert.Equal(EsclCertificates.Fingerprint(certificate), SpkiFingerprint.Hex(SpkiFingerprint.Of(certificate.RawData)!));
        }
        byte[] point = ec.ExportSubjectPublicKeyInfo()[^65..];
        Assert.Equal(ec.ExportSubjectPublicKeyInfo(), SpkiFingerprint.P256SubjectPublicKeyInfo(point));
    }

    private static byte[] With(byte[] data, int index, byte value)
    {
        var copy = (byte[])data.Clone();
        copy[index] = value;
        return copy;
    }
}
