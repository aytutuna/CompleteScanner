import XCTest
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/InspectorSectionsTests.cs: the settings column's sections
// and the summaries their collapsed headers show.

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
        XCTAssertEqual(InspectorSections.openedBy(.archive), InspectorSections.archive)
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

    func test_shown_hidesWhatCannotApply_eachSectionOnce() {
        var s: ScanSettings = ScanSettings()
        XCTAssertEqual(InspectorSections.shown(s), ["scanner", "output", "adjustments", "pages", "split", "archive", "more"])
        XCTAssertEqual(InspectorSections.title(InspectorSections.output, for: s), "Output")
        XCTAssertTrue(InspectorSections.textApplies(s))

        s.format = .word
        XCTAssertEqual(InspectorSections.shown(s), ["scanner", "output", "adjustments", "pages", "split", "more"])
        XCTAssertFalse(InspectorSections.writesPDF(s))
        XCTAssertFalse(InspectorSections.textApplies(s))

        // A queue of image pages is saved as a PDF.
        s.format = .jpeg
        XCTAssertTrue(InspectorSections.writesPDF(s))
        s.documentMultiPage = false
        XCTAssertFalse(InspectorSections.writesPDF(s))

        var photos: ScanSettings = ScanSettings()
        photos.intent = .photo
        XCTAssertEqual(InspectorSections.shown(photos), ["scanner", "output", "adjustments", "more"])
        XCTAssertEqual(InspectorSections.title(InspectorSections.output, for: photos), "Photos")
        XCTAssertEqual(InspectorSections.shownFormat(photos), .jpeg)

        var receipts: ScanSettings = TaskCatalog.apply(.receipt, to: ScanSettings())
        receipts.format = .word
        XCTAssertEqual(InspectorSections.shown(receipts), ["task", "scanner", "output", "adjustments", "archive", "more"])
        XCTAssertEqual(InspectorSections.title(InspectorSections.task, for: receipts), "Receipts")
        XCTAssertEqual(InspectorSections.shownFormat(receipts), .pdf)
        XCTAssertTrue(InspectorSections.textApplies(receipts))
        receipts.format = .png
        XCTAssertFalse(InspectorSections.shown(receipts).contains(InspectorSections.archive))

        var copy: ScanSettings = TaskCatalog.apply(.copy, to: ScanSettings())
        copy.taskOptions.copyAlsoSavePdf = false
        XCTAssertEqual(InspectorSections.shown(copy), ["task", "scanner", "output", "adjustments", "more"])
        XCTAssertEqual(InspectorSections.title(InspectorSections.task, for: copy), "Photocopy")
        copy.taskOptions.copyAlsoSavePdf = true
        XCTAssertTrue(InspectorSections.shown(copy).contains(InspectorSections.archive))
        XCTAssertFalse(InspectorSections.textApplies(copy))

        // The ID card never goes through the queue and is saved from its review as a PDF or an image.
        var idCard: ScanSettings = TaskCatalog.apply(.idCard, to: ScanSettings())
        idCard.format = .word
        XCTAssertEqual(InspectorSections.shown(idCard), ["scanner", "output", "adjustments", "archive", "more"])
        XCTAssertEqual(InspectorSections.shownFormat(idCard), .pdf)
        XCTAssertTrue(InspectorSections.savesPageFormat(idCard))
        XCTAssertTrue(InspectorSections.savesPageFormat(receipts))
        XCTAssertFalse(InspectorSections.savesPageFormat(ScanSettings()))
        XCTAssertFalse(InspectorSections.textApplies(idCard))
        idCard.format = .png
        XCTAssertFalse(InspectorSections.shown(idCard).contains(InspectorSections.archive))

        XCTAssertNil(InspectorSections.taskTitle(ScanSettings()))
        XCTAssertEqual(InspectorSections.title(InspectorSections.task, for: ScanSettings()), "Task")
        let all: [ScanSettings] = [s, photos, receipts, copy, idCard]
        for settings in all {
            let shown: [String] = InspectorSections.shown(settings)
            XCTAssertEqual(Set(shown).count, shown.count)
            var inOrder: [String] = []
            for id in InspectorSections.all where shown.contains(id) {
                inOrder.append(id)
            }
            XCTAssertEqual(shown, inOrder)
        }
    }

    func test_headers_forASetting_haveTheirSummaryDotAndName() {
        var s: ScanSettings = ScanSettings()
        XCTAssertEqual(InspectorSections.summary(InspectorSections.scanner, for: s), "Flatbed \u{00B7} 300 dpi \u{00B7} Color")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.scanner, for: s))
        XCTAssertEqual(InspectorSections.accessibleName(InspectorSections.scanner, for: s),
                       "Scanner, Flatbed \u{00B7} 300 dpi \u{00B7} Color")
        XCTAssertEqual(InspectorSections.summary(InspectorSections.output, for: s), "PDF \u{00B7} Standard")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.output, for: s))
        XCTAssertEqual(InspectorSections.summary(InspectorSections.pages, for: s), "")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.pages, for: s))
        XCTAssertEqual(InspectorSections.accessibleName(InspectorSections.pages, for: s), "Pages")
        XCTAssertEqual(InspectorSections.summary(InspectorSections.split, for: s), "Off")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.split, for: s))
        XCTAssertEqual(InspectorSections.summary(InspectorSections.archive, for: s), "Off")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.archive, for: s))
        XCTAssertEqual(InspectorSections.summary(InspectorSections.more, for: s), "")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.more, for: s))
        XCTAssertEqual(InspectorSections.accessibleName(InspectorSections.more, for: s), "More options")
        XCTAssertEqual(InspectorSections.summary(InspectorSections.task, for: s), "")
        XCTAssertFalse(InspectorSections.changed(InspectorSections.task, for: s))

        s.resolution = 600
        s.output.alsoSaveText = true
        s.output.protect = true
        s.document.splitMode = .blankSheet
        s.document.autoCrop = true
        s.document.autoRotate = true
        XCTAssertEqual(InspectorSections.summary(InspectorSections.pages, for: s), "Crop \u{00B7} Upright")
        XCTAssertTrue(InspectorSections.changed(InspectorSections.pages, for: s))
        XCTAssertEqual(InspectorSections.accessibleName(InspectorSections.pages, for: s), "Pages, 2 options on")
        XCTAssertTrue(InspectorSections.changed(InspectorSections.scanner, for: s))
        XCTAssertEqual(InspectorSections.summary(InspectorSections.more, for: s), ".txt")
        XCTAssertTrue(InspectorSections.changed(InspectorSections.more, for: s))
        XCTAssertEqual(InspectorSections.accessibleName(InspectorSections.archive, for: s), "Archive & password, Password on")
        XCTAssertTrue(InspectorSections.changed(InspectorSections.split, for: s))
        s.format = .word
        XCTAssertEqual(InspectorSections.summary(InspectorSections.more, for: s), "")
        XCTAssertEqual(InspectorSections.summary(InspectorSections.output, for: s), "Word")
        XCTAssertTrue(InspectorSections.changed(InspectorSections.output, for: s))

        var photos: ScanSettings = ScanSettings()
        photos.intent = .photo
        XCTAssertEqual(InspectorSections.accessibleName(InspectorSections.output, for: photos), "Photos, JPEG")
    }
}
