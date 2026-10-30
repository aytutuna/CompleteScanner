import CoreGraphics
import Foundation

// Twin of windows/LazyScan.Core/Barcodes.cs.

/// The kinds of code read on scanned pages for splitting a stack at barcode or QR sheets
/// (`SplitMode.barcode`). Other kinds are not looked for. Twin of C# `BarcodeSymbology`
/// (`BarcodeSymbologies.All` / `Label`).
public enum BarcodeSymbology: Int, CaseIterable, Codable, Sendable {
    case qrCode
    case code128
    case code39
    case dataMatrix

    /// Every kind read, in this order.
    public static let all: [BarcodeSymbology] = [.qrCode, .code128, .code39, .dataMatrix]

    /// "QR code", "Code 128", "Code 39", "Data Matrix".
    public var label: String {
        switch self {
        case .qrCode: return "QR code"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .dataMatrix: return "Data Matrix"
        }
    }
}

/// A code read on a page: its kind, its text, and where it is (pixels, top-left origin; on the page as
/// it was read when it comes from `BarcodeSeparators.read`, on the image read when it comes from a
/// `BarcodeReader`). Twin of C# `BarcodeReading`.
public struct BarcodeReading: Equatable, Codable, Sendable {
    public var symbology: BarcodeSymbology
    public var text: String
    public var bounds: CGRect

    public init(symbology: BarcodeSymbology, text: String, bounds: CGRect) {
        self.symbology = symbology
        self.text = text
        self.bounds = bounds
    }
}

/// Reads the barcodes and QR codes of the kinds in `BarcodeSymbology.all` on a gray image, with their
/// bounds in that image's pixels (top-left origin). The platform does the reading: Vision on the Mac
/// (`VisionBarcodeReader`), ZXing.Net in the Windows app (`ZXingBarcodeReader`); tests use a stand-in.
/// Twin of C# `IBarcodeReader`.
public protocol BarcodeReader {
    /// Whether codes can be read at all.
    var isAvailable: Bool { get }
    /// The codes on `image`, in any order. Throws when reading fails.
    func read(_ image: GrayImage) throws -> [BarcodeReading]
}

/// Barcode and QR separator sheets (`SplitMode.barcode`): reading the codes on a page, the first one in
/// reading order, which codes split the stack (`splittingCode`), and the document name a code's text
/// gives. Twin of C# `BarcodeSeparators`.
public enum BarcodeSeparators {
    /// Pages are read as gray at this resolution (box filter; a coarser scan is read as it is): fine
    /// enough for a 0.01 in bar, coarse enough that the scanner's noise is averaged out.
    public static let readingDPI = 200

    /// The text a separator sheet's code starts with (`DocumentOptions.splitBarcodePrefix` by
    /// default): only such a code makes a separator sheet, so the codes printed on the documents
    /// themselves (payment QR codes, order numbers) are not taken for one.
    public static let defaultPrefix = "CS-SEP"

    /// The text of a separator sheet that gives no name (`QrSeparatorSheet` with no name, when the
    /// prefix is empty): the document after it is not named by it. Compared ignoring case.
    public static let unnamedText = "SEPARATOR"

    /// The most characters of a code's text a note shows; a longer text is cut, ending with "…".
    public static let maxNoteTextLength = 40

    /// The one line under "Codes are on": what happens to the page or sheet with a code, kept as a
    /// document's first page (`on`) or left out as a separator sheet.
    public static func startsDocumentCaption(_ on: Bool) -> String {
        on ? "Pages are kept" : "Sheets are left out"
    }

    /// What `DocumentOptions.barcodeStartsDocument` does, on and off, under its switch; off, with the
    /// codes that make a separator sheet (those starting with `prefix`, `defaultPrefix` when nil; every
    /// code when it is empty).
    public static func startsDocumentHint(_ on: Bool, prefix: String? = nil) -> String {
        if on {
            return "Each page with a barcode or QR code is kept as the first page of a new document, named after the code's text: for documents that carry their own code, such as invoices."
        }
        let start = Self.prefix(prefix ?? defaultPrefix)
        if start.isEmpty {
            return "A sheet with a barcode or QR code is a separator sheet: it is left out, and the code's text names the document after it. Print QR separator sheets below, with a name or without."
        }
        return "A sheet whose barcode or QR code starts with \u{201C}\(start)\u{201D} is a separator sheet: it is left out, and the rest of the code's text names the document after it. Other codes are ignored. Print QR separator sheets below, with a name or without."
    }

    /// The prefix as it is compared: `prefix` trimmed. Empty: every code makes a separator sheet.
    public static func prefix(_ prefix: String?) -> String {
        (prefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` starts with `prefix` (`prefix(_:)`), a–z matching A–Z, after any spaces and
    /// invisible characters it starts with (a byte-order mark). Compared in UTF-16 code units, as on Windows.
    public static func startsWithPrefix(_ text: String, _ prefix: String?) -> Bool {
        let units = Array(asciiUppercased(withoutLeadingInvisibles(text)).utf16)
        let start = Array(asciiUppercased(Self.prefix(prefix)).utf16)
        return units.starts(with: start)
    }

    /// `text` without the spaces, control and format characters (a byte-order mark) it starts with.
    private static func withoutLeadingInvisibles(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex {
            let scalar = scalars[start]
            let category = scalar.properties.generalCategory
            guard scalar.properties.isWhitespace || category == .format || category == .control else { break }
            start = scalars.index(after: start)
        }
        return String(scalars[start...])
    }

    /// Whether `reading` splits the stack under `options`: with `barcodeStartsDocument` every code does
    /// (its page starts a document); otherwise only a code starting with `splitBarcodePrefix` (its
    /// sheet is a separator).
    public static func splits(_ reading: BarcodeReading?, options: DocumentOptions) -> Bool {
        guard let reading else { return false }
        return options.barcodeStartsDocument || startsWithPrefix(reading.text, options.splitBarcodePrefix)
    }

    /// The first of `readings` (reading order) that splits the stack (`splits`); nil when none does or
    /// the page was not read.
    public static func splittingCode(_ readings: [BarcodeReading]?, options: DocumentOptions) -> BarcodeReading? {
        readings?.first(where: { splits($0, options: options) })
    }

    /// The document name a splitting code gives: its text after `splitBarcodePrefix` when it starts with
    /// it (a separator sheet's "CS-SEP Lease" names "Lease"), otherwise all of it, as `label` makes it.
    /// nil for no text or nothing left.
    public static func codeLabel(_ text: String?, options: DocumentOptions) -> String? {
        guard let text else { return nil }
        let start = Self.prefix(options.splitBarcodePrefix)
        guard !start.isEmpty, startsWithPrefix(text, start) else { return label(text) }
        let rest = Array(withoutLeadingInvisibles(text).utf16).dropFirst(start.utf16.count)
        return label(String(decoding: rest, as: UTF16.self))
    }

    /// Whether `page` is a separator sheet by its own code under `options`: split at barcode or QR
    /// sheets, without `barcodeStartsDocument`, and read with a code starting with the prefix. Such a
    /// page is never saved, so it is not turned upright.
    public static func isSeparatorPage(_ page: ScannedPage, options: DocumentOptions) -> Bool {
        options.splitMode == .barcode && !options.barcodeStartsDocument
            && splittingCode(page.barcodes, options: options) != nil
    }

    /// `image`, scanned at `dpi`, as gray at `readingDPI`.
    public static func readingImage(_ image: RgbaImage, dpi: Int) -> GrayImage {
        GrayImage.from(image, sourceDPI: dpi, analysisDPI: readingDPI)
    }

    /// The codes on `image`, scanned at `dpi`, read by `reader` on its gray copy (`readingImage`), with
    /// their bounds in the page's pixels, in reading order (`inReadingOrder`).
    public static func read(_ image: RgbaImage, dpi: Int, reader: any BarcodeReader) throws -> [BarcodeReading] {
        let gray = readingImage(image, dpi: dpi)
        return try inReadingOrder(reader.read(gray).map { scaled($0, by: 1 / gray.scale) })
    }

    /// The same for a page image (Mac only: read through `GrayImage(cgImage:sourceDPI:analysisDPI:)`,
    /// so the page is never held as RGBA). Empty when the image can't be read.
    public static func read(_ image: CGImage, dpi: Int, reader: any BarcodeReader) throws -> [BarcodeReading] {
        guard let gray = GrayImage(cgImage: image, sourceDPI: dpi, analysisDPI: readingDPI) else { return [] }
        return try inReadingOrder(reader.read(gray).map { scaled($0, by: 1 / gray.scale) })
    }

    /// The codes on a queued page (`read`), read on the pixels it holds (a preview once it is
    /// spooled, at the resolution that gives), with their bounds in its full-size pixels.
    public static func readPage(_ page: ScannedPage, reader: any BarcodeReader) throws -> [BarcodeReading] {
        let ratio = previewRatio(page)
        let dpi = max(1, Int((Double(page.dpi) / ratio).rounded()))
        let found = try read(page.image, dpi: dpi, reader: reader)
        return ratio == 1 ? found : found.map { scaled($0, by: ratio) }
    }

    /// The codes on a page already queued, read again when the split at barcode or QR sheets is chosen
    /// after it was scanned: on `spoolImage`, the page's full-resolution pixels from its spool file (as
    /// saved, before the user's turns, which are applied here), at the page's resolution, so small
    /// codes read as they do during the scan. Without it (no spool file, or one that can't be read) on
    /// the pixels the page holds (`readPage`); when those are a coarser preview and show no code, nil:
    /// the page counts as not read, since a code too fine for the preview may be there.
    public static func readQueuedPage(_ page: ScannedPage, spoolImage: CGImage?,
                                      reader: any BarcodeReader) throws -> [BarcodeReading]? {
        if let spoolImage {
            let turns = ((page.rotationQuarterTurns % 4) + 4) % 4
            let image = turns == 0 ? spoolImage : ImagePipeline.rotate(spoolImage, quarterTurns: turns)
            return try read(image, dpi: page.dpi, reader: reader)
        }
        let found = try readPage(page, reader: reader)
        return found.isEmpty && previewRatio(page) > 1 ? nil : found
    }

    /// How many times finer the page is than the pixels it holds: above 1 for a spooled page's preview.
    private static func previewRatio(_ page: ScannedPage) -> Double {
        guard let full = page.fullPixelSize else { return 1 }
        let fullSide = Double(max(full.width, full.height))
        let shown = Double(max(page.image.width, page.image.height))
        return fullSide > shown ? fullSide / shown : 1
    }

    /// `reading` with its bounds multiplied by `factor`.
    private static func scaled(_ reading: BarcodeReading, by factor: Double) -> BarcodeReading {
        var copy = reading
        copy.bounds = CGRect(x: reading.bounds.origin.x * factor, y: reading.bounds.origin.y * factor,
                             width: reading.bounds.size.width * factor, height: reading.bounds.size.height * factor)
        return copy
    }

    /// `readings` top to bottom, then left to right (by the top-left corner of their bounds; then by
    /// kind), without codes with no text and without a second reading of the same kind and text.
    public static func inReadingOrder(_ readings: [BarcodeReading]) -> [BarcodeReading] {
        let ordered = readings.filter { !$0.text.isEmpty }.enumerated().sorted { a, b in
            let p = a.element.bounds.origin, q = b.element.bounds.origin
            if p.y != q.y { return p.y < q.y }
            if p.x != q.x { return p.x < q.x }
            if a.element.symbology != b.element.symbology {
                return a.element.symbology.rawValue < b.element.symbology.rawValue
            }
            return a.offset < b.offset
        }
        var result: [BarcodeReading] = []
        for entry in ordered {
            let reading = entry.element
            if !result.contains(where: { $0.symbology == reading.symbology && $0.text == reading.text }) {
                result.append(reading)
            }
        }
        return result
    }

    /// The first code of `readings` (reading order); nil when there is none or the page was not read.
    public static func first(_ readings: [BarcodeReading]?) -> BarcodeReading? {
        readings?.first
    }

    /// The document name a code's text gives ({label}): invisible format characters (byte-order marks,
    /// zero-width spaces and joiners, bidi overrides and isolates) dropped, control characters and runs
    /// of spaces one space, the characters file names can't have (/ \ : * ? " < > |) a hyphen, then
    /// `DocumentSplitter.cleaned` (trimmed, at most 100 characters). nil for no text, nothing left, or
    /// `unnamedText`.
    public static func label(_ text: String?) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        var space = false
        for raw in text.unicodeScalars {
            let category = raw.properties.generalCategory
            if category == .format { continue }
            var c: Unicode.Scalar = category == .control ? " " : raw
            switch c {
            case "/", "\\", ":", "*", "?", "\"", "<", ">", "|": c = "-"
            default: break
            }
            if c.properties.isWhitespace {
                space = true
                continue
            }
            if space && !scalars.isEmpty { scalars.append(" ") }
            space = false
            scalars.append(c)
        }
        let name = String(scalars)
        if asciiUppercased(name) == unnamedText { return nil }
        return DocumentSplitter.cleaned(name)
    }

    /// "QR code “Lease 2026”": the code's kind and text, the text cut to `maxNoteTextLength` characters.
    public static func describe(_ reading: BarcodeReading) -> String {
        var text = reading.text
        if text.count > maxNoteTextLength {
            text = String(text.prefix(maxNoteTextLength - 1)) + "\u{2026}"
        }
        return "\(reading.symbology.label) \u{201C}\(text)\u{201D}"
    }

    /// `text` with a–z made A–Z and every other character as it is.
    static func asciiUppercased(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 97 && scalar.value <= 122, let upper = Unicode.Scalar(scalar.value - 32) {
                scalars.append(upper)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// The modules of a QR code, without its quiet zone: `size` × `size`, row by row from the top, true for
/// a dark module. Made by the platform (`QrEncoder`). Twin of C# `QrModules` (whose constructor throws
/// where this one returns nil).
public struct QrModules: Equatable, Sendable {
    public let size: Int
    public let dark: [Bool]

    /// nil unless `size` is positive and `dark` holds `size` × `size` modules.
    public init?(size: Int, dark: [Bool]) {
        guard size > 0, dark.count == size * size else { return nil }
        self.size = size
        self.dark = dark
    }

    /// Whether the module in column `x`, row `y` is dark.
    public subscript(x: Int, y: Int) -> Bool { dark[y * size + x] }
}

/// Makes the QR code of a separator sheet: the Mac with Core Image (`CoreImageQrEncoder`), Windows
/// with ZXing.Net in the app (`ZXingQrEncoder`). Twin of C# `IQrEncoder`.
public protocol QrEncoder {
    /// The QR code holding `text` (UTF-8, error correction level M); nil when it can't be made.
    func encode(_ text: String) -> QrModules?
}

/// The QR separator sheet to print for splitting at barcode or QR sheets: a QR code holding the
/// separator prefix and the name of the document it goes in front of (`text(_:prefix:)`; the prefix
/// alone starts a document with no name), the name written under it and how to use the sheet, in the 5 × 7 dot type of the
/// patch-code sheet. Saved as a PDF or printed like the patch-code sheet (`SeparatorSheet`). Twin of
/// C# `QrSeparatorSheet`.
public enum QrSeparatorSheet {
    /// The sheet's resolution.
    public static let dpi = 300

    /// The QR code is at most 2.5 in wide (with its quiet zone), its top 1.8 in from the top of the sheet.
    public static let codeSideHundredths = 250
    public static let codeTopHundredths = 180

    /// The print job's name.
    public static let jobName = "Separator sheet (QR code)"

    /// The text of the sheet's code: `prefix` (`BarcodeSeparators.prefix`; `DocumentOptions.splitBarcodePrefix`),
    /// a space and the name as a code's text gives it (`BarcodeSeparators.label`): "CS-SEP Lease 2026";
    /// the prefix alone with no name. With an empty prefix the name alone, or `BarcodeSeparators.unnamedText`.
    public static func text(_ name: String?, prefix: String = BarcodeSeparators.defaultPrefix) -> String {
        let start = BarcodeSeparators.prefix(prefix)
        let label = BarcodeSeparators.label(name)
        if start.isEmpty { return label ?? BarcodeSeparators.unnamedText }
        if let label { return "\(start) \(label)" }
        return start
    }

    /// `text` in the sheet's type: accents dropped, a–z made A–Z, and every character the type does not
    /// have a question mark.
    public static func caption(_ text: String) -> String {
        var result = ""
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            var value = scalar.value
            if value >= 97 && value <= 122 { value -= 32 }
            var c: Character = "?"
            if value < 128, let ascii = Unicode.Scalar(value) { c = Character(ascii) }
            result.append(c == " " || PatchCodeDetector.hasGlyph(c) ? c : "?")
        }
        return result
    }

    /// The sheet, `widthInches` × `heightInches` at `dpi`: white, "SEPARATOR SHEET" at the top, `code`
    /// (the QR code of `text(_:)`) in the middle, whole pixels per module, with its quiet zone, the name
    /// under it (`caption`, made smaller or cut with "..." to fit) or that the document has no name, and
    /// how to use the sheet near the bottom.
    public static func render(_ code: QrModules, name: String?, widthInches: Double, heightInches: Double,
                              dpi: Int) -> GrayImage {
        let d = Double(dpi)
        let w = max(1, Int((widthInches * d).rounded()))
        let h = max(1, Int((heightInches * d).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)
        let title = max(1, roundPixels(5, d))
        let body = max(1, roundPixels(2, d))
        let label = BarcodeSeparators.label(name)

        PatchCodeDetector.drawText(&pixels, w, h, "SEPARATOR SHEET", top: roundPixels(100, d), cell: title)

        // The code with a quiet zone of four modules on every side.
        let side = max(1, min(roundPixels(codeSideHundredths, d), w - 2 * roundPixels(100, d)))
        let module = max(1, side / (code.size + 8))
        let codeSide = module * code.size
        let x0 = (w - codeSide) / 2
        let y0 = roundPixels(codeTopHundredths, d) + 4 * module
        for y in 0..<code.size {
            for x in 0..<code.size where code[x, y] {
                PatchCodeDetector.fillRect(&pixels, w, h, x0 + x * module, y0 + y * module, module, module, 0)
            }
        }

        var top = y0 + codeSide + 4 * module + roundPixels(30, d)
        if let label {
            PatchCodeDetector.drawText(&pixels, w, h, "THE NEXT DOCUMENT IS NAMED", top: top, cell: body)
            top += 7 * body + roundPixels(20, d)
            drawCaption(&pixels, w, h, caption(label), top: top, dpi: d)
        } else {
            PatchCodeDetector.drawText(&pixels, w, h, "A NEW DOCUMENT STARTS AFTER THIS SHEET.", top: top, cell: body)
        }
        PatchCodeDetector.drawText(&pixels, w, h,
                                   label != nil ? "PUT THIS SHEET IN FRONT OF THE DOCUMENT IT NAMES." : "PUT THIS SHEET IN FRONT OF EACH DOCUMENT.",
                                   top: h - roundPixels(150, d), cell: body)
        PatchCodeDetector.drawText(&pixels, w, h, "SPLIT INTO DOCUMENTS: AT BARCODE OR QR SHEETS.",
                                   top: h - roundPixels(120, d), cell: body)
        return GrayImage(width: w, height: h, pixels: pixels, dpi: d)
    }

    /// `caption` (in the sheet's type) centred with its top at `top`: dots of 0.04 in, smaller down to
    /// 0.02 in to fit within 0.5 in of the sides, then cut, ending with "...". Returns the dot size used.
    @discardableResult
    static func drawCaption(_ pixels: inout [UInt8], _ w: Int, _ h: Int, _ caption: String, top: Int, dpi: Double) -> Int {
        let available = max(1, w - 2 * roundPixels(50, dpi))
        var cell = max(1, roundPixels(4, dpi))
        let smallest = max(1, roundPixels(2, dpi))
        func width(_ count: Int, _ dots: Int) -> Int { (count * 6 - 1) * dots }
        var text = caption
        while cell > smallest && width(text.count, cell) > available { cell -= 1 }
        if width(text.count, cell) > available {
            let fits = (available / cell + 1) / 6
            var cut = String(text.prefix(max(0, fits - 3)))
            while cut.hasSuffix(" ") { cut.removeLast() }
            text = cut + "..."
        }
        PatchCodeDetector.drawText(&pixels, w, h, text, top: top, cell: cell)
        return cell
    }

    /// "Separator sheet (QR code, Lease 2026, Letter)", or "Separator sheet (QR code, Letter)" with no
    /// name: the PDF's name, without its extension.
    public static func fileBaseName(_ name: String?, paper: PaperSize) -> String {
        if let label = BarcodeSeparators.label(name) {
            return "Separator sheet (QR code, \(label), \(paper.label))"
        }
        return "Separator sheet (QR code, \(paper.label))"
    }

    /// The status after the PDF was saved.
    public static func savedMessage(_ fileName: String, name: String?) -> String {
        if let label = BarcodeSeparators.label(name) {
            return "Saved the QR separator sheet for \u{201C}\(label)\u{201D}: \(fileName). Print it and put it in front of that document; the document is named \u{201C}\(label)\u{201D}."
        }
        return "Saved the QR separator sheet: \(fileName). Print as many as you need and put one in front of each document."
    }

    /// The status after the sheet was sent to `printer`.
    public static func printedMessage(_ printer: String, name: String?) -> String {
        if let label = BarcodeSeparators.label(name) {
            return "Sent the QR separator sheet for \u{201C}\(label)\u{201D} to \(printer). Put it in front of that document; the document is named \u{201C}\(label)\u{201D}."
        }
        return "Sent the QR separator sheet to \(printer). Put one in front of each document; print more copies as you need them."
    }

    /// The pixels of `hundredths` of an inch at `dpi`, rounded to nearest (halves away from zero).
    static func roundPixels(_ hundredths: Int, _ dpi: Double) -> Int {
        Int((Double(hundredths) * dpi / 100).rounded())
    }
}

/// Code 39, drawn without a library: the demo scanner's barcode separator sheets
/// (`MockScannerBackend.renderBarcodeSeparatorSheet`) and the tests' synthetic pages. Each character is
/// five bars and four spaces, three of them wide; characters are '*'-framed and a narrow space apart.
/// Twin of C# `Code39`.
public enum Code39 {
    /// A wide bar or space is this many narrow ones.
    public static let wideRatio = 3

    /// The bars of each character: bar, space, bar… nine elements, 1 for a wide one.
    private static let patterns: [Character: String] = [
        "0": "000110100", "1": "100100001", "2": "001100001", "3": "101100000",
        "4": "000110001", "5": "100110000", "6": "001110000", "7": "000100101",
        "8": "100100100", "9": "001100100", "A": "100001001", "B": "001001001",
        "C": "101001000", "D": "000011001", "E": "100011000", "F": "001011000",
        "G": "000001101", "H": "100001100", "I": "001001100", "J": "000011100",
        "K": "100000011", "L": "001000011", "M": "101000010", "N": "000010011",
        "O": "100010010", "P": "001010010", "Q": "000000111", "R": "100000110",
        "S": "001000110", "T": "000010110", "U": "110000001", "V": "011000001",
        "W": "111000000", "X": "010010001", "Y": "110010000", "Z": "011010000",
        "-": "010000101", ".": "110000100", " ": "011000100", "$": "010101000",
        "/": "010100010", "+": "010001010", "%": "000101010", "*": "010010100",
    ]

    /// Whether `text` can be drawn: not empty, and only 0–9, A–Z, space and - . $ / + %.
    public static func canEncode(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 != "*" && patterns[$0] != nil }
    }

    /// The narrow modules of `text` framed by '*', true for a bar: narrow elements one module, wide ones
    /// `wideRatio`, a narrow space between characters. Empty when `canEncode` says no.
    public static func modules(_ text: String) -> [Bool] {
        guard canEncode(text) else { return [] }
        var modules: [Bool] = []
        let framed = Array("*" + text + "*")
        for (i, character) in framed.enumerated() {
            if i > 0 { modules.append(false) }
            guard let pattern = patterns[character] else { continue }
            for (e, element) in pattern.enumerated() {
                let bar = e % 2 == 0
                let width = element == "1" ? wideRatio : 1
                for _ in 0..<width { modules.append(bar) }
            }
        }
        return modules
    }

    /// A barcode separator sheet, `widthInches` × `heightInches` at `dpi`: white, "SEPARATOR SHEET" at
    /// the top, `text` in Code 39 across the middle (narrow bars 0.02 in, thinner when it would not fit
    /// within 0.5 in of the sides, but never under a pixel; 0.8 in tall) and the text under it in the
    /// sheet's type. Text that can't be drawn gives the sheet without a code.
    public static func renderSheet(_ text: String, widthInches: Double, heightInches: Double, dpi: Int) -> GrayImage {
        let d = Double(dpi)
        let w = max(1, Int((widthInches * d).rounded()))
        let h = max(1, Int((heightInches * d).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)
        PatchCodeDetector.drawText(&pixels, w, h, "SEPARATOR SHEET", top: QrSeparatorSheet.roundPixels(100, d),
                                   cell: max(1, QrSeparatorSheet.roundPixels(5, d)))
        let bars = modules(text)
        let top = QrSeparatorSheet.roundPixels(180, d)
        let height = max(1, QrSeparatorSheet.roundPixels(80, d))
        if !bars.isEmpty {
            let available = max(1, w - 2 * QrSeparatorSheet.roundPixels(50, d))
            let module = max(1, min(QrSeparatorSheet.roundPixels(2, d), available / bars.count))
            let x0 = (w - module * bars.count) / 2
            for (i, bar) in bars.enumerated() where bar {
                PatchCodeDetector.fillRect(&pixels, w, h, x0 + i * module, top, module, height, 0)
            }
        }
        QrSeparatorSheet.drawCaption(&pixels, w, h, QrSeparatorSheet.caption(text),
                                     top: top + height + QrSeparatorSheet.roundPixels(30, d), dpi: d)
        PatchCodeDetector.drawText(&pixels, w, h, "A NEW DOCUMENT STARTS AFTER THIS SHEET.",
                                   top: h - QrSeparatorSheet.roundPixels(150, d),
                                   cell: max(1, QrSeparatorSheet.roundPixels(2, d)))
        return GrayImage(width: w, height: h, pixels: pixels, dpi: d)
    }
}
