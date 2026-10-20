import Foundation

// Twin of windows/CompleteScanner.Core/Companion/SpkiFingerprint.cs: the same DER walk, the same
// fingerprint, check code and test vectors on both platforms.

/// The fingerprint a phone pins a desktop's certificate by: the SHA-256 of the certificate's
/// SubjectPublicKeyInfo (the key, not the whole certificate, so a renewed certificate with the same
/// key keeps every pin). The SubjectPublicKeyInfo is found by a small DER walk over the
/// certificate's bytes (what `SecCertificateCopyData` returns), so both platforms hash exactly the
/// same bytes as .NET's `PublicKey.ExportSubjectPublicKeyInfo`.
public enum SpkiFingerprint {
    /// The fingerprint's length in bytes (SHA-256).
    public static let byteCount = 32

    /// The length of an uncompressed P-256 point (0x04, X, Y).
    public static let p256PointByteCount = 65

    /// The DER of a P-256 SubjectPublicKeyInfo up to its key: SEQUENCE { SEQUENCE { id-ecPublicKey,
    /// prime256v1 }, BIT STRING (no unused bits) }. Followed by the 65-byte point it is the whole SPKI.
    public static let p256Prefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    /// The SubjectPublicKeyInfo (its whole DER element) of the X.509 certificate `certificateDER`;
    /// nil when the bytes are not one well-formed certificate. Walks Certificate → tbsCertificate →
    /// [0] version (optional), serialNumber, signature, issuer, validity, subject →
    /// subjectPublicKeyInfo, checking every length against its parent.
    public static func subjectPublicKeyInfo(_ certificateDER: Data) -> Data? {
        let der = [UInt8](certificateDER)
        guard let certificate = readElement(der, offset: 0, limit: der.count),
              certificate.tag == 0x30, certificate.end == der.count,
              let tbs = readElement(der, offset: certificate.contentStart, limit: certificate.end), tbs.tag == 0x30
        else { return nil }
        var position = tbs.contentStart
        if position < tbs.end && der[position] == 0xA0 {
            guard let version = readElement(der, offset: position, limit: tbs.end) else { return nil }
            position = version.end
        }
        // serialNumber INTEGER, signature SEQUENCE, issuer SEQUENCE, validity SEQUENCE, subject SEQUENCE.
        let skipped: [UInt8] = [0x02, 0x30, 0x30, 0x30, 0x30]
        for tag in skipped {
            guard let element = readElement(der, offset: position, limit: tbs.end), element.tag == tag else { return nil }
            position = element.end
        }
        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }.
        guard let spki = readElement(der, offset: position, limit: tbs.end), spki.tag == 0x30,
              let algorithm = readElement(der, offset: spki.contentStart, limit: spki.end), algorithm.tag == 0x30,
              let key = readElement(der, offset: algorithm.end, limit: spki.end), key.tag == 0x03,
              key.end == spki.end
        else { return nil }
        return Data(der[position..<spki.end])
    }

    /// The fingerprint of `certificateDER`; nil when it is not a certificate.
    public static func of(_ certificateDER: Data) -> Data? {
        guard let spki = subjectPublicKeyInfo(certificateDER) else { return nil }
        return ofSubjectPublicKeyInfo(spki)
    }

    /// The fingerprint of a SubjectPublicKeyInfo's DER.
    public static func ofSubjectPublicKeyInfo(_ spki: Data) -> Data {
        Data(SHA256Digest.hash(spki))
    }

    /// The SubjectPublicKeyInfo of a P-256 key given as its uncompressed point (65 bytes starting with
    /// 0x04, what `SecKeyCopyExternalRepresentation` returns for a public key); nil for anything else.
    public static func p256SubjectPublicKeyInfo(_ uncompressedPoint: Data) -> Data? {
        let point = [UInt8](uncompressedPoint)
        guard point.count == p256PointByteCount, point[0] == 0x04 else { return nil }
        return Data(p256Prefix + point)
    }

    /// The fingerprint as the pairing code carries it: base64url without padding (43 characters).
    public static func text(_ fingerprint: Data) -> String {
        CompanionProtocol.encodeBase64Url(fingerprint)
    }

    /// The fingerprint as lowercase hex (64 digits), for logs and diagnostics.
    public static func hex(_ fingerprint: Data) -> String {
        [UInt8](fingerprint).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two fingerprints are the same, in time that does not depend on where they differ.
    public static func matches(_ fingerprint: Data, _ expected: Data) -> Bool {
        let a = [UInt8](fingerprint)
        let b = [UInt8](expected)
        guard a.count == byteCount, b.count == byteCount else { return false }
        var difference: UInt8 = 0
        for i in 0..<byteCount {
            difference |= a[i] ^ b[i]
        }
        return difference == 0
    }

    /// The six-digit check code people compare on the phone and the desktop when a pairing is entered
    /// by hand: the fingerprint's first four bytes as a big-endian number, modulo one million, with
    /// leading zeros ("004213"); "" for fewer than four bytes.
    public static func checkCode(_ fingerprint: Data) -> String {
        let bytes = [UInt8](fingerprint)
        guard bytes.count >= 4 else { return "" }
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let code = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - code.count) + code
    }

    /// The check code as shown: "004 213".
    public static func formatCheckCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// One DER element: its tag, where its content starts and where it ends (exclusive).
    private struct Element {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    /// The DER element at `offset`, which must end by `limit`. Low tag numbers only; definite lengths
    /// in short form or long form of up to four bytes.
    private static func readElement(_ der: [UInt8], offset: Int, limit: Int) -> Element? {
        guard offset >= 0, limit <= der.count, offset + 2 <= limit else { return nil }
        let tag = der[offset]
        guard tag & 0x1F != 0x1F else { return nil }
        var position = offset + 1
        let first = der[position]
        position += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, position + count <= limit else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(der[position])
                position += 1
            }
        }
        guard length <= limit - position else { return nil }
        return Element(tag: tag, contentStart: position, end: position + length)
    }
}
