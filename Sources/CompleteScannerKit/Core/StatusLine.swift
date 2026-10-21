import Foundation

// The status line's short text. Both apps show at most six words of their status sentence, facts
// only, and keep the whole sentence as the line's accessibility label. Twin of
// windows/CompleteScanner.Core/StatusLine.cs (same rules, same tests).

/// The status line's visible text: at most `maxWords` words, facts only. The full sentence stays the
/// status line's accessibility label, so VoiceOver reads all of it. Twin of C# `StatusLine`.
public enum StatusLine {
    public static let maxWords = 6

    /// Words as the text spec counts them: whitespace-separated tokens with a letter or digit.
    public static func words(_ text: String) -> Int {
        let tokens: [Substring] = text.split(whereSeparator: { (c: Character) -> Bool in c.isWhitespace })
        return tokens.filter { (token: Substring) -> Bool in isWord(token) }.count
    }

    /// `message`'s short form. `deviceName`: the connected scanner, for "Ready — Demo Scanner" after a
    /// task is picked. A setting changed for the scanner, or a two-sided scan that came back
    /// one-sided, keeps a short warning on the line ("Ready — Demo · feeder used", "3 pages added · one
    /// side only"); when the line can't hold both, the warnings win.
    public static func short(_ message: String, deviceName: String? = nil) -> String {
        let text: String = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        let found: (shorts: [String], notesAt: Int) = findWarnings(text)
        var head: String = ""
        if found.notesAt > 0 {
            let before: String = (text as NSString).substring(to: found.notesAt)
            head = headOf(before.trimmingCharacters(in: .whitespacesAndNewlines), deviceName: deviceName)
        }
        return compose(head, found.shorts)
    }

    /// `head` with the short warnings found in `message`, the same way `short` adds them: "Saved · 600
    /// dpi used", or the warnings alone when the line can't hold both; just `head` when there are none.
    public static func withWarnings(_ head: String, message: String) -> String {
        compose(head, warnings(message))
    }

    /// The short warnings in `message`, in the order they come: a setting changed for the scanner
    /// ("600 dpi used"), a two-sided scan that came back one-sided ("One side only").
    public static func warnings(_ message: String) -> [String] {
        findWarnings(message.trimmingCharacters(in: .whitespacesAndNewlines)).shorts
    }

    /// What the status line shows while the app is idle: nothing while a review shows its own title
    /// (`reviewShown`), "Saved" with any warning while the saved files' actions show (`savedShown`, for
    /// a message about a save), else `short`.
    public static func shown(_ message: String, deviceName: String?, reviewShown: Bool, savedShown: Bool) -> String {
        if reviewShown { return "" }
        let start: String = String(message.drop(while: { (c: Character) -> Bool in c.isWhitespace }))
        if savedShown && start.hasPrefix("Saved") { return withWarnings("Saved", message: message) }
        return short(message, deviceName: deviceName)
    }

    // MARK: - Private

    /// A two-sided scan came back with one side of each sheet.
    private static let oneSidedMark = "the scanner did not scan both sides"
    private static let oneSidedShort = "One side only"

    /// A token with a letter or a digit.
    private static func isWord(_ token: Substring) -> Bool {
        token.contains { (c: Character) -> Bool in c.isLetter || c.isNumber }
    }

    /// The sentences `SettingsAdapter` adds when a setting had to change for the scanner, each with its
    /// short form (a template: "$1 dpi used"): a warning stays visible, not only in the label.
    private static func settingsNotes() -> [(NSRegularExpression, String)] {
        let papers: [String] = PaperSize.allCases.map { (size: PaperSize) -> String in
            NSRegularExpression.escapedPattern(for: size.label)
        }
        let paperPattern: String = "(?:" + papers.joined(separator: "|")
            + ") paper does not fit this scanner's (?:feeder|glass), so the paper size is Automatic\\."
        let patterns: [(String, String)] = [
            ("This scanner has no flatbed, so the document feeder is used\\.", "Feeder used"),
            ("This scanner has no document feeder, so the flatbed is used\\.", "Flatbed used"),
            ("This scanner's feeder scans one side at a time, so you'll turn the stack over by hand\\.", "Two-sided by hand"),
            (paperPattern, "Paper size Automatic"),
            ("This scanner does not offer \\d+ dpi, so (\\d+) dpi is used\\.", "$1 dpi used"),
        ]
        var notes: [(NSRegularExpression, String)] = []
        for (pattern, shortForm) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                notes.append((regex, shortForm))
            }
        }
        return notes
    }

    /// The warnings in `text`, and where the first settings note starts (UTF-16 offset; the text's
    /// length when none does).
    private static func findWarnings(_ text: String) -> (shorts: [String], notesAt: Int) {
        // The notes are appended after the message: the message is what comes before the first one.
        let ns: NSString = text as NSString
        let whole: NSRange = NSRange(location: 0, length: ns.length)
        var found: [(at: Int, order: Int, short: String)] = []
        var notesAt: Int = ns.length
        for (regex, shortForm) in settingsNotes() {
            for match in regex.matches(in: text, options: [], range: whole) {
                let short: String = regex.replacementString(for: match, in: text, offset: 0, template: shortForm)
                found.append((at: match.range.location, order: found.count, short: short))
                notesAt = min(notesAt, match.range.location)
            }
        }
        let oneSided: NSRange = ns.range(of: oneSidedMark)
        if oneSided.location != NSNotFound {
            found.append((at: oneSided.location, order: found.count, short: oneSidedShort))
        }
        let sorted = found.sorted { (a: (at: Int, order: Int, short: String), b: (at: Int, order: Int, short: String)) -> Bool in
            a.at != b.at ? a.at < b.at : a.order < b.order
        }
        let shorts: [String] = sorted.map { (item: (at: Int, order: Int, short: String)) -> String in item.short }
        return (shorts: shorts, notesAt: notesAt)
    }

    /// The head, then the warnings while they fit; when the line can't hold both, the warnings win.
    private static func compose(_ head: String, _ shorts: [String]) -> String {
        guard let firstShort = shorts.first else { return head }
        if !head.isEmpty {
            let lowered: [String] = shorts.map { (s: String) -> String in lowerFirst(s) }
            let all: String = ([head] + lowered).joined(separator: " \u{00B7} ")
            if words(all) <= maxWords { return all }
        }
        // Not room for the message too: the warnings alone, as many as fit, then how many more.
        var shown: String = firstShort
        var i: Int = 1
        while i < shorts.count {
            let next: String = shown + " \u{00B7} " + lowerFirst(shorts[i])
            // While more would follow, keep a word free for "+N".
            let room: Int = maxWords - (i < shorts.count - 1 ? 1 : 0)
            if words(next) > room { break }
            shown = next
            i += 1
        }
        return i < shorts.count ? "\(shown) +\(shorts.count - i)" : shown
    }

    /// "Feeder used" after a message reads "… · feeder used"; "300 dpi used" stays as it is.
    private static func lowerFirst(_ text: String) -> String {
        guard let first: Character = text.first, first.isUppercase else { return text }
        return String(first).lowercased() + String(text.dropFirst())
    }

    /// The groups of `pattern`'s first match in `text` (group 0 is the whole match; a group that took
    /// no part is ""); nil when it does not match.
    private static func groups(_ pattern: String, in text: String,
                               options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns: NSString = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var result: [String] = []
        for index in 0..<match.numberOfRanges {
            let range: NSRange = match.range(at: index)
            result.append(range.location == NSNotFound ? "" : ns.substring(with: range))
        }
        return result
    }

    /// The short form of the message itself (without the notes after it).
    private static func headOf(_ text: String, deviceName: String?) -> String {
        if text.isEmpty { return "" }
        if text.hasPrefix("Ready for \u{201C}") {
            if let name = deviceName, !name.isEmpty { return "Ready \u{2014} \(name)" }
            return "Ready"
        }
        if let added = groups("^Added (\\d+) (?:page|pages)\\b", in: text) {
            let count: Int = Int(added[1]) ?? 0
            var head: String
            if count == 1, let queue = groups("\u{2014} (\\d+) in queue", in: text) {
                head = "Page \(queue[1]) added"
            } else {
                head = "\(count) \(count == 1 ? "page" : "pages") added"
            }
            if let blank = groups("(\\d+) looks? blank", in: text) {
                head = append(head, "\(blank[1]) blank")
            }
            if let spreads = groups("(\\d+) (spreads?) split into pages", in: text) {
                head = append(head, "\(spreads[1]) \(spreads[2]) split")
            }
            return head
        }
        let savedPattern: String = "^(?:Cancelled \u{2014} )?Saved (\\d+) (photos?|receipts?|documents?|files?|PDFs?|copies)\\b"
        if let saved = groups(savedPattern, in: text, options: [.caseInsensitive]) {
            return "Saved \(saved[1]) \(saved[2])"
        }
        if text.hasPrefix("Saved ") { return "Saved" }
        if let found = groups("^Found (\\d+) (photos?|receipts?)\\b", in: text) {
            return "Found \(found[1]) \(found[2])"
        }
        if text.hasPrefix("Page queue cleared") { return "Queue cleared" }
        if let reading = groups("^Reading the text of page (\\d+)( of \\d+)?\u{2026}", in: text) {
            return "Reading page \(reading[1])\(reading[2])\u{2026}"
        }
        if let adding = groups("^Adding (\\d+) (pages?) to .+\u{2026}$", in: text) {
            return "Adding \(adding[1]) \(adding[2])\u{2026}"
        }
        if text.hasPrefix("Sent ") { return "Sent to the printer" }

        // Anything else: its first sentence, then what comes before a dash or a colon, then its whole facts.
        let first: String = firstSentence(text)
        if words(first) <= maxWords { return first }
        for mark in [" \u{2014} ", ": ", ", "] {
            if let range = first.range(of: mark), range.lowerBound > first.startIndex {
                let before: String = String(first[first.startIndex..<range.lowerBound])
                if words(before) <= maxWords { return before }
            }
        }
        // Facts joined by " · " ("9 pages · 3 documents · 2 separator pages skipped"): the whole facts that fit.
        let facts: [String] = first.components(separatedBy: " \u{00B7} ")
        if facts.count > 1, words(facts[0]) <= maxWords {
            var shown: String = facts[0]
            for fact in facts.dropFirst() {
                let next: String = shown + " \u{00B7} " + fact
                if words(next) > maxWords { break }
                shown = next
            }
            return shown
        }
        let tokens: [Substring] = first.split(separator: " ", omittingEmptySubsequences: true)
        var kept: [String] = []
        var count: Int = 0
        for token in tokens {
            if isWord(token) {
                count += 1
                if count > maxWords { break }
            }
            kept.append(String(token))
        }
        var joined: String = kept.joined(separator: " ")
        let trailing: Set<Character> = [",", ":", ";", ".", " "]
        while let last: Character = joined.last, trailing.contains(last) {
            joined.removeLast()
        }
        return joined + "\u{2026}"
    }

    /// "6 pages added · 1 blank", while the words stay within the limit.
    private static func append(_ head: String, _ part: String) -> String {
        let joined: String = head + " \u{00B7} " + part
        return words(joined) <= maxWords ? joined : head
    }

    /// The first sentence without its full stop ("…" is kept: it says work is under way).
    private static func firstSentence(_ text: String) -> String {
        let chars: [Character] = Array(text)
        let enders: Set<Character> = [".", "!", "?"]
        var i: Int = 0
        while i + 2 < chars.count {
            let next: Character = chars[i + 2]
            if enders.contains(chars[i]) && chars[i + 1] == " " && (next.isUppercase || next.isNumber) {
                return String(chars[0..<i])
            }
            i += 1
        }
        if text.hasSuffix(".") && !text.hasSuffix("\u{2026}") { return String(text.dropLast()) }
        return text
    }
}
