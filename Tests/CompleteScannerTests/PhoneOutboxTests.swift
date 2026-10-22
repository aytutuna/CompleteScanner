import Foundation
import XCTest
@testable import CompleteScannerKit

// The documents a phone has still to send to its desktop (PhoneOutbox.swift). Swift only.

final class PhoneOutboxTests: XCTestCase {
    private let desk = "desk-0001-abcd"
    private var folder: URL!
    private var outboxFolder: URL { folder.appendingPathComponent("Outbox", isDirectory: true) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A package file outside the outbox.
    private func package(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("package \(name)".utf8).write(to: url)
        return url
    }

    func test_enqueue_movesTheFileInAndNextIsTheOldest() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let source = try package("Scan 1.csdoc")

        let first = try outbox.enqueue(source, target: .new, desktopId: desk)
        let second = try outbox.enqueue(try package("Scan 2.csdoc"), target: .current, desktopId: desk)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(first.fileName, "Scan 1.csdoc")
        XCTAssertEqual(try Data(contentsOf: outbox.fileURL(of: first)), Data("package Scan 1.csdoc".utf8))
        XCTAssertTrue(CompanionProtocol.isValidId(first.id))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.target, .current)
        XCTAssertEqual(outbox.next(), first)
        XCTAssertEqual(outbox.next(excluding: [first.id]), second)
        XCTAssertNil(outbox.next(excluding: [first.id, second.id]))
    }

    func test_enqueue_aFileInTheOutboxStaysWhereItIs_aNameTakenGetsANumber() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
        let inside = outboxFolder.appendingPathComponent("Scan.csdoc")
        try Data("inside".utf8).write(to: inside)

        let kept = try outbox.enqueue(inside, target: .new, desktopId: desk)
        let moved = try outbox.enqueue(try package("Scan.csdoc"), target: .new, desktopId: desk)

        XCTAssertEqual(kept.fileName, "Scan.csdoc")
        XCTAssertEqual(moved.fileName, "Scan 2.csdoc")
        XCTAssertEqual(try Data(contentsOf: inside), Data("inside".utf8))
    }

    func test_markFailed_countsAndKeepsWhy_markSentRemovesTheFile() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let item = try outbox.enqueue(try package("Scan.csdoc"), target: .new, desktopId: desk)

        outbox.markFailed(item.id, error: "Office PC cannot be reached on this network.")
        outbox.markFailed(item.id, error: "Too many attempts.")

        XCTAssertEqual(outbox.items.first?.attempts, 2)
        XCTAssertEqual(outbox.items.first?.lastError, "Too many attempts.")

        outbox.markSent(item.id)

        XCTAssertTrue(outbox.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.fileURL(of: item).path))
    }

    func test_enqueue_atMost50() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        for index in 0..<PhoneOutbox.maxItems {
            try outbox.enqueue(try package("Scan \(index).csdoc"), target: .new, desktopId: desk)
        }
        let extra = try package("One more.csdoc")

        XCTAssertThrowsError(try outbox.enqueue(extra, target: .new, desktopId: desk)) { error in
            XCTAssertEqual(error as? PhoneOutboxError, .full)
            XCTAssertEqual(error.localizedDescription, CompanionText.outboxFullMessage)
        }
        XCTAssertEqual(outbox.count, 50)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
    }

    func test_survivesANewInstance_droppingEntriesWhoseFileWent() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let kept = try outbox.enqueue(try package("Kept.csdoc"), target: .current, desktopId: desk)
        let gone = try outbox.enqueue(try package("Gone.csdoc"), target: .new, desktopId: desk)
        outbox.markFailed(kept.id, error: "Busy.")
        try FileManager.default.removeItem(at: outbox.fileURL(of: gone))

        let reopened = PhoneOutbox(directory: outboxFolder)

        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.items.first?.id, kept.id)
        XCTAssertEqual(reopened.items.first?.target, .current)
        XCTAssertEqual(reopened.items.first?.desktopId, desk)
        XCTAssertEqual(reopened.items.first?.attempts, 1)
        XCTAssertEqual(reopened.items.first?.lastError, "Busy.")
    }

    func test_load_isLenient() throws {
        try FileManager.default.createDirectory(at: outboxFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outboxFolder.appendingPathComponent("A.csdoc"))
        let json = """
            {"items":[{"id":"pkg-0001-abcd","fileName":"A.csdoc","target":"sideways","attempts":"many","more":1}]}
            """
        try Data(json.utf8).write(to: outboxFolder.appendingPathComponent(PhoneOutbox.fileName))

        let item = try XCTUnwrap(PhoneOutbox(directory: outboxFolder).items.first)

        XCTAssertEqual(item.id, "pkg-0001-abcd")
        XCTAssertEqual(item.target, .new)
        XCTAssertEqual(item.attempts, 0)
        XCTAssertFalse(item.viaSyncFolder)
    }

    func test_markViaSyncFolder_isKept_andReadLeniently() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let item = try outbox.enqueue(try package("Scan.csdoc"), target: .new, desktopId: desk)
        XCTAssertFalse(item.viaSyncFolder)

        outbox.markViaSyncFolder(item.id)

        XCTAssertEqual(outbox.items.first?.viaSyncFolder, true)
        XCTAssertEqual(PhoneOutbox(directory: outboxFolder).items.first?.viaSyncFolder, true)
        let text = try String(contentsOf: outboxFolder.appendingPathComponent(PhoneOutbox.fileName), encoding: .utf8)
        XCTAssertTrue(text.contains("\"viaSyncFolder\""))

        let json = #"{"items":[{"id":"pkg-0001-abcd","fileName":"Scan.csdoc","viaSyncFolder":"yes"}]}"#
        try Data(json.utf8).write(to: outboxFolder.appendingPathComponent(PhoneOutbox.fileName))
        XCTAssertEqual(PhoneOutbox(directory: outboxFolder).items.first?.viaSyncFolder, false)
    }

    func test_markInSyncFolder_andMarkRefused_areKept_andReadLeniently() throws {
        let outbox = PhoneOutbox(directory: outboxFolder)
        let item = try outbox.enqueue(try package("Scan.csdoc"), target: .new, desktopId: desk)
        XCTAssertFalse(item.inSyncFolder)
        XCTAssertFalse(item.refused)

        outbox.markInSyncFolder(item.id)
        outbox.markRefused(item.id)

        let kept = try XCTUnwrap(PhoneOutbox(directory: outboxFolder).items.first)
        XCTAssertTrue(kept.inSyncFolder)
        XCTAssertTrue(kept.refused)
        outbox.markInSyncFolder(item.id, false)
        XCTAssertEqual(PhoneOutbox(directory: outboxFolder).items.first?.inSyncFolder, false)

        let json = #"{"items":[{"id":"pkg-0001-abcd","fileName":"Scan.csdoc","inSyncFolder":"yes","refused":"no"}]}"#
        try Data(json.utf8).write(to: outboxFolder.appendingPathComponent(PhoneOutbox.fileName))
        let lenient = try XCTUnwrap(PhoneOutbox(directory: outboxFolder).items.first)
        XCTAssertFalse(lenient.inSyncFolder)
        XCTAssertFalse(lenient.refused)
    }
}
