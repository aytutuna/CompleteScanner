#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation

/// What the iPhone's corner editor shows and does, without a screen: the photo fitted into the view,
/// the four corners (in the photo's pixels, top-left origin) and which one a finger moves, where the
/// magnifier sits, and the editor's answers. The same rules as the Mac's `PhotoCornersEditorView`
/// (`PhotoImport.movedCorner` keeps the corners in the photo and on a convex outline; the magnifier
/// sits diagonally away from the page's middle), adapted to touch: a larger handle to hit, and a corner
/// moves by how far the finger moves, so it is never hidden under the finger.
struct CornerEditorModel: Equatable {
    /// How far from a handle's center a touch still takes it (points).
    static let handleHitRadius: CGFloat = 36
    /// The magnifier's diameter (points), its zoom over the fitted photo, and its gap from the corner.
    static let loupeSize: CGFloat = 120
    static let loupeZoom: CGFloat = 2.5
    static let loupeGap: CGFloat = 28
    /// The margin around the fitted photo (points), so a handle on the photo's edge can be reached.
    static let inset: CGFloat = 24

    let photoWidth: Int
    let photoHeight: Int
    /// The corners the editor opened with, for Reset.
    let start: Quad
    /// The corners as placed (0 top-left … 3 bottom-left, as placed).
    private(set) var corners: Quad
    /// The corner the magnifier shows and the last one moved.
    private(set) var selected: Int = 0
    /// The corner a finger is moving, if any.
    private(set) var dragging: Int?
    /// Where the moved corner was when the finger came down, in the photo's pixels.
    private var dragOrigin: CGPoint = .zero

    init(photoWidth: Int, photoHeight: Int, corners: Quad) {
        self.photoWidth = max(photoWidth, 1)
        self.photoHeight = max(photoHeight, 1)
        self.start = corners
        self.corners = corners
    }

    init(request: PhotoCornersRequest) {
        self.init(photoWidth: request.photo.width, photoHeight: request.photo.height, corners: request.plan.corners)
    }

    /// The magnifier shows while a corner is moved.
    var showsLoupe: Bool { dragging != nil }

    /// Reset would change the corners.
    var canReset: Bool { corners != start }

    /// The page can be cut out along the corners (`PhotoImport.canUseCorners`).
    var canUseCorners: Bool { PhotoImport.canUseCorners(corners) }

    /// The answer of Use corners.
    var useCornersAnswer: PhotoCornersAnswer { PhotoCornersAnswer(choice: .useCorners, corners: corners) }

    /// Back to the corners the editor opened with.
    mutating func reset() {
        corners = start
        dragging = nil
    }

    // MARK: Fitting the photo

    /// The photo fitted into a view of `size`, `inset` in from each side, centered (aspect fit).
    func fittedFrame(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: CornerEditorModel.inset, dy: CornerEditorModel.inset)
        guard bounds.width > 0, bounds.height > 0 else { return CGRect(origin: .zero, size: .zero) }
        let w: CGFloat = CGFloat(photoWidth)
        let h: CGFloat = CGFloat(photoHeight)
        let scale: CGFloat = min(bounds.width / w, bounds.height / h)
        let fittedWidth: CGFloat = w * scale
        let fittedHeight: CGFloat = h * scale
        return CGRect(x: bounds.midX - fittedWidth / 2, y: bounds.midY - fittedHeight / 2,
                      width: fittedWidth, height: fittedHeight)
    }

    /// A point of the photo (pixels) in the view.
    func viewPoint(_ imagePoint: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + imagePoint.x / CGFloat(photoWidth) * frame.width,
                y: frame.minY + imagePoint.y / CGFloat(photoHeight) * frame.height)
    }

    /// A point of the view in the photo (pixels).
    func imagePoint(_ viewPoint: CGPoint, frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - frame.minX) / frame.width * CGFloat(photoWidth),
                       y: (viewPoint.y - frame.minY) / frame.height * CGFloat(photoHeight))
    }

    /// The corners in the view, in order.
    func viewCorners(frame: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        for index in 0..<4 {
            points.append(viewPoint(corners[index], frame: frame))
        }
        return points
    }

    // MARK: Moving a corner

    /// The corner whose handle is under `location` (the nearest when handles overlap); nil for none.
    func handle(at location: CGPoint, frame: CGRect) -> Int? {
        var best: Int?
        var bestDistance: CGFloat = CornerEditorModel.handleHitRadius
        for index in 0..<4 {
            let point: CGPoint = viewPoint(corners[index], frame: frame)
            let distance: CGFloat = hypot(point.x - location.x, point.y - location.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// A finger came down at `location`: the corner under it, if any, starts moving. False when no
    /// handle is there.
    @discardableResult
    mutating func beginDrag(at location: CGPoint, frame: CGRect) -> Bool {
        guard let index = handle(at: location, frame: frame) else { return false }
        dragging = index
        selected = index
        dragOrigin = corners[index]
        return true
    }

    /// The finger that came down at `start` is at `location`: the corner moves by as much (in the
    /// photo's pixels), kept within the photo and on a convex outline (`PhotoImport.movedCorner`).
    mutating func drag(from start: CGPoint, to location: CGPoint, frame: CGRect) {
        guard let index = dragging, frame.width > 0, frame.height > 0 else { return }
        let dx: CGFloat = (location.x - start.x) / frame.width * CGFloat(photoWidth)
        let dy: CGFloat = (location.y - start.y) / frame.height * CGFloat(photoHeight)
        let target = CGPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy)
        corners = PhotoImport.movedCorner(corners, index: index, to: target, width: photoWidth, height: photoHeight)
    }

    /// The finger lifted.
    mutating func endDrag() {
        dragging = nil
    }

    // MARK: The magnifier

    /// Where the magnifier's center sits for the selected corner in a view of `size`: diagonally away
    /// from the page's middle, else the first other diagonal that keeps it in the view (the Mac's rule).
    func loupeCenter(frame: CGRect, in size: CGSize) -> CGPoint {
        let points: [CGPoint] = viewCorners(frame: frame)
        let corner: CGPoint = points[selected]
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in points {
            sumX += point.x
            sumY += point.y
        }
        let middle = CGPoint(x: sumX / 4, y: sumY / 4)
        return CornerEditorModel.loupeCenter(corner: corner, middle: middle, in: size)
    }

    /// The magnifier's center for `corner` of a page whose middle is `middle`, in a view of `size`.
    static func loupeCenter(corner: CGPoint, middle: CGPoint, in size: CGSize) -> CGPoint {
        let dx: CGFloat = corner.x >= middle.x ? 1 : -1
        let dy: CGFloat = corner.y >= middle.y ? 1 : -1
        let reach: CGFloat = loupeSize / 2 + loupeGap
        let signsX: [CGFloat] = [dx, -dx, dx, -dx]
        let signsY: [CGFloat] = [dy, dy, -dy, -dy]
        let half: CGFloat = loupeSize / 2
        var last = CGPoint.zero
        for index in 0..<4 {
            let candidate = CGPoint(x: corner.x + signsX[index] * reach, y: corner.y + signsY[index] * reach)
            let fitsX: Bool = candidate.x - half >= 0 && candidate.x + half <= size.width
            let fitsY: Bool = candidate.y - half >= 0 && candidate.y + half <= size.height
            if fitsX && fitsY { return candidate }
            last = candidate
        }
        return last
    }

    /// The offset of the magnified photo inside the magnifier, so the selected corner is at its center.
    func loupeImageOffset(frame: CGRect) -> CGSize {
        let corner: CGPoint = viewPoint(corners[selected], frame: frame)
        let zoom: CGFloat = CornerEditorModel.loupeZoom
        return CGSize(width: CornerEditorModel.loupeSize / 2 - (corner.x - frame.minX) * zoom,
                      height: CornerEditorModel.loupeSize / 2 - (corner.y - frame.minY) * zoom)
    }

    /// The name of place `index` on an outline (0 top left … 3 bottom left).
    static func cornerName(_ index: Int) -> String {
        switch index & 3 {
        case 0: return "Top left corner"
        case 1: return "Top right corner"
        case 2: return "Bottom right corner"
        default: return "Bottom left corner"
        }
    }

    /// VoiceOver's name for corner `index`, from where it sits now: its place once the outline's corners
    /// are named again (`Quad.fromCorners`), so a corner dragged round to the page's top right is read as
    /// the top right one. Each corner gets a name of its own, also when two of them meet.
    func cornerLabel(_ index: Int) -> String {
        let points: [CGPoint] = corners.corners
        let named: [CGPoint] = Quad.fromCorners(points).corners
        let wanted: Int = index & 3
        var taken: [Bool] = [false, false, false, false]
        var place: Int = wanted
        for slot in 0..<4 {
            var original: Int = 0
            while original < 4 {
                if !taken[original] && points[original] == named[slot] {
                    taken[original] = true
                    if original == wanted {
                        place = slot
                    }
                    break
                }
                original += 1
            }
        }
        return CornerEditorModel.cornerName(place)
    }

    /// VoiceOver's value for corner `index`: where it is, in percent of the photo's width and height,
    /// "12 percent from the left, 8 percent from the top"; read again after each step, so a step that
    /// the photo's edge stopped is heard too.
    func cornerValue(_ index: Int) -> String {
        let point: CGPoint = corners[index & 3]
        let left: Int = Int((Double(point.x) / Double(photoWidth) * 100).rounded())
        let top: Int = Int((Double(point.y) / Double(photoHeight) * 100).rounded())
        return "\(left) percent from the left, \(top) percent from the top"
    }

    /// Corner `index` moved one step with VoiceOver's swipe up or down: `outward` away from the page's
    /// middle, else towards it, a hundredth of the photo's long side along both axes.
    mutating func nudge(_ index: Int, outward: Bool) {
        let points: [CGPoint] = corners.corners
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in points {
            sumX += point.x
            sumY += point.y
        }
        let at: CGPoint = corners[index & 3]
        let step: CGFloat = CGFloat(max(photoWidth, photoHeight)) / 100
        let sign: CGFloat = outward ? 1 : -1
        let dx: CGFloat = at.x >= sumX / 4 ? sign * step : -sign * step
        let dy: CGFloat = at.y >= sumY / 4 ? sign * step : -sign * step
        selected = index & 3
        corners = PhotoImport.movedCorner(corners, index: index & 3, to: CGPoint(x: at.x + dx, y: at.y + dy),
                                          width: photoWidth, height: photoHeight)
    }
}
#endif
