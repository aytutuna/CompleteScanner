#if os(iOS)
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// PDFs imported on the iPhone (`IOSPDFPages`, `IOSImportSession`): each page drawn at 300 dpi the right
// way up (its rotation applied) and on white, a poster drawn smaller, a locked PDF refused, and the round
// trip: a PDF's pages imported into the queue and saved again keep their number, order and size.

/// A PDF of pages `sizes` (points), each with a red square 72 pt (one inch) wide, 36 pt in from its
/// top-left corner, and a blue one at its bottom right; page `rotated` (if any) turned 90° clockwise.
private func makePDF(_ sizes: [CGSize], rotated: Int? = nil, password: String? = nil) throws -> Data {
    let data = NSMutableData()
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password
    }
    let consumer: CGDataConsumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    var first = CGRect(origin: .zero, size: sizes[0])
    let context: CGContext = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &first, info as CFDictionary))
    for size in sizes {
        var box = CGRect(origin: .zero, size: size)
        let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: boxData]
        context.beginPDFPage(pageInfo as CFDictionary)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        // PDF space counts y up from the bottom.
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 36, y: size.height - 36 - 72, width: 72, height: 72))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: size.width - 36 - 72, y: 36, width: 72, height: 72))
        context.endPDFPage()
    }
    context.closePDF()
    guard let rotated else { return data as Data }
    let document: PDFDocument = try XCTUnwrap(PDFDocument(data: data as Data))
    let page: PDFPage = try XCTUnwrap(document.page(at: rotated))
    page.rotation = 90
    return try XCTUnwrap(document.dataRepresentation())
}

/// The pixel at (x, y) (top-left origin) of `image`, as red, green, blue.
private func color(_ image: CGImage, x: Int, y: Int) -> [Int] {
    let pixels: RgbaImage = RgbaImage(cgImage: image)!
    let at: Int = (y * pixels.width + x) * 4
    return [Int(pixels.pixels[at]), Int(pixels.pixels[at + 1]), Int(pixels.pixels[at + 2])]
}

private let letter = CGSize(width: 612, height: 792)
private let a4Landscape = CGSize(width: 842, height: 595)

final class IOSPDFImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSPDFImportTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    func test_eachPage_isDrawnAt300dpi_theRightWayUp_onWhite() throws {
        let data: Data = try makePDF([letter, a4Landscape, letter], rotated: 2)
        let document: PDFDocument = try IOSPDFPages.open(data, fileName: "three.pdf")
        XCTAssertEqual(document.pageCount, 3)

        let first: IOSRenderedPage = try XCTUnwrap(IOSPDFPages.render(document, index: 0))
        XCTAssertEqual(first.dpi, 300)
        XCTAssertEqual(first.image.width, 2550)
        XCTAssertEqual(first.image.height, 3300)
        // The red inch 0.5 in from the top left: pixels 150 to 450; the blue one at the bottom right.
        let red: [Int] = color(first.image, x: 300, y: 300)
        XCTAssertGreaterThan(red[0], 180)
        XCTAssertLessThan(red[2], 80)
        let blue: [Int] = color(first.image, x: 2550 - 300, y: 3300 - 300)
        XCTAssertGreaterThan(blue[2], 180)
        XCTAssertLessThan(blue[0], 80)
        for channel in color(first.image, x: 1275, y: 1650) {
            XCTAssertGreaterThanOrEqual(channel, 250)
        }

        let second: IOSRenderedPage = try XCTUnwrap(IOSPDFPages.render(document, index: 1))
        XCTAssertEqual(second.image.width, 3508)
        XCTAssertEqual(second.image.height, 2479)

        // Turned 90° clockwise: shown landscape, the red square now at the top right.
        let third: IOSRenderedPage = try XCTUnwrap(IOSPDFPages.render(document, index: 2))
        XCTAssertEqual(third.image.width, 3300)
        XCTAssertEqual(third.image.height, 2550)
        let turnedRed: [Int] = color(third.image, x: 3300 - 300, y: 300)
        XCTAssertGreaterThan(turnedRed[0], 180)
        XCTAssertLessThan(turnedRed[2], 80)
        let turnedBlue: [Int] = color(third.image, x: 300, y: 2550 - 300)
        XCTAssertGreaterThan(turnedBlue[2], 180)

        XCTAssertNil(IOSPDFPages.render(document, index: 3))
        XCTAssertNil(IOSPDFPages.render(document, index: -1))
    }

    func test_aPoster_isDrawnAtTheResolutionThatFits() {
        XCTAssertEqual(IOSPDFPages.resolution(for: letter), 300)
        // 3000 × 2000 pt at 300 dpi would be 12500 px long: 7000 px fit at 168 dpi.
        XCTAssertEqual(IOSPDFPages.resolution(for: CGSize(width: 3000, height: 2000)), 168)
        XCTAssertEqual(IOSPDFPages.resolution(for: CGSize(width: 0, height: 0)), 300)
        XCTAssertEqual(IOSPDFPages.maxLongSide, 7000)
    }

    func test_aLockedPDF_isRefused_withWhy() throws {
        let data: Data = try makePDF([letter], password: "sesame")
        XCTAssertThrowsError(try IOSPDFPages.open(data, fileName: "locked.pdf")) { (error: Error) in
            XCTAssertEqual((error as? IOSImportError)?.message,
                           PhotoImport.unreadableMessage("locked.pdf", detail: IOSPDFPages.lockedDetail))
        }
        XCTAssertThrowsError(try IOSPDFPages.open(Data("not a pdf".utf8), fileName: "notes.pdf"))
    }

    @MainActor
    func test_roundTrip_importedPagesSavedAgain_keepTheirNumberOrderAndSize() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state)
        let data: Data = try makePDF([letter, a4Landscape, letter], rotated: 2)
        let item = IOSImportItem(name: "three.pdf", data: data, kind: IOSImportItem.kind(forFileName: "three.pdf", data: data))
        XCTAssertEqual(item.kind, .pdf)
        let outcome: IOSImportOutcome = await importer.importItems([item])
        XCTAssertEqual(outcome.added, 3)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertFalse(importer.isImporting)
        XCTAssertNil(importer.cornerRequest)
        try await ImportTestSupport.waitUntil(timeout: 120) { !state.isBusy }
        XCTAssertEqual(state.scannedPages.count, 3)
        var dpis: [Int] = []
        for page in state.scannedPages {
            dpis.append(page.dpi)
            XCTAssertEqual(page.source, .photo)
            XCTAssertNil(page.capture)
        }
        XCTAssertEqual(dpis, [300, 300, 300])

        state.savePDF()
        try await ImportTestSupport.waitUntil(timeout: 240) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        let url: URL = try XCTUnwrap(state.lastSavedURLs.first)
        let saved: PDFDocument = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(saved.pageCount, 3)
        let expected: [CGSize] = [letter, a4Landscape, CGSize(width: 792, height: 612)]
        var index: Int = 0
        while index < 3 {
            let page: PDFPage = try XCTUnwrap(saved.page(at: index))
            let size: CGSize = IOSPDFPages.shownSize(page)
            XCTAssertEqual(Double(size.width), Double(expected[index].width), accuracy: 1.0, "page \(index + 1)")
            XCTAssertEqual(Double(size.height), Double(expected[index].height), accuracy: 1.0, "page \(index + 1)")
            index += 1
        }
        // Saved, the queue is empty.
        XCTAssertTrue(state.scannedPages.isEmpty)
    }
}
#endif
