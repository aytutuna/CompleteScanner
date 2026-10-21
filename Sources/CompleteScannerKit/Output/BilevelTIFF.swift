import Foundation

// Twin of windows/CompleteScanner.Core/BilevelTiff.cs: the same file, byte for byte (the golden
// value in BilevelOutputTests, pinned in C#). See CONTRACTS.md, "CCITT G4 for black & white pages".

/// One page of a black & white TIFF: the page and its resolution.
public struct BilevelTIFFPage {
    public let image: RgbaImage
    public let dpi: Int

    public init(image: RgbaImage, dpi: Int) {
        self.image = image
        self.dpi = dpi
    }
}

/// Black & white TIFF files compressed with CCITT G4 (compression 4), one page or several:
/// little-endian, each page one strip of `CCITTG4Encoder` data followed by its image file directory,
/// 1 bit per pixel, WhiteIsZero (as fax images are stored), the resolution in pixels per inch.
/// Several pages are marked as pages of one document (NewSubfileType 2, PageNumber n of count).
/// Pixels are black where their luma is below `Bilevel.threshold`.
public enum BilevelTIFF {
    /// Whether a page saved as `format` in `mode` is written here: black & white TIFFs.
    public static func applies(_ format: OutputFormat, _ mode: ColorMode) -> Bool {
        format == .tiff && mode == .blackWhite
    }

    /// A one-page file.
    public static func make(_ image: RgbaImage, dpi: Int) -> Data {
        make([BilevelTIFFPage(image: image, dpi: dpi)])
    }

    /// A file with every page, in order. `pages` must not be empty (a TIFF needs a page; C# throws
    /// ArgumentException there).
    public static func make(_ pages: [BilevelTIFFPage]) -> Data {
        precondition(!pages.isEmpty, "A TIFF needs at least one page.")
        var output: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0, 0, 0, 0] // "II*\0", then the first directory's offset
        var linkOffset = 4
        let multiPage = pages.count > 1
        for index in 0..<pages.count {
            let page = pages[index]
            let strip = CCITTG4Encoder.encode(page.image)
            let stripOffset = output.count
            output.append(contentsOf: strip)
            if output.count % 2 == 1 { output.append(0) } // directories start on a word boundary

            var entries: [Entry] = []
            if multiPage { entries.append(Entry(tag: 254, type: long, count: 1, value: 2)) } // NewSubfileType: a page of a document
            entries.append(Entry(tag: 256, type: long, count: 1, value: page.image.width))   // ImageWidth
            entries.append(Entry(tag: 257, type: long, count: 1, value: page.image.height))  // ImageLength
            entries.append(Entry(tag: 258, type: short, count: 1, value: 1))                 // BitsPerSample
            entries.append(Entry(tag: 259, type: short, count: 1, value: 4))                 // Compression: CCITT T.6
            entries.append(Entry(tag: 262, type: short, count: 1, value: 0))                 // PhotometricInterpretation: WhiteIsZero
            entries.append(Entry(tag: 273, type: long, count: 1, value: stripOffset))        // StripOffsets
            entries.append(Entry(tag: 277, type: short, count: 1, value: 1))                 // SamplesPerPixel
            entries.append(Entry(tag: 278, type: long, count: 1, value: page.image.height))  // RowsPerStrip: one strip
            entries.append(Entry(tag: 279, type: long, count: 1, value: strip.count))        // StripByteCounts
            entries.append(Entry(tag: 282, type: rational, count: 1, value: 0))              // XResolution (value after the directory)
            entries.append(Entry(tag: 283, type: rational, count: 1, value: 0))              // YResolution
            entries.append(Entry(tag: 293, type: long, count: 1, value: 0))                  // T6Options: no uncompressed mode
            entries.append(Entry(tag: 296, type: short, count: 1, value: 2))                 // ResolutionUnit: inch
            if multiPage {
                // PageNumber: two shorts, this page (from 0) and the page count.
                let pageNumber = index | (pages.count << 16)
                entries.append(Entry(tag: 297, type: short, count: 2, value: pageNumber))
            }

            let directory = output.count
            let resolution = directory + 2 + entries.count * 12 + 4 // two rationals after the directory
            appendUInt16(&output, entries.count)
            for entry in entries {
                appendUInt16(&output, entry.tag)
                appendUInt16(&output, entry.type)
                appendUInt32(&output, entry.count)
                var value = entry.value
                if entry.type == rational { value = resolution + (entry.tag == 282 ? 0 : 8) }
                if entry.type == short && entry.count == 1 {
                    appendUInt16(&output, value)
                    appendUInt16(&output, 0)
                } else {
                    appendUInt32(&output, value) // a long, two shorts, an offset
                }
            }
            // The next directory's offset (0 for the last) is written when it is known.
            appendUInt32(&output, 0)
            let dpi = max(page.dpi, 1)
            appendUInt32(&output, dpi)
            appendUInt32(&output, 1)
            appendUInt32(&output, dpi)
            appendUInt32(&output, 1)

            writeUInt32(&output, at: linkOffset, directory)
            linkOffset = directory + 2 + entries.count * 12
        }
        return Data(output)
    }

    private static let short = 3
    private static let long = 4
    private static let rational = 5

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let value: Int
    }

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: Int) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: Int) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func writeUInt32(_ bytes: inout [UInt8], at offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
