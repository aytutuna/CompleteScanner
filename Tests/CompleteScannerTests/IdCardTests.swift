import XCTest
import CoreGraphics
import PDFKit
@testable import CompleteScannerKit

// The ID card task: paper, steps, layout, composer and detector. Mirrors
// windows/LazyScan.Core.Tests/IdCardTests.cs: the same cases, on the same synthetic beds.

private let card = CGSize(width: IdCardDetector.cardLongSideInches, height: IdCardDetector.cardShortSideInches)
private let letter = PaperSizes.inches(.letter)!
private let a4 = PaperSizes.inches(.a4)!

/// One flat-colored rectangle on a synthetic bed, in inches, turned clockwise by `angleDegrees`.
private struct BedItem {
    let center: CGPoint
    let size: CGSize
    let angleDegrees: Double
    let r: UInt8, g: UInt8, b: UInt8
}

/// A flatbed scan: light gray glass (245) with flat rectangles on it. Pixels whose centre lies
/// inside a rectangle take its color.
private func bed(dpi: Int, widthInches: Double, heightInches: Double, _ items: [BedItem]) -> RgbaImage {
    let width = Int((widthInches * Double(dpi)).rounded()), height = Int((heightInches * Double(dpi)).rounded())
    var image = RgbaImage.filled(width: width, height: height, r: 245, g: 245, b: 245)
    for item in items {
        let a = item.angleDegrees * .pi / 180, cosA = cos(a), sinA = sin(a)
        let cx = Double(item.center.x) * Double(dpi), cy = Double(item.center.y) * Double(dpi)
        let hw = Double(item.size.width) * Double(dpi) / 2, hh = Double(item.size.height) * Double(dpi) / 2
        let reach = (hw * hw + hh * hh).squareRoot() + 2
        let minX = max(0, Int(cx - reach)), maxX = min(width - 1, Int(cx + reach))
        let minY = max(0, Int(cy - reach)), maxY = min(height - 1, Int(cy + reach))
        guard minX <= maxX, minY <= maxY else { continue }
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let lx = dx * cosA + dy * sinA, ly = -dx * sinA + dy * cosA
                if abs(lx) > hw || abs(ly) > hh { continue }
                let i = (y * width + x) * 4
                image.pixels[i] = item.r
                image.pixels[i + 1] = item.g
                image.pixels[i + 2] = item.b
            }
        }
    }
    return image
}

private func pixel(_ image: RgbaImage, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * image.width + x) * 4
    return [image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]]
}

private func assertRect(_ expected: CGRect, _ actual: CGRect?, file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("No rectangle", file: file, line: line) }
    XCTAssertEqual(Double(actual.origin.x), Double(expected.origin.x), accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(Double(actual.origin.y), Double(expected.origin.y), accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(Double(actual.size.width), Double(expected.size.width), accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(Double(actual.size.height), Double(expected.size.height), accuracy: 0.001, file: file, line: line)
}

private func solidSide(_ inches: CGSize, dpi: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> IdCardSide {
    IdCardSide(image: RgbaImage.filled(width: Int((Double(inches.width) * Double(dpi)).rounded()),
                                       height: Int((Double(inches.height) * Double(dpi)).rounded()), r: r, g: g, b: b),
               dpi: dpi)
}

private func region(_ x: Double, _ y: Double, _ widthInches: Double, _ heightInches: Double, dpi: Int = 300,
                    angle: Double = 0) -> DetectedPhotoRegion {
    DetectedPhotoRegion(center: CGPoint(x: x * Double(dpi), y: y * Double(dpi)),
                        size: CGSize(width: widthInches * Double(dpi), height: heightInches * Double(dpi)),
                        angleDegrees: angle)
}

final class IdCardTests: XCTestCase {

    // MARK: Paper

    func test_paper_automaticIsTheFirstChoice_storedNames() {
        XCTAssertEqual(IdCardPaper.allCases, [.auto, .a4, .letter])
        XCTAssertEqual(IdCardPaper.allCases.map(\.rawValue), ["auto", "a4", "letter"])
        XCTAssertEqual(IdCardPaper.allCases.map(\.label), ["Automatic", "A4", "Letter"])
        XCTAssertEqual(TaskOptions().idCardPaper, .auto)
        XCTAssertFalse(TaskOptions().idCardSaveSidesAsImages)
    }

    func test_paper_automaticFollowsTheRegion() {
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "US"), .letter)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "ca"), .letter)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "TR"), .a4)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "DE"), .a4)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: nil), .a4)
        XCTAssertEqual(IdCardPapers.resolve(.a4, regionCode: "US"), .a4)
        XCTAssertEqual(IdCardPapers.resolve(.letter, regionCode: "TR"), .letter)
        XCTAssertEqual(IdCardPapers.choiceLabel(.auto, regionCode: "US"), "Automatic (Letter)")
        XCTAssertEqual(IdCardPapers.choiceLabel(.auto, regionCode: "TR"), "Automatic (A4)")
        XCTAssertEqual(IdCardPapers.choiceLabel(.a4, regionCode: "US"), "A4")
    }

    func test_paper_automaticIsTheDefaultPrintersPaper_whenItIsA4OrLetter() {
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "TR", printerPaper: .letter), .letter)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "US", printerPaper: .a4), .a4)
        // Other paper in the printer, or none known: the region's.
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "TR", printerPaper: .legal), .a4)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "US", printerPaper: .a5), .letter)
        XCTAssertEqual(IdCardPapers.resolve(.auto, regionCode: "US", printerPaper: nil), .letter)
        // A choice made by hand stands.
        XCTAssertEqual(IdCardPapers.resolve(.a4, regionCode: "US", printerPaper: .letter), .a4)
        XCTAssertEqual(IdCardPapers.resolve(.letter, regionCode: "TR", printerPaper: .a4), .letter)
        XCTAssertEqual(IdCardPapers.choiceLabel(.auto, regionCode: "TR", printerPaper: .letter), "Automatic (Letter)")
        XCTAssertEqual(IdCardPapers.choiceLabel(.auto, regionCode: "TR", printerPaper: .legal), "Automatic (A4)")
        XCTAssertEqual(IdCardPapers.choiceLabel(.letter, regionCode: "TR", printerPaper: .a4), "Letter")
    }

    // MARK: Steps

    func test_steps_frontThenBackThenReview() {
        let steps = IdCardSteps.steps
        XCTAssertEqual(steps.map(\.id), ["front", "back", "review"])
        XCTAssertEqual(steps.map(\.primaryActionLabel), ["Scan front", "Scan back", "Review"])
        XCTAssertEqual(steps.map(\.requiresCapture), [true, false, false])
        XCTAssertEqual(steps.map(\.skippable), [false, true, false])
        XCTAssertTrue(steps.allSatisfy { !$0.repeats })
        XCTAssertTrue(steps.allSatisfy { !$0.prompt.isEmpty })
        XCTAssertEqual(steps.map(\.prompt), ["Place the card face down near a corner and scan.",
                                             "Turn the card over where it lies and scan.", "Check both sides, then save."])
        XCTAssertEqual(steps.map(\.help), ["Close the lid before scanning.", "Nothing printed on the back? Select No back side.",
                                           "Both sides go on one page at real size."])
        XCTAssertEqual(steps.map(\.word), ["Front", "Back", "Check"])
        XCTAssertEqual(IdCardSteps.skipBackLabel, "No back side")
        XCTAssertEqual(IdCardSteps.privacyNote, "Not kept in Scans history")
        XCTAssertEqual(IdCardSteps.privacyHelp, "The scans stay on this computer and are cleared once you save or discard them.")
        XCTAssertEqual(IdCardSteps.sideOf("front"), .front)
        XCTAssertEqual(IdCardSteps.sideOf("back"), .back)
        XCTAssertNil(IdCardSteps.sideOf("review"))
        XCTAssertNil(IdCardSteps.sideOf(nil))
        XCTAssertEqual(IdCardSteps.stepID(.front), "front")
        XCTAssertEqual(IdCardSteps.stepID(.back), "back")
    }

    func test_offersSkip_onlyTheBackOfTheCard_neverTheBacksOfAStackTurnedOver() {
        XCTAssertEqual(IdCardSteps.steps.map { IdCardSteps.offersSkip($0) }, [false, true, false])
        XCTAssertFalse(IdCardSteps.offersSkip(nil))
        // The backs of a stack turned over by hand are skippable in the steps, but are left out with
        // Keep Fronts Only: no Skip button for them.
        XCTAssertTrue(DocumentSides.manualSteps.contains { $0.skippable })
        XCTAssertTrue(DocumentSides.manualSteps.allSatisfy { !IdCardSteps.offersSkip($0) })
        // Nor for the steps of any other task.
        for definition in TaskCatalog.all where definition.task != .idCard {
            XCTAssertTrue(definition.steps.allSatisfy { !IdCardSteps.offersSkip($0) }, "\(definition.task)")
        }
    }

    func test_flow_skipTheBack_retakeTheFront_finishOnlyWithAFront() {
        var flow = TaskFlow(steps: IdCardSteps.steps)
        XCTAssertFalse(flow.canFinish)
        XCTAssertFalse(flow.advance())
        XCTAssertFalse(flow.skip())
        let front = UUID()
        flow.record(stepID: "front", captureID: front)
        XCTAssertTrue(flow.canFinish)
        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.current?.id, "back")
        // A card with nothing on its back: skipped, on to the review.
        XCTAssertTrue(flow.skip())
        XCTAssertTrue(flow.isSkipped("back"))
        XCTAssertEqual(flow.current?.id, "review")
        XCTAssertTrue(flow.canFinish)
        // The front again: its capture goes, the back stays skipped.
        XCTAssertEqual(flow.retake(stepID: "front"), [front])
        XCTAssertEqual(flow.current?.id, "front")
        XCTAssertFalse(flow.canFinish)
        XCTAssertTrue(flow.isSkipped("back"))
        flow.record(stepID: "front", captureID: UUID())
        XCTAssertTrue(flow.canFinish)
        // A second front replaces the first.
        let third = UUID()
        XCTAssertEqual(flow.record(stepID: "front", captureID: third).count, 1)
        XCTAssertEqual(flow.captures(for: "front"), [third])
        // The review neither needs nor skips anything; done once advanced past.
        XCTAssertTrue(flow.advance())
        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.current?.id, "review")
        XCTAssertFalse(flow.skip())
        XCTAssertTrue(flow.advance())
        XCTAssertTrue(flow.isComplete)
    }

    // MARK: Layout

    func test_layout_letter_bothSidesAtRealSize() {
        let layout = IdCardLayout.place(front: card, back: card, paper: letter)
        XCTAssertFalse(layout.scaledToFit)
        XCTAssertEqual(layout.scale, 1)
        assertRect(CGRect(x: 2.565, y: 1.0, width: 3.370, height: 2.125), layout.front)
        assertRect(CGRect(x: 2.565, y: 3.625, width: 3.370, height: 2.125), layout.back)
    }

    func test_layout_a4_bothSidesAtRealSize() {
        let layout = IdCardLayout.place(front: card, back: card, paper: a4)
        XCTAssertFalse(layout.scaledToFit)
        assertRect(CGRect(x: (8.2677 - 3.370) / 2, y: 1.0, width: 3.370, height: 2.125), layout.front)
        assertRect(CGRect(x: (8.2677 - 3.370) / 2, y: 3.625, width: 3.370, height: 2.125), layout.back)
    }

    func test_layout_frontOnly() {
        let layout = IdCardLayout.place(front: card, back: nil, paper: letter)
        XCTAssertNil(layout.back)
        assertRect(CGRect(x: 2.565, y: 1.0, width: 3.370, height: 2.125), layout.front)
        // A card lying the other way round (a portrait licence) keeps its own shape.
        let portrait = IdCardLayout.place(front: CGSize(width: 2.125, height: 3.370), back: nil, paper: letter)
        assertRect(CGRect(x: (8.5 - 2.125) / 2, y: 1.0, width: 2.125, height: 3.370), portrait.front)
    }

    func test_layout_tooLarge_isScaledToFit() {
        let large = CGSize(width: 7, height: 5)
        // Front only: 1 + 5 in fits in 11 − 0.25 in.
        XCTAssertFalse(IdCardLayout.place(front: large, back: nil, paper: letter).scaledToFit)
        // Both: 1 + 5 + 0.5 + 5 = 11.5 in does not; 9.25 / 10.
        let both = IdCardLayout.place(front: large, back: large, paper: letter)
        XCTAssertTrue(both.scaledToFit)
        XCTAssertEqual(both.scale, 0.925, accuracy: 1e-6)
        assertRect(CGRect(x: (8.5 - 6.475) / 2, y: 1.0, width: 6.475, height: 4.625), both.front)
        assertRect(CGRect(x: (8.5 - 6.475) / 2, y: 6.125, width: 6.475, height: 4.625), both.back)
        XCTAssertLessThanOrEqual(Double(both.back!.maxY), 11 - IdCardLayout.edgeMarginInches + 1e-9)
        // Too wide: 9 in on 8.5 in paper.
        let wide = IdCardLayout.place(front: CGSize(width: 9, height: 2), back: nil, paper: letter)
        XCTAssertTrue(wide.scaledToFit)
        XCTAssertEqual(wide.scale, 8.0 / 9, accuracy: 1e-6)
        XCTAssertEqual(Double(wide.front.origin.x), 0.25, accuracy: 1e-6)
        XCTAssertEqual(Double(wide.front.size.width), 8.0, accuracy: 1e-6)
    }

    func test_layout_caption() {
        XCTAssertEqual(IdCardLayout.caption(paper: .a4, hasBack: true, scaledToFit: false), "One A4 page, real size")
        XCTAssertEqual(IdCardLayout.caption(paper: .letter, hasBack: true, scaledToFit: false), "One Letter page, real size")
        XCTAssertEqual(IdCardLayout.caption(paper: .letter, hasBack: false, scaledToFit: true),
                       "Front only, one Letter page, made smaller to fit")
        XCTAssertEqual(IdCardLayout.caption(paper: .a4, hasBack: true, scaledToFit: true), "One A4 page, made smaller to fit")
    }

    // MARK: Composer

    func test_composer_letterAt300DPI() {
        let front = solidSide(card, dpi: 300, 200, 40, 40)
        let back = solidSide(card, dpi: 300, 40, 90, 200)
        XCTAssertEqual(front.image.width, 1011)
        XCTAssertEqual(front.image.height, 638)
        let page = IdCardComposer.compose(front: front, back: back, dpi: 300, paperInches: letter)
        XCTAssertEqual(page.width, 2550)
        XCTAssertEqual(page.height, 3300)
        let size = IdCardComposer.canvasSize(paperInches: letter, dpi: 300)
        XCTAssertEqual(size.width, 2550)
        XCTAssertEqual(size.height, 3300)
        // The centre of each side is its color.
        XCTAssertEqual(pixel(page, 1275, 300 + 319), [200, 40, 40])
        XCTAssertEqual(pixel(page, 1275, 1088 + 319), [40, 90, 200])
        // The margins, and the gap between the sides, are white.
        for (x, y) in [(0, 0), (2549, 3299), (1275, 150), (100, 619), (2450, 619), (1275, 1000), (1275, 3000)] {
            XCTAssertEqual(pixel(page, x, y), [255, 255, 255], "\(x), \(y)")
        }
    }

    func test_composer_a4At300DPI_frontOnly() {
        let page = IdCardComposer.compose(front: solidSide(card, dpi: 300, 200, 40, 40), back: nil, dpi: 300, paperInches: a4)
        XCTAssertEqual(page.width, 2480)
        XCTAssertEqual(page.height, 3508)
        XCTAssertEqual(pixel(page, 1240, 619), [200, 40, 40])
        // No back: white where it would be.
        XCTAssertEqual(pixel(page, 1240, 1407), [255, 255, 255])
    }

    func test_composer_resamplesASideScannedAtAnotherResolution() {
        // Scanned at 150 dpi, composed at 300: the side covers its real size.
        let front = solidSide(card, dpi: 150, 10, 120, 60)
        XCTAssertEqual(front.image.width, 506)
        XCTAssertEqual(front.image.height, 319)
        let page = IdCardComposer.compose(front: front, back: nil, dpi: 300, paperInches: letter)
        XCTAssertEqual(pixel(page, 1275, 619), [10, 120, 60])
        // Its edges are where a 300 dpi side's would be (within a pixel).
        XCTAssertEqual(pixel(page, 771, 302), [10, 120, 60])
        XCTAssertEqual(pixel(page, 1778, 934), [10, 120, 60])
        XCTAssertEqual(pixel(page, 767, 619), [255, 255, 255])
        XCTAssertEqual(pixel(page, 1783, 619), [255, 255, 255])
    }

    func test_composer_pageIsTheWholePaperInThePDF() throws {
        let front = solidSide(card, dpi: 100, 200, 40, 40)
        let back = solidSide(card, dpi: 100, 40, 90, 200)
        let composed = IdCardComposer.compose(front: front, back: back, dpi: 100, paperInches: letter)
        XCTAssertEqual(composed.width, 850)
        XCTAssertEqual(composed.height, 1100)
        let image = try XCTUnwrap(composed.makeCGImage())
        let data = try PDFBuilder.makePDF(pages: [ScannedPage(image: image, dpi: 100, colorMode: .color)],
                                          searchable: false, ocrLanguages: [], progress: nil)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(bounds.width), 612, accuracy: 0.5)
        XCTAssertEqual(Double(bounds.height), 792, accuracy: 0.5)
        // A4 at 300 dpi: 595.3 × 841.9 pt.
        let a4Pixels = IdCardComposer.canvasSize(paperInches: a4, dpi: 300)
        XCTAssertEqual(Double(a4Pixels.width) / 300 * 72, 595.3, accuracy: 0.5)
        XCTAssertEqual(Double(a4Pixels.height) / 300 * 72, 841.9, accuracy: 0.5)
    }

    func test_composer_sideFileNames() {
        XCTAssertEqual(IdCardComposer.sideFileBase("ID card 2026-10-19", side: .front), "ID card 2026-10-19 front")
        XCTAssertEqual(IdCardComposer.sideFileBase("ID card 2026-10-19", side: .back), "ID card 2026-10-19 back")
    }

    // MARK: Detector

    func test_score_zeroForACard_growsWithShapeAndSize() {
        XCTAssertEqual(IdCardDetector.score(region(2, 2, 3.370, 2.125), dpi: 300), 0, accuracy: 1e-9)
        // Either way round.
        XCTAssertEqual(IdCardDetector.score(region(2, 2, 2.125, 3.370), dpi: 300), 0, accuracy: 1e-9)
        let square = IdCardDetector.score(region(2, 2, 2.6, 2.6), dpi: 300)
        let photo = IdCardDetector.score(region(2, 2, 6, 4), dpi: 300)
        XCTAssertEqual(square, abs(1 - IdCardDetector.cardAspect) / IdCardDetector.cardAspect + (3.370 - 2.6) / 3.370,
                       accuracy: 1e-9)
        XCTAssertTrue(square > 0.5 && photo > 0.5)
        XCTAssertLessThan(IdCardDetector.score(region(2, 2, 3.4, 2.1), dpi: 300), 0.05)
        XCTAssertEqual(IdCardDetector.score(region(2, 2, 3, 0), dpi: 300), Double.greatestFiniteMagnitude)
    }

    func test_pickCard_takesTheRegionClosestToACard() {
        let square = region(5, 5, 2.6, 2.6)
        let cardRegion = region(2, 2, 3.36, 2.13, angle: 7)
        let passport = region(5, 2, 4.92, 3.46)
        let photo = region(4, 8, 6, 4)
        let bedSize = CGSize(width: 2550, height: 3510)
        let pick = IdCardDetector.pickCard([square, photo, cardRegion, passport], dpi: 300, imageSize: bedSize)
        XCTAssertEqual(pick.region.id, cardRegion.id)
        XCTAssertEqual(pick.kind, .card)
        XCTAssertFalse(pick.needsManualCrop)
        XCTAssertNil(pick.note)
        // A passport page qualifies on its own.
        XCTAssertEqual(IdCardDetector.pickCard([square, passport], dpi: 300, imageSize: bedSize).region.id, passport.id)
        // Equals: the first.
        let twin = region(6, 6, 3.36, 2.13, angle: 7)
        XCTAssertEqual(IdCardDetector.pickCard([cardRegion, twin], dpi: 300, imageSize: bedSize).region.id, cardRegion.id)
    }

    func test_pickCard_nothingCardSized_takesTheLargest() {
        let small = region(2, 2, 2.0, 1.6)
        let huge = region(4, 5, 7, 9)
        let pick = IdCardDetector.pickCard([small, huge], dpi: 300, imageSize: CGSize(width: 2550, height: 3510))
        XCTAssertEqual(pick.region.id, huge.id)
        XCTAssertEqual(pick.kind, .largestRegion)
        XCTAssertFalse(pick.needsManualCrop)
        XCTAssertEqual(pick.note, "This does not look like the size of an ID card. Check the crop.")
    }

    func test_pickCard_nothingFound_takesTheWholeScan() {
        let pick = IdCardDetector.pickCard([], dpi: 300, imageSize: CGSize(width: 2550, height: 3510))
        XCTAssertEqual(pick.kind, .wholeScan)
        XCTAssertTrue(pick.needsManualCrop)
        XCTAssertEqual(pick.region.center, CGPoint(x: 1275, y: 1755))
        XCTAssertEqual(pick.region.size, CGSize(width: 2550, height: 3510))
        XCTAssertEqual(pick.region.angleDegrees, 0)
        XCTAssertTrue(pick.note?.hasPrefix("No card was found") == true)
    }

    func test_pickCard_theBackFallsBackOnTheFrontsPlace() {
        let front = region(2, 2, 3.37, 2.125, angle: 4)
        let flipped = IdCardDetector.flippedInPlace(front)
        XCTAssertEqual(flipped.center, front.center)
        XCTAssertEqual(flipped.size, front.size)
        XCTAssertEqual(flipped.angleDegrees, -4)
        XCTAssertEqual(IdCardDetector.flippedInPlace(region(2, 2, 3, 2)).angleDegrees, 0)
        let bedSize = CGSize(width: 2550, height: 3510)
        let pick = IdCardDetector.pickCard([region(6, 8, 1.6, 1.6)], dpi: 300, imageSize: bedSize, fallback: flipped)
        XCTAssertEqual(pick.region.id, flipped.id)
        XCTAssertEqual(pick.kind, .frontPlace)
        XCTAssertTrue(pick.note?.hasPrefix("The card did not stand out") == true)
        // A card on the back's scan wins over the front's place.
        let cardRegion = region(3, 3, 3.37, 2.125)
        XCTAssertEqual(IdCardDetector.pickCard([cardRegion], dpi: 300, imageSize: bedSize, fallback: flipped).region.id,
                       cardRegion.id)
    }

    func test_frontPlaceOnBack_sameScan_isTheFrontFlipped() throws {
        let front = region(2, 2, 3.37, 2.125, angle: 4)
        let area = IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 2550, height: 3510), selection: nil)
        let place = try XCTUnwrap(IdCardDetector.frontPlaceOnBack(front, front: area, back: area))
        XCTAssertEqual(place.center, front.center)
        XCTAssertEqual(place.size, front.size)
        XCTAssertEqual(place.angleDegrees, -4)
        // A pixel of rounding in the scan's size does not matter.
        let rounded = IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 2551, height: 3509), selection: nil)
        XCTAssertNotNil(IdCardDetector.frontPlaceOnBack(front, front: area, back: rounded))
    }

    func test_frontPlaceOnBack_anotherResolution_isScaled() throws {
        // The front at 300 dpi, the back at 600 dpi: the place is where the card is on the 600 dpi scan.
        let front = region(2, 2, 3.37, 2.125, angle: 4)
        let at300 = IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 2550, height: 3510), selection: nil)
        let at600 = IdCardScanArea(dpi: 600, pixelSize: CGSize(width: 5100, height: 7020), selection: nil)
        let place = try XCTUnwrap(IdCardDetector.frontPlaceOnBack(front, front: at300, back: at600))
        XCTAssertEqual(Double(place.center.x), 1200, accuracy: 1e-6)
        XCTAssertEqual(Double(place.center.y), 1200, accuracy: 1e-6)
        XCTAssertEqual(Double(place.size.width), 3.37 * 600, accuracy: 1e-6)
        XCTAssertEqual(Double(place.size.height), 2.125 * 600, accuracy: 1e-6)
        XCTAssertEqual(place.angleDegrees, -4)
        // 300 → 150 dpi halves it.
        let at150 = IdCardScanArea(dpi: 150, pixelSize: CGSize(width: 1275, height: 1755), selection: nil)
        let half = try XCTUnwrap(IdCardDetector.frontPlaceOnBack(front, front: at300, back: at150))
        XCTAssertEqual(Double(half.center.x), 300, accuracy: 1e-6)
        XCTAssertEqual(Double(half.size.width), 3.37 * 150, accuracy: 1e-6)
    }

    func test_frontPlaceOnBack_anotherPartOfTheGlass_isNone() {
        let front = region(2, 2, 3.37, 2.125)
        let whole = IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 2550, height: 3510), selection: nil)
        let selected = IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 1275, height: 1755),
                                      selection: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let elsewhere = IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 1275, height: 1755),
                                       selection: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        // Another selection.
        XCTAssertNil(IdCardDetector.frontPlaceOnBack(front, front: whole, back: selected))
        XCTAssertNil(IdCardDetector.frontPlaceOnBack(front, front: selected, back: whole))
        XCTAssertNil(IdCardDetector.frontPlaceOnBack(front, front: selected, back: elsewhere))
        // The same selection.
        XCTAssertNotNil(IdCardDetector.frontPlaceOnBack(front, front: selected, back: selected))
        // A scan of another size for its resolution (the scanner cut it differently).
        XCTAssertNil(IdCardDetector.frontPlaceOnBack(
            front, front: whole, back: IdCardScanArea(dpi: 600, pixelSize: CGSize(width: 5100, height: 6600), selection: nil)))
        XCTAssertNil(IdCardDetector.frontPlaceOnBack(
            front, front: whole, back: IdCardScanArea(dpi: 300, pixelSize: CGSize(width: 2400, height: 3510), selection: nil)))
        // No resolution known.
        XCTAssertNil(IdCardDetector.frontPlaceOnBack(
            front, front: IdCardScanArea(dpi: 0, pixelSize: CGSize(width: 2550, height: 3510), selection: nil), back: whole))
    }

    func test_composer_pageResolution_isTheScansAtMost600DPI() {
        XCTAssertEqual(IdCardComposer.maxPageDPI, 600)
        XCTAssertEqual(IdCardComposer.pageDPI(300), 300)
        XCTAssertEqual(IdCardComposer.pageDPI(600), 600)
        XCTAssertEqual(IdCardComposer.pageDPI(1200), 600)
        XCTAssertEqual(IdCardComposer.pageDPI(2400), 600)
        XCTAssertEqual(IdCardComposer.pageDPI(75), 75)
        XCTAssertEqual(IdCardComposer.pageDPI(0), 1)
        // A side scanned at 2400 dpi goes on an A4 page at 600 dpi: at real size, and the page fits
        // in one image (at 2400 dpi it would be 19843 × 28063 pixels).
        let side = solidSide(CGSize(width: 1, height: 0.5), dpi: 2400, 200, 40, 40)
        let dpi = IdCardComposer.pageDPI(side.dpi)
        let page = IdCardComposer.compose(front: side, back: nil, dpi: dpi, paperInches: a4)
        let expected = IdCardComposer.canvasSize(paperInches: a4, dpi: 600)
        XCTAssertEqual(page.width, expected.width)
        XCTAssertEqual(page.height, expected.height)
        XCTAssertEqual(pixel(page, page.width / 2, 600 + 150), [200, 40, 40])
        XCTAssertEqual(pixel(page, page.width / 2 - 320, 600 + 150), [255, 255, 255])
    }

    func test_composer_pageColorMode_isWhatTheSidesWereScannedIn() {
        for mode in ColorMode.allCases {
            XCTAssertEqual(IdCardComposer.pageColorMode(front: mode, back: nil), mode)
            XCTAssertEqual(IdCardComposer.pageColorMode(front: mode, back: mode), mode)
        }
        XCTAssertEqual(IdCardComposer.pageColorMode(front: .color, back: .blackWhite), .color)
        XCTAssertEqual(IdCardComposer.pageColorMode(front: .grayscale, back: .color), .color)
        XCTAssertEqual(IdCardComposer.pageColorMode(front: .blackWhite, back: .grayscale), .grayscale)
        XCTAssertEqual(IdCardComposer.pageColorMode(front: .grayscale, back: .blackWhite), .grayscale)
    }

    func test_detectedPhoto_keepsTheColorModeItWasScannedIn() throws {
        // C# also checks DetectedPhoto.Recropped; the Mac re-crops in AppState, passing the mode on.
        let image = try XCTUnwrap(RgbaImage.filled(width: 4, height: 4, r: 255, g: 255, b: 255).makeCGImage())
        let region = DetectedPhotoRegion(center: CGPoint(x: 2, y: 2), size: CGSize(width: 4, height: 4), angleDegrees: 0)
        XCTAssertEqual(DetectedPhoto(region: region, image: image, dpi: 300).colorMode, .color)
        let photo = DetectedPhoto(region: region, image: image, dpi: 300, sourcePageID: UUID(), colorMode: .blackWhite)
        XCTAssertEqual(photo.colorMode, .blackWhite)
    }

    func test_detect_findsTheCardOnABed_atItsRealSize() throws {
        // 300 dpi, 6.5 × 6.5 in of glass: a blue card turned 7°, a 1 in square and a 2.6 in square.
        let scan = bed(dpi: 300, widthInches: 6.5, heightInches: 6.5, [
            BedItem(center: CGPoint(x: 2.3, y: 1.7), size: card, angleDegrees: 7, r: 40, g: 90, b: 160),
            BedItem(center: CGPoint(x: 1.2, y: 5.2), size: CGSize(width: 1, height: 1), angleDegrees: 0, r: 60, g: 60, b: 60),
            BedItem(center: CGPoint(x: 4.6, y: 4.8), size: CGSize(width: 2.6, height: 2.6), angleDegrees: -3, r: 170, g: 60, b: 40),
        ])
        let image = try XCTUnwrap(scan.makeCGImage())
        let pick = IdCardDetector.detect(image, dpi: 300)
        XCTAssertEqual(pick.kind, .card)
        let found = pick.region
        let longSide = Double(max(found.size.width, found.size.height)) / 300
        let shortSide = Double(min(found.size.width, found.size.height)) / 300
        XCTAssertEqual(longSide, 3.370, accuracy: 0.04)
        XCTAssertEqual(shortSide, 2.125, accuracy: 0.04)
        XCTAssertEqual(found.angleDegrees, 7, accuracy: 0.5)
        XCTAssertEqual(Double(found.center.x) / 300, 2.3, accuracy: 0.05)
        XCTAssertEqual(Double(found.center.y) / 300, 1.7, accuracy: 0.05)
        // Cut out straight: the card's own size, its color in the middle.
        let side = try XCTUnwrap(RgbaImage(cgImage: IdCardDetector.extract(image, pick: pick)))
        XCTAssertEqual(Double(side.width), 1011, accuracy: 12)
        XCTAssertEqual(Double(side.height), 638, accuracy: 12)
        let middle = pixel(side, side.width / 2, side.height / 2)
        XCTAssertEqual(Double(middle[0]), 40, accuracy: 2)
        XCTAssertEqual(Double(middle[1]), 90, accuracy: 2)
        XCTAssertEqual(Double(middle[2]), 160, accuracy: 2)
    }

    func test_detect_emptyGlass_takesTheWholeScan() throws {
        let image = try XCTUnwrap(bed(dpi: 100, widthInches: 6, heightInches: 5, []).makeCGImage())
        let pick = IdCardDetector.detect(image, dpi: 100)
        XCTAssertEqual(pick.kind, .wholeScan)
        let whole = IdCardDetector.extract(image, pick: pick)
        XCTAssertEqual(whole.width, 600)
        XCTAssertEqual(whole.height, 500)
    }
}
