#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation
import Vision

/// Where the page is in an imported photo, for the corner editor to start from.
public struct IOSFoundPage: Equatable, Sendable {
    /// The corners to start from, in the photo's pixels (within the photo).
    public let corners: Quad
    /// Why the corners need a look (`PhotoImport.reasonText`); `.none` when the page was found clearly.
    public let reason: PhotoReviewReason
    /// Vision found the page (false: the shared detector, or a start rectangle).
    public let byVision: Bool

    public init(corners: Quad, reason: PhotoReviewReason, byVision: Bool) {
        self.corners = corners
        self.reason = reason
        self.byVision = byVision
    }
}

/// Finds the page in an upright photo: Vision's document segmentation (`VNDetectDocumentSegmentationRequest`,
/// the page's four corners) first, its outline kept when it is a document page's (`MultiQuadPicker`,
/// `.document`: at least a tenth of the photo, a page's shape) and usable (`PhotoImport.canUseCorners`)
/// and moved onto the photo's edges (`QuadRefiner`); otherwise the shared detector (`PhotoImport.plan`, the
/// Mac's and Windows' photo import, which refines its page the same way), whose corners and reason the
/// editor shows. Vision's page counts as found clearly only when Vision was at least `sureVisionConfidence`
/// sure and the photo's edges back every side of it (`minSureSupport`, `QuadRefinement.support`); else it is
/// `.unsure` and the editor opens on the refined corners. The corners always go to the corner editor.
public enum IOSPageFinder {
    /// Vision's outline is taken from this confidence up.
    public static let minVisionConfidence: Double = 0.5
    /// Vision's outline is found clearly from this confidence up (with its edges backing it).
    public static let sureVisionConfidence: Double = 0.7
    /// Vision's outline is found clearly when at least this share of its weakest side lies on an edge.
    public static let minSureSupport: Double = 0.7

    /// The page in `photo`, Vision first; with another page detector picked for the test (`PageDetector`),
    /// that one first (DocAligner's page refined and judged as Vision's is, its confidence as Vision's), or
    /// the shared detector alone.
    public static func find(_ photo: RgbaImage) -> IOSFoundPage {
        let detector: PageDetector = PageDetector.stored()
        if detector == .builtIn {
            return fallback(photo)
        }
        if let model = detector.model {
            if let image = photo.makeCGImage(), let found = PageDetector.run(model, on: image)?.page {
                let candidate = QuadCandidate(quad: found.quad.scaled(Double(photo.width), Double(photo.height)),
                                              confidence: found.confidence)
                if let corners = accepted(candidate, width: photo.width, height: photo.height) {
                    return refined(corners, confidence: candidate.confidence, in: photo)
                }
            }
            return fallback(photo)
        }
        if let image = photo.makeCGImage(), let candidate = visionCandidate(image),
           let corners = accepted(candidate, width: photo.width, height: photo.height) {
            return refined(corners, confidence: candidate.confidence, in: photo)
        }
        return fallback(photo)
    }

    /// Vision's `corners` (accepted, `photo`'s pixels) moved onto the photo's edges and kept within it, found
    /// clearly when Vision's `confidence` and the edges' support both reach theirs.
    public static func refined(_ corners: Quad, confidence: Double, in photo: RgbaImage) -> IOSFoundPage {
        let refinement: QuadRefinement = QuadRefiner.refine(photo, corners)
        let kept: Quad = PhotoImport.clampedToPhoto(refinement.quad, width: photo.width, height: photo.height)
        let sure: Bool = confidence >= sureVisionConfidence && refinement.support >= minSureSupport
        return IOSFoundPage(corners: kept, reason: sure ? .none : .unsure, byVision: true)
    }

    /// The shared detector's corners and reason: the page found clearly (`.none`), else the outline seen
    /// or the start rectangle with why.
    public static func fallback(_ photo: RgbaImage) -> IOSFoundPage {
        let plan: PhotoImportPlan = PhotoImport.plan(photo)
        let reason: PhotoReviewReason = plan.action == .correct ? .none : plan.reason
        let corners: Quad = PhotoImport.clampedToPhoto(plan.corners, width: photo.width, height: photo.height)
        return IOSFoundPage(corners: corners, reason: reason, byVision: false)
    }

    /// `candidate`'s outline when it is a document page's and usable, kept within the photo; nil otherwise.
    public static func accepted(_ candidate: QuadCandidate, width: Int, height: Int) -> Quad? {
        guard candidate.confidence >= minVisionConfidence else { return nil }
        let picked: [Quad] = MultiQuadPicker.pick([candidate], imageWidth: width, imageHeight: height, kind: .document)
        guard let quad = picked.first else { return nil }
        let clamped: Quad = PhotoImport.clampedToPhoto(quad, width: width, height: height)
        guard PhotoImport.canUseCorners(clamped) else { return nil }
        return clamped
    }

    /// Vision's normalized corners (origin bottom-left) in the photo's pixels (top-left origin), named
    /// by where they are (`Quad.fromCorners`).
    public static func quad(fromNormalized points: [CGPoint], width: Int, height: Int) -> Quad {
        let w: Double = Double(width)
        let h: Double = Double(height)
        var pixels: [CGPoint] = []
        for point in points {
            pixels.append(CGPoint(x: Double(point.x) * w, y: (1.0 - Double(point.y)) * h))
        }
        return Quad.fromCorners(pixels)
    }

    /// The page outline Vision's document segmentation finds in `image` (upright), with its confidence;
    /// nil when it finds none or cannot run (the Simulator may not run it).
    static func visionCandidate(_ image: CGImage) -> QuadCandidate? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        return segmentation(handler, width: image.width, height: image.height)
    }

    /// The page outline Vision's document segmentation finds in the image `handler` holds, in the pixels of
    /// that image drawn `width` x `height` (the photo's, or a live frame made small), with its confidence;
    /// nil when it finds none or cannot run. The photo import and the live outline both search this way.
    static func segmentation(_ handler: VNImageRequestHandler, width: Int, height: Int) -> QuadCandidate? {
        let request = VNDetectDocumentSegmentationRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var observations: [VNObservation] = []
        if let results = request.results {
            for result in results {
                observations.append(result)
            }
        }
        guard let first = observations.first, let rectangle = first as? VNRectangleObservation else { return nil }
        let points: [CGPoint] = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
        let outline: Quad = IOSPageFinder.quad(fromNormalized: points, width: width, height: height)
        return QuadCandidate(quad: outline, confidence: Double(rectangle.confidence))
    }
}
#endif
