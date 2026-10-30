import XCTest
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/EsclTrustTests.cs (same cases), except the C# suite's two
// checks through a real TLS connection to a loopback server and its check of the loopback identities,
// whose twins are in EsclLoopbackTests with the client. Certificate pinning for eSCL over HTTPS and the
// escl-trust.json and escl-hosts.json files, including trust files written by either platform. The certificates are the shared fixtures in
// Tests/Fixtures/Escl; the validator gets a certificate's DER, its subject and the system's verdict,
// where the C# one gets an X509Certificate2 and SslPolicyErrors.

final class EsclTrustTests: XCTestCase {
    private let uuid = "564e4333-4230-3538-3930-a0b3cce51a2b"
    private let otherUuid = "cfe92100-67c4-11d4-a45f-f8d0273e1a0b"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompleteScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> EsclTrustStore {
        EsclTrustStore(directory: directory)
    }

    private var trustFileURL: URL { directory.appendingPathComponent(EsclTrustStore.fileName) }

    /// A made-up fingerprint: 64 times the letter n places after "a".
    private func fingerprint(_ n: Int) -> String {
        let letter: Character = Character(Unicode.Scalar(UInt8(97 + n)))
        return String(repeating: String(letter), count: 64)
    }

    private func fingerprints(_ certificates: [EsclTrustedCertificate]) -> [String] {
        var list: [String] = []
        for certificate in certificates {
            list.append(certificate.fingerprint)
        }
        return list
    }

    private func entry(_ certificates: [EsclTrustedCertificate], _ fingerprint: String) -> EsclTrustedCertificate? {
        for certificate in certificates where certificate.fingerprint == fingerprint {
            return certificate
        }
        return nil
    }

    private func files(withPrefix prefix: String) throws -> [String] {
        var found: [String] = []
        let names: [String] = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            found.append(name)
        }
        return found
    }

    // MARK: - Trust store

    func testFirstUseIsUnknownThenTrustedEverywhere() throws {
        let store: EsclTrustStore = makeStore()
        let first: EsclTrustCheck = store.check(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443")
        XCTAssertEqual(first.verdict, .unknown)
        XCTAssertNil(first.previous)

        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        XCTAssertEqual(store.check(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .trusted)
        // The pinned key is trusted at another address too (DHCP), and that address is remembered.
        XCTAssertEqual(store.check(fingerprint(0), deviceUuid: nil, authority: "HPA1B2C3.local:443").verdict, .trusted)
        let certificates: [EsclTrustedCertificate] = makeStore().certificates
        XCTAssertEqual(certificates.count, 1)
        let pinned: EsclTrustedCertificate = try XCTUnwrap(certificates.first)
        XCTAssertEqual(pinned.fingerprint, fingerprint(0))
        XCTAssertEqual(pinned.deviceUuid, "564e4333423035383930a0b3cce51a2b")
        XCTAssertEqual(pinned.addresses, ["192.168.1.20:443", "hpa1b2c3.local:443"])
        XCTAssertEqual(pinned.name, "HP M479")
        XCTAssertNotNil(pinned.trusted)
    }

    func testANewKeyForATrustedScannerIsAChange() throws {
        let store: EsclTrustStore = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")

        // Same UUID, anywhere.
        let sameUuid: EsclTrustCheck = store.check(fingerprint(1), deviceUuid: uuid.uppercased(), authority: "10.0.0.5:443")
        XCTAssertEqual(sameUuid.verdict, .changed)
        XCTAssertEqual(sameUuid.previous?.fingerprint, fingerprint(0))
        // Same address, UUID unknown (an address added by hand).
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "192.168.1.20:443").verdict, .changed)
        // Same address but another scanner's UUID: a different device took the address.
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.20:443").verdict, .unknown)
        // Another port is another endpoint.
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "192.168.1.20:8443").verdict, .unknown)
        XCTAssertEqual(store.check("", deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .invalid)
    }

    func testTrustingTheNewKeyReplacesTheOldOne() throws {
        let store: EsclTrustStore = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        try store.trust(fingerprint(5), deviceUuid: nil, authority: "10.0.0.9:443", name: "Other scanner")
        try store.trust(fingerprint(1), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")

        let reloaded: EsclTrustStore = makeStore()
        XCTAssertEqual(fingerprints(reloaded.certificates), [fingerprint(5), fingerprint(1)])
        XCTAssertEqual(reloaded.check(fingerprint(1), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .trusted)
        XCTAssertEqual(reloaded.check(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .changed)
        XCTAssertThrowsError(try reloaded.trust("", deviceUuid: uuid, authority: "x:1", name: "x")) { error in
            XCTAssertEqual(error as? EsclTrustStoreError, EsclTrustStoreError.noCertificate)
        }
    }

    func testLearningAnAddressKeepsWhatAnotherWindowTrusted() throws {
        let scannerS: String = "192.168.1.20:443"
        let scannerY: String = "192.168.1.30:443"
        let setup: EsclTrustStore = makeStore()
        try setup.trust(fingerprint(0), deviceUuid: uuid, authority: scannerS, name: "S")
        try setup.trust(fingerprint(3), deviceUuid: otherUuid, authority: scannerY, name: "Y")

        // Two parts of the app, each with the file as it was when it started.
        let windowA: EsclTrustStore = makeStore()
        let windowB: EsclTrustStore = makeStore()
        // B trusts S's new certificate, and a scanner A has never seen.
        try windowB.trust(fingerprint(1), deviceUuid: uuid, authority: scannerS, name: "S")
        try windowB.trust(fingerprint(4), deviceUuid: nil, authority: "10.0.0.7:443", name: "X")

        // A reaches Y at a new address (DHCP): the address is learned without undoing B's changes.
        XCTAssertEqual(windowA.check(fingerprint(3), deviceUuid: otherUuid, authority: "192.168.1.31:443").verdict, .trusted)
        let reloaded: [EsclTrustedCertificate] = makeStore().certificates
        XCTAssertEqual(fingerprints(reloaded), [fingerprint(3), fingerprint(1), fingerprint(4)])
        XCTAssertEqual(entry(reloaded, fingerprint(3))?.addresses, ["192.168.1.30:443", "192.168.1.31:443"])

        // A also sees B's pins: S's new key is trusted, the old one is a change.
        let windowA2: EsclTrustStore = makeStore()
        let stale: EsclTrustStore = makeStore()
        try windowB.trust(fingerprint(2), deviceUuid: uuid, authority: scannerS, name: "S")
        XCTAssertEqual(stale.check(fingerprint(2), deviceUuid: uuid, authority: scannerS).verdict, .trusted)
        let changed: EsclTrustCheck = windowA2.check(fingerprint(1), deviceUuid: uuid, authority: scannerS)
        XCTAssertEqual(changed.verdict, .changed)
        XCTAssertEqual(changed.previous?.fingerprint, fingerprint(2))
        XCTAssertEqual(windowA.check(fingerprint(4), deviceUuid: nil, authority: "10.0.0.7:443").verdict, .trusted)
    }

    func testAPinnedKeyDoesNotVouchForAnotherScannersUuid() throws {
        let store: EsclTrustStore = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        // Pinned for an address added by hand, the scanner's UUID not known yet.
        try store.trust(fingerprint(1), deviceUuid: nil, authority: "hp.local:443", name: "hp.local")
        try store.trust(fingerprint(2), deviceUuid: otherUuid, authority: "10.0.0.9:443", name: "Other")

        // The key pinned by address claims the trusted scanner's UUID: a change, nothing learned.
        var check: EsclTrustCheck = store.check(fingerprint(1), deviceUuid: uuid, authority: "hp.local:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(0))
        XCTAssertEqual(entry(makeStore().certificates, fingerprint(1))?.deviceUuid, "")
        // Another scanner's key claiming it, at the trusted scanner's own address too.
        check = store.check(fingerprint(2), deviceUuid: uuid, authority: "192.168.1.20:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(0))

        // Without a UUID, or with its own, a pinned key is still trusted anywhere.
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "hp.local:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(2), deviceUuid: otherUuid, authority: "10.0.0.10:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(0), deviceUuid: uuid, authority: "10.0.0.11:443").verdict, .trusted)
        // A UUID nobody holds is learned.
        let thirdUuid: String = "e3248000-80ce-11db-8000-30055c773bcf"
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: thirdUuid, authority: "hp.local:443").verdict, .trusted)
        XCTAssertEqual(entry(makeStore().certificates, fingerprint(1))?.deviceUuid, "e324800080ce11db800030055c773bcf")

        // Trusting the key for the scanner it claims replaces that scanner's pin.
        try store.trust(fingerprint(2), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(1), fingerprint(2)])
    }

    func testTrustedCertificatesStayTrustedWhenTheFileCannotBeWritten() throws {
        let store: EsclTrustStore = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "S")

        // Writes fail from here on (the folder takes no new files, so the file cannot be replaced); the
        // file still reads. C# makes its temporary file's name a folder instead; Foundation's atomic
        // write picks its own temporary file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path),
                      "The tests run with permissions that ignore a read-only folder.")
        try store.trust(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443", name: "Y")
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(0)])
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "192.168.1.31:443").verdict, .trusted)
        var check: EsclTrustCheck = store.check(fingerprint(5), deviceUuid: otherUuid, authority: "10.0.0.5:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(1))

        // Another part of the app changes the file meanwhile: its pins count, and the unsaved one is kept.
        let changedFile: String = """
            {"certificates": [
              {"fingerprint": "\(fingerprint(0))", "deviceUuid": "564e4333423035383930a0b3cce51a2b", "addresses": ["192.168.1.20:443"], "name": "S"},
              {"fingerprint": "\(fingerprint(4))", "deviceUuid": "", "addresses": ["10.0.0.7:443"], "name": "X"}
            ]}
            """
        try changedFile.write(to: trustFileURL, atomically: false, encoding: .utf8)
        XCTAssertEqual(store.check(fingerprint(4), deviceUuid: nil, authority: "10.0.0.7:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443").verdict, .trusted)

        // A later trust for the same scanner replaces the unsaved one, which does not come back.
        try store.trust(fingerprint(2), deviceUuid: otherUuid, authority: "192.168.1.30:443", name: "Y")
        check = store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(2))

        // Once the file can be written, the next write saves what was not saved.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertEqual(store.check(fingerprint(2), deviceUuid: otherUuid, authority: "192.168.1.32:443").verdict, .trusted)
        let reloaded: [EsclTrustedCertificate] = makeStore().certificates
        XCTAssertEqual(fingerprints(reloaded), [fingerprint(0), fingerprint(4), fingerprint(2)])
        XCTAssertEqual(entry(reloaded, fingerprint(2))?.addresses, ["192.168.1.30:443", "192.168.1.32:443"])
    }

    func testAnUndecodableTrustFileIsKeptAside() throws {
        try "{ not json".write(to: trustFileURL, atomically: true, encoding: .utf8)
        let store: EsclTrustStore = makeStore()
        XCTAssertTrue(store.certificates.isEmpty)
        XCTAssertEqual(try files(withPrefix: "escl-trust.unreadable-").count, 1)

        // A field of the wrong type resets only that field.
        let text: String = """
            {"certificates": [{"fingerprint": "\(fingerprint(2))", "deviceUuid": 42, "addresses": ["a:1"], "name": "Kept"}]}
            """
        try text.write(to: trustFileURL, atomically: true, encoding: .utf8)
        let certificates: [EsclTrustedCertificate] = makeStore().certificates
        XCTAssertEqual(certificates.count, 1)
        let kept: EsclTrustedCertificate = try XCTUnwrap(certificates.first)
        XCTAssertEqual(kept.fingerprint, fingerprint(2))
        XCTAssertEqual(kept.deviceUuid, "")
        XCTAssertEqual(kept.name, "Kept")
    }

    func testTrustFilesFromEitherPlatformLoad() throws {
        let p256: String = "61010433c5795ff33b96976a6bc6f2aa324a36b7182a1ddcab4d234744fe7d6c"
        let rsa: String = "4ad3ab48789a9c2f6b9b8cb55503d2bdf9fa889488beca7137476c0e1bb4e4e9"
        let names: [String] = ["escl-trust-windows.json", "escl-trust-apple.json"]
        for name in names {
            let folder: URL = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: EsclFixtures.url(name),
                                             to: folder.appendingPathComponent(EsclTrustStore.fileName))
            let store: EsclTrustStore = EsclTrustStore(directory: folder)
            let certificates: [EsclTrustedCertificate] = store.certificates
            XCTAssertEqual(fingerprints(certificates), [p256, rsa], name)
            guard certificates.count == 2 else { continue }
            let scanner: EsclTrustedCertificate = certificates[0]
            XCTAssertEqual(scanner.deviceUuid, "564e4333423035383930a0b3cce51a2b", name)
            XCTAssertEqual(scanner.addresses, ["192.168.1.20:443", "hpa1b2c3.local:443"], name)
            XCTAssertEqual(scanner.name, "HP Color LaserJet MFP M479fdw", name)
            let byAddress: EsclTrustedCertificate = certificates[1]
            XCTAssertEqual(byAddress.deviceUuid, "", name)
            XCTAssertEqual(byAddress.addresses, ["[fe80::1%12]:443"], name)
            XCTAssertEqual(byAddress.name, "fe80::1%12", name)
            // Each platform writes the date its own way; the other platform's reads as unknown.
            if name == "escl-trust-apple.json" {
                XCTAssertEqual(scanner.trusted, Date(timeIntervalSinceReferenceDate: 814_300_008.71075), name)
            } else {
                XCTAssertNil(scanner.trusted, name)
            }
            var unreadable: [String] = []
            let contents: [String] = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            for file in contents where file.hasPrefix("escl-trust.unreadable-") {
                unreadable.append(file)
            }
            XCTAssertTrue(unreadable.isEmpty, name)
            XCTAssertEqual(store.check(p256, deviceUuid: uuid.uppercased(), authority: "10.0.0.20:443").verdict, .trusted, name)
            let check: EsclTrustCheck = store.check(fingerprint(1), deviceUuid: nil, authority: "[fe80::1%12]:443")
            XCTAssertEqual(check.verdict, .changed, name)
            XCTAssertEqual(check.previous?.fingerprint, rsa, name)
        }
    }

    func testFingerprintsArePublicKeyHashesFormattedForPeople() throws {
        for vector in EsclFixtures.certificates {
            let der: Data = try EsclFixtures.certificateDER(vector.file)
            let fingerprint: String = try XCTUnwrap(EsclCertificates.fingerprint(certificateDER: der), vector.file)
            XCTAssertEqual(fingerprint.count, 64, vector.file)
            XCTAssertEqual(fingerprint, vector.fingerprint, vector.file)
        }
        XCTAssertNil(EsclCertificates.fingerprint(certificateDER: Data([0x30, 0x00])))
        XCTAssertEqual(EsclCertificates.format("abcd01"), "AB:CD:01")
        XCTAssertEqual(EsclCertificates.format("aabbcc", bytesPerLine: 2), "AA:BB\nCC")
    }

    // MARK: - Validator

    private let fakeScannerSubject = "CN=FakeScanner"

    func testTheValidatorTrustsWindowsValidCertificatesAndPinnedOnes() throws {
        // "Windows valid" in the C# name: here, valid for the system's own evaluation.
        let der: Data = try EsclFixtures.certificateDER("certificate-p256.pem")
        let store: EsclTrustStore = makeStore()
        let validator: EsclCertificateValidator = EsclCertificateValidator(store: store, deviceUuid: uuid,
                                                                           deviceName: "Fake MFP")
        let url: URL = try XCTUnwrap(URL(string: "https://192.168.1.20/eSCL/ScannerCapabilities"))

        XCTAssertTrue(validator.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: true))
        XCTAssertNil(validator.takeRejection())

        XCTAssertFalse(validator.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))
        let rejection: EsclCertificateError = try XCTUnwrap(validator.takeRejection())
        XCTAssertEqual(rejection.verdict, .unknown)
        XCTAssertTrue(rejection.canTrust)
        XCTAssertEqual(rejection.authority, "192.168.1.20:443")
        XCTAssertEqual(rejection.subject, "CN=FakeScanner")
        XCTAssertEqual(rejection.fingerprint, EsclCertificates.fingerprint(certificateDER: der))
        XCTAssertEqual(rejection.message,
                       "Fake MFP uses a security certificate that has not been trusted yet, so Lazy Scan did not connect.")
        XCTAssertNil(validator.takeRejection())   // taken once

        try store.trust(rejection.fingerprint, deviceUuid: rejection.deviceUuid, authority: rejection.authority,
                        name: "Fake MFP")
        XCTAssertTrue(validator.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))

        XCTAssertFalse(validator.validate(url: url, certificateDER: nil, subject: "", systemTrusted: false))
        let missing: EsclCertificateError = try XCTUnwrap(validator.takeRejection())
        XCTAssertEqual(missing.verdict, .invalid)
        XCTAssertFalse(missing.canTrust)
        // Bytes that are not a certificate cannot be pinned either.
        XCTAssertFalse(validator.validate(url: url, certificateDER: Data([0x30, 0x03, 0x02, 0x01, 0x00]),
                                          subject: "", systemTrusted: false))
        XCTAssertEqual(validator.takeRejection()?.verdict, .invalid)
    }

    func testAPinMadeByAddressLearnsTheScannersUuid() throws {
        let der: Data = try EsclFixtures.certificateDER("certificate-p256.pem")
        let store: EsclTrustStore = makeStore()
        let pinned: String = try XCTUnwrap(EsclCertificates.fingerprint(certificateDER: der))
        try store.trust(pinned, deviceUuid: nil, authority: "10.0.0.7:443", name: "10.0.0.7")
        let validator: EsclCertificateValidator = EsclCertificateValidator(store: store, deviceUuid: nil,
                                                                           deviceName: "10.0.0.7")
        try validator.rememberDevice(uuid)   // nothing accepted yet: nothing to learn
        XCTAssertEqual(store.certificates.first?.deviceUuid, "")
        XCTAssertEqual(store.certificates.count, 1)

        let url: URL = try XCTUnwrap(URL(string: "https://10.0.0.7/eSCL/"))
        XCTAssertTrue(validator.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))
        try validator.rememberDevice(uuid)
        let certificates: [EsclTrustedCertificate] = makeStore().certificates
        XCTAssertEqual(certificates.count, 1)
        XCTAssertEqual(certificates.first?.deviceUuid, "564e4333423035383930a0b3cce51a2b")
        // Discovery later finds the scanner by its UUID at another address, with another key.
        XCTAssertEqual(store.check(fingerprint(3), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .changed)
    }

    func testTheValidatorPinsAFirstUseCertificateOnlyOnceItsUuidIsChecked() throws {
        let der: Data = try EsclFixtures.certificateDER("certificate-p256.pem")
        let presented: String = try XCTUnwrap(EsclCertificates.fingerprint(certificateDER: der))
        let url: URL = try XCTUnwrap(URL(string: "https://10.0.0.30/eSCL/ScannerCapabilities"))
        let store: EsclTrustStore = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")

        // Not the certificate allowed for first use: refused.
        let other: EsclCertificateValidator = EsclCertificateValidator(store: store, deviceUuid: nil,
                                                                       deviceName: "10.0.0.30", firstUse: fingerprint(7))
        XCTAssertFalse(other.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))
        XCTAssertEqual(other.takeRejection()?.verdict, .unknown)

        // The first-use certificate is accepted without being pinned; it claims the trusted scanner's
        // UUID, so it is a change and stays unpinned.
        let claims: EsclCertificateValidator = EsclCertificateValidator(store: store, deviceUuid: nil,
                                                                        deviceName: "10.0.0.30", firstUse: presented)
        XCTAssertTrue(claims.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))
        XCTAssertEqual(fingerprints(store.certificates), [fingerprint(0)])
        XCTAssertThrowsError(try claims.rememberDevice(uuid)) { error in
            guard let changed = error as? EsclCertificateError else {
                XCTFail("Not a certificate error: \(error)")
                return
            }
            XCTAssertEqual(changed.verdict, .changed)
            XCTAssertEqual(changed.previous?.fingerprint, self.fingerprint(0))
            XCTAssertEqual(changed.fingerprint, presented)
            XCTAssertEqual(changed.authority, "10.0.0.30:443")
            XCTAssertTrue(changed.canTrust)
        }
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(0)])

        // A scanner nobody trusted: pinned with its UUID once it answered.
        let fresh: EsclCertificateValidator = EsclCertificateValidator(store: store, deviceUuid: nil,
                                                                       deviceName: "10.0.0.30", firstUse: presented)
        XCTAssertTrue(fresh.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))
        try fresh.rememberDevice(otherUuid)
        let pin: EsclTrustedCertificate = try XCTUnwrap(entry(makeStore().certificates, presented))
        XCTAssertEqual(pin.deviceUuid, "cfe9210067c411d4a45ff8d0273e1a0b")
        XCTAssertEqual(pin.addresses, ["10.0.0.30:443"])
        // Pinned now: the same validator accepts it as a pinned key, and nothing changes.
        XCTAssertTrue(fresh.validate(url: url, certificateDER: der, subject: fakeScannerSubject, systemTrusted: false))
        try fresh.rememberDevice(otherUuid)
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(0), presented])
    }

    func testAuthoritiesMatchTheAddressForm() throws {
        let zoned: ScannerAddress = try ScannerAddress.parse("[fe80::1%12]:8080")
        XCTAssertEqual(EsclUrlText.authority(zoned.baseURLText), "[fe80::1%12]:8080")
        let named: URL = try XCTUnwrap(URL(string: "https://Scanner.Local/eSCL/"))
        XCTAssertEqual(EsclCertificateValidator.authorityOf(named), "scanner.local:443")
        let address: ScannerAddress = try ScannerAddress.parse("https://10.0.0.7:8443")
        let base: URL = try XCTUnwrap(address.baseURL)
        XCTAssertEqual(EsclCertificateValidator.authorityOf(base), address.authority)
    }

    // MARK: - Addresses added by hand (escl-hosts.json)

    private func descriptions(_ addresses: [ScannerAddress]) -> [String] {
        var list: [String] = []
        for address in addresses {
            list.append(address.description)
        }
        return list
    }

    func testHostListAddsCanonicalAddressesOnce() throws {
        let hosts: EsclHostList = EsclHostList(directory: directory)
        XCTAssertTrue(hosts.load().isEmpty)
        XCTAssertTrue(hosts.add(try ScannerAddress.parse("http://192.168.1.50:80/eSCL")))
        XCTAssertFalse(hosts.add(try ScannerAddress.parse("192.168.1.50")))
        XCTAssertTrue(hosts.add(try ScannerAddress.parse("https://10.0.0.7")))
        XCTAssertEqual(hosts.loadEntries(), ["192.168.1.50", "https://10.0.0.7"])
        XCTAssertTrue(hosts.remove(try ScannerAddress.parse("192.168.1.50")))
        XCTAssertFalse(hosts.remove(try ScannerAddress.parse("192.168.1.50")))
        XCTAssertEqual(hosts.loadEntries(), ["https://10.0.0.7"])
    }

    func testHandWrittenHostEntriesKeepWorking() throws {
        let hosts: EsclHostList = EsclHostList(directory: directory)
        try "[\"192.168.1.50\", \"epson.local:8080\", \"not an address\", \"192.168.1.50\"]"
            .write(to: hosts.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(descriptions(hosts.load()), ["192.168.1.50", "epson.local:8080"])
        // Adding keeps the other entries, including the one that is not an address.
        XCTAssertTrue(hosts.add(try ScannerAddress.parse("10.0.0.9")))
        XCTAssertEqual(hosts.loadEntries(), ["192.168.1.50", "epson.local:8080", "not an address", "192.168.1.50", "10.0.0.9"])
    }

    func testAnUndecodableHostListIsKeptAside() throws {
        let hosts: EsclHostList = EsclHostList(directory: directory)
        try "{\"hosts\": [\"192.168.1.50\"]}".write(to: hosts.fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(hosts.load().isEmpty)
        XCTAssertEqual(try files(withPrefix: "escl-hosts.unreadable-").count, 1)
        XCTAssertTrue(hosts.add(try ScannerAddress.parse("10.0.0.9")))
        XCTAssertEqual(hosts.loadEntries(), ["10.0.0.9"])
    }
}
