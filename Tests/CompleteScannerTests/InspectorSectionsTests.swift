import XCTest
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/InspectorSectionsTests.cs: the settings column's sections
// and the summaries their collapsed headers show. Windows-only case: its Archive document task opens
// Archive & password (the Mac has no such task until its PDF writer port).

final class InspectorSectionsTests: XCTestCase {

    func test_onlyTheTaskScannerAndOutput_startOpen() {
        XCTAssertEqual(InspectorSections.all, ["task", "scanner", "output", "adjustments", "pages", "split", "archive", "more"])
        XCTAssertTrue(InspectorSections.openByDefault(InspectorSections.task))
        XCTAssertTrue(InspectorSections.openByDefault(InspectorSections.scanner))
        XCTAssertTrue(InspectorSections.openByDefault(InspectorSections.output))
        let collapsed: [String] = [InspectorSections.adjustments, InspectorSections.pages, InspectorSections.split,
                                   InspectorSections.archive, InspectorSections.more]
        for id in collapsed {
            XCTAssertFalse(InspectorSections.openByDefault(id), id)
        }
        XCTAssertEqual(InspectorSections.openedBy(.photoRestore), InspectorSections.adjustments)
        XCTAssertEqual(InspectorSections.openedBy(.book), InspectorSections.pages)
        XCTAssertEqual(InspectorSections.openedBy(.batch), InspectorSections.split)
        XCTAssertNil(InspectorSections.openedBy(.document))
    }

    func test_titles_areShort() {
        XCTAssertEqual(InspectorSections.all.map { InspectorSections.title($0) },
                       ["Task", "Scanner", "Output", "Adjustments", "Pages", "Split into documents", "Archive & password",
                        "More options"])
        for id in InspectorSections.all {
            XCTAssertTrue((1...3).contains(StatusLine.words(InspectorSections.title(id))), id)
        }
    }

    func test_summaries_ofTheDefaults_sayLittle_andShowNoChange() {
        let s = ScanSettings()
        XCTAssertEqual(InspectorSections.scannerSummary(s), "Flatbed \u{00B7} 300 dpi \u{00B7} Color")
        XCTAssertFalse(InspectorSections.scannerChanged(s))
        XCTAssertEqual(InspectorSections.outputSummary(s, shownFormat: .pdf), "PDF \u{00B7} Standard")
        XCTAssertFalse(InspectorSections.outputChanged(s, shownFormat: .pdf))
        XCTAssertEqual(InspectorSections.adjustmentsSummary(s.adjustments), "")
        XCTAssertEqual(InspectorSections.pagesSummary(s.document), "")
        XCTAssertEqual(InspectorSections.splitSummary(s.document), "Off")
        XCTAssertEqual(InspectorSections.archiveSummary(s.output), "Off")
        XCTAssertEqual(InspectorSections.moreSummary(s.output, textShown: true), "")
        XCTAssertEqual(InspectorSections.pagesHeaderName(s.document), "Pages")
        XCTAssertEqual(InspectorSections.headerName("Scanner", summary: InspectorSections.scannerSummary(s)),
                       "Scanner, Flatbed \u{00B7} 300 dpi \u{00B7} Color")
        XCTAssertEqual(InspectorSections.headerName("More options", summary: ""), "More options")
    }

    func test_summaries_sayWhatIsOn() {
        var s = ScanSettings()
        s.source = .documentFeeder
        s.duplex = .both
        s.colorMode = .grayscale
        s.resolution = 200
        s.format = .word
        XCTAssertEqual(InspectorSections.scannerSummary(s), "Feeder \u{00B7} both sides \u{00B7} 200 dpi \u{00B7} Gray")
        XCTAssertTrue(InspectorSections.scannerChanged(s))
        XCTAssertEqual(InspectorSections.outputSummary(s, shownFormat: .word), "Word")
        XCTAssertTrue(InspectorSections.outputChanged(s, shownFormat: .word))
        var photo = ScanSettings()
        photo.intent = .photo
        XCTAssertEqual(InspectorSections.outputSummary(photo, shownFormat: .jpeg), "JPEG")
        // Photos at their defaults save JPEG: nothing changed; another image format is a change.
        XCTAssertFalse(InspectorSections.outputChanged(photo, shownFormat: .jpeg))
        XCTAssertTrue(InspectorSections.outputChanged(photo, shownFormat: .png))
        // A PDF size other than the default is a change only while a PDF is shown.
        var compact = ScanSettings()
        compact.output.pdfSize = .compact
        XCTAssertTrue(InspectorSections.outputChanged(compact, shownFormat: .pdf))
        compact.intent = .photo
        XCTAssertFalse(InspectorSections.outputChanged(compact, shownFormat: .jpeg))
        XCTAssertEqual(InspectorSections.outputSummary(s, shownFormat: .text), "Text")

        s.adjustments.autoEnhance = true
        XCTAssertEqual(InspectorSections.adjustmentsSummary(s.adjustments), "Auto")
        s.adjustments.brightness = 0.2
        XCTAssertEqual(InspectorSections.adjustmentsSummary(s.adjustments), "Edited")

        s.document.removeBlankPages = true
        s.document.autoRotate = true
        XCTAssertEqual(InspectorSections.pagesSummary(s.document), "Skip blank \u{00B7} Upright")
        s.document.splitFacingPages = true
        XCTAssertEqual(InspectorSections.pagesSummary(s.document), "Skip blank \u{00B7} Upright +1")
        XCTAssertEqual(InspectorSections.pagesOn(s.document), 3)
        XCTAssertEqual(InspectorSections.pagesHeaderName(s.document), "Pages, 3 options on")
        s.document.removeBlankPages = false
        s.document.splitFacingPages = false
        XCTAssertEqual(InspectorSections.pagesHeaderName(s.document), "Pages, 1 option on")

        s.document.splitMode = .sheetCount
        s.document.splitSheetCount = 3
        XCTAssertEqual(InspectorSections.splitSummary(s.document), "Every 3 sheets")
        s.document.splitSheetCount = 1
        XCTAssertEqual(InspectorSections.splitSummary(s.document), "Every sheet")
        s.document.splitMode = .barcode
        XCTAssertEqual(InspectorSections.splitSummary(s.document), "QR codes")
        s.document.splitMode = .separatorSheet
        XCTAssertEqual(InspectorSections.splitSummary(s.document), "Separator sheets")

        s.output.archival = true
        XCTAssertEqual(InspectorSections.archiveSummary(s.output), "PDF/A")
        s.output.protect = true
        XCTAssertEqual(InspectorSections.archiveSummary(s.output), "Password on")

        s.output.afterSave = .open
        s.output.alsoSaveText = true
        XCTAssertEqual(InspectorSections.moreSummary(s.output, textShown: true), "Open after saving \u{00B7} .txt")
        XCTAssertEqual(InspectorSections.moreSummary(s.output, textShown: false), "Open after saving")
        s.output.afterSave = .share
        XCTAssertEqual(InspectorSections.moreSummary(s.output, textShown: true), "Share after saving \u{00B7} .txt")
    }
}
