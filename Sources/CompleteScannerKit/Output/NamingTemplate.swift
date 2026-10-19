import Foundation

public struct NamingTemplate {
    public let template: String

    public init(_ template: String) {
        self.template = template
    }

    /// Tokens: {date}=yyyy-MM-dd, {time}=HH.mm.ss, {year} {month} {day}, {counter} (also {counter:N}
    /// zero-padded), {intent} ("Document"/"Photos"), {index} (photo number in a batch, empty when nil).
    /// Unknown tokens pass through; result sanitized for the filesystem (no "/" or ":").
    /// Same as `baseFilename(_:)` without a task or document date.
    public func baseFilename(counter: Int, date: Date, intent: ScanIntent, index: Int?) -> String {
        baseFilename(NamingContext(counter: counter, date: date, intent: intent, index: index))
    }

    /// The file name (without extension) for `context`: the tokens of
    /// `baseFilename(counter:date:intent:index:)`, plus {task} (the task's `fileLabel`, or the
    /// {intent} text when there is no task), {docdate} (the date printed on the document,
    /// yyyy-MM-dd, read from its text; the scan date when there is none) and {label} (the
    /// document's name, cut to `maxLabelBytes` and sanitized like the rest; empty when it has none).
    public func baseFilename(_ context: NamingContext) -> String {
        let counter = context.counter
        let date = context.date
        let index = context.index
        var result = template

        // {counter:N} — zero-padded to N digits.
        while let range = result.range(of: "\\{counter:[0-9]+\\}", options: .regularExpression) {
            let token = result[range]
            let widthText = token.dropFirst("{counter:".count).dropLast()
            let width = min(Int(widthText) ?? 1, 20)
            result.replaceSubrange(range, with: zeroPadded(counter, width: width))
        }

        let replacements: [(String, String)] = [
            ("{date}", formatted(date, "yyyy-MM-dd")),
            ("{time}", formatted(date, "HH.mm.ss")),
            ("{year}", formatted(date, "yyyy")),
            ("{month}", formatted(date, "MM")),
            ("{day}", formatted(date, "dd")),
            ("{counter}", String(counter)),
            ("{intent}", context.intent.label),
            ("{index}", index.map(String.init) ?? ""),
            ("{task}", context.task.map { TaskCatalog.definition($0).fileLabel } ?? context.intent.label),
            ("{docdate}", (context.documentDate ?? DocumentDate(date: date)).text),
            ("{label}", Self.cutToBytes(context.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                        maxBytes: Self.maxLabelBytes)),
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }

        // In a photo batch, make sure every file gets its index even when the
        // template has no {index} token, so batch photos never collide.
        if let index, !template.contains("{index}") {
            result += " \(index)"
        }

        return sanitized(result)
    }

    /// The most UTF-8 bytes {label} adds to a file name: a long document name is cut (between
    /// characters), so the name stays well within the 255 a file name can have on the Mac and Windows.
    public static let maxLabelBytes = 120

    /// The first characters of `text` that fit in `maxBytes` bytes of UTF-8; never cuts inside a character.
    static func cutToBytes(_ text: String, maxBytes: Int) -> String {
        if text.utf8.count <= maxBytes { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maxBytes { break }
            bytes += size
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// base.ext, appending " 2", " 3", … until the name is free.
    public static func uniqueURL(in directory: URL, base: String, fileExtension: String) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    // MARK: - Private helpers

    private func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func zeroPadded(_ value: Int, width: Int) -> String {
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }

    /// Make the name safe for the filesystem: no "/" or ":", no leading/trailing
    /// whitespace, no doubled spaces, never empty.
    private func sanitized(_ name: String) -> String {
        var result = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.isEmpty ? "Scan" : result
    }
}

/// Everything a file name can be built from (see `NamingTemplate.baseFilename(_:)`). Later
/// naming tokens add their values here as further optional properties, so the signature of
/// `baseFilename(_:)` stays the same. Twin of C# `NamingContext`.
public struct NamingContext: Equatable, Sendable {
    /// The running number for {counter}.
    public var counter: Int
    /// The scan date and time for {date}, {time}, {year}, {month} and {day}.
    public var date: Date
    /// The scan mode for {intent}.
    public var intent: ScanIntent
    /// The file's number within a batch for {index}; appended when the template has no {index}.
    public var index: Int?
    /// The task for {task}; nil gives the {intent} text.
    public var task: ScanTask?
    /// The date printed on the document for {docdate} (a receipt's date, read from its text by
    /// `ReceiptDateExtractor`); nil gives the date of `date`.
    public var documentDate: DocumentDate?
    /// The document's name for {label}: given to it in the page strip when the queue is split into
    /// documents (`SaveDocument.label`); nil gives an empty text.
    public var label: String?

    public init(counter: Int, date: Date, intent: ScanIntent, index: Int? = nil, task: ScanTask? = nil,
                documentDate: DocumentDate? = nil, label: String? = nil) {
        self.counter = counter
        self.date = date
        self.intent = intent
        self.index = index
        self.task = task
        self.documentDate = documentDate
        self.label = label
    }
}

/// A calendar day with no time and no time zone: the date printed on a document. Twin of C#
/// `DocumentDate` (NamingTemplate.cs).
public struct DocumentDate: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The year, 1 to 9999.
    public let year: Int
    /// The month, 1 to 12.
    public let month: Int
    /// The day of the month, 1 to its last day.
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day of `date` as the Gregorian calendar shows it in `timeZone` (the user's by default,
    /// as `{date}` is written).
    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The day when it exists in the Gregorian calendar (years 1 to 9999), else nil.
    public static func make(year: Int, month: Int, day: Int) -> DocumentDate? {
        isValid(year: year, month: month, day: day) ? DocumentDate(year: year, month: month, day: day) : nil
    }

    /// Whether the day exists: a month of 1 to 12 and a day up to its last, leap years included.
    public static func isValid(year: Int, month: Int, day: Int) -> Bool {
        (1...9999).contains(year) && (1...12).contains(month) && day >= 1 && day <= daysInMonth(year: year, month: month)
    }

    /// The days of `month` in `year` (Gregorian leap years).
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (negative before it), for counting days between dates.
    public var dayNumber: Int {
        // Days from civil (H. Hinnant's algorithm), integer arithmetic only.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The same day `years` years later (earlier when negative); 29 February becomes the 28th in a common year.
    public func addingYears(_ years: Int) -> DocumentDate {
        let newYear = year + years
        return DocumentDate(year: newYear, month: month, day: min(day, DocumentDate.daysInMonth(year: newYear, month: month)))
    }

    public static func < (a: DocumentDate, b: DocumentDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// "2026-03-12": the form file names use.
    public var text: String {
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
        }
        return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
    }

    public var description: String { text }
}
