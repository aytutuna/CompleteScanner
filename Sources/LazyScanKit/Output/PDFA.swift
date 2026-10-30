import Foundation

// Twin of windows/LazyScan.Core/PdfA.cs (PdfConformance, PdfWriteOptions, PdfA): the same XMP
// packet, information dictionary, output intent and sRGB profile bytes, so a PDF/A file is the same
// file on both platforms (PDFATests' golden value, pinned in C#). C# `DateTimeOffset` is a `Date`
// with the `TimeZone` whose offset it is written with; C#'s exceptions are `ScanError.exportFailed`.

/// Which standard a written PDF follows. The first case is the default (C# `PdfConformance`).
public enum PDFConformance: String, CaseIterable, Sendable {
    /// A plain PDF file: PDF 1.4, or PDF 1.7 when it is password-protected.
    case standard
    /// PDF/A-2b (ISO 19005-2, level B) for long-term keeping: PDF 1.7, XMP metadata matching the
    /// document information, an sRGB output intent and a file identifier. Never encrypted.
    case pdfA2b
}

/// Where a protected file's key, salts and IVs come from: `count` bytes each time it is called
/// (C#'s `Action<Span<byte>>`); it throws when it has none. `PDFEncryption.systemRandom` unless a test
/// gives another.
public typealias PDFRandomSource = (_ count: Int) throws -> [UInt8]

/// How `PDFWriter` writes a document beyond its pages (C# `PdfWriteOptions`). The date, the file
/// identifier and (for a protected file) the random bytes are taken from here when given, so the same
/// input gives the same bytes (tests); otherwise the current time and random bytes are used. The options
/// go along to the task that writes the PDF; their protection and random source are used there only.
public struct PDFWriteOptions: @unchecked Sendable {
    /// The options of a plain PDF.
    public static var standard: PDFWriteOptions { PDFWriteOptions() }

    public var conformance: PDFConformance

    /// The document's title (the file name without its extension); nil leaves it out.
    public var title: String?

    /// When the document was made (whole seconds are written); nil means now.
    public var creationDate: Date?

    /// The time zone whose offset the date is written with (C#'s `DateTimeOffset.Offset`); nil means
    /// the current one.
    public var timeZone: TimeZone?

    /// The 16-byte file identifier (/ID); nil (or another length) means random bytes.
    public var documentId: [UInt8]?

    /// The password the file opens with and its permissions (AES-256, `PDFEncryption`); nil writes a
    /// file anyone can open. A PDF/A file can't have one: `PDFWriter` refuses options asking for both.
    public var protection: PDFProtection?

    /// Where a protected file's key, salts and IVs come from (tests); nil: `SecRandomCopyBytes`.
    var random: PDFRandomSource?

    public init(conformance: PDFConformance = .standard, title: String? = nil, creationDate: Date? = nil,
                timeZone: TimeZone? = nil, documentId: [UInt8]? = nil, protection: PDFProtection? = nil) {
        self.conformance = conformance
        self.title = title
        self.creationDate = creationDate
        self.timeZone = timeZone
        self.documentId = documentId
        self.protection = protection
        self.random = nil
    }

    public var isArchival: Bool { conformance == .pdfA2b }

    public var isProtected: Bool { protection != nil }

    /// The options a save with `output` asks for, titled `title`: protected with `protection` when the
    /// password option is on (`OutputOptions.protect`; it must then be given, else this throws), else
    /// PDF/A-2b when the archival option is on (`OutputOptions.archival`). The two exclude each other;
    /// a settings file with both on gets the password, never a file anyone can open. C# `For`.
    public static func forOutput(_ output: OutputOptions, title: String?,
                                 protection: PDFProtection? = nil) throws -> PDFWriteOptions {
        if output.protect && protection == nil {
            throw ScanError.exportFailed("The password option is on: a password is needed.")
        }
        var options = PDFWriteOptions()
        options.conformance = output.archival && !output.protect ? .pdfA2b : .standard
        options.title = title
        options.protection = output.protect ? protection : nil
        return options
    }
}

/// What a PDF/A-2b file carries besides its pages: the XMP metadata packet, the document information
/// dictionary that must say the same, and the sRGB output intent. Used by `PDFWriter`; the texts of
/// the archival option are here too. Twin of C# `PdfA`.
public enum PDFA {
    /// What the file names as its producer and creator tool (pdf:Producer, xmp:CreatorTool).
    public static let producer = "Lazy Scan"

    /// The output intent's condition: the color space of the embedded profile.
    public static let outputConditionIdentifier = "sRGB IEC61966-2.1"

    /// The archival switch in the inspector's Archive & password section.
    public static let optionLabel = "Archival PDF (PDF/A)"

    /// What the switch does, on hover.
    public static let optionHint = "Made to look the same for years. Can't have a password."

    /// What the switch does, for screen readers.
    public static let optionHelp =
        "Made to be kept for years: a PDF/A file holds everything it needs to look the same later. PDF/A files can't have a password."

    /// Why the switch is greyed out while the password is on, shown next to it.
    public static let notWithPasswordReason = "Not with a password"

    /// Why the password option is greyed out while the archival option is on, and the other way round.
    public static let cannotProtectNote = "PDF/A can't be password-protected."

    /// The sRGB color profile embedded as the output intent: "sRGB-v2-magic.icc" from
    /// Compact-ICC-Profiles by Clinton Ingram (https://github.com/saucecontrol/Compact-ICC-Profiles),
    /// released to the public domain under CC0 1.0. An ICC v2.1 display profile, 736 bytes,
    /// SHA-256 af4efe28f6d311799865f325ba39184a2e978b113ca74124d60af7de22b105f4: the same bytes as
    /// C# `PdfA.SrgbProfile`. Do not change the array.
    public static let srgbProfile: [UInt8] = [
        0x00, 0x00, 0x02, 0xE0, 0x6C, 0x63, 0x6D, 0x73, 0x02, 0x10, 0x00, 0x00, 0x6D, 0x6E, 0x74, 0x72,
        0x52, 0x47, 0x42, 0x20, 0x58, 0x59, 0x5A, 0x20, 0x07, 0xE2, 0x00, 0x03, 0x00, 0x14, 0x00, 0x09,
        0x00, 0x0E, 0x00, 0x1D, 0x61, 0x63, 0x73, 0x70, 0x4D, 0x53, 0x46, 0x54, 0x00, 0x00, 0x00, 0x00,
        0x73, 0x61, 0x77, 0x73, 0x63, 0x74, 0x72, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF6, 0xD6, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0xD3, 0x2D,
        0x68, 0x61, 0x6E, 0x64, 0x93, 0xB2, 0x34, 0xA9, 0x0E, 0xB0, 0x22, 0x8A, 0x98, 0xFD, 0x9A, 0xAF,
        0xA3, 0x67, 0x89, 0x9B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x09, 0x64, 0x65, 0x73, 0x63, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00, 0x5F,
        0x63, 0x70, 0x72, 0x74, 0x00, 0x00, 0x01, 0x0C, 0x00, 0x00, 0x00, 0x0C, 0x77, 0x74, 0x70, 0x74,
        0x00, 0x00, 0x01, 0x18, 0x00, 0x00, 0x00, 0x14, 0x72, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x2C,
        0x00, 0x00, 0x00, 0x14, 0x67, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0x14,
        0x62, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x54, 0x00, 0x00, 0x00, 0x14, 0x72, 0x54, 0x52, 0x43,
        0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x01, 0x78, 0x67, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x68,
        0x00, 0x00, 0x01, 0x78, 0x62, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x01, 0x78,
        0x64, 0x65, 0x73, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x73, 0x52, 0x47, 0x42,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x74, 0x65, 0x78, 0x74,
        0x00, 0x00, 0x00, 0x00, 0x43, 0x43, 0x30, 0x00, 0x58, 0x59, 0x5A, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xF3, 0x54, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x16, 0xC9, 0x58, 0x59, 0x5A, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6F, 0xA0, 0x00, 0x00, 0x38, 0xF2, 0x00, 0x00, 0x03, 0x8F,
        0x58, 0x59, 0x5A, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x96, 0x00, 0x00, 0xB7, 0x89,
        0x00, 0x00, 0x18, 0xDA, 0x58, 0x59, 0x5A, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0xA0,
        0x00, 0x00, 0x0F, 0x85, 0x00, 0x00, 0xB6, 0xC4, 0x63, 0x75, 0x72, 0x76, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0xB6, 0x00, 0x00, 0x00, 0x1C, 0x00, 0x38, 0x00, 0x54, 0x00, 0x70, 0x00, 0x8C,
        0x00, 0xA8, 0x00, 0xC4, 0x00, 0xE1, 0x01, 0x00, 0x01, 0x22, 0x01, 0x46, 0x01, 0x6D, 0x01, 0x95,
        0x01, 0xC1, 0x01, 0xF0, 0x02, 0x20, 0x02, 0x55, 0x02, 0x8B, 0x02, 0xC4, 0x03, 0x01, 0x03, 0x3F,
        0x03, 0x82, 0x03, 0xC6, 0x04, 0x0E, 0x04, 0x59, 0x04, 0xA7, 0x04, 0xF9, 0x05, 0x4C, 0x05, 0xA4,
        0x05, 0xFE, 0x06, 0x5C, 0x06, 0xBE, 0x07, 0x21, 0x07, 0x8A, 0x07, 0xF4, 0x08, 0x63, 0x08, 0xD5,
        0x09, 0x49, 0x09, 0xC3, 0x0A, 0x3F, 0x0A, 0xBF, 0x0B, 0x42, 0x0B, 0xC9, 0x0C, 0x54, 0x0C, 0xE1,
        0x0D, 0x74, 0x0E, 0x09, 0x0E, 0xA2, 0x0F, 0x40, 0x0F, 0xE0, 0x10, 0x85, 0x11, 0x2D, 0x11, 0xDA,
        0x12, 0x8A, 0x13, 0x3E, 0x13, 0xF6, 0x14, 0xB2, 0x15, 0x71, 0x16, 0x36, 0x16, 0xFD, 0x17, 0xCA,
        0x18, 0x99, 0x19, 0x6E, 0x1A, 0x46, 0x1B, 0x22, 0x1C, 0x03, 0x1C, 0xE7, 0x1D, 0xD0, 0x1E, 0xBD,
        0x1F, 0xAE, 0x20, 0xA4, 0x21, 0x9E, 0x22, 0x9C, 0x23, 0x9F, 0x24, 0xA5, 0x25, 0xB1, 0x26, 0xC0,
        0x27, 0xD5, 0x28, 0xED, 0x2A, 0x0A, 0x2B, 0x2B, 0x2C, 0x51, 0x2D, 0x7C, 0x2E, 0xAA, 0x2F, 0xDE,
        0x31, 0x16, 0x32, 0x52, 0x33, 0x94, 0x34, 0xD9, 0x36, 0x24, 0x37, 0x73, 0x38, 0xC6, 0x3A, 0x20,
        0x3B, 0x7C, 0x3C, 0xDF, 0x3E, 0x45, 0x3F, 0xB0, 0x41, 0x21, 0x42, 0x96, 0x44, 0x10, 0x45, 0x8F,
        0x47, 0x12, 0x48, 0x9B, 0x4A, 0x28, 0x4B, 0xBB, 0x4D, 0x51, 0x4E, 0xEE, 0x50, 0x8F, 0x52, 0x35,
        0x53, 0xE0, 0x55, 0x90, 0x57, 0x45, 0x59, 0x00, 0x5A, 0xBE, 0x5C, 0x84, 0x5E, 0x4C, 0x60, 0x1B,
        0x61, 0xEF, 0x63, 0xC7, 0x65, 0xA6, 0x67, 0x89, 0x69, 0x71, 0x6B, 0x5F, 0x6D, 0x51, 0x6F, 0x4A,
        0x71, 0x46, 0x73, 0x4A, 0x75, 0x51, 0x77, 0x5E, 0x79, 0x71, 0x7B, 0x88, 0x7D, 0xA6, 0x7F, 0xC8,
        0x81, 0xF0, 0x84, 0x1E, 0x86, 0x50, 0x88, 0x89, 0x8A, 0xC5, 0x8D, 0x09, 0x8F, 0x51, 0x91, 0x9F,
        0x93, 0xF3, 0x96, 0x4B, 0x98, 0xAB, 0x9B, 0x0E, 0x9D, 0x78, 0x9F, 0xE7, 0xA2, 0x5B, 0xA4, 0xD6,
        0xA7, 0x56, 0xA9, 0xDB, 0xAC, 0x67, 0xAE, 0xF7, 0xB1, 0x8F, 0xB4, 0x2A, 0xB6, 0xCC, 0xB9, 0x74,
        0xBC, 0x21, 0xBE, 0xD5, 0xC1, 0x8D, 0xC4, 0x4C, 0xC7, 0x10, 0xC9, 0xDA, 0xCC, 0xAB, 0xCF, 0x7F,
        0xD2, 0x5C, 0xD5, 0x3D, 0xD8, 0x24, 0xDB, 0x12, 0xDE, 0x04, 0xE0, 0xFE, 0xE3, 0xFC, 0xE7, 0x01,
        0xEA, 0x0C, 0xED, 0x1C, 0xF0, 0x34, 0xF3, 0x50, 0xF6, 0x73, 0xF9, 0x9B, 0xFC, 0xCA, 0xFF, 0xFF,
    ]

    /// A date in a PDF string, in `timeZone`'s offset at that moment: "D:20261019213005+03'00'".
    public static func pdfDate(_ date: Date, timeZone: TimeZone) -> String {
        let parts = DateParts(date, timeZone: timeZone)
        var text: String = "D:" + pad(parts.year, 4) + pad(parts.month, 2) + pad(parts.day, 2)
        text += pad(parts.hour, 2) + pad(parts.minute, 2) + pad(parts.second, 2)
        return text + offset(parts.offsetSeconds, separator: "'") + "'"
    }

    /// The same date in XMP: "2026-10-19T21:30:05+03:00".
    public static func xmpDate(_ date: Date, timeZone: TimeZone) -> String {
        let parts = DateParts(date, timeZone: timeZone)
        var text: String = pad(parts.year, 4) + "-" + pad(parts.month, 2) + "-" + pad(parts.day, 2) + "T"
        text += pad(parts.hour, 2) + ":" + pad(parts.minute, 2) + ":" + pad(parts.second, 2)
        return text + offset(parts.offsetSeconds, separator: ":")
    }

    /// The calendar fields of a date in a time zone's offset at that moment, and that offset.
    private struct DateParts {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
        let offsetSeconds: Int

        init(_ date: Date, timeZone: TimeZone) {
            let seconds: Int = timeZone.secondsFromGMT(for: date)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: seconds) ?? timeZone
            let fields: DateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                                 from: date)
            year = fields.year ?? 0
            month = fields.month ?? 0
            day = fields.day ?? 0
            hour = fields.hour ?? 0
            minute = fields.minute ?? 0
            second = fields.second ?? 0
            offsetSeconds = seconds
        }
    }

    /// "+03" + separator + "00"; "-05" + separator + "30" (whole minutes, as C#'s TimeSpan gives them).
    private static func offset(_ seconds: Int, separator: String) -> String {
        let sign: String = seconds < 0 ? "-" : "+"
        let minutes: Int = abs(seconds) / 60
        return sign + pad(minutes / 60, 2) + separator + pad(minutes % 60, 2)
    }

    /// `value` in decimal, zero-padded to `digits` (C#'s "D2", "yyyy").
    private static func pad(_ value: Int, _ digits: Int) -> String {
        PDFObjectWriter.padded(value, digits: digits)
    }

    /// `text` as a PDF text string: a literal "(...)" when it is printable ASCII (with "\", "(" and
    /// ")" escaped), otherwise UTF-16BE with its byte order mark, in hex.
    public static func textString(_ text: String) -> String {
        var printable = true
        for unit in text.utf16 where unit < 0x20 || unit > 0x7E {
            printable = false
            break
        }
        if printable {
            var literal = "("
            for unit in text.utf16 {
                if unit == 0x5C || unit == 0x28 || unit == 0x29 { literal += "\\" }
                literal.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            }
            return literal + ")"
        }
        var hex = "<FEFF"
        for unit in text.utf16 {
            hex += hex4(unit)
        }
        return hex + ">"
    }

    /// A UTF-16 code unit as four upper-case hex digits.
    private static func hex4(_ unit: UInt16) -> String {
        let digits: [Character] = Array("0123456789ABCDEF")
        var text = ""
        var shift = 12
        while shift >= 0 {
            let nibble = Int((unit >> UInt16(shift)) & 0xF)
            text.append(digits[nibble])
            shift -= 4
        }
        return text
    }

    /// A title with the characters XML cannot hold removed (control characters, U+FFFE, U+FFFF and
    /// lone surrogates, which a Swift string never holds), so the XMP and the information dictionary
    /// carry the same text.
    public static func cleanTitle(_ title: String) -> String {
        let units: [UInt16] = Array(title.utf16)
        var kept: [UInt16] = []
        kept.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let unit: UInt16 = units[i]
            let high: Bool = unit >= 0xD800 && unit <= 0xDBFF
            if high && i + 1 < units.count && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF {
                kept.append(unit)
                kept.append(units[i + 1])
                i += 2
                continue
            }
            let surrogate: Bool = unit >= 0xD800 && unit <= 0xDFFF
            if !surrogate && unit >= 0x20 && unit != 0x7F && unit != 0xFFFE && unit != 0xFFFF {
                kept.append(unit)
            }
            i += 1
        }
        return String(decoding: kept, as: UTF16.self)
    }

    /// The document information dictionary: /Title (when given), /Producer, /Creator, /CreationDate
    /// and /ModDate, each the same as its XMP property (`xmp`).
    public static func infoDictionary(title: String?, date: Date, timeZone: TimeZone) -> String {
        var text = "<<"
        if let title { text += "/Title " + textString(title) + " " }
        let written: String = pdfDate(date, timeZone: timeZone)
        text += "/Producer (" + producer + ") /Creator (" + producer + ") "
        text += "/CreationDate (" + written + ") /ModDate (" + written + ")>>"
        return text
    }

    /// The XMP packet, UTF-8 without a byte order mark: PDF/A-2 level B (pdfaid), the title
    /// (dc:title, when given), the dates (xmp:CreateDate, ModifyDate and MetadataDate) and the
    /// producer (pdf:Producer, xmp:CreatorTool), matching `infoDictionary`.
    public static func xmp(title: String?, date: Date, timeZone: TimeZone) -> Data {
        let written: String = xmpDate(date, timeZone: timeZone)
        var text = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
        text += "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n"
        text += " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        text += "  <rdf:Description rdf:about=\"\"\n"
        text += "    xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"\n"
        text += "    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n"
        text += "    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n"
        text += "    xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">\n"
        text += "   <pdfaid:part>2</pdfaid:part>\n"
        text += "   <pdfaid:conformance>B</pdfaid:conformance>\n"
        text += "   <dc:format>application/pdf</dc:format>\n"
        if let title {
            text += "   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">"
            text += escapeXML(title) + "</rdf:li></rdf:Alt></dc:title>\n"
        }
        text += "   <xmp:CreateDate>" + written + "</xmp:CreateDate>\n"
        text += "   <xmp:ModifyDate>" + written + "</xmp:ModifyDate>\n"
        text += "   <xmp:MetadataDate>" + written + "</xmp:MetadataDate>\n"
        text += "   <xmp:CreatorTool>" + producer + "</xmp:CreatorTool>\n"
        text += "   <pdf:Producer>" + producer + "</pdf:Producer>\n"
        text += "  </rdf:Description>\n"
        text += " </rdf:RDF>\n"
        text += "</x:xmpmeta>\n"
        text += "<?xpacket end=\"w\"?>"
        return Data(text.utf8)
    }

    /// `text` with "&", "<", ">" and the double quote written as XML entities.
    private static func escapeXML(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// The catalog's /OutputIntents entry, its profile in object `profileObject`.
    public static func outputIntents(_ profileObject: Int) -> String {
        var text: String = "[<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier ("
        text += outputConditionIdentifier + ") /Info (" + outputConditionIdentifier + ") "
        text += "/DestOutputProfile \(profileObject) 0 R>>]"
        return text
    }
}
