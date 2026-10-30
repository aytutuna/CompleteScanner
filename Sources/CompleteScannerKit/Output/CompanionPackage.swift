import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/CompanionPackage.cs: the same manifest, the same bytes for
// the same document, the same checks and messages when reading one.

/// How a page's picture is stored in a companion package.
public enum CompanionImageFormat: String, Equatable, Sendable {
    case jpeg
    case png
    /// A bilevel TIFF (CCITT G4), for black & white pages only.
    case tiff
}

/// One picture in a companion package: its encoded bytes and what they show. `pixelWidth` and
/// `pixelHeight` are 0 when a package did not say (decode the picture).
public struct CompanionImage: Equatable, Sendable {
    public var data: Data
    public var format: CompanionImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var dpi: Int
    public var colorMode: ColorMode

    public init(data: Data, format: CompanionImageFormat, pixelWidth: Int, pixelHeight: Int, dpi: Int,
                colorMode: ColorMode) {
        self.data = data
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dpi = dpi
        self.colorMode = colorMode
    }
}

/// One page of a companion package: its picture as the app shows it and, optionally, what the app
/// knows about it.
public struct CompanionPage {
    public var image: CompanionImage
    /// Quarter turns clockwise still to apply to `image` (0...3), as `ScannedPage.rotationQuarterTurns`.
    public var rotationQuarterTurns: Int
    /// Which side of its sheet the page is, for two-sided scans.
    public var side: PageSide?
    /// The sheet the page belongs to (0 = first), for two-sided scans.
    public var sheetIndex: Int?
    /// The recognized text (Vision-normalized boxes, origin bottom-left); nil when not recognized,
    /// empty when no text was found.
    public var ocrLines: [OCRLine]?
    /// The page as scanned, before crop, clean-up and the like; nil when there is no other version.
    public var original: CompanionImage?
    /// What the camera recorded about the page (`ScannedPage.capture`), its corners in the pixels of
    /// `original` as stored; nil for a page not taken by a camera, and when a package's record of it
    /// cannot be read.
    public var capture: CaptureFacts?

    public init(image: CompanionImage, rotationQuarterTurns: Int = 0, side: PageSide? = nil, sheetIndex: Int? = nil,
                ocrLines: [OCRLine]? = nil, original: CompanionImage? = nil, capture: CaptureFacts? = nil) {
        self.image = image
        self.rotationQuarterTurns = rotationQuarterTurns
        self.side = side
        self.sheetIndex = sheetIndex
        self.ocrLines = ocrLines
        self.original = original
        self.capture = capture
    }
}

/// The app that wrote a package: its name, version and platform ("windows", "macos", "ios").
public struct CompanionWriterInfo: Equatable, Sendable {
    public var app: String
    public var appVersion: String
    public var platform: String

    public init(app: String, appVersion: String, platform: String) {
        self.app = app
        self.appVersion = appVersion
        self.platform = platform
    }
}

/// A document moved between the phone and the desktop as one `.csdoc` package.
public struct CompanionDocument {
    public var title: String
    public var pages: [CompanionPage]
    public var writer: CompanionWriterInfo
    /// When the document was made; kept to the second, in UTC.
    public var created: Date?
    /// The id of the task the document was scanned with (a `ScanTask` id).
    public var taskId: String?
    /// The file name the sender would give it, without an extension.
    public var suggestedName: String?
    /// The naming template the sender used (see `NamingTemplate`).
    public var namingTemplate: String?

    public init(title: String, pages: [CompanionPage],
                writer: CompanionWriterInfo = CompanionWriterInfo(app: "CompleteScanner", appVersion: "", platform: ""),
                created: Date? = nil, taskId: String? = nil, suggestedName: String? = nil,
                namingTemplate: String? = nil) {
        self.title = title
        self.pages = pages
        self.writer = writer
        self.created = created
        self.taskId = taskId
        self.suggestedName = suggestedName
        self.namingTemplate = namingTemplate
    }
}

/// Why a companion package could not be written or read.
public enum CompanionPackageErrorKind: String, Equatable, Sendable {
    /// The zip archive itself was refused (see `ZipReadError`).
    case invalidArchive
    /// No manifest, or a manifest that is not a CompleteScanner document's.
    case notPackage
    /// A newer major format version than this app reads.
    case newerVersion
    /// The manifest is not JSON, too large, or names a picture twice.
    case invalidManifest
    case noPages
    case tooManyPages
    case missingImage
    /// A picture's SHA-256 or byte count does not match the manifest.
    case checksumMismatch
    /// A picture is not a JPEG, PNG or TIFF, or not the format the manifest names.
    case unsupportedImage
    /// Writing: a page that cannot be packaged (see the message).
    case invalidDocument
    /// Writing: the package would be past the limits a reader holds it to.
    case tooLarge
}

/// A companion package that cannot be written or read, with a message for the user.
public struct CompanionPackageError: LocalizedError, Equatable, Sendable {
    public let kind: CompanionPackageErrorKind
    public let message: String

    public init(_ kind: CompanionPackageErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The `.csdoc` package: a `ZipStore` archive holding `manifest.json` first and then each page's
/// picture ("pages/0001.jpg") followed by its original ("pages/0001-original.png"). Writing is
/// deterministic: the manifest is compact JSON written by hand with a fixed key order and fixed
/// number format, entries are stored and dated 1980-01-01, so this and the C# twin write the same
/// bytes for the same document. Reading goes through `ZipStoreReader`, decodes the manifest
/// leniently (rule 6: unknown keys ignored, missing or wrong-typed fields default, unknown enum
/// values fall back), refuses a newer major version, and checks every picture's byte count,
/// SHA-256 and format.
public enum CompanionPackage {
    public static let fileExtension = "csdoc"
    public static let formatName = "csdoc"
    /// The major version: a reader refuses a larger one.
    public static let formatVersion = 1
    /// The minor version: raised for additions older readers can ignore (1: the pages' capture facts).
    public static let formatMinor = 1
    public static let manifestName = "manifest.json"
    public static let maxPages = 2000
    public static let maxManifestBytes = 16 * 1024 * 1024
    /// The resolution a page gets when its manifest gives none.
    public static let defaultDpi = 300

    // MARK: - Writing

    /// The package for `document`; throws `CompanionPackageError` for a document it cannot hold.
    public static func make(_ document: CompanionDocument) throws -> Data {
        ZipStore.make(try entries(document))
    }

    /// The entries of the package for `document`, in package order.
    public static func entries(_ document: CompanionDocument) throws -> [ZipStoreEntry] {
        try validate(document)
        var entries = [ZipStoreEntry(name: manifestName, data: Data(manifestJSON(document).utf8))]
        for (index, page) in document.pages.enumerated() {
            entries.append(ZipStoreEntry(name: imageEntryName(index + 1, format: page.image.format, original: false),
                                         data: page.image.data))
            if let original = page.original {
                entries.append(ZipStoreEntry(name: imageEntryName(index + 1, format: original.format, original: true),
                                             data: original.data))
            }
        }
        let limits = ZipReadLimits.standard
        let total = entries.reduce(0) { $0 + $1.data.count }
        if entries[0].data.count > maxManifestBytes || total > limits.maxTotalBytes
            || entries.contains(where: { $0.data.count > limits.maxEntryBytes }) {
            throw CompanionPackageError(.tooLarge, tooLargeMessage)
        }
        return entries
    }

    /// "The document is larger than 512 MB, too large for one package."
    public static var tooLargeMessage: String {
        "The document is larger than \(ZipReadLimits.standard.maxTotalBytes / (1024 * 1024)) MB, too large for one package."
    }

    /// The manifest's exact text: compact JSON, keys in a fixed order, a line break at the end.
    public static func manifestJSON(_ document: CompanionDocument) -> String {
        var json = "{\"format\":" + quote(formatName)
        json += ",\"formatVersion\":" + String(formatVersion)
        json += ",\"formatMinor\":" + String(formatMinor)
        json += ",\"writer\":{\"app\":" + quote(document.writer.app)
        json += ",\"appVersion\":" + quote(document.writer.appVersion)
        json += ",\"platform\":" + quote(document.writer.platform) + "}"
        if let created = document.created { json += ",\"created\":" + quote(formatDate(created)) }
        json += ",\"title\":" + quote(document.title)
        if let taskId = document.taskId { json += ",\"taskId\":" + quote(taskId) }
        if document.suggestedName != nil || document.namingTemplate != nil {
            json += ",\"naming\":{"
            var first = true
            if let name = document.suggestedName {
                json += "\"suggestedName\":" + quote(name)
                first = false
            }
            if let template = document.namingTemplate {
                json += (first ? "" : ",") + "\"template\":" + quote(template)
            }
            json += "}"
        }
        json += ",\"pages\":["
        for (index, page) in document.pages.enumerated() {
            if index > 0 { json += "," }
            json += "{\"image\":"
            json += imageJSON(page.image, file: imageEntryName(index + 1, format: page.image.format, original: false))
            json += ",\"rotationQuarterTurns\":" + String(page.rotationQuarterTurns)
            if let side = page.side { json += ",\"side\":" + quote(side == .back ? "back" : "front") }
            if let sheet = page.sheetIndex { json += ",\"sheetIndex\":" + String(sheet) }
            if let lines = page.ocrLines {
                json += ",\"ocrLines\":["
                for (k, line) in lines.enumerated() {
                    if k > 0 { json += "," }
                    let box = line.boundingBox
                    json += "{\"text\":" + quote(line.text)
                    json += ",\"x\":" + number(Double(box.origin.x))
                    json += ",\"y\":" + number(Double(box.origin.y))
                    json += ",\"width\":" + number(Double(box.size.width))
                    json += ",\"height\":" + number(Double(box.size.height))
                    json += ",\"confidence\":" + number(Double(line.confidence)) + "}"
                }
                json += "]"
            }
            if let capture = page.capture { json += captureJSON(capture) }
            if let original = page.original {
                json += ",\"original\":"
                json += imageJSON(original, file: imageEntryName(index + 1, format: original.format, original: true))
            }
            json += "}"
        }
        json += "]}\n"
        return json
    }

    /// "pages/0001.jpg", "pages/0001-original.png", "pages/0002.tif".
    public static func imageEntryName(_ pageNumber: Int, format: CompanionImageFormat, original: Bool) -> String {
        let digits = String(pageNumber)
        let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        return "pages/" + padded + (original ? "-original" : "") + "." + imageExtension(format)
    }

    /// "jpg", "png", "tif".
    public static func imageExtension(_ format: CompanionImageFormat) -> String {
        switch format {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tif"
        }
    }

    /// The manifest's name for `format`: "jpeg", "png", "tiff".
    public static func formatValue(_ format: CompanionImageFormat) -> String {
        format.rawValue
    }

    /// The format the bytes start like (JPEG SOI, PNG signature, TIFF "II*\0" or "MM\0*"); nil for anything else.
    public static func sniff(_ data: Data) -> CompanionImageFormat? {
        let b = [UInt8](data.prefix(8))
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return .jpeg }
        if b.count >= 8 && b == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b.count >= 4 {
            let little = b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0
            let big = b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A
            if little || big { return .tiff }
        }
        return nil
    }

    /// The SHA-256 of `data` as 64 lowercase hex digits.
    public static func sha256Hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(64)
        for byte in SHA256Digest.hash(data) {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// A number as the manifest writes it: rounded half away from zero to 6 decimals, no exponent,
    /// no trailing zeros.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let scaled = (value * 1_000_000).rounded(.toNearestOrAwayFromZero)
        guard abs(scaled) < 9e15 else { return "0" }
        let units = Int64(scaled)
        let magnitude = units.magnitude
        var text = String(magnitude / 1_000_000)
        let fraction = magnitude % 1_000_000
        if fraction != 0 {
            var digits = String(fraction)
            digits = String(repeating: "0", count: 6 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return units < 0 ? "-" + text : text
    }

    /// A string as a JSON literal: quote, backslash and control characters escaped (\n, \r, \t,
    /// \b, \f, else \u00xx), the rest as is.
    static func quote(_ text: String) -> String {
        var json = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: json += "\\\""
            case 0x5C: json += "\\\\"
            case 0x0A: json += "\\n"
            case 0x0D: json += "\\r"
            case 0x09: json += "\\t"
            case 0x08: json += "\\b"
            case 0x0C: json += "\\f"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                json += "\\u00" + (hex.count < 2 ? "0" : "") + hex
            default:
                json.unicodeScalars.append(scalar)
            }
        }
        return json + "\""
    }

    /// "2026-10-20T08:30:00Z": UTC, to the second.
    static func formatDate(_ date: Date) -> String {
        let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        return pad(c.year ?? 0, 4) + "-" + pad(c.month ?? 0, 2) + "-" + pad(c.day ?? 0, 2) + "T"
            + pad(c.hour ?? 0, 2) + ":" + pad(c.minute ?? 0, 2) + ":" + pad(c.second ?? 0, 2) + "Z"
    }

    /// A date in exactly `formatDate`'s form; nil for anything else.
    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let chars = Array(text.utf8)
        guard chars.count == 20, chars[4] == 0x2D, chars[7] == 0x2D, chars[10] == 0x54, chars[13] == 0x3A,
              chars[16] == 0x3A, chars[19] == 0x5A else { return nil }
        func field(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for i in start..<(start + length) {
                let c = chars[i]
                guard c >= 0x30 && c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = field(0, 4), let month = field(5, 2), let day = field(8, 2), let hour = field(11, 2),
              let minute = field(14, 2), let second = field(17, 2) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = utcCalendar.date(from: components), formatDate(date) == text else { return nil }
        return date
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar
    }()

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func validate(_ document: CompanionDocument) throws {
        if document.pages.isEmpty { throw CompanionPackageError(.noPages, noPagesMessage) }
        if document.pages.count > maxPages { throw CompanionPackageError(.tooManyPages, tooManyPagesMessage) }
        for (index, page) in document.pages.enumerated() {
            try validateImage(page.image, pageNumber: index + 1, original: false)
            if let original = page.original { try validateImage(original, pageNumber: index + 1, original: true) }
            if page.rotationQuarterTurns < 0 || page.rotationQuarterTurns > 3 {
                throw CompanionPackageError(.invalidDocument, "Page \(index + 1)'s rotation must be 0 to 3 quarter turns.")
            }
            if let sheet = page.sheetIndex, sheet < 0 {
                throw CompanionPackageError(.invalidDocument, "Page \(index + 1)'s sheet cannot be negative.")
            }
        }
    }

    private static func validateImage(_ image: CompanionImage, pageNumber: Int, original: Bool) throws {
        let subject = CompanionPackage.subject(pageNumber, original: original)
        if sniff(image.data) != image.format {
            throw CompanionPackageError(.invalidDocument, "\(subject) is not a \(formatValue(image.format).uppercased()) file.")
        }
        if image.format == .tiff && image.colorMode != .blackWhite {
            throw CompanionPackageError(.invalidDocument, "\(subject) is a TIFF, which only black & white pages can be.")
        }
        if image.pixelWidth <= 0 || image.pixelHeight <= 0 || image.dpi <= 0 {
            throw CompanionPackageError(.invalidDocument, "\(subject) needs a size in pixels and a resolution.")
        }
    }

    /// ,"capture":{"quad":[x, y of the four corners clockwise from the top-left],"sourceWidth",
    /// "sourceHeight","kind"[,"focalLength"][,"scale":{"basis"[,"size"],"dpi","pixelWidth",
    /// "pixelHeight","widthInches","heightInches"}]}.
    private static func captureJSON(_ capture: CaptureFacts) -> String {
        var json = ",\"capture\":{\"quad\":["
        for i in 0..<4 {
            if i > 0 { json += "," }
            let corner = capture.quad[i]
            json += number(Double(corner.x)) + "," + number(Double(corner.y))
        }
        json += "],\"sourceWidth\":" + String(capture.sourceWidth)
        json += ",\"sourceHeight\":" + String(capture.sourceHeight)
        json += ",\"kind\":" + quote(capture.kind.rawValue)
        if let focalLength = capture.focalLength { json += ",\"focalLength\":" + number(focalLength) }
        if let scale = capture.scale {
            json += ",\"scale\":{\"basis\":" + quote(scale.basis.rawValue)
            if let size = scale.size { json += ",\"size\":" + quote(size) }
            json += ",\"dpi\":" + String(scale.dpi)
            json += ",\"pixelWidth\":" + String(scale.pixelWidth)
            json += ",\"pixelHeight\":" + String(scale.pixelHeight)
            json += ",\"widthInches\":" + number(scale.widthInches)
            json += ",\"heightInches\":" + number(scale.heightInches) + "}"
        }
        json += "}"
        return json
    }

    private static func imageJSON(_ image: CompanionImage, file: String) -> String {
        var json = "{\"file\":" + quote(file)
        json += ",\"format\":" + quote(formatValue(image.format))
        json += ",\"byteCount\":" + String(image.data.count)
        json += ",\"sha256\":" + quote(sha256Hex(image.data))
        json += ",\"pixelWidth\":" + String(image.pixelWidth)
        json += ",\"pixelHeight\":" + String(image.pixelHeight)
        json += ",\"dpi\":" + String(image.dpi)
        json += ",\"colorMode\":" + quote(image.colorMode.rawValue) + "}"
        return json
    }

    // MARK: - Reading

    /// The document in the package `data`, every picture checked.
    public static func read(_ data: Data, limits: ZipReadLimits = .standard) throws -> CompanionDocument {
        try archive { try read(ZipStoreReader(data: data, limits: limits)) }
    }

    /// The document in the package file at `url`, read from the file a picture at a time.
    public static func read(contentsOf url: URL, limits: ZipReadLimits = .standard) throws -> CompanionDocument {
        try archive { () throws -> CompanionDocument in
            let reader = try ZipStoreReader(contentsOf: url, limits: limits)
            defer { reader.close() }
            return try read(reader)
        }
    }

    public static let notPackageMessage = "This file is not a Lazy Scan document."
    public static let noPagesMessage = "This document has no pages."
    public static var tooManyPagesMessage: String { "This document has more than \(maxPages) pages." }
    public static let damagedManifestMessage = "This document cannot be opened: its list of pages is damaged."

    /// "This document was made by a newer version of Lazy Scan (package format 2). Update Lazy Scan to open it."
    public static func newerVersionMessage(_ version: Int) -> String {
        "This document was made by a newer version of Lazy Scan (package format \(version)). Update Lazy Scan to open it."
    }

    /// "Page 3's picture", "Page 3's original picture".
    public static func subject(_ pageNumber: Int, original: Bool) -> String {
        "Page \(pageNumber)'s \(original ? "original picture" : "picture")"
    }

    /// Runs `body`, turning an archive the zip reader refuses into `.invalidArchive`.
    private static func archive<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ZipReadError {
            throw CompanionPackageError(.invalidArchive, "This document cannot be opened: \(error.message)")
        }
    }

    private static func read(_ reader: ZipStoreReader) throws -> CompanionDocument {
        guard let manifestEntry = reader.entry(named: manifestName) else {
            throw CompanionPackageError(.notPackage, notPackageMessage)
        }
        if manifestEntry.size > maxManifestBytes { throw CompanionPackageError(.invalidManifest, damagedManifestMessage) }
        let manifest = try decodeManifest(try reader.read(manifestEntry))
        if manifest.format != formatName || manifest.formatVersion < 1 {
            throw CompanionPackageError(.notPackage, notPackageMessage)
        }
        if manifest.formatVersion > Int32(formatVersion) {
            throw CompanionPackageError(.newerVersion, newerVersionMessage(Int(manifest.formatVersion)))
        }
        if manifest.pages.isEmpty { throw CompanionPackageError(.noPages, noPagesMessage) }
        if manifest.pages.count > maxPages { throw CompanionPackageError(.tooManyPages, tooManyPagesMessage) }

        var used = Set<[UInt8]>() // entry names as bytes, compared exactly as the C# twin does
        var pages: [CompanionPage] = []
        pages.reserveCapacity(manifest.pages.count)
        for (index, dto) in manifest.pages.enumerated() {
            let image = try readImage(reader, dto.image, pageNumber: index + 1, original: false, used: &used)
            var original: CompanionImage?
            if let originalDTO = dto.original {
                original = try readImage(reader, originalDTO, pageNumber: index + 1, original: true, used: &used)
            }
            let side: PageSide?
            switch dto.side {
            case "front"?: side = .front
            case "back"?: side = .back
            default: side = nil
            }
            var sheet: Int?
            if let value = dto.sheetIndex, value >= 0 { sheet = Int(value) }
            let lines = dto.ocrLines?.map { line in
                OCRLine(text: line.text,
                        boundingBox: CGRect(x: line.x, y: line.y, width: line.width, height: line.height),
                        confidence: Float(line.confidence))
            }
            let rotation = dto.rotationQuarterTurns >= 0 && dto.rotationQuarterTurns <= 3 ? Int(dto.rotationQuarterTurns) : 0
            pages.append(CompanionPage(image: image, rotationQuarterTurns: rotation, side: side, sheetIndex: sheet,
                                       ocrLines: lines, original: original, capture: readCapture(dto.capture)))
        }
        return CompanionDocument(
            title: manifest.title, pages: pages,
            writer: CompanionWriterInfo(app: manifest.writer.app, appVersion: manifest.writer.appVersion,
                                        platform: manifest.writer.platform),
            created: parseDate(manifest.created), taskId: manifest.taskId,
            suggestedName: manifest.naming.suggestedName, namingTemplate: manifest.naming.template)
    }

    /// The capture facts as a package records them; nil when missing or unusable (not four finite
    /// corners, no photo size), so a damaged record costs the page only them. An unknown kind reads as a
    /// document; an unusable scale (no resolution or size) is left out, an unknown basis reads as nominal.
    private static func readCapture(_ dto: CaptureDTO?) -> CaptureFacts? {
        guard let dto = dto, let q = dto.quad, q.count == 8, dto.sourceWidth > 0, dto.sourceHeight > 0 else { return nil }
        for value in q where !value.isFinite { return nil }
        let quad = Quad(topLeft: CGPoint(x: q[0], y: q[1]), topRight: CGPoint(x: q[2], y: q[3]),
                        bottomRight: CGPoint(x: q[4], y: q[5]), bottomLeft: CGPoint(x: q[6], y: q[7]))
        let kind: CaptureKind = dto.kind.flatMap { CaptureKind(rawValue: $0) } ?? .document
        var focalLength: Double?
        if let f = dto.focalLength, f > 0, f.isFinite { focalLength = f }
        var scale: CaptureScaleResult?
        if let s = dto.scale, s.dpi > 0, s.pixelWidth > 0, s.pixelHeight > 0,
           s.widthInches > 0, s.widthInches.isFinite, s.heightInches > 0, s.heightInches.isFinite {
            let basis: CaptureScaleBasis = s.basis.flatMap { CaptureScaleBasis(rawValue: $0) } ?? .nominal
            scale = CaptureScaleResult(basis: basis, size: s.size, dpi: Int(s.dpi), pixelWidth: Int(s.pixelWidth),
                                       pixelHeight: Int(s.pixelHeight), widthInches: s.widthInches,
                                       heightInches: s.heightInches)
        }
        return CaptureFacts(quad: quad, sourceWidth: Int(dto.sourceWidth), sourceHeight: Int(dto.sourceHeight),
                            kind: kind, focalLength: focalLength, scale: scale)
    }

    /// The manifest as the C# twin reads it (`StoreFiles.Decode`), through the same settings-file
    /// rules as `StoreFiles.utf8JSON`: UTF-8 with or without a byte-order mark, UTF-16 or UTF-32,
    /// text invalid in its encoding damaging the whole manifest whichever JSONDecoder runs, and no
    /// comma before a closing bracket or brace (System.Text.Json refuses one; JSONDecoder takes it).
    private static func decodeManifest(_ bytes: Data) throws -> ManifestDTO {
        do {
            return try JSONDecoder().decode(ManifestDTO.self, from: StoreFiles.utf8JSON(bytes))
        } catch {
            throw CompanionPackageError(.invalidManifest, damagedManifestMessage)
        }
    }

    private static func readImage(_ reader: ZipStoreReader, _ dto: ImageDTO?, pageNumber: Int, original: Bool,
                                  used: inout Set<[UInt8]>) throws -> CompanionImage {
        let subject = CompanionPackage.subject(pageNumber, original: original)
        let missing = CompanionPackageError(.missingImage, "\(subject) is missing from the document.")
        guard let dto, !dto.file.isEmpty, !dto.file.utf8.elementsEqual(manifestName.utf8) else { throw missing }
        if !used.insert(Array(dto.file.utf8)).inserted {
            throw CompanionPackageError(.invalidManifest, "This document cannot be opened: \(subject) is listed twice.")
        }
        guard let entry = reader.entry(named: dto.file) else { throw missing }
        let damaged = CompanionPackageError(.checksumMismatch, "\(subject) is damaged: its checksum does not match.")
        if let count = dto.byteCount, count != Int64(entry.size) { throw damaged }
        let data = try reader.read(entry)
        if dto.sha256.lowercased() != sha256Hex(data) { throw damaged }
        let unsupported = CompanionPackageError(
            .unsupportedImage, "\(subject) is in a format this version of Lazy Scan cannot read.")
        guard let format = sniff(data) else { throw unsupported }
        if let named = dto.format, CompanionImageFormat(rawValue: named) != format { throw unsupported }
        return CompanionImage(data: data, format: format, pixelWidth: max(Int(dto.pixelWidth), 0),
                              pixelHeight: max(Int(dto.pixelHeight), 0),
                              dpi: dto.dpi > 0 ? Int(dto.dpi) : defaultDpi, colorMode: dto.colorMode)
    }
}

// MARK: - The manifest as read

// Every property on its own and leniently (`decodeLenient`), the defaults below for anything
// missing, null, wrong-typed or unknown. Whole numbers are 32-bit like the C# twin's, so a value
// past Int32 falls back on both platforms; one written with a fraction or an exponent ("1.0",
// "3e2") reads when its value is whole and in range, as JSONDecoder does and the C# twin's
// WholeNumberConverter mirrors.

private struct ManifestDTO: Decodable {
    var format = ""
    var formatVersion: Int32 = 0
    var formatMinor: Int32 = 0
    var writer = WriterDTO()
    var created: String?
    var title = ""
    var taskId: String?
    var naming = NamingDTO()
    var pages: [PageDTO] = []

    enum CodingKeys: String, CodingKey {
        case format, formatVersion, formatMinor, writer, created, title, taskId, naming, pages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.decodeLenient(forKey: .format, default: format)
        formatVersion = c.decodeLenient(forKey: .formatVersion, default: formatVersion)
        formatMinor = c.decodeLenient(forKey: .formatMinor, default: formatMinor)
        writer = c.decodeLenient(forKey: .writer, default: writer)
        created = c.decodeLenient(forKey: .created, default: created)
        title = c.decodeLenient(forKey: .title, default: title)
        taskId = c.decodeLenient(forKey: .taskId, default: taskId)
        naming = c.decodeLenient(forKey: .naming, default: naming)
        pages = c.decodeLenient(forKey: .pages, default: pages)
    }
}

private struct WriterDTO: Decodable {
    var app = ""
    var appVersion = ""
    var platform = ""

    enum CodingKeys: String, CodingKey { case app, appVersion, platform }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = c.decodeLenient(forKey: .app, default: app)
        appVersion = c.decodeLenient(forKey: .appVersion, default: appVersion)
        platform = c.decodeLenient(forKey: .platform, default: platform)
    }
}

private struct NamingDTO: Decodable {
    var suggestedName: String?
    var template: String?

    enum CodingKeys: String, CodingKey { case suggestedName, template }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestedName = c.decodeLenient(forKey: .suggestedName, default: suggestedName)
        template = c.decodeLenient(forKey: .template, default: template)
    }
}

private struct PageDTO: Decodable {
    var image: ImageDTO?
    var rotationQuarterTurns: Int32 = 0
    var side: String?
    var sheetIndex: Int32?
    var ocrLines: [OCRLineDTO]?
    var original: ImageDTO?
    var capture: CaptureDTO?

    enum CodingKeys: String, CodingKey { case image, rotationQuarterTurns, side, sheetIndex, ocrLines, original, capture }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = c.decodeLenient(forKey: .image, default: image)
        rotationQuarterTurns = c.decodeLenient(forKey: .rotationQuarterTurns, default: rotationQuarterTurns)
        side = c.decodeLenient(forKey: .side, default: side)
        sheetIndex = c.decodeLenient(forKey: .sheetIndex, default: sheetIndex)
        ocrLines = c.decodeLenient(forKey: .ocrLines, default: ocrLines)
        original = c.decodeLenient(forKey: .original, default: original)
        capture = c.decodeLenient(forKey: .capture, default: capture)
    }
}

private struct CaptureDTO: Decodable {
    var quad: [Double]?
    var sourceWidth: Int32 = 0
    var sourceHeight: Int32 = 0
    var kind: String?
    var focalLength: Double?
    var scale: ScaleDTO?

    enum CodingKeys: String, CodingKey { case quad, sourceWidth, sourceHeight, kind, focalLength, scale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quad = c.decodeLenient(forKey: .quad, default: quad)
        sourceWidth = c.decodeLenient(forKey: .sourceWidth, default: sourceWidth)
        sourceHeight = c.decodeLenient(forKey: .sourceHeight, default: sourceHeight)
        kind = c.decodeLenient(forKey: .kind, default: kind)
        focalLength = c.decodeLenient(forKey: .focalLength, default: focalLength)
        scale = c.decodeLenient(forKey: .scale, default: scale)
    }
}

private struct ScaleDTO: Decodable {
    var basis: String?
    var size: String?
    var dpi: Int32 = 0
    var pixelWidth: Int32 = 0
    var pixelHeight: Int32 = 0
    var widthInches = 0.0
    var heightInches = 0.0

    enum CodingKeys: String, CodingKey { case basis, size, dpi, pixelWidth, pixelHeight, widthInches, heightInches }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        basis = c.decodeLenient(forKey: .basis, default: basis)
        size = c.decodeLenient(forKey: .size, default: size)
        dpi = c.decodeLenient(forKey: .dpi, default: dpi)
        pixelWidth = c.decodeLenient(forKey: .pixelWidth, default: pixelWidth)
        pixelHeight = c.decodeLenient(forKey: .pixelHeight, default: pixelHeight)
        widthInches = c.decodeLenient(forKey: .widthInches, default: widthInches)
        heightInches = c.decodeLenient(forKey: .heightInches, default: heightInches)
    }
}

private struct ImageDTO: Decodable {
    var file = ""
    var format: String?
    var byteCount: Int64?
    var sha256 = ""
    var pixelWidth: Int32 = 0
    var pixelHeight: Int32 = 0
    var dpi: Int32 = 0
    var colorMode: ColorMode = .color

    enum CodingKeys: String, CodingKey { case file, format, byteCount, sha256, pixelWidth, pixelHeight, dpi, colorMode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = c.decodeLenient(forKey: .file, default: file)
        format = c.decodeLenient(forKey: .format, default: format)
        byteCount = c.decodeLenient(forKey: .byteCount, default: byteCount)
        sha256 = c.decodeLenient(forKey: .sha256, default: sha256)
        pixelWidth = c.decodeLenient(forKey: .pixelWidth, default: pixelWidth)
        pixelHeight = c.decodeLenient(forKey: .pixelHeight, default: pixelHeight)
        dpi = c.decodeLenient(forKey: .dpi, default: dpi)
        colorMode = c.decodeLenient(forKey: .colorMode, default: colorMode)
    }
}

private struct OCRLineDTO: Decodable {
    var text = ""
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    var confidence = 0.0

    enum CodingKeys: String, CodingKey { case text, x, y, width, height, confidence }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.decodeLenient(forKey: .text, default: text)
        x = c.decodeLenient(forKey: .x, default: x)
        y = c.decodeLenient(forKey: .y, default: y)
        width = c.decodeLenient(forKey: .width, default: width)
        height = c.decodeLenient(forKey: .height, default: height)
        confidence = c.decodeLenient(forKey: .confidence, default: confidence)
    }
}

// MARK: - SHA-256

/// SHA-256 (FIPS 180-4) over a whole buffer, written out because Foundation has none. Also used by
/// the phone link (`SpkiFingerprint`, `PairedDeviceStore`).
enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
                           0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19]
        var w = [UInt32](repeating: 0, count: 64)
        let count = data.count
        let fullBlocks = count / 64
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for block in 0..<fullBlocks {
                compress(&h, &w, raw, at: block * 64)
            }
        }
        // The last bytes, a 1 bit, zeros, and the length in bits.
        var tail = [UInt8](data.suffix(count - fullBlocks * 64))
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = UInt64(count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        tail.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for block in 0..<(raw.count / 64) {
                compress(&h, &w, raw, at: block * 64)
            }
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in h {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    private static func compress(_ h: inout [UInt32], _ w: inout [UInt32], _ bytes: UnsafeRawBufferPointer, at offset: Int) {
        for t in 0..<16 {
            let i = offset + 4 * t
            var word = UInt32(bytes[i]) << 24
            word |= UInt32(bytes[i + 1]) << 16
            word |= UInt32(bytes[i + 2]) << 8
            word |= UInt32(bytes[i + 3])
            w[t] = word
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choose = (e & f) ^ (~e & g)
            let t1 = hh &+ bigS1 &+ choose &+ k[t] &+ w[t]
            let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = bigS0 &+ majority
            hh = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }
        h[0] = h[0] &+ a
        h[1] = h[1] &+ b
        h[2] = h[2] &+ c
        h[3] = h[3] &+ d
        h[4] = h[4] &+ e
        h[5] = h[5] &+ f
        h[6] = h[6] &+ g
        h[7] = h[7] &+ hh
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
