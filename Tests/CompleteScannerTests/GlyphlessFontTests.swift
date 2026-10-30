import XCTest
import Compression
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/GlyphlessFontTests.cs: the same tables, checksums and
// pinned bytes (the font program's and the CIDToGIDMap's lengths and SHA-256, pinned in C#). The map
// is inflated here with the Compression framework (raw deflate between the zlib header and the
// Adler-32), where C# uses ZLibStream. A Swift string cannot hold a lone surrogate, so the lone
// surrogates of the C# case come from UTF-16 decoding, which makes them U+FFFD, as C# writes them.

final class GlyphlessFontTests: XCTestCase {
    private struct TableEntry {
        let offset: Int
        let length: Int
        let checksum: UInt32
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> Int {
        (Int(b[at]) << 8) | Int(b[at + 1])
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        let high = (UInt32(b[at]) << 24) | (UInt32(b[at + 1]) << 16)
        let low = (UInt32(b[at + 2]) << 8) | UInt32(b[at + 3])
        return high | low
    }

    private static func tag(_ font: [UInt8], _ at: Int) -> String {
        String(decoding: font[at..<(at + 4)], as: UTF8.self)
    }

    /// The table directory of a TrueType font: tag → (offset, length, stored checksum).
    private static func tables(_ font: [UInt8]) -> [String: TableEntry] {
        var result: [String: TableEntry] = [:]
        let count = u16(font, 4)
        for i in 0..<count {
            let at = 12 + i * 16
            let entry = TableEntry(offset: Int(u32(font, at + 8)), length: Int(u32(font, at + 12)),
                                   checksum: u32(font, at + 4))
            result[tag(font, at)] = entry
        }
        return result
    }

    private static func sha256(_ bytes: [UInt8]) -> String {
        CompanionPackage.sha256Hex(Data(bytes)).uppercased()
    }

    /// The numbers before each `word` ("100 beginbfrange" → 100), in order.
    private static func counts(before word: String, in text: String) -> [Int] {
        var result: [Int] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2 && parts[1] == Substring(word), let value = Int(parts[0]) {
                result.append(value)
            }
        }
        return result
    }

    func test_program_isATrueTypeFontWithItsTablesInOrder() {
        let font = GlyphlessFont.program
        XCTAssertEqual(Self.u32(font, 0), 0x0001_0000)
        XCTAssertEqual(Self.u16(font, 4), 10)
        XCTAssertEqual(Self.u16(font, 6), 128) // searchRange
        XCTAssertEqual(Self.u16(font, 8), 3)   // entrySelector
        XCTAssertEqual(Self.u16(font, 10), 32) // rangeShift
        var tags: [String] = []
        for i in 0..<10 { tags.append(Self.tag(font, 12 + i * 16)) }
        XCTAssertEqual(tags, ["OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"])
        for (tag, entry) in Self.tables(font) {
            XCTAssertEqual(entry.offset % 4, 0, tag)
            XCTAssertTrue(entry.offset + entry.length <= font.count, tag)
        }
        XCTAssertEqual(font.count % 4, 0)
    }

    func test_program_checksumsAreRight() throws {
        let font = GlyphlessFont.program
        let tables = Self.tables(font)
        for (tag, entry) in tables {
            var data = Array(font[entry.offset..<(entry.offset + entry.length)])
            if tag == "head" {
                // The head is summed without its checksum adjustment.
                for i in 8..<12 { data[i] = 0 }
            }
            XCTAssertEqual(GlyphlessFont.checksum(data), entry.checksum, tag)
        }
        // The adjustment makes the whole file sum to the magic number.
        XCTAssertEqual(GlyphlessFont.checksum(font), 0xB1B0_AFBA)
        let head = try XCTUnwrap(tables["head"])
        XCTAssertEqual(Self.u32(font, head.offset + 12), 0x5F0F_3CF5)
    }

    func test_program_hasTwoEmptyGlyphsHalfAnEmWide() throws {
        let font = GlyphlessFont.program
        let t = Self.tables(font)
        let head = try XCTUnwrap(t["head"]).offset
        let hhea = try XCTUnwrap(t["hhea"]).offset
        let maxp = try XCTUnwrap(t["maxp"]).offset
        XCTAssertEqual(Self.u16(font, head + 18), 1000)        // unitsPerEm
        XCTAssertEqual(Self.u16(font, head + 50), 0)           // short loca offsets
        XCTAssertEqual(Self.u16(font, maxp + 4), 2)            // numGlyphs
        XCTAssertEqual(Self.u32(font, maxp), 0x0001_0000)      // TrueType maxp
        XCTAssertEqual(Self.u16(font, hhea + 4), 1000)         // ascender
        XCTAssertEqual(Self.u16(font, hhea + 6), 0)            // descender
        XCTAssertEqual(Self.u16(font, hhea + 34), 2)           // numberOfHMetrics
        let hmtx = try XCTUnwrap(t["hmtx"])
        XCTAssertEqual(hmtx.length, 8)
        XCTAssertEqual(Self.u16(font, hmtx.offset), 500)
        XCTAssertEqual(Self.u16(font, hmtx.offset + 4), 500)
        let loca = try XCTUnwrap(t["loca"])
        XCTAssertEqual(loca.length, 6)
        for i in 0..<3 { XCTAssertEqual(Self.u16(font, loca.offset + i * 2), 0) } // both glyphs empty
        let os2 = try XCTUnwrap(t["OS/2"]).offset
        XCTAssertEqual(Self.u16(font, os2 + 8), 0)         // fsType: embedding allowed
        // The name table names the font as the PDF does.
        let name = try XCTUnwrap(t["name"])
        let storage = name.offset + Self.u16(font, name.offset + 4)
        var units: [UInt16] = []
        var at = storage
        while at + 1 < name.offset + name.length {
            units.append(UInt16(Self.u16(font, at)))
            at += 2
        }
        XCTAssertTrue(String(decoding: units, as: UTF16.self).contains(GlyphlessFont.fontName))
    }

    func test_program_bytesArePinned() {
        // The same bytes as C#'s GlyphlessFontTests.Program_BytesArePinned.
        let font = GlyphlessFont.program
        XCTAssertEqual(font.count, 636)
        XCTAssertEqual(Self.sha256(font), "103B87CF98EE3A3E5FD752F3DB29975611605F785B36C879FAA61ABD439CC391")
        XCTAssertEqual(GlyphlessFont.build(), font)
    }

    func test_cidToGidMap_inflatesToGlyphOneForEveryCode() throws {
        let compressed = GlyphlessFont.cidToGidMap
        // zlib header, then raw deflate, then the Adler-32 of the data.
        XCTAssertEqual(compressed[0], 0x78)
        XCTAssertEqual(compressed[1], 0x01)
        let deflated = Array(compressed[2..<(compressed.count - 4)])
        let expectedCount = GlyphlessFont.codeCount * 2
        var map = [UInt8](repeating: 0xEE, count: expectedCount + 64)
        let capacity = map.count
        let written: Int = map.withUnsafeMutableBufferPointer { output -> Int in
            deflated.withUnsafeBufferPointer { input -> Int in
                compression_decode_buffer(output.baseAddress!, capacity, input.baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertEqual(written, expectedCount)
        map.removeSubrange(written..<map.count)
        var wrong = 0
        var i = 0
        while i < map.count {
            if map[i] != 0 || map[i + 1] != 1 { wrong += 1 }
            i += 2
        }
        XCTAssertEqual(wrong, 0, "codes that do not map to glyph 1")
        XCTAssertEqual(map, GlyphlessFont.cidToGidMapData())
        XCTAssertEqual(GlyphlessFont.adler32(map), Self.u32(compressed, compressed.count - 4))
    }

    func test_cidToGidMap_bytesArePinned() {
        let compressed = GlyphlessFont.cidToGidMap
        XCTAssertEqual(compressed.count, 837)
        XCTAssertEqual(Self.sha256(compressed), "2B554AACC4A744E7F14EF4BE52FA515B70E9AE4A60402C38B1D404E8EC7AE17E")
    }

    func test_adler32_knownValues() {
        XCTAssertEqual(GlyphlessFont.adler32([]), 0x0000_0001)
        XCTAssertEqual(GlyphlessFont.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
    }

    func test_toUnicode_mapsEveryCodeOutsideTheSurrogatesToItself_inBlocksOfAtMost100() {
        let cmap = GlyphlessCodes.of([]).toUnicodeCMap()
        XCTAssertTrue(cmap.contains("1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"))
        XCTAssertEqual(Self.counts(before: "beginbfrange", in: cmap), [100, 100, 48])
        XCTAssertFalse(cmap.contains("bfchar"))
        var expected = ""
        for high in 0..<256 where high < 0xD8 || high > 0xDF {
            let h = GlyphlessCodes.hex(high, digits: 2)
            expected += "<\(h)00> <\(h)FF> <\(h)00>\n"
        }
        var ranges = ""
        for line in cmap.split(separator: "\n") where line.hasPrefix("<") && line.split(separator: " ").count == 3 {
            ranges += String(line)
            ranges += "\n"
        }
        XCTAssertEqual(ranges, expected)
        XCTAssertTrue(cmap.utf8.allSatisfy { $0 < 0x80 }, "ASCII only")
        XCTAssertTrue(cmap.hasSuffix("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"))
    }

    func test_codes_areTheUtf16CodeUnitsInTheBmp() {
        let codes = GlyphlessCodes.of(["Hi", "çğıİöşü"])
        XCTAssertTrue(codes.supplementary.isEmpty)
        XCTAssertEqual(codes.hexString("Hi"), "<00480069>")
        XCTAssertEqual(codes.hexString(""), "<>")
        // Turkish: ç ğ ı İ ö ş ü.
        XCTAssertEqual(codes.hexString("çğıİöşü"), "<00E7011F0131013000F6015F00FC>")
        XCTAssertEqual(codes.hexString("日本語"), "<65E5672C8A9E>")
        XCTAssertEqual(codes.hexString("مرڭ"), "<0645063106AD>")
    }

    func test_codes_beyondTheBmpGetSurrogateRangeCodes_inOrderOfFirstUse() {
        // U+1F4C4 (page facing up), U+2000B (a CJK Extension B ideograph), U+1D11E (G clef).
        let codes = GlyphlessCodes.of(["a \u{1F4C4} b", "\u{2000B}\u{1F4C4}", "", "\u{1D11E}"])
        XCTAssertEqual(codes.supplementary, [0x1F4C4, 0x2000B, 0x1D11E])
        XCTAssertEqual(codes.codes("a \u{1F4C4} b"), [0x61, 0x20, 0xD800, 0x20, 0x62])
        XCTAssertEqual(codes.hexString("\u{2000B}\u{1F4C4}\u{1D11E}"), "<D801D800D802>")
        // A character the codes were not built from, and lone surrogates (U+FFFD once decoded), are
        // written as U+FFFD.
        let lone = String(decoding: [0xD800, 0x78, 0xDC00] as [UInt16], as: UTF16.self)
        XCTAssertEqual(codes.codes("\u{1F600}" + lone), [0xFFFD, 0xFFFD, 0x78, 0xFFFD])
        let cmap = codes.toUnicodeCMap()
        XCTAssertTrue(cmap.contains("3 beginbfchar\n<D800> <D83DDCC4>\n<D801> <D840DC0B>\n<D802> <D834DD1E>\nendbfchar\n"))
    }

    func test_codes_beyondTheBmp_stopAt2048() {
        var many = ""
        for value in 0x20000..<(0x20000 + 2100) {
            many.unicodeScalars.append(Unicode.Scalar(UInt32(value))!)
        }
        let codes = GlyphlessCodes.of([many])
        XCTAssertEqual(codes.supplementary.count, GlyphlessCodes.supplementaryCapacity)
        let written = codes.codes(many)
        XCTAssertEqual(written.count, 2100)
        XCTAssertEqual(written[2047], 0xDFFF)
        XCTAssertTrue(written[2048...].allSatisfy { $0 == 0xFFFD })
        let cmap = codes.toUnicodeCMap()
        var expected = [Int](repeating: 100, count: 20)
        expected.append(48)
        XCTAssertEqual(Self.counts(before: "beginbfchar", in: cmap), expected)
    }

    func test_textWidth_isHalfTheSizePerCode() {
        XCTAssertEqual(GlyphlessFont.textWidth(codeCount: 5, fontSize: 10), 25.0)
        XCTAssertEqual(GlyphlessFont.textWidth(codeCount: 0, fontSize: 10), 0.0)
        let codes = GlyphlessCodes.of(["日本\u{2000B}"])
        // One code per character.
        XCTAssertEqual(GlyphlessFont.textWidth(codeCount: codes.codes("日本\u{2000B}").count, fontSize: 12), 18.0)
    }
}
