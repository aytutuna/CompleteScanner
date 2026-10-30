import Foundation
import Security
import XCTest
@testable import LazyScanKit

// The desktop's certificate for the phone link (SelfSignedCertificate.swift), read back by the Security
// framework and by the DER reader the phone pins with. Swift only: the Windows app makes its
// certificate with .NET's CertificateRequest. The keys are made in memory, without a keychain.

final class SelfSignedCertificateTests: XCTestCase {
    /// 2026-10-20T08:30:00Z.
    private let now = Date(timeIntervalSince1970: 1_792_485_000)

    private func makeKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    private func publicPoint(_ key: SecKey) throws -> Data {
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        return try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    }

    func testMake_IsACertificateTheSystemReads() throws {
        let der = try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: try makeKey(), now: now)
        let certificate = try XCTUnwrap(SelfSignedCertificate.certificate(der))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "aytu-mac.local CompleteScanner")
        XCTAssertEqual(SecCertificateCopyData(certificate) as Data, der)
    }

    func testFingerprint_IsTheKeys() throws {
        let key = try makeKey()
        let der = try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: key, now: now)
        let spki = try XCTUnwrap(SpkiFingerprint.p256SubjectPublicKeyInfo(try publicPoint(key)))
        XCTAssertEqual(SpkiFingerprint.subjectPublicKeyInfo(der), spki)
        XCTAssertEqual(SpkiFingerprint.of(der), SpkiFingerprint.ofSubjectPublicKeyInfo(spki))
        // A new certificate for the same key keeps the pin.
        let renewed = try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: key, now: now.addingTimeInterval(86_400))
        XCTAssertNotEqual(renewed, der)
        XCTAssertEqual(SpkiFingerprint.of(renewed), SpkiFingerprint.of(der))
    }

    func testValidity_RoundTrips() throws {
        let der = try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: try makeKey(), now: now.addingTimeInterval(0.75))
        XCTAssertEqual(SelfSignedCertificate.notAfter(der), now.addingTimeInterval(SelfSignedCertificate.validity))
        XCTAssertEqual(SelfSignedCertificate.validityPeriod(der)?.notBefore, now.addingTimeInterval(-SelfSignedCertificate.backdate))
        // From 2050 the dates are GeneralizedTime.
        let late = Date(timeIntervalSince1970: 2_524_608_000) // 2050-01-01T00:00:00Z
        let lateDer = try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: try makeKey(), now: late)
        XCTAssertEqual(SelfSignedCertificate.notAfter(lateDer), late.addingTimeInterval(SelfSignedCertificate.validity))
        XCTAssertEqual(SelfSignedCertificate.validityPeriod(lateDer)?.notBefore, late.addingTimeInterval(-SelfSignedCertificate.backdate))
        XCTAssertNil(SelfSignedCertificate.notAfter(Data([0x30, 0x00])))
        XCTAssertNotNil(SelfSignedCertificate.notAfter(CompanionVectors.certificate))
    }

    func testTrust_WithItselfAsTheAnchor() throws {
        let der = try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: try makeKey(), now: now)
        let certificate = try XCTUnwrap(SelfSignedCertificate.certificate(der))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let made = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(made, [certificate] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(made, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetVerifyDate(made, now.addingTimeInterval(3600) as CFDate), errSecSuccess)
        var error: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(made, &error), "\(String(describing: error))")
    }

    func testSignature_VerifiesWithTheKey() throws {
        let key = try makeKey()
        let der = [UInt8](try SelfSignedCertificate.make(hostName: "aytu-mac.local", key: key, now: now))
        let certificate = try XCTUnwrap(SpkiFingerprint.readElement(der, offset: 0, limit: der.count))
        let tbs = try XCTUnwrap(SpkiFingerprint.readElement(der, offset: certificate.contentStart, limit: certificate.end))
        let algorithm = try XCTUnwrap(SpkiFingerprint.readElement(der, offset: tbs.end, limit: certificate.end))
        let signature = try XCTUnwrap(SpkiFingerprint.readElement(der, offset: algorithm.end, limit: certificate.end))
        XCTAssertEqual(signature.tag, 0x03)
        XCTAssertEqual(der[signature.contentStart], 0)
        let signed = Data(der[certificate.contentStart..<tbs.end])
        let value = Data(der[(signature.contentStart + 1)..<signature.end])
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        var error: Unmanaged<CFError>?
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, signed as CFData, value as CFData, &error))
    }

    func testSubjectAltName_OnlyForADnsName() throws {
        let san = Data(DerWriter.oid(SelfSignedCertificate.subjectAltNameOid))
        let named = try SelfSignedCertificate.make(hostName: "Aytus-MacBook-Pro.local", key: try makeKey(), now: now)
        XCTAssertNotNil(named.range(of: san))
        XCTAssertNotNil(named.range(of: Data("Aytus-MacBook-Pro.local".utf8)))
        let spoken = try SelfSignedCertificate.make(hostName: "Aytu's Mac", key: try makeKey(), now: now)
        XCTAssertNil(spoken.range(of: san))
        let certificate = try XCTUnwrap(SelfSignedCertificate.certificate(spoken))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Aytu's Mac CompleteScanner")
        XCTAssertTrue(SelfSignedCertificate.isDnsName("localhost"))
        XCTAssertFalse(SelfSignedCertificate.isDnsName(""))
        XCTAssertFalse(SelfSignedCertificate.isDnsName("-mac.local"))
        XCTAssertFalse(SelfSignedCertificate.isDnsName("mac..local"))
    }

    func testDer_Encodings() {
        XCTAssertEqual(DerWriter.oid(SelfSignedCertificate.ecdsaWithSha256), [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        XCTAssertEqual(DerWriter.oid([2, 5, 29, 17]), [0x06, 0x03, 0x55, 0x1D, 0x11])
        XCTAssertEqual(DerWriter.integer([2]), [0x02, 0x01, 0x02])
        XCTAssertEqual(DerWriter.integer([0x00, 0x00, 0x05]), [0x02, 0x01, 0x05])
        XCTAssertEqual(DerWriter.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(DerWriter.integer([]), [0x02, 0x01, 0x00])
        XCTAssertEqual(DerWriter.length(127), [0x7F])
        XCTAssertEqual(DerWriter.length(200), [0x81, 0xC8])
        XCTAssertEqual(DerWriter.length(300), [0x82, 0x01, 0x2C])
        XCTAssertEqual(DerWriter.bitString([0x80], unusedBits: 7), [0x03, 0x02, 0x07, 0x80])
        XCTAssertEqual(DerWriter.time(now), [0x17, 0x0D] + Array("261020083000Z".utf8))
        XCTAssertEqual(DerWriter.time(Date(timeIntervalSince1970: 2_524_608_000)), [0x18, 0x0F] + Array("20500101000000Z".utf8))
        XCTAssertEqual(DerWriter.explicit(0, DerWriter.integer([2])), [0xA0, 0x03, 0x02, 0x01, 0x02])
    }
}
