import CoreGraphics
import Foundation
import XCTest
@testable import LazyScanKit

// The phone's side of C1 through the app's state (AppState+Companion.swift), against the stub desktop
// of CompanionFakes.swift. Every AppState here keeps its settings, presets, spool and companion files
// in a folder of its own.

private struct CompanionScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

private struct CompanionBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// A light picture with a dark bar across it.
private func companionPicture(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: max(2, height / 25)))
    return context.makeImage()!
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out after \(timeout) s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

final class AppStateCompanionTests: XCTestCase {
    private var folder: URL!
    private var secrets: MemorySecretStore!

    private var companionFolder: URL { folder.appendingPathComponent("Network", isDirectory: true) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateCompanionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        secrets = MemorySecretStore()
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An AppState collecting document pages with `count` pages queued, its companion set up on the
    /// stub desktops.
    @MainActor
    private func makeState(pages count: Int = 0) async throws -> AppState {
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: CompanionScorer(),
                             barcodeReader: CompanionBarcodes(), files: AppStateFiles.all(in: folder))
        var settings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.taskId = nil
        settings.source = .flatbed
        settings.duplex = .off
        settings.resolution = 75
        settings.format = .pdf
        settings.pdfSearchable = false
        settings.destinationPath = folder.path
        state.settings = settings
        var pages: [ScannedPage] = []
        for _ in 0..<count {
            pages.append(ScannedPage(image: companionPicture(width: 400, height: 520), dpi: 50, colorMode: .color))
        }
        if count > 0 {
            XCTAssertTrue(state.ingest(pages, source: .photo))
            try await waitUntil(timeout: 60) { !state.isBusy }
        }
        state.companionProtocolClasses = [CompanionStubProtocol.self]
        state.setUpCompanion(in: companionFolder, secrets: secrets)
        return state
    }

    private func code(_ fake: CompanionFakeDesktop) throws -> String {
        try PairingUri(desktopId: CompanionLink.desktopId, name: "Office PC", fingerprint: CompanionVectors.fingerprintText,
                       addresses: [CompanionLink.address], port: fake.port, token: CompanionVectors.tokenText).format()
    }

    /// A one-page package, as the desktop would hold it for the phone.
    private func receipt() throws -> Data {
        let picture = companionPicture(width: 40, height: 60)
        let image = CompanionImage(data: PDFImageEncoding.encodeJPEG(picture, quality: 0.9)!, format: .jpeg,
                                   pixelWidth: 40, pixelHeight: 60, dpi: 200, colorMode: .color)
        return try CompanionPackage.make(CompanionDocument(title: "Receipt", pages: [CompanionPage(image: image)]))
    }

    @MainActor
    private func pair(_ state: AppState, with fake: CompanionFakeDesktop) async throws {
        fake.on("POST " + CompanionProtocol.pairPath, CompanionLink.pairResponse())
        let uri = try code(fake)
        await state.pairDesktop(uri: uri, phoneName: "Test phone")
        XCTAssertNil(state.errorMessage)
    }

    /// The sync key the desktop hands out in `pairWithSyncKey`: 0x01...0x20.
    private let syncKey = Data((1...32).map { UInt8($0) })

    /// Pairs with a desktop that has the cloud sync folder.
    @MainActor
    private func pairWithSyncKey(_ state: AppState, with fake: CompanionFakeDesktop) async throws {
        fake.on("POST " + CompanionProtocol.pairPath,
                .json(200, PairResponse(desktopId: CompanionLink.desktopId, desktopName: "Office PC",
                                        deviceSecret: CompanionVectors.secretText, protocolVersion: CompanionProtocol.version,
                                        syncKey: CompanionProtocol.encodeBase64Url(syncKey)).toJSON()))
        let uri = try code(fake)
        await state.pairDesktop(uri: uri, phoneName: "Test phone")
        XCTAssertNil(state.errorMessage)
    }

    /// Sets `cloud` as the sync folder, opened by a resolver standing in for the iPhone's bookmarks.
    @MainActor
    private func setSyncFolder(_ state: AppState, _ cloud: URL) {
        state.resolveSyncFolderBookmark = { bookmark in (folder: cloud, bookmark: bookmark) }
        state.setSyncFolder(bookmark: Data("cloud folder".utf8))
    }

    @MainActor
    func test_pairDesktop_keepsTheDesktopAndItsSecret() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        XCTAssertEqual(state.companionStatus, .notPaired)

        try await pair(state, with: fake)

        let desktop = try XCTUnwrap(state.companionDesktop)
        XCTAssertEqual(desktop.id, CompanionLink.desktopId)
        XCTAssertEqual(desktop.name, "Office PC")
        XCTAssertEqual(desktop.addresses, [CompanionLink.address])
        XCTAssertTrue(CompanionProtocol.isValidId(desktop.phoneId))
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC", queuedPages: 0))
        XCTAssertEqual(state.statusMessage, CompanionText.pairedMessage("Office PC"))
        XCTAssertEqual(try secrets.load(for: CompanionLink.desktopId), CompanionVectors.secret)
        XCTAssertEqual(PairedDesktopStore(directory: companionFolder, secrets: secrets).load(), desktop)
        let request = try XCTUnwrap(PairRequest.fromJSON(fake.requests("POST " + CompanionProtocol.pairPath)[0].body))
        XCTAssertEqual(request.phoneId, desktop.phoneId)
        XCTAssertEqual(request.phoneName, "Test phone")

        // A new start finds it again.
        let again = try await makeState()
        XCTAssertEqual(again.companionDesktop, desktop)
        XCTAssertEqual(again.companionStatus, .checking)
    }

    @MainActor
    func test_pairDesktop_refusal_saysTheDesktopsMessage() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("POST " + CompanionProtocol.pairPath, .error(403, CompanionError.declined))
        let state = try await makeState()
        let uri = try code(fake)

        await state.pairDesktop(uri: uri, phoneName: "Test phone")

        XCTAssertEqual(state.errorMessage, CompanionError.declined.message)
        XCTAssertNil(state.companionDesktop)
        XCTAssertEqual(state.companionStatus, .notPaired)
        XCTAssertEqual(secrets.count, 0)

        state.errorMessage = nil
        await state.pairDesktop(uri: "https://example.com", phoneName: "Test phone")
        XCTAssertEqual(state.errorMessage, PairingUri.notPairingCodeMessage)
    }

    @MainActor
    func test_checkDesktop_401_forgetsTheSecretAndSaysUnpaired() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.unauthorized)

        await state.checkDesktop()

        XCTAssertEqual(state.companionStatus, .unpaired(byDesktop: "Office PC"))
        XCTAssertNil(try secrets.load(for: CompanionLink.desktopId))
        XCTAssertNotNil(state.companionDesktop)
    }

    @MainActor
    func test_checkDesktop_reachable_thenUnreachableWithItsReason() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello(queuedPages: 4))

        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC", queuedPages: 4))

        fake.downHosts = [CompanionLink.address]
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))

        var asked: [String] = []
        state.companionDesktopSeenOnNetwork = { id in
            asked.append(id)
            return true
        }
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.clientIsolationReason))
        XCTAssertEqual(asked, [CompanionLink.desktopId])
        XCTAssertNotNil(try secrets.load(for: CompanionLink.desktopId))
    }

    @MainActor
    func test_sendQueueToDesktop_sendsThePackageAndEmptiesTheOutbox() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 2)
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            let id = String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count))
            return .json(201, InboxResponse(packageId: id, pageCount: 2, duplicate: false).toJSON())
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello(queuedPages: 2))

        await state.sendQueueToDesktop(target: .new)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.statusMessage, "Sent 2 pages to Office PC.")
        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC", queuedPages: 2))
        XCTAssertEqual(state.scannedPages.count, 2)
        let put = try XCTUnwrap(fake.requests.first { $0.method == "PUT" })
        XCTAssertEqual(put.header(CompanionProtocol.targetHeader), "new")
        XCTAssertEqual(try CompanionPackage.read(put.body).pages.count, 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: companionFolder.appendingPathComponent("Outbox").path)
        XCTAssertEqual(left.filter { $0.hasSuffix(".csdoc") }, [])
    }

    @MainActor
    func test_sendQueueToDesktop_unreachable_keepsTheDocumentUntilItGoes() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            let id = String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count))
            return .json(200, InboxResponse(packageId: id, pageCount: 1, duplicate: true).toJSON())
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        fake.downHosts = [CompanionLink.address]

        await state.sendQueueToDesktop(target: .current)

        XCTAssertEqual(state.statusMessage, "Office PC cannot be reached on this network.")
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))
        XCTAssertEqual(state.companionOutboxCount, 1)

        fake.downHosts = []
        await state.drainOutbox()

        // A duplicate counts as sent: the desktop had it.
        XCTAssertEqual(state.statusMessage, "Sent 1 page to Office PC.")
        XCTAssertEqual(state.companionOutboxCount, 0)
        let put = try XCTUnwrap(fake.requests.last { $0.method == "PUT" })
        XCTAssertEqual(put.header(CompanionProtocol.targetHeader), "current")
    }

    @MainActor
    func test_drainOutbox_sendsADocumentOnlyToTheDesktopItWasFor() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            let id = String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count))
            return .json(201, InboxResponse(packageId: id, pageCount: 1, duplicate: false).toJSON())
        }
        let outbox = try XCTUnwrap(state.companionOutbox)
        let file = folder.appendingPathComponent("For another.csdoc")
        try Data("package".utf8).write(to: file)
        try outbox.enqueue(file, target: .new, desktopId: "desk-0002-other")

        await state.drainOutbox()

        XCTAssertTrue(fake.requests.filter { $0.method == "PUT" }.isEmpty)
        XCTAssertEqual(state.companionOutboxCount, 1)
    }

    @MainActor
    func test_clearOutbox_removesTheWaitingDocuments() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pair(state, with: fake)
        fake.downHosts = [CompanionLink.address]
        await state.sendQueueToDesktop(target: .new)
        XCTAssertEqual(state.companionOutboxCount, 1)

        state.clearOutbox()

        XCTAssertEqual(state.companionOutboxCount, 0)
        let outbox = companionFolder.appendingPathComponent("Outbox")
        var packages: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: outbox.path)
        where name.hasSuffix("." + CompanionPackage.fileExtension) {
            packages.append(name)
        }
        XCTAssertEqual(packages, [])
        XCTAssertEqual(state.scannedPages.count, 1)
    }

    @MainActor
    func test_desktopFound_keepsTheNewAddresses_ofThePairedDesktopOnly() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())

        await state.desktopFound(id: "desk-0002-other", addresses: ["192.168.1.99"], port: fake.port)
        XCTAssertEqual(state.companionDesktop?.addresses, [CompanionLink.address])

        // Anyone can advertise the desktop's id: where the desktop does not answer, nothing is kept.
        fake.downHosts = ["192.168.1.66"]
        let unanswered = await state.desktopFound(id: CompanionLink.desktopId, addresses: ["192.168.1.66"],
                                                  port: fake.port)
        XCTAssertFalse(unanswered)
        XCTAssertEqual(state.companionDesktop?.addresses, [CompanionLink.address])
        fake.downHosts = []

        let kept = await state.desktopFound(id: CompanionLink.desktopId,
                                            addresses: ["fe80::1%4", "192.168.1.30", "printer.local"], port: fake.port)
        XCTAssertTrue(kept)
        let desktop = try XCTUnwrap(state.companionDesktop)
        XCTAssertEqual(desktop.addresses, ["192.168.1.30", "fe80::1%4"])
        XCTAssertEqual(PairedDesktopStore(directory: companionFolder, secrets: secrets).load()?.addresses,
                       desktop.addresses)

        // The old address is gone: the desktop answers at the new one.
        fake.downHosts = [CompanionLink.address]
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .reachable(desktopName: "Office PC", queuedPages: 0))
    }

    @MainActor
    func test_sendQueueToDesktop_notPaired_isRefused() async throws {
        let state = try await makeState(pages: 1)

        await state.sendQueueToDesktop(target: .new)

        XCTAssertEqual(state.errorMessage, CompanionText.notPairedMessage)
        XCTAssertEqual(state.companionOutboxCount, 0)
    }

    @MainActor
    func test_pullFromDesktop_acksThePackageThenOffersItOnTheBanner() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        let package = try receipt()
        let item = OutboxItem(id: "item-0001-abcd", name: "Receipt.csdoc", contentType: CompanionProtocol.packageContentType,
                              byteCount: package.count, created: Date(timeIntervalSince1970: 1_790_000_000))
        fake.on("GET " + CompanionProtocol.outboxPath,
                .json(200, OutboxList(items: [item]).toJSON()),
                .json(200, OutboxList(items: []).toJSON(), delay: 0.2))
        fake.on("GET " + CompanionProtocol.outboxPrefix + item.id, CompanionStubAnswer(status: 200, body: package))
        var acked = CompanionStubAnswer.empty(204)
        acked.delay = 0.5
        fake.on("DELETE " + CompanionProtocol.outboxPrefix + item.id, acked)

        state.pullFromDesktop()
        defer { state.stopPulling() }
        try await waitUntil(timeout: 30) {
            !fake.requests("DELETE " + CompanionProtocol.outboxPrefix + item.id).isEmpty
        }

        // Its id is noted before the ack, and the offer waits for the ack's answer.
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.companionDesktop?.received, [item.id])
        XCTAssertEqual(PairedDesktopStore(directory: companionFolder, secrets: secrets).load()?.received, [item.id])
        try await waitUntil(timeout: 30) { state.pendingPackage != nil }
        let offered = try XCTUnwrap(state.pendingPackage)
        XCTAssertEqual(offered.fileName, "Receipt.csdoc")
        XCTAssertEqual(offered.pageCount, 1)
        XCTAssertEqual(fake.requests("GET " + CompanionProtocol.outboxPath).first?.query, "wait=25")
        var keys: [String] = []
        for request in fake.requests where request.path.hasPrefix(CompanionProtocol.outboxPrefix) {
            keys.append(request.key)
        }
        XCTAssertEqual(keys, ["GET " + CompanionProtocol.outboxPrefix + item.id,
                              "DELETE " + CompanionProtocol.outboxPrefix + item.id])
        // The file stays until the offer is answered: the desktop has let go of it.
        let inbox = companionFolder.appendingPathComponent("Inbox")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), ["Receipt.csdoc"])
        state.dismissPendingPackage()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    @MainActor
    func test_pullFromDesktop_twoPackages_theSecondIsOfferedOnceTheFirstIsAnswered() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        let package = try receipt()
        let type = CompanionProtocol.packageContentType
        let first = OutboxItem(id: "item-0001-abcd", name: "First.csdoc", contentType: type, byteCount: package.count,
                               created: Date(timeIntervalSince1970: 1_790_000_000))
        let second = OutboxItem(id: "item-0002-abcd", name: "Second.csdoc", contentType: type, byteCount: package.count,
                                created: Date(timeIntervalSince1970: 1_790_000_060))
        fake.on("GET " + CompanionProtocol.outboxPath,
                .json(200, OutboxList(items: [first, second]).toJSON()),
                .json(200, OutboxList(items: []).toJSON(), delay: 0.2))
        fake.on("GET " + CompanionProtocol.outboxPrefix + "*", CompanionStubAnswer(status: 200, body: package))
        fake.on("DELETE " + CompanionProtocol.outboxPrefix + "*", .empty(204))

        state.pullFromDesktop()
        defer { state.stopPulling() }
        try await waitUntil(timeout: 30) {
            !fake.requests("DELETE " + CompanionProtocol.outboxPrefix + second.id).isEmpty && state.pendingPackage != nil
        }

        XCTAssertEqual(state.pendingPackage?.fileName, "First.csdoc")
        state.dismissPendingPackage()
        try await waitUntil(timeout: 30) { state.pendingPackage != nil }
        XCTAssertEqual(state.pendingPackage?.fileName, "Second.csdoc")
        state.dismissPendingPackage()
        let inbox = companionFolder.appendingPathComponent("Inbox")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    @MainActor
    func test_pullFromDesktop_anotherFile_goesToTheSaveFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        let pdf = Data("%PDF-1.7 not really".utf8)
        let item = OutboxItem(id: "item-0003-abcd", name: "Invoice.pdf", contentType: "application/pdf",
                              byteCount: pdf.count, created: Date(timeIntervalSince1970: 1_790_000_000))
        fake.on("GET " + CompanionProtocol.outboxPath,
                .json(200, OutboxList(items: [item]).toJSON()),
                .json(200, OutboxList(items: []).toJSON(), delay: 0.2))
        fake.on("GET " + CompanionProtocol.outboxPrefix + item.id, CompanionStubAnswer(status: 200, body: pdf))
        fake.on("DELETE " + CompanionProtocol.outboxPrefix + item.id, .empty(204))

        state.pullFromDesktop()
        defer { state.stopPulling() }
        try await waitUntil(timeout: 30) { state.statusMessage == "Received Invoice.pdf from Office PC." }

        XCTAssertEqual(fake.requests("DELETE " + CompanionProtocol.outboxPrefix + item.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Invoice.pdf")), pdf)
        XCTAssertEqual(state.statusMessage, "Received Invoice.pdf from Office PC.")
        XCTAssertNil(state.pendingPackage)
    }

    @MainActor
    func test_pullFromDesktop_anItemListedAgain_isAckedAgainNotSavedTwice() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        let pdf = Data("%PDF-1.7 not really".utf8)
        let item = OutboxItem(id: "item-0004-abcd", name: "Invoice.pdf", contentType: "application/pdf",
                              byteCount: pdf.count, created: Date(timeIntervalSince1970: 1_790_000_000))
        // The first ack's answer was lost: the desktop lists the item again.
        fake.on("GET " + CompanionProtocol.outboxPath,
                .json(200, OutboxList(items: [item]).toJSON()),
                .json(200, OutboxList(items: [item]).toJSON()),
                .json(200, OutboxList(items: []).toJSON(), delay: 0.2))
        fake.on("GET " + CompanionProtocol.outboxPrefix + item.id, CompanionStubAnswer(status: 200, body: pdf))
        fake.on("DELETE " + CompanionProtocol.outboxPrefix + item.id, .empty(204))

        state.pullFromDesktop()
        defer { state.stopPulling() }
        try await waitUntil(timeout: 30) {
            fake.requests("DELETE " + CompanionProtocol.outboxPrefix + item.id).count == 2
        }

        XCTAssertEqual(fake.requests("GET " + CompanionProtocol.outboxPrefix + item.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Invoice.pdf")), pdf)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Invoice 2.pdf").path))
        XCTAssertEqual(state.companionDesktop?.received, [item.id])
    }

    @MainActor
    func test_pullFromDesktop_401_stopsAndSaysUnpaired() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("GET " + CompanionProtocol.outboxPath, CompanionLink.unauthorized)

        state.pullFromDesktop()
        try await waitUntil(timeout: 30) { state.companionStatus == .unpaired(byDesktop: "Office PC") }

        XCTAssertNil(state.companionPull)
        XCTAssertEqual(fake.requests("GET " + CompanionProtocol.outboxPath).count, 1)
    }

    @MainActor
    func test_unpairDesktop_tellsTheDesktopAndForgetsIt() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        fake.on("DELETE " + CompanionProtocol.deviceSelfPath, .empty(204))

        await state.unpairDesktop()

        XCTAssertEqual(fake.requests("DELETE " + CompanionProtocol.deviceSelfPath).count, 1)
        XCTAssertNil(state.companionDesktop)
        XCTAssertEqual(state.companionStatus, .notPaired)
        XCTAssertEqual(secrets.count, 0)
        XCTAssertNil(PairedDesktopStore(directory: companionFolder, secrets: secrets).load())
    }

    @MainActor
    func test_pairDesktop_keepsTheSyncKey_andAnOldDesktopGivesNone() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pair(state, with: fake)
        XCTAssertFalse(state.canUseSyncFolder)

        try await pairWithSyncKey(state, with: fake)

        XCTAssertTrue(state.canUseSyncFolder)
        XCTAssertEqual(try secrets.load(for: CompanionLink.desktopId + ".sync"), syncKey)
    }

    @MainActor
    func test_drainOutbox_unreachable_putsTheDocumentInTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.downHosts = [CompanionLink.address]

        await state.sendQueueToDesktop(target: .current)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(state.companionOutbox?.items.first?.inSyncFolder, true)
        let names = try FileManager.default.contentsOfDirectory(atPath: cloud.path)
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasSuffix("." + SyncPackage.fileExtension))
        let packageId = String(name.dropLast(SyncPackage.fileExtension.count + 1))
        XCTAssertTrue(CompanionProtocol.isValidId(packageId))
        let desktop = try XCTUnwrap(state.companionDesktop)
        let opened = try SyncPackage.open(Data(contentsOf: cloud.appendingPathComponent(name)), packageId: packageId,
                                          phoneId: desktop.phoneId, key: syncKey)
        XCTAssertEqual(opened.target, .current)
        XCTAssertEqual(try CompanionPackage.read(opened.plaintext).pages.count, 1)
        let status = state.statusMessage
        XCTAssertTrue(status.hasPrefix("Put "), status)
        XCTAssertTrue(status.hasSuffix(" in the cloud folder for Office PC."), status)

        // It waits until the desktop takes the file out of the folder.
        await state.drainOutbox()
        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [name])
        try FileManager.default.removeItem(at: cloud.appendingPathComponent(name))
        await state.drainOutbox()
        XCTAssertEqual(state.companionOutboxCount, 0)
    }

    @MainActor
    func test_drainOutbox_unreachable_leavesWhatTheDesktopRefusedOutOfTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*",
                .error(422, CompanionError(code: CompanionErrorCode.invalidPackage, message: "Page 2's picture is damaged.")))
        await state.sendQueueToDesktop(target: .new)
        XCTAssertEqual(state.companionOutbox?.items.first?.refused, true)

        fake.downHosts = [CompanionLink.address]
        await state.sendQueueToDesktop(target: .new)

        let items = try XCTUnwrap(state.companionOutbox?.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].inSyncFolder)
        XCTAssertTrue(items[1].inSyncFolder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [SyncPackage.fileName(items[1].id)])
    }

    @MainActor
    func test_drainOutbox_anotherErrorStatus_stillLetsTheDocumentGoInTheSyncFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pairWithSyncKey(state, with: fake)
        let cloud = folder.appendingPathComponent("OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        setSyncFolder(state, cloud)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*",
                .error(500, CompanionError.serverError))
        await state.sendQueueToDesktop(target: .new)
        let item = try XCTUnwrap(state.companionOutbox?.items.first)
        XCTAssertFalse(item.refused)
        XCTAssertTrue(state.errorMessage?.hasPrefix(item.fileName + " was not sent: ") == true, state.errorMessage ?? "")

        fake.downHosts = [CompanionLink.address]
        await state.drainOutbox()

        XCTAssertEqual(state.companionOutbox?.items.first?.inSyncFolder, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [SyncPackage.fileName(item.id)])
    }

    @MainActor
    func test_drainOutbox_unreachableWithoutAFolder_saysWhereToSetOneOnce() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pairWithSyncKey(state, with: fake)
        fake.downHosts = [CompanionLink.address]

        await state.sendQueueToDesktop(target: .new)

        XCTAssertEqual(state.statusMessage,
                       "Office PC cannot be reached on this network. Set a cloud folder in My computer to send when the PC cannot be reached.")
        XCTAssertEqual(state.companionOutboxCount, 1)

        await state.drainOutbox()
        XCTAssertEqual(state.statusMessage, "Office PC cannot be reached on this network.")
        XCTAssertEqual(state.companionOutboxCount, 1)
    }

    @MainActor
    func test_sendThroughSyncFolder_aWriteThatFails_keepsTheDocumentForTheFolder() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState(pages: 1)
        try await pairWithSyncKey(state, with: fake)
        setSyncFolder(state, folder.appendingPathComponent("Not there", isDirectory: true))
        fake.downHosts = [CompanionLink.address]

        await state.sendQueueToDesktop(target: .new)

        XCTAssertEqual(state.companionOutboxCount, 1)
        let item = try XCTUnwrap(state.companionOutbox?.items.first)
        XCTAssertTrue(item.viaSyncFolder)
        XCTAssertTrue(state.errorMessage?.hasPrefix(item.fileName + " was not sent: ") == true, state.errorMessage ?? "")

        // The folder is there now: the next round puts it there without asking the desktop.
        let cloud = folder.appendingPathComponent("Not there")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        fake.downHosts = []
        let puts = fake.requests.filter { $0.method == "PUT" }.count
        await state.drainOutbox()

        XCTAssertEqual(state.companionOutboxCount, 1)
        XCTAssertEqual(fake.requests.filter { $0.method == "PUT" }.count, puts)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [SyncPackage.fileName(item.id)])

        // Sent over the network after all: it leaves the outbox, and its file the folder.
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*") { request in
            let id = String(request.path.dropFirst(CompanionProtocol.inboxPrefix.count))
            return .json(201, InboxResponse(packageId: id, pageCount: 1, duplicate: false).toJSON())
        }
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        await state.drainOutbox()

        XCTAssertEqual(state.companionOutboxCount, 0)
        XCTAssertEqual(fake.requests.filter { $0.method == "PUT" }.count, puts + 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.path), [])
    }

    @MainActor
    func test_checkDesktop_devicesKeptApart_withASyncFolder_saysTheFolderIsUsed() async throws {
        let fake = CompanionFakeDesktop()
        let state = try await makeState()
        try await pairWithSyncKey(state, with: fake)
        fake.downHosts = [CompanionLink.address]
        state.companionDesktopSeenOnNetwork = { _ in true }

        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.clientIsolationReason))

        setSyncFolder(state, folder)
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: CompanionText.clientIsolationSyncFolderReason))

        state.companionDesktopSeenOnNetwork = { _ in false }
        await state.checkDesktop()
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))
    }
}
