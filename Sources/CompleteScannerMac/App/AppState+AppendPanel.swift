#if os(macOS)
import AppKit
import CompleteScannerKit
import Foundation
import UniformTypeIdentifiers

extension AppState {
    /// Picks a PDF with the open panel, starting in the save folder, and adds the queued pages to its
    /// end (`appendToPDF(at:)`).
    public func chooseAndAppendToPDF() {
        guard canAppendPages else { return }
        let panel = NSOpenPanel()
        panel.title = PDFAppender.pickerTitle
        panel.message = PDFAppender.buttonHint
        panel.prompt = "Add Pages"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        // Start where the app saves, where the PDF the pages belong to most likely is.
        let folder = URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appendToPDF(at: url)
    }

    /// `confirmAppend` on the Mac: the warnings of `question` (`PDFAppendTarget.confirmMessage`) under
    /// `PDFAppender.confirmQuestion`, with Add Pages and Cancel. Return does not add, as No is the
    /// Windows question's default.
    @MainActor
    static func confirmAppendAlert(_ question: String) -> Bool {
        var details = question
        let ending = "\n\n" + PDFAppender.confirmQuestion
        if details.hasSuffix(ending) { details.removeLast(ending.count) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = PDFAppender.confirmQuestion
        alert.informativeText = details
        let add = alert.addButton(withTitle: "Add Pages")
        alert.addButton(withTitle: "Cancel")
        add.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
