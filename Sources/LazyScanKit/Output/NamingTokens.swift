import Foundation

/// A part a file name can be built from, as the Insert menu offers it: its name, the token typed into
/// the template and what it becomes. Twin of C# `NamingToken`.
public struct NamingToken: Equatable, Sendable {
    public let label: String
    public let token: String
    public let help: String

    public init(label: String, token: String, help: String) {
        self.label = label
        self.token = token
        self.help = help
    }
}

/// The template typed with a token put in, and where the caret goes after it.
public struct NamingInsertion: Equatable, Sendable {
    public let text: String
    public let caret: Int

    public init(text: String, caret: Int) {
        self.text = text
        self.caret = caret
    }
}

/// What the file name field offers around `NamingTemplate`: the parts to insert, putting one in, the
/// name the next file gets, and what is wrong with a template. Twin of C# `NamingTokens`.
public enum NamingTokens {
    /// The Insert menu's parts, in order.
    public static let all: [NamingToken] = [
        NamingToken(label: "Date", token: "{date}", help: "Scan date, e.g. 2026-08-13"),
        NamingToken(label: "Time", token: "{time}", help: "Scan time, e.g. 14.05.32"),
        NamingToken(label: "Number", token: "{counter}", help: "Running number"),
        NamingToken(label: "Mode", token: "{intent}", help: "\u{201C}Document\u{201D} or \u{201C}Photos\u{201D}"),
        NamingToken(label: "Task", token: "{task}", help: "The task, e.g. \u{201C}Receipt\u{201D}"),
        NamingToken(label: "Document name", token: "{label}", help: "The document\u{2019}s name, given in the page strip"),
        NamingToken(label: "Receipt date", token: "{docdate}", help: "The date printed on a receipt"),
    ]

    /// Every token `NamingTemplate` replaces; {counter:N} is known as well.
    public static let known: [String] = ["{date}", "{time}", "{year}", "{month}", "{day}", "{counter}", "{intent}",
                                         "{index}", "{task}", "{docdate}", "{label}"]

    /// The line under a blank file name: the last name is kept.
    public static let emptyProblem = "Needs a file name"

    /// The line under a file name with a token `NamingTemplate` does not know (it stays as typed).
    public static func unknownProblem(_ token: String) -> String {
        "Unknown part \(token)"
    }

    /// `token` put into `text` at `offset` (in characters, kept within the text), with a space before it
    /// unless it follows a space or starts the text; the caret goes right after it.
    public static func insert(_ token: String, into text: String, at offset: Int) -> NamingInsertion {
        let characters: [Character] = Array(text)
        let at: Int = min(max(offset, 0), characters.count)
        var inserted: String = token
        if at > 0 && !characters[at - 1].isWhitespace {
            inserted = " " + token
        }
        let before: String = String(characters[0..<at])
        let after: String = String(characters[at...])
        return NamingInsertion(text: before + inserted + after, caret: at + inserted.count)
    }

    /// What is wrong with `template`, in a few words: nothing typed, or the first token in braces it
    /// does not know; nil when it is fine.
    public static func problem(_ template: String) -> String? {
        if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return emptyProblem }
        for token in braced(template) where !isKnown(token) {
            return unknownProblem(token)
        }
        return nil
    }

    /// Whether `token` ("{date}", "{counter:3}") is one `NamingTemplate` replaces.
    public static func isKnown(_ token: String) -> Bool {
        if known.contains(token) { return true }
        let prefix: String = "{counter:"
        guard token.hasPrefix(prefix), token.hasSuffix("}") else { return false }
        let digits: String = String(token.dropFirst(prefix.count).dropLast())
        if digits.isEmpty { return false }
        for character in digits {
            if !character.isASCII || !character.isNumber { return false }
        }
        return true
    }

    /// The parts of `template` in braces, in order: "{" up to the next "}" with no "{" between.
    public static func braced(_ template: String) -> [String] {
        let characters: [Character] = Array(template)
        var tokens: [String] = []
        var start: Int?
        var i: Int = 0
        while i < characters.count {
            let character: Character = characters[i]
            if character == "{" {
                start = i
            } else if character == "}", let open = start {
                tokens.append(String(characters[open...i]))
                start = nil
            }
            i += 1
        }
        return tokens
    }

    /// The format a save of `s` writes, for the file name's example: an image for photos, a PDF or an
    /// image for receipts, the queue's file for pages collected before saving, else the format.
    public static func savedFormat(_ s: ScanSettings) -> OutputFormat {
        if TaskCatalog.flow(of: s) == .receiptSplit { return s.format.pageFormat }
        if s.intent == .photo { return s.format.imageFormatOrJPEG }
        return s.documentMultiPage ? s.format.queueFormat : s.format
    }

    /// The name the next file gets with `template`: "Scan 2026-10-20 4.pdf", numbered `counter`, dated
    /// `date`, for the settings' task, with `format`'s extension.
    public static func example(_ template: String, settings: ScanSettings, format: OutputFormat, counter: Int,
                               date: Date) -> String {
        let context: NamingContext = NamingContext(counter: counter, date: date, intent: settings.intent,
                                                   task: TaskCatalog.infer(settings))
        let name: String = NamingTemplate(template).baseFilename(context)
        return name + "." + format.fileExtension
    }
}
