# CompleteScanner — module contracts

Native macOS scanner app. SwiftUI, macOS 14+, Swift 5.9 language mode, SwiftPM, **system frameworks only** (AppKit, SwiftUI, ImageCaptureCore, CoreImage, Vision, PDFKit, CoreGraphics, ImageIO, UniformTypeIdentifiers, Accelerate). No third-party dependencies. No UIKit.

All app code lives in the library target `CompleteScannerKit` (`Sources/CompleteScannerKit/`). Tests in `Tests/CompleteScannerTests` use `@testable import CompleteScannerKit`.

Already written (READ THESE FIRST, code against them exactly):
- `Sources/CompleteScannerKit/Core/Models.swift` — all shared types (ScanIntent, ColorMode, ScanSource, OutputFormat, AdjustmentSettings, ScanSettings, ScannedPage, DetectedPhotoRegion, DetectedPhoto, ScannerInfo, ScannerCapabilities, ScanProgress, Preset, ScanError).
- `Sources/CompleteScannerKit/Core/DeviceMerge.swift` — `DeviceGroup` and `DeviceMerge` (one row per physical scanner, see below).
- `Sources/CompleteScannerKit/Core/Troubleshooting.swift` — `ScannerProblem` and `ScannerProblems.describe` (see below).
- `Sources/CompleteScannerKit/Core/ScannerBackend.swift` — `ScannerBackend` / `ScannerSession` protocols (both `@MainActor`).
- `Sources/CompleteScannerKit/App/AppState.swift` — the `@MainActor ObservableObject` all UI binds to.
- `Sources/CompleteScannerKit/App/ContentView.swift`, `CompleteScannerApp.swift`.

## Global rules

1. Write ONLY the files assigned to you. Never edit shared files.
2. Platform parity and CI. The Windows app under `windows/` is a sibling of this package. Every change to shared core logic (models, settings, naming, pipeline, output, persistence) lands on both platforms in the same change, with mirrored tests: `Tests/CompleteScannerTests` here and `windows/CompleteScanner.Core.Tests` there, same cases. Both suites must be green in CI (`.github/workflows/ci.yml`: `swift build` + `swift test` on macOS, `dotnet test windows/CompleteScanner.sln` on Windows) before a change counts as done. The one exception is the protocol logic of connections only Windows has — WIA, eSCL and TWAIN (`windows/CompleteScanner.Core/WiaErrors.cs`, `Escl/`, `Twain/`): macOS reaches the same scanners through ImageCaptureCore, so that logic and its tests have no Swift twin (see `windows/README.md`). What those connections report to the app (`ScannerInfo`, `ScannerCapabilities`, `ScannerProblem`, `ScanStop`) stays shared.
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
   - Windows (`windows/CompleteScanner.Core/Persistence.cs`) follows the same rules without per-type code: `StoreFiles.JsonOptions` reads every property of every type in a settings file on its own and falls back to the value a freshly constructed instance has. A new persisted property only needs an initializer default, a persisted type needs a public parameterless constructor, and enums are read only as their exact camelCase name (the Swift raw value).

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
```
Twin of `windows/CompleteScanner.Core/Troubleshooting.cs` (`ScanException.ForProblem` / `ScanException.Problem`): same cases, same text. Backends report fixable scanner conditions this way rather than as `scanFailed` text.

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
    /// Loads saved presets; on first run returns (and persists) built-in starter presets.
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
public enum PDFBuilder {
    /// Multi-page PDF; each page sized pixels/dpi*72 points. When `searchable`, run OCR per page
    /// and draw an invisible text layer aligned with the words.
    public static func makePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                               progress: ((String) -> Void)?) throws -> Data
    /// Same, but streamed straight to `url` (never holds the whole document in memory).
    public static func writePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                                to url: URL, progress: ((String) -> Void)?) throws
}
```
Note: `ScannedPage.fileURL` (optional) points at a full-resolution spill TIFF; when set,
`page.image` is only a preview and PDFBuilder reloads the full pixels from the file per page.

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
    /// Write jpeg/png/tiff with DPI metadata. Throws ScanError.unsupported for .pdf.
    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, dpi: Int, jpegQuality: Double) throws
}
```

### Output/NamingTemplate.swift

```swift
public struct NamingTemplate {
    public let template: String
    public init(_ template: String)
    /// Tokens: {date}=yyyy-MM-dd, {time}=HH.mm.ss, {year} {month} {day}, {counter} (also {counter:N}
    /// zero-padded), {intent} ("Document"/"Photos"), {index} (photo number in a batch, empty when nil).
    /// Unknown tokens pass through; result sanitized for the filesystem (no "/" or ":").
    public func baseFilename(counter: Int, date: Date, intent: ScanIntent, index: Int?) -> String
    /// base.ext, appending " 2", " 3", … until the name is free.
    public static func uniqueURL(in directory: URL, base: String, fileExtension: String) -> URL
}
```

### Backends/ICScannerBackend.swift

```swift
public final class ICScannerBackend: NSObject, ScannerBackend { ... }
```
ImageCaptureCore implementation: `ICDeviceBrowser` (scanner mask, local + bonjour + shared), sessions via `ICScannerDevice` (see task brief).

### Backends/MockScannerBackend.swift

```swift
public final class MockScannerBackend: ScannerBackend { ... }
```
One demo device, `ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true)`; synthesizes deterministic flatbed images (see task brief). It also has a document feeder (`sources: [.flatbed, .documentFeeder]`, `feederSizeInches` 8.5 × 11): a feeder scan returns `feederSheetCount` letter-size sheets (default `MockScannerBackend.defaultFeederSheetCount` = 3, read when the scan starts; sheet *n* carries *n* square marks near its bottom edge), and 0 sheets fails with `ScanError.scannerProblem(.feederEmpty)`. `feederJamsAfter` (default nil) makes the sheet after that many jam: the earlier sheets are returned and `lastScanStop` carries `.paperJam`; a jam on the first sheet fails with `ScanError.scannerProblem(.paperJam)`. Same behaviour as the C# `MockScannerBackend` (`FeederSheetCount`, `FeederJamsAfter`).

### UI files (all `internal`, SwiftUI, bind to `@EnvironmentObject var state: AppState`)

- `UI/SidebarView.swift` — `struct SidebarView: View`: device list + refresh.
- `UI/InspectorView.swift` — `struct InspectorView: View`: all settings + Overview/Scan/Cancel buttons + presets.
- `UI/StatusBarView.swift` — `struct StatusBarView: View`: status text, progress, last-saved reveal buttons.
- `UI/PreviewCanvasView.swift` — `struct PreviewCanvasView: View`: shows `state.canvasImage`, marquee selection editing `state.selectionRect` (only when `state.overviewImage != nil`).
- `UI/PagesStripView.swift` — `struct PagesStripView: View`: page-queue thumbnails + Save PDF / Clear.
- `UI/PhotoReviewView.swift` — `struct PhotoReviewView: View`: detected-photo grid sheet; Save via `state.saveReviewedPhotos()`, cancel via `state.cancelPhotoReview()`.
