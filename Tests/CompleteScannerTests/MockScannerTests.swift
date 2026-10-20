import XCTest
import CoreGraphics
@testable import CompleteScannerKit

// The demo scanner's feeder. Mirrors windows/CompleteScanner.Core.Tests/MockScannerTests.cs.

private let mockDPI = 75

/// Renders a CGImage to a tightly packed sRGB RGBA8 buffer (row 0 = top of the image).
private func rgbaPixels(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: ptr, count: width * height * 4))
}

/// Where each dark run starts along the row through the middle of the sheet marks (0.8 in
/// above the bottom edge).
private func markRuns(_ image: CGImage) -> [Int] {
    let pixels = rgbaPixels(image)
    let y = Int(Double(image.height) - 0.8 * Double(mockDPI))
    var starts: [Int] = []
    var dark = false
    for x in 0..<image.width {
        let isDark = pixels[(y * image.width + x) * 4] < 128
        if isDark && !dark { starts.append(x) }
        dark = isDark
    }
    return starts
}

/// Dark runs along the row through the middle of the sheet marks.
private func sheetMarks(_ image: CGImage) -> Int { markRuns(image).count }

/// The sheet marks sit on the left half of the page (a front) rather than the right (a back).
private func marksOnTheLeft(_ image: CGImage) -> Bool {
    guard let first = markRuns(image).first else { return false }
    return first < image.width / 2
}

private func feederSettings(intent: ScanIntent = .document, duplex: DuplexMode = .off) -> ScanSettings {
    var settings = ScanSettings()
    settings.source = .documentFeeder
    settings.resolution = mockDPI
    settings.intent = intent
    settings.duplex = duplex
    return settings
}

final class MockScannerTests: XCTestCase {

    @MainActor
    private func open() async throws -> (MockScannerBackend, any ScannerSession) {
        let backend = MockScannerBackend()
        backend.startBrowsing()
        let session = try await backend.openSession(deviceID: "mock:demo")
        return (backend, session)
    }

    @MainActor
    func test_demoScannerHasAFeeder() async throws {
        let (_, session) = try await open()
        let caps = try await session.capabilities()
        XCTAssertEqual(caps.sources, [.flatbed, .documentFeeder])
        XCTAssertEqual(caps.feederSizeInches, CGSize(width: 8.5, height: 14))
        XCTAssertTrue(caps.supportsDuplex)
        XCTAssertTrue(caps.supportsOverview)
    }

    @MainActor
    func test_demoFeederCanScanOneSideOnly() async throws {
        let (backend, session) = try await open()
        backend.feederDuplex = false
        let caps = try await session.capabilities()
        XCTAssertFalse(caps.supportsDuplex)
        // Asked for both sides anyway: the fronts, and the session says it scanned one side.
        let pages = try await session.performScan(settings: feederSettings(duplex: .both), selection: nil)
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { marksOnTheLeft($0.image) })
        XCTAssertEqual(session.lastScanDuplex, false)
    }

    @MainActor
    func test_theSessionSaysWhetherItScannedBothSides() async throws {
        let (_, session) = try await open()
        _ = try await session.performScan(settings: feederSettings(duplex: .both), selection: nil)
        XCTAssertEqual(session.lastScanDuplex, true)
        // Not asked for: nothing to say.
        _ = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        XCTAssertNil(session.lastScanDuplex)
        _ = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertNil(session.lastScanDuplex)
    }

    @MainActor
    func test_twoSidedFeederDeliversFrontBackPairs() async throws {
        let (_, session) = try await open()
        let pages = try await session.performScan(settings: feederSettings(duplex: .both), selection: nil)
        XCTAssertEqual(pages.count, 6)
        for (i, page) in pages.enumerated() {
            XCTAssertEqual(sheetMarks(page.image), i / 2 + 1)
            // Fronts carry their marks on the left, backs on the right; both upright.
            XCTAssertEqual(marksOnTheLeft(page.image), i % 2 == 0)
            XCTAssertEqual(page.image.height, 11 * mockDPI)
        }
        XCTAssertEqual(Set(pages.map(\.id)).count, 6)
    }

    @MainActor
    func test_blankBacks_lookBlank_theOtherSidesDoNot() async throws {
        let (backend, session) = try await open()
        XCTAssertTrue(backend.feederBlankBackSheets.isEmpty)
        backend.feederBlankBackSheets = [1]
        let pages = try await session.performScan(settings: feederSettings(duplex: .both), selection: nil)
        XCTAssertEqual(pages.count, 6)
        XCTAssertEqual(pages.map { BlankPageDetector.analyze($0.image, dpi: $0.dpi).isBlank },
                       [false, false, false, true, false, false])
        // The blank back is paper, not white: noise and the front showing through.
        let back = rgbaPixels(pages[3].image)
        XCTAssertEqual(sheetMarks(pages[3].image), 0)
        let reds = stride(from: 0, to: back.count, by: 4).map { Int(back[$0]) }
        let mean = Double(reds.reduce(0, +)) / Double(reds.count)
        XCTAssertGreaterThanOrEqual(mean, 225)
        XCTAssertLessThanOrEqual(mean, 250)
        XCTAssertTrue(reds.contains { $0 < 236 })
        // Deterministic: the same sheet looks the same every time.
        let again = try await session.performScan(settings: feederSettings(duplex: .both), selection: nil)
        XCTAssertEqual(rgbaPixels(again[3].image), back)
    }

    @MainActor
    func test_blankBacks_turnedOverByHand_comeInTheBacksScan() async throws {
        let (backend, session) = try await open()
        backend.feederBlankBackSheets = [0, 2]
        let fronts = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        XCTAssertTrue(fronts.allSatisfy { !BlankPageDetector.analyze($0.image, dpi: $0.dpi).isBlank })
        let backs = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        // Last sheet first: sheets 2, 1, 0.
        XCTAssertEqual(backs.map { BlankPageDetector.analyze($0.image, dpi: $0.dpi).isBlank }, [true, false, true])
        XCTAssertEqual(sheetMarks(backs[1].image), 2)
    }

    @MainActor
    func test_twoSidedJamKeepsTheSheetsBeforeIt() async throws {
        let (backend, session) = try await open()
        backend.feederJamsAfter = 1
        let pages = try await session.performScan(settings: feederSettings(duplex: .both), selection: nil)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(session.lastScanStop?.problem, ScannerProblem.paperJam)
    }

    @MainActor
    func test_turningOverByHand_theSecondScanDeliversTheBacksLastSheetFirst() async throws {
        let (backend, session) = try await open()
        let fronts = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        XCTAssertEqual(fronts.map { sheetMarks($0.image) }, [1, 2, 3])
        XCTAssertTrue(fronts.allSatisfy { marksOnTheLeft($0.image) })
        XCTAssertTrue(backend.feederStackTurnedOver)

        let backs = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        XCTAssertEqual(backs.map { sheetMarks($0.image) }, [3, 2, 1])
        XCTAssertTrue(backs.allSatisfy { !marksOnTheLeft($0.image) })
        XCTAssertFalse(backend.feederStackTurnedOver)
    }

    @MainActor
    func test_turningOverByHand_aJamLeavesTheStackAsItIs() async throws {
        let (backend, session) = try await open()
        backend.feederJamsAfter = 2
        let fronts = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        XCTAssertEqual(fronts.map { sheetMarks($0.image) }, [1, 2])
        XCTAssertNotNil(session.lastScanStop)
        // The rest of the fronts comes next, not the backs.
        XCTAssertFalse(backend.feederStackTurnedOver)
        backend.feederJamsAfter = nil
        let more = try await session.performScan(settings: feederSettings(duplex: .manual), selection: nil)
        XCTAssertTrue(more.allSatisfy { marksOnTheLeft($0.image) })
        XCTAssertTrue(backend.feederStackTurnedOver)
    }

    @MainActor
    func test_otherScansLoadTheStackTheRightWayUp() async throws {
        let (backend, session) = try await open()
        backend.feederStackTurnedOver = true
        let backs = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertTrue(backs.allSatisfy { !marksOnTheLeft($0.image) })
        XCTAssertFalse(backend.feederStackTurnedOver)
        let fronts = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertTrue(fronts.allSatisfy { marksOnTheLeft($0.image) })
    }

    @MainActor
    func test_feederScansThePaperSize() async throws {
        let (_, session) = try await open()
        var settings = feederSettings()
        settings.paperSize = .a4
        let a4 = try await session.performScan(settings: settings, selection: nil)
        for page in a4 {
            XCTAssertEqual(page.image.width, Int(8.2677 * Double(mockDPI)))
            XCTAssertEqual(page.image.height, Int(11.6929 * Double(mockDPI)))
        }
        XCTAssertEqual(sheetMarks(a4[0].image), 1)
        settings.paperSize = .legal
        let legal = try await session.performScan(settings: settings, selection: nil)
        XCTAssertTrue(legal.allSatisfy { $0.image.height == 14 * mockDPI })
    }

    @MainActor
    func test_feederScanDeliversThreeNumberedSheets() async throws {
        let (_, session) = try await open()
        let pages = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertEqual(pages.count, MockScannerBackend.defaultFeederSheetCount)
        XCTAssertEqual(pages.count, 3)
        for (i, page) in pages.enumerated() {
            XCTAssertEqual(page.dpi, mockDPI)
            XCTAssertEqual(page.image.width, Int(8.5 * Double(mockDPI)))
            XCTAssertEqual(page.image.height, 11 * mockDPI)
            XCTAssertEqual(sheetMarks(page.image), i + 1)
        }
        XCTAssertEqual(Set(pages.map(\.id)).count, 3)
    }

    @MainActor
    func test_feederIgnoresTheSelection() async throws {
        let (_, session) = try await open()
        let pages = try await session.performScan(settings: feederSettings(),
                                                  selection: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        for page in pages {
            XCTAssertEqual(page.image.height, 11 * mockDPI)
        }
    }

    @MainActor
    func test_feederPhotoSheetsHoldOnePhotoEach() async throws {
        let (_, session) = try await open()
        let pages = try await session.performScan(settings: feederSettings(intent: .photo), selection: nil)
        XCTAssertEqual(pages.count, 3)
        for page in pages {
            XCTAssertEqual(PhotoDetector.detectRegions(in: page.image, dpi: page.dpi).count, 1)
        }
    }

    @MainActor
    func test_sheetCountIsReadWhenTheScanStarts() async throws {
        let (backend, session) = try await open()
        backend.feederSheetCount = 1
        let pages = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertEqual(pages.count, 1)
    }

    @MainActor
    func test_emptyFeederAsksForPaper() async throws {
        let (backend, session) = try await open()
        backend.feederSheetCount = 0
        do {
            _ = try await session.performScan(settings: feederSettings(), selection: nil)
            XCTFail("An empty feeder must fail the scan.")
        } catch let error as ScanError {
            XCTAssertEqual(error.problem, ScannerProblem.feederEmpty)
            XCTAssertEqual(error.errorDescription, ScannerProblems.describe(.feederEmpty))
        }
    }

    @MainActor
    func test_aFullBatchHasNoStop() async throws {
        let (_, session) = try await open()
        _ = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertNil(session.lastScanStop)
    }

    @MainActor
    func test_aJamPartwayKeepsTheSheetsAndSaysWhy() async throws {
        let (backend, session) = try await open()
        backend.feederJamsAfter = 2
        let pages = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(sheetMarks(pages[0].image), 1)
        XCTAssertEqual(sheetMarks(pages[1].image), 2)
        let stop = try XCTUnwrap(session.lastScanStop)
        XCTAssertEqual(stop.problem, ScannerProblem.paperJam)
        XCTAssertEqual(stop.reason, ScannerProblems.describe(.paperJam))
    }

    @MainActor
    func test_aJamOnTheFirstSheetFailsTheScan() async throws {
        let (backend, session) = try await open()
        backend.feederJamsAfter = 0
        do {
            _ = try await session.performScan(settings: feederSettings(), selection: nil)
            XCTFail("A jam on the first sheet must fail the scan.")
        } catch let error as ScanError {
            XCTAssertEqual(error.problem, ScannerProblem.paperJam)
        }
        XCTAssertNil(session.lastScanStop)
    }

    @MainActor
    func test_theNextScanClearsTheStop() async throws {
        let (backend, session) = try await open()
        backend.feederJamsAfter = 1
        let jammed = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertEqual(jammed.count, 1)
        XCTAssertNotNil(session.lastScanStop)
        backend.feederJamsAfter = nil
        let full = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertEqual(full.count, 3)
        XCTAssertNil(session.lastScanStop)
    }

    @MainActor
    func test_flatbedStillScansOneBed() async throws {
        let (_, session) = try await open()
        var settings = ScanSettings()
        settings.resolution = mockDPI
        let pages = try await session.performScan(settings: settings, selection: nil)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.image.height, Int(11.7 * Double(mockDPI)))
    }

    // MARK: ID card

    private func idCardSettings(dpi: Int) -> ScanSettings {
        var settings = TaskCatalog.apply(.idCard, to: ScanSettings())
        settings.resolution = dpi
        return settings
    }

    @MainActor
    func test_idCardScansTurnTheSampleCardOver() async throws {
        let (backend, session) = try await open()
        XCTAssertFalse(backend.idCardTurnedOver)
        // A preview shows the side facing the glass without turning the card.
        let preview = try await session.performOverviewScan(settings: idCardSettings(dpi: mockDPI))
        XCTAssertFalse(backend.idCardTurnedOver)
        let first = try await session.performScan(settings: idCardSettings(dpi: mockDPI), selection: nil)
        let front = try XCTUnwrap(first.first).image
        XCTAssertTrue(backend.idCardTurnedOver)
        let second = try await session.performScan(settings: idCardSettings(dpi: mockDPI), selection: nil)
        let back = try XCTUnwrap(second.first).image
        XCTAssertFalse(backend.idCardTurnedOver)
        let third = try await session.performScan(settings: idCardSettings(dpi: mockDPI), selection: nil)
        let frontAgain = try XCTUnwrap(third.first).image
        XCTAssertEqual(front.width, back.width)
        XCTAssertEqual(front.height, back.height)
        XCTAssertEqual(front.height, Int(11.7 * Double(mockDPI)))
        XCTAssertNotEqual(rgbaPixels(front), rgbaPixels(back))
        XCTAssertEqual(rgbaPixels(front), rgbaPixels(frontAgain))
        XCTAssertEqual(preview.height, Int(11.7 * 100.0))
        // Other scans do not touch the card.
        var plain = ScanSettings()
        plain.resolution = mockDPI
        _ = try await session.performScan(settings: plain, selection: nil)
        XCTAssertTrue(backend.idCardTurnedOver)
    }

    @MainActor
    func test_theSampleCardIsFoundAtIdOneSize() async throws {
        let (_, session) = try await open()
        for angle in [4.0, -4.0] {
            let pages = try await session.performScan(settings: idCardSettings(dpi: 150), selection: nil)
            let scan = try XCTUnwrap(pages.first)
            let pick = IdCardDetector.detect(scan.image, dpi: 150)
            XCTAssertEqual(pick.kind, .card)
            let longSide = Double(max(pick.region.size.width, pick.region.size.height)) / 150
            let shortSide = Double(min(pick.region.size.width, pick.region.size.height)) / 150
            XCTAssertEqual(longSide, 3.370, accuracy: 0.05)
            XCTAssertEqual(shortSide, 2.125, accuracy: 0.05)
            XCTAssertEqual(pick.region.angleDegrees, angle, accuracy: 0.5)
            XCTAssertEqual(Double(pick.region.center.x) / 150, 2.35, accuracy: 0.05)
            XCTAssertEqual(Double(pick.region.center.y) / 150, 1.75, accuracy: 0.05)
        }
    }

    // MARK: - Receipts

    @MainActor
    func test_theDemoReceiptsAreFoundApart_alongTheirPaper() async throws {
        let (_, session) = try await open()
        var settings = TaskCatalog.apply(.receipt, to: ScanSettings())
        settings.resolution = 150
        let preview = try await session.performOverviewScan(settings: settings)
        XCTAssertEqual(preview.height, Int(11.7 * 100.0))
        let pages = try await session.performScan(settings: settings, selection: nil)
        let scan = try XCTUnwrap(pages.first)
        let image = try XCTUnwrap(RgbaImage(cgImage: scan.image))
        let found = ReceiptDetector.find(image, dpi: 150)
        let places = MockScannerBackend.demoReceiptPlaces
        XCTAssertEqual(found.count, places.count)
        for (receipt, place) in zip(found, places) {
            let region = receipt.region
            XCTAssertEqual(receipt.basis, .paper)
            XCTAssertEqual(Double(region.center.x) / 150, Double(place.centerInches.x), accuracy: 0.05)
            XCTAssertEqual(Double(region.center.y) / 150, Double(place.centerInches.y), accuracy: 0.05)
            XCTAssertEqual(Double(region.size.width) / 150, Double(place.sizeInches.width), accuracy: 0.08)
            XCTAssertEqual(Double(region.size.height) / 150, Double(place.sizeInches.height), accuracy: 0.08)
            XCTAssertEqual(region.angleDegrees, place.angleDegrees, accuracy: 0.5)
        }
        // Other tasks keep the usual bed.
        var plain = ScanSettings()
        plain.resolution = 150
        let documentPages = try await session.performScan(settings: plain, selection: nil)
        let document = try XCTUnwrap(documentPages.first)
        XCTAssertNotEqual(rgbaPixels(scan.image), rgbaPixels(document.image))
    }

    // MARK: - Batch of separate documents

    @MainActor
    func test_theBatchStack_hasSeparatorSheetsTheSplitterFinds() async throws {
        let (backend, session) = try await open()
        XCTAssertEqual(backend.batchSheetCount, MockScannerBackend.defaultBatchSheetCount)
        XCTAssertEqual(backend.batchSeparatorSheets, [2, 4])
        var settings = TaskCatalog.apply(.batch, to: ScanSettings())
        settings.resolution = mockDPI
        let pages = try await session.performScan(settings: settings, selection: nil)
        XCTAssertEqual(pages.count, 7)
        XCTAssertEqual(pages.map { PatchCodeDetector.detect($0.image, dpi: $0.dpi)?.code },
                       [nil, nil, .patchT, nil, .patchT, nil, nil])
        // The documents' sheets keep their numbers.
        XCTAssertEqual([0, 1, 3, 5, 6].map { sheetMarks(pages[$0].image) }, [1, 2, 4, 6, 7])
        // Through the page processor and the splitter: three documents of two, one and two sheets.
        let processed = try PageProcessor.forScan(settings).process(pages).pages
        XCTAssertEqual(DocumentSplitter.plan(processed, options: settings.document).documents.map(\.pages),
                       [[0, 1], [3], [5, 6]])
        // Both sides: a separator's back is blank paper, and the whole sheet is left out.
        settings.duplex = .both
        let scanned = try await session.performScan(settings: settings, selection: nil)
        let twoSided = try PageProcessor.forScan(settings, arrangement: .twoSided).process(scanned).pages
        XCTAssertEqual(twoSided.count, 14)
        XCTAssertEqual(twoSided[5].blank?.isBlank, true)
        XCTAssertEqual(DocumentSplitter.plan(twoSided, options: settings.document).documents.map(\.pages),
                       [[0, 1, 2, 3], [6, 7], [10, 11, 12, 13]])
    }

    @MainActor
    func test_otherTasks_keepTheUsualStack() async throws {
        let (backend, session) = try await open()
        backend.batchSheetCount = 2
        let pages = try await session.performScan(settings: feederSettings(), selection: nil)
        XCTAssertEqual(pages.count, 3)
        for page in pages {
            XCTAssertNil(PatchCodeDetector.detect(page.image, dpi: page.dpi))
        }
        var batch = TaskCatalog.apply(.batch, to: ScanSettings())
        batch.resolution = mockDPI
        let batchPages = try await session.performScan(settings: batch, selection: nil)
        XCTAssertEqual(batchPages.count, 2)
    }

    // MARK: - Book or magazine

    @MainActor
    func test_theDemoBook_turnsItsPageAfterEveryScan_andSplitsAtItsSpine() async throws {
        let (backend, session) = try await open()
        XCTAssertEqual(backend.bookSpread, 0)
        var settings = TaskCatalog.apply(.book, to: ScanSettings())
        settings.resolution = 150
        // A preview shows the spread without turning the page.
        let preview = try await session.performOverviewScan(settings: settings)
        XCTAssertEqual(preview.height, Int(11.7 * 100.0))
        XCTAssertEqual(backend.bookSpread, 0)
        let firstPages = try await session.performScan(settings: settings, selection: nil)
        let first = try XCTUnwrap(firstPages.first)
        XCTAssertEqual(backend.bookSpread, 1)
        let secondPages = try await session.performScan(settings: settings, selection: nil)
        let second = try XCTUnwrap(secondPages.first)
        XCTAssertEqual(backend.bookSpread, 2)
        XCTAssertNotEqual(rgbaPixels(first.image), rgbaPixels(second.image))
        // The spine is found where the demo book has it, by its shadow.
        let spine = MockScannerBackend.demoBookGutterFraction * Double(first.image.width)
        let gutter = try XCTUnwrap(BookSplitter.findGutter(first.image, dpi: 150))
        XCTAssertEqual(gutter.axis, .vertical)
        XCTAssertEqual(gutter.kind, .shadow)
        XCTAssertEqual(Double(gutter.position), spine, accuracy: 0.05 * 150)
        // Through the page processor: two pages each, cut at the spine, the left page first.
        let processed = try PageProcessor.forScan(settings).process([first, second])
        XCTAssertEqual(processed.pages.count, 4)
        XCTAssertEqual(Double(processed.pages[0].image.width), spine, accuracy: 0.05 * 150)
        XCTAssertEqual(processed.pages[0].image.width + processed.pages[1].image.width, first.image.width)
        XCTAssertEqual(processed.pages.map { $0.spread?.part }, [0, 1, 0, 1])
        XCTAssertEqual(processed.pages.compactMap(\.spreadID), [first.id, first.id, second.id, second.id])
        // Other scans leave the book where it is.
        var plain = ScanSettings()
        plain.resolution = mockDPI
        _ = try await session.performScan(settings: plain, selection: nil)
        XCTAssertEqual(backend.bookSpread, 2)
    }
}
