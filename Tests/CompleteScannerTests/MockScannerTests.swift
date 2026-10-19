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

/// Dark runs along the row through the middle of the sheet marks (0.8 in above the bottom edge).
private func sheetMarks(_ image: CGImage) -> Int {
    let pixels = rgbaPixels(image)
    let y = Int((11 - 0.8) * Double(mockDPI))
    var runs = 0
    var dark = false
    for x in 0..<image.width {
        let isDark = pixels[(y * image.width + x) * 4] < 128
        if isDark && !dark { runs += 1 }
        dark = isDark
    }
    return runs
}

private func feederSettings(intent: ScanIntent = .document) -> ScanSettings {
    var settings = ScanSettings()
    settings.source = .documentFeeder
    settings.resolution = mockDPI
    settings.intent = intent
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
        XCTAssertEqual(caps.feederSizeInches, CGSize(width: 8.5, height: 11))
        XCTAssertFalse(caps.supportsDuplex)
        XCTAssertTrue(caps.supportsOverview)
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
