import XCTest
import CoreGraphics
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/DocumentSidesTests.cs: the same cases.

private func rows(_ transfers: [SidedTransfer]) -> [String] {
    transfers.map { "\($0.transferIndex) \($0.sheetIndex) \($0.side.rawValue)" }
}

private func rows(_ interleave: ManualInterleave) -> [String] {
    interleave.order.map { "\($0.batch.rawValue) \($0.index) \($0.sheetIndex)" }
}

/// A 2 × 1 page: red on the left, blue on the right, so a half turn shows.
private func twoPixelPage(fileURL: URL? = nil) -> ScannedPage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    return ScannedPage(image: ctx.makeImage()!, dpi: 100, colorMode: .color, fileURL: fileURL,
                       fullPixelSize: fileURL == nil ? nil : CGSize(width: 2, height: 1))
}

/// The leftmost pixel is red (the page is the right way round).
private func redOnTheLeft(_ page: ScannedPage) -> Bool {
    let image = page.image
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return pixels[0] > 200 && pixels[2] < 50
}

private func feeder(_ duplex: DuplexMode) -> ScanSettings {
    var settings = ScanSettings()
    settings.source = .documentFeeder
    settings.duplex = duplex
    return settings
}

final class DocumentSidesTests: XCTestCase {

    // MARK: Sides of a feeder scan

    func test_assignSides_oneSided_everyTransferIsTheFrontOfItsSheet() {
        XCTAssertEqual(rows(DocumentSides.assignSides(transferCount: 3, duplex: false)),
                       ["0 0 front", "1 1 front", "2 2 front"])
    }

    func test_assignSides_twoSided_sixTransfersAreThreeSheets() {
        XCTAssertEqual(rows(DocumentSides.assignSides(transferCount: 6, duplex: true)),
                       ["0 0 front", "1 0 back", "2 1 front", "3 1 back", "4 2 front", "5 2 back"])
    }

    func test_assignSides_twoSided_oddCountEndsWithAFrontOnly() {
        let sides = DocumentSides.assignSides(transferCount: 5, duplex: true)
        XCTAssertEqual(sides.count, 5)
        XCTAssertEqual(rows(sides).last, "4 2 front")
        XCTAssertEqual(Set(sides.map(\.sheetIndex)).count, 3)
    }

    func test_assignSides_reverseOrder_numbersTheSheetsFromTheEnd() {
        XCTAssertEqual(rows(DocumentSides.assignSides(transferCount: 4, duplex: true, reverseOrder: true)),
                       ["2 0 front", "3 0 back", "0 1 front", "1 1 back"])
        XCTAssertEqual(rows(DocumentSides.assignSides(transferCount: 3, duplex: false, reverseOrder: true)),
                       ["2 0 front", "1 1 front", "0 2 front"])
    }

    func test_assignSides_nothingScanned() {
        XCTAssertTrue(DocumentSides.assignSides(transferCount: 0, duplex: true).isEmpty)
        XCTAssertTrue(DocumentSides.assignSides(transferCount: -2, duplex: false).isEmpty)
    }

    // MARK: Turning the stack over by hand

    func test_interleaveManual_threeAndThree_theBacksComeLastSheetFirst() {
        let result = DocumentSides.interleaveManual(fronts: 3, backs: 3)
        XCTAssertEqual(rows(result), ["front 0 0", "back 2 0", "front 1 1", "back 1 1", "front 2 2", "back 0 2"])
        XCTAssertFalse(result.mismatch)
        XCTAssertNil(result.mismatchMessage)
    }

    func test_interleaveManual_backsInScanOrder() {
        XCTAssertEqual(rows(DocumentSides.interleaveManual(fronts: 2, backs: 2, backsReversed: false)),
                       ["front 0 0", "back 0 0", "front 1 1", "back 1 1"])
    }

    func test_interleaveManual_threeFrontsTwoBacks_pairsWhatItCanAndSaysSo() {
        let result = DocumentSides.interleaveManual(fronts: 3, backs: 2)
        XCTAssertEqual(rows(result), ["front 0 0", "back 1 0", "front 1 1", "back 0 1", "front 2 2"])
        XCTAssertTrue(result.mismatch)
        XCTAssertEqual(result.mismatchMessage, "3 fronts but 2 backs")
    }

    func test_interleaveManual_moreBacksThanFronts_theExtraBacksComeLast() {
        let result = DocumentSides.interleaveManual(fronts: 2, backs: 3)
        XCTAssertEqual(rows(result), ["front 0 0", "back 2 0", "front 1 1", "back 1 1", "back 0 2"])
        XCTAssertEqual(result.mismatchMessage, "2 fronts but 3 backs")
    }

    func test_interleaveManual_noBacks() {
        let result = DocumentSides.interleaveManual(fronts: 2, backs: 0)
        XCTAssertEqual(rows(result), ["front 0 0", "front 1 1"])
        XCTAssertEqual(result.mismatchMessage, "2 fronts but 0 backs")
    }

    func test_countMessage_singularAndPlural() {
        XCTAssertEqual(DocumentSides.countMessage(fronts: 12, backs: 11), "12 fronts but 11 backs")
        XCTAssertEqual(DocumentSides.countMessage(fronts: 1, backs: 2), "1 front but 2 backs")
        XCTAssertEqual(DocumentSides.countMessage(fronts: 2, backs: 1), "2 fronts but 1 back")
    }

    func test_sideLabel() {
        XCTAssertEqual(DocumentSides.sideLabel(side: .back, sheetIndex: 1), "2 \u{00B7} back")
        XCTAssertEqual(DocumentSides.sideLabel(side: .front, sheetIndex: 0), "1 \u{00B7} front")
        XCTAssertEqual(DocumentSides.sideLabel(side: .front, sheetIndex: nil), "Front")
        XCTAssertEqual(DocumentSides.sideLabel(side: .back, sheetIndex: nil), "Back")
        XCTAssertNil(DocumentSides.sideLabel(side: nil, sheetIndex: 3))
    }

    func test_sideName_spellsTheSheetOut() {
        XCTAssertEqual(DocumentSides.sideName(side: .back, sheetIndex: 1), "Sheet 2, back")
        XCTAssertEqual(DocumentSides.sideName(side: .front, sheetIndex: 0), "Sheet 1, front")
        XCTAssertEqual(DocumentSides.sideName(side: .front, sheetIndex: nil), "Front")
        XCTAssertEqual(DocumentSides.sideName(side: .back, sheetIndex: nil), "Back")
        XCTAssertNil(DocumentSides.sideName(side: nil, sheetIndex: 3))
        XCTAssertEqual(DocumentSides.needsFeederReason, "Needs the feeder")
        XCTAssertEqual(DocumentSides.feederOnlyReason, "Two-sided scanning uses the document feeder.")
    }

    func test_backQuarterTurns_shortEdgeBacksAreUpsideDown() {
        XCTAssertEqual(DocumentSides.backQuarterTurns(.longEdge), 0)
        XCTAssertEqual(DocumentSides.backQuarterTurns(.shortEdge), 2)
    }

    func test_manualSteps_frontsThenBacks() {
        let steps = DocumentSides.manualSteps
        XCTAssertEqual(steps.map(\.id), [DocumentSides.frontsStepID, DocumentSides.backsStepID])
        XCTAssertEqual(steps.map(\.id), ["fronts", "backs"])
        XCTAssertEqual(steps.map(\.primaryActionLabel), ["Scan fronts", "Scan backs"])
        XCTAssertTrue(steps.allSatisfy(\.repeats))
        XCTAssertTrue(steps[0].requiresCapture)
        XCTAssertFalse(steps[0].skippable)
        XCTAssertFalse(steps[1].requiresCapture)
        XCTAssertTrue(steps[1].skippable)
        XCTAssertEqual(steps[0].prompt, "Load the stack in the feeder and scan the fronts.")
        XCTAssertEqual(steps[1].prompt, "Turn the stack over, load it again and scan.")
        XCTAssertTrue(steps[1].help.contains("turn it over"))
        XCTAssertEqual(steps.map(\.word), ["Front", "Back"])
        for step in steps {
            XCTAssertTrue((1...10).contains(StatusLine.words(step.prompt)), step.prompt)
        }
    }

    // MARK: What a scan does with the settings

    func test_effective_onlyTheFeederScansTwoSided() {
        var flatbed = ScanSettings()
        flatbed.duplex = .both
        XCTAssertEqual(DocumentSides.effective(flatbed, capabilities: nil), .off)
        flatbed.duplex = .manual
        XCTAssertEqual(DocumentSides.effective(flatbed, capabilities: nil), .off)
        XCTAssertEqual(DocumentSides.effective(feeder(.off), capabilities: nil), .off)
    }

    func test_effective_aOneSidedFeederTurnsTheStackOverByHand() {
        let oneSided = ScannerCapabilities(sources: [.documentFeeder], supportsDuplex: false)
        let twoSided = ScannerCapabilities(sources: [.documentFeeder], supportsDuplex: true)
        XCTAssertEqual(DocumentSides.effective(feeder(.both), capabilities: nil), .both)
        XCTAssertEqual(DocumentSides.effective(feeder(.both), capabilities: twoSided), .both)
        XCTAssertEqual(DocumentSides.effective(feeder(.both), capabilities: oneSided), .manual)
        XCTAssertEqual(DocumentSides.effective(feeder(.manual), capabilities: twoSided), .manual)
    }

    func test_capabilitiesForSides_aFeederNotYetAskedIsTakenToScanBothSides() {
        let unknown = ScannerCapabilities(supportedResolutions: [150, 300], sources: [.flatbed, .documentFeeder],
                                          feederSizeInches: CGSize(width: 8.5, height: 14), supportsDuplex: false)
        let assumed = DocumentSides.capabilitiesForSides(unknown, duplexKnown: false)
        XCTAssertNotNil(assumed)
        XCTAssertEqual(assumed?.supportsDuplex, true)
        XCTAssertEqual(assumed?.sources, unknown.sources)
        XCTAssertEqual(assumed?.supportedResolutions, unknown.supportedResolutions)
        XCTAssertEqual(assumed?.feederSizeInches, unknown.feederSizeInches)
        XCTAssertEqual(DocumentSides.effective(feeder(.both), capabilities: assumed), .both)
        XCTAssertFalse(DocumentSides.usesManualSteps(feeder(.both), capabilities: assumed))

        // Known: as reported.
        XCTAssertEqual(DocumentSides.capabilitiesForSides(unknown, duplexKnown: true), unknown)
        XCTAssertEqual(DocumentSides.effective(feeder(.both),
                                               capabilities: DocumentSides.capabilitiesForSides(unknown, duplexKnown: true)),
                       .manual)
        // Nothing to assume without a feeder or capabilities.
        let flatbed = ScannerCapabilities(sources: [.flatbed])
        XCTAssertEqual(DocumentSides.capabilitiesForSides(flatbed, duplexKnown: false), flatbed)
        XCTAssertNil(DocumentSides.capabilitiesForSides(nil, duplexKnown: false))
    }

    func test_usesManualSteps_documentsCollectedIntoOnePDF() {
        let oneSided = ScannerCapabilities(sources: [.documentFeeder])
        XCTAssertTrue(DocumentSides.usesManualSteps(feeder(.manual), capabilities: nil))
        XCTAssertTrue(DocumentSides.usesManualSteps(feeder(.both), capabilities: oneSided))
        XCTAssertFalse(DocumentSides.usesManualSteps(feeder(.both), capabilities: nil))
        var flatbed = ScanSettings()
        flatbed.duplex = .manual
        XCTAssertFalse(DocumentSides.usesManualSteps(flatbed, capabilities: nil))

        var photos = feeder(.manual)
        photos.intent = .photo
        XCTAssertFalse(DocumentSides.usesManualSteps(photos, capabilities: nil))
        XCTAssertEqual(DocumentSides.manualUnavailableReason(photos),
                       "Turning the stack over by hand works for documents, not photos.")

        var eachSaved = feeder(.manual)
        eachSaved.documentMultiPage = false
        XCTAssertFalse(DocumentSides.usesManualSteps(eachSaved, capabilities: nil))
        XCTAssertEqual(DocumentSides.manualUnavailableReason(eachSaved),
                       "Turning the stack over by hand needs \u{201C}Collect pages, then Save PDF\u{201D}.")
        // The switch it names reads as the format saves the collected pages.
        eachSaved.format = .word
        XCTAssertEqual(DocumentSides.manualUnavailableReason(eachSaved),
                       "Turning the stack over by hand needs \u{201C}Collect pages, then Save Word\u{201D}.")
        eachSaved.format = .text
        XCTAssertEqual(DocumentSides.manualUnavailableReason(eachSaved),
                       "Turning the stack over by hand needs \u{201C}Collect pages, then Save Text\u{201D}.")
        eachSaved.format = .jpeg
        XCTAssertEqual(DocumentSides.manualUnavailableReason(eachSaved),
                       "Turning the stack over by hand needs \u{201C}Collect pages, then Save PDF\u{201D}.")
        XCTAssertNil(DocumentSides.manualUnavailableReason(feeder(.manual)))

        // The Copy task is in Document mode, yet copies are made from one side of each sheet.
        var copySettings = TaskCatalog.apply(.copy, to: ScanSettings())
        copySettings.source = .documentFeeder
        copySettings.duplex = .manual
        XCTAssertEqual(TaskCatalog.flow(of: copySettings), .copy)
        XCTAssertFalse(DocumentSides.usesManualSteps(copySettings, capabilities: nil))
        XCTAssertEqual(DocumentSides.manualUnavailableReason(copySettings),
                       "Copies are made from one side of each sheet; turn the stack over and copy again.")
    }

    // MARK: Pages

    func test_arrangeTwoSided_marksSidesAndTurnsShortEdgeBacksUpright() {
        let pages = (0..<4).map { _ in twoPixelPage() }
        let arranged = DocumentSides.arrangeTwoSided(pages, binding: .shortEdge)
        XCTAssertEqual(arranged.map(\.id), pages.map(\.id))
        XCTAssertEqual(arranged.map(\.side), [.front, .back, .front, .back])
        XCTAssertEqual(arranged.map(\.sheetIndex), [0, 0, 1, 1])
        XCTAssertEqual(arranged.map(redOnTheLeft), [true, false, true, false])
        XCTAssertTrue(arranged.allSatisfy { $0.rotationQuarterTurns == 0 })
        // The input is not changed.
        XCTAssertTrue(pages.allSatisfy { $0.side == nil && redOnTheLeft($0) })

        let longEdge = DocumentSides.arrangeTwoSided(pages, binding: .longEdge)
        XCTAssertTrue(longEdge.allSatisfy(redOnTheLeft))
    }

    func test_arrangeTwoSided_reverseOrder() {
        let pages = (0..<4).map { _ in twoPixelPage() }
        let arranged = DocumentSides.arrangeTwoSided(pages, binding: .longEdge, reverseOrder: true)
        XCTAssertEqual(arranged.map(\.id), [pages[2].id, pages[3].id, pages[0].id, pages[1].id])
        XCTAssertEqual(arranged.map(\.sheetIndex), [0, 0, 1, 1])
    }

    func test_markManual_backsAreTurnedUpright_theirSheetsComeLater() {
        let pages = [twoPixelPage(), twoPixelPage()]
        let backs = DocumentSides.markManual(pages, side: .back, binding: .shortEdge)
        XCTAssertTrue(backs.allSatisfy { $0.side == .back && $0.sheetIndex == nil && !redOnTheLeft($0) })
        let fronts = DocumentSides.markManual(pages, side: .front, binding: .shortEdge)
        XCTAssertTrue(fronts.allSatisfy { $0.side == .front && redOnTheLeft($0) })
        let longEdge = DocumentSides.markManual(pages, side: .back, binding: .longEdge)
        XCTAssertTrue(longEdge.allSatisfy(redOnTheLeft))
    }

    func test_markCamera_marksTheSide_keepsTheSheet_andNeverTurnsABack() {
        let pages: [ScannedPage] = [twoPixelPage(), twoPixelPage().withSide(nil, sheetIndex: 4)]
        let backs: [ScannedPage] = DocumentSides.markCamera(pages, side: .back)
        XCTAssertEqual(backs.map(\.side), [.back, .back])
        XCTAssertEqual(backs.map(\.sheetIndex), [nil, 4])
        XCTAssertEqual(backs.map(\.id), pages.map(\.id))
        // The user turned the sheet over: the binding has no say, the picture stays as taken.
        XCTAssertTrue(backs.allSatisfy { redOnTheLeft($0) && $0.rotationQuarterTurns == 0 })
        let fronts: [ScannedPage] = DocumentSides.markCamera(pages, side: .front)
        XCTAssertTrue(fronts.allSatisfy { $0.side == .front && redOnTheLeft($0) })
        XCTAssertTrue(pages.allSatisfy { $0.side == nil })
    }

    func test_markManual_aSpooledBackTurnsItsPreviewNowAndItsFileWhenSaved() throws {
        let url = URL(fileURLWithPath: "/tmp/page.tiff")
        let back = try XCTUnwrap(DocumentSides.markManual([twoPixelPage(fileURL: url)], side: .back,
                                                          binding: .shortEdge).first)
        XCTAssertFalse(redOnTheLeft(back))
        XCTAssertEqual(back.rotationQuarterTurns, 2)
        XCTAssertEqual(back.fileURL, url)
        XCTAssertEqual(back.fullPixelSize, CGSize(width: 2, height: 1))
    }

    func test_collateQueue_theStackTakesThePlaceOfItsFirstPage() {
        let ids = (0..<8).map { _ in UUID() }
        let (x, f0, f1, f2, y, b0, b1, b2) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7])
        let collation = DocumentSides.collateQueue([x, f0, f1, f2, y, b0, b1, b2], fronts: [f0, f1, f2], backs: [b0, b1, b2])
        XCTAssertEqual(collation.order, [x, f0, b2, f1, b1, f2, b0, y])
        XCTAssertEqual(collation.positions[f0], SheetPosition(sheetIndex: 0, side: .front))
        XCTAssertEqual(collation.positions[b2], SheetPosition(sheetIndex: 0, side: .back))
        XCTAssertEqual(collation.positions[b0], SheetPosition(sheetIndex: 2, side: .back))
        XCTAssertNil(collation.positions[x])
        XCTAssertFalse(collation.interleave.mismatch)
    }

    func test_collateQueue_pagesNoLongerQueuedAreLeftOut_andAMismatchIsReported() {
        let (f0, f1, gone, b0) = (UUID(), UUID(), UUID(), UUID())
        let collation = DocumentSides.collateQueue([f0, f1, b0], fronts: [f0, f1, gone], backs: [b0])
        XCTAssertEqual(collation.order, [f0, b0, f1])
        XCTAssertTrue(collation.interleave.mismatch)
        XCTAssertEqual(collation.interleave.mismatchMessage, "2 fronts but 1 back")
        XCTAssertEqual(collation.positions[f1], SheetPosition(sheetIndex: 1, side: .front))
    }

    // MARK: Page facts survive rebuilding the page

    func test_withImage_keepsTheIdentityAndWhatTheScanRecorded() {
        var page = twoPixelPage().withSide(.back, sheetIndex: 4)
        page.rotationQuarterTurns = 3
        let other = twoPixelPage().image
        let url = URL(fileURLWithPath: "/tmp/spool.tiff")
        let rebuilt = page.withImage(other, colorMode: .grayscale, fileURL: url, fullPixelSize: CGSize(width: 10, height: 20))
        XCTAssertEqual(rebuilt.id, page.id)
        XCTAssertEqual(rebuilt.dpi, page.dpi)
        XCTAssertEqual(rebuilt.createdAt, page.createdAt)
        XCTAssertEqual(rebuilt.rotationQuarterTurns, 3)
        XCTAssertEqual(rebuilt.side, .back)
        XCTAssertEqual(rebuilt.sheetIndex, 4)
        XCTAssertTrue(rebuilt.image === other)
        XCTAssertEqual(rebuilt.colorMode, .grayscale)
        XCTAssertEqual(rebuilt.fileURL, url)
        XCTAssertEqual(rebuilt.fullPixelSize, CGSize(width: 10, height: 20))
        // Without a color mode or file: the page's color mode, no file.
        let plain = page.withImage(other)
        XCTAssertEqual(plain.colorMode, .color)
        XCTAssertNil(plain.fileURL)
        XCTAssertNil(plain.fullPixelSize)
    }

    func test_copyMeta_keepsTheSides() {
        let source = twoPixelPage().withSide(.front, sheetIndex: 2)
        let copy = twoPixelPage().copyMeta(from: source)
        XCTAssertEqual(copy.side, .front)
        XCTAssertEqual(copy.sheetIndex, 2)
        XCTAssertNil(twoPixelPage().side)
        XCTAssertNil(source.withSide(nil, sheetIndex: nil).sheetIndex)
    }
}
