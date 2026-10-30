import CoreGraphics
import Foundation

/// Printing: the Copy task (scan, then print at real size, like a photocopier), printing the ID
/// card's page, and the ruler test page. Pages are placed with `PrintLayout` on a PDF the size of the
/// paper (`PrintDocument`) and printed through `PrintService`, which shows the standard print panel
/// set to 100 %. The printer and the number of copies are chosen in the inspector (`TaskOptions`);
/// on the iPhone and iPad a copy's pages are held on its screen and printed from there (`copyPages`).
/// The stored state is in AppState.swift (`printerNames`, `defaultPrinterPaper`, `copySetup`, `copyPages`).
/// Twin of the Windows `AppViewModel.Copy.cs`.
extension AppState {
    /// Whether a printer is installed.
    public var hasPrinter: Bool { !printerNames.isEmpty }

    /// The scans of the settings go straight to the printer (the Copy task).
    public var isCopyFlow: Bool { TaskCatalog.flow(of: settings) == .copy }

    /// The printer copies are printed on: the one chosen, while it is installed, else the default
    /// printer; nil when there is none.
    public var copyPrinterName: String? {
        if let chosen = settings.taskOptions.copyPrinterName,
           printerNames.contains(where: { $0.caseInsensitiveCompare(chosen) == .orderedSame }) {
            return chosen
        }
        return printService.defaultPrinterName ?? printerNames.first
    }

    /// The paper the chosen printer prints copies on, e.g. "Letter (8.5 × 11 in)"; empty while unknown.
    public var copyPaperText: String { copySetup?.paper.description ?? "" }

    /// "Edges may be cut by up to 5 mm (printer margins)." when copies at real size from the corner
    /// of the paper lose an edge to the chosen printer's margins; nil otherwise.
    public var copyMarginWarning: String? {
        guard let setup = copySetup, !settings.taskOptions.copyFitToPage,
              setup.paper.largestMargin > PrintLayout.clipWarningInches else { return nil }
        return "Edges may be cut by up to \(PrintLayout.millimetres(setup.paper.largestMargin)) mm (printer margins)."
    }

    /// Reads the installed printers, the default printer's paper (for Automatic paper of the ID card)
    /// and what the printer chosen for copies offers. Only reads: nothing is changed on any printer.
    public func refreshPrinters() {
        let paperBefore = idCardPaperSize
        printerNames = printService.printerNames
        defaultPrinterPaper = printerNames.isEmpty ? nil : printService.setup(printerName: nil, requestedPaper: nil)?.paper.size
        refreshCopySetup()
        // Automatic paper of the ID card follows the default printer's paper.
        if paperBefore != idCardPaperSize && showIdCardReview { refreshIdCardPreview() }
    }

    /// Reads what the printer chosen for copies offers, for the inspector.
    func refreshCopySetup() {
        copySetup = hasPrinter ? setupForPrinting(settings, requestedPaper: Self.requestedPaper(settings)) : nil
    }

    /// What printing with these settings would use: the printer chosen for copies, else (and when it
    /// is no longer installed) the default printer.
    func setupForPrinting(_ s: ScanSettings, requestedPaper: PaperSize?) -> PrinterSetup? {
        if let name = s.taskOptions.copyPrinterName,
           let setup = printService.setup(printerName: name, requestedPaper: requestedPaper) {
            return setup
        }
        return printService.setup(printerName: nil, requestedPaper: requestedPaper)
    }

    /// The printer a job went to: read again once it printed, since iOS picks it in its picker meanwhile.
    func printedOn(_ setup: PrinterSetup, _ s: ScanSettings) -> String {
        setupForPrinting(s, requestedPaper: nil)?.printerName ?? setup.printerName
    }

    /// The paper asked of the printer for copies: the paper size chosen in the inspector; nil (the
    /// printer's own) for Automatic.
    static func requestedPaper(_ s: ScanSettings) -> PaperSize? {
        s.paperSize == .auto || s.paperSize == .idCard ? nil : s.paperSize
    }

    /// The printer for copies (and for the ID card): nil for the default printer. Saved with the settings.
    public func setCopyPrinter(_ name: String?) {
        guard !isBusy else { return }
        // Choosing the default printer follows the default, should it change.
        var stored = name
        if let chosen = name, let defaultName = printService.defaultPrinterName,
           chosen.caseInsensitiveCompare(defaultName) == .orderedSame {
            stored = nil
        }
        guard settings.taskOptions.copyPrinterName != stored else { return }
        settings.taskOptions.copyPrinterName = stored
        refreshCopySetup()
    }

    /// How many copies to print (1 to 99).
    public func setCopyCount(_ count: Int) {
        let clamped = PrintCopies.clamp(count)
        guard !isBusy, settings.taskOptions.copyCount != clamped else { return }
        settings.taskOptions.copyCount = clamped
    }

    /// Copies are made smaller to fit the printable area (true), or printed at real size (false).
    public func setCopyFitToPage(_ fit: Bool) {
        guard !isBusy, settings.taskOptions.copyFitToPage != fit else { return }
        settings.taskOptions.copyFitToPage = fit
    }

    /// Each copy is also saved as a PDF.
    public func setCopyAlsoSavePdf(_ save: Bool) {
        guard !isBusy, settings.taskOptions.copyAlsoSavePdf != save else { return }
        settings.taskOptions.copyAlsoSavePdf = save
    }

    /// On the glass with nothing selected and Automatic paper, the part of the glass the printer's
    /// paper covers from the corner (a copier copies the sheet it prints on); nil otherwise.
    func copyScanArea(_ s: ScanSettings, setup: PrinterSetup) -> CGRect? {
        guard s.source == .flatbed, selectionRect == nil, s.paperSize == .auto,
              let bed = capabilities?.flatbedSizeInches, bed.width > 0, bed.height > 0 else { return nil }
        let paper = setup.paper.paper
        return CGRect(x: 0, y: 0, width: min(1, Double(paper.width) / Double(bed.width)),
                      height: min(1, Double(paper.height) / Double(bed.height)))
    }

    /// Prints the pages of a copy: each at real size (or fitted, when chosen) on the printer's paper,
    /// against the corner as it lay on the glass or centred when an area was selected, as many copies
    /// as asked; then saves them as a PDF too when asked, also when printing failed (the pages are kept
    /// nowhere else; the print error is reported after), not when the print panel was cancelled, and never
    /// for the queue's pages printed from Save's menu (`copyIsOfQueue`): the queue's own Save writes them. The
    /// status says where they went and what the printer's margins cut off. `reusePrinter` prints on the
    /// printer picked last without asking (`PrintService.printAgain`). False when the print panel was
    /// cancelled.
    @discardableResult
    func printCopyPages(_ pages: [ScannedPage], settings s: ScanSettings, setup: PrinterSetup, areaSelected: Bool,
                        reusePrinter: Bool = false, flag: CancelFlag) async throws -> Bool {
        let options = s.taskOptions
        let alsoPDF = options.copyAlsoSavePdf && !copyIsOfQueue
        let allRealSize = pages.allSatisfy { $0.printsAtRealSize }
        let fit = PrintLayout.copyFitsToPage(chosenFit: options.copyFitToPage, allPagesRealSize: allRealSize)
        let mode: PrintMode = fit ? .fitToPrintable : .actualSize
        let align = PrintLayout.align(hasSelection: areaSelected)
        let printPages = pages.map { page in
            PrintPage(image: page.image, dpi: page.dpi,
                      placement: PrintLayout.place(pixelWidth: page.image.width, pixelHeight: page.image.height,
                                                   dpi: page.dpi, on: setup.paper, mode: mode, align: align))
        }
        let paper = setup.paper.paper
        let document: Data? = await Task.detached(priority: .userInitiated) {
            PrintDocument.makePDF(pages: printPages, paper: paper)
        }.value
        guard let document else { throw PrintError.failed("The copy could not be prepared for printing.") }
        if flag.isCancelled { throw ScanError.cancelled }
        // A protected PDF's password is asked for before printing. No answer still prints the copy;
        // the PDF is then not written.
        var noPassword = false
        if alsoPDF {
            do {
                _ = try await protectionFor(s)
            } catch is PDFPasswordNotGiven {
                noPassword = true
            }
        }
        let copies = PrintCopies.clamp(options.copyCount)
        statusMessage = "Printing on \(setup.printerName)\u{2026}"
        let job = PrintJob(printerName: setup.printerName, jobName: "Copy", paper: setup.paper, copies: copies)
        var printError: Error?
        do {
            let printed: Bool
            if reusePrinter {
                printed = try await printService.printAgain(document, job: job)
            } else {
                printed = try await printService.print(document, job: job)
            }
            guard printed else {
                statusMessage = "Printing cancelled."
                return false
            }
        } catch {
            // The PDF asked for is still written: the pages are kept nowhere else.
            guard alsoPDF else { throw error }
            printError = error
        }
        // A held copy goes into the history and the task's steps once, on its first print, whatever
        // becomes of its PDF.
        if printError == nil && holdsCopy(s) && !copyPagesRecorded {
            copyPagesRecorded = true
            _ = await addToHistory(pages, intent: s.intent, generation: nil)
            recordCaptures(pages.map(\.id))
        }
        let sent = PrintText.sent(pageCount: pages.count, copies: copies, printerName: printedOn(setup, s))
        let warning = printPages.lazy.compactMap { PrintLayout.clipWarning($0.placement, paper: paper) }.first
        let warningNote = warning.map { " \($0)" } ?? ""
        guard alsoPDF else {
            statusMessage = sent + warningNote
            return true
        }
        if noPassword {
            guard let printError else {
                statusMessage = "\(sent) \(PDFProtection.notSavedMessage)\(warningNote)"
                return true
            }
            // A held copy stays on its screen, so it is not queued as well.
            if holdsCopy(s) {
                throw AppState.copyNotPrinted(printError, setup: setup, pdfNote: " \(PDFProtection.notSavedMessage)")
            }
            // Neither printed nor saved: the pages wait in the queue rather than being lost.
            let spool = spoolDirectory
            let spooled: [ScannedPage] = await Task.detached(priority: .userInitiated) {
                AppState.spoolPages(pages, to: spool)
            }.value
            scannedPages.append(contentsOf: spooled)
            throw AppState.copyNotPrinted(printError, setup: setup,
                                          pdfNote: " \(PDFProtection.keptInQueueMessage(pages.count))")
        }
        statusMessage = "Saving the PDF\u{2026}"
        // After a copy went to the printer, a PDF that cannot be written is reported, not undone.
        let url: URL
        var protected = false
        do {
            let target = try outputURL(fileExtension: "pdf")
            let writeOptions: PDFWriteOptions = try await self.pdfOptions(s, for: target)
            protected = writeOptions.isProtected
            try await Task.detached(priority: .userInitiated) {
                try AppState.writePDFAtomically(pages: pages, searchable: s.pdfSearchable, languages: s.ocrLanguages,
                                                pdfSize: s.output.pdfSize, to: target, options: writeOptions,
                                                shouldContinue: { !flag.isCancelled }, progress: nil)
            }.value
            url = target
        } catch {
            if AppState.isCancellation(error) || AppState.isPasswordNotGiven(error) {
                if let printError {
                    throw AppState.copyNotPrinted(printError, setup: setup, pdfNote: " The PDF was not saved (cancelled).")
                }
                // The copy has gone to the printer: only the PDF was cancelled.
                statusMessage = AppState.isPasswordNotGiven(error)
                    ? "\(sent) \(PDFProtection.notSavedMessage)"
                    : "\(sent) PDF not saved (cancelled)."
                return true
            }
            guard let printError else { throw error }
            throw AppState.copyNotPrinted(printError, setup: setup,
                                          pdfNote: " The PDF could not be saved either: \(error.localizedDescription)")
        }
        lastSavedURLs = [url]
        notePDFSize(of: url, protected: protected)
        if let printError {
            throw AppState.copyNotPrinted(printError, setup: setup, pdfNote: " The scan was saved as \(url.lastPathComponent).")
        }
        statusMessage = "\(sent) Saved \(url.lastPathComponent)\(pdfSizeSuffix).\(warningNote)"
        return true
    }

    /// Whether `error` is a cancelled operation (Cancel was pressed).
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if let scanError = error as? ScanError, case .cancelled = scanError { return true }
        return error is CancellationError
    }

    /// The error of a copy that could not be printed: why, then what became of its PDF.
    nonisolated static func copyNotPrinted(_ printError: Error, setup: PrinterSetup, pdfNote: String) -> PrintError {
        let reason = printError is PrintError
            ? printError.localizedDescription
            : "Could not print on \(setup.printerName): \(printError.localizedDescription)"
        return PrintError.failed(reason + pdfNote)
    }

    // MARK: Copy on the iPhone and iPad

    /// The phone has no inspector to set a copy up before it is taken, so a copy's pages (from the camera,
    /// Photos, Files or a network scanner) are cleaned up as any copy's, then held for the copy screen and
    /// printed from there; not queued, not spooled, and not in the history until they print.
    func holdsCopy(_ s: ScanSettings) -> Bool {
        platform == .ios && TaskCatalog.flow(of: s) == .copy
    }

    /// Holds a copy's pages, in memory only, for the copy screen; an area selected on the preview prints
    /// centred, as on the Mac.
    func holdCopy(_ pages: [ScannedPage], areaSelected: Bool) {
        copyPages = pages
        copyAreaSelected = areaSelected
        statusMessage = "Copy ready to print."
    }

    /// Print… on the phone: the pages Save would write, at full resolution, held on the copy screen as a
    /// copy's are, to print from there whatever the task. The queue keeps them; letting the copy go only
    /// closes the screen. Nothing is copied, so the status is a print's, not `holdCopy`'s.
    public func printQueueAsCopy() {
        guard !isBusy, !scannedPages.isEmpty else { return }
        let s = settings
        runExclusive { flag in
            await self.pageEditChain?.value
            let plan = SavePlan.make(self.scannedPages, options: s.document)
            let pages: [ScannedPage] = plan.documents.flatMap { $0.pages }
            guard !pages.isEmpty else {
                self.errorMessage = PageFilter.nothingToSaveMessage
                return
            }
            // A spooled page shows a preview; its print size comes from the full pixels at its dpi.
            let full: [ScannedPage] = await Task.detached(priority: .userInitiated) { () -> [ScannedPage] in
                pages.map { (page: ScannedPage) -> ScannedPage in
                    guard page.fileURL != nil else { return page }
                    var loaded = page.withImage(Self.fullImage(of: page))
                    loaded.rotationQuarterTurns = 0
                    return loaded
                }
            }.value
            if flag.isCancelled { throw ScanError.cancelled }
            self.refreshPrinters()
            self.holdCopy(full, areaSelected: false)
            self.copyIsOfQueue = true
            self.statusMessage = "Ready to print."
        }
    }

    /// Some held page has no known real size (a camera page that matched no paper size), so the copy is
    /// fitted to the page whatever Fit to page says (`PrintLayout.copyFitsToPage`).
    public var copyNeedsFit: Bool { copyPages.contains { !$0.printsAtRealSize } }

    /// Prints the held copy on the printer chosen in the picker. The pages stay held, for Copy again.
    public func printHeldCopy() {
        printHeldCopy(reusePrinter: false)
    }

    /// Prints the held copy again on the printer picked last, without the picker.
    public func printHeldCopyAgain() {
        printHeldCopy(reusePrinter: true)
    }

    private func printHeldCopy(reusePrinter: Bool) {
        let pages = copyPages
        guard !pages.isEmpty else { return }
        let s = settings
        let areaSelected = copyAreaSelected
        runExclusive { flag in
            guard let setup = self.setupForPrinting(s, requestedPaper: Self.requestedPaper(s)) else {
                throw PrintError.noPrinter
            }
            try await self.printCopyPages(pages, settings: s, setup: setup, areaSelected: areaSelected,
                                          reusePrinter: reusePrinter, flag: flag)
        }
    }

    /// Lets the held copy go.
    public func discardHeldCopy() {
        guard !isBusy, !copyPages.isEmpty else { return }
        let ofQueue = copyIsOfQueue
        copyPages = []
        statusMessage = ofQueue
            ? "\(scannedPages.count) page\(scannedPages.count == 1 ? "" : "s") in the queue."
            : "Copy discarded."
    }

    /// Prints the ID card's page: both sides at real size, laid out on the paper of the review (or the
    /// paper chosen in the print panel's printer), one copy, on the printer chosen for copies. The
    /// review stays open: the card is still saved or discarded there.
    public func printIdCard() {
        guard let front = idCardFront else { return }
        let back = idCardBack
        let s = settings
        let paper = idCardPaperSize
        runExclusive { flag in
            guard let setup = self.setupForPrinting(s, requestedPaper: paper) else { throw PrintError.noPrinter }
            let paperInches = setup.paper.paper
            let pageDPI = IdCardComposer.pageDPI(front.dpi)
            let drawn: (Data, IdCardLayoutResult)? = await Task.detached(priority: .userInitiated) { () -> (Data, IdCardLayoutResult)? in
                guard let f = AppState.idCardSide(of: front) else { return nil }
                let b = back.flatMap { AppState.idCardSide(of: $0) }
                let layout = IdCardLayout.place(front: f.inches, back: b?.inches, paper: paperInches)
                let composed = IdCardComposer.compose(front: f, back: b, dpi: pageDPI, paperInches: paperInches)
                guard let image = composed.makeCGImage() else { return nil }
                let whole = CGRect(x: 0, y: 0, width: Double(paperInches.width), height: Double(paperInches.height))
                let page = PrintPage(image: image, dpi: pageDPI,
                                     placement: PrintPlacement(rect: whole, scale: 1, quarterTurns: 0, clippedInches: 0))
                guard let data = PrintDocument.makePDF(pages: [page], paper: paperInches) else { return nil }
                return (data, layout)
            }.value
            guard let drawn else { throw PrintError.failed("The page could not be drawn.") }
            if flag.isCancelled { throw ScanError.cancelled }
            let layout = drawn.1
            // The page is the paper; what matters is whether the printer's margins reach the card.
            var clipped = PrintLayout.clippedInches(layout.front, printable: setup.paper.printable)
            if let backRect = layout.back {
                clipped = max(clipped, PrintLayout.clippedInches(backRect, printable: setup.paper.printable))
            }
            let placement = PrintPlacement(rect: CGRect(x: 0, y: 0, width: Double(paperInches.width),
                                                        height: Double(paperInches.height)),
                                           scale: 1, quarterTurns: 0, clippedInches: clipped)
            self.statusMessage = "Printing the ID card on \(setup.printerName)\u{2026}"
            let job = PrintJob(printerName: setup.printerName, jobName: "ID card", paper: setup.paper, copies: 1)
            guard try await self.printService.print(drawn.0, job: job) else {
                self.statusMessage = "Printing cancelled."
                return
            }
            let size = layout.scaledToFit ? "made smaller to fit" : "at real size"
            let warning = PrintLayout.clipWarning(placement, paper: paperInches)
            self.statusMessage = "Sent the ID card to \(self.printedOn(setup, s)) on \(setup.paper.description), \(size)."
                + (warning.map { " \($0)" } ?? "")
        }
    }

    /// Prints a page with a 1-inch grid and centimetre ticks at real size on the printer chosen for
    /// copies, to check with a ruler that copies come out at real size.
    public func printRulerPage() {
        let s = settings
        runExclusive { flag in
            guard let setup = self.setupForPrinting(s, requestedPaper: Self.requestedPaper(s)) else { throw PrintError.noPrinter }
            let paper = setup.paper
            let dpi = 300
            let document: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
                let ruler = PrintCalibration.makeRulerPage(paper: paper.paper, dpi: dpi)
                guard let image = ruler.makeCGImage() else { return nil }
                let placement = PrintLayout.place(pixelWidth: ruler.width, pixelHeight: ruler.height, dpi: dpi,
                                                  on: paper, mode: .actualSize, align: .paperOrigin)
                return PrintDocument.makePDF(pages: [PrintPage(image: image, dpi: dpi, placement: placement)],
                                             paper: paper.paper)
            }.value
            guard let document else { throw PrintError.failed("The ruler test page could not be drawn.") }
            if flag.isCancelled { throw ScanError.cancelled }
            self.statusMessage = "Printing the ruler test page on \(setup.printerName)\u{2026}"
            let job = PrintJob(printerName: setup.printerName, jobName: "Ruler test page", paper: paper, copies: 1)
            guard try await self.printService.print(document, job: job) else {
                self.statusMessage = "Printing cancelled."
                return
            }
            self.statusMessage = "Sent the ruler test page to \(self.printedOn(setup, s)). At real size each square measures 1 inch (2.54 cm) and each tick 1 cm."
        }
    }
}
