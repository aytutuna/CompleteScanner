import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/SpkiFingerprintTests.cs (same vectors). The Windows-only
// case that makes certificates with .NET's CertificateRequest has no twin here.

/// Test vectors both platforms check: a P-256 certificate made once with OpenSSL.
enum CompanionVectors {
    static let certificateBase64 =
        "MIIBkTCCATegAwIBAgICEjQwCgYIKoZIzj0EAwIwJzElMCMGA1UEAwwcQ29tcGxldGVTY2FubmVyIHRlc3QgZGVza3RvcDAeFw0yNjEwMjAxOTU5NTNaFw0zNjEwMTcxOTU5NTNaMCcxJTAjBgNVBAMMHENvbXBsZXRlU2Nhbm5lciB0ZXN0IGRlc2t0b3AwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASrFvbVkah5L96QuAcjfzhKh5b5hdfmc1MRk26RaZyQtBDiRCQ/QbohqBmuTVtFspZZ8tZf5ZT9mBLd4/FLOgX1o1MwUTAdBgNVHQ4EFgQUiiMmYf4nZVZXg4OUTPJYUS+BLcMwHwYDVR0jBBgwFoAUiiMmYf4nZVZXg4OUTPJYUS+BLcMwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiAeCEetpwei5JEtTio+5qel6xpNUsEYkjtlBJFSAJ2ivwIhAOmF6fkUCL0pHwOZjRTiC490wmrDm7BUTzY+08uYp/3z"

    static let spkiHex =
        "3059301306072a8648ce3d020106082a8648ce3d03010703420004ab16f6d591a8792fde90b807237f384a8796f985d7e6735311936e91699c90b410e244243f41ba21a819ae4d5b45b29659f2d65fe594fd9812dde3f14b3a05f5"

    static let fingerprintHex = "4754937b5f808034d63d5120e93859f11f43efe07081d3bab47996730943312e"
    static let fingerprintText = "R1STe1-AgDTWPVEg6ThZ8R9D7-BwgdO6tHmWcwlDMS4"
    static let checkCode = "725115"

    static var certificate: Data { Data(base64Encoded: certificateBase64)! }
    static var fingerprint: Data { hexData(fingerprintHex) }

    /// The bytes 0, 1, 2, … as a device secret, its SHA-256 and its text.
    static var secret: Data { Data((0..<32).map { UInt8($0) }) }
    static let secretHash = "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"
    static let secretText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    /// The bytes 0…15 as a pairing token, and its text.
    static var token: Data { Data((0..<16).map { UInt8($0) }) }
    static let tokenText = "AAECAwQFBgcICQoLDA0ODw"

    static func hexData(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}

final class SpkiFingerprintTests: XCTestCase {
    func testSharedCertificate_HasTheSharedFingerprint() throws {
        let spki = try XCTUnwrap(SpkiFingerprint.subjectPublicKeyInfo(CompanionVectors.certificate))
        XCTAssertEqual(SpkiFingerprint.hex(spki), CompanionVectors.spkiHex)
        let fingerprint = try XCTUnwrap(SpkiFingerprint.of(CompanionVectors.certificate))
        XCTAssertEqual(SpkiFingerprint.hex(fingerprint), CompanionVectors.fingerprintHex)
        XCTAssertEqual(SpkiFingerprint.text(fingerprint), CompanionVectors.fingerprintText)
        XCTAssertEqual(SpkiFingerprint.hex(SpkiFingerprint.ofSubjectPublicKeyInfo(spki)), CompanionVectors.fingerprintHex)
    }

    func testP256Point_RebuildsTheSubjectPublicKeyInfo() {
        let spki = CompanionVectors.hexData(CompanionVectors.spkiHex)
        let point = Data(spki.suffix(SpkiFingerprint.p256PointByteCount))
        XCTAssertEqual(SpkiFingerprint.p256SubjectPublicKeyInfo(point), spki)
        XCTAssertEqual([UInt8](spki.prefix(26)), SpkiFingerprint.p256Prefix)
        XCTAssertNil(SpkiFingerprint.p256SubjectPublicKeyInfo(Data(point.prefix(64))))
        var compressed = [UInt8](point)
        compressed[0] = 0x02
        XCTAssertNil(SpkiFingerprint.p256SubjectPublicKeyInfo(Data(compressed)))
    }

    func testCheckCode_IsSixDigitsOfTheFingerprint() {
        XCTAssertEqual(SpkiFingerprint.checkCode(CompanionVectors.fingerprint), CompanionVectors.checkCode)
        XCTAssertEqual(SpkiFingerprint.formatCheckCode(CompanionVectors.checkCode), "725 115")
        XCTAssertEqual(SpkiFingerprint.checkCode(Data(count: 32)), "000000")
        // 0x000F4240 = 1,000,000 → 0; 0x000F4241 → 1, with leading zeros.
        XCTAssertEqual(SpkiFingerprint.checkCode(Data([0x00, 0x0F, 0x42, 0x41] + [UInt8](repeating: 0, count: 28))), "000001")
        XCTAssertEqual(SpkiFingerprint.checkCode(Data([1, 2, 3])), "")
        XCTAssertEqual(SpkiFingerprint.formatCheckCode("12345"), "12345")
    }

    func testMatches_ComparesWholeFingerprints() {
        let fingerprint = CompanionVectors.fingerprint
        XCTAssertTrue(SpkiFingerprint.matches(fingerprint, Data(fingerprint)))
        var other = [UInt8](fingerprint)
        other[31] ^= 1
        XCTAssertFalse(SpkiFingerprint.matches(fingerprint, Data(other)))
        XCTAssertFalse(SpkiFingerprint.matches(Data(fingerprint.prefix(31)), Data(fingerprint.prefix(31))))
        XCTAssertFalse(SpkiFingerprint.matches(Data(), Data()))
    }

    func testMalformedCertificates_HaveNoFingerprint() {
        let good = [UInt8](CompanionVectors.certificate)
        func with(_ index: Int, _ value: UInt8) -> Data {
            var copy = good
            copy[index] = value
            return Data(copy)
        }
        XCTAssertNil(SpkiFingerprint.of(Data()))
        XCTAssertNil(SpkiFingerprint.of(Data([0x30])))
        XCTAssertNil(SpkiFingerprint.of(Data(good.prefix(100))))
        XCTAssertNil(SpkiFingerprint.of(Data(good.dropLast())))
        XCTAssertNil(SpkiFingerprint.of(Data(good + [0x00])))
        XCTAssertNil(SpkiFingerprint.of(with(0, 0x31)))                         // not a SEQUENCE
        XCTAssertNil(SpkiFingerprint.of(with(1, 0x80)))                         // indefinite length
        XCTAssertNil(SpkiFingerprint.of(with(1, 0x85)))                         // a length of five bytes
        XCTAssertNil(SpkiFingerprint.of(Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])))  // longer than the data
        XCTAssertNil(SpkiFingerprint.of(with(4, 0x31)))                         // tbsCertificate not a SEQUENCE
        XCTAssertNil(SpkiFingerprint.of(with(13, 0x04)))                        // serial number not an INTEGER
        XCTAssertNil(SpkiFingerprint.of(with(3, 0x1F)))                         // a length that is not the data's
        XCTAssertNil(SpkiFingerprint.of(with(8, 0xBF)))                         // a high tag number
    }
}
