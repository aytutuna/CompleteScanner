import Foundation

// Twin of windows/CompleteScanner.Core/GlyphlessFont.cs: the same font program, the same hand-made
// zlib stream (its own Deflate encoder, no compression library) and the same ToUnicode map, byte
// for byte (the lengths and SHA-256 pinned in GlyphlessFontTests on both platforms).

/// The font of a PDF's invisible text layer: a tiny TrueType program whose only glyph draws nothing
/// and is half an em wide, embedded as a two-byte (Identity-H) composite font in which every
/// character code shows that glyph. A character of the Basic Multilingual Plane is written as its
/// own UTF-16 code unit; the few characters beyond it (rare CJK, emoji) get a code of the surrogate
/// range, which never stands for a character on its own (`GlyphlessCodes`). Any text in any script
/// can then be written to the page, selected, searched and copied out through the ToUnicode map,
/// and nothing about it depends on fonts installed anywhere. Everything here is built from code,
/// deterministically, so the bytes are the same on every run and platform.
public enum GlyphlessFont {
    /// The font's name, in the PDF (/BaseFont, /FontName) and in its name table.
    public static let fontName = "GlyphLessFont"

    /// Units per em of the font program.
    public static let unitsPerEm = 1000

    /// The advance of every glyph, in 1/1000 em: the PDF's /DW and the program's hmtx agree.
    public static let glyphWidth = 500

    /// Character codes: 0 to this (two bytes).
    public static let codeCount = 0x10000

    /// The TrueType program (/FontFile2), built once.
    public static let program: [UInt8] = build()

    /// The /CIDToGIDMap stream's data, zlib-compressed (/Filter /FlateDecode): every code to glyph
    /// 1, so no code ever shows the .notdef glyph. Built once.
    public static let cidToGidMap: [UInt8] = buildCidToGidMap()

    /// How wide `codeCount` codes are set at `fontSize`: half the size each.
    public static func textWidth(codeCount: Int, fontSize: Double) -> Double {
        Double(codeCount) * (Double(glyphWidth) / 1000.0) * fontSize
    }

    // MARK: - The font program

    /// A TrueType font with two glyphs, both empty: .notdef and glyph 1, each 500 units wide on a
    /// 1000-unit em, ascent 1000 and descent 0. Tables: OS/2, cmap (U+0020 to glyph 1), glyf, head,
    /// hhea, hmtx, loca, maxp, name and post, with their checksums and the head's checksum adjustment.
    public static func build() -> [UInt8] {
        // The tags in ordinal order, as the C# SortedDictionary lists them.
        let tags: [String] = ["OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"]
        var tables: [[UInt8]] = []
        tables.append(os2Table())
        tables.append(cmapTable())
        tables.append([UInt8](repeating: 0, count: 4)) // glyf: both glyphs are empty; kept non-empty for strict readers
        tables.append(headTable())
        tables.append(hheaTable())
        tables.append(hmtxTable())
        tables.append(locaTable())
        tables.append(maxpTable())
        tables.append(nameTable())
        tables.append(postTable())

        let numTables = tables.count
        var searchPower = 1
        var entrySelector = 0
        while searchPower * 2 <= numTables {
            searchPower *= 2
            entrySelector += 1
        }
        var font = BigEndianWriter()
        font.u32(0x0001_0000)
        font.u16(numTables)
        font.u16(searchPower * 16)
        font.u16(entrySelector)
        font.u16(numTables * 16 - searchPower * 16)

        var offset = 12 + numTables * 16
        var headOffset = 0
        for index in 0..<numTables {
            let data = tables[index]
            font.ascii(tags[index])
            font.u32(checksum(data))
            font.u32(UInt32(offset))
            font.u32(UInt32(data.count))
            if tags[index] == "head" { headOffset = offset }
            offset += padded(data.count)
        }
        for data in tables {
            font.bytes(data)
            font.bytes([UInt8](repeating: 0, count: padded(data.count) - data.count))
        }
        var bytes = font.data
        // head.checkSumAdjustment (bytes 8-11 of the table) makes the whole file sum to 0xB1B0AFBA.
        let adjustment: UInt32 = UInt32(0xB1B0_AFBA) &- checksum(bytes)
        bytes[headOffset + 8] = UInt8(truncatingIfNeeded: adjustment >> 24)
        bytes[headOffset + 9] = UInt8(truncatingIfNeeded: adjustment >> 16)
        bytes[headOffset + 10] = UInt8(truncatingIfNeeded: adjustment >> 8)
        bytes[headOffset + 11] = UInt8(truncatingIfNeeded: adjustment)
        return bytes
    }

    private static func padded(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    /// The TrueType table checksum: the sum of its big-endian 32-bit words, zero-padded.
    static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < data.count {
            var word: UInt32 = 0
            for j in 0..<4 {
                let byte: UInt32 = i + j < data.count ? UInt32(data[i + j]) : 0
                word = (word << 8) | byte
            }
            sum = sum &+ word
            i += 4
        }
        return sum
    }

    private static func os2Table() -> [UInt8] {
        var t = BigEndianWriter()
        t.u16(4)                  // version
        t.i16(glyphWidth)         // xAvgCharWidth
        t.u16(400)                // usWeightClass: regular
        t.u16(5)                  // usWidthClass: medium
        t.u16(0)                  // fsType: installable, no embedding restrictions
        t.i16(650); t.i16(600); t.i16(0); t.i16(75)   // subscript x size, y size, x offset, y offset
        t.i16(650); t.i16(600); t.i16(0); t.i16(350)  // superscript x size, y size, x offset, y offset
        t.i16(50); t.i16(250)     // strikeout size, position
        t.i16(0)                  // sFamilyClass
        t.bytes([UInt8](repeating: 0, count: 10)) // panose: any
        t.u32(0); t.u32(0); t.u32(0); t.u32(0)    // ulUnicodeRange1-4
        t.ascii("NONE")           // achVendID
        t.u16(0x0040)             // fsSelection: regular
        t.u16(0x0020)             // usFirstCharIndex
        t.u16(0x0020)             // usLastCharIndex
        t.i16(unitsPerEm); t.i16(0); t.i16(0)   // typo ascender, descender, line gap
        t.u16(unitsPerEm); t.u16(0)             // win ascent, descent
        t.u32(1); t.u32(0)        // ulCodePageRange1-2: Latin 1
        t.i16(500); t.i16(unitsPerEm)           // sxHeight, sCapHeight
        t.u16(0); t.u16(0x0020); t.u16(1)       // usDefaultChar, usBreakChar, usMaxContext
        return t.data
    }

    private static func cmapTable() -> [UInt8] {
        // One Windows Unicode (3, 1) subtable, format 4: U+0020 to glyph 1, then the required
        // 0xFFFF segment. A PDF reaches the glyph through the CIDToGIDMap, never through this.
        var t = BigEndianWriter()
        t.u16(0)    // version
        t.u16(1)    // one encoding record
        t.u16(3); t.u16(1); t.u32(12)
        let segCount = 2
        t.u16(4)                        // format
        t.u16(16 + segCount * 8)        // length
        t.u16(0)                        // language
        t.u16(segCount * 2)             // segCountX2
        t.u16(2 * 2)                    // searchRange: 2 × 2^floor(log2(segCount))
        t.u16(1)                        // entrySelector
        t.u16(0)                        // rangeShift
        t.u16(0x0020); t.u16(0xFFFF)    // endCode
        t.u16(0)                        // reservedPad
        t.u16(0x0020); t.u16(0xFFFF)    // startCode
        t.i16(1 - 0x0020); t.i16(1)     // idDelta
        t.u16(0); t.u16(0)              // idRangeOffset
        return t.data
    }

    private static func headTable() -> [UInt8] {
        var t = BigEndianWriter()
        t.u32(0x0001_0000)        // version 1.0
        t.u32(0x0001_0000)        // fontRevision 1.0
        t.u32(0)                  // checkSumAdjustment: set once the whole font is laid out
        t.u32(0x5F0F_3CF5)        // magicNumber
        t.u16(0x000B)             // flags: baseline at y = 0, left sidebearing at x = 0, integer scaling
        t.u16(unitsPerEm)
        t.u32(0); t.u32(0)        // created: fixed, so the bytes never change
        t.u32(0); t.u32(0)        // modified
        t.i16(0); t.i16(0); t.i16(glyphWidth); t.i16(unitsPerEm) // xMin, yMin, xMax, yMax
        t.u16(0)                  // macStyle
        t.u16(8)                  // lowestRecPPEM
        t.i16(2)                  // fontDirectionHint
        t.i16(0)                  // indexToLocFormat: short offsets
        t.i16(0)                  // glyphDataFormat
        return t.data
    }

    private static func hheaTable() -> [UInt8] {
        var t = BigEndianWriter()
        t.u32(0x0001_0000)
        t.i16(unitsPerEm)         // ascender
        t.i16(0)                  // descender
        t.i16(0)                  // lineGap
        t.u16(glyphWidth)         // advanceWidthMax
        t.i16(0); t.i16(0)        // minLeftSideBearing, minRightSideBearing
        t.i16(0)                  // xMaxExtent
        t.i16(1); t.i16(0); t.i16(0) // caretSlopeRise, caretSlopeRun, caretOffset
        t.i16(0); t.i16(0); t.i16(0); t.i16(0) // reserved
        t.i16(0)                  // metricDataFormat
        t.u16(2)                  // numberOfHMetrics
        return t.data
    }

    private static func hmtxTable() -> [UInt8] {
        var t = BigEndianWriter()
        for _ in 0..<2 {
            t.u16(glyphWidth)
            t.i16(0)
        }
        return t.data
    }

    private static func locaTable() -> [UInt8] {
        var t = BigEndianWriter()
        for _ in 0..<3 { t.u16(0) } // short offsets (bytes / 2): both glyphs empty
        return t.data
    }

    private static func maxpTable() -> [UInt8] {
        var t = BigEndianWriter()
        t.u32(0x0001_0000)        // version 1.0 (TrueType outlines)
        t.u16(2)                  // numGlyphs
        t.u16(0); t.u16(0)        // maxPoints, maxContours
        t.u16(0); t.u16(0)        // maxCompositePoints, maxCompositeContours
        t.u16(2)                  // maxZones
        t.u16(0); t.u16(0); t.u16(0); t.u16(0) // twilight points, storage, function defs, instruction defs
        t.u16(0); t.u16(0)        // maxStackElements, maxSizeOfInstructions
        t.u16(0); t.u16(0)        // maxComponentElements, maxComponentDepth
        return t.data
    }

    private static func nameTable() -> [UInt8] {
        let ids: [Int] = [1, 2, 4, 6]
        let texts: [String] = [fontName, "Regular", fontName, fontName]
        var strings = BigEndianWriter()
        var records = BigEndianWriter()
        for index in 0..<ids.count {
            var utf16 = BigEndianWriter()
            for unit in texts[index].utf16 { utf16.u16(Int(unit)) }
            records.u16(3); records.u16(1); records.u16(0x0409); records.u16(ids[index])
            records.u16(utf16.count)
            records.u16(strings.count)
            strings.bytes(utf16.data)
        }
        var t = BigEndianWriter()
        t.u16(0)                          // format
        t.u16(ids.count)
        t.u16(6 + ids.count * 12)         // string storage offset
        t.bytes(records.data)
        t.bytes(strings.data)
        return t.data
    }

    private static func postTable() -> [UInt8] {
        var t = BigEndianWriter()
        t.u32(0x0003_0000)        // format 3: no glyph names
        t.u32(0)                  // italicAngle
        t.i16(-100); t.i16(50)    // underlinePosition, underlineThickness
        t.u32(1)                  // isFixedPitch
        t.u32(0); t.u32(0); t.u32(0); t.u32(0) // memory hints
        return t.data
    }

    // MARK: - CIDToGIDMap

    /// The map's uncompressed data: two bytes per code, each the glyph 0x0001.
    static func cidToGidMapData() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: codeCount * 2)
        var i = 1
        while i < data.count {
            data[i] = 1
            i += 2
        }
        return data
    }

    /// The map zlib-compressed by hand: one fixed-Huffman deflate block holding the literals 00 01,
    /// then back-references of 258 bytes at distance 2 (and one of 6) for the rest, the end of
    /// block, and the Adler-32 of the data. 837 bytes for 128 KiB, the same on every platform,
    /// with no compression library involved.
    private static func buildCidToGidMap() -> [UInt8] {
        var bits = DeflateBits()
        bits.bits(1, 1)               // BFINAL
        bits.bits(1, 2)               // BTYPE 01: fixed Huffman codes
        bits.literal(0x00)
        bits.literal(0x01)
        let remaining = codeCount * 2 - 2     // 131070 = 508 × 258 + 6
        for _ in 0..<(remaining / 258) { bits.match(258, distance: 2) }
        if remaining % 258 > 0 { bits.match(remaining % 258, distance: 2) }
        bits.endOfBlock()

        var output: [UInt8] = [0x78, 0x01] // zlib: deflate, 32 KiB window, no dictionary
        output.append(contentsOf: bits.finish())
        let adler = adler32(cidToGidMapData())
        output.append(UInt8(truncatingIfNeeded: adler >> 24))
        output.append(UInt8(truncatingIfNeeded: adler >> 16))
        output.append(UInt8(truncatingIfNeeded: adler >> 8))
        output.append(UInt8(truncatingIfNeeded: adler))
        return output
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for value in data {
            a = (a + UInt32(value)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }

    /// Deflate's bit order: fields least significant bit first, Huffman codes most significant bit first.
    private struct DeflateBits {
        private var output: [UInt8] = []
        private var current = 0
        private var filled = 0

        mutating func bits(_ value: Int, _ count: Int) {
            for i in 0..<count {
                current |= ((value >> i) & 1) << filled
                filled += 1
                if filled == 8 {
                    output.append(UInt8(truncatingIfNeeded: current))
                    current = 0
                    filled = 0
                }
            }
        }

        private mutating func code(_ code: Int, _ length: Int) {
            var i = length - 1
            while i >= 0 {
                bits((code >> i) & 1, 1)
                i -= 1
            }
        }

        /// Literals 0-143 are the 8-bit codes 0x30 + value.
        mutating func literal(_ value: Int) {
            code(0x30 + value, 8)
        }

        /// Symbol 256: the 7-bit code 0.
        mutating func endOfBlock() {
            code(0, 7)
        }

        /// A length of 3-10 or 258 (symbols 257-264 and 285; no extra bits) at a distance of 1-4.
        mutating func match(_ length: Int, distance: Int) {
            precondition(length == 258 || (length >= 3 && length <= 10), "Unsupported match length \(length).")
            precondition(distance >= 1 && distance <= 4, "Unsupported match distance \(distance).")
            if length == 258 {
                code(0xC0 + (285 - 280), 8)   // symbols 280-287: 8-bit codes 0xC0 +
            } else {
                code(length - 3 + 1, 7)       // symbols 257-264: 7-bit codes 1-8
            }
            code(distance - 1, 5)             // distance codes 0-3: no extra bits
        }

        func finish() -> [UInt8] {
            var bytes = output
            if filled > 0 { bytes.append(UInt8(truncatingIfNeeded: current)) }
            return bytes
        }
    }

    // MARK: - ToUnicode

    /// The part of every ToUnicode map that never changes: each code outside the surrogate range
    /// D800-DFFF maps to the same UTF-16 code unit, as 248 ranges of 256 codes
    /// (<XX00> <XXFF> <XX00>) in blocks of at most 100, as CMaps require.
    static let identityRanges: String = buildIdentityRanges()

    private static func buildIdentityRanges() -> String {
        var highBytes: [Int] = []
        for high in 0..<256 where high < 0xD8 || high > 0xDF {
            highBytes.append(high)
        }
        var text = ""
        var start = 0
        while start < highBytes.count {
            let count = min(100, highBytes.count - start)
            text += "\(count) beginbfrange\n"
            for index in start..<(start + count) {
                let h = GlyphlessCodes.hex(highBytes[index], digits: 2)
                text += "<\(h)00> <\(h)FF> <\(h)00>\n"
            }
            text += "endbfrange\n"
            start += 100
        }
        return text
    }

    // MARK: - Big-endian writer

    private struct BigEndianWriter {
        private(set) var data: [UInt8] = []

        var count: Int { data.count }

        mutating func u16(_ value: Int) {
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }

        mutating func i16(_ value: Int) {
            u16(value & 0xFFFF)
        }

        mutating func u32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }

        mutating func ascii(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }

        mutating func bytes(_ more: [UInt8]) {
            data.append(contentsOf: more)
        }
    }
}

/// The character codes of one document's text layer in `GlyphlessFont`. A character of the Basic
/// Multilingual Plane is its own UTF-16 code unit. Each character beyond it (a surrogate pair in the
/// text) gets a code of its own from D800 up, in the order the document first uses it, since a
/// surrogate never stands for a character alone; the ToUnicode map gives that code back as the
/// pair. A document with more than 2048 such characters writes the rest, and any lone surrogate,
/// as U+FFFD. Built before the font is written, from every line of every page. Twin of C#
/// `GlyphlessCodes` (`For` is `of(_:)` here).
public final class GlyphlessCodes {
    /// The first code given to a character beyond the Basic Multilingual Plane.
    public static let firstSupplementaryCode = 0xD800

    /// How many such characters a document can carry: the surrogate range, D800-DFFF.
    public static let supplementaryCapacity = 0x800

    /// What a character without a code is written as.
    public static let replacementCode = 0xFFFD

    private var codeOf: [Int: Int] = [:]
    private var characters: [Int] = []

    private init() {}

    /// The codes for these texts: every character beyond the BMP in them, in order of first use.
    public static func of(_ texts: [String]) -> GlyphlessCodes {
        let result = GlyphlessCodes()
        for text in texts {
            let units: [UInt16] = Array(text.utf16)
            var i = 0
            while i + 1 < units.count {
                if !isSurrogatePair(units[i], units[i + 1]) {
                    i += 1
                    continue
                }
                let codePoint = combine(units[i], units[i + 1])
                i += 2
                if result.codeOf[codePoint] != nil { continue }
                if result.characters.count == supplementaryCapacity { continue }
                result.codeOf[codePoint] = firstSupplementaryCode + result.characters.count
                result.characters.append(codePoint)
            }
        }
        return result
    }

    /// The characters beyond the BMP with a code, by code: the first is D800.
    public var supplementary: [Int] { characters }

    /// The codes of `text`, one per character.
    public func codes(_ text: String) -> [Int] {
        let units: [UInt16] = Array(text.utf16)
        var result: [Int] = []
        result.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let unit = units[i]
            if i + 1 < units.count && GlyphlessCodes.isSurrogatePair(unit, units[i + 1]) {
                let codePoint = GlyphlessCodes.combine(unit, units[i + 1])
                result.append(codeOf[codePoint] ?? GlyphlessCodes.replacementCode)
                i += 2
            } else {
                let lone = UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit)
                result.append(lone ? GlyphlessCodes.replacementCode : Int(unit))
                i += 1
            }
        }
        return result
    }

    /// `text` as a PDF hex string of its codes, two bytes each ("<00480069>" for "Hi").
    public func hexString(_ text: String) -> String {
        var result = "<"
        for code in codes(text) {
            result += GlyphlessCodes.hex(code, digits: 4)
        }
        result += ">"
        return result
    }

    /// The ToUnicode CMap: every code outside D800-DFFF is the UTF-16 code unit it was written from
    /// (`GlyphlessFont.identityRanges`), and each code from D800 is its character's surrogate pair,
    /// in blocks of at most 100.
    public func toUnicodeCMap() -> String {
        var text = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        text += "/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n"
        text += "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        text += "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        text += GlyphlessFont.identityRanges
        var start = 0
        while start < characters.count {
            let count = min(100, characters.count - start)
            text += "\(count) beginbfchar\n"
            for i in start..<(start + count) {
                let offset = characters[i] - 0x10000
                let high = 0xD800 + (offset >> 10)
                let low = 0xDC00 + (offset & 0x3FF)
                let code = GlyphlessCodes.hex(GlyphlessCodes.firstSupplementaryCode + i, digits: 4)
                let pair = GlyphlessCodes.hex(high, digits: 4) + GlyphlessCodes.hex(low, digits: 4)
                text += "<\(code)> <\(pair)>\n"
            }
            text += "endbfchar\n"
            start += 100
        }
        text += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return text
    }

    // MARK: - Helpers

    private static func isSurrogatePair(_ high: UInt16, _ low: UInt16) -> Bool {
        UTF16.isLeadSurrogate(high) && UTF16.isTrailSurrogate(low)
    }

    private static func combine(_ high: UInt16, _ low: UInt16) -> Int {
        let upper = (Int(high) - 0xD800) << 10
        let lower = Int(low) - 0xDC00
        return 0x10000 + upper + lower
    }

    /// `value` as `digits` uppercase hexadecimal digits, zero-padded (C#'s "X2" / "X4").
    static func hex(_ value: Int, digits: Int) -> String {
        let symbols: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        var output: [Character] = []
        var rest = value
        for _ in 0..<digits {
            output.append(symbols[rest & 0xF])
            rest >>= 4
        }
        return String(output.reversed())
    }
}
