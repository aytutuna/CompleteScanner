#if os(iOS)
import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// A CompleteScanner document (.csdoc) on the iPhone, through the shell as the root view and the scan
// screen use it, without a screen: where an opened file goes, the queue shared as one, and one opened
// from a folder of the test's own. What the banner's buttons do is AppStatePackageTests'.

final class IOSPackageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSPackageTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: IOSShell.packageShareFolder)
    }

    /// A light page with a dark bar, `width` × `height` pixels.
    private func picture(width: Int, height: Int) -> CGImage {
        let ctx: CGContext = ImportTestSupport.context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: 8))
        return ctx.makeImage()!
    }

    func test_aPackage_goesToTheBanner_otherFilesToTheImport() {
        XCTAssertTrue(IOSShell.isPackage(URL(fileURLWithPath: "/tmp/Inbox/Receipt.csdoc")))
        XCTAssertTrue(IOSShell.isPackage(URL(fileURLWithPath: "/tmp/RECEIPT.CSDOC")))
        XCTAssertFalse(IOSShell.isPackage(URL(fileURLWithPath: "/tmp/scan.pdf")))
        XCTAssertFalse(IOSShell.isPackage(URL(fileURLWithPath: "/tmp/photo.jpg")))
        XCTAssertFalse(IOSShell.isPackage(URL(fileURLWithPath: "/tmp/csdoc")))
        XCTAssertEqual(IOSShell.packageType.identifier, "com.completescanner.package")
        XCTAssertEqual(IOSShell.sharePackageLabel, "Share as Lazy Scan document")
    }

    @MainActor
    func test_sharePackage_writesTheQueueUnderTheSettingsName_andOpensTheShareSheet() async throws {
        let actions = IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in })
        let state = AppState(backends: [], presetStore: PresetStore(directory: folder), fileActions: actions,
                             orientationScorer: ImportTestScorer(), barcodeReader: ImportTestBarcodes(),
                             files: AppStateFiles.all(in: folder))
        state.settings.intent = .document
        state.settings.documentMultiPage = true
        state.settings.taskId = nil
        state.settings.format = .pdf
        state.settings.pdfSearchable = false
        state.settings.destinationPath = folder.path
        state.settings.namingTemplate = "Lunch"

        let nothing: URL? = await IOSShell.sharePackage(state)
        XCTAssertNil(nothing)
        XCTAssertEqual(state.errorMessage, CompanionPackage.noPagesMessage)
        XCTAssertNil(actions.shareRequest)
        state.errorMessage = nil

        let pages: [ScannedPage] = [ScannedPage(image: picture(width: 300, height: 400), dpi: 50, colorMode: .color),
                                    ScannedPage(image: picture(width: 300, height: 400), dpi: 50, colorMode: .color)]
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }

        let shared: URL? = await IOSShell.sharePackage(state)
        let url: URL = try XCTUnwrap(shared)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(url.lastPathComponent, "Lunch.csdoc")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       IOSShell.packageShareFolder.standardizedFileURL.path)
        XCTAssertEqual(actions.shareRequest?.urls, [url])
        XCTAssertEqual(try CompanionPackage.read(contentsOf: url).pages.count, 2)
        XCTAssertEqual(state.scannedPages.count, 2)

        // The folder is emptied each time, so the next share keeps the plain name.
        let again: URL? = await IOSShell.sharePackage(state)
        XCTAssertEqual(again?.lastPathComponent, "Lunch.csdoc")
    }

    @MainActor
    func test_openPackage_offersACopyOfTheFile_andLeavesTheFileAndTheQueueAlone() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let jpeg: Data = try XCTUnwrap(PDFImageEncoding.encodeJPEG(picture(width: 40, height: 60), quality: 0.9))
        let document = CompanionDocument(title: "Receipt", pages: [CompanionPage(image: CompanionImage(
            data: jpeg, format: .jpeg, pixelWidth: 40, pixelHeight: 60, dpi: 200, colorMode: .color))])
        let url: URL = folder.appendingPathComponent("Receipt.csdoc")
        try CompanionPackage.make(document).write(to: url)

        await IOSShell.openPackage(url, in: state)
        XCTAssertNil(state.errorMessage)
        let offered: PendingPackage = try XCTUnwrap(state.pendingPackage)
        XCTAssertEqual(offered.fileName, "Receipt.csdoc")
        XCTAssertEqual(offered.pageCount, 1)
        XCTAssertEqual(offered.documentName, "Receipt")
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        state.dismissPendingPackage()
        await IOSShell.openPackage(folder.appendingPathComponent("Missing.csdoc"), in: state)
        XCTAssertNil(state.pendingPackage)
        XCTAssertTrue(state.errorMessage?.hasPrefix("Missing.csdoc could not be opened: ") == true)
    }
}
#endif
