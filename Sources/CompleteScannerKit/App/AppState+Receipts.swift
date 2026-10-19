import CoreGraphics
import Foundation

/// The Receipts task: the receipts on a scan are found (`ReceiptDetector`), cut out, straightened and
/// made easy to read (`ReceiptEnhancer`), reviewed in the photo review, then saved: each one's text is
/// read once with OCR for its date (the file name's {docdate}), the PDF's text layer and the text beside
/// it, and the receipts are written as a file each or as one PDF, all or nothing. Twin of the Windows
/// `AppViewModel.Receipts.cs`.
extension AppState {
    /// The scans of the settings are receipts (the Receipts task).
    public var isReceiptFlow: Bool { TaskCatalog.flow(of: settings) == .receiptSplit }

    /// The review's title: "Found 3 receipts", or for photos "Detected photos (3)".
    public var reviewTitle: String {
        isReceiptReview ? Receipts.reviewTitle(detectedPhotos.count) : "Detected photos (\(detectedPhotos.count))"
    }

    /// The review's save button: "Save 2 Receipts", "Save as One PDF", "Save 3 Photos".
    public var reviewSaveTitle: String {
        let included = detectedPhotos.filter(\.included).count
        return isReceiptReview
            ? Receipts.saveTitle(included: included, combine: settings.taskOptions.receiptCombine, format: settings.format)
            : "Save \(included) Photo\(included == 1 ? "" : "s")"
    }

    public func setReceiptNameByDate(_ byDate: Bool) {
        guard settings.taskOptions.receiptNameByDate != byDate else { return }
        settings.taskOptions.receiptNameByDate = byDate
    }

    public func setReceiptCombine(_ combine: Bool) {
        guard settings.taskOptions.receiptCombine != combine else { return }
        settings.taskOptions.receiptCombine = combine
    }

    /// The receipts on one scanned page, cut out, upright and cleaned up: several on the glass, the
    /// whole sheet as one from the feeder; the whole page when nothing looks like a receipt.
    nonisolated static func splitReceipts(from page: ScannedPage, settings s: ScanSettings) -> [DetectedPhoto] {
        guard let scan = RgbaImage(cgImage: page.image) else { return [] }
        let options = ReceiptDetectorOptions(singleReceipt: s.source == .documentFeeder)
        var regions = ReceiptDetector.detectRegions(in: scan, dpi: page.dpi, options: options)
        if regions.isEmpty {
            let w = Double(scan.width), h = Double(scan.height)
            regions = [DetectedPhotoRegion(center: CGPoint(x: w / 2, y: h / 2), size: CGSize(width: w, height: h),
                                           angleDegrees: 0)]
        }
        var receipts: [DetectedPhoto] = []
        for region in regions {
            guard let cut = ReceiptDetector.extractEnhanced(scan, region: region, dpi: page.dpi),
                  let image = cut.makeCGImage() else { continue }
            receipts.append(DetectedPhoto(region: region, image: image, dpi: page.dpi, sourcePageID: page.id))
        }
        return receipts
    }

    /// Opens the review on the receipts found on the pages just scanned.
    func showReceipts(_ processed: [ScannedPage], settings s: ScanSettings, flag: CancelFlag,
                      generation: Int) async throws {
        statusMessage = "Finding receipts\u{2026}"
        let found: [DetectedPhoto] = try await Task.detached(priority: .userInitiated) {
            var all: [DetectedPhoto] = []
            for page in processed {
                if flag.isCancelled { throw ScanError.cancelled }
                all.append(contentsOf: Self.splitReceipts(from: page, settings: s))
            }
            return all
        }.value
        guard switchGeneration == generation else { return }
        if flag.isCancelled { throw ScanError.cancelled }
        // Every page's full-resolution scan stays while the review is open, for Fix crop.
        photoSourceImages = Dictionary(uniqueKeysWithValues: processed.map { ($0.id, $0.image) })
        detectedPhotos = found
        isReceiptReview = true
        recordCaptures(found.map(\.id))
        showPhotoReview = !found.isEmpty
        if found.isEmpty { photoSourceImages = [:] }
        statusMessage = "\(Receipts.reviewTitle(found.count)) on the glass."
    }

    /// Fix crop on a receipt: cut out upright and cleaned up again, as it was found.
    nonisolated static func recutReceipt(_ source: CGImage, region: DetectedPhotoRegion, dpi: Int) -> CGImage? {
        guard let scan = RgbaImage(cgImage: source),
              let cut = ReceiptDetector.extractEnhanced(scan, region: region, dpi: dpi) else { return nil }
        return cut.makeCGImage()
    }

    /// Saves the receipts kept in the review: each turned as shown, its text read once with OCR when it
    /// is needed (`Receipts.readsText`) for its date, the PDF's text layer and the text beside it; then a
    /// file each, or one PDF for all (`TaskOptions.receiptCombine`), named by the receipt's date
    /// ({docdate}; for one PDF the earliest), the scan date when none is found. All or nothing: a failed or
    /// cancelled save removes what it wrote and the review stays open.
    func saveReceipts() {
        let s = settings
        let format = s.format.pageFormat
        let byDate = Receipts.namesByDate(s)
        let readsText = Receipts.readsText(s)
        let dayFirst = ReceiptDateExtractor.prefersDayFirst()
        runExclusive { flag in
            let receipts = self.detectedPhotos.filter(\.included)
            guard !receipts.isEmpty else { return }
            let combine = Receipts.combines(s.taskOptions.receiptCombine, format: s.format, count: receipts.count)
            let today = DocumentDate(date: Date())

            // 1. Each receipt as shown, its text read once.
            self.statusMessage = "Reading the receipts\u{2026}"
            let read: [ReadReceipt] = try await Task.detached(priority: .userInitiated) { () throws -> [ReadReceipt] in
                var out: [ReadReceipt] = []
                for receipt in receipts {
                    if flag.isCancelled { throw ScanError.cancelled }
                    let image = receipt.rotationQuarterTurns == 0
                        ? receipt.image
                        : ImagePipeline.rotate(receipt.image, quarterTurns: receipt.rotationQuarterTurns)
                    var lines: [OCRLine]?
                    var problem: String?
                    if readsText {
                        // A receipt whose text cannot be read is still saved: without a text layer,
                        // named by the scan date.
                        do {
                            lines = try OCRService.recognizeLines(in: image)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    var date: DocumentDate?
                    if byDate, let lines {
                        date = ReceiptDateExtractor.findDate(
                            Receipts.textLines(lines, pixelWidth: image.width, pixelHeight: image.height),
                            today: today, preferDayFirst: dayFirst)
                    }
                    out.append(ReadReceipt(image: image, dpi: receipt.dpi, lines: lines, date: date, problem: problem))
                }
                return out
            }.value
            if flag.isCancelled { throw ScanError.cancelled }

            // 2. The files, all or nothing.
            var saved: [URL] = []
            var written: [URL] = []
            var textProblem: String?
            do {
                if combine {
                    let url = try self.outputURL(fileExtension: "pdf", documentDate: Receipts.combinedDate(read.map(\.date)))
                    self.statusMessage = "Writing the PDF\u{2026}"
                    let text = try await Task.detached(priority: .userInitiated) { () throws -> (url: URL?, problem: String?) in
                        try Self.writeReceiptsPDF(read, settings: s, to: url, shouldContinue: { !flag.isCancelled })
                    }.value
                    saved.append(url)
                    written.append(url)
                    if let textURL = text.url { written.append(textURL) }
                    if let problem = text.problem { textProblem = textProblem ?? problem }
                } else {
                    for (index, receipt) in read.enumerated() {
                        if flag.isCancelled { throw ScanError.cancelled }
                        self.statusMessage = "Saving receipt \(index + 1) of \(read.count)\u{2026}"
                        let url = try self.outputURL(fileExtension: format.fileExtension, documentDate: receipt.date)
                        if format == .pdf {
                            let text = try await Task.detached(priority: .userInitiated) { () throws -> (url: URL?, problem: String?) in
                                try Self.writeReceiptsPDF([receipt], settings: s, to: url, shouldContinue: { !flag.isCancelled })
                            }.value
                            saved.append(url)
                            written.append(url)
                            if let textURL = text.url { written.append(textURL) }
                            if let problem = text.problem { textProblem = textProblem ?? problem }
                        } else {
                            try await Task.detached(priority: .userInitiated) {
                                try ImageExporter.write(receipt.image, to: url, format: format, dpi: receipt.dpi,
                                                        jpegQuality: s.jpegQuality)
                            }.value
                            saved.append(url)
                            written.append(url)
                        }
                    }
                }
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            self.lastSavedURLs = saved
            if let url = saved.first, format == .pdf, saved.count == 1 { self.notePDFSize(of: url) }
            self.detectedPhotos = []
            self.showPhotoReview = false
            self.isReceiptReview = false
            self.photoSourceImages = [:]
            self.resetFlow()
            if let textProblem { self.errorMessage = TextExport.sidecarFailed(textProblem) }
            let undated = byDate ? read.filter { $0.date == nil }.count : 0
            self.statusMessage = Receipts.savedMessage(count: read.count, fileNames: saved.map(\.lastPathComponent),
                                                       combined: combine, undated: undated)
            self.runAfterSave(s.output.afterSave, saved: saved)
        }
    }

    /// One PDF of `receipts` (a page each, gray, at the PDF size chosen) with the text read beforehand as
    /// its layer when searchable, and the text beside it when asked for. Returns the text file written
    /// (the next free name when the PDF's is taken; nil when none was), else why it was not (the PDF is kept).
    nonisolated static func writeReceiptsPDF(_ receipts: [ReadReceipt], settings s: ScanSettings, to url: URL,
                                             shouldContinue: @escaping () -> Bool) throws -> (url: URL?, problem: String?) {
        let pages = receipts.map { ScannedPage(image: $0.image, dpi: $0.dpi, colorMode: .grayscale) }
        let lines = receipts.map(\.lines)
        var layer: PDFTextLayer?
        if s.pdfSearchable {
            layer = { index, _ in index < lines.count ? lines[index] : nil }
        }
        try writePDFAtomically(pages: pages, pdfSize: s.output.pdfSize, to: url, textLayer: layer,
                               shouldContinue: shouldContinue, progress: nil)
        guard s.output.alsoSaveText else { return (nil, nil) }
        let text = PDFTextCollector()
        for receipt in receipts {
            if let found = receipt.lines {
                text.pages.append(OCRPage.of(found, pixelWidth: receipt.image.width, pixelHeight: receipt.image.height,
                                             dpi: receipt.dpi))
            } else if text.problem == nil {
                text.problem = receipt.problem ?? "The text could not be read."
            }
        }
        return writeTextBeside(pdf: url, text: text)
    }
}

/// A receipt as saved: its image turned as shown, its text (nil when it was not read or could not be),
/// its date and why its text could not be read.
struct ReadReceipt {
    let image: CGImage
    let dpi: Int
    let lines: [OCRLine]?
    let date: DocumentDate?
    let problem: String?
}
