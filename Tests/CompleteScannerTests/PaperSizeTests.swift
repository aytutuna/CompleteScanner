import XCTest
import CoreGraphics
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/PaperSizeTests.cs: the same cases.

private func assertSize(_ width: Double, _ height: Double, _ actual: CGSize?,
                        file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("No size", file: file, line: line) }
    XCTAssertEqual(Double(actual.width), width, accuracy: 0.00005, file: file, line: line)
    XCTAssertEqual(Double(actual.height), height, accuracy: 0.00005, file: file, line: line)
}

private func assertRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ actual: CGRect?,
                        file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("No rect", file: file, line: line) }
    XCTAssertEqual(Double(actual.origin.x), x, accuracy: 0.00005, file: file, line: line)
    XCTAssertEqual(Double(actual.origin.y), y, accuracy: 0.00005, file: file, line: line)
    XCTAssertEqual(Double(actual.width), width, accuracy: 0.00005, file: file, line: line)
    XCTAssertEqual(Double(actual.height), height, accuracy: 0.00005, file: file, line: line)
}

final class PaperSizeTests: XCTestCase {

    func test_automaticIsTheFirstSizeAndTheDefault() {
        XCTAssertEqual(PaperSize.allCases.first, .auto)
        XCTAssertEqual(ScanSettings().paperSize, .auto)
        XCTAssertNil(PaperSizes.inches(.auto))
    }

    func test_rawValues_areTheStoredNames() throws {
        XCTAssertEqual(PaperSize.allCases.map(\.rawValue),
                       ["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard"])
        for size in PaperSize.allCases {
            let data = try JSONEncoder().encode([size])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(size.rawValue)\"]")
        }
    }

    func test_inches_portraitWidthByHeight() {
        assertSize(8.5, 11, PaperSizes.inches(.letter))
        assertSize(8.5, 14, PaperSizes.inches(.legal))
        assertSize(7.25, 10.5, PaperSizes.inches(.executive))
        assertSize(8.2677, 11.6929, PaperSizes.inches(.a4))
        assertSize(5.8268, 8.2677, PaperSizes.inches(.a5))
        assertSize(4.1339, 5.8268, PaperSizes.inches(.a6))
        assertSize(7.1654, 10.1181, PaperSizes.inches(.b5Jis))
        assertSize(2.125, 3.370, PaperSizes.inches(.idCard))
        // 210 × 297 mm.
        XCTAssertEqual((Double(PaperSizes.inches(.a4)!.width) * 25.4).rounded(), 210)
        XCTAssertEqual((Double(PaperSizes.inches(.a4)!.height) * 25.4).rounded(), 297)
    }

    func test_parse_isLenient() {
        XCTAssertEqual(PaperSizes.parse("a4"), .a4)
        XCTAssertEqual(PaperSizes.parse("A4"), .a4)
        XCTAssertEqual(PaperSizes.parse(" letter "), .letter)
        XCTAssertEqual(PaperSizes.parse("b5jis"), .b5Jis)
        XCTAssertEqual(PaperSizes.parse("idCard"), .idCard)
        XCTAssertEqual(PaperSizes.parse("tabloid"), .auto)
        XCTAssertEqual(PaperSizes.parse(""), .auto)
        XCTAssertEqual(PaperSizes.parse(nil), .auto)
    }

    func test_defaultForRegion_letterInTheAmericasAndThePhilippines_a4Elsewhere() {
        XCTAssertEqual(PaperSizes.letterRegions.count, 14)
        for code in ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE", "us", " ca "] {
            XCTAssertEqual(PaperSizes.defaultForRegion(code), .letter, code)
        }
        for code: String? in ["DE", "GB", "JP", "BR", "AU", "TR", "", nil] {
            XCTAssertEqual(PaperSizes.defaultForRegion(code), .a4, code ?? "nil")
        }
    }

    func test_match_thePaperAPrinterReports() {
        // Windows reports A4 as 793.7 × 1122.5 device-independent pixels (1/96 in).
        XCTAssertEqual(PaperSizes.match(CGSize(width: 793.700787 / 96, height: 1122.519685 / 96)), .a4)
        XCTAssertEqual(PaperSizes.match(CGSize(width: 8.5, height: 11)), .letter)
        // Either way round, within a little rounding.
        XCTAssertEqual(PaperSizes.match(CGSize(width: 11.02, height: 8.49)), .letter)
        XCTAssertEqual(PaperSizes.match(CGSize(width: 8.5, height: 14)), .legal)
        XCTAssertEqual(PaperSizes.match(CGSize(width: 5.83, height: 8.27)), .a5)
        XCTAssertNil(PaperSizes.match(CGSize(width: 8, height: 10)))
        XCTAssertNil(PaperSizes.match(CGSize(width: 8.5, height: 11.2)))
        XCTAssertNil(PaperSizes.match(CGSize(width: 0, height: 0)))
        for size in PaperSize.allCases {
            if let inches = PaperSizes.inches(size) {
                XCTAssertEqual(PaperSizes.match(inches), size)
            }
        }
    }

    func test_displayOrder_automaticThenTheUsualSize() {
        XCTAssertEqual(PaperSizes.displayOrder(region: "US"),
                       [.auto, .letter, .legal, .executive, .a4, .a5, .a6, .b5Jis, .idCard])
        XCTAssertEqual(PaperSizes.displayOrder(region: "DE"),
                       [.auto, .a4, .letter, .legal, .executive, .a5, .a6, .b5Jis, .idCard])
    }

    func test_fits_withinTheAreaAndALittleRounding() {
        let letterGlass = CGSize(width: 8.5, height: 11.7)
        XCTAssertTrue(PaperSizes.fits(.a4, in: letterGlass))
        XCTAssertTrue(PaperSizes.fits(.letter, in: letterGlass))
        XCTAssertFalse(PaperSizes.fits(.legal, in: letterGlass))
        XCTAssertTrue(PaperSizes.fits(.a4, in: CGSize(width: 8.26, height: 11.65)))
        XCTAssertFalse(PaperSizes.fits(.letter, in: CGSize(width: 8.27, height: 11.69)))
        XCTAssertTrue(PaperSizes.fits(.auto, in: CGSize(width: 1, height: 1)))
        XCTAssertTrue(PaperSizes.fits(.legal, in: nil))
        XCTAssertTrue(PaperSizes.fits(.legal, in: CGSize(width: 0, height: 0)))
    }

    func test_flatbedSelection_fromTheCornerOfTheGlass() {
        let glass = CGSize(width: 8.5, height: 11.7)
        XCTAssertNil(PaperSizes.flatbedSelection(.auto, bed: glass))
        assertRect(0, 0, 1, 11 / 11.7, PaperSizes.flatbedSelection(.letter, bed: glass))
        assertRect(0, 0, 5.8268 / 8.5, 8.2677 / 11.7, PaperSizes.flatbedSelection(.a5, bed: glass))
        // Larger than the glass: clamped to it.
        assertRect(0, 0, 1, 1, PaperSizes.flatbedSelection(.legal, bed: glass))
        XCTAssertNil(PaperSizes.flatbedSelection(.a4, bed: CGSize(width: 0, height: 11)))
    }

    func test_feederRegion_thePaperClampedToTheLargestSheet() {
        let legal = CGSize(width: 8.5, height: 14)
        assertRect(0, 0, 8.5, 14, PaperSizes.feederRegionInches(.auto, max: legal))
        assertRect(0, 0, 8.2677, 11.6929, PaperSizes.feederRegionInches(.a4, max: legal))
        assertRect(0, 0, 8.5, 11, PaperSizes.feederRegionInches(.legal, max: CGSize(width: 8.5, height: 11)))
    }

    func test_labelsAndHints() {
        XCTAssertEqual(PaperSize.allCases.map(\.label),
                       ["Automatic", "Letter", "Legal", "Executive", "A4", "A5", "A6", "B5 (JIS)", "ID card"])
        XCTAssertEqual(PaperSize.a4.detail, "210 \u{00D7} 297 mm")
        XCTAssertEqual(PaperSize.letter.detail, "8.5 \u{00D7} 11 in")
        XCTAssertEqual(PaperSizes.hint(.auto, source: .flatbed), "The whole glass, or the area selected on the preview.")
        XCTAssertEqual(PaperSizes.hint(.auto, source: .documentFeeder), "The sheet size the feeder takes.")
        XCTAssertEqual(PaperSizes.hint(.a4, source: .documentFeeder), "Sheets of this size, from the feeder.")
        XCTAssertEqual(PaperSizes.hint(.letter, source: .flatbed), "From the glass corner. A preview selection replaces it.")
        XCTAssertEqual(PaperSizes.doesNotFitReason(source: .flatbed), "Too big for this glass")
        XCTAssertEqual(PaperSizes.doesNotFitReason(source: .documentFeeder), "Too big for this feeder")
        XCTAssertEqual(PaperSizes.selectedAreaNote, "Using the selected area")
    }
}
