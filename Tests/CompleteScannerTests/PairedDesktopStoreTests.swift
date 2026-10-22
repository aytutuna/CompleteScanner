import Foundation
import XCTest
@testable import CompleteScannerKit

// The phone's record of its desktop (companion-desktop.json) and where its secret goes. Swift only:
// the Windows app is never the phone.

final class PairedDesktopStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairedDesktopStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func desktop(id: String = "desk-0001-abcd") -> PairedDesktop {
        PairedDesktop(id: id, name: "Office PC", fingerprint: CompanionVectors.fingerprintText,
                      addresses: ["192.168.1.20", "fe80::1%en0"], port: 52731, phoneId: "phone-0001",
                      pairedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                      lastSeen: Date(timeIntervalSinceReferenceDate: 800_000_060))
    }

    func test_save_roundTripsTheDesktop() throws {
        let secrets = MemorySecretStore()
        try PairedDesktopStore(directory: folder, secrets: secrets).save(desktop(), secret: CompanionVectors.secret)

        let store = PairedDesktopStore(directory: folder, secrets: secrets)

        XCTAssertEqual(store.load(), desktop())
        XCTAssertEqual(store.secret(for: desktop()), CompanionVectors.secret)
        XCTAssertEqual(desktop().fingerprintBytes, CompanionVectors.fingerprint)
    }

    func test_save_keepsTheSecretOutOfTheFile() throws {
        let secrets = MemorySecretStore()
        try PairedDesktopStore(directory: folder, secrets: secrets).save(desktop(), secret: CompanionVectors.secret)

        let text = try String(contentsOf: folder.appendingPathComponent(PairedDesktopStore.fileName), encoding: .utf8)

        XCTAssertFalse(text.contains(CompanionVectors.secretText))
        XCTAssertFalse(text.contains(CompanionVectors.secret.base64EncodedString()))
        XCTAssertTrue(text.contains(CompanionVectors.fingerprintText))
        XCTAssertEqual(try secrets.load(for: "desk-0001-abcd"), CompanionVectors.secret)
    }

    func test_load_isLenient() throws {
        let json = """
            {"id":"desk-0001-abcd","name":42,"fingerprint":"\(CompanionVectors.fingerprintText)",
             "addresses":["10.0.0.5"],"port":"high","phoneId":"phone-0001","pairedAt":"yesterday","extra":true}
            """
        try Data(json.utf8).write(to: folder.appendingPathComponent(PairedDesktopStore.fileName))

        let loaded = try XCTUnwrap(PairedDesktopStore(directory: folder, secrets: MemorySecretStore()).load())

        XCTAssertEqual(loaded.id, "desk-0001-abcd")
        XCTAssertEqual(loaded.name, "")
        XCTAssertEqual(loaded.addresses, ["10.0.0.5"])
        XCTAssertEqual(loaded.port, CompanionProtocol.defaultPort)
        XCTAssertNil(loaded.pairedAt)
    }

    func test_load_withoutAUsableDesktop_isNil() throws {
        let url = folder.appendingPathComponent(PairedDesktopStore.fileName)
        let store = PairedDesktopStore(directory: folder, secrets: MemorySecretStore())
        XCTAssertNil(store.load())

        try Data("{\"id\":\"desk-0001-abcd\",\"phoneId\":\"phone-0001\",\"addresses\":[\"10.0.0.5\"]}".utf8).write(to: url)
        XCTAssertNil(store.load(), "no fingerprint")
    }

    func test_pairingAnotherDesktop_dropsTheFirstsSecret() throws {
        let secrets = MemorySecretStore()
        let store = PairedDesktopStore(directory: folder, secrets: secrets)
        try store.save(desktop(), secret: CompanionVectors.secret)

        try store.save(desktop(id: "desk-0002-abcd"), secret: Data(repeating: 7, count: 32))

        XCTAssertEqual(store.load()?.id, "desk-0002-abcd")
        XCTAssertNil(try secrets.load(for: "desk-0001-abcd"))
        XCTAssertEqual(secrets.count, 1)
    }

    func test_forgetSecret_keepsTheDesktop_removeForgetsBoth() throws {
        let secrets = MemorySecretStore()
        let store = PairedDesktopStore(directory: folder, secrets: secrets)
        try store.save(desktop(), secret: CompanionVectors.secret)

        store.forgetSecret(of: desktop())
        XCTAssertEqual(store.load(), desktop())
        XCTAssertNil(store.secret(for: desktop()))

        try store.save(desktop(), secret: CompanionVectors.secret)
        store.remove()
        XCTAssertNil(store.load())
        XCTAssertEqual(secrets.count, 0)
    }

    func test_syncKey_isKeptBesideTheSecret_andGoesWithIt() throws {
        let secrets = MemorySecretStore()
        let store = PairedDesktopStore(directory: folder, secrets: secrets)
        let key = Data(repeating: 9, count: SyncPackage.keyByteCount)
        var paired = desktop()
        paired.syncFolderBookmark = Data("bookmark".utf8)
        try store.save(paired, secret: CompanionVectors.secret, syncKey: key)

        XCTAssertEqual(store.syncKey(for: paired), key)
        XCTAssertEqual(try secrets.load(for: "desk-0001-abcd.sync"), key)
        XCTAssertEqual(store.load(), paired)
        let text = try String(contentsOf: folder.appendingPathComponent(PairedDesktopStore.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains(key.base64EncodedString()))

        // A desktop without the sync folder pairs again: the key goes.
        try store.save(paired, secret: CompanionVectors.secret)
        XCTAssertNil(store.syncKey(for: paired))

        try store.save(paired, secret: CompanionVectors.secret, syncKey: key)
        store.forgetSecret(of: paired)
        XCTAssertNil(store.syncKey(for: paired))
        XCTAssertEqual(secrets.count, 0)

        try store.save(paired, secret: CompanionVectors.secret, syncKey: key)
        try store.save(desktop(id: "desk-0002-abcd"), secret: CompanionVectors.secret, syncKey: key)
        XCTAssertNil(try secrets.load(for: "desk-0001-abcd.sync"))
        store.remove()
        XCTAssertEqual(secrets.count, 0)
    }

    func test_received_keepsTheNewestIds() throws {
        let store = PairedDesktopStore(directory: folder, secrets: MemorySecretStore())
        var paired = desktop()
        for n in 0..<(PairedDesktop.maxReceived + 5) {
            paired.noteReceived("item-\(n)")
        }
        paired.noteReceived("item-10")
        try store.save(paired, secret: CompanionVectors.secret)

        let received = try XCTUnwrap(store.load()?.received)
        XCTAssertEqual(received.count, PairedDesktop.maxReceived)
        XCTAssertEqual(received.first, "item-5")
        XCTAssertEqual(received.last, "item-10")
        XCTAssertEqual(received.filter { $0 == "item-10" }.count, 1)
    }
}
