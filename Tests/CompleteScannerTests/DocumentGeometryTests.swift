import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/DocumentGeometryTests.cs: crop to the page and
// straighten it, on the same synthetic pages (TestPages, byte-identical, checked by checksum).

private func rowMean(_ gray: GrayImage, _ y: Int) -> Double {
    var sum = 0
    for x in 0..<gray.width { sum += Int(gray.pixels[y * gray.width + x]) }
    return Double(sum) / Double(gray.width)
}

private func columnMean(_ gray: GrayImage, _ x: Int) -> Double {
    var sum = 0
    for y in 0..<gray.height { sum += Int(gray.pixels[y * gray.width + x]) }
    return Double(sum) / Double(gray.height)
}

private func assertIn(_ value: Double, _ low: Double, _ high: Double, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value >= low && value <= high, "\(value) not in \(low)...\(high) \(message)", file: file, line: line)
}

final class DocumentGeometryTests: XCTestCase {

    // MARK: The pages are the same on both platforms

    func test_geometryPages_areTheSameBytesOnBothPlatforms() {
        XCTAssertEqual(TestPages.checksum(TestPages.textPage()), 0xF559_B7D5)
        XCTAssertEqual(TestPages.checksum(TestPages.turned(TestPages.textPage(), TestPages.plus3, fill: 245)), 0x944A_54E5)
        XCTAssertEqual(TestPages.checksum(TestPages.turned(TestPages.textPage(), TestPages.minus1Point5, fill: 245)), 0x04B3_2746)
        XCTAssertEqual(TestPages.checksum(TestPages.sheetOnBackdrop(TestPages.plus2, backdrop: 245, paper: 250, shadow: 2,
                                                                    seed: 0x5EE7_0001)), 0x25E9_2C27)
        XCTAssertEqual(TestPages.checksum(TestPages.sheetOnBackdrop(TestPages.minus4, backdrop: 30, paper: 240, shadow: 0,
                                                                    seed: 0x5EE7_0002)), 0xA945_0876)
        // Turning by nothing changes nothing.
        XCTAssertEqual(TestPages.checksum(TestPages.turned(TestPages.textPage(), TestPages.straight, fill: 245)), 0xF559_B7D5)
    }

    // MARK: Text lines

    func test_estimateTextLayout_recoversTheSkew() {
        for turn in [TestPages.plus3, TestPages.minus1Point5, TestPages.plus6Point5] {
            let layout = DocumentGeometry.estimateTextLayout(TestPages.turned(TestPages.textPage(), turn, fill: 245))
            XCTAssertEqual(layout.axis, .horizontal)
            XCTAssertTrue(layout.isConfident, "confidence \(layout.confidence), points \(layout.inkPoints)")
            assertIn(layout.skewDegrees, turn.degrees - 0.15, turn.degrees + 0.15)
        }
    }

    func test_estimateTextLayout_straightText_isStraight() {
        let layout = DocumentGeometry.estimateTextLayout(TestPages.textPage())
        XCTAssertEqual(layout.axis, .horizontal)
        XCTAssertTrue(layout.isConfident)
        assertIn(layout.skewDegrees, -0.1, 0.1)
    }

    func test_estimateTextLayout_pageOnItsSide_hasVerticalLines() {
        let sideways = GrayImage.luma(TestPages.turned(TestPages.textPage(), TestPages.plus2, fill: 245).toRgba()
            .rotatedQuarterTurns(1))
        let layout = DocumentGeometry.estimateTextLayout(sideways)
        XCTAssertEqual(layout.axis, .vertical)
        XCTAssertTrue(layout.isConfident)
        // Turning the page a quarter keeps the skew's sense: the columns lean the same way.
        assertIn(layout.skewDegrees, TestPages.plus2.degrees - 0.15, TestPages.plus2.degrees + 0.15)
    }

    func test_estimateTextLayout_blankPage_isNotConfident() {
        for page in [TestPages.cleanBlank(), TestPages.noisyBlank(), TestPages.pageNumber()] {
            XCTAssertFalse(DocumentGeometry.estimateTextLayout(page).isConfident)
            XCTAssertNil(DocumentGeometry.plan(page, crop: false, straighten: true))
        }
    }

    func test_plan_tinySkew_leavesThePage() {
        let page = TestPages.turned(TestPages.textPage(), TestPages.plus0Point1, fill: 245)
        XCTAssertNil(DocumentGeometry.plan(page, crop: false, straighten: true))
        XCTAssertNil(DocumentGeometry.plan(TestPages.textPage(), crop: true, straighten: true))
    }

    func test_plan_skewedText_turnsTheScanInPlace() throws {
        let page = TestPages.turned(TestPages.textPage(), TestPages.plus3, fill: 245)
        let plan = try XCTUnwrap(DocumentGeometry.plan(page, crop: true, straighten: true))
        XCTAssertEqual(plan.action, .rotate)
        XCTAssertEqual(plan.basis, .textLines)
        assertIn(plan.angleDegrees, 2.85, 3.15)
        // The corners turned out of the frame are paper: the scan keeps its size.
        XCTAssertEqual(plan.canvas, CGSize(width: page.width, height: page.height))
        XCTAssertEqual(plan.geometry, PageGeometry(cropped: false, angleDegrees: plan.angleDegrees, basis: .textLines))
        // Straightening is not asked: nothing to do without a sheet.
        XCTAssertNil(DocumentGeometry.plan(page, crop: true, straighten: false))
    }

    func test_plan_turningWouldCutOffMarksInTheCorners_growsTheCanvas() throws {
        var page = TestPages.turned(TestPages.textPage(), TestPages.plus3, fill: 245)
        // A mark in each corner of the scan: turning the page in place would cut them off.
        for (x, y) in [(6, 6), (834, 6), (6, 1084), (834, 1084)] {
            for py in y..<(y + 10) {
                for px in x..<(x + 10) { page.pixels[py * page.width + px] = 30 }
            }
        }
        let plan = try XCTUnwrap(DocumentGeometry.plan(page, crop: false, straighten: true))
        XCTAssertEqual(plan.action, .rotate)
        XCTAssertTrue(Double(plan.canvas.width) > Double(page.width) && Double(plan.canvas.height) > Double(page.height),
                      "\(plan.canvas)")
        // Every corner mark lies inside the turned canvas.
        let a = plan.angleDegrees * .pi / 180
        for (x, y) in [(6, 6), (844, 6), (6, 1094), (844, 1094)] {
            let dx = Double(x) - Double(page.width) / 2, dy = Double(y) - Double(page.height) / 2
            XCTAssertTrue(abs(dx * cos(a) + dy * sin(a)) <= Double(plan.canvas.width) / 2)
            XCTAssertTrue(abs(-dx * sin(a) + dy * cos(a)) <= Double(plan.canvas.height) / 2)
        }
    }

    // MARK: Page edges

    func test_detectPage_whiteSheetShownOnlyByItsShadow_isFound() throws {
        let page = TestPages.sheetOnBackdrop(TestPages.plus2, backdrop: 245, paper: 250, shadow: 2, seed: 0x5EE7_0001)
        let search = DocumentGeometry.findPage(page)
        XCTAssertEqual(search.rejection, .none)
        let region = try XCTUnwrap(search.page)
        assertIn(Double(region.center.x), 425 - 2, 425 + 2)
        assertIn(Double(region.center.y), 550 - 2, 550 + 2)
        assertIn(region.angleDegrees, TestPages.plus2.degrees - 0.3, TestPages.plus2.degrees + 0.3)
        // The outline found is the sheet with its shadow.
        assertIn(Double(region.size.width), Double(TestPages.sheetWidth - 2), Double(TestPages.sheetWidth + 4 + 2))
        assertIn(Double(region.size.height), Double(TestPages.sheetHeight - 2), Double(TestPages.sheetHeight + 4 + 2))
        XCTAssertFalse(search.touchesBorder)
    }

    func test_detectPage_sheetOnADarkBackdrop_isFound() throws {
        let page = TestPages.sheetOnBackdrop(TestPages.minus4, backdrop: 30, paper: 240, shadow: 0, seed: 0x5EE7_0002)
        let region = try XCTUnwrap(DocumentGeometry.detectPage(page))
        assertIn(Double(region.center.x), 425 - 2, 425 + 2)
        assertIn(Double(region.center.y), 550 - 2, 550 + 2)
        assertIn(region.angleDegrees, TestPages.minus4.degrees - 0.3, TestPages.minus4.degrees + 0.3)
        assertIn(Double(region.size.width), Double(TestPages.sheetWidth - 2), Double(TestPages.sheetWidth + 2))
        assertIn(Double(region.size.height), Double(TestPages.sheetHeight - 2), Double(TestPages.sheetHeight + 2))
    }

    func test_detectPage_sheetWithNoVisibleEdge_isNotFound() {
        let page = TestPages.sheetOnBackdrop(TestPages.plus2, backdrop: 245, paper: 248, shadow: 0, seed: 0x5EE7_0003)
        XCTAssertNil(DocumentGeometry.detectPage(page))
        XCTAssertNil(DocumentGeometry.plan(page, crop: true, straighten: false))
    }

    func test_detectPage_pageFillingTheScan_isNotCropped() {
        XCTAssertNil(DocumentGeometry.detectPage(TestPages.textPage()))
        // A page with a thin dark line all around the scan's edge: the "sheet" is all of it.
        var framed = TestPages.textPage()
        for x in 0..<framed.width {
            framed.pixels[x] = 20
            framed.pixels[(framed.height - 1) * framed.width + x] = 20
        }
        for y in 0..<framed.height {
            framed.pixels[y * framed.width] = 20
            framed.pixels[y * framed.width + framed.width - 1] = 20
        }
        let search = DocumentGeometry.findPage(framed)
        XCTAssertNil(search.page)
        XCTAssertEqual(search.rejection, .fillsScan)
    }

    func test_detectPage_pictureOnAPageOfText_isNeverTakenForTheSheet() {
        // A dark 4 × 5 in picture (with a 0.2 in margin) in the middle of a page of text that fills
        // the scan: cropping to it would cut away the text.
        var page = TestPages.textPage()
        for y in 280..<820 {
            for x in 205..<645 {
                let picture = y >= 300 && y < 800 && x >= 225 && x < 625
                page.pixels[y * page.width + x] = picture ? 60 : 245
            }
        }
        let search = DocumentGeometry.findPage(page)
        XCTAssertNil(search.page)
        XCTAssertEqual(search.rejection, .textAround)
        XCTAssertTrue(search.outsideMarks > DocumentGeometry.maxOutsideMarks)
        XCTAssertNil(DocumentGeometry.plan(page, crop: true, straighten: false))
    }

    func test_detectPage_anotherSheetBesideIt_isNotCropped_aSmallObjectIs() {
        // A 1 x 2 in card beside the sheet: cropping to the sheet would drop it.
        var page = TestPages.sheetOnBackdrop(TestPages.straight, backdrop: 30, paper: 240, shadow: 0, seed: 0x5EE7_0005)
        for y in 100..<300 {
            for x in 740..<840 { page.pixels[y * page.width + x] = 240 }
        }
        let search = DocumentGeometry.findPage(page)
        XCTAssertNil(search.page)
        XCTAssertEqual(search.rejection, .otherObjects)
        // A thin 0.1 x 1.5 in strip (a thread, a ruler's edge) is not worth keeping: the sheet is found.
        var strip = TestPages.sheetOnBackdrop(TestPages.straight, backdrop: 30, paper: 240, shadow: 0, seed: 0x5EE7_0005)
        for y in 100..<250 {
            for x in 760..<770 { strip.pixels[y * strip.width + x] = 240 }
        }
        XCTAssertNotNil(DocumentGeometry.detectPage(strip))
    }

    func test_detectPage_smallOrNothing_isNotASheet() {
        XCTAssertEqual(DocumentGeometry.findPage(TestPages.cleanBlank()).rejection, .nothingFound)
        // A card of 2 × 3 in on a dark backdrop: under the smallest sheet.
        var card = GrayImage.filled(width: 850, height: 1100, value: 30)
        for y in 400..<700 {
            for x in 300..<500 { card.pixels[y * 850 + x] = 240 }
        }
        XCTAssertEqual(DocumentGeometry.findPage(card).rejection, .tooSmall)
    }

    func test_plan_sheetOnTheBackdrop_isCutOutUpright() throws {
        let page = TestPages.sheetOnBackdrop(TestPages.minus4, backdrop: 30, paper: 240, shadow: 0, seed: 0x5EE7_0002)
        let plan = try XCTUnwrap(DocumentGeometry.plan(page, crop: true, straighten: true))
        XCTAssertEqual(plan.action, .cropStraightened)
        XCTAssertEqual(plan.basis, .pageEdges)
        assertIn(plan.angleDegrees, TestPages.minus4.degrees - 0.3, TestPages.minus4.degrees + 0.3)
        XCTAssertEqual(plan.geometry.caption, "Cropped and straightened 4.0°")
        // Crop only: the box around the sheet, not turned.
        let box = try XCTUnwrap(DocumentGeometry.plan(page, crop: true, straighten: false))
        XCTAssertEqual(box.action, .cropBox)
        XCTAssertEqual(box.angleDegrees, 0)
        XCTAssertEqual(box.geometry.caption, "Cropped")
        // Straighten only: the scan turned by the sheet's angle.
        let turn = try XCTUnwrap(DocumentGeometry.plan(page, crop: false, straighten: true))
        XCTAssertEqual(turn.action, .rotate)
        XCTAssertEqual(turn.basis, .pageEdges)
        XCTAssertEqual(turn.geometry.caption, "Straightened 4.0°")
    }

    func test_plan_straightSheet_isCroppedNotTurned() {
        let page = TestPages.sheetOnBackdrop(TestPages.straight, backdrop: 30, paper: 240, shadow: 0, seed: 0x5EE7_0004)
        XCTAssertEqual(DocumentGeometry.plan(page, crop: true, straighten: true)?.action, .cropBox)
        // The sheet's edges say it is straight: the text is not asked.
        XCTAssertNil(DocumentGeometry.plan(page, crop: false, straighten: true))
    }

    // MARK: Correct (full resolution)

    func test_correct_sheetOnADarkBackdrop_givesTheSheetUpright() throws {
        let page = TestPages.sheetOnBackdrop(TestPages.minus4, backdrop: 30, paper: 240, shadow: 0, seed: 0x5EE7_0002)
        let result = try XCTUnwrap(DocumentGeometry.correct(page.toRgba(), dpi: 100, crop: true, straighten: true))
        XCTAssertTrue(result.geometry.cropped)
        assertIn(result.geometry.angleDegrees, TestPages.minus4.degrees - 0.3, TestPages.minus4.degrees + 0.3)
        assertIn(Double(result.image.width), Double(TestPages.sheetWidth - 4), Double(TestPages.sheetWidth + 2))
        assertIn(Double(result.image.height), Double(TestPages.sheetHeight - 4), Double(TestPages.sheetHeight + 2))
        // No backdrop left along the edges: the outermost rows and columns are paper.
        let gray = GrayImage.luma(result.image)
        for x in [0, gray.width - 1] { XCTAssertTrue(columnMean(gray, x) > 150, "column \(x): \(columnMean(gray, x))") }
        for y in [0, gray.height - 1] { XCTAssertTrue(rowMean(gray, y) > 150, "row \(y): \(rowMean(gray, y))") }
    }

    func test_correct_whiteSheetOnALid_trimsTheShadow() throws {
        let page = TestPages.sheetOnBackdrop(TestPages.plus2, backdrop: 245, paper: 250, shadow: 2, seed: 0x5EE7_0001)
        let result = try XCTUnwrap(DocumentGeometry.correct(page.toRgba(), dpi: 100, crop: true, straighten: true))
        XCTAssertEqual(result.plan.action, .cropStraightened)
        assertIn(Double(result.image.width), Double(TestPages.sheetWidth - 4), Double(TestPages.sheetWidth + 2))
        assertIn(Double(result.image.height), Double(TestPages.sheetHeight - 4), Double(TestPages.sheetHeight + 2))
        let gray = GrayImage.luma(result.image)
        for x in [0, gray.width - 1] { XCTAssertTrue(columnMean(gray, x) > 230, "column \(x): \(columnMean(gray, x))") }
        for y in [0, gray.height - 1] { XCTAssertTrue(rowMean(gray, y) > 230, "row \(y): \(rowMean(gray, y))") }
    }

    func test_correct_nothingAskedOrNothingFound_leavesThePage() {
        let page = TestPages.textPage().toRgba()
        XCTAssertNil(DocumentGeometry.correct(page, dpi: 100, crop: false, straighten: false))
        XCTAssertNil(DocumentGeometry.correct(page, dpi: 100, crop: true, straighten: true))
        XCTAssertNil(DocumentGeometry.correct(TestPages.noisyBlank().toRgba(), dpi: 100, crop: true, straighten: true))
    }

    func test_correct_turnedText_keepsTheScanSizeAndStraightensIt() throws {
        let page = TestPages.turned(TestPages.textPage(), TestPages.plus3, fill: 245).toRgba()
        let result = try XCTUnwrap(DocumentGeometry.correct(page, dpi: 100, crop: false, straighten: true))
        XCTAssertEqual(result.image.width, 850)
        XCTAssertEqual(result.image.height, 1100)
        XCTAssertFalse(result.geometry.cropped)
        let after = DocumentGeometry.estimateTextLayout(GrayImage.luma(result.image))
        assertIn(after.skewDegrees, -0.15, 0.15)
    }

    // MARK: Helpers

    func test_rectAtAngle_enclosesThePoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]
        let straight = DocumentGeometry.rectAtAngle(points, angleDegrees: 0)
        XCTAssertEqual(straight.center, CGPoint(x: 50, y: 25))
        XCTAssertEqual(straight.size, CGSize(width: 100, height: 50))
        let turned = DocumentGeometry.rectAtAngle(points, angleDegrees: 10)
        let a = 10 * Double.pi / 180
        for p in points {
            let dx = Double(p.x - turned.center.x), dy = Double(p.y - turned.center.y)
            XCTAssertTrue(abs(dx * cos(a) + dy * sin(a)) <= Double(turned.size.width) / 2 + 1e-9)
            XCTAssertTrue(abs(-dx * sin(a) + dy * cos(a)) <= Double(turned.size.height) / 2 + 1e-9)
        }
    }

    func test_edgeInsets_trimOnlyDarkLinesAtTheEdge() {
        var gray = GrayImage.filled(width: 200, height: 300, value: 240)
        // A 2 px shadow along the left edge; print 10 px in from the right edge.
        for y in 0..<300 {
            gray.pixels[y * 200] = 150
            gray.pixels[y * 200 + 1] = 170
            gray.pixels[y * 200 + 189] = 20
        }
        let insets = DocumentGeometry.edgeInsets(gray.toRgba(), dpi: 100)
        XCTAssertEqual([insets.left, insets.top, insets.right, insets.bottom], [2, 0, 0, 0])
    }

    func test_borderColor_isTheRingsMedianPerChannel() {
        let color = DocumentGeometry.borderColor(RgbaImage.filled(width: 100, height: 100, r: 10, g: 20, b: 30), dpi: 100)
        XCTAssertEqual([color.r, color.g, color.b], [10, 20, 30])
    }

    func test_angleText_hasOneDecimal() {
        XCTAssertEqual(DocumentGeometry.angleText(-2.4361), "2.4°")
        XCTAssertEqual(DocumentGeometry.angleText(0.25), "0.3°")
    }
}
