import CoreGraphics
import Foundation

// Twin of windows/LazyScan.Core/CaptureObjects.cs: the same kinds, pages and rules.

/// The objects of one camera shot as pages (I13): several receipts or photos, or the side of an ID card,
/// each the photo as taken with the object's corners as its capture facts, so the clean-up stage cuts
/// each out along them at its real size (`PerspectiveStep`, which measures it with `CaptureScale` for its
/// kind) and cleans it up for its kind (`EnhanceStep`: photos and cards as photos, never evened out). The
/// task decides the kind (`kind(for:)`); a shot in which no object was found comes in whole
/// (`fallbackPage`), for the flatbed's own search to look at it (receipts on a white table:
/// `ReceiptDetector`; photos on a plain table: `PhotoDetector`) at `fallbackDPI`. A page cut out this
/// way (`isCutOut`) is one object already: the review takes it whole. Twin of C# `CaptureObjects`.
public enum CaptureObjects {
    /// The resolution a whole shot is searched at when no object was found in it: a phone held over a
    /// table takes in about 20 in across, about 200 pixels an inch of a 4000-pixel photo.
    public static let fallbackDPI: Int = CaptureScale.nominalDPI

    /// The kind of object the settings' task photographs: photos, receipts, an ID card, else document pages.
    /// Twin of C# `KindFor`.
    public static func kind(for settings: ScanSettings) -> CaptureKind {
        switch TaskCatalog.flow(of: settings) {
        case .photoSplit:
            return .photo
        case .receiptSplit:
            return .receipt
        case .idCard:
            return .idCard
        case .documentQueue, .copy:
            return .document
        }
    }

    /// One shot may hold several objects of `kind` (receipts, photos), each a page of its own.
    public static func findsSeveral(_ kind: CaptureKind) -> Bool {
        MultiQuadPicker.options(for: kind).maxCount > 1
    }

    /// The page was cut out of its photo along its corners (`PerspectiveStep`): its capture facts carry the
    /// real size it was measured at, and its geometry is the perspective's.
    public static func isCutOut(_ page: ScannedPage) -> Bool {
        page.capture?.scale != nil && page.geometry?.basis == .perspective
    }

    /// The upright rectangle around `quad` (its bounding box), in the same pixels. Twin of C# `RegionAround`.
    public static func region(around quad: Quad) -> DetectedPhotoRegion {
        let corners: [CGPoint] = quad.corners
        var minX: Double = Double(corners[0].x)
        var maxX: Double = Double(corners[0].x)
        var minY: Double = Double(corners[0].y)
        var maxY: Double = Double(corners[0].y)
        for i in 1..<4 {
            minX = min(minX, Double(corners[i].x))
            maxX = max(maxX, Double(corners[i].x))
            minY = min(minY, Double(corners[i].y))
            maxY = max(maxY, Double(corners[i].y))
        }
        return DetectedPhotoRegion(center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                                   size: CGSize(width: maxX - minX, height: maxY - minY), angleDegrees: 0)
    }

    /// A page for each of `quads` (in their order): the photo as taken, at `CaptureScale.nominalDPI` in
    /// color, from a photo (`PageSource.photo`), with the object's corners (named again,
    /// `Quad.fromCorners`), the photo's size, `kind` and the camera's `focalLength` as its capture facts.
    /// The pages share the photo's pixels until each is cut out.
    public static func pages(_ photo: CGImage, quads: [Quad], kind: CaptureKind, focalLength: Double? = nil,
                             createdAt: Date = Date()) -> [ScannedPage] {
        var pages: [ScannedPage] = []
        for quad in quads {
            let named: Quad = Quad.fromCorners(quad.corners)
            let facts = CaptureFacts(quad: named, sourceWidth: photo.width, sourceHeight: photo.height, kind: kind,
                                     focalLength: focalLength)
            var page: ScannedPage = ScannedPage(image: photo, dpi: CaptureScale.nominalDPI, colorMode: .color,
                                                createdAt: createdAt).withCapture(facts)
            page.source = .photo
            pages.append(page)
        }
        return pages
    }

    /// A shot in which no object was found, whole: the photo at `fallbackDPI` in color, from a photo, with
    /// no capture facts, so nothing cuts it and the task's flatbed search looks at it.
    public static func fallbackPage(_ photo: CGImage, createdAt: Date = Date()) -> ScannedPage {
        var page = ScannedPage(image: photo, dpi: fallbackDPI, colorMode: .color, createdAt: createdAt)
        page.source = .photo
        return page
    }

    /// The note on a side of the ID card cut out of a shot whose shape matched no ID-1 card
    /// (`CaptureScaleResult.isRealSize` false): its size is made up.
    public static let cardNotRealSizeNote: String =
        "This does not look like the shape of an ID card, so it is not at real size. Fix the crop, or take it again."

    /// The note on a side of the ID card cut out of a shot: `cardNotRealSizeNote` when it was not measured
    /// at its real size, then `GlareDetector.hint` when the photo shows glare on the card; nil for neither.
    /// Twin of C# `CardNote`.
    public static func cardNote(realSize: Bool, glare: Bool) -> String? {
        var parts: [String] = []
        if !realSize { parts.append(cardNotRealSizeNote) }
        if glare { parts.append(GlareDetector.hint) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The photo review's short texts, the same on every platform (the receipts' are `Receipts`'). Twin of
/// C# `PhotoReview`.
public enum PhotoReview {
    /// The review's title: "Found 3 photos", "Found 1 photo".
    public static func title(_ found: Int) -> String {
        "Found \(found) photo\(found == 1 ? "" : "s")"
    }

    /// The review's save button: "Save 3 photos", "Save 1 photo".
    public static func saveTitle(_ included: Int) -> String {
        "Save \(included) photo\(included == 1 ? "" : "s")"
    }
}
