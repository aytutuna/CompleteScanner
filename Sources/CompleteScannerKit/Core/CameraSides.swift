import Foundation

/// How the iPhone's camera takes both sides of each sheet in the two-sided task (I14), as
/// `TaskOptions.cameraFrontsFirst` says.
public enum CameraSidesMode: String, Sendable {
    /// Flip & capture: each front, then its back, the sheet turned over between the two shots.
    case flip
    /// Every front first, then every back, first sheet first; put in order with the manual interleave.
    case frontsFirst
}

/// Where the camera is in a two-sided stack (I14): the side the next shot is, the sheet it belongs to
/// (flip & capture knows it at once), and the fronts and backs taken (fronts first, put in reading order
/// by `DocumentSides.collateQueue` once every back is in). The pages are marked with their side as they
/// come in (`ScanArrangement.cameraFront`, `.cameraBack`); a back is never turned for the binding, since
/// the user turned the sheet over and turning pages upright fixes it. Swift only: the Windows app takes
/// no camera shots.
public struct CameraSides: Equatable, Sendable {
    public let mode: CameraSidesMode
    /// The side the next shot is.
    public private(set) var next: PageSide = .front
    /// Flip & capture: the sheet the next shot belongs to, from 0.
    public private(set) var sheet: Int = 0
    /// Fronts first: the fronts taken, by page id, in the order taken.
    public private(set) var fronts: [UUID] = []
    /// Fronts first: the backs taken, by page id, in the order taken.
    public private(set) var backs: [UUID] = []
    /// Flip & capture: the pages of the last shot, which can be taken again once they are all removed.
    private var lastShot: [UUID] = []

    public init(mode: CameraSidesMode) {
        self.mode = mode
    }

    /// The way `options` take the sides.
    public static func mode(_ options: TaskOptions) -> CameraSidesMode {
        options.cameraFrontsFirst ? .frontsFirst : .flip
    }

    /// How the next shot's pages are marked.
    public var arrangement: ScanArrangement {
        next == .front ? .cameraFront : .cameraBack
    }

    /// The sheet the next shot's pages are given: flip & capture's; nil for fronts first, whose sheets are
    /// known once the stack is put in order.
    public var sheetForNext: Int? {
        mode == .flip ? sheet : nil
    }

    /// The pages of a shot (`ids`) came in as `next`: flip & capture asks for the back after a front and
    /// for the next sheet's front after a back; fronts first records them.
    public mutating func took(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        switch mode {
        case .flip:
            lastShot = ids
            if next == .front {
                next = .back
            } else {
                next = .front
                sheet += 1
            }
        case .frontsFirst:
            if next == .front {
                fronts.append(contentsOf: ids)
            } else {
                backs.append(contentsOf: ids)
            }
        }
    }

    /// Flip & capture waits for a back, which can be left out (an empty back).
    public var canSkipBack: Bool {
        mode == .flip && next == .back
    }

    /// No back: the next shot is the next sheet's front.
    public mutating func skipBack() {
        guard canSkipBack else { return }
        next = .front
        sheet += 1
        lastShot = []
    }

    /// The page `id` left the queue. Flip & capture steps back once every page of the last shot is gone,
    /// so the shot taken again is the same side of the same sheet; fronts first forgets the page.
    public mutating func removed(_ id: UUID) {
        switch mode {
        case .flip:
            guard let index = lastShot.firstIndex(of: id) else { return }
            lastShot.remove(at: index)
            guard lastShot.isEmpty else { return }
            if next == .back {
                next = .front
            } else {
                next = .back
                sheet -= 1
            }
        case .frontsFirst:
            fronts.removeAll { (front: UUID) -> Bool in front == id }
            backs.removeAll { (back: UUID) -> Bool in back == id }
        }
    }

    /// Fronts first, with fronts taken and the backs not started.
    public var canStartBacks: Bool {
        mode == .frontsFirst && next == .front && !fronts.isEmpty
    }

    /// Every front is in: the backs come next.
    public mutating func startBacks() {
        guard canStartBacks else { return }
        next = .back
    }

    /// Fronts first, some backs taken: the stack can be put in order before every back is in.
    public var canPutInOrder: Bool {
        mode == .frontsFirst && next == .back && !backs.isEmpty
    }

    /// Fronts first, as many backs as fronts: the stack is put in order by itself.
    public var hasEveryBack: Bool {
        mode == .frontsFirst && next == .back && !fronts.isEmpty && backs.count >= fronts.count
    }

    /// The fronts and backs of `queue` in reading order: sheet by sheet, the front before its back, the
    /// backs taken first sheet first (`DocumentSides.collateQueue`, not reversed); counts that differ are
    /// paired as far as they go and flagged (`ManualInterleave.mismatch`).
    public func collation(_ queue: [UUID]) -> QueueCollation {
        DocumentSides.collateQueue(queue, fronts: fronts, backs: backs, backsReversed: false)
    }

    /// Back to the first sheet's front, for the next stack.
    public mutating func reset() {
        next = .front
        sheet = 0
        fronts = []
        backs = []
        lastShot = []
    }
}
