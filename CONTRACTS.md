# CompleteScanner — module contracts

Native macOS scanner app. SwiftUI, macOS 14+, Swift 5.9 language mode, SwiftPM, **system frameworks only** (AppKit, SwiftUI, ImageCaptureCore, CoreImage, Vision, PDFKit, CoreGraphics, ImageIO, UniformTypeIdentifiers, Accelerate). No third-party dependencies. No UIKit.

All app code lives in the library target `CompleteScannerKit` (`Sources/CompleteScannerKit/`). Tests in `Tests/CompleteScannerTests` use `@testable import CompleteScannerKit`.

Already written (READ THESE FIRST, code against them exactly):
- `Sources/CompleteScannerKit/Core/Models.swift` — all shared types (ScanIntent, ColorMode, ScanSource, OutputFormat, AdjustmentSettings, ScanSettings, ScannedPage, DetectedPhotoRegion, DetectedPhoto, ScannerInfo, ScannerCapabilities, ScanProgress, Preset, ScanError).
- `Sources/CompleteScannerKit/Core/DeviceMerge.swift` — `DeviceGroup` and `DeviceMerge` (one row per physical scanner, see below).
- `Sources/CompleteScannerKit/Core/Troubleshooting.swift` — `ScannerProblem` and `ScannerProblems.describe` (see below).
- `Sources/CompleteScannerKit/Core/Troubleshooter.swift`, `App/TroubleshooterService.swift` — "Why isn't my scanner listed?": the discovery snapshot, its checks and what they offer to do (see below).
- `Sources/CompleteScannerKit/Core/ScannerBackend.swift` — `ScannerBackend` / `ScannerSession` protocols (both `@MainActor`).
- `Sources/CompleteScannerKit/Core/ScanTask.swift`, `TaskCatalog.swift`, `TaskFlow.swift`, `SettingsAdapter.swift` — the start screen's tasks, their guided steps, and fitting settings to a scanner (see below).
- `Sources/CompleteScannerKit/Output/PDFImageEncoding.swift`, `Pipeline/ColorAnalysis.swift` — the PDF sizes: how each page image is stored in a PDF (see below).
- `Sources/CompleteScannerKit/Core/SaveActions.swift`, `App/FileActions.swift` — what can be done with saved files (open, open with, show in Finder, share, email, copy) and the after-save action (see below).
- `Sources/CompleteScannerKit/Core/DocumentSides.swift`, `Core/PaperSize.swift` — two-sided scanning (which page is which side of which sheet, turning a stack over by hand) and paper sizes (see below).
- `Sources/CompleteScannerKit/Pipeline/PageProcessor.swift`, `BlankPageDetector.swift`, `RgbaImage.swift`, `GrayImage.swift`, `BackgroundMap.swift`, `MaskOps.swift` — the page clean-up stage every scanned page goes through, blank-page detection, and the image toolkit the page analyses share (see below).
- `Sources/CompleteScannerKit/Pipeline/DocumentGeometry.swift` — crop to the page and straighten it: the sheet's edges on the scanner's background, the skew of the text lines, and what is done to the page (see below).
- `Sources/CompleteScannerKit/Pipeline/IdCard.swift`, `App/AppState+IdCard.swift`, `UI/IdCardReviewView.swift` — the ID card task: both sides of a card found on the glass and laid out on one page at real size (see below).
- `Sources/CompleteScannerKit/Output/PrintLayout.swift`, `App/PrintController.swift`, `App/AppState+Copy.swift` — copy and print: the Copy task, printing the ID card's page and the ruler test page, at real size (see below).
- `Sources/CompleteScannerKit/Output/OCRText.swift`, `TextExport.swift`, `DocxWriter.swift`, `ZipStore.swift` — text output: OCR lines in reading order and paragraphs, the text file, the Word document and its zip package, Copy Text (see below).
- `Sources/CompleteScannerKit/App/AppState.swift` — the `@MainActor ObservableObject` all UI binds to; its task members are in `App/AppState+Tasks.swift`.
- `Sources/CompleteScannerKit/App/ContentView.swift`, `CompleteScannerApp.swift`.

## Global rules

1. Write ONLY the files assigned to you. Never edit shared files.
2. Platform parity and CI. The Windows app under `windows/` is a sibling of this package. Every change to shared core logic (models, settings, naming, pipeline, output, persistence) lands on both platforms in the same change, with mirrored tests: `Tests/CompleteScannerTests` here and `windows/CompleteScanner.Core.Tests` there, same cases. Both suites must be green in CI (`.github/workflows/ci.yml`: `swift build` + `swift test` on macOS, `dotnet test windows/CompleteScanner.sln` on Windows) before a change counts as done. The one exception is the protocol logic of connections only Windows has — WIA, eSCL and TWAIN (`windows/CompleteScanner.Core/WiaErrors.cs`, `Escl/`, `Twain/`), and the Windows service and network values the troubleshooter reads (`WindowsSystemStatus.cs`): macOS reaches the same scanners through ImageCaptureCore, so that logic and its tests have no Swift twin (see `windows/README.md`). What those connections report to the app (`ScannerInfo`, `ScannerCapabilities`, `ScannerProblem`, `ScanStop`) stays shared.
3. Any helper function, extension, or type not listed in this document must be `private` or `fileprivate` in your file to avoid cross-file collisions.
4. Coordinate conventions:
   - Image/region coordinates: pixels, origin TOP-LEFT, x right, y down (see DetectedPhotoRegion doc comment; positive angle = clockwise on screen).
   - Scan selection: normalized 0...1 rect of the flatbed, origin top-left.
   - Vision (`VNRecognizedTextObservation.boundingBox`): normalized, origin BOTTOM-LEFT.
   - PDF user space: points (72/inch), origin BOTTOM-LEFT. Page size = pixels / dpi × 72.
5. Errors thrown across modules should be `ScanError`.
6. Settings files (`presets.json`, `settings.json`, and any file added later) must load across versions:
   - Every new stored field of a persisted type is optional-with-default: it gets a default value, and the type's `init(from:)` (kept in an extension so memberwise initializers survive) decodes it with `container.decodeLenient(forKey:default:)` (`Core/Models.swift`), passing that default. A missing key, a null, a wrong-typed value or a corrupt nested object resets only that field.
   - The first case of every persisted enum is also its default and its safe fallback; an unknown raw value (written by a newer version) decodes as the property's default instead of failing the file. Add new cases after the existing ones and never rename a raw value.
   - Keys never change: encoding stays the synthesized `encode(to:)` with explicit `CodingKeys` named after the properties.
   - Never overwrite a settings file that could not be read. A file that was read but does not decode is moved aside as `<name>.unreadable-<yyyyMMdd-HHmmss>.json` in the same folder before defaults are written. A file that cannot be read at all (permissions, I/O errors) is left in place, defaults are used in memory only, and writes to it are refused for the rest of the session. A missing file (including one removed between checks) means first run.
   - Windows (`windows/CompleteScanner.Core/Persistence.cs`) follows the same rules without per-type code, for its Windows-only files too (`preferences.json`, and the network scanners added by address and their trusted certificates, `escl-hosts.json` and `escl-trust.json`): `StoreFiles.JsonOptions` reads every property of every type in a settings file on its own and falls back to the value a freshly constructed instance has. A new persisted property only needs an initializer default, a persisted type needs a public parameterless constructor, and enums are read only as their exact camelCase name (the Swift raw value).

## APIs each module must expose (exact signatures)

### Core/Troubleshooting.swift (+ ScanError, ScannerCapabilities in Core/Models.swift)

```swift
/// A condition at the scanner that stops a scan and that the user can usually fix.
/// The first case is the safe default; add new cases after the existing ones.
public enum ScannerProblem: String, CaseIterable, Sendable {
    case unknown, feederEmpty, paperJam, paperProblem, multiFeed, coverOpen
    case offline, busy, warmingUp, needsAttention, communicationError
}

public enum ScannerProblems {
    /// User-facing text: what happened and what to do, e.g. "Load paper in the feeder, then scan again."
    public static func describe(_ problem: ScannerProblem) -> String
}

// ScanError gains `case scannerProblem(ScannerProblem)` (its errorDescription is
// `ScannerProblems.describe`) and `var problem: ScannerProblem?`.
// ScannerCapabilities gains `feederSizeInches: CGSize?` (largest feeder sheet, nil when
// unknown) and `supportsDuplex: Bool` (reported only); both have init defaults.

/// Why a feeder batch ended before the feeder ran out; the scan still returns its pages.
public struct ScanStop: Equatable, Sendable {
    public var reason: String
    public var problem: ScannerProblem?
    public init(reason: String, problem: ScannerProblem? = nil)
    public static func from(_ error: Error) -> ScanStop
    /// "Scanning stopped after 3 pages; they were kept. <reason>"
    public func message(pagesKept: Int) -> String
}
// ScannerSession gains `var lastScanStop: ScanStop? { get }` (default nil): set by a scan
// that keeps its pages after a mid-batch failure, reset by every scan. AppState shows
// `message(pagesKept:)` as an error once the pages are handled.
// ScannerSession also has `func feederSupportsDuplex() async -> Bool?` (default nil) and
// `var feederDuplexNeedsSelection: Bool { get }` (default false): for backends that can tell
// whether the feeder scans both sides only once it is selected (ImageCaptureCore, true). AppState
// asks only when the feeder is used, until the scanner answers (nil = no answer this time); scans
// and previews wait for a check under way. Until then its feeder is taken to scan both sides
// (`AppState.sidesCapabilities`, `DocumentSides.capabilitiesForSides`).
// ScannerSession also has `var lastScanDuplex: Bool? { get }` (default nil; C#
// `IScannerSession.LastScanDuplex`): whether a feeder scan asked for `.both` scanned both sides,
// false when the scanner fell back to one side; reset by every scan. The app arranges the pages as
// fronts and backs only when it is not false.
```
Twin of `windows/CompleteScanner.Core/Troubleshooting.cs` (`ScanException.ForProblem` / `ScanException.Problem`): same cases, same text. Backends report fixable scanner conditions this way rather than as `scanFailed` text.

### Core/Troubleshooter.swift, App/TroubleshooterService.swift

```swift
public enum TroubleshootPlatform: String, Sendable { case windows, mac }
public enum NetworkStatus: String, Sendable { case unknown, offline, publicNetwork, privateNetwork, domainNetwork }
public enum ServiceStatus: String, Sendable { case unknown, running, starting, stopping, stopped, paused, disabled, notInstalled }
public enum TwainStatus: String, Sendable { case unknown, available, notInstalled, failed }
public enum DiscoveryStatus: String, Sendable { case unknown, off, searching, running, unavailable }
public enum CheckStatus: String, CaseIterable, Sendable { case ok, tip, warning, problem }
public enum TroubleshootAction: String, CaseIterable, Sendable {
    case refresh, addByAddress, openScannerSettings, openNetworkSettings, openImageCapture, copyDiagnostics
}
public struct ManualHostStatus: Equatable, Sendable { address: String; listed: Bool; problem: String? }
public struct ScannerFailure: Equatable, Sendable { deviceName: String; message: String; problem: ScannerProblem? }
/// Everything the troubleshooter looks at; defaults (unknown, empty) produce no check. The
/// Windows-only fields (wiaService, twain…, manualHosts, discoveredCount) stay at their defaults
/// on the Mac. `init` takes every field, all defaulted, platform `.windows` first.
public struct DiscoverySnapshot: Equatable, Sendable {
    platform, devices: [ScannerInfo], network, wiaService, twain, twainDriverCount: Int,
    thirtyTwoBitOnlyDrivers: [String], discovery, discoveryDetail: String?, discoveredCount: Int,
    manualHosts: [ManualHostStatus], lastFailure: ScannerFailure?
    var listedScannerCount: Int { get }            // not the demo scanner
}
public struct TroubleshootCheck: Equatable, Sendable { id, status, title, detail, actions: [TroubleshootAction] }

@MainActor public protocol ScannerBackendDiagnostics: AnyObject {   // optional; ScannerBackend is unchanged
    func addStatus(to snapshot: DiscoverySnapshot) -> DiscoverySnapshot
    func rescan()                                   // look again; never changes system settings
}

public enum Troubleshooter {
    /// Problems, then warnings, then OK, then tips; within each: last failure, network, WIA service,
    /// TWAIN, 32-bit TWAIN drivers, the search, addresses added by hand, tips. The Mac never gets
    /// the Windows checks or `.addByAddress`.
    public static func diagnose(_ snapshot: DiscoverySnapshot) -> [TroubleshootCheck]
    public static func headline(_ snapshot: DiscoverySnapshot) -> String      // "No scanner found yet", "2 scanners found"
    public static func summary(_ checks: [TroubleshootCheck]) -> String       // "2 problems and 1 warning found."
    public static func label(_ action: TroubleshootAction, platform: TroubleshootPlatform) -> String
    public static func statusLabel(_ status: CheckStatus) -> String           // "OK", "Tip", "Warning", "Problem"
    public static func report(_ snapshot: DiscoverySnapshot, checks: [TroubleshootCheck]) -> String
    public static func combineNetworks(_ connected: [NetworkStatus]) -> NetworkStatus
    /// nil for cancelled, export and unsupported errors (and CancellationError).
    public static func failure(deviceName: String, error: Error) -> ScannerFailure?
}

// App/TroubleshooterService.swift: the system side, injected into AppState so tests can stand in for it.
@MainActor public protocol TroubleshooterService: AnyObject {
    func open(_ action: TroubleshootAction) throws   // Printers & Scanners, Network, Image Capture
    func copy(_ text: String) throws                 // NSPasteboard
}
@MainActor public final class SystemTroubleshooterService: TroubleshooterService { public init() }
```
Twin of `windows/CompleteScanner.Core/Troubleshooter.cs` (`IScannerBackendDiagnostics.AddStatus` / `Rescan`, `Troubleshooter.Diagnose` / `Headline` / `Summary` / `Label` / `StatusLabel` / `Report` / `CombineNetworks` / `FailureFrom`, `DiscoverySnapshot` as a record with init properties); `TroubleshooterTests` are the same cases on both sides. The apps only read the system's state and link to its settings; they never change a service or a setting. `AppState` takes an optional `troubleshooterService:` (default `SystemTroubleshooterService()`), keeps `lastFailure` (the last connection or scan that failed with something the troubleshooter explains, cleared by the next one that works) and `errorSuggestsTroubleshooter` (the error alert then offers Troubleshoot…), and offers `showTroubleshooter`, `hasRealDevices`, `troubleshootSnapshot()`, `refreshScanners()`, `diagnosticsText(_:)`, `copyDiagnostics(_:)` and `openTroubleshootLink(_:)`. `copyDiagnostics(_:)` and `openTroubleshootLink(_:)` return why they did not work (nil when they did) for the troubleshooter's footer and leave `errorMessage` alone, since its alert cannot show over the sheet; Windows reports the same failures in its non-modal error bar as well. `ICScannerBackend` conforms to `ScannerBackendDiagnostics` (browsing or not; Refresh restarts the browser only while nothing is listed and the browser has run at least the watchdog's first delay, 10 s, and the watchdog waits as long after a restart). A Refresh while one is running is ignored on both platforms. devices.txt ends with `Troubleshooter.report`. `UI/TroubleshooterView.swift` (`struct TroubleshooterView: View`) is the sheet, shown from the Scanners header, the empty list and the alert. Windows (`App/Services/SystemDiagnostics.cs`, `TroubleshooterWindow`) also reads the WIA service (`QueryServiceStatus`) and the network category (Network List Manager).

### Core/DeviceMerge.swift (+ ScannerInfo in Core/Models.swift)

```swift
// ScannerInfo gains `backend: String` ("wia", "twain", "escl", "ic", "mock"; "" when unknown),
// `model: String?` and `hardwareID: String?` (eSCL UUID or serial), all with init defaults.
// ICScannerBackend sets backend "ic" and model = device.name, never a hardwareID: every
// ImageCaptureCore connection has its own uuidString.

public struct DeviceGroup: Equatable, Sendable {
    public let key: String          // stable across runs; unique within one grouping
    public let primary: ScannerInfo // the entry to connect through
    public let members: [ScannerInfo]
}

public enum DeviceMerge {
    public static let windowsRanking: [String]  // ["wia:WIA", "escl:Network", "wia:*", "twain:*"]
    public static let macRanking: [String]      // ["ic:USB", "ic:Network", "ic:Shared"]
    /// Lowercased model words: brackets, IP addresses and bit widths removed, vendor aliases
    /// mapped, connection words dropped, duplicates removed; joined by spaces.
    public static func modelKey(_ name: String) -> String
    public static func sameDevice(_ a: ScannerInfo, _ b: ScannerInfo) -> Bool
    public static func group(_ devices: [ScannerInfo], rankPatterns: [String],
                             overrides: [String: String] = [:]) -> [DeviceGroup]
    public static func connectionID(_ device: ScannerInfo) -> String    // "backend:transport"
    public static func connectionLabel(_ device: ScannerInfo) -> String
    public static func diagnosticsReport(_ groups: [DeviceGroup]) -> String
}
```
Twin of `windows/CompleteScanner.Core/DeviceMerge.cs` (`HardwareId`, `ConnectionId`): same rules, same keys, same report text; `DeviceMergeTests` on both sides share one table. Only ASCII letters and digits count as model words on both platforms, so the result never depends on locale or Unicode tables. `AppState.devices` lists one entry per group (the connection in use for the selected scanner) and `AppState` writes `diagnosticsReport` to `~/Library/Logs/CompleteScanner/devices.txt` when it changes. The Mac has no connection chooser; Windows keeps the user's choice in `AppPreferences.PreferredConnection` (group key → connection id).

### Core/ScanTask.swift, Core/TaskCatalog.swift, Core/TaskFlow.swift (+ ScanSettings in Core/Models.swift)

```swift
// ScanSettings gains `taskId: String?` (nil by default; left out of the file when nil) and
// the computed `task: ScanTask?` (`ScanTask.tryParse(taskId)`). The task is stored as text,
// not as the enum: a task id of a newer version reads as no task and is written back unchanged.
// ScanSettings also gains `taskOptions: TaskOptions` (the "taskOptions" object): how the user
// wants a task done, kept when a task is picked (see Pipeline/IdCard.swift).

public enum ScanTask: String, CaseIterable, Identifiable, Sendable {
    case document, feeder, photos, photoRestore, quickScan, email, twoSided, idCard, copy, word   // add new tasks after these
    public static func tryParse(_ rawValue: String?) -> ScanTask?
}

public enum TaskFlowKind: String, Sendable { case documentQueue, photoSplit, idCard, copy }

public struct TaskDefinition: Equatable, Sendable {
    public let task: ScanTask
    public let title: String, subtitle: String
    public let iconKey: String          // "document", "feeder", "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word"
    public let flow: TaskFlowKind
    public let intent: ScanIntent
    public let requiredSource: ScanSource?
    public let fileLabel: String        // what {task} becomes
    public let steps: [TaskStep]
}

public struct TaskAvailability: Equatable, Sendable {
    public let isAvailable: Bool
    public let reason: String?          // "This scanner has no document feeder."
    public static let available: TaskAvailability
}

public enum TaskCatalog {
    public static let all: [TaskDefinition]                 // start-screen order
    public static func definition(_ task: ScanTask) -> TaskDefinition
    /// The task's settings over `current`; keeps the destination folder, the photo detection
    /// tuning, the legacy OCR languages, the paper size, the back binding and `taskOptions`; sets
    /// `taskId`. Only `.twoSided` sets `duplex` (`.both`); the others set `.off`. Only `.idCard`
    /// (the numbers on an ID are better not indexed) and `.copy` (a copy is for paper) turn
    /// `pdfSearchable` off. Every task turns `output.alsoSaveText` off; `.word` (Scan to Word)
    /// saves a Word document (`format = .word`, 300 dpi, collected pages).
    public static func apply(_ task: ScanTask, to current: ScanSettings) -> ScanSettings
    /// The stored task, else the task the settings look like (display and file names only): a
    /// Word document is `.word` (from the feeder, `.feeder`); a scan saved at once as an image is
    /// `.quickScan`.
    public static func infer(_ settings: ScanSettings) -> ScanTask
    /// `.copy` also needs a printer: `hasPrinter` false gives `PrintText.noPrinterReason` ("No printer is installed.").
    public static func availability(of task: ScanTask, capabilities: ScannerCapabilities?,
                                    hasPrinter: Bool = true) -> TaskAvailability
    /// Same scan mode and, when the task has one, the required source; `.twoSided` also needs
    /// `duplex != .off`, `.word` a Word document.
    public static func fits(_ task: ScanTask, _ settings: ScanSettings) -> Bool
    /// The steps the scan screen guides: `DocumentSides.manualSteps` whenever the settings turn
    /// a stack over by hand (`DocumentSides.usesManualSteps`), otherwise the fitting task's steps;
    /// nil when nothing is guided.
    public static func guidedSteps(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> [TaskStep]?
    /// The stored task's flow while it fits, otherwise by intent. The scan handler switches on it.
    public static func flow(of settings: ScanSettings) -> TaskFlowKind
    /// "300 dpi · Color · PDF"; a PDF size other than `.standard` is named: "300 dpi · Color · Compact PDF";
    /// two-sided feeder scanning too: "… · Both sides", "… · Both sides, turned by hand"; a copy
    /// (flow `.copy`) says how it prints: "300 dpi · Color · Actual size", "… · Fit to page · 3 copies"
    public static func summary(_ settings: ScanSettings) -> String
}

public struct TaskStep: Equatable, Sendable {
    public let id: String, title: String, prompt: String, primaryActionLabel: String
    public let skippable: Bool, repeats: Bool, requiresCapture: Bool
    public init(id:title:prompt:primaryActionLabel:skippable: = false, repeats: = false, requiresCapture: = true)
}

public struct TaskFlow: Equatable, Sendable {      // a pure state machine; unknown step ids are ignored
    public init(steps: [TaskStep])
    public let steps: [TaskStep]
    public private(set) var stepIndex: Int
    public var stepCount: Int { get }
    public var current: TaskStep? { get }
    public var isComplete: Bool { get }
    public var canFinish: Bool { get }             // every step that requires a capture has one
    public func captures(for stepID: String) -> [UUID]
    public func isSkipped(_ stepID: String) -> Bool
    @discardableResult public mutating func record(stepID: String, captureID: UUID) -> [UUID]  // replaced captures
    @discardableResult public mutating func advance() -> Bool
    @discardableResult public mutating func skip() -> Bool
    @discardableResult public mutating func retake(stepID: String) -> [UUID]                   // dropped captures
    public mutating func reset()
}
```
Twins of `windows/CompleteScanner.Core/ScanTask.cs`, `TaskCatalog.cs` and `TaskFlow.cs` (C# names in PascalCase; `TaskCatalog.FlowOf` for `flow(of:)`, `ScanTasks.TryParse` / `RawValue`); `ScanTaskTests` and `TaskFlowTests` are the same cases on both sides. Task cards exist only for features that are built; later features add a `ScanTask` case, a catalog entry and their steps. `AppState` (`App/AppState+Tasks.swift`) keeps the task in `settings.taskId`, so it is saved and restored with the settings: `startTask(_:)`, `exitTask()`, `skipStep()` (the current step when it is skippable), `taskCards`, `activeTask`, `taskFlow`, `primaryActionLabel`, `isFirstRun`. Its `settings` didSet ends a task the settings no longer fit. The banner offers Skip for a skippable step ("Skip back side").

### Core/SettingsAdapter.swift

```swift
public enum SettingsChange: String, Sendable { case source, resolution, duplex, paperSize }
public struct SettingsNote: Equatable, Sendable { public let change: SettingsChange; public let message: String }
public struct AdaptedSettings: Equatable, Sendable { public let settings: ScanSettings; public let notes: [SettingsNote] }

public enum SettingsAdapter {
    /// A source the scanner has (its first one when the chosen one is missing, the flatbed when it
    /// lists none), `.both` turned into `.manual` for a feeder source on a scanner without
    /// `supportsDuplex`, `.auto` for a paper size larger than the glass or the feeder (whichever is
    /// the source; kept when that size is unknown), and the nearest resolution it supports, with a
    /// note for each change in that order; unchanged when `capabilities` is nil.
    public static func adapt(_ settings: ScanSettings, to capabilities: ScannerCapabilities?) -> AdaptedSettings
}
```
Twin of `windows/CompleteScanner.Core/SettingsAdapter.cs` (same note texts); `SettingsAdapterTests` on both sides. Every place settings meet a scanner goes through it: applying a preset or task, and connecting to a scanner.

### Core/DocumentSides.swift, Core/PaperSize.swift (+ ScanSettings, ScannedPage in Core/Models.swift)

```swift
// ScanSettings gains `duplex: DuplexMode` (.off), `backBinding: DuplexBinding` (.longEdge) and
// `paperSize: PaperSize` (.auto): top-level keys "duplex", "backBinding", "paperSize", read by the
// backends. ScannedPage gains `side: PageSide?` and `sheetIndex: Int?` (nil for one-sided pages).
public enum DuplexMode: String, Codable, CaseIterable, Identifiable, Sendable { case off, both, manual }   // label, hint
public enum DuplexBinding: String, Codable, CaseIterable, Identifiable, Sendable { case longEdge, shortEdge } // label
public enum PageSide: String, Sendable { case front, back }

extension ScannedPage {   // in the struct itself; every place that rebuilds a page uses these
    /// Same id, dpi, creation time, rotation, side and sheet; the color mode when given; the file
    /// and full size given (none by default).
    public func withImage(_ image: CGImage, colorMode: ColorMode? = nil, fileURL: URL? = nil,
                          fullPixelSize: CGSize? = nil) -> ScannedPage
    public func copyMeta(from source: ScannedPage) -> ScannedPage           // side and sheet of `source`
    public func withSide(_ side: PageSide?, sheetIndex: Int?) -> ScannedPage
}

public struct SidedTransfer: Equatable, Sendable { transferIndex, sheetIndex: Int; side: PageSide }
public struct ManualPage: Equatable, Sendable { batch: PageSide; index, sheetIndex: Int }
public struct ManualInterleave: Equatable, Sendable {
    order: [ManualPage]; fronts, backs: Int
    var mismatch: Bool; var mismatchMessage: String?   // "3 fronts but 2 backs"
}
public struct SheetPosition: Equatable, Hashable, Sendable { sheetIndex: Int; side: PageSide }
public struct QueueCollation: Equatable, Sendable { order: [UUID]; positions: [UUID: SheetPosition]; interleave: ManualInterleave }

public enum DocumentSides {
    public static let feederOnlyReason: String, oneSidedFeederReason: String
    public static let frontsStepID = "fronts", backsStepID = "backs"
    public static let manualSteps: [TaskStep]           // "Scan fronts", "Scan backs" (skippable, no capture required)
    /// Reading order (by sheet, front first) of a feeder scan's transfers; two-sided transfers come
    /// front, back, …; an odd last one is a front only; `reverseOrder` numbers sheets from the end.
    public static func assignSides(transferCount: Int, duplex: Bool, reverseOrder: Bool = false) -> [SidedTransfer]
    /// Fronts and backs scanned separately; turning the stack over reverses the backs. Counts
    /// that differ pair as far as they go, the rest follows, and `mismatch` is set (never nil).
    public static func interleaveManual(fronts: Int, backs: Int, backsReversed: Bool = true) -> ManualInterleave
    public static func backQuarterTurns(_ binding: DuplexBinding) -> Int    // 2 for short edge, else 0
    /// `.off` unless the feeder is the source; `.both` on a feeder without duplex is `.manual`.
    public static func effective(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> DuplexMode
    /// While whether the feeder scans both sides is not known (`duplexKnown` false), a scanner
    /// with a feeder is taken to (a copy with `supportsDuplex` true); otherwise unchanged.
    public static func capabilitiesForSides(_ capabilities: ScannerCapabilities?, duplexKnown: Bool) -> ScannerCapabilities?
    /// Effective `.manual`, document queue flow, collect pages.
    public static func usesManualSteps(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> Bool
    /// The Copy task: "Copies are made from one side of each sheet; turn the stack over and copy again.";
    /// another flow than the queue: "… works for documents, not photos."; not collecting pages: "… needs …".
    public static func manualUnavailableReason(_ settings: ScanSettings) -> String?
    public static func countMessage(fronts: Int, backs: Int) -> String
    public static func sideLabel(side: PageSide?, sheetIndex: Int?) -> String?   // "Sheet 2 · back", "Front"
    /// Pages of a two-sided scan in reading order, marked, backs turned upright for `binding`.
    public static func arrangeTwoSided(_ pages: [ScannedPage], binding: DuplexBinding, reverseOrder: Bool = false) -> [ScannedPage]
    /// One scan of a stack turned over by hand, marked as fronts or backs (backs turned upright;
    /// a spooled page's file turns at save time through `rotationQuarterTurns`).
    public static func markManual(_ pages: [ScannedPage], side: PageSide, binding: DuplexBinding) -> [ScannedPage]
    /// The queue with the stack in reading order where its first page was; pages no longer queued are left out.
    public static func collateQueue(_ queue: [UUID], fronts: [UUID], backs: [UUID], backsReversed: Bool = true) -> QueueCollation
}

public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, letter, legal, executive, a4, a5, a6, b5Jis, idCard   // first case = default and fallback
    public var label: String       // "Automatic", "Letter", "B5 (JIS)", "ID card"
    public var detail: String      // "8.5 × 11 in", "210 × 297 mm"
}
public enum PaperSizes {
    public static let fitTolerance: Double                 // 0.05 in
    public static let letterRegions: [String]              // the ICU Letter list (14 codes)
    public static func inches(_ size: PaperSize) -> CGSize?    // portrait; nil for .auto
    public static func parse(_ text: String?) -> PaperSize    // case-insensitive raw value, else .auto
    public static func defaultForRegion(_ regionCode: String?) -> PaperSize   // .letter or .a4
    public static func match(_ inches: CGSize) -> PaperSize?   // a printer's paper, either way round, within fitTolerance
    public static func displayOrder(region: String?) -> [PaperSize]           // auto, the usual size, the rest
    public static func fits(_ size: PaperSize, in area: CGSize?) -> Bool
    public static func flatbedSelection(_ size: PaperSize, bed: CGSize) -> CGRect?   // normalized, top-left
    public static func feederRegionInches(_ size: PaperSize, max: CGSize) -> CGRect
    public static func hint(_ size: PaperSize, source: ScanSource) -> String
    public static func doesNotFitReason(source: ScanSource) -> String
}
```
Twins of `windows/CompleteScanner.Core/DocumentSides.cs` and `PaperSize.cs` (`PaperSizes.Label` / `Detail` / `RawValue` as extensions, `DocumentSides.FrontsStepId` / `ArrangeTwoSided` / `MarkManual` / `CollateQueue`, `ScannedPage.WithImage` / `CopyMeta` / `WithSide`; C# also has `ScannedPage.RotatedClockwise`, which keeps the sides); `DocumentSidesTests`, `PaperSizeTests` and the sides cases of `ModelsCompatTests`, `ScanTaskTests`, `SettingsAdapterTests` and `MockScannerTests` are the same on both sides. Every backend returns the pages of a two-sided scan in reading order, front, back, front, back… (ImageCaptureCore reorders a feeder with `reverseFeederPageOrder`); the app (`AppState.performScan`) asks the backend for `.both` only when `effective` says so, then marks the sides and turns the backs upright (`arrangeTwoSided`, `markManual`) before adjusting, recording history and spooling. Turning a stack over by hand is guided through `TaskFlow` with `manualSteps`, with or without a task (`AppState.isTurningOverByHand`, `awaitingBacks`, `canFinishFronts`, `canScanMoreFronts`, `sidesMismatch`, `finishFronts()`, `scanMoreFronts()`, `combineSidesAnyway()`, `scanBacksAgain()`, `keepFrontsOnly()`, `scanOneSideOnly()`): the fronts advance the steps unless the feeder stopped early (then the rest of the fronts is scanned and `finishFronts()` moves on), `scanMoreFronts()` goes back to the fronts before any back is scanned, the backs are put in order in the queue when the counts pair up, otherwise the mismatch is shown. A scan asked for `.both` whose session says it scanned one side (`lastScanDuplex == false`) is queued one-sided. When the capabilities could not be read on connect, a scan that works reads them again. The flatbed scans `flatbedSelection` of the paper size when nothing is selected; backends ask the feeder for `feederRegionInches`. The demo feeder (`MockScannerBackend.feederDuplex`, `feederStackTurnedOver`) scans its three sheets one side or both.

### Pipeline/RgbaImage.swift, GrayImage.swift, BackgroundMap.swift, MaskOps.swift (the image toolkit)

```swift
/// RGBA8, row-major, top-left origin; a port of C# RgbaImage (same box filter, bilinear sampling
/// and rounding: halves to even when sampling, away from zero when sizing). A value type: no clone().
public struct RgbaImage: Equatable, Sendable {
    public let width: Int, height: Int
    public var pixels: [UInt8]                     // width * height * 4
    public init(width: Int, height: Int, pixels: [UInt8])          // preconditions on the sizes
    public static func filled(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> RgbaImage
    public func resized(width: Int, height: Int) -> RgbaImage      // box filter down, bilinear up
    public func cropped(_ rect: CGRect) -> RgbaImage?              // integral, clamped; nil when empty
    public func extractRotated(center: CGPoint, size: CGSize, angleDegrees: Double,
                               fillR: UInt8 = 255, fillG: UInt8 = 255, fillB: UInt8 = 255) -> RgbaImage?
    public func rotatedQuarterTurns(_ quarterTurns: Int) -> RgbaImage   // clockwise
    public init?(cgImage: CGImage)                                 // ColorAnalysis.rgbaPixels
    public func makeCGImage() -> CGImage?
}

/// 8-bit luminance at a resolution (`dpi`); the page analyses work at `analysisDPI` (100).
public struct GrayImage: Equatable, Sendable {
    public static let analysisDPI: Int             // 100
    public let width: Int, height: Int
    public var pixels: [UInt8]
    public let dpi: Double
    public let scale: Double                       // these pixels per source pixel
    public init(width: Int, height: Int, pixels: [UInt8], dpi: Double = 100, scale: Double = 1)
    public static func filled(width: Int, height: Int, value: UInt8, dpi: Double = 100) -> GrayImage
    public subscript(x: Int, y: Int) -> UInt8 { get }
    public static func luma(_ image: RgbaImage, dpi: Double = 100) -> GrayImage      // rounded Rec. 601
    public static func from(_ image: RgbaImage, sourceDPI: Int, analysisDPI: Int = 100) -> GrayImage
    public init?(cgImage: CGImage, sourceDPI: Int, analysisDPI: Int = 100)   // reads in bands of rows
    public func atResolution(_ dpi: Int) -> GrayImage                        // itself when no finer
    public func downsampled(width: Int, height: Int) -> GrayImage            // box filter, rounding down
    public func toRgba() -> RgbaImage
}

/// The paper's brightness across an area: tiles, a percentile per tile, bilinear between tile centers.
public struct BackgroundMap: Sendable {
    public let x: Int, y: Int, width: Int, height: Int, columns: Int, rows: Int
    public let tiles: [UInt8]
    public static func estimate(_ gray: GrayImage, x: Int, y: Int, width: Int, height: Int,
                                tileSize: Int, percentile: Double = 0.9) -> BackgroundMap?   // nil when empty
    public static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> UInt8
    public func medianTile() -> UInt8
    public func maxSmoothed() -> BackgroundMap        // brightest of each tile and its 8 neighbors
    public func clampedBelow(_ floor: UInt8) -> BackgroundMap
    public func valueAt(x: Int, y: Int) -> Double
    public func inkMask(_ gray: GrayImage, contrast: Double) -> [UInt8]   // 1 where darker than (1 − contrast) × paper
}

// Internal (shared by the detectors; moved out of PhotoDetector unchanged):
struct MaskComponent { var area: Int; var rows: [Int: (minX: Int, maxX: Int)] }
enum MaskOps {
    static func dilate(_ mask: [UInt8], _ w: Int, _ h: Int, radius: Int) -> [UInt8]
    static func erode(_ mask: [UInt8], _ w: Int, _ h: Int, radius: Int, outsideSet: Bool = false) -> [UInt8]   // outsideSet: the border keeps its edge
    static func connectedComponents(mask: [UInt8], width: Int, height: Int) -> [MaskComponent]   // 4-connected
    static func componentAreas(mask: [UInt8], width: Int, height: Int, eightConnected: Bool = false) -> [Int]
}
```
Twins of `windows/CompleteScanner.Core/RgbaImage.cs`, `GrayImage.cs` (`GrayImage.Luma` / `From` / `AtResolution` / `Downsampled`, `AnalysisDpi`), `BackgroundMap.cs` and `MaskOps.cs` (internal there too); `RgbaImageTests`, `GrayImageTests` and `MaskOpsTests` are the same cases on both sides and expect the same bytes. `MaskOpsTests` keeps PhotoDetector's former private code as the reference and checks MaskOps against it; the C# suite also pins PhotoDetector's regions on the demo bed to the last bit. New page analyses (page edges, separator sheets, receipts) build on these types rather than on CoreGraphics, so both platforms compute the same numbers; Swift meets CoreGraphics only in `RgbaImage(cgImage:)`, `makeCGImage()` and `GrayImage(cgImage:…)`.

### Pipeline/BlankPageDetector.swift, Pipeline/PageProcessor.swift (+ DocumentOptions, ScannedPage in Core/Models.swift)

```swift
// ScanSettings gains `document: DocumentOptions` (the "document" object; later page features add
// their fields there). ScannedPage gains `blank: BlankPageResult?` (nil: not checked) and
// `inclusion: PageInclusion` (.automatic); copyMeta(from:) copies both, and `withBlank(_:)` /
// `withInclusion(_:)` return the page with one changed. For crop and straighten it also gains
// `geometry: PageGeometry?` (nil: left as scanned), `showsOriginal: Bool` (false) and
// `alternate: PageVersion?` (the version not shown); copyMeta(from:) copies geometry and
// showsOriginal and keeps the page's own alternate, withImage keeps the alternate:
//   public struct PageVersion { public var image: CGImage?; public var fileURL: URL?; public var fullPixelSize: CGSize? }
//   public var canSwapVersions: Bool                                   // geometry != nil && alternate != nil
//   public func withGeometry(_ corrected: CGImage, geometry: PageGeometry) -> ScannedPage   // the page as it was becomes the alternate
//   public func withAlternate(_ alternate: PageVersion?) -> ScannedPage
//   public func withVersionsSwapped(_ shown: CGImage) -> ScannedPage   // shown = the other version's preview, turned like the page; no alternate: unchanged
public enum BlankSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case medium, low, high                         // first case = default and fallback
    public var label: String                       // "Low", "Medium", "High"
    public var hint: String                        // what counts as blank at that level
    public static let displayOrder: [BlankSensitivity]   // [.low, .medium, .high]
}
public enum PageInclusion: String, Sendable { case automatic, keep, skip }   // not persisted
public struct DocumentOptions: Codable, Equatable, Sendable {
    public var removeBlankPages: Bool = false      // "removeBlankPages"
    public var blankSensitivity: BlankSensitivity = .medium   // "blankSensitivity"
    public var autoCrop: Bool = false              // "autoCrop"
    public var autoStraighten: Bool = false        // "autoStraighten"
}

public struct BlankPageOptions: Equatable, Sendable {
    public var sensitivity: BlankSensitivity       // .medium
    public var marginInches: Double                // BlankPageDetector.marginInches
    public init(sensitivity: BlankSensitivity = .medium, marginInches: Double = BlankPageDetector.marginInches)
}
public struct BlankPageResult: Equatable, Sendable {
    public let inkCoverage: Double, inkComponents: Int, hasLargeDarkArea: Bool, isBlank: Bool
    public func isBlankAt(_ sensitivity: BlankSensitivity) -> Bool
}
public enum BlankPageDetector {
    // marginInches 0.7, smallPageInches 2.5, smallPageMarginFraction 0.15, tileInches 0.25,
    // backgroundPercentile 0.9, darkAreaDrop 64, darkTileFraction 0.01, inkContrast 0.30, minMarkPixels 6
    public static func threshold(_ sensitivity: BlankSensitivity) -> Double   // 0.0001, 0.0003, 0.001
    public static func analyze(_ gray: GrayImage, options: BlankPageOptions = BlankPageOptions()) -> BlankPageResult
    public static func analyze(_ page: RgbaImage, dpi: Int, options: BlankPageOptions = BlankPageOptions()) -> BlankPageResult
    public static func analyze(_ image: CGImage, dpi: Int, options: BlankPageOptions = BlankPageOptions()) -> BlankPageResult
}

public protocol PageStep { var name: String { get }; func apply(_ page: ScannedPage) -> ScannedPage }
public struct BlankDetectionStep: PageStep { public let options: BlankPageOptions }   // "blank"
public struct GeometryStep: PageStep { public let crop: Bool; public let straighten: Bool }   // "geometry": DocumentGeometry.correct, then withGeometry
public struct AdjustmentStep: PageStep { public let adjustments: AdjustmentSettings; public let colorMode: ColorMode }   // "adjust" (the alternate's pixels too)
public enum ScanArrangement: Sendable { case asScanned, twoSided, turnedOverFronts, turnedOverBacks }
public struct ProcessedScan { public let arranged: [ScannedPage]; public let pages: [ScannedPage]; public var blankCount: Int }
public struct PageProcessor {
    public let steps: [any PageStep]; public let arrangement: ScanArrangement; public let binding: DuplexBinding
    public init(steps: [any PageStep], arrangement: ScanArrangement = .asScanned, binding: DuplexBinding = .longEdge)
    /// Blank check (when `checksBlankPages`), crop and straighten (when `correctsGeometry`), then
    /// adjustments (unless they change nothing).
    public static func forScan(_ settings: ScanSettings, arrangement: ScanArrangement = .asScanned) -> PageProcessor
    /// Document queue flow and documentMultiPage: pages saved at once are never checked.
    public static func checksBlankPages(_ settings: ScanSettings) -> Bool
    /// checksBlankPages and (autoCrop or autoStraighten): pages saved at once are never changed unseen.
    public static func correctsGeometry(_ settings: ScanSettings) -> Bool
    /// Arranges (DocumentSides.arrangeTwoSided / markManual), then every step on every page in
    /// order; throws ScanError.cancelled when `shouldContinue` says no (asked before each page and step).
    public func process(_ scanned: [ScannedPage], shouldContinue: () -> Bool = { true }) throws -> ProcessedScan
}
public enum PageFilter {
    public static let nothingToSaveMessage: String
    public static func looksBlank(_ page: ScannedPage, sensitivity: BlankSensitivity) -> Bool
    public static func isExcluded(_ page: ScannedPage, options: DocumentOptions) -> Bool   // keep / skip, else the setting
    public static func toggled(_ page: ScannedPage, options: DocumentOptions) -> PageInclusion   // two clicks undo one
    public static func pagesToSave(_ pages: [ScannedPage], options: DocumentOptions) -> [ScannedPage]
    public static func badge(_ page: ScannedPage, options: DocumentOptions) -> String?          // "Blank, skipped", "Skipped", "Looks blank"
    public static func toggleLabel(_ page: ScannedPage, options: DocumentOptions) -> String?    // "Keep this page", "Skip this page"
    public static func queueSummary(_ pages: [ScannedPage], options: DocumentOptions) -> String  // "24 pages in queue, 5 blank skipped"
    public static func scanNote(_ added: [ScannedPage], options: DocumentOptions) -> String     // " 2 look blank and will be skipped."
}
public enum PageCorrections {
    public static func caption(_ page: ScannedPage) -> String?          // "Cropped and straightened 2.4°", "As scanned", nil
    public static func toggleLabel(_ page: ScannedPage) -> String?      // "Show as scanned", "Show straightened", nil when it cannot swap
    public static func swapNote(_ page: ScannedPage, number: Int) -> String   // "Page 3 is shown as scanned. It is saved that way."
    public static func scanNote(_ added: [ScannedPage]) -> String        // " 2 straightened.", " 3 cropped or straightened."
}
```
Twins of `windows/CompleteScanner.Core/BlankPageDetector.cs`, `PageProcessor.cs` (`IPageStep`, `BlankDetectionStep`, `AdjustmentStep`, `ScanArrangement`, `ProcessedScan`, `PageProcessor`, `PageFilter`; `ScanSettings.Document`, `DocumentOptions`, `BlankSensitivities.DisplayOrder`, `ModelLabels.Label` / `Hint`, `ScannedPage.Blank` / `Inclusion` / `WithBlank` / `WithInclusion`); `BlankPageDetectorTests` and `PageProcessorTests` are the same cases on both sides, on the same synthetic pages (`TestPages`, byte-identical, checked by checksum), and the blank-page cases of `ModelsCompatTests`, `ScanTaskTests` and `MockScannerTests` match. Every scan's pages go through `PageProcessor` in `AppState.performScan` (Windows `AppViewModel.PerformScan`): arranged by sides, checked for being blank on the page as scanned, adjusted. Later page features add their steps between the blank check and the adjustments. Blank pages are never removed from the queue: the page strip flags them (and dims those left out), one click keeps or skips a page (`AppState.togglePageInclusion(id:)`), and `savePDF` writes `pagesToSave`, reporting how many were left out; when nothing is left it sets `errorMessage` to `nothingToSaveMessage` and keeps the queue. `TaskCatalog.apply` turns `removeBlankPages` on for `.twoSided` only and keeps `blankSensitivity`. Crop and straighten (`GeometryStep`, `PageCorrections`, `DocumentOptions.autoCrop` / `autoStraighten`, `ScannedPage.geometry` / `showsOriginal` / `alternate`, twins of C# `GeometryStep`, `PageCorrections`, `DocumentOptions.AutoCrop` / `AutoStraighten`, `ScannedPage.Geometry` / `ShowsOriginal` / `Alternate` / `WithGeometry` / `WithAlternate` / `WithVersionsSwapped`, `PageVersion`) run after the blank check, on the page as scanned, and only on pages collected in the queue; `TaskCatalog.apply` turns `autoStraighten` on for `.twoSided` only and `autoCrop` off for every task. A changed page keeps the page as scanned as its `alternate`; `AdjustmentStep` adjusts both, `spoolPages` writes both (`<id>.tiff` and `<id>-other.tiff`, Windows `.png`) and keeps the hidden one's pixels only when its file could not be written, `rotatePage` turns the alternate's pixels in memory, and deleting a page's spool files deletes both. `AppState.togglePageGeometry(id:)` (Windows `AppViewModel.TogglePageGeometry`) shows the other version: its preview is read from its spool file off the main actor, turned like the page, and swapped in only if the page is still queued as it was; saving writes whichever version is shown. The status after a scan adds `PageCorrections.scanNote`.

### Pipeline/DocumentGeometry.swift

```swift
public enum TextAxis: Sendable { case unknown, horizontal, vertical }
public struct TextLayout: Equatable, Sendable {
    public let axis: TextAxis; public let skewDegrees: Double; public let confidence: Double; public let inkPoints: Int
    public var isConfident: Bool                   // axis known, inkPoints >= minInkPoints, confidence >= minConfidence
    public static let nothing: TextLayout
}
public enum GeometryBasis: Sendable { case pageEdges, textLines }
public enum GeometryAction: Sendable { case cropStraightened, cropBox, rotate }
public struct PageGeometry: Equatable, Sendable {  // not persisted
    public let cropped: Bool; public let angleDegrees: Double; public let basis: GeometryBasis
    public var straightened: Bool                  // angleDegrees != 0
    public var caption: String                     // "Cropped and straightened 2.4°", "Straightened 1.5°", "Cropped"
}
public struct GeometryPlan {                       // in analysis pixels
    public let action: GeometryAction; public let angleDegrees: Double; public let basis: GeometryBasis
    public let page: DetectedPhotoRegion?; public let canvas: CGSize; public let text: TextLayout?
    public var geometry: PageGeometry
}
public struct GeometryCorrection { public let image: RgbaImage; public let geometry: PageGeometry; public let plan: GeometryPlan; public let region: DetectedPhotoRegion }
public enum PageRejection: Sendable { case none, nothingFound, tooSmall, fillsScan, notRectangular, textAround, otherObjects }
public struct PageSearch {
    public let page: DetectedPhotoRegion?; public let rejection: PageRejection; public let candidate: DetectedPhotoRegion?
    public let areaFraction: Double; public let fill: Double; public let outsideMarks: Int
    public let touchesBorder: Bool; public let hull: [CGPoint]
    public static let nothing: PageSearch
}
public enum DocumentGeometry {
    // Page edges: borderRingFraction 0.02, borderRingInches 0.03, scanEdgeInches 0.02, pageContrast 0.045,
    // backdropSpread 3.7, closeRadius 3, openRadius 2, minPageAreaFraction 0.15, maxPageAreaFraction 0.99,
    // maxBorderContact 0.1, minPageFill 0.9, maxPageAspect 5, minOutsideMarkPixels 6, maxOutsideMarks 8,
    // maxOutsideObjectFraction 0.02. Text lines: inkContrast 0.30, maxGlyphSide 60, minGlyphPixels 3,
    // maxInkPoints 150_000, minInkPoints 2000, maxTextSkewDegrees 7, coarseStepDegrees 0.5,
    // fineStepDegrees 0.05, minConfidence 0.15, axisMargin 1.25. Corrections: minCorrectionDegrees 0.2,
    // maxPageAngleDegrees 15, maxLostContentPixels 4, refineTolerance 4, edgeTrimInches 0.04, edgeTrimDrop 0.03.
    public static func angleText(_ degrees: Double) -> String                 // "2.4°", halves rounded up
    public static func correct(_ image: RgbaImage, dpi: Int, crop: Bool, straighten: Bool) -> GeometryCorrection?
    public static func plan(_ gray: GrayImage, crop: Bool, straighten: Bool) -> GeometryPlan?
    public static func rectAtAngle(_ points: [CGPoint], angleDegrees: Double) -> DetectedPhotoRegion
    public static func detectPage(_ gray: GrayImage) -> DetectedPhotoRegion?   // findPage(gray).page
    public static func findPage(_ gray: GrayImage) -> PageSearch
    public static func ringWidth(_ w: Int, _ h: Int, dpi: Double) -> Int
    public static func backgroundLuminance(_ gray: GrayImage) -> Int
    public static func borderColor(_ image: RgbaImage, dpi: Int) -> (r: UInt8, g: UInt8, b: UInt8)
    public static func safeCanvas(_ gray: GrayImage, angleDegrees: Double) -> CGSize
    public static func estimateTextLayout(_ gray: GrayImage) -> TextLayout
    // internal: median3x3, edgeInsets(_:dpi:) -> (left, top, right, bottom)
}
```
Twin of `windows/CompleteScanner.Core/DocumentGeometry.cs` (`TextAxis`, `TextLayout`, `GeometryBasis`, `GeometryAction`, `PageGeometry`, `GeometryPlan`, `GeometryCorrection`, `PageRejection`, `PageSearch`, `DocumentGeometry` with the same members in PascalCase); `DocumentGeometryTests` are the same cases on both sides, on the same synthetic pages (`TestPages.textPage`, `turned`, `sheetOnBackdrop`, drawn with fixed-point sines and cosines, checked by checksum). Everything works on the page's gray copy at the analysis resolution and changes the full-resolution pixels once (`RgbaImage.extractRotated` or `cropped`), so both platforms compute the same plan; the full-resolution snap of the sheet's edges goes through `PhotoDetector.refineRegion`, which draws with CoreGraphics on the Mac and with `RgbaImage` on Windows, and is only taken when no edge moves by more than `refineTolerance` analysis pixels. The rules: the backdrop is the median of a thin outer ring, with a threshold widened on textured backdrops; the sheet is the largest region of what differs from it (closed, holes filled, strands cut), taken only when it covers 15–99 % of the scan, fills ≥ 90 % of its rectangle, is at most 5 times as long as wide, has no more than 8 text-like marks around it and nothing beside it as large as 2 % of it; a sheet with more than 10 % of its outline on the scan's edge takes its angle from the text and its crop is the smallest rectangle at that angle around it; a sheet's edges win over the text; turns under 0.2° are left alone, sheets beyond 15° are cropped along their box, text skew is searched over ±7° (a best angle at the end of the sweep is not trusted); turning a scan in place never cuts off content from its corners (the canvas grows instead, its outermost 0.02 in excepted); and the dark lines along the edges of an upright crop (shadow, backdrop) are trimmed, at most 0.04 in.

### Pipeline/IdCard.swift (+ TaskOptions in Core/Models.swift), App/AppState+IdCard.swift

```swift
// ScanSettings gains `taskOptions: TaskOptions` ("taskOptions"; `TaskCatalog.apply` keeps it).
public struct TaskOptions: Codable, Equatable, Sendable {
    public var idCardPaper: IdCardPaper = .auto               // "idCardPaper"
    public var idCardSaveSidesAsImages: Bool = false          // "idCardSaveSidesAsImages"
    public var copyCount: Int = 1                             // "copyCount"; read through PrintCopies.clamp (1...99)
    public var copyFitToPage: Bool = false                    // "copyFitToPage"
    public var copyPrinterName: String?                       // "copyPrinterName"; nil: the default printer (left out of the file)
    public var copyAlsoSavePdf: Bool = false                  // "copyAlsoSavePdf"
}
public enum IdCardPaper: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, a4, letter                                     // first case = default and fallback
    public var label: String                                  // "Automatic", "A4", "Letter"
}
public enum IdCardPapers {
    /// .auto: `printerPaper` (the default printer's) when it is .a4 or .letter, else PaperSizes.defaultForRegion
    public static func resolve(_ paper: IdCardPaper, regionCode: String?, printerPaper: PaperSize? = nil) -> PaperSize
    public static func choiceLabel(_ paper: IdCardPaper, regionCode: String?, printerPaper: PaperSize? = nil) -> String  // "Automatic (A4)", "Letter"
}
public enum IdCardSteps {
    public static let frontStepID = "front", backStepID = "back", reviewStepID = "review"
    /// "Scan front"; "Scan back" (skippable, no capture required); "Review" (no capture required).
    public static let steps: [TaskStep]
    public static func sideOf(_ stepID: String?) -> PageSide?
    public static func stepID(_ side: PageSide) -> String
    /// Only the back of an ID card offers Skip; never the backs of a stack turned over by hand
    /// (skippable in `DocumentSides.manualSteps`, left out with Keep Fronts Only).
    public static func offersSkip(_ step: TaskStep?) -> Bool
}
/// What a scan a side was found on covers: resolution, size in pixels, selection (nil: whole glass).
public struct IdCardScanArea: Equatable { dpi: Int; pixelSize: CGSize; selection: CGRect? }
public enum IdCardPickKind: Sendable { case card, largestRegion, frontPlace, wholeScan }
public struct IdCardPick: Equatable {
    public let region: DetectedPhotoRegion; public let kind: IdCardPickKind
    public var needsManualCrop: Bool                          // .wholeScan
    public var note: String?                                  // what to check; nil for .card
}
public enum IdCardDetector {
    // cardLongSideInches 3.370, cardShortSideInches 2.125 (ID-1, 85.60 × 53.98 mm), cardAspect,
    // minLongSideInches 2.5, maxLongSideInches 6.0, minSideInches 1.5, maxRegions 4
    public static func detectionOptions() -> PhotoDetectorOptions        // min side 1.5 in, 4 regions
    public static func score(_ region: DetectedPhotoRegion, dpi: Int) -> Double   // |aspect − 1.586| / 1.586 + |long side − 3.370| / 3.370
    public static func qualifies(_ region: DetectedPhotoRegion, dpi: Int) -> Bool // long side 2.5 ... 6.0 in
    /// The qualifying region with the lowest score (the first of equals); else `fallback`; else the
    /// largest region; else the whole scan.
    public static func pickCard(_ regions: [DetectedPhotoRegion], dpi: Int, imageSize: CGSize,
                                fallback: DetectedPhotoRegion? = nil) -> IdCardPick
    public static func wholeScan(_ imageSize: CGSize) -> DetectedPhotoRegion
    public static func flippedInPlace(_ region: DetectedPhotoRegion) -> DetectedPhotoRegion   // same place, tilt mirrored
    /// `flippedInPlace` scaled by back dpi / front dpi; nil when the selections differ or the sizes
    /// differ once the resolution is allowed for (more than 2 px or 1 %).
    public static func frontPlaceOnBack(_ frontRegion: DetectedPhotoRegion, front: IdCardScanArea,
                                        back: IdCardScanArea) -> DetectedPhotoRegion?
    public static func detect(_ image: CGImage, dpi: Int, fallback: DetectedPhotoRegion? = nil) -> IdCardPick
    public static func extract(_ image: CGImage, pick: IdCardPick) -> CGImage   // cut out straight; the scan when that fails
    public static func note(_ kind: IdCardPickKind) -> String?
}
public struct IdCardLayoutResult: Equatable { front: CGRect; back: CGRect?; scale: Double; var scaledToFit: Bool }   // inches, top-left
public enum IdCardLayout {
    // topMarginInches 1.0, gapInches 0.5, edgeMarginInches 0.25, notRealSizeMessage
    /// Centred across, the front 1 in from the top, the back 0.5 in under it, at real size; both
    /// made smaller by one factor when they would come closer than 0.25 in to an edge.
    public static func place(front: CGSize, back: CGSize?, paper: CGSize) -> IdCardLayoutResult
    public static func caption(paper: PaperSize, hasBack: Bool, scaledToFit: Bool) -> String   // "Front and back on one A4 page, at real size."
}
public struct IdCardSide: Equatable, Sendable { image: RgbaImage; dpi: Int; var inches: CGSize }
public enum IdCardComposer {
    public static let maxPageDPI = 600
    public static func pageDPI(_ sideDPI: Int) -> Int          // the page is composed and saved at min(scan dpi, 600)
    public static func canvasSize(paperInches: CGSize, dpi: Int) -> (width: Int, height: Int)   // round(paper × dpi)
    /// White page with each side copied into its place, resampled only when its place in pixels
    /// differs from its size. Saved at `dpi`, the page is the paper size: the sides print at real size.
    public static func compose(front: IdCardSide, back: IdCardSide?, dpi: Int, paperInches: CGSize) -> RgbaImage
    public static func sideFileBase(_ baseName: String, side: PageSide) -> String   // "ID card 2026-10-19 front"
}
```
Twin of `windows/CompleteScanner.Core/IdCard.cs` (`IdCardPaper`, `IdCardPapers.Resolve` / `ChoiceLabel` / `Label` / `RawValue`, `IdCardSteps.FrontStepId` / `Steps` / `SideOf` / `StepId` / `OffersSkip`, `IdCardScanArea`, `IdCardPickKind`, `IdCardPick`, `IdCardDetector`, `IdCardLayoutResult`, `IdCardLayout`, `IdCardSide`, `IdCardComposer`) and `TaskOptions` in `Models.cs`; `IdCardTests` are the same cases on both sides, on the same synthetic beds, and the task-options cases of `ModelsCompatTests`, the ID card cases of `ScanTaskTests` and `MockScannerTests` match. The task (`ScanTask.idCard`, flow `.idCard`, flatbed only, 300 dpi color PDF, not searchable, "ID card {date}") is guided by `IdCardSteps.steps`. `AppState.performScan` scans the whole glass for it (no paper-size area), finds the card on the scan the step is at (`IdCardDetector.detect`; a back that does not stand out takes the front's place, `frontPlaceOnBack`, only when both scans cover the same part of the glass: `idCardScanAreas`) and records it (`recordIdCardSide`): the front moves on to the back, a front scanned again goes past a back already scanned or skipped, and once the sides are in the review opens (`showIdCardReview`, `UI/IdCardReviewView.swift`; Scan at the review step opens it again). ID card scans are never spooled and never added to the scan history; their scans stay in memory (`idCardSourceImages`, read by `photoSource(for:)`) only while the sides do, so the crop editor works on them unchanged (`recropPhoto` routes a side to `recropIdCardSide`). `AppState+IdCard.swift`: `idCardFront`, `idCardBack`, `idCardFrontNote`, `idCardBackNote`, `idCardPreview` (the page at 40 dpi), `idCardLayoutCaption`, `idCardSizeWarning`, `isIdCardFlow`, `hasIdCardCaptures`, `idCardPaperSize` (`regionCode`: the user's region; `defaultPrinterPaper`: the default printer's), `idCardPaperChoiceLabel(_:)`, `rotateIdCardSide(_:)`, `swapIdCardSides()`, `retakeIdCardSide(_:)`, `setIdCardPaper(_:)`, `refreshIdCardPreview()`, `saveIdCard()` (the page as a PDF or in the chosen image format at `IdCardComposer.pageDPI`, at most 600 dpi, and each side as an image at the scan's resolution when `idCardSaveSidesAsImages`; all or nothing) and `discardIdCard()`. Saving, discarding, leaving the task or picking a task again drops everything of the card from memory and clears the stage, also when no side was held (a scan whose card was not found, a cancelled one, a preview) (`clearIdCard(clearCanvas:)`). While a side is held: the app's own scanner switches wait (`autoSwitchMustWait` in `mergeDevices`/`endOfWork`; Windows `AutoSwitchMustWait`, also for `ChooseConnection`, `SelectAddedDevice` and the certificate fallback), the inspector's Mode and Source are disabled, and leaving the task, picking a task or applying a preset goes through `leaveIdCard(then:)`, which asks Discard / Cancel (`pendingIdCardLeave`, an alert in `ContentView`; `discardIdCard(andThen:)`; Windows `MainWindow.ConfirmDropIdCard`). None of these is possible while a scan runs (the banner's leave button is disabled then, and `exitTask()` and `leaveIdCard(then:)` refuse), and a scan of the card that still finishes outside the steps keeps nothing: `recordIdCardSide` drops it and clears the stage (`dropIdCardScanOutsideTask()`; Windows `CaptureIdCardSide`, `DropIdCardScanOutsideTask`), so a side is never held without the task. Skip is offered only for the card's back (`canSkipStep`). Windows has the same members in `AppViewModel` (`IdCardFront` / `IdCardBack` as `PhotoItem`, `RecropIdCardSide`, `IdCardSource`, `SetIdCardSaveSidesAsImages`, `SaveIdCard`, `DiscardIdCard`, `SkipStep`, `IdCardPaperChoiceLabel`) and the review as an overlay in `MainWindow.xaml`. The review's Print prints the page (`printIdCard()`, see Copy and print below); Automatic paper is the default printer's paper when that is A4 or Letter (`PaperSizes.match` of what the print system reports), else the region's.

### Output/PrintLayout.swift, App/PrintController.swift, App/AppState+Copy.swift

```swift
public enum PrintMode: Sendable { case actualSize, fitToPrintable }
public enum PrintAlign: Sendable { case paperOrigin, center }
/// Inches, origin at the paper's top-left corner, portrait as fed.
public struct PrinterPaper: Equatable, Sendable {
    public let paper: CGSize; public let printable: CGRect
    public static func make(paper: CGSize, printable: CGRect?) -> PrinterPaper   // clamped; nil or empty: the whole sheet
    public var size: PaperSize?                  // PaperSizes.match(paper)
    public var largestMargin: Double
    public var description: String               // "Letter (8.5 × 11 in)", "8.27 × 11.69 in"
}
public struct PrintPlacement: Equatable, Sendable {
    public let rect: CGRect                      // inches on the paper, top-left origin
    public let scale: Double; public let quarterTurns: Int; public let clippedInches: Double
    public var isClipped: Bool                   // clippedInches > PrintLayout.clipWarningInches (0.05)
}
public enum PrintLayout {
    /// Actual size: pixels / dpi, at the paper's corner or centred on the paper, turned a quarter only
    /// when that cuts off less; clippedInches = how far it runs past the printable area. Fit: smaller
    /// only, min(pw / w, ph / h, 1) of the printable area, turned when that scales larger, centred in it.
    public static func place(pixelWidth: Int, pixelHeight: Int, dpi: Int, paper: CGSize, printable: CGRect,
                             mode: PrintMode, align: PrintAlign) -> PrintPlacement
    public static func place(pixelWidth: Int, pixelHeight: Int, dpi: Int, on paper: PrinterPaper,
                             mode: PrintMode, align: PrintAlign) -> PrintPlacement
    public static func clippedInches(_ rect: CGRect, printable: CGRect) -> Double     // worst side, 0 inside
    public static func toUnits(_ inches: CGRect, unitsPerInch: Double) -> CGRect       // 96 WPF, 72 points
    public static func toUnits(_ inches: CGSize, unitsPerInch: Double) -> CGSize
    public static func align(hasSelection: Bool) -> PrintAlign                         // selection: .center
    /// "Larger than the paper: up to 6 mm is cut off. Turn on Fit to page to print all of it." or
    /// "Edges may be cut by up to 7 mm (printer margins)."; nil when nothing worth saying is cut off.
    public static func clipWarning(_ placement: PrintPlacement, paper: CGSize) -> String?
    public static func millimetres(_ inches: Double) -> Int                            // rounded up, at least 1
}
public struct PrintCopiesPlan: Equatable, Sendable { ticketCopies: Int; documentRepeats: Int }
public enum PrintCopies {
    public static let maxCount = 99
    public static func clamp(_ count: Int) -> Int
    /// The printer makes the copies when it says it can make that many and, for more than one page, that
    /// it collates; else the pages are repeated in the job.
    public static func plan(requested: Int, maxCopyCount: Int?, pageCount: Int = 1, canCollate: Bool = true) -> PrintCopiesPlan
}
public enum PrintCalibration {
    /// White, round(paper × dpi); grey 1-inch grid from the corner; black cm ticks (0.15 in, 0.3 in every
    /// 5 cm) along the first inch line across and down; lines lineWidth(dpi) = round(dpi / 150) ≥ 1.
    public static func makeRulerPage(paper: CGSize, dpi: Int) -> RgbaImage
    public static func lineWidth(_ dpi: Int) -> Int
    public static func tickPosition(_ k: Int, dpi: Int) -> Int                          // round(dpi + k × dpi / 2.54)
}
public enum PrintText {
    public static let noPrinterReason: String     // "No printer is installed."
    public static let noPrinterMessage: String    // "No printer is installed. Add a printer, then try again."
    public static func sent(pageCount: Int, copies: Int, printerName: String) -> String  // "Sent 2 pages to X, 3 copies."
    public static func modeLabel(fitToPage: Bool) -> String                            // "Actual size", "Fit to page"
    public static func copyPaperHint(_ size: PaperSize, source: ScanSource) -> String   // Automatic on the glass: the printer's paper
}

// App/PrintController.swift (the system side, injected into AppState so tests can stand in for it)
public struct PrintPage { image: CGImage; dpi: Int; placement: PrintPlacement }
public struct PrinterSetup: Equatable, Sendable { printerName: String; paper: PrinterPaper }
public struct PrintJob { printerName: String?; jobName: String; paper: PrinterPaper; copies: Int }
public enum PrintError: LocalizedError, Equatable { case noPrinter, failed(String) }   // not a ScanError
@MainActor public protocol PrintService: AnyObject {
    var printerNames: [String] { get }
    var defaultPrinterName: String? { get }
    func setup(printerName: String?, requestedPaper: PaperSize?) -> PrinterSetup?   // nil: no printer
    func print(_ document: Data, job: PrintJob) throws -> Bool                     // the print panel; false: cancelled
}
public enum PrintDocument { static func makePDF(pages: [PrintPage], paper: CGSize) -> Data? }   // a page the size of the paper per page
@MainActor public final class SystemPrintService: PrintService { public init() }   // the paper asked for only when the printer has it (`PrinterPapers.offers`)
```
Twins of `windows/CompleteScanner.Core/PrintLayout.cs` (`PrintMode`, `PrintAlign`, `PrinterPaper.Make` / `Size` / `LargestMargin` / `Description`, `PrintPlacement`, `PrintLayout.Place` / `ClippedInches` / `ToUnits` / `AlignFor` / `ClipWarning` / `Millimetres`, `PrintCopiesPlan`, `PrintCopies`, `PrintCalibration`, `PrintText.CopyPaperHint`) and `PaperSizes.Match`; `PrintLayoutTests` are the same cases on both sides, and the copy cases of `ScanTaskTests`, `ModelsCompatTests`, `PaperSizeTests` and `IdCardTests` match. The print system side has no twin: the Mac (`PrintService`, `PrintDocument`, checked by `PrintDocumentTests.swift`, which draws the PDF back into pixels) prints through `PDFDocument.printOperation(for:scalingMode: .pageScaleNone, autoRotate: false)` and the standard print panel, set to the printer, paper (`NSPrintInfo.paperSize`), copies and zero margins; Windows (`windows/CompleteScanner.App/Services/PrintService.cs`: `IPrintService`, `WindowsPrintService`, `PrintDocument`, checked by `windows/CompleteScanner.App.Tests/PrintDocumentTests.cs`, which writes the document to an XPS file and reads it back) sends the job with no dialog through System.Printing and the XPS print path: the queue's own ticket, portrait, 100 % scaling, the paper asked for when the printer lists it, and, whatever the printer's saved preferences say (`WindowsPrintService.ApplyJobSettings`), the copy count of `PrintCopies.plan` (collated; the pages repeated in the job when `MaxCopyCount` is too low or several pages would not be collated, `PrinterSetup.CanCollate`), one page per sheet, one-sided printing, grey output for a grey scan and colour for a colour one; one paper-sized page per page with the image at its placement in 1/96 in, drawn as the writer asks for it, as a plain bitmap (a JPEG-backed one would be stored once and printed on every page). The Copy task (`ScanTask.copy`, flow `.copy`, any source, 300 dpi color, PDF not searchable, "Copy {date} {counter}", step "Make a copy" with the button "Copy") reads the printer first (`setupForPrinting`: the chosen printer, else the default; nil throws `PrintError.noPrinter`); on the glass with nothing selected and Automatic paper it scans the part of the glass the printer's paper covers (`copyScanArea`); the pages are processed as any scan (no blank-page check, no crop; the inspector's blank-page, crop and straighten switches are off for the task and say "Copies print every page as scanned: …"), recorded in the history and never queued or spooled, then printed (`printCopyPages`): each placed at real size against the corner, centred for an area selected on the preview, or fitted with `copyFitToPage`; `copyCount` copies; also saved as a PDF with `copyAlsoSavePdf` once printed, and also when printing failed (the pages are kept nowhere else; the print error then says what became of the PDF), a Cancel while it is written giving "Sent …. PDF not saved (cancelled)."; the status is `PrintText.sent` plus the first `clipWarning`. `AppState+Copy.swift`: `printerNames`, `defaultPrinterPaper`, `copySetup` (stored in AppState.swift), `hasPrinter`, `isCopyFlow`, `copyPrinterName`, `copyPaperText`, `copyMarginWarning`, `refreshPrinters()` (at start, each time the app becomes active, when the Copy task is picked and with Look Again; only reads), `setCopyPrinter(_:)` (the default printer stores nil), `setCopyCount(_:)`, `setCopyFitToPage(_:)`, `setCopyAlsoSavePdf(_:)`, `printIdCard()` (the page composed on the printer's paper at `IdCardComposer.pageDPI`, one copy; the review stays open; the warning when the margins reach a card) and `printRulerPage()` (300 dpi, actual size, from the corner). `AppState` takes an optional `printService:` (default `SystemPrintService()`). Windows has the same members in `AppViewModel.Copy.cs` (`Printers`, `HasPrinter`, `IsCopyFlow`, `CopyPrinterName`, `CopyPaperText`, `CopyMarginWarning`, `RefreshPrintersAsync`, `PrintersMayHaveChanged` (the window back in front, the start screen shown; a print system that cannot be read leaves `HasPrinter` true), `SetCopyPrinter`, `SetCopyCount`, `SetCopyFitToPage`, `SetCopyAlsoSavePdf`, `PrintIdCard`, `PrintRulerPage`; the constructor's optional `printService`), the Copies section of the inspector and the review's Print button in `MainWindow.xaml` / `MainWindow.Copy.cs`. Printing errors are not scanner failures: the troubleshooter does not record them.

### Pipeline/PhotoDetector.swift (+ Pipeline/Geometry.swift)

```swift
public struct PhotoDetectorOptions {
    public var minPhotoSideInches: Double = 1.0
    public var maxPhotoCount: Int = 20
    /// Pixels (at full scan resolution) shaved off each edge of the detected rect before extraction.
    public var edgeInsetPixels: Int = 0
    public init() {}
}

public enum PhotoDetector {
    /// Find distinct photos lying on a flatbed scan. Regions are in full-resolution pixel
    /// coordinates of `image`, sorted top-to-bottom then left-to-right.
    public static func detectRegions(in image: CGImage, dpi: Int, options: PhotoDetectorOptions = PhotoDetectorOptions()) -> [DetectedPhotoRegion]
    /// Crop (and if `deskew`, rotate to upright) one region out of the source scan.
    public static func extractPhoto(from image: CGImage, region: DetectedPhotoRegion, deskew: Bool) -> CGImage?
    /// Internal (also used by DocumentGeometry): one region snapped to the edges at full resolution; nil when degenerate.
    static func refineRegion(_ region: DetectedPhotoRegion, in image: CGImage, backgroundLuminance bg: Double) -> DetectedPhotoRegion?
}
```

### Pipeline/ImagePipeline.swift

```swift
public enum ImagePipeline {
    /// Apply adjustments + color-mode conversion. Returns the input unchanged when
    /// `settings.isIdentity && colorMode == .color`.
    public static func apply(_ settings: AdjustmentSettings, to image: CGImage, colorMode: ColorMode) -> CGImage
    /// Lossless 90° steps, clockwise. quarterTurns 0...3.
    public static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage
}
```

### Persistence/PresetStore.swift

```swift
public final class PresetStore {
    public init()
    /// Loads saved presets; on first run returns (and persists) an empty list. (Earlier versions
    /// seeded five starter presets; files holding them keep them. The task cards replace them.)
    public func load() -> [Preset]
    public func save(_ presets: [Preset])
}

public enum SettingsStore {
    public static func load() -> ScanSettings?
    public static func save(_ settings: ScanSettings)
}
```
Storage: JSON under `~/Library/Application Support/CompleteScanner/` (`presets.json`, `settings.json`).

### Output/PDFBuilder.swift

```swift
/// A page's text layer: called with its index and its prepared page (full pixels, rotation
/// applied, full-resolution size) before it is drawn; nil draws none.
public typealias PDFTextLayer = (_ index: Int, _ page: PDFBuilder.PreparedPage) -> [OCRLine]?

public enum PDFBuilder {
    public struct PreparedPage { image: CGImage; pixelWidth: Int; pixelHeight: Int }
    /// The spill file's full pixels with the page's rotation, else the in-memory image; the size
    /// from the recorded full-resolution size. Twin of C# `PdfBuilder.PreparePage`.
    public static func preparePage(_ page: ScannedPage) -> PreparedPage
    /// Multi-page PDF; each page sized pixels/dpi*72 points. When `searchable`, run OCR per page
    /// (on the full pixels) and draw an invisible text layer aligned with the words. Each page
    /// image is stored as `pdfSize` plans it (`PDFImageEncoding.encodedPage`).
    public static func makePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                               pdfSize: PDFSizePreset = .best,
                               progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws -> Data
    /// Same, but streamed straight to `url` (never holds the whole document in memory).
    public static func writePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                                pdfSize: PDFSizePreset = .best,
                                to url: URL, progress: ((String) -> Void)?,
                                shouldContinue: (() -> Bool)? = nil) throws
    /// The text layer read beforehand: `ocrLines[i]` on page `i` (nil, or past the end: none). No OCR runs.
    public static func makePDF(pages: [ScannedPage], ocrLines: [[OCRLine]?], pdfSize: PDFSizePreset = .best,
                               progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws -> Data
    public static func writePDF(pages: [ScannedPage], ocrLines: [[OCRLine]?], pdfSize: PDFSizePreset = .best,
                                to url: URL, progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws
    /// Each page's text layer from `textLayer` (none when nil): the app's one OCR pass per save.
    public static func makePDF(pages: [ScannedPage], pdfSize: PDFSizePreset = .best, progress: ((String) -> Void)?,
                               shouldContinue: (() -> Bool)? = nil, textLayer: PDFTextLayer?) throws -> Data
    public static func writePDF(pages: [ScannedPage], pdfSize: PDFSizePreset = .best, to url: URL,
                                progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil,
                                textLayer: PDFTextLayer?) throws
}
```
The `searchable:` overloads are kept for existing callers (OCR on every page when searchable). The app saves through the `textLayer:` overload so OCR reads each page once per save, for the text layer and for the text file beside the PDF (`output.alsoSaveText`). Windows has no twin of these overloads: its view model reads the pages with OCR and hands `PdfBuilder` the lines in `PdfPageInput`.

### Output/OCRText.swift, TextExport.swift, DocxWriter.swift, ZipStore.swift (+ OutputFormat, OutputOptions in Core/Models.swift)

```swift
// OutputFormat gains `.text` ("Text (.txt)", txt) and `.word` ("Word (.docx)", docx), after the
// earlier cases, and:
//   isImageFormat (jpeg, png, tiff), isTextFormat (text, word),
//   static offered(for: ScanIntent) -> [OutputFormat]   // documents: pdf, word, text, jpeg, png, tiff; photos: jpeg, png, tiff
//   imageFormatOrJPEG (what a photo is saved as), queueFormat (collected pages: text and word as chosen, else pdf),
//   pageFormat (the ID card's page: pdf or the image format), savesPDF(collectsPages:) -> Bool,
//   saveTitle ("Save PDF", "Save Word", "Save Text"), saveTitle(pageCount:) ("Save Word (3 pages)").
// Every switch over OutputFormat lists the new cases (ImageExporter throws ScanError.unsupported for them).
// OutputOptions gains `alsoSaveText: Bool` ("alsoSaveText" in the "output" object; false by default and
// for files written before it existed): a .txt with the PDF's name beside each saved PDF.

public struct OCRPage { lines: [OCRLine]; widthPoints: Double; heightPoints: Double     // any one unit
    public static func of(_ lines: [OCRLine], pixelWidth: Int, pixelHeight: Int, dpi: Int) -> OCRPage }
public struct OCRParagraph { public let lines: [OCRLine]; public var text: String }    // paragraphText(lines)
public enum OCRText {
    // columnGap 2, blockGap 1.5, tableGapShare 1, sameRowOverlap 0.5 (line heights / shares);
    // paragraphGap 0.75, paragraphGapFactor 1.5, indentLines 1, leftEdgeShift 0.2, shortLineShare 0.15,
    // centredLines 0.25, jumpLines 0.5; cellSeparator "\t".
    /// Recursive X-Y cut: a gap across ≥ blockGap line heights first, else a gap down ≥ columnGap
    /// between two columns of text (≥ 2 lines a side, not a table), else any gap across; a row's
    /// lines joined by " " (a tab across ≥ columnGap); empty lines dropped; ties broken by the engine's order.
    public static func readingOrder(_ lines: [OCRLine], pageWidth: Double = 1, pageHeight: Double = 1) -> [OCRLine]
    public static func paragraphs(_ page: OCRPage) -> [OCRParagraph]
    public static func paragraphs(_ ordered: [OCRLine], pageWidth: Double = 1, pageHeight: Double = 1) -> [OCRParagraph]
    public static func paragraphText(_ lines: [OCRLine]) -> String    // wrapped lines joined, short lines and table rows keep "\n"
    public static func joinLines(_ lines: [String]) -> String         // "forward-" + "ing" -> "forwarding"
    public static func pageText(_ page: OCRPage) -> String            // a line per line, "\n\n" between paragraphs
    public static func plainText(_ pages: [OCRPage]) -> String        // "\n\n\n" between pages, "\n" at the end; "" without text
    public static func cleanLine(_ text: String) -> String
}
public enum TextExport {
    public static func encode(_ pages: [OCRPage]) -> Data             // UTF-8, no BOM, LF
    public static func hasText(_ pages: [OCRPage]) -> Bool
    public static func savedMessage(format: OutputFormat, pageCount: Int, fileName: String, hasText: Bool) -> String
    public static func sidecarSuffix(_ textFileName: String) -> String    // " and its text, Scan 1.txt"
    public static func recognitionFailed(_ ocrMessage: String) -> String  // "The text could not be read: …"
    public static func sidecarFailed(_ message: String) -> String         // "The PDF was saved, but not its text file: …"
    public static func copiedMessage(pageNumber: Int, hasText: Bool) -> String
}
public struct TextOutputError: LocalizedError, Equatable { public init(_ message: String) }   // not a ScanError
public enum DocxWriter {
    public static let twipsPerInch = 1440, minPageTwips = 144, maxPageTwips = 31680
    public static let contentTypesXML: String, relationshipsXML: String
    public static func make(_ pages: [OCRPage]) -> Data                // [Content_Types].xml, _rels/.rels, word/document.xml
    public static func documentXML(_ pages: [OCRPage]) -> String       // a w:p per paragraph, pageBreakBefore per page, w:tab, w:br
    public static func pageSizeTwips(_ page: OCRPage?) -> (width: Int, height: Int)   // page 1 × 20, clamped; Letter without a page
    public static func marginTwips(width: Int, height: Int) -> Int    // min(1440, shorter side / 8)
    public static func escapeXML(_ text: String) -> String
}
public struct ZipStoreEntry { public let name: String; public let data: Data }
public enum ZipStore {
    public static func crc32<Bytes: Sequence>(_ data: Bytes) -> UInt32 where Bytes.Element == UInt8
    public static func make(_ entries: [ZipStoreEntry]) -> Data       // stored, 1980-01-01, in order, no zip64
}
```
Twins of `windows/CompleteScanner.Core/OcrText.cs` (`OcrPage.Of`, `OcrParagraph`, `OcrText`), `TextExport.cs`, `DocxWriter.cs`, `ZipStore.cs` and `OutputFormats` in `Models.cs` (`IsImageFormat`, `IsTextFormat`, `Offered`, `ImageFormatOrJpeg`, `QueueFormat`, `PageFormat`, `SavesPdf`, `SaveTitle`); `OCRTextTests`, `TextExportTests` (with `OutputFormatsTests`), `DocxWriterTests` (with `ZipStoreTests`) are the same cases on both sides, and both pin the same CRC-32 and length of the sample text file and Word document, so the two platforms write the same bytes. `TextExport.WriteNewFile` (a hidden temporary file moved to a free name) is Windows only; the Mac writes with `Data.write`. `AppState` saves the collected pages as `settings.format.queueFormat` (`savePDF()`: a Word document or text file, else a PDF and, with `alsoSaveText`, its text beside it), a scan saved at once as Text or Word too, reads each page with OCR once per save (`PDFTextLayer`), and offers `copyPageText(id:)` (Copy Text in a queued page's menu: the page's `OCRText.pageText` on the pasteboard). A page whose text cannot be read fails a Text or Word save with `TextOutputError(TextExport.recognitionFailed(…))`; for the text beside a PDF the PDF is kept and `errorMessage` is `TextExport.sidecarFailed(…)`. A scan saved at once as Text or Word whose text cannot be read, whose file cannot be written, or whose save is cancelled, is put in the queue instead of being lost (`statusMessage` is `TextExport.keptInQueue(…)`, with `textUnreadable` true only when the error is a `TextOutputError` from OCR, so a file error is not told to wait for the text; on Windows the OCR error is a private `InvalidOperationException` subclass in `AppViewModel`). `FileActionService` gains `copyText(_:)` (Windows: `IFileActions.CopyText`, with "\r\n" line breaks). Windows: `AppViewModel.SavePdf` / `CopyPageText`, the inspector's "Also save text (.txt)" and format list, the page strip's menu.

### Output/PDFImageEncoding.swift, Pipeline/ColorAnalysis.swift (+ ScanSettings in Core/Models.swift)

```swift
// ScanSettings gains `output: OutputOptions` (the "output" object; `OutputOptions.pdfSize`
// defaults to .standard, also for files written before it existed).
public enum PDFSizePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, best, compact, smallest     // first case = default and fallback
    public var label: String                   // "Standard", "Best", ...
    public var hint: String                    // one line, shown under the size picker
    public static let displayOrder: [PDFSizePreset]   // [.best, .standard, .compact, .smallest]
}

public enum ColorAnalysis {
    public static let sampleStep: Int          // 4: every 4th pixel of every 4th row
    public static let chromaThreshold: Int     // 32: max(R,G,B) − min(R,G,B) above this is color
    public static let maxColoredFraction: Double   // 0.001: gray when fewer samples are colored
    public static func isEffectivelyGray(_ image: CGImage) -> Bool
    public static func isEffectivelyGray(rgba: [UInt8], width: Int, height: Int) -> Bool
    public static func grayPixels(rgba: [UInt8], width: Int, height: Int) -> [UInt8]  // Rec. 601 luma
    public static func rgbaPixels(of image: CGImage) -> [UInt8]?   // sRGB RGBA8, row 0 = top
}

public enum PDFImageKind: Equatable, Sendable { case jpegColor, jpegGray }
public struct PDFSizeProfile: Equatable, Sendable { maxDPI: Int?, colorQuality, grayQuality: Double, autoGray: Bool }
public struct PDFImagePlan: Equatable, Sendable { targetDPI: Int, kind: PDFImageKind, quality: Double; var isGray: Bool }
public struct JPEGHeader: Equatable, Sendable { width, height, components: Int }

public enum PDFImageEncoding {
    public static let downsampleSlack = 1.1
    /// best: scan dpi, 0.90/0.90, no auto-gray; standard: 300 dpi, 0.80/0.80;
    /// compact: 200 dpi, 0.65/0.70; smallest: 150 dpi, 0.50/0.55 (color/gray quality; auto-gray on).
    /// The size alone sets the quality; the JPEG quality setting is for JPEG files only.
    public static func profile(_ size: PDFSizePreset) -> PDFSizeProfile
    /// Downsample only above maxDPI × 1.1; gray JPEG for gray and black & white pages and (except
    /// at best) for color pages without color; quality = the size's color or gray quality.
    public static func plan(mode: ColorMode, imageDPI: Int, size: PDFSizePreset, looksGray: Bool) -> PDFImagePlan
    public static func plan(mode: ColorMode, imageDPI: Int, size: PDFSizePreset, image: CGImage) -> PDFImagePlan
    public static func effectiveDPI(imageWidth: Int, pagePixelWidth: Int, pageDPI: Int) -> Int
    public static func targetSize(width: Int, height: Int, imageDPI: Int, targetDPI: Int) -> (width: Int, height: Int)
    public static func downsample(rgba: [UInt8], width: Int, height: Int, newWidth: Int, newHeight: Int) -> [UInt8]  // box filter
    // Mac only: ImageIO JPEG, read back as a JPEG-backed CGImage for the PDF context.
    public static func encodedPage(_ image: CGImage, imageDPI: Int, mode: ColorMode,
                                   size: PDFSizePreset) -> PDFPageImage?   // plan, jpegData, image
    public static func encodeJPEG(_ image: CGImage, quality: Double) -> Data?
    public static func readJPEGHeader(_ data: Data) -> JPEGHeader?
}
```
Twins of `windows/CompleteScanner.Core/PdfImageEncoding.cs` (`PdfSizePreset`, `PdfSizePresets.DisplayOrder`, `ModelLabels.Label` / `Hint`, `PdfSizeProfile`, `PdfImagePlan`, `PdfImageEncoding.Plan` / `EffectiveDpi` / `TargetSize` / `Downsample`) and `ColorAnalysis.cs` (`IsEffectivelyGray`, `GrayPixels`); `PdfImageEncodingTests` and `ColorAnalysisTests` are the same cases on both sides. `readJPEGHeader` is the twin of `PdfBuilder.TryReadJpegHeader`, which declares a one-component JPEG `/DeviceGray`. Windows encodes the planned JPEG with WIC (`WpfImageCodec.EncodeJpeg(image, dpi, quality, gray)`); black & white pages are gray JPEGs on both platforms until CCITT G4 exists.
Note: `ScannedPage.fileURL` (optional) points at a full-resolution spill TIFF; when set,
`page.image` is only a preview and PDFBuilder reloads the full pixels from the file per page.

### Core/SaveActions.swift (+ OutputOptions in Core/Models.swift), App/FileActions.swift

```swift
// OutputOptions gains `afterSave: AfterSaveAction` ("afterSave" in the "output" object; `.none`
// for files written before it existed and for an action this version does not know).
public enum AfterSaveAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, open, reveal, share             // first case = default and fallback
    public var label: String                   // "Do nothing", "Open", "Show in folder", "Share…"
    public var hint: String                    // one line, the picker's tooltip
}
public enum FileAction: String, CaseIterable, Identifiable, Sendable {
    case open, openWith, reveal, share, email, copy
    public var label: String                   // "Open", "Open with…", "Show in folder", "Share…", "Email…", "Copy"
}
public struct SaveFollowUp: Equatable, Sendable { action: AfterSaveAction; urls: [URL]; var fileAction: FileAction }
public struct ClipboardContent: Equatable, Sendable { files: [URL]; imageFile: URL? }
public enum SendRoute: Equatable, Sendable { case compose, shareSheet, showInFolder }
public struct SendProbe: Equatable, Sendable { canCompose: Bool; canShare: Bool }

public enum SaveActions {
    public static let showInFolderMessage: String
    /// nil for `.none` or no files; `.open` with several files becomes `.reveal` (no viewer per photo).
    /// Run only after a save that finished, never after a cancelled or failed one.
    public static func plan(_ action: AfterSaveAction, saved: [URL]) -> SaveFollowUp?
    /// One file: all six, in that order; several: reveal, share, email, copy; none: [].
    public static func offered(fileCount: Int) -> [FileAction]
    public static func isImageFile(_ url: URL) -> Bool                       // jpg, jpeg, png, tif, tiff
    /// The files, and the picture too for exactly one image file.
    public static func clipboardContent(for urls: [URL]) -> ClipboardContent
    public static func emailRoute(_ probe: SendProbe) -> SendRoute          // compose, else share sheet, else folder
    public static func shareRoute(_ probe: SendProbe) -> SendRoute          // share sheet, else folder
    public static func shareTitle(_ urls: [URL]) -> String                  // the file's name, or "3 files"
}

// App/FileActions.swift: the system side, injected into AppState so tests can stand in for it.
@MainActor public protocol FileActionService: AnyObject {
    func open(_ url: URL) throws
    func openWith(_ url: URL) throws                    // a menu of the apps that open the file, then "Other…"
    func reveal(_ urls: [URL])
    func sendProbe(for urls: [URL]) -> SendProbe        // compose = Mail can take the files
    func share(_ urls: [URL], title: String) throws     // NSSharingServicePicker
    func composeEmail(_ urls: [URL]) throws             // NSSharingService(named: .composeEmail)
    func copy(_ content: ClipboardContent) throws       // NSPasteboard: the files, and the picture of one image
    func copyText(_ text: String) throws                // NSPasteboard: Copy Text on a scanned page
}
@MainActor public final class SystemFileActions: FileActionService { public init() }
extension FileAction { var systemImage: String; func hint(fileCount: Int) -> String }   // internal, UI only
```
Twin of `windows/CompleteScanner.Core/SaveActions.cs` (`AfterSaveAction`, `FileAction`, `ModelLabels.Label` / `Hint`, `SaveFollowUp` with `Paths` and `FileAction`, `ClipboardContent`, `SendRoute`, `SendProbe`, `SaveActions.Plan` / `Offered` / `IsImageFile` / `ClipboardContentFor` / `EmailRoute` / `ShareRoute` / `ShareTitle`, paths as strings); `SaveActionsTests` are the same cases on both sides, and the after-save cases of `ModelsCompatTests` match. `AppState` takes an optional `fileActions:` (default `SystemFileActions()`), offers `savedFileActions` (for `lastSavedURLs`) and `runFileAction(_:urls:)`, which reports a missing file or a refusal in `errorMessage`, and runs the plan of `settings.output.afterSave` after `savePDF`, `saveImmediately` and `saveReviewedPhotos` finish. Windows (`App/Services/FileActions.cs`, `ShareService.cs`) has no compose route, so Email opens the share window there; nothing is ever sent without the user sending it. `TaskCatalog.apply` sets the after-save action: `.share` for the Email task, `.none` for the others.

### Output/OCRService.swift

```swift
public struct OCRLine {
    public let text: String
    /// Vision-normalized bounding box (origin bottom-left).
    public let boundingBox: CGRect
    public let confidence: Float
    public init(text: String, boundingBox: CGRect, confidence: Float)
}

public enum OCRService {
    public static func recognizeLines(in image: CGImage, languages: [String]) throws -> [OCRLine]
}
```

### Output/ImageExporter.swift

```swift
public enum ImageExporter {
    /// Write jpeg/png/tiff with DPI metadata. Throws ScanError.unsupported for .pdf, .text and .word.
    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, dpi: Int, jpegQuality: Double) throws
}
```

### Output/NamingTemplate.swift

```swift
public struct NamingTemplate {
    public let template: String
    public init(_ template: String)
    /// Tokens: {date}=yyyy-MM-dd, {time}=HH.mm.ss, {year} {month} {day}, {counter} (also {counter:N}
    /// zero-padded), {intent} ("Document"/"Photos"), {index} (photo number in a batch, empty when nil),
    /// {task} (the task's `fileLabel`; the {intent} text without a task).
    /// Unknown tokens pass through; result sanitized for the filesystem (no "/" or ":").
    public func baseFilename(_ context: NamingContext) -> String
    /// The same without a task (kept for existing callers).
    public func baseFilename(counter: Int, date: Date, intent: ScanIntent, index: Int?) -> String
    /// base.ext, appending " 2", " 3", … until the name is free.
    public static func uniqueURL(in directory: URL, base: String, fileExtension: String) -> URL
}
```

```swift
public struct NamingContext: Equatable, Sendable {
    public var counter: Int, date: Date, intent: ScanIntent
    public var index: Int?          // default nil
    public var task: ScanTask?      // default nil
    public init(counter: Int, date: Date, intent: ScanIntent, index: Int? = nil, task: ScanTask? = nil)
}
```
Twin of C# `NamingContext` (a record with `Index` / `Task` init properties). Later tokens add optional properties here, so `baseFilename(_:)` keeps its signature.

### Backends/ICScannerBackend.swift

```swift
public final class ICScannerBackend: NSObject, ScannerBackend { ... }
```
ImageCaptureCore implementation: `ICDeviceBrowser` (scanner mask, local + bonjour + shared), sessions via `ICScannerDevice` (see task brief).

### Backends/MockScannerBackend.swift

```swift
public final class MockScannerBackend: ScannerBackend { ... }
```
One demo device, `ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true)`; synthesizes deterministic flatbed images (see task brief). For the ID card task (`settings.task == .idCard`) its glass holds a made-up sample card (ID-1 size, rounded corners, "SAMPLE", a grey photo placeholder, field bars; a barcode and code blocks on the back; no real document and no flags), front down at (2.35, 1.75) in tilted 4°: a scan delivers the side facing the glass and then turns the card over where it lies (`idCardTurnedOver`, tilt mirrored), so scans alternate front, back; a preview shows the side without turning it (C# `IdCardTurnedOver`, drawn pixel by pixel there and with CoreGraphics here). It also has a document feeder (`sources: [.flatbed, .documentFeeder]`, `feederSizeInches` 8.5 × 14, `supportsDuplex` = `feederDuplex`, default true): a feeder scan returns `feederSheetCount` two-sided sheets (default `MockScannerBackend.defaultFeederSheetCount` = 3, read when the scan starts; letter size, or the paper size asked for; the front of sheet *n* carries *n* square marks near its bottom left corner, its back *n* marks near the bottom right, both upright), front and back of each sheet for `.both` on a two-sided feeder, otherwise the side facing up: a one-sided scan with `.manual` turns the stack over (`feederStackTurnedOver`), so the next one delivers the backs, last sheet first; any other feeder scan puts it back the right way up; a scan cut short by a jam leaves the stack as it is; `lastScanDuplex` says whether a scan asked for `.both` scanned both sides; and 0 sheets fails with `ScanError.scannerProblem(.feederEmpty)`. `feederJamsAfter` (default nil) makes the sheet after that many jam: the earlier sheets are returned and `lastScanStop` carries `.paperJam`; a jam on the first sheet fails with `ScanError.scannerProblem(.paperJam)`. `feederBlankBackSheets` (a `Set<Int>` of sheets counted from 0, default empty, read when the scan starts) makes those sheets' backs blank: off-white paper with noise, a few specks of dust and the front showing through mirrored at a tenth of its darkness (`BlankPageDetector` finds them blank; no sheet marks); the app's demo scanner (`AppState`'s default backends) has a blank back on its second sheet. Same behaviour as the C# `MockScannerBackend` (`FeederSheetCount`, `FeederJamsAfter`, `FeederDuplex`, `FeederStackTurnedOver`, `FeederBlankBackSheets`).

### UI files (all `internal`, SwiftUI, bind to `@EnvironmentObject var state: AppState`)

- `UI/SidebarView.swift` — `struct SidebarView: View`: device list + refresh (`refreshScanners()`), the "Why isn't my scanner listed?" button in the Scanners header and link in the empty list, and the troubleshooter sheet (`state.showTroubleshooter`).
- `UI/TroubleshooterView.swift` — `struct TroubleshooterView: View`: the troubleshooter's checks as cards with their buttons, Refresh, Copy Diagnostics and Done.
- `UI/InspectorView.swift` — `struct InspectorView: View`: all settings + Overview/Scan/Cancel buttons + presets; the Output section's formats (`OutputFormat.offered(for:)`); the Document section's "Collect pages, then Save …" (the format's `saveTitle`), "Also save text (.txt)" (off, with the reason, when the save writes no PDF and in the ID card and Copy tasks), "Skip blank pages" and "What counts as blank", "Crop to page" and "Straighten pages" (off, with the reason, when each scan is saved at once); for the Copy task a Copies section (Printer, its paper, Copies 1–99, Fit to page with its hint, the margin warning, Also save a PDF, Print Ruler Test Page…; without a printer, the reason and Look Again).
- `UI/StatusBarView.swift` — `struct StatusBarView: View`: status text, progress, and the actions for the files saved last (open, show, share, copy; More adds open with and email).
- `UI/PreviewCanvasView.swift` — `struct PreviewCanvasView: View`: shows `state.canvasImage`, marquee selection editing `state.selectionRect` (only when `state.overviewImage != nil`).
- `UI/PagesStripView.swift` — `struct PagesStripView: View`: page-queue thumbnails + Save PDF (or Save Word / Save Text: `format.saveTitle(pageCount:)`) / Clear; Copy Text in each page's context menu (`state.copyPageText(id:)`); the queue summary, each flagged page's badge and its Keep or Skip button (always shown), left-out pages dimmed, Save PDF counting the pages it writes; under a cropped or straightened page, its swap button (always shown: `PageCorrections.toggleLabel`, help = caption and label) calling `state.togglePageGeometry(id:)`.
- `UI/PhotoReviewView.swift` — `struct PhotoReviewView: View`: detected-photo grid sheet with the "After saving" choice; Save via `state.saveReviewedPhotos()`, cancel via `state.cancelPhotoReview()`.
- `UI/IdCardReviewView.swift` — `struct IdCardReviewView: View`: the ID card's sheet (`state.showIdCardReview`, presented from the detail in `ContentView`): each side with turn, Fix crop (the crop editor) and Scan again, a missing back with Scan the Back, Swap Front and Back, the page picture with its caption and the not-at-real-size warning, and Paper, Save as (PDF or an image format: `format.pageFormat`; a text format chosen in the inspector shows and saves as PDF), "Also save each side as an image", Print…, Discard and Save.
- `UI/TaskStartView.swift` — `struct TaskStartView: View` (`onOpenScanner: () -> Void`): the start screen's task cards (`state.taskCards`) and preset cards; also `enum TaskSymbols` (icon key → SF Symbol).
- `UI/TaskBannerView.swift` — `struct TaskBannerView: View` (`definition: TaskDefinition?`, `onChangeTask: () -> Void`): the active task, or turning a stack over by hand without one (`definition` nil), above the preview, with Change Task and a leave-task button (without a task: scan one side only); fronts scanned without moving on (the feeder stopped early), Done with Fronts; while the backs are due, Keep Fronts Only, before any back is scanned Scan More Fronts, and on a count mismatch also Combine Anyway and Scan Back Sides Again; the back of an ID card (`state.canSkipStep`) offers "Skip back side" (`state.skipStep()`); the leave-task button goes through `state.leaveIdCard(then:)`.
