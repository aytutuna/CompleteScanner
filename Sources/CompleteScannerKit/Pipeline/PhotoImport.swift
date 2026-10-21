import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/PhotoImport.cs: the same rules, numbers and words.

/// How a photo's stored pixels are turned to show it the right way up, read from the orientation tag
/// cameras write (EXIF and TIFF tag 274, values 1 to 8, ImageIO's `kCGImagePropertyOrientation`):
/// mirrored left to right first when `mirrored`, then turned `quarterTurns` quarter turns clockwise.
/// Twin of C# `PhotoOrientation`.
public struct PhotoOrientation: Equatable, Sendable {
    public var quarterTurns: Int
    public var mirrored: Bool

    public init(quarterTurns: Int, mirrored: Bool) {
        self.quarterTurns = quarterTurns
        self.mirrored = mirrored
    }

    /// The pixels are stored the right way up (tag 1, or no tag).
    public static let upright = PhotoOrientation(quarterTurns: 0, mirrored: false)

    public var isUpright: Bool { quarterTurns == 0 && !mirrored }

    /// The turn for tag value `value`: 1 upright, 2 mirrored, 3 upside down, 4 mirrored top to
    /// bottom, 5 mirrored across the main diagonal, 6 turned a quarter clockwise, 7 mirrored across
    /// the other diagonal, 8 turned a quarter counterclockwise. Any other value (no tag, 0, 9…) is upright.
    public static func fromExif(_ value: Int) -> PhotoOrientation {
        switch value {
        case 2: return PhotoOrientation(quarterTurns: 0, mirrored: true)
        case 3: return PhotoOrientation(quarterTurns: 2, mirrored: false)
        case 4: return PhotoOrientation(quarterTurns: 2, mirrored: true)
        case 5: return PhotoOrientation(quarterTurns: 3, mirrored: true)
        case 6: return PhotoOrientation(quarterTurns: 1, mirrored: false)
        case 7: return PhotoOrientation(quarterTurns: 1, mirrored: true)
        case 8: return PhotoOrientation(quarterTurns: 3, mirrored: false)
        default: return .upright
        }
    }
}

/// What happens to an imported photo (`PhotoImport.plan(_:width:height:)`). Twin of C# `PhotoImportAction`.
public enum PhotoImportAction: Sendable {
    /// The page was found clearly: it is cut out along its corners without asking.
    case correct
    /// The user checks the corners first (or uses the whole photo, or skips it).
    case review
}

/// Why the user is asked to check a photo's corners. Twin of C# `PhotoReviewReason`.
public enum PhotoReviewReason: Sendable {
    /// Nothing to check: the page was found clearly.
    case none
    /// An outline was found, but its edges are not clear enough to trust.
    case unsure
    /// The page runs off the edge of the photo.
    case cutOff
    /// Two pages of about the same size are in the photo.
    case twoPages
    /// No page was found.
    case nothingFound
}

/// What to do with one imported photo: correct it along `corners`, or show the corner editor with
/// `corners` as its starting guess and `reason` as its note. `corners` are in the photo's pixels
/// (upright photo): the page found, else the best outline seen kept within the photo, else a
/// rectangle inset from the photo's edges. Twin of C# `PhotoImportPlan`.
public struct PhotoImportPlan: Equatable, Sendable {
    public var action: PhotoImportAction
    public var corners: Quad
    public var reason: PhotoReviewReason
    public var detection: PhotoDocumentDetection

    public init(action: PhotoImportAction, corners: Quad, reason: PhotoReviewReason, detection: PhotoDocumentDetection) {
        self.action = action
        self.corners = corners
        self.reason = reason
        self.detection = detection
    }
}

/// The user's answer in the corner editor. Twin of C# `PhotoCornersChoice`.
public enum PhotoCornersChoice: Sendable {
    /// Cut the page out along the corners as placed.
    case useCorners
    /// Add the whole photo as the page, unchanged.
    case wholePhoto
    /// Leave this photo out.
    case skip
}

/// Importing photos of documents (JPEG, PNG, HEIC… files) as pages of the queue: each photo is turned
/// upright by its orientation tag, the page is found (`PhotoDocumentDetector`) and cut out along its
/// corners with its perspective corrected (`PerspectiveCorrector`); when the page is not found
/// clearly the user places the corners (or takes the whole photo). The page then goes through the
/// clean-up stage like a scan (`PageProcessor.forPhotoImport`), with the photo as it was kept as its
/// other version, so one click shows it as photographed. The photo files are only read: never
/// changed, moved or copied beside themselves. Twin of C# `PhotoImport`.
public enum PhotoImport {
    /// A page found with at least this confidence is corrected without asking.
    public static let sureConfidence = 0.7
    /// The resolution of a page whose paper size is not known (`PerspectiveCorrector.nominalDPI`).
    public static let nominalDPI = 200
    /// The lowest resolution a page from a photo is given (a small photo of a big sheet)…
    public static let minDPI = 50
    /// …and the highest.
    public static let maxDPI = 1200
    /// With nothing found, the editor starts with a rectangle this share of the photo in from each edge.
    public static let startInset = 0.1
    /// The corner editor keeps every edge at least this many photo pixels long.
    public static let minEdgePixels = 16.0
    /// A photo of more pixels than this is not imported (its pixels alone would take 600 MB).
    public static let maxPhotoPixels = 150_000_000

    /// The file types offered for import (lowercase, without the dot).
    public static let fileExtensions = ["jpg", "jpeg", "jpe", "png", "heic", "heif", "hif", "tif", "tiff", "bmp", "webp"]
    /// The HEIF file types (iPhone photos): Windows reads them only with the HEIF extension installed.
    public static let heifExtensions = ["heic", "heif", "hif"]

    public static let buttonLabel = "Import photos of documents\u{2026}"
    /// The import button's tooltip.
    public static let buttonHint = "Add phone photos of documents as pages"
    /// The import button's full explanation, for VoiceOver.
    public static let buttonHelp = "Each page is found in the photo and straightened. Your photo files are not changed."
    public static let pickerTitle = "Import photos of documents"
    /// The line under the import link on the empty stage.
    public static let dropHint = "or drop them here"
    /// What the window shows while photo files are dragged over it.
    public static let dropOverlay = "Drop to add as pages"
    /// The page strip's label on a page taken from a photo.
    public static let label = "Photo"
    public static let labelHelp = "Imported from a photo"
    /// The caption of a page cut out of its photo (`PageGeometry.caption`).
    public static let correctedCaption = "Corrected from photo"
    /// The caption of such a page shown as photographed (`PageCorrections.caption`).
    public static let originalCaption = "As photographed"
    public static let editorTitle = "Check the corners"
    public static let editorHelp = "Drag each corner onto a corner of the page."
    /// The corner editor's keys, behind its info button and in the canvas's VoiceOver help.
    public static let editorKeys = "Keys 1\u{2013}4 select a corner. Arrow keys move it; Shift takes bigger steps."
    public static let useCornersLabel = "Use corners"
    public static let wholePhotoLabel = "Use whole photo"
    public static let skipLabel = "Skip photo"
    public static let notOfferedMessage =
        "Photos of documents are added to the page queue: choose Document mode, or a document task, to import them."
    public static let noPhotosMessage =
        "None of those files is a photo that can be imported (JPEG, PNG, HEIC, TIFF, BMP or WebP)."
    /// Why a file that is no picture (or a damaged one) was not imported (`unreadableMessage`).
    public static let unreadableDetail = "it is not a picture this app can read, or the file is damaged."
    /// Why a photo of more than `maxPhotoPixels` was not imported.
    public static let tooLargeDetail = "the photo is too large (more than 150 megapixels)."
    /// Why a file that went away before it was read was not imported.
    public static let missingDetail = "the file is no longer there."

    /// `path` names a file of a type offered for import (by its extension).
    public static func isPhotoFile(_ path: String) -> Bool { fileExtensions.contains(extensionOf(path)) }

    /// `path` names a HEIF file (.heic, .heif, .hif).
    public static func isHeif(_ path: String) -> Bool { heifExtensions.contains(extensionOf(path)) }

    /// The photo files among `paths` (files dropped, say), in their order, each once (letter case aside).
    public static func photoFiles(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { isPhotoFile($0) && seen.insert($0.lowercased()).inserted }
    }

    /// Whether photos can be imported with these settings: the document queue collects them.
    public static func isOffered(_ settings: ScanSettings) -> Bool {
        TaskCatalog.flow(of: settings) == .documentQueue
    }

    /// The photo the right way up: `stored` mirrored and turned as `orientation` says.
    public static func oriented(_ stored: RgbaImage, orientation: PhotoOrientation) -> RgbaImage {
        let image = orientation.mirrored ? mirroredLeftToRight(stored) : stored
        return orientation.quarterTurns % 4 == 0 ? image : image.rotatedQuarterTurns(orientation.quarterTurns)
    }

    /// What to do with `photo` (upright): the page looked for, then `plan(_:width:height:)`.
    public static func plan(_ photo: RgbaImage) -> PhotoImportPlan {
        plan(PhotoDocumentDetector.detect(photo), width: photo.width, height: photo.height)
    }

    /// What to do with a photo of `width` × `height` where the page search found `detection`: a page
    /// found with at least `sureConfidence` (and that can be corrected) is corrected; anything else is
    /// shown in the corner editor, starting from the page found, else the best outline seen (kept
    /// within the photo), else a rectangle `startInset` in from the photo's edges.
    public static func plan(_ detection: PhotoDocumentDetection, width: Int, height: Int) -> PhotoImportPlan {
        if let quad = detection.quad {
            let sure = detection.confidence >= sureConfidence
                && PerspectiveCorrector.plan(quad, imageWidth: width, imageHeight: height) != nil
            return sure
                ? PhotoImportPlan(action: .correct, corners: quad, reason: .none, detection: detection)
                : PhotoImportPlan(action: .review, corners: clampedToPhoto(quad, width: width, height: height),
                                  reason: .unsure, detection: detection)
        }
        let reason: PhotoReviewReason
        switch detection.rejection {
        case .cutOff: reason = .cutOff
        case .ambiguous: reason = .twoPages
        case .lowConfidence: reason = .unsure
        default: reason = .nothingFound
        }
        let start = detection.candidate.map { clampedToPhoto($0, width: width, height: height) }
            ?? startCorners(width: width, height: height)
        return PhotoImportPlan(action: .review, corners: start, reason: reason, detection: detection)
    }

    /// The corners of the whole photo.
    public static func wholePhoto(width: Int, height: Int) -> Quad {
        let w = Double(width), h = Double(height)
        return Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: w, y: 0),
                    bottomRight: CGPoint(x: w, y: h), bottomLeft: CGPoint(x: 0, y: h))
    }

    /// The editor's start when nothing was found: a rectangle `startInset` of the photo in from each edge.
    public static func startCorners(width: Int, height: Int) -> Quad {
        let w = Double(width), h = Double(height)
        let dx = w * startInset, dy = h * startInset
        return Quad(topLeft: CGPoint(x: dx, y: dy), topRight: CGPoint(x: w - dx, y: dy),
                    bottomRight: CGPoint(x: w - dx, y: h - dy), bottomLeft: CGPoint(x: dx, y: h - dy))
    }

    /// `quad` with every corner moved into the photo (the editor's handles stay where they can be
    /// seen and dragged); `startCorners` when that leaves no usable outline.
    public static func clampedToPhoto(_ quad: Quad, width: Int, height: Int) -> Quad {
        let c = quad.corners.map { clamp($0, width: Double(width), height: Double(height)) }
        let clamped = Quad(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3])
        return canUseCorners(clamped) ? clamped : startCorners(width: width, height: height)
    }

    /// The corners the editor can cut a page out along: running clockwise around a convex outline,
    /// every edge at least `minEdgePixels` long.
    public static func canUseCorners(_ quad: Quad) -> Bool {
        guard quad.isConvex else { return false }
        for i in 0..<4 where !(quad.edgeLength(i) >= minEdgePixels) {
            return false
        }
        return true
    }

    /// `quad` with corner `index` (0 top-left … 3 bottom-left, as placed) moved to `to`, kept within
    /// the photo; the quad as it was when the move would leave corners the page cannot be cut out along
    /// (`canUseCorners`). The corners keep their places in the quad while they are dragged;
    /// `Quad.fromCorners` names them again when the page is cut out.
    public static func movedCorner(_ quad: Quad, index: Int, to: CGPoint, width: Int, height: Int) -> Quad {
        var corners = quad.corners
        corners[index & 3] = clamp(to, width: Double(width), height: Double(height))
        let moved = Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
        return canUseCorners(moved) ? moved : quad
    }

    /// The resolution of a page from a photo: `dpi` (from the paper size its shape matched,
    /// `PerspectivePlan.dpi`) rounded and kept within `minDPI` to `maxDPI`; `nominalDPI` when the size
    /// is not known.
    public static func pageDPI(_ dpi: Double?) -> Int {
        guard let d = dpi, d.isFinite, d > 0 else { return nominalDPI }
        return min(max(Int((d + 0.5).rounded(.down)), minDPI), maxDPI)
    }

    /// The resolution of a whole photo taken as the page: from a paper size its shape matches, else `nominalDPI`.
    public static func wholePhotoDPI(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return nominalDPI }
        let longSide = Double(max(width, height)), shortSide = Double(min(width, height))
        guard let paper = PerspectiveCorrector.matchPaper(longSide / shortSide),
              let inches = PaperSizes.inches(paper.size) else { return nominalDPI }
        return pageDPI(longSide / max(Double(inches.width), Double(inches.height)))
    }

    /// The page cut out of `photo` along `corners` (named again with `Quad.fromCorners`), its
    /// perspective corrected, at `pageDPI`: a color page from a photo (`PageSource.photo`) whose other
    /// version is the photo as it was (`ScannedPage.withGeometry`, `GeometryBasis.perspective`). nil when
    /// the corners outline no page (or the pixels cannot be made into images).
    public static func correctedPage(_ photo: RgbaImage, corners: Quad, createdAt: Date = Date()) -> ScannedPage? {
        let named = Quad.fromCorners(corners.corners)
        guard let corrected = PerspectiveCorrector.correct(photo, quad: named),
              let photoImage = photo.makeCGImage(), let pageImage = corrected.image.makeCGImage() else { return nil }
        var page = ScannedPage(image: photoImage, dpi: pageDPI(corrected.plan.dpi), colorMode: .color, createdAt: createdAt)
        page.source = .photo
        return page.withGeometry(pageImage, geometry: PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective))
    }

    /// The whole photo as the page (`wholePhotoDPI`), labelled as a photo, with no other version; nil
    /// when the pixels cannot be made into an image.
    public static func wholePhotoPage(_ photo: RgbaImage, createdAt: Date = Date()) -> ScannedPage? {
        guard let image = photo.makeCGImage() else { return nil }
        var page = ScannedPage(image: image, dpi: wholePhotoDPI(width: photo.width, height: photo.height),
                               colorMode: .color, createdAt: createdAt)
        page.source = .photo
        return page
    }

    /// "Photo" for a page taken from a photo, "From phone" for one a paired phone sent; nil for other pages.
    public static func sourceLabel(_ page: ScannedPage) -> String? {
        switch page.source {
        case .photo: return label
        case .phone: return CompanionProtocol.pageLabel
        case .scanner: return nil
        }
    }

    /// The source label's tooltip: where a photo's or a phone's page came from; nil for other pages.
    public static func sourceHelp(_ page: ScannedPage) -> String? {
        switch page.source {
        case .photo: return labelHelp
        case .phone: return CompanionProtocol.pageLabelHelp
        case .scanner: return nil
        }
    }

    /// The corner editor's note on why it is shown; empty for `.none`.
    public static func reasonText(_ reason: PhotoReviewReason) -> String {
        switch reason {
        case .unsure: return "The page edges are unclear."
        case .cutOff: return "The page runs off the photo."
        case .twoPages: return "Two pages found: pick one."
        case .nothingFound: return "No page found in this photo."
        case .none: return ""
        }
    }

    /// The corner editor's caption: "Photo 2 of 5" (the file name is its tooltip), or the file name alone
    /// for one photo.
    public static func counter(_ number: Int, of count: Int, fileName: String) -> String {
        count > 1 ? "Photo \(number) of \(count)" : fileName
    }

    /// The caption with the file name, for its tooltip and VoiceOver: "Photo 2 of 5: IMG_0042.jpg".
    public static func counterName(_ number: Int, of count: Int, fileName: String) -> String {
        count > 1 ? "Photo \(number) of \(count): \(fileName)" : fileName
    }

    /// "Importing photo 2 of 5…", or "Importing photo…" for one.
    public static func progressMessage(_ number: Int, of count: Int) -> String {
        count > 1 ? "Importing photo \(number) of \(count)\u{2026}" : "Importing photo\u{2026}"
    }

    /// The progress while page `page` of a file of `pageCount` pages (a TIFF of several pages) is
    /// imported: "Importing photo 2 of 5, page 3 of 7…", or "Importing page 3 of 7…" for one file;
    /// `progressMessage(_:of:)` for a file of one page.
    public static func progressMessage(_ number: Int, of count: Int, page: Int, pageCount: Int) -> String {
        if pageCount <= 1 { return progressMessage(number, of: count) }
        return count > 1
            ? "Importing photo \(number) of \(count), page \(page) of \(pageCount)\u{2026}"
            : "Importing page \(page) of \(pageCount)\u{2026}"
    }

    /// The name of page `page` of a file of `pageCount` pages, for the corner editor and the error
    /// messages: "fax.tif, page 2 of 5", or the file name alone for one page.
    public static func pageName(_ fileName: String, page: Int, pageCount: Int) -> String {
        pageCount > 1 ? "\(fileName), page \(page) of \(pageCount)" : fileName
    }

    /// The status after an import: "Added 3 pages from photos — 5 in queue. Scan more or save PDF."
    /// (or "No pages were added."), then " 1 photo was skipped." and " 2 photos could not be opened."
    /// when that happened.
    public static func addedMessage(added: Int, skipped: Int, failed: Int, queueCount: Int, saveTitle: String) -> String {
        var text = added > 0
            ? "Added \(added) page\(added == 1 ? "" : "s") from photos \u{2014} \(queueCount) in queue. Scan more or \(saveTitle)."
            : "No pages were added."
        if skipped > 0 { text += " \(skipped) photo\(skipped == 1 ? " was" : "s were") skipped." }
        if failed > 0 { text += " \(failed) photo\(failed == 1 ? "" : "s") could not be opened." }
        return text
    }

    /// The status after an import was cancelled: "Cancelled." or "Cancelled after adding 2 pages from photos — 4 in queue."
    public static func cancelledMessage(added: Int, queueCount: Int) -> String {
        added == 0
            ? "Cancelled."
            : "Cancelled after adding \(added) page\(added == 1 ? "" : "s") from photos \u{2014} \(queueCount) in queue."
    }

    /// "IMG_0042.jpg could not be opened: …".
    public static func unreadableMessage(_ fileName: String, detail: String) -> String {
        "\(fileName) could not be opened: \(detail)"
    }

    /// A HEIF photo Windows could not read: most often the HEIF extension (or the HEVC one) is missing, else
    /// the file is damaged. The Mac reads HEIF itself (ImageIO), so it never shows this; it is here so both
    /// platforms keep the same words.
    public static func heifUnavailableMessage(_ fileName: String) -> String {
        "\(fileName) could not be opened: HEIC photos need the free \u{201C}HEIF Image Extensions\u{201D} from the Microsoft Store "
            + "(most iPhone photos also need \u{201C}HEVC Video Extensions\u{201D}). If they are installed, the photo may be damaged; "
            + "a phone set to save photos as JPEG avoids this."
    }

    /// The lowercase extension of `path`, without the dot.
    private static func extensionOf(_ path: String) -> String {
        let characters = Array(path)
        var slash = -1, dot = -1
        for (index, character) in characters.enumerated() {
            if character == "/" || character == "\\" { slash = index }
            if character == "." { dot = index }
        }
        guard dot > slash, dot < characters.count - 1 else { return "" }
        return String(characters[(dot + 1)...]).lowercased()
    }

    private static func clamp(_ p: CGPoint, width: Double, height: Double) -> CGPoint {
        CGPoint(x: min(max(Double(p.x), 0), width), y: min(max(Double(p.y), 0), height))
    }

    /// The image mirrored left to right.
    private static func mirroredLeftToRight(_ image: RgbaImage) -> RgbaImage {
        let w = image.width, h = image.height
        var output = [UInt8](repeating: 0, count: image.pixels.count)
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w {
                let si = row + x * 4, di = row + (w - 1 - x) * 4
                output[di] = image.pixels[si]
                output[di + 1] = image.pixels[si + 1]
                output[di + 2] = image.pixels[si + 2]
                output[di + 3] = image.pixels[si + 3]
            }
        }
        return RgbaImage(width: w, height: h, pixels: output)
    }
}
