import CoreGraphics
import Foundation
import ImageIO

/// A camera's queued page cut out of its photo again (the iPhone's page viewer): with another filter
/// (`CaptureFilter`), or along corners placed again (Crop). The photo is the page's other version, in its
/// spool file; the corners and the real size are in the page's capture facts. The cut goes through the steps
/// the page went through when it was taken (`PerspectiveStep`, `EnhanceStep`), so a filter chosen afterwards
/// gives the pixels the same filter gives as the page is taken. Swift only: the Windows app takes no camera
/// shots.
public enum PageRecut {
    /// Whether `page` can be cut again: a camera's page cut out along its corners and shown that way (not
    /// swapped to its photo), with a filter (a photo or a card has none), its pixels and its photo in spool
    /// files.
    public static func canRecut(_ page: ScannedPage) -> Bool {
        guard page.capture?.scale != nil, page.geometry?.basis == .perspective, !page.showsOriginal,
              page.fileURL != nil, page.alternate?.fileURL != nil else { return false }
        return filter(of: page) != nil
    }

    /// The page's filter: the one recorded, or for a page queued before filters the one its clean-up stands
    /// for; nil for pages without one (photos, cards, pages not taken by a camera).
    public static func filter(of page: ScannedPage) -> CaptureFilter? {
        guard let capture = page.capture, page.geometry?.basis == .perspective else { return nil }
        if let filter = capture.filter { return filter }
        return capture.enhancement.flatMap { (mode: DocumentEnhanceMode) -> CaptureFilter? in CaptureFilter(mode: mode) }
    }

    /// The quarter turns the page's spool files hold. Turning pages upright turns the pixels of a page that is
    /// not spooled yet, which a camera's page never is then; every turn after that goes into its rotation.
    static func fileTurns(_ page: ScannedPage) -> Int {
        page.upright?.quarterTurns ?? 0
    }

    /// `page` cut again out of `photo` (its other version as the spool file holds it, at any size: the
    /// corners are scaled to it) with `filter`, along `corners` (in the photo as taken, before any turn; nil:
    /// the page's own). The pixels come back turned as the spool file holds the page, not by its rotation;
    /// the resolution, the real size, the corners and the filter are the new cut's, and everything else the
    /// queue knows about the page (its rotation, its photo, its blank check, its codes) is kept. Nil when the
    /// corners cut nothing.
    public static func recut(_ page: ScannedPage, photo: CGImage, filter: CaptureFilter, corners: Quad? = nil) -> ScannedPage? {
        guard var facts = page.capture else { return nil }
        let turns: Int = fileTurns(page)
        let taken: CGImage = turns == 0 ? photo : ImagePipeline.rotate(photo, quarterTurns: 4 - turns)
        if let corners {
            facts.quad = Quad.fromCorners(corners.corners)
        }
        facts.scale = nil
        facts.enhancement = nil
        facts.filter = nil
        let source = ScannedPage(image: taken, dpi: page.dpi, colorMode: .color, id: page.id, createdAt: page.createdAt)
            .withCapture(facts)
        let cut: ScannedPage = EnhanceStep(mode: filter.mode).apply(PerspectiveStep().apply(source))
        guard cut.geometry?.basis == .perspective, cut.capture?.filter != nil else { return nil }
        let image: CGImage = turns == 0 ? cut.image : ImagePipeline.rotate(cut.image, quarterTurns: turns)
        var result = ScannedPage(image: image, dpi: cut.dpi, colorMode: cut.colorMode, id: page.id, createdAt: page.createdAt)
        result.rotationQuarterTurns = page.rotationQuarterTurns
        result = result.copyMeta(from: page).withAlternate(page.alternate)
        result.geometry = cut.geometry
        result.capture = cut.capture
        return result
    }

    /// The corners `corners`, placed on the page's photo turned `quarterTurns` clockwise, on the photo as taken.
    static func cornersAsTaken(_ corners: Quad, facts: CaptureFacts, quarterTurns: Int) -> Quad {
        let turns: Int = ((quarterTurns % 4) + 4) % 4
        var shown: CaptureFacts = facts.oriented(PhotoOrientation(quarterTurns: turns, mirrored: false))
        shown.quad = Quad.fromCorners(corners.corners)
        return shown.oriented(PhotoOrientation(quarterTurns: (4 - turns) % 4, mirrored: false)).quad
    }

    /// "Page 2: Grayscale."
    public static func filterNote(_ filter: CaptureFilter, number: Int) -> String {
        "Page \(number): \(filter.label)."
    }

    /// "Page 2 is cut out again."
    public static func cropNote(number: Int) -> String {
        "Page \(number) is cut out again."
    }

    public static let failedMessage = "The page could not be changed: its photo could not be read."
}

extension AppState {
    /// Gives the queued page `id` another filter: the page is cut out of its photo again with it, off the main
    /// actor, and its spool file replaced (`PageRecut`). It runs behind the page swaps and turns under way,
    /// like them, and a save waits for it, so the last filter tapped is the one the page ends with; a page that
    /// has the filter by then is left as it is, and one that cannot be cut again is never touched. Not while a
    /// share or a send reads the pages (`readsQueue`): the cut takes the old file away.
    public func setPageFilter(id: UUID, _ filter: CaptureFilter) {
        guard !isBusy, !readsQueue, let page = scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == id }),
              PageRecut.canRecut(page) else { return }
        enqueuePageEdit { (state: AppState) async -> Void in
            await state.recut(id: id, filter: filter, corners: nil)
        }
    }

    /// Crop: the queued page `id` cut out of its photo again along `corners`, placed on the picture
    /// `pageCropStart(id:)` gave (the photo turned as the page is shown, while its rotation was `rotation`),
    /// keeping its filter; as `setPageFilter(id:_:)` does it. Nothing happens once the page was turned since.
    public func recropPage(id: UUID, corners: Quad, rotation: Int) {
        guard !isBusy, !readsQueue, let page = scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == id }),
              page.rotationQuarterTurns == rotation, PageRecut.canRecut(page), let filter = PageRecut.filter(of: page),
              let facts = page.capture else { return }
        let turns: Int = PageRecut.fileTurns(page) + page.rotationQuarterTurns
        let taken: Quad = PageRecut.cornersAsTaken(corners, facts: facts, quarterTurns: turns)
        enqueuePageEdit { (state: AppState) async -> Void in
            await state.recut(id: id, filter: filter, corners: taken)
        }
    }

    /// Where Crop starts for the queued page `id`: its photo read off the main actor and turned as the page is
    /// shown, with the corners the page was cut along there, once the page edits under way have landed; nil when
    /// the page cannot be cut again or its photo cannot be read.
    public func pageCropStart(id: UUID) async -> PhotoCropStart? {
        await pageEditChain?.value
        guard let page = scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == id }),
              PageRecut.canRecut(page), let facts = page.capture, let url = page.alternate?.fileURL else { return nil }
        let rotation: Int = page.rotationQuarterTurns
        let photo: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let stored = AppState.imageInFile(url) else { return nil }
            return rotation == 0 ? stored : ImagePipeline.rotate(stored, quarterTurns: rotation)
        }.value
        guard let photo else { return nil }
        let turns: Int = (PageRecut.fileTurns(page) + rotation) % 4
        let corners: Quad = facts.oriented(PhotoOrientation(quarterTurns: turns, mirrored: false)).quad
        return PhotoCropStart(source: photo, corners: PhotoImport.clampedToPhoto(corners, width: photo.width, height: photo.height),
                              kind: facts.kind)
    }

    /// Small pictures of the queued page `id` with each filter, cut out of a copy of its photo about
    /// `maxSide` × 2 pixels on its longer side, off the main actor, and turned as the page is shown; empty when
    /// the page cannot be cut again or its photo cannot be read.
    public func filterPreviews(id: UUID, maxSide: Int) async -> [CaptureFilter: CGImage] {
        guard let page = scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == id }),
              PageRecut.canRecut(page), let url = page.alternate?.fileURL else { return [:] }
        let rotation: Int = page.rotationQuarterTurns
        return await Task.detached(priority: .userInitiated) { () -> [CaptureFilter: CGImage] in
            guard let photo = AppState.thumbnailOfFile(url, maxSide: maxSide * 2) else { return [:] }
            var previews: [CaptureFilter: CGImage] = [:]
            for filter in CaptureFilter.displayOrder {
                guard let cut = PageRecut.recut(page, photo: photo, filter: filter) else { continue }
                previews[filter] = rotation == 0 ? cut.image : ImagePipeline.rotate(cut.image, quarterTurns: rotation)
            }
            return previews
        }.value
    }

    /// Cuts the page again and puts it in the queue with a spool file of its own, if the page is still there
    /// as it was when the work started (not removed, turned or swapped meanwhile); the old file goes.
    func recut(id: UUID, filter: CaptureFilter, corners: Quad?) async {
        guard let page = scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == id }),
              PageRecut.canRecut(page), corners != nil || PageRecut.filter(of: page) != filter,
              let photoURL = page.alternate?.fileURL, let oldFile = page.fileURL else { return }
        let spool: URL = spoolDirectory
        recuttingPages.insert(id)
        let made: ScannedPage? = await Task.detached(priority: .userInitiated) { () -> ScannedPage? in
            guard let photo = AppState.imageInFile(photoURL),
                  let cut = PageRecut.recut(page, photo: photo, filter: filter, corners: corners) else { return nil }
            return AppState.spoolRecut(cut, to: spool)
        }.value
        recuttingPages.remove(id)
        guard let index = scannedPages.firstIndex(where: { (item: ScannedPage) -> Bool in item.id == id }),
              scannedPages[index].fileURL == oldFile,
              scannedPages[index].rotationQuarterTurns == page.rotationQuarterTurns,
              scannedPages[index].showsOriginal == page.showsOriginal else {
            if let file = made?.fileURL { try? FileManager.default.removeItem(at: file) }
            return
        }
        guard let made else {
            errorMessage = PageRecut.failedMessage
            return
        }
        // What changed on the page meanwhile (kept or skipped, its document) stays.
        var updated: ScannedPage = made.copyMeta(from: scannedPages[index])
        updated.geometry = made.geometry
        updated.capture = made.capture
        scannedPages[index] = updated
        try? FileManager.default.removeItem(at: oldFile)
        statusMessage = corners == nil ? PageRecut.filterNote(filter, number: index + 1) : PageRecut.cropNote(number: index + 1)
        // The record names the new file at once: the old one is gone.
        if keepsQueue { writeQueueRecord() }
    }

    /// `page` (full pixels, no file) written to a spool file of its own in `directory` and queued as a preview
    /// turned by its rotation, as `spoolPages` queues a page; nil when the file cannot be written.
    nonisolated static func spoolRecut(_ page: ScannedPage, to directory: URL) -> ScannedPage? {
        let url = directory.appendingPathComponent("\(page.id.uuidString)-\(UUID().uuidString).tiff")
        do {
            try ImageExporter.write(page.image, to: url, format: .tiff, dpi: page.dpi, jpegQuality: 1.0)
        } catch {
            return nil
        }
        let small: CGImage = makePreview(page.image, maxSide: 1600) ?? page.image
        let turns: Int = page.rotationQuarterTurns
        let preview: CGImage = turns == 0 ? small : ImagePipeline.rotate(small, quarterTurns: turns)
        return page.withImage(preview, fileURL: url, fullPixelSize: CGSize(width: page.image.width, height: page.image.height))
    }

    /// The full pixels of the picture in `url`; nil when it cannot be read.
    nonisolated static func imageInFile(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The picture in `url` made at most `maxSide` pixels on its longer side, as stored (no turn).
    nonisolated static func thumbnailOfFile(_ url: URL, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
