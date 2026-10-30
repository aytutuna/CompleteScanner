import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/LazyScan.Core.Tests/BookSplitterTests.cs: finding the gutter of an open book
// and cutting the spread into its pages, on the same synthetic spreads (TestPages, byte-identical,
// checked by checksum).

/// ±0.05 in at the analysis resolution (100 dpi).
private let spineTolerance = 5.0

private func assertIn(_ value: Double, _ low: Double, _ high: Double, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value >= low && value <= high, "\(value) not in \(low)...\(high) \(message)", file: file, line: line)
}

/// A w × h image whose pixel (x, y) is (x, y, 7, 255), so every pixel can be told apart.
private func coordinates(_ w: Int, _ h: Int) -> RgbaImage {
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            p[i] = UInt8(x & 0xFF)
            p[i + 1] = UInt8(y & 0xFF)
            p[i + 2] = 7
            p[i + 3] = 255
        }
    }
    return RgbaImage(width: w, height: h, pixels: p)
}

/// The first pixel's red value of each page: which part of the scan it came from (its x).
private func origins(_ pages: [RgbaImage]) -> [Int] {
    pages.map { Int($0.pixels[0]) }
}

private func blankPage() -> ScannedPage {
    ScannedPage(image: RgbaImage.filled(width: 4, height: 4, r: 255, g: 255, b: 255).makeCGImage()!, dpi: 100, colorMode: .color)
}

/// A blank spread twice as wide as it is high, to cut in two.
private func blankSpread() -> ScannedPage {
    ScannedPage(image: RgbaImage.filled(width: 20, height: 10, r: 255, g: 255, b: 255).makeCGImage()!, dpi: 100, colorMode: .color)
}

private func part(_ spread: UUID, _ part: Int?) -> ScannedPage {
    var page = blankPage()
    page.spread = SpreadPart(spreadID: spread, part: part,
                             gutter: part == nil ? nil : GutterResult(axis: .vertical, position: 2, confidence: 0.2, kind: .shadow))
    return page
}

final class BookSplitterTests: XCTestCase {

    // MARK: The spreads are the same on both platforms

    func test_spreads_areTheSameBytesOnBothPlatforms() {
        XCTAssertEqual(TestPages.checksum(TestPages.shadowSpread()), 0x4938_C9B4)
        XCTAssertEqual(TestPages.checksum(TestPages.marginSpread()), 0x7CCF_EA71)
        XCTAssertEqual(TestPages.checksum(TestPages.blankFacingSpread()), 0x01F7_6AFA)
        XCTAssertEqual(TestPages.checksum(TestPages.singlePageAcross()), 0xD3D4_D1E1)
        XCTAssertEqual(TestPages.checksum(TestPages.twoColumnPage()), 0xCBA4_11FE)
        XCTAssertEqual(TestPages.checksum(TestPages.sectionGapPage()), 0x978E_0100)
        XCTAssertEqual(TestPages.checksum(TestPages.pageBesideEmptyGlass()), 0xCB7D_0020)
    }

    // MARK: Finding the gutter

    func test_shadowSpread_findsTheSpine_withinAFiftiethOfAnInch() throws {
        let found = try XCTUnwrap(BookSplitter.findGutter(TestPages.shadowSpread()))
        XCTAssertEqual(found.axis, .vertical)
        XCTAssertEqual(found.kind, .shadow)
        assertIn(found.center, 572 - spineTolerance, 572 + spineTolerance)
        // The shadow is 25 % deep at its middle (less once smoothed, against the brightest paper).
        assertIn(found.confidence, 0.15, 0.3)
    }

    func test_shadowSpread_scannedAt300Dpi_isCutAtTheSpine() throws {
        let scan = TestPages.enlarged(TestPages.shadowSpread(), 3)
        let gutter = try XCTUnwrap(BookSplitter.findGutter(scan, dpi: 300))
        XCTAssertEqual(gutter.axis, .vertical)
        XCTAssertEqual(gutter.kind, .shadow)
        assertIn(Double(gutter.position), 3 * 572 - 15, 3 * 572 + 15)
        assertIn(gutter.fraction(width: scan.width, height: scan.height), 0.515, 0.525)
        // The same through CoreGraphics, as the app's pages hold their pixels.
        let cgScan = try XCTUnwrap(scan.makeCGImage())
        let fromCG = try XCTUnwrap(BookSplitter.findGutter(cgScan, dpi: 300))
        XCTAssertEqual(fromCG.axis, gutter.axis)
        XCTAssertEqual(fromCG.kind, gutter.kind)
        XCTAssertLessThanOrEqual(abs(fromCG.position - gutter.position), 1)
    }

    func test_marginSpread_withoutAShadow_findsTheMarginCentre() throws {
        let found = try XCTUnwrap(BookSplitter.findGutter(TestPages.marginSpread()))
        XCTAssertEqual(found.axis, .vertical)
        XCTAssertEqual(found.kind, .margin)
        // Lines end unevenly on the left page, so the blank run's middle may lie a little left of the spine.
        assertIn(found.center, 550 - spineTolerance, 550 + spineTolerance)
        // The run is at least the two inner margins long (1.2 in of 11).
        assertIn(found.confidence, 0.1, 0.16)
    }

    func test_blankFacingPage_theShadowStillSplits() throws {
        let found = try XCTUnwrap(BookSplitter.findGutter(TestPages.blankFacingSpread()))
        XCTAssertEqual(found.kind, .shadow)
        assertIn(found.center, 550 - spineTolerance, 550 + spineTolerance)
        // Without the shadow nothing tells where the blank page ends: the spread stays whole.
        XCTAssertNil(BookSplitter.findGutter(TestPages.spread(550, innerMargin: 40, outerMargin: 80, shadowDepth: 0,
                                                              shadowRadius: 0, seed: 0xB00C_0003, blankLeft: true)))
    }

    func test_singlePages_areNotSplit() {
        XCTAssertNil(BookSplitter.findGutter(TestPages.singlePageAcross()))
        XCTAssertNil(BookSplitter.findGutter(TestPages.twoColumnPage()))
        XCTAssertNil(BookSplitter.findGutter(TestPages.sectionGapPage()))
        XCTAssertNil(BookSplitter.findGutter(TestPages.textPage()))
        // Turned on its side, a single page is still a single page.
        XCTAssertNil(BookSplitter.findGutter(TestPages.quarterTurned(TestPages.singlePageAcross())))
    }

    func test_aCreaseAcrossAFoldedLetter_isNotSplit() {
        // The creases run along the lines of text: a fold, not a spine.
        XCTAssertNil(BookSplitter.findGutter(TestPages.foldedLetter()))
        XCTAssertNil(BookSplitter.findGutter(TestPages.quarterTurned(TestPages.foldedLetter())))
    }

    func test_theGuttersOwnDarkLine_doesNotHideIt() throws {
        // The spine with the pages' edges meeting in it: a thin dark line along the cut.
        let c = TestPages.Canvas(1100, 850, paper: 245, seed: 0xB00C_0001)
        c.p = TestPages.shadowSpread().pixels
        c.fillRect(571, 0, 2, 850, 60)
        let found = try XCTUnwrap(BookSplitter.findGutter(c.gray()))
        XCTAssertEqual(found.axis, .vertical)
        assertIn(found.center, 572 - spineTolerance, 572 + spineTolerance)
        // Judged with the band around it blanked out, the text runs across the spine, along a section gap.
        XCTAssertFalse(BookSplitter.runsAlongText(c.gray(), found))
        XCTAssertTrue(BookSplitter.runsAlongText(TestPages.sectionGapPage(),
                                                 GutterCandidate(axis: .horizontal, center: 550, confidence: 0.1, kind: .margin)))
    }

    func test_aTitlePageFacingText_isSplitOnlyByItsShadow() throws {
        // Without a shadow the blank run beside the centered title is not in the middle of the text: kept whole.
        XCTAssertNil(BookSplitter.findGutter(TestPages.titleFacingText(0)))
        let found = try XCTUnwrap(BookSplitter.findGutter(TestPages.titleFacingText(250)))
        XCTAssertEqual(found.kind, .shadow)
        assertIn(found.center, 550 - spineTolerance, 550 + spineTolerance)
    }

    func test_aPageBesideEmptyGlass_isNotSplitAtItsEdge() {
        XCTAssertNil(BookSplitter.findGutter(TestPages.pageBesideEmptyGlass()))
    }

    func test_nothingToRead_isNotSplit() {
        XCTAssertNil(BookSplitter.findGutter(TestPages.cleanBlank()))
        XCTAssertNil(BookSplitter.findGutter(TestPages.spread(550, innerMargin: 30, outerMargin: 80, shadowDepth: 250,
                                                              shadowRadius: 17, seed: 0xB00C_000E,
                                                              blankLeft: true, blankRight: true)))
    }

    func test_stackedSpread_findsTheHorizontalAxis() throws {
        // The book lying sideways: turned a quarter clockwise, the left page is on top.
        let found = try XCTUnwrap(BookSplitter.findGutter(TestPages.quarterTurned(TestPages.shadowSpread())))
        XCTAssertEqual(found.axis, .horizontal)
        XCTAssertEqual(found.kind, .shadow)
        assertIn(found.center, 572 - spineTolerance, 572 + spineTolerance)
        let margins = try XCTUnwrap(BookSplitter.findGutter(TestPages.quarterTurned(TestPages.marginSpread())))
        XCTAssertEqual(margins.axis, .horizontal)
        XCTAssertEqual(margins.kind, .margin)
        assertIn(margins.center, 550 - spineTolerance, 550 + spineTolerance)
    }

    func test_candidates_skipTheAxisAlongTheLinesOfText() {
        // The spread's lines run across, so only a vertical cut is looked for.
        for candidate in BookSplitter.candidates(TestPages.shadowSpread()) {
            XCTAssertEqual(candidate.axis, .vertical)
        }
        for candidate in BookSplitter.candidates(TestPages.quarterTurned(TestPages.shadowSpread())) {
            XCTAssertEqual(candidate.axis, .horizontal)
        }
    }

    func test_profile_measuresBrightnessAndInkOverTheMiddleBand() {
        let profile = BookSplitter.profile(TestPages.shadowSpread(), axis: .vertical)
        XCTAssertEqual(profile.length, 1100)
        // Paper in the outer margin, darker under the spine's shadow; text on the pages, none in the shadow.
        assertIn(profile.brightness[40], 240, 250)
        assertIn(profile.brightness[572], 170, 200)
        XCTAssertGreaterThan(profile.ink[300], 0.05)
        XCTAssertEqual(profile.ink[572], 0)
        XCTAssertEqual(BookSplitter.smoothWidth(100), 5)
        XCTAssertEqual(BookSplitter.smoothWidth(300), 15)
        XCTAssertEqual(BookSplitter.smoothWidth(40), 3)
    }

    // MARK: Cutting

    func test_halves_togetherAreExactlyTheScan() throws {
        let image = coordinates(101, 40)
        let halves = try XCTUnwrap(BookSplitter.halves(image, gutter: GutterResult(axis: .vertical, position: 37,
                                                                                   confidence: 0.2, kind: .shadow)))
        XCTAssertEqual(halves.first.width, 37)
        XCTAssertEqual(halves.second.width, 64)
        XCTAssertEqual(halves.first.height, 40)
        XCTAssertEqual(halves.second.height, 40)
        XCTAssertEqual(halves.first.width + halves.second.width, image.width)
        for y in 0..<40 {
            for x in 0..<101 {
                let half = x < 37 ? halves.first : halves.second
                let hx = x < 37 ? x : x - 37
                XCTAssertEqual(image.pixels[(y * 101 + x) * 4], half.pixels[(y * half.width + hx) * 4])
                XCTAssertEqual(image.pixels[(y * 101 + x) * 4 + 1], half.pixels[(y * half.width + hx) * 4 + 1])
            }
        }
        let stacked = try XCTUnwrap(BookSplitter.halves(coordinates(30, 90), gutter: GutterResult(axis: .horizontal, position: 50,
                                                                                                  confidence: 0.2, kind: .margin)))
        XCTAssertEqual([stacked.first.width, stacked.first.height, stacked.second.width, stacked.second.height], [30, 50, 30, 40])
        XCTAssertEqual(stacked.second.pixels[1], 50)
        // A cut at the edge still leaves a column on each side.
        let edge = try XCTUnwrap(BookSplitter.halves(image, gutter: GutterResult(axis: .vertical, position: 0, confidence: 1, kind: .manual)))
        XCTAssertEqual([edge.first.width, edge.second.width], [1, 100])
        // The same cut through CoreGraphics.
        let cgImage = try XCTUnwrap(image.makeCGImage())
        let cg = try XCTUnwrap(BookSplitter.halves(cgImage, gutter: GutterResult(axis: .vertical, position: 37,
                                                                                  confidence: 0.2, kind: .shadow)))
        XCTAssertEqual([cg.first.width, cg.second.width, cg.first.height], [37, 64, 40])
        XCTAssertEqual(RgbaImage(cgImage: cg.second)?.pixels[0], 37)
    }

    func test_split_leftToRight_orRightToLeft() {
        let image = coordinates(200, 60)
        let cut = GutterResult(axis: .vertical, position: 100, confidence: 0.3, kind: .shadow)
        let pages = BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 0, rightToLeft: false)
        XCTAssertEqual(origins(pages), [0, 100])
        for page in pages {
            XCTAssertEqual(page.width, 100)
            XCTAssertEqual(page.height, 60)
        }
        XCTAssertEqual(origins(BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 0, rightToLeft: true)), [100, 0])
    }

    func test_split_turnedBook_ordersThePagesByWhereTheyLieOnceTurned() {
        // Stacked: the top page (y 0..59) and the bottom one (60..119); green tells them apart.
        let image = coordinates(80, 120)
        let cut = GutterResult(axis: .horizontal, position: 60, confidence: 0.3, kind: .shadow)
        func tops(_ pages: [RgbaImage], _ turns: Int) -> [Int] {
            pages.map { Int($0.rotatedQuarterTurns(4 - turns).pixels[1]) }
        }
        // Turned a quarter clockwise the top page lies on the right: it comes second, first right to left.
        let clockwise = BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 1, rightToLeft: false)
        XCTAssertEqual(tops(clockwise, 1), [60, 0])
        for page in clockwise {
            XCTAssertEqual(page.width, 60)
            XCTAssertEqual(page.height, 80)
        }
        XCTAssertEqual(tops(BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 1, rightToLeft: true), 1), [0, 60])
        // Turned a quarter counterclockwise the top page lies on the left.
        XCTAssertEqual(tops(BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 3, rightToLeft: false), 3), [0, 60])
        XCTAssertEqual(tops(BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 3, rightToLeft: true), 3), [60, 0])
        // Not turned, top comes before bottom whichever way the book reads.
        XCTAssertEqual(tops(BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 0, rightToLeft: true), 0), [0, 60])
        // Upside down, the bottom page is now on top.
        XCTAssertEqual(tops(BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 2, rightToLeft: false), 2), [60, 0])
    }

    func test_split_upsideDownSpread_swapsLeftAndRight() {
        let image = coordinates(200, 60)
        let cut = GutterResult(axis: .vertical, position: 100, confidence: 0.3, kind: .shadow)
        let pages = BookSplitter.split(image, gutter: cut, rotationQuarterTurns: 2, rightToLeft: false)
        // Turned half way, each page's first pixel is its old last one: the right part (x 100..199) comes first.
        XCTAssertEqual(origins(pages), [199, 99])
    }

    func test_firstPartLeads_table() {
        let turns = [0, 1, 2, 3]
        // Vertical: the left part leads unturned (left to right) or turned half way (right to left).
        XCTAssertEqual(turns.map { BookSplitter.firstPartLeads(.vertical, quarterTurns: $0, rightToLeft: false) },
                       [true, true, false, false])
        XCTAssertEqual(turns.map { BookSplitter.firstPartLeads(.vertical, quarterTurns: $0, rightToLeft: true) },
                       [false, true, true, false])
        // Horizontal: the top part leads unturned, or turned counterclockwise (left to right), clockwise (right to left).
        XCTAssertEqual(turns.map { BookSplitter.firstPartLeads(.horizontal, quarterTurns: $0, rightToLeft: false) },
                       [true, false, false, true])
        XCTAssertEqual(turns.map { BookSplitter.firstPartLeads(.horizontal, quarterTurns: $0, rightToLeft: true) },
                       [true, true, false, false])
        // Turns beyond 0...3 count modulo 4.
        XCTAssertEqual(BookSplitter.firstPartLeads(.horizontal, quarterTurns: 3, rightToLeft: false),
                       BookSplitter.firstPartLeads(.horizontal, quarterTurns: -1, rightToLeft: false))
        XCTAssertEqual(BookSplitter.firstPartLeads(.vertical, quarterTurns: 2, rightToLeft: false),
                       BookSplitter.firstPartLeads(.vertical, quarterTurns: 6, rightToLeft: false))
    }

    func test_totalTurns_addWhatReadingTheTextAgreedOn() {
        let one = UprightTurn(quarterTurns: 1)
        let three = UprightTurn(quarterTurns: 3)
        XCTAssertEqual(BookSplitter.totalTurns(0, nil, nil), 0)
        XCTAssertEqual(BookSplitter.totalTurns(0, one, one), 1)
        // One page read and turned, the other unread (blank, a picture): the turn counts.
        XCTAssertEqual(BookSplitter.totalTurns(0, one, nil), 1)
        XCTAssertEqual(BookSplitter.totalTurns(0, nil, three), 3)
        // Pages turned different ways say nothing.
        XCTAssertEqual(BookSplitter.totalTurns(2, one, three), 2)
        // The book's own rotation adds up; a turn the user undid does not count.
        XCTAssertEqual(BookSplitter.totalTurns(3, one, one), 0)
        XCTAssertEqual(BookSplitter.totalTurns(3, UprightTurn(quarterTurns: 1, undone: true), nil), 3)
        XCTAssertEqual(BookSplitter.normalizedTurns(-3), 1)
        XCTAssertEqual(BookSplitter.normalizedTurns(6), 2)
    }

    func test_manual_placesTheCutAtAShareOfTheAxis_keptOffTheEdges() {
        let cut = BookSplitter.manual(.vertical, fraction: 0.52, width: 1000, height: 700)
        XCTAssertEqual(cut, GutterResult(axis: .vertical, position: 520, confidence: 1, kind: .manual))
        XCTAssertEqual(cut.fraction(width: 1000, height: 700), 0.52, accuracy: 1e-6)
        XCTAssertEqual(BookSplitter.manual(.horizontal, fraction: 0.5, width: 1000, height: 700).position, 350)
        XCTAssertEqual(BookSplitter.manual(.vertical, fraction: -0.5, width: 1000, height: 700).position, 1)
        XCTAssertEqual(BookSplitter.manual(.vertical, fraction: 1, width: 1000, height: 700).position, 999)
        XCTAssertEqual(BookSplitter.manual(.vertical, fraction: .nan, width: 1000, height: 700).position, 500)
    }

    func test_atScale_mapsTheAnalysisCentreBackToTheScan() {
        let candidate = GutterCandidate(axis: .vertical, center: 300.5, confidence: 0.2, kind: .shadow)
        // An analysis image a third the size of the scan.
        XCTAssertEqual(BookSplitter.atScale(candidate, width: 1800, height: 1200, scale: 1.0 / 3).position, 902)
        var far = candidate
        far.center = 700
        XCTAssertEqual(BookSplitter.atScale(far, width: 1800, height: 1200, scale: 1.0 / 3).position, 1799)
    }

    func test_options_comeFromTheSettings() {
        var s = ScanSettings()
        XCTAssertEqual(BookSplitOptions.of(s), BookSplitOptions(rotationQuarterTurns: 0, rightToLeft: false))
        s.taskOptions.bookRotationQuarterTurns = 7
        s.taskOptions.bookRightToLeft = true
        XCTAssertEqual(BookSplitOptions.of(s), BookSplitOptions(rotationQuarterTurns: 3, rightToLeft: true))
    }

    // MARK: What the strip and the status say

    func test_labels_numberTheSpreadsAndTheirPages() {
        let a = UUID(), b = UUID()
        let pages = [part(a, 0), part(a, 1), blankPage(), part(b, nil)]
        XCTAssertEqual((0..<pages.count).map { BookPages.label(pages, $0) },
                       ["1 \u{00B7} left", "1 \u{00B7} right", nil, "2 \u{00B7} not split"])
        // Pages moved apart keep their spread's number, in queue order, and each keeps its own side.
        let moved = [pages[1], pages[3], pages[0]]
        XCTAssertEqual((0..<moved.count).map { BookPages.label(moved, $0) },
                       ["1 \u{00B7} right", "2 \u{00B7} not split", "1 \u{00B7} left"])
        // The left page removed: the right page is still the right page.
        XCTAssertEqual(BookPages.label([pages[1]], 0), "1 \u{00B7} right")
        XCTAssertEqual(BookPages.help(pages, 3), "Spread 2, not split")
        XCTAssertEqual(BookPages.help(pages, 1), "Spread 1, right page")
        XCTAssertNil(BookPages.help(pages, 2))
        XCTAssertNil(BookPages.label(pages, 9))
        // The side recorded when the spread was cut wins over the part: a book scanned upside down.
        var first = part(a, 1)
        first.spread?.left = true
        var second = part(a, 0)
        second.spread?.left = false
        let upsideDown = [first, second]
        XCTAssertEqual((0..<upsideDown.count).map { BookPages.label(upsideDown, $0) },
                       ["1 \u{00B7} left", "1 \u{00B7} right"])
        XCTAssertEqual(BookPages.notSplitBadge, "Not split")
        XCTAssertEqual(BookPages.notWithTwoSidedReason, "Not with two-sided")
    }

    func test_labels_inOnePass_areTheLabelAndHelpOfEveryPage() {
        let a = UUID(), b = UUID()
        let pages = [part(a, 1), blankPage(), part(b, nil), part(a, 0)]
        let labels = BookPages.labels(pages)
        XCTAssertEqual(labels, [
            BookPageLabel(label: "1 \u{00B7} right", help: "Spread 1, right page"),
            nil,
            BookPageLabel(label: "2 \u{00B7} not split", help: "Spread 2, not split"),
            BookPageLabel(label: "1 \u{00B7} left", help: "Spread 1, left page"),
        ])
        XCTAssertEqual((0..<pages.count).map { BookPages.label(pages, $0) }, labels.map { $0?.label })
        XCTAssertEqual((0..<pages.count).map { BookPages.help(pages, $0) }, labels.map { $0?.help })
        XCTAssertTrue(BookPages.labels([]).isEmpty)
        // A long book: every spread numbered, each page with its side.
        var book: [ScannedPage] = []
        for _ in 0..<1000 {
            let id = UUID()
            book.append(part(id, 0))
            book.append(part(id, 1))
        }
        let bookLabels = BookPages.labels(book)
        XCTAssertEqual(bookLabels.first??.label, "1 \u{00B7} left")
        XCTAssertEqual(bookLabels.last??.label, "1000 \u{00B7} right")
    }

    func test_labels_keepTheSideEachPageWasCutWith() throws {
        // A left-to-right book: the left page leads.
        let spread = blankSpread()
        let cut = BookSplitter.manual(.vertical, fraction: 0.5, width: 20, height: 10)
        let ltr = try PageProcessor(steps: []).processSpread(spread, cut: cut, options: BookSplitOptions())
        XCTAssertEqual(ltr.map { $0.spread?.part }, [0, 1])
        XCTAssertEqual(BookPages.labels(ltr).map { $0?.label }, ["1 \u{00B7} left", "1 \u{00B7} right"])
        // A right-to-left book scanned next: the right page leads, and the pages of the first spread
        // keep their sides, as the setting applies to the spreads scanned from then on.
        let rtl = try PageProcessor(steps: [])
            .processSpread(blankSpread(), cut: cut, options: BookSplitOptions(rotationQuarterTurns: 0, rightToLeft: true))
        XCTAssertEqual(rtl.map { $0.spread?.part }, [1, 0])
        let queue = ltr + rtl
        XCTAssertEqual(BookPages.labels(queue).map { $0?.label },
                       ["1 \u{00B7} left", "1 \u{00B7} right", "2 \u{00B7} right", "2 \u{00B7} left"])
        XCTAssertEqual(BookPages.help(queue, 2), "Spread 2, right page")
        // Upside down on the glass: the part before the cut lies on the right once turned.
        let turned = try PageProcessor(steps: [])
            .processSpread(spread, cut: cut, options: BookSplitOptions(rotationQuarterTurns: 2))
        XCTAssertEqual(turned.map { $0.spread?.part }, [1, 0])
        XCTAssertEqual(BookPages.labels(turned).map { $0?.label }, ["1 \u{00B7} left", "1 \u{00B7} right"])
        // A page moved in front of its partner, or left alone, keeps its side.
        XCTAssertEqual(BookPages.labels([ltr[1], ltr[0]]).map { $0?.label }, ["1 \u{00B7} right", "1 \u{00B7} left"])
        XCTAssertEqual(BookPages.labels([ltr[1]]).map { $0?.label }, ["1 \u{00B7} right"])
    }

    func test_replacementPages_keepWhatTheUserDecided() {
        let id = UUID()
        // Split again: each new page takes the break, name and keep or skip of the queued page of its part.
        let left = part(id, 0).withInclusion(.skip)
        let right = part(id, 1).withDocumentBreak(.split).withDocumentLabel("Chapter 2")
        let fresh = [part(id, 0), part(id, 1)]
        let both = BookPages.replacementPages([left, right], fresh: fresh)
        XCTAssertEqual(both.map(\.id), fresh.map(\.id))
        XCTAssertEqual(both[0].inclusion, .skip)
        XCTAssertEqual(both[0].documentBreak, .automatic)
        XCTAssertNil(both[0].documentLabel)
        XCTAssertEqual(both[1].inclusion, .automatic)
        XCTAssertEqual(both[1].documentBreak, .split)
        XCTAssertEqual(both[1].documentLabel, "Chapter 2")
        // In the new order (right to left, the right page first) each still takes its own part's.
        let reversed = BookPages.replacementPages([left, right], fresh: [fresh[1], fresh[0]])
        XCTAssertEqual(reversed.map(\.id), [fresh[1].id, fresh[0].id])
        XCTAssertEqual(reversed[0].documentBreak, .split)
        XCTAssertEqual(reversed[1].inclusion, .skip)
        // A part the user removed from the queue stays out.
        let one = BookPages.replacementPages([right], fresh: fresh)
        XCTAssertEqual(one.map(\.id), [fresh[1].id])
        XCTAssertEqual(one.first?.documentBreak, .split)
        XCTAssertEqual(one.first?.documentLabel, "Chapter 2")
        // Joined: the first queued page's break, the first name among them, the keep or skip they share.
        let whole = part(id, nil)
        let joined = BookPages.replacementPages([left.withDocumentBreak(.split), right], fresh: [whole])
        XCTAssertEqual(joined.map(\.id), [whole.id])
        XCTAssertEqual(joined.first?.documentBreak, .split)
        XCTAssertEqual(joined.first?.documentLabel, "Chapter 2")
        XCTAssertEqual(joined.first?.inclusion, .automatic)
        XCTAssertEqual(BookPages.replacementPages([left, right.withInclusion(.skip)], fresh: [whole]).map(\.inclusion), [.skip])
        // A whole spread split: the first page takes its break and name, both its keep or skip.
        let kept = whole.withDocumentBreak(.split).withDocumentLabel("Atlas").withInclusion(.keep)
        let split = BookPages.replacementPages([kept], fresh: fresh)
        XCTAssertEqual(split.map(\.id), fresh.map(\.id))
        XCTAssertEqual(split.map(\.documentBreak), [.split, .automatic])
        XCTAssertEqual(split.map(\.documentLabel), ["Atlas", nil])
        XCTAssertEqual(split.map(\.inclusion), [.keep, .keep])
        // Nothing queued: the new pages as they are.
        XCTAssertEqual(BookPages.replacementPages([], fresh: fresh).map(\.id), fresh.map(\.id))
    }

    func test_actions_splitOrJoinASpread() {
        let id = UUID()
        XCTAssertEqual(BookPages.splitActionLabel(part(id, 1)), "Change the split\u{2026}")
        XCTAssertEqual(BookPages.joinActionLabel(part(id, 1)), "Join the two pages")
        XCTAssertEqual(BookPages.splitActionLabel(part(id, nil)), "Split this spread\u{2026}")
        XCTAssertNil(BookPages.joinActionLabel(part(id, nil)))
        XCTAssertNil(BookPages.splitActionLabel(blankPage()))
        XCTAssertNil(BookPages.joinActionLabel(blankPage()))
        XCTAssertEqual(BookPages.splitNote(spreadNumber: 3, split: true), "Spread 3 is split into two pages.")
        XCTAssertEqual(BookPages.splitNote(spreadNumber: 3, split: false), "Spread 3 is one page again.")
    }

    func test_scanNote_countsTheSpreadsSplitAndKeptWhole() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(BookPages.scanNote([blankPage()]), "")
        XCTAssertEqual(BookPages.scanNote([part(a, 0), part(a, 1)]), " 1 spread split into pages.")
        XCTAssertEqual(BookPages.scanNote([part(a, 0), part(a, 1), part(b, 1), part(b, 0)]), " 2 spreads split into pages.")
        XCTAssertEqual(BookPages.scanNote([part(c, nil)]),
                       " The spine of 1 spread was not found: it was added as one page (Split\u{2026} on it splits it).")
        XCTAssertEqual(BookPages.scanNote([part(a, 0), part(a, 1), part(b, nil), part(c, nil)]),
                       " 1 spread split into pages. The spine of 2 spreads was not found: they were added as one page each (Split\u{2026} on one splits it).")
    }

    func test_rotation_andHint() {
        XCTAssertEqual(BookPages.rotationChoices.map { BookPages.rotationLabel($0) },
                       ["As scanned", "90\u{00B0} clockwise", "180\u{00B0}", "90\u{00B0} counterclockwise"])
        XCTAssertEqual(BookPages.rotationLabel(5), "90\u{00B0} clockwise")
        var book = TaskCatalog.apply(.book, to: ScanSettings())
        XCTAssertEqual(BookPages.hint(book), "Each book scan becomes two pages, cut at the spine.")
        book.document.splitFacingPages = false
        XCTAssertEqual(BookPages.hint(book), "Each book scan becomes two pages, cut at the spine.")
        book.documentMultiPage = false
        XCTAssertTrue(BookPages.hint(book).hasPrefix("Only for pages collected"))
        XCTAssertTrue(BookPages.hint(TaskCatalog.apply(.copy, to: ScanSettings())).hasPrefix("Copies print"))
        XCTAssertTrue(BookPages.hint(TaskCatalog.apply(.receipt, to: ScanSettings())).hasPrefix("Receipts are"))
        // Two-sided scans keep their pages as scanned.
        var feeder = TaskCatalog.apply(.book, to: ScanSettings())
        feeder.source = .documentFeeder
        feeder.duplex = .both
        XCTAssertFalse(BookPages.scansOneSide(feeder))
        XCTAssertEqual(BookPages.hint(feeder), "Only for one side of each sheet: pages scanned on both sides are kept as scanned.")
        feeder.duplex = .manual
        XCTAssertTrue(BookPages.hint(feeder).hasPrefix("Only for one side of each sheet"))
        feeder.duplex = .off
        XCTAssertTrue(BookPages.scansOneSide(feeder))
        XCTAssertTrue(BookPages.hint(feeder).hasPrefix("Each book scan becomes two pages"))
    }
}
