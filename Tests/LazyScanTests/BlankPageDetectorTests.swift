import XCTest
@testable import LazyScanKit

// Twin of windows/LazyScan.Core.Tests/BlankPageDetectorTests.cs: same pages, same expectations.

final class BlankPageDetectorTests: XCTestCase {
    private let levels: [BlankSensitivity] = [.low, .medium, .high]

    private func check(_ page: GrayImage, _ sensitivity: BlankSensitivity = .medium) -> BlankPageResult {
        BlankPageDetector.analyze(page, options: BlankPageOptions(sensitivity: sensitivity))
    }

    func test_fixtures_areTheSameBytesOnBothPlatforms() {
        // FNV-1a of each page; TestPages.cs gives the same numbers.
        XCTAssertEqual(TestPages.all().map { TestPages.checksum($0.page) },
                       [0xB28D_863D, 0xC790_1B30, 0x41EC_9527, 0x7F42_A318,
                        0xD7C4_DB8C, 0xC37B_1A14, 0x0E42_C008, 0xC739_A64F])
    }

    func test_blankPagesAsScannersDeliverThem_areBlankAtEveryLevel() {
        for page in [TestPages.cleanBlank(), TestPages.noisyBlank(), TestPages.showThrough()] {
            for level in levels {
                let result = check(page, level)
                XCTAssertTrue(result.isBlank, "\(level): coverage \(result.inkCoverage)")
                XCTAssertFalse(result.hasLargeDarkArea)
            }
        }
    }

    func test_cleanPaper_hasNoInkAtAll() {
        let result = check(TestPages.cleanBlank())
        XCTAssertEqual(result.inkCoverage, 0)
        XCTAssertEqual(result.inkComponents, 0)
    }

    func test_dustNoiseShadowsHolesAndShowThrough_addNoInk() {
        // Specks are smaller than a mark, the shadow and holes are in the margin, show-through and
        // the gradient are lighter than ink.
        XCTAssertLessThan(check(TestPages.noisyBlank()).inkCoverage, 0.00002)
        XCTAssertEqual(check(TestPages.showThrough()).inkCoverage, 0)
    }

    func test_pagesWithLittleOnThem_areNeverBlank() {
        for page in [TestPages.oneTextLine(), TestPages.signature(), TestPages.photo(), TestPages.tintedWithText()] {
            for level in levels {
                let result = check(page, level)
                XCTAssertFalse(result.isBlank, "\(level): coverage \(result.inkCoverage)")
            }
        }
    }

    func test_oneTextLineAndASignature_coverMoreThanTheHighestThreshold() {
        for page in [TestPages.oneTextLine(), TestPages.signature()] {
            let coverage = check(page).inkCoverage
            XCTAssertGreaterThanOrEqual(coverage, 0.0015)
            XCTAssertLessThanOrEqual(coverage, 0.004)
        }
        XCTAssertGreaterThan(check(TestPages.oneTextLine()).inkComponents, 50)
    }

    func test_aLonePageNumber_isBlankAtMediumAndHigh_butNotAtLow() {
        let page = TestPages.pageNumber()
        let medium = check(page)
        XCTAssertTrue(medium.isBlank)
        XCTAssertGreaterThanOrEqual(medium.inkCoverage, 0.0001)
        XCTAssertLessThanOrEqual(medium.inkCoverage, 0.0003)
        XCTAssertEqual(medium.inkComponents, 2)
        XCTAssertFalse(check(page, .low).isBlank)
        XCTAssertTrue(check(page, .high).isBlank)
    }

    func test_aThinSlantedPencilNote_isOneMarkPerStroke_notDust() {
        // Four zigzag lines one pixel wide at 55 % of the paper: each step is diagonal, so the
        // strokes only hold together 8-connected.
        let page = TestPages.noisy(0x009E_9C11, 245) { p in
            for line in 0..<4 {
                for x in 0..<250 {
                    let y = 300 + line * 30 + (x / 6 % 2 == 0 ? x % 6 : 6 - x % 6)
                    p[y * TestPages.width + 200 + x] = UInt8(245 * 55 / 100)
                }
            }
        }
        for level in levels {
            let result = check(page, level)
            XCTAssertFalse(result.isBlank, "\(level): coverage \(result.inkCoverage)")
            XCTAssertEqual(result.inkComponents, 4)
        }
    }

    func test_aPhoto_isALargeDarkArea() {
        let result = check(TestPages.photo(), .high)
        XCTAssertTrue(result.hasLargeDarkArea)
        XCTAssertFalse(result.isBlank)
        XCTAssertFalse(result.isBlankAt(.high))
    }

    func test_tintedPaper_isPaper_andItsTextIsInk() {
        let result = check(TestPages.tintedWithText())
        XCTAssertFalse(result.hasLargeDarkArea)
        XCTAssertGreaterThan(result.inkCoverage, 0.005)
        // Tinted paper alone is blank.
        XCTAssertTrue(check(TestPages.noisy(0x8181_818A, 217) { _ in }).isBlank)
    }

    func test_isBlankAt_agreesWithTheThresholds() {
        XCTAssertLessThan(BlankPageDetector.threshold(.low), BlankPageDetector.threshold(.medium))
        XCTAssertLessThan(BlankPageDetector.threshold(.medium), BlankPageDetector.threshold(.high))
        XCTAssertEqual(BlankPageDetector.threshold(.low), 0.0001)
        XCTAssertEqual(BlankPageDetector.threshold(.medium), 0.0003)
        XCTAssertEqual(BlankPageDetector.threshold(.high), 0.001)
        for (_, page) in TestPages.all() {
            for level in levels {
                let result = check(page, level)
                XCTAssertEqual(result.isBlank, result.isBlankAt(level))
            }
        }
    }

    func test_theMargin_keepsEdgeShadowsAndHolesOut() {
        let noMargin = BlankPageDetector.analyze(TestPages.noisyBlank(), options: BlankPageOptions(marginInches: 0))
        XCTAssertFalse(noMargin.isBlank)
        XCTAssertGreaterThan(noMargin.inkCoverage, 0.01)
    }

    func test_aHigherResolutionScan_givesTheSameResult() {
        for page in [TestPages.noisyBlank(), TestPages.pageNumber(), TestPages.oneTextLine()] {
            let scan = TestPages.enlarged(page, 3)
            let gray = GrayImage.from(scan, sourceDPI: 300)
            XCTAssertEqual(gray.dpi, 100)
            XCTAssertEqual(gray.width, page.width)
            XCTAssertEqual(gray.height, page.height)
            XCTAssertEqual(gray.pixels, page.pixels)
            XCTAssertEqual(check(page), BlankPageDetector.analyze(scan, dpi: 300))
        }
    }

    func test_aScanAsCGImage_givesTheSameResultAsItsPixels() throws {
        // The CoreGraphics adapter reads the same RGBA as RgbaImage(cgImage:), in bands.
        for page in [TestPages.noisyBlank(), TestPages.oneTextLine()] {
            let scan = TestPages.enlarged(page, 2)
            let cgImage = try XCTUnwrap(scan.makeCGImage())
            let banded = try XCTUnwrap(GrayImage(cgImage: cgImage, sourceDPI: 200))
            let read = try XCTUnwrap(RgbaImage(cgImage: cgImage))
            XCTAssertEqual(banded, GrayImage.from(read, sourceDPI: 200))
            XCTAssertEqual(BlankPageDetector.analyze(cgImage, dpi: 200), BlankPageDetector.analyze(read, dpi: 200))
        }
    }

    func test_aLowResolutionScan_isAnalyzedAtItsOwnResolution() {
        // 50 dpi: half the pixels; marks and tiles scale with it.
        let blank = GrayImage.filled(width: 425, height: 550, value: 240, dpi: 50)
        XCTAssertTrue(BlankPageDetector.analyze(blank).isBlank)
        let text = TestPages.oneTextLine().downsampled(width: 425, height: 550)
        XCTAssertEqual(text.dpi, 50)
        XCTAssertFalse(BlankPageDetector.analyze(text).isBlank)
    }

    func test_aSmallCard_usesAShareOfItsShortSideAsMargin() {
        // A 3.5 × 2 in card: a 0.7 in margin would leave almost nothing.
        let card = GrayImage.filled(width: 350, height: 200, value: 245)
        XCTAssertTrue(BlankPageDetector.analyze(card).isBlank)
        var pixels = card.pixels
        for x in 60..<290 {
            for y in 95..<105 { pixels[y * 350 + x] = (x / 4) % 2 == 0 ? 40 : 245 }
        }
        XCTAssertFalse(BlankPageDetector.analyze(GrayImage(width: 350, height: 200, pixels: pixels)).isBlank)
    }

    func test_aTinyImage_isNotBlank() {
        XCTAssertFalse(BlankPageDetector.analyze(GrayImage.filled(width: 3, height: 3, value: 255)).isBlank)
        XCTAssertFalse(BlankPageDetector.analyze(GrayImage.filled(width: 1, height: 1, value: 255)).isBlank)
    }

    func test_aDarkBandAcrossThePage_isNeverBlank() {
        // A scanner's black backing showing past a short sheet.
        let page = TestPages.noisy(0x00BA_DBAD, 245) { p in TestPages.fill(&p, 0, 900, TestPages.width, 200, 20) }
        let result = check(page, .high)
        XCTAssertTrue(result.hasLargeDarkArea)
        XCTAssertFalse(result.isBlank)
    }
}
