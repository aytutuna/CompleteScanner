#if os(iOS)
import CompleteScannerKit
import Foundation

/// What the app was launched with. `-demoScanner` (the UI smoke test's) keeps the app on the demo
/// scanner alone: the iPhone has no other connection yet, and once it has (eSCL), a test launched this
/// way still scans the same made-up pages. `-importFixture` (the import UI test's) imports one photo at
/// launch into the Document task, as the Files app would hand it over: its PNG bytes, base64, in the
/// environment variable `importFixtureVariable`, since a UI test cannot drive the system's pickers.
public struct IOSLaunchOptions: Equatable, Sendable {
    /// The launch argument for the demo scanner alone.
    public static let demoScannerArgument = "-demoScanner"
    /// The launch argument that imports the photo in `importFixtureVariable` at launch.
    public static let importFixtureArgument = "-importFixture"
    /// The environment variable holding that photo's bytes, base64.
    public static let importFixtureVariable = "COMPLETESCANNER_IMPORT_FIXTURE"
    /// The name the photo imported at launch is shown with.
    public static let importFixtureName = "fixture.png"

    /// Only the demo scanner is offered.
    public let demoScannerOnly: Bool
    /// The photo to import at launch; nil for none.
    public let launchImport: IOSImportItem?

    public init(demoScannerOnly: Bool) {
        self.demoScannerOnly = demoScannerOnly
        self.launchImport = nil
    }

    /// The options in the process's launch arguments.
    public init(arguments: [String]) {
        self.init(arguments: arguments, environment: [:])
    }

    /// The options in the process's launch arguments and environment (`ProcessInfo`).
    public init(arguments: [String], environment: [String: String]) {
        self.demoScannerOnly = arguments.contains(IOSLaunchOptions.demoScannerArgument)
        var item: IOSImportItem?
        if arguments.contains(IOSLaunchOptions.importFixtureArgument),
           let text = environment[IOSLaunchOptions.importFixtureVariable],
           let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]), !data.isEmpty {
            item = IOSImportItem(name: IOSLaunchOptions.importFixtureName, data: data, kind: .image)
        }
        self.launchImport = item
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
    /// photocopy a printer, Quick scan an area chosen on the preview, and the Archive document task
    /// the Archive & password settings (the PDF/A writer is shared already), which come later.
    public static func offers(_ task: ScanTask) -> Bool {
        if task == .quickScan || task == .archive { return false }
        return TaskCatalog.definition(task).flow == .documentQueue
    }

    /// Why a task is not offered yet: the tile's one visible line.
    public static let notYetReason = "Not in this version yet"

    /// Whether a task's scan screen opens Apple's document scanner (Document, Email, Word).
    public static func offersCamera(_ task: ScanTask?) -> Bool {
        guard let task else { return false }
        return IOSDocumentCamera.tasks.contains(task)
    }

    /// The formats the scan screen's Save offers: PDF or JPEG (a picture a page) while the queue would
    /// be saved as a PDF; none to choose for Word and text, which are saved as chosen.
    public static func saveFormats(_ settings: ScanSettings) -> [OutputFormat] {
        if settings.format.isTextFormat { return [] }
        return [.pdf, .jpeg]
    }

    /// The collected pages are saved as pictures (`AppState.saveImages`), not as one file (`savePDF`).
    public static func savesImages(_ settings: ScanSettings) -> Bool {
        settings.format.isImageFormat
    }

    /// The Save button's title: "Save 3 JPEGs" for pictures (`AppState.imagesSaveTitle`), else the
    /// queue's own ("Save PDF (3 pages)", "Save Word").
    public static func saveTitle(_ settings: ScanSettings, plan: SavePlan) -> String {
        if savesImages(settings) {
            return AppState.imagesSaveTitle(settings.format, pageCount: plan.pageCount)
        }
        return plan.saveTitle(settings.format)
    }

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
        case "archive": return "archivebox"
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
