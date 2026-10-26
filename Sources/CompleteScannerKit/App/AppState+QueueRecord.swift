import CoreGraphics
import Foundation

/// The page queue as the iPhone keeps it beside its spool files (queue.json), so the pages taken survive iOS
/// ending the app in the background (`AppStateFiles.keepsQueue`): each page's spool files and what the queue
/// knows about it. The previews are read from the files again. The spreads book pages were cut from and the
/// spine's shadow stay in memory only, as the companion package leaves them out. Swift only: Windows keeps
/// emptying its spool at launch.
struct QueueRecord: Codable, Sendable {
    var pages: [Page]

    struct Page: Codable, Sendable {
        var id: UUID
        var file: String
        var fullPixelSize: CGSize?
        var alternateFile: String?
        var alternatePixelSize: CGSize?
        var dpi: Int
        var colorMode: ColorMode
        var createdAt: Date
        var rotationQuarterTurns: Int
        var side: PageSide?
        var sheetIndex: Int?
        var blank: BlankPageResult?
        var inclusion: PageInclusion
        var geometry: PageGeometry?
        var showsOriginal: Bool
        var patch: PatchCode?
        var barcodes: [BarcodeReading]?
        var documentBreak: DocumentBreak
        var documentLabel: String?
        var upright: UprightTurn?
        var source: PageSource
        var capture: CaptureFacts?
    }

    static let fileName = "queue.json"

    /// "Bringing back 3 pages…"
    static func restoringMessage(_ count: Int) -> String {
        count == 1 ? "Bringing back 1 page\u{2026}" : "Bringing back \(count) pages\u{2026}"
    }

    /// "3 pages are back from last time."; when none could be read, says so.
    static func restoredMessage(_ count: Int) -> String {
        switch count {
        case 0: return "The pages kept from last time could not be read."
        case 1: return "1 page is back from last time."
        default: return "\(count) pages are back from last time."
        }
    }

    /// The record of `pages`; nil when one of them has no file in `spool` (kept in memory because its spill
    /// failed), which the record could not bring back. A version not shown that is in memory only is left out.
    init?(_ pages: [ScannedPage], spool: URL) {
        var records: [Page] = []
        for page in pages {
            guard let url = page.fileURL, url.deletingLastPathComponent().path == spool.path else { return nil }
            var alternateFile: String?
            if let other = page.alternate?.fileURL, other.deletingLastPathComponent().path == spool.path {
                alternateFile = other.lastPathComponent
            }
            records.append(Page(id: page.id, file: url.lastPathComponent, fullPixelSize: page.fullPixelSize,
                                alternateFile: alternateFile, alternatePixelSize: page.alternate?.fullPixelSize,
                                dpi: page.dpi, colorMode: page.colorMode, createdAt: page.createdAt,
                                rotationQuarterTurns: page.rotationQuarterTurns, side: page.side,
                                sheetIndex: page.sheetIndex, blank: page.blank, inclusion: page.inclusion,
                                geometry: page.geometry, showsOriginal: page.showsOriginal, patch: page.patch,
                                barcodes: page.barcodes, documentBreak: page.documentBreak,
                                documentLabel: page.documentLabel, upright: page.upright, source: page.source,
                                capture: page.capture))
        }
        self.pages = records
    }

    /// The record in `spool` when its pages can come back: it reads, every page's file is there, and the
    /// settings the app starts with save a queue (`TaskFlowKind.documentQueue`). Otherwise nil, and the
    /// spool is emptied as it always was.
    static func read(in spool: URL, settings: ScanSettings) -> QueueRecord? {
        guard TaskCatalog.flow(of: settings) == .documentQueue,
              let data = try? Data(contentsOf: spool.appendingPathComponent(fileName)),
              let record = try? JSONDecoder().decode(QueueRecord.self, from: data), !record.pages.isEmpty else {
            return nil
        }
        let present: Bool = record.pages.allSatisfy { (page: Page) -> Bool in
            FileManager.default.fileExists(atPath: spool.appendingPathComponent(page.file).path)
        }
        return present ? record : nil
    }

    /// Pages kept in Application Support are no use in a backup: they belong to this device's session.
    static func keepOutOfBackups(_ spool: URL) {
        var directory = spool
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// Empties `spool` of what a previous run left, the files of the queue `kept` (and its record) aside.
    static func clear(_ spool: URL, keeping kept: QueueRecord?) {
        let manager = FileManager.default
        guard let kept else {
            try? manager.removeItem(at: spool)
            try? manager.createDirectory(at: spool, withIntermediateDirectories: true)
            return
        }
        var keep: Set<String> = [fileName]
        for page in kept.pages {
            keep.insert(page.file)
            if let other = page.alternateFile { keep.insert(other) }
        }
        let names = (try? manager.contentsOfDirectory(atPath: spool.path)) ?? []
        for name in names where !keep.contains(name) {
            try? manager.removeItem(at: spool.appendingPathComponent(name))
        }
    }
}

extension QueueRecord.Page {
    /// The page this was recorded from, with `preview` (read from its file) as its picture.
    func page(preview: CGImage, spool: URL) -> ScannedPage {
        var page = ScannedPage(image: preview, dpi: dpi, colorMode: colorMode, id: id, createdAt: createdAt,
                               fileURL: spool.appendingPathComponent(file), fullPixelSize: fullPixelSize)
        page.rotationQuarterTurns = rotationQuarterTurns
        page.side = side
        page.sheetIndex = sheetIndex
        page.blank = blank
        page.inclusion = inclusion
        page.geometry = geometry
        page.showsOriginal = showsOriginal
        page.patch = patch
        page.barcodes = barcodes
        page.documentBreak = documentBreak
        page.documentLabel = documentLabel
        page.upright = upright
        page.source = source
        page.capture = capture
        if let alternateFile {
            let other = spool.appendingPathComponent(alternateFile)
            if FileManager.default.fileExists(atPath: other.path) {
                page.alternate = PageVersion(image: nil, fileURL: other, fullPixelSize: alternatePixelSize)
            }
        }
        return page
    }
}

extension AppState {
    /// Writes the queue's record beside the spool, or removes it when the queue is empty or could not be
    /// brought back from its files.
    func writeQueueRecord() {
        queueRecordTask?.cancel()
        queueRecordTask = nil
        let url = spoolDirectory.appendingPathComponent(QueueRecord.fileName)
        guard !scannedPages.isEmpty, let record = QueueRecord(scannedPages, spool: spoolDirectory),
              let data = try? JSONEncoder().encode(record) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Records a queue kept a moment after it last changed (`queueRecordDelay`), so a batch of changes
    /// writes once.
    func scheduleQueueRecord() {
        guard keepsQueue, !restoringQueue else { return }
        queueRecordTask?.cancel()
        let delay = queueRecordDelay
        queueRecordTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.writeQueueRecord()
        }
    }

    /// Brings back the queue kept last time as an operation of its own (`isBusy`), so no kind is picked,
    /// nothing saved and no page taken until the pages are back: their previews are read off the main
    /// actor, and a page whose file cannot be read is left out. Cancel does not stop it.
    func restoreQueue(_ record: QueueRecord) {
        restoringQueue = true
        let spool = spoolDirectory
        statusMessage = QueueRecord.restoringMessage(record.pages.count)
        runExclusive { _ in
            let previews: [CGImage?] = await Task.detached(priority: .userInitiated) {
                record.pages.map { (page: QueueRecord.Page) -> CGImage? in
                    AppState.previewOfSpoolFile(spool.appendingPathComponent(page.file),
                                                quarterTurns: page.rotationQuarterTurns)
                }
            }.value
            var pages: [ScannedPage] = []
            for (page, preview) in zip(record.pages, previews) {
                if let preview {
                    pages.append(page.page(preview: preview, spool: spool))
                }
            }
            self.restoringQueue = false
            self.scannedPages = pages + self.scannedPages
            self.statusMessage = QueueRecord.restoredMessage(pages.count)
        }
    }
}
