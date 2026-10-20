import CoreGraphics
import Foundation

/// Splitting a stack into separate documents: the plan the page strip shows (`DocumentSplitter`),
/// splitting and joining by hand, naming a document, saving several files all or nothing
/// (`SavePlan`), and printing the separator sheet. Twin of the Windows `AppViewModel.Split.cs`.
extension AppState {
    /// The documents the queue is saved as, and what saving does with each page, under the current settings.
    public var queuePlan: SplitPlan { DocumentSplitter.plan(scannedPages, options: settings.document) }

    /// What saving the queue writes under the current settings.
    public var queueSavePlan: SavePlan { SavePlan.make(scannedPages, options: settings.document) }

    /// The status after a scan's pages were queued: the blank pages among them (not counting the
    /// separators), what crop and straighten did, the pages turned upright, and the separator pages
    /// found with the documents the queue now makes.
    func queueScanNote(_ added: [ScannedPage], options: DocumentOptions) -> String {
        let plan = queuePlan
        var separatorIDs = Set<UUID>()
        for (index, page) in scannedPages.enumerated() where plan.pages[index].role == .separator {
            separatorIDs.insert(page.id)
        }
        let notSeparators = added.filter { !separatorIDs.contains($0.id) }
        let separatorsAdded = added.count - notSeparators.count
        return BookPages.scanNote(added) + PageFilter.scanNote(notSeparators, options: options)
            + PageCorrections.scanNote(added) + PageTurns.scanNote(added)
            + DocumentSplitter.scanNote(plan, separatorsAdded: separatorsAdded)
    }

    /// One click on the gap before a queued page: a new document starts there, or the page joins
    /// the document before; a second click goes back to what the split setting says.
    public func toggleDocumentBreak(id: UUID) {
        guard !isBusy, let index = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let facts = scannedPages.map { PageFacts.of($0, options: settings.document) }
        guard DocumentSplitter.canToggleBreak(DocumentSplitter.plan(facts, options: settings.document), index) else { return }
        scannedPages[index] = scannedPages[index].withDocumentBreak(
            DocumentSplitter.toggledBreak(facts, index, options: settings.document))
        carryDocumentLabels(from: facts)
        let plan = queuePlan
        let documents = plan.documents.count
        let count = "\(documents) document\(documents == 1 ? "" : "s") to save."
        let page = plan.pages[index]
        if page.startsDocument, let number = page.document, number > 1 {
            statusMessage = "Document \(number) starts at page \(index + 1). \(count)"
        } else {
            statusMessage = "Page \(index + 1) joins the document before it. \(count)"
        }
    }

    /// After a page's inclusion or document break changed (`before`: the facts until then), or the
    /// settings (`beforeOptions`: the document settings until then; nil: unchanged): a document
    /// whose first saved page changed keeps its name, moved to its new first page
    /// (`DocumentSplitter.carriedLabels`).
    func carryDocumentLabels(from before: [PageFacts], options beforeOptions: DocumentOptions? = nil) {
        let after = scannedPages.map { PageFacts.of($0, options: settings.document) }
        let labels = DocumentSplitter.carriedLabels(before, beforeOptions: beforeOptions ?? settings.document,
                                                    after, options: settings.document)
        for index in scannedPages.indices where scannedPages[index].documentLabel != labels[index] {
            scannedPages[index] = scannedPages[index].withDocumentLabel(labels[index])
        }
    }

    /// After the document settings changed (Skip blank pages, what counts as blank, the split; by
    /// hand, a task or a preset; `settings`' didSet): a named document whose first saved page they
    /// now leave out, or that a page before it now joins, keeps its name, as after a click on Keep
    /// or Skip.
    func carryDocumentLabels(settingsBefore: DocumentOptions) {
        guard !scannedPages.isEmpty else { return }
        carryDocumentLabels(from: scannedPages.map { PageFacts.of($0, options: settingsBefore) }, options: settingsBefore)
    }

    /// The name of the document the queued page is in (empty when it has none, or the page is left out).
    public func documentLabel(of id: UUID) -> String {
        guard let index = scannedPages.firstIndex(where: { $0.id == id }) else { return "" }
        let plan = queuePlan
        guard let number = plan.pages[index].document else { return "" }
        return plan.documents[number - 1].label ?? ""
    }

    /// Names the document the queued page is in ({label} in the file name): the name is kept on the
    /// document's first page, and any other name among its pages is dropped. An empty name removes it.
    public func setDocumentLabel(id: UUID, label: String?) {
        guard !isBusy, let index = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let plan = queuePlan
        guard let number = plan.pages[index].document else { return }
        let document = plan.documents[number - 1]
        let cleaned = DocumentSplitter.cleaned(label)
        for (k, pageIndex) in document.pages.enumerated() {
            let wanted: String? = k == 0 ? cleaned : nil
            if scannedPages[pageIndex].documentLabel != wanted {
                scannedPages[pageIndex] = scannedPages[pageIndex].withDocumentLabel(wanted)
            }
        }
        if let cleaned {
            statusMessage = "Document \(number) is named \u{201C}\(cleaned)\u{201D}: {label} in the file name."
        } else {
            statusMessage = "Document \(number) has no name."
        }
    }

    /// Where the queue is split into documents: a split setting from the inspector.
    public func setSplitMode(_ mode: SplitMode) {
        guard settings.document.splitMode != mode else { return }
        settings.document.splitMode = mode
        if !scannedPages.isEmpty {
            statusMessage = DocumentSplitter.queueSummary(scannedPages, options: settings.document) + "."
        }
    }

    /// The sheets per document for `.sheetCount` (1 to 999).
    public func setSplitSheetCount(_ count: Int) {
        let clamped = DocumentSplitter.clampSheetCount(count)
        guard settings.document.splitSheetCount != clamped else { return }
        settings.document.splitSheetCount = clamped
        if !scannedPages.isEmpty {
            statusMessage = DocumentSplitter.queueSummary(scannedPages, options: settings.document) + "."
        }
    }

    /// Saves the documents of a split queue, a file each (with its text beside it when asked for),
    /// all or nothing: a failure or Cancel part-way removes every file written, and the queue stays
    /// as it was so it can be saved again.
    func saveDocuments(_ plan: SavePlan, settings s: ScanSettings, queued: [ScannedPage], flag: CancelFlag) async throws {
        let format = s.format.queueFormat
        let files = WrittenFiles()
        var saved: [URL] = []
        var textFiles: [String] = []
        var noText: [String] = []
        var textProblem: String?
        // All or nothing (`SavePlan.writeAllOrNothing`, written out here so the work stays on the main actor).
        do {
            for document in plan.documents {
                if flag.isCancelled { throw ScanError.cancelled }
                self.statusMessage = "Saving document \(document.number) of \(plan.documents.count)\u{2026}"
                let pages = document.pages
                let url = try self.outputURL(fileExtension: format.fileExtension, index: plan.fileIndex(document),
                                             label: document.label)
                if format.isTextFormat {
                    let pageImages: PDFSizePreset? = s.output.wordPageImages ? s.output.pdfSize : nil
                    let hasText = try await Task.detached(priority: .userInitiated) {
                        try Self.writeTextDocument(pages: pages, format: format, to: url,
                                                   pageImages: pageImages,
                                                   shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                            Task { @MainActor in self?.statusMessage = msg }
                        }
                    }.value
                    files.add(url)
                    saved.append(url)
                    if !hasText { noText.append(url.lastPathComponent) }
                    continue
                }
                let text = s.output.alsoSaveText ? PDFTextCollector() : nil
                let textResult = try await Task.detached(priority: .userInitiated) { () throws -> (url: URL?, problem: String?)? in
                    try Self.writePDFAtomically(pages: pages, pdfSize: s.output.pdfSize, to: url,
                                                textLayer: Self.textLayer(searchable: s.pdfSearchable, collecting: text,
                                                                          pages: pages),
                                                shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                        Task { @MainActor in self?.statusMessage = msg }
                    }
                    return text.map { Self.writeTextBeside(pdf: url, text: $0) }
                }.value
                files.add(url)
                saved.append(url)
                if let textURL = textResult?.url {
                    files.add(textURL)
                    textFiles.append(textURL.lastPathComponent)
                }
                if let problem = textResult?.problem { textProblem = textProblem ?? problem }
            }
        } catch {
            files.rollBack()
            switch error {
            case ScanError.cancelled, is CancellationError:
                throw ScanError.cancelled
            default:
                throw NotSavedError(SavePlan.notSavedMessage(SavePlan.failureReason(error)))
            }
        }
        lastSavedURLs = saved
        // The last PDF's size, as after any save (the Windows inspector shows the same).
        if format == .pdf, let last = saved.last { notePDFSize(of: last) }
        deleteSpoolFiles(of: queued)
        scannedPages = []
        resetFlow()
        if let textProblem { errorMessage = TextExport.sidecarFailed(textProblem) }
        let size: String? = format == .pdf ? Self.totalSizeText(of: saved) : nil
        statusMessage = plan.savedMessage(format, fileNames: saved.map(\.lastPathComponent), size: size,
                                          textFileNames: textFiles, noTextFound: noText)
        runAfterSave(s.output.afterSave, saved: saved)
    }

    /// "1.2 MB": the size of the files together, as the Finder shows it; nil when one cannot be read.
    nonisolated static func totalSizeText(of urls: [URL]) -> String? {
        var total: Int64 = 0
        for url in urls {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                return nil
            }
            total += size.int64Value
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Saves the separator sheet (Patch T) as a PDF in the scans folder, on the paper usual where the
    /// user lives (Letter or A4), to print at actual size on any printer, here or elsewhere: the
    /// saved bar opens it. Works with no printer installed.
    public func saveSeparatorSheet() {
        runExclusive { flag in
            self.statusMessage = "Saving the separator sheet\u{2026}"
            let sheetPaper = SeparatorSheet.paper(regionCode: Self.regionCode)
            let inches = PaperSizes.inches(sheetPaper) ?? CGSize(width: 8.5, height: 11)
            let folder = try self.destinationDirectory()
            let url = NamingTemplate.uniqueURL(in: folder,
                                               base: SeparatorSheet.fileBaseName(sheetPaper), fileExtension: "pdf")
            let dpi = SeparatorSheet.dpi
            let document: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
                let sheet = PatchCodeDetector.renderSheet(SeparatorSheet.code, widthInches: Double(inches.width),
                                                          heightInches: Double(inches.height), dpi: dpi).toRgba()
                guard let image = sheet.makeCGImage() else { return nil }
                let paper = PrinterPaper.make(paper: inches, printable: nil)
                let placement = PrintLayout.place(pixelWidth: sheet.width, pixelHeight: sheet.height, dpi: dpi,
                                                  on: paper, mode: .actualSize, align: .paperOrigin)
                return PrintDocument.makePDF(pages: [PrintPage(image: image, dpi: dpi, placement: placement)],
                                             paper: inches)
            }.value
            guard let document else { throw NotSavedError("The separator sheet could not be drawn.") }
            if flag.isCancelled { throw ScanError.cancelled }
            do {
                try document.write(to: url, options: .withoutOverwriting)
            } catch {
                throw NotSavedError("The separator sheet could not be saved: \(error.localizedDescription)")
            }
            self.lastSavedURLs = [url]
            self.notePDFSize(of: url)
            self.statusMessage = SeparatorSheet.savedMessage(url.lastPathComponent)
        }
    }

    /// Prints the separator sheet (Patch T) at real size on the printer chosen for copies, on the
    /// paper it has (whatever paper size the scan asks for): the sheet goes in front of each
    /// document after the first.
    public func printSeparatorSheet() {
        let s = settings
        runExclusive { flag in
            guard let setup = self.setupForPrinting(s, requestedPaper: nil) else { throw PrintError.noPrinter }
            let paper = setup.paper
            let dpi = SeparatorSheet.dpi
            let document: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
                let sheet = PatchCodeDetector.renderSheet(SeparatorSheet.code, widthInches: Double(paper.paper.width),
                                                          heightInches: Double(paper.paper.height), dpi: dpi).toRgba()
                guard let image = sheet.makeCGImage() else { return nil }
                let placement = PrintLayout.place(pixelWidth: sheet.width, pixelHeight: sheet.height, dpi: dpi,
                                                  on: paper, mode: .actualSize, align: .paperOrigin)
                return PrintDocument.makePDF(pages: [PrintPage(image: image, dpi: dpi, placement: placement)],
                                             paper: paper.paper)
            }.value
            guard let document else { throw PrintError.failed("The separator sheet could not be drawn.") }
            if flag.isCancelled { throw ScanError.cancelled }
            self.statusMessage = "Printing the separator sheet on \(setup.printerName)\u{2026}"
            let job = PrintJob(printerName: setup.printerName, jobName: "Separator sheet (Patch T)", paper: paper, copies: 1)
            guard try self.printService.print(document, job: job) else {
                self.statusMessage = "Printing cancelled."
                return
            }
            self.statusMessage = "Sent the separator sheet to \(setup.printerName). Put one in front of each document after the first; print more copies as you need them."
        }
    }
}
