import Foundation

// The options every PDF a save writes is written with: PDF/A-2b when the archival option is on, a
// password when the password option is, asked for once per save and never stored. Twin of the
// Windows view model's `ProtectionFor`, `ForgetPdfPassword`, `PasswordNotGivenException` and
// `PdfNote` (windows/CompleteScanner.App/AppViewModel.cs).

/// A save that needed a password got none (the dialog was cancelled, or nobody could ask): handled
/// like a cancellation, with its own message (`PDFProtection.notSavedMessage`). Nothing is saved
/// without the password.
struct PDFPasswordNotGiven: LocalizedError {
    var errorDescription: String? { PDFProtection.notSavedMessage }
}

extension AppState {
    /// What a saved PDF's status says after its size when it has a password: "(412 KB, password-protected)".
    nonisolated static var protectedNote: String { "password-protected" }

    /// What is said in brackets after saved PDFs: their size and "password-protected" when they are
    /// ("412 KB, password-protected"); nil when there is neither. Twin of the Windows `PdfNote`.
    nonisolated static func pdfNote(size: String?, isProtected: Bool) -> String? {
        if let size {
            return isProtected ? "\(size), \(protectedNote)" : size
        }
        return isProtected ? protectedNote : nil
    }

    /// The password the PDFs of this save are protected with: nil when the option is off; else the
    /// one given earlier in this save, or asked for now (`askPDFPassword`). No answer throws
    /// `PDFPasswordNotGiven`: nothing is saved unprotected. Kept nowhere but here, and wiped when the
    /// save ends (`forgetPDFPassword`, run by `runExclusive`).
    func protectionFor(_ s: ScanSettings) async throws -> PDFProtection? {
        guard s.output.protect else { return nil }
        if let given = savePassword { return given }
        guard let ask = askPDFPassword else { throw PDFPasswordNotGiven() }
        guard let answer = await ask() else { throw PDFPasswordNotGiven() }
        savePassword = answer
        return answer
    }

    /// The options of a PDF this save writes to `url`: protected with the save's password when the
    /// password option is on (asked for once per save), else PDF/A-2b when the archival option is,
    /// titled with the file's name (`PDFWriteOptions.forOutput`).
    func pdfOptions(_ s: ScanSettings, for url: URL) async throws -> PDFWriteOptions {
        let protection: PDFProtection? = try await protectionFor(s)
        let title: String = url.deletingPathExtension().lastPathComponent
        return try PDFWriteOptions.forOutput(s.output, title: title, protection: protection)
    }

    /// Wipes the password of the save that just ended.
    func forgetPDFPassword() {
        savePassword?.dispose()
        savePassword = nil
    }

    /// Whether `error` is a save that got no password.
    nonisolated static func isPasswordNotGiven(_ error: Error) -> Bool {
        error is PDFPasswordNotGiven
    }
}
