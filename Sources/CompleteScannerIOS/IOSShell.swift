#if os(iOS)
import CompleteScannerKit
import Foundation

/// What the app was launched with. `-demoScanner` (the UI smoke test's) keeps the app on the demo
/// scanner alone: the iPhone has no other connection yet, and once it has (the camera, eSCL), a test
/// launched this way still scans the same made-up pages.
public struct IOSLaunchOptions: Equatable, Sendable {
    /// The launch argument for the demo scanner alone.
    public static let demoScannerArgument = "-demoScanner"

    /// Only the demo scanner is offered.
    public let demoScannerOnly: Bool

    public init(demoScannerOnly: Bool) {
        self.demoScannerOnly = demoScannerOnly
    }

    /// The options in the process's launch arguments.
    public init(arguments: [String]) {
        self.demoScannerOnly = arguments.contains(IOSLaunchOptions.demoScannerArgument)
    }
}

/// What the iPhone's and iPad's app shell passes `AppState`: its scanner connections, its file
/// actions and its lifecycle. Printing and the troubleshooter's links are not passed yet, so the
/// Kit's stand-ins refuse them (no printer, nothing opened or copied).
public enum IOSShell {
    /// The scanner connections: the demo scanner, whatever `options` say, since it is the only one
    /// the iPhone has so far.
    @MainActor
    public static func backends(options: IOSLaunchOptions) -> [any ScannerBackend] {
        let demo: MockScannerBackend = AppState.makeDemoBackend()
        let backends: [any ScannerBackend] = [demo]
        return backends
    }

    /// Whether this app offers a task yet: the tasks whose pages are collected and saved, without a
    /// review screen of their own. Photos, receipts and the ID card need their review screens, the
    /// photocopy a printer, and Quick scan an area chosen on the preview, which come later.
    public static func offers(_ task: ScanTask) -> Bool {
        if task == .quickScan { return false }
        return TaskCatalog.definition(task).flow == .documentQueue
    }

    /// Why a task is not offered yet: the tile's one visible line.
    public static let notYetReason = "Not in this version yet"

    /// Whether a start-screen tile can be picked, and if not, why: a task this app does not offer
    /// yet says so; otherwise the card's own availability (a scanner without a feeder, say).
    public static func availability(_ card: TaskCard) -> TaskAvailability {
        if !offers(card.definition.task) {
            return TaskAvailability(isAvailable: false, reason: notYetReason)
        }
        return card.availability
    }

    /// The start screen's groups (`TaskCatalog.sections`, in order) with a tile for each task card.
    public static func groups(_ cards: [TaskCard]) -> [IOSTaskGroup] {
        var result: [IOSTaskGroup] = []
        for section in TaskCatalog.sections {
            var tiles: [IOSTaskTile] = []
            for definition in section.definitions {
                guard let card = cards.first(where: { (candidate: TaskCard) -> Bool in
                    candidate.definition.task == definition.task
                }) else { continue }
                tiles.append(IOSTaskTile(card: card))
            }
            result.append(IOSTaskGroup(group: section.group, tiles: tiles))
        }
        return result
    }

    /// The SF Symbol for a task's icon key (`TaskDefinition.iconKey`), as on the Mac.
    public static func systemImage(_ iconKey: String) -> String {
        switch iconKey {
        case "document": return "doc.text"
        case "feeder": return "doc.on.doc"
        case "photos": return "photo.on.rectangle.angled"
        case "restore": return "wand.and.stars"
        case "quick": return "bolt"
        case "email": return "envelope"
        case "twoSided": return "arrow.left.arrow.right.square"
        case "idCard": return "person.text.rectangle"
        case "copy": return "printer"
        case "word": return "doc.richtext"
        case "receipt": return "receipt"
        case "batch": return "square.stack.3d.down.right"
        case "book": return "book"
        default: return "scanner"
        }
    }
}

/// A start-screen tile: the task, its title and subtitle, its symbol, and whether it can be picked.
public struct IOSTaskTile: Identifiable, Equatable {
    public let task: ScanTask
    public let title: String
    public let subtitle: String
    public let summary: String
    public let symbol: String
    public let availability: TaskAvailability
    public let isCurrent: Bool

    public var id: ScanTask { task }

    /// What VoiceOver reads after the title: "Current" for the task set up now (the tile's badge),
    /// nothing otherwise.
    public var accessibilityValue: String { isCurrent ? "Current" : "" }

    public init(card: TaskCard) {
        self.task = card.definition.task
        self.title = card.definition.title
        self.subtitle = card.definition.subtitle
        self.summary = card.summary
        self.symbol = IOSShell.systemImage(card.definition.iconKey)
        self.availability = IOSShell.availability(card)
        self.isCurrent = card.isCurrent
    }
}

/// A group of the start screen with its tiles.
public struct IOSTaskGroup: Identifiable, Equatable {
    public let group: TaskGroup
    public let tiles: [IOSTaskTile]

    public var id: TaskGroup { group }
    public var title: String { group.title }

    public init(group: TaskGroup, tiles: [IOSTaskTile]) {
        self.group = group
        self.tiles = tiles
    }
}

extension AppState {
    /// The iPhone's and iPad's state: the scanner connections of `IOSShell.backends`, the iOS file
    /// actions (share sheet, Quick Look, the Files app) and UIKit's lifecycle; no printer and no
    /// troubleshooter links yet (the Kit's stand-ins refuse them).
    @MainActor
    public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions) -> AppState {
        let backends: [any ScannerBackend] = IOSShell.backends(options: options)
        let lifecycle: UIKitLifecycle = UIKitLifecycle()
        return AppState(backends: backends, fileActions: fileActions, lifecycle: lifecycle)
    }
}
#endif
