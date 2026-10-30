#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation

/// The iPhone's short texts of the photo and receipt review, the ID card's review and the ID card's guide
/// frame on the camera (I13). The titles and save buttons are the shared ones (`PhotoReview`, `Receipts`,
/// `AppState.reviewTitle`); the privacy line is `IdCardSteps.privacyNote`.
public enum IOSReviewText {
    /// Leaves the review, keeping nothing (photos and receipts).
    public static let cancelLabel = "Cancel"
    /// Whether a photo or receipt is saved.
    public static let keepLabel = "Keep"
    public static let fixCropLabel = "Fix crop"
    public static let rotateLabel = "Rotate"
    /// What the list of photos is for, for VoiceOver (the Windows review's help text).
    public static let listHelp = "Untick a photo to leave it out, or fix its crop."
    /// The receipts' choices (the Mac's and Windows' Receipts section).
    public static let nameByDateLabel = "Name by receipt date"
    public static let combineLabel = "One PDF for all"
    public static let saveAsLabel = "Save as"

    /// The ID card's review.
    public static let idCardTitle = "Check the ID card"
    /// The privacy line's full sentence on the iPhone, for VoiceOver.
    public static let privacyHelp = "The photos stay on this device and are cleared once you save or discard them."
    public static let frontTitle = "Front"
    public static let backTitle = "Back"
    public static let scanAgainLabel = "Scan again"
    public static let swapLabel = "Swap sides"
    /// A card saved without its back.
    public static let noBackLine = "No back side"
    public static let scanBackLabel = "Scan the back"
    public static let pagePreviewName = "Page preview"
    public static let paperLabel = "Paper"
    public static let sidesAsImagesLabel = "Also save sides as images"
    public static let discardLabel = "Discard"
    public static let discardHint = "Delete both sides; can't be undone"
    /// The ID card review's Print button (AirPrint, I16).
    public static let printLabel = "Print"
    public static let printIdCardHint = "Print both sides at real size on an AirPrint printer"

    /// The ID card's guide frame on the camera: what to fit in it, by side.
    public static let cardFrontPrompt = "Fit the front in the frame"
    public static let cardBackPrompt = "Fit the back in the frame"
    /// What VoiceOver calls the guide frame.
    public static let guideName = "Card frame"

    /// The ID card's save button: "Save PDF", "Save JPEG".
    public static func idCardSaveTitle(_ format: OutputFormat) -> String {
        "Save \(format.pageFormat.label)"
    }

    /// "Rotate the front", "Fix crop of the back", "Scan the front again": a side's button as VoiceOver reads it.
    public static func sideAction(_ action: String, side: PageSide) -> String {
        let name: String = side == .front ? "front" : "back"
        if action == scanAgainLabel { return "Scan the \(name) again" }
        if action == fixCropLabel { return "Fix crop of the \(name)" }
        return "\(action) the \(name)"
    }

    /// A photo's or receipt's size on paper: "6.0 × 4.0 in".
    public static func sizeCaption(width: Int, height: Int, dpi: Int) -> String {
        let d: Double = Double(max(dpi, 1))
        let w: Double = Double(width) / d
        let h: Double = Double(height) / d
        return String(format: "%.1f \u{00D7} %.1f in", w, h)
    }
}

/// Fix crop for one photo, receipt or side of the ID card: the corner editor's request on the picture it
/// was cut from (`AppState.cropStart(for:)`), and which photo it is for.
public struct IOSCropRequest: Identifiable {
    public let photoID: UUID
    public let request: PhotoCornersRequest

    public var id: UUID { request.id }

    public init(photoID: UUID, request: PhotoCornersRequest) {
        self.photoID = photoID
        self.request = request
    }
}

/// The photo and receipt review on the iPhone and iPad without a screen (I13), a port of the Mac's and
/// Windows' review: the photos (or receipts) found, each kept or left out (`DetectedPhoto.included`) and
/// turned a quarter at a time; the receipts' naming by date, one PDF for all and PDF or JPEG; Fix crop
/// through the touch corner editor on the picture each was cut from (`cropRequest`, `applyCrop`: the
/// camera's objects are cut again along the new corners with the perspective warp); Save
/// (`AppState.saveReviewedPhotos`: photos as pictures, receipts named by their date) and Cancel. The ID
/// card's review uses its Fix crop too. The state is the one source: the screen observes it.
@MainActor
public final class IOSPhotoReviewModel {
    public let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    /// "Found 3 photos", "Found 2 receipts".
    public var title: String { state.reviewTitle }
    /// "Save 3 photos", "Save 2 Receipts", "Save as One PDF".
    public var saveTitle: String { state.reviewSaveTitle }
    public var photos: [DetectedPhoto] { state.detectedPhotos }
    public var isReceipts: Bool { state.isReceiptReview }

    /// How many are kept.
    public var includedCount: Int {
        var count: Int = 0
        for photo in state.detectedPhotos where photo.included {
            count += 1
        }
        return count
    }

    /// Something is kept and nothing runs.
    public var canSave: Bool { includedCount > 0 && !state.isBusy }

    public func isIncluded(_ id: UUID) -> Bool {
        for photo in state.detectedPhotos where photo.id == id {
            return photo.included
        }
        return false
    }

    public func setIncluded(_ id: UUID, _ included: Bool) {
        guard let index = index(of: id) else { return }
        state.detectedPhotos[index].included = included
    }

    public func toggle(_ id: UUID) {
        setIncluded(id, !isIncluded(id))
    }

    /// Turns the photo a quarter clockwise (applied when it is saved).
    public func rotate(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let turns: Int = state.detectedPhotos[index].rotationQuarterTurns + 1
        state.detectedPhotos[index].rotationQuarterTurns = ((turns % 4) + 4) % 4
    }

    public func save() {
        guard canSave else { return }
        state.saveReviewedPhotos()
    }

    public func cancel() {
        guard !state.isBusy else { return }
        state.cancelPhotoReview()
    }

    // MARK: Receipts

    public var nameByDate: Bool { state.settings.taskOptions.receiptNameByDate }

    public func setNameByDate(_ on: Bool) {
        state.setReceiptNameByDate(on)
    }

    public var combine: Bool { state.settings.taskOptions.receiptCombine }

    public func setCombine(_ on: Bool) {
        state.setReceiptCombine(on)
    }

    /// One PDF for all is offered for receipts saved as PDFs.
    public var offersCombine: Bool { isReceipts && state.settings.format.pageFormat == .pdf }

    /// The formats offered: receipts as PDFs or JPEGs; photos in the task's own format (none to choose).
    public var formats: [OutputFormat] { isReceipts ? [.pdf, .jpeg] : [] }

    public var format: OutputFormat { state.settings.format.isImageFormat ? .jpeg : .pdf }

    public func setFormat(_ format: OutputFormat) {
        guard state.settings.format != format else { return }
        state.settings.format = format
    }

    // MARK: Fix crop

    /// The corner editor's request for `photo` (a photo, a receipt or a side of the ID card): the picture it
    /// was cut from, read off the main actor, with the corners it was cut along and what it is, which the
    /// editor's words name (`PhotoCropStart.kind`), shown as `name` (number of count); nil once the review is
    /// closed.
    public func cropRequest(for photo: DetectedPhoto, name: String, number: Int, count: Int) async -> IOSCropRequest? {
        guard let start = state.cropStart(for: photo) else { return nil }
        let source: CGImage = start.source
        let pixels: RgbaImage? = await Task.detached(priority: .userInitiated) { () -> RgbaImage? in
            RgbaImage(cgImage: source)
        }.value
        guard let picture = pixels else { return nil }
        let plan = PhotoImportPlan(action: .review, corners: start.corners, reason: PhotoReviewReason.none,
                                   detection: PhotoDocumentDetection.nothing)
        let request = PhotoCornersRequest(photo: picture, plan: plan, fileName: name, number: number, count: count,
                                          kind: start.kind)
        return IOSCropRequest(photoID: photo.id, request: request)
    }

    /// The corner editor's answer: Use corners cuts the photo again along them, Use whole photo along the
    /// whole picture; Cancel (Skip) changes nothing.
    public func applyCrop(_ crop: IOSCropRequest, answer: PhotoCornersAnswer) {
        switch answer.choice {
        case .useCorners:
            if let corners = answer.corners {
                state.recropPhoto(id: crop.photoID, corners: corners)
            }
        case .wholePhoto:
            let whole: Quad = PhotoImport.wholePhoto(width: crop.request.photo.width, height: crop.request.photo.height)
            state.recropPhoto(id: crop.photoID, corners: whole)
        case .skip:
            break
        }
    }

    // MARK: Pictures

    /// `image` made small for a card of the review (its longer side at most `maxSide` pixels).
    public nonisolated static func thumbnail(_ image: CGImage, maxSide: Int) -> CGImage {
        let width: Int = image.width
        let height: Int = image.height
        let longest: Int = max(width, height)
        guard longest > maxSide, maxSide > 0 else { return image }
        let scale: Double = Double(maxSide) / Double(longest)
        let w: Int = max(1, Int((Double(width) * scale).rounded()))
        let h: Int = max(1, Int((Double(height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    private func index(of id: UUID) -> Int? {
        state.detectedPhotos.firstIndex(where: { (photo: DetectedPhoto) -> Bool in photo.id == id })
    }
}
#endif
