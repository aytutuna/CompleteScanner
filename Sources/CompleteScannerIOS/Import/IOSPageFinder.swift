#if os(iOS)
import CompleteScannerKit
import CompleteScannerModel
import CoreGraphics
import Foundation

/// Where the page is in an imported photo, for the corner editor to start from.
public struct IOSFoundPage: Equatable, Sendable {
    /// The corners to start from, in the photo's pixels (within the photo).
    public let corners: Quad
    /// Why the corners need a look (`PhotoImport.reasonText`); `.none` when the page was found clearly.
    public let reason: PhotoReviewReason
    /// The corner model found the page (false: the shared detector, or a start rectangle).
    public let byModel: Bool

    public init(corners: Quad, reason: PhotoReviewReason, byModel: Bool) {
        self.corners = corners
        self.reason = reason
        self.byModel = byModel
    }
}

/// Finds the page in an upright photo by the photo import's rules, the Mac's and Windows' too
/// (`PhotoImport.plan(_:model:)`): DocAligner's FastViT-T8 first (`FastViTCornerModel`, `PhotoImport.modelPlan`:
/// a document page's outline the editor can use, moved onto the photo's edges, found clearly when the model
/// is sure and the edges back it), otherwise the shared detector (`PhotoImport.plan(_:)`). The corners and
/// the reason go to the corner editor.
public enum IOSPageFinder {
    /// The corner model the photos and the live outline use; nil when it is not in this build.
    static let model: FastViTCornerModel? = FastViTCornerModel.isAvailable ? FastViTCornerModel.shared : nil

    /// The page in `photo`, the corner model first.
    public static func find(_ photo: RgbaImage) -> IOSFoundPage {
        if let model = IOSPageFinder.model, let plan = PhotoImport.modelPlan(photo, model: model) {
            return found(plan, in: photo, byModel: true)
        }
        return fallback(photo)
    }

    /// The shared detector's corners and reason: the page found clearly (`.none`), else the outline seen
    /// or the start rectangle with why.
    public static func fallback(_ photo: RgbaImage) -> IOSFoundPage {
        found(PhotoImport.plan(photo), in: photo, byModel: false)
    }

    /// `plan`'s corners, kept within `photo`, and its reason (`.none` when it corrects the photo).
    static func found(_ plan: PhotoImportPlan, in photo: RgbaImage, byModel: Bool) -> IOSFoundPage {
        let reason: PhotoReviewReason = plan.action == .correct ? .none : plan.reason
        let corners: Quad = PhotoImport.clampedToPhoto(plan.corners, width: photo.width, height: photo.height)
        return IOSFoundPage(corners: corners, reason: reason, byModel: byModel)
    }

    /// `candidate`'s outline when the model is sure enough of it (`PhotoImport.minModelConfidence`) and it is a
    /// document page's and usable, kept within the photo; nil otherwise.
    public static func accepted(_ candidate: QuadCandidate, width: Int, height: Int) -> Quad? {
        guard candidate.confidence >= PhotoImport.minModelConfidence else { return nil }
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
}
#endif
