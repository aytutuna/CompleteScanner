import XCTest
import CoreGraphics
import Foundation
import ImageIO
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/CcittG4EncoderTests.cs: the same known answers (written
// from the bit strings of ITU-T T.4 and T.6, not from the encoder's own tables) and the same golden
// bytes, pinned in C#. C# decodes with PdfPig; here the round trips decode with ImageIO, through a
// G4 TIFF around the data (`BilevelTIFF`), as CONTRACTS.md asks of the Mac's port. The every-run
// round trip decodes a sample of run lengths (every one up to 130, then every 61st, and each code
// boundary) so a debug build stays quick; the known answers cover the codes themselves.

final class CCITTG4EncoderTests: XCTestCase {
    private static let eofb = "000000000001" + "000000000001"

    /// The bit strings in order, then zero bits up to a byte boundary.
    static func bits(_ parts: [String]) -> [UInt8] {
        var all: [UInt8] = []
        for part in parts { all.append(contentsOf: Array(part.utf8)) }
        var bytes = [UInt8](repeating: 0, count: (all.count + 7) / 8)
        for i in 0..<all.count where all[i] == UInt8(ascii: "1") {
            bytes[i / 8] |= UInt8(0x80 >> (i % 8))
        }
        return bytes
    }

    /// Packed rows (`Bilevel` layout) from rows of "1" (black) and "0" (white).
    static func rows(_ rows: [String]) -> [UInt8] {
        var grid: [[UInt8]] = []
        for row in rows { grid.append(Array(row.utf8)) }
        let width = grid[0].count
        return packed(width: width, height: grid.count) { x, y in grid[y][x] == UInt8(ascii: "1") }
    }

    /// Packed rows of `width` × `height` pixels, black where `black(x, y)`; asked row by row, left to
    /// right (the order the C# tests draw seeded noise in).
    static func packed(width: Int, height: Int, _ black: (Int, Int) -> Bool) -> [UInt8] {
        let stride = Bilevel.stride(width)
        var packed = [UInt8](repeating: 0xFF, count: stride * height)
        for y in 0..<height {
            for x in 0..<width where black(x, y) {
                let mask = UInt8(0x80 >> (x & 7))
                packed[y * stride + (x >> 3)] &= ~mask
            }
        }
        return packed
    }

    /// An image of black (true) and white pixels.
    static func image(width: Int, height: Int, _ black: (Int, Int) -> Bool) -> RgbaImage {
        Bilevel.unpack(packed(width: width, height: height, black), width: width, height: height)
    }

    /// The G4 file of a packed image decoded by ImageIO, as packed rows; nil when ImageIO decodes nothing.
    static func decodeWithImageIO(_ packed: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let tiff = BilevelTIFF.make(Bilevel.unpack(packed, width: width, height: height), dpi: 300)
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == width, decoded.height == height,
              let rgba = ColorAnalysis.rgbaPixels(of: decoded) else {
            return nil
        }
        return Bilevel.pack(rgba: rgba, width: width, height: height)
    }

    /// What a round trip does when ImageIO decodes no G4 TIFF: a failure on the Mac; in the iOS
    /// Simulator a skip that says why (never a silent pass).
    static func imageIODecodedNothing(_ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        #if os(iOS)
        throw XCTSkip("ImageIO in the iOS Simulator decoded nothing from \(what); the macOS run checks this round trip.")
        #else
        XCTFail("ImageIO did not decode \(what)", file: file, line: line)
        #endif
    }

    /// Encodes, decodes with ImageIO and expects every pixel back; returns the G4 data.
    @discardableResult
    private func assertRoundTrip(_ packed: [UInt8], width: Int, height: Int,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        let g4 = try CCITTG4Encoder.encode(packed, width: width, height: height)
        guard let decoded = Self.decodeWithImageIO(packed, width: width, height: height) else {
            try Self.imageIODecodedNothing("the \(width) × \(height) G4 TIFF", file: file, line: line)
            return g4
        }
        XCTAssertEqual(decoded.count, packed.count, file: file, line: line)
        for y in 0..<height {
            for x in 0..<width {
                let expected = Bilevel.isBlack(packed, width: width, x: x, y: y)
                if Bilevel.isBlack(decoded, width: width, x: x, y: y) != expected {
                    XCTFail("\(width) × \(height): pixel (\(x), \(y)) differs after decoding", file: file, line: line)
                    return g4
                }
            }
        }
        return g4
    }

    private static func text(_ code: CCITTG4Encoder.Code) -> String {
        var characters: [Character] = []
        var i = code.length - 1
        while i >= 0 {
            characters.append((code.code >> i) & 1 == 1 ? "1" : "0")
            i -= 1
        }
        return String(characters)
    }

    private static func assertPrefixFree(_ codes: [String], _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<codes.count {
            for j in 0..<codes.count where i != j {
                XCTAssertFalse(codes[j].hasPrefix(codes[i]), "\(what): \(codes[i]) is a prefix of \(codes[j])",
                               file: file, line: line)
            }
        }
    }

    private static func texts(_ tables: [[CCITTG4Encoder.Code]]) -> [String] {
        var result: [String] = []
        for table in tables {
            for code in table { result.append(text(code)) }
        }
        return result
    }

    // MARK: - Code tables

    func test_codeTables_coverEveryRun_andArePrefixFreePerColor() {
        XCTAssertEqual(CCITTG4Encoder.whiteTerminating.count, 64)
        XCTAssertEqual(CCITTG4Encoder.blackTerminating.count, 64)
        XCTAssertEqual(CCITTG4Encoder.whiteMakeUp.count, 27)
        XCTAssertEqual(CCITTG4Encoder.blackMakeUp.count, 27)
        XCTAssertEqual(CCITTG4Encoder.extendedMakeUp.count, 13)
        XCTAssertEqual(CCITTG4Encoder.vertical.count, 7)

        let eol = "000000000001"
        var white = Self.texts([CCITTG4Encoder.whiteTerminating, CCITTG4Encoder.whiteMakeUp, CCITTG4Encoder.extendedMakeUp])
        white.append(eol)
        Self.assertPrefixFree(white, "white")
        var black = Self.texts([CCITTG4Encoder.blackTerminating, CCITTG4Encoder.blackMakeUp, CCITTG4Encoder.extendedMakeUp])
        black.append(eol)
        Self.assertPrefixFree(black, "black")
        var modes = Self.texts([CCITTG4Encoder.vertical])
        modes.append(Self.text(CCITTG4Encoder.Code(code: CCITTG4Encoder.passCode, length: CCITTG4Encoder.passLength)))
        modes.append(Self.text(CCITTG4Encoder.Code(code: CCITTG4Encoder.horizontalCode,
                                                   length: CCITTG4Encoder.horizontalLength)))
        modes.append(eol)
        Self.assertPrefixFree(modes, "modes")

        // A few entries checked against T.4 by hand.
        XCTAssertEqual(Self.text(CCITTG4Encoder.whiteTerminating[0]), "00110101")
        XCTAssertEqual(Self.text(CCITTG4Encoder.blackTerminating[0]), "0000110111")
        XCTAssertEqual(Self.text(CCITTG4Encoder.whiteTerminating[63]), "00110100")
        XCTAssertEqual(Self.text(CCITTG4Encoder.blackTerminating[63]), "000001100111")
        XCTAssertEqual(Self.text(CCITTG4Encoder.whiteMakeUp[26]), "010011011")      // 1728
        XCTAssertEqual(Self.text(CCITTG4Encoder.blackMakeUp[26]), "0000001100101")  // 1728
        XCTAssertEqual(Self.text(CCITTG4Encoder.extendedMakeUp[0]), "00000001000")   // 1792
        XCTAssertEqual(Self.text(CCITTG4Encoder.extendedMakeUp[12]), "000000011111") // 2560
    }

    // MARK: - Known answers

    func test_allWhite_isOneV0PerRow_thenEofb() throws {
        let g4 = try CCITTG4Encoder.encode(Self.packed(width: 1728, height: 10) { _, _ in false }, width: 1728, height: 10)
        XCTAssertEqual(g4, Self.bits(["1111111111", Self.eofb]))
        XCTAssertEqual(g4, [0xFF, 0xC0, 0x04, 0x00, 0x40])
        XCTAssertEqual(g4, CCITTG4Encoder.encode(RgbaImage.filled(width: 1728, height: 10, r: 255, g: 255, b: 255)))
    }

    func test_allBlack_isOneHorizontalRow_thenTwoV0PerRow() throws {
        let g4 = try CCITTG4Encoder.encode(Self.packed(width: 1728, height: 10) { _, _ in true }, width: 1728, height: 10)
        // Row 1 against the white row above: horizontal, white 0, black 1728 (make-up 1728 + 0).
        // Every later row: V0 under the black run's start, V0 at the end.
        let later = String(repeating: "11", count: 9)
        XCTAssertEqual(g4, Self.bits(["001", "00110101", "0000001100101", "0000110111", later, Self.eofb]))
        XCTAssertEqual(g4.count, 10)
        XCTAssertEqual(g4, CCITTG4Encoder.encode(RgbaImage.filled(width: 1728, height: 10, r: 0, g: 0, b: 0)))
    }

    func test_modeCodes_passHorizontalAndEveryVerticalOffset() throws {
        let packed = Self.rows([
            "00011000",  // H: white 3, black 2; V0
            "00011000",  // V0 V0 V0
            "00110000",  // VL1 VL1 V0
            "00000000",  // pass, V0
            "00000011",  // VL2 (b1 is the row's end), V0
            "00000001",  // VR1, V0
            "01111111",  // H: white 1, black 7
            "11111000",  // VL1, VL3, V0
            "00001110",  // H: white 4, black 3; V0
            "00000011",  // VR2, VR1
            "11111111",  // H: white 0, black 8
            "11100000",  // V0, H starting black: black 3, white 5
            "00011111",  // VR3, V0
        ])
        let g4 = try CCITTG4Encoder.encode(packed, width: 8, height: 13)
        let expected: [String] = [
            "001", "1000", "11", "1",
            "1", "1", "1",
            "010", "010", "1",
            "0001", "1",
            "000010", "1",
            "011", "1",
            "001", "000111", "00011",
            "010", "0000010", "1",
            "001", "1011", "10", "1",
            "000011", "011",
            "001", "00110101", "000101",
            "1", "001", "10", "1100",
            "0000011", "1",
            Self.eofb,
        ]
        XCTAssertEqual(g4, Self.bits(expected))
        try assertRoundTrip(packed, width: 8, height: 13)
    }

    func test_longRuns_repeatTheLargestExtendedMakeUpCode() throws {
        // White 5200 = 2560 + 2560 + 64 + 16; black 2800 = 2560 + 192 + 48.
        var g4 = try CCITTG4Encoder.encode(Self.packed(width: 8000, height: 1) { x, _ in x >= 5200 }, width: 8000, height: 1)
        XCTAssertEqual(g4, Self.bits(["001",
                                      "000000011111", "000000011111", "11011", "101010",
                                      "000000011111", "000011001001", "000001100100",
                                      Self.eofb]))

        // 2624 is the first run with two make-up codes (2560 + 64 + 0); 2623 is 2560 + 63.
        g4 = try CCITTG4Encoder.encode(Self.packed(width: 5247, height: 1) { x, _ in x >= 2624 }, width: 5247, height: 1)
        XCTAssertEqual(g4, Self.bits(["001",
                                      "000000011111", "11011", "00110101",
                                      "000000011111", "000001100111",
                                      Self.eofb]))
    }

    func test_noRows_isJustEofb() throws {
        XCTAssertEqual(try CCITTG4Encoder.encode([], width: 100, height: 0), [0x00, 0x10, 0x01])
    }

    func test_singlePixels_andOnePixelLines() throws {
        // A black pixel: VL1 (a1 = 0, one left of b1 at the row's end), then V0.
        XCTAssertEqual(try CCITTG4Encoder.encode(Self.rows(["1"]), width: 1, height: 1), Self.bits(["010", "1", Self.eofb]))
        XCTAssertEqual(try CCITTG4Encoder.encode(Self.rows(["0"]), width: 1, height: 1), Self.bits(["1", Self.eofb]))
        // A one-pixel-wide column and a one-pixel-tall row, both with a pattern.
        let column = Self.packed(width: 1, height: 17) { _, y in y % 3 != 1 }
        try assertRoundTrip(column, width: 1, height: 17)
        let row = Self.packed(width: 997, height: 1) { x, _ in x % 5 < 2 || x > 900 }
        try assertRoundTrip(row, width: 997, height: 1)
    }

    func test_arguments_areChecked() {
        XCTAssertThrowsError(try CCITTG4Encoder.encode([UInt8](repeating: 0, count: 4), width: 0, height: 1))
        XCTAssertThrowsError(try CCITTG4Encoder.encode([UInt8](repeating: 0, count: 4), width: 8, height: -1))
        XCTAssertThrowsError(try CCITTG4Encoder.encode([UInt8](repeating: 0, count: 3), width: 9, height: 2)) // needs 4 bytes
    }

    // MARK: - Round trips through a separate decoder (ImageIO)

    func test_roundTrip_runLengthsOfBothColors() throws {
        // Rows separated by white rows, so each is coded in horizontal mode: white L then black,
        // and black L then white. Every L up to 130, every 61st after it, and each code boundary.
        var runs: [Int] = []
        for run in 1...130 { runs.append(run) }
        var run = 131
        while run <= 2700 {
            runs.append(run)
            run += 61
        }
        for boundary in [1727, 1728, 1729, 1791, 1792, 1793, 2559, 2560, 2561, 2623, 2624, 2625, 2700] {
            runs.append(boundary)
        }
        let width = 2710
        let height = runs.count * 4
        let packed = Self.packed(width: width, height: height) { x, y in
            let length = runs[y / 4]
            switch y % 4 {
            case 1: return x >= length
            case 3: return x < length
            default: return false
            }
        }
        try assertRoundTrip(packed, width: width, height: height)
    }

    func test_roundTrip_oddWidths() throws {
        for width in [1, 2, 7, 8, 9, 15, 17, 1727, 1729] {
            let rng = TestPages.Rng(UInt32(0xB1E0 + width))
            // Noise, a checkerboard and runs that end on the last pixel.
            let packed = Self.packed(width: width, height: 24) { x, y in
                if y < 8 { return rng.below(3) == 0 }
                if y < 16 { return ((x + y) & 1) == 0 }
                return x >= width - (y - 15)
            }
            try assertRoundTrip(packed, width: width, height: 24)
        }
    }

    func test_roundTrip_veryWideRows() throws {
        let rng = TestPages.Rng(0x5EED_0001)
        let packed = Self.packed(width: 20000, height: 12) { x, y in
            switch y {
            case 0: return true
            case 1: return x >= 3 && x < 15000
            case 2: return x % 2629 == 0
            case 3: return x >= 10000
            case 4: return x < 2624 || (x >= 5184 && x < 5247)
            case 5: return rng.below(50) == 0
            default: return (x / 97 + y) % 3 == 0
            }
        }
        try assertRoundTrip(packed, width: 20000, height: 12)
    }

    // MARK: - Golden bytes (pinned in C#)

    func test_golden_checkerboard_noise_textPage() throws {
        let checkerBits = Self.packed(width: 37, height: 23) { x, y in ((x + y) & 1) == 0 }
        let checker = try CCITTG4Encoder.encode(checkerBits, width: 37, height: 23)
        XCTAssertEqual(checker.count, 335)
        XCTAssertEqual(CompanionPackage.sha256Hex(Data(checker)).uppercased(),
                       "E8A046161C50C7D37EA4A44DC4A9F1DCE909940D388C27C8CCECCBE798DC43EC")

        let rng = TestPages.Rng(0xC0FF_EE01)
        let noiseBits = Self.packed(width: 517, height: 211) { _, _ in rng.below(2) == 0 }
        let noise = try CCITTG4Encoder.encode(noiseBits, width: 517, height: 211)
        XCTAssertEqual(noise.count, 28704)
        XCTAssertEqual(CompanionPackage.sha256Hex(Data(noise)).uppercased(),
                       "4255D22C831C890F8DAFAC2B936E2CAB95D2AB5FAAD06CC844C04E5AB8D215C0")

        // The blank-page tests' text page (850 × 1100 at 100 dpi) made black & white.
        let text = TestPages.textPage().toRgba()
        let page = CCITTG4Encoder.encode(text)
        XCTAssertEqual(page.count, 17666)
        XCTAssertEqual(CompanionPackage.sha256Hex(Data(page)).uppercased(),
                       "DD8EC2973FEA77FBB02C0DBD9A9BC69C9771852D2AD18B70AEF0387D94EC4DFE")

        // Each decodes back to its pixels.
        try assertRoundTrip(checkerBits, width: 37, height: 23)
        try assertRoundTrip(noiseBits, width: 517, height: 211)
        try assertRoundTrip(Bilevel.pack(text), width: text.width, height: text.height)
    }

    // MARK: - Bilevel

    func test_bilevel_thresholdsLumaAt128() {
        // Gray 127 is black, 128 white; pure red (luma 76) black, pure green (150) white;
        // (255, 0, 136): luma 76 + 0 + 16 = 92 black.
        let pixels: [UInt8] = [
            127, 127, 127, 255, 128, 128, 128, 255, 255, 0, 0, 255, 0, 255, 0, 255, 255, 0, 136, 255,
        ]
        let image = RgbaImage(width: 5, height: 1, pixels: pixels)
        let packed = Bilevel.pack(image)
        XCTAssertEqual(packed, [0b0101_0111]) // black, white, black, white, black, then padding
        var black: [Bool] = []
        for x in 0..<5 { black.append(Bilevel.isBlack(packed, width: 5, x: x, y: 0)) }
        XCTAssertEqual(black, [true, false, true, false, true])
        XCTAssertEqual(Bilevel.stride(1), 1)
        XCTAssertEqual(Bilevel.stride(8), 1)
        XCTAssertEqual(Bilevel.stride(9), 2)
    }

    func test_bilevel_packAndUnpack_roundTrip_withWhitePadding() {
        let rng = TestPages.Rng(0xB11_EBE1)
        let packed = Self.packed(width: 13, height: 5) { _, _ in rng.below(2) == 0 }
        let image = Bilevel.unpack(packed, width: 13, height: 5)
        XCTAssertEqual(Bilevel.pack(image), packed)
        for y in 0..<5 {
            XCTAssertEqual(packed[y * 2 + 1] & 0b0000_0111, 0b0000_0111)
        }
        for p in 0..<(image.pixels.count / 4) {
            let value = image.pixels[p * 4]
            XCTAssertTrue(value == 0 || value == 255)
            XCTAssertEqual(image.pixels[p * 4 + 3], 255)
        }
    }

    func test_encode_ofAnImage_isTheEncodingOfItsPackedBits() throws {
        let page = TestPages.textPage().toRgba()
        XCTAssertEqual(CCITTG4Encoder.encode(page),
                       try CCITTG4Encoder.encode(Bilevel.pack(page), width: page.width, height: page.height))
        let g4 = PDFImageData.encodeCCITTG4(page)
        guard case .ccittG4(let data, let width, let height) = g4 else {
            return XCTFail("Not a G4 image: \(g4)")
        }
        XCTAssertEqual(width, page.width)
        XCTAssertEqual(height, page.height)
        XCTAssertEqual(data, Data(CCITTG4Encoder.encode(page)))
    }
}
