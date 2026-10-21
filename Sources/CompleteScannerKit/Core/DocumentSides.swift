import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/DocumentSides.cs: which page is which side of which sheet
// in a two-sided scan, and putting pages in reading order. The one collation helper for feeders
// that scan both sides and for stacks turned over by hand.

/// A side of a sheet.
public enum PageSide: String, Sendable {
    case front
    case back
}

/// Where one transfer of a feeder scan belongs: its sheet and side. `transferIndex` is the
/// position in the order the scanner delivered the pages.
public struct SidedTransfer: Equatable, Sendable {
    public let transferIndex: Int
    public let sheetIndex: Int
    public let side: PageSide

    public init(transferIndex: Int, sheetIndex: Int, side: PageSide) {
        self.transferIndex = transferIndex
        self.sheetIndex = sheetIndex
        self.side = side
    }
}

/// One page of a stack turned over by hand, in reading order: the scan it came from (`.front`
/// for the fronts, `.back` for the backs), its position within that scan, and the sheet it is
/// assigned to.
public struct ManualPage: Equatable, Sendable {
    public let batch: PageSide
    public let index: Int
    public let sheetIndex: Int

    public init(batch: PageSide, index: Int, sheetIndex: Int) {
        self.batch = batch
        self.index = index
        self.sheetIndex = sheetIndex
    }
}

/// The reading order of fronts and backs scanned separately. When the counts differ the pages
/// still come in an order (the leftovers at the end), and `mismatch` says so.
public struct ManualInterleave: Equatable, Sendable {
    public let order: [ManualPage]
    public let fronts: Int
    public let backs: Int

    /// The fronts and backs do not pair up: a sheet was skipped, doubled or left out.
    public var mismatch: Bool { fronts != backs }

    /// "12 fronts but 11 backs" when the counts differ; nil when they pair up.
    public var mismatchMessage: String? { mismatch ? DocumentSides.countMessage(fronts: fronts, backs: backs) : nil }
}

/// A page's place in a two-sided stack.
public struct SheetPosition: Equatable, Hashable, Sendable {
    public let sheetIndex: Int
    public let side: PageSide

    public init(sheetIndex: Int, side: PageSide) {
        self.sheetIndex = sheetIndex
        self.side = side
    }
}

/// The page queue with a stack's fronts and backs put in reading order (see
/// `DocumentSides.collateQueue`), where each of those pages now sits, and how the counts paired up.
public struct QueueCollation: Equatable, Sendable {
    public let order: [UUID]
    public let positions: [UUID: SheetPosition]
    public let interleave: ManualInterleave
}

public enum DocumentSides {
    /// Why the sides cannot be chosen while the flatbed is the source.
    public static let feederOnlyReason = "Two-sided scanning uses the document feeder."

    /// The short reason shown next to Sides while the flatbed of a scanner with a feeder is the source.
    public static let needsFeederReason = "Needs the feeder"

    /// Why "Both sides" is not offered: the feeder cannot scan both sides in one pass.
    public static let oneSidedFeederReason =
        "This scanner's feeder scans one side at a time. To scan both sides, turn the stack over by hand."

    /// The step that scans the fronts of a stack turned over by hand.
    public static let frontsStepID = "fronts"
    /// The step that scans the backs, after the stack was turned over.
    public static let backsStepID = "backs"

    /// The guided steps of turning a stack over by hand: scan the fronts, turn the stack over,
    /// scan the backs. Every page is a capture, so both steps repeat; the backs can be left out
    /// ("Keep fronts only").
    public static let manualSteps: [TaskStep] = [
        TaskStep(id: frontsStepID, title: "Scan the front sides",
                 prompt: "Load the stack in the feeder and scan the fronts.",
                 primaryActionLabel: "Scan fronts", repeats: true,
                 help: "Only the front of each sheet is scanned this time."),
        TaskStep(id: backsStepID, title: "Scan the back sides",
                 prompt: "Turn the stack over, load it again and scan.",
                 primaryActionLabel: "Scan backs", skippable: true, repeats: true, requiresCapture: false,
                 help: "Take the stack from the output tray and turn it over as a whole, keeping the sheets in order. Then scan the back sides."),
    ]

    /// The sheet and side of each transfer of a feeder scan, in reading order (by sheet, the
    /// front first). One-sided: transfer k is the front of sheet k. Two-sided: transfers come as
    /// front, back, front, back; an odd last transfer is a sheet with only its front.
    /// `reverseOrder`: the feeder delivers the last sheet first (ImageCaptureCore's
    /// reverseFeederPageOrder), so the sheets are numbered from the end, keeping each sheet's
    /// front before its back.
    public static func assignSides(transferCount: Int, duplex: Bool, reverseOrder: Bool = false) -> [SidedTransfer] {
        let count = max(0, transferCount)
        let sheets = duplex ? (count + 1) / 2 : count
        var result: [SidedTransfer] = []
        for k in 0..<count {
            let scanned = duplex ? k / 2 : k
            let side: PageSide = duplex && k % 2 == 1 ? .back : .front
            let sheet = reverseOrder ? sheets - 1 - scanned : scanned
            result.append(SidedTransfer(transferIndex: k, sheetIndex: sheet, side: side))
        }
        // Stable order: by sheet, the front before the back.
        return result.sorted { a, b in
            if a.sheetIndex != b.sheetIndex { return a.sheetIndex < b.sheetIndex }
            return a.side == .front && b.side == .back
        }
    }

    /// Fronts and backs scanned separately, put in reading order: sheet i's front, then its back.
    /// Turning the stack over reverses it, so with `backsReversed` the back of sheet i is the
    /// (n−1−i)-th back scanned. Counts that differ are paired as far as they go; the remaining
    /// fronts, then the remaining backs, follow as sheets of their own, and the result says the
    /// counts did not match.
    public static func interleaveManual(fronts: Int, backs: Int, backsReversed: Bool = true) -> ManualInterleave {
        let f = max(0, fronts), b = max(0, backs)
        var order: [ManualPage] = []
        for sheet in 0..<max(f, b) {
            if sheet < f { order.append(ManualPage(batch: .front, index: sheet, sheetIndex: sheet)) }
            if sheet < b {
                order.append(ManualPage(batch: .back, index: backsReversed ? b - 1 - sheet : sheet, sheetIndex: sheet))
            }
        }
        return ManualInterleave(order: order, fronts: f, backs: b)
    }

    /// Quarter turns (clockwise) that put a back side upright: 2 for short-edge sheets, 0 for long-edge ones.
    public static func backQuarterTurns(_ binding: DuplexBinding) -> Int {
        binding == .shortEdge ? 2 : 0
    }

    /// How a scan with these settings captures the sheets: `.off` unless the feeder is the
    /// source; a two-sided scan by a feeder that cannot do it is done by hand. Unknown
    /// capabilities (nil) leave the choice as it is.
    public static func effective(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> DuplexMode {
        guard settings.source == .documentFeeder, settings.duplex != .off else { return .off }
        if settings.duplex == .both, let capabilities, !capabilities.supportsDuplex { return .manual }
        return settings.duplex
    }

    /// The capabilities to decide the sides with (`effective`, `SettingsAdapter.adapt`, the
    /// steps). While it is not known whether the feeder scans both sides (`duplexKnown` false:
    /// ImageCaptureCore tells only once the feeder is selected), a scanner with a feeder is taken
    /// to scan both, so "Both sides" stays chosen until the scanner says otherwise; the scan then
    /// reports what it did (`ScannerSession.lastScanDuplex`). Otherwise unchanged.
    public static func capabilitiesForSides(_ capabilities: ScannerCapabilities?,
                                            duplexKnown: Bool) -> ScannerCapabilities? {
        guard !duplexKnown, var assumed = capabilities, !assumed.supportsDuplex,
              assumed.sources.contains(.documentFeeder) else { return capabilities }
        assumed.supportsDuplex = true
        return assumed
    }

    /// The stack is turned over by hand and the app guides it (`manualSteps`): a two-sided
    /// feeder scan done by hand, whose pages go to the queue to be saved together.
    public static func usesManualSteps(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> Bool {
        effective(settings, capabilities: capabilities) == .manual
            && TaskCatalog.flow(of: settings) == .documentQueue
            && settings.documentMultiPage
    }

    /// Why turning over by hand cannot be guided with these settings; nil when it can (also when
    /// the settings do not ask for it).
    public static func manualUnavailableReason(_ settings: ScanSettings) -> String? {
        let flow = TaskCatalog.flow(of: settings)
        if flow == .copy {
            return "Copies are made from one side of each sheet; turn the stack over and copy again."
        }
        if flow != .documentQueue {
            return "Turning the stack over by hand works for documents, not photos."
        }
        if !settings.documentMultiPage {
            return "Turning the stack over by hand needs \u{201C}Collect pages, then \(settings.format.saveTitle)\u{201D}."
        }
        return nil
    }

    /// The badge on the thumbnail of a page of a two-sided stack: "2 · back" (sheet 2), or "Front" /
    /// "Back" before its sheet is known; nil for a page without a side.
    public static func sideLabel(side: PageSide?, sheetIndex: Int?) -> String? {
        guard let side else { return nil }
        guard let sheetIndex else { return side == .front ? "Front" : "Back" }
        let word: String = side == .front ? "front" : "back"
        return "\(sheetIndex + 1) \u{00B7} \(word)"
    }

    /// The badge spelled out for VoiceOver: "Sheet 2, back", or "Front" / "Back"; nil for a page without a side.
    public static func sideName(side: PageSide?, sheetIndex: Int?) -> String? {
        guard let side else { return nil }
        guard let sheetIndex else { return side == .front ? "Front" : "Back" }
        let word: String = side == .front ? "front" : "back"
        return "Sheet \(sheetIndex + 1), \(word)"
    }

    /// "3 fronts but 2 backs", "1 front but 2 backs".
    public static func countMessage(fronts: Int, backs: Int) -> String {
        "\(fronts) front\(fronts == 1 ? "" : "s") but \(backs) back\(backs == 1 ? "" : "s")"
    }

    /// The pages of a two-sided feeder scan (front, back, front, back… as delivered), in reading
    /// order, each marked with its sheet and side; the backs are turned upright for `binding`.
    public static func arrangeTwoSided(_ pages: [ScannedPage], binding: DuplexBinding,
                                       reverseOrder: Bool = false) -> [ScannedPage] {
        let turns = backQuarterTurns(binding)
        return assignSides(transferCount: pages.count, duplex: true, reverseOrder: reverseOrder).map { transfer in
            mark(pages[transfer.transferIndex], side: transfer.side, sheet: transfer.sheetIndex, turns: turns)
        }
    }

    /// The pages of one scan of a stack turned over by hand, marked as fronts or backs; backs are
    /// turned upright for `binding`. Their sheets are known only once the two scans are put
    /// together (`collateQueue`).
    public static func markManual(_ pages: [ScannedPage], side: PageSide, binding: DuplexBinding) -> [ScannedPage] {
        let turns = side == .back ? backQuarterTurns(binding) : 0
        return pages.map { mark($0, side: side, sheet: nil, turns: turns) }
    }

    private static func mark(_ page: ScannedPage, side: PageSide, sheet: Int?, turns: Int) -> ScannedPage {
        let marked = page.withSide(side, sheetIndex: sheet)
        guard side == .back, turns % 4 != 0 else { return marked }
        let rotated = ImagePipeline.rotate(page.image, quarterTurns: turns)
        guard let fileURL = page.fileURL else { return marked.withImage(rotated) }
        // A spooled page: its preview turns now, its full-resolution file when it is saved.
        var turned = marked.withImage(rotated, fileURL: fileURL, fullPixelSize: page.fullPixelSize)
        turned.rotationQuarterTurns = (turned.rotationQuarterTurns + turns) % 4
        return turned
    }

    /// The page queue with a stack's fronts and backs (page ids in scan order) put in reading
    /// order (`interleaveManual`). Pages no longer in the queue are left out. The stack takes the
    /// place of its first page in the queue; the other pages keep their order around it.
    /// `positions` gives each stack page its sheet and side.
    public static func collateQueue(_ queue: [UUID], fronts: [UUID], backs: [UUID],
                                    backsReversed: Bool = true) -> QueueCollation {
        let present = Set(queue)
        var f: [UUID] = []
        for id in fronts where present.contains(id) && !f.contains(id) { f.append(id) }
        var stackSet = Set(f)
        var b: [UUID] = []
        for id in backs where present.contains(id) && !stackSet.contains(id) && !b.contains(id) { b.append(id) }
        stackSet.formUnion(b)

        let interleave = interleaveManual(fronts: f.count, backs: b.count, backsReversed: backsReversed)
        var stack: [UUID] = []
        var positions: [UUID: SheetPosition] = [:]
        for page in interleave.order {
            let id = page.batch == .front ? f[page.index] : b[page.index]
            stack.append(id)
            positions[id] = SheetPosition(sheetIndex: page.sheetIndex, side: page.batch)
        }

        var order: [UUID] = []
        var placed = false
        for id in queue {
            if !stackSet.contains(id) {
                order.append(id)
            } else if !placed {
                order.append(contentsOf: stack)
                placed = true
            }
        }
        return QueueCollation(order: order, positions: positions, interleave: interleave)
    }
}
