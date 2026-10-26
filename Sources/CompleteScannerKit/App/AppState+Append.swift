import Foundation

// Twin of windows/CompleteScanner.App/AppViewModel.Append.cs: the queued pages added to the end of a
// PDF the user picks, as an incremental update (`PDFAppender`). The window asks the question
// (`confirmAppend`); the iPhone also wraps the file's reading and its update in the picked file's
// security scope and a coordinated access (`accessPDFForAppend`), which Windows has no need of. A PDF
// picked before scanning (`appendTarget`) takes the queue when it is saved (`savePDF()`).

extension AppState {
    /// There are pages to add (some are not left out) and nothing else is running.
    public var canAppendPages: Bool {
        !isBusy && SavePlan.make(scannedPages, options: settings.document).pageCount > 0
    }

    /// Makes Save add the queue to the PDF at `url` (read when the pages are added, not now) until the
    /// pages are in or `clearAppendTarget()` is called.
    public func setAppendTarget(_ url: URL) {
        appendTarget = url
    }

    /// Save writes a new file again.
    public func clearAppendTarget() {
        appendTarget = nil
    }

    /// Adds the pages the queue would save (all its documents, in order; pages left out stay out) to
    /// the end of the PDF at `url`, stored as the PDF size and the text layer settings say. The file
    /// is read first: a password-protected, damaged or unreadable file, or one that is read-only or
    /// open in another app, is refused with what to do, and the pages stay in the queue. The file
    /// decides the rest: no password is added (the password switch is for new files) and a PDF/A file
    /// stays one where it can (`PDFAppender.keepsPdfA`), with a question first where it may not, or
    /// where it is signed. Once the pages are in, the queue is cleared and the file is offered like a
    /// saved one, with the after-save action, and the `appendTarget` is cleared.
    public func appendToPDF(at url: URL) {
        guard !scannedPages.isEmpty else { return }
        let s: ScanSettings = settings
        let access = accessPDFForAppend
        runExclusive { flag in
            // Let page swaps and turns that were clicked before land first.
            await self.pageEditChain?.value
            let queued: [ScannedPage] = self.scannedPages
            guard !queued.isEmpty else { return }
            let plan: SavePlan = SavePlan.make(queued, options: s.document)
            guard !plan.isEmpty else {
                self.errorMessage = PageFilter.nothingToSaveMessage
                self.statusMessage = DocumentSplitter.queueSummary(queued, options: s.document) + "."
                return
            }
            let name: String = url.lastPathComponent
            self.statusMessage = "Reading \(name)…"
            let target: PDFAppendTarget = try await Task.detached(priority: .userInitiated) { () throws -> PDFAppendTarget in
                try Self.accessing(url, writing: false, through: access) { (file: URL) throws -> PDFAppendTarget in
                    try PDFAppender.inspect(path: file.path)
                }
            }.value
            if let question = target.confirmMessage {
                var yes = false
                if let ask = self.confirmAppend { yes = await ask(question) }
                if !yes {
                    self.statusMessage = "Nothing was added to \(name)."
                    return
                }
            }
            var collected: [ScannedPage] = []
            for document in plan.documents {
                collected.append(contentsOf: document.pages)
            }
            let pages: [ScannedPage] = collected
            let count: Int = pages.count
            self.statusMessage = s.pdfSearchable ? "Running OCR and adding pages…" : "Adding pages…"
            let result: PDFAppendResult = try await Task.detached(priority: .userInitiated) { () throws -> PDFAppendResult in
                let report: (String) -> Void = { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
                let inputs: [PDFPageInput] = try PDFBuilder.pageInputs(
                    pages, pdfSize: s.output.pdfSize, progress: report, shouldContinue: { !flag.isCancelled },
                    textLayer: Self.textLayer(searchable: s.pdfSearchable, collecting: nil, pages: pages))
                report("Adding \(count) \(count == 1 ? "page" : "pages") to \(name)…")
                return try Self.accessing(url, writing: true, through: access) { (file: URL) throws -> PDFAppendResult in
                    try PDFAppender.appendToFile(path: file.path, pages: inputs,
                                                 shouldContinue: { !flag.isCancelled })
                }
            }.value
            self.lastPDFByteCount = Int64(result.bytes)
            self.lastPDFProtected = false
            // The URL picked, not the result's path: on the iPhone it carries the file's security scope,
            // kept open for the file actions after the save (`scopedSavedURL`).
            self.lastSavedURLs = [url]
            if self.scopedSavedURL == nil, url.startAccessingSecurityScopedResource() {
                self.scopedSavedURL = url
            }
            self.appendTarget = nil
            self.deleteSpoolFiles(of: queued)
            self.scannedPages = []
            self.resetFlow()
            let size: String = ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
            var message: String = PDFAppender.addedMessage(count, fileName: name, pageCount: result.pageCount, size: size)
            message += plan.leftOutNote()
            if s.output.protect { message += ". " + PDFAppender.noPasswordNote }
            self.statusMessage = message
            self.runAfterSave(s.output.afterSave, saved: [url])
        }
    }

    /// `body` run on the file at `url` through `access` (the iPhone's `accessPDFForAppend`), or on
    /// `url` itself when there is none.
    nonisolated static func accessing<T>(_ url: URL, writing: Bool,
                                         through access: (@Sendable (URL, Bool, (URL) throws -> Void) throws -> Void)?,
                                         _ body: (URL) throws -> T) throws -> T {
        guard let access else { return try body(url) }
        var result: T?
        try access(url, writing) { (file: URL) throws -> Void in
            result = try body(file)
        }
        guard let result else {
            throw PDFAppendError(.missing, PDFAppender.message(.missing, url.lastPathComponent))
        }
        return result
    }
}
