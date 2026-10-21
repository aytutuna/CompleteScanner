import CoreGraphics
import Foundation

// Twin of the object-level parts of windows/CompleteScanner.Core/PdfBuilder.cs (PdfImageData,
// PdfJpegImage, PdfCcittImage, PdfPageInput, Make, Write, WritePage, ImageEntries, WriteTextFont,
// TextLayerLine, F): the same objects, numbering, content streams and number formatting, for plain,
// PDF/A-2b and password-protected files (`PDFWriteOptions`, `PDFA`, `PDFEncryption`), so each is the
// same file on both platforms (the golden values in PDFWriterTests, PDFATests and PDFEncryptionTests,
// pinned in C#). The Mac's and the iPhone's PDFBuilder write every PDF through this writer.

/// A page image as a PDF stores it (C# `PdfImageData`, `PdfJpegImage`, `PdfCcittImage`). The image
/// may be smaller than the page (a downsampled image, or a preview used when the full-resolution
/// spool file is missing); it is stretched across it.
public enum PDFImageData: Equatable, Sendable {
    /// A JPEG, embedded with /DCTDecode. Its dimensions and color space are read from the JPEG
    /// itself; a one-component JPEG is embedded as /DeviceGray, anything else as /DeviceRGB.
    case jpeg(Data)
    /// A black & white image as CCITT G4 data (`CCITTG4Encoder`), embedded as a 1-bit /DeviceGray
    /// image with /CCITTFaxDecode (/K -1, /BlackIs1 false: black pixels decode to 0); `width` and
    /// `height` are its /Columns and /Rows.
    case ccittG4(data: Data, width: Int, height: Int)

    /// The stored bytes.
    public var data: Data {
        switch self {
        case .jpeg(let bytes):
            return bytes
        case .ccittG4(let bytes, _, _):
            return bytes
        }
    }

    /// The page encoded as G4, black where its luma is below `Bilevel.threshold`
    /// (C# `PdfCcittImage.Encode`).
    public static func encodeCCITTG4(_ image: RgbaImage) -> PDFImageData {
        let bytes = CCITTG4Encoder.encode(image)
        return .ccittG4(data: Data(bytes), width: image.width, height: image.height)
    }
}

/// One page to be written into a PDF (C# `PdfPageInput`).
public struct PDFPageInput {
    /// The page image (see `PDFImageData`).
    public let image: PDFImageData
    /// Full-resolution page width in pixels (sizes the media box).
    public let pixelWidth: Int
    /// Full-resolution page height in pixels (sizes the media box).
    public let pixelHeight: Int
    /// Scan resolution; the PDF page is sized pixels / dpi × 72 points.
    public let dpi: Int
    /// Recognized text to embed as an invisible selectable layer, or nil for a plain image page.
    /// Bounding boxes are normalized with a BOTTOM-LEFT origin (Vision's).
    public let ocrLines: [OCRLine]?

    public init(image: PDFImageData, pixelWidth: Int, pixelHeight: Int, dpi: Int, ocrLines: [OCRLine]?) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dpi = dpi
        self.ocrLines = ocrLines
    }

    /// A page whose image is the JPEG `jpegData`.
    public init(jpegData: Data, pixelWidth: Int, pixelHeight: Int, dpi: Int, ocrLines: [OCRLine]?) {
        self.init(image: .jpeg(jpegData), pixelWidth: pixelWidth, pixelHeight: pixelHeight, dpi: dpi,
                  ocrLines: ocrLines)
    }

    /// The stored image bytes: the JPEG of a JPEG page, the G4 data of a G4 page.
    public var jpegData: Data { image.data }
}

/// The dependency-free PDF writer of scanned pages, ported from C# `PdfBuilder`. It writes PDF 1.4,
/// PDF/A-2b for keeping, or a PDF 1.7 file that opens only with a password (AES-256), as
/// `PDFWriteOptions` ask.
///
/// Each page carries one full-page image XObject: a JPEG (/DeviceRGB, or /DeviceGray for a
/// one-component JPEG) or, for black & white pages, a 1-bit /DeviceGray CCITT G4 image; when OCR
/// lines are provided they are drawn with text rendering mode 3 (invisible) in the embedded
/// `GlyphlessFont`, horizontally scaled (Tz) so each line's selectable text spans the same width as
/// the printed words. The text is written as UTF-16 code units, so every script survives.
///
/// Objects are numbered in a fixed order: 1 Catalog, 2 Pages; when any page has text, the six
/// objects of the text layer's font (Type0 font, CIDFont, FontDescriptor, FontFile2, CIDToGIDMap,
/// ToUnicode); for PDF/A, the Info dictionary, the XMP Metadata and the sRGB profile; for a protected
/// file, the Encrypt dictionary; then Page, Image and Contents for each page.
///
/// A protected file is PDF 1.7 with Adobe's extension level 8 declared in the catalog (what AES-256
/// readers look for), every stream and string encrypted with its own random file key
/// (`PDFEncryption`), and /Encrypt and /ID in the trailer.
public enum PDFWriter {
    /// Build the PDF in memory (`options`: see `write(_:progress:shouldContinue:options:to:)`).
    public static func make(_ pages: [PDFPageInput], progress: ((String) -> Void)? = nil,
                            shouldContinue: (() -> Bool)? = nil, options: PDFWriteOptions? = nil) throws -> Data {
        var result = Data()
        try write(pages, progress: progress, shouldContinue: shouldContinue, options: options) { chunk in
            result.append(chunk)
        }
        return result
    }

    /// Write the PDF to the file at `url` (created or replaced), streaming it: the whole document is
    /// never held in memory. Errors are `ScanError`s; a failed or cancelled write leaves an
    /// incomplete file, so callers write to a temporary file and move it into place.
    public static func writeFile(_ pages: [PDFPageInput], to url: URL, progress: ((String) -> Void)? = nil,
                                 shouldContinue: (() -> Bool)? = nil, options: PDFWriteOptions? = nil) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ScanError.exportFailed("Could not write to \(url.path).")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw ScanError.exportFailed("Could not write to \(url.path).")
        }
        defer { try? handle.close() }
        do {
            try write(pages, progress: progress, shouldContinue: shouldContinue, options: options) { chunk in
                try handle.write(contentsOf: chunk)
            }
        } catch let error as ScanError {
            throw error
        } catch {
            throw ScanError.exportFailed("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Stream the PDF to `output`, never holding the whole document. `shouldContinue` is polled
    /// before each page; returning false aborts with `ScanError.cancelled`, leaving `output` with an
    /// incomplete document. `progress` hears "Writing page n of m…" before each page. `options` (nil:
    /// a plain PDF) choose PDF/A-2b and carry its title, date and file identifier, or protect the file
    /// with a password; options asking for both are refused (`ScanError.exportFailed` with
    /// `PDFA.cannotProtectNote`): PDF/A forbids encryption. So is a protection already disposed.
    public static func write(_ pages: [PDFPageInput], progress: ((String) -> Void)? = nil,
                             shouldContinue: (() -> Bool)? = nil, options: PDFWriteOptions? = nil,
                             to output: @escaping (Data) throws -> Void) throws {
        let settings: PDFWriteOptions = options ?? PDFWriteOptions.standard
        let archival: Bool = settings.isArchival
        if archival && settings.isProtected { throw ScanError.exportFailed(PDFA.cannotProtectNote) }
        var hasText = false
        var texts: [String] = []
        for page in pages {
            guard let lines = page.ocrLines else { continue }
            if !lines.isEmpty { hasText = true }
            for line in lines { texts.append(line.text) }
        }
        // The text layer's character codes: characters beyond the BMP get theirs from every line.
        let codes = GlyphlessCodes.of(texts)
        // A protected file gets its own random file key; it is wiped once the file is written.
        var encryption: PDFEncryption? = nil
        if let protection = settings.protection {
            encryption = try PDFEncryption.create(protection, random: settings.random)
        }
        defer { encryption?.dispose() }
        let w = PDFObjectWriter(encryption: encryption, output: output)
        try w.writeHeader(archival || encryption != nil ? "1.7" : "1.4")

        var next = 3
        let fontObject = hasText ? next : 0
        if hasText { next += 6 }
        let infoObject = archival ? next : 0
        let metadataObject = infoObject + 1
        let profileObject = infoObject + 2
        if archival { next += 3 }
        var encryptObject = 0
        if encryption != nil {
            encryptObject = next
            next += 1
        }
        let firstPageObject = next

        // 1: Catalog
        if archival {
            let intents: String = PDFA.outputIntents(profileObject)
            try w.writeObject(1, "<</Type /Catalog /Pages 2 0 R /Metadata \(metadataObject) 0 R /OutputIntents \(intents)>>")
        } else if encryption != nil {
            try w.writeObject(1, "<</Type /Catalog /Pages 2 0 R /Extensions <</ADBE <</BaseVersion /1.7 /ExtensionLevel 8>>>>>>")
        } else {
            try w.writeObject(1, "<</Type /Catalog /Pages 2 0 R>>")
        }

        // 2: Pages
        var kids = ""
        for i in 0..<pages.count {
            if i > 0 { kids += " " }
            kids += "\(firstPageObject + i * 3) 0 R"
        }
        try w.writeObject(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages.count)>>")

        if hasText { try writeTextFont(w, first: fontObject, codes: codes) }

        if archival {
            // Whole seconds, as both dates are written.
            let made: Date = settings.creationDate ?? Date()
            let date = Date(timeIntervalSince1970: made.timeIntervalSince1970.rounded(.down))
            let zone: TimeZone = settings.timeZone ?? TimeZone.current
            var title: String? = nil
            if let requested = settings.title { title = PDFA.cleanTitle(requested) }
            let info: String = PDFA.infoDictionary(title: title, date: date, timeZone: zone)
            let metadata: Data = PDFA.xmp(title: title, date: date, timeZone: zone)
            try w.writeObject(infoObject, info)
            try w.writeStream(metadataObject, "/Type /Metadata /Subtype /XML", metadata)
            try w.writeStream(profileObject, "/N 3", Data(PDFA.srgbProfile))
        }

        if let encryption { try w.writeObject(encryptObject, encryption.dictionary) }

        for i in 0..<pages.count {
            if shouldContinue?() == false { throw ScanError.cancelled }
            progress?("Writing page \(i + 1) of \(pages.count)…")
            let pageObject = firstPageObject + i * 3
            try writePage(w, pageObject: pageObject, imageObject: pageObject + 1, contentsObject: pageObject + 2,
                          parent: "2 0 R", index: i, page: pages[i], fontObject: fontObject, codes: codes,
                          extraEntries: "")
        }

        var trailer = "/Root 1 0 R"
        if archival {
            let id: [UInt8] = settings.documentId?.count == 16 ? (settings.documentId ?? []) : uuidBytes()
            let hex: String = PDFEncryption.hex(id)
            trailer += " /Info \(infoObject) 0 R /ID [<\(hex)> <\(hex)>]"
        } else if encryption != nil {
            // PDF 2.0 asks for the identifier whenever a file is encrypted.
            var id: [UInt8] = []
            if let given = settings.documentId, given.count == 16 {
                id = given
            } else {
                id = try PDFEncryption.randomBytes(settings.random ?? PDFEncryption.systemRandom, 16)
            }
            let hex: String = PDFEncryption.hex(id)
            trailer += " /Encrypt \(encryptObject) 0 R /ID [<\(hex)> <\(hex)>]"
        }
        try w.finish(trailer)
    }

    /// Sixteen random bytes from a new UUID (C#'s `Guid.NewGuid().ToByteArray()`): a PDF/A file's
    /// identifier when none is given.
    private static func uuidBytes() -> [UInt8] {
        let uuid: uuid_t = UUID().uuid
        let bytes: [UInt8] = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
                              uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15]
        return bytes
    }

    /// One page's three objects: the page (child of `parent`, its image named "Im{index}", the font
    /// `fontObject` as /F1 when it has text, then `extraEntries` at the end of its dictionary), the
    /// image XObject and the content stream.
    static func writePage(_ w: PDFObjectWriter, pageObject: Int, imageObject: Int, contentsObject: Int,
                          parent: String, index: Int, page: PDFPageInput, fontObject: Int,
                          codes: GlyphlessCodes, extraEntries: String) throws {
        // PDF media box in points: pixels / dpi × 72.
        let dpi = Double(max(page.dpi, 1))
        let widthPts = Double(page.pixelWidth) / dpi * 72.0
        let heightPts = Double(page.pixelHeight) / dpi * 72.0
        let lines: [OCRLine] = page.ocrLines ?? []
        let pageHasText = !lines.isEmpty

        let fontResource = pageHasText ? " /Font <</F1 \(fontObject) 0 R>>" : ""
        var dictionary = "<</Type /Page /Parent \(parent) /MediaBox [0 0 \(f(widthPts)) \(f(heightPts))] "
        dictionary += "/Resources <</XObject <</Im\(index) \(imageObject) 0 R>>\(fontResource)>> "
        dictionary += "/Contents \(contentsObject) 0 R\(extraEntries)>>"
        try w.writeObject(pageObject, dictionary)

        // The XObject declares the image's own dimensions, which differ from the page's pixel size
        // when only a preview was available or the image was downsampled; the content stream's cm
        // scales the unit-square image onto the full media box either way.
        try w.writeStream(imageObject, imageEntries(page), page.image.data)

        let contents = contentStream(index, widthPts: widthPts, heightPts: heightPts, lines: lines, codes: codes)
        try w.writeStream(contentsObject, "", contents)
    }

    /// The image XObject's dictionary entries (before /Length). A JPEG declares its own frame size,
    /// and /DeviceGray when it has one component; one that cannot be read keeps the assumption of an
    /// RGB image the size of the page. G4 data is a 1-bit gray image.
    static func imageEntries(_ page: PDFPageInput) -> String {
        switch page.image {
        case .ccittG4(_, let width, let height):
            var entries = "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) "
            entries += "/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode "
            entries += "/DecodeParms <</K -1 /Columns \(width) /Rows \(height) /BlackIs1 false>>"
            return entries
        case .jpeg(let jpeg):
            var imageWidth = page.pixelWidth
            var imageHeight = page.pixelHeight
            var components = 3
            if let header = PDFImageEncoding.readJPEGHeader(jpeg) {
                imageWidth = header.width
                imageHeight = header.height
                components = header.components
            }
            let colorSpace = components == 1 ? "/DeviceGray" : "/DeviceRGB"
            var entries = "/Type /XObject /Subtype /Image /Width \(imageWidth) /Height \(imageHeight) "
            entries += "/ColorSpace \(colorSpace) /BitsPerComponent 8 /Filter /DCTDecode"
            return entries
        }
    }

    /// The text layer's font, objects `first` to first + 5: a Type0 font with Identity-H encoding
    /// (two-byte codes, see `GlyphlessCodes`) over a CIDFontType2 whose every glyph is
    /// `GlyphlessFont`'s empty, half-em-wide glyph 1, embedded, with a ToUnicode map giving each
    /// code back as its character (`codes`). The descriptor's /Descent is -1, not the program's 0:
    /// PDFKit reads no text at all from a font whose descriptor and hhea table both give a descent
    /// of 0.
    static func writeTextFont(_ w: PDFObjectWriter, first: Int, codes: GlyphlessCodes) throws {
        let cidFont = first + 1
        let descriptor = first + 2
        let program = first + 3
        let cidToGid = first + 4
        let toUnicode = first + 5
        let name = GlyphlessFont.fontName
        let width = GlyphlessFont.glyphWidth
        let em = GlyphlessFont.unitsPerEm
        let registry = try w.asciiString("Adobe")
        let ordering = try w.asciiString("Identity")

        var type0 = "<</Type /Font /Subtype /Type0 /BaseFont /\(name) /Encoding /Identity-H "
        type0 += "/DescendantFonts [\(cidFont) 0 R] /ToUnicode \(toUnicode) 0 R>>"
        try w.writeObject(first, type0)

        var cid = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /\(name) "
        cid += "/CIDSystemInfo <</Registry \(registry) /Ordering \(ordering) /Supplement 0>> "
        cid += "/FontDescriptor \(descriptor) 0 R /DW \(width) /CIDToGIDMap \(cidToGid) 0 R>>"
        try w.writeObject(cidFont, cid)

        var fontDescriptor = "<</Type /FontDescriptor /FontName /\(name) /Flags 5 "
        fontDescriptor += "/FontBBox [0 0 \(width) \(em)] /ItalicAngle 0 "
        fontDescriptor += "/Ascent \(em) /Descent -1 /CapHeight \(em) /StemV 80 "
        fontDescriptor += "/FontFile2 \(program) 0 R>>"
        try w.writeObject(descriptor, fontDescriptor)

        let font = GlyphlessFont.program
        try w.writeStream(program, "/Length1 \(font.count)", Data(font))
        try w.writeStream(cidToGid, "/Filter /FlateDecode", Data(GlyphlessFont.cidToGidMap))
        try w.writeStream(toUnicode, "", Data(codes.toUnicodeCMap().utf8))
    }

    // MARK: - Content stream

    private static func contentStream(_ pageIndex: Int, widthPts: Double, heightPts: Double,
                                      lines: [OCRLine], codes: GlyphlessCodes) -> Data {
        // Draw the page image across the full media box.
        var text = "q\n\(f(widthPts)) 0 0 \(f(heightPts)) 0 0 cm\n/Im\(pageIndex) Do\nQ\n"
        if !lines.isEmpty {
            // Invisible text layer: mode 3 = neither fill nor stroke, but selectable/searchable.
            // OCR boxes are normalized with a bottom-left origin, the same origin as PDF user
            // space, so they map straight into points with no flip.
            text += "BT\n3 Tr\n"
            for line in lines {
                guard let placed = textLayerLine(line, codes: codes, widthPts: widthPts, heightPts: heightPts) else {
                    continue
                }
                text += "/F1 \(f(placed.fontSize)) Tf\n"
                text += "\(f(placed.horizontalScale * 100)) Tz\n"
                text += "1 0 0 1 \(f(placed.x)) \(f(placed.baseline)) Tm\n"
                text += codes.hexString(line.text)
                text += " Tj\n"
            }
            text += "ET\n"
        }
        // Pure ASCII: the text is written as hex.
        return Data(text.utf8)
    }

    /// Where one OCR line's invisible text goes, in points: the font size is the box's height and
    /// the baseline its bottom edge (the glyphless font's ascent is a full em and its descent none,
    /// so a selection covers the box), stretched across the box's width by the horizontal scale
    /// (Tz / 100, clamped to 0.2–5).
    struct PlacedLine: Equatable {
        let fontSize: Double
        let horizontalScale: Double
        let x: Double
        let baseline: Double
    }

    /// The placement of `line` on a page of the given size; nil for an empty line or box.
    static func textLayerLine(_ line: OCRLine, codes: GlyphlessCodes, widthPts: Double,
                              heightPts: Double) -> PlacedLine? {
        if line.text.isEmpty { return nil }
        let box = line.boundingBox.standardized
        let targetWidth = Double(box.width) * widthPts
        let fontSize = Double(box.height) * heightPts
        if fontSize <= 0 || targetWidth <= 0 { return nil }
        let codeCount = codes.codes(line.text).count
        let measuredWidth = GlyphlessFont.textWidth(codeCount: codeCount, fontSize: fontSize)
        let scale = min(max(targetWidth / measuredWidth, 0.2), 5.0)
        let x = Double(box.minX) * widthPts
        let baseline = Double(box.minY) * heightPts
        return PlacedLine(fontSize: fontSize, horizontalScale: scale, x: x, baseline: baseline)
    }

    // MARK: - Numbers

    /// A number as PDF syntax writes it, exactly as C#'s `value.ToString("0.####",
    /// CultureInfo.InvariantCulture)`: the value's 15 significant digits, rounded half up at the
    /// fourth decimal, trailing zeros and a trailing point dropped, '.' as the decimal point; a
    /// negative value keeps its sign even when it rounds to 0 ("-0").
    static func f(_ value: Double) -> String {
        if !value.isFinite { return "0" }
        var scientific = String(format: "%.14e", value)
        var negative = false
        if scientific.hasPrefix("-") {
            negative = true
            scientific.removeFirst()
        }
        let parts = scientific.split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return "0" }
        var digits: [Int] = []
        for character in parts[0].utf8 where character != UInt8(ascii: ".") {
            digits.append(Int(character) - 48)
        }
        var point = exponent + 1 // digits before the decimal point
        if digits.first == 0 {
            digits = []
            point = 0
        }
        dropTrailingZeros(&digits)
        let keep = point + 4 // the digits kept: up to the fourth decimal
        if keep < 0 {
            digits = []
            point = 0
        } else if keep < digits.count {
            let roundsUp = digits[keep] >= 5
            digits.removeSubrange(keep..<digits.count)
            if roundsUp { point += roundUp(&digits) }
            dropTrailingZeros(&digits)
        }
        if digits.isEmpty { return negative ? "-0" : "0" }
        return (negative ? "-" : "") + decimalText(digits, point: point)
    }

    private static func dropTrailingZeros(_ digits: inout [Int]) {
        while let last = digits.last, last == 0 { digits.removeLast() }
    }

    /// Adds one unit in the last place of `digits`; returns 1 when that adds a leading digit.
    private static func roundUp(_ digits: inout [Int]) -> Int {
        var i = digits.count - 1
        while i >= 0 && digits[i] == 9 {
            digits[i] = 0
            i -= 1
        }
        if i >= 0 {
            digits[i] += 1
            return 0
        }
        digits.insert(1, at: 0)
        return 1
    }

    /// The digits with the decimal point after the first `point` of them.
    private static func decimalText(_ digits: [Int], point: Int) -> String {
        var integer = ""
        var fraction = ""
        if point <= 0 {
            integer = "0"
            fraction = String(repeating: "0", count: -point)
            for digit in digits { fraction += String(digit) }
        } else {
            for index in 0..<point {
                integer += index < digits.count ? String(digits[index]) : "0"
            }
            if point < digits.count {
                for index in point..<digits.count { fraction += String(digits[index]) }
            }
        }
        return fraction.isEmpty ? integer : integer + "." + fraction
    }
}
