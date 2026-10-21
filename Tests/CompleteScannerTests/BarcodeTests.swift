import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/BarcodeTests.cs: the same cases, with a stand-in reader.
// The real readers are checked on synthetic scans: Vision here (VisionBarcodeTests.swift), ZXing.Net
// in the Windows app's tests (CompleteScanner.App.Tests/BarcodeReaderTests.cs).

/// A reader that returns what it was given and records the images it was asked to read.
private final class FakeReader: BarcodeReader {
    let readings: [BarcodeReading]
    var seen: [GrayImage] = []
    var isAvailable = true
    var failure: Error?

    init(_ readings: BarcodeReading...) {
        self.readings = readings
    }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        seen.append(image)
        if let failure { throw failure }
        return readings
    }
}

private struct ReaderFailure: Error {}

private struct UprightScorer: OrientationScorer {
    var isAvailable: Bool { true }
    func score(_ image: RgbaImage) throws -> OrientationScore { .none }
}

private func qr(_ text: String, x: Double = 10, y: Double = 10) -> BarcodeReading {
    BarcodeReading(symbology: .qrCode, text: text, bounds: CGRect(x: x, y: y, width: 20, height: 20))
}

private let plain = PageFacts()

/// The code of a QR separator sheet naming `name`: "CS-SEP Lease"; "CS-SEP" for none.
private func sheet(_ name: String?) -> String { QrSeparatorSheet.text(name) }

/// A side of a separator sheet naming `name`.
private func coded(_ name: String?) -> PageFacts { PageFacts(barcode: qr(sheet(name))) }

/// A page carrying a code of its own (an invoice's number, a payment QR code): no separator code.
private func own(_ text: String) -> PageFacts { PageFacts(barcode: qr(text)) }

private func front(_ sheet: Int, _ code: String? = nil, blank: Bool = false) -> PageFacts {
    PageFacts(sheetIndex: sheet, side: .front, looksBlank: blank, barcode: code.map { qr($0) })
}

private func back(_ sheet: Int, _ code: String? = nil, blank: Bool = false) -> PageFacts {
    PageFacts(sheetIndex: sheet, side: .back, looksBlank: blank, barcode: code.map { qr($0) })
}

private func with(_ facts: PageFacts, documentBreak: DocumentBreak? = nil, inclusion: PageInclusion? = nil,
                  label: String? = nil) -> PageFacts {
    var f = facts
    if let documentBreak { f.documentBreak = documentBreak }
    if let inclusion { f.inclusion = inclusion }
    if let label { f.label = label }
    return f
}

private func options(startsDocument: Bool = false, removeBlankPages: Bool = false,
                     mode: SplitMode = .barcode) -> DocumentOptions {
    var o = DocumentOptions()
    o.splitMode = mode
    o.barcodeStartsDocument = startsDocument
    o.removeBlankPages = removeBlankPages
    return o
}

private func documents(_ plan: SplitPlan) -> [[Int]] { plan.documents.map(\.pages) }

private func roles(_ plan: SplitPlan) -> String {
    String(plan.pages.map { page -> Character in
        switch page.role {
        case .content: return "c"
        case .skipped: return "s"
        case .separator: return "x"
        }
    })
}

private func solid(_ width: Int, _ height: Int, _ value: UInt8) -> CGImage {
    RgbaImage.filled(width: width, height: height, r: value, g: value, b: value).makeCGImage()!
}

private func pageOf(_ width: Int = 30, _ height: Int = 40, dpi: Int = 300) -> ScannedPage {
    ScannedPage(image: solid(width, height, 255), dpi: dpi, colorMode: .color)
}

/// A made-up 25 × 25 module pattern, the same on both platforms (not a readable code).
private func pattern() -> QrModules {
    let size = 25
    var dark = [Bool](repeating: false, count: size * size)
    for y in 0..<size {
        for x in 0..<size { dark[y * size + x] = (x * 3 + y * 5 + x * y) % 7 < 3 }
    }
    return QrModules(size: size, dark: dark)!
}

final class BarcodeTests: XCTestCase {
    // MARK: Kinds and readings

    func test_symbologies_theFourKindsRead() {
        XCTAssertEqual(BarcodeSymbology.all, [.qrCode, .code128, .code39, .dataMatrix])
        XCTAssertEqual(BarcodeSymbology.all.map(\.label), ["QR code", "Code 128", "Code 39", "Data Matrix"])
    }

    func test_inReadingOrder_topToBottomThenLeftToRight_withoutEmptyOrRepeatedCodes() {
        let lower = qr("lower", x: 5, y: 50)
        let right = qr("right", x: 40, y: 10)
        let left = BarcodeReading(symbology: .code128, text: "left", bounds: CGRect(x: 5, y: 10, width: 30, height: 0))
        let empty = qr("", x: 0, y: 0)
        let again = qr("right", x: 60, y: 70)
        let sameTextOtherKind = BarcodeReading(symbology: .dataMatrix, text: "right", bounds: CGRect(x: 0, y: 80, width: 5, height: 5))
        let ordered = BarcodeSeparators.inReadingOrder([lower, right, empty, left, again, sameTextOtherKind])
        XCTAssertEqual(ordered, [left, right, lower, sameTextOtherKind])
        // The same corner: by kind, then as read.
        let a = qr("a", x: 1, y: 1)
        let b = BarcodeReading(symbology: .code39, text: "b", bounds: CGRect(x: 1, y: 1, width: 3, height: 3))
        let c = qr("c", x: 1, y: 1)
        XCTAssertEqual(BarcodeSeparators.inReadingOrder([b, a, c]), [a, c, b])
        XCTAssertEqual(BarcodeSeparators.first(ordered), left)
        XCTAssertNil(BarcodeSeparators.first([]))
        XCTAssertNil(BarcodeSeparators.first(nil))
    }

    func test_read_handsTheReaderTheGrayCopyAtTheReadingResolution_andGivesBoundsInThePagesPixels() throws {
        let reader = FakeReader(qr("Lease", x: 20, y: 40), qr("Index", x: 2, y: 4))
        let image = RgbaImage.filled(width: 600, height: 900, r: 250, g: 250, b: 250)
        let found = try BarcodeSeparators.read(image, dpi: 300, reader: reader)
        XCTAssertEqual(reader.seen.count, 1)
        XCTAssertEqual(reader.seen[0].width, 400)
        XCTAssertEqual(reader.seen[0].height, 600)
        XCTAssertEqual(reader.seen[0].dpi, 200)
        XCTAssertEqual(found.map(\.text), ["Index", "Lease"])
        XCTAssertEqual(found[1].bounds, CGRect(x: 30, y: 60, width: 30, height: 30))
        // A scan no finer than the reading resolution is read as it is.
        let coarse = FakeReader(qr("Lease", x: 20, y: 40))
        let same = try BarcodeSeparators.read(RgbaImage.filled(width: 150, height: 200, r: 250, g: 250, b: 250),
                                              dpi: 150, reader: coarse)
        XCTAssertEqual(coarse.seen[0].width, 150)
        XCTAssertEqual(coarse.seen[0].height, 200)
        XCTAssertEqual(same[0].bounds, CGRect(x: 20, y: 40, width: 20, height: 20))
    }

    func test_readPage_readsASpooledPagesPreview_atTheResolutionItHas_boundsInFullSizePixels() throws {
        // A 2400 × 3000 page at 300 dpi whose preview is 800 × 1000: 100 dpi.
        let spool = URL(fileURLWithPath: "/tmp/spool.tiff")
        let preview = ScannedPage(image: solid(800, 1000, 255), dpi: 300, colorMode: .color, fileURL: spool,
                                  fullPixelSize: CGSize(width: 2400, height: 3000))
        let reader = FakeReader(qr("Lease", x: 20, y: 40))
        let found = try BarcodeSeparators.readPage(preview, reader: reader)
        XCTAssertEqual(reader.seen[0].width, 800)
        XCTAssertEqual(reader.seen[0].height, 1000)
        XCTAssertEqual(reader.seen[0].dpi, 100)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].bounds, CGRect(x: 60, y: 120, width: 60, height: 60))
        // Turned a quarter: the longer sides still match.
        let turned = ScannedPage(image: solid(1000, 800, 255), dpi: 300, colorMode: .color, fileURL: spool,
                                 fullPixelSize: CGSize(width: 2400, height: 3000))
        XCTAssertEqual(try BarcodeSeparators.readPage(turned, reader: reader)[0].bounds, CGRect(x: 60, y: 120, width: 60, height: 60))
        // A page not spooled: its own pixels at its own resolution.
        let whole = FakeReader(qr("Lease", x: 20, y: 40))
        _ = try BarcodeSeparators.readPage(pageOf(300, 400, dpi: 300), reader: whole)
        XCTAssertEqual(whole.seen[0].width, 200)
        XCTAssertEqual(whole.seen[0].height, 267)
        XCTAssertEqual(whole.seen[0].dpi, 200)
    }

    func test_readQueuedPage_readsTheSpoolFileTurnedLikeThePage_andAPreviewShowingNoCodeStaysUnread() throws {
        // A 2400 × 3000 page at 300 dpi whose preview is 800 × 1000; its spool file has every pixel.
        let spool = URL(fileURLWithPath: "/tmp/spool.png")
        let preview = ScannedPage(image: solid(800, 1000, 255), dpi: 300, colorMode: .color, fileURL: spool,
                                  fullPixelSize: CGSize(width: 2400, height: 3000))
        let full = solid(2400, 3000, 255)
        let reader = FakeReader(qr("Lease", x: 20, y: 40))
        let found = try BarcodeSeparators.readQueuedPage(preview, spoolImage: full, reader: reader)
        XCTAssertEqual(reader.seen[0].width, 1600)
        XCTAssertEqual(reader.seen[0].height, 2000)
        XCTAssertEqual(reader.seen[0].dpi, 200)
        XCTAssertEqual(found?.count, 1)
        XCTAssertEqual(found?.first?.bounds, CGRect(x: 30, y: 60, width: 30, height: 30))
        // Nothing found on the spool file: read, with no code.
        XCTAssertEqual(try BarcodeSeparators.readQueuedPage(preview, spoolImage: full, reader: FakeReader()), [])
        // Turned a quarter by the user: the spool file, as scanned, is turned like the page.
        var turned = ScannedPage(image: solid(1000, 800, 255), dpi: 300, colorMode: .color, fileURL: spool,
                                 fullPixelSize: CGSize(width: 2400, height: 3000))
        turned.rotationQuarterTurns = 1
        let turnedReader = FakeReader()
        _ = try BarcodeSeparators.readQueuedPage(turned, spoolImage: full, reader: turnedReader)
        XCTAssertEqual(turnedReader.seen[0].width, 2000)
        XCTAssertEqual(turnedReader.seen[0].height, 1600)
        // No spool file to read: the preview. Nothing found there leaves the page unread, as a code too
        // fine for the preview may be there; a code found is kept.
        let none = FakeReader()
        XCTAssertNil(try BarcodeSeparators.readQueuedPage(preview, spoolImage: nil, reader: none))
        XCTAssertEqual(none.seen[0].width, 800)
        XCTAssertEqual(none.seen[0].height, 1000)
        XCTAssertEqual(try BarcodeSeparators.readQueuedPage(preview, spoolImage: nil,
                                                            reader: FakeReader(qr("Lease", x: 20, y: 40)))?.first?.bounds,
                       CGRect(x: 60, y: 120, width: 60, height: 60))
        // A page never spooled holds every pixel: nothing found is no code.
        XCTAssertEqual(try BarcodeSeparators.readQueuedPage(pageOf(300, 400, dpi: 300), spoolImage: nil, reader: FakeReader()), [])
    }

    // MARK: Names from codes

    func test_label_aCodesTextAsADocumentName() {
        XCTAssertEqual(BarcodeSeparators.label("  Lease\t2026 \r\n"), "Lease 2026")
        XCTAssertEqual(BarcodeSeparators.label("Invoice\u{0}42\u{7} -   March"), "Invoice 42 - March")
        XCTAssertEqual(BarcodeSeparators.label("https://example.com/inv/42"), "https---example.com-inv-42")
        XCTAssertEqual(BarcodeSeparators.label("a\\b:c*d?e\"f<g>h|i"), "a-b-c-d-e-f-g-h-i")
        XCTAssertEqual(BarcodeSeparators.label("Fatura Şubat №5 東京"), "Fatura Şubat №5 東京")
        XCTAssertNil(BarcodeSeparators.label(nil))
        XCTAssertNil(BarcodeSeparators.label(""))
        XCTAssertNil(BarcodeSeparators.label(" \n\t"))
        // The sheet that only splits.
        XCTAssertNil(BarcodeSeparators.label("SEPARATOR"))
        XCTAssertNil(BarcodeSeparators.label(" separator "))
        XCTAssertEqual(BarcodeSeparators.label("SEPARATORS"), "SEPARATORS")
        // Invisible format characters are dropped: a byte-order mark, zero-width spaces and joiners,
        // bidi overrides and isolates, which would hide or reorder a file name.
        XCTAssertNil(BarcodeSeparators.label("\u{FEFF}SEPARATOR"))
        XCTAssertEqual(BarcodeSeparators.label("\u{FEFF}Inv\u{200B}oice\u{00A0}7"), "Invoice 7")
        XCTAssertEqual(BarcodeSeparators.label("Invoice\u{202E}txt.exe\u{202C}"), "Invoicetxt.exe")
        XCTAssertEqual(BarcodeSeparators.label("\u{2066}Lease\u{2069}\u{200D}"), "Lease")
        XCTAssertNil(BarcodeSeparators.label("\u{200B}\u{FEFF}\u{202E}"))
        // Cut like a name typed in the page strip.
        let longText = String(repeating: "0123456789", count: 12)
        XCTAssertEqual(BarcodeSeparators.label(longText), String(longText.prefix(DocumentSplitter.maxLabelLength)))
    }

    func test_describe_theKindAndTheText_cutWhenLong() {
        XCTAssertEqual(BarcodeSeparators.describe(qr("Lease")), "QR code \u{201C}Lease\u{201D}")
        let longText = String(repeating: "abcdefghij", count: 5)
        XCTAssertEqual(BarcodeSeparators.describe(BarcodeReading(symbology: .code39, text: longText,
                                                                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1))),
                       "Code 39 \u{201C}\(String(longText.prefix(39)))\u{2026}\u{201D}")
        XCTAssertTrue(BarcodeSeparators.startsDocumentHint(true).contains("invoices"))
        XCTAssertTrue(BarcodeSeparators.startsDocumentHint(false).contains("left out"))
        XCTAssertTrue(BarcodeSeparators.startsDocumentHint(false).contains("starts with \u{201C}CS-SEP\u{201D}"))
        XCTAssertTrue(BarcodeSeparators.startsDocumentHint(false, prefix: " DOC ").contains("starts with \u{201C}DOC\u{201D}"))
        XCTAssertFalse(BarcodeSeparators.startsDocumentHint(false, prefix: "").contains("starts with"))
    }

    // MARK: The clean-up stage

    func test_barcodeStep_recordsTheCodes_andAPageTheReaderFailsOnStaysUnread() throws {
        let page = pageOf(300, 400, dpi: 300)
        XCTAssertNil(page.barcodes)
        let read = BarcodeStep(reader: FakeReader(qr("Lease", x: 20, y: 40))).apply(page)
        XCTAssertEqual(BarcodeStep(reader: FakeReader()).name, "barcode")
        XCTAssertEqual(read.barcodes?.count, 1)
        XCTAssertEqual(read.barcodes?.first?.bounds, CGRect(x: 30, y: 60, width: 30, height: 30))
        XCTAssertTrue(read.image === page.image)
        let none = BarcodeStep(reader: FakeReader()).apply(page)
        XCTAssertEqual(none.barcodes, [])
        let failing = FakeReader()
        failing.failure = ReaderFailure()
        XCTAssertNil(BarcodeStep(reader: failing).apply(page).barcodes)
        XCTAssertThrowsError(try BarcodeStep(reader: FakeReader()).apply(page, shouldContinue: { false }))
        let cancelling = FakeReader()
        cancelling.failure = ScanError.cancelled
        XCTAssertThrowsError(try BarcodeStep(reader: cancelling).apply(page, shouldContinue: { true }))
    }

    func test_forScan_readsBarcodes_onlyWhenTheStackIsSplitAtBarcodes_andTheReaderCanRead() throws {
        let reader = FakeReader()
        var s = ScanSettings()
        s.adjustments.brightness = 0.25
        for mode in SplitMode.displayOrder where mode != .barcode {
            s.document.splitMode = mode
            XCTAssertFalse(PageProcessor.readsBarcodes(s))
            XCTAssertEqual(PageProcessor.forScan(s, barcodes: reader).steps.map(\.name), ["blank", "separator", "adjust"])
        }
        s.document.splitMode = .barcode
        XCTAssertTrue(PageProcessor.readsBarcodes(s))
        let processor = PageProcessor.forScan(s, barcodes: reader)
        XCTAssertEqual(processor.steps.map(\.name), ["blank", "separator", "barcode", "adjust"])
        let step = try XCTUnwrap(processor.steps[2] as? BarcodeStep)
        XCTAssertTrue((step.reader as AnyObject) === reader)
        XCTAssertEqual(PageProcessor.forScan(s).steps.map(\.name), ["blank", "separator", "adjust"])
        let unavailable = FakeReader()
        unavailable.isAvailable = false
        XCTAssertEqual(PageProcessor.forScan(s, barcodes: unavailable).steps.map(\.name), ["blank", "separator", "adjust"])
        // Before turning pages upright.
        s.document.autoRotate = true
        XCTAssertEqual(PageProcessor.forScan(s, scorer: UprightScorer(), barcodes: reader).steps.map(\.name),
                       ["blank", "separator", "barcode", "orientation", "adjust"])
        // Pages saved at once and photos are never read.
        var atOnce = s
        atOnce.documentMultiPage = false
        XCTAssertFalse(PageProcessor.readsBarcodes(atOnce))
        var photos = s
        photos.intent = .photo
        XCTAssertFalse(PageProcessor.readsBarcodes(photos))
    }

    func test_process_readsEveryPage() throws {
        var s = ScanSettings()
        s.document.splitMode = .barcode
        let reader = FakeReader(qr("Lease"))
        let result = try PageProcessor.forScan(s, barcodes: reader).process([pageOf(), pageOf()])
        for page in result.pages {
            XCTAssertEqual(page.barcodes?.map(\.text), ["Lease"])
        }
        XCTAssertEqual(reader.seen.count, 2)
    }

    func test_barcodes_surviveRebuildingThePage() {
        let codes = [qr(sheet("Lease"))]
        let original = pageOf().withBarcodes(codes)
        let geometry = PageGeometry(cropped: false, angleDegrees: 1.5, basis: .textLines)
        let shadow = SpineShadowResult(edge: .left, depth: 0.2, widthInches: 0.5, maxGain: 1.3, protectedFraction: 0)
        let rebuilt = [
            original.withImage(solid(3, 3, 0)),
            original.withSide(.front, sheetIndex: 0),
            original.withBlank(nil),
            original.withInclusion(.skip),
            original.withPatch(nil),
            original.withDocumentBreak(.split),
            original.withDocumentLabel("Chapter 1"),
            original.withUpright(UprightTurn(quarterTurns: 2)),
            original.turnedUpright(1),
            original.withAlternate(nil),
            original.withSpread(nil),
            original.withGeometry(solid(3, 3, 0), geometry: geometry),
            original.withSpineShadow(solid(3, 3, 0), result: shadow),
            pageOf().copyMeta(from: original),
        ]
        for page in rebuilt {
            XCTAssertEqual(page.barcodes, codes)
        }
        let corrected = original.withGeometry(solid(3, 3, 0), geometry: geometry)
        XCTAssertEqual(corrected.withVersionsSwapped(solid(30, 40, 255)).barcodes, codes)
        XCTAssertNil(original.withBarcodes(nil).barcodes)
        XCTAssertEqual(PageFacts.of(original, options: options()).barcode?.text, "CS-SEP Lease")
        XCTAssertNil(PageFacts.of(pageOf(), options: options()).barcode)
    }

    // MARK: Splitting at barcode or QR sheets

    func test_barcodeSheets_oneSided_areLeftOut_andNameTheDocumentAfterThem() {
        let plan = DocumentSplitter.plan([plain, plain, coded("Lease"), plain, coded("Invoice 42"), plain, plain], options: options())
        XCTAssertEqual(documents(plan), [[0, 1], [3], [5, 6]])
        XCTAssertEqual(roles(plan), "ccxcxcc")
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Lease", "Invoice 42"])
        XCTAssertEqual(plan.separatorCount, 2)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.pageCount, 5)
        // A sheet in front of the first document names it too; one with no name names nothing.
        let first = DocumentSplitter.plan([coded("Lease"), plain, coded(nil), plain], options: options())
        XCTAssertEqual(documents(first), [[1], [3]])
        XCTAssertEqual(first.documents.map(\.label), ["Lease", nil])
        XCTAssertEqual(DocumentSplitter.dividerTitle(first, 1), "Document 1 \u{00B7} Lease")
    }

    func test_barcodeSheets_inARow_splitOnce_theLastOneNames() {
        let plan = DocumentSplitter.plan([plain, coded("Old"), coded("New"), plain, coded("Named"), coded(nil), plain,
                                          coded("Last")], options: options())
        XCTAssertEqual(documents(plan), [[0], [3], [6]])
        XCTAssertEqual(plan.documents.map(\.label), [nil, "New", nil])
        XCTAssertEqual(roles(plan), "cxxcxxcx")
    }

    func test_barcodeSheets_twoSided_aCodeOnEitherSide_theWholeSheetIsLeftOut() {
        let facts = [
            front(0), back(0, blank: true),
            front(1, blank: true), back(1, sheet("Lease")),
            front(2), back(2, "PAY 42"),
            front(3, sheet("Invoice 7")), back(3, sheet("Ignored"), blank: true),
            front(4), back(4, blank: true),
        ]
        let plan = DocumentSplitter.plan(facts, options: options(removeBlankPages: true))
        XCTAssertEqual(documents(plan), [[0], [4, 5], [8]])
        XCTAssertEqual(roles(plan), "csxxccxxcs")
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Lease", "Invoice 7"])
    }

    func test_onlyCodesStartingWithThePrefix_makeSeparatorSheets_othersAreIgnored() {
        // An invoice carrying a payment QR code and an order number, between two separator sheets.
        let facts = [plain, coded("Lease"), own("SPC 0200 1 CH4431999123000889012"), plain, own("ORDER-4711"), coded(nil), plain]
        let plan = DocumentSplitter.plan(facts, options: options())
        XCTAssertEqual(documents(plan), [[0], [2, 3, 4], [6]])
        XCTAssertEqual(roles(plan), "cxcccxc")
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Lease", nil])
        // Compared with a–z matching A–Z, after spaces and invisible characters (a byte-order mark).
        XCTAssertEqual(BarcodeSeparators.defaultPrefix, "CS-SEP")
        XCTAssertEqual(DocumentOptions().splitBarcodePrefix, "CS-SEP")
        XCTAssertTrue(BarcodeSeparators.startsWithPrefix("cs-sep Lease", "CS-SEP"))
        XCTAssertTrue(BarcodeSeparators.startsWithPrefix("\u{FEFF} CS-SEP", " CS-SEP "))
        XCTAssertFalse(BarcodeSeparators.startsWithPrefix("CS-SE", "CS-SEP"))
        XCTAssertFalse(BarcodeSeparators.startsWithPrefix("INVOICE CS-SEP", "CS-SEP"))
        XCTAssertEqual(BarcodeSeparators.codeLabel("cs-sep Lease", options: options()), "Lease")
        XCTAssertEqual(BarcodeSeparators.codeLabel("\u{FEFF}CS-SEP Lease", options: options()), "Lease")
        XCTAssertEqual(BarcodeSeparators.codeLabel("ORDER-4711", options: options()), "ORDER-4711")
        XCTAssertNil(BarcodeSeparators.codeLabel("CS-SEP", options: options()))
        XCTAssertNil(BarcodeSeparators.codeLabel("CS-SEP \u{200B} ", options: options()))
        XCTAssertNil(BarcodeSeparators.codeLabel(nil, options: options()))
        // On a page with several codes, the first separator code counts, wherever it is; a barcode
        // starting a document takes the first code.
        let page = pageOf().withBarcodes([qr("PAY 42", x: 10, y: 10), qr(sheet("Invoice 7"), x: 10, y: 300)])
        XCTAssertEqual(PageFacts.of(page, options: options()).barcode?.text, sheet("Invoice 7"))
        XCTAssertEqual(PageFacts.of(page, options: options(startsDocument: true)).barcode?.text, "PAY 42")
        XCTAssertNil(PageFacts.of(pageOf().withBarcodes([qr("PAY 42")]), options: options()).barcode)
        // Another prefix, spaces around it ignored.
        var mine = options()
        mine.splitBarcodePrefix = "  DOC: "
        let custom = DocumentSplitter.plan([plain, own("doc: Lease"), plain, coded("Invoice"), plain], options: mine)
        XCTAssertEqual(documents(custom), [[0], [2, 3, 4]])
        XCTAssertEqual(custom.documents.map(\.label), [nil, "Lease"])
        XCTAssertEqual(QrSeparatorSheet.text("Lease", prefix: mine.splitBarcodePrefix), "DOC: Lease")
        XCTAssertEqual(QrSeparatorSheet.text(nil, prefix: mine.splitBarcodePrefix), "DOC:")
        // An empty prefix: every code makes a separator sheet, and "SEPARATOR" names nothing.
        var anyCode = options()
        anyCode.splitBarcodePrefix = " "
        let all = DocumentSplitter.plan([plain, own("Lease"), plain, own("separator"), plain], options: anyCode)
        XCTAssertEqual(documents(all), [[0], [2], [4]])
        XCTAssertEqual(all.documents.map(\.label), [nil, "Lease", nil])
        XCTAssertEqual(QrSeparatorSheet.text("Lease", prefix: ""), "Lease")
        XCTAssertEqual(QrSeparatorSheet.text(nil, prefix: " "), "SEPARATOR")
    }

    func test_barcodeSheets_keptByTheUser_areSavedAndSplitNothing() {
        let facts = [plain, with(coded("Lease"), inclusion: .keep), plain]
        let plan = DocumentSplitter.plan(facts, options: options())
        XCTAssertEqual(documents(plan), [[0, 1, 2]])
        XCTAssertEqual(plan.documents.map(\.label), [nil])
        XCTAssertEqual(DocumentSplitter.toggledInclusion([plain, coded("Lease"), plain], 1, options: options()), .keep)
    }

    func test_aBarcodeStartsADocument_thePageIsKept_andNamesIt() {
        let starts = options(startsDocument: true)
        let plan = DocumentSplitter.plan([plain, own("Invoice 41"), plain, plain, own("Invoice 42"), own("Invoice 43")],
                                         options: starts)
        XCTAssertEqual(documents(plan), [[0], [1, 2, 3], [4], [5]])
        XCTAssertEqual(roles(plan), "cccccc")
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Invoice 41", "Invoice 42", "Invoice 43"])
        // The first page with a code: one document, named.
        let first = DocumentSplitter.plan([own("Lease"), plain], options: starts)
        XCTAssertEqual(documents(first), [[0, 1]])
        XCTAssertEqual(first.documents[0].label, "Lease")
        // A separator sheet's code does the same, named without its prefix.
        let fromSheets = DocumentSplitter.plan([plain, coded("Lease"), plain, coded(nil)], options: starts)
        XCTAssertEqual(documents(fromSheets), [[0], [1, 2], [3]])
        XCTAssertEqual(fromSheets.documents.map(\.label), [nil, "Lease", nil])
        // Two-sided: a code on the back starts the document at the front.
        let sheets = DocumentSplitter.plan([front(0), back(0), front(1), back(1, "Lease"), front(2), back(2)], options: starts)
        XCTAssertEqual(documents(sheets), [[0, 1], [2, 3, 4, 5]])
        XCTAssertEqual(sheets.documents.map(\.label), [nil, "Lease"])
        // A page with a code that is skipped still starts the document at the next page saved.
        let skipped = DocumentSplitter.plan([plain, with(own("Lease"), inclusion: .skip), plain], options: starts)
        XCTAssertEqual(documents(skipped), [[0], [2]])
        XCTAssertEqual(skipped.documents.map(\.label), [nil, "Lease"])
    }

    func test_theUsersNamesAndJoinsWin_overTheCodes() {
        let facts = [plain, coded("Lease"), with(plain, label: "Mine"), plain, coded("Invoice"), with(plain, documentBreak: .join)]
        let plan = DocumentSplitter.plan(facts, options: options())
        XCTAssertEqual(documents(plan), [[0], [2, 3, 5]])
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Mine"])
        // A split by hand after a separator does not take its name.
        let split = DocumentSplitter.plan([coded("Lease"), plain, with(plain, documentBreak: .split)], options: options())
        XCTAssertEqual(split.documents.map(\.label), ["Lease", nil])
        // Joined to the document before: the code's name is gone with its document.
        let joined = DocumentSplitter.plan([plain, with(coded("Lease"), documentBreak: .join), plain],
                                           options: options(startsDocument: true))
        XCTAssertEqual(documents(joined), [[0, 1, 2]])
        XCTAssertEqual(joined.documents.map(\.label), [nil])
    }

    func test_otherSplits_ignoreBarcodes() {
        let facts = [plain, coded("Lease"), plain]
        for mode in [SplitMode.none, .separatorSheet, .blankSheet, .sheetCount] {
            let plan = DocumentSplitter.plan(facts, options: options(mode: mode))
            XCTAssertTrue(plan.documents.allSatisfy { $0.label == nil }, mode.rawValue)
            XCTAssertEqual(plan.separatorCount, 0, mode.rawValue)
        }
    }

    func test_carriedLabels_leaveNamesFromCodesToTheCodes() {
        // Skipping the first page of a document named by its separator sheet: no name is written on the pages.
        let before = [plain, coded("Lease"), plain, plain]
        let after = [plain, coded("Lease"), with(plain, inclusion: .skip), plain]
        XCTAssertEqual(DocumentSplitter.carriedLabels(before, after, options: options()), [nil, nil, nil, nil])
        XCTAssertEqual(DocumentSplitter.plan(after, options: options()).documents[1].label, "Lease")
        // A name the user gave still moves with its document.
        let named = [plain, coded("Lease"), with(plain, label: "Mine"), plain]
        let namedAfter = [plain, coded("Lease"), with(plain, inclusion: .skip, label: "Mine"), plain]
        XCTAssertEqual(DocumentSplitter.carriedLabels(named, namedAfter, options: options()), [nil, nil, nil, "Mine"])
    }

    func test_texts_forTheStripAndTheTaskSummary() {
        let pages = [
            pageOf(), pageOf().withBarcodes([qr(sheet("Lease"))]), pageOf(), pageOf().withBarcodes([qr(sheet(nil))]), pageOf(),
        ]
        let o = options()
        let plan = DocumentSplitter.plan(pages, options: o)
        XCTAssertEqual(documents(plan), [[0], [2], [4]])
        XCTAssertEqual(DocumentSplitter.badge(plan, 1, page: pages[1], options: o), "Separator")
        XCTAssertEqual(DocumentSplitter.separatorNote(plan, 1, page: pages[1]),
                       "Separator sheet (QR code \u{201C}CS-SEP Lease\u{201D}): a new document named \u{201C}Lease\u{201D} starts after it. It is not saved.")
        XCTAssertEqual(DocumentSplitter.separatorNote(plan, 3, page: pages[3]),
                       "Separator sheet (QR code \u{201C}CS-SEP\u{201D}): a new document starts after it. It is not saved.")
        XCTAssertNil(DocumentSplitter.separatorNote(plan, 2, page: pages[2]))
        XCTAssertEqual(DocumentSplitter.dividerTitle(plan, 2), "Document 2 \u{00B7} Lease")
        XCTAssertEqual(DocumentSplitter.queueSummary(pages, options: o), "5 pages \u{00B7} 3 documents \u{00B7} 2 separator pages skipped")
        XCTAssertEqual(DocumentSplitter.scanNote(plan, separatorsAdded: 2), " Found 2 separator pages: 3 documents to save.")
        // The save names the files after the codes.
        XCTAssertEqual(SavePlan.make(pages, options: o).documents.map(\.label), [nil, "Lease", nil])

        var s = TaskCatalog.apply(.batch, to: ScanSettings())
        s.document.splitMode = .barcode
        XCTAssertTrue(TaskCatalog.summary(s).contains("Split at barcode sheets"))
        s.document.barcodeStartsDocument = true
        XCTAssertTrue(TaskCatalog.summary(s).contains("Split and named at barcodes"))
    }

    func test_separatorNote_namesTheDocumentThePlanStartsAfterTheSheet() throws {
        // Two code sheets in a row: the last names the document, and both notes say so.
        var pages = [
            pageOf(), pageOf().withBarcodes([qr(sheet("Lease"))]), pageOf().withBarcodes([qr(sheet("Invoice 7"))]), pageOf(),
        ]
        let plan = DocumentSplitter.plan(pages, options: options())
        XCTAssertEqual(DocumentSplitter.separatorNote(plan, 1, page: pages[1]),
                       "Separator sheet (QR code \u{201C}CS-SEP Lease\u{201D}): a new document named \u{201C}Invoice 7\u{201D} starts after it. It is not saved.")
        XCTAssertEqual(DocumentSplitter.separatorNote(plan, 2, page: pages[2]),
                       "Separator sheet (QR code \u{201C}CS-SEP Invoice 7\u{201D}): a new document named \u{201C}Invoice 7\u{201D} starts after it. It is not saved.")
        // A name the user gives wins.
        pages[3] = pages[3].withDocumentLabel("Mine")
        let named = DocumentSplitter.plan(pages, options: options())
        XCTAssertEqual(DocumentSplitter.separatorNote(named, 2, page: pages[2]),
                       "Separator sheet (QR code \u{201C}CS-SEP Invoice 7\u{201D}): a new document named \u{201C}Mine\u{201D} starts after it. It is not saved.")
        // Two-sided, the code on the back only: the front gives the sheet's code too.
        let sheets = [
            pageOf().withSide(.front, sheetIndex: 0), pageOf().withSide(.back, sheetIndex: 0),
            pageOf().withSide(.front, sheetIndex: 1), pageOf().withSide(.back, sheetIndex: 1).withBarcodes([qr(sheet("Lease"))]),
            pageOf().withSide(.front, sheetIndex: 2), pageOf().withSide(.back, sheetIndex: 2),
        ]
        let twoSided = DocumentSplitter.plan(sheets, options: options())
        XCTAssertEqual(twoSided.pages[2].code?.text, sheet("Lease"))
        XCTAssertEqual(DocumentSplitter.separatorNote(twoSided, 2, page: sheets[2]),
                       "Separator sheet (QR code \u{201C}CS-SEP Lease\u{201D}): a new document named \u{201C}Lease\u{201D} starts after it. It is not saved.")
        XCTAssertEqual(DocumentSplitter.separatorNote(twoSided, 2, page: sheets[2]),
                       DocumentSplitter.separatorNote(twoSided, 3, page: sheets[3]))
        // A sheet with nothing after it.
        let last = DocumentSplitter.plan([pageOf(), pageOf().withBarcodes([qr(sheet("Lease"))])], options: options())
        XCTAssertEqual(DocumentSplitter.separatorNote(last, 1, page: pageOf().withBarcodes([qr(sheet("Lease"))])),
                       "Separator sheet (QR code \u{201C}CS-SEP Lease\u{201D}): a new document starts after it. It is not saved.")
        // Joined across the sheet: no document starts after it, so none is named.
        let joinedPages = [
            pageOf().withDocumentLabel("Alpha"), pageOf().withBarcodes([qr(sheet("Lease"))]), pageOf().withDocumentBreak(.join),
        ]
        let joined = DocumentSplitter.plan(joinedPages, options: options())
        XCTAssertEqual(documents(joined), [[0, 2]])
        XCTAssertEqual(joined.documents[0].label, "Alpha")
        XCTAssertEqual(DocumentSplitter.separatorNote(joined, 1, page: joinedPages[1]),
                       "Separator sheet (QR code \u{201C}CS-SEP Lease\u{201D}): the pages after it are joined to the document before. It is not saved.")
        // Patch codes and other splits carry no code.
        XCTAssertTrue(DocumentSplitter.plan(pages, options: options(mode: .separatorSheet)).pages.allSatisfy { $0.code == nil })
    }

    // MARK: The QR separator sheet

    func test_qrModules_rowByRow() {
        let modules = QrModules(size: 2, dark: [true, false, false, true])!
        XCTAssertTrue(modules[0, 0])
        XCTAssertFalse(modules[1, 0])
        XCTAssertFalse(modules[0, 1])
        XCTAssertTrue(modules[1, 1])
        XCTAssertNil(QrModules(size: 2, dark: [true]))
        XCTAssertNil(QrModules(size: 0, dark: []))
    }

    func test_qrSheet_textAndCaption() {
        XCTAssertEqual(QrSeparatorSheet.text(" Lease  2026 "), "CS-SEP Lease 2026")
        XCTAssertEqual(QrSeparatorSheet.text(nil), "CS-SEP")
        XCTAssertEqual(QrSeparatorSheet.text("  "), "CS-SEP")
        XCTAssertEqual(QrSeparatorSheet.text("separator"), "CS-SEP")
        XCTAssertEqual(BarcodeSeparators.codeLabel(QrSeparatorSheet.text(" Lease  2026 "), options: DocumentOptions()), "Lease 2026")
        XCTAssertEqual(QrSeparatorSheet.caption("Lease 2026"), "LEASE 2026")
        XCTAssertEqual(QrSeparatorSheet.caption("Fatura Şubat №5 東京"), "FATURA SUBAT ?5 ??")
        XCTAssertEqual(QrSeparatorSheet.caption("Café crème, a-b_c #1+2 & 'x'!"), "CAFE CREME, A-B_C #1+2 & 'X'!")
        XCTAssertEqual(QrSeparatorSheet.caption("😀@"), "??")
    }

    func test_qrSheet_drawsTheCodeWithItsQuietZone_theNameAndHowToUseIt() {
        let code = pattern()
        let sheet = QrSeparatorSheet.render(code, name: "Lease 2026", widthInches: 8.5, heightInches: 11, dpi: 100)
        XCTAssertEqual(sheet.width, 850)
        XCTAssertEqual(sheet.height, 1100)
        XCTAssertEqual(sheet.dpi, 100)
        // 2.5 in for 25 modules and 8 of quiet zone: 7 pixels a module, the code 175 pixels wide, centred.
        let module = 250 / (25 + 8)
        XCTAssertEqual(module, 7)
        let x0 = (850 - 25 * module) / 2, y0 = 180 + 4 * module
        for y in 0..<25 {
            for x in 0..<25 {
                XCTAssertEqual(sheet[x0 + x * module + 3, y0 + y * module + 3], code[x, y] ? 0 : 255)
            }
        }
        // The quiet zone is white.
        for k in (-4 * module)..<(25 * module + 4 * module) {
            XCTAssertEqual(sheet[x0 + k, y0 - 4 * module], 255)
            XCTAssertEqual(sheet[x0 + k, y0 + 25 * module + 4 * module - 1], 255)
        }
        XCTAssertEqual(TestPages.checksum(sheet), 968_354_098)
        XCTAssertEqual(TestPages.checksum(QrSeparatorSheet.render(code, name: nil, widthInches: 8.5, heightInches: 11, dpi: 100)),
                       501_687_770)
        XCTAssertEqual(TestPages.checksum(QrSeparatorSheet.render(code, name: "Lease 2026", widthInches: 210 / 25.4,
                                                                  heightInches: 297 / 25.4, dpi: 150)),
                       1_710_040_988)
        // A name too long for the line at the smallest type is cut with "...".
        let longName = String(repeating: "W", count: 100)
        let cut = QrSeparatorSheet.render(code, name: longName, widthInches: 8.5, heightInches: 11, dpi: 100)
        XCTAssertNotEqual(TestPages.checksum(cut), TestPages.checksum(sheet))
        var buffer = [UInt8](repeating: 0, count: 850 * 50)
        XCTAssertEqual(QrSeparatorSheet.drawCaption(&buffer, 850, 50, QrSeparatorSheet.caption(longName), top: 0, dpi: 100), 2)
        XCTAssertEqual(QrSeparatorSheet.drawCaption(&buffer, 850, 50, "LEASE", top: 0, dpi: 100), 4)
        XCTAssertEqual(QrSeparatorSheet.drawCaption(&buffer, 850, 50, String(repeating: "W", count: 40), top: 0, dpi: 100), 3)
    }

    func test_qrSheet_fileNamesAndMessages() {
        XCTAssertEqual(QrSeparatorSheet.fileBaseName(" Lease 2026", paper: .letter), "Separator sheet (QR code, Lease 2026, Letter)")
        XCTAssertEqual(QrSeparatorSheet.fileBaseName(nil, paper: .a4), "Separator sheet (QR code, A4)")
        XCTAssertEqual(QrSeparatorSheet.fileBaseName("a/b", paper: .a4), "Separator sheet (QR code, a-b, A4)")
        XCTAssertEqual(QrSeparatorSheet.savedMessage("S.pdf", name: "Lease"),
                       "Saved the QR separator sheet for \u{201C}Lease\u{201D}: S.pdf. Print it and put it in front of that document; the document is named \u{201C}Lease\u{201D}.")
        XCTAssertEqual(QrSeparatorSheet.savedMessage("S.pdf", name: ""),
                       "Saved the QR separator sheet: S.pdf. Print as many as you need and put one in front of each document.")
        XCTAssertEqual(QrSeparatorSheet.printedMessage("P", name: "Lease"),
                       "Sent the QR separator sheet for \u{201C}Lease\u{201D} to P. Put it in front of that document; the document is named \u{201C}Lease\u{201D}.")
        XCTAssertEqual(QrSeparatorSheet.printedMessage("P", name: nil),
                       "Sent the QR separator sheet to P. Put one in front of each document; print more copies as you need them.")
        XCTAssertEqual(QrSeparatorSheet.dpi, 300)
    }

    // MARK: Code 39

    func test_code39_modulesFramedByStars() {
        XCTAssertTrue(Code39.canEncode("INVOICE 1002"))
        XCTAssertTrue(Code39.canEncode("A-B.C $/+%"))
        XCTAssertFalse(Code39.canEncode(""))
        XCTAssertFalse(Code39.canEncode("lower"))
        XCTAssertFalse(Code39.canEncode("A*B"))
        XCTAssertEqual(Code39.modules("lower"), [])
        // A character is 6 narrow and 3 wide elements (15 modules); a narrow space between characters.
        let a = Code39.modules("A")
        XCTAssertEqual(a.count, 3 * 15 + 2)
        let bits = String(a.map { $0 ? Character("1") : Character("0") })
        XCTAssertEqual(bits, "100010111011101" + "0" + "111010100010111" + "0" + "100010111011101")
    }

    func test_code39_theDemoSheet() {
        let sheet = Code39.renderSheet("INVOICE 1002", widthInches: 8.5, heightInches: 11, dpi: 100)
        XCTAssertEqual(sheet.width, 850)
        XCTAssertEqual(sheet.height, 1100)
        // The bars, 0.02 in a module, 0.8 in tall, 1.8 in from the top, centred.
        let modules = Code39.modules("INVOICE 1002")
        let x0 = (850 - 2 * modules.count) / 2
        for (i, bar) in modules.enumerated() {
            XCTAssertEqual(sheet[x0 + 2 * i, 180], bar ? 0 : 255)
            XCTAssertEqual(sheet[x0 + 2 * i + 1, 259], bar ? 0 : 255)
        }
        XCTAssertEqual(sheet[x0 + 1, 260], 255)
        XCTAssertEqual(TestPages.checksum(sheet), 28_674_273)
        // Text that can't be drawn: the sheet without a code.
        XCTAssertEqual(Code39.renderSheet("lower", widthInches: 8.5, heightInches: 11, dpi: 100)[425, 200], 255)
    }
}
