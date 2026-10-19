import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/PageProcessorTests.cs: the clean-up stage, which
// pages are saved, and the page facts every rebuild keeps.

private let blankRgba = TestPages.enlarged(TestPages.noisyBlank(), 1)
private let textRgba = TestPages.enlarged(TestPages.oneTextLine(), 1)
private let blankImage: CGImage = blankRgba.makeCGImage()!
private let textImage: CGImage = textRgba.makeCGImage()!
/// A 6 × 8 in sheet lying at -4° on a dark backdrop, scanned at 100 dpi.
private let sheetRgba = TestPages.sheetOnBackdrop(TestPages.minus4, backdrop: 30, paper: 240, shadow: 0,
                                                  seed: 0x5EE7_0002).toRgba()
private let sheetImage: CGImage = sheetRgba.makeCGImage()!

/// The sheet cropped and straightened by hand: a gray stand-in, with the facts a scan records.
private func corrected() -> ScannedPage {
    page(sheetImage)
        .withSide(.front, sheetIndex: 1)
        .withBlank(BlankPageResult(inkCoverage: 0.01, inkComponents: 50, hasLargeDarkArea: false, isBlank: false))
        .withGeometry(RgbaImage.filled(width: 60, height: 80, r: 200, g: 200, b: 200).makeCGImage()!,
                      geometry: PageGeometry(cropped: true, angleDegrees: -4, basis: .pageEdges))
}

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
            XCTAssertEqual(processor.steps.map(\.name), ["blank", "separator"])
            let step = try XCTUnwrap(processor.steps[0] as? BlankDetectionStep)
            XCTAssertEqual(step.options.sensitivity, .high)
        }
    }

    func test_forScan_adjustmentsComeAfterTheBlankCheck_onlyWhenTheyChangeSomething() throws {
        var s = ScanSettings()
        s.adjustments.brightness = 0.25
        XCTAssertEqual(PageProcessor.forScan(s).steps.map(\.name), ["blank", "separator", "adjust"])
        var gray = ScanSettings()
        gray.colorMode = .grayscale
        XCTAssertEqual(PageProcessor.forScan(gray).steps.map(\.name), ["blank", "separator", "adjust"])
        let adjust = try XCTUnwrap(PageProcessor.forScan(gray).steps[2] as? AdjustmentStep)
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

    func test_forScan_cropAndStraighten_comeBetweenTheBlankCheckAndTheAdjustments() throws {
        var s = ScanSettings()
        XCTAssertFalse(PageProcessor.correctsGeometry(s))
        s.document.autoStraighten = true
        s.adjustments.brightness = 0.25
        XCTAssertTrue(PageProcessor.correctsGeometry(s))
        let processor = PageProcessor.forScan(s)
        XCTAssertEqual(processor.steps.map(\.name), ["blank", "geometry", "separator", "adjust"])
        let step = try XCTUnwrap(processor.steps[1] as? GeometryStep)
        XCTAssertEqual([step.crop, step.straighten], [false, true])
        s.document.autoCrop = true
        s.document.autoStraighten = false
        let cropOnly = try XCTUnwrap(PageProcessor.forScan(s).steps[1] as? GeometryStep)
        XCTAssertEqual([cropOnly.crop, cropOnly.straighten], [true, false])
    }

    func test_forScan_photosAndPagesSavedAtOnce_areNeverCroppedOrStraightened() {
        var photos = ScanSettings()
        photos.intent = .photo
        var atOnce = ScanSettings()
        atOnce.documentMultiPage = false
        for var s in [photos, atOnce] {
            s.document.autoCrop = true
            s.document.autoStraighten = true
            XCTAssertFalse(PageProcessor.correctsGeometry(s))
            XCTAssertFalse(PageProcessor.forScan(s).steps.map(\.name).contains("geometry"))
        }
    }

    func test_forScan_separatorSheets_areLookedForOnCollectedDocumentPages_whetherOrNotTheStackIsSplit() throws {
        for mode in SplitMode.displayOrder {
            var s = ScanSettings()
            s.document.splitMode = mode
            XCTAssertTrue(PageProcessor.forScan(s).steps.map(\.name).contains("separator"))
        }
        var photos = ScanSettings()
        photos.intent = .photo
        var atOnce = ScanSettings()
        atOnce.documentMultiPage = false
        for var s in [photos, atOnce] {
            s.document.splitMode = .separatorSheet
            XCTAssertFalse(PageProcessor.forScan(s).steps.map(\.name).contains("separator"))
        }
        // The check records the code and keeps every other fact of the page.
        let sheet = try XCTUnwrap(PatchCodeDetector.renderSheet(.patch2, widthInches: 8.5, heightInches: 11, dpi: 150)
            .toRgba().makeCGImage())
        let scanned = ScannedPage(image: sheet, dpi: 150, colorMode: .color)
            .withSide(.front, sheetIndex: 3).withInclusion(.keep)
        let processed = try PageProcessor.forScan(ScanSettings()).process([scanned]).pages[0]
        XCTAssertEqual(processed.patch, .patch2)
        XCTAssertEqual(processed.side, .front)
        XCTAssertEqual(processed.sheetIndex, 3)
        XCTAssertEqual(processed.inclusion, .keep)
        XCTAssertEqual(processed.blank?.isBlank, false)
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

    func test_process_cropsAndStraightens_keepingThePageAsScanned() throws {
        var s = ScanSettings()
        s.document.autoCrop = true
        s.document.autoStraighten = true
        let scanned = page(sheetImage)
        let result = try PageProcessor.forScan(s).process([scanned])
        let processed = result.pages[0]
        XCTAssertEqual(processed.id, scanned.id)
        let geometry = try XCTUnwrap(processed.geometry)
        XCTAssertTrue(geometry.cropped)
        XCTAssertTrue(abs(geometry.angleDegrees - TestPages.minus4.degrees) <= 0.3, "\(geometry.angleDegrees)")
        XCTAssertFalse(processed.showsOriginal)
        XCTAssertTrue(processed.canSwapVersions)
        XCTAssertTrue(processed.alternate?.image === sheetImage)
        XCTAssertTrue(processed.image.width >= TestPages.sheetWidth - 4 && processed.image.width <= TestPages.sheetWidth + 2,
                      "\(processed.image.width)")
        // The blank check ran on the page as scanned.
        XCTAssertEqual(processed.blank?.isBlank, false)
        XCTAssertEqual(PageCorrections.scanNote(result.pages), " 1 cropped and straightened.")
    }

    func test_process_pageItIsNotSureAbout_staysAsScanned() throws {
        var s = ScanSettings()
        s.document.autoCrop = true
        s.document.autoStraighten = true
        let scanned = page(blankImage)
        let processed = try PageProcessor.forScan(s).process([scanned]).pages[0]
        XCTAssertTrue(processed.image === scanned.image)
        XCTAssertNil(processed.geometry)
        XCTAssertNil(processed.alternate)
        XCTAssertFalse(processed.canSwapVersions)
        XCTAssertEqual(PageCorrections.scanNote([processed]), "")
    }

    func test_adjustmentStep_adjustsBothVersions() throws {
        var s = ScanSettings()
        s.colorMode = .grayscale
        s.document.autoCrop = true
        s.document.autoStraighten = true
        let processed = try PageProcessor.forScan(s).process([page(sheetImage)]).pages[0]
        XCTAssertEqual(processed.colorMode, .grayscale)
        // The page as scanned went through the adjustments too: new pixels, its own size.
        let other = try XCTUnwrap(processed.alternate?.image)
        XCTAssertFalse(other === sheetImage)
        XCTAssertEqual(other.width, sheetImage.width)
        XCTAssertEqual(other.height, sheetImage.height)
        XCTAssertNotNil(processed.geometry)
    }

    // MARK: Showing a page as scanned

    func test_withVersionsSwapped_showsThePageAsScanned_andBackAgain() throws {
        let changed = corrected()
        let original = changed.withVersionsSwapped(try XCTUnwrap(changed.alternate?.image))
        XCTAssertTrue(original.showsOriginal)
        XCTAssertTrue(original.image === sheetImage)
        XCTAssertEqual(original.id, changed.id)
        XCTAssertEqual(original.geometry, changed.geometry)
        XCTAssertEqual(original.side, .front)
        XCTAssertEqual(original.sheetIndex, 1)
        XCTAssertEqual(original.blank, changed.blank)
        XCTAssertTrue(original.alternate?.image === changed.image)
        let back = original.withVersionsSwapped(try XCTUnwrap(original.alternate?.image))
        XCTAssertFalse(back.showsOriginal)
        XCTAssertTrue(back.image === changed.image)
        XCTAssertTrue(back.alternate?.image === sheetImage)
        // A page with no other version stays as it is.
        let plain = page(blankImage)
        let same = plain.withVersionsSwapped(textImage)
        XCTAssertTrue(same.image === blankImage)
        XCTAssertFalse(same.showsOriginal)
    }

    func test_withVersionsSwapped_spooledVersions_swapFilesAndDropThePixelsOfTheHiddenOne() throws {
        let correctedURL = URL(fileURLWithPath: "/tmp/corrected.tiff")
        let originalURL = URL(fileURLWithPath: "/tmp/original.tiff")
        let spooled = corrected()
            .withImage(solid(6, 8, 1), fileURL: correctedURL, fullPixelSize: CGSize(width: 60, height: 80))
            .withAlternate(PageVersion(image: nil, fileURL: originalURL, fullPixelSize: CGSize(width: 850, height: 1100)))
        let preview = solid(85, 110, 2)
        let original = spooled.withVersionsSwapped(preview)
        XCTAssertEqual(original.fileURL, originalURL)
        XCTAssertEqual(original.fullPixelSize, CGSize(width: 850, height: 1100))
        XCTAssertTrue(original.image === preview)
        let hidden = try XCTUnwrap(original.alternate)
        XCTAssertNil(hidden.image)
        XCTAssertEqual(hidden.fileURL, correctedURL)
        XCTAssertEqual(hidden.fullPixelSize, CGSize(width: 60, height: 80))
    }

    func test_geometry_survivesRebuildingThePage_theOtherVersionStaysWithItsPixels() {
        let swapped = corrected().withVersionsSwapped(sheetImage)
        let rebuilt = [
            swapped.withImage(solid(3, 3, 0)),
            swapped.withSide(.back, sheetIndex: 0),
            swapped.withBlank(nil),
            swapped.withInclusion(.skip),
        ]
        for page in rebuilt {
            XCTAssertEqual(page.geometry, swapped.geometry)
            XCTAssertTrue(page.showsOriginal)
            XCTAssertTrue(page.alternate?.image === swapped.alternate?.image)
        }
        // copyMeta takes the source's facts and keeps this page's other version.
        let other = page(textImage).copyMeta(from: swapped)
        XCTAssertEqual(other.geometry, swapped.geometry)
        XCTAssertTrue(other.showsOriginal)
        XCTAssertNil(other.alternate)
        XCTAssertNil(page(textImage).geometry)
    }

    func test_pageCorrections_sayWhatWasDone_andWhatOneClickDoes() {
        let changed = corrected()
        XCTAssertEqual(PageCorrections.caption(changed), "Cropped and straightened 4.0°")
        XCTAssertEqual(PageCorrections.toggleLabel(changed), "Show as scanned")
        XCTAssertEqual(PageCorrections.swapNote(changed, number: 2), "Page 2 is cropped and straightened again.")
        let original = changed.withVersionsSwapped(sheetImage)
        XCTAssertEqual(PageCorrections.caption(original), "As scanned")
        XCTAssertEqual(PageCorrections.toggleLabel(original), "Show cropped and straightened")
        XCTAssertEqual(PageCorrections.swapNote(original, number: 2), "Page 2 is shown as scanned. It is saved that way.")
        let straightened = page(sheetImage).withGeometry(sheetImage, geometry: PageGeometry(cropped: false, angleDegrees: 1.25,
                                                                                             basis: .textLines))
        XCTAssertEqual(PageCorrections.caption(straightened), "Straightened 1.3°")
        XCTAssertEqual(PageCorrections.toggleLabel(straightened.withVersionsSwapped(sheetImage)), "Show straightened")
        let cropped = page(sheetImage).withGeometry(sheetImage, geometry: PageGeometry(cropped: true, angleDegrees: 0,
                                                                                        basis: .pageEdges))
        XCTAssertEqual(PageCorrections.caption(cropped), "Cropped")
        XCTAssertNil(PageCorrections.caption(page(blankImage)))
        XCTAssertNil(PageCorrections.toggleLabel(page(blankImage)))
        XCTAssertNil(PageCorrections.toggleLabel(cropped.withAlternate(nil)))
        XCTAssertEqual(PageCorrections.scanNote([straightened, straightened, page(blankImage)]), " 2 straightened.")
        XCTAssertEqual(PageCorrections.scanNote([straightened, cropped]), " 2 cropped or straightened.")
        XCTAssertEqual(PageCorrections.scanNote([original]), "")
    }

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
