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

/// The spread of TestPages.shadowSpread as a 100 dpi scan: its spine at x = 572 of 1100.
private let spreadImage: CGImage = TestPages.shadowSpread().toRgba().makeCGImage()!

/// A w × h scan whose left part (x below w / 2) is red and right part blue, top half bright and bottom dim.
private func twoTone(_ w: Int, _ h: Int) -> RgbaImage {
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let level: UInt8 = y < h / 2 ? 250 : 120
            p[i] = x < w / 2 ? level : 0
            p[i + 2] = x < w / 2 ? 0 : level
            p[i + 3] = 255
        }
    }
    return RgbaImage(width: w, height: h, pixels: p)
}

/// A step that turns every page upright by `quarterTurns` clockwise, as reading its text would.
private struct TurnStep: PageStep {
    let quarterTurns: Int
    var name: String { "orientation" }

    func apply(_ page: ScannedPage) -> ScannedPage {
        page.turnedUpright(quarterTurns)
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

/// Text recognition that can or cannot run, reading nothing.
private struct StubScorer: OrientationScorer {
    let isAvailable: Bool
    func score(_ image: RgbaImage) throws -> OrientationScore { OrientationScore.none }
}

/// A step that records whether it was handed `shouldContinue`, and what it said.
private final class AskingStep: CancellablePageStep {
    private(set) var answers: [Bool] = []
    var name: String { "asking" }

    func apply(_ page: ScannedPage) -> ScannedPage {
        XCTFail("process hands shouldContinue on")
        return page
    }

    func apply(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage {
        answers.append(shouldContinue())
        return page
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

    func test_forScan_rotatePagesUpright_readsAfterTheSeparatorCheck_whenTextCanBeRead() throws {
        var s = ScanSettings()
        let scorer = StubScorer(isAvailable: true)
        XCTAssertFalse(PageProcessor.turnsPagesUpright(s))
        XCTAssertEqual(PageProcessor.forScan(s, scorer: scorer).steps.map(\.name), ["blank", "separator"])
        s.document.autoRotate = true
        XCTAssertTrue(PageProcessor.turnsPagesUpright(s))
        let processor = PageProcessor.forScan(s, scorer: scorer)
        XCTAssertEqual(processor.steps.map(\.name), ["blank", "separator", "orientation"])
        let step = try XCTUnwrap(processor.steps[2] as? OrientationStep)
        XCTAssertTrue(step.scorer is StubScorer)
        XCTAssertEqual(step.maxSeconds, OrientationDecision.maxSecondsPerPage)
        s.document.autoStraighten = true
        s.adjustments.brightness = 0.25
        XCTAssertEqual(PageProcessor.forScan(s, scorer: scorer).steps.map(\.name),
                       ["blank", "geometry", "separator", "orientation", "adjust"])
        // No text recognition: the pages are not turned.
        XCTAssertFalse(PageProcessor.forScan(s).steps.map(\.name).contains("orientation"))
        XCTAssertFalse(PageProcessor.forScan(s, scorer: StubScorer(isAvailable: false)).steps.map(\.name).contains("orientation"))
        // Pages saved at once, and photos, are never turned unseen.
        var photos = ScanSettings()
        photos.intent = .photo
        var atOnce = ScanSettings()
        atOnce.documentMultiPage = false
        for var other in [photos, atOnce] {
            other.document.autoRotate = true
            XCTAssertFalse(PageProcessor.turnsPagesUpright(other))
            XCTAssertFalse(PageProcessor.forScan(other, scorer: scorer).steps.map(\.name).contains("orientation"))
        }
    }

    func test_process_handsShouldContinueToStepsThatCanStopPartWay() throws {
        let step = AskingStep()
        _ = try PageProcessor(steps: [step]).process([page(blankImage), page(textImage)], shouldContinue: { true })
        XCTAssertEqual(step.answers, [true, true])
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

    // MARK: Facing pages

    func test_forScan_splitsFacingPages_onlyOnCollectedDocumentPages() throws {
        var s = ScanSettings()
        XCTAssertFalse(PageProcessor.splitsFacingPages(s))
        XCTAssertNil(PageProcessor.forScan(s).book)
        s.document.splitFacingPages = true
        s.taskOptions.bookRightToLeft = true
        s.taskOptions.bookRotationQuarterTurns = -1
        XCTAssertTrue(PageProcessor.splitsFacingPages(s))
        XCTAssertEqual(PageProcessor.forScan(s).book, BookSplitOptions(rotationQuarterTurns: 3, rightToLeft: true))
        // The steps are the usual ones: the split comes before them.
        XCTAssertEqual(PageProcessor.forScan(s).steps.map(\.name), ["blank", "separator"])
        XCTAssertNotNil(PageProcessor.forScan(TaskCatalog.apply(.book, to: ScanSettings())).book)
        // Pages saved at once, photos, copies and receipts are never cut unseen.
        var once = ScanSettings()
        once.documentMultiPage = false
        var photos = ScanSettings()
        photos.intent = .photo
        for var other in [once, photos, TaskCatalog.apply(.copy, to: ScanSettings()), TaskCatalog.apply(.receipt, to: ScanSettings())] {
            other.document.splitFacingPages = true
            XCTAssertFalse(PageProcessor.splitsFacingPages(other))
            XCTAssertNil(PageProcessor.forScan(other).book)
        }
        // Pages scanned on both sides keep their sheet and side: by a feeder that scans both, or turned by hand.
        for duplex in [DuplexMode.both, DuplexMode.manual] {
            var twoSided = ScanSettings()
            twoSided.source = .documentFeeder
            twoSided.duplex = duplex
            twoSided.document.splitFacingPages = true
            XCTAssertFalse(PageProcessor.splitsFacingPages(twoSided))
            XCTAssertNil(PageProcessor.forScan(twoSided).book)
        }
        // One side of each sheet from the feeder is split.
        var oneSided = ScanSettings()
        oneSided.source = .documentFeeder
        oneSided.duplex = .off
        oneSided.document.splitFacingPages = true
        XCTAssertTrue(PageProcessor.splitsFacingPages(oneSided))
        // The flatbed scans one side, whatever the feeder's choice.
        var flatbed = ScanSettings()
        flatbed.source = .flatbed
        flatbed.duplex = .both
        flatbed.document.splitFacingPages = true
        XCTAssertTrue(PageProcessor.splitsFacingPages(flatbed))
    }

    func test_process_spreadsGivenASide_keepTheirSheetAndSide() throws {
        // A front and its back, each a spread: every page cut from them keeps the side and sheet arranging gave it.
        let book = BookSplitOptions()
        let result = try PageProcessor(steps: [], arrangement: .twoSided, book: book)
            .process([page(spreadImage), page(spreadImage)])
        XCTAssertEqual(result.pages.count, 4)
        XCTAssertEqual(result.pages.map { $0.spread?.isWhole }, [false, false, false, false])
        XCTAssertEqual(result.pages.map(\.side), [.front, .front, .back, .back])
        XCTAssertEqual(result.pages.map(\.sheetIndex), [0, 0, 0, 0])
        // A spread kept whole too.
        let single = TestPages.singlePageAcross().toRgba().makeCGImage()!
        let whole = try PageProcessor(steps: [], arrangement: .twoSided, book: book)
            .process([page(single), page(single)]).pages
        XCTAssertEqual(whole.map { $0.spread?.isWhole }, [true, true])
        XCTAssertEqual(whole.map(\.side), [.front, .back])
        XCTAssertEqual(whole.map(\.sheetIndex), [0, 0])
        // Turned over by hand, and a spread split again by hand.
        let backs = try PageProcessor(steps: [], arrangement: .turnedOverBacks, book: book).process([page(spreadImage)]).pages
        XCTAssertFalse(backs.isEmpty)
        for back in backs {
            XCTAssertEqual(back.side, .back)
        }
        let cut = BookSplitter.manual(.vertical, fraction: 0.3, width: 200, height: 100)
        let again = try PageProcessor(steps: [])
            .processSpread(page(twoTone(200, 100).makeCGImage()!).withSide(.back, sheetIndex: 3), cut: cut, options: book)
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again.map(\.side), [.back, .back])
        XCTAssertEqual(again.map(\.sheetIndex), [3, 3])
        // A spread scanned one side has none.
        let plain = try PageProcessor(steps: [], book: book).process([page(spreadImage)]).pages
        XCTAssertEqual(plain.map(\.side), [nil, nil])
        XCTAssertEqual(plain.map(\.sheetIndex), [nil, nil])
    }

    func test_process_aSpread_becomesItsTwoPages_inReadingOrder() throws {
        let spread = page(spreadImage)
        let result = try PageProcessor(steps: [], book: BookSplitOptions()).process([spread])
        XCTAssertEqual(result.arranged.map(\.id), [spread.id])
        XCTAssertEqual(result.spreads.map(\.id), [spread.id])
        XCTAssertEqual(result.pages.count, 2)
        let left = result.pages[0], right = result.pages[1]
        // Cut at the spine, together exactly the spread, each at the scan's resolution.
        XCTAssertTrue((567...577).contains(left.image.width), "\(left.image.width)")
        XCTAssertEqual(left.image.width + right.image.width, 1100)
        for page in result.pages {
            XCTAssertEqual(page.image.height, 850)
            XCTAssertEqual(page.dpi, 100)
            XCTAssertEqual(page.colorMode, .color)
        }
        XCTAssertEqual(left.createdAt, spread.createdAt)
        // Each page records its spread and part, and has an id of its own.
        XCTAssertEqual(left.spreadID, spread.id)
        XCTAssertEqual(left.spread?.part, 0)
        XCTAssertEqual(left.spread?.gutter?.kind, .shadow)
        XCTAssertEqual(right.spreadID, spread.id)
        XCTAssertEqual(right.spread?.part, 1)
        XCTAssertEqual(left.spread?.gutter, right.spread?.gutter)
        XCTAssertEqual(Set([spread.id, left.id, right.id]).count, 3)
        // Right to left, the right page comes first.
        let rtl = try PageProcessor(steps: [], book: BookSplitOptions(rotationQuarterTurns: 0, rightToLeft: true))
            .process([spread]).pages
        XCTAssertEqual(rtl.map { $0.spread?.part }, [1, 0])
    }

    func test_process_aSpreadWithoutAClearSpine_staysWhole() throws {
        let single = page(TestPages.singlePageAcross().toRgba().makeCGImage()!)
        let result = try PageProcessor(steps: [], book: BookSplitOptions()).process([single])
        XCTAssertEqual(result.pages.count, 1)
        let whole = result.pages[0]
        XCTAssertEqual(whole.spread?.isWhole, true)
        XCTAssertEqual(whole.spreadID, single.id)
        XCTAssertNil(whole.spread?.gutter)
        XCTAssertNotEqual(whole.id, single.id)
        XCTAssertEqual(whole.image.width, 850)
        XCTAssertEqual(whole.image.height, 1100)
        XCTAssertEqual(result.spreads.map(\.id), [single.id])
        // Without the split, the page goes through as it is.
        let plain = try PageProcessor(steps: []).process([single])
        XCTAssertEqual(plain.pages.map(\.id), [single.id])
        XCTAssertNil(plain.pages[0].spread)
        XCTAssertTrue(plain.spreads.isEmpty)
    }

    func test_process_theStepsRunOnEachPage_ofEverySpread() throws {
        var log: [String] = []
        let spreads = [page(spreadImage), page(spreadImage)]
        let result = try PageProcessor(steps: [RecordingStep("one", log: { log.append($0) })], book: BookSplitOptions())
            .process(spreads)
        XCTAssertEqual(result.pages.count, 4)
        XCTAssertEqual(log, result.pages.map { "one:\($0.id)" })
        XCTAssertEqual(result.pages.compactMap(\.spreadID), [spreads[0].id, spreads[0].id, spreads[1].id, spreads[1].id])
        // A blank facing page is flagged like any blank page.
        let blankFacing = try PageProcessor.forScan(TaskCatalog.apply(.book, to: ScanSettings()))
            .process([page(TestPages.blankFacingSpread().toRgba().makeCGImage()!)]).pages
        XCTAssertEqual(blankFacing.map { $0.blank?.isBlank == true }, [true, false])
    }

    func test_processSpread_cutsWhereAsked_orKeepsTheSpreadWhole() throws {
        let spread = page(twoTone(200, 100).makeCGImage()!)
        let processor = PageProcessor(steps: [], book: BookSplitOptions())
        let cut = BookSplitter.manual(.vertical, fraction: 0.3, width: 200, height: 100)
        let pages = try processor.processSpread(spread, cut: cut, options: BookSplitOptions())
        XCTAssertEqual(pages.map(\.image.width), [60, 140])
        for page in pages {
            XCTAssertEqual(page.spread?.gutter?.kind, .manual)
        }
        let whole = try processor.processSpread(spread, cut: nil, options: BookSplitOptions())
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(whole[0].spread?.isWhole, true)
        XCTAssertEqual([whole[0].image.width, whole[0].image.height], [200, 100])
        // The book's rotation turns the whole spread too.
        let turned = try processor.processSpread(spread, cut: nil, options: BookSplitOptions(rotationQuarterTurns: 1))
        XCTAssertEqual([turned[0].image.width, turned[0].image.height], [100, 200])
    }

    func test_processSpread_pagesTurnedByReadingTheirText_areOrderedAsTheyLieTurned() throws {
        // A book lying sideways: its pages one above the other, red on top, blue below.
        let stacked = page(twoTone(200, 100).rotatedQuarterTurns(1).makeCGImage()!)
        let cut = BookSplitter.manual(.horizontal, fraction: 0.5, width: 100, height: 200)
        // Reading turns each page a quarter counterclockwise: the top page lies on the left, and leads.
        let counter = try PageProcessor(steps: [TurnStep(quarterTurns: 3)])
            .processSpread(stacked, cut: cut, options: BookSplitOptions())
        XCTAssertEqual(counter.map { $0.spread?.part }, [0, 1])
        for page in counter {
            XCTAssertEqual(page.upright, UprightTurn(quarterTurns: 3))
        }
        // Clockwise, the top page lies on the right: the bottom one leads, unless the book reads right to left.
        let clockwise = try PageProcessor(steps: [TurnStep(quarterTurns: 1)])
            .processSpread(stacked, cut: cut, options: BookSplitOptions())
        XCTAssertEqual(clockwise.map { $0.spread?.part }, [1, 0])
        let rightToLeft = try PageProcessor(steps: [TurnStep(quarterTurns: 1)])
            .processSpread(stacked, cut: cut, options: BookSplitOptions(rotationQuarterTurns: 0, rightToLeft: true))
        XCTAssertEqual(rightToLeft.map { $0.spread?.part }, [0, 1])
        // The book's rotation counts the same way: turned clockwise by setting, then not read.
        let bySetting = try PageProcessor(steps: []).processSpread(stacked, cut: cut, options: BookSplitOptions(rotationQuarterTurns: 1))
        XCTAssertEqual(bySetting.map { $0.spread?.part }, [1, 0])
        for page in bySetting {
            XCTAssertEqual([page.image.width, page.image.height], [100, 100])
        }
    }

    func test_spread_survivesRebuildingThePage() {
        let spreadPart = SpreadPart(spreadID: UUID(), part: 1, gutter: BookSplitter.manual(.vertical, fraction: 0.5, width: 10, height: 10))
        let original = page(blankImage).withSpread(spreadPart)
        let geometry = PageGeometry(cropped: false, angleDegrees: 1.5, basis: .textLines)
        let rebuilt = [
            original.withImage(solid(3, 3, 0)),
            original.withSide(.front, sheetIndex: 0),
            original.withBlank(nil),
            original.withInclusion(.skip),
            original.withPatch(nil),
            original.withDocumentBreak(.split),
            original.withDocumentLabel("Chapter 1"),
            original.withUpright(UprightTurn(quarterTurns: 2)),
            original.turnedUpright(2),
            original.withAlternate(nil),
            original.withGeometry(solid(3, 3, 0), geometry: geometry),
            original.withGeometry(solid(3, 3, 0), geometry: geometry).withVersionsSwapped(blankImage),
            page(textImage).copyMeta(from: original),
        ]
        for page in rebuilt {
            XCTAssertEqual(page.spread, spreadPart)
            XCTAssertEqual(page.spreadID, spreadPart.spreadID)
        }
        XCTAssertNil(original.withSpread(nil).spread)
        XCTAssertNil(page(blankImage).spreadID)
    }
}
