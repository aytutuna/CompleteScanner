import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors the syntax and filter cases of windows/CompleteScanner.Core.Tests/PdfReaderLiteTests.cs:
// the same values read and written back, the same refusals, the same predictor and Flate cases.
// The Flate case also inflates zlib's own bytes for its text, so Foundation's inflate is checked
// against another encoder than the fixtures' Foundation deflate.

final class PDFSyntaxTests: XCTestCase {
    private func parse(_ text: String) throws -> any PDFObject {
        try PDFLexer(PDFArrayBytes(PDFFixture.latin1(text))).readObject()
    }

    private func assertProblem(_ text: String, _ problem: PDFReadProblem, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), line: line) { error in
            XCTAssertEqual((error as? PDFReadError)?.problem, problem, line: line)
        }
    }

    // MARK: - Syntax

    func test_lexer_readsEveryKindOfValue() throws {
        let dictionary = try XCTUnwrap(parse(
            "<</Name /A#20B#23 /Int -12 /Real +.5 /Ref 12 3 R /Array [1 2 3 0 R true false null] % comment\n" +
            "/Literal (a(b)c\\)\\\\\\101\\n\\\r\nx) /Hex <48 65 6c6C 6>>>") as? PDFDictionary)
        XCTAssertEqual((dictionary["Name"] as? PDFName)?.value, "A B#")
        XCTAssertEqual((dictionary["Int"] as? PDFNumber)?.integer, -12)
        let real = try XCTUnwrap(dictionary["Real"] as? PDFNumber)
        XCTAssertEqual(real.value, 0.5)
        XCTAssertNil(real.integer)
        let reference = try XCTUnwrap(dictionary["Ref"] as? PDFReference)
        XCTAssertEqual(reference.number, 12)
        XCTAssertEqual(reference.generation, 3)
        let array = try XCTUnwrap(dictionary["Array"] as? PDFArray)
        XCTAssertEqual(array.items.count, 6)
        guard array.items.count == 6 else { return }
        XCTAssertEqual((array.items[0] as? PDFNumber)?.integer, 1)
        XCTAssertEqual((array.items[1] as? PDFNumber)?.integer, 2)
        XCTAssertEqual((array.items[2] as? PDFReference)?.number, 3)
        XCTAssertEqual((array.items[3] as? PDFBoolean)?.value, true)
        XCTAssertEqual((array.items[4] as? PDFBoolean)?.value, false)
        XCTAssertTrue(array.items[5] is PDFNull)
        XCTAssertEqual((dictionary["Literal"] as? PDFString)?.bytes, PDFFixture.latin1("a(b)c)\\A\nx"))
        let hex = try XCTUnwrap(dictionary["Hex"] as? PDFString)
        XCTAssertTrue(hex.isHex)
        XCTAssertEqual(hex.bytes, PDFFixture.latin1("Hell`"))
    }

    func test_values_writeBackAsTheSameValues() throws {
        let text = "<</A#20B /x /S (a\\(b\\)\\\\c\r\u{E9}) /H <00FF> /N -.5 /R 4 0 R /Arr [/a 1 [2]] /D <</In true>>>>"
        let written = try parse(text).description
        XCTAssertEqual(written, "<</A#20B /x /S (a\\(b\\)\\\\c\\n\\351) /H <00FF> /N -.5 /R 4 0 R /Arr [/a 1 [2]] /D <</In true>>>>")
        XCTAssertEqual(try parse(written).description, written)
    }

    func test_lexer_refusesWhatIsNotAnObject() {
        assertProblem("<</A (open", .damaged)
        assertProblem("<</A 1 2>>", .damaged)
        assertProblem("[1 2", .damaged)
        assertProblem("1.2.3", .damaged)
        assertProblem(String(repeating: "[", count: 500), .unsupported)
    }

    // MARK: - Filters

    func test_pngPredictors_undoEveryRowFilter() throws {
        // Two rows of three bytes, one byte per pixel: None, Sub, Up, Average, Paeth.
        let rows: [UInt8] = [10, 20, 30, 15, 25, 40]
        func encode(_ type: Int) -> [UInt8] {
            var output: [UInt8] = []
            var previous: [Int] = [0, 0, 0]
            for r in 0..<2 {
                output.append(UInt8(type))
                for i in 0..<3 {
                    let x = Int(rows[r * 3 + i])
                    let a = i > 0 ? Int(rows[r * 3 + i - 1]) : 0
                    let b = previous[i]
                    let c = i > 0 ? previous[i - 1] : 0
                    let p = a + b - c
                    let pa = abs(p - a)
                    let pb = abs(p - b)
                    let pc = abs(p - c)
                    let predicted: Int
                    switch type {
                    case 0: predicted = 0
                    case 1: predicted = a
                    case 2: predicted = b
                    case 3: predicted = (a + b) / 2
                    default: predicted = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                    }
                    output.append(UInt8(truncatingIfNeeded: x - predicted))
                }
                previous = [Int(rows[r * 3]), Int(rows[r * 3 + 1]), Int(rows[r * 3 + 2])]
            }
            return output
        }
        let parameters = try XCTUnwrap(parse("<</Predictor 15 /Columns 3>>") as? PDFDictionary)
        for type in 0...4 {
            XCTAssertEqual(try PDFFilters.predict(encode(type), parameters), rows, "row filter \(type)")
        }
        // TIFF predictor 2: each byte after the first of a row is the difference from the one before.
        let tiff = try XCTUnwrap(parse("<</Predictor 2 /Columns 3>>") as? PDFDictionary)
        XCTAssertEqual(try PDFFilters.predict([10, 10, 10, 15, 10, 15], tiff), rows)
    }

    func test_filters_inflateFlate_refuseOthers() throws {
        let data = Array("hello hello hello".utf8)
        XCTAssertEqual(try PDFFilters.decode(PDFFixture.deflate(data), filter: PDFName("FlateDecode"), parameters: nil), data)
        let zlib: [UInt8] = [0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0x40, 0x90, 0x00, 0x3A, 0x2E, 0x06, 0x7D]
        XCTAssertEqual(try PDFFilters.decode(zlib, filter: PDFName("FlateDecode"), parameters: nil), data)
        var wrong = PDFFixture.deflate(data)
        wrong[wrong.count - 1] ^= 1 // the Adler-32
        XCTAssertThrowsError(try PDFFilters.decode(wrong, filter: PDFName("FlateDecode"), parameters: nil)) { error in
            XCTAssertEqual((error as? PDFReadError)?.problem, .damaged)
        }
        XCTAssertEqual(try PDFFilters.decode(data, filter: nil, parameters: nil), data)
        XCTAssertThrowsError(try PDFFilters.decode(data, filter: PDFName("LZWDecode"), parameters: nil)) { error in
            XCTAssertEqual((error as? PDFReadError)?.problem, .unsupported)
        }
        XCTAssertThrowsError(try PDFFilters.decode([0xFF, 0xFF, 0xFF, 0xFF], filter: PDFName("FlateDecode"), parameters: nil)) { error in
            XCTAssertEqual((error as? PDFReadError)?.problem, .damaged)
        }
    }
}
