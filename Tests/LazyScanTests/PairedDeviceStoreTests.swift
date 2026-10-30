import XCTest
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/PairedDeviceStoreTests.cs (same cases; each platform
// writes its own file in its own settings folder, so only the JSON keys are shared, not dates).

final class PairedDeviceStoreTests: XCTestCase {
    /// 2026-10-20T08:30:00Z.
    private let now = Date(timeIntervalSince1970: 1_792_485_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompleteScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent(PairedDeviceStore.fileName) }

    private func makeStore() -> PairedDeviceStore { PairedDeviceStore(directory: directory) }

    func testHashSecret_IsSha256Hex() {
        XCTAssertEqual(PairedDeviceStore.hashSecret(CompanionVectors.secret), CompanionVectors.secretHash)
    }

    func testPair_KeepsOnlyTheSecretsHash() throws {
        let store = makeStore()
        let secret = try store.pair(id: "phone-0001", name: "Aytu's iPhone", platform: "ios", appVersion: "1.0", now: now,
                                    secret: CompanionVectors.secret)
        XCTAssertEqual(secret, CompanionVectors.secretText)
        let device = try XCTUnwrap(store.devices.first)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(device.id, "phone-0001")
        XCTAssertEqual(device.name, "Aytu's iPhone")
        XCTAssertEqual(device.platform, "ios")
        XCTAssertEqual(device.secretHash, CompanionVectors.secretHash)
        XCTAssertEqual(device.paired, now)
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(file.contains(CompanionVectors.secretHash))
        XCTAssertFalse(file.contains(CompanionVectors.secretText))
        // A fresh store reads the same phone.
        XCTAssertEqual(makeStore().devices.map(\.id), ["phone-0001"])
    }

    func testAuthenticate_NeedsTheRightIdAndSecret() throws {
        let store = makeStore()
        let secret = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        XCTAssertEqual(secret.count, 43)
        XCTAssertEqual(store.authenticate(id: "phone-0001", secret: secret, now: now)?.id, "phone-0001")
        XCTAssertNil(store.authenticate(id: "phone-0002", secret: secret, now: now))
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: CompanionVectors.secretText, now: now))
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: String(secret.dropLast()), now: now))
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: nil, now: now))
        XCTAssertNil(store.authenticate(id: nil, secret: secret, now: now))
        XCTAssertNil(store.authenticate(id: "../../x", secret: secret, now: now))
    }

    func testAuthenticate_RecordsLastSeenToTheMinute() throws {
        let store = makeStore()
        let secret = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        _ = store.authenticate(id: "phone-0001", secret: secret, now: now.addingTimeInterval(30))
        XCTAssertEqual(store.devices.first?.lastSeen, now)
        _ = store.authenticate(id: "phone-0001", secret: secret, now: now.addingTimeInterval(120))
        XCTAssertEqual(makeStore().devices.first?.lastSeen, now.addingTimeInterval(120))
    }

    func testPairingAgain_ReplacesTheSecret() throws {
        let store = makeStore()
        let first = try store.pair(id: "phone-0001", name: "Old name", platform: "ios", appVersion: "1.0", now: now)
        let second = try store.pair(id: "phone-0001", name: "New name", platform: "ios", appVersion: "1.1", now: now.addingTimeInterval(86_400))
        XCTAssertNotEqual(first, second)
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: first, now: now))
        XCTAssertEqual(store.authenticate(id: "phone-0001", secret: second, now: now)?.name, "New name")
        XCTAssertEqual(store.devices.count, 1)
    }

    func testRemove_RefusesThePhoneAtOnce() throws {
        let store = makeStore()
        let secret = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        var changes = 0
        store.onChange = { changes += 1 }
        XCTAssertTrue(store.remove("phone-0001"))
        XCTAssertFalse(store.remove("phone-0001"))
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: secret, now: now))
        XCTAssertTrue(makeStore().devices.isEmpty)
        XCTAssertEqual(changes, 1)
    }

    func testRemoveAll_UnpairsEveryPhone() throws {
        let store = makeStore()
        let a = try store.pair(id: "phone-0001", name: "A", platform: "ios", appVersion: "1.0", now: now)
        let b = try store.pair(id: "phone-0002", name: "B", platform: "ios", appVersion: "1.0", now: now)
        XCTAssertEqual(store.removeAll(), 2)
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: a, now: now))
        XCTAssertNil(store.authenticate(id: "phone-0002", secret: b, now: now))
        XCTAssertEqual(store.count, 0)
    }

    func testPair_RefusesTooManyPhonesAndBadIds() throws {
        let store = makeStore()
        for i in 0..<PairedDeviceStore.maxDevices {
            _ = try store.pair(id: String(format: "phone-%04ld", i), name: "P", platform: "ios", appVersion: "1.0", now: now)
        }
        XCTAssertThrowsError(try store.pair(id: "phone-9999", name: "P", platform: "ios", appVersion: "1.0", now: now)) { error in
            XCTAssertEqual(error as? PairedDeviceStoreError, .tooManyDevices)
        }
        // Pairing one of them again is fine.
        _ = try store.pair(id: "phone-0003", name: "P", platform: "ios", appVersion: "1.0", now: now)
        XCTAssertThrowsError(try store.pair(id: "bad id!", name: "P", platform: "ios", appVersion: "1.0", now: now))
        XCTAssertThrowsError(try store.pair(id: "phone-0001", name: "P", platform: "ios", appVersion: "1.0", now: now, secret: Data(count: 16)))
    }

    func testDesktopId_IsMadeOnceAndKept() {
        let store = makeStore()
        let id = store.desktopId
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(CompanionProtocol.isValidId(id))
        XCTAssertEqual(store.desktopId, id)
        XCTAssertEqual(makeStore().desktopId, id)
    }

    func testCleanName_DropsControlCharactersAndCutsLongNames() {
        XCTAssertEqual(PairedDeviceStore.cleanName("  Aytu's\u{1} iPhone\n "), "Aytu's iPhone")
        XCTAssertEqual(PairedDeviceStore.cleanName(nil), "")
        XCTAssertEqual(PairedDeviceStore.cleanName(String(repeating: "é", count: 100)), String(repeating: "é", count: 64))
    }

    func testUnreadableFile_IsKeptAsideAndPairingStillWorks() throws {
        try Data("{ not json".utf8).write(to: fileURL)
        let store = makeStore()
        XCTAssertTrue(store.devices.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("companion-devices.unreadable-") && $0.hasSuffix(".json") }
        XCTAssertEqual(kept.count, 1)
        let secret = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        XCTAssertNotNil(store.authenticate(id: "phone-0001", secret: secret, now: now))
    }

    func testFileWithOddValues_LoadsLeniently() throws {
        let json = #"{"desktopId":5,"devices":[{"id":"phone-0001","name":7,"secretHash":""#
            + CompanionVectors.secretHash + #"","paired":"yesterday","later":true}],"extra":{}}"#
        try Data(json.utf8).write(to: fileURL)
        let store = makeStore()
        let device = try XCTUnwrap(store.devices.first)
        XCTAssertEqual(device.name, "")
        XCTAssertNil(device.paired)
        XCTAssertNotNil(store.authenticate(id: "phone-0001", secret: CompanionVectors.secretText, now: now))
        XCTAssertTrue(CompanionProtocol.isValidId(store.desktopId))
    }

    func testPair_MakesASyncKeyKeptInItsStore() throws {
        let keys = MemorySecretStore()
        let store = PairedDeviceStore(directory: directory, syncKeyStore: keys)
        _ = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        let key = try XCTUnwrap(try store.syncKey(for: "phone-0001"))
        XCTAssertEqual(key.count, SyncPackage.keyByteCount)
        XCTAssertEqual(try keys.load(for: "phone-0001"), key)
        XCTAssertEqual(try PairedDeviceStore(directory: directory, syncKeyStore: keys).syncKey(for: "phone-0001"), key)
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains(CompanionProtocol.encodeBase64Url(key)))
        XCTAssertFalse(file.contains(key.base64EncodedString()))
        XCTAssertNil(try store.syncKey(for: "phone-0002"))
        XCTAssertTrue(store.hasSyncKey("phone-0001"))
        XCTAssertFalse(store.hasSyncKey("phone-0002"))
        // Without a store no key is made.
        XCTAssertNil(try makeStore().syncKey(for: "phone-0001"))

        // Pairing again keeps the key; removing the phone drops it, and pairing after that makes a new one.
        _ = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        XCTAssertEqual(try store.syncKey(for: "phone-0001"), key)
        store.remove("phone-0001")
        XCTAssertNil(try store.syncKey(for: "phone-0001"))
        XCTAssertNil(try keys.load(for: "phone-0001"))
        _ = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        XCTAssertNotEqual(try store.syncKey(for: "phone-0001"), key)
        _ = try store.pair(id: "phone-0002", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        store.removeAll()
        XCTAssertNil(try store.syncKey(for: "phone-0002"))
        XCTAssertEqual(keys.count, 0)

        // A store that cannot be read now says so, where a phone without a key has none.
        _ = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        keys.loadFails = true
        XCTAssertThrowsError(try store.syncKey(for: "phone-0001"))
        XCTAssertFalse(store.hasSyncKey("phone-0001"))
        keys.loadFails = false
        XCTAssertNotNil(try store.syncKey(for: "phone-0001"))
    }

    func testSyncFolder_IsKeptWithThePhones() throws {
        let store = makeStore()
        XCTAssertNil(store.syncFolder)
        var changes = 0
        store.onChange = { changes += 1 }
        let folder = directory.appendingPathComponent("OneDrive/Scans", isDirectory: true)
        XCTAssertTrue(store.setSyncFolder(folder))
        XCTAssertEqual(makeStore().syncFolder?.path, folder.path)
        _ = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        store.removeAll()
        XCTAssertEqual(store.syncFolder?.path, folder.path)
        XCTAssertTrue(store.setSyncFolder(nil))
        XCTAssertNil(makeStore().syncFolder)
        XCTAssertEqual(changes, 4)
    }

    func testRemovedPhone_StaysRemovedWhenTheFileComesBack() throws {
        let store = makeStore()
        let secret = try store.pair(id: "phone-0001", name: "Phone", platform: "ios", appVersion: "1.0", now: now)
        let before = try Data(contentsOf: fileURL)
        store.remove("phone-0001")
        // Another window that still had the old list writes it back.
        try before.write(to: fileURL)
        XCTAssertNil(store.authenticate(id: "phone-0001", secret: secret, now: now))
    }
}
