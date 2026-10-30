using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;

namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Companion/SpkiFingerprint.swift: the same DER walk, the same
// fingerprint, check code and test vectors on both platforms.

/// <summary>
/// The fingerprint a phone pins a desktop's certificate by: the SHA-256 of the certificate's
/// SubjectPublicKeyInfo (the key, not the whole certificate, so a renewed certificate with the same
/// key keeps every pin). The SubjectPublicKeyInfo is found by a small DER walk over the
/// certificate's bytes (what an Apple client gets from <c>SecCertificateCopyData</c>), so both
/// platforms hash exactly the same bytes as .NET's <c>PublicKey.ExportSubjectPublicKeyInfo</c>.
/// </summary>
public static class SpkiFingerprint
{
    /// <summary>The fingerprint's length in bytes (SHA-256).</summary>
    public const int ByteCount = 32;

    /// <summary>The length of an uncompressed P-256 point (0x04, X, Y).</summary>
    public const int P256PointByteCount = 65;

    /// <summary>
    /// The DER of a P-256 SubjectPublicKeyInfo up to its key: SEQUENCE { SEQUENCE { id-ecPublicKey,
    /// prime256v1 }, BIT STRING (no unused bits) }. Followed by the 65-byte point it is the whole SPKI.
    /// </summary>
    public static ReadOnlySpan<byte> P256Prefix =>
    [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ];

    /// <summary>
    /// The SubjectPublicKeyInfo (its whole DER element) of the X.509 certificate
    /// <paramref name="certificateDer"/>; null when the bytes are not one well-formed certificate.
    /// Walks Certificate → tbsCertificate → [0] version (optional), serialNumber, signature,
    /// issuer, validity, subject → subjectPublicKeyInfo, checking every length against its parent.
    /// </summary>
    public static byte[]? SubjectPublicKeyInfo(ReadOnlySpan<byte> certificateDer)
    {
        if (!ReadElement(certificateDer, 0, certificateDer.Length, out var certificate)
            || certificate.Tag != 0x30 || certificate.End != certificateDer.Length)
        {
            return null;
        }
        if (!ReadElement(certificateDer, certificate.ContentStart, certificate.End, out var tbs) || tbs.Tag != 0x30)
        {
            return null;
        }
        int position = tbs.ContentStart;
        if (position < tbs.End && certificateDer[position] == 0xA0)
        {
            if (!ReadElement(certificateDer, position, tbs.End, out var version)) return null;
            position = version.End;
        }
        // serialNumber INTEGER, signature SEQUENCE, issuer SEQUENCE, validity SEQUENCE, subject SEQUENCE.
        ReadOnlySpan<byte> skipped = [0x02, 0x30, 0x30, 0x30, 0x30];
        foreach (byte tag in skipped)
        {
            if (!ReadElement(certificateDer, position, tbs.End, out var element) || element.Tag != tag) return null;
            position = element.End;
        }
        if (!ReadElement(certificateDer, position, tbs.End, out var spki) || spki.Tag != 0x30) return null;
        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }.
        if (!ReadElement(certificateDer, spki.ContentStart, spki.End, out var algorithm) || algorithm.Tag != 0x30
            || !ReadElement(certificateDer, algorithm.End, spki.End, out var key) || key.Tag != 0x03
            || key.End != spki.End)
        {
            return null;
        }
        return certificateDer[position..spki.End].ToArray();
    }

    /// <summary>The fingerprint of <paramref name="certificateDer"/>; null when it is not a certificate.</summary>
    public static byte[]? Of(ReadOnlySpan<byte> certificateDer) =>
        SubjectPublicKeyInfo(certificateDer) is { } spki ? SHA256.HashData(spki) : null;

    /// <summary>The fingerprint of a SubjectPublicKeyInfo's DER.</summary>
    public static byte[] OfSubjectPublicKeyInfo(ReadOnlySpan<byte> spki) => SHA256.HashData(spki);

    /// <summary>
    /// The SubjectPublicKeyInfo of a P-256 key given as its uncompressed point (65 bytes starting
    /// with 0x04, what <c>SecKeyCopyExternalRepresentation</c> returns for a public key); null for
    /// anything else.
    /// </summary>
    public static byte[]? P256SubjectPublicKeyInfo(ReadOnlySpan<byte> uncompressedPoint)
    {
        if (uncompressedPoint.Length != P256PointByteCount || uncompressedPoint[0] != 0x04) return null;
        var spki = new byte[P256Prefix.Length + P256PointByteCount];
        P256Prefix.CopyTo(spki);
        uncompressedPoint.CopyTo(spki.AsSpan(P256Prefix.Length));
        return spki;
    }

    /// <summary>The fingerprint as the pairing code carries it: base64url without padding (43 characters).</summary>
    public static string Text(ReadOnlySpan<byte> fingerprint) => CompanionProtocol.EncodeBase64Url(fingerprint);

    /// <summary>The fingerprint as lowercase hex (64 digits), for logs and diagnostics.</summary>
    public static string Hex(ReadOnlySpan<byte> fingerprint) => Convert.ToHexStringLower(fingerprint);

    /// <summary>Whether two fingerprints are the same, in time that does not depend on where they differ.</summary>
    public static bool Matches(ReadOnlySpan<byte> fingerprint, ReadOnlySpan<byte> expected) =>
        fingerprint.Length == ByteCount && expected.Length == ByteCount
        && CryptographicOperations.FixedTimeEquals(fingerprint, expected);

    /// <summary>
    /// The six-digit check code people compare on the phone and the desktop when a pairing is
    /// entered by hand: the fingerprint's first four bytes as a big-endian number, modulo one million,
    /// with leading zeros ("004213"); "" for fewer than four bytes.
    /// </summary>
    public static string CheckCode(ReadOnlySpan<byte> fingerprint)
    {
        if (fingerprint.Length < 4) return "";
        uint value = BinaryPrimitives.ReadUInt32BigEndian(fingerprint);
        return (value % 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
    }

    /// <summary>The check code as shown: "004 213".</summary>
    public static string FormatCheckCode(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;

    /// <summary>One DER element: its tag, where its content starts and where it ends (exclusive).</summary>
    private readonly record struct Element(byte Tag, int ContentStart, int End);

    /// <summary>
    /// The DER element at <paramref name="offset"/>, which must end by <paramref name="limit"/>.
    /// Low tag numbers only; definite lengths in short form or long form of up to four bytes.
    /// </summary>
    private static bool ReadElement(ReadOnlySpan<byte> der, int offset, int limit, out Element element)
    {
        element = default;
        if (offset < 0 || limit > der.Length || offset + 2 > limit) return false;
        byte tag = der[offset];
        if ((tag & 0x1F) == 0x1F) return false;
        int position = offset + 1;
        byte first = der[position++];
        long length;
        if (first < 0x80)
        {
            length = first;
        }
        else
        {
            int count = first & 0x7F;
            if (count == 0 || count > 4 || position + count > limit) return false;
            length = 0;
            for (int i = 0; i < count; i++) length = (length << 8) | der[position++];
        }
        if (length > limit - position) return false;
        element = new Element(tag, position, position + (int)length);
        return true;
    }
}
