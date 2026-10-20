import CoreGraphics
import Foundation
import ImageIO

/// A spread pages in the queue were cut from, as scanned: its full-resolution pixels in a spool file
/// (or in memory when the file could not be written), how it was scanned, and its size in pixels.
/// Twin of the Windows `AppViewModel.SpreadSource`.
struct SpreadSource {
    let fileURL: URL?
    let image: CGImage?
    let dpi: Int
    let colorMode: ColorMode
    let createdAt: Date
    let width: Int
    let height: Int
}

/// What the split sheet shows for a spread (`AppState.spreadEditor(for:)`). Twin of the Windows
/// `SpreadEditorSource`.
public struct SpreadEditorSource: Identifiable {
    /// The queued page the sheet was opened from.
    public let pageID: UUID
    /// The spread as scanned, at most 1600 pixels long.
    public let preview: CGImage
    /// How it is cut now.
    public let axis: GutterAxis
    /// Where it is cut now, along `axis` (0...1).
    public let fraction: Double
    /// It is cut now (not kept whole).
    public let isSplit: Bool
    /// Its number in the queue, from 1.
    public let spreadNumber: Int

    public var id: UUID { pageID }
}

/// Books and magazines: the spreads the queued pages were cut from (kept in the spool so a spread can
/// be joined or split again), joining and splitting a spread by hand. The page strip labels the pages
/// with `BookPages`; the inspector binds the book options directly. Twin of the Windows
/// `AppViewModel.Book.cs`.
extension AppState {
    /// Writes each spread as scanned to a spool TIFF of its own ("{id}-spread.tiff"), for joining and
    /// splitting it again; a spread whose file cannot be written is kept in memory.
    nonisolated static func spoolSpreads(_ spreads: [ScannedPage]) -> [UUID: SpreadSource] {
        try? FileManager.default.createDirectory(at: pageSpoolDirectory, withIntermediateDirectories: true)
        var sources: [UUID: SpreadSource] = [:]
        for spread in spreads {
            let url = pageSpoolDirectory.appendingPathComponent("\(spread.id.uuidString)-spread.tiff")
            do {
                try ImageExporter.write(spread.image, to: url, format: .tiff, dpi: spread.dpi, jpegQuality: 1.0)
                sources[spread.id] = SpreadSource(fileURL: url, image: nil, dpi: spread.dpi, colorMode: spread.colorMode,
                                                  createdAt: spread.createdAt, width: spread.image.width,
                                                  height: spread.image.height)
            } catch {
                sources[spread.id] = SpreadSource(fileURL: nil, image: spread.image, dpi: spread.dpi,
                                                  colorMode: spread.colorMode, createdAt: spread.createdAt,
                                                  width: spread.image.width, height: spread.image.height)
            }
        }
        return sources
    }

    static func deleteSpreadFiles(_ sources: [SpreadSource]) {
        for source in sources {
            if let url = source.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The spread's full-resolution pixels: from memory, or read from its spool file; nil when it
    /// cannot be read.
    nonisolated static func loadSpread(_ source: SpreadSource) -> CGImage? {
        if let image = source.image { return image }
        guard let url = source.fileURL, let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    /// Drops the spreads no queued page was cut from any more, and their files. Runs whenever the
    /// queue changes (`scannedPages`).
    func pruneSpreads() {
        guard !spreadSources.isEmpty else { return }
        let used = Set(scannedPages.compactMap(\.spreadID))
        for (id, source) in spreadSources where !used.contains(id) {
            Self.deleteSpreadFiles([source])
            spreadSources[id] = nil
        }
    }

    /// Which spread of the queue (from 1, in queue order) `spreadID` is; 0 when none.
    func spreadNumber(_ spreadID: UUID) -> Int {
        var order: [UUID] = []
        for page in scannedPages {
            if let id = page.spreadID, !order.contains(id) { order.append(id) }
        }
        return (order.firstIndex(of: spreadID) ?? -1) + 1
    }

    /// The spread a queued page was cut from can be joined or split again: its spread is at hand.
    public func canEditSpread(id: UUID) -> Bool {
        guard let page = scannedPages.first(where: { $0.id == id }) else { return false }
        return canEditSpread(of: page)
    }

    /// `canEditSpread(id:)` for a page already at hand, without looking it up in the queue (the strip
    /// asks this for every cell on every refresh).
    public func canEditSpread(of page: ScannedPage) -> Bool {
        guard let spreadID = page.spreadID else { return false }
        return spreadSources[spreadID] != nil
    }

    /// What the split sheet shows for the spread a queued page was cut from: a preview of the spread as
    /// scanned, where it is cut now (a spread kept whole: up and down its middle), and its number. nil
    /// when the page is no book page or its spread can no longer be read.
    public func spreadEditor(for pageID: UUID) async -> SpreadEditorSource? {
        guard let page = scannedPages.first(where: { $0.id == pageID }), let part = page.spread,
              let source = spreadSources[part.spreadID] else { return nil }
        let preview: CGImage? = await Task.detached(priority: .userInitiated) {
            Self.loadSpread(source).map { Self.makePreview($0, maxSide: 1600) ?? $0 }
        }.value
        guard let preview else {
            errorMessage = "The spread could not be read."
            return nil
        }
        let fraction = part.gutter?.fraction(width: source.width, height: source.height) ?? 0.5
        return SpreadEditorSource(pageID: pageID, preview: preview, axis: part.gutter?.axis ?? .vertical,
                                  fraction: fraction, isSplit: !part.isWhole, spreadNumber: spreadNumber(part.spreadID))
    }

    /// The split sheet's Split: the spread the page was cut from is cut again along `axis` at
    /// `fraction` of it, and its pages in the queue are replaced by the new ones, checked, straightened
    /// and turned as a scan is (`PageProcessor.processSpread`); a page the user removed stays out, and
    /// each page keeps its document break, name and keep or skip (`BookPages.replacementPages`).
    public func splitSpread(id: UUID, axis: GutterAxis, fraction: Double) {
        replaceSpread(id: id, cut: (axis, fraction))
    }

    /// "Join the Two Pages" (and the sheet's "Keep as One Page"): the pages cut from the spread are
    /// replaced by the whole spread, as one page.
    public func joinSpread(id: UUID) {
        replaceSpread(id: id, cut: nil)
    }

    private func replaceSpread(id: UUID, cut: (axis: GutterAxis, fraction: Double)?) {
        guard !isBusy, canEditSpread(id: id) else { return }
        let s = settings
        let scorer = orientationScorer
        runExclusive { flag in
            // Turns and swaps clicked before must not land on pages about to be replaced.
            await self.pageEditChain?.value
            guard let page = self.scannedPages.first(where: { $0.id == id }), let spreadID = page.spreadID,
                  let source = self.spreadSources[spreadID] else { return }
            self.statusMessage = cut == nil ? "Joining the pages\u{2026}" : "Splitting the spread\u{2026}"
            // The spread keeps the sheet and side its pages were given.
            let side = page.side
            let sheetIndex = page.sheetIndex
            let pages: [ScannedPage] = try await Task.detached(priority: .userInitiated) { () throws -> [ScannedPage] in
                guard let image = Self.loadSpread(source) else {
                    throw ScanError.scanFailed("The spread could not be read.")
                }
                var spread = ScannedPage(image: image, dpi: source.dpi, colorMode: source.colorMode, id: spreadID,
                                         createdAt: source.createdAt)
                spread.side = side
                spread.sheetIndex = sheetIndex
                let gutter = cut.map { BookSplitter.manual($0.axis, fraction: $0.fraction, width: image.width, height: image.height) }
                let processed = try PageProcessor.forScan(s, arrangement: .asScanned, scorer: scorer)
                    .processSpread(spread, cut: gutter, options: BookSplitOptions.of(s), shouldContinue: { !flag.isCancelled })
                return Self.spoolPages(processed)
            }.value
            let indices = self.scannedPages.indices.filter { self.scannedPages[$0].spreadID == spreadID }
            guard !flag.isCancelled, let firstIndex = indices.first, !pages.isEmpty else {
                self.deleteSpoolFiles(of: pages)
                if flag.isCancelled { throw ScanError.cancelled }
                return
            }
            // The new pages take what the user decided about the old ones; a part the user removed stays out.
            let removed = indices.map { self.scannedPages[$0] }
            let replacement = BookPages.replacementPages(removed, fresh: pages)
            let kept = Set(replacement.map(\.id))
            self.deleteSpoolFiles(of: pages.filter { !kept.contains($0.id) })
            // One change to the queue, so the spread is never without a page (`pruneSpreads`).
            var queue = self.scannedPages
            for index in indices.reversed() { queue.remove(at: index) }
            queue.insert(contentsOf: replacement, at: firstIndex)
            self.scannedPages = queue
            self.deleteSpoolFiles(of: removed)
            self.statusMessage = BookPages.splitNote(spreadNumber: self.spreadNumber(spreadID), split: cut != nil)
                + PageFilter.scanNote(replacement, options: s.document) + PageCorrections.scanNote(replacement)
                + PageTurns.scanNote(replacement)
        }
    }
}
