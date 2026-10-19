import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/PageProcessorTests.cs: the clean-up stage, which
// pages are saved, and the page facts every rebuild keeps.

private let blankRgba = TestPages.enlarged(TestPages.noisyBlank(), 1)
private let textRgba = TestPages.enlarged(TestPages.oneTextLine(), 1)
private let blankImage: CGImage = blankRgba.makeCGImage()!
private let textImage: CGImage = textRgba.makeCGImage()!

private func page(_ image: CGImage) -> ScannedPage {
    ScannedPage(image: image, dpi: 100, colorMode: .color)
}

private func checked(_ blank: Bool, _ inclusion: PageInclusion = .automatic) -> ScannedPage {
    page(blankImage)
        .withBlank(BlankPageResult(inkCoverage: blank ? 0.00005 : 0.002, inkComponents: blank ? 1 : 40,
                                   hasLargeDarkArea: false, isBlank: blank))
        .withInclusion(inclusion)
}

private func options(_ remove: Bool, _ sensitivity: BlankSensitivity = .medium) -> DocumentOptions {
    var options = DocumentOptions()
    options.removeBlankPages = remove
    options.blankSensitivity = sensitivity
    return options
}

private func solid(_ width: Int, _ height: Int, _ value: UInt8) -> CGImage {
    RgbaImage.filled(width: width, height: height, r: value, g: value, b: value).makeCGImage()!
}

/// A step that records the pages it saw and turns each a quarter.
private final class RecordingStep: PageStep {
    let name: String
    private let log: (String) -> Void

    init(_ name: String, log: @escaping (String) -> Void) {
        self.name = name
        self.log = log
    }

    func apply(_ page: ScannedPage) -> ScannedPage {
        log("\(name):\(page.id)")
        return page.withImage(ImagePipeline.rotate(page.image, quarterTurns: 1))
    }
}

/// A step that prints a bar across the page.
private struct BarStep: PageStep {
    var name: String { "bar" }

    func apply(_ page: ScannedPage) -> ScannedPage {
        guard var image = RgbaImage(cgImage: page.image) else { return page }
        for y in 500..<520 {
            for x in 100..<700 {
                let i = (y * image.width + x) * 4
                image.pixels[i] = 0
                image.pixels[i + 1] = 0
                image.pixels[i + 2] = 0
            }
        }
        return page.withImage(image.makeCGImage()!)
    }
}

final class PageProcessorTests: XCTestCase {

    // MARK: The steps a scan gets

    func test_forScan_documentQueue_checksBlankPagesWhetherOrNotTheyAreSkipped() throws {
        for remove in [false, true] {
            var s = ScanSettings()
            s.document.removeBlankPages = remove
            s.document.blankSensitivity = .high
            let processor = PageProcessor.forScan(s)
            XCTAssertEqual(processor.steps.map(\.name), ["blank"])
            let step = try XCTUnwrap(processor.steps[0] as? BlankDetectionStep)
            XCTAssertEqual(step.options.sensitivity, .high)
        }
    }

    func test_forScan_adjustmentsComeAfterTheBlankCheck_onlyWhenTheyChangeSomething() throws {
        var s = ScanSettings()
        s.adjustments.brightness = 0.25
        XCTAssertEqual(PageProcessor.forScan(s).steps.map(\.name), ["blank", "adjust"])
        var gray = ScanSettings()
        gray.colorMode = .grayscale
        XCTAssertEqual(PageProcessor.forScan(gray).steps.map(\.name), ["blank", "adjust"])
        let adjust = try XCTUnwrap(PageProcessor.forScan(gray).steps[1] as? AdjustmentStep)
        XCTAssertEqual(adjust.colorMode, .grayscale)
    }

    func test_forScan_photosAndPagesSavedAtOnce_areNotChecked() {
        var photos = ScanSettings()
        photos.intent = .photo
        XCTAssertTrue(PageProcessor.forScan(photos).steps.isEmpty)
        XCTAssertFalse(PageProcessor.checksBlankPages(photos))
        var atOnce = ScanSettings()
        atOnce.documentMultiPage = false
        atOnce.document.removeBlankPages = true
        XCTAssertTrue(PageProcessor.forScan(atOnce).steps.isEmpty)
        XCTAssertFalse(PageProcessor.checksBlankPages(atOnce))
        XCTAssertTrue(PageProcessor.checksBlankPages(ScanSettings()))
        // Quick scan saves every scan at once.
        XCTAssertFalse(PageProcessor.checksBlankPages(TaskCatalog.apply(.quickScan, to: ScanSettings())))
    }

    func test_forScan_takesTheBackBindingAndArrangement() {
        var s = ScanSettings()
        s.backBinding = .shortEdge
        let processor = PageProcessor.forScan(s, arrangement: .turnedOverBacks)
        XCTAssertEqual(processor.arrangement, .turnedOverBacks)
        XCTAssertEqual(processor.binding, .shortEdge)
        XCTAssertEqual(PageProcessor.forScan(s).arrangement, .asScanned)
    }

    // MARK: Processing

    func test_process_recordsWhichPagesLookBlank_pixelsUnchanged() throws {
        let pages = [page(textImage), page(blankImage)]
        let result = try PageProcessor.forScan(ScanSettings()).process(pages)
        XCTAssertEqual(result.pages.map(\.id), pages.map(\.id))
        XCTAssertEqual(result.pages.map { $0.blank?.isBlank }, [false, true])
        XCTAssertTrue(result.pages[1].image === pages[1].image)
        XCTAssertEqual(result.blankCount, 1)
        // The arranged pages are the pages as scanned, before any step.
        XCTAssertEqual(result.arranged.map(\.id), pages.map(\.id))
        XCTAssertNil(result.arranged[1].blank)
    }

    func test_process_checksThePageAsScanned_beforeTheAdjustments() throws {
        // The result is that of the page as scanned, not of the adjusted pixels.
        var s = ScanSettings()
        s.colorMode = .blackWhite
        s.adjustments.brightness = -0.5
        s.adjustments.contrast = 3
        let result = try PageProcessor.forScan(s).process([page(textImage)])
        XCTAssertEqual(result.pages[0].blank, BlankPageDetector.analyze(textRgba, dpi: 100))
        XCTAssertEqual(result.pages[0].colorMode, .blackWhite)
        XCTAssertNotEqual(BlankPageDetector.analyze(result.pages[0].image, dpi: 100), result.pages[0].blank)
    }

    func test_process_aStepAfterTheCheck_doesNotChangeItsResult() throws {
        // A step that prints a bar over a blank page: the check before it still saw a blank page.
        let processor = PageProcessor(steps: [BlankDetectionStep(options: BlankPageOptions()), BarStep()])
        let result = try processor.process([page(blankImage)])
        XCTAssertEqual(result.pages[0].blank?.isBlank, true)
        XCTAssertFalse(BlankPageDetector.analyze(result.pages[0].image, dpi: 100).isBlank)
    }

    func test_process_twoSided_arrangesLikeDocumentSides_thenRunsTheSteps() throws {
        let scanned = (0..<4).map { _ in page(solid(4, 6, 255)) }
        var s = ScanSettings()
        s.backBinding = .shortEdge
        let result = try PageProcessor.forScan(s, arrangement: .twoSided).process(scanned)
        let expected = DocumentSides.arrangeTwoSided(scanned, binding: .shortEdge)
        XCTAssertEqual(result.arranged.map(\.id), expected.map(\.id))
        XCTAssertEqual(result.arranged.map(\.side), expected.map(\.side))
        XCTAssertEqual(result.arranged.map(\.sheetIndex), expected.map(\.sheetIndex))
        XCTAssertEqual(result.arranged.map(\.rotationQuarterTurns), expected.map(\.rotationQuarterTurns))
        XCTAssertEqual(result.pages.map(\.id), expected.map(\.id))
        XCTAssertEqual(result.pages.map(\.side), expected.map(\.side))
        XCTAssertTrue(result.pages.allSatisfy { $0.blank != nil })
    }

    func test_process_turnedOver_marksTheSide() throws {
        let scanned = [page(blankImage), page(textImage)]
        let fronts = try PageProcessor(steps: [], arrangement: .turnedOverFronts).process(scanned)
        let expected = DocumentSides.markManual(scanned, side: .front, binding: .longEdge)
        XCTAssertEqual(fronts.pages.map(\.side), expected.map(\.side))
        XCTAssertEqual(fronts.pages.map(\.sheetIndex), expected.map(\.sheetIndex))
        let backs = try PageProcessor(steps: [], arrangement: .turnedOverBacks).process(scanned)
        XCTAssertTrue(backs.pages.allSatisfy { $0.side == .back })
    }

    func test_process_runsEveryStepOnEveryPage_inOrder() throws {
        var log: [String] = []
        let pages = [page(solid(2, 3, 0)), page(solid(2, 3, 0))]
        let processor = PageProcessor(steps: [RecordingStep("one", log: { log.append($0) }),
                                              RecordingStep("two", log: { log.append($0) })])
        let result = try processor.process(pages)
        XCTAssertEqual(log, ["one:\(pages[0].id)", "two:\(pages[0].id)", "one:\(pages[1].id)", "two:\(pages[1].id)"])
        // Two quarter turns: the steps' results were passed on.
        XCTAssertTrue(result.pages.allSatisfy { $0.image.width == 2 && $0.image.height == 3 })
        XCTAssertTrue(try PageProcessor(steps: []).process([]).pages.isEmpty)
    }

    func test_process_stopsWhenCancelled() {
        XCTAssertThrowsError(try PageProcessor.forScan(ScanSettings()).process([page(blankImage)], shouldContinue: { false })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Which pages are saved

    func test_isExcluded_followsTheSetting_unlessTheUserDecided() {
        let on = options(true)
        let off = options(false)
        XCTAssertTrue(PageFilter.isExcluded(checked(true), options: on))
        XCTAssertFalse(PageFilter.isExcluded(checked(true), options: off))
        XCTAssertFalse(PageFilter.isExcluded(checked(false), options: on))
        XCTAssertFalse(PageFilter.isExcluded(page(blankImage), options: on))   // never checked
        XCTAssertFalse(PageFilter.isExcluded(checked(true, .keep), options: on))
        XCTAssertTrue(PageFilter.isExcluded(checked(false, .skip), options: off))
        XCTAssertTrue(PageFilter.isExcluded(checked(true, .skip), options: off))
    }

    func test_looksBlank_usesTheSensitivityOfNow() {
        // 0.02 % ink: blank at Medium and High, not at Low.
        let numbered = page(blankImage).withBlank(BlankPageResult(inkCoverage: 0.0002, inkComponents: 2,
                                                                  hasLargeDarkArea: false, isBlank: true))
        XCTAssertTrue(PageFilter.looksBlank(numbered, sensitivity: .medium))
        XCTAssertFalse(PageFilter.looksBlank(numbered, sensitivity: .low))
        XCTAssertFalse(PageFilter.isExcluded(numbered, options: options(true, .low)))
        let dark = page(blankImage).withBlank(BlankPageResult(inkCoverage: 0, inkComponents: 0,
                                                              hasLargeDarkArea: true, isBlank: false))
        XCTAssertFalse(PageFilter.looksBlank(dark, sensitivity: .high))
    }

    func test_toggled_flipsWhatSavingDoes_andTwoClicksUndoOne() {
        for remove in [false, true] {
            let o = options(remove)
            for start in [checked(true), checked(false)] {
                let before = PageFilter.isExcluded(start, options: o)
                let once = start.withInclusion(PageFilter.toggled(start, options: o))
                XCTAssertEqual(PageFilter.isExcluded(once, options: o), !before)
                let twice = once.withInclusion(PageFilter.toggled(once, options: o))
                XCTAssertEqual(PageFilter.isExcluded(twice, options: o), before)
                XCTAssertEqual(twice.inclusion, .automatic)
            }
        }
        XCTAssertEqual(PageFilter.toggled(checked(true), options: options(true)), .keep)
        XCTAssertEqual(PageFilter.toggled(checked(true), options: options(false)), .skip)
    }

    func test_pagesToSave_leavesOutExcludedPages_inQueueOrder() {
        let pages = [checked(false), checked(true), checked(true, .keep), checked(false, .skip)]
        XCTAssertEqual(PageFilter.pagesToSave(pages, options: options(true)).map(\.id), [pages[0].id, pages[2].id])
        XCTAssertEqual(PageFilter.pagesToSave(pages, options: options(false)).map(\.id), [pages[0].id, pages[1].id, pages[2].id])
    }

    func test_badge_andToggleLabel_sayWhatHappensToThePage() {
        let on = options(true)
        let off = options(false)
        XCTAssertEqual(PageFilter.badge(checked(true), options: on), "Blank, skipped")
        XCTAssertEqual(PageFilter.toggleLabel(checked(true), options: on), "Keep this page")
        XCTAssertEqual(PageFilter.badge(checked(true), options: off), "Looks blank")
        XCTAssertEqual(PageFilter.toggleLabel(checked(true), options: off), "Skip this page")
        XCTAssertEqual(PageFilter.badge(checked(true, .keep), options: on), "Looks blank")
        XCTAssertEqual(PageFilter.toggleLabel(checked(true, .keep), options: on), "Skip this page")
        XCTAssertEqual(PageFilter.badge(checked(false, .skip), options: off), "Skipped")
        XCTAssertEqual(PageFilter.toggleLabel(checked(false, .skip), options: off), "Keep this page")
        XCTAssertNil(PageFilter.badge(checked(false), options: on))
        XCTAssertNil(PageFilter.toggleLabel(checked(false), options: on))
        XCTAssertNil(PageFilter.badge(page(blankImage), options: on))
    }

    func test_queueSummary_andScanNote_countTheSkippedPages() {
        let on = options(true)
        XCTAssertEqual(PageFilter.queueSummary([checked(false)], options: on), "1 page in queue")
        XCTAssertEqual(PageFilter.queueSummary([checked(false), checked(true), checked(true)], options: on),
                       "3 pages in queue, 2 blank skipped")
        XCTAssertEqual(PageFilter.queueSummary([checked(false), checked(false, .skip)], options: on),
                       "2 pages in queue, 1 skipped")
        XCTAssertEqual(PageFilter.queueSummary([checked(true), checked(false)], options: options(false)), "2 pages in queue")
        XCTAssertEqual(PageFilter.scanNote([checked(true), checked(true), checked(false)], options: on),
                       " 2 look blank and will be skipped.")
        XCTAssertEqual(PageFilter.scanNote([checked(true)], options: options(false)), " 1 looks blank.")
        XCTAssertEqual(PageFilter.scanNote([checked(false), page(blankImage)], options: on), "")
    }

    // MARK: Page facts survive every rebuild

    func test_blankResultAndInclusion_surviveRebuildingThePage() {
        let result = BlankPageResult(inkCoverage: 0.00001, inkComponents: 1, hasLargeDarkArea: false, isBlank: true)
        let original = page(blankImage).withSide(.back, sheetIndex: 2).withBlank(result).withInclusion(.keep)
        let rebuilt = [
            original.withImage(solid(3, 3, 0)),
            original.withImage(ImagePipeline.rotate(original.image, quarterTurns: 1)),
            original.withSide(.front, sheetIndex: 0),
            page(textImage).copyMeta(from: original),
            original.withInclusion(.keep).withBlank(result),
        ]
        for page in rebuilt {
            XCTAssertEqual(page.blank, result)
            XCTAssertEqual(page.inclusion, .keep)
        }
        XCTAssertEqual(original.side, .back)
        XCTAssertEqual(original.sheetIndex, 2)
        XCTAssertEqual(page(blankImage).inclusion, .automatic)
        XCTAssertNil(page(blankImage).blank)
    }
}
