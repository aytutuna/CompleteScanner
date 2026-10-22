import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import CompleteScannerKit

// Adding the queued pages to an existing PDF through the app's state (AppState+Append.swift): what is
// asked, said and kept. Swift only, as `AppStateSeamTests`: the Windows view model is not in Core, so
// `AppViewModel.AppendToPdf` has no C# test; the update itself is `PDFAppenderTests` on both sides.
// Every AppState here keeps its settings, presets and spool in a folder of its own and saves there.

/// Text recognition that cannot run, so no page is read with Vision here.
private struct AppendScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct AppendBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// What the shell's file access was asked for: reading (false) or the update (true), in order.
private final class AccessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [Bool] = []

    func add(_ writing: Bool) {
        lock.lock()
        kinds.append(writing)
        lock.unlock()
    }

    var writes: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }
}

/// A light page with a dark bar across it, `width` × `height` pixels.
private func appendPage(width: Int = 400, height: Int = 520, dpi: Int = 50) -> ScannedPage {
    let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: max(2, height / 25)))
    let image: CGImage = context.makeImage()!
    return ScannedPage(image: image, dpi: dpi, colorMode: .color)
}

/// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
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

final class AppStateAppendTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateAppendTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An AppState with its files in `folder`, collecting document pages saved as PDF without OCR, with
    /// `count` pages in its queue.
    @MainActor
    private func makeState(pages count: Int) async throws -> AppState {
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: AppendScorer(),
                             barcodeReader: AppendBarcodes(), files: AppStateFiles.all(in: folder))
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
            pages.append(appendPage())
        }
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.scannedPages.count, count)
        return state
    }

    /// A one-page PDF our own builder made, written to `folder` as `name`.
    private func builtPDF(_ name: String, options: PDFWriteOptions? = nil) throws -> URL {
        let data = try PDFBuilder.makePDF(pages: [appendPage(width: 300, height: 400)], pdfSize: .best, progress: nil,
                                          textLayer: nil, options: options)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @MainActor
    private func append(_ state: AppState, to url: URL) async throws {
        state.appendToPDF(at: url)
        try await waitUntil(timeout: 60) { !state.isBusy }
    }

    @MainActor
    func test_appendToPDF_addsTheQueuedPages_clearsTheQueue_andOffersTheFile() async throws {
        let state = try await makeState(pages: 2)
        let url = try builtPDF("Contract.pdf")
        let original = try Data(contentsOf: url)
        XCTAssertTrue(state.canAppendPages)
        try await append(state, to: url)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertFalse(state.canAppendPages)
        XCTAssertEqual(state.lastSavedURLs, [url])
        let updated = try Data(contentsOf: url)
        // An incremental update: the original bytes untouched at the start.
        XCTAssertGreaterThan(updated.count, original.count)
        XCTAssertEqual(updated.prefix(original.count), original)
        XCTAssertEqual(state.lastPDFByteCount, Int64(updated.count))
        XCTAssertFalse(state.lastPDFProtected)
        let size = ByteCountFormatter.string(fromByteCount: Int64(updated.count), countStyle: .file)
        XCTAssertEqual(state.statusMessage,
                       PDFAppender.addedMessage(2, fileName: "Contract.pdf", pageCount: 3, size: size))
        XCTAssertEqual(try PDFReaderLite(data: updated).pageCount, 3)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
        // Nothing else was written beside it (the temporary file and the backup are gone).
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var written: [String] = []
        for name in names where name.hasSuffix(".pdf") || name.hasSuffix(".tmp") || name.hasSuffix(".bak") {
            written.append(name)
        }
        XCTAssertEqual(written, ["Contract.pdf"])
    }

    @MainActor
    func test_save_withATarget_addsTheQueueToIt_andClearsTheTarget() async throws {
        let state = try await makeState(pages: 2)
        let url = try builtPDF("Contract.pdf")
        let original = try Data(contentsOf: url)
        state.setAppendTarget(url)
        XCTAssertEqual(state.appendTarget, url)
        XCTAssertEqual(PDFAppender.saveTitle(url.lastPathComponent), "Add to Contract.pdf")
        state.savePDF()
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.appendTarget)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertEqual(state.lastSavedURLs, [url])
        let updated = try Data(contentsOf: url)
        XCTAssertEqual(updated.prefix(original.count), original)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(pdfs, ["Contract.pdf"])
    }

    @MainActor
    func test_save_afterTheTargetIsCleared_writesANewFile() async throws {
        let state = try await makeState(pages: 1)
        let url = try builtPDF("Contract.pdf")
        let original = try Data(contentsOf: url)
        state.setAppendTarget(url)
        state.clearAppendTarget()
        XCTAssertNil(state.appendTarget)
        state.savePDF()
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(state.lastSavedURLs.count, 1)
        let saved = try XCTUnwrap(state.lastSavedURLs.first)
        XCTAssertNotEqual(saved.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(PDFDocument(url: saved)?.pageCount, 1)
        XCTAssertEqual(PDFAppender.saveAsNewLabel, "Save as new PDF")
    }

    @MainActor
    func test_appendToPDF_withThePasswordSwitchOn_addsNoPassword_andSaysSo() async throws {
        let state = try await makeState(pages: 1)
        state.settings.output.protect = true
        var asked = 0
        state.askPDFPassword = { () async -> PDFProtection? in
            asked += 1
            return nil
        }
        let url = try builtPDF("Plain.pdf")
        try await append(state, to: url)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(state.statusMessage.hasSuffix(". " + PDFAppender.noPasswordNote), state.statusMessage)
        let reader = try PDFReaderLite(data: try Data(contentsOf: url))
        XCTAssertFalse(reader.isEncrypted)
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertFalse(state.lastPDFProtected)
    }

    @MainActor
    func test_aSignedFile_asksFirst_andNoAnswerAddsNothing_keepingTheQueue() async throws {
        let state = try await makeState(pages: 2)
        let url = folder.appendingPathComponent("Contract.pdf")
        let signed = Data(PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 3>>"))
        try signed.write(to: url)
        var questions: [String] = []
        state.confirmAppend = { (question: String) async -> Bool in
            questions.append(question)
            return false
        }
        try await append(state, to: url)
        XCTAssertEqual(questions, [PDFAppender.signedWarning("Contract.pdf") + "\n\n" + PDFAppender.confirmQuestion])
        XCTAssertEqual(state.statusMessage, "Nothing was added to Contract.pdf.")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertEqual(try Data(contentsOf: url), signed)
        XCTAssertEqual(state.lastSavedURLs, [])

        // Nobody to ask: the same.
        state.confirmAppend = nil
        try await append(state, to: url)
        XCTAssertEqual(state.statusMessage, "Nothing was added to Contract.pdf.")
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertEqual(try Data(contentsOf: url), signed)

        // Yes: the pages are added after the signed bytes.
        state.confirmAppend = { (_: String) async -> Bool in true }
        try await append(state, to: url)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.scannedPages.isEmpty)
        let updated = try Data(contentsOf: url)
        XCTAssertEqual(updated.prefix(signed.count), signed)
        XCTAssertEqual(try PDFReaderLite(data: updated).pageCount, 3)
    }

    @MainActor
    func test_anEncryptedFile_isRefused_withWhatToDo_andThePagesStay() async throws {
        let state = try await makeState(pages: 1)
        let protection = try PDFProtection("Şifre 2026")
        let url = try builtPDF("Gizli.pdf", options: PDFWriteOptions(protection: protection))
        let original = try Data(contentsOf: url)
        var asked = false
        state.confirmAppend = { (_: String) async -> Bool in
            asked = true
            return true
        }
        try await append(state, to: url)
        XCTAssertEqual(state.errorMessage, PDFAppender.message(.encrypted, "Gizli.pdf"))
        XCTAssertEqual(state.errorMessage,
                       "Gizli.pdf is password-protected, so pages can't be added to it. Save them as a new PDF instead.")
        XCTAssertFalse(asked)
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertTrue(state.canAppendPages)
        XCTAssertEqual(state.lastSavedURLs, [])
        XCTAssertEqual(try Data(contentsOf: url), original)
        state.deleteSpoolFiles(of: state.scannedPages)
    }

    @MainActor
    func test_aFileThatIsNotAPDF_isRefused_andThePagesStay() async throws {
        let state = try await makeState(pages: 1)
        let url = folder.appendingPathComponent("Notes.pdf")
        try Data("Not a PDF at all.\n".utf8).write(to: url)
        try await append(state, to: url)
        XCTAssertEqual(state.errorMessage, PDFAppender.message(.notPdf, "Notes.pdf"))
        XCTAssertEqual(state.scannedPages.count, 1)
        state.deleteSpoolFiles(of: state.scannedPages)
    }

    @MainActor
    func test_theShellsAccess_wrapsTheReadingAndTheUpdate() async throws {
        let state = try await makeState(pages: 1)
        let url = try builtPDF("Shared.pdf")
        let log = AccessLog()
        state.accessPDFForAppend = { (file: URL, writing: Bool, body: (URL) throws -> Void) throws -> Void in
            log.add(writing)
            try body(file)
        }
        try await append(state, to: url)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(log.writes, [false, true])
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
    }

    func test_accessing_withoutTheShellsAccess_usesTheFile_andAnAccessThatNeverRanIsMissing() throws {
        let url = URL(fileURLWithPath: "/x/Contract.pdf")
        XCTAssertEqual(try AppState.accessing(url, writing: false, through: nil) { (file: URL) -> String in file.path },
                       "/x/Contract.pdf")
        let moved = URL(fileURLWithPath: "/y/Contract.pdf")
        let elsewhere: @Sendable (URL, Bool, (URL) throws -> Void) throws -> Void = { (_: URL, _: Bool, body: (URL) throws -> Void) throws -> Void in
            try body(moved)
        }
        XCTAssertEqual(try AppState.accessing(url, writing: true, through: elsewhere) { (file: URL) -> String in file.path },
                       "/y/Contract.pdf")
        let never: @Sendable (URL, Bool, (URL) throws -> Void) throws -> Void = { (_: URL, _: Bool, _: (URL) throws -> Void) throws -> Void in }
        XCTAssertThrowsError(try AppState.accessing(url, writing: true, through: never) { (file: URL) -> String in file.path }) { error in
            XCTAssertEqual((error as? PDFAppendError)?.problem, .missing)
        }
    }
}
