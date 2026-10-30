#if os(iOS)
import LazyScanKit
import CoreGraphics
import Foundation
import Vision

/// What Vision's rectangle search (`VNDetectRectanglesRequest`) is asked for, for one kind of object: up to
/// `maximumObservations` outlines whose short side over long side, as the photo shows them, lies between
/// `minimumAspectRatio` and `maximumAspectRatio`, at least `minimumSize` of the photo's shorter side, with
/// corners within `quadratureTolerance` degrees of square and a confidence of at least `minimumConfidence`.
/// The shape window is wider than `MultiQuadPicker`'s for the kind, since a tilted object looks narrower or
/// wider than it is; the picker then checks its real shape (`CaptureScale.aspect`), size and nesting.
public struct IOSRectangleSearch: Equatable, Sendable {
    public let maximumObservations: Int
    public let minimumAspectRatio: Double
    public let maximumAspectRatio: Double
    public let minimumSize: Double
    public let quadratureTolerance: Double
    public let minimumConfidence: Double

    public init(maximumObservations: Int, minimumAspectRatio: Double, maximumAspectRatio: Double, minimumSize: Double,
                quadratureTolerance: Double, minimumConfidence: Double) {
        self.maximumObservations = maximumObservations
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.minimumSize = minimumSize
        self.quadratureTolerance = quadratureTolerance
        self.minimumConfidence = minimumConfidence
    }

    /// The search for `kind`: receipts long and narrow, up to 16 outlines (the picker keeps 6), crumpled
    /// corners allowed 20°; photos up to twice as long as wide, up to 16 (the picker keeps 8), 15°; an ID
    /// card near ID-1's shape, up to 4 (the picker keeps 1), 15°, a fifth of the photo at least; a page,
    /// one outline of at least 0.3 of the photo.
    public static func of(_ kind: CaptureKind) -> IOSRectangleSearch {
        switch kind {
        case .receipt:
            return IOSRectangleSearch(maximumObservations: 16, minimumAspectRatio: 0.08, maximumAspectRatio: 0.95,
                                      minimumSize: 0.08, quadratureTolerance: 20, minimumConfidence: 0.3)
        case .photo:
            return IOSRectangleSearch(maximumObservations: 16, minimumAspectRatio: 0.4, maximumAspectRatio: 1,
                                      minimumSize: 0.1, quadratureTolerance: 15, minimumConfidence: 0.3)
        case .idCard:
            return IOSRectangleSearch(maximumObservations: 4, minimumAspectRatio: 0.45, maximumAspectRatio: 0.85,
                                      minimumSize: 0.2, quadratureTolerance: 15, minimumConfidence: 0.3)
        case .document:
            return IOSRectangleSearch(maximumObservations: 1, minimumAspectRatio: 0.4, maximumAspectRatio: 1,
                                      minimumSize: 0.3, quadratureTolerance: 20, minimumConfidence: 0.5)
        }
    }
}

/// Finds the objects of one camera shot (several receipts or photos, an ID card) in an upright photo:
/// Vision's rectangles (`VNDetectRectanglesRequest`, asked as `IOSRectangleSearch.of(kind)` says), their
/// normalized corners in the photo's pixels (x · W, (1 − y) · H, named by where they are), picked by the
/// shared `MultiQuadPicker` for the kind (size, shape, nesting, overlap, reading order), each kept within
/// the photo and only when it can be cut out along (`PhotoImport.canUseCorners`). Empty when Vision finds
/// none or cannot run (the Simulator may not run it): the import then falls back to the flatbed's search
/// of the whole shot (`CaptureObjects.fallbackPage`) for receipts and photos, or the page finder for a card.
public enum IOSObjectFinder {
    /// The objects of `kind` in `photo`, in reading order.
    public static func find(_ photo: RgbaImage, kind: CaptureKind) -> [Quad] {
        guard let image = photo.makeCGImage() else { return [] }
        let found: [QuadCandidate] = visionCandidates(image, search: IOSRectangleSearch.of(kind))
        return pick(found, width: photo.width, height: photo.height, kind: kind)
    }

    /// The outlines among `candidates` (the photo's pixels) that are objects of `kind`, in reading order,
    /// each kept within the photo and usable to cut along.
    public static func pick(_ candidates: [QuadCandidate], width: Int, height: Int, kind: CaptureKind) -> [Quad] {
        let picked: [Quad] = MultiQuadPicker.pick(candidates, imageWidth: width, imageHeight: height, kind: kind)
        var usable: [Quad] = []
        for quad in picked {
            let kept: Quad = PhotoImport.clampedToPhoto(quad, width: width, height: height)
            if PhotoImport.canUseCorners(kept) {
                usable.append(kept)
            }
        }
        return usable
    }

    /// Vision's outlines as candidates in the photo's pixels: each observation's four normalized corners
    /// (origin bottom-left, as Vision gives top left, top right, bottom right, bottom left) with its
    /// confidence; observations without four corners are left out.
    public static func candidates(_ corners: [[CGPoint]], confidences: [Double], width: Int, height: Int) -> [QuadCandidate] {
        var result: [QuadCandidate] = []
        var index: Int = 0
        while index < corners.count {
            let points: [CGPoint] = corners[index]
            if points.count == 4 {
                let quad: Quad = IOSPageFinder.quad(fromNormalized: points, width: width, height: height)
                let confidence: Double = index < confidences.count ? confidences[index] : 0
                result.append(QuadCandidate(quad: quad, confidence: confidence))
            }
            index += 1
        }
        return result
    }

    /// The rectangles Vision finds in `image` (upright) as asked by `search`; empty when it finds none or
    /// cannot run.
    static func visionCandidates(_ image: CGImage, search: IOSRectangleSearch) -> [QuadCandidate] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = search.maximumObservations
        request.minimumAspectRatio = VNAspectRatio(search.minimumAspectRatio)
        request.maximumAspectRatio = VNAspectRatio(search.maximumAspectRatio)
        request.minimumSize = Float(search.minimumSize)
        request.quadratureTolerance = VNDegrees(search.quadratureTolerance)
        request.minimumConfidence = VNConfidence(search.minimumConfidence)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var observations: [VNObservation] = []
        if let results = request.results {
            for result in results {
                observations.append(result)
            }
        }
        var corners: [[CGPoint]] = []
        var confidences: [Double] = []
        for observation in observations {
            guard let rectangle = observation as? VNRectangleObservation else { continue }
            corners.append([rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft])
            confidences.append(Double(rectangle.confidence))
        }
        return candidates(corners, confidences: confidences, width: image.width, height: image.height)
    }
}
#endif
