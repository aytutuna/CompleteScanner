import Foundation

public struct NamingTemplate {
    public let template: String

    public init(_ template: String) {
        self.template = template
    }

    /// Tokens: {date}=yyyy-MM-dd, {time}=HH.mm.ss, {year} {month} {day}, {counter} (also {counter:N}
    /// zero-padded), {intent} ("Document"/"Photos"), {index} (photo number in a batch, empty when nil).
    /// Unknown tokens pass through; result sanitized for the filesystem (no "/" or ":").
    public func baseFilename(counter: Int, date: Date, intent: ScanIntent, index: Int?) -> String {
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
            ("{intent}", intent.label),
            ("{index}", index.map(String.init) ?? ""),
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
