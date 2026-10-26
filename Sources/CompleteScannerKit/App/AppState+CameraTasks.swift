import CoreGraphics
import Foundation

/// The camera's own ways through the tasks (I14): the two-sided task's sides (flip & capture, or fronts
/// first then backs, `CameraSides`), Separate documents' New document, and Quick scan's page held until
/// it is saved as a picture or its text copied. The sides and Quick scan apply to pages from a photo
/// (`PageSource.photo`: our camera, Photos and Files), which only the iPhone brings in through `ingest`; New
/// document applies to a network scanner's pages too. Swift only: the Windows app takes no camera shots.
extension AppState {
    // MARK: Two-sided

    /// Keeps the camera's two-sided steps in line with the settings: the two-sided task has them, in the
    /// way its options say (a change of way starts them afresh); other tasks have none. A pending New
    /// document goes once the settings no longer offer it.
    func syncCameraSides() {
        if newDocumentPending && !offersNewDocument { newDocumentPending = false }
        guard settings.task == .twoSided else {
            if cameraSides != nil { cameraSides = nil }
            return
        }
        let mode: CameraSidesMode = CameraSides.mode(settings.taskOptions)
        if cameraSides?.mode != mode {
            cameraSides = CameraSides(mode: mode)
        }
    }

    /// A camera's pages came in as `side`: flip & capture moves on to the back or the next sheet; fronts
    /// first records them and puts the stack in order once there are as many backs as fronts. A mismatch
    /// said before goes with the counts it was about, so Put in order checks the new ones first.
    func afterCameraSide(_ side: PageSide, ids: [UUID]) {
        guard var sides = cameraSides, sides.next == side else { return }
        sides.took(ids)
        cameraSides = sides
        if sides.hasEveryBack {
            collateCameraSides(combineAnyway: true)
        } else if sidesMismatch != nil {
            sidesMismatch = nil
        }
    }

    /// A page left the queue: the two-sided steps forget it, and step back when it was the last shot's
    /// (`CameraSides.removed`), so a retaken page is the same side of the same sheet.
    func cameraPageRemoved(_ id: UUID) {
        guard var sides = cameraSides else { return }
        sides.removed(id)
        if sides != cameraSides {
            cameraSides = sides
            if sidesMismatch != nil { sidesMismatch = nil }
        }
    }

    /// The back of the sheet in hand is empty (flip & capture): the next shot is the next sheet's front.
    public func skipCameraBack() {
        guard !isBusy, var sides = cameraSides, sides.canSkipBack else { return }
        sides.skipBack()
        cameraSides = sides
        statusMessage = "No back. Next sheet."
    }

    /// Fronts first: every front is in, the backs come next.
    public func startCameraBacks() {
        guard !isBusy, var sides = cameraSides, sides.canStartBacks else { return }
        sides.startBacks()
        cameraSides = sides
        statusMessage = CameraTaskCatalog.backsPrompt
    }

    /// Fronts first, before every back is in: puts the stack in order when the counts pair up; otherwise
    /// says they do not (`sidesMismatch`), and a second call combines the pages as they are.
    public func putCameraSidesInOrder() {
        guard !isBusy, let sides = cameraSides, sides.canPutInOrder else { return }
        collateCameraSides(combineAnyway: sidesMismatch != nil)
    }

    /// Puts the fronts and backs of the camera's stack in reading order in the queue
    /// (`CameraSides.collation`), unless their counts differ and `combineAnyway` is false: then the mismatch
    /// is shown and more backs can be taken. The steps start again for the next stack.
    private func collateCameraSides(combineAnyway: Bool) {
        guard var sides = cameraSides else { return }
        let collation: QueueCollation = sides.collation(scannedPages.map(\.id))
        let counts: ManualInterleave = collation.interleave
        if counts.mismatch && !combineAnyway {
            sidesMismatch = counts.mismatchMessage
            statusMessage = counts.mismatchMessage ?? ""
            return
        }
        var byID: [UUID: ScannedPage] = [:]
        for page in scannedPages {
            byID[page.id] = page
        }
        var ordered: [ScannedPage] = []
        for id in collation.order {
            guard let page = byID[id] else { continue }
            if let position = collation.positions[id] {
                ordered.append(page.withSide(position.side, sheetIndex: position.sheetIndex))
            } else {
                ordered.append(page)
            }
        }
        scannedPages = ordered
        sides.reset()
        cameraSides = sides
        sidesMismatch = nil
        let sheets: Int = max(counts.fronts, counts.backs)
        statusMessage = "Put \(sheets) sheet\(sheets == 1 ? "" : "s") in order \u{2014} \(scannedPages.count) in queue."
    }

    // MARK: Separate documents

    /// The Separate documents task collects pages, so New document can mark where the next one starts.
    public var offersNewDocument: Bool {
        settings.task == .batch && TaskCatalog.flow(of: settings) == .documentQueue && settings.documentMultiPage
    }

    /// New document can be tapped: pages are in the queue and nothing runs.
    public var canStartNewDocument: Bool {
        offersNewDocument && !isBusy && !scannedPages.isEmpty && !newDocumentPending
    }

    /// New document: the next page taken starts a new document, as a click on the gap before it would.
    public func startNewDocument() {
        guard canStartNewDocument else { return }
        newDocumentPending = true
        statusMessage = CameraTaskCatalog.newDocumentPrompt
    }

    /// After pages came in (from the camera or a scanner): the first of `ids` that is saved (not a separator
    /// sheet, not left out as blank) starts a new document when New document is pending; until one comes, it
    /// stays pending.
    func applyNewDocument(to ids: [UUID]) {
        guard newDocumentPending, offersNewDocument else { return }
        let facts: [PageFacts] = scannedPages.map { (page: ScannedPage) -> PageFacts in
            PageFacts.of(page, options: settings.document)
        }
        let plan: SplitPlan = DocumentSplitter.plan(facts, options: settings.document)
        for id in ids {
            guard let index = scannedPages.firstIndex(where: { (page: ScannedPage) -> Bool in page.id == id }) else { continue }
            guard plan.pages[index].role == .content else { continue }
            newDocumentPending = false
            if plan.pages[index].startsDocument { return }
            scannedPages[index] = scannedPages[index].withDocumentBreak(.split)
            carryDocumentLabels(from: facts)
            if let number = queuePlan.pages[index].document {
                statusMessage = "Document \(number) starts at page \(index + 1)."
            }
            return
        }
    }

    // MARK: Quick scan

    /// Quick scan's pages from a photo are held for its screen (save as a picture or copy the text) rather
    /// than saved at once, as a scan's are on the Mac. The phone holds a scanner's page too: its Text kind
    /// promises the text whatever the page came from.
    nonisolated static func holdsQuickScan(_ settings: ScanSettings, source: PageSource,
                                           platform: TroubleshootPlatform) -> Bool {
        (source == .photo || platform == .ios) && settings.task == .quickScan && !settings.documentMultiPage
    }

    /// Holds the page a Quick scan shot gave, in memory only.
    func holdQuickScan(_ pages: [ScannedPage]) {
        guard let page = pages.last else { return }
        quickScanPage = page
        statusMessage = "Quick scan ready."
    }

    /// Saves the held Quick scan page as a picture (JPEG unless an image format is chosen) in the save
    /// folder, then lets it go.
    public func saveQuickScan() {
        guard let page = quickScanPage else { return }
        let s: ScanSettings = settings
        let format: OutputFormat = s.format.imageFormatOrJPEG
        runExclusive { flag in
            let url: URL = try self.outputURL(fileExtension: format.fileExtension)
            try await Task.detached(priority: .userInitiated) { () throws -> Void in
                try ImageExporter.write(page.image, to: url, format: format, dpi: page.dpi, jpegQuality: s.jpegQuality,
                                        colorMode: page.colorMode)
            }.value
            if flag.isCancelled {
                try? FileManager.default.removeItem(at: url)
                throw ScanError.cancelled
            }
            self.lastSavedURLs = [url]
            self.quickScanPage = nil
            self.statusMessage = "Saved \(url.lastPathComponent)"
            self.runAfterSave(s.output.afterSave, saved: [url])
        }
    }

    /// Copy text: reads the held Quick scan page's text and puts it on the pasteboard, a blank line between
    /// paragraphs; the page stays, to be saved too.
    public func copyQuickScanText() {
        copyQuickScanText(reading: AppState.readText)
    }

    /// The same with the text read by `reading` (tests pass a stand-in).
    func copyQuickScanText(reading: @escaping @Sendable (ScannedPage) throws -> String) {
        guard let page = quickScanPage else { return }
        runExclusive { flag in
            self.statusMessage = "Reading the text\u{2026}"
            let text: String = try await Task.detached(priority: .userInitiated) { () throws -> String in
                try reading(page)
            }.value
            if flag.isCancelled { throw ScanError.cancelled }
            if !text.isEmpty {
                do {
                    try self.copyTextToPasteboard(text)
                } catch {
                    throw TextOutputError("Copy did not work: \(error.localizedDescription)")
                }
            }
            self.statusMessage = text.isEmpty ? "No text found." : "Text copied."
        }
    }

    /// Lets the held Quick scan page go, unsaved.
    public func discardQuickScan() {
        guard !isBusy, quickScanPage != nil else { return }
        quickScanPage = nil
        statusMessage = "Quick scan discarded."
    }

    /// The text OCR reads on `page`, in reading order with a blank line between paragraphs.
    nonisolated static func readText(_ page: ScannedPage) throws -> String {
        let prepared = PDFBuilder.preparePage(page)
        let lines: [OCRLine]
        do {
            lines = try OCRService.recognizeLines(in: prepared.image)
        } catch {
            throw TextOutputError(TextExport.recognitionFailed(error.localizedDescription))
        }
        return OCRText.pageText(OCRPage.of(lines, pixelWidth: prepared.pixelWidth, pixelHeight: prepared.pixelHeight,
                                           dpi: page.dpi))
    }
}
