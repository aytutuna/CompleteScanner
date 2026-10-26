import CoreGraphics
import Foundation

/// Saving the collected pages as pictures, one file a page: the iPhone's "Save JPEG" (the Mac and Windows
/// save the queue as one PDF, Word document or text file; `OutputFormat.queueFormat`). Swift only, like
/// the other members the app shells use.
extension AppState {
    /// "Save JPEG", or "Save 3 JPEGs" for several pages: the button that saves the collected pages as
    /// pictures in `format` (its image format, `OutputFormat.imageFormatOrJPEG`).
    public nonisolated static func imagesSaveTitle(_ format: OutputFormat, pageCount: Int) -> String {
        let name: String = format.imageFormatOrJPEG.label
        if pageCount > 1 { return "Save \(pageCount) \(name)s" }
        return "Save \(name)"
    }

    /// "Saved 3 JPEG files: Scan 2026-10-21 4 1.jpg …", the status after `saveImages()`.
    public nonisolated static func imagesSavedMessage(_ urls: [URL], format: OutputFormat) -> String {
        let name: String = format.imageFormatOrJPEG.label
        guard let first = urls.first else { return "Saved nothing." }
        if urls.count == 1 { return "Saved \(name): \(first.lastPathComponent)" }
        return "Saved \(urls.count) \(name) files: \(first.lastPathComponent) \u{2026}"
    }

    /// Saves the pages the queue would save (`SavePlan`: pages flagged in the strip are left out, now and
    /// only now) as pictures, one file a page in reading order, in the image format chosen
    /// (`settings.format.imageFormatOrJPEG`) at each page's resolution, named by the naming template
    /// with the page's number (`{index}`, appended when the template has none). The full pixels come from
    /// each page's spool file, turned as the page is shown. All or nothing: a failure or Cancel part-way
    /// removes the files written, and the queue stays as it was. Saved, the queue is emptied, the task's
    /// steps start over and the after-save action runs, as `savePDF()` does.
    public func saveImages() {
        guard !scannedPages.isEmpty else { return }
        let s: ScanSettings = settings
        let format: OutputFormat = s.format.imageFormatOrJPEG
        runExclusive { flag in
            // Let page swaps and turns that were clicked before the save land first.
            await self.pageEditChain?.value
            let queued: [ScannedPage] = self.scannedPages
            guard !queued.isEmpty else { return }
            let plan: SavePlan = SavePlan.make(queued, options: s.document)
            guard !plan.isEmpty else {
                self.errorMessage = PageFilter.nothingToSaveMessage
                self.statusMessage = DocumentSplitter.queueSummary(queued, options: s.document) + "."
                return
            }
            var pages: [ScannedPage] = []
            for document in plan.documents {
                pages.append(contentsOf: document.pages)
            }
            let left: String = plan.leftOutNote()
            var saved: [URL] = []
            do {
                var number: Int = 1
                for page in pages {
                    if flag.isCancelled { throw ScanError.cancelled }
                    self.statusMessage = "Saving page \(number) of \(pages.count)\u{2026}"
                    let url: URL = try self.outputURL(fileExtension: format.fileExtension,
                                                      index: pages.count > 1 ? number : nil)
                    let quality: Double = s.jpegQuality
                    try await Task.detached(priority: .userInitiated) {
                        let full: CGImage = Self.fullImage(of: page)
                        try ImageExporter.write(full, to: url, format: format, dpi: page.dpi,
                                                jpegQuality: quality, colorMode: page.colorMode)
                    }.value
                    saved.append(url)
                    number += 1
                }
            } catch {
                for url in saved {
                    try? FileManager.default.removeItem(at: url)
                }
                throw error
            }
            self.lastSavedURLs = saved
            self.dropSaved(queued)
            self.resetFlow()
            self.statusMessage = Self.imagesSavedMessage(saved, format: format) + left
            self.runAfterSave(s.output.afterSave, saved: saved)
        }
    }

    /// The full pixels of `page` as it is shown: its spool file turned by the page's rotation (the file
    /// stays unturned until it is saved), or the pixels in memory, which show the rotation already.
    nonisolated static func fullImage(of page: ScannedPage) -> CGImage {
        guard let spooled = spoolImage(of: page) else { return page.image }
        let turns: Int = ((page.rotationQuarterTurns % 4) + 4) % 4
        if turns == 0 { return spooled }
        return ImagePipeline.rotate(spooled, quarterTurns: turns)
    }
}
