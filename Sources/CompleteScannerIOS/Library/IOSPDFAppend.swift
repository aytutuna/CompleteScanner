#if os(iOS)
import CompleteScannerKit
import Foundation
import UIKit

/// Adding the queued pages to a PDF on the iPhone and iPad (`AppState.appendToPDF(at:)`): the file comes
/// from Files (the scan screen's picker) or the save folder (the Saved files list). Its reading and its
/// update run inside its security scope and a coordinated access (`AppState.accessPDFForAppend`), the update
/// as a replacement, so iCloud Drive and other providers take the new file as a new version of theirs. The
/// question before adding pages to a signed or PDF/A file is an alert over whatever is shown
/// (`AppState.confirmAppend`). Both are set by `AppState.makeForIOS`.
public enum IOSPDFAppend {
    /// Runs `body` on the file at `url`: read (`writing` false) or replaced (`writing` true).
    public static func access(_ url: URL, writing: Bool, _ body: (URL) throws -> Void) throws {
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let coordinator: NSFileCoordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var failure: (any Error)?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { (file: URL) -> Void in
                do {
                    try body(file)
                } catch {
                    failure = error
                }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { (file: URL) -> Void in
                do {
                    try body(file)
                } catch {
                    failure = error
                }
            }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
    }

    /// Asks `question` (`PDFAppendTarget.confirmMessage`): its warnings under `PDFAppender.confirmQuestion`,
    /// with Add Pages and Cancel. Nothing shown to ask over answers no.
    @MainActor
    public static func confirm(_ question: String) async -> Bool {
        guard let top: UIViewController = IOSPasswordPrompt.topViewController() else { return false }
        var details: String = question
        let ending: String = "\n\n" + PDFAppender.confirmQuestion
        if details.hasSuffix(ending) { details.removeLast(ending.count) }
        let message: String = details
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer: IOSPasswordAnswer = IOSPasswordAnswer(continuation)
            let alert: UIAlertController = UIAlertController(title: PDFAppender.confirmQuestion, message: message,
                                                             preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { (_: UIAlertAction) -> Void in
                answer.give(false)
            })
            alert.addAction(UIAlertAction(title: "Add Pages", style: .default) { (_: UIAlertAction) -> Void in
                answer.give(true)
            })
            top.present(alert, animated: true, completion: nil)
        }
    }
}
#endif
