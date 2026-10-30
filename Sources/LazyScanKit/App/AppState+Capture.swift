import CoreGraphics
import Foundation

/// The objects of a camera's shot in the reviews (I13): the photos and receipts a shot was cut into
/// (`CaptureObjects`) come into the photo review one each, with the photo they were cut from and their
/// corners kept for Fix crop; a side of the ID card cut out of a shot is the whole page, checked for glare
/// on the photo as taken (`GlareDetector`), and kept in memory only, as a scanned side is. Fix crop along
/// four corners (the iPhone's touch corner editor) cuts the object out of its photo again with the
/// perspective warp at its real size (`CaptureScale` for its kind) and cleans it up as the shot was; an
/// object found on a scan is cut out of the scan again at its resolution, as the region editor cuts it.
/// Swift only: the Windows app takes no camera shots.
extension AppState {
    /// Where the review of `pages` (cleaned up) finds each page's picture for Fix crop.
    nonisolated static func reviewSources(_ pages: [ScannedPage]) -> ReviewSources {
        var sources = ReviewSources()
        for page in pages {
            if CaptureObjects.isCutOut(page), let facts = page.capture, let photo = page.alternate?.image {
                sources.images[page.id] = photo
                sources.facts[page.id] = facts
            } else {
                sources.images[page.id] = page.image
            }
        }
        return sources
    }

    /// One object of a camera's shot, cut out already (`CaptureObjects.isCutOut`), as a photo of the
    /// review: the whole page, its region the box around its corners in the photo; nil for other pages.
    nonisolated static func cutOutPhoto(_ page: ScannedPage) -> DetectedPhoto? {
        guard CaptureObjects.isCutOut(page), let quad = page.capture?.quad else { return nil }
        return DetectedPhoto(region: CaptureObjects.region(around: quad), image: page.image, dpi: page.dpi,
                             sourcePageID: page.id, colorMode: page.colorMode)
    }

    /// A side of the ID card cut out of a camera's shot along its corners at its real size: the whole page
    /// is the side, the photo as taken is kept (in memory) for Fix crop, and the side's note says when its
    /// shape matched no ID-1 card, so it is not at real size, and gives the glare hint when the photo shows
    /// glare on the card (`CaptureObjects.cardNote`). False when another scanner was chosen meanwhile (a
    /// scan's pages; ingested pages belong to none).
    func recordCapturedIdCardSide(_ side: PageSide, page: ScannedPage, flag: CancelFlag, generation: Int?) async throws -> Bool {
        guard let facts = page.capture else { return true }
        let photo: CGImage = page.alternate?.image ?? page.image
        let quad: Quad = facts.quad
        let glare: Bool = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let pixels = RgbaImage(cgImage: photo) else { return false }
            return GlareDetector.hasGlare(pixels, region: quad)
        }.value
        guard isCurrent(generation) else { return false }
        if flag.isCancelled { throw ScanError.cancelled }
        let card = DetectedPhoto(region: CaptureObjects.region(around: quad), image: page.image, dpi: page.dpi,
                                 sourcePageID: page.id, colorMode: page.colorMode)
        let note: String? = CaptureObjects.cardNote(realSize: facts.scale?.isRealSize == true, glare: glare)
        recordIdCardSide(side, photo: card, note: note, source: photo, area: nil, capture: facts)
        return true
    }

    /// Where Fix crop along four corners starts for `photo` (a photo or receipt of the review, or a side of
    /// the ID card): the picture it was cut from, the corners it was cut along there (a camera's, else the
    /// region found on a scan), kept within the picture, and the kind of object. Nil once the review is closed.
    public func cropStart(for photo: DetectedPhoto) -> PhotoCropStart? {
        guard let sourceID = photo.sourcePageID, let source = photoSource(for: photo) else { return nil }
        let facts: CaptureFacts? = photoCaptureFacts[sourceID] ?? idCardCaptureFacts[sourceID]
        let kind: CaptureKind = facts?.kind ?? CaptureObjects.kind(for: settings)
        let corners: Quad
        if let quad = facts?.quad {
            corners = quad
        } else {
            corners = Quad.fromCorners(photo.region.corners)
        }
        let kept: Quad = PhotoImport.clampedToPhoto(corners, width: source.width, height: source.height)
        return PhotoCropStart(source: source, corners: kept, kind: kind)
    }

    /// Fix crop along four corners (the touch corner editor): the photo, receipt or side of the ID card with
    /// `id` is cut out of its picture again along `corners` (its pixels). One cut out of a camera's shot is
    /// cut with the perspective warp, at its real size (`CaptureScale` for its kind), and cleaned up as the
    /// shot was (a receipt made easy to read, a card checked for its size and for glare), off the main
    /// actor. One found on a scan, or on a whole shot, is cut out again at the scan's resolution as the
    /// region editor cuts it (`recropPhoto(id:region:)`, along `region(along:near:)`). It keeps its turn
    /// and whether it is kept; nothing changes when it was saved, discarded or scanned again meanwhile, or
    /// when the corners cut nothing.
    public func recropPhoto(id: UUID, corners: Quad) {
        guard !isBusy else { return }
        let side: PageSide? = idCardSide(ofPhoto: id)
        var found: DetectedPhoto?
        if let side {
            found = side == .front ? idCardFront : idCardBack
        } else {
            found = detectedPhotos.first(where: { (photo: DetectedPhoto) -> Bool in photo.id == id })
        }
        guard let photo = found, let sourceID = photo.sourcePageID, let start = cropStart(for: photo) else { return }
        guard let facts = photoCaptureFacts[sourceID] ?? idCardCaptureFacts[sourceID] else {
            recropPhoto(id: id, region: AppState.region(along: corners, near: photo.region))
            return
        }
        let focalLength: Double? = facts.focalLength
        let kind: CaptureKind = start.kind
        let source: CGImage = start.source
        let s: ScanSettings = settings
        Task { @MainActor [weak self] in
            let cut: CapturedCut? = await Task.detached(priority: .userInitiated) { () -> CapturedCut? in
                AppState.cutAlong(source, corners: corners, kind: kind, focalLength: focalLength, settings: s)
            }.value
            guard let self, let cut, !self.isBusy else { return }
            if let side {
                let current: DetectedPhoto? = side == .front ? self.idCardFront : self.idCardBack
                guard let held = current, held.id == photo.id else { return }
                var updated = DetectedPhoto(region: cut.region, image: cut.image, dpi: cut.dpi, id: held.id,
                                            sourcePageID: held.sourcePageID, colorMode: cut.colorMode)
                updated.rotationQuarterTurns = held.rotationQuarterTurns
                self.idCardCaptureFacts[sourceID] = cut.facts
                let note: String? = CaptureObjects.cardNote(realSize: cut.facts.scale?.isRealSize == true, glare: cut.glare)
                self.setIdCardSide(side, photo: updated, note: note)
                self.statusMessage = "Crop updated."
                self.refreshIdCardPreview()
            } else {
                guard let index = self.detectedPhotos.firstIndex(where: { (item: DetectedPhoto) -> Bool in item.id == id }) else { return }
                let old: DetectedPhoto = self.detectedPhotos[index]
                var updated = DetectedPhoto(region: cut.region, image: cut.image, dpi: cut.dpi, id: old.id,
                                            sourcePageID: old.sourcePageID, colorMode: cut.colorMode)
                updated.included = old.included
                updated.rotationQuarterTurns = old.rotationQuarterTurns
                self.photoCaptureFacts[sourceID] = cut.facts
                self.detectedPhotos[index] = updated
            }
        }
    }

    /// `source` cut out along `corners` as an object of `kind` with the steps the shot went through
    /// (`PageProcessor.forCapture`: the perspective warp at its real size, the clean-up of the task's mode for
    /// that kind, then the task's adjustments and color mode), a receipt then made easy to read
    /// (`ReceiptEnhancer`), a card checked for glare on `source`; nil when the corners cut nothing.
    nonisolated static func cutAlong(_ source: CGImage, corners: Quad, kind: CaptureKind, focalLength: Double?,
                                     settings: ScanSettings) -> CapturedCut? {
        let named: Quad = Quad.fromCorners(corners.corners)
        let facts = CaptureFacts(quad: named, sourceWidth: source.width, sourceHeight: source.height, kind: kind,
                                 focalLength: focalLength)
        var page: ScannedPage = ScannedPage(image: source, dpi: CaptureScale.nominalDPI, colorMode: .color).withCapture(facts)
        page.source = .photo
        let processor: PageProcessor = PageProcessor.forCapture(settings)
        guard let processed = try? processor.process([page]), let cut = processed.pages.first,
              CaptureObjects.isCutOut(cut), let measured = cut.capture else { return nil }
        var image: CGImage = cut.image
        if kind == .receipt {
            guard let pixels = RgbaImage(cgImage: cut.image),
                  let cleaned = ReceiptEnhancer.enhance(pixels, dpi: cut.dpi).makeCGImage() else { return nil }
            image = cleaned
        }
        var glare: Bool = false
        if kind == .idCard, let pixels = RgbaImage(cgImage: source) {
            glare = GlareDetector.hasGlare(pixels, region: named)
        }
        return CapturedCut(image: image, dpi: cut.dpi, colorMode: cut.colorMode, facts: measured,
                           region: CaptureObjects.region(around: named), glare: glare)
    }

    /// The region along four corners on a scan: the smallest rectangle around them
    /// (`DocumentGeometry.rectAtAngle`) turned as their top and bottom edges are on average, by the quarter
    /// turn nearest `old`'s, so the picture cut along it stays the way up it was.
    nonisolated static func region(along corners: Quad, near old: DetectedPhotoRegion) -> DetectedPhotoRegion {
        let named: Quad = Quad.fromCorners(corners.corners)
        let top: Double = atan2(Double(named.topRight.y) - Double(named.topLeft.y),
                                Double(named.topRight.x) - Double(named.topLeft.x))
        let bottom: Double = atan2(Double(named.bottomRight.y) - Double(named.bottomLeft.y),
                                   Double(named.bottomRight.x) - Double(named.bottomLeft.x))
        var angle: Double = (top + bottom) / 2 * 180 / Double.pi
        while angle - old.angleDegrees > 45 { angle -= 90 }
        while old.angleDegrees - angle > 45 { angle += 90 }
        return DocumentGeometry.rectAtAngle(named.corners, angleDegrees: angle)
    }
}

/// Where Fix crop along four corners starts for a photo, a receipt or a side of the ID card
/// (`AppState.cropStart(for:)`): the picture it was cut from, the corners it was cut along there, and the
/// kind of object it is.
public struct PhotoCropStart {
    public let source: CGImage
    public let corners: Quad
    public let kind: CaptureKind

    public init(source: CGImage, corners: Quad, kind: CaptureKind) {
        self.source = source
        self.corners = corners
        self.kind = kind
    }
}

/// The pictures the objects of a review were cut from, by scanned-page id (`AppState.reviewSources`): a
/// scan itself, or for an object cut out of a camera's shot the photo as taken, with its capture facts.
struct ReviewSources {
    var images: [UUID: CGImage] = [:]
    var facts: [UUID: CaptureFacts] = [:]
}

/// An object cut out again along new corners (`AppState.cutAlong`): its picture, resolution and color
/// mode, the capture facts it was measured with, the box around its corners and whether a card shows glare.
struct CapturedCut {
    let image: CGImage
    let dpi: Int
    let colorMode: ColorMode
    let facts: CaptureFacts
    let region: DetectedPhotoRegion
    let glare: Bool
}
