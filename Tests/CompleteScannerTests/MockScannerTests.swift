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
}
