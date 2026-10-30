import XCTest
import CoreGraphics
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/OcrTextTests.cs: the same cases.

/// Lines placed on a 1000 × 1000 page by their top-left corner, as a person reads the page.
enum OCRFixtures {
    static let pageSize = 1000.0

    /// A line at (`left`, `top`), origin top-left, in page units.
    static func line(_ text: String, _ left: Double, _ top: Double, _ width: Double, _ height: Double = 20,
                     confidence: Float = 1) -> OCRLine {
        OCRLine(text: text,
                boundingBox: CGRect(x: left / pageSize, y: 1 - (top + height) / pageSize,
                                    width: width / pageSize, height: height / pageSize),
                confidence: confidence)
    }

    static func page(_ lines: OCRLine...) -> OCRPage {
        OCRPage(lines: lines, widthPoints: pageSize, heightPoints: pageSize)
    }

    static func ordered(_ lines: [OCRLine]) -> [String] {
        OCRText.readingOrder(lines, pageWidth: pageSize, pageHeight: pageSize).map(\.text)
    }
}

final class OCRTextTests: XCTestCase {
    private func L(_ text: String, _ left: Double, _ top: Double, _ width: Double, _ height: Double = 20) -> OCRLine {
        OCRFixtures.line(text, left, top, width, height)
    }

    func test_readingOrder_twoColumns_leftColumnFirst() {
        // The engine reads across the gutter, row by row.
        let ordered = OCRFixtures.ordered([
            L("left 1", 50, 100, 400), L("right 1", 550, 100, 400),
            L("left 2", 50, 140, 400), L("right 2", 550, 140, 400),
            L("left 3", 50, 180, 380), L("right 3", 550, 180, 300),
        ])
        XCTAssertEqual(ordered, ["left 1", "left 2", "left 3", "right 1", "right 2", "right 3"])
    }

    func test_readingOrder_headingAcrossColumns_comesFirst_thenEachColumn() {
        let ordered = OCRFixtures.ordered([
            L("right 1", 550, 100, 400), L("left 1", 50, 100, 400),
            L("right 2", 550, 140, 400), L("left 2", 50, 140, 400),
            L("THE HEADING", 200, 40, 600, 30),
            L("footer across the page", 50, 300, 900),
        ])
        XCTAssertEqual(ordered, ["THE HEADING", "left 1", "left 2", "right 1", "right 2", "footer across the page"])
    }

    func test_readingOrder_sidebarBesideALetterhead_isReadBeforeIt() {
        // A list of names on the left, small print on the right, side by side and interleaved.
        let ordered = OCRFixtures.ordered([
            L("CLARA BARTON.", 90, 130, 100, 6), L("FOR THE RELIEF OF SUFFERING", 270, 107, 620, 9),
            L("PRESIDENT.", 110, 138, 60, 4), L("EXTENT. THE ORGANIZATION", 310, 117, 540, 8),
            L("MRS. JOHN A. LOGAN.", 90, 148, 130, 5), L("AT GENEVA, SWITZERLAND", 350, 127, 460, 9),
            L("VICE-PRESIDENT.", 110, 156, 80, 4), L("STATES GAVE ITS ADHESION", 390, 137, 390, 9),
            L("August 31, 1903.", 660, 225, 180, 13),
        ])
        XCTAssertEqual(ordered, ["CLARA BARTON.", "PRESIDENT.", "MRS. JOHN A. LOGAN.", "VICE-PRESIDENT.",
                                 "FOR THE RELIEF OF SUFFERING", "EXTENT. THE ORGANIZATION", "AT GENEVA, SWITZERLAND",
                                 "STATES GAVE ITS ADHESION", "August 31, 1903."])
    }

    func test_readingOrder_piecesOfOneRow_joinedWithASpace_orATabAcrossAWideGap() {
        let ordered = OCRFixtures.ordered([
            L("Charles G. Washburn,", 280, 100, 210), L("Honorable", 165, 101, 100),
            L("Green Sea Turtle 25", 70, 200, 185), L("Vegetable with Macaroni 10", 630, 199, 255),
            L("August", 665, 300, 64), L("31,", 743, 300, 29), L("1903.", 788, 299, 51),
        ])
        XCTAssertEqual(ordered, ["Honorable Charles G. Washburn,", "Green Sea Turtle 25\tVegetable with Macaroni 10",
                                 "August 31, 1903."])
    }

    func test_readingOrder_headingJustAboveARow_comesFirst() {
        // A menu: a section heading, a row of two dishes right under it, then one in the middle.
        // A lone line beside the others is not a column.
        let ordered = OCRFixtures.ordered([
            L("Green Sea Turtle 25", 71, 325.5, 184, 8.5), L("SOUPS", 440, 318, 76, 7),
            L("Consomme Financiere 10", 390, 336, 227, 8), L("Vegetable with Macaroni 10", 629, 325.5, 257, 10.5),
        ])
        XCTAssertEqual(ordered, ["SOUPS", "Green Sea Turtle 25\tVegetable with Macaroni 10", "Consomme Financiere 10"])
    }

    func test_readingOrder_joinedRow_takesBothBoxesAndTheLowestConfidence() throws {
        let a = OCRFixtures.line("Honorable", 165, 101, 100, 20, confidence: 0.9)
        let b = OCRFixtures.line("Washburn,", 280, 100, 210, 22, confidence: 0.6)
        let rows = OCRText.readingOrder([b, a], pageWidth: 1000, pageHeight: 1000)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.text, "Honorable Washburn,")
        XCTAssertEqual(row.confidence, 0.6)
        XCTAssertEqual(Double(row.boundingBox.minX), 0.165, accuracy: 1e-9)
        XCTAssertEqual(Double(row.boundingBox.maxX), 0.49, accuracy: 1e-9)
        XCTAssertEqual(Double(row.boundingBox.minY), 1 - 0.122, accuracy: 1e-9)
        XCTAssertEqual(Double(row.boundingBox.maxY), 1 - 0.100, accuracy: 1e-9)
    }

    func test_readingOrder_slightlyOverlappingLines_stayApart() {
        // A slanted page: each line's box reaches into the next one, so there is no gap between
        // them, but they share too little height to be one row.
        let ordered = OCRFixtures.ordered([
            L("third line", 50, 150, 800, 30), L("first line", 50, 100, 800, 30), L("second line", 50, 125, 800, 30),
        ])
        XCTAssertEqual(ordered, ["first line", "second line", "third line"])
    }

    func test_readingOrder_doesNotDependOnTheEnginesOrder() {
        let lines = [
            L("title", 300, 50, 400, 30), L("a1", 50, 120, 380), L("b1", 560, 120, 380),
            L("a2", 50, 150, 380), L("b2", 560, 150, 380), L("price", 800, 260, 60), L("dish", 50, 261, 200),
        ]
        let expected = OCRFixtures.ordered(lines)
        XCTAssertEqual(expected, ["title", "a1", "a2", "b1", "b2", "dish\tprice"])
        XCTAssertEqual(OCRFixtures.ordered(lines.reversed()), expected)
        XCTAssertEqual(OCRFixtures.ordered(Array(lines.dropFirst(3)) + Array(lines.prefix(3))), expected)
    }

    func test_readingOrder_cleansTheText_andDropsEmptyLines() {
        let ordered = OCRFixtures.ordered([
            L("  two  words\u{0007}here ", 50, 100, 300), L("   ", 50, 140, 300), L("", 50, 180, 300),
            L("line\nbreak", 50, 220, 300),
            OCRLine(text: "no size", boundingBox: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), confidence: 1),
        ])
        XCTAssertEqual(ordered, ["two words here", "line break"])
        XCTAssertTrue(OCRText.readingOrder([], pageWidth: 1000, pageHeight: 1000).isEmpty)
    }

    func test_paragraphs_clearlyWiderGap_startsAParagraph() {
        let page = OCRFixtures.page(
            L("First paragraph, line one", 50, 100, 800), L("line two of it.", 50, 126, 300),
            L("Second paragraph starts", 50, 172, 800), L("and ends.", 50, 198, 200))
        XCTAssertEqual(OCRText.paragraphs(page).map(\.text),
                       ["First paragraph, line one line two of it.", "Second paragraph starts and ends."])
    }

    func test_paragraphs_doubleSpacedLetter_splitsAtIndentsOnly() {
        // Every line the same distance apart; paragraphs start indented (like a typed letter).
        let page = OCRFixtures.page(
            L("My dear Sir:-", 165, 100, 140, 13),
            L("I am enclosing herewith copy of letter I am forward-", 280, 130, 575, 13),
            L("ing to his Honor the Mayor of Worcester, which will be self", 169, 160, 650, 13),
            L("explanatory when I tell you.", 168, 190, 400, 13),
            L("The purpose of this note is to ask you to receive my", 280, 220, 575, 13),
            L("Secretary, Mr. E. Howe.", 170, 250, 300, 13))
        XCTAssertEqual(OCRText.paragraphs(page).map(\.text),
                       ["My dear Sir:-",
                        "I am enclosing herewith copy of letter I am forwarding to his Honor the Mayor of Worcester, which will be self explanatory when I tell you.",
                        "The purpose of this note is to ask you to receive my Secretary, Mr. E. Howe."])
    }

    func test_paragraphs_nextColumn_andALeftEdgeFarAway_startParagraphs() {
        let ordered = [
            L("left column one", 50, 100, 380), L("left column two", 50, 124, 380),
            L("right column one", 560, 100, 380), L("right column two", 560, 124, 380),
            L("far right", 850, 148, 100),
        ]
        XCTAssertEqual(OCRText.paragraphs(ordered, pageWidth: 1000, pageHeight: 1000).map(\.text),
                       ["left column one left column two", "right column one right column two", "far right"])
        XCTAssertTrue(OCRText.paragraphs([], pageWidth: 1000, pageHeight: 1000).isEmpty)
    }

    func test_paragraphs_centredLines_stayTogether_aStaircaseAddressDoesNot() {
        let page = OCRFixtures.page(
            L("THE AMERICAN NATIONAL RED CROSS.", 300, 40, 400, 13),
            L("FOR THE RELIEF OF SUFFERING BY WAR", 280, 58, 440, 9),
            L("OFFICE OF THE PRESIDENT,", 420, 72, 160, 9),
            L("Honorable Charles G. Washburn,", 165, 140, 330, 13),
            L("44 Elm St.,", 277, 175, 118, 13),
            L("Worcester, Mass.", 388, 210, 129, 13),
            L("My dear Sir:-", 166, 245, 143, 13),
            L("I am enclosing herewith copy of letter I am forward-", 279, 280, 576, 13),
            L("ing to his Honor the Mayor of Worcester.", 169, 315, 500, 13))
        XCTAssertEqual(OCRText.paragraphs(page).map(\.text),
                       ["THE AMERICAN NATIONAL RED CROSS. FOR THE RELIEF OF SUFFERING BY WAR OFFICE OF THE PRESIDENT,",
                        "Honorable Charles G. Washburn,", "44 Elm St.,", "Worcester, Mass.", "My dear Sir:-",
                        "I am enclosing herewith copy of letter I am forwarding to his Honor the Mayor of Worcester."])
    }

    func test_paragraphText_aWrappedLineJoinsTheNext_aShortLineKeepsItsBreak() {
        XCTAssertEqual(OCRText.paragraphText([L("Mr. Phillip Moen; Mr. Geo.", 170, 100, 685),
                                              L("Whitney; Henry A. Marsh.", 170, 130, 300)]),
                       "Mr. Phillip Moen; Mr. Geo. Whitney; Henry A. Marsh.")
        XCTAssertEqual(OCRText.paragraphText([L("Dear John,", 50, 100, 150),
                                              L("this line runs right across the page", 50, 130, 800)]),
                       "Dear John,\nthis line runs right across the page")
        XCTAssertEqual(OCRText.paragraphText([L("Soup\t4.50", 50, 100, 800), L("Bread\t1.00", 50, 130, 800)]),
                       "Soup\t4.50\nBread\t1.00")
        XCTAssertEqual(OCRText.paragraphText([]), "")
    }

    func test_joinLines_joinsWordsBrokenOverTwoLines() {
        XCTAssertEqual(OCRText.joinLines(["I am forward-", "ing it"]), "I am forwarding it")
        XCTAssertEqual(OCRText.joinLines(["well-", "Known"]), "well- Known")
        XCTAssertEqual(OCRText.joinLines(["1903-", "1904"]), "1903- 1904")
        XCTAssertEqual(OCRText.joinLines(["a -", "b"]), "a - b")
        XCTAssertEqual(OCRText.joinLines(["  one ", "", " two"]), "one two")
        XCTAssertEqual(OCRText.joinLines([]), "")
    }

    func test_plainText_linesParagraphsAndPages() {
        let first = OCRFixtures.page(
            L("Title", 400, 50, 200, 30),
            L("First paragraph, line one", 50, 120, 800), L("line two.", 50, 146, 300),
            L("Dish 25", 50, 220, 150), L("Price list", 700, 220, 150))
        let empty = OCRFixtures.page()
        let last = OCRFixtures.page(L("The end.", 50, 100, 200))
        XCTAssertEqual(OCRText.pageText(first), "Title\n\nFirst paragraph, line one\nline two.\n\nDish 25\tPrice list")
        XCTAssertEqual(OCRText.pageText(empty), "")
        XCTAssertEqual(OCRText.plainText([first, empty, last]),
                       "Title\n\nFirst paragraph, line one\nline two.\n\nDish 25\tPrice list\n\n\n\n\n\nThe end.\n")
        XCTAssertEqual(OCRText.plainText([empty, empty]), "")
        XCTAssertEqual(OCRText.plainText([]), "")
    }

    func test_ocrPage_sizeInPointsFromPixelsAndDPI() {
        let page = OCRPage.of([], pixelWidth: 2550, pixelHeight: 3300, dpi: 300)
        XCTAssertEqual(page.widthPoints, 612)
        XCTAssertEqual(page.heightPoints, 792)
        XCTAssertEqual(OCRPage.of([], pixelWidth: 2550, pixelHeight: 1, dpi: 0).widthPoints, 2550 * 72)
        XCTAssertEqual(OCRPage.of([], pixelWidth: 2550, pixelHeight: 1, dpi: 0).heightPoints, 72)
    }
}
