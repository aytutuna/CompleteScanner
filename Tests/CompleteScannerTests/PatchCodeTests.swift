import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/LazyScan.Core.Tests/PatchCodeTests.cs: the same pages, the same expectations.

final class PatchCodeTests: XCTestCase {
    private enum Expected {
        static let patchT: UInt32 = 0x1C4A_46D4
        static let patch2Vertical: UInt32 = 0x405A_20EB
        static let patchTPlus2Point5: UInt32 = 0xC526_D510
        static let ruledTable: UInt32 = 0xDC4E_ED7D
        static let sheetLetter100: UInt32 = 0xDA73_C7FA
    }

    func test_codes_theirBarsAndLabels() {
        XCTAssertEqual(PatchCode.allCases.map(\.label), ["Patch 1", "Patch 2", "Patch 3", "Patch 4", "Patch 6", "Patch T"])
        XCTAssertEqual(PatchCode.allCases.map { $0.bars.map { $0 ? "1" : "0" }.joined() },
                       ["1100", "1001", "1010", "0110", "0011", "0101"])
        for code in PatchCode.allCases {
            let bars = code.bars
            XCTAssertEqual(PatchCode.fromBars(bars[0], bars[1], bars[2], bars[3]), code)
        }
        XCTAssertNil(PatchCode.fromBars(true, true, true, false))
        XCTAssertNil(PatchCode.fromBars(false, false, false, false))
        // Read from the other end: 1 and 6, 3 and T swap; 2 and 4 read the same.
        XCTAssertEqual(PatchCode.allCases.map(\.reversed), [.patch6, .patch2, .patchT, .patch4, .patch1, .patch3])
    }

    func test_fixtures_areTheSameBytesOnBothPlatforms() {
        let pages = [
            TestPages.patchPage(.patchT, vertical: false, TestPages.straight),
            TestPages.patchPage(.patch2, vertical: true, TestPages.straight),
            TestPages.patchPage(.patchT, vertical: false, TestPages.plus2Point5),
            TestPages.ruledTable(),
            PatchCodeDetector.renderSheet(.patchT, widthInches: 8.5, heightInches: 11, dpi: 100),
        ]
        XCTAssertEqual(pages.map(TestPages.checksum),
                       [Expected.patchT, Expected.patch2Vertical, Expected.patchTPlus2Point5, Expected.ruledTable,
                        Expected.sheetLetter100])
    }

    func test_everyCode_acrossAndDownThePage() throws {
        for code in PatchCode.allCases {
            let across = try XCTUnwrap(PatchCodeDetector.detect(TestPages.patchPage(code, vertical: false, TestPages.straight)))
            XCTAssertEqual(across.code, code)
            XCTAssertFalse(across.verticalBars)
            // The bars: x 275 ..< 575; y from 200, 80 px deep (2 wide, 2 narrow, 3 gaps).
            XCTAssertEqual(across.bounds, CGRect(x: 275, y: 200, width: 300, height: 80))
            XCTAssertEqual(across.length, 300)

            let down = try XCTUnwrap(PatchCodeDetector.detect(TestPages.patchPage(code, vertical: true, TestPages.straight)))
            XCTAssertEqual(down.code, code)
            XCTAssertTrue(down.verticalBars)
            XCTAssertEqual(down.bounds, CGRect(x: 200, y: 400, width: 80, height: 300))
        }
    }

    func test_aSlantOfAFewDegrees_isRead() throws {
        for turn in [TestPages.plus2Point5, TestPages.minus2Point5, TestPages.plus3, TestPages.minus3] {
            for code in [PatchCode.patchT, .patch2, .patch1] {
                for vertical in [false, true] {
                    let hit = try XCTUnwrap(PatchCodeDetector.detect(TestPages.patchPage(code, vertical: vertical, turn)),
                                            "\(code) vertical \(vertical) at \(turn.degrees)°")
                    XCTAssertEqual(hit.code, code)
                    XCTAssertEqual(hit.verticalBars, vertical)
                    XCTAssertTrue((280...300).contains(hit.length), "\(hit.length)")
                }
            }
        }
    }

    func test_textTablesAndPagesWithoutACode_areNotRead() {
        XCTAssertNil(PatchCodeDetector.detect(TestPages.textPage()))
        XCTAssertNil(PatchCodeDetector.detect(TestPages.turned(TestPages.textPage(), TestPages.plus3, fill: 245)))
        XCTAssertNil(PatchCodeDetector.detect(TestPages.ruledTable()))
        XCTAssertNil(PatchCodeDetector.detect(TestPages.quarterTurned(TestPages.ruledTable())))
        for (name, page) in TestPages.all() {
            XCTAssertNil(PatchCodeDetector.detect(page), name)
        }
        XCTAssertNil(PatchCodeDetector.detect(TestPages.sheetOnBackdrop(TestPages.plus2, backdrop: 245, paper: 250,
                                                                        shadow: 2, seed: 0x5EE7_0001)))
    }

    func test_barsShorterThanAnInchAndAHalf_areNotACode() {
        XCTAssertNil(PatchCodeDetector.detect(TestPages.patchPage(.patchT, vertical: false, TestPages.straight, length: 140)))
        XCTAssertNotNil(PatchCodeDetector.detect(TestPages.patchPage(.patchT, vertical: false, TestPages.straight, length: 160)))
    }

    func test_theSeparatorSheet_readsItsCode_eitherWayRound_atAnyResolution() throws {
        for code in PatchCode.allCases {
            let sheet = PatchCodeDetector.renderSheet(code, widthInches: 8.5, heightInches: 11, dpi: 100)
            XCTAssertEqual(sheet.width, 850)
            XCTAssertEqual(sheet.height, 1100)
            let hit = try XCTUnwrap(PatchCodeDetector.detect(sheet))
            XCTAssertEqual(hit.code, code)
            XCTAssertFalse(hit.verticalBars)
            // 6 in bars, centred, 1 in from the top.
            let depth = code.bars.reduce(0) { $0 + ($1 ? 20 : 8) } + 3 * 8
            XCTAssertEqual(hit.bounds, CGRect(x: 125, y: 100, width: 600, height: depth))
            // Fed the other way round, the copy near the other edge reads the same code.
            XCTAssertEqual(PatchCodeDetector.detect(TestPages.halfTurned(sheet))?.code, code)
            // Fed sideways, its bars run down the page.
            XCTAssertEqual(PatchCodeDetector.detect(TestPages.quarterTurned(sheet))?.verticalBars, true)
        }
        // A4 at 300 dpi, read at the analysis resolution.
        let a4 = PatchCodeDetector.renderSheet(.patchT, widthInches: 8.27, heightInches: 11.69, dpi: 300)
        XCTAssertEqual(a4.width, 2481)
        XCTAssertEqual(a4.height, 3507)
        XCTAssertEqual(PatchCodeDetector.detect(a4)?.code, .patchT)
        XCTAssertEqual(PatchCodeDetector.detect(a4.toRgba(), dpi: 300)?.code, .patchT)
        // Through CoreGraphics, as the page processor reads a scan.
        let image = try XCTUnwrap(a4.toRgba().makeCGImage())
        XCTAssertEqual(PatchCodeDetector.detect(image, dpi: 300)?.code, .patchT)
    }

    func test_theSeparatorSheetPDF_isPatchT_onThePaperUsualWhereTheUserLives() {
        XCTAssertEqual(SeparatorSheet.code, .patchT)
        XCTAssertEqual(SeparatorSheet.dpi, 300)
        XCTAssertEqual(SeparatorSheet.paper(regionCode: "US"), .letter)
        XCTAssertEqual(SeparatorSheet.paper(regionCode: "ca"), .letter)
        XCTAssertEqual(SeparatorSheet.paper(regionCode: "DE"), .a4)
        XCTAssertEqual(SeparatorSheet.paper(regionCode: nil), .a4)
        XCTAssertEqual(SeparatorSheet.fileBaseName(.letter), "Separator sheet (Patch T, Letter)")
        XCTAssertEqual(SeparatorSheet.fileBaseName(.a4), "Separator sheet (Patch T, A4)")
        XCTAssertEqual(SeparatorSheet.savedMessage("Separator sheet (Patch T, A4).pdf"),
                       "Saved the separator sheet: Separator sheet (Patch T, A4).pdf. Print it at actual size (100%), as many as you need, and put one in front of each document after the first.")
    }

    func test_theSeparatorSheet_hasTheStandardBarWidths() {
        let sheet = PatchCodeDetector.renderSheet(.patchT, widthInches: 8.5, heightInches: 11, dpi: 300)
        // Down the middle column from the top: white to 1 in, then narrow 24, gap 24, wide 60,
        // gap 24, narrow 24, gap 24, wide 60 (0.08 and 0.20 in at 300 dpi).
        let x = sheet.width / 2
        var runs: [(ink: Bool, length: Int)] = []
        for y in 0..<600 {
            let ink = sheet[x, y] == 0
            if let last = runs.last, last.ink == ink {
                runs[runs.count - 1].length += 1
            } else {
                runs.append((ink, 1))
            }
        }
        XCTAssertEqual(runs.map(\.ink), [false, true, false, true, false, true, false, true, false])
        XCTAssertEqual(runs.map(\.length), [300, 24, 24, 60, 24, 24, 24, 60, 60])
        // The words lie between the two codes, clear of their quiet zones (0.3 in).
        func rowHasInk(_ y: Int) -> Bool { (0..<sheet.width).contains { sheet[$0, y] == 0 } }
        XCTAssertFalse((540..<630).contains(where: rowHasInk))
        XCTAssertFalse((2670..<2760).contains(where: rowHasInk))
        XCTAssertTrue((1100..<2200).contains(where: rowHasInk))
    }

    func test_aSeparatorSheetScannedAsADocumentPage_isFound() throws {
        // The page processor's step: the patch code is recorded on the page; other pages get none.
        let sheet = try XCTUnwrap(PatchCodeDetector.renderSheet(.patchT, widthInches: 8.5, heightInches: 11, dpi: 200)
            .toRgba().makeCGImage())
        let page = SeparatorStep().apply(ScannedPage(image: sheet, dpi: 200, colorMode: .color))
        XCTAssertEqual(page.patch, .patchT)
        let text = try XCTUnwrap(TestPages.enlarged(TestPages.textPage(), 2).makeCGImage())
        XCTAssertNil(SeparatorStep().apply(ScannedPage(image: text, dpi: 200, colorMode: .color)).patch)
    }
}
