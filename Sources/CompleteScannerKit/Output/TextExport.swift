import Foundation

// Twin of windows/CompleteScanner.Core/TextExport.cs: the same bytes and the same messages.

/// The text file of a save (`OutputFormat.text`, or the text beside a PDF with
/// `OutputOptions.alsoSaveText`), and what the app says about text it saved or could not read. The
/// text is `OCRText.plainText`: UTF-8 without a byte order mark, "\n" line breaks, one line of text
/// per line on the page, a blank line between paragraphs and two between pages.
public enum TextExport {
    /// The bytes of the text file for `pages`.
    public static func encode(_ pages: [OCRPage]) -> Data {
        Data(OCRText.plainText(pages).utf8)
    }

    /// Whether any page has text to save.
    public static func hasText(_ pages: [OCRPage]) -> Bool {
        !OCRText.plainText(pages).isEmpty
    }

    /// "Saved 3-page Word document: Scan 1.docx", "Saved 1-page text file: Scan 1.txt", with
    /// " — no text was found" when the pages had none (the file is saved all the same).
    public static func savedMessage(format: OutputFormat, pageCount: Int, fileName: String, hasText: Bool) -> String {
        let kind = format == .word ? "Word document" : "text file"
        return "Saved \(pageCount)-page \(kind): \(fileName)" + (hasText ? "" : " \u{2014} no text was found")
    }

    /// " and its text, Scan 1.txt": added after a PDF's name when its text was saved beside it.
    public static func sidecarSuffix(_ textFileName: String) -> String {
        " and its text, \(textFileName)"
    }

    /// What the user reads when the text could not be read: "The text could not be read: no OCR
    /// language … ." from the OCR error's message ("Scan failed: OCR failed: …").
    public static func recognitionFailed(_ ocrMessage: String) -> String {
        "The text could not be read: \(reason(ocrMessage))"
    }

    /// "The PDF was saved, but not its text file: …": the text beside a PDF could not be read or
    /// written (`message`, an OCR or file error); the PDF is kept.
    public static func sidecarFailed(_ message: String) -> String {
        "The PDF was saved, but not its text file: \(reason(message))"
    }

    /// What the user reads when a scan to be saved at once as Word or text could not be (its text
    /// could not be read, its file could not be written, or the save was cancelled) and its pages
    /// went to the queue instead: "The 3 pages are kept in the queue: press Save Word once the text
    /// can be read, or choose PDF to save them as scanned." when `textUnreadable` (OCR failed),
    /// "… press Save Word to try again, or choose PDF …" for any other failure, or
    /// "Cancelled — the page is kept in the queue.".
    public static func keptInQueue(format: OutputFormat, pageCount: Int, cancelled: Bool,
                                   textUnreadable: Bool = true) -> String {
        let pages = pageCount == 1 ? "the page is" : "the \(pageCount) pages are"
        if cancelled { return "Cancelled \u{2014} \(pages) kept in the queue." }
        let them = pageCount == 1 ? "it" : "them"
        let advice = textUnreadable ? "once the text can be read" : "to try again"
        return "\(pages.prefix(1).uppercased())\(pages.dropFirst()) kept in the queue: press \(format.saveTitle) \(advice), or choose PDF to save \(them) as scanned."
    }

    /// "Copied the text of page 2." or "No text was found on page 2." after Copy Text; `pageNumber`
    /// counts from 1.
    public static func copiedMessage(pageNumber: Int, hasText: Bool) -> String {
        hasText ? "Copied the text of page \(pageNumber)." : "No text was found on page \(pageNumber)."
    }

    /// An error's message without the "Scan failed: " and "OCR failed: " it starts with, ending in a
    /// full stop.
    private static func reason(_ message: String) -> String {
        var reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Scan failed: ", "OCR failed: "] where reason.hasPrefix(prefix) {
            reason = String(reason.dropFirst(prefix.count))
        }
        if reason.isEmpty { reason = "the text recognition did not work" }
        if !reason.hasSuffix(".") { reason += "." }
        return reason
    }
}

/// Text the user asked for could not be read or written; its message says why (a missing OCR
/// language names the setting that adds one). Not a `ScanError`: the troubleshooter does not record it.
public struct TextOutputError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
