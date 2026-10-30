import Foundation
import XCTest
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/SyncFolderWatcherTests.cs (same cases); the sync keys are
// kept in memory here, where Windows keeps them with the Data Protection API.

final class SyncFolderWatcherTests: XCTestCase {
    private let phoneId = "phone-0001"
    private var root: URL!
    private var folder: URL!
    private var keys: MemorySecretStore!
    private var devices: PairedDeviceStore!
    private var inbox: CompanionInbox!
    private var watcher: SyncFolderWatcher!
    private var received: [(package: ReceivedPackage, device: PairedDevice)] = []
    private var problems: [String] = []
    private var now = Date(timeIntervalSince1970: 1_792_659_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFolderWatcherTests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("iCloud Drive/CompleteScanner", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        keys = MemorySecretStore()
        devices = PairedDeviceStore(directory: root, syncKeyStore: keys)
        inbox = CompanionInbox(directory: root.appendingPathComponent("Inbox", isDirectory: true))
        watcher = SyncFolderWatcher(folder: folder, devices: devices, inbox: inbox) { [unowned self] in self.now }
        watcher.onPackageReceived = { [unowned self] package, device in self.received.append((package, device)) }
        watcher.onProblem = { [unowned self] message in self.problems.append(message) }
    }

    override func tearDownWithError() throws {
        watcher.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func pairPhone(_ id: String? = nil) throws -> Data {
        let id = id ?? phoneId
        _ = try devices.pair(id: id, name: "Aytu's iPhone", platform: "ios", appVersion: "1.0", now: now)
        return try XCTUnwrap(try devices.syncKey(for: id))
    }

    @discardableResult
    private func put(_ packageId: String, key: Data, phoneId: String? = nil, target: CompanionTarget = .current) throws -> URL {
        let url = folder.appendingPathComponent(SyncPackage.fileName(packageId))
        let package = try CompanionPackage.make(CompanionFixtures.minimal)
        try SyncPackage.seal(packageId: packageId, phoneId: phoneId ?? self.phoneId, target: target, plaintext: package,
                             key: key).write(to: url)
        return url
    }

    /// Looks once, then again once the files have settled.
    private func pollTwice() async {
        await watcher.poll()
        now = now.addingTimeInterval(SyncFolderWatcher.settleTime)
        await watcher.poll()
    }

    func test_aSealedFile_isReceivedOnceSettled_thenDeleted() async throws {
        let url = try put("package-0001", key: try pairPhone())

        await watcher.poll()
        XCTAssertTrue(received.isEmpty)
        now = now.addingTimeInterval(1)
        await watcher.poll()
        XCTAssertTrue(received.isEmpty)
        now = now.addingTimeInterval(1)
        await watcher.poll()

        XCTAssertEqual(received.count, 1)
        let first = try XCTUnwrap(received.first)
        XCTAssertEqual(first.device.id, phoneId)
        XCTAssertEqual(first.package.packageId, "package-0001")
        XCTAssertEqual(first.package.target, .current)
        XCTAssertEqual(first.package.document.pages.count, CompanionFixtures.minimal.pages.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.package.url.path))
        XCTAssertNotNil(inbox.find(deviceId: phoneId, packageId: "package-0001"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(problems, [])

        await pollTwice()
        XCTAssertEqual(received.count, 1)
    }

    func test_thePhoneIsFoundByItsKey() async throws {
        _ = try pairPhone("phone-0002")
        try put("package-0001", key: try pairPhone(), target: .new)

        await pollTwice()

        XCTAssertEqual(received.map { $0.device.id }, [phoneId])
        XCTAssertEqual(received.first?.package.target, .new)
    }

    func test_aPackageReceivedBefore_isOnlyDeleted() async throws {
        let key = try pairPhone()
        try put("package-0001", key: key)
        await pollTwice()
        XCTAssertEqual(received.count, 1)

        let again = try put("package-0001", key: key)
        await pollTwice()

        XCTAssertEqual(received.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path))
        XCTAssertEqual(problems, [])
    }

    func test_aFileNoPairedPhoneOpens_isLeftAndReportedOnce() async throws {
        _ = try pairPhone()
        let url = try put("package-0001", key: Data(count: SyncPackage.keyByteCount))
        let other = folder.appendingPathComponent("notes.cssync")
        try Data("not a package".utf8).write(to: other)

        await pollTwice()
        await pollTwice()

        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems.contains(SyncFolderWatcher.unreadableMessage(
            "package-0001.cssync", reason: SyncPackageError.wrongKeyOrTampered.localizedDescription)))
        XCTAssertTrue(problems.contains(SyncFolderWatcher.unreadableMessage(
            "notes.cssync", reason: SyncPackageError.notASyncPackage.localizedDescription)))
    }

    func test_aReportedFile_isTriedAgainOnlyAfterAMinute() async throws {
        let key = try pairPhone()
        let url = try put("package-0001", key: key)
        try keys.delete(for: phoneId)
        await pollTwice()
        XCTAssertEqual(problems, [SyncFolderWatcher.unreadableMessage(
            "package-0001.cssync", reason: SyncPackageError.wrongKeyOrTampered.localizedDescription)])

        try keys.save(key, for: phoneId)
        now = now.addingTimeInterval(SyncFolderWatcher.retryTime - 1)
        await watcher.poll()
        XCTAssertTrue(received.isEmpty)

        now = now.addingTimeInterval(1)
        await watcher.poll()

        XCTAssertEqual(received.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(problems.count, 1)
    }

    func test_aKeyThatCannotBeRead_isReportedOnce_andTheFileWaitsAMinute() async throws {
        let url = try put("package-0001", key: try pairPhone())
        try put("package-0002", key: Data(count: SyncPackage.keyByteCount))
        keys.loadFails = true
        let loads = keys.loads

        await pollTwice()
        await pollTwice()

        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(problems, [SyncFolderWatcher.keyUnreadableMessage("Aytu's iPhone")])
        XCTAssertEqual(keys.loads, loads + 1)

        // Not read again before a minute has passed, though the key opens now.
        keys.loadFails = false
        await pollTwice()
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(keys.loads, loads + 1)

        now = now.addingTimeInterval(SyncFolderWatcher.retryTime)
        await watcher.poll()

        XCTAssertEqual(received.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(problems.count, 2)
        XCTAssertEqual(problems.last, SyncFolderWatcher.unreadableMessage(
            "package-0002.cssync", reason: SyncPackageError.wrongKeyOrTampered.localizedDescription))
    }

    func test_aFileStillGrowing_waitsUntilItSettles() async throws {
        let url = try put("package-0001", key: try pairPhone())
        let whole = try Data(contentsOf: url)
        try whole.prefix(100).write(to: url)

        await watcher.poll()
        now = now.addingTimeInterval(SyncFolderWatcher.settleTime)
        try whole.write(to: url)
        await watcher.poll()
        XCTAssertTrue(received.isEmpty)
        now = now.addingTimeInterval(SyncFolderWatcher.settleTime)
        await watcher.poll()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(problems, [])
    }

    func test_aFileFromARemovedPhone_isNotReceived() async throws {
        let key = try pairPhone()
        devices.remove(phoneId)
        try put("package-0001", key: key)

        await pollTwice()

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(problems.count, 1)
    }
}
