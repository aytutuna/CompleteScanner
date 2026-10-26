# CompleteScanner — module contracts

Native scanner app for macOS, with the iPhone and iPad app in progress. SwiftUI, macOS 14+ and iOS 18+, `swift-tools-version: 6.0` with the Swift 5 language mode (`swiftLanguageModes: [.v5]`), SwiftPM, **system frameworks only** (AppKit, SwiftUI, ImageCaptureCore, CoreImage, Vision, PDFKit, CoreGraphics, ImageIO, UniformTypeIdentifiers, Accelerate, CryptoKit, CommonCrypto (`CCCrypt`, a system library), Security, Network and the DNS-SD library (`dnssd`, I12: finding network scanners); UIKit and QuickLook on iOS). No third-party dependencies. UIKit only in `CompleteScannerIOS`; AppKit, SwiftUI and ImageCaptureCore never in `CompleteScannerKit`.

The package's targets:
- `CompleteScannerKit` (`Sources/CompleteScannerKit/`): everything the Mac and the iPhone share: Core, Pipeline, Output, Persistence, Companion, the demo scanner (`Backends/MockScannerBackend.swift`), `AppState` and the protocols of the system services an app shell passes in (`FileActionService`, `PrintService`, `TroubleshooterService`, `PlatformLifecycle`, `BackgroundActivity`), with `PrintDocument` and `PrinterPapers`. It builds for macOS and iOS.
- `CompleteScannerMac` (`Sources/CompleteScannerMac/`): what only the Mac has: `Backends/ICScannerBackend.swift`, the system services (`App/SystemFileActions.swift`, `SystemPrintService.swift`, `SystemTroubleshooterService.swift`, `AppKitLifecycle.swift`), the open panel of `chooseAndImportPhotos()` (`App/AppState+ImportPanel.swift`), the phone link's platform pieces (`App/CompanionCertificateStore.swift`, `MacNetworkSource.swift`, `MacDnsSdAdvertiser.swift`), `UI/*`, `App/ContentView.swift` and `App/CompleteScannerApp.swift` (with `AppState.makeForMac()`, which passes the Mac's backends and services in). Every file is wrapped whole in `#if os(macOS)`, so the target builds to nothing for iOS.
- `CompleteScannerIOS` (`Sources/CompleteScannerIOS/`): what only the iPhone and iPad have: `UIKitLifecycle.swift`, `UIKitBackgroundActivity.swift` (I11: UIKit's background time for a network scanner's job), the app shell's services and start-screen rules (`IOSShell.swift`: `IOSLaunchOptions`, `IOSShell`, `AppState.makeForIOS`; `IOSFileActions.swift`), Apple's document scanner (`Camera/IOSDocumentCamera.swift`), our own camera (I8 and I9, `Camera/`: `LiveQuadTracker`, `IOSCameraLens`, `IOSCameraLifecycle`, `IOSCameraModel`, `IOSCameraController`; the screen `Views/CameraScreen.swift`; the automatic shutter and continuous capture since I9), importing photos and PDFs (`Import/`: `IOSPhotoDecoder`, `IOSPDFPages`, `IOSPageFinder`, `IOSPickedImage`, `IOSImportSession`, `CornerEditorModel`; I13: `IOSObjectFinder`, several objects in one shot), the photo, receipt and ID card reviews (I13: `Review/IOSPhotoReviewModel.swift` with `IOSReviewText` and `IOSCropRequest`; `Views/PhotoReviewScreen.swift`, `Views/IdCardReviewScreen.swift`, `Views/IdCardGuide.swift` with `IOSIdCardGuide`), the remaining tasks (I14: Quick scan's screen, `Review/IOSQuickScanModel.swift` and `Views/QuickScanScreen.swift` with Live Text; the password sheet, `Protection/IOSPasswordPrompt.swift` with `IOSPasswordForm` and `Views/PasswordSheetView.swift`; Mail's composer, `Views/MailComposeView.swift`; the tasks' camera buttons and choices, `Views/TaskControls.swift` with `IOSPDFOptions`; a spread split again, `Views/SpreadSplitSheet.swift`), the presets, history, saved files, file name and settings screens and the iPad's layout (I15: `Library/` with `IOSPresetsModel`, `IOSHistory`, `IOSSavedFiles`; `Settings/` with `IOSSettingsSections`, `IOSAdjustment`, `IOSNamingModel`; `IOSLayout.swift` with `IOSLayout`, `IOSShortcuts`, `IOSPageDrop`, `IOSDroppedFile`; the screens `Views/SettingsScreen.swift`, `PresetsScreen.swift`, `HistoryScreen.swift`, `SavedFilesScreen.swift`, `NamingEditorScreen.swift`, `IOSSidebar.swift`), network scanners (I12, `Network/`: `IOSNetworkScanners` with `IOSNetworkText`, `IOSLocalNetworkProbe`, `IOSTroubleshooterService` with `IOSNetworkPath`, `IOSScannerPickerModel` with `IOSScannerRow` and `IOSAddScannerModel`; the screens `Views/ScannerPickerView.swift`, `Views/TroubleshooterScreen.swift`, `Views/FlatbedPreview.swift`), the app (`CompleteScannerIOSApp.swift`) and its SwiftUI views (`Views/`). Every file is wrapped whole in `#if os(iOS)`, so the target builds to nothing for macOS.
- `ios/` (not a package target): the iPhone and iPad app's Xcode project, written by XcodeGen from `ios/project.yml` on CI (the `ios/CompleteScanneriOS.xcodeproj` it writes is not checked in). Its app target `CompleteScanneriOS` holds no logic: `ios/CompleteScanneriOS/main.swift` starts `CompleteScannerIOSApp` from the package, with `Info.plist`, `PrivacyInfo.xcprivacy` and `Assets.xcassets` (the icon is drawn by `scripts/make_ios_icon.py`); its UI test target `CompleteScanneriOSUITests` holds the smoke test.
- `CompleteScanner` (`Sources/CompleteScanner/main.swift`, inside `#if os(macOS)`): the Mac app; it depends on `CompleteScannerMac` on macOS only.
- Tests: `Tests/CompleteScannerTests` (`@testable import CompleteScannerKit`) is shared: `swift test` runs it on macOS and CI's `ios` job on the iOS Simulator. A test that needs what the Simulator lacks throws `XCTSkip` with the reason there, never passes silently: the Word package's XML read back with `XMLDocument` (macOS only, `DocxWriterTests`), and Vision's barcode reading when it reads nothing in the Simulator (`VisionBarcodeTests`). `Tests/CompleteScannerMacTests` (`@testable import CompleteScannerMac`) and `Tests/CompleteScannerIOSTests` (`@testable import CompleteScannerIOS`) hold each platform's own tests, wrapped like their targets. The app's UI smoke test (`ios/CompleteScanneriOSUITests/SmokeTests.swift`) runs in the same CI job, on the app built from `ios/project.yml`.

A member of `CompleteScannerKit` that the platform targets need and this document does not list as `public` is `package` (`AppState.sidesCapabilities`, `AppState.printService`, the setter of `AppState.sectionsOpenedByTask`, `PrinterPapers`, `PhotoFileReader.headerPixelSize` and `PhotoFileReader.tooLarge`), never `public`.

Already written (READ THESE FIRST, code against them exactly):
- `Sources/CompleteScannerKit/Core/Models.swift` — all shared types (ScanIntent, ColorMode, ScanSource, OutputFormat, AdjustmentSettings, ScanSettings, ScannedPage, DetectedPhotoRegion, DetectedPhoto, ScannerInfo, ScannerCapabilities, ScanProgress, Preset, ScanError).
- `Sources/CompleteScannerKit/Core/DeviceMerge.swift` — `DeviceGroup` and `DeviceMerge` (one row per physical scanner, see below).
- `Sources/CompleteScannerKit/Core/Troubleshooting.swift` — `ScannerProblem` and `ScannerProblems.describe` (see below).
- `Sources/CompleteScannerKit/Core/Troubleshooter.swift`, `App/TroubleshooterService.swift` — "Why isn't my scanner listed?": the discovery snapshot, its checks and what they offer to do (see below).
- `Sources/CompleteScannerKit/Core/ScannerBackend.swift` — `ScannerBackend` / `ScannerSession` protocols (both `@MainActor`).
- `Sources/CompleteScannerKit/Core/ScanTask.swift`, `TaskCatalog.swift`, `TaskFlow.swift`, `SettingsAdapter.swift` — the start screen's tasks, their guided steps, and fitting settings to a scanner (see below).
- `Sources/CompleteScannerKit/Core/StatusLine.swift`, `Core/InspectorSections.swift` — the short texts both apps show: the status line's six words, and the settings column's sections with the summaries of their collapsed headers (see below).
- `Sources/CompleteScannerKit/Output/PDFImageEncoding.swift`, `Pipeline/ColorAnalysis.swift` — the PDF sizes: how each page image is stored in a PDF (see below).
- `Sources/CompleteScannerKit/Output/PDFObjectWriter.swift`, `PDFWriter.swift`, `GlyphlessFont.swift`, `PDFA.swift`, `PDFEncryption.swift`, `CCITTG4Encoder.swift`, `BilevelTIFF.swift`, `Pipeline/Bilevel.swift` — the port of the C# PDF writer (I4, I5): the object writer, the plain PDF with its Unicode text layer, PDF/A-2b, password-protected PDFs (AES-256) and black & white pages as CCITT G4 in PDFs and TIFFs, byte for byte as Windows writes them; every PDF the Mac and the iPhone save goes through it (see "Output/PDFBuilder.swift", "PDF/A-2b and the Unicode text layer", "Password-protected PDFs" and "CCITT G4 for black & white pages" below); `App/AppState+Protection.swift` gives each PDF a save writes its options (PDF/A, or the password asked for once per save).
- `Sources/CompleteScannerKit/Output/PDFSyntax.swift`, `PDFReaderLite.swift`, `PDFAppender.swift`, `App/AppState+Append.swift` — adding pages to an existing PDF as an incremental update (M21; see "Adding pages to an existing PDF" below).
- `Sources/CompleteScannerKit/Core/SaveActions.swift`, `App/FileActions.swift` — what can be done with saved files (open, open with, show in Finder, share, email, copy) and the after-save action (see below).
- `Sources/CompleteScannerKit/Core/DocumentSides.swift`, `Core/PaperSize.swift` — two-sided scanning (which page is which side of which sheet, turning a stack over by hand) and paper sizes (see below).
- `Sources/CompleteScannerKit/Pipeline/PageProcessor.swift`, `BlankPageDetector.swift`, `RgbaImage.swift`, `GrayImage.swift`, `BackgroundMap.swift`, `MaskOps.swift` — the page clean-up stage every scanned page goes through, blank-page detection, and the image toolkit the page analyses share (see below).
- `Sources/CompleteScannerKit/Pipeline/DocumentGeometry.swift` — crop to the page and straighten it: the sheet's edges on the scanner's background, the skew of the text lines, and what is done to the page (see below).
- `Sources/CompleteScannerKit/Pipeline/Orientation.swift` (+ `VisionOrientationScorer` in `Output/OCRService.swift`) — rotate pages upright: which way up a page reads by text recognition, the turn and its one-click undo (see below).
- `Sources/CompleteScannerKit/Pipeline/BookSplitter.swift`, `App/AppState+Book.swift`, `CompleteScannerMac/UI/SpreadSplitView.swift` — books and magazines: the gutter of an open book found on a spread, the spread cut into its pages in reading order, joined or split again by hand (see below).
- `Sources/CompleteScannerKit/Pipeline/SpineShadow.swift` — softening the shadow along the spine on each page cut from a spread: measured from the paper itself, lifted towards the paper's white with the text kept dark, pictures beside the spine left alone, one click shows the page as scanned (see below).
- `Sources/CompleteScannerKit/Pipeline/IdCard.swift`, `App/AppState+IdCard.swift`, `CompleteScannerMac/UI/IdCardReviewView.swift` — the ID card task: both sides of a card found on the glass and laid out on one page at real size (see below).
- `Sources/CompleteScannerKit/Output/PrintLayout.swift`, `App/PrintController.swift`, `App/AppState+Copy.swift` — copy and print: the Copy task, printing the ID card's page and the ruler test page, at real size (see below).
- `Sources/CompleteScannerKit/Output/OCRText.swift`, `TextExport.swift`, `DocxWriter.swift`, `ZipStore.swift` — text output: OCR lines in reading order and paragraphs, the text file, the Word document and its zip package, Copy Text (see below).
- `Sources/CompleteScannerKit/Pipeline/ReceiptProcessing.swift`, `App/AppState+Receipts.swift` — the Receipts task: several receipts found on the glass, cleaned up for faded thermal print, and named by the date read from their text (see below).
- `Sources/CompleteScannerKit/Core/DocumentSplitter.swift`, `Core/SavePlan.swift`, `Pipeline/PatchCodeDetector.swift`, `App/AppState+Split.swift` — splitting a stack into separate documents: separator sheets with patch codes, blank sheets, every N sheets, splitting and joining by hand in the page strip, the {label} token, and saving several files all or nothing (see below).
- `Sources/CompleteScannerKit/Pipeline/Quad.swift`, `Homography.swift`, `PerspectiveCorrector.swift`, `PhotoDocumentDetector.swift`, `CaptureStability.swift` — photos of documents: a page's four corners found in a camera photo, the page made upright with its perspective corrected, and when a held-still page should be taken (see below).
- `Sources/CompleteScannerKit/Pipeline/PerspectiveWarp.swift`, `CaptureScale.swift`, `MultiQuadPicker.swift` — camera geometry (I6): the reference warp of camera pages, a captured page's real size, the objects picked from one shot, and what the camera recorded about a page (`CaptureFacts`, `ScannedPage.capture`, `PerspectiveStep`) (see below).
- `Sources/CompleteScannerKit/Pipeline/FrameQuality.swift`, `DocumentEnhancer.swift` — the camera's automatic shutter and clean-up (I9): how sharp and bright a live frame is, and camera pages with their lighting evened out, the paper white and the print black (`EnhanceStep`, `CaptureFacts.enhancement`) (see below).
- `Sources/CompleteScannerKit/Pipeline/PhotoImport.swift`, `App/AppState+Import.swift`, `CompleteScannerMac/UI/PhotoCornersEditorView.swift` — importing photos of documents as pages of the queue, with the corner editor for a page not found clearly (see below).
- `Sources/CompleteScannerKit/Pipeline/CaptureObjects.swift`, `GlareDetector.swift`, `App/AppState+Capture.swift` — several objects in one camera shot (I13): receipts, photos or an ID card's side as pages cut out at their real size, the photo review's words, glare on a card, and Fix crop along four corners (see below).
- `Sources/CompleteScannerKit/Core/CameraTaskCatalog.swift`, `Core/CameraSides.swift`, `App/AppState+CameraTasks.swift` — the remaining tasks on the iPhone (I14): the camera's words for every task, the two-sided camera's steps (Flip & capture, or fronts then backs), New document, Quick scan's held page and the Email task's mail route (see "The remaining tasks on the iPhone" under "App shells" below); Swift only, on the shared camera arrangement and spreads (`ScanArrangement.cameraFront`, `.cameraBack`, `PageProcessor.prepare`), which have twins.
- `Sources/CompleteScannerKit/Companion/SpkiFingerprint.swift`, `PairingUri.swift`, `PairingSession.swift`, `PairedDeviceStore.swift`, `CompanionHttp.swift`, `CompanionProtocol.swift` — the phone companion's shared pieces: the certificate pin, the pairing code, the one-time pairing window, the paired phones, the HTTP subset and the protocol's messages (see below; the Windows desktop's server, the iPhone's client (I20) and the Mac's server and host (I21) are built on them).
- `Sources/CompleteScannerKit/Escl/` — network scanners over eSCL (AirScan): the protocol (I10: capabilities, scan requests, status, retries, TXT records, addresses, the device list's endpoints, the addresses added by hand and certificate pinning) and the connection (I11: `EsclClient` on URLSession with its trust delegate, `EsclScannerSession`, `EsclScannerBackend`), twins of the C# `Escl/` with the same tests, and finding scanners on the network (I12: `EsclDiscovery`, `EsclNWBrowser` and `EsclDnssdResolver`, Swift only) with the addresses added by hand and the troubleshooter's view in `EsclScannerBackend` (see "Escl/", "Escl/EsclClient.swift, EsclScannerSession.swift, EsclScannerBackend.swift" and "Escl/EsclDiscovery.swift, EsclNetworkServices.swift" below).
- `Sources/CompleteScannerKit/Pipeline/Barcodes.swift`, `Output/BarcodeServices.swift` — barcode and QR separator sheets: reading the codes on a page (Vision), the document name a code's text gives, the QR separator sheet to print (Core Image draws its code) and Code 39 for the demo scanner (see below).
- `Sources/CompleteScannerKit/App/AppState.swift` — the `@MainActor ObservableObject` all UI binds to; its task members are in `App/AppState+Tasks.swift`. What each app shell passes in and the one way pages come in: `App/PlatformLifecycle.swift`, `AppState.ingest` (see "App shells" below).
- `Sources/CompleteScannerMac/App/ContentView.swift`, `CompleteScannerApp.swift`.

## Global rules

1. Write ONLY the files assigned to you. Never edit shared files.
2. Platform parity and CI. The Windows app under `windows/` is a sibling of this package. Every change to shared core logic (models, settings, naming, pipeline, output, persistence) lands on both platforms in the same change, with mirrored tests: `Tests/CompleteScannerTests` here and `windows/CompleteScanner.Core.Tests` there, same cases. Both suites must be green in CI (`.github/workflows/ci.yml`: `swift build` + `swift test` on macOS, the shared Swift suite on the iOS Simulator and the iPhone app's UI tests (the `ios` job, after the macOS job; `ScreenshotTests` walks the main screens and the job uploads a screenshot of each, named by screen, as the `ios-screenshots` artifact), `dotnet test windows/CompleteScanner.sln` on Windows) before a change counts as done. The one exception is the protocol logic of connections only Windows has — WIA and TWAIN (`windows/CompleteScanner.Core/WiaErrors.cs`, `Twain/`), and the Windows service and network values the troubleshooter reads (`WindowsSystemStatus.cs`): macOS reaches the same scanners through ImageCaptureCore, so that logic and its tests have no Swift twin (see `windows/README.md`). The eSCL protocol is shared, because the iPhone has no ImageCaptureCore scanners: `Escl/` has Swift twins in `Sources/CompleteScannerKit/Escl/` with the same cases, reading the same fixtures (`Tests/Fixtures/Escl`; see "Escl/" below), since I10 for the protocol and since I11 for the HTTP client and session (`EsclClient`, `EsclScannerSession`, `EsclClientTests`, and the two `EsclTrustTests` cases through a real TLS connection, whose Swift twins are in `EsclLoopbackTests`); the Windows app's eSCL backend (`Scanning/EsclScannerBackend.cs`: discovery, the addresses added by hand and the troubleshooter's view) has its Swift counterpart in `Escl/EsclScannerBackend.swift`, which since I12 has the same device list, the addresses added by hand (escl-hosts.json, checked and re-checked every minute), the troubleshooter's view and the devices.txt lines, and finds scanners with `Escl/EsclDiscovery.swift` (NWBrowser and the dnssd resolver, `Escl/EsclNetworkServices.swift`); the Windows search is the Windows app's own (`Scanning/EsclDiscovery.cs`, a device watcher), so the search, the backend and their tests (`EsclBrowsingTests`, `EsclScannerBackendTests`, over stand-ins for the browsers and a URLProtocol stub) have no C# twin, while what they hand over (`EsclService`, `EsclEndpoint.choose`, `EsclHostList`, `ScannerAddress`) is shared with the same tests. The iPhone's troubleshooter cases (I12: `TroubleshootPlatform.ios`, `TroubleshootAction.openAppSettings`, `DiscoveryStatus.denied`, the iPhone's checks and tips) and `DeviceMerge.iosRanking` are shared, in C# and Swift with the same tests (`TroubleshooterTests`, `DeviceMergeTests`); Windows never produces them. `ScannerProblem.appSuspended` (I11) is shared text that only the iPhone's eSCL connection produces. What those connections report to the app (`ScannerInfo`, `ScannerCapabilities`, `ScannerProblem`, `ScanStop`) stays shared. The 32-bit TWAIN helper (M22e) belongs to that TWAIN exception and changes nothing on the Mac except the shared troubleshooter's "twain32" check, which says why the helper does not reach a 32-bit-only driver when the Windows app fills in `DiscoverySnapshot.thirtyTwoBitHelperProblem` (same text and tests, `TroubleshooterTests`, on both platforms): the x86 helper program (`windows/CompleteScanner.TwainHelper`), its protocol in Core (`Twain/TwainHelperProtocol.cs`, `TwainHelperServer.cs`, `TwainHelperClient.cs`), the app's side (`Scanning/Twain/Twain32ScannerBackend.cs`, `TwainHelperProcess.cs`) and their tests (`TwainHelperProtocolTests`, `TwainHelperSessionTests`, `TwainHelperTests` in `CompleteScanner.App.Tests`) have no Swift twin; its sources reach the app as shared `ScannerInfo` entries (backend `twain32`, which `DeviceMerge` ranks after every other connection), and its errors as the shared `ScannerProblem` and `ScanStop`. The Windows Scan connection (M22f: the WinRT `ImageScanner` API, `Windows.Devices.Scanners`, a backup connection to WIA scanners chosen in the Windows connection chooser, never a replacement for WIA Automation) belongs to the WIA exception and changes nothing on the Mac: its capability mapping, scan request, error mapping and diagnostics in Core (`WindowsScan.cs`, plus `ResolutionList.FromBounds` in `Scanning.cs`, which is C# only like the rest of `ResolutionList`), the app's adapter (`Scanning/WinRtScannerBackend.cs`), the app waiting for WIA Automation to look again before it chooses a scanner only Windows Scan lists (`Scanning/IPolledScannerBackend.cs`, `AppViewModel`), and their tests (`WindowsScanTests`, the `FromBounds` cases of `ResolutionListTests`, `WinRtScannerTests` and `WiaEnumerationTests` in `CompleteScanner.App.Tests`) have no Swift twin; its devices reach the app as shared `ScannerInfo` entries (backend `winrt`, transport "Windows Scan (backup)", which `DeviceMerge.connectionLabel` shows as it does every transport it has no name for), `DeviceMerge` ranks them after every connection `windowsRanking` lists (it lists no `winrt`, so `windowsRanking` and `DeviceMergeTests` are unchanged on both platforms), and its errors reach the app as the shared `ScannerProblem` and `ScanStop`. It stores no setting: the user's choice of it is the existing `PreferredConnection` entry. The C# PDF writer is ported whole (I4, I5): `PdfObjectWriter.cs` with its encryption (`Output/PDFObjectWriter.swift`, with the incremental-update members of M21 below), the object-level parts of `PdfBuilder.cs` (`PdfImageData`, `PdfJpegImage`, `PdfCcittImage`, `PdfPageInput`, `Make`, `Write`, `WritePage`, `ImageEntries`, `WriteTextFont`, `TextLayerLine`, `F`: `Output/PDFWriter.swift`), `GlyphlessFont.cs` with its own Deflate encoder (`Output/GlyphlessFont.swift`), M19's PDF/A pieces (`PdfA.cs`: `PdfConformance`, `PdfWriteOptions`, `PdfA` in `Output/PDFA.swift`, with the same sRGB profile bytes), M20's password pieces (`PdfEncryption.cs`: `PasswordStrength`, `PdfProtection`, `PdfEncryption` in `Output/PDFEncryption.swift`) and M22a's CCITT G4 pieces (`CcittG4Encoder.cs`, `Bilevel.cs`, `BilevelTiff.cs`: `Output/CCITTG4Encoder.swift`, `Pipeline/Bilevel.swift`, `Output/BilevelTIFF.swift`) have Swift twins that write the same bytes, checked by mirrored tests and the C#-pinned golden files (`PDFWriterTests`, `PDFATests`, `PDFEncryptionTests`, `GlyphlessFontTests`, `CCITTG4EncoderTests`, `BilevelOutputTests` on both sides). `PdfBuilder`'s file helpers (`WriteFile`, `WriteNewFile`) stay C# only (the Mac moves its temporary file into place in `AppState.writePDFAtomically`), and every PDF the Mac and the iPhone save goes through `PDFWriter` (see "Output/PDFBuilder.swift" below); the plan that chooses G4 (`PdfImageEncoding`) is shared. The Archive document task (`ScanTask.archive`), the Archive & password settings section and the password dialog are on both platforms (see "PDF/A-2b and the Unicode text layer" and "Password-protected PDFs" below); what asks for the password and when is each app's own (the Windows view model's `AskPdfPassword` and `PdfPasswordWindow`, `AppState.askPDFPassword` with the Mac's `PDFPasswordWindow`); the Mac's save flows with a password and PDF/A are checked by `AppStateSeamTests`, which have no C# twin (the Windows view model is not in Core). Adding pages to an existing PDF (M21) is shared: the reader and the incremental update (`PdfSyntax.cs`, `PdfReaderLite.cs`, `PdfAppender.cs` and the update members of `PdfObjectWriter.cs`) have Swift twins with the same cases (`Output/PDFSyntax.swift`, `Output/PDFReaderLite.swift`, `Output/PDFAppender.swift`, `Output/PDFObjectWriter.swift`; `PDFSyntaxTests`, `PDFReaderLiteTests`, `PDFAppenderTests`), and the Mac and the iPhone offer it as Windows does (`AppState+Append.swift`, the twin of `AppViewModel.Append.cs`; see "Adding pages to an existing PDF" below); it stores no setting. The phone companion's desktop server (C1) runs on Windows and, since I21, on the Mac: its shared pieces (`SpkiFingerprint`, `PairingUri`, `PairingSession`, `PairedDeviceStore`, `CompanionHttp`, `CompanionProtocol`, `PageSource.phone`) have Swift twins with the same tests, and since I21 so has the server itself (`Companion/CompanionInbox.cs`, `CompanionOutbox.cs`, `CompanionRouter.cs`, `CompanionServer.cs`, `CompanionRateLimiter.cs`, the trusted-network rules of `CompanionNetworks.cs` and `CompanionTroubleshooter.cs`, with `CompanionRouterTests`, `CompanionNetworkTests` but its `Firewall_*` cases, and the server's cases of `CompanionLoopbackTests`; see "The companion server in Swift" below), and so have the host and service (`CompanionHost.cs`, `CompanionService.cs`, with the host's cases of `CompanionLoopbackTests` in `CompanionHostTests`; see "The companion host on the Mac" below). Windows Firewall (`CompanionFirewall.cs`) has no Swift twin, and each app has its own side: on Windows `Services/Companion/`, `AppViewModel.Companion.cs`, `PhoneWindow` and `MainWindow.Phone.cs` (tested by `CompanionAppTests` in `CompleteScanner.App.Tests`), on the Mac `AppState+CompanionHost.swift` (tested by `AppStateCompanionHostTests`, whose C# counterparts are the `CompanionPages` cases of `CompanionAppTests`) and, in `CompleteScannerMac`, the keychain identity, the interfaces, DNS-SD and the Phone window (see "The phone companion" below). Reading barcodes and drawing QR codes are platform services behind shared protocols (M22d): Vision and Core Image on the Mac (`Output/BarcodeServices.swift`), ZXing.Net in the Windows app only (`windows/CompleteScanner.App/Services/ZXingBarcodeReader.cs`, `ZXingQrEncoder.cs`, checked by `CompleteScanner.App.Tests/BarcodeReaderTests.cs`; the Mac's twin checks are `VisionBarcodeTests.swift`, Data Matrix on Windows only since macOS draws none); everything they feed is shared Core (`Pipeline/Barcodes.swift` / `Barcodes.cs`) with the same tests on both sides (`BarcodeTests`). Both halves of the text spec are built ("less text, same clarity"). The shared texts are short on both platforms, in C# and Swift alike (task titles and one-line subtitles, a step's one-line `prompt` with its fuller `help`, the troubleshooter's one-line `detail` with its `more`, the error's title by problem, a few words of help per choice, the strip labels and badges, the photo import's texts); the short texts both apps show and their logic are in Core with Swift twins (`Core/StatusLine.swift` / `StatusLine.cs`: the status line's six words; `Core/InspectorSections.swift` / `InspectorSections.cs`: the settings column's sections, which start open and the collapsed headers' summaries; and the short reasons with the types they belong to, such as `DocumentSides.needsFeederReason`, `BookPages.notWithTwoSidedReason`, `BlankSensitivity.highWarning`, `PaperSizes.selectedAreaNote`, `SplitMode.caption` and `steps`, `BarcodeSeparators.startsDocumentCaption`, `IdCardSteps.privacyNote`), checked by `StatusLineTests` and `InspectorSectionsTests` on both sides. The Windows app keeps only its own short texts and layout logic (`windows/CompleteScanner.App/LessText.cs`: the empty stage's line and chip and a few Windows-only reasons, checked by `LessTextTests` in `CompleteScanner.App.Tests`); the Mac mirrors the layout in SwiftUI (start tiles in groups, the inspector's disclosure sections with summaries, captions moved to help, the six-word status line, the banner's info popover, the troubleshooter's one-line headline and More help). The app shells' seams are Swift only (I1): Windows has one app shell, so `PlatformLifecycle` with the Mac's `AppKitLifecycle` and the iPhone's `UIKitLifecycle`, the Kit's stand-ins for a service a shell does not pass, and `AppState.ingest` have no C# twin (see "App shells" below); `AppStateSeamTests`, `AppKitLifecycleTests` and `UIKitLifecycleTests` check them. The iPhone's app shell (I2: `IOSShell`, `IOSFileActions`, the views, the Xcode project in `ios/`) is Swift only too; `IOSShellTests`, `IOSFileActionsTests` and the UI smoke test check it. So are its camera and imports (I7: Apple's document scanner, `IOSDocumentCamera`; photos and PDFs from the Photos picker, the Files app and other apps, `Import/`; the touch corner editor; saving the queue as a JPEG a page, `AppState.saveImages`), checked by `IOSPhotoDecoderTests`, `IOSPDFImportTests`, `CornerEditorModelTests`, `IOSImportSessionTests`, `IOSCaptureTests`, the saving cases of `AppStateSeamTests` and the import UI test (`ios/CompleteScanneriOSUITests/ImportTests.swift`); what they build on in Core (`CaptureFacts`, `PerspectiveStep`, `CaptureScale`, `PhotoImport`) is shared with its twins. So is our own camera (I8: the capture session, the lens choice, the live page outline `LiveQuadTracker` with its `FrameSource`, when the camera runs, the camera screen; I9: the automatic shutter's toggle and countdown, continuous capture, our camera as the default with Apple's scanner as "Use Apple's scanner"), checked by `LiveQuadTrackerTests`, `IOSCameraTests` and the camera UI test (`ios/CompleteScanneriOSUITests/CameraTests.swift`); the live outline is found by Vision with the shared `PhotoDocumentDetector` as its fallback (see **Page edges**), its steadiness judged by the shared `CaptureStability` and each frame's sharpness and brightness measured by the shared `FrameQuality`, all with their twins, and its photos come in through the I7 import, so Windows has nothing to mirror. What I9 added to Core is shared with twins and the same tests on both sides: the shutter's quality check (`FrameQuality`, `CaptureStability.judge`, `markCaptured`, `CaptureQuality`; `FrameQualityTests`, `CaptureStabilityTests`) and the clean-up of camera pages (`DocumentEnhancer`, `BackgroundMap.raisedDarkTiles`, `EnhanceStep`, `CaptureFacts.enhancement`; `DocumentEnhancerTests`, `CapturePageTests`), with golden bytes pinned on both sides; the Windows app does not use the enhancer yet (its photo import is unchanged; `PageProcessor.ForCapture`, which runs it, is used by no Windows window). What I13 added to Core is shared with twins and the same tests on both sides: the objects of one shot as pages (`CaptureObjects`), the photo review's words (`PhotoReview`, which the Windows review now uses), glare (`GlareDetector`) and `PageProcessor.forCapture` leaving the queue's steps (and so text recognition) out for photos, receipts and the ID card (`CaptureObjectsTests`, `GlareDetectorTests`); the iPhone's side (Vision's rectangles, `IOSObjectFinder`; the photo, receipt and ID card reviews; the card's guide frame) and the state's camera flows (`AppState+Capture.swift`, `CaptureFlowTests`) are Swift only, since no Windows window takes camera shots. What I14 added to Core is shared with twins and the same tests on both sides: the camera arrangement (`ScanArrangement.cameraFront`, `.cameraBack`, `DocumentSides.markCamera`), a camera's whole book spread cut out before it is split (`PageProcessor.prepare`, `forCapture`'s `arrangement`, `splitsCameraSpreads`) and the camera's two choices in `TaskOptions` (`cameraFrontsFirst`, `cameraSpreads`; Windows keeps them as they are); the camera's words (`CameraTaskCatalog`), its two-sided steps (`CameraSides`) and the state's camera tasks (`AppState+CameraTasks.swift`: the sides, New document, Quick scan's held page, the Email task's mail route; `CameraTaskTests`) are Swift only. What I15 added to Core is shared with twins and the same tests on both sides: the file name field's parts, putting one in, what is wrong with a template and the next file's name (`Output/NamingTokens.swift` / `NamingTokens.cs`, `NamingTokensTests`; the Windows Insert menu and file name preview use it) and the sections a setting shows with their titles, summaries, dots and accessible names (`InspectorSections.shown`, `title(_:for:)`, `summary`, `changed`, `accessibleName`, `writesPDF`, `textApplies`, `taskTitle`, `shownFormat`; `InspectorSectionsTests`; the Windows inspector's `WritesPdf`, `ShownFormat` and Also save text use it); the iPhone's screens built on them (presets, scans, saved files, the file name, Settings, the iPad's sidebar, keyboard shortcuts and drag and drop) and the state's `renamePreset` and `fileNameExample` are Swift only (`IOSLibraryTests`, `IOSSettingsTests`, the smoke test's preset case), as Windows renames no preset.
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
   - Windows (`windows/CompleteScanner.Core/Persistence.cs`) follows the same rules without per-type code, for its Windows-only files too (`preferences.json`, the network scanners added by address and their trusted certificates, `escl-hosts.json` and `escl-trust.json`, which have Swift twins since I10, and the phone link's paired phones and approved networks, `companion-devices.json` and `companion-networks.json`, plus its inbox and outbox lists under `%LOCALAPPDATA%\CompleteScanner\Companion`); `preferences.json` also keeps which inspector sections the user left open, `inspectorSections`, a map that is empty, meaning every section at its default, when missing or unreadable: `StoreFiles.JsonOptions` reads every property of every type in a settings file on its own and falls back to the value a freshly constructed instance has. A new persisted property only needs an initializer default, a persisted type needs a public parameterless constructor, and enums are read only as their exact camelCase name (the Swift raw value).
   - The eSCL files (`escl-hosts.json`, a JSON list of address strings; `escl-trust.json`, `EsclTrustFile`) are read on Apple platforms by `EsclHostList` and `EsclTrustStore` through `StoreFiles.load` (the C# `StoreFiles.Load`: a file that does not decode is moved aside, one that cannot be read is left in place and never overwritten). Each platform keeps its own in its own settings folder, with the same keys; a file from the other platform loads with every pin, only `EsclTrustedCertificate.trusted` reads as nil (C# writes ISO 8601 text, JSONEncoder a number), as the shared fixtures `escl-trust-windows.json` and `escl-trust-apple.json` check on both sides (`EsclTrustTests.TrustFilesFromEitherPlatformLoad`). The iPhone and iPad keep theirs (I12) in Application Support/CompleteScanner/Network (`IOSNetworkScanners.filesFolder()`), a folder kept out of backups (`isExcludedFromBackup`): pinned keys and addresses belong to the device. Whether the Local Network explanation was read is not a settings file: a flag in the user's defaults (`localNetworkExplained`, the `UserDefaults` use the privacy manifest declares already).

## APIs each module must expose (exact signatures)

### Core/Troubleshooting.swift (+ ScanError, ScannerCapabilities in Core/Models.swift)

```swift
/// A condition at the scanner that stops a scan and that the user can usually fix.
/// The first case is the safe default; add new cases after the existing ones.
public enum ScannerProblem: String, CaseIterable, Sendable {
    case unknown, feederEmpty, paperJam, paperProblem, multiFeed, coverOpen
    case offline, busy, warmingUp, needsAttention, communicationError
    case appSuspended   // I11: the system suspended the app mid-job (the iPhone's eSCL connection only; Windows never produces it)
}

public enum ScannerProblems {
    /// User-facing text: what happened and what to do, e.g. "Load paper in the feeder, then scan again."
    public static func describe(_ problem: ScannerProblem) -> String
    public static let genericTitle: String                                // "Something went wrong"
    public static func title(_ problem: ScannerProblem) -> String         // "Paper jam", "Scanner offline"; .unknown: genericTitle
    public static func advice(_ problem: ScannerProblem) -> String        // ten words at most: "Clear the jam, then scan again."
    public static func find(_ message: String?) -> ScannerProblem?        // the problem whose describe text is in the message
    /// The error bar's (Windows) or alert's (Mac) title and message: the problem's title and the
    /// message with its describe text cut to the advice; genericTitle and the message as it is otherwise.
    public static func notice(_ message: String) -> ProblemNotice
}
public struct ProblemNotice: Equatable, Sendable { public let title: String; public let message: String }

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
public enum TroubleshootPlatform: String, Sendable { case windows, mac, ios }   // ios: I12, never produced on Windows
public enum NetworkStatus: String, Sendable { case unknown, offline, publicNetwork, privateNetwork, domainNetwork }
public enum ServiceStatus: String, Sendable { case unknown, running, starting, stopping, stopped, paused, disabled, notInstalled }
public enum TwainStatus: String, Sendable { case unknown, available, notInstalled, failed }
public enum DiscoveryStatus: String, Sendable { case unknown, off, searching, running, unavailable, denied }   // denied: I12
public enum CheckStatus: String, CaseIterable, Sendable { case ok, tip, warning, problem }
public enum TroubleshootAction: String, CaseIterable, Sendable {
    case refresh, addByAddress, openScannerSettings, openNetworkSettings, openImageCapture, copyDiagnostics
    case openAppSettings   // I12: the app's page in the Settings app (iPhone and iPad), "Open Settings"
}
public struct ManualHostStatus: Equatable, Sendable { address: String; listed: Bool; problem: String? }
public struct ScannerFailure: Equatable, Sendable { deviceName: String; message: String; problem: ScannerProblem? }
/// Everything the troubleshooter looks at; defaults (unknown, empty) produce no check. The
/// Windows-only fields (wiaService, twain…, thirtyTwoBit…, manualHosts, discoveredCount) stay at
/// their defaults on the Mac. `init` takes every field, all defaulted, platform `.windows` first.
/// `thirtyTwoBitHelperProblem`: why the Windows app's 32-bit TWAIN helper does not reach
/// `thirtyTwoBitOnlyDrivers`, as sentences about the helper ("It …") with what to do; the
/// "twain32" check quotes it (nil: "which has not listed it yet").
public struct DiscoverySnapshot: Equatable, Sendable {
    platform, devices: [ScannerInfo], network, wiaService, twain, twainDriverCount: Int,
    thirtyTwoBitOnlyDrivers: [String], thirtyTwoBitHelperProblem: String?, discovery, discoveryDetail: String?, discoveredCount: Int,
    manualHosts: [ManualHostStatus], lastFailure: ScannerFailure?
    var listedScannerCount: Int { get }            // not the demo scanner
}
/// title: six words at most; detail: one line of fifteen words at most; more: the rest, behind "More
/// help" ("" when the detail says it all); init(id:status:title:detail:more: = "", actions:) (C#: More last,
/// optional). fullDetail: detail and more, for screen readers.
public struct TroubleshootCheck: Equatable, Sendable { id, status, title, detail, more, actions: [TroubleshootAction]; var fullDetail: String }

@MainActor public protocol ScannerBackendDiagnostics: AnyObject {   // optional; ScannerBackend is unchanged
    func addStatus(to snapshot: DiscoverySnapshot) -> DiscoverySnapshot
    func rescan()                                   // look again; never changes system settings
    var diagnosticsReport: String? { get }          // I12, default nil: lines for devices.txt and Copy diagnostics (C#: IBackendDiagnostics)
}

public enum Troubleshooter {
    /// Problems, then warnings, then OK, then tips; within each: last failure, network, WIA service,
    /// TWAIN, 32-bit TWAIN drivers, the search, addresses added by hand, tips. The Mac never gets
    /// the Windows checks or `.addByAddress`.
    public static func diagnose(_ snapshot: DiscoverySnapshot) -> [TroubleshootCheck]
    public static func headline(_ snapshot: DiscoverySnapshot) -> String      // "No scanner found", "2 scanners found"
    public static func summary(_ checks: [TroubleshootCheck]) -> String       // "2 problems and 1 warning found."
    public static func overview(_ snapshot: DiscoverySnapshot, checks: [TroubleshootCheck]) -> String  // "No scanner found · 2 problems, 1 warning"
    public static func label(_ action: TroubleshootAction, platform: TroubleshootPlatform) -> String  // "Add by address…", "Scanner settings" (Mac "Printers & Scanners"), "Network settings", "Image Capture"
    public static func statusLabel(_ status: CheckStatus) -> String           // "OK", "Tip", "Warning", "Problem"
    public static func report(_ snapshot: DiscoverySnapshot, checks: [TroubleshootCheck]) -> String   // each check's more on the line after its detail
    public static func combineNetworks(_ connected: [NetworkStatus]) -> NetworkStatus
    /// nil for cancelled, export and unsupported errors (and CancellationError).
    public static func failure(deviceName: String, error: Error) -> ScannerFailure?
}

// App/TroubleshooterService.swift: the system side, injected into AppState so tests can stand in for it.
@MainActor public protocol TroubleshooterService: AnyObject {
    func open(_ action: TroubleshootAction) throws   // Printers & Scanners, Network, Image Capture (iPhone: the app's Settings page)
    func copy(_ text: String) throws                 // NSPasteboard (iPhone: UIPasteboard)
    func addSystemStatus(to snapshot: DiscoverySnapshot) -> DiscoverySnapshot   // I12, default: unchanged (the iPhone: its network)
}
// CompleteScannerMac/App/SystemTroubleshooterService.swift:
@MainActor public final class SystemTroubleshooterService: TroubleshooterService { public init() }
```
Twin of `windows/CompleteScanner.Core/Troubleshooter.cs` (`IScannerBackendDiagnostics.AddStatus` / `Rescan`, `Troubleshooter.Diagnose` / `Headline` / `Summary` / `Label` / `StatusLabel` / `Report` / `CombineNetworks` / `FailureFrom`, `DiscoverySnapshot` as a record with init properties); `TroubleshooterTests` are the same cases on both sides. The apps only read the system's state and link to its settings; they never change a service or a setting. `AppState` takes an optional `troubleshooterService:` (the Mac app passes `SystemTroubleshooterService()`; without one, nothing opens and nothing is copied, both refused with `ScanError.unsupported`), keeps `lastFailure` (the last connection or scan that failed with something the troubleshooter explains, cleared by the next one that works) and `errorSuggestsTroubleshooter` (the error alert then offers Troubleshoot…), and offers `showTroubleshooter`, `hasRealDevices`, `troubleshootSnapshot()`, `refreshScanners()`, `diagnosticsText(_:)`, `copyDiagnostics(_:)` and `openTroubleshootLink(_:)`. `copyDiagnostics(_:)` and `openTroubleshootLink(_:)` return why they did not work (nil when they did) for the troubleshooter's footer and leave `errorMessage` alone, since its alert cannot show over the sheet; Windows reports the same failures in its non-modal error bar as well. `ICScannerBackend` conforms to `ScannerBackendDiagnostics` (browsing or not; Refresh restarts the browser only while nothing is listed and the browser has run at least the watchdog's first delay, 10 s, and the watchdog waits as long after a restart). A Refresh while one is running is ignored on both platforms. devices.txt ends with `Troubleshooter.report`. `CompleteScannerMac/UI/TroubleshooterView.swift` (`struct TroubleshooterView: View`) is the sheet, shown from the Scanners header, the empty list and the alert. Windows (`App/Services/SystemDiagnostics.cs`, `TroubleshooterWindow`) also reads the WIA service (`QueryServiceStatus`) and the network category (Network List Manager).

**The iPhone and iPad (I12).** `AppState.platform` (`public package(set)`, `.mac` unless the shell says otherwise; `makeForIOS` sets `.ios`) names the snapshot's platform and the label platform; `diagnosticsText` adds each connection's `diagnosticsReport` between the grouping and the checks, as Windows' devices.txt does. With `.ios`, `diagnose` gives: the network check of a phone (`.offline`: problem "Not connected to Wi-Fi", "Join the scanner's Wi-Fi network, then tap Refresh.", [refresh], more "Network scanners are found only on Wi-Fi or a wired network. The camera works without one."; public, private or domain: OK "Connected to a local network", "Network scanners on this network can be found."; unknown: none), the Windows search checks with "iOS" for "Windows" in the unavailable check's more, the addresses added by hand as on Windows, the failure check with "another device or app may be using it" and "It must be on the same network as this device.", and its own tips: "networkScanner" ("Scanner on the network?", "This device and the scanner must be on the same Wi-Fi.", more "Guest networks and some VPNs hide scanners. Try adding the scanner by its address.", [addByAddress]), "usb" ("Connected by USB?", "Use its Wi-Fi connection; iPhone and iPad can't use USB scanners.", more "Most scanners that print or copy also join Wi-Fi. The scanner's manual shows how.", no action) and "otherApps" (more "Press a button on the scanner. Close scanning apps on other devices. Some scanners work only with Windows (WSD) or their maker's app."); never the Windows or Mac checks and actions. `DiscoveryStatus.denied` gives, on every platform (only the iPhone reports it), the problem "localNetwork" in place of the search's check: "Local Network access is off", "Turn on Local Network for CompleteScanner in Settings.", [openAppSettings], more "Without it, the app can't find or reach scanners on your network. Scanners appear as soon as it's on. If it's on already, turn it off and on again." (the last sentence covers the iOS 18 state that went out of step, FB14321888). `label(.openAppSettings, _)` is "Open Settings". The new cases are appended after the existing ones on both platforms; none of these enums is stored in a settings file, so there is nothing to decode. The iPhone's `TroubleshooterService` is `IOSTroubleshooterService` (CompleteScannerIOS): `.openAppSettings` opens `UIApplication.openSettingsURLString` (the only system page an app may open; every other action is refused), Copy diagnostics puts the text on the pasteboard when the user asks, and `addSystemStatus` sets the network from `IOSNetworkPath` (NWPathMonitor: Wi-Fi or wired Ethernet on a satisfied path is `.privateNetwork`, anything else `.offline`, `.unknown` until the system has said). The iPhone's troubleshooter screen is `Views/TroubleshooterScreen.swift`, with the shared texts as the Mac's and Windows' windows show them (one-line headline, cards with More help, compact OK rows, Refresh and Copy diagnostics at the bottom).

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
    public static let iosRanking: [String]      // I12: ["escl:Network", "companion:*"]; Windows never uses it
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
Twin of `windows/CompleteScanner.Core/DeviceMerge.cs` (`HardwareId`, `ConnectionId`): same rules, same keys, same report text; `DeviceMergeTests` on both sides share one table. Only ASCII letters and digits count as model words on both platforms, so the result never depends on locale or Unicode tables. `AppState.devices` lists one entry per group (the connection in use for the selected scanner) and `AppState` writes `diagnosticsReport` to `~/Library/Logs/CompleteScanner/devices.txt` when it changes. The Mac has no connection chooser; Windows keeps the user's choice in `AppPreferences.PreferredConnection` (group key → connection id). `AppState` groups with `rankPatterns` (`package`): `macRanking`, or `iosRanking` when `platform` is `.ios` (the scanner's own network connection, then a computer's scanner through the desktop companion, which comes later); `DeviceMergeTests.Group_IosRankingPrefersTheScannersOwnNetworkConnection` on both sides.

### Core/ScanTask.swift, Core/TaskCatalog.swift, Core/TaskFlow.swift (+ ScanSettings in Core/Models.swift)

```swift
// ScanSettings gains `taskId: String?` (nil by default; left out of the file when nil) and
// the computed `task: ScanTask?` (`ScanTask.tryParse(taskId)`). The task is stored as text,
// not as the enum: a task id of a newer version reads as no task and is written back unchanged.
// ScanSettings also gains `taskOptions: TaskOptions` (the "taskOptions" object): how the user
// wants a task done, kept when a task is picked (see Pipeline/IdCard.swift).
// Since I3, `destinationBookmark: Data?` (C# `DestinationBookmark`, `byte[]?`; base64 in the file,
// left out when nil): the iPhone's save folder picked outside the app (iCloud Drive, a USB drive),
// with `destinationPath` its path. Only iOS reads it (`AppState.resolveDestinationBookmark`, set by
// `makeForIOS`; `openBookmarkedFolder()` keeps the bookmark and path up to date, also when a preset
// is applied; when it does not resolve, the bookmark and path are kept and that save goes to the
// app's folder with an alert, since the drive may only be unplugged; only Use app folder drops it);
// the Mac and Windows keep it unchanged.
// `ScanSettings.rebasedDestinationPath(_:documents:)` moves a path inside another container's
// …/Application/<UUID>/Documents into this install's Documents (`AppState.documentsFolder`, nil on the
// Mac), since the iPhone's container path changes with every update; other paths are kept, and so is
// a picked folder's (with a bookmark), which may be in another app's Documents.

public enum ScanTask: String, CaseIterable, Identifiable, Sendable {
    case document, feeder, photos, photoRestore, quickScan, email, twoSided, idCard, copy, word, receipt, batch, book, archive   // add new tasks after these
    public static func tryParse(_ rawValue: String?) -> ScanTask?
}

public enum TaskFlowKind: String, Sendable { case documentQueue, photoSplit, idCard, copy, receiptSplit }

public enum TaskGroup: String, CaseIterable, Sendable {   // the start screen's groups, in order; not stored
    case documents, photosAndImages, other
    public var title: String { get }                       // "Documents", "Photos & images", "Other"
}
public struct TaskGroupSection: Equatable, Sendable { public let group: TaskGroup; public let definitions: [TaskDefinition] }

public struct TaskDefinition: Equatable, Sendable {
    public let task: ScanTask
    public let title: String            // "Document to PDF", "Stack from feeder", "Restore old photos", "Photocopy", "Separate documents", …
    public let subtitle: String         // one short line, the tile's help: "Page by page into a searchable PDF."
    public let iconKey: String          // "document", "feeder", "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word", "receipt", "batch", "book", "archive"
    public let flow: TaskFlowKind
    public let intent: ScanIntent
    public let requiredSource: ScanSource?
    public let fileLabel: String        // what {task} becomes
    public let steps: [TaskStep]
    public let group: TaskGroup
}

public struct TaskAvailability: Equatable, Sendable {
    public let isAvailable: Bool
    public let reason: String?          // the tile's one line: "Needs a document feeder", "Needs a flatbed", "Needs a printer"
    public static let available: TaskAvailability
}

public enum TaskCatalog {
    public static let all: [TaskDefinition]                 // ScanTask.allCases order
    public static let startOrder: [ScanTask]                // group by group, as the start screen shows them
    public static var sections: [TaskGroupSection] { get }  // TaskGroup.allCases, each with its tasks in startOrder
    public static let needsFeederReason: String, needsFlatbedReason: String
    public static func unavailableMessage(_ task: ScanTask, reason: String) -> String   // "Stack from feeder needs a document feeder."
    public static func definition(_ task: ScanTask) -> TaskDefinition
    /// The task's settings over `current`; keeps the destination folder, the photo detection
    /// tuning, the legacy OCR languages, the paper size, the back binding and `taskOptions`; sets
    /// `taskId`. Only `.twoSided` sets `duplex` (`.both`); the others set `.off`. Only `.idCard`
    /// (the numbers on an ID are better not indexed) and `.copy` (a copy is for paper) turn
    /// `pdfSearchable` off. Every task turns `output.alsoSaveText` off and `output.archival` off but
    /// `.archive` (the Archive document task: 300 dpi color PDF/A at the Best size, which turns
    /// `output.protect` off; every other task keeps it, see M19 and M20 below); `.word` (Scan to Word)
    /// saves a Word document (`format = .word`, 300 dpi, collected pages); `.receipt` scans in
    /// grayscale (the only task that does) into Compact PDFs named "Receipt {docdate} {counter}";
    /// `.batch` (feeder, 300 dpi PDF, "Document {label} {date} {counter}") is the only task that
    /// splits (`document.splitMode = .separatorSheet`, the others `.none`) and turns
    /// `removeBlankPages` on with `.twoSided`; every task keeps `document.splitSheetCount`.
    /// `.book` (flatbed, 300 dpi color PDF, searchable, "{task} {date} {counter}") is the only task
    /// that splits facing pages (`document.splitFacingPages`), and turns `autoStraighten` and
    /// `autoRotate` on with `.twoSided`; every task keeps `taskOptions.bookRightToLeft` and
    /// `bookRotationQuarterTurns`.
    public static func apply(_ task: ScanTask, to current: ScanSettings) -> ScanSettings
    /// The stored task, else the task the settings look like (display and file names only): a
    /// Word document is `.word` (from the feeder, `.feeder`); a scan saved at once as an image is
    /// `.quickScan`; collected document pages with a split are `.batch`, with facing pages split `.book`.
    public static func infer(_ settings: ScanSettings) -> ScanTask
    /// `.copy` also needs a printer: `hasPrinter` false gives `PrintText.noPrinterReason` ("Needs a printer").
    public static func availability(of task: ScanTask, capabilities: ScannerCapabilities?,
                                    hasPrinter: Bool = true) -> TaskAvailability
    /// Same scan mode and, when the task has one, the required source; `.twoSided` also needs
    /// `duplex != .off`, `.word` a Word document, `.batch` a split (`document.splitMode != .none`),
    /// `.book` facing pages split (`document.splitFacingPages`; it requires the flatbed).
    public static func fits(_ task: ScanTask, _ settings: ScanSettings) -> Bool
    /// The steps the scan screen guides: `DocumentSides.manualSteps` whenever the settings turn
    /// a stack over by hand (`DocumentSides.usesManualSteps`), otherwise the fitting task's steps;
    /// nil when nothing is guided.
    public static func guidedSteps(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> [TaskStep]?
    /// The stored task's flow while it fits, otherwise by intent. The scan handler switches on it.
    public static func flow(of settings: ScanSettings) -> TaskFlowKind
    /// Pages queued under another task can still be saved once `task` is started: the `.documentQueue`
    /// tasks but `.quickScan` (Document, feeder, Email, two-sided, Word, Separate documents, Book, Archive).
    /// The iPhone asks before it starts any other task over a queue (`AppState.pagesLeftBehind(by:)`).
    public static func carriesPages(_ task: ScanTask) -> Bool
    /// "300 dpi · Color · PDF"; a PDF size other than `.standard` is named: "300 dpi · Color · Compact PDF";
    /// two-sided feeder scanning too: "… · Both sides", "… · Both sides, turned by hand"; a copy
    /// (flow `.copy`) says how it prints: "300 dpi · Color · Actual size", "… · Fit to page · 3 copies";
    /// collected document pages that are split say so: "… · Split at separator sheets", "… · Split every 3 sheets",
    /// and so do their facing pages: "… · Facing pages split", "… · Facing pages split, right to left"
    public static func summary(_ settings: ScanSettings) -> String
}

public struct TaskStep: Equatable, Sendable {
    public let id: String, title: String, primaryActionLabel: String
    public let prompt: String           // one short line (ten words at most), the banner's
    public let help: String             // the fuller guidance behind the banner's info button; "" when the prompt says it all
    public let skippable: Bool, repeats: Bool, requiresCapture: Bool
    public init(id:title:prompt:primaryActionLabel:skippable: = false, repeats: = false, requiresCapture: = true, help: = "")
    public var word: String { get }       // the step in one word for "Front · Back · Check": "Scan the front sides" is "Front"
    public var fullPrompt: String { get } // prompt and help, for screen readers
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
Twins of `windows/CompleteScanner.Core/ScanTask.cs`, `TaskCatalog.cs` and `TaskFlow.cs` (C# names in PascalCase; `TaskCatalog.FlowOf` for `flow(of:)`, `ScanTasks.TryParse` / `RawValue`); `ScanTaskTests` and `TaskFlowTests` are the same cases on both sides, the Archive document task (`ScanTask.archive`, M19, I5) included. The iPhone does not offer it yet (`IOSShell.offers`: its Archive & password settings come later). Task cards exist only for features that are built; later features add a `ScanTask` case, a catalog entry and their steps. `AppState` (`App/AppState+Tasks.swift`) keeps the task in `settings.taskId`, so it is saved and restored with the settings: `startTask(_:)`, `exitTask()`, `skipStep()` (the current step when it is skippable), `taskCards`, `activeTask`, `taskFlow`, `primaryActionLabel`, `isFirstRun`. Its `settings` didSet ends a task the settings no longer fit. `startTask(_:)` never touches the queue: the pages stay whatever the task. `pagesLeftBehind(by:)` counts the queued pages a task would leave without a Save (all of them unless `TaskCatalog.carriesPages`), and `discardPages(andStart:)` starts the task and then drops them with their spooled files, the scan history kept (Swift only, the iPhone's Discard; `AppStateTaskSwitchTests`). The banner offers Skip for a skippable step (the ID card's back: `IdCardSteps.skipBackLabel`, "No back side"). Titles changed from the first versions (Multi-page from feeder, Old photo restoration, Copy, Batch of separate documents are now Stack from feeder, Restore old photos, Photocopy, Separate documents); settings files and presets store the raw value (`taskId`), never the title, so they read as before (`ModelsCompatTests` checks the four on both sides), and preset names saved with the old titles are left as they are.

### Core/StatusLine.swift, Core/InspectorSections.swift (the short texts both apps show)

```swift
public enum StatusLine {
    public static let maxWords: Int                                   // 6
    public static func words(_ text: String) -> Int                   // tokens with a letter or digit
    /// The status sentence in six words at most, facts only: "Page 3 added", "6 pages added · 1 blank",
    /// "Saved", "Saved 3 photos", "Ready — Demo Scanner" (for "Ready for “…”." with `deviceName`), else its
    /// first sentence or what comes before a dash, a colon or a comma, else six words and "…". A setting
    /// changed for the scanner (`SettingsAdapter`'s notes) or a two-sided scan that came back one-sided
    /// keeps a short warning ("… · 300 dpi used", "… · one side only"); when both can't fit, the warnings win.
    public static func short(_ message: String, deviceName: String? = nil) -> String
    public static func withWarnings(_ head: String, message: String) -> String
    public static func warnings(_ message: String) -> [String]
    /// "" while a review shows its own title; "Saved" (with warnings) for a message about a save while
    /// the saved files' actions show; else `short`.
    public static func shown(_ message: String, deviceName: String?, reviewShown: Bool, savedShown: Bool) -> String
}

public enum InspectorSections {
    public static let task, scanner, output, adjustments, pages, split, archive, more: String   // "task", "scanner", …
    public static let all: [String]                                    // in the column's order
    public static func title(_ section: String) -> String              // "Scanner", "Split into documents", "Archive & password"
    public static func openByDefault(_ section: String) -> Bool        // the task's section, Scanner and Output
    public static func openedBy(_ scanTask: ScanTask) -> String?       // .photoRestore adjustments, .book pages, .batch split, .archive archive
    public static func scannerSummary(_ s: ScanSettings) -> String     // "Flatbed · 300 dpi · Color", "Feeder · both sides · 200 dpi · Gray"
    public static func scannerChanged(_ s: ScanSettings) -> Bool
    public static func outputSummary(_ s: ScanSettings, shownFormat: OutputFormat) -> String   // "PDF · Standard", "Word", "JPEG"
    public static func outputChanged(_ s: ScanSettings, shownFormat: OutputFormat) -> Bool
    public static func adjustmentsSummary(_ a: AdjustmentSettings) -> String    // "Edited", "Auto" or ""
    public static func pagesSummary(_ d: DocumentOptions) -> String             // "Skip blank · Upright +1"
    public static func pagesOn(_ d: DocumentOptions) -> Int
    public static func splitSummary(_ d: DocumentOptions) -> String             // "Off", "Separator sheets", "Every 3 sheets", "QR codes"
    public static func archiveSummary(_ o: OutputOptions) -> String             // "Off", "PDF/A", "Password on"
    public static func moreSummary(_ o: OutputOptions, textShown: Bool) -> String   // "Open after saving · .txt"
    public static func headerName(_ title: String, summary: String) -> String   // "Scanner, Flatbed · 300 dpi · Color"
    public static func pagesHeaderName(_ d: DocumentOptions) -> String          // "Pages, 2 options on"
    // I15: the sections for a setting, as both desktops show them and the iPhone's Settings lists them
    public static func shown(_ s: ScanSettings) -> [String]            // in order: task (Photocopy, Receipts), scanner, output,
                                                                       // adjustments, pages and split (document pages, not those
                                                                       // two tasks), archive (writesPDF), more
    public static func taskTitle(_ s: ScanSettings) -> String?         // "Photocopy", "Receipts"; nil
    public static func title(_ section: String, for s: ScanSettings) -> String   // the task's, "Photos" for Output in Photos mode
    public static func shownFormat(_ s: ScanSettings) -> OutputFormat  // receipts pageFormat, photos imageFormatOrJPEG, else format
    public static func writesPDF(_ s: ScanSettings) -> Bool            // the Windows WritesPdf: document intent; copy copyAlsoSavePdf;
                                                                       // receipts and ID card pageFormat == .pdf; else savesPDF
    public static func textApplies(_ s: ScanSettings) -> Bool          // Also save text: the queue saving a PDF, receipts as PDFs
    public static func summary(_ section: String, for s: ScanSettings) -> String   // "" for the task's section
    public static func changed(_ section: String, for s: ScanSettings) -> Bool     // the collapsed header's dot
    public static func accessibleName(_ section: String, for s: ScanSettings) -> String   // pagesHeaderName for Pages
}
```
Twins of `windows/CompleteScanner.Core/StatusLine.cs` and `InspectorSections.cs`; `StatusLineTests` and `InspectorSectionsTests` are the same cases on both sides. The status line's visible text is `shown` (Windows `MainWindow.LessText.cs`, the Mac `StatusBarView`), and the whole sentence stays its accessible name. The column's choices also carry their short help in Core: `ScanSource.hint` ("Automatic document feeder (ADF)"), `PDFSizePreset.hint` and `detail` (the dpi limits, for screen readers), `DuplexMode.hint`, `DuplexBinding.pickerHint`, `BlankSensitivity.hint` and `highWarning`, `SplitMode.hint`, `caption` and `steps`, `AfterSaveAction.hint` (C#: `ModelLabels.Hint` / `Detail` / `Caption` / `Steps`, `DuplexBindings.PickerHint`, `BlankSensitivities.HighWarning`).

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
    public static let needsFeederReason: String         // "Needs the feeder": next to Sides on the flatbed of a scanner with a feeder
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
    public static func sideLabel(side: PageSide?, sheetIndex: Int?) -> String?   // the badge: "2 · back", "Front"
    public static func sideName(side: PageSide?, sheetIndex: Int?) -> String?    // spoken: "Sheet 2, back", "Front"
    /// Pages of a two-sided scan in reading order, marked, backs turned upright for `binding`.
    public static func arrangeTwoSided(_ pages: [ScannedPage], binding: DuplexBinding, reverseOrder: Bool = false) -> [ScannedPage]
    /// One scan of a stack turned over by hand, marked as fronts or backs (backs turned upright;
    /// a spooled page's file turns at save time through `rotationQuarterTurns`).
    public static func markManual(_ pages: [ScannedPage], side: PageSide, binding: DuplexBinding) -> [ScannedPage]
    /// I14: pages a camera took of one side of their sheets, marked as that side, the sheet a page was given
    /// kept; never turned for the binding (the user turned the sheet over; OrientationStep fixes a back).
    public static func markCamera(_ pages: [ScannedPage], side: PageSide) -> [ScannedPage]
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
    public static func hint(_ size: PaperSize, source: ScanSource) -> String   // an item's help: "From the glass corner. A preview selection replaces it."
    public static func doesNotFitReason(source: ScanSource) -> String         // "Too big for this glass" / "… feeder"
    public static let selectedAreaNote: String                                // "Using the selected area"
}
```
Twins of `windows/CompleteScanner.Core/DocumentSides.cs` and `PaperSize.cs` (`PaperSizes.Label` / `Detail` / `RawValue` as extensions, `DocumentSides.FrontsStepId` / `ArrangeTwoSided` / `MarkManual` / `MarkCamera` / `CollateQueue`, `ScannedPage.WithImage` / `CopyMeta` / `WithSide`; C# also has `ScannedPage.RotatedClockwise`, which keeps the sides); `DocumentSidesTests`, `PaperSizeTests` and the sides cases of `ModelsCompatTests`, `ScanTaskTests`, `SettingsAdapterTests` and `MockScannerTests` are the same on both sides. Every backend returns the pages of a two-sided scan in reading order, front, back, front, back… (ImageCaptureCore reorders a feeder with `reverseFeederPageOrder`); the app (`AppState.performScan`) asks the backend for `.both` only when `effective` says so, then marks the sides and turns the backs upright (`arrangeTwoSided`, `markManual`) before adjusting, recording history and spooling. Turning a stack over by hand is guided through `TaskFlow` with `manualSteps`, with or without a task (`AppState.isTurningOverByHand`, `awaitingBacks`, `canFinishFronts`, `canScanMoreFronts`, `sidesMismatch`, `finishFronts()`, `scanMoreFronts()`, `combineSidesAnyway()`, `scanBacksAgain()`, `keepFrontsOnly()`, `scanOneSideOnly()`): the fronts advance the steps unless the feeder stopped early (then the rest of the fronts is scanned and `finishFronts()` moves on), `scanMoreFronts()` goes back to the fronts before any back is scanned, the backs are put in order in the queue when the counts pair up, otherwise the mismatch is shown. A scan asked for `.both` whose session says it scanned one side (`lastScanDuplex == false`) is queued one-sided. When the capabilities could not be read on connect, a scan that works reads them again. The flatbed scans `flatbedSelection` of the paper size when nothing is selected; backends ask the feeder for `feederRegionInches`. The demo feeder (`MockScannerBackend.feederDuplex`, `feederStackTurnedOver`) scans its three sheets one side or both.

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
// For rotate pages upright it gains `upright: UprightTurn?` (nil: not turned; see
// Pipeline/Orientation.swift below); copyMeta(from:) and every with… copy it:
//   public func withUpright(_ upright: UprightTurn?) -> ScannedPage
//   public func turnedUpright(_ quarterTurns: Int) -> ScannedPage   // pixels (and the alternate's in memory) turned clockwise, the turn recorded;
//                                                                    // the rotation grows only when a spool file holds the unturned page; 0 turns: unchanged
//   public func withUprightToggled() -> ScannedPage                 // undo, or make again, through the page's rotation like a turn by hand; not turned: unchanged
// For books it gains `spread: SpreadPart?` (nil: not cut from a spread; in memory only, see
// Pipeline/BookSplitter.swift below) and `spreadID: UUID?` (`spread?.spreadID`); copyMeta(from:),
// withGeometry and withVersionsSwapped keep it:
//   public func withSpread(_ spread: SpreadPart?) -> ScannedPage
// For softening the spine's shadow it gains `spineShadow: SpineShadowResult?` (nil: not softened; in
// memory only, see Pipeline/SpineShadow.swift below); copyMeta(from:), withGeometry and
// withVersionsSwapped keep it, and canSwapVersions is (geometry != nil || spineShadow != nil) && alternate != nil:
//   public func withSpineShadow(_ softened: CGImage, result: SpineShadowResult) -> ScannedPage   // the alternate stays the page
//                                                                 // as scanned when there is one, else the page as it was becomes it
// For photos of documents it gains `source: PageSource` (.scanner; in memory only, see
// Pipeline/PhotoImport.swift below); copyMeta(from:) and every with… copy it:
//   public enum PageSource: String, Sendable { case scanner, photo }   // not persisted
// For camera pages it gains `capture: CaptureFacts?` (nil: not taken by a camera; see
// Pipeline/CaptureScale.swift below; carried by companion packages); copyMeta(from:), withGeometry,
// withSpineShadow, withVersionsSwapped and every with… copy it:
//   public func withCapture(_ capture: CaptureFacts?) -> ScannedPage
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
    public var splitMode: SplitMode = .none         // "splitMode" (see Core/DocumentSplitter.swift below)
    public var splitSheetCount: Int = 1             // "splitSheetCount"; read through DocumentSplitter.clampSheetCount
    public var autoRotate: Bool = false             // "autoRotate" (see Pipeline/Orientation.swift below)
    public var splitFacingPages: Bool = false       // "splitFacingPages" (see Pipeline/BookSplitter.swift below)
    public var softenSpineShadow: Bool = false      // "softenSpineShadow" (see Pipeline/SpineShadow.swift below)
    public var barcodeStartsDocument: Bool = false  // "barcodeStartsDocument" (see Pipeline/Barcodes.swift below)
    public var splitBarcodePrefix: String = BarcodeSeparators.defaultPrefix   // "splitBarcodePrefix" ("CS-SEP"; no inspector field)
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
/// A step that can stop part way: `process` hands it its `shouldContinue` (C# `ICancellablePageStep`, the token).
public protocol CancellablePageStep: PageStep { func apply(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage }
public struct BlankDetectionStep: PageStep { public let options: BlankPageOptions }   // "blank"
public struct PerspectiveStep: PageStep { public init() }   // "perspective": a page with capture (scale nil) and no geometry:
    // CaptureScale.measure (the quad and focal length scaled to the pixels at hand), PerspectiveWarp.warp at its pixel size,
    // dpi = scale.dpi, capture.scale set, then withGeometry(PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective,
    // quad:)); other pages and quads that are not convex unchanged
public struct GeometryStep: PageStep { public let crop: Bool; public let straighten: Bool }   // "geometry": DocumentGeometry.correct, then withGeometry;
    // pages with capture or a .perspective geometry unchanged (cut out along their corners already, no scanner background)
public struct SpineShadowStep: PageStep { public let rotationQuarterTurns: Int; public init(rotationQuarterTurns: Int) }   // "spineShadow":
    // SpineShadow.gutterEdge(page.spread, …), SpineShadow.soften, then withSpineShadow; rotationQuarterTurns normalized
public struct SeparatorStep: PageStep { public init() }   // "separator": PatchCodeDetector.detect, then withPatch
public struct BarcodeStep: CancellablePageStep {            // "barcode": BarcodeSeparators.readPage, then withBarcodes;
    public let reader: any BarcodeReader; public init(reader: any BarcodeReader)   // a reader that throws leaves the page unread
}
public struct OrientationStep: CancellablePageStep {        // "orientation": OrientationDecision.check, then turnedUpright
    public let scorer: any OrientationScorer; public let maxSeconds: Double; public let split: DocumentOptions?
    public init(scorer: any OrientationScorer, maxSeconds: Double = OrientationDecision.maxSecondsPerPage,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, split: DocumentOptions? = nil)
}   // blank pages (blank?.isBlank), separator sheets (patch != nil) and, under `split`, barcode or QR separator
    // sheets (BarcodeSeparators.isSeparatorPage) are not read; forScan passes settings.document
public struct AdjustmentStep: PageStep { public let adjustments: AdjustmentSettings; public let colorMode: ColorMode }   // "adjust" (the alternate's pixels too)
extension AdjustmentStep { public func mode(for page: ScannedPage) -> ColorMode }   // I9 (C# ModeFor): a color task keeps a camera page made gray or black and white
public enum ScanArrangement: Sendable { case asScanned, twoSided, turnedOverFronts, turnedOverBacks,
                                          cameraFront, cameraBack }   // I14: the iPhone's two-sided camera (markCamera); Windows never produces them
public struct ProcessedScan {
    public let arranged: [ScannedPage]; public let pages: [ScannedPage]; public var blankCount: Int
    public var spreads: [ScannedPage]        // the arranged pages that pages were cut from (or kept whole as)
}
public struct PageProcessor {
    public let steps: [any PageStep]; public let arrangement: ScanArrangement; public let binding: DuplexBinding
    public let book: BookSplitOptions?        // nil: spreads are not split
    public let prepare: [any PageStep]        // I14: run on each arranged page before the steps and before a spread is cut;
                                              // forCapture's cut and clean-up (so `arranged` holds the page cut out); none for a scan
    public init(steps: [any PageStep], arrangement: ScanArrangement = .asScanned, binding: DuplexBinding = .longEdge,
                book: BookSplitOptions? = nil, prepare: [any PageStep] = [])
    /// Blank check (when `checksBlankPages`), crop and straighten (when `correctsGeometry`), softening the
    /// spine's shadow (when `softensSpineShadow`, with BookSplitOptions.of(settings).rotationQuarterTurns), the
    /// separator-sheet check (when `checksBlankPages`, whatever the split), reading barcodes (when
    /// `readsBarcodes` and `barcodes?.isAvailable`), turning pages upright (when `turnsPagesUpright` and
    /// `scorer?.isAvailable`), then adjustments (unless they change nothing);
    /// `book` = `BookSplitOptions.of(settings)` when `splitsFacingPages`.
    public static func forScan(_ settings: ScanSettings, arrangement: ScanArrangement = .asScanned,
                               scorer: (any OrientationScorer)? = nil,
                               barcodes: (any BarcodeReader)? = nil) -> PageProcessor
    /// Document queue flow and documentMultiPage: pages saved at once are never checked.
    public static func checksBlankPages(_ settings: ScanSettings) -> Bool
    /// checksBlankPages and (autoCrop or autoStraighten): pages saved at once are never changed unseen.
    public static func correctsGeometry(_ settings: ScanSettings) -> Bool
    /// checksBlankPages and autoRotate: pages saved at once are never turned unseen.
    public static func turnsPagesUpright(_ settings: ScanSettings) -> Bool
    /// checksBlankPages and splitMode == .barcode: reading takes time, so other splits never read codes.
    public static func readsBarcodes(_ settings: ScanSettings) -> Bool
    /// checksBlankPages and splitFacingPages: pages saved at once are never cut unseen.
    public static func splitsFacingPages(_ settings: ScanSettings) -> Bool
    /// splitsFacingPages and softenSpineShadow.
    public static func softensSpineShadow(_ settings: ScanSettings) -> Bool
    /// Pages made from imported photos (always queued): the blank check, the separator-sheet check, reading
    /// barcodes (splitMode == .barcode and `barcodes?.isAvailable`), turning upright (autoRotate and
    /// `scorer?.isAvailable`), then adjustments (unless they change nothing); never crop and straighten, the
    /// spine's shadow or splitting facing pages (the page was cut out along its corners already).
    public static func forPhotoImport(_ settings: ScanSettings, scorer: (any OrientationScorer)? = nil,
                                      barcodes: (any BarcodeReader)? = nil) -> PageProcessor
    /// Pages taken by a camera: PerspectiveStep, then the steps of forPhotoImport. I14: `arrangement` marks
    /// the iPhone's two-sided pages (.cameraFront, .cameraBack); a book's whole spread (`splitsCameraSpreads`)
    /// gets PerspectiveStep and EnhanceStep as `prepare`, then `book` (BookSplitOptions.of) and the queue's
    /// steps with the spine's softening after the blank check when `softensSpineShadow`.
    public static func forCapture(_ settings: ScanSettings, scorer: (any OrientationScorer)? = nil,
                                  barcodes: (any BarcodeReader)? = nil,
                                  arrangement: ScanArrangement = .asScanned) -> PageProcessor
    /// I14: splitsFacingPages and taskOptions.cameraSpreads (the iPhone's "Whole spread"; page by page otherwise).
    public static func splitsCameraSpreads(_ settings: ScanSettings) -> Bool
    /// Arranges (DocumentSides.arrangeTwoSided / markManual / markCamera), runs `prepare` on each arranged
    /// page (they are `arranged` from then on), then every step on every page in
    /// order; throws ScanError.cancelled when `shouldContinue` says no (asked before each page and
    /// step, and handed to a CancellablePageStep).
    public func process(_ scanned: [ScannedPage], shouldContinue: () -> Bool = { true }) throws -> ProcessedScan
    /// One spread cut at `cut` (nil: kept whole), each page turned by options.rotationQuarterTurns, every
    /// step run, then put in reading order (see Pipeline/BookSplitter.swift below). With `book`, `process`
    /// calls it for every arranged page with `BookSplitter.findGutter`.
    public func processSpread(_ spread: ScannedPage, cut: GutterResult?, options: BookSplitOptions,
                              shouldContinue: () -> Bool = { true }) throws -> [ScannedPage]
}
public enum PageFilter {
    public static let nothingToSaveMessage: String
    public static func looksBlank(_ page: ScannedPage, sensitivity: BlankSensitivity) -> Bool
    public static func isExcluded(_ page: ScannedPage, options: DocumentOptions) -> Bool   // keep / skip, else the setting
    public static func toggled(_ page: ScannedPage, options: DocumentOptions) -> PageInclusion   // two clicks undo one
    public static func pagesToSave(_ pages: [ScannedPage], options: DocumentOptions) -> [ScannedPage]
    public static func badge(_ page: ScannedPage, options: DocumentOptions) -> String?          // "Blank, skipped", "Skipped", "Looks blank"
    public static func toggleLabel(_ page: ScannedPage, options: DocumentOptions) -> String?    // "Keep this page", "Skip this page"
    public static func queueSummary(_ pages: [ScannedPage], options: DocumentOptions) -> String  // "24 pages · 5 blank skipped"
    public static func scanNote(_ added: [ScannedPage], options: DocumentOptions) -> String     // " 2 look blank and will be skipped."
}
public enum PageCorrections {                                           // a page taken from a photo (geometry.basis == .perspective):
                                                                        // "Corrected from photo" / "As photographed", "Show as photographed" /
                                                                        // "Show corrected", "Page 3 is shown as photographed. It is saved that
                                                                        // way." / "Page 3 is corrected again."; scanNote leaves such pages out
    public static func caption(_ page: ScannedPage) -> String?          // "Cropped and straightened 2.4°", "As scanned", nil;
                                                                        // softened: "Spine shadow softened", "Straightened 1.5°, spine shadow softened"
    public static func toggleLabel(_ page: ScannedPage) -> String?      // "Show as scanned", "Show straightened", nil when it cannot swap;
                                                                        // softened: "Show with the spine shadow softened", "Show straightened, with the spine shadow softened"
    public static func swapNote(_ page: ScannedPage, number: Int) -> String   // "Page 3 is shown as scanned. It is saved that way.";
                                                                        // "Page 3 is shown with the spine shadow softened again.", "Page 3 is straightened again, with the spine shadow softened."
    public static func scanNote(_ added: [ScannedPage]) -> String        // " 2 straightened.", " 3 cropped or straightened.", then " Spine shadow softened on 2 pages."
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
public enum GeometryBasis: CaseIterable, Sendable { case pageEdges, textLines, perspective }   // perspective: cut out of a photo
                                                         // along its corners (PhotoImport, PerspectiveStep); caption "Corrected from photo"
public enum GeometryAction: Sendable { case cropStraightened, cropBox, rotate }
public struct PageGeometry: Equatable, Sendable {  // not persisted
    public let cropped: Bool; public let angleDegrees: Double; public let basis: GeometryBasis
    public let quad: Quad?                         // .perspective: the corners cut along, in the other version's (the photo's) pixels
                                                   // as taken, before any turn; nil otherwise and when not known
    public init(cropped: Bool, angleDegrees: Double, basis: GeometryBasis, quad: Quad? = nil)
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
/// The limits a sheet is held to (`findPage(_:options:)`); `.default` is the constants below. Only the
/// Receipts task asks for others (`ReceiptDetector.pageSearch`: contrast 0.02, fill 0.85, aspect 15).
public struct PageSearchOptions: Equatable, Sendable {
    public var pageContrast: Double, minPageAreaFraction: Double, maxPageAreaFraction: Double
    public var minPageFill: Double, maxPageAspect: Double      // each defaults to its DocumentGeometry constant
    public init()
    public static let `default`: PageSearchOptions
}
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
    public static func findPage(_ gray: GrayImage) -> PageSearch                       // findPage(gray, options: .default)
    public static func findPage(_ gray: GrayImage, options: PageSearchOptions) -> PageSearch
    public static func ringWidth(_ w: Int, _ h: Int, dpi: Double) -> Int
    public static func backgroundLuminance(_ gray: GrayImage) -> Int
    public static func borderColor(_ image: RgbaImage, dpi: Int) -> (r: UInt8, g: UInt8, b: UInt8)
    public static func safeCanvas(_ gray: GrayImage, angleDegrees: Double) -> CGSize
    public static func estimateTextLayout(_ gray: GrayImage) -> TextLayout
    // internal: median3x3, edgeInsets(_:dpi:) -> (left, top, right, bottom),
    //           refined(_:image:background:tolerance:) (the full-resolution snap, also used by ReceiptDetector)
}
```
Twin of `windows/CompleteScanner.Core/DocumentGeometry.cs` (`TextAxis`, `TextLayout`, `GeometryBasis`, `GeometryAction`, `PageGeometry`, `GeometryPlan`, `GeometryCorrection`, `PageRejection`, `PageSearch`, `DocumentGeometry` with the same members in PascalCase); `DocumentGeometryTests` are the same cases on both sides, on the same synthetic pages (`TestPages.textPage`, `turned`, `sheetOnBackdrop`, drawn with fixed-point sines and cosines, checked by checksum). Everything works on the page's gray copy at the analysis resolution and changes the full-resolution pixels once (`RgbaImage.extractRotated` or `cropped`), so both platforms compute the same plan; the full-resolution snap of the sheet's edges goes through `PhotoDetector.refineRegion`, which draws with CoreGraphics on the Mac and with `RgbaImage` on Windows, and is only taken when no edge moves by more than `refineTolerance` analysis pixels. The rules: the backdrop is the median of a thin outer ring, with a threshold widened on textured backdrops; the sheet is the largest region of what differs from it (closed, holes filled, strands cut), taken only when it covers 15–99 % of the scan, fills ≥ 90 % of its rectangle, is at most 5 times as long as wide, has no more than 8 text-like marks around it and nothing beside it as large as 2 % of it; a sheet with more than 10 % of its outline on the scan's edge takes its angle from the text and its crop is the smallest rectangle at that angle around it; a sheet's edges win over the text; turns under 0.2° are left alone, sheets beyond 15° are cropped along their box, text skew is searched over ±7° (a best angle at the end of the sweep is not trusted); turning a scan in place never cuts off content from its corners (the canvas grows instead, its outermost 0.02 in excepted); and the dark lines along the edges of an upright crop (shadow, backdrop) are trimmed, at most 0.04 in.

### Pipeline/Orientation.swift (+ DocumentOptions, ScannedPage in Core/Models.swift), VisionOrientationScorer in Output/OCRService.swift

```swift
public struct OrientationScore: Equatable, Sendable {
    public let letters: Int; public let wordLetters: Int  // letters and digits read; those in words that look like words
    public init(letters: Int, wordLetters: Int)
    public static let none: OrientationScore
    public static func of(_ lines: [String]) -> OrientationScore      // words split at white space
    public static func wordScore(_ word: String) -> Int  // punctuation around it dropped; >= 2 long; a number, or letters (parts joined by - ' ’)
                                                         // in one case each: lower, CAPS, Capitalized or a script without case; else 0
    public var readsClearly: Bool                        // wordLetters >= clearWordLetters && wordLetters >= clearShare * letters
}
public protocol OrientationScorer {                       // C# IOrientationScorer
    var isAvailable: Bool { get }
    func score(_ image: RgbaImage) throws -> OrientationScore        // the image as it is; C# also takes a CancellationToken
}
public enum OrientationVerdict: Sendable { case upright, turned, unsure, noText, outOfTime }
public struct CandidateScore: Equatable, Sendable { public let quarterTurns: Int; public let score: OrientationScore }
public struct OrientationCheck: Equatable, Sendable {
    public let verdict: OrientationVerdict; public let quarterTurns: Int   // clockwise turns that make the page upright; 0 unless .turned
    public let scores: [CandidateScore]; public let layout: TextLayout; public let seconds: Double
    public var passes: Int { get }
}
public enum OrientationDecision {
    // analysisMaxSide 1600, minWordLetters 20, margin 2.0, clearWordLetters 150, clearShare 0.85, maxSecondsPerPage 3
    public static func candidates(_ layout: TextLayout) -> [Int]   // [0, 2] across, [1, 3] down, [0, 2, 1, 3] not clear
                                                                   // (axis unknown or confidence < minConfidence), [] under minInkPoints
    public static func choose(_ scored: [CandidateScore]) -> Int?  // best wordLetters >= minWordLetters and >= margin × every other; else nil
    public static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int)   // longest side at most 1600, rounded half to even
    public static func analysisImage(_ image: RgbaImage) -> RgbaImage
    public static func check(_ image: RgbaImage, dpi: Int, scorer: any OrientationScorer,
                             maxSeconds: Double = maxSecondsPerPage, clock: @escaping () -> Double = { … },
                             shouldContinue: () -> Bool = { true }) throws -> OrientationCheck
}
public struct UprightTurn: Equatable, Sendable { public var quarterTurns: Int; public var undone: Bool }   // not persisted
public enum PageTurns {
    public static func caption(_ page: ScannedPage) -> String?      // "Turned upright 180°", "… 90° clockwise", "… 90° counterclockwise", "Turned back as scanned"
    public static func toggleLabel(_ page: ScannedPage) -> String?  // "Undo turn", "Turn upright again"
    public static func toggleNote(_ page: ScannedPage, number: Int) -> String   // "Page 3 is turned upright again." / "… turned back as scanned. It is saved that way."
    public static func scanNote(_ added: [ScannedPage]) -> String   // " 2 turned upright."
    public static let unavailableNote: String                       // " Pages were not turned upright: no text recognition language is installed."
    public static func hint(_ settings: ScanSettings, available: Bool) -> String
}
// Output/OCRService.swift:
//   OCRService.orientationScore(in image: CGImage) throws -> OrientationScore   // VNRecognizeTextRequest .fast, no language
//                                                    // correction, lines whose top candidate is more than 0.3 sure
//   public struct VisionOrientationScorer: OrientationScorer { public init() }   // always available
```
Twin of `windows/CompleteScanner.Core/Orientation.cs` (`OrientationScore.Of` / `WordScore` / `ReadsClearly`, `IOrientationScorer`, `OrientationVerdict`, `CandidateScore`, `OrientationCheck`, `OrientationDecision`, `UprightTurn`, `PageTurns`), `OrientationStep` and `ICancellablePageStep` in `PageProcessor.cs`, `DocumentOptions.AutoRotate` and `ScannedPage.Upright` / `WithUpright` / `TurnedUpright` / `WithUprightToggled` in `Models.cs`; the scorers are `WindowsOrientationScorer` (`windows/CompleteScanner.App/Services/WindowsOrientationScorer.cs`: the recognizer of the user's languages, else the first installed, one recognizer only) and `VisionOrientationScorer`. `OrientationTests` are the same cases on both sides, on `TestPages.textPage` with a dark square in its top left corner, read by a stand-in scorer that tells the way up by that corner and answers like real OCR (well upright, words that are not words upside down, next to nothing sideways), and the rotate cases of `PageProcessorTests`, `ModelsCompatTests` and `ScanTaskTests` match. The rules: a page's lines of text (`DocumentGeometry.estimateTextLayout` on its gray copy) choose the ways up worth reading; each is read once on a copy at most 1600 px long, turned in Core (`rotatedQuarterTurns`), the likeliest first; a reading that is clear is taken at once when it is the page as it is (an upright page costs one reading) or, once the page was read the opposite way up (180° from it), has twice the letters in words of every way read before it (so a sideways page is always read both quarter turns); otherwise every way worth reading is read and the most letters in words win with at least 20 and twice as many as any other way; no new reading starts after 3 s, a failed reading leaves the page, blank pages (as checked) and separator sheets are never read. `OrientationStep` runs after the separator check and before the adjustments, on pages collected in the queue only (`turnsPagesUpright`), and only when the scorer can read; `TaskCatalog.apply` turns `autoRotate` on for `.twoSided` only. A turned page's pixels, and its alternate's, are turned before it is spooled (the spool files hold the page upright, its rotation stays 0); undoing goes through the rotation (`withUprightToggled`) whenever either version has a spool file (pixels in memory turn at once and ignore the rotation when saved), so the spool files are never rewritten and a turn by hand adds to it. The Windows turn button's glyph (U+E72C, the twin of `arrow.clockwise`) differs from the hover bar's rotate (U+E7AD). `AppState` takes an optional `orientationScorer:` (default `VisionOrientationScorer()`), passes it to `forScan` in `performScan`, adds `PageTurns.scanNote` to the status after a scan (`queueScanNote`) and `unavailableNote` when pages were to be turned and the scorer cannot read, and offers `canTurnPagesUpright` and `togglePageUpright(id:)` (behind a swap still reading its file, like a turn by hand; the status gives `toggleNote`). Windows has the same in `AppViewModel` (`orientationScorer` constructor parameter, `CanTurnPagesUpright`, `TogglePageUpright`, `PageItem.UprightCaption` / `UprightToggleLabel` / `UprightToolTip`), the inspector's **Rotate pages upright** switch and its hint, and the page's turn button in `MainWindow.xaml`. The Mac shows the switch under Straighten pages (`InspectorView.autoRotateRow`) and the turn button under the page beside the swap button (`PagesStripView`).

### Pipeline/BookSplitter.swift (+ DocumentOptions, TaskOptions, ScannedPage in Core/Models.swift), App/AppState+Book.swift, CompleteScannerMac/UI/SpreadSplitView.swift

```swift
// DocumentOptions gains `splitFacingPages: Bool` (false; "splitFacingPages"); TaskOptions gains
// `bookRightToLeft: Bool` (false) and `bookRotationQuarterTurns: Int` (0; read through
// BookSplitter.normalizedTurns), kept when a task is picked.
public enum GutterAxis: Sendable { case vertical, horizontal }   // up and down the scan (pages side by side) / across it (stacked)
public enum GutterKind: Sendable { case shadow, margin, manual }
public struct GutterResult: Equatable, Sendable {
    public var axis: GutterAxis; public var position: Int   // scan pixels from the left (top) edge; 1 ... length − 1
    public var confidence: Double; public var kind: GutterKind
    public func fraction(width: Int, height: Int) -> Double
}
public struct SpreadPart: Equatable, Sendable {        // ScannedPage.spread; never saved
    public var spreadID: UUID                           // the id of the page as scanned
    public var part: Int?                               // 0 left/top, 1 right/bottom as on the scan; nil: the whole spread
    public var gutter: GutterResult?                    // nil when whole
    public var left: Bool?                              // the left page, as worked out when the spread was cut (processSpread); nil: not recorded
    public init(spreadID: UUID, part: Int?, gutter: GutterResult?, left: Bool? = nil)   // C# SpreadPart(SpreadId, Part, Gutter, Left = null)
    public var isWhole: Bool { get }
    public var isLeft: Bool { get }                     // left ?? (part == 0)
}
public struct BookSplitOptions: Equatable, Sendable {
    public var rotationQuarterTurns: Int; public var rightToLeft: Bool
    public init(rotationQuarterTurns: Int = 0, rightToLeft: Bool = false)
    public static func of(_ settings: ScanSettings) -> BookSplitOptions
}
public struct GutterCandidate: Equatable, Sendable { public var axis: GutterAxis; public var center: Double; public var confidence: Double; public var kind: GutterKind }
public struct GutterProfile: Equatable, Sendable { public var axis: GutterAxis; public var brightness: [Double]; public var ink: [Double]; public var length: Int }
public enum BookSplitter {
    // analysisMaxSide 1000, bandFraction 0.1, smoothInches 0.05 (minSmoothPixels 3), search 0.25…0.75,
    // inkStep 24, paperLevelPercentile 0.9, minShadowDepth 0.08, minShadowWidthInches 0.08,
    // maxShadowWidthFraction 0.12, textLevelPercentile 0.8, shadowInkFraction 0.5,
    // shadowSymmetryFraction 0.12, oneSidedShadowDepth 0.15, marginInkFraction 0.25,
    // marginBlankFraction 0.1, minMarginInches 0.6, marginSymmetryFraction 0.25,
    // marginPaperFraction 0.97, sideInches 1.5, minSideInk 0.25, bottomFraction 0.1,
    // lineCheckBandInches 0.3, longSideBonus 1.25
    public static func findGutter(_ image: RgbaImage, dpi: Int) -> GutterResult?
    public static func findGutter(_ image: CGImage, dpi: Int) -> GutterResult?   // read in bands (GrayImage(cgImage:))
    public static func analysisImage(_ image: RgbaImage, dpi: Int) -> GrayImage
    public static func findGutter(_ gray: GrayImage) -> GutterCandidate?
    public static func candidates(_ gray: GrayImage) -> [GutterCandidate]
    public static func runsAlongText(_ gray: GrayImage, _ candidate: GutterCandidate) -> Bool
    public static func profile(_ gray: GrayImage, axis: GutterAxis) -> GutterProfile
    public static func smoothWidth(_ dpi: Double) -> Int
    public static func smoothed(_ values: [Double], box: Int) -> [Double]
    public static func findShadow(_ profile: GutterProfile, dpi: Double) -> GutterCandidate?
    public static func findMargin(_ profile: GutterProfile, dpi: Double) -> GutterCandidate?
    public static func atScale(_ candidate: GutterCandidate, width: Int, height: Int, scale: Double) -> GutterResult
    public static func manual(_ axis: GutterAxis, fraction: Double, width: Int, height: Int) -> GutterResult
    public static func halves(_ image: RgbaImage, gutter: GutterResult) -> (first: RgbaImage, second: RgbaImage)?   // C# throws instead of nil
    public static func halves(_ image: CGImage, gutter: GutterResult) -> (first: CGImage, second: CGImage)?
    public static func split(_ image: RgbaImage, gutter: GutterResult, rotationQuarterTurns: Int, rightToLeft: Bool) -> [RgbaImage]
    public static func firstPartLeads(_ axis: GutterAxis, quarterTurns: Int, rightToLeft: Bool) -> Bool
    public static func totalTurns(_ rotationQuarterTurns: Int, _ first: UprightTurn?, _ second: UprightTurn?) -> Int
    public static func normalizedTurns(_ quarterTurns: Int) -> Int
}
public struct BookPageLabel: Equatable, Sendable { public let label: String; public let help: String; public init(label: String, help: String) }
public enum BookPages {
    public static func scansOneSide(_ settings: ScanSettings) -> Bool          // DocumentSides.effective(settings, capabilities: nil) == .off
    public static let notSplitBadge: String                                     // "Not split"
    public static let notWithTwoSidedReason: String                             // "Not with two-sided"
    /// Every page's badge and its spoken form, in one pass; each page keeps the side recorded when its
    /// spread was cut (`SpreadPart.isLeft`), wherever it is moved and whatever the reading order is set to later.
    public static func labels(_ pages: [ScannedPage]) -> [BookPageLabel?]
    public static func label(_ pages: [ScannedPage], _ index: Int) -> String?   // "2 · left", "2 · not split"
    public static func help(_ pages: [ScannedPage], _ index: Int) -> String?    // "Spread 2, left page", "Spread 2, not split"
    public static func replacementPages(_ queued: [ScannedPage], fresh: [ScannedPage]) -> [ScannedPage]   // C# ReplacementPages(queued, fresh)
    public static func splitActionLabel(_ page: ScannedPage) -> String?         // "Split this spread…", "Change the split…"
    public static func joinActionLabel(_ page: ScannedPage) -> String?          // "Join the two pages"
    public static func scanNote(_ added: [ScannedPage]) -> String               // " 1 spread split into pages. The spine of 1 spread was not found: …"
    public static func splitNote(spreadNumber: Int, split: Bool) -> String      // "Spread 2 is split into two pages." / "… is one page again."
    public static let rotationChoices: [Int]                                    // [0, 1, 2, 3]
    public static func rotationLabel(_ quarterTurns: Int) -> String             // "As scanned", "90° clockwise", "180°", "90° counterclockwise"
    public static func hint(_ settings: ScanSettings) -> String                 // "Each book scan becomes two pages, cut at the spine."; two-sided: "Only for one side of each sheet: …"
}
// App/AppState+Book.swift: struct SpreadSource (the spread's spool file or pixels, dpi, color mode,
// date, size); public struct SpreadEditorSource: Identifiable (pageID, preview, axis, fraction, isSplit,
// spreadNumber); AppState: spreadSources (stored in AppState.swift), spoolSpreads(_:to:) (into the AppState's spoolDirectory), loadSpread(_:),
// pruneSpreads() (run by scannedPages' didSet), spreadNumber(_:), canEditSpread(id:),
// canEditSpread(of:) (the strip's per-cell check, no queue lookup), spreadEditor(for:) async, splitSpread(id:axis:fraction:), joinSpread(id:).
// CompleteScannerMac/UI/SpreadSplitView.swift (internal to CompleteScannerMac): struct SpreadSplitView
// (source, onDone: (SpreadSplitChoice) -> Void); enum SpreadSplitChoice { case split(axis:fraction:), keepWhole }.
```
Twin of `windows/CompleteScanner.Core/BookSplitter.cs` (`GutterAxis`, `GutterKind`, `GutterResult`, `SpreadPart`, `BookSplitOptions`, `GutterCandidate`, `BookSplitter` with `GutterProfile` nested, `BookPages`), `BookSplitOptions` / `ProcessSpread` / `SplitsFacingPages` / `ProcessedScan.Spreads` in `PageProcessor.cs`, `DocumentOptions.SplitFacingPages`, `TaskOptions.BookRightToLeft` / `BookRotationQuarterTurns`, `ScannedPage.Spread` / `SpreadId` / `WithSpread` in `Models.cs`; `BookSplitterTests` are the same cases on both sides, on the same synthetic spreads (`TestPages.spread`, `shadowSpread`, `marginSpread`, `blankFacingSpread`, `singlePageAcross`, `twoColumnPage`, `sectionGapPage`, `pageBesideEmptyGlass`, `foldedLetter`, `titleFacingText`, drawn in integers, checked by checksum), and the book cases of `PageProcessorTests`, `ModelsCompatTests`, `ScanTaskTests` and `MockScannerTests` match (the C# demo-book check is in `BookSplitterTests`, the Swift one in `MockScannerTests`, since the Swift renderer is private). The rules: the gutter is looked for on a gray copy at 100 dpi (at most 1000 px long), from two profiles along each axis over the middle 80 % of the other: the mean gray and the share of neighbouring pairs across the axis that differ by more than 24 levels (ink edges), both smoothed over 0.05 in; between 0.25 and 0.75 of the axis. A shadow is a darkest point with nothing darker within 6 % of the axis, at least 8 % darker than the paper beside it (the lower of the brightest points within that reach on each side, capped by the window's 90th percentile), at least 0.08 in wide where it darkens the paper by 4 % and at most 12 % of the axis wide at half its own depth, with at most half the text level (the 80th percentile of the ink profile) at its bottom and text within 1.5 in on at least one side; with text on both sides its centre (the middle of its bottom, within 10 % of its depth) is within 12 % of the axis of the middle of the spread's text, with text on one side only it is at least 15 % deep. Without a shadow, a margin is the longest run with less than a tenth of the text level, at least 0.6 in long, bright as paper, its middle in the window and within a quarter of its length of the middle of the spread's text, with text within 1.5 in on both sides. A candidate is dropped when the text runs along it (`DocumentGeometry.estimateTextLayout` with 0.3 in either side of it blanked to paper; the shadow is tried first, then the margin); of the two axes the higher confidence wins, the one cutting the longer side counting 1.25 times. The cut is the candidate's centre scaled back to the scan, kept a pixel from either end. `processSpread` cuts with `halves` (CGImage cropping on the Mac), turns each part by the book's rotation, runs the steps on each (so each page is checked, straightened and turned upright on its own), then orders the two by where the first part lies once turned by the book's rotation plus the turn reading their text agreed on (`totalTurns`): left before right (right before left reading right to left), top before bottom. Every page records its `SpreadPart` (the spread's id, its part, the cut, and `left`: the page that leads is the left one, or the right one reading right to left, so the strip's "2 · left" badge stays true when pages are moved or removed and when the reading order is changed for later spreads) and gets an id of its own; a spread with no clear gutter becomes one page with `part` nil. `PageProcessor.forScan` splits facing pages on document pages collected in the queue only, scanned one side of each sheet (`splitsFacingPages`, `BookPages.scansOneSide`: two-sided scans, by the feeder or by hand, keep their pages as scanned, and the inspector's switch is greyed out with `BookPages.hint` saying why; `TaskCatalog.summary` names the split only then); each page cut from a spread keeps the spread's `side` and `sheetIndex`; `TaskCatalog.apply` turns `splitFacingPages` (and `softenSpineShadow`, see Pipeline/SpineShadow.swift below) on for `.book` only. `AppState.performScan` spools the spreads that pages were cut from (`<spreadID>-spread.tiff`, Windows `-spread.png`; kept in memory when the file cannot be written) beside the pages, and the status adds `BookPages.scanNote` (`queueScanNote`); a spread is dropped with its last page (`pruneSpreads`, run whenever the queue changes; Windows from `SyncPageOptions`). `joinSpread(id:)` and `splitSpread(id:axis:fraction:)` (Windows `JoinSpread` / `SplitSpread`) run exclusively after the page edits queued before them, read the spread back, run `processSpread` with the current settings, color mode included (the spread is given `settings.colorMode`, so a page is what the adjustment step makes of it in that mode, or, in color with no adjustments, the spread as scanned labelled color) (nil cut, or `BookSplitter.manual`), spool the new pages and put them in place of the spread's pages in one change of the queue, as `BookPages.replacementPages` picks them (a split moved: each new page replaces the queued page of the same part, with its document break, document name and inclusion, and a part removed from the queue stays out; a join or a first split: every new page, the first with the first queued page's break and the first name among them, each with the inclusion they share, else automatic); the status gives `splitNote` plus the blank, crop and turn notes. The strip labels book pages with `BookPages.labels` (one pass over the queue per refresh; `BookPages.label` / `help` for one page), and their menu offers `splitActionLabel` (the split sheet, `SpreadSplitView`; Windows `SpreadSplitWindow`, with the arrow keys too) and `joinActionLabel`; the inspector's **Split facing pages** switch shows **Reads right to left**, **Turn the pages** and **Soften spine shadow** while it is on. The demo scanner's Book task glass holds a made-up open book (`MockScannerBackend.bookSpread`, C# `BookSpread`: two pages side by side, the spine at 0.52 of the width with a bell-curve shadow 25 % deep, σ 0.1 in; the page turns after every scan, not after a preview; `demoBookGutterFraction`).

### Pipeline/SpineShadow.swift (+ DocumentOptions, ScannedPage in Core/Models.swift, SpineShadowStep in Pipeline/PageProcessor.swift)

```swift
// DocumentOptions gains `softenSpineShadow: Bool` (false; "softenSpineShadow"); ScannedPage gains
// `spineShadow: SpineShadowResult?` (see the page clean-up stage above).
public enum PageEdge: Int, Sendable { case left, top, right, bottom }   // clockwise order
public struct SpineShadowResult: Equatable, Sendable {                  // ScannedPage.spineShadow; never saved
    public var edge: PageEdge; public var depth: Double                  // deepest darkening, 0...1
    public var widthInches: Double; public var maxGain: Double; public var protectedFraction: Double
    public init(edge: PageEdge, depth: Double, widthInches: Double, maxGain: Double, protectedFraction: Double)
}
public struct SpineShadowModel: Sendable {      // in analysis pixels; row v along the edge, column u away from it
    public let edge: PageEdge; public let extent: Int; public let length: Int; public let band: Int
    public let gains: [Double]                  // length × band, 1 or more
    public let pictures: [UInt8]                // length × band, 1 on a picture's box
    public let result: SpineShadowResult
}
public struct SpineShadowCorrection: Sendable { public let image: RgbaImage; public let result: SpineShadowResult }
public enum SpineShadow {
    // bandInches 1.5, maxBandFraction 0.5, minBandInches 0.25, referenceInches 0.4, blockInches 0.3,
    // minBlockRows 4, paperPercentile 0.9, minPaper 96, paperTolerance 0.1, fadeTolerance 0.05,
    // minShadowedShare 0.3, minShadowedBlocks 2, consensusTolerance 0.05, consensusSpread 0.4, minDepth 0.04,
    // maxDeepestInches 0.25, deadZone 0.02, minFadeInches 0.04,
    // maxGain 2.5, taperInches 0.2, pictureLevel 0.85, openInches 0.02, closeInches 0.05,
    // minPictureInches 0.3, featherInches 0.03
    public static func gutterEdge(_ spread: SpreadPart?, rotationQuarterTurns: Int) -> PageEdge?   // nil: not cut, or whole
    public static func turned(_ edge: PageEdge, quarterTurns: Int) -> PageEdge                     // clockwise
    public static func hint(_ on: Bool) -> String
    public static func soften(_ image: RgbaImage, dpi: Int, edge: PageEdge) -> SpineShadowCorrection?   // nil: nothing to soften
    public static func estimate(_ gray: GrayImage, edge: PageEdge) -> SpineShadowModel?
    public static func apply(_ image: RgbaImage, model: SpineShadowModel) -> RgbaImage
}
```
Twin of `windows/CompleteScanner.Core/SpineShadow.cs` (`PageEdge`, `SpineShadowResult`, `SpineShadowModel`, `SpineShadowCorrection`, `SpineShadow` with the same members in PascalCase), `SpineShadowStep` / `SoftensSpineShadow` and the `PageCorrections` texts in `PageProcessor.cs`, `DocumentOptions.SoftenSpineShadow` and `ScannedPage.SpineShadow` / `WithSpineShadow` in `Models.cs`; `SpineShadowTests` are the same cases on both sides, on the same synthetic book pages (`TestPages.bookPage`, `shadowedBookPage`, `unshadowedBookPage`, `pictureBookPage`, `unshadowedPictureBookPage`, `tintBookPage`, `shadowedBookSpread`, drawn in integers, checked by checksum), and expect the same softened bytes (checksums of the softened pages at 100 and 300 dpi); the spine-shadow cases of `PageProcessorTests`, `ModelsCompatTests` and `ScanTaskTests` match. The arithmetic is + − × ÷ on doubles in the same order on both sides, rounding by adding 0.5 and truncating, so both platforms give the same bytes. The rules: the edge along the spine is the edge of the cut (a left part's right edge, a right part's left edge, a top part's bottom edge, a bottom part's top edge), turned clockwise with the page by the book's rotation; a whole spread or a page not cut from one is left alone. On the page's gray copy at 100 dpi, the band along that edge is at most 1.5 in and half the page wide, and the paper's own brightness is read 0.4 in past it; rows along the edge are measured in blocks of 0.3 in, and in every block, at every distance from the edge, the paper's brightness is the 90th percentile of three columns (the paper between the text, not the ink). Each block's paper is the upper quartile past the band (the page's median when it differs by more than 10 %, then a running median of five); a page whose paper is darker than 96 is left alone. The blocks that show the spine's shadow are those whose share of the paper's light is at least 4 % lower within 0.25 in of the edge and back within 5 % over the last quarter of the band (a picture or a tint running across the band, and the lid beside a small book, do not); at least 30 % of the blocks, and two, must show it, and the shadow they agree on is their median at each distance, which must be at least 4 % deep, deepest within 0.25 in of the edge and faded (within 2 %) before the end of the band, and must fade gradually: from a quarter of the way back to the paper to within 2 % of it takes at least 0.04 in (a tint or a bar printed all along the spine comes back in a step, and is left alone). A cell darker than that shadow by more than 0.05 plus 0.4 of its depth is no paper, and makes every cell between it and the edge no paper too (a picture or a tint reaching the spine); those take the shadow of the nearest paper cells above and below (linearly), a lighter cell keeps its own (less shadow, the lid, a hole), and the shadow is smoothed across the blocks (1-2-1, twice) and along the distance (1-2-1). Each cell's gain is 0.98 divided by the light left, between 1 and 2.5, easing to none over the last 0.2 in of the band, interpolated between block centres; pixels darker than 0.85 of the shadowed paper there, opened by 0.02 in (text strokes gone) and closed by 0.05 in, in parts of at least 0.3 in square, are pictures: their boxes keep their pixels, the gain fading in over the 0.06 in beyond the box. `apply` multiplies red, green and blue by the gain (bilinear at the image's resolution, past the band none), rounding, at most 255; alpha, every pixel past the band and every pixel whose nearest analysis pixel is on a picture's box (rounding by adding 0.5 and truncating; on an image finer than the analysis copy, on the boxes grown by one analysis pixel, `MaskOps.dilate` radius 1, since a picture's edge can fall inside an analysis pixel lighter than the picture and left out of its box) are kept, so a picture keeps its pixels at any resolution, its edges on the analysis grid or not. `SpineShadowStep` runs after crop and straighten and before the separator check, on pages cut from a spread while facing pages are split (`softensSpineShadow`: `splitsFacingPages` and `softenSpineShadow`); a softened page keeps the page as scanned as its `alternate` (the one crop and straighten kept, or the page as cut), so the page strip's swap button (`PageCorrections`) shows it as scanned and back, the adjustments reach both, and `queueScanNote`, the join and split notes add " Spine shadow softened on 2 pages." through `PageCorrections.scanNote`. `TaskCatalog.apply` turns `softenSpineShadow` on for `.book` only; settings files without it read it as off. The inspector's **Soften spine shadow** switch (with `SpineShadow.hint`) shows under **Turn the pages** while facing pages are split (`InspectorView.bookRow`; Windows `SoftenSpineShadowBox` in `BookOptions`). Page curvature is not corrected.

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
    public var receiptNameByDate: Bool = true                 // "receiptNameByDate"; true also for files without it
    public var receiptCombine: Bool = false                   // "receiptCombine"
    public var bookRightToLeft: Bool = false                  // "bookRightToLeft" (see Pipeline/BookSplitter.swift)
    public var bookRotationQuarterTurns: Int = 0              // "bookRotationQuarterTurns"; read through BookSplitter.normalizedTurns
    public var cameraFrontsFirst: Bool = false                // I14 "cameraFrontsFirst": the iPhone's two-sided camera takes every front first
    public var cameraSpreads: Bool = false                    // I14 "cameraSpreads": the iPhone's camera takes a book as whole spreads
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
    public static let skipBackLabel: String     // "No back side"
    public static let privacyNote: String       // "Not kept in Scans history", the review's privacy line
    public static let privacyHelp: String       // its full sentence, for the help and screen readers
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
    public static func caption(paper: PaperSize, hasBack: Bool, scaledToFit: Bool) -> String   // "One A4 page, real size", "Front only, one Letter page, made smaller to fit"
}
public struct IdCardSide: Equatable, Sendable { image: RgbaImage; dpi: Int; var inches: CGSize }
public enum IdCardComposer {
    public static let maxPageDPI = 600
    public static func pageDPI(_ sideDPI: Int) -> Int          // the page is composed and saved at min(scan dpi, 600)
    /// The page's color mode from the modes the sides were scanned in (`DetectedPhoto.colorMode`):
    /// theirs when they agree, color when either is color, else grayscale.
    public static func pageColorMode(front: ColorMode, back: ColorMode?) -> ColorMode
    public static func canvasSize(paperInches: CGSize, dpi: Int) -> (width: Int, height: Int)   // round(paper × dpi)
    /// White page with each side copied into its place, resampled only when its place in pixels
    /// differs from its size. Saved at `dpi`, the page is the paper size: the sides print at real size.
    public static func compose(front: IdCardSide, back: IdCardSide?, dpi: Int, paperInches: CGSize) -> RgbaImage
    public static func sideFileBase(_ baseName: String, side: PageSide) -> String   // "ID card 2026-10-19 front"
}
```
Twin of `windows/CompleteScanner.Core/IdCard.cs` (`IdCardPaper`, `IdCardPapers.Resolve` / `ChoiceLabel` / `Label` / `RawValue`, `IdCardSteps.FrontStepId` / `Steps` / `SideOf` / `StepId` / `OffersSkip`, `IdCardScanArea`, `IdCardPickKind`, `IdCardPick`, `IdCardDetector`, `IdCardLayoutResult`, `IdCardLayout`, `IdCardSide`, `IdCardComposer`) and `TaskOptions` in `Models.cs`; `IdCardTests` are the same cases on both sides, on the same synthetic beds, and the task-options cases of `ModelsCompatTests`, the ID card cases of `ScanTaskTests` and `MockScannerTests` match. The task (`ScanTask.idCard`, flow `.idCard`, flatbed only, 300 dpi color PDF, not searchable, "ID card {date}") is guided by `IdCardSteps.steps`. `AppState.performScan` scans the whole glass for it (no paper-size area), finds the card on the scan the step is at (`IdCardDetector.detect`; a back that does not stand out takes the front's place, `frontPlaceOnBack`, only when both scans cover the same part of the glass: `idCardScanAreas`) and records it (`recordIdCardSide`): the front moves on to the back, a front scanned again goes past a back already scanned or skipped, and once the sides are in the review opens (`showIdCardReview`, `CompleteScannerMac/UI/IdCardReviewView.swift`; Scan at the review step opens it again). ID card scans are never spooled and never added to the scan history; their scans stay in memory (`idCardSourceImages`, read by `photoSource(for:)`) only while the sides do, so the crop editor works on them unchanged (`recropPhoto` routes a side to `recropIdCardSide`). `AppState+IdCard.swift`: `idCardFront`, `idCardBack`, `idCardFrontNote`, `idCardBackNote`, `idCardPreview` (the page at 40 dpi), `idCardLayoutCaption`, `idCardSizeWarning`, `isIdCardFlow`, `hasIdCardCaptures`, `idCardPaperSize` (`regionCode`: the user's region; `defaultPrinterPaper`: the default printer's), `idCardPaperChoiceLabel(_:)`, `rotateIdCardSide(_:)`, `swapIdCardSides()`, `retakeIdCardSide(_:)`, `setIdCardPaper(_:)`, `refreshIdCardPreview()`, `saveIdCard()` (the page as a PDF or in the chosen image format at `IdCardComposer.pageDPI`, at most 600 dpi, in the color mode the sides were scanned in, `IdCardComposer.pageColorMode`, not the one set when saving, and each side as an image at the scan's resolution when `idCardSaveSidesAsImages`; all or nothing) and `discardIdCard()`. Saving, discarding, leaving the task or picking a task again drops everything of the card from memory and clears the stage, also when no side was held (a scan whose card was not found, a cancelled one, a preview) (`clearIdCard(clearCanvas:)`). While a side is held: the app's own scanner switches wait (`autoSwitchMustWait` in `mergeDevices`/`endOfWork`; Windows `AutoSwitchMustWait`, also for `ChooseConnection`, `SelectAddedDevice` and the certificate fallback), the inspector's Mode and Source are disabled, and leaving the task, picking a task or applying a preset goes through `leaveIdCard(then:)`, which asks Discard / Cancel (`pendingIdCardLeave`, an alert in `ContentView`; `discardIdCard(andThen:)`; Windows `MainWindow.ConfirmDropIdCard`). None of these is possible while a scan runs (the banner's leave button is disabled then, and `exitTask()` and `leaveIdCard(then:)` refuse), and a scan of the card that still finishes outside the steps keeps nothing: `recordIdCardSide` drops it and clears the stage (`dropIdCardScanOutsideTask()`; Windows `CaptureIdCardSide`, `DropIdCardScanOutsideTask`), so a side is never held without the task. Skip is offered only for the card's back (`canSkipStep`). A side taken by a camera (I13: the iPhone's camera or a photo, cut out along the card's corners at ID-1's size, `CaptureObjects.isCutOut`) is the whole page, its source the photo as taken and its note the glare hint when there is glare on it (see "Pipeline/CaptureObjects.swift"); it is held in memory only like a scanned side, never spooled, never in the history, never written before Save, and Fix crop moves its four corners (`recropPhoto(id:corners:)`). Windows has the same members in `AppViewModel` (`IdCardFront` / `IdCardBack` as `PhotoItem`, `RecropIdCardSide`, `IdCardSource`, `SetIdCardSaveSidesAsImages`, `SaveIdCard`, `DiscardIdCard`, `SkipStep`, `IdCardPaperChoiceLabel`) and the review as an overlay in `MainWindow.xaml`. The review's Print prints the page (`printIdCard()`, see Copy and print below); Automatic paper is the default printer's paper when that is A4 or Letter (`PaperSizes.match` of what the print system reports), else the region's.

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
    public static let noPrinterReason: String     // "Needs a printer"
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
    func print(_ document: Data, job: PrintJob) async throws -> Bool               // Mac: print panel; iOS: AirPrint; false: cancelled
    func printAgain(_ document: Data, job: PrintJob) async throws -> Bool          // the printer picked last; default: print
}
public enum PrintDocument { static func makePDF(pages: [PrintPage], paper: CGSize) -> Data? }   // a page the size of the paper per page
package enum PrinterPapers { static func names(_ size: PaperSize) -> [String]; static func offers(_ size: PaperSize, pageSize: (String) -> CGSize) -> Bool }
// CompleteScannerMac/App/SystemPrintService.swift:
@MainActor public final class SystemPrintService: PrintService { public init() }   // the paper asked for only when the printer has it (`PrinterPapers.offers`)
// CompleteScannerIOS/IOSPrintService.swift (I16): AirPrint, behind #if os(iOS)
@MainActor public final class IOSPrintService: NSObject, PrintService, UIPrintInteractionControllerDelegate { public override init() }   // UIPrintPageRenderer at 100 %, copies drawn by us, last UIPrinter reused, paper chosen to match
```
Twins of `windows/CompleteScanner.Core/PrintLayout.cs` (`PrintMode`, `PrintAlign`, `PrinterPaper.Make` / `Size` / `LargestMargin` / `Description`, `PrintPlacement`, `PrintLayout.Place` / `ClippedInches` / `ToUnits` / `AlignFor` / `ClipWarning` / `Millimetres`, `PrintCopiesPlan`, `PrintCopies`, `PrintCalibration`, `PrintText.CopyPaperHint`) and `PaperSizes.Match`; `PrintLayoutTests` are the same cases on both sides, and the copy cases of `ScanTaskTests`, `ModelsCompatTests`, `PaperSizeTests` and `IdCardTests` match. The print system side has no twin: the Mac (`PrintService`, `PrintDocument`, checked by `PrintDocumentTests.swift`, which draws the PDF back into pixels) prints through `PDFDocument.printOperation(for:scalingMode: .pageScaleNone, autoRotate: false)` and the standard print panel, set to the printer, paper (`NSPrintInfo.paperSize`), copies and zero margins; Windows (`windows/CompleteScanner.App/Services/PrintService.cs`: `IPrintService`, `WindowsPrintService`, `PrintDocument`, checked by `windows/CompleteScanner.App.Tests/PrintDocumentTests.cs`, which writes the document to an XPS file and reads it back) sends the job with no dialog through System.Printing and the XPS print path: the queue's own ticket, portrait, 100 % scaling, the paper asked for when the printer lists it, and, whatever the printer's saved preferences say (`WindowsPrintService.ApplyJobSettings`), the copy count of `PrintCopies.plan` (collated; the pages repeated in the job when `MaxCopyCount` is too low or several pages would not be collated, `PrinterSetup.CanCollate`), one page per sheet, one-sided printing, grey output for a grey scan and colour for a colour one; one paper-sized page per page with the image at its placement in 1/96 in, drawn as the writer asks for it, as a plain bitmap (a JPEG-backed one would be stored once and printed on every page). The Copy task (`ScanTask.copy`, flow `.copy`, any source, 300 dpi color, PDF not searchable, "Copy {date} {counter}", step "Make a copy" with the button "Copy") reads the printer first (`setupForPrinting`: the chosen printer, else the default; nil throws `PrintError.noPrinter`); on the glass with nothing selected and Automatic paper it scans the part of the glass the printer's paper covers (`copyScanArea`); the pages are processed as any scan (no blank-page check, no crop; the inspector's blank-page, crop and straighten switches are off for the task and say "Copies print every page as scanned: …"), recorded in the history and never queued or spooled, then printed (`printCopyPages`): each placed at real size against the corner, centred for an area selected on the preview, or fitted to the page (`PrintLayout.copyFitsToPage`: when `copyFitToPage` is on, or when a page's real size is not known — `ScannedPage.printsAtRealSize` is false for a camera page that `CaptureScale` snapped to no known size, `PrintText.realSizeUnavailable`); `copyCount` copies; also saved as a PDF with `copyAlsoSavePdf` once printed, and also when printing failed (the pages are kept nowhere else; the print error then says what became of the PDF), a Cancel while it is written giving "Sent …. PDF not saved (cancelled)."; the status is `PrintText.sent` plus the first `clipWarning`. `AppState+Copy.swift`: `printerNames`, `defaultPrinterPaper`, `copySetup` (stored in AppState.swift), `hasPrinter`, `isCopyFlow`, `copyPrinterName`, `copyPaperText`, `copyMarginWarning`, `refreshPrinters()` (at start, each time the app becomes active, when the Copy task is picked and with Look Again; only reads), `setCopyPrinter(_:)` (the default printer stores nil), `setCopyCount(_:)`, `setCopyFitToPage(_:)`, `setCopyAlsoSavePdf(_:)`, `printIdCard()` (the page composed on the printer's paper at `IdCardComposer.pageDPI`, one copy; the review stays open; the warning when the margins reach a card) and `printRulerPage()` (300 dpi, actual size, from the corner). `AppState` takes an optional `printService:` (the Mac app passes `SystemPrintService()`; without one there is no printer: no printer names, no setup, and printing throws `PrintError.noPrinter`). Windows has the same members in `AppViewModel.Copy.cs` (`Printers`, `HasPrinter`, `IsCopyFlow`, `CopyPrinterName`, `CopyPaperText`, `CopyMarginWarning`, `RefreshPrintersAsync`, `PrintersMayHaveChanged` (the window back in front, the start screen shown; a print system that cannot be read leaves `HasPrinter` true), `SetCopyPrinter`, `SetCopyCount`, `SetCopyFitToPage`, `SetCopyAlsoSavePdf`, `PrintIdCard`, `PrintRulerPage`; the constructor's optional `printService`), the Copies section of the inspector and the review's Print button in `MainWindow.xaml` / `MainWindow.Copy.cs`. Printing errors are not scanner failures: the troubleshooter does not record them.

`PrintService.print` is `async` (I16): the Mac still runs its modal panel, iOS reports the outcome through a completion handler. On the iPhone and iPad `IOSPrintService` (`CompleteScannerIOS`, behind `#if os(iOS)`, injected by `AppState.makeForIOS`) prints over AirPrint: it draws the paper-sized PDF through a `UIPrintPageRenderer` at 100 %, repeats the pages itself for the copies (`showsNumberOfCopies = false`, UIKit's print info has no copy count), presents the system printer picker (`UIPrinterPickerController`) and keeps the picked `UIPrinter` so "Copy again" reuses it. iOS cannot list installed printers before the picker, so `printerNames` reports one logical AirPrint printer when `UIPrintInteractionController.isPrintingAvailable`, and `setup` lays pages out on the paper asked for (else the region's usual one) inside `assumedMarginInches` (0.25 in: the printer's own margins are known only once it is picked, so Fit to page stays clear of them and the margin warnings can show), named after the printer picked last (a stored printer name is not used: iOS cannot address a printer by name). The printer is chosen in the picker at print time and asked for the sheet closest to that paper (`printInteractionController(_:choosePaper:)`, `UIPrintPaper.bestPaper`; the delegate is cleared after the job), and the renderer pins the PDF's top edge to the sheet's, so a sheet of another size loses its bottom, never its top-left corner. The status names the printer the job went to (`printedOn`: the setup read again after printing, since the picker runs inside `print`). The phone reaches printing from the ID card review's Print button (`printIdCard`), the ruler test page in Settings (`printRulerPage`) and the Copy task. **Copy on the iPhone and iPad:** the phone has no inspector to set a copy up before it is taken, so with `platform` `.ios` and the flow `.copy` (`holdsCopy`) the pages brought in (our camera, Photos, Files or a network scanner, any `source`; `IOSShell.takesPhotos` is true for every flow; Use whole photo on a copy's photo is measured as a camera page, `IOSImportSession.capturedPage` with kind `.document`, so it prints at real size only when it snapped to a paper size; files opened in the app while the photocopy is set up go into Document to PDF instead, unless a copy is still held, which keeps its task and refuses the file as a held Quick scan does) are cleaned up as any copy's and then held in memory (`copyPages`, published) instead of printed: not queued, not spooled (a print that failed while the PDF got no password throws and leaves them held), not in the session history, and `canIngest` is false while they are held (so a PDF of several pages brings in its first page only). `printHeldCopy()` prints them through the picker (`setupForPrinting`, nil throws `PrintError.noPrinter`, then `printCopyPages`, centred when the pages were of an area selected on the preview, `copyAreaSelected`, kept by `holdCopy`); `printHeldCopyAgain()` prints them on the printer picked last (`printCopyPages(reusePrinter: true)`, through `PrintService.printAgain`, whose protocol-extension default calls `print`, so the Mac and the test stand-ins need nothing). The pages stay held after printing, for Copy again; the first print that was not cancelled puts them in the session history (`addToHistory`) and the task's steps (`recordCaptures`), once (`copyPagesRecorded`), inside `printCopyPages` before its PDF is written, so a PDF that cannot be written does not keep a printed copy out of them. `discardHeldCopy()` lets them go ("Copy discarded."), and so do picking a task (`startTask`) and settings that leave the copy flow (`settings`' didSet). The phone's Print… holds the queue's pages the same way whatever the task (`printQueueAsCopy()`, the pages Save would write, at full resolution; `copyIsOfQueue` keeps them through settings changes, and discarding them leaves the queue as it is). `copyNeedsFit` is true while a held page is not `printsAtRealSize`: the screen then shows Fit to page on and fixed, with `PrintText.realSizeUnavailable`. `printCopyPages` returns false when the print panel was cancelled (`@discardableResult`). The screen is `CopyScreen` (a full-screen `ScanCover.copy`, restored and closed with `copyPages` as Quick scan's is) over `IOSCopyModel` (texts in `IOSCopyText`): the first page large with "2 pages" when several, Copies (`setCopyCount`, 1 to `PrintCopies.maxCount`), Fit to page (`setCopyFitToPage`), Also save a PDF (`setCopyAlsoSavePdf`), "Prints on …" once a printer was picked (`IOSPrintService.lastPrinterName`) or "You choose the printer when printing", the status, Print, Copy again (once a printer was picked) and Discard (`copy.print`, `copy.again`, `copy.discard`, `copy.copies`, `copy.fit`, `copy.pdf`); it shows its own error alert and stays open after printing. Settings' Photocopy section only says where these choices are (`IOSCopyText.settingsNote`). Checked by `IOSCopyTests`. The shared real-size-or-fit decision (`PrintLayout.copyFitsToPage`, `ScannedPage.printsAtRealSize`, `PrintText.realSizeUnavailable`) has a C# twin (`PrintLayout.CopyFitsToPage`, `ScannedPage.PrintsAtRealSize`, `PrintText.RealSizeUnavailable`), checked by `PrintLayoutTests` on both platforms.

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
    /// Internal (also used by ReceiptDetector): the detector's merging of overlapping regions and its
    /// row-major order (C# `PhotoDetector.MergeOverlapping` / `SortRowMajor`, internal there).
    static func mergingOverlaps(_ regions: [DetectedPhotoRegion]) -> [DetectedPhotoRegion]
    static func sortedRowMajor(_ regions: [DetectedPhotoRegion]) -> [DetectedPhotoRegion]
}
```

### Pipeline/Quad.swift, Homography.swift, PerspectiveCorrector.swift, PhotoDocumentDetector.swift, CaptureStability.swift (photos of documents)

```swift
public struct Quad: Equatable, Sendable {                  // four corners in continuous image pixels, clockwise on screen
    public var topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint
    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint)
    public subscript(index: Int) -> CGPoint                // mod 4: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
    public var corners: [CGPoint]; public var signedArea: Double; public var area: Double
    public var isConvex: Bool; public var centroid: CGPoint
    public func edgeLength(_ index: Int) -> Double         // 0 top, 1 right, 2 bottom, 3 left
    public func scaled(_ sx: Double, _ sy: Double) -> Quad
    public func maxCornerDistance(_ other: Quad) -> Double
    public func meanCornerDistance(_ other: Quad) -> Double
    public func isInside(width: Double, height: Double, margin: Double = 0) -> Bool
    public func contains(_ point: CGPoint, tolerance: Double = 0) -> Bool
    public func intersectionArea(_ other: Quad) -> Double  // both convex and clockwise (Sutherland–Hodgman)
    public static func fromCorners(_ corners: [CGPoint]) -> Quad   // any 4-point cycle, either way round, named as below
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double     // internal
}
public struct Homography: Equatable, Sendable {             // row-major 3×3: (x, y) → ((m00·x + m01·y + m02) / w, (m10·x + m11·y + m12) / w),
    public init(_ m00: Double, _ m01: Double, _ m02: Double,  //   w = m20·x + m21·y + m22
                _ m10: Double, _ m11: Double, _ m12: Double, _ m20: Double, _ m21: Double, _ m22: Double)
    public static let identity: Homography
    public func map(_ p: CGPoint) -> CGPoint; public func weight(_ p: CGPoint) -> Double
    public var determinant: Double; public func inverse() -> Homography?          // nil when singular
    public static func multiply(_ a: Homography, _ b: Homography) -> Homography    // b first
    public static func squareToQuad(_ quad: Quad) -> Homography?                   // Heckbert's closed form
    public static func rectToQuad(width: Double, height: Double, quad: Quad) -> Homography?
    public static func quadToRect(_ quad: Quad, width: Double, height: Double) -> Homography?
    public static func fromCorrespondences(_ from: [CGPoint], _ to: [CGPoint]) -> Homography?   // 8×8 elimination, partial pivoting, m22 = 1
}
public struct AspectEstimate: Equatable, Sendable { public var widthOverHeight: Double; public var focalLength: Double?; public var longOverShort: Double }
public struct PaperMatch: Equatable, Sendable { public var size: PaperSize; public var longOverShort: Double }
public enum Supersampling: Sendable { case auto, off, on }
public struct PerspectiveOptions: Equatable, Sendable {
    public var outputWidth: Int?, outputHeight: Int?       // both or neither; else from the quad
    public var maxLongSide = 0                              // 0: no limit of the caller's own
    public var paperAspectTolerance = 0.03, snapToPaper = true, supersample: Supersampling = .auto
    public var fillR: UInt8 = 255, fillG: UInt8 = 255, fillB: UInt8 = 255
    public static let `default`: PerspectiveOptions
}
public struct PerspectivePlan: Equatable, Sendable {
    public var width: Int, height: Int; public var outputToSource: Homography; public var widthOverHeight: Double
    public var paper: PaperMatch?; public var dpi: Double?  // dpi: output long side / paper long side, when a paper matched
    public var supersampled: Bool
}
public struct PerspectiveCorrection: Sendable { public let image: RgbaImage; public let plan: PerspectivePlan }
public enum PerspectiveCorrector {
    // paperAspectTolerance 0.03, nominalDPI 200, minFocalDiagonals 0.3, maxFocalDiagonals 4, supersampleAbove 1.25,
    // maxPhotoDiagonals 2, maxOutputSide 23170, matchedSizes [.a4, .letter, .legal, .idCard] (A4 stands for every √2 size)
    public static func estimateAspect(_ quad: Quad, imageWidth: Double, imageHeight: Double) -> AspectEstimate
    public static func estimateAspect(_ quad: Quad, imageWidth: Double, imageHeight: Double,   // with a known focal length (pixels);
                                      focalLength: Double) -> AspectEstimate                    // not a positive number: the overload above
    public static func matchPaper(_ longOverShort: Double, tolerance: Double = paperAspectTolerance) -> PaperMatch?
    public static func plan(_ quad: Quad, imageWidth: Int, imageHeight: Int, options: PerspectiveOptions = .default) -> PerspectivePlan?
    public static func warp(_ image: RgbaImage, plan: PerspectivePlan, options: PerspectiveOptions = .default) -> RgbaImage
    public static func correct(_ image: RgbaImage, quad: Quad, options: PerspectiveOptions = .default) -> PerspectiveCorrection?
}
public enum PhotoDocumentRejection: Sendable { case none, nothingFound, cutOff, ambiguous, lowConfidence }
public struct PhotoDocumentOptions: Equatable, Sendable {
    public var analysisLongSide = 1000, minAreaShare = 0.05, acceptScore = 0.55, minSideScore = 0.35, paperAspectTolerance = 0.03
    public static let `default`: PhotoDocumentOptions
}
public struct PhotoDocumentDetection: Equatable, Sendable {
    public var quad: Quad?; public var confidence: Double; public var rejection: PhotoDocumentRejection
    public var candidate: Quad?                             // the best outline seen when none was taken (cut off, ambiguous, unclear)
    public var aspect: AspectEstimate?; public var paper: PaperMatch?
    public var found: Bool; public static let nothing: PhotoDocumentDetection
}
public enum PhotoDocumentDetector {
    public static func detect(_ image: RgbaImage, hint: Quad? = nil, options: PhotoDocumentOptions = .default) -> PhotoDocumentDetection
    // internal, for tests and tuning: explain(_:hint:options:) (the scored pool), otsu, fitLine, simplify,
    // largestQuad, cornerDistance, separated (C# also ScoreOf)
}
public enum CaptureState: Sendable { case noPage, moving, steadying, captured }
public enum CaptureQuality: Sendable { case good, blurry, dark }   // I9
public struct CaptureObservation: Equatable, Sendable {
    public var quad: Quad?; public var confidence: Double; public var timestampMs: Double; public var frameWidth: Int; public var frameHeight: Int
    public var sharpness: Double?; public var brightness: Double?   // I9: FrameQuality's readings; nil: not measured
    public init(quad:confidence:timestampMs:frameWidth:frameHeight:sharpness: = nil, brightness: = nil)
}
public struct CaptureDecision: Equatable, Sendable { public var state: CaptureState; public var shouldCapture: Bool; public var progress: Double
    public var quality: CaptureQuality = .good }               // I9: how the frame was judged
public struct CaptureStabilityOptions: Equatable, Sendable {   // each defaults to its CaptureStability constant
    public var steadyMs, enterMovement, stayMovement, enterConfidence, stayConfidence, maxGapMs, newPageMovement: Double
    public var minSharpness, minBrightness: Double             // I9
    public static let `default`: CaptureStabilityOptions
}
public struct CaptureStability: Sendable {
    // steadyMs 600, enterMovement 0.01, stayMovement 0.025 (shares of the frame's diagonal, largest corner movement),
    // enterConfidence 0.6, stayConfidence 0.45, maxGapMs 250, newPageMovement 0.15; I9: minSharpness 40, minBrightness 50
    public init(options: CaptureStabilityOptions = .default)
    public private(set) var state: CaptureState
    public mutating func update(_ frame: CaptureObservation) -> CaptureDecision
    public mutating func reset()
    public mutating func markCaptured()                         // I9: the page in view was taken by hand
    public mutating func resume(atMs timestampMs: Double)       // I9: frames again after a pause (C# Resume): the time since the
                                                                // last frame counts neither as missing nor as held still
    public static func judge(sharpness: Double?, brightness: Double?, options: CaptureStabilityOptions = .default) -> CaptureQuality
    public static func movement(_ a: Quad, _ b: Quad) -> Double   // largest corner distance, least over the 4 cyclic pairings
}
```
Twins of `windows/CompleteScanner.Core/Quad.cs` (`readonly record struct Quad(TopLeft, TopRight, BottomRight, BottomLeft)` of `PointD`, indexer, `Corners`, `SignedArea`, `Area`, `IsConvex`, `Centroid`, `EdgeLength`, `Scaled`, `MaxCornerDistance`, `MeanCornerDistance`, `IsInside`, `Contains`, `FromCorners`), `Homography.cs` (`record struct Homography(M00…M22)`), `PerspectiveCorrector.cs`, `PhotoDocumentDetector.cs` and `CaptureStability.cs` (a sealed class there), members in PascalCase. They import only Foundation and CoreGraphics (no AppKit, Vision or Accelerate), so they belong to the platform-neutral part of `CompleteScannerKit`. Coordinates (extending rule 4): quads are in continuous image pixels of the image passed in (top-left origin, y down; pixel (i, j) covers [i, i + 1) × [j, j + 1), its center is (i + 0.5, j + 0.5), as `RgbaImage.extractRotated` reads regions); the corners run clockwise on screen (positive shoelace sum with y down) and are named by where they are in the image, not by which way the text reads: the top edge is the edge whose midpoint has the smallest y (the smaller midpoint x on a tie), `topLeft` is its first corner (`Quad.fromCorners`); which way up the page reads is decided later by the orientation step. Near the turn where two edges' midpoints are equally high (a W × H sheet turned by atan(H / W): about 54.7° for portrait A4) a fraction of a degree renames every corner, so anything that compares quads across frames compares them from every starting corner (`CaptureStability.movement`, `PhotoDocumentDetector.cornerDistance`), never corner by corner. Vision's normalized corners (origin bottom-left) convert as x·W, (1 − y)·H, then `Quad.fromCorners`. The detector analyses a copy of at most `analysisLongSide` px (the toolkit's box filter) and answers in the photo's pixels; it finds straight edges with a Hough transform (a cos/sin table built from two literals, no libm trigonometry) and region outlines, scores each edge against the table's texture, the contrast across it, an edge running on past its corners and the edges' polarity, refines the best to sub-pixel accuracy, and answers `cutOff` (a corner more than 1 analysis px outside the frame, or an edge within 2 px of the frame's border along its length), `ambiguous` (two separate sheets of about the same size), `lowConfidence` (with `candidate`, when the best scores at least 0.25) or `nothingFound` rather than a wild outline; a page is taken at a score of at least `acceptScore` with every edge at least `minSideScore`; `hint` (the previous frame's quad) is refined as an outline of its own and favours outlines near it. The warp samples bilinearly at pixel centers (at H(o + 0.5) − 0.5), 2 × 2 at quarter offsets when the page is made smaller by more than 1.25 (`supersample` `.auto`), rounds halves to even, blends toward the fill color outside the photo, and gives the same bytes on both platforms; the output's long side is the longer edge of each opposite pair, cut to `maxLongSide`, `maxPhotoDiagonals` of the photo's diagonal and `maxOutputSide` (so W × H × 4 always fits one array), its shape the matched paper size (A4, Letter, Legal, ID-1 within 3 %), else the camera's view of the quad (Zhang and He, principal point at the photo's center), else the mean of the opposite edges' ratio; `plan` returns nil for a non-convex quad, a photo without pixels or a given size beyond `maxOutputSide`, and `warp` refuses a hand-made plan beyond it (C# `ArgumentException`, Swift `precondition`). `CaptureStability` (twin, though the iOS plan listed it as Swift only): it enters steadying when no corner moved more than `enterMovement` since the previous frame and the confidence is at least `enterConfidence`, stays while every corner is within `stayMovement` of the anchor and the confidence at least `stayConfidence`, bridges frames without a page that come within `maxGapMs` of the last sighting (the time missing never counts as holding still), starts over after a longer pause, fires once when steady for `steadyMs`, and stays captured until the page has gone (a frame without it more than `maxGapMs` after the last sighting), moved by `newPageMovement` from the captured quad, or `reset()`. **The shutter's quality check (I9):** a frame may carry `FrameQuality`'s readings (C# init properties `Sharpness` and `Brightness` on the positional `CaptureObservation`, and `Quality` on `CaptureDecision`); `judge` says `.dark` when the brightness is below `minBrightness` (50, mean luma 0...255), else `.blurry` when the sharpness is below `minSharpness` (40, the variance of the luma's 4-neighbour Laplacian on the live frame of at most 480 px), else (and for readings not measured) `.good`; every decision carries the frame's judgement, and a page held still for `steadyMs` is taken only from a `.good` frame: until one comes it stays `.steadying` with its progress at 1, so a camera still focusing or a dark room never fires the shutter, and the first sharp, lit frame while the page still holds still does. Frames without readings are decided exactly as before. `markCaptured()` (a photo taken by hand) makes the page last seen the captured one, so the same page is not taken again until it goes or moves `newPageMovement`; with no page seen it changes nothing. The thresholds are provisional, from synthetic frames (a sheet on a table: a sharp blank sheet reads about 690, the same blurred by a 5 × 5 box 13, the sheet with print 8481); they are to be tuned on real iPhones. Determinism: integer arithmetic for blur, Sobel and masks; doubles only with + − × ÷ and square roots in the same order on both sides; rounding `floor(x + 0.5)` or explicit half-even; every sort totally ordered. `HomographyTests`, `PhotoDocumentDetectorTests`, `PerspectiveCorrectorTests` and `CaptureStabilityTests` are the same cases on both sides, on the same synthetic photos (`PhotoScenes`, byte-identical, checked by FNV-1a checksum: e.g. `WoodScene` 0x5D456758, `CutOffScene` 0xB990DDDA); `PerspectiveCorrectorTests` pins the corrected bytes (`RoundTripScene` forced to 210 × 297, 2 × 2 sampled 0x9866E633, single-sampled 0xC4BDFAD2; `WoodScene` along its exact quad: 235 × 333, A4, 0x0A7E6D3A). Corner accuracy on the fixtures: every corner within 1 % of the diagonal. The detector's corners are not pinned across platforms yet (to be added once macOS CI compiles the Swift twin). Nothing here stores a setting.

### Pipeline/PerspectiveWarp.swift, CaptureScale.swift, MultiQuadPicker.swift (camera geometry, I6)

```swift
public enum PerspectiveWarp {
    public static let prefilterAbove = 2.0
    public static func prefilterFactor(_ quad: Quad, width: Int, height: Int) -> Int   // whole part of the shrink when above prefilterAbove, else 1
    public static func boxReduced(_ image: RgbaImage, factor: Int) -> RgbaImage        // ⌈W/k⌉ × ⌈H/k⌉ block means, (sum + n/2) / n
    public static func warp(_ image: RgbaImage, quad: Quad, width: Int, height: Int,
                            options: PerspectiveOptions = .default) -> RgbaImage?      // nil: not convex, size outside 1...maxOutputSide
}
public enum CaptureKind: String, CaseIterable, Sendable { case document, receipt, photo, idCard }        // first = default and fallback
public enum CaptureScaleBasis: String, CaseIterable, Sendable { case nominal, paper, receiptWidth, photoSize }
public struct CaptureSize: Equatable, Sendable {
    public var id: String; public var basis: CaptureScaleBasis; public var shortInches: Double
    public var longInches: Double?                          // nil: free length (receipts)
    public var paper: PaperSize?; public var longOverShort: Double?
    public init(id: String, basis: CaptureScaleBasis, shortInches: Double, longInches: Double?, paper: PaperSize? = nil)
}
public struct CaptureScaleResult: Equatable, Sendable {
    public var basis: CaptureScaleBasis; public var size: String?   // a CaptureSize.id; nil for .nominal
    public var dpi: Int; public var pixelWidth: Int; public var pixelHeight: Int; public var widthInches: Double; public var heightInches: Double
    public init(basis:size:dpi:pixelWidth:pixelHeight:widthInches:heightInches:)
    public var isRealSize: Bool                             // basis != .nominal
    public var paper: PaperSize?                            // CaptureScale.find(size)?.paper
}
public struct CaptureFacts: Equatable, Sendable {
    public var quad: Quad; public var sourceWidth: Int; public var sourceHeight: Int   // the page's corners in the photo as taken
    public var kind: CaptureKind; public var focalLength: Double?                      // pixels of that photo
    public var scale: CaptureScaleResult?                   // set by PerspectiveStep; nil until the page is cut out
    public init(quad: Quad, sourceWidth: Int, sourceHeight: Int, kind: CaptureKind = .document,
                focalLength: Double? = nil, scale: CaptureScaleResult? = nil)
    public func oriented(_ orientation: PhotoOrientation) -> CaptureFacts   // mirrored, then turned clockwise, as PhotoImport.oriented
    public func scaled(toWidth width: Int, height: Int) -> CaptureFacts      // corners scaled; focal length × √(sx · sy)
    public func describesPhoto(width: Int, height: Int) -> Bool              // the same shape, within a resize's rounding
}
public enum CaptureScale {
    // tolerance 0.03, nominalDPI 200, maxDPI 600, fullFrameDiagonalMm 43.266615305567875
    public static let papers: [CaptureSize]                 // PerspectiveCorrector.matchedSizes: a4, letter, legal, idCard
    public static let receiptWidths: [CaptureSize]          // receipt80mm, receipt57mm
    public static let photoSizes: [CaptureSize]             // photo4x6in, photo5x7in, photo3.5x5in, photo10x15cm (4 × 6 in's shape: never matched after it)
    public static var idCard: CaptureSize
    public static func candidates(_ kind: CaptureKind) -> [CaptureSize]   // document papers, receipt widths, photo sizes, [idCard]
    public static func find(_ id: String?) -> CaptureSize?
    public static func focalLengthPixels(_ focalLength35mm: Double, width: Int, height: Int) -> Double?
    public static func aspect(_ quad: Quad, imageWidth: Int, imageHeight: Int, focalLength: Double? = nil) -> AspectEstimate
    public static func match(_ longOverShort: Double, candidates: [CaptureSize], tolerance: Double = tolerance) -> CaptureSize?
    public static func measure(_ quad: Quad, imageWidth: Int, imageHeight: Int, kind: CaptureKind, focalLength: Double? = nil) -> CaptureScaleResult
    public static func measure(_ quad: Quad, imageWidth: Int, imageHeight: Int, candidates: [CaptureSize],
                               focalLength: Double? = nil) -> CaptureScaleResult
    public static func snap(widthOverHeight: Double, longSidePixels: Double, candidates: [CaptureSize]) -> CaptureScaleResult
    public static func fromAspect(pixelWidth: Int, pixelHeight: Int, kind: CaptureKind) -> CaptureScaleResult
}
public struct QuadCandidate: Equatable, Sendable { public var quad: Quad; public var confidence: Double; public init(quad:confidence:) }
public struct MultiQuadOptions: Equatable, Sendable {
    public var minLongOverShort = 1.0, maxLongOverShort = 2.0, minAreaFraction = 0.0, maxAreaFraction = 1.0
    public var maxOverlap = MultiQuadPicker.maxOverlap, maxCount = 1
    public init()
}
public enum MultiQuadPicker {
    // maxOverlap 0.3 (intersection over union), insideTolerance 2 px, minBackgroundCoverage 0.15, idCardLongOverShort 3.370 / 2.125, idCardShapeSlack 0.12
    public static func options(for kind: CaptureKind) -> MultiQuadOptions
    public static func pick(_ candidates: [QuadCandidate], imageWidth: Int, imageHeight: Int, kind: CaptureKind) -> [Quad]
    public static func pick(_ candidates: [QuadCandidate], imageWidth: Int, imageHeight: Int, options: MultiQuadOptions) -> [Quad]
    public static func overlap(_ a: Quad, _ b: Quad) -> Double
}
```

Twins of `windows/CompleteScanner.Core/PerspectiveWarp.cs`, `CaptureScale.cs` (`CaptureKind`, `CaptureScaleBasis`, `CaptureSize` and `CaptureScaleResult` records, `CaptureFacts` a record with `Kind`, `FocalLength` and `Scale` as init properties and `Oriented`, `ScaledTo`, `DescribesPhoto`, `CaptureScale.Papers` for `papers`, `MaxDpi` / `NominalDpi` for `maxDPI` / `nominalDPI`), `MultiQuadPicker.cs` (`QuadCandidate`, `MultiQuadOptions` with init properties, `MultiQuadPicker.OptionsFor` for `options(for:)`), `Quad.IntersectionArea`, the `PerspectiveCorrector.EstimateAspect` overload with a focal length, `PageGeometry.Quad` (an init property, so the positional record is unchanged), `ScannedPage.Capture` / `WithCapture` (every `With…` and `CopyMeta` copy it), `PerspectiveStep`, `PageProcessor.ForCapture` and `CompanionPage.Capture`, members in PascalCase. They import only Foundation and CoreGraphics, so they belong to the platform-neutral part of `CompleteScannerKit`; the camera itself (AVFoundation, VisionKit, the corner editor) is I7–I9's. The plan's `Quad` and `Homography` are D1's, reused; the reference warp is `PerspectiveCorrector`'s sampler behind an integer box prefilter, so photo imports and camera pages share one sampler and its pinned bytes stay as they were. **Warp:** when the longer of each pair of opposite edges against the output size (`max(w0 / width, h0 / height)`) is more than 2, the photo is averaged in k × k blocks from its top-left corner (k the whole part of that factor; ⌈W / k⌉ × ⌈H / k⌉ pixels, each block's in-image pixels summed per channel in integers and divided rounding half up, `(sum + n / 2) / n`) and the quad multiplied by `1.0 / k`; then `PerspectiveCorrector.plan` with the output size given and no paper snap, and `PerspectiveCorrector.warp` (bilinear at pixel centers, 2 × 2 at quarter offsets when the remaining shrink is more than 1.25, halves to even, the options' fill color outside). The same bytes on both platforms: `PerspectiveWarpTests` pins three fixture photos (`Fixture` / `WarpFixtures.photo`: R = (37x + 11y) mod 256, G = 40 + 3x mod 160 on the 4 px checker's even squares else 220 − 5y mod 120, B = (xy + 3x + 7y) mod 256, A = 255) by FNV-1a and three sample pixels each: 96 × 72 along (10.25, 6.5) (85.75, 12) (80.5, 66.25) (6, 60.75) to 40 × 30, 2 × 2 sampled, 0x4F042AE9; 240 × 180 along (20.5, 15.25) (220, 30.75) (205.25, 170.5) (12, 150) to 48 × 36, prefiltered by 4, 0x97396FCA; 32 × 24 along (−4, −3) (30, 1) (36, 26) (2, 22) to 50 × 40, enlarged with white outside, 0x8B045C82 (an independent model of the algorithm recomputes all three from this description). Round trip: a 300 × 400 page with four dots, photographed into 640 × 480 along a known quad and warped back, keeps every dot within 1 px both ways and a PSNR of at least 30 dB; a 2 px checkerboard made 4 times smaller averages to even gray (at least 30 dB, and 6 dB better than without the prefilter). **Real size:** the shape is `estimateAspect` (with `focalLength`, the known-focal construction, which also gives the shape of a sheet tilted about one of its own edges, where the quad alone tells no focal length; `focalLengthPixels` turns EXIF FocalLenIn35mmFilm into pixels: f35 × the photo's diagonal / 43.2666 mm); the long side the camera resolved is the longer of each pair of opposite edges, kept within 2 photo diagonals and 23170 px. `match` takes the fixed size whose long-over-short ratio is nearest within 3 % (the first on a tie), else the first free-length size (a receipt width fits any shape), else none; the lists are per kind, because shapes overlap across kinds (5 × 7 in is within 1 % of A4; A4, A5 and A6 share one shape, so a document page is taken as A4, as `PerspectiveCorrector.matchedSizes` does; 57 and 80 mm receipts differ only in scale, so 80 mm is taken unless a list names 57 mm; 10 × 15 cm has exactly 4 × 6 in's shape and is listed after it, so a 10 × 15 cm print is reported as 4 × 6 in). Snapped to a fixed size, `dpi = clamp(floor(longSide / longInches), 1, 600)` and the page is `floor(inches × dpi + 0.5)` pixels each way, so it is never larger than the photo shows it (a close-up is made smaller, at 600); a receipt the same along its short side, its length `width × longOverShort`; nothing matched, 200 dpi and the page keeps its pixels (`floor(longSide + 0.5)` by `floor(longSide / longOverShort + 0.5)`), its inches made up (`isRealSize` false: real-size printing must fit it to the paper and say why). `fromAspect` sizes a page that came upright with no corners (Apple's document scanner): matched the same way, `dpi = floor(px / inches + 0.5)` of the long side (the short side for a receipt), never capped since its pixels are kept. **Several objects:** `pick` names each candidate (`Quad.fromCorners`) and drops one that is not convex, outside the kind's area share or shape (receipts 1.25 to 8.33, at least 0.5 % and at most 90 % of the photo, up to 6; photos 1 to 2, 1 % to 95 %, up to 8; an ID card 1.586 ± 0.12, at least 2 %, one; a document page 1 to 2, at least 10 %, one); then the fitting outlines nest (one is inside another when every corner is within 2 px of it; each hangs under the smallest larger one holding it) and are folded from the smallest up: an outline holding no object or exactly one (a print and the picture on it, a receipt and its logo) is one object, itself, and what it holds is dropped; one holding two or more separate objects (counted surest first, one overlapping one already counted by more than 0.3 of their union being the same object) whose areas together are at least `minBackgroundCoverage` (0.15) of its own (an album page under prints, a sheet under receipts, which they cover a fifth to a third of) is the background and is dropped, its objects kept, while one whose objects cover less (windows in the picture on a print) or that holds one object seen twice is one object, itself; when the kind wants one object (`maxCount` 1) the outermost outline is always the object, as before; then surest first (larger, then earlier, on a tie), each kept unless it overlaps one already kept by more than 0.3 of their union, and returns them in reading order (`PhotoDetector`'s row grouping on their bounding boxes). **Pages:** `PerspectiveStep` (first in `PageProcessor.forCapture`, before the clean-up of I9's `EnhanceStep` and the blank check) measures and cuts out a page whose `capture.scale` is nil and that has no geometry, sets its dpi to the scale's and keeps the photo as its other version with `PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective, quad:)`, so the existing swap shows it "As photographed" and the captions and notes are the photo import's. **The facts follow the photo (I7):** a photo turned or resized before it is cut out has its facts turned or resized with it: `oriented` maps each corner as its pixel moves (mirrored left to right first, (x, y) → (W − x, y), then each clockwise quarter turn of a W × H photo (x, y) → (H − y, x)), names the corners again (`Quad.fromCorners`) and swaps the size with an odd turn, keeping the kind, focal length (a turn keeps the scale) and real size; `scaled(toWidth:height:)` scales the corners by (sx, sy) and the focal length by √(sx · sy) (the scale itself when the shape is kept), and returns the facts as they are for the same size, no photo size or no pixels; `describesPhoto` is true when |width · sourceHeight − height · sourceWidth| is at most the longer source side (a resize's rounding, floor or nearest), so a photo turned a quarter is not taken for its unturned facts unless it is within that of square. `PerspectiveStep` scales the facts to a photo in memory of another size (`describesPhoto`), records the facts in that photo's pixels (corners, size and focal length, with the scale), so the corners always match the photo kept as the other version (and the companion package's "corners in the pixels of the page's `original`"), and leaves a page whose photo is not the facts' shape (turned without them) as it is; pages from scanners and pages cut out already are left alone as before. Turns made after the cut (`OrientationStep`, the user's) are the page's `upright` and rotation, as for any page: the facts stay in the photo's pixels before them; `GeometryStep` leaves pages with `capture` or a `.perspective` geometry alone. `PhotoImport.correctedPage` records its corners as the geometry's `quad` too. There is no exhaustive `switch` over `GeometryBasis` on either platform (every use compares with `==`), and `CapturePageTests.EveryGeometryBasisHasItsWords` goes through every case. **Stored:** `capture` is in memory like the other page facts, and travels in companion packages: format minor version 1 adds an optional `"capture"` object to a page, after `ocrLines` and before `original`: `{"quad":[x0,y0,x1,y1,x2,y2,x3,y3],"sourceWidth","sourceHeight","kind"[,"focalLength"][,"scale":{"basis"[,"size"],"dpi","pixelWidth","pixelHeight","widthInches","heightInches"}]}` (numbers as the manifest writes them; the corners in the pixels of the page's `original` as stored); read under rule 6: unknown keys ignored, an unknown kind reads as `.document` and an unknown basis as `.nominal`, a scale without a positive dpi, pixel size or inches is left out, and a record without eight finite corner numbers and a positive photo size is left out whole, so the page still reads; a package without it (minor version 0) reads with no capture. The golden package (`CompanionFixtures`) carries one and is pinned on both sides; the Windows app keeps a phone page's capture when it queues the page (`CompanionPages`). Tests: `PerspectiveWarpTests`, `CaptureScaleTests` (a card turned 25° and tilted 35° snaps to ID-1 within 0.5 mm, a card tilted 35° about its own edge needs the focal length, A4 either way round, nothing upsampled, the 600 dpi cap, nominal 200 dpi, receipt widths, photo sizes, `fromAspect`), `MultiQuadPickerTests`, `CapturePageTests` (the facts turned and mirrored with their photo for all eight orientation tags, landing on the same marked pixels, and resized with it; a photo turned with its facts cut out as the same page turned, and one turned without them left alone; the facts of a page cut from a photo at half size in that photo's pixels) and the capture cases of `CompanionPackageTests` are the same cases on both sides; `CompanionAppTests` (Windows) checks the queued page. QuadFinder, a page finder without Vision, is deferred to I17.

### Pipeline/FrameQuality.swift, DocumentEnhancer.swift (+ BackgroundMap.raisedDarkTiles, EnhanceStep in Pipeline/PageProcessor.swift, CaptureFacts.enhancement) (I9)

```swift
public struct FrameQualityReading: Equatable, Sendable { public var sharpness: Double; public var brightness: Double; public init(sharpness:brightness:) }
public struct FrameQualityArea: Equatable, Sendable { public var x0, y0, x1, y1: Int; public init(x0:y0:x1:y1:) }   // C#: a tuple (X0, Y0, X1, Y1)
public enum FrameQuality {
    public static let margin: Int                                   // 2
    public static func measure(_ frame: RgbaImage, region: Quad? = nil) -> FrameQualityReading
    public static func measure(_ gray: GrayImage, region: Quad? = nil) -> FrameQualityReading
    public static func area(_ region: Quad?, width: Int, height: Int) -> FrameQualityArea
}
public enum DocumentEnhanceMode: String, CaseIterable, Sendable { case auto, color, gray, blackAndWhite, photo }   // not stored
public struct DocumentEnhancement: Sendable { public let image: RgbaImage; public let mode: DocumentEnhanceMode }  // mode: .auto resolved
public struct PaperWhiteBalance: Equatable, Sendable { public var r, g, b: Double; public static let neutral: PaperWhiteBalance }
public enum DocumentEnhancer {
    // tilesAlongLongSide 16, minTileSize 8, backgroundPercentile 0.9, darkTileShare 0.7, minBackgroundShare 0.4, minBackground 32,
    // paperShare 0.9, minGain 0.625, maxGain 1.6, whitePoint 0.9, blackPercentile 0.005, maxBlackPoint 0.5, levels 1024,
    // sampleStep 2, photoClip 0.005, minPhotoRange 64, groundPercentile 0.5, lightContrast 1.5, minLightShare 0.005
    public static func mode(for settings: ScanSettings) -> DocumentEnhanceMode          // C# ModeFor(settings)
    public static func mode(_ mode: DocumentEnhanceMode, kind: CaptureKind) -> DocumentEnhanceMode   // C# ModeFor(mode, kind)
    public static func tileSize(width: Int, height: Int) -> Int
    public static func paperMap(_ gray: GrayImage) -> BackgroundMap?                     // C#: never null
    public static func isLightOnDark(_ gray: GrayImage) -> Bool                          // light print on a dark ground
    public static func whiteBalance(_ image: RgbaImage, gray: GrayImage, paper: BackgroundMap) -> PaperWhiteBalance
    public static func blackPoint(_ gray: GrayImage, paper: BackgroundMap) -> Double
    public static func enhance(_ image: RgbaImage, mode: DocumentEnhanceMode) -> DocumentEnhancement
    public static func photo(_ image: RgbaImage) -> RgbaImage
    public static func level(_ value: Double, _ background: Double) -> Int
    public static func stretch(_ lo: Double, _ hi: Double) -> [UInt8]
}
extension BackgroundMap {
    public func raisedDarkTiles(share: Double) -> BackgroundMap
    public func minSmoothed() -> BackgroundMap        // darkest of each tile and its 8 neighbors
}
public struct EnhanceStep: PageStep { public let mode: DocumentEnhanceMode; public init(mode:) }    // name "enhance"
extension CaptureFacts { public var enhancement: DocumentEnhanceMode? }                // in memory only
```
Twins of `windows/CompleteScanner.Core/FrameQuality.cs` (`FrameQualityReading` a record struct, `FrameQuality.Measure`, `Area`), `DocumentEnhancer.cs` (`DocumentEnhanceMode`, `DocumentEnhancement` a record, `PaperWhiteBalance` a record struct with `Neutral`, `DocumentEnhancer` with the same members in PascalCase, `ModeFor` for `mode`), `BackgroundMap.RaisedDarkTiles` and `MinSmoothed`, `EnhanceStep` in `PageProcessor.cs` and `CaptureFacts.Enhancement` (an init property), members in PascalCase. They import only Foundation and CoreGraphics. **Frame quality** (the automatic shutter's readings, measured by `LiveQuadTracker` on each live frame it searches, at most 480 px): the area is the page's bounding box (`floor` of the least corner coordinates, `ceil` of the greatest) widened by `margin` and kept within the frame, so the page's own edges are in it and a blank page is still sharp by its edges; the whole frame without a page, or with one that leaves nothing of the frame or has a corner that is not a number. Brightness is the mean luma (`ColorAnalysis.grayPixels`) over the area; sharpness the variance of 4·p − (up + down + left + right) over the area's pixels with all four neighbours in the frame, from integer sums divided once (sum of squares over n minus the mean squared, never below 0), so both are the same bits on both platforms. `CaptureStability.judge` turns them into `CaptureQuality` (see above). **The clean-up** (`DocumentEnhancer.enhance`, on a page cut out of its photo): the luma's paper map is `BackgroundMap.estimate` in tiles of `max(8, long side / 16)` px at the 0.9 percentile; then `raisedDarkTiles(share: 0.7)`: pass after pass (each reading the one before, at most as many as the map's tiles across or down, stopping when nothing changes), a tile darker than 0.7 of the brightest of its eight neighbours takes that neighbour's value, so a soft shadow (darker from tile to tile by less than that) stays and is evened out, while a picture or black bar larger than a tile is filled with the paper around it and keeps its own tones; then each filled region (the tiles that changed, joined through their eight neighbours, found from its first tile in row-major order) that reaches an outer tile of the map takes its own values back: it is a shadow cast across the sheet from beyond its edge, however hard its edge, and is evened out like a soft one (within a tile of a hard shadow's edge the paper map steps between tile centres, so the paper there is not fully white, and in black and white a few pixels next to the edge of a shadow darker than about half the light may turn black); a dark picture that touches the page's edge is evened out the same way, which is the price of that rule; then every tile at least `max(32, floor(median tile × 0.4))`; then bilinear between tile centres (`valueAt`). Each pixel's level is `floor(min(1, value / paper) × 1024 + 0.5)`; the black point is the 0.005 percentile of the levels of every second pixel of every second row (the smallest level with at least ⌈0.005 × n⌉ at or below it), at most 0.5; the stretch maps level k to `floor(clamp((k / 1024 − black) / (0.9 − black), 0, 1) × 255 + 0.5)`. Gray: R = G = B = the stretched luma level. Black and white: that gray, 0 below `Bilevel.threshold` (128), else 255, so CCITT G4 keeps every pixel and print in a shadow stays black (the threshold follows the paper). Color: the paper's white balance over the sampled pixels whose luma is at least 0.9 of the paper there (each channel's gain the luma sum over the channel sum, within 0.625...1.6; neutral when no paper is seen), then each channel's level is `channel × gain / paper`, stretched with the luma's black point. Auto: color, then the gray result (the same bytes as `.gray`) when the color result is effectively gray (`ColorAnalysis.isEffectivelyGray`), reported as `.gray`, else `.color`. **Light on dark** (`isLightOnDark`, checked first, before any paper map): a chalkboard, a dark flyer with white text or a slide has no paper to divide by (every tile's 0.9 percentile is the dark ground, so dividing would make the ground and the print both white). The ground is `BackgroundMap.estimate` at the 0.5 percentile in the same tiles; over every second pixel of every second row, a luma at least 1.5 × the brightest ground of its tile and the eight around it (`maxSmoothed`, bilinear, at least 32 (`minBackground`)) is light print, one with luma × 1.5 at most the darkest of them (`minSmoothed`, bilinear, at least 32) dark print, so the paper beside a hard step (the edge of a shadow cast across the sheet, a big dark picture), which is the ground of the tile next to it, is neither, wherever in its tile the edge falls; light on dark when the light print outnumbers the dark and is at least 0.005 of the samples. Such a page is stretched as a whole as a photo is (below); color keeps that, auto keeps it when it is not effectively gray (`.color`), else its luma (R = G = B, alpha 255) as `.gray`; gray is that luma, black and white that luma thresholded at 128. Photo: no evening out: the 0.005 and 0.995 percentiles of the luma become 0 and 255 (`floor((v − lo) × 255 / (hi − lo) + 0.5)` within 0...255, the same for each channel, alpha kept), a photo whose two are less than 64 apart left as it is. Every page made is opaque (alpha 255) except a photo's, which keeps its alpha. **Which mode** (`mode(for:)`): photo tasks (`intent == .photo`) `.photo`; else by the color mode: grayscale `.gray`, black and white `.blackAndWhite`, color `.auto` (a color page stays color, a page without color comes out gray and is stored smaller); a shot of a photo print or an ID card (`CaptureKind.photo`, `.idCard`) is always `.photo` (`mode(_:kind:)`). **Where:** `EnhanceStep` runs second in `PageProcessor.forCapture` (perspective, enhance, then `forPhotoImport`'s steps for pages of the queue; since I13 the objects of the other tasks get only their adjustments after it, see "Pipeline/CaptureObjects.swift"), on a page `PerspectiveStep` cut out (capture facts with a scale, `GeometryBasis.perspective`) and not cleaned up yet (`capture.enhancement` nil): the page's pixels are replaced (the photo kept as the other version is not touched, so "As photographed" still shows the photo), the mode applied is recorded on its capture facts, and a gray or black and white result sets the page's color mode, which the adjustments of a color task keep (`AdjustmentStep.mode(for:)`, while the photo kept as the other version is adjusted in color); Apple's scanner's pages (cut out whole and cleaned by it, no geometry), pages from scanners and pages cleaned up already are left alone. `enhancement` is kept in memory like the other page facts (every rebuild of the page keeps it, as it keeps `capture`), and not written to companion packages. **Tests, the same cases on both sides:** `DocumentEnhancerTests` on `EnhancerPages` (240 × 320 warm paper (232, 226, 212) with lines of print (40, 38, 44) and a red stamp (196, 48, 44), optionally a 100 × 90 dark picture (70, 74, 80), under the light `255 − 130·x/239 − 30·y/319` out of 255, each channel `(c × light + 127) / 255`; FNV-1a 0x4329E79A, without the stamp 0x8F960753, with the picture 0x2C86F2C0): the shadowed paper (luma 84 to 226) comes out at 250 or more everywhere and the print at 10 or less (the contrast kept, in the shadow too); color takes the paper's tint out (every paper pixel at least 250 per channel, red and blue within 3) and keeps the stamp red; auto is the color result with the stamp and the gray result without it; black and white is 0 or 255 with all paper white and all print black, and survives `Bilevel` packing; the dark picture stays dark (mean at most 70) while the paper around it is white, its tiles filled from the paper; photo keeps the shadow and stretches the ends; and the golden bytes (auto and color 0x70604295, gray 0xEC4526A3, black and white 0x43422875, photo 0xBCA2862C, auto without the stamp 0xF81468D6, gray with the picture 0x13CF7A4C), which an independent model of this description recomputes; `raisedDarkTiles` on hand-made maps; the modes; `EnhanceStep` once only, on cut pages only. `FrameQualityTests` on `QualityFrames` (320 × 240: a table (88, 80, 72), a sheet (205, 200, 192) from (80, 40) to (240, 200), print (95, 92, 100) in 2 px lines every 4 px with words of 7 px every 10, a box blur and a dimming as asked; FNV-1a 0x44CA3AC5, blank 0x4DC7DDC5, blank blurred by 2 0x1EB25E85, blurred 0xCA5C90C9, dimmed to 40 0xCCACDE45): the readings over the sheet to 1e-9 (sharp print 8481.175490779298 and 172.04818560380727; whole frame 3013.975159875271 and 112.88583333333334; blank 689.5895300416419 and 195.2177275431291; blank blurred 13.418652532892908; dimmed 189.7358715050565 and 26.668054729327782), a known Laplacian (one bright pixel: 200000 / 9), the area's rules, and a scripted sequence through `CaptureStability` (blurred, then dark, then sharp frames of the sheet held still: taken once, at the first sharp lit frame; moved 70 px, taken again). `DocumentEnhancerTests` also has a hard shadow (`EnhancerPages.hardShadow`: the warm paper and print at full light left of x = 130, mid-tile, and at 115/255 from there to the right edge; FNV-1a 0xA8CB3FCD): the paper map follows the shadow (not filled), the paper at 250 or more on both sides except within a tile right of the edge, the print at 30 or less, black and white keeps all print black and that paper white (gray and auto 0x2E7FEF38, black and white 0x1EDFC6F4, color 0x2C520A1D); and light print on a dark ground (`EnhancerPages.darkGround`: luma 55 with 1 px lines of 235 every 12 px; FNV-1a 0xE4CFC2D5): light on dark, and in gray, black and white, auto (gray) and color the ground at 5 or less and the print at 250 or more (0x6EDC8C95 for all four), while the other fixtures and a blank dark sheet are not light on dark, nor a short note or a blank sheet under the hard shadow (`hardShadow(print:edge:)` with `.fewLines`: five 2 px lines from y = 70 to 130, or `.blank`; the edge at x = 109, 127, 130 and 148), nor a big dark picture with a caption (`EnhancerPages.pictureWithCaption`: (70, 74, 80) from (30, 50) to (210, 230), two 2 px caption lines of print from y = 262, in full light; FNV-1a 0x78DD9B25); the short note and the blank sheet under the hard shadow (FNV-1a 0x4B4A6495 and 0x2EC994C5; edge at 109 0x263A9905, blank edge at 148 0xA99E33C5) come out with the paper at 250 or more and white in black and white on both sides except within a tile right of the edge and the print at 30 or less and black (the note gray and auto 0x7181A6C5, black and white 0xF84323D5; the blank sheet black and white 0x55EE99C5), and the picture page with its paper at 250 or more, its caption at 30 or less and its picture's mean at most 70 (gray 0x895657F5, black and white 0x4ACCE6B5); `raisedDarkTiles` keeps a dark region that reaches the map's edge. `CapturePageTests` adds a color task with brightness +0.1 through `forCapture`: the page without color stays `.grayscale` after the adjustments, its photo stays in color, the page with the stamp stays `.color`, and `AdjustmentStep.mode(for:)`. `CaptureStabilityTests` adds the waits for a sharp frame and for light, `judge`, `markCaptured` and `resume(atMs:)` (a page taken before a pause stays taken through a first frame without it, without `resume` it is taken twice, a page gone meanwhile is gone after `maxGapMs`, a page holding still goes on from where it was).

### Pipeline/CaptureObjects.swift, GlareDetector.swift, App/AppState+Capture.swift (several objects in one shot, I13)

```swift
public enum CaptureObjects {
    public static let fallbackDPI: Int                                    // CaptureScale.nominalDPI, 200
    public static func kind(for settings: ScanSettings) -> CaptureKind    // C# KindFor: .photoSplit .photo, .receiptSplit .receipt,
                                                                          // .idCard .idCard, else .document
    public static func findsSeveral(_ kind: CaptureKind) -> Bool          // MultiQuadPicker.options(for:).maxCount > 1
    public static func isCutOut(_ page: ScannedPage) -> Bool              // capture.scale set and geometry .perspective
    public static func region(around quad: Quad) -> DetectedPhotoRegion   // C# RegionAround: the bounding box, angle 0
    public static func pages(_ photo: CGImage, quads: [Quad], kind: CaptureKind, focalLength: Double? = nil,
                             createdAt: Date = Date()) -> [ScannedPage]   // C# Pages(RgbaImage, …)
    public static func fallbackPage(_ photo: CGImage, createdAt: Date = Date()) -> ScannedPage   // C# FallbackPage
}
public enum PhotoReview {
    public static func title(_ found: Int) -> String          // "Found 3 photos", "Found 1 photo"
    public static func saveTitle(_ included: Int) -> String   // "Save 3 photos", "Save 1 photo"
}
public struct GlareReading: Equatable, Sendable {
    public var clippedShare: Double; public var largestBlobShare: Double
    public var hasGlare: Bool                                 // largestBlobShare >= GlareDetector.minBlobShare
    public static let none: GlareReading
}
public enum GlareDetector {
    // clipLevel 250, minBlobShare 0.01, insetShare 0.04, analysisLongSide 400; hint "Tilt to avoid glare"
    public static func measure(_ image: RgbaImage, region: Quad? = nil) -> GlareReading
    public static func hasGlare(_ image: RgbaImage, region: Quad? = nil) -> Bool
}
// App/AppState+Capture.swift (Swift only):
public struct PhotoCropStart { public let source: CGImage; public let corners: Quad; public let kind: CaptureKind }
extension AppState {
    public func cropStart(for photo: DetectedPhoto) -> PhotoCropStart?     // nil once the review is closed
    public func recropPhoto(id: UUID, corners: Quad)                       // Fix crop along four corners (photos, receipts, ID card sides)
    // internal: reviewSources(_:) -> ReviewSources, cutOutPhoto(_:), recordCapturedIdCardSide(_:page:flag:generation:),
    // cutAlong(_:corners:kind:focalLength:settings:) -> CapturedCut; photoCaptureFacts, idCardCaptureFacts (AppState.swift)
}
```
Twins of `windows/CompleteScanner.Core/CaptureObjects.cs` (`CaptureObjects` with `FallbackDpi`, `KindFor`, `FindsSeveral`, `IsCutOut`, `RegionAround`, `Pages`, `FallbackPage`, `CardNotRealSizeNote`, `CardNote`; `PhotoReview.Title` / `SaveTitle`, which `AppViewModel.Receipts.cs` uses for the Windows review's title and button) and `GlareDetector.cs` (`GlareReading` a record struct with `HasGlare` and `None`, `GlareDetector` with the same constants, `Hint`, `Measure`, `HasGlare`), members in PascalCase; they import only Foundation and CoreGraphics. **The objects of one shot as pages:** the task says what a shot holds (`kind(for:)`); each object is a page of its own: the photo as taken (all of a shot's pages share its pixels), at `CaptureScale.nominalDPI` in color, from a photo (`PageSource.photo`), with the object's corners (named again, `Quad.fromCorners`), the photo's size, the kind and the camera's focal length as its capture facts, so the clean-up stage cuts each out along its corners at the real size `CaptureScale.measure` gives its kind (`PerspectiveStep`: a print's size, a receipt roll's width, ID-1; else 200 dpi) and cleans it up for its kind (`EnhanceStep`: `DocumentEnhancer.mode(_:kind:)` makes photos and ID cards `.photo`, never evened out); a page cut out this way is `isCutOut`. A shot in which no object was found comes in whole (`fallbackPage`): the photo at `fallbackDPI` (a phone held over a table takes in about 20 in across, about 200 px an inch of a 4000 px photo), with no capture facts, so nothing cuts it and the task's flatbed search looks at it (`ReceiptDetector`'s print-based search finds thermal paper on a white table; `PhotoDetector` finds prints on a plain table). **`PageProcessor.forCapture`** runs `forPhotoImport`'s steps (blank pages, separator sheets, barcodes, turning pages upright with text recognition) only for the document queue (`TaskCatalog.flow(of:) == .documentQueue`); for photos, receipts and the ID card only `AdjustmentStep` follows the clean-up, unless the adjustments change nothing (identity and color), so their pages are never checked for blankness and an ID card is never read by text recognition; that step leaves their other version alone (`AdjustmentStep(adjustments:colorMode:adjustsAlternate: false)`, C# `AdjustsAlternate`, true by default and for every other use), so the objects of a shot share the one photo as taken, which Fix crop starts from and the glare check reads. **The card's note** (`cardNote(realSize:glare:)`): a side whose shape matched no ID-1 card (`CaptureScaleResult.isRealSize` false, its size made up) gets `cardNotRealSizeNote` ("This does not look like the shape of an ID card, so it is not at real size. Fix the crop, or take it again."), then, after a space, `GlareDetector.hint` when the photo shows glare; nil for neither. **Glare** (`GlareDetector.measure`, on the photo as taken, before any clean-up stretches its whites): the area is `region` (or the whole picture), convex, its bounding box (`floor` of the least corner coordinates, `ceil` of the greatest, within the picture) cut into cells of k × k pixels, k = ⌈long side / 400⌉; a cell counts when its center ((x0 + x1) / 2, (y0 + y1) / 2) lies in the outline at least `insetShare` × the shorter of its mean opposite edges inside it (`Quad.contains` with that tolerance negated), and is clipped when the mean of each of its channels, `(sum + n / 2) / n`, is at least 250; clipped cells side by side (four neighbours) are a patch, found in row-major order; the reading is clipped / counted and the largest patch / counted; glare from a patch of 1 % (`minBlobShare`). A region that is not convex, outside the picture or without a counted cell reads `none`. **Tests, the same cases on both sides:** `GlareDetectorTests` on `GlareCards` (428 × 270: ground (214, 220, 226), a photo box (150, 130, 120), six 8 px lines of print (40, 44, 52); glare a white ellipse at (300, 120), radii 70 × 40, its halo at half light; specks 2 × 2 white every 30 px on rows 20 and 240; a white 6 px strip along the left edge; FNV-1a 0x0CE717C5, glare 0x17657405, specks 0x6BF09B45, edge 0xD428B625, a light card (236, 238, 240) 0xC0761E05, all three 0xF39EE005): no glare on the plain or light card; glare 0.08509803921568627 of the card; specks 0.0010980392156862745 clipped with a largest patch of 3.9215686274509805e-05 (no glare); the edge left out; the left half nothing, the right half 0.1780855199222546, a tilted outline 0.2681216850576114, a crossed outline and one outside nothing (to 1e-12, recomputed by an independent model); a 3 × larger photo in cells of 4 px, the same glare. `CaptureObjectsTests` on `ObjectShots` (two 6 × 4 in prints on a dark table, 900 × 600; an ID-1 card turned 25° and tilted 35° at 180 mm in a 1200 × 900 photo of focal length 1000 px; two bordered prints on a plain table, 1200 × 900, FNV-1a 0xE0C900E1, the photos UI test's fixture): the kinds; the pages (shared pixels, named corners, kind, focal length, nothing measured yet); the fallback page left as it is; the bounding box; the card's notes; the `forCapture` steps (the document task with text recognition available: perspective, enhance, blank, separator, orientation; Photos and ID card perspective and enhance; Restore old photos and Receipts with adjust); receipts of a shot made gray while their other version stays the shot itself, and a gray document task adjusting the other version; the two prints cut out as 4 × 6 in at 50 and 60 dpi in color, cleaned up as photos; the camera ID card cut out as ID-1 and composed on A4 at its own resolution at 85.60 × 53.98 mm within 0.5 mm (its printed box measured on the page), without glare; two thermal receipts on a white table found in the whole shot at 200 dpi; the two bordered prints found in the whole shot by `PhotoDetector`; `PhotoReview`'s words.

**In the state (Swift only, `App/AppState+Capture.swift`):** the objects of one shot come in together through `ingest(_:source: .photo)`; `.photoSplit` takes a cut-out page as one photo, whole (`splitPhotos`, `cutOutPhoto`: its region the box around its corners), `.receiptSplit` as one receipt made easy to read (`splitReceipts`: `ReceiptEnhancer.enhance` on the cut page at its dpi), and both keep, for Fix crop, the photo as taken with its capture facts in place of the scan (`reviewSources`, `photoSourceImages`, `photoCaptureFacts`, dropped with the sources when the review closes); other pages as before (the fallback shot is searched as a scan). The ID card's flow takes a cut-out page as the step's side, whole (`recordCapturedIdCardSide`): no `IdCardDetector`, no `frontPlaceOnBack` (no glass is covered: `IdCardScanArea` nil), the photo as taken kept as the side's source (`idCardSourceImages`) with its capture facts (`idCardCaptureFacts`), both in memory only and dropped with the side, and the side's note `CaptureObjects.cardNote`: not at real size when the card did not snap to ID-1, the glare hint when the photo shows glare inside the card's corners. `cropStart(for:)` gives Fix crop its picture and corners (a camera's, else the region found on the scan, as a quad, kept within the picture) and kind; `recropPhoto(id:corners:)` cuts an object of a camera's shot out of that picture again along the new corners (`cutAlong`: `PerspectiveStep` and `EnhanceStep` for the kind, a receipt then `ReceiptEnhancer`, a card checked for its size and for glare), off the main actor, keeping its turn and whether it is kept; nothing changes when it was saved, discarded or taken again meanwhile. An object with no capture facts (found on a scan, or on a whole shot) is cut again as the region editor cuts it, at the scan's own resolution and with its own clean-up (`recropPhoto(id:region:)`, the side of a card `recropIdCardSide`), along `region(along:near:)`: the smallest rectangle around the corners (`DocumentGeometry.rectAtAngle`) at the mean angle of their top and bottom edges, by the quarter turn nearest the old region's. `CaptureFlowTests` (shared suite): two prints open the review cut out, Fix crop along an inner outline gives 240 × 160 at 40 dpi, one turned print saved as a JPEG; receipts cut out gray, Fix crop starting from the shot itself; the fallback shot of thermal receipts gives two, and Fix crop along a receipt's corners cuts it again at 200 dpi with no capture facts; a region turned 0°, 10°, −30°, 60° and 95° found again from its corners; the camera ID card at 85.60 × 53.98 mm within 0.5 mm with nothing in the spool, the history, the queue or the save folder, the back with a white patch carrying the glare hint, the review refusing new pages, Discard dropping every picture and corner; a card twice as long as it is wide taken at 200 dpi with the not-at-real-size note; a card saved with No back side as one PDF.

### Pipeline/PhotoImport.swift, App/AppState+Import.swift, CompleteScannerMac/UI/PhotoCornersEditorView.swift (importing photos of documents)

```swift
public struct PhotoOrientation: Equatable, Sendable {      // the orientation tag (EXIF/TIFF 274, kCGImagePropertyOrientation):
    public var quarterTurns: Int; public var mirrored: Bool //   mirrored left to right first, then turned clockwise
    public init(quarterTurns: Int, mirrored: Bool)
    public static let upright: PhotoOrientation; public var isUpright: Bool
    public static func fromExif(_ value: Int) -> PhotoOrientation   // 1 upright, 2 mirrored, 3 (2 turns), 4 (2, mirrored), 5 (3, mirrored),
}                                                                    // 6 (1), 7 (1, mirrored), 8 (3); anything else upright
public enum PhotoImportAction: Sendable { case correct, review }
public enum PhotoReviewReason: Sendable { case none, unsure, cutOff, twoPages, nothingFound }
public struct PhotoImportPlan: Equatable, Sendable {
    public var action: PhotoImportAction; public var corners: Quad; public var reason: PhotoReviewReason
    public var detection: PhotoDocumentDetection
}
public enum PhotoCornersChoice: Sendable { case useCorners, wholePhoto, skip }
public enum PhotoImport {
    // sureConfidence 0.7, nominalDPI 200, minDPI 50, maxDPI 1200, startInset 0.1, minEdgePixels 16, maxPhotoPixels 150_000_000,
    // fileExtensions [jpg jpeg jpe png heic heif hif tif tiff bmp webp], heifExtensions [heic heif hif]; the words: buttonLabel
    // "Import photos of documents…", buttonHint (its tooltip), buttonHelp (for screen readers), pickerTitle, dropHint "or drop
    // them here", dropOverlay "Drop to add as pages", label "Photo", labelHelp, correctedCaption "Corrected from photo",
    // originalCaption "As photographed", editorTitle "Check the corners", editorHelp, editorKeys (behind an info button),
    // useCornersLabel "Use corners", wholePhotoLabel, skipLabel "Skip photo", notOfferedMessage, noPhotosMessage,
    // unreadableDetail, tooLargeDetail, missingDetail
    public static func isPhotoFile(_ path: String) -> Bool; public static func isHeif(_ path: String) -> Bool
    public static func photoFiles(_ paths: [String]) -> [String]    // the photos, in order, each once (letter case aside)
    public static func isOffered(_ settings: ScanSettings) -> Bool  // TaskCatalog.flow(of:) == .documentQueue
    public static func oriented(_ stored: RgbaImage, orientation: PhotoOrientation) -> RgbaImage
    public static func plan(_ photo: RgbaImage) -> PhotoImportPlan  // detect, the page found refined (QuadRefiner), then:
    public static func plan(_ detection: PhotoDocumentDetection, width: Int, height: Int) -> PhotoImportPlan
    public static func wholePhoto(width: Int, height: Int) -> Quad
    public static func startCorners(width: Int, height: Int) -> Quad
    public static func clampedToPhoto(_ quad: Quad, width: Int, height: Int) -> Quad
    public static func canUseCorners(_ quad: Quad) -> Bool          // convex, clockwise, every edge ≥ minEdgePixels
    public static func movedCorner(_ quad: Quad, index: Int, to: CGPoint, width: Int, height: Int) -> Quad
    public static func pageDPI(_ dpi: Double?) -> Int               // floor(dpi + 0.5) within minDPI…maxDPI; nominalDPI when unknown
    public static func wholePhotoDPI(width: Int, height: Int) -> Int
    public static func correctedPage(_ photo: RgbaImage, corners: Quad, createdAt: Date = Date()) -> ScannedPage?
    public static func wholePhotoPage(_ photo: RgbaImage, createdAt: Date = Date()) -> ScannedPage?   // C#: never null
    public static func sourceLabel(_ page: ScannedPage) -> String?  // "Photo" for a page from a photo, "From phone" for a phone's
    public static func sourceHelp(_ page: ScannedPage) -> String?   // "Imported from a photo", "Sent from a paired phone"; nil for a scan
    public static func reasonText(_ reason: PhotoReviewReason) -> String
    public static func counter(_ number: Int, of count: Int, fileName: String) -> String       // "Photo 2 of 5" (one photo: its name)
    public static func counterName(_ number: Int, of count: Int, fileName: String) -> String   // "Photo 2 of 5: IMG_0042.jpg"
    public static func progressMessage(_ number: Int, of count: Int) -> String                // "Importing photo 2 of 5…"
    public static func progressMessage(_ number: Int, of count: Int, page: Int, pageCount: Int) -> String  // "Importing photo 2 of 5, page 3 of 7…"
    public static func pageName(_ fileName: String, page: Int, pageCount: Int) -> String       // "fax.tif, page 2 of 5"; the name alone for one page
    public static func addedMessage(added: Int, skipped: Int, failed: Int, queueCount: Int, saveTitle: String) -> String
    public static func cancelledMessage(added: Int, queueCount: Int) -> String
    public static func unreadableMessage(_ fileName: String, detail: String) -> String
    public static func heifUnavailableMessage(_ fileName: String) -> String   // Windows only shows it; same words on both
}
// Pipeline/QuadRefiner.swift (twin of windows/CompleteScanner.Core/QuadRefiner.cs):
public struct QuadRefinement: Equatable, Sendable { public var quad: Quad; public var refined: Bool; public var support: Double }
public enum QuadRefiner {
    // band 0.03 (of the diagonal, either side of each side), samples 48 (10 %…90 % of a side), minSideSupport 0.5,
    // supportReach 1.5 (analysis px), outerShare 0.7, outerReach 1/3 (of the band, outward); searched at
    // PhotoDocumentDetector.analysisLongSide
    public static func refine(_ image: RgbaImage, _ quad: Quad) -> QuadRefinement   // C# Refine; internal supportOf for tests
}
// App/AppState+Import.swift (twin of windows/CompleteScanner.App/AppViewModel.Import.cs):
public struct PhotoCornersRequest: Identifiable { public let photo: RgbaImage; public let plan: PhotoImportPlan; public let fileName: String; public let number: Int; public let count: Int }
public struct PhotoCornersAnswer: Sendable { public var choice: PhotoCornersChoice; public var corners: Quad?; public static let skip: PhotoCornersAnswer }
extension AppState {
    public var canImportPhotos: Bool                    // isOffered, not busy, no review open, not turning a stack over by hand
    public func chooseAndImportPhotos()                 // CompleteScannerMac: NSOpenPanel, several files, starting in Pictures
    public func importPhotos(_ urls: [URL])
    public func answerCorners(_ answer: PhotoCornersAnswer)   // the corner editor's answer; `cornerReview` (stored in AppState.swift) is the sheet's item
}
```
Twin of `windows/CompleteScanner.Core/PhotoImport.cs` (`PhotoOrientation.FromExif`, `PhotoImportAction`, `PhotoReviewReason`, `PhotoImportPlan`, `PhotoCornersChoice`, `PhotoImport` with the same members in PascalCase, `Dpi` for `DPI`), `PageProcessor.ForPhotoImport`, `PageSource` / `ScannedPage.Source` and `GeometryBasis.Perspective`; `PhotoImportTests` are the same cases on both sides, on `PhotoScenes`. A photo is imported into the page queue wherever the queue collects pages (`isOffered`: the document flow, whatever `documentMultiPage` says; not photos, ID card, copy or receipts), with no scanner needed: Import photos of documents… (Windows: a button under Preview and Scan and a link on the empty stage; the Mac: a button under Preview and Scan), or photo files dropped on the window (Windows: anywhere on the main window; a file drag shows the copy pointer only when it carries photos the window takes, and the no-drop pointer otherwise, the drop is answered as a copy; photos dropped while the settings do not import them, with nothing running, are answered with `notOfferedMessage`; drags of anything but files are left to the controls) or the scanner view (the Mac). Each photo is read once into memory and never written, moved or locked; its size is read from its header before any pixel is decoded, so a photo of more than `maxPhotoPixels` (or one whose pixels do not fit in memory) is listed with `tooLargeDetail` and the others go on; each page of a TIFF of several pages is imported in turn as a photo of its own (how many is read from the file's header, `PhotoFileReader.pageCount`, so a page that cannot be read is listed and the pages after it still go on), named `pageName` in the editor and the errors, with `progressMessage(_:of:page:pageCount:)` (other files give their main picture) (Windows: WIC through `windows/CompleteScanner.App/Services/PhotoFileReader.cs`, checked by `CompleteScanner.App.Tests/PhotoFileReaderTests.cs`; HEIC needs the HEIF Image Extensions, and HEVC Video Extensions for most iPhone photos, from the Microsoft Store, and a HEIC file Windows cannot decode is reported with `heifUnavailableMessage`; the Mac: ImageIO in `AppState+Import.swift`, which reads HEIC itself; neither applies color profiles beyond what `RgbaImage(cgImage:)` does on the Mac), turned upright by its orientation tag (`oriented`), searched for the page (`plan`): a page found with a confidence of at least `sureConfidence` that `PerspectiveCorrector.plan` accepts is cut out at once (`correctedPage`); otherwise the corner editor opens (Windows `PhotoCornersWindow`, modal; the Mac `PhotoCornersEditorView`, a sheet on the detail's tab bar so it opens whichever tab is shown, `cornerReview`; Cancel answers a waiting editor with Skip and stops the import) with `reasonText` and the plan's corners (the page found, else the outline seen kept within the photo, else `startCorners`): each corner is dragged on its own and kept within the photo and on a convex outline (`movedCorner`), a magnifier shows the photo around the corner being moved, keys 1–4 select a corner and the arrow keys move it (Shift: ten steps); Use corners, Use whole photo (`wholePhotoPage`) or Skip photo (also closing it). A page from a photo is a color page (`source == .photo`, labelled "Photo" in the strip) at `pageDPI(plan.dpi)` (the matched paper size's resolution, else 200), whose geometry is `PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective, quad:)` (the corners it was cut along) and whose `alternate` is the upright photo, so the existing swap shows it "As photographed" and saves it that way at the page's resolution; a whole photo has no alternate and takes `wholePhotoDPI`. Each page goes through `PageProcessor.forPhotoImport` and `spoolPages` (the photo is spooled as `<id>-other`), is added to the queue at once and recorded with the task's step; Cancel keeps the pages added before it (`cancelledMessage`). Files that are no photo are left out (`photoFiles`; none at all: `noPhotosMessage`); a photo that cannot be read is listed in one error at the end (`unreadableMessage`) while the others are imported; the status is `addedMessage` plus the queue's notes (`PageCorrections.scanNote` leaves photo pages out). It stores no setting. Moving the corners of a page already in the queue again is not offered yet.

### Companion/SpkiFingerprint.swift, PairingUri.swift, PairingSession.swift, PairedDeviceStore.swift, CompanionHttp.swift, CompanionProtocol.swift, CompanionClient.swift, PairedDesktop.swift, PairedDesktopStore.swift, PhoneOutbox.swift, CompanionRateLimiter.swift, CompanionInbox.swift, CompanionOutbox.swift, CompanionRouter.swift, CompanionNetworks.swift, CompanionTroubleshooter.swift, SelfSignedCertificate.swift, CompanionServer.swift, CompanionHost.swift, CompanionService.swift, SyncPackage.swift, SyncFolderWatcher.swift, App/AppState+CompanionHost.swift (the phone companion)

```swift
public enum SpkiFingerprint {      // byteCount 32, p256PointByteCount 65, p256Prefix (the 26 DER bytes before a P-256 point)
    public static func subjectPublicKeyInfo(_ certificateDER: Data) -> Data?   // a DER walk: Certificate → tbsCertificate → [0]?,
    public static func of(_ certificateDER: Data) -> Data?                     //   serial, signature, issuer, validity, subject → SPKI; nil if malformed
    public static func ofSubjectPublicKeyInfo(_ spki: Data) -> Data            // SHA-256
    public static func p256SubjectPublicKeyInfo(_ uncompressedPoint: Data) -> Data?   // prefix + 0x04 X Y (SecKeyCopyExternalRepresentation)
    public static func text(_ fingerprint: Data) -> String                     // base64url, 43 characters (the pairing code's fp)
    public static func hex(_ fingerprint: Data) -> String
    public static func matches(_ fingerprint: Data, _ expected: Data) -> Bool  // constant time, 32 bytes each
    public static func checkCode(_ fingerprint: Data) -> String                // first 4 bytes big-endian % 1_000_000, 6 digits; "" under 4 bytes
    public static func formatCheckCode(_ code: String) -> String               // "725 115"
}
public enum PairingUriErrorKind { case notPairingCode, newerVersion, damaged }
public struct PairingUriError: LocalizedError { kind; message }                // notPairingCodeMessage, newerVersionMessage, damagedMessage
public struct PairingUri: Equatable {
    // completescanner://pair?v=1&id=<desktopId>&n=<name>&fp=<SPKI SHA-256, base64url>&a=<addr,addr>&p=<port>&t=<16-byte token, base64url>
    public var desktopId, name, fingerprint: String; public var addresses: [String]; public var port: Int; public var token: String
    public static let maxLength = 2048 /* UTF-8 bytes */, maxAddresses = 8, maxAddressLength = 64, maxNameBytes = 128, tokenByteCount = 16
    public var fingerprintBytes: Data?
    public func format() throws -> String            // values percent-encoded (all but A-Z a-z 0-9 - . _ ~, uppercase hex); "a" left out when empty
    public static func parse(_ text: String) throws -> PairingUri   // scheme and host in any case; unknown parameters ignored; the version
                                                                    // first (newer → .newerVersion); a duplicate, bad escape, non-UTF-8,
                                                                    // '#', a value out of its rule → .damaged
    public static func isValidAddress(_ address: String) -> Bool   // IPv4 dotted (no leading zeros) or IPv6 ("::", IPv4 tail, %zone)
    public static func percentEncode(_ value: String) -> String; public static func percentDecode(_ value: String) -> String?
}
public enum PairingSessionState { case open, used, expired, closed }
public enum PairingRedeemResult { case accepted, wrongToken, expired, alreadyUsed, closed }
public final class PairingSession {                // lifetime 5 min, maxFailedAttempts 5; the clock is passed in
    public init(opened: Date, token: Data? = nil) throws   // 16 random bytes unless given (C#: ArgumentException for another length)
    public let token: String; public let opened: Date; public let expires: Date; public var failedAttempts: Int
    public func state(at now: Date) -> PairingSessionState; public func remaining(at now: Date) -> TimeInterval
    public func redeem(_ token: String?, now: Date) -> PairingRedeemResult   // constant time; once; the 5th wrong token closes it
    public func close()
}
public struct PairedDevice: Codable { id, name, platform, appVersion, secretHash: String; paired, lastSeen: Date? }
    // C#: + SyncKeyProtected (the sync key under DPAPI for the current user, base64; "" for none)
public struct PairedDevicesFile: Codable { desktopId: String; devices: [PairedDevice]; syncFolder: String }   // companion-devices.json, rule 6
public final class PairedDeviceStore {             // fileName, secretByteCount 32, maxDevices 16, lastSeenResolution 60 s
    public init(directory: URL, syncKeyStore: (any CompanionSecretStore)? = nil)   // sync keys by phone id; nil: none made
    public var desktopId: String { get }   // 32 hex digits, made and saved on first use
    public var devices: [PairedDevice]; public var count: Int; public var onChange: (() -> Void)?   // C#: event Changed
    public func pair(id:name:platform:appVersion:now:) throws -> String   // a new 256-bit secret, base64url; only SHA-256 hex is kept
    public func authenticate(id: String?, secret: String?, now: Date) -> PairedDevice?   // constant time; last seen to the minute
    public func remove(_ id: String) -> Bool; public func removeAll() -> Int   // removed phones stay refused for the session
    public func syncKey(for id: String) throws -> Data?   // 32 bytes, made at the first pairing, kept when it pairs again; dropped with
                                                    // the phone; throws when the store cannot be read now (C#: SyncKey(id), DPAPI,
                                                    // CryptographicException)
    public var syncFolder: URL? { get }; @discardableResult public func setSyncFolder(_ folder: URL?) -> Bool   // a path; C#: string?
    public static func hashSecret(_ secret: Data) -> String; public static func cleanName(_ name: String?) -> String
}
public enum CompanionHttp {                        // maxRequestLineBytes 2048, maxHeadBytes 16 KiB, maxHeaderCount 64, methods GET PUT POST DELETE
    public static func parse(_ data: [UInt8]) -> HttpParseResult   // .incomplete / .complete(head, consumed) / .invalid(errorStatus)
    public static func reasonPhrase(_ status: Int) -> String
    public static func responseHead(status: Int, headers: [HttpHeader], contentLength: Int64) -> Data   // + Content-Length, Connection: close
    public static let continueResponse: Data; public static func queryParameters(_ query: String) -> [String: String]
}
public struct HttpRequestHead { method, target: String; headers: [HttpHeader]; contentLength: Int64?; expectsContinue: Bool
                                path, query, bearerToken; func header(_ name: String) -> String? }
public enum CompanionProtocol {                    // version 1, serviceType "_completescan._tcp", defaultPort 52731, the paths and headers,
    // maxJsonBodyBytes 8192, maxOutboxWaitSeconds 25, maxUploadBytes (zip total + 16 MiB), pageLabel "From phone", pageLabelHelp
    public static func isValidId(_ id: String?) -> Bool          // 8–64 of A-Z a-z 0-9 - _
    public static func encodeBase64Url(_ data: Data) -> String; public static func decodeBase64Url(_ text: String?) -> Data?   // strict
    public static func target(_ value: String?) -> CompanionTarget; public static func targetValue(_ target: CompanionTarget) -> String
    public static func addedMessage(_ pageCount: Int, phoneName: String) -> String   // "3 pages from Aytu's iPhone added to the queue."
}
public enum CompanionTarget: String { case new, current }
public struct CompanionError { code, message; toJSON(); fromJSON(_:) }   // codes in CompanionErrorCode, messages as static members
public struct PairRequest { token, phoneId, phoneName, platform, appVersion }        // each message: toJSON() with a fixed key order,
public struct PairResponse { desktopId, desktopName, deviceSecret, protocolVersion, syncKey: String? }  // fromJSON(_:) read leniently, nil when
public struct HealthResponse { protocolVersion, paired }                              // not a JSON object (HealthResponse: not ours)
public struct HelloResponse { desktopId, desktopName, protocolVersion, queuedPages, maxUploadBytes }
public struct InboxResponse { packageId, pageCount, duplicate }
public struct OutboxItem { id, name, contentType, byteCount, created }; public struct OutboxList { items }   // items without a valid id or date dropped
// App/AppState+Package.swift (I18): a .csdoc opened by hand
public enum PackageText {                          // addToPages "Add to pages", openAsNew "Open as new", notOfferedMessage
    public static func openedMessage(_ fileName: String, pageCount: Int) -> String   // "Opened Receipt.csdoc: 3 pages"
    public static func unreadablePictureMessage(_ fileName: String) -> String        // "Receipt.csdoc cannot be opened: one of its pictures cannot be read."
}
public struct PendingPackage { fileName: String; pages: [ScannedPage]; documentName: String; pageCount: Int
    public static func read(_ url: URL) throws -> PendingPackage   // pages as CompanionPages.ToScannedPages(.current), source .phone
    public var asNewDocument: [ScannedPage] }                      // the first page named documentName
extension AppState {                               // `pendingPackage: PendingPackage?` is stored in AppState.swift
    public func openPackage(at url: URL) async                     // off the main actor; a refusal goes to errorMessage
    @discardableResult public func addPendingPackageToPages() -> Bool   // ingest(_, source: .phone) after the queued pages
    @discardableResult public func openPendingPackageAsNew() -> Bool    // clearPages(), then ingest (the iPhone asks about queued pages first)
    public func dismissPendingPackage()
    public func exportPackage(to folder: URL) async throws -> URL  // <next file name>.csdoc in folder
}
// Companion/CompanionClient.swift, PairedDesktop.swift, PairedDesktopStore.swift, PhoneOutbox.swift (I20): the phone's side
public enum CompanionClientError: Error, LocalizedError {   // a refusal carries the body's CompanionError, else refusedMessage(status)
    case unreachable(Error), wrongCertificate, unauthorized /* 401 */, rateLimited(retryAfter: Int) /* 429: Retry-After, else 60 */
    case tooLarge(CompanionError) /* 413 */, invalidPackage(CompanionError) /* 422 */, busy(CompanionError) /* 409 busy */
    case refused(status: Int, CompanionError), badResponse
}
public final class CompanionClient {               // probeTimeout 5 s, requestTimeout 15 s, pairTimeout 150 s; ephemeral URLSession
    public init(desktop: PairedDesktop, secret: Data?, protocolClasses: [AnyClass] = [])   // protocolClasses: test stubs
    public let desktop: PairedDesktop; public var address: String? { get }   // the address that answered a health check
    public static func accepts(_ certificateDER: Data?, pinned: Data?) -> Bool   // SpkiFingerprint.of(DER) matches the pin; nothing else
    public func health() async throws -> HealthResponse
    public func pair(token: String, phoneId: String, phoneName: String, platform: String, appVersion: String) async throws -> PairResponse
    public func hello() async throws -> HelloResponse
    public func send(packageId: String, data: Data, target: CompanionTarget) async throws -> InboxResponse   // 150 s + 1 s per MB, Expect: 100-continue
    public func outbox(wait: Int) async throws -> OutboxList      // wait clamped to 0...maxOutboxWaitSeconds
    public func outboxItem(id: String) async throws -> Data; public func ack(id: String) async throws; public func unpair() async throws
}
public struct PairedDesktop: Codable { id, name, fingerprint: String; addresses: [String]; port: Int; phoneId: String
    pairedAt, lastSeen: Date?; received: [String]; syncFolderBookmark: Data?
    static let maxReceived = 200; mutating func noteReceived(_ id: String)
    var fingerprintBytes: Data?; static func makePhoneId() -> String }   // companion-desktop.json, rule 6
public protocol CompanionSecretStore: Sendable {   // the Keychain on the iPhone (sync key: "<desktopId>.sync"); the Mac's for sync keys
    func save(_ secret: Data, for desktopId: String) throws; func load(for desktopId: String) throws -> Data?
    func delete(for desktopId: String) throws
}
public final class PairedDesktopStore {            // fileName "companion-desktop.json"; the secret is never in the file
    public init(directory: URL, secrets: any CompanionSecretStore)
    public func load() -> PairedDesktop?            // nil without a valid id, phone id, fingerprint and an address
    public func save(_ desktop: PairedDesktop, secret: Data, syncKey: Data? = nil) throws   // .notSaved; another desktop's secret
                                                    // and sync key go; nil drops a sync key kept before
    public func update(_ desktop: PairedDesktop); public func secret(for desktop: PairedDesktop) -> Data?
    public func syncKey(for desktop: PairedDesktop) -> Data?   // 32 bytes or nil; forgetSecret and remove drop it too
    public func forgetSecret(of desktop: PairedDesktop); public func remove()
}
public struct PhoneOutboxItem: Codable { id, fileName, desktopId: String; target: CompanionTarget; created: Date?; attempts: Int
    lastError: String; viaSyncFolder: Bool         // the folder failed once: tried first next time
    inSyncFolder: Bool; refused: Bool }            // in the folder until the desktop has it; refused: never into the folder
public final class PhoneOutbox {                   // fileName "outbox.json", maxItems 50; a folder of .csdoc files
    public init(directory: URL); public let directory: URL; public var items: [PhoneOutboxItem]; public var count: Int
    public func fileURL(of item: PhoneOutboxItem) -> URL
    @discardableResult public func enqueue(_ package: URL, target: CompanionTarget, desktopId: String,
                                           now: Date = Date()) throws -> PhoneOutboxItem
    public func next(excluding: Set<String> = []) -> PhoneOutboxItem?   // the oldest
    public func markSent(_ id: String); public func markFailed(_ id: String, error: String); public func remove(_ id: String)
    public func markViaSyncFolder(_ id: String); public func markInSyncFolder(_ id: String, _ inSyncFolder: Bool = true)
    public func markRefused(_ id: String)
}
// App/AppState+Companion.swift (I20)
public enum CompanionStatus { case notPaired, checking, reachable(desktopName: String, queuedPages: Int), unreachable(reason: String),
                              unpaired(byDesktop: String) }
public enum CompanionText {                        // clientIsolationReason, notPairedMessage, outboxFullMessage, unreachableMessage,
                                                   // wrongCertificateMessage, badResponseMessage, notSavedMessage,
                                                   // syncFolderHint, syncFolderUnavailableMessage, syncFolderLine,
                                                   // clientIsolationSyncFolderReason
    public static func notOnNetworkReason(_ desktopName: String) -> String       // "Office PC is not on this network."
    public static func cannotReachMessage(_ desktopName: String) -> String       // "Office PC cannot be reached on this network."
    public static func pairedMessage(_ desktopName: String) -> String            // "Paired with Office PC."
    public static func unpairedMessage(_ desktopName: String) -> String          // "This phone is no longer paired with Office PC."
    public static func sentMessage(_ pageCount: Int, desktopName: String) -> String   // "Sent 3 pages to Office PC."
    public static func notSentMessage(_ fileName: String, reason: String) -> String   // "Scan 12.csdoc was not sent: <reason>"
    public static func receivedMessage(_ fileName: String, desktopName: String) -> String   // "Received Invoice.pdf from Office PC."
    public static func refusedMessage(_ status: Int) -> String                   // "The computer refused the request (HTTP 501)."
    public static func putInSyncFolderMessage(_ documentName: String, desktopName: String) -> String   // "Put Scan 12 in the cloud folder for Office PC."
    public static func putInSyncFolderMessage(count: Int, desktopName: String) -> String   // "Put 3 documents in the cloud folder for Office PC."
}
extension AppState {                               // companionDesktop, companionStatus, companionOutboxCount (published) and
                                                   // companionDesktopSeenOnNetwork: ((String) -> Bool)? are stored in AppState.swift
    public func setUpCompanion(in folder: URL, secrets: any CompanionSecretStore)
    public func pairDesktop(uri: String, phoneName: String) async
    public func unpairDesktop() async; public func checkDesktop() async
    public func sendQueueToDesktop(target: CompanionTarget) async; public func drainOutbox() async
    public func pullFromDesktop(); public func stopPulling()
    public func clearOutbox()                                      // the waiting documents removed, unsent
    // the paired desktop's, when changed and its pinned certificate answers there: IPv4 first, at most 8
    @discardableResult public func desktopFound(id: String, addresses: [String], port: Int) async -> Bool
    // C2: resolveSyncFolderBookmark: (@MainActor (Data) -> (folder: URL, bookmark: Data)?)? is stored in AppState.swift
    public var canUseSyncFolder: Bool               // the desktop handed out a sync key
    public func setSyncFolder(bookmark: Data?); public func openSyncFolder() -> URL?
    @discardableResult public func sendThroughSyncFolder(itemId: String) -> Bool
}
// Companion/CompanionRateLimiter.swift, CompanionInbox.swift, CompanionOutbox.swift, CompanionRouter.swift, CompanionNetworks.swift,
// CompanionTroubleshooter.swift, SelfSignedCertificate.swift, CompanionServer.swift (I21): the desktop's side, for the Mac's host
public final class CompanionRateLimiter {         // maxFailures 10, maxRequestsPerWindow 300, maxTrackedAddresses 1024, window 60 s
    public func isBlocked(_ address: NWEndpoint.Host, now: Date) -> Bool; public func tryRequest(_ address: NWEndpoint.Host, now: Date) -> Bool
    public func recordFailure(_ address: NWEndpoint.Host, now: Date)   // an IPv4-mapped IPv6 address counts as its IPv4 address
}
public struct ReceivedPackage { deviceId, packageId: String; url: URL; document: CompanionDocument; target: CompanionTarget; received: Date }
public struct ReceivedEntry: Codable { packageId: String; pageCount: Int; received: Date? }; public struct ReceivedLog: Codable { packages }
public enum CompanionInboxError: Error { case invalidId, endedEarly, notSaved }
public final class CompanionInbox {                // maxLoggedPackages 1000, logFileName "received.json"; a folder per phone
    public init(directory: URL); public static var defaultDirectory: URL   // Application Support/CompleteScanner/Companion/Inbox
    public func find(deviceId: String, packageId: String) -> ReceivedEntry?
    public func tryBegin(deviceId: String, packageId: String) -> Bool; public func end(deviceId: String, packageId: String)
    public func receive(deviceId: String, packageId: String, target: CompanionTarget, body: CompanionRequestBody, length: Int64,
                        now: Date) async throws -> ReceivedPackage   // <id>.part, read in full, then <id>.csdoc and received.json
    public func release(_ package: ReceivedPackage); public func pending() -> [ReceivedPackage]; public func removeDevice(_ deviceId: String)
}
public struct OutboxEntry: Codable { id, name, contentType: String; byteCount: Int64; created: Date? }; public struct OutboxIndex: Codable { items }
public enum CompanionOutboxError: Error { case invalidId, notSaved }
public final class CompanionOutbox {               // what the desktop holds for each phone (not PhoneOutbox); keepFor 7 days, "outbox.json"
    public init(directory: URL); public static var defaultDirectory: URL   // Application Support/CompleteScanner/Companion/Outbox
    @discardableResult public func add(deviceId: String, source: URL, name: String, contentType: String, now: Date) throws -> OutboxItem
    public func list(deviceId: String, now: Date) -> [OutboxItem]    // oldest first; items past keepFor or without their file dropped
    public func open(deviceId: String, id: String) -> (item: OutboxItem, file: FileHandle, length: Int64)?
    @discardableResult public func remove(deviceId: String, id: String) -> Bool; public func removeDevice(_ deviceId: String)
    public func wait(deviceId: String, timeout: TimeInterval) async  // until something is added, the timeout, or the task is cancelled
}
public final class CompanionRequestBody {          // exactly Content-Length bytes: what came with the head, then `source`
    public init(length: Int64, prefix: Data = Data(), sendContinue: (() async throws -> Void)? = nil,
                source: @escaping (Int) async throws -> Data)
    public let length: Int64; public var remaining: Int64 { get }; public var hasStarted: Bool { get }; public var isWithheld: Bool
    public func read(maxLength: Int) async throws -> Data; public func discard(maxBytes: Int64) async throws -> Bool
}
public struct CompanionRequest { head: HttpRequestHead; body: CompanionRequestBody; remote: NWEndpoint.Host }
public struct CompanionResponse { status: Int; headers: [HttpHeader]; body: Data; bodyFile: FileHandle?; length: Int64; text: String
    static func json(_ status: Int, _ json: String, headers:), error(_ status: Int, _ error: CompanionError, headers:), empty(_ status: Int),
    file(_ file: FileHandle, length: Int64, contentType: String) }
public final class CompanionRouter {
    public init(devices: PairedDeviceStore, inbox: CompanionInbox, outbox: CompanionOutbox, limiter: CompanionRateLimiter,
                clock: @escaping () -> Date = { Date() })
    public var desktopName: () -> String; public var currentPairing: () -> PairingSession?; public var queuedPages: () -> Int
    public var approvePairing: (PairRequest) async -> Bool          // default true; cancelled and declined after approvalTimeout (120 s)
    public var approvalTimeout: TimeInterval; public var awaitingApproval: Int { get }
    public var onDevicePaired: ((PairedDevice) -> Void)?; public var onPackageReceived: ((ReceivedPackage, PairedDevice) -> Void)?
    public var onDeviceRemoved: ((PairedDevice) -> Void)?; public var onApprovalSettled: (() -> Void)?
    public func handle(_ request: CompanionRequest) async -> CompanionResponse
}
public enum CompanionNetworkCategory { case publicNetwork, privateNetwork, domainNetwork }   // no categories: .publicNetwork
public struct LocalSubnet { address: NWEndpoint.Host; prefixLength: Int; func contains(_ other: NWEndpoint.Host) -> Bool }
public struct CompanionNetworkInterface { index: Int; adapterId: String; addresses: [LocalSubnet] }
public struct CompanionNetwork { id, name: String; category: CompanionNetworkCategory; interfaces: [CompanionNetworkInterface] }
public enum NetworkTrust { case notTrusted, privateNetwork, approved }
public struct ApprovedNetwork: Codable { id, name: String; approved: Date? }; public struct ApprovedNetworksFile: Codable { networks }
public final class TrustedNetworkStore {           // fileName "companion-networks.json"; an approval withdrawn holds for the session
    public init(directory: URL); public var approved: [ApprovedNetwork]; public var onChange: (() -> Void)?   // C#: event Changed
    public func isApproved(_ networkId: String) -> Bool; @discardableResult public func approve(_ network: CompanionNetwork, now: Date) -> Bool
    public func revoke(_ networkId: String)
}
public enum TrustedNetworkPolicy {
    public static func trust(_ network: CompanionNetwork, isApproved: (String) -> Bool) -> NetworkTrust
    public static func listenAddresses(_ networks: [CompanionNetwork], isApproved: (String) -> Bool) -> [LocalSubnet]   // IPv4 first
    public static func isAllowedPeer(_ remote: NWEndpoint.Host, listening: [LocalSubnet]) -> Bool
    public static func isLocalAddress(_ remote: NWEndpoint.Host) -> Bool   // loopback, RFC 1918, link-local, 100.64.0.0/10, fc00::/7
}
public enum CompanionListenState { case off, offline, noTrustedNetwork, listening, failed, elsewhere }   // C#: in CompanionHost.cs
public enum CompanionFirewallVerdict { case unknown, off, allowed, blocked, willAsk }   // Windows only; the Mac leaves .unknown
public struct CompanionNetworkState { network: CompanionNetwork; trust: NetworkTrust }
public struct CompanionSnapshot { platform: TroubleshootPlatform; networks: [CompanionNetworkState]; listen: CompanionListenState; port: Int
    listenError: String?; firewall: CompanionFirewallVerdict; blockingRules: [String]; pairedCount: Int; pairingOpen: Bool
    syncFolderChosen: Bool; phonesQuietFor: TimeInterval? }   // C2; C#: SyncFolderChosen, PhonesQuietFor (TimeSpan?)
public enum CompanionTroubleshooter {              // quietTime 3 days
    public static func diagnose(_ snapshot: CompanionSnapshot) -> [TroubleshootCheck]   // "this PC" or "this Mac" by platform
    public static func headline(_ snapshot: CompanionSnapshot) -> String; public static func summary(_ checks: [TroubleshootCheck]) -> String
}
public enum SelfSignedCertificate {                // validity 825 days, backdate 1 day; SelfSignedCertificateError
    public static func commonName(hostName: String) -> String       // "<host name> CompleteScanner"
    public static func make(hostName: String, key: SecKey, now: Date) throws -> Data   // the DER
    public static func notAfter(_ der: Data) -> Date?; public static func certificate(_ der: Data) -> SecCertificate?
    public static func der(of identity: SecIdentity) -> Data?
}
public protocol CompanionIdentity: AnyObject {      // the server's SecIdentity: the Mac's keychain store, or a test's
    func current(now: Date) throws -> SecIdentity    // made on first use, renewed with the same key before it expires
    func renew(now: Date) throws -> SecIdentity      // a new key (Reset pairing)
}
public struct CompanionServerOptions { maxConnections 8, handshakeTimeout 10 s, headTimeout 10 s, idleTimeout 30 s, maxDiscardBytes 1 MiB,
    allowPeer: ((NWEndpoint.Host) -> Bool)?, stopGrace 2 s }
public enum CompanionServerError: Error { case alreadyRunning, nothingToListenOn, unusableIdentity }
public final class CompanionServer {
    public init(identity: SecIdentity, router: CompanionRouter, limiter: CompanionRateLimiter,
                options: CompanionServerOptions = CompanionServerOptions(), clock: @escaping () -> Date = { Date() })
    @discardableResult public func start(_ endpoints: [NWEndpoint]) async throws -> [NWEndpoint]   // .hostPort each; .any: the first's port
    public func stop() async; public var localEndpoints: [NWEndpoint]; public var isRunning: Bool; public var activeConnections: Int
}
public protocol CompanionNetworkSource: AnyObject { func networks() -> [CompanionNetwork]; var onChange: (() -> Void)? { get set } }
public struct DnsSdRegistration: Equatable { instanceName: String; port: Int; interfaceIndex: Int; txt: [String: String]; serviceType }
public protocol DnsSdAdvertiser: AnyObject { func register(_ registration: DnsSdRegistration) throws -> () -> Void }   // returns the withdrawal
public final class NoDnsSdAdvertiser: DnsSdAdvertiser
public struct CompanionHostStatus: Equatable { state: CompanionListenState; networks: [CompanionNetworkState]; endpoints: [NWEndpoint]
    error: String?; port: Int; static let initial; static func port(of endpoints: [NWEndpoint]) -> Int }
public struct CompanionHostOptions { preferredPort (52731); instanceName; desktopId: () -> String; server: CompanionServerOptions; clock }
public final class CompanionHost {
    public init(identity: @escaping () throws -> SecIdentity, router: CompanionRouter, limiter: CompanionRateLimiter,
                networks: CompanionNetworkSource, isApproved: @escaping (String) -> Bool, advertiser: DnsSdAdvertiser,
                wanted: @escaping () -> Bool, options: CompanionHostOptions = CompanionHostOptions())
    public var status: CompanionHostStatus { get }; public var onStatusChange: (() -> Void)?; public var advertised: [DnsSdRegistration]
    public func refresh(restart: Bool = false) async; public func dispose() async   // one at a time, in the order asked
}
public struct CompanionServiceOptions { settingsDirectory, dataDirectory: URL; identity: CompanionIdentity; networks: CompanionNetworkSource
    advertiser (NoDnsSdAdvertiser); clock; desktopName: String; preferredPort (52731); server: CompanionServerOptions
    syncKeyStore: (any CompanionSecretStore)?      // the Mac's Keychain; C# has none (DPAPI in PairedDeviceStore)
    init(settingsDirectory:dataDirectory:identity:networks:desktopName:) }
public final class CompanionService {
    public init(_ options: CompanionServiceOptions)
    public let devices: PairedDeviceStore; trustedNetworks: TrustedNetworkStore; inbox: CompanionInbox; outbox: CompanionOutbox
    public let limiter: CompanionRateLimiter; router: CompanionRouter; host: CompanionHost
    public var onChange: (() -> Void)?; onDevicePaired: ((PairedDevice) -> Void)?; onPackageReceived: ((ReceivedPackage, PairedDevice) -> Void)?
    public var onSyncFolderProblem: ((String) -> Void)?   // C#: event SyncFolderProblem
    public var syncFolder: URL? { get }; @discardableResult public func setSyncFolder(_ folder: URL?) -> Bool   // C#: SetSyncFolder(string?)
    public var status: CompanionHostStatus; pairing: PairingSession?; awaitingApproval: Bool; queuedPages: Int { get set }
    public func fingerprint() throws -> Data; start() async; refresh() async; openPairing() async -> PairingUri?; pairingCode() -> PairingUri?
    public func closePairing() async; removeDevice(_ id: String) async; resetPairing() async throws
    @discardableResult public func setNetworkApproved(_ network: CompanionNetwork, _ approved: Bool) async -> Bool
    public func snapshot(platform: TroubleshootPlatform = .mac) -> CompanionSnapshot; dispose() async
    public static func codeAddresses(_ endpoints: [NWEndpoint]) -> [String]; pairingName(_ name: String) -> String
    public static var settingsFolder: URL; static func dataFolder() -> URL   // Application Support/CompleteScanner(/Companion, out of backups)
}
// Companion/SyncPackage.swift, SyncFolderWatcher.swift (C2): the cloud sync folder
public enum SyncPackageError: Error, LocalizedError { case notASyncPackage, newerVersion, wrongKeyOrTampered, tooLarge }
public enum SyncPackage {                          // fileExtension "cssync", version 1, keyByteCount 32, nonceByteCount 12,
                                                   // tagByteCount 16, headerByteCount 16, magic "CSSYNC01"
    public static var maxFileBytes: Int            // maxUploadBytes + 64
    public static func seal(packageId: String, phoneId: String, target: CompanionTarget, plaintext: Data, key: Data,
                            nonce: Data? = nil) throws -> Data   // a random nonce unless given; .tooLarge past maxUploadBytes
    public static func open(_ data: Data, packageId: String, phoneId: String, key: Data) throws -> (target: CompanionTarget, plaintext: Data)
    public static func fileName(_ packageId: String) -> String   // "<packageId>.cssync"
}
public final class SyncFolderWatcher {             // pollInterval 5 s, settleTime 2 s
    public init(folder: URL, devices: PairedDeviceStore, inbox: CompanionInbox, clock: @escaping () -> Date = { Date() })
    public let folder: URL; public var onPackageReceived: ((ReceivedPackage, PairedDevice) -> Void)?; public var onProblem: ((String) -> Void)?
    public func start(); public func stop(); public func poll() async   // C#: Start(), Dispose(), PollAsync()
    public static func unreadableMessage(_ fileName: String, reason: String) -> String
}
public enum CompanionHostText { elsewhereMessage; notStartedMessage(_:); addingMessage(_:); waitingMessage(pageCount:from:collectsPages:)
    unreadableMessage(_:); notAddedMessage(_:reason:) }
extension AppState {   // the desktop's side (AppState+CompanionHost.swift); the phone's side is AppState+Companion.swift
    public internal(set) var companionService: CompanionService?
    @Published companionHostStatus: CompanionHostStatus; companionHostError: String?; phoneBarMessage: String?; phoneDocumentsWaitingMessage: String?
    public var confirmPhonePairing: (@MainActor (PairRequest) async -> Bool)?
    public func setUpCompanionHost(_ options: CompanionServiceOptions); @discardableResult public func ensureCompanionHost() -> CompanionService?
    public func dismissPhoneBar(); public var canTakePhonePages: Bool
}
```
Twins of `windows/CompleteScanner.Core/Companion/SpkiFingerprint.cs`, `PairingUri.cs` (`PairingUriException`), `PairingSession.cs`, `PairedDeviceStore.cs`, `CompanionHttp.cs` (headers as `KeyValuePair<string, string>`), `CompanionProtocol.cs`; `SpkiFingerprintTests` (with the shared `CompanionVectors`: a P-256 certificate made with OpenSSL, its SPKI, fingerprint, text and check code, a device secret and its hash, a token), `PairingUriTests`, `PairingSessionTests`, `PairedDeviceStoreTests`, `CompanionHttpTests` and `CompanionProtocolTests` are the same cases on both sides (C# only: `MatchesDotNetSubjectPublicKeyInfo`). Swift computes SHA-256 with the package's own `SHA256Digest` (no CryptoKit) and random bytes with `SystemRandomNumberGenerator`.

**The phone companion (C1, Windows; the Mac since I21).** A phone paired with the desktop sends `.csdoc` packages (`CompanionPackage`) over HTTP/1.1 on TLS 1.2/1.3, the phone always connecting. The desktop's certificate is a self-signed ECDSA P-256 certificate in the user's own store (`CurrentUser\My`, friendly name "CompleteScanner phone link", made on first use, renewed with the same key before it expires so pins hold; `Services/Companion/CompanionCertificateStore.cs`); the phone pins its `SpkiFingerprint`, which the pairing code carries, so the first connection is already pinned. Pairing: Pair a phone opens a `PairingSession` and shows its `PairingUri` as a QR code (ZXing.Net) with the address, the token and the check code; `POST /v1/pair` with the token (the only call an unpaired client may make besides `GET /v1/health`) asks the user in the Phone window whether the phone may pair (no answer in 2 minutes declines), then hands the phone a 256-bit secret whose SHA-256 alone is kept (`PairedDeviceStore`); every later request carries `Authorization: Bearer <secret>` and `X-Device-Id`, and anything else gets 401 (a removed phone too). Endpoints and errors: `CompanionProtocol`; uploads (`PUT /v1/inbox/{id}`, at most `maxUploadBytes`, Content-Length required, chunked refused, `Expect: 100-continue` honoured so a refused upload is never sent) are streamed to a file, read in full through `ZipStoreReader`/`CompanionPackage` before they count, idempotent by package id (`CompanionInbox`, its last 1000 ids per phone), and refused with 422 and the package's message otherwise. Each request counts towards a per-address limit (`CompanionRateLimiter`: 300 a minute; 10 wrong secrets or tokens a minute block the address before TLS); at most 8 connections, every step timed out; peers outside private, link-local, shared and unique-local ranges and the listened subnet are closed before TLS. Where it listens (`CompanionHost`, `TrustedNetworkPolicy`): only while it is wanted (a phone is paired, a code is shown, or a phone that presented the code waits for the user's answer; nothing listens for someone who never chooses Pair a phone, and the certificate is made the first time a code is shown; Pair a phone on a network it does not receive on shows why instead of a code and leaves no pairing session open) and only on the addresses of trusted networks (Windows treats them as Private, or the user turned on "Allow receiving on this network" for them in the Phone window, stored by the Network List Manager's network id in `companion-networks.json`; a work domain network needs the same approval), never on an adapter of an untrusted network; it follows the Network List Manager (`Services/Companion/WindowsNetworkSource.cs`: address changes and a check every 15 s, since a category change moves no address), stops and withdraws everything when the last trusted network goes, and advertises `_completescan._tcp` (TXT `v`, `id`) through `DnsServiceRegister` on each trusted interface only, while listening (`WindowsDnsSdAdvertiser`). One window of the app receives (a named mutex); another says so. Documents from paired phones are added to the queue on their own (`AppViewModel.Companion.cs`, `CompanionPages`): each picture decoded (WIC), the rotation the phone had still to apply applied, `source == .phone` ("From phone" in the strip), side and sheet kept, the picture as photographed kept as the page's other version and what the phone's camera recorded kept as the page's `capture`, a document sent as new starting its own document in the queue under its name; while the queue does not collect pages (Photos mode, the ID card, copy or receipt tasks, a review, a stack turned over by hand) or the app is busy, the document waits with a message and is added as soon as it can be; a bar above the window says what arrived and the taskbar button flashes when the window is in the background; a package received but not yet added (the app closed, or its pages could not be written to the page spool) is added at the next start, while one with a picture that cannot be read is dropped with a message. The Phone window also lists the paired phones (Remove; Reset pairing makes a new key and unpairs every phone) and the connection checks (`CompanionTroubleshooter`: a network not received on, an approved public network, Windows Firewall's verdict read from its rules through `HNetCfg.FwPolicy2` without changing them (`FirewallReader`, `CompanionFirewall`: a block rule for the app on the profile of a network it receives on, or while it receives on none of a connected network, is a problem; another adapter's profile, such as the public virtual switch of Hyper-V or WSL, does not count; no rule means Windows will ask once), listening or why not, and the tip for networks that keep devices apart). The outbox (`GET /v1/outbox`, long-poll up to 25 s, `GET`/`DELETE /v1/outbox/{id}`, items kept 7 days) is served for the iPhone app; nothing on the desktop puts files in it yet. The iPhone's client and its screens are in the next paragraph. Not built yet: Print through my computer from the phone (I19–I20), a short pairing code to type instead of the 22-character token (the desktop shows none: entering the pairing code's text is the way by hand), and sending from the desktop to a phone (the outbox is served and the phone takes from it, but nothing on the desktop fills it yet).

**The iPhone companion client (I20).** The phone's side of C1 is in the shared core (`Companion/CompanionClient.swift`, `PairedDesktop.swift`, `PairedDesktopStore.swift`, `PhoneOutbox.swift`, `App/AppState+Companion.swift`); its requests are the C# `FakePhone`'s (`windows/CompleteScanner.Core.Tests/CompanionLoopbackTests.cs`), and the Windows server stays the reference. `CompanionClient` talks to one desktop over URLSession (ephemeral, no cache, no cookies, TLS 1.2 at least): its session delegate accepts the server's certificate only when `accepts(_:pinned:)` finds the SHA-256 of the leaf's SubjectPublicKeyInfo (`SpkiFingerprint.of`) to be the fingerprint the pairing code carried (the system's trust is not asked: the certificate is self-signed), and cancels the connection otherwise, remembered for that host so the failure is `.wrongCertificate` rather than `.unreachable`. The first of the code's addresses that answers an anonymous `GET /v1/health` within 5 s is used for the client's life; when it stops answering, the addresses are tried again once (not for pairing, whose token works once, nor for an upload whose connection broke after it connected). An upload whose connection broke after the request went out (any transport error but no connection, an unresolved host, no network or a timeout) may have been answered before its body was read, the desktop closing on the rest (a 401, 409 busy, 413 or a 200 duplicate, should CFNetwork not wait for 100 Continue), so one bodiless authenticated `GET /v1/hello` asks the same address: 401 is `.unauthorized`, an answer means the desktop is up and the answer was lost, so the upload is sent once more (the inbox is idempotent per package id), and no answer leaves it `.unreachable`. Whether CFNetwork waits for 100 Continue is checked on a device against the Windows server. Requests: `POST /v1/pair` (Content-Type `application/json; charset=utf-8`, no credentials, 150 s, since the desktop asks its user for up to 2 minutes; an answer without a valid desktop id and a 32-byte secret is `.badResponse`), and with `Authorization: Bearer <secret>` and `X-Device-Id` after it: `GET /v1/health`, `GET /v1/hello`, `PUT /v1/inbox/{id}` (the package as a Data body, so with Content-Length and never chunked, `X-Target`, `Expect: 100-continue` so a refused upload is not sent, and Content-Type `packageContentType` where the C# FakePhone sends none, since URLSession would send a form's; 150 s plus 1 s per MB), `GET /v1/outbox?wait=N` (N clamped to 25; 15 s more than N), `GET` and `DELETE /v1/outbox/{id}`, `DELETE /v1/devices/self`. Every status outside 2xx is a `CompanionClientError` carrying the body's code and message (401 `.unauthorized`, 429 `.rateLimited` with Retry-After or 60, 413 `.tooLarge`, 422 `.invalidPackage`, 409 `busy` `.busy`, any other `.refused`); a transport failure is `.unreachable` with its `URLError`. The phone keeps its desktop in companion-desktop.json (`PairedDesktopStore`, rule 6: id, name, fingerprint as base64url, addresses, port, the phone's id, made once as 32 hex digits and kept when pairing again, when it paired, when it was last seen and the ids of the last 200 outbox items it took) in the folder the shell gives (the iPhone's network folder, out of backups), and the device secret only in a `CompanionSecretStore` (the iPhone's Keychain, `IOSCompanionSecrets`); pairing another desktop replaces it and drops the other's secret. Documents to send wait in `PhoneOutbox` (that folder's "Outbox": the `.csdoc` files and outbox.json with each one's package id, file name, the desktop it is for, target, date, attempts and last error; at most 50, beyond that `PhoneOutboxError.full` with `outboxFullMessage`) until the desktop has them (201, or 200 with `duplicate`) or the user removes them, across launches; it is not called `CompanionOutbox`, the name of the twin of the desktop's (I21). `AppState`: `setUpCompanion(in:secrets:)` (by the shell, once) loads the desktop (`companionStatus` `.checking` until `checkDesktop` runs, `.unpaired` when its secret is gone); `pairDesktop(uri:phoneName:)` parses the code (`PairingUri`'s errors in `errorMessage`), pairs with platform "ios" and the bundle's version, keeps the desktop and its secret, says `pairedMessage` and is `.reachable`; a refusal goes to `errorMessage` with the desktop's own message (`declined`, `tokenExpired`…) and the pairing kept before stays. `checkDesktop()` asks `hello` (`.reachable(desktopName:queuedPages:)`, the name and last-seen time kept on the desktop as it is when the answer comes, so addresses found meanwhile stay; nothing when it was unpaired meanwhile, and no failure is said for a desktop no longer paired). A 401, there or on any request, forgets the secret: `.unpaired(byDesktop:)`, the desktop kept to say which one to pair with again. A desktop that does not answer is `.unreachable` with `companionUnreachableReason`: "This network keeps devices apart (client isolation). Use another Wi-Fi." when the shell's `companionDesktopSeenOnNetwork(desktopId)` says its DNS-SD browser sees the desktop, else "Office PC is not on this network."; nothing is forgotten. `sendQueueToDesktop(target:)` writes the queue with `exportPackage(to:)` into the outbox (the queue stays) and runs `drainOutbox()`, which sends the waiting documents one at a time, oldest first, each under its own package id so sending again is harmless, and each only to the desktop it was queued for (after unpairing, or pairing another desktop, they wait for that one or for Remove): a duplicate counts as sent; a document refused for itself (`.tooLarge`, `.invalidPackage`) stays, marked `refused`, said in `errorMessage` ("Scan 12.csdoc was not sent: …"), and the next one is sent; another error status (`.refused`, a 500 say) is said and passed over the same way but not marked, so the folder still takes it; a desktop that does not answer stops the drain ("Office PC cannot be reached on this network."), and so do busy, rate limited and 401; at the end "Sent 3 pages to Office PC." (the pages the desktop counted) and a `checkDesktop`. `pullFromDesktop()` long-polls the outbox (wait 25) until `stopPulling()`: each item is downloaded into the folder's "Inbox"; a `.csdoc` (by `packageContentType` or its extension) is kept there and offered on the banner with `openPackage(at:)` as one opened by hand once nothing else is offered, oldest first, its file deleted only when the offer is taken or dismissed (so one replaced by a file opened by hand, or not answered before the app ended, is offered again; one that cannot be read is said and deleted); any other file goes to the save folder (`destinationDirectory`, which Files shows on the iPhone) and is said (`receivedMessage`). Once its file is written the item's id is kept on the desktop (`PairedDesktop.received` in companion-desktop.json, the last 200) and the item acknowledged (`DELETE`; a 404 counts), before the offer, which decodes every picture; an item listed again whose id is kept (its acknowledgement failed or was cancelled) is acknowledged again and never downloaded or saved twice. A 401 stops it as `.unpaired`; other failures wait 5 s, then 30 s each time (Retry-After for 429). `CompanionClientTests` (a URLProtocol stub playing the desktop: the pairing request and its headers, hello, an upload's Content-Length and X-Target with 201 then 200 duplicate, 401, 429, the error body's message, a status without a body, the second address and the address in use going away, the outbox's clamped wait, download and ack, unpairing; the pinning on `accepts` with the shared test certificate, since a stub never reaches TLS), `PairedDesktopStoreTests`, `PhoneOutboxTests` and `AppStateCompanionTests` (pairing kept and found again at the next start, a refusal, 401 → unpaired, the two reasons for a desktop that does not answer, the queue sent and the outbox drained, a send that waits for the desktop and then goes as a duplicate, a package pulled, offered and acknowledged, 401 while pulling, unpairing) are Swift only; the loopback against a real TLS server is `CompanionLoopbackTests` (I21). `clearOutbox()` removes what waits, unsent; `desktopFound(id:addresses:port:)` keeps the addresses and port the shell's browse resolved for the paired desktop when they changed (a new DHCP lease: IPv4 first, at most 8, invalid ones dropped) and the pinned certificate answers an anonymous health check there (the TXT `id` is anyone's to advertise), and makes the client anew. **On the iPhone** (`Sources/CompleteScannerIOS/Companion/`, `Views/CompanionScreen.swift`). The secret is a generic password in the Keychain (`IOSCompanionSecrets`: service "com.completescanner.companion", account the desktop's id, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, the data protection keychain; a failed call throws `IOSKeychainError` with its status, said as `notSavedMessage`). `makeForIOS` sets the companion up (`IOSShell.setUpCompanion`) in the network folder (Application Support/CompleteScanner/Network, out of backups) with those secrets. With the app's `IOSCompanionBrowser` (none under `-demoScanner`), `companionDesktopSeenOnNetwork` asks whether the browse saw the desktop's TXT `id`, and a desktop resolved elsewhere goes to `desktopFound`. The browse is `EsclNWBrowser(type: "_completescan._tcp")` with `EsclDnssdResolver`, only while My computer is open or a check runs, each desktop resolved once a browse; Info.plist lists `_completescan._tcp` in NSBonjourServices, and its Local Network and camera usage texts now name the computer and its pairing code (NSAllowsLocalNetworking was there already). Through UIKitLifecycle's hooks: each time the app becomes active with a desktop paired, `pullFromDesktop()` starts, the desktop is checked while the browse runs (one that did not answer is checked again after 3 s more of browsing, since a refusal comes before the browse has seen the desktop), then `drainOutbox()`; a desktop that did not answer and is then found at new addresses is checked and drained there; when the app goes to the background (the hook that means the app may end; there is no resign-active hook) `stopPulling()`. Settings has My computer (`IOSSettingsText.companionLabel`, `settings.companion`), pushing `CompanionScreen` (`IOSCompanionModel`, texts in `IOSCompanionText`). With no computer paired, or one that no longer knows the phone: "Pair with a computer", with `PairingScannerView` (VisionKit's `DataScannerViewController` for QR codes when `isSupported` and `isAvailable`, else an AVCaptureSession with AVCaptureMetadataOutput for `.qr`; camera access asked for the first time, and a refusal or no camera said as our camera says it, `IOSCameraAvailability`; the first text starting with `completescanner://pair?`, in any case, is taken), the "Enter pairing text" field, `PairingUri`'s message for text that is not a code, the check code ("066 051", `SpkiFingerprint.checkCode` of the code's fingerprint) with "Compare with the code on the computer", "Name of this phone" (UIDevice's name to begin with, which iOS gives as the model, "iPhone", to an app without the user-assigned device name entitlement, so it can be changed), and Pair (under that name; "Accept this phone on the computer." while the desktop asks; pulling starts once paired). Once paired: the computer's name, its state (`IOSCompanionText.status`: "Connected", "Connected · 3 pages queued there", or the Kit's sentence; checked when the screen opens and with Refresh), Unpair, and "2 documents waiting to be sent" with Send again (`drainOutbox`) and Remove (`clearOutbox`); Local Network access that is off is said with Open Settings. The scan screen's Save area has Send to computer (`send.computer`) while it collects pages and a computer is paired that still knows the phone (`IOSShell.offersSendToComputer`), asking New document or Into the open document (`CompanionTarget`) and calling `sendQueueToDesktop`; the status line shows the Kit's texts. The privacy manifest is unchanged: the Keychain is not a required-reason API. `IOSCompanionTests`: the Keychain round trip (skipped where the test host has no Keychain entitlement), the pairing text and its check code, `makeForIOS` setting the companion up, pulling from becoming active until the background with the check's reason, the browse's seen ids and a changed address kept, nothing pulled without a desktop, the TXT id, and when Send to computer is offered; `AppStateCompanionTests` adds `clearOutbox`, `desktopFound` (an address where the desktop does not answer not kept), a document kept for another desktop not sent, two packages pulled at once offered one after the other, and another file pulled into the save folder; `CompanionClientTests` adds `Expect: 100-continue` and an upload whose connection broke: not sent again when the hello fails, `.unauthorized` on its 401, the second attempt's answer when it succeeds; `AppStateCompanionTests` also has the ack before the offer and an item listed again acknowledged again, not saved twice. The Simulator has no camera (the scanner view says so and the text is entered below it) and the tests never reach a computer: QR scanning, the Local Network prompt, a real pairing, sending and receiving, and a desktop whose address changed need an iPhone and a PC. Not built yet: a short pairing code to type (the way by hand is the pairing code's text), and Print through my computer.

**The companion server in Swift (I21).** The desktop's side of C1 is shared now (`Companion/CompanionRateLimiter.swift`, `CompanionInbox.swift`, `CompanionOutbox.swift`, `CompanionRouter.swift`, `CompanionNetworks.swift`, `CompanionTroubleshooter.swift`, `CompanionServer.swift`, and `SelfSignedCertificate.swift` for the certificate), twins of the Core files of the same names with the same limits, files (received.json, outbox.json and `<id>.bin` in each phone's folder, companion-networks.json), routes, statuses, headers and error bodies, so a phone cannot tell the Mac from the PC; the Windows server stays the reference. `CompanionOutbox` is the desktop's outbox, served by `GET /v1/outbox`; the phone's documents waiting to be sent are `PhoneOutbox`. Differences from C#: addresses are `NWEndpoint.Host` (an IPv4-mapped IPv6 address counts as its IPv4 address, as `IPAddress.MapToIPv4` does there); the router's events and `Func` properties are closures, `approvePairing` is async and runs in a task that is cancelled when `approvalTimeout` passes or the request is cut off, both of which decline; a request's body is read through a closure the server gives (the connection) instead of a stream; the inbox and outbox answer an id that is not valid with nil or false, and `receive`/`add` throw `.invalidId`, where C# throws `ArgumentException`; the default folders are Application Support/CompleteScanner/Companion/Inbox and Outbox. `CompanionNetwork` is a value the host fills from its interfaces; a system without network categories reports `.publicNetwork`, so it receives only on networks the user allowed (by `CompanionNetwork.id`). `CompanionSnapshot` carries the platform as `DiscoverySnapshot` does: the checks say "this PC" on Windows and "this Mac" on the Mac, a network not received on asks the Mac's user to turn on Allow receiving on this network (no Windows category to change, no action), and the Windows Firewall fields stay `.unknown` there (no check). `CompanionServer` runs one `NWListener` per address (`requiredLocalEndpoint`, the loopback interface only for 127.0.0.1 and ::1; a port of `.any` takes the first listener's port for the others) with `NWProtocolTLS` from the identity's `sec_identity_t` (TLS 1.2 at least, tickets and resumption off). A connection is offered before it is started, so one from a peer `allowPeer` refuses (the host passes `TrustedNetworkPolicy.isAllowedPeer`), from an address the rate limiter blocks, or beyond 8 at once is cancelled before TLS. Every step is bounded: the handshake and the head 10 s each, every body read and response write 30 s; `Expect: 100-continue` is answered when the body is first read, a refused request's body up to 1 MiB is read and dropped before closing, every response closes the connection, and `stop()` lets requests being served finish for 2 s before cutting them off. `SelfSignedCertificate` makes the certificate with a small DER writer (`DerWriter`), since the Security framework makes none: X.509 v3, a random positive 16-byte serial, ecdsa-with-SHA256 signed with `SecKeyCreateSignature`, issuer and subject CN "<host name> CompleteScanner", valid from a day before `now` for 825 days (UTCTime, GeneralizedTime from 2050), basicConstraints CA false and keyUsage digitalSignature (both critical), extKeyUsage serverAuth, and subjectAltName with the host name when it is a DNS name; its SubjectPublicKeyInfo is `SpkiFingerprint.p256SubjectPublicKeyInfo` of the key, so the pin is the key's and a renewed certificate keeps it. `CompanionIdentity` is where the server's `SecIdentity` comes from (made on first use and renewed with the same key; `renew` makes a new key for Reset pairing); the Mac's keychain store implements it with the host. Tests: `CompanionRouterTests` and `CompanionNetworkTests` mirror the C# classes (all of their cases but `Firewall_*`, plus the Mac's wording of the checks); `SelfSignedCertificateTests` (Swift only) has the Security framework read the certificate and its subject, its fingerprint is the key's and survives a renewal, its validity round-trips through the reader, `SecTrust` accepts it with itself as the only anchor, its signature checks with the key, and the DER encodings; `CompanionLoopbackTests` runs the server on 127.0.0.1 against the I20 `CompanionClient` pinned to the certificate's key, the end to end the C# `FakePhone` cases cover for the server: pairing and sending adds the document once, a wrong pin is refused before anything is sent, expired and reused tokens, a removed phone gets 401 while another keeps working, malicious packages are refused and nothing is kept, oversize and chunked uploads are refused without their body (and an upload that waits gets 100 Continue, then 201), plain HTTP gets no answer, repeated wrong secrets are cut off before TLS until the minute is over, and the outbox's long poll reaches the phone. Its identity is fixed, not made per test: a P-256 key and self-signed certificate in PKCS #12 (`Tests/Fixtures/Companion`, `tls-desktop-a.p12`, and `tls-desktop-b.p12` after Reset pairing), imported to memory (`FixtureIdentity`: kSecImportToMemoryOnly on macOS 15, skipped on earlier macOS; the plain import on the iPhone Simulator), because a CI runner's keychain refuses new keys (errSecMissingEntitlement); a test checks both files' SPKI fingerprints. The C# loopback cases about the host are in `CompanionHostTests` (next paragraph).

**The companion host on the Mac (I21).** The rest of the desktop's side is shared too: `Companion/CompanionHost.swift` and `CompanionService.swift` are twins of `CompanionHost.cs` and `CompanionService.cs`, with the same listen states and the same rules: the host listens only while it is wanted (a phone is paired, a code is shown, or a phone that presented the code waits for the answer) and only on the addresses of trusted networks, tries the port used last, then 52731, then any, advertises on each trusted interface only while it listens, withdraws everything when the last trusted network goes, shows no code when nothing can listen (and leaves no session open), and Reset pairing makes the new key first, so a failure changes nothing. Differences from C#: the network source (`CompanionNetworkSource`) and the advertiser (`DnsSdAdvertiser`, whose `register` returns the closure that withdraws) are protocols, and events are closures (`onChange`, `onStatusChange`, `onDevicePaired`, `onPackageReceived`); `DnsSdRegistration` carries no host record (mDNSResponder publishes the Mac's own) and its TXT is a dictionary; the certificate is a `CompanionIdentity`, which can always renew; the app sets `queuedPages`; a failed start says "macOS did not let CompleteScanner listen for phones (…)". The check every 15 s belongs to the Mac's network source, as it belongs to `WindowsNetworkSource`. The server's listeners allow their local endpoint to be reused, so a restart keeps its port while closed connections still hold it, and `stop()` returns once they have let go of their sockets (2 s at most). The Mac's rule for networks: macOS has no network categories, so every network is `.publicNetwork` and needs the user's approval once (Allow receiving on this network in the Phone window), kept in companion-networks.json by the network's id: the interface's BSD name, its IPv4 subnet and the NetworkSignature of the interface's IPv4 service from SystemConfiguration, the router's address and hardware address ("en0 192. A network whose signature is not known yet (no router, or the system has not published it) has no id and cannot be approved, so an approval never carries over to another network on the same interface and subnet.168.1.0/24 IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=…"), so another network that hands out the same subnet needs its own approval. Each subnet is also its own adapter (`adapterId` is the network's id), so an untrusted subnet on the same interface does not shut out an approved one. The host scopes each address it listens on to its adapter's interface and the server pins that listener to it (`requiredInterface`), since macOS takes a packet for one of its addresses on any interface; Windows does not. `MacNetworkSource` (`CompleteScannerMac/App/`) reads the interfaces with getifaddrs (up and running, IPv4; loopback interfaces and link-local addresses never count), names each network by its interface ("Wi-Fi (192.168.1.0/24)", from SystemConfiguration), and follows `NWPathMonitor` and a check every 15 s. `MacDnsSdAdvertiser` registers `_completescan._tcp` with TXT `v` and `id` through `DNSServiceRegister` on each trusted interface with the server's port; `NWListener.Service` would advertise from the server's listeners, one per address with no interface of their own. `CompanionCertificateStore` keeps a permanent P-256 key in the login keychain (application tag `com.completescanner.companion`, label "CompleteScanner companion") and its `SelfSignedCertificate` under the same label (CN "<local host name> CompleteScanner"), paired into a `SecIdentity` by `SecIdentityCreateWithCertificate`: made the first time a code is shown, renewed with the same key 60 days before it ends, and replaced by a new key on Reset pairing, the old certificates and keys deleted only once the new one is in the keychain. One copy of the app receives, the one holding an flock on Companion/companion.lock; another reports `.elsewhere`. The app's side is `AppState+CompanionHost.swift`, the twin of `AppViewModel.Companion.cs`: `setUpCompanionHost(_:)` (from `makeForMac`, with the settings folder for companion-devices.json and companion-networks.json and Application Support/CompleteScanner/Companion, kept out of backups, for Inbox and Outbox) starts the host when a phone is paired, `ensureCompanionHost()` when the Phone window opens, and `companionHostStatus` follows it. `confirmPhonePairing` asks the Phone window (the pairing is allowed when it is not set, and declined when the asking task is cancelled, as the router does after 2 minutes). A phone's document is decoded (`PendingPackage.read`), made the queue's pages as `CompanionPages.ToScannedPages` does (a document sent as new starts a document of its own under its name) and queued through `ingestPages` as `.phone` pages when `canTakePhonePages` (the queue collects pages with Collect pages before saving on, and `canIngest`); otherwise it waits with `phoneDocumentsWaitingMessage` (on the bar unless the app is busy) and is tried again every second and when the running work ends. Once added, the status says "2 pages from Aytu's iPhone added to the queue. 3 in queue.", `phoneBarMessage` shows its first sentence on the bar under the tab bar (`PhoneBarView`: announced, and the Dock icon bounces when the app is in the background) and the package leaves the inbox; a package with a picture that cannot be read is dropped with a message, and one that cannot be read now stays to be added at the next start. The Phone window (`CompleteScannerMac/UI/PhoneView.swift`) is a sheet from the sidebar's Phone button, as the troubleshooter is: the headline, the networks with their toggles (and a note that macOS may ask once for local network access), Pair a phone with the QR code (`CoreImageQrEncoder`, whole pixels per module, drawn without interpolation), its countdown, the address, the code in groups of four and the check code, Stop pairing, the Allow / Don't allow question, the paired phones with Remove, the connection checks (`CompanionTroubleshooter` for the Mac, the troubleshooter's cards), Refresh and Reset pairing after a confirmation; closing it closes the pairing code. The Mac app's Info.plist (`scripts/make_app.sh`) has `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_completescan._tcp`): macOS 15 asks for Local Network access the first time the app listens and advertises. Tests: `CompanionHostTests` runs the host's C# loopback cases (nothing listens until a phone is paired or a code is shown, the listener stops when the network is no longer trusted and comes back on the same port once it is allowed, only trusted interfaces are listened on and advertised, Reset pairing changes the key and unpairs everyone, a phone waiting for the answer keeps the host listening, a declined phone stops the listening it kept up, pairing without a trusted network leaves no session, Reset pairing without a new key changes nothing), over stand-ins for the network source and the advertiser and with the keychain test identity (skipped as the server's loopback tests are); its second network is ::1, since macOS has no 127.0.0.2 unless it is added. `CompanionCodeTests` checks the code's addresses and name without the keychain. `AppStateCompanionHostTests` checks a phone's document becoming queue pages with the bar's text, joining the current document, and waiting while the app is busy and while the settings do not collect pages. The keychain store, the interfaces, DNS-SD and the Phone window are not unit-tested.

**The cloud sync folder (C2).** When the phone and the desktop cannot reach each other (client isolation on a school or café network), the phone puts its documents, sealed, into a folder the user syncs through iCloud Drive or OneDrive (any folder works; those two are the ones named), and the desktop watches the same folder and takes them as if they had been uploaded. **The key:** a desktop that has the folder makes a 32-byte random sync key for each phone it pairs and hands it out once, as `PairResponse.syncKey` (base64url; left out of the JSON when there is none, and nil from a desktop from before C2, so such a phone simply has no folder). It never goes in a file in the clear: Windows keeps it in companion-devices.json as `syncKeyProtected`, protected with the Data Protection API for the current user (`ProtectedData`, `DataProtectionScope.CurrentUser`, the one package Core references, called on Windows only); the Mac keeps it in its Keychain through `CompanionServiceOptions.syncKeyStore` (a `CompanionSecretStore` keyed by the phone's id; without one no key is made); the phone keeps it in its Keychain next to the device secret, under "<desktopId>.sync". The device secret cannot be the key: the desktop keeps only its hash. Pairing the same phone again keeps its key, so what it put in the folder before still opens; removing a phone, the phone leaving, Reset pairing and a 401 on the phone drop it on the side concerned, and a pairing after that makes a new one; a key that cannot be kept only leaves that phone without the folder. **The file:** "<packageId>.cssync" (the outbox item's id, `CompanionProtocol.isValidId`): the 8 ASCII bytes "CSSYNC01", a 16-byte header (version 1, target 0 new or 1 current, two reserved zero bytes, a 12-byte random nonce), then the `.csdoc` encrypted with AES-256-GCM under the sync key and its 16-byte tag; the associated data is the magic and header, the package id's UTF-8, a zero byte and the phone's id's UTF-8, so a file renamed, put under another phone or changed in any byte does not open (`SyncPackage`, twins with a golden vector pinned on both sides; Swift through CryptoKit's `AES.GCM`, C# through `AesGcm`). Opening refuses a file over `maxUploadBytes` + 64 bytes (`tooLarge`), one too short or without the magic (`notASyncPackage`), a newer version (`newerVersion`) and anything the key does not open (`wrongKeyOrTampered`); sealing refuses a package over `maxUploadBytes`. **The phone:** the folder is a bookmark in companion-desktop.json (`PairedDesktop.syncFolderBookmark`, kept when the same desktop is paired again), opened through `AppState.resolveSyncFolderBookmark`, which the iPhone's shell sets as it does for the save folder. `drainOutbox` sends over the network first; when the desktop does not answer and it handed out a key and a folder is set, every document waiting for it is sealed and written into the folder as "<id>.cssync", whole (an atomic write inside a coordinated write, `NSFileCoordinator` with `.forReplacing`, so iCloud Drive and other providers take it up), and stays in the outbox marked `inSyncFolder` ("Put Scan 12 in the cloud folder for Office PC.", "Put 3 documents in the cloud folder for Office PC."). A later round drops it once its file has left the folder (the desktop deletes what it took; listed in a coordinated read, an iCloud ".<name>.icloud" placeholder counting as there), or sends it over the network when the desktop answers and then deletes its file from the folder, so a document whose file the desktop can no longer open (its key dropped since) still gets there; choosing another folder, or none, sends those again. A document the desktop refused for itself (413 or 422; `PhoneOutboxItem.refused`, also set when it is too large to seal; another error status leaves it unset) never goes into the folder, and one that cannot be put there does not keep the others out; with a key and no folder the status adds, once a session, "Set a cloud folder in My computer to send when the PC cannot be reached."; without a key nothing changes. A folder that does not open ("The cloud folder could not be opened. Choose it again in My computer.") or a write that fails leaves the document waiting with `viaSyncFolder`, so the next round tries the folder first and the network only when no folder can be used. **The desktop:** the folder is a path in companion-devices.json (`syncFolder`, "" for none; `CompanionService.setSyncFolder`), watched while the companion service runs (`SyncFolderWatcher`: a poll every 5 s, plus a FileSystemWatcher on Windows and a DispatchSource on the Mac that look at once and again after 2 s). A "*.cssync" file is taken once its size has stayed the same for 2 s: read whole (which downloads a OneDrive or iCloud placeholder; a read that fails is tried on the next poll), opened with each paired phone's key in turn (the associated data binds the phone, so the first key that opens it names the phone), skipped and deleted when that phone's received.json has its id already (it came over the network, or from the folder before), else received into the inbox exactly as an upload (`CompanionInbox.receive`, the same checks, the target from the header, received.json), handed to `PackageReceived`/`onPackageReceived` as an upload is, so the same bar, waiting and release follow, and deleted from the folder. A file no paired phone's key opens, or whose package is refused, is left where it is and said once while it stays unchanged: "A file in the cloud folder could not be read: <name>. <reason>" (`SyncFolderWatcher.unreadableMessage`; `SyncFolderProblem`/`onSyncFolderProblem`, the Mac's status line); it is read again only when its size or modification date changes or 60 s after it was last tried (`retryTime`/`RetryTime`, on the watcher's clock), not on every poll. A phone whose key cannot be read (`PairedDeviceStore.syncKey(for:)` throws the store's error, a locked or refused keychain; C# `SyncKey` throws `CryptographicException`) is said once, until its key reads again: "The key for <phone name> could not be read, so files from it cannot be opened. Pair the phone again." (`keyUnreadableMessage`/`KeyUnreadableMessage`), and skipped for the rest of that poll; a file no key opened while a key was skipped is not said (it may be that phone's) but waits the same 60 s. `SyncPackageTests`, `SyncFolderWatcherTests`, and the new cases of `CompanionProtocolTests` and `PairedDeviceStoreTests` are the same on both sides (C#: the watcher's and the key's cases run on Windows only, where the Data Protection API is); `PhoneOutboxTests`, `PairedDesktopStoreTests` and `AppStateCompanionTests` (Swift only) cover the phone. On the Mac, the keys are generic passwords in the login keychain (`MacCompanionSyncKeys`, service "com.completescanner.companion.sync", account the phone's id; legacy keychain items, as for `CompanionCertificateStore`, since an app built with swift build has no keychain entitlement). The Mac's Phone window has the Windows Cloud folder section: the folder with Choose… (an open panel starting in the folder, else in iCloud Drive when it is set up) and Clear (files already there stay), "Watching <path>.", "Waiting for <path>: the folder is not there now.", "Not watching: no folder chosen." or "Not watching." without the service, and the last file that could not be read (`AppState.syncFolderProblem`, cleared by `setPhoneSyncFolder`, the twin of C# `SetPhoneSyncFolder`; it goes to the status line too). The connection checks on both desktops add the tip `phoneSyncFolder` ("Phone has not reached this PC lately?", "this Mac" on the Mac) when a phone is paired, no folder is chosen and no paired phone has been seen for `quietTime` (`CompanionSnapshot.syncFolderChosen`, and `phonesQuietFor` from the latest `lastSeen`). On the iPhone, My computer shows a Cloud folder section for a desktop that handed out a key: Choose… (a folder picked in Files, kept as a security-scoped bookmark and opened by `IOSSyncFolder` the way `IOSSaveFolder` opens the save folder, both through the internal `IOSBookmarkedFolder`), Clear, and the line "A folder in iCloud Drive or OneDrive that your computer also syncs. Documents go here, encrypted, when the computer cannot be reached." (`CompanionText.syncFolderLine`); under the waiting documents (which include those in the folder until the desktop has them), "2 documents in the cloud folder" counts the "*.cssync" files the folder still holds, listed in a coordinated read (the desktop deletes each once taken; those of another phone syncing the same folder count too). When the desktop is seen on the network but does not answer and a folder is set, the phone's status says "This network keeps devices apart (client isolation). Documents go to the cloud folder instead." (`CompanionText.clientIsolationSyncFolderReason`) rather than suggesting another Wi-Fi. On Windows the Phone window has the same Cloud folder card between Paired phones and Connection checks (the tip says to choose a folder above): the hint, the path, Choose… (`OpenFolderDialog`) and Clear, the same status lines (the buttons disabled and "Not watching." while the link runs in another window), and the last file that could not be read in red (`AppViewModel.SyncFolderProblem`, set from `CompanionService.SyncFolderProblem` on the UI thread and put in `StatusMessage` too); `AppViewModel.SetPhoneSyncFolder(path)` saves the folder through the service, clears the problem and returns false when it could not be saved, which the footer says ("The setting could not be saved."). In the paired phones on both desktops, a phone without a sync key that reads now (paired before the cloud folder; `PairedDeviceStore.hasSyncKey(_:)`, C# `HasSyncKey`) has the caption "Pair again to use the cloud folder" under it.
```csharp
public enum SyncPackageErrorKind { NotASyncPackage, NewerVersion, WrongKeyOrTampered, TooLarge }
public sealed class SyncPackageException : IOException { SyncPackageErrorKind Kind; }
public static class SyncPackage {                       // FileExtension "cssync", Version 1, KeyByteCount 32, NonceByteCount 12,
                                                        // TagByteCount 16, HeaderByteCount 16, Magic "CSSYNC01"u8
    static long MaxFileBytes;                           // MaxUploadBytes + 64
    static byte[] Seal(string packageId, string phoneId, CompanionTarget target, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> key
                       [, ReadOnlySpan<byte> nonce]);    // a random nonce unless given (tests)
    static (CompanionTarget Target, byte[] Plaintext) Open(ReadOnlySpan<byte> data, string packageId, string phoneId, ReadOnlySpan<byte> key);
    static string FileName(string packageId);
    const string NotASyncPackageMessage, NewerVersionMessage, WrongKeyMessage;
}
public sealed class SyncFolderWatcher : IDisposable {   // PollInterval 5 s, SettleTime 2 s
    SyncFolderWatcher(string folder, PairedDeviceStore devices, CompanionInbox inbox, Func<DateTimeOffset>? clock = null);
    string Folder; event EventHandler<CompanionPackageReceivedEventArgs>? PackageReceived; event EventHandler<string>? Problem;
    void Start(); Task PollAsync(); void Dispose(); static string UnreadableMessage(string fileName, string reason);
}
// PairedDevice.SyncKeyProtected; PairedDevicesFile.SyncFolder; PairedDeviceStore.SyncKey(id) (throws CryptographicException), SyncFolder, SetSyncFolder(path)
// PairResponse(..., string? SyncKey = null); CompanionService.SyncFolder, SetSyncFolder(path), event SyncFolderProblem
```

**The .csdoc file on the desktop and the phone (I18).** A `.csdoc` opened by hand is offered, not added: `openPackage(at:)` (C# `AppViewModel.OpenPackage(path)`, `windows/CompleteScanner.App/AppViewModel.Package.cs`) reads it off the main thread through `CompanionPackage` (the zip limits, a newer `formatVersion` refused with `newerVersionMessage`, a picture that cannot be decoded, or whose header claims more than `PhotoImport.maxPhotoPixels` (C# `PendingPackage.Decode`), with `PackageText.unreadablePictureMessage`) and sets `pendingPackage` (C# `PendingPackage`) to its file name, its pages and its document's name (`suggestedName`, else the title), replacing one offered before; the file opened last is the one offered (a read that ends after a later open is dropped), and Windows' Add to pages clears only the offer it took; the queue is not touched, so it works while a scan runs. The pages are C1's (`CompanionPages.ToScannedPages` for a document added to the current one: the rotation applied, `source == .phone`, side and sheet, the picture as photographed as the other version, the capture facts), decoded when the file is opened. Add to pages (`addPendingPackageToPages`) puts them after the queued pages with no document break or name; Open as new (`openPendingPackageAsNew`) clears the queue and adds them with the document's name on the first page; both wait (the offer stays) while something runs or a review is open, and say `PackageText.notOfferedMessage` while the settings do not collect pages (`PhotoImport.isOffered` with `documentMultiPage` on, C# `CollectsPackages`: without it `ingest` would save the pages at once). The Mac and the iPhone add them through `ingest(_:source: .phone)`, so its status and history follow; Windows spools them as C1 does and says `CompanionProtocol.addedMessage` with the file's name ("3 pages from Receipt.csdoc added to the queue. 5 in queue."). `dismissPendingPackage` drops the offer. `exportPackage(to:)` (C# `ExportPackage(folder)`, built on `CompanionPages.ToDocument`) writes the queue as one `.csdoc` in a folder, named as the next saved file would be (the running number read, not taken), each page as shown at full resolution, a black & white page as a bilevel TIFF and the others as a JPEG at the settings' quality (Windows: a gray page as a gray JPEG), with side, sheet and capture facts, and returns the file; a spooled page whose file went meanwhile (the queue saved or cleared) is refused ("Page 2's picture could not be written.") rather than written from its preview; document breaks, recognized text and the pictures as photographed are not carried yet. A paired phone's uploads keep C1's automatic adding. `PackageAppTests` (C#, the pieces without the view model, which reads the user's settings) and `AppStatePackageTests` (Swift, through `AppState`) share the cases of reading, the refusals (newer format, a picture that cannot be read or claims too many pixels) and the written document (black & white as TIFF, side and sheet); adding, Open as new, waiting and a spooled page that went are Swift only, the extension check C# only; that C# reads what Swift writes is the golden package (`CompanionPackageTests`: Swift writes its pinned bytes, C# reads them). On the Mac a `.csdoc` opened from the Finder (`onOpenURL`, taken by the open window through `handlesExternalEvents`), dropped on the scanner view (photos dropped with it are imported, so such a drop is refused while photos cannot be taken) or picked with Import photos of documents (its panel takes `.csdoc` too; photos picked with it are imported as before) calls `openPackage(at:)`, and `PackageBannerView` shows the offer under the tab bar on every tab: "Opened Receipt.csdoc: 3 pages", Add to pages and Open as new (disabled while `canIngest` is false) and a close button (`dismissPendingPackage`). The bundled app (`scripts/make_app.sh`) exports the type `com.completescanner.package` (extension `csdoc`, conforming to `public.data` and `public.content`) and opens it as its Owner; `swift run` registers no type, so the Finder does not offer it there. File > Import from iPhone or iPad (`ImportFromDevicesCommands`, Continuity Camera) hands its pictures to `importsItemProviders([.image])` on the window, which writes each to a file in the temporary folder and imports the files as dropped photos (`importPhotos`: page found, corner editor, `source == .photo`); while something runs, before or after the pictures come over, they are refused and said in `errorMessage`, since the menu cannot see the state. On the iPhone and iPad (`Sources/CompleteScannerIOS`) the app exports the same type in `ios/CompleteScanneriOS/Info.plist` (`UTExportedTypeDeclarations`: `com.completescanner.package`, extension `csdoc`, conforming to `public.data` and `public.archive`; a `CFBundleDocumentTypes` entry with `LSHandlerRank` Owner) and `IOSShell.packageType` names it. `IOSShell.isPackage(_:)` (the extension, any case) routes a file: one opened in the app (AirDrop, Files, Mail: the root view's `onOpenURL`) or picked with Files (its picker takes `packageType` too) never goes into a task's import; `IOSShell.openPackage(_:in:)` copies it, through its security scope and a coordinated read (`IOSPDFAppend.access`), into a folder of its own in the temporary folder, calls `openPackage(at:)` on the copy and deletes it, and a file that cannot be copied says `PhotoImport.unreadableMessage`. The root view sets up Document to PDF when no task is set up (a task set up is kept) and shows the scan screen, whose bottom bar shows the offer above the status line (`PackageBanner`: "Opened Receipt.csdoc: 3 pages", Add to pages and Open as new, disabled while `canIngest` is false, and a close). Beside Save, while the screen collects pages (`IOSShell.collectsPages`), a share button (`IOSShell.sharePackageLabel`, "Share as CompleteScanner document") runs `IOSShell.sharePackage(_:)`: the folder `packageShareFolder` ("Shared documents" in the temporary folder) emptied, `exportPackage(to:)` into it, then `runFileAction(.share)` with the file, so its name is the settings' naming template's ("Lunch.csdoc"); a refusal goes to `errorMessage`, and Save waits while the file is written. `IOSPackageTests` cover the routing, the shared file's name and opening a package written in a test folder through the shell. The privacy manifest is unchanged. A `.csdoc` dropped on the iPad's scan screen is not taken yet (`IOSDroppedFile` takes PDFs and pictures). On Windows (`MainWindow.Package.cs`, `MainWindow.Import.cs`) a `.csdoc` given on the command line (the first one: File Explorer passes it), dropped anywhere on the window or picked with Import photos (its picker lists photos and `*.csdoc` together, then `*.csdoc` alone) calls `OpenPackage`; a drop with a `.csdoc` is always taken on its own, even while work runs or the queue collects no pages; photos dropped or picked with it are imported as before, so a drop holding both waits until photos can be taken; only the first `.csdoc` is opened. A bar in the saved bar's style, under the phone's, shows while `PendingPackage` is set: `PackageText.OpenedMessage` ("Opened Receipt.csdoc: 3 pages") with Add to pages, Open as new and Dismiss, announced to screen readers when a new package is offered; the two buttons are greyed out while `CanTakePhonePages` is false, except where the settings collect no pages and nothing runs, where a click says `NotOfferedMessage`. `Services/FileAssociation.cs` writes the per-user association at each start, off the UI thread, and only the values not already right: under HKCU\Software\Classes, `.csdoc` → `CompleteScanner.Package` ("CompleteScanner document", `DefaultIcon` `"<exe>",0`, `shell\open\command` `"<exe>" "%1"`, the exe being the one that runs), then tells File Explorer (`SHChangeNotify`); HKLM is never touched, a policy that keeps the user's classes read-only leaves them as they were, and since the app has no installer nothing removes them. The app has no single instance, so a file opened from File Explorer while it runs opens in a new window. `FileAssociationTests` check the entries and write them under a scratch key of HKCU\Software, removed afterwards; the bar itself is not tested (the view model reads the user's settings).

### Escl/ (the eSCL protocol, I10: Escl/EsclCapabilities.swift, EsclScanRequest.swift, EsclStatus.swift, EsclRetry.swift, EsclTxtRecord.swift, ScannerAddress.swift, EsclEndpoint.swift, EsclHostList.swift, EsclTrust.swift, EsclXml.swift)

```swift
public struct EsclFormatError: Error, Equatable, LocalizedError { public let message: String }   // C#: FormatException
public struct EsclInputCaps: Equatable { maxSizeInches, minSizeInches: CGSize?; resolutions: [Int]; colorModes, documentFormats: [String] }
public struct EsclCapabilities: Equatable {        // defaultAreaInches 8.5 × 11.7, fallbackResolutions [75, 150, 200, 300, 600]
    public var version, makeAndModel, uuid: String?; public var platen, adfSimplex, adfDuplex: EsclInputCaps?; public var supportsDuplex: Bool
    public var hasPlaten: Bool; public var hasAdf: Bool; public var feeder: EsclInputCaps?   // adfSimplex ?? adfDuplex
    public func inputCaps(_ source: ScanSource) -> EsclInputCaps?
    public func toScannerCapabilities() -> ScannerCapabilities
}
public enum EsclCapabilitiesParser {               // XMLParser (XMLDocument is macOS only); elements matched by local name
    public static func parse(_ xml: String) throws -> EsclCapabilities; public static func parse(data: Data) throws -> EsclCapabilities
}
public struct EsclRegion: Hashable { xOffset, yOffset, width, height: Int }   // 1/300 inch, top-left
public struct EsclScanRequest: Equatable {         // maxFeederHeightInches 17
    public var inputSource, colorMode, documentFormat: String; public var resolution: Int; public var region: EsclRegion; public var duplex: Bool
    public static func create(_ caps: EsclCapabilities, source: ScanSource, colorMode: ColorMode, dpi: Int, selection: CGRect?,
                              duplex: Bool = false, paperSize: PaperSize = .auto) -> EsclScanRequest   // C#'s Math.Round: halves to even
    public func toXml() -> String                  // the same bytes as C# ToXml ("\n" line breaks, Duplex after the resolutions)
}
public enum EsclJob {
    public static func resolveLocation(_ scanJobs: URL, _ location: String?) -> URL?   // absolute, host-relative or relative; no trailing slash
    public static func nextDocument(_ job: URL) -> URL
}
public struct EsclScannerStatus: Equatable { state, adfState: String?
    public static func parse(_ xml: String) -> EsclScannerStatus?; public static func parse(data: Data) -> EsclScannerStatus?
    public func problem(_ source: ScanSource) -> ScannerProblem? }   // feeder state first for feeder jobs, then the device state
public struct EsclRetryPolicy: Equatable {         // seconds; .default: 0.5, ×1.5, at most 5, give up after 60
    initialDelay, multiplier, maxDelay, giveUpAfter; public func delayBefore(_ retry: Int, retryAfter: TimeInterval? = nil) -> TimeInterval }
public enum EsclRetry {
    public static func isRetryable(_ statusCode: Int) -> Bool   // 503 only
    public static func send<Response>(_ request: () async throws -> Response, statusCode: (Response) -> Int,
                                      retryAfter: (Response) -> TimeInterval?, policy: EsclRetryPolicy = .default,
                                      delay: ((TimeInterval) async throws -> Void)? = nil,
                                      elapsed: (() -> TimeInterval)? = nil) async throws -> Response
    // C#'s SendAsync over HttpResponseMessage; here over any response, so the URLSession layer (I11) plugs in. Real time is
    // ProcessInfo.systemUptime (SystemBootTime 35F9.1) and Task.sleep; a cancelled task stops with CancellationError.
}
public struct EsclTxtRecord: Equatable {           // resourcePath ("eSCL"), model, uuid, adminUrl, version, note, duplex: Bool?,
    public static func parse(_ attributes: [String]?) -> EsclTxtRecord   // inputSources, colorSpaces, documentFormats
    public static func uuidKey(_ uuid: String?) -> String?
}
public struct ScannerAddress: Hashable, CustomStringConvertible {   // == and hash: the canonical text, ignoring case
    public let secure: Bool; public let host: String; public let port: Int; public let resourcePath: String
    public var defaultPort: Int; public var authority: String       // "host:port", IPv6 in brackets with its zone
    public var baseURLText: String; public var baseURL: URL?        // C#'s BaseUri.AbsoluteUri, except an IPv6 zone is kept as "%25" + zone (RFC 6874)
    public var description: String                                  // C#'s ToString: the canonical text of escl-hosts.json
    public static func create(secure: Bool, host: String, port: Int, resourcePath: String) -> ScannerAddress?
    public static func parse(_ text: String) throws -> ScannerAddress   // EsclFormatError with the C# messages
    public static func tryParse(_ text: String?, error: inout String) -> ScannerAddress?
}
public struct EsclService: Equatable { id, instanceName: String; secure: Bool; hostName: String?; addresses: [String]; port: Int; textAttributes: [String] }
public struct EsclEndpoint: Equatable { key, name: String; txt: EsclTxtRecord; addresses: [ScannerAddress]; uuid: String?
    public static func choose(_ services: [EsclService]) -> [EsclEndpoint] }
public final class EsclHostList {                  // fileName "escl-hosts.json"; init(directory:); fileURL
    public func loadEntries() -> [String]; public func load() -> [ScannerAddress]
    public func add(_ address: ScannerAddress) -> Bool; public func remove(_ address: ScannerAddress) -> Bool
}
public enum EsclTrustVerdict: String { case unknown, trusted, changed, invalid }
public struct EsclTrustedCertificate: Codable { fingerprint, deviceUuid: String; addresses: [String]; name: String; trusted: Date? }
public struct EsclTrustFile: Codable { certificates: [EsclTrustedCertificate] }   // escl-trust.json, rule 6
public struct EsclTrustCheck: Equatable { verdict: EsclTrustVerdict; previous: EsclTrustedCertificate? }   // C#: Check's out parameter
public enum EsclTrustStoreError: Error { case noCertificate }   // C#: ArgumentException
public final class EsclTrustStore {                // fileName "escl-trust.json", maxAddresses 8; init(directory:)
    public func check(_ fingerprint: String, deviceUuid: String?, authority: String) -> EsclTrustCheck
    public func trust(_ fingerprint: String, deviceUuid: String?, authority: String, name: String) throws
    public var certificates: [EsclTrustedCertificate] { get }
}
public struct EsclCertificateError: Error, LocalizedError, Equatable {   // C#: EsclCertificateException, the same messages
    verdict, deviceName, deviceUuid, authority, fingerprint, subject, previous; canTrust; message }
public enum EsclCertificates {
    public static func fingerprint(certificateDER: Data) -> String?   // SpkiFingerprint.of, lowercase hex (C#: from an X509Certificate2)
    public static func format(_ fingerprint: String, bytesPerLine: Int = 0) -> String
}
public final class EsclCertificateValidator {      // init(store:deviceUuid:deviceName:firstUse:)
    public func validate(url: URL?, certificateDER: Data?, subject: String, systemTrusted: Bool) -> Bool
    //   C#: Validate(Uri?, X509Certificate2?, SslPolicyErrors); the TLS hook (C#: CreateHandler) comes with the client (I11).
    //   A certificate whose key cannot be found by the DER walk is refused as .invalid.
    public func rememberDevice(_ deviceUuid: String?) throws; public func takeRejection() -> EsclCertificateError?
    static func authorityOf(_ url: URL) -> String
}
// Internal helpers: EsclXmlElement and EsclXml (the XMLParser tree: child, descendants, value, text), EsclResolutions (C#'s
// ResolutionList.Build without a preferred list or optical resolution, ExpandRange), EsclHostText (normalizeHost, ipv4, ipv6
// with inet_pton/inet_ntop and if_nametoindex for a named zone, isDnsName: Uri.CheckHostName's rules), EsclIPv6Address, EsclUrlParts and EsclUrlText (URL text
// split by hand: split, removeDotSegments, escapePath, authority), and StoreFiles.load in Persistence/PresetStore.swift.
```
Twins of `windows/CompleteScanner.Core/Escl/EsclCapabilitiesParser.cs`, `EsclScanRequest.cs` (with `EsclJob`), `EsclStatus.cs`, `EsclRetry.cs`, `EsclTxtRecord.cs`, `ScannerAddress.cs`, `EsclEndpoint.cs`, `EsclHostList.cs` and `EsclTrust.cs`, Foundation only, building for macOS and iOS. `EsclTests`, `EsclRetryTests`, `EsclDiscoveryTests` and `EsclTrustTests` are the same cases on both sides, a C# theory being one Swift test over the same rows; both suites read `Tests/Fixtures/Escl` (the C# project copies it next to its assembly, the Swift suite finds it from `#filePath`, on the Mac and in the iOS Simulator): the four capability documents, the two request snapshots (`request-platen-color.xml`, `request-feeder-two-sided.xml`, compared byte for byte), the HP TXT record, three self-signed certificates (RSA-2048, P-256, P-384) whose SubjectPublicKeyInfo SHA-256 both suites check (`SpkiFingerprintTests.SharedScannerCertificates_HaveTheSharedFingerprints`, and in `EsclTrustTests`), and a trust file written by each platform. `.gitattributes` there keeps the files byte for byte (no line-ending conversion). The client and session have Swift twins since I11 (see "Escl/EsclClient.swift, EsclScannerSession.swift, EsclScannerBackend.swift" below): `EsclClientTests` are the same 18 cases on both sides, and the two `EsclTrustTests` cases through a real TLS connection (`AFirstUseCertificateIsPinnedOnlyOnceItsUuidIsChecked`, `HttpsConnectsOnlyOnceTheCertificateIsTrustedAndRefusesAChangedOne`) are twinned in `EsclLoopbackTests`; their validator rules are also checked without TLS on both sides (`TheValidatorPinsAFirstUseCertificateOnlyOnceItsUuidIsChecked`). An IPv6 zone is an interface number or the name of an interface on the device (`%en0` on Apple platforms, `%ethernet_32769` on Windows), read as its number with `if_nametoindex` as .NET does and kept as that number; a zone that is neither (a name no interface has, a number beyond 32 bits) makes the address invalid, where `IPAddress.TryParse` alone would drop the zone without a word (C#'s `ScannerAddress.ParseIPv6`, Swift's `EsclHostText.ipv6`; discovery skips such addresses too). Deliberate differences: `baseURLText` keeps an IPv6 zone (System.Uri drops it from the text, keeping it in `DnsSafeHost`); inputs only System.Uri reads its own way (IPv4 parts with leading zeros or fewer than four parts inside an http(s) URL, which .NET reads as octal or packed numbers) are read as plain decimal or refused here. The iPhone app offers network scanners since I12 (see "Escl/EsclDiscovery.swift, EsclNetworkServices.swift" below); the Mac keeps ImageCaptureCore.

### Escl/EsclClient.swift, EsclScannerSession.swift, EsclScannerBackend.swift (the network scanner connection, I11)

```swift
public struct EsclClientOptions {                  // C#: EsclClientOptions, plus the C# constructor's handler and decoder
    public var requestTimeout: TimeInterval        // 10 s: capabilities, status, DELETE
    public var jobTimeout: TimeInterval            // 120 s: the job's POST and each NextDocument
    public var connectivityWait: TimeInterval      // 60 s: how long the client's first capabilities request waits for a network
    public var retryPolicy: EsclRetryPolicy        // .default
    public var delay: ((TimeInterval) async throws -> Void)?; public var startClock: (() -> (() -> TimeInterval))?   // fake clocks in tests
    public var configuration: URLSessionConfiguration?   // copied; nil = .ephemeral (tests add a URLProtocol stub)
    public var pageDirectory: URL?                 // where pages are downloaded; nil = AppStateFiles.standard.spoolDirectory
    public var readPage: ((URL) throws -> CGImage)?   // nil = EsclPageReader.read (ImageIO, decoded at once)
    public init(requestTimeout: TimeInterval = 10, jobTimeout: TimeInterval = 120, connectivityWait: TimeInterval = 60,
                retryPolicy: EsclRetryPolicy = .default)
}
public struct EsclJobResult: @unchecked Sendable { public let pages: [ScannedPage]; public let stop: ScanStop? }
public struct EsclHttpError: Error, Equatable, LocalizedError, Sendable { public let statusCode: Int }   // C#: HttpRequestException
public enum EsclPageReader { public static func read(_ file: URL) throws -> CGImage }
public final class EsclTrustDelegate: NSObject, URLSessionTaskDelegate {   // C#: EsclCertificateValidator.CreateHandler
    public init(validator: EsclCertificateValidator?)
    // urlSession(_:task:didReceive:completionHandler:): server trust -> validator.validate(url: the task's URL, certificateDER: the leaf
    //   (SecTrustCopyCertificateChain), subject: SecCertificateCopySubjectSummary, systemTrusted: SecTrustEvaluateWithError);
    //   accepted: .useCredential; refused: .cancelAuthenticationChallenge (nothing is sent). No validator: default handling.
    // urlSession(_:task:willPerformHTTPRedirection:...): never from HTTPS to plain HTTP.
}
public final class EsclClient {
    public init(baseURL: URL, deviceName: String, validator: EsclCertificateValidator? = nil, options: EsclClientOptions = EsclClientOptions())
    public func getCapabilities() async throws -> EsclCapabilities        // URLError, EsclHttpError, EsclFormatError or EsclCertificateError
    public func getProblem(_ source: ScanSource) async throws -> ScannerProblem?   // nil when the status says nothing; throws only CancellationError
    public func scan(_ request: EsclScanRequest, colorMode: ColorMode, source: ScanSource,
                     progress: ((ScanProgress) -> Void)?, suspended: (() -> Bool)? = nil) async throws -> EsclJobResult
    public func abandonJob()                       // the app is being suspended: the job under way is deleted now
    public func whenCleanedUp() async              // the deletions started so far have finished
}
@MainActor public final class EsclScannerSession: ScannerSession {
    public init(info: ScannerInfo, client: EsclClient, capabilities: EsclCapabilities, background: (any BackgroundActivity)? = nil)
    public let esclCapabilities: EsclCapabilities; public let client: EsclClient; public let background: (any BackgroundActivity)?
}
@MainActor public final class EsclScannerBackend: ScannerBackend {
    public init(trust: EsclTrustStore, endpoints: [EsclEndpoint], clientOptions: EsclClientOptions = EsclClientOptions(),
                background: (any BackgroundActivity)? = nil)
    public static func endpoint(_ address: ScannerAddress) -> EsclEndpoint   // key: the address's text; name: its host
    public var confirmCertificate: ((EsclCertificateError) async -> Bool)?
    public func openSession(deviceID: String, interactive: Bool) async throws -> any ScannerSession   // openSession(deviceID:) = interactive false
    public func trustCertificate(_ certificate: EsclCertificateError, deviceUuid: String?, name: String)
}
```
Twins of `windows/CompleteScanner.Core/Escl/EsclClient.cs` and `EsclScannerSession.cs`, with the same rules and the same 18 cases (`EsclClientTests`, on a `URLProtocol` stub here): the job's POST must answer 201 with a `Location`; `NextDocument` is pulled until 404, which finishes the job (not deleted); 503 answers are retried (`EsclRetry`), and a 503 that outlasts them is `busy`; a failure before the first page fails the scan with the scanner's status problem when it names one (an empty feeder after a job without pages), after it the pages are kept with a `ScanStop`; every other way out (an error, a cancel, a batch cut short, the app suspended) deletes the job on the scanner. The POST is never cancelled: a cancel stops the wait and the job is deleted once its address arrives. URLSession has an ephemeral configuration (no cache, no cookies): requests time out after `requestTimeout` and job requests after `jobTimeout` (`URLRequest.timeoutInterval`); `waitsForConnectivity` is on only for the client's first capabilities request (its own session, `connectivityWait`); the transport never sends the POST twice (only a 503 answer, which created no job, is asked again, as on Windows). Deliberate differences from C#: each page is downloaded (`URLSession.download`) into `pageDirectory`, the app's page spool, read once by `readPage` and its file removed, so a page's compressed bytes are never in memory next to its pixels; `ScanError.scannerProblem` carries no detail, so the "(HTTP 409)" of the C# message is only in a stopped batch's `reason`; the session's job also stops when the system's background time runs out (below). `EsclScannerSession` matches C# (`Scanning…`, `Scanning overview…`; the overview on the flatbed in color at the first resolution of at least 150 dpi; `lastScanDuplex` from the capabilities for a two-sided feeder scan; `close()` releases the connection once a cancelled job has wound down).

**The background time (iPhone).** Each job of an `EsclScannerSession` with a `background` asks it for time (`BackgroundActivity.beginActivity("Scanning on <name>")`), so a page in flight and the deletion of a job cut short finish when the user switches apps; the time is given back once the job and its deletion are done. When the system's time is nearly up (`UIKitBackgroundActivity` checks `backgroundTimeRemaining` every second and tells the work to stop at `windDownTime`, 10 s, rather than at UIKit's expiration, which would leave no time to send anything), the session marks the job suspended, sends the deletion at once (`abandonJob`) and cancels the job; the time is given back only once the deletion has been answered (`whenCleanedUp`), or when UIKit's own expiration ends it as a last resort: the pages received are kept with the stop `ScanStop(reason: describe(.appSuspended), problem: .appSuspended)` ("Scanning stopped after 3 pages; they were kept. The system suspended CompleteScanner in the background before the scan finished. …"), or the scan fails with `ScanError.scannerProblem(.appSuspended)` before the first page. Windows never produces `appSuspended`; its text, title ("App suspended") and advice are shared (`TroubleshootingTests`).

**Trust.** `EsclScannerBackend.openSession` is the twin of the Windows backend's `OpenSessionAsync`: the scanner's addresses in order; a certificate seen for the first time is accepted for one capabilities request (`firstUse`) and pinned with the UUID the scanner reports (`rememberDevice`), unless that UUID belongs to a scanner trusted with another key (`changed`); a `changed` certificate is offered to `confirmCertificate` only when `interactive`, trusted when the user agrees and the same address tried again; any other refused certificate fails the connection and never falls back to a later plain-HTTP address. Addresses that do not answer are collected into `ScanError.sessionFailed("<name> did not answer (<address>: <reason>; …).")`. A TLS failure that is not about trust (an old TLS version, a handshake error: `URLError` `.secureConnectionFailed`, `.clientCertificateRejected`, `.clientCertificateRequired`, `EsclScannerBackend.isTLSFailure`) counts as an address that did not answer, so the next address is tried, which may be the scanner's own advertised HTTP address (decided in I12, as Windows does it): a session opened over plain HTTP for a scanner that has an HTTPS address is "Not encrypted" (`isNotEncrypted(deviceID)`, `notEncryptedLabel`; the picker's row and the scan screen show it, devices.txt lists it). A refused certificate never leads there: it ends the connection. The device list: one entry per UUID (`"escl:" + EsclTxtRecord.uuidKey(uuid)`, else `"escl:" + endpoint.key`), transport "Network", backend "escl", the TXT model and the UUID as `hardwareID`, as on Windows: the endpoints it was made with, then the discovered ones, then the addresses added by hand (I12, below); nothing while not browsing.

**Tests.** `EsclClientTests` (the 18 C# cases), `EsclLoopbackTests` (an `NWListener` on 127.0.0.1 only, never advertised, serving the fixtures' PKCS #12 identities `tls-scanner-a.p12` and `tls-scanner-b.p12` over TLS; the two C# TLS cases, a full feeder job through `AppState` with first-use trust, cancel mid-job with the DELETE, the app suspended mid-job, the background time given back, and a refused certificate that never falls back to plain HTTP), `IOSNetworkScannerTests` (UIKit's background tasks, the shell's entry point), on the Mac and in the iOS Simulator (loopback needs no Local Network permission). On the Mac the identities are imported into memory only (`kSecImportToMemoryOnly`, macOS 15); earlier systems skip those tests. C#'s `EsclTrustTests.TheLoopbackIdentitiesHaveTheirFingerprints` checks the identities' fingerprints too. Real scanners (`_uscan` and `_uscans`), a first certificate and a changed one after a factory reset need a real iPhone.

### Escl/EsclDiscovery.swift, EsclNetworkServices.swift and the iPhone's scanner screens (I12)

```swift
public struct EsclBrowseResult: Hashable, Sendable {      // what a browser reports: name, type, domain, interfaceIndex, txt ("key=value", key order)
    public var secure: Bool { get }                        // _uscans
    public var key: String { get }                         // name.type.domain, lowercase: the EsclService id
}
public enum EsclBrowserStatus: Equatable, Sendable { case setup, ready, waiting(code: Int32?, detail: String), failed(code: Int32?, detail: String), cancelled }
public struct EsclResolvedService: Equatable, Sendable { hostName: String?; port: Int; addresses: [String] }   // "fe80::1%4": the interface as the zone
public enum EsclResolveOutcome: Equatable, Sendable { case resolved(EsclResolvedService), failed(String), denied }
public enum EsclLocalNetwork { public static let policyDeniedCode: Int32 /* -65570 */; public static func isPolicyDenied(_ code: Int32?) -> Bool }
@MainActor public protocol EsclCancellable: AnyObject { func cancel() }
@MainActor public protocol EsclServiceBrowsing: AnyObject { var secure: Bool { get }; var onStatus, onResults; func start(); func cancel() }
@MainActor public protocol EsclServiceResolving: AnyObject {
    func resolve(_ result: EsclBrowseResult, completion: @escaping @MainActor (EsclResolveOutcome) -> Void) -> any EsclCancellable }
@MainActor public final class EsclDiscovery {
    public init(makeBrowser: @escaping @MainActor (Bool) -> any EsclServiceBrowsing, resolver: any EsclServiceResolving,
                carryTime: TimeInterval = 5, schedule: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil)
    public var onChange: (() -> Void)?
    public var services: [EsclService] { get }             // resolved, in the order first reported (the Windows EsclService values)
    public var status: DiscoveryStatus { get }             // off, denied, unavailable, searching, running
    public var failure: String? { get }; public var statusLine: String { get }; public var unresolvedLines: [String] { get }
    public var firstSearchTime: TimeInterval               // 5: after start or resume, still looking although the browsers are ready
    public var isLooking: Bool { get }                     // searching or running, and within firstSearchTime of start or resume, or a resolve under way
    public func start(); func stop(); func pause(); func resume(); func restart(); func reportDenied()
}
@MainActor public final class EsclNWBrowser: EsclServiceBrowsing { public init(secure: Bool)   // NWBrowser .bonjourWithTXTRecord, peer-to-peer off, main queue
    public init(type: String) }                    // I20: another service type (_completescan._tcp), secure false
@MainActor public final class EsclDnssdResolver: EsclServiceResolving { public init(); public var timeout: TimeInterval /* 5 */; public var settleTime: TimeInterval /* 1 */ }

public struct EsclAddressCheck: Equatable, Sendable { address; capabilities; certificate: EsclCertificateError?; error: String?; var noAnswer: Bool }
extension EsclScannerBackend {   // since I12, beside the I11 members
    public init(trust: EsclTrustStore, endpoints: [EsclEndpoint] = [], hosts: EsclHostList? = nil, discovery: EsclDiscovery? = nil,
                clientOptions: EsclClientOptions = EsclClientOptions(), background: (any BackgroundActivity)? = nil)
    public let discovery: EsclDiscovery?; public let hosts: EsclHostList?; public var reprobeInterval: TimeInterval   // 60
    public var onDiscoveryChanged: (() -> Void)?; public var discoveryStatus: DiscoveryStatus { get }
    public var isSearching: Bool { get }                   // discovery.isLooking while browsing in front with the network allowed
    public private(set) var isNetworkAllowed: Bool; public func holdNetwork(); public func allowNetwork()
    public func suspendBrowsing(); public func resumeBrowsing()
    public func checkAddress(_ address: ScannerAddress, firstUse: String? = nil) async throws -> EsclAddressCheck   // throws only CancellationError
    @discardableResult public func addAddress(_ address: ScannerAddress, capabilities: EsclCapabilities) -> String
    public func manualAddresses(_ deviceID: String) -> [ScannerAddress]; public func removeAddress(_ address: ScannerAddress)
    public func isNotEncrypted(_ deviceID: String) -> Bool; public static let notEncryptedLabel: String   // "Not encrypted"
    // ScannerBackendDiagnostics: addStatus(to:), rescan(), diagnosticsReport
}
// Core/ScannerBackend.swift: ScannerBackend gains openSession(deviceID:interactive:) (default: openSession(deviceID:)); AppState
// opens the scanner the user picks (userSelectDevice) interactively, so a network scanner's changed certificate is asked about then only.
// userSelectNoDevice(resetsManualSides: Bool = true) (the iPhone's camera as the source; the Mac never calls it): no scanner,
// none selected on its own until the user picks one, the status "Ready"; with resetsManualSides, turning over by hand (.manual)
// back to .both once the session has closed (at once when none was selected). The phone's own deselect while it waits for the
// scanner picked as its source passes false, so a hand-turned job keeps its sides.
// A scanner the app opened on its own whose changed certificate was refused (EsclCertificateError, canTrust) is handled as the
// Windows AppViewModel does: kept out of preferredDefaultDevice for the session (certificateRefused, cleared once it opens), the
// error gets " To review the new certificate, choose the scanner in the list.", and the app moves on to the preferred scanner
// (the demo scanner when none) unless the user picked it.
```
**Discovery.** Swift only (the Windows search is its own app's device watcher), in the Kit (Network and dnssd are on the Mac too, which does not use them). One `NWBrowser` per service type (`_uscans._tcp`, `_uscan._tcp`, `.bonjourWithTXTRecord`, `includePeerToPeer` false, on the main queue), the TXT record read from the result's metadata (`NWTXTRecord.dictionary`, as "key=value" entries in key order). Every new instance is resolved with the DNS-SD C API (`EsclDnssdResolver`: `DNSServiceResolve` for the host and port, then `DNSServiceGetAddrInfo` for IPv4 and IPv6, the interface index as a link-local address's zone; its answer once the first address has had a second for the others, or "no answer in time" after five; Apple's documentation lists these calls as available, not deprecated, so the NWConnection fallback the plan kept in reserve, which reaches one address only, is not needed); the host name's trailing dot is dropped, as Windows reports it. A service is listed (`services`) once resolved, as the `EsclService(id:instanceName:secure:hostName:addresses:port:textAttributes:)` Windows makes, and the backend merges them with `EsclEndpoint.choose`. A browser's list replaces what it reported before: an instance it no longer reports is gone (its resolve stopped); a changed TXT record is taken without resolving again; a late answer of a resolve for an instance gone, or resolved again, is dropped. The troubleshooter's state: `.off` before the start and while paused, `.searching` until both browsers are ready (a browser waiting for another reason, such as no network yet, is still searching), `.running`, `.unavailable` when a browser failed (`failure`, `statusLine` "unavailable (…)"), `.denied` (below); Refresh (`restart`) starts again a browser that failed and resolves again what could not be, leaving a working or denied browser alone. **Local Network permission.** There is no API to read or request it (TN3179); a refusal is inferred: a browser waiting or failing with `kDNSServiceErr_PolicyDenied` (-65570), a resolve refused with it, or a connection waiting with the path's `unsatisfiedReason` `.localNetworkDenied` (`IOSLocalNetworkProbe`, a TCP connection opened only after an address the user typed found no scanner, closed at once) all make the search `.denied` until a browser is ready again (the system retries by itself once access is granted). The iPhone shows, before the first search, the explanation card ("Find scanners on your Wi-Fi", "CompleteScanner talks only to devices on your network.", Continue: `IOSNetworkScanners.needsExplanation`, the defaults flag `localNetworkExplained`), so the system's prompt (`NSLocalNetworkUsageDescription`, `NSBonjourServices` `_uscan._tcp` and `_uscans._tcp`) comes when the user expects it: until it is read, `EsclScannerBackend.holdNetwork()` keeps the search and the checks of the addresses added by hand from starting (`allowNetwork()` starts them); a refusal shows one line, "Local Network access is off.", with Open Settings, and the troubleshooter's "localNetwork" problem; the app never asks again with its own UI. **In front only.** The search runs only while the app is in front: going to the background pauses it (`suspendBrowsing`, `EsclDiscovery.pause`: the browsers and resolves stop, what was found stays listed, so a selected scanner is not lost), coming back resumes it (new browsers; what they have not reported again within `carryTime`, 5 s, is dropped then) and checks the addresses added by hand again. Nothing is ever advertised or registered. **Addresses added by hand.** As on Windows: `checkAddress` (the Windows wording: "No scanner answered at <address> (it answered, but not like an eSCL scanner / it answered HTTP 404 / it did not answer in time / the system's text)."), `addAddress` (escl-hosts.json, listed under the scanner's UUID, joining its discovered entry), `removeAddress`, `manualAddresses`; while browsing, every address in the file is checked, those that do not answer again every `reprobeInterval` (60 s) until they do, a check overtaken by an add or a removal of its address dropped; a certificate seen for the first time on such a check is trusted once the scanner's UUID shows it is not a changed one; the troubleshooter gets each checked address (`ManualHostStatus`) and devices.txt the lines Windows writes. **Add by address on the iPhone** (`IOSAddScannerModel`, `AddScannerView`): the Windows dialog's title, line, placeholder, ⓘ text and messages (`ScannerAddress.tryParse`); a certificate seen for the first time is trusted without asking (trust on first use, the plan's decided default, unlike the Windows dialog, which asks), a changed one is asked about (`CertificateChangedView`: both fingerprints, 8 bytes a line, monospaced, Cancel and "Trust the new certificate"); when nothing answers, `IOSLocalNetworkProbe` tells a refused Local Network access apart (the line and Open Settings); closing the sheet abandons the check, and nothing is added or trusted after it. Under `-demoScanner` there is no network connection: a valid address says "Network scanners are off in demo mode." **The picker** (`IOSScannerPickerModel`, `ScannerPickerList`): a sheet on iPhone (the scan screen's scanner row, `scanner.menu`), a sidebar beside the scan screen on iPad (regular width); the explanation card, the denied line, one row per scanner (`IOSScannerRow`: the name, `DeviceMerge.connectionLabel` as Windows labels connections, "Not encrypted" after it when so, a check mark on the chosen one, Remove address in its context menu and swipe actions when an address added by hand reaches it), "Looking for scanners…" with a spinner (`showsSearching`: only the demo scanner listed and `EsclScannerBackend.isSearching`, i.e. within the first 5 s of the search, or of its resumption when the app is in front again, or while a service found resolves), else "No scanner found" with Troubleshoot while only the demo scanner is listed, Add by address, Troubleshoot. Picking a row opens the scanner interactively (a changed certificate asks then: `IOSNetworkScanners.certificateQuestion`, the root view's sheet). **The scan screen** (network parts): Preview while the flatbed is used (`AppState.performOverview`); the preview in the scrolling column only shows the scan area (`FlatbedThumbnail`, nothing to drag, so a swipe on it scrolls), and tapping it or Choose area opens it full screen (`CropScreen`, a full-screen cover; neither while the feeder is the source, when the column shows the last scan and the area waits for the flatbed, `IOSShell.showsFlatbedPreview`, as on the Mac) with the area to edit (`FlatbedPreview`: drag to make it, inside to move it, a corner to resize it, at least 4 % a side, kept on the glass; `IOSCropGeometry` mirrors the Mac's preview canvas, whose selection logic is in its own file; the area is `AppState.selectionRect`, which the next flatbed scan uses), a Presets menu (whole glass, top, bottom, left or right half) and Done; for VoiceOver and Full Keyboard Access the area is one element whose value says its size and place in percent, swipe up or down makes it larger or smaller by 5 % a side, and its actions (`IOSCropCommand`) choose a preset or move it by 5 %; Clear selection beside Preview; while a job runs, its progress (`AppState.progress`: the client's "Transferring page 3…", which counts a feeder's pages) with Cancel, which deletes the job on the scanner (I11), and the screen kept on (`UIApplication.isIdleTimerDisabled`, `IOSShell.keepsScreenAwake`: busy with a network scanner); the pages go into the queue as a scan's do. **Shell** (`IOSShell.backends(options:networkScanners:)`, `AppState.makeForIOS(options:fileActions:networkScanners:)`): the app makes `IOSNetworkScanners()` (the files in Application Support/CompleteScanner/Network, kept out of backups; the search; UIKit's background time) only when launched without `-demoScanner`; with it (the UI tests) there is no network connection at all, so nothing is ever searched for, and `backends(options:)` stays the demo scanner alone for tests and previews. **Tests.** `EsclBrowsingTests` (13 cases over stand-in browsers and resolvers: the two browsers, resolving every address, both services of one scanner as one endpoint, gone instances, late answers, TXT changes, failed resolves and Refresh, the denial from a browser, a resolve or a connection, a failed browser, pause and resume, still looking, stop), `EsclScannerBackendTests` (escl-hosts.json round trip, re-checks and the troubleshooter's checks, the Windows messages, a discovered scanner and its address as one entry, nothing before the network is allowed, suspend and resume, "Not encrypted" after a TLS failure, the diagnostics, the iPhone's `AppState`, a changed certificate on a scanner the app chose), `IOSScannerPickerTests` (rows, the card, "Looking for scanners…" before "No scanner found", the denial with Settings, the background, the certificate question, add by address: messages, trust on first use, a changed certificate, a refused Local Network access; the shell under `-demoScanner`; the screen kept awake; the troubleshooter service; the crop, by dragging and by its commands), the UI test `ScannerPickerTests` (the picker with the demo scanner and the add sheet's message for a bad address, without any network). The permission prompt, a denial and access granted again, client isolation, IPv6, real TXT records and a feeder batch while the app goes to the background need a real iPhone and scanner.

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
`AppState` keeps the presets (`presets`, `applyPreset`, `saveCurrentAsPreset(named:)`, `deletePreset(id:)`, and since I15 `renamePreset(id:to:)`, which trims the name, refuses a blank one or a preset that is gone and returns whether it renamed; Swift only, as the Windows app renames none) and writes them through the store at each change. Storage: JSON under `~/Library/Application Support/CompleteScanner/` (`presets.json`, `settings.json`). The file plumbing (`StoreFiles`, `StoreReadResult`) is internal to the module so other settings files follow the same rules (`PairedDeviceStore`'s `companion-devices.json`); `StoreFiles.write` returns whether the file was written.

### Output/PDFBuilder.swift

```swift
/// A page's text layer: called with its index and its prepared page (full pixels, rotation
/// applied, full-resolution size) before it is stored; nil writes none.
public typealias PDFTextLayer = (_ index: Int, _ page: PDFBuilder.PreparedPage) -> [OCRLine]?

public enum PDFBuilder {
    public struct PreparedPage { image: CGImage; pixelWidth: Int; pixelHeight: Int }
    /// The spill file's full pixels with the page's rotation, else the in-memory image; the size
    /// from the recorded full-resolution size. Twin of C# `PdfBuilder.PreparePage`.
    public static func preparePage(_ page: ScannedPage) -> PreparedPage
    /// Multi-page PDF; each page sized pixels/dpi*72 points. When `searchable`, run OCR per page
    /// (on the full pixels) and write an invisible text layer aligned with the words. Each page
    /// image is stored as `pdfSize` plans it (`storedImage`).
    public static func makePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                               pdfSize: PDFSizePreset = .best,
                               progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws -> Data
    /// Same, but written to `url` (created or replaced).
    public static func writePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                                pdfSize: PDFSizePreset = .best,
                                to url: URL, progress: ((String) -> Void)?,
                                shouldContinue: (() -> Bool)? = nil) throws
    /// The text layer read beforehand: `ocrLines[i]` on page `i` (nil, or past the end: none). No OCR runs.
    public static func makePDF(pages: [ScannedPage], ocrLines: [[OCRLine]?], pdfSize: PDFSizePreset = .best,
                               progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws -> Data
    public static func writePDF(pages: [ScannedPage], ocrLines: [[OCRLine]?], pdfSize: PDFSizePreset = .best,
                                to url: URL, progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws
    /// Each page's text layer from `textLayer` (none when nil): the app's one OCR pass per save;
    /// PDF/A or a password as `options` ask (nil: a plain PDF; see `PDFWriter.write`).
    public static func makePDF(pages: [ScannedPage], pdfSize: PDFSizePreset = .best, progress: ((String) -> Void)?,
                               shouldContinue: (() -> Bool)? = nil, textLayer: PDFTextLayer?,
                               options: PDFWriteOptions? = nil) throws -> Data
    public static func writePDF(pages: [ScannedPage], pdfSize: PDFSizePreset = .best, to url: URL,
                                progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil,
                                textLayer: PDFTextLayer?, options: PDFWriteOptions? = nil) throws
}
```
The `searchable:` overloads are kept for existing callers (OCR on every page when searchable). The app saves through the `textLayer:` overload so OCR reads each page once per save, for the text layer and for the text file beside the PDF (`output.alsoSaveText`). Windows has no twin of these overloads: its view model reads the pages with OCR and hands `PdfBuilder` the lines in `PdfPageInput`.

Every overload writes through the port of the C# writer, `PDFWriter` (I5 took the plan's recommendation: the CoreGraphics PDF context and its CoreText text layer are gone from saving), so every PDF the Mac and the iPhone save has the structure Windows writes: one stored image a page (the planned JPEG, CCITT G4 for a page scanned in black & white), the text layer in the embedded `GlyphLessFont`, PDF/A-2b or AES-256 as the options ask. Like the Windows view model, the pages are prepared, read and encoded one at a time (`pageInputs`), then written, so the stored images of a document are held until it is written. CoreGraphics still draws what is printed (`PrintDocument`); the separator sheet saved to print elsewhere is a plain PDF through `PDFWriter` (a gray JPEG at quality 0.9, as Windows writes it), never PDF/A or protected.
```swift
extension PDFBuilder {   // internal, for the tests
    static func writesG4(_ pages: [ScannedPage]) -> Bool          // any page scanned in black & white
    /// Twin of the Windows view model's PdfPageInputs: prepared page, its text layer, the stored image.
    static func pageInputs(_ pages: [ScannedPage], pdfSize: PDFSizePreset, progress: ((String) -> Void)?,
                           shouldContinue: (() -> Bool)?, textLayer: PDFTextLayer?) throws -> [PDFPageInput]
    /// Black & white: downsampled to the plan (box filter), Bilevel.pack, G4. Others: encodedPage's JPEG,
    /// else a JPEG of the pixels at the size's color quality. Nil when the pixels cannot be read or encoded.
    static func storedImage(_ prepared: PreparedPage, colorMode: ColorMode, dpi: Int,
                            pdfSize: PDFSizePreset) -> PDFImageData?
}
```

### PDF/A-2b and the Unicode text layer (M19: Windows; the Mac and the iPhone since I4 and I5)

The Swift port of the C# PDF writer is complete (I4, I5): the object writer, the plain PDF and its
Unicode text layer in the embedded `GlyphLessFont`, PDF/A-2b and protected files, byte for byte as
Windows writes them (below). Every PDF the Mac saves goes through it (`PDFBuilder`, above), so the
archival option and the Archive document task work on the Mac as on Windows.

```swift
// OutputOptions has `archival: Bool` ("archival" in the "output" object; false by default and for
// files written before it existed; a wrong-typed value reads as false). TaskCatalog.apply turns it
// on for the Archive document task only, which also turns `protect` off.
```
The C# side, which the Swift port mirrors name for name and byte for byte:
```csharp
public enum PdfConformance { Standard, PdfA2b }          // first member = default
public sealed record PdfWriteOptions {                     // PdfWriteOptions.Standard = a plain PDF
    PdfConformance Conformance; string? Title; DateTimeOffset? CreationDate /* null: now */;
    byte[]? DocumentId /* 16 bytes; null: random */; bool IsArchival;
    static PdfWriteOptions For(OutputOptions output, string? title);   // archival from the setting
}
public sealed class PdfObjectWriter {                      // header, numbered objects, streams, classic xref
    PdfObjectWriter(Stream); long Position; void WriteHeader(string version);
    void BeginObject(int n); void EndObject(); void WriteObject(int n, string value);
    void WriteStream(int n, string entries, ReadOnlySpan<byte> data);  // "<<entries /Length n>>", Length last
    void Finish(string trailerEntries);                    // throws on a gap or a repeated number
}
public static class GlyphlessFont {                        // the text layer's font, built from code
    const string FontName = "GlyphLessFont"; const int UnitsPerEm = 1000, GlyphWidth = 500, CodeCount = 0x10000;
    static byte[] Program;        // TrueType, 636 bytes, SHA-256 103B87CF…C391 (GlyphlessFontTests pins it)
    static byte[] CidToGidMap;    // zlib by hand (fixed Huffman, no library), 837 bytes, SHA-256 2B554AAC…E17E
    static byte[] Build();  static double TextWidth(int codeCount, double fontSize);   // codes × 0.5 × size
}
public sealed class GlyphlessCodes {                       // one document's character codes
    const int FirstSupplementaryCode = 0xD800, SupplementaryCapacity = 0x800, ReplacementCode = 0xFFFD;
    static GlyphlessCodes For(IEnumerable<string> texts); IReadOnlyList<int> Supplementary;
    List<int> Codes(string text); string HexString(string text); string ToUnicodeCMap();
}
public static class PdfA {
    const string Producer = "CompleteScanner", OutputConditionIdentifier = "sRGB IEC61966-2.1";
    const string OptionLabel = "Archival PDF (PDF/A)", OptionHint, OptionHelp, NotWithPasswordReason = "Not with a password";
    const string CannotProtectNote = "PDF/A can't be password-protected.";
    static readonly byte[] SrgbProfile;     // sRGB-v2-magic.icc, Compact-ICC-Profiles, CC0 1.0, 736 bytes, SHA-256 AF4EFE28…05F4
    static string PdfDate(DateTimeOffset);  // "D:20261019213005+03'00'"
    static string XmpDate(DateTimeOffset);  // "2026-10-19T21:30:05+03:00"
    static string TextString(string);       // "(ASCII)" with \ ( ) escaped, else "<FEFF…>" UTF-16BE
    static string CleanTitle(string);       // drops control characters, U+FFFE/FFFF, lone surrogates
    static string InfoDictionary(string? title, DateTimeOffset date);
    static byte[] Xmp(string? title, DateTimeOffset date);   // UTF-8, no BOM, xpacket header without bytes/encoding
    static string OutputIntents(int profileObject);
}
// PdfBuilder.Make / Write / WriteFile / WriteNewFile gain a last optional `PdfWriteOptions? options`.
```
The Swift twins (names in Swift case, `GlyphlessCodes.For` is `of`, `PdfWriteOptions.For` is
`forOutput`; a `DateTimeOffset` is a `Date` with the `TimeZone` whose offset it is written with;
misuse throws `ScanError.exportFailed` where C# throws argument, invalid-operation, disposed or
cryptographic exceptions):
```swift
public final class PDFObjectWriter {                       // Output/PDFObjectWriter.swift
    public init(encryption: PDFEncryption? = nil, output: @escaping (Data) throws -> Void)  // every byte, in order
    public let encryption: PDFEncryption?
    public private(set) var position: Int
    public func writeHeader(_ version: String) throws; func beginObject(_ number: Int) throws; func endObject() throws
    public func writeObject(_ number: Int, _ value: String) throws
    public func writeStream(_ number: Int, _ entries: String, _ data: Data) throws   // "<<entries /Length n>>", encrypted when the file is
    public func asciiString(_ text: String) throws -> String                         // "(text)" escaped; encrypted hex in an encrypted file
    public func finish(_ trailerEntries: String) throws     // throws on a gap; a repeated number throws when written
    public func writeBytes(_ bytes: Data) throws; func writeASCII(_ text: String) throws
}
public enum GlyphlessFont {                                 // Output/GlyphlessFont.swift
    static let fontName = "GlyphLessFont", unitsPerEm = 1000, glyphWidth = 500, codeCount = 0x10000
    static let program: [UInt8]       // 636 bytes, SHA-256 103B87CF…C391 (as C#)
    static let cidToGidMap: [UInt8]   // its own Deflate (fixed Huffman), 837 bytes, SHA-256 2B554AAC…E17E (as C#)
    static func build() -> [UInt8]; static func textWidth(codeCount: Int, fontSize: Double) -> Double
}
public final class GlyphlessCodes {
    static let firstSupplementaryCode = 0xD800, supplementaryCapacity = 0x800, replacementCode = 0xFFFD
    static func of(_ texts: [String]) -> GlyphlessCodes; var supplementary: [Int]
    func codes(_ text: String) -> [Int]; func hexString(_ text: String) -> String; func toUnicodeCMap() -> String
}
public enum PDFConformance: String, CaseIterable, Sendable { case standard, pdfA2b }   // Output/PDFA.swift
public typealias PDFRandomSource = (_ count: Int) throws -> [UInt8]                   // C#'s Action<Span<byte>>
public struct PDFWriteOptions: @unchecked Sendable {        // PDFWriteOptions.standard = a plain PDF
    var conformance: PDFConformance; var title: String?; var creationDate: Date? /* nil: now */
    var timeZone: TimeZone? /* nil: the current one */; var documentId: [UInt8]? /* 16 bytes; nil: random */
    var protection: PDFProtection?; internal var random: PDFRandomSource?   // tests; nil: SecRandomCopyBytes
    var isArchival: Bool; var isProtected: Bool
    init(conformance: = .standard, title: = nil, creationDate: = nil, timeZone: = nil, documentId: = nil, protection: = nil)
    static func forOutput(_ output: OutputOptions, title: String?, protection: PDFProtection? = nil) throws -> PDFWriteOptions
}
public enum PDFA {
    static let producer, outputConditionIdentifier, optionLabel, optionHint, optionHelp, notWithPasswordReason, cannotProtectNote: String
    static let srgbProfile: [UInt8]   // the same 736 bytes, SHA-256 AF4EFE28…05F4 (PDFATests pins it)
    static func pdfDate(_ date: Date, timeZone: TimeZone) -> String; static func xmpDate(_ date: Date, timeZone: TimeZone) -> String
    static func textString(_ text: String) -> String; static func cleanTitle(_ title: String) -> String
    static func infoDictionary(title: String?, date: Date, timeZone: TimeZone) -> String
    static func xmp(title: String?, date: Date, timeZone: TimeZone) -> Data
    static func outputIntents(_ profileObject: Int) -> String
}
public enum PDFImageData: Equatable, Sendable {             // Output/PDFWriter.swift
    case jpeg(Data); case ccittG4(data: Data, width: Int, height: Int)
    var data: Data; static func encodeCCITTG4(_ image: RgbaImage) -> PDFImageData   // C# PdfCcittImage.Encode
}
public struct PDFPageInput {                                // C# PdfPageInput
    image: PDFImageData; pixelWidth, pixelHeight, dpi: Int; ocrLines: [OCRLine]?; var jpegData: Data
    init(image:pixelWidth:pixelHeight:dpi:ocrLines:); init(jpegData:pixelWidth:pixelHeight:dpi:ocrLines:)
}
public enum PDFWriter {                                     // C# PdfBuilder's object level
    static func make(_ pages: [PDFPageInput], progress: ((String) -> Void)? = nil,
                     shouldContinue: (() -> Bool)? = nil, options: PDFWriteOptions? = nil) throws -> Data
    static func writeFile(_ pages: [PDFPageInput], to url: URL, progress:, shouldContinue:, options:) throws  // streamed
    static func write(_ pages: [PDFPageInput], progress:, shouldContinue:, options:, to output: @escaping (Data) throws -> Void) throws
    // internal, as in C#: writePage, imageEntries, writeTextFont, textLayerLine (PlacedLine), f (C#'s "0.####")
}
```
`shouldContinue` returning false before a page throws `ScanError.cancelled` (C#'s cancellation
token); `progress` hears "Writing page n of m…". Numbers are written as C#'s `ToString("0.####",
CultureInfo.InvariantCulture)` writes them: 15 significant digits rounded half up at the fourth
decimal, a negative value that rounds to 0 as "-0" (checked against .NET on 200,000 values).
- **Object numbers, fixed order:** 1 Catalog, 2 Pages; when any page has text, 3–8 the font (Type0, CIDFontType2, FontDescriptor, FontFile2, CIDToGIDMap, ToUnicode); for PDF/A, the Info dictionary, the XMP Metadata and the ICC profile; for a protected file, the Encrypt dictionary; then Page, Image and Contents per page. A document without text has no font objects and no `/Font` resource.
- **Plain PDFs** stay `%PDF-1.4` with no Info, Metadata, OutputIntents or `/ID`; only their text layer changed (below).
- **PDF/A-2b:** `%PDF-1.7` and the binary comment line; the catalog's `/Metadata` (unfiltered XMP: `pdfaid:part 2`, `pdfaid:conformance B`, `dc:format`, `dc:title` x-default, `xmp:CreateDate` = `ModifyDate` = `MetadataDate`, `xmp:CreatorTool`, `pdf:Producer`) and `/OutputIntents` (`/GTS_PDFA1`, the sRGB profile with `/N 3`); an Info dictionary that says exactly the same (`/Title`, `/Producer`, `/Creator`, `/CreationDate`, `/ModDate`, whole seconds with the local offset); `/ID [<id> <id>]` in the trailer (a new UUID's bytes when none is given); no encryption, no `/Interpolate`, no LZW. The title is the file name without its extension: when `WriteNewFile` is given that title and another writer takes the name while the PDF is being built, the file goes to the next free " 2", " 3", … name and is rewritten in place titled with that name (a failed rewrite leaves the complete file with the requested title); any other title is kept as given. The Mac titles each PDF with the name `AppState` chose for it, and replaces the file at that name (`writePDFAtomically`). The JPEG pages (`/DeviceRGB`, `/DeviceGray`) are covered by the output intent.
- **The text layer (every PDF):** the embedded `GlyphLessFont` replaces Helvetica/WinAnsi, so no character turns into "?" any more. Type0 with `/Encoding /Identity-H` over a CIDFontType2 with `/DW 500` and a `/CIDToGIDMap` that sends every code to glyph 1 (never .notdef); FontDescriptor `/Flags 5 /FontBBox [0 0 500 1000] /Ascent 1000 /Descent -1 /CapHeight 1000 /StemV 80` (the descent is -1, not the program's 0, because PDFKit reads no text from a font whose descriptor and `hhea` table both give a descent of 0). A BMP character is its UTF-16 code unit; each character beyond the BMP gets a code from D800 in order of first use (2048 at most, the rest and lone surrogates U+FFFD), and the ToUnicode map gives it back as its pair (`bfchar`), next to 248 identity ranges `<XX00> <XXFF> <XX00>` that skip D8–DF, in blocks of at most 100. Each line: `/F1 <box height> Tf`, `Tz` = box width ÷ (codes × 0.5 × size) × 100 clamped to 20–500, `1 0 0 1 <box left> <box bottom> Tm`, the codes as a hex string, `Tj`, all in `3 Tr`. The font size is the box's height and the baseline its bottom edge, so a selection covers the box.
- **Golden bytes** (`PdfATests`, `PDFATests` and `PDFWriterTests`): a dated, identified one-page Letter PDF/A with a Turkish line is 11497 bytes, SHA-256 `D643A7AA…6370`; the same line as a plain two-page PDF is 9866 bytes, SHA-256 `7364F912…2594` (full values in the tests). The Swift port writes both byte for byte (`PDFATests.test_archival_goldenBytes`, `PDFWriterTests.test_standard_goldenBytes`, the same TinyJpeg bytes); the sRGB profile's 736 bytes are pinned by SHA-256 on both sides.
- **Not with a password:** PDF/A forbids encryption. The password option (M20, below) and the archival option exclude each other: while one is on the other is off and greyed out, with its short reason next to it (`PdfA.NotWithPasswordReason`, `PdfProtection.NotWithArchivalReason`) and `PdfA.CannotProtectNote` as its tooltip; a settings file with both on gets the password (`PdfWriteOptions.For`, `PDFWriteOptions.forOutput`); the writer refuses options asking for both (C# `ArgumentException`, Swift `ScanError.exportFailed(PDFA.cannotProtectNote)`).
- **Both apps:** "Archival PDF (PDF/A)" in the Archive & password section of the settings column (shown whenever the save writes a PDF; hint `PdfA.OptionHint`, help `OptionHelp`); the **Archive document** task (`ScanTask.Archive` / `.archive`, raw value "archive", icon "archive" (a Segoe Fluent Icons glyph on Windows, the SF Symbol "archivebox" on the Mac), after `Book`, listed last under Documents): flatbed or feeder, 300 dpi color PDF at the Best size, searchable, archival, "Scan {date} {counter}", file label "Document"; starting it opens Archive & password. It fits while the format is PDF and archival is on; every other task turns archival off. Every PDF the app saves (queue, split documents, receipts, the ID card's page, a copy's PDF) follows the setting; the separator sheet does not. The iPhone offers the task and the switch since I14: the scan screen's PDF choices (`PDFOptionsSection`: the PDF size, then Archive and Password, which grey each other out with the same reasons, `IOSPDFOptions`) whenever its Save writes a PDF (`IOSShell.offersPDFOptions`).
- **Checks:** `PdfATests` and `GlyphlessFontTests` (structure, XMP dates equal Info dates, the text layer read back in Turkish, Greek, Cyrillic, Arabic, Hebrew, Japanese, Chinese with an Extension B ideograph, Devanagari and emoji through PdfPig, a test-only package; the font's checksums and tables; the map inflated with `ZLibStream`). The Swift side: `PDFATests` (the same cases: dates, strings, titles, the information dictionary, the XMP read with XMLParser, the profile, the archival file's structure and metadata through PDFKit, the text layer's codes and map for every script and PDFKit's reading of the left-to-right ones, the golden file, the validation samples), `GlyphlessFontTests` (the same cases; the map inflated with the Compression framework) and `PDFWriterTests` (the object writer, the plain file's structure and text layer, the JPEG headers with C#'s `SyntheticJpeg` generator, cancellation, the numbers, PDFKit opening the file and reading the Turkish line back, the golden files). CI runs the pinned veraPDF on the PDF/A samples of both writers: the Windows job on `PdfATests.Archival_ValidationSamples`' files, the macOS job on `PDFATests.test_archival_validationSamples`' (`COMPLETESCANNER_PDFA_SAMPLES`). qpdf is a developer check where installed; neither ships.

### Password-protected PDFs (M20: Windows; the Mac since I5)

The second part of the Swift port (I5) brought `PdfEncryption` and the encryption members of
`PdfObjectWriter` (`Output/PDFEncryption.swift`, `Output/PDFObjectWriter.swift`): a protected file is
the same file on both platforms for the same password and random bytes, and the Mac saves protected
PDFs, asking for the password with its own dialog.

```swift
// OutputOptions has `protect: Bool` ("protect" in the "output" object; false by default and for
// files written before it existed; a wrong-typed value reads as false). Only the switch is stored,
// never a password. TaskCatalog.apply keeps it, except that the Archive document task turns it off.
```
The C# side, which the Swift port mirrors name for name and byte for byte:
```csharp
public enum PasswordStrength { None, Weak, Fair, Strong }        // first member = default
public sealed class PdfProtection : IDisposable {                // one save's password; Dispose wipes it
    const int MaxPasswordBytes = 127;
    const string OptionLabel = "Require a password", OptionHint, OptionHelp, NotWithArchivalReason = "Not with PDF/A",
                 DialogTitle, DialogMessage, DialogHelp, PermissionsNote, PermissionsShortNote, NotSavedMessage;
    static string KeptInQueueMessage(int pages);
    PdfProtection(string password, bool allowPrinting = true, bool allowCopying = true); // throws on Problem
    bool AllowPrinting, AllowCopying; int PermissionFlags;
    internal ReadOnlySpan<byte> Password;                        // prepared; throws once disposed
    internal ReadOnlySpan<byte> DecomposedPassword;              // DecomposePassword's; throws once disposed
    static int Permissions(bool allowPrinting, bool allowCopying); // -4; no printing clears bits 3 and 12, no copying bit 5
    static byte[] PreparePassword(string);  // SASLprep's mappings (spaces to U+0020, B.1 to nothing), NFKC, UTF-8, cut at 127 bytes
    static byte[] DecomposePassword(string); // the same mappings, NFKD, UTF-8, cut at 127 bytes: what PDFKit passes on
    static string? Problem(string password, string confirmation);  // empty, control characters, nothing left once prepared, mismatch
    static PasswordStrength StrengthOf(string); static string StrengthLabel(PasswordStrength);
    static int StrengthSegments(PasswordStrength); static string StrengthHint(PasswordStrength);
}
public sealed class PdfEncryption : IDisposable {                // standard security handler V5 R6, AES-256
    const int FileKeyLength = 32, SaltLength = 8, OwnerPasswordLength = 32, PermsRandomLength = 4, IvLength = 16;
    static PdfEncryption Create(PdfProtection, Action<Span<byte>>? random = null);
    int P; byte[] O, U, OE, UE, Perms; string Dictionary;
    byte[] Encrypt(ReadOnlySpan<byte>);                          // 16-byte random IV, then AES-256-CBC with PKCS#7
    static byte[] Hash(ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> userKey); // algorithm 2.B
    static byte[]? FileKeyFor(ReadOnlySpan<byte> password, o, u, oe, ue);   // algorithm 2.A, owner first
    static bool PermsMatch(ReadOnlySpan<byte> fileKey, ReadOnlySpan<byte> perms, int p); // algorithm 13
    static byte[] Decrypt(ReadOnlySpan<byte> fileKey, ReadOnlySpan<byte> stored);
}
// PdfWriteOptions gains `PdfProtection? Protection`, `bool IsProtected` and (tests) `internal Action<Span<byte>>? Random`;
// For(OutputOptions output, string? title, PdfProtection? protection = null): protected when output.Protect (the
// protection must then be given: ArgumentNullException), else PDF/A when output.Archival.
// PdfObjectWriter gains `PdfObjectWriter(Stream, PdfEncryption? encryption = null)`, `PdfEncryption? Encryption` and
// `string AsciiString(string)`: "(text)" escaped in an open file, the encrypted bytes as hex in an encrypted one;
// WriteStream encrypts the data (the /Length is the encrypted data's).
```
The Swift twins (`Output/PDFEncryption.swift`; AES-CBC and AES-ECB are CommonCrypto's `CCCrypt`, as
CryptoKit has none; SHA-256/384/512 CryptoKit's; random bytes `SecRandomCopyBytes`'; bytes are
`[UInt8]`; what C# throws is `ScanError.exportFailed`, and `Dispose` is `dispose()`, also run by `deinit`):
```swift
public enum PasswordStrength: String, CaseIterable, Sendable { case none, weak, fair, strong }
public final class PDFProtection: @unchecked Sendable {
    static let maxPasswordBytes = 127
    static let optionLabel, optionHint, optionHelp, notWithArchivalReason, dialogTitle, dialogMessage, dialogHelp,
               permissionsNote, permissionsShortNote, notSavedMessage: String
    static func keptInQueueMessage(_ pages: Int) -> String
    init(_ password: String, allowPrinting: Bool = true, allowCopying: Bool = true) throws  // throws with `problem`
    let allowPrinting: Bool, allowCopying: Bool; var permissionFlags: Int
    internal func password() throws -> [UInt8]                     // prepared; throws once disposed
    internal func decomposedPassword() throws -> [UInt8]           // decomposePassword's; throws once disposed
    func dispose()
    static func permissions(allowPrinting: Bool, allowCopying: Bool) -> Int
    static func preparePassword(_ password: String) -> [UInt8]
    static func decomposePassword(_ password: String) -> [UInt8]
    static func problem(_ password: String, _ confirmation: String) -> String?   // compared code unit by code unit, as C#
    static func strengthOf(_ password: String) -> PasswordStrength; static func strengthLabel(_:) -> String
    static func strengthSegments(_:) -> Int; static func strengthHint(_:) -> String
}
public final class PDFEncryption {
    static let fileKeyLength = 32, saltLength = 8, ownerPasswordLength = 32, permsRandomLength = 4, ivLength = 16
    static let systemRandom: PDFRandomSource                       // SecRandomCopyBytes
    static func create(_ protection: PDFProtection, random: PDFRandomSource? = nil) throws -> PDFEncryption
    let p: Int; let o, u, oe, ue, perms: [UInt8]; var dictionary: String
    func encrypt(_ data: [UInt8]) throws -> [UInt8]; func dispose()
    static func hash(_ password: [UInt8], salt: [UInt8], userKey: [UInt8]) throws -> [UInt8]
    static func fileKeyFor(_ password: [UInt8], o: [UInt8], u: [UInt8], oe: [UInt8], ue: [UInt8]) throws -> [UInt8]?
    static func permsMatch(fileKey: [UInt8], perms: [UInt8], p: Int) -> Bool
    static func decrypt(fileKey: [UInt8], stored: [UInt8]) throws -> [UInt8]
}
```
- **The random bytes,** in the order they are taken: the file key (32), the user validation and key salts (8 + 8), the owner password (32, taken even when it is not used), the owner validation and key salts (8 + 8), the /Perms filler (4); then 16 for the IV of each string and stream in the order they are written; then the file identifier when none is given.
- **The values:** /U = hash(user password, user validation salt) ‖ the user salts; /UE = the file key in AES-256-CBC (zero IV, no padding) under hash(user password, user key salt); /O and /OE the same with the owner password, hashed with the whole 48-byte /U; the owner password is the 32 random bytes, unless the password decomposes (`DecomposePassword` differs from `PreparePassword`: an accented letter, a Hangul syllable, ...), when it is `DecomposePassword`'s bytes: PDFKit's `PDFDocument.unlock` (and so Preview and the Mac app) passes a typed password on decomposed (NFKD) and tries no other form, so it could not open the file otherwise; it then opens it as its owner, without the permissions, while readers that prepare the password as PDF 2.0 asks open it as its user; /Perms = P (little-endian) ‖ FF FF FF FF ‖ "T" ‖ "adb" ‖ 4 random bytes in AES-256-ECB under the file key. Hash = algorithm 2.B (SHA-256 of password ‖ salt ‖ userKey, then at least 64 rounds of AES-128-CBC over (password ‖ K ‖ userKey) × 64 and SHA-256/384/512 by the sum of the first 16 bytes modulo 3, while the last byte is above the round number − 32).
- **The file:** `%PDF-1.7` and the binary comment line; the catalog adds `/Extensions <</ADBE <</BaseVersion /1.7 /ExtensionLevel 8>>>>`; the Encrypt dictionary (`/Filter /Standard /V 5 /R 6 /Length 256 /CF <</StdCF <</CFM /AESV3 /AuthEvent /DocOpen /Length 32>>>> /StmF /StdCF /StrF /StdCF /O /U /OE /UE /Perms /P /EncryptMetadata true`) is the object after the font (and PDF/A objects, which never come with it), before the pages; the trailer adds `/Encrypt n 0 R /ID [<id> <id>]`. Every stream (the font, its map and ToUnicode, each image and content stream) and every string (the CIDSystemInfo's) is encrypted with the file key; the Encrypt dictionary and /ID are not. Each file gets its own key, salts and IVs.
- **Golden bytes** (`PdfEncryptionTests`, `PDFEncryptionTests`): "Şifre 2026" with the counting bytes 0, 1, 2, … gives /U `69E56736…2E2F`, /O `5FBC1E56…5E5F`, /UE `5939E7CB…6E0D`, /OE `C111D7C0…1A2C`, /Perms `A23A07C7…CB0E` (full values in the tests; /U, /UE and /Perms also computed by a separate implementation of algorithm 2.B, /O and /OE, made with the decomposed password, by the Swift port); the one-page Letter file with a Turkish line is 10030 bytes, SHA-256 `CFA0C44F…D2B1`. The Swift port writes the same values and the same file.
- **Known answers:** algorithm 2.B, /UE and /OE against pdf.js's PDF 2.0 cases (`test/unit/crypto_spec.js`, Apache-2.0); its SASLprep case ("S\u{AA}SL\u{AD}prep" opens the file made with "SaSLprep"); its revision 6 dictionary, whose /P was changed after /Perms was made, fails `PermsMatch` for that /P. The same cases on both sides.
- **The password is never stored:** settings and presets keep only `protect`; the app asks for the password once per save (Windows: `AppViewModel.AskPdfPassword`, the window's `PdfPasswordWindow`; the Mac: `AppState.askPDFPassword`, set by `AppState.makeForMac` to `PDFPasswordWindow.ask`, a modal window of its own so it also comes up over a review sheet; `AppState+Protection.swift`), uses it for every PDF of that save and disposes it when the save ends (`runExclusive`); nothing about it is logged. The iPhone asks with its own sheet since I14 (`IOSPasswordPrompt`, set by `AppState.makeForIOS(..., passwordPrompt:)`: `PasswordSheetView` presented over whatever is on top, the scan screen or a review, as the Mac's window comes up over its sheets; the password twice in secure fields, the strength bar and word, the problem as typed, Allow printing and Allow copying; the form, `IOSPasswordForm`, mirrors the Mac's `PDFPasswordForm`; nothing typed is kept, no Keychain). No answer (or nobody to ask) saves nothing: collected pages stay, pages saved as they are scanned go to the queue (`PdfProtection.KeptInQueueMessage`), a split save writes no document, and the status is `PdfProtection.NotSavedMessage`. A copy that also saves a PDF asks before printing: no answer still prints it, and when printing fails its pages go to the queue (the print error, then `KeptInQueueMessage`).
- **Both apps:** "Require a password" under "Archival PDF (PDF/A)" in Archive & password (hint `PdfProtection.OptionHint`, help `OptionHelp`); the two grey each other out (see M19); the section's collapsed header shows a lock and "Password on" (`InspectorSections.archiveSummary`), and the Save button a lock, read as "Save password-protected PDF". The dialog asks for the password twice, shows the strength bar (`StrengthSegments`) with `StrengthLabel` (its `StrengthHint` on hover and for screen readers, announced when it changes) and `Problem` as they are typed (a difference once the second has as many characters as the first, a control character at once; Return while Save is off, or leaving the second box with something in it, shows the problem), and offers "Allow printing" and "Allow copying" (both on, read as "Allow copying text and images") with `PermissionsShortNote` and `PermissionsNote` on hover: the permissions are advisory. Every PDF the app saves follows the switch; the separator sheet does not. A saved file's status ends "(412 KB, password-protected)"; a split save's says it in the brackets after the page count ("(7 pages, 1.2 MB, password-protected)"), receipts' after the last file name (`AppState.pdfNote`, the Windows `PdfNote`).
- **Checks:** `PdfEncryptionTests` and the password cases of `ModelsCompatTests`, `ScanTaskTests` and `SaveActionsTests` on both sides. C#: PdfPig (test-only) opens the files with the password and refuses them without it or with a wrong one; `Windows.Data.Pdf` opens no revision 6 file (reference files made by qpdf fail with 0x80048040 as ours do), so the Saved tab shows a protected file's icon. Swift: `PDFEncryptionTests` opens the files with PDFKit, locked until `PDFDocument.unlock` gets the user's password or the owner password (for a password that does not decompose, the counting bytes make it "0123456789:;<=>?@ABCDEFGHIJKLMNO"), refusing a wrong one, and honoring "no printing, no copying" for the user; a password that decomposes ("Şifre 2026", "Çağrı 2026") opens in the Mac's PDFKit as the owner's and in CoreGraphics, given the prepared bytes, as the user's; it runs on the Mac and in the iOS Simulator. `AppStateSeamTests` checks the Mac's save flows (asked once, a locked file that opens with the password, nothing saved without one, pages saved as scanned kept in the queue, PDF/A titled with the file's name). qpdf (`qpdf --password=… --check`) is a developer check where installed.

### Adding pages to an existing PDF (M21: Windows, the Mac and the iPhone)

Every platform adds the queued pages to the end of a PDF the user picks as an incremental update,
with a reader of its own. The Swift files are twins of the C# ones, with the same bytes, refusals
and messages (`Output/PDFSyntax.swift`, `Output/PDFReaderLite.swift`, `Output/PDFAppender.swift`
and the update members of `Output/PDFObjectWriter.swift`), and the app's part is
`App/AppState+Append.swift`, the twin of `AppViewModel.Append.cs`. Nothing is stored: the target
is picked for each addition (or once before scanning, held in memory until the pages are in), never
kept in a preset or settings file, so the settings files stay the same.
```csharp
public enum PdfReadProblem { NotPdf, Damaged, Encrypted, Unsupported }
public sealed class PdfReadException : Exception { PdfReadProblem Problem; }
public sealed class PdfReaderLite : IDisposable {        // reads; never repairs or guesses
    static PdfReaderLite Open(string path); PdfReaderLite(byte[]); PdfReaderLite(Stream, bool leaveOpen = false);
    long Length, StartXref; long? LatestPrev; string Version; int SectionCount, NextObjectNumber, PageCount;
    bool XrefIsStream, IsHybrid, HasObjectStreams, IsEncrypted, IsSigned, IsCertified;   // IsSigned, IsCertified and the
                                                         // PDF/A facts read objects when asked (throw PdfReadException)
    int? PdfAPart, OutputIntentComponents; string? PdfAConformance;
}
public enum PdfAppendProblem { NotPdf, Damaged, Encrypted, Unsupported, ReadOnly, InUse, Missing, Changed, NotVerified, NotWritten, LeftAsBackup }
public sealed class PdfAppendException : Exception { PdfAppendProblem Problem; }   // Message: PdfAppender.Message (LeftAsBackup: LeftAsBackupMessage)
public sealed record PdfAppendTarget(string Path, int PageCount, bool IsSigned, int? PdfAPart, string? PdfAConformance, bool KeepsPdfA,
                                     bool IsCertified = false)
    { bool IsPdfA; IReadOnlyList<string> Warnings; string? ConfirmMessage; }
public sealed record PdfAppendResult(string Path, int PagesBefore, int PagesAdded, long Bytes) { int PageCount; }
public sealed record PdfAppendOptions { byte[]? DocumentId; }                      // tests: the new identifier half
public static class PdfAppender {
    const string ButtonLabel = "Add to existing PDF…", ButtonHint, SavedMenuLabel = "Add the scanned pages to this PDF",
                 SavedMenuHint, PickerTitle, ConfirmQuestion = "Add the pages anyway?", NoPasswordNote;
    static string SaveTitle(string fileName);                                          // "Add to Contract.pdf"
    static string Message(PdfAppendProblem, string fileName); static string SignedWarning(string fileName);
    static string LeftAsBackupMessage(string fileName, string? backupName);   // where the unchanged file was left
    static string CertifiedWarning(string fileName);   // instead of SignedWarning for a certified file
    static string PdfAWarning(string fileName, int part, string? conformance);
    static string AddedMessage(int added, string fileName, int pageCount, string? size);  // "Added 2 pages to A.pdf (now 11 pages, 1.4 MB)"
    static bool KeepsPdfA(int? part, string? conformance, int? outputIntentComponents);   // 1B, 2B/2U, 3B/3U with an RGB intent
    static PdfAppendTarget Inspect(string path);
    static byte[] Append(byte[] original, IReadOnlyList<PdfPageInput> pages, PdfAppendOptions? options = null);
    static void WriteUpdate(PdfReaderLite, Stream output, IReadOnlyList<PdfPageInput>, PdfAppendOptions?, Action<string>?, CancellationToken);
    static PdfAppendResult AppendToFile(string path, IReadOnlyList<PdfPageInput>, Action<string>? progress = null,
                                        CancellationToken = default, PdfAppendOptions? options = null);
}
// PdfObjectWriter gains PdfObjectWriter(Stream, long position) for an update, BeginObject/WriteObject with a
// generation, FinishUpdate(trailerEntries) (a classic section of the objects written) and
// FinishUpdateStream(number, entries) (an uncompressed /W [1 4 2] stream listing itself; wider offsets past 4 GB).
```
```swift
public enum PDFReadProblem { notPdf, damaged, encrypted, unsupported }
public struct PDFReadError: LocalizedError { problem: PDFReadProblem; detail: String }
public final class PDFReaderLite {                      // reads; never repairs or guesses
    static func open(path:) throws -> PDFReaderLite; init(data:) throws; init(length:read:) throws; func close()
    var length, startXref: Int; latestPrev: Int?; version: String; sectionCount, nextObjectNumber, pageCount: Int
    var xrefIsStream, isHybrid, hasObjectStreams, isEncrypted: Bool
    var isSigned, isCertified: Bool { get throws }; pdfAPart, outputIntentComponents: Int? { get throws }
    var pdfAConformance: String? { get throws }        // read when asked, as C#'s properties
}
public enum PDFAppendProblem { notPdf, damaged, encrypted, unsupported, readOnly, inUse, missing, changed, notVerified, notWritten, leftAsBackup }
public struct PDFAppendError: LocalizedError { problem: PDFAppendProblem; message: String; underlying: (any Error)? }
public struct PDFAppendTarget { path; pageCount; isSigned; pdfAPart; pdfAConformance; keepsPdfA; isCertified = false
                                isPdfA; warnings: [String]; confirmMessage: String? }
public struct PDFAppendResult { path; pagesBefore; pagesAdded; bytes; pageCount }
public struct PDFAppendOptions { documentId: [UInt8]? }                      // tests: the new identifier half
public enum PDFAppender {
    static let buttonLabel, buttonHint, savedMenuLabel, savedMenuHint, pickerTitle, confirmQuestion, noPasswordNote,
               saveAsNewLabel                                                        // Mac and iPhone only
    static func saveTitle(_ fileName: String) -> String                              // SaveTitle
    static func message(_:_:), leftAsBackupMessage(_:backupName:), signedWarning(_:), certifiedWarning(_:)
    static func pdfAWarning(_:part:conformance:), addedMessage(_:fileName:pageCount:size:)
    static func keepsPdfA(part:conformance:outputIntentComponents:) -> Bool
    static func inspect(path:) throws -> PDFAppendTarget
    static func append(_ original: Data, pages: [PDFPageInput], options: PDFAppendOptions? = nil) throws -> Data
    static func writeUpdate(_: PDFReaderLite, into: (Data) throws -> Void, pages:, options:, progress:, shouldContinue:) throws
    static func appendToFile(path:pages:progress:shouldContinue:options:) throws -> PDFAppendResult
}
// PDFObjectWriter gains init(position:output:), beginObject/writeObject with a generation, finishUpdate(_:)
// and finishUpdateStream(_:_:), as C#. Cancelling is shouldContinue, polled where C# checks its token.
extension AppState {                                    // the twin of AppViewModel.Append.cs
    var confirmAppend: (@MainActor (String) async -> Bool)?                       // ConfirmAppend
    var accessPDFForAppend: (@Sendable (URL, Bool, (URL) throws -> Void) throws -> Void)?   // the iPhone's file access
    var canAppendPages: Bool; func appendToPDF(at: URL)                       // CanAppendPages, AppendToPdf
    var appendTarget: URL? { get }                                            // string? AppendTarget
    func setAppendTarget(_ url: URL); func clearAppendTarget()                // SetAppendTarget, ClearAppendTarget
}
```
- **Reading:** the header must be at byte 0 (else Unsupported); the last `startxref` in the last 4 KB and a `%%EOF` after it; classic tables and cross-reference streams (Flate, PNG predictors 10–15 and TIFF 2), every `/Prev` (a loop is Damaged), a hybrid file's `/XRefStm` (its entries fill numbers the table gives as free or not at all), objects in object streams; newer sections win, older trailers supply `/Root`, `/Info` and `/ID` when the newest lacks them. Every object read is checked to be the one its entry says, every stream read to end at `endstream` after its `/Length`; the page tree is walked (nested nodes, indirect `/Kids`) and a loop is Damaged. The tree's root must have `/Kids` (a root that is a page is Damaged). A `/Size`, table subsection or `/Index` range past object number 8,388,607 (ISO 32000-1 Annex C) is Damaged. An `/Encrypt` entry stops reading (IsEncrypted). Signed: `/SigFlags` bit 1 or `/Perms`; certified: `/Perms` has `/DocMDP`. PDF/A: `pdfaid:part` and `pdfaid:conformance` in the catalog's XMP, as attributes or elements.
- **The update:** the original bytes untouched (an end of line first only when the file lacks one); the text layer's font when a new page has text, then Page, Image and Contents per page as `PdfBuilder` writes them, numbered from `NextObjectNumber`, each page with `/Parent` the tree's root, its own `/MediaBox` and `/Resources`, `/Rotate 0`, and `/CropBox` = the media box when the root has one; the root again (same number and generation) with the new pages at the end of `/Kids` (made direct) and `/Count` = old pages + new; a section of the newest one's kind (a classic table, also for a hybrid file; an uncompressed cross-reference stream after a stream) whose trailer has `/Size`, `/Root`, `/Info` (when there is one), `/ID [<first as it was, or the new one> <new>]` and `/Prev`. New objects past number 8,388,607 are refused (Unsupported) before anything is written, the end of line included.
- **The file:** opened for reading and writing, sharing reading only (read-only → ReadOnly; open elsewhere → InUse; gone → Missing); original + update written to a hidden `.{guid}.pdf.tmp` in the same folder, read back (the original's SHA-256 at its start, one more section, `/Prev` = the original's `startxref`, every page), checked unchanged since it was read (Changed), given the original's creation time and attributes, then put in its place with `File.Replace` (ReplaceFile, the original moved aside to `.{guid}.pdf.bak`, which carries the original's own attributes, until then and removed after, or hidden and left when it cannot be removed), which keeps the original's permissions, alternate data streams (Zone.Identifier) and EFS encryption, but not other hard links to the file (they keep the old content); a plain rename where the file system has no ReplaceFile. When ReplaceFile moved the original aside but the new file could not take its name, the original is moved back (InUse); if that fails it stays under the backup name and the refusal is LeftAsBackup, whose message (`LeftAsBackupMessage`) names the backup file. A folder that takes no new files is ReadOnly, a failed write (a full disk) NotWritten. Any failure removes the temporary file; the original is never written. Every failure, including what the reader finds in objects read after it opened the file, is a `PdfAppendException` whose message is `Message` (for LeftAsBackup, `LeftAsBackupMessage` with the backup's name). The Swift twin opens the file with open(2) for reading and writing (EACCES, EPERM or EROFS → ReadOnly; ENOENT → Missing) and sees it open elsewhere only when another app holds a lock on it (flock), creates the temporary file with O_EXCL, and puts it in the original's place with `FileManager.replaceItemAt` under the same backup name, with the same LeftAsBackup outcome, after giving it the original's creation date and POSIX permissions; there is no Hidden attribute, no alternate data stream and no plain rename. On the iPhone, which is given a file picked in Files without its folder, the temporary file is written in the system's item-replacement folder for the file and swapped into place with no backup, so a refused swap leaves the original where it was (a permission error, also when it comes as EACCES under Foundation's error, is ReadOnly).
- **Windows UI:** "Add to existing PDF…" (`ButtonLabel`, an item in the Save button's menu; tooltip and help text `ButtonHint`) opens a file picker in the save folder; the start screen's "Add pages to a PDF" tile (after the task tiles) opens the same picker, then starts Document to PDF and sets `AppendTarget` (any other task tile, or a preset from anywhere, clears it), and while it is set the Save button reads `SaveTitle`, with the file's path and a × (`ClearAppendTarget`) under it; a PDF's menu in the Saved tab offers `SavedMenuLabel`. Both add the pages the queue would save (all its documents in order; skipped, blank and separator pages stay out), stored as the PDF size and the text layer say, then clear the queue, show the file in the bar after a save and run the after-save action. While every queued page is left out the item is off and its tooltip says `PageFilter.NothingToSaveMessage`, as Save's does. Refusals are errors (`Message`), and the pages stay. A signed or certified file, or a PDF/A file whose level the pages may not keep, asks `ConfirmMessage` first (No: "Nothing was added to A.pdf."). The password and archival switches do not apply: the file decides (with the password switch on the status adds `NoPasswordNote`).
- **Append target:** `appendTarget` (C# `AppendTarget`, the path) is a PDF picked before the pages are scanned (the start screen's "Add pages to a PDF"). While it is set, Save (`savePDF()`, `SavePdf()`) runs `appendToPDF(at:)` into it instead of writing a new file, and the Save button reads `saveTitle(name)` ("Add to Contract.pdf"); on the Mac and the iPhone `saveAsNewLabel` names the menu item that saves a new PDF instead (shown while the queue is saved as a PDF), and Windows has a × under Save for that. The file is only read when the pages are added. Any append that puts the pages in clears it, as `clearAppendTarget()` does; a refusal or a No keeps it, with the pages. It lives in memory only.
- **Mac and iPhone UI:** the Mac's Save is a split button while the queue is saved as a PDF or an append target is set: `saveAsNewLabel` (clears the target, then saves; not for Word or text) and `buttonLabel` in its menu, and while a target is set the queue strip shows even with no pages, with Stop Adding (`clearAppendTarget()`) beside Clear; an open panel (`pickerTitle`) starting in the save folder, also for the start screen's "Add pages to a PDF" tile (after the task tiles), which then starts Document to PDF and sets the target (any other task tile, or a preset from anywhere, clears it), and `savedMenuLabel` (help `savedMenuHint`) in the menus of a PDF in the Saved tab; the question is an alert, `confirmQuestion` over the warnings, with Add Pages and Cancel (Return does not add, as No is the Windows default). The iPhone and iPad have the same menu beside Save (`ScanScreen.saveMenu`) while Save writes a PDF (`IOSShell.offersPDFOptions`) or a target is set, picking the PDF in Files, the start screen's tile after the task tiles (`IOSAppendTile`, picked when Document to PDF can be) picking it in Files before starting Document to PDF with the target (the URL as Files gives it, its scope opened only when the pages are added; any other task, from the tiles or the iPad's sidebar, or a preset clears it), Save reading `saveTitle` (`ScanScreen.saveTitle`), and `savedMenuLabel` in a PDF's menu in Saved files; the question is an alert over whatever is shown (`IOSPDFAppend.confirm`). The iPhone reads and replaces the file inside its security scope and an `NSFileCoordinator` access, a reading one for `inspect` and a writing one `.forReplacing` for the update, so iCloud Drive and other providers see the new file (`IOSPDFAppend.access`, set by `makeForIOS` as `AppState.accessPDFForAppend`). Both add, clear, report and refuse as Windows does; the file is offered like a saved one (`lastSavedURLs`, the PDF's size) and the after-save action runs. On the iPhone the file's security scope is opened again once the pages are in and stays open while it is the file saved last (`AppState.scopedSavedURL`, let go when `lastSavedURLs` changes), so Share, Email, Open and Show in Files reach a file outside the app's folder.
- **Checks:** `PdfReaderLiteTests` and `PdfAppenderTests` (hand-made fixtures for each layout and refusal, our own plain, PDF/A and protected files; every result read back with PdfPig's lenient parsing off), and veraPDF in CI on a PDF/A file with pages added twice. Their Swift twins, `PDFSyntaxTests`, `PDFReaderLiteTests` and `PDFAppenderTests`, have the same cases over the same fixtures (`PDFFixtures.swift`), read back by `PDFReaderLite` and PDFKit, with POSIX permissions and flock where C# uses ACLs, attributes and sharing. `AppStateAppendTests` (Swift only, as the view model is not in Core) checks the state's part: pages added to a `PDFBuilder` file, the question refused or unanswered, an encrypted file refused, the queue kept, Save with a target adding to it and clearing it, Save after the target is cleared writing a new file (C#: the texts only, in `PdfAppenderTests`); an `IOSShellTests` case checks the iPhone's coordinated access, another the start tile's availability and Save's title with a target, and an `IOSLibraryTests` case that a preset clears the target.
- **Pending (not built yet):** the picker's first-page thumbnail of the chosen file, on every platform.

### CCITT G4 for black & white pages (M22a: Windows; the Mac since I4)

Black & white pages (the Black & White color mode, after its threshold) are stored as lossless
1-bit CCITT Group 4 images: in every PDF Windows writes (plain, PDF/A, protected, pages added to
an existing PDF), in every PDF the Mac writes (plain, PDF/A, protected) and in TIFF files on
both. The plan that chooses G4 is shared (`PdfImageEncoding` above: `bilevelG4`,
`bilevelMaxDPI`); the encoder, the TIFF writer and the PDF image type have Swift twins with the
same names and the same bytes (`Output/CCITTG4Encoder.swift`, `Pipeline/Bilevel.swift`,
`Output/BilevelTIFF.swift`, and `PDFImageData.ccittG4` in `Output/PDFWriter.swift`). No setting
is stored: the color mode and the PDF size decide.
```csharp
public static class Bilevel {                  // 1 bit per pixel, rows from the top, each on a byte boundary
    const int Threshold = 128;                 // luma below it is black (Rec. 601, ×1000 integer weights, +500, /1000)
    static int Stride(int width);              // (width + 7) / 8
    static byte[] Pack(RgbaImage); static byte[] Pack(ReadOnlySpan<byte> rgba, int width, int height);
                                               // MSB first, 0 = black, 1 = white; bits past the last pixel are 1
    static bool IsBlack(ReadOnlySpan<byte> packed, int width, int x, int y);
    static RgbaImage Unpack(ReadOnlySpan<byte> packed, int width, int height);   // black (0,0,0) / white, opaque
}
public static class CcittG4Encoder {           // ITU-T T.6
    static byte[] Encode(ReadOnlySpan<byte> packed, int width, int height);   // width ≥ 1, height ≥ 0
    static byte[] Encode(RgbaImage image);     // Encode(Bilevel.Pack(image), ...)
}
public abstract record PdfImageData(byte[] Data);
public sealed record PdfJpegImage(byte[] Data) : PdfImageData(Data);
public sealed record PdfCcittImage(byte[] Data, int Width, int Height) : PdfImageData(Data)
    { static PdfCcittImage Encode(RgbaImage image); }
// PdfPageInput(PdfImageData Image, int PixelWidth, int PixelHeight, int Dpi, IReadOnlyList<OcrLine>? OcrLines);
// the byte[] constructor (a JPEG page) and `byte[] JpegData` (= Image.Data) are kept.
public sealed record BilevelTiffPage(RgbaImage Image, int Dpi);
public static class BilevelTiff {
    static bool Applies(OutputFormat format, ColorMode mode);   // TIFF and black & white
    static byte[] Make(RgbaImage image, int dpi); static byte[] Make(IReadOnlyList<BilevelTiffPage> pages);
}
// WpfImageCodec.SaveAsNew gains `ColorMode colorMode = ColorMode.Color`: a black & white TIFF is BilevelTiff.Make.
```
```swift
public enum Bilevel {                          // Pipeline/Bilevel.swift
    static let threshold = 128; static func stride(_ width: Int) -> Int
    static func pack(_ image: RgbaImage) -> [UInt8]; static func pack(rgba: [UInt8], width: Int, height: Int) -> [UInt8]
    static func isBlack(_ packed: [UInt8], width: Int, x: Int, y: Int) -> Bool
    static func unpack(_ packed: [UInt8], width: Int, height: Int) -> RgbaImage
}
public enum CCITTG4Encoder {                   // Output/CCITTG4Encoder.swift
    static func encode(_ packed: [UInt8], width: Int, height: Int) throws -> [UInt8]  // ScanError.exportFailed on bad sizes
    static func encode(_ image: RgbaImage) -> [UInt8]
}
public struct BilevelTIFFPage { image: RgbaImage; dpi: Int }
public enum BilevelTIFF {                      // Output/BilevelTIFF.swift
    static func applies(_ format: OutputFormat, _ mode: ColorMode) -> Bool
    static func make(_ image: RgbaImage, dpi: Int) -> Data; static func make(_ pages: [BilevelTIFFPage]) -> Data  // pages not empty
}
// ImageExporter.write gains `colorMode: ColorMode = .color`: a black & white TIFF is BilevelTIFF.make.
// PDFImageData.ccittG4(data:width:height:) and PDFImageData.encodeCCITTG4(_:) are C#'s PdfCcittImage.
```
- **The coding:** the reference row above the first is white. Each row's changing elements are
  the pixels whose color differs from the pixel before them (white before the first). a0 starts
  at −1 and white; a1 is the first changing element of the coding row right of a0, a2 the next;
  b1 is the first changing element of the reference row right of a0 of the color opposite a0's
  (changing elements alternate in color, so it is the first one right of a0 or the one after
  it; one of the wrong color must not be skipped for good, a vertical mode can make it b1 next),
  b2 the next one; missing elements are the row's width. Then: b2 < a1 → pass (`0001`), a0 = b2;
  |a1 − b1| ≤ 3 → vertical (a1 − b1 = −3 … 3: `0000010`, `000010`, `010`, `1`, `011`, `000011`,
  `0000011`), a0 = a1 and the color flips; else horizontal (`001`, then the run a0…a1 in a0's
  color with a0 = −1 counted as 0, then a1…a2 in the other color), a0 = a2. The row ends when
  a0 ≥ width. A run is written as libtiff writes it: the 2560 extended make-up code while 2624 or
  more remain, then one make-up code for the remaining multiple of 64 (1792 and up from the
  extended table shared by both colors), then its terminating code. The data ends with EOFB
  (`000000000001` twice) and zero bits up to a byte; rows are not byte-aligned and there are no
  EOLs. Bits are written most significant first. The code tables in `CcittG4Encoder.cs` are T.4's
  tables 2 and 3 as bit strings, to be copied as they are.
- **Known answers** (`CcittG4EncoderTests`): an all-white 1728 × 10 page is `FF C0 04 00 40`; no
  rows is `00 10 01`; a black 1-pixel image is `010` `1` + EOFB; the all-black page, the 8 × 13
  page that uses pass, horizontal (starting white and black) and all seven vertical codes, and
  the runs 5200/2800 and 2624/2623 are spelled out bit by bit there.
- **Golden bytes** (both platforms check them): the 37 × 23 checkerboard (black where x + y is
  even) is 335 bytes, SHA-256 `E8A04616…43EC`; 517 × 211 noise (black where `TestPages.Rng(0xC0FFEE01).Below(2) == 0`,
  row by row) is 28704 bytes, `4255D22C…15C0`; `TestPages.TextPage()` is 17666 bytes,
  `DD8EC297…4DFE`; its black & white page as a one-page 300 dpi TIFF is 17852 bytes,
  `EF4F98A0…A38D` (the gray page thresholded at 128 gives the same file, which the C# test also
  checks, so the Swift twin builds it from `TestPages.textPage()` without C#'s image pipeline); a
  plain PDF of the checkerboard as a G4 page at 100 dpi with the line "Siyah beyaz — Çağrı"
  (0.1, 0.5, 0.8 × 0.2), then a TinyJpeg page of 850 × 1100 at 100 dpi, is 9892 bytes,
  `75ED330C…EF29` (`BilevelOutputTests.Pdf_G4AndJpegPages_GoldenBytes`, Swift
  `PDFWriterTests.test_g4AndJpegPages_goldenBytes`; full values in the tests).
- **In a PDF:** the page's image XObject is `/Type /XObject /Subtype /Image /Width w /Height h
  /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms <</K -1
  /Columns w /Rows h /BlackIs1 false>>` and the G4 data (encrypted like every stream in a
  protected file); object numbers, the page and its content stream are as for a JPEG page. The
  output intent of PDF/A covers it like the gray JPEGs.
- **In a TIFF:** little-endian; per page the G4 strip, then (on a word boundary) its directory in
  tag order — NewSubfileType 2 (several pages only), ImageWidth, ImageLength (LONG),
  BitsPerSample 1, Compression 4, PhotometricInterpretation 0 (WhiteIsZero), StripOffsets,
  SamplesPerPixel 1, RowsPerStrip = height, StripByteCounts, XResolution, YResolution
  (RATIONAL dpi/1, after the directory), T6Options 0, ResolutionUnit 2, PageNumber (index from
  0, page count; several pages only) — then the next directory's offset, 0 for the last.
- **Windows:** the view model stores a page planned as G4 as `PdfCcittImage.Encode` of the
  (possibly downsampled) pixels; a black & white page saved as TIFF (each scan saved at once, the
  photos of the photo review, the ID card's page and its sides) is `BilevelTiff.Make`; receipts,
  always enhanced gray, stay LZW; the Saved tab's rotate keeps a 1-bit TIFF G4 (WIC's encoder).
- **The Mac:** `PDFBuilder` writes every document through `PDFWriter` (`pageInputs`,
  `storedImage`; `writesG4` tells whether a document has a black & white page): its black & white
  pages are the planned G4 images of the (possibly downsampled, box filter) pixels, its other
  pages `encodedPage`'s JPEGs, its text layer the `GlyphLessFont` one. The same saves
  as on Windows write `BilevelTIFF` through `ImageExporter.write(..., colorMode:)` (each scan saved
  at once, the photos of the photo review, the ID card's page and its sides; receipts and the
  spool files stay LZW), and the Saved tab's rotate keeps a 1-bit TIFF (`kCGImagePropertyDepth`
  1) G4. `encodedPage` still gives a page planned as G4 as a gray JPEG for a caller that cannot
  store G4.
- **The mode a page was scanned in decides**, never the color mode set when it is saved, since
  only pixels the black & white mode thresholded (at the user's level) may become G4:
  `DetectedPhoto.colorMode` (C# `ColorMode`, init/constructor default color, kept by C#
  `Recropped` and by the Mac's re-crops) is the scan's `ScannedPage.colorMode` for photos and ID
  card sides (receipts keep the default); the ID card's page is `IdCardComposer.pageColorMode` of
  its sides; a spread joined or split again is made in the current color mode (see the book
  section). Shared now; the Mac's PDF page of the ID card already uses it.
- **Checks:** `CcittG4EncoderTests` and `BilevelOutputTests` (Core: PdfPig decodes every G4 image
  it is given, every run length of both colors included; App: WIC decodes the TIFFs, WIC's own G4
  encoder gives the same bytes strip by strip, Windows.Data.Pdf renders the pages pixel for pixel
  when read at three times their size); `PdfATests.Archival_ValidationSamples` adds a black &
  white PDF/A sample for veraPDF in CI, as `PDFATests.test_archival_validationSamples` does for the
  Swift writer. The Swift twins (`CCITTG4EncoderTests`,
  `BilevelOutputTests`) have the same known answers and golden bytes; their round trips decode
  with ImageIO (the G4 TIFF through `CGImageSource`: the run lengths up to 130 and every 61st up
  to 2700 with each code boundary, odd widths, 20000-pixel rows), CoreGraphics renders the G4 PDF
  pages (at one pixel per point, at most 1 % of the pixels may differ), and the Mac's own paths
  (`PDFBuilder` with black & white pages, their size limits, text layer, file and cancellation,
  a document without them written by `PDFWriter` too, PDF/A and a password through the options;
  `ImageExporter`'s G4 and LZW TIFFs) are checked there too.

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
// OutputOptions gains `wordPageImages: Bool` ("wordPageImages" in the "output" object; true by default
// and for files written before it existed; kept when a task is picked): a Word document shows each
// page's picture before its text, stored as `pdfSize` stores a PDF page.
public enum DocxPictureFormat: Equatable, Sendable { case jpeg, png }
public struct DocxPicture: Equatable, Sendable { public let data: Data; public let format: DocxPictureFormat }
public enum DocxWriter {
    public static let twipsPerInch = 1440, minPageTwips = 144, maxPageTwips = 31680
    public static let emuPerPoint = 12700, emuPerTwip = 635
    public static let contentTypesXML: String, relationshipsXML: String, imageRelationshipType: String
    public static let pageImagesLabel: String                          // "Include page images"
    public static func pageImagesHint(on: Bool) -> String
    /// [Content_Types].xml, _rels/.rels, word/document.xml; with pictures then
    /// word/_rels/document.xml.rels and word/media/image1.jpeg (or .png) and on, in page order.
    public static func make(_ pages: [OCRPage], pictures: [DocxPicture?] = []) -> Data
    /// The length of `make`'s output, without writing it. A save refuses a Word document past
    /// `maxPackageBytes` (2,000,000,000, both platforms) with `ScanError.exportFailed(tooLargeMessage)`
    /// (Windows: an IOException with that message), checked as the pictures add up and before `make`.
    public static func packageSize(_ pages: [OCRPage], pictures: [DocxPicture?] = []) -> Int
    public static let maxPackageBytes = 2_000_000_000
    public static let tooLargeMessage: String   // "The Word document would be larger than 2 GB, too large to write. …"
    /// A w:p per paragraph, pageBreakBefore per page, w:tab, w:br; a page with a picture starts
    /// with it (see below) and its text follows without a break of its own.
    public static func documentXML(_ pages: [OCRPage], pictures: [DocxPicture?] = []) -> String
    public static func pageSizeTwips(_ page: OCRPage?) -> (width: Int, height: Int)   // page 1 × 20, clamped; Letter without a page
    public static func marginTwips(width: Int, height: Int) -> Int    // min(1440, shorter side / 8)
    public static func escapeXML(_ text: String) -> String
    public static func packageContentTypesXML(_ pictures: [DocxPicture]) -> String     // + Default jpeg / png when used
    public static func documentRelationshipsXML(_ pictures: [DocxPicture]) -> String   // rId1… → media/image1.jpeg…
    public static func mediaName(_ number: Int, format: DocxPictureFormat) -> String   // "image1.jpeg"
    public static func pictureExtension(_ format: DocxPictureFormat) -> String; pictureContentType(_:) -> String
    public static func pictureFormat(_ plan: PDFImagePlan) -> DocxPictureFormat        // bilevel → png, else jpeg
    /// The page's real size (points × 12700 EMU) or, when larger, shrunk with its shape kept to fit
    /// inside the paper's margins (integer EMU, rounded down); no size → the space inside the margins.
    public static func pictureSizeEMU(_ page: OCRPage, paperWidthTwips: Int, paperHeightTwips: Int) -> (width: Int, height: Int)
    // Mac only: the picture of a page (color/gray: encodedPage's JPEG; black & white: downsampled to
    // its plan, luma < 128 black, a 1-bit gray PNG through ImageIO). Nil leaves the page without one.
    public static func picture(of image: CGImage, imageDPI: Int, mode: ColorMode, size: PDFSizePreset) -> DocxPicture?
}
public struct ZipStoreEntry { public let name: String; public let data: Data }
public enum ZipStore {
    public static func crc32<Bytes: Sequence>(_ data: Bytes) -> UInt32 where Bytes.Element == UInt8
    public static func make(_ entries: [ZipStoreEntry]) -> Data       // stored, 1980-01-01, in order, no zip64
    public static func packageSize(_ entries: [ZipStoreEntry]) -> Int // make(entries).count, without writing (C#: long)
}
```
Twins of `windows/CompleteScanner.Core/OcrText.cs` (`OcrPage.Of`, `OcrParagraph`, `OcrText`), `TextExport.cs`, `DocxWriter.cs` (with `DocxPictureFormat`, `DocxPicture`), `ZipStore.cs` and `OutputFormats` in `Models.cs` (`IsImageFormat`, `IsTextFormat`, `Offered`, `ImageFormatOrJpeg`, `QueueFormat`, `PageFormat`, `SavesPdf`, `SaveTitle`); `OCRTextTests`, `TextExportTests` (with `OutputFormatsTests`), `DocxWriterTests` (with `ZipStoreTests` and `DocxWriterPictureTests`) are the same cases on both sides, and both pin the same CRC-32 and length of the sample text file and Word document, with and without page pictures (the same 16 × 12 JPEG and PNG fixtures, as hex, in both suites), so the two platforms write the same bytes.
**Page pictures in a Word document (M22b).** With `output.wordPageImages` on, every page of a Word save gets its picture before its text: a paragraph of its own (`w:pageBreakBefore` from the second page on, `w:spacing` before and after 0, centred) holding one inline DrawingML picture (`wp:inline` with `wp:extent`, `wp:docPr` id n, name "Page p", descr "Page p as scanned", `a:graphic` / `pic:pic` with `a:blip r:embed="rIdn"` and the same `a:ext`), the root declaring `r`, `wp`, `a` and `pic` only then. One layout for every page, chosen so that it reads the same in Word, LibreOffice, Pages and Google Docs and survives editing: the picture is inline (it flows with the text, no anchors or text boxes), at the page's real size, or shrunk to fit inside the margins of the document's paper (the first page's size) with its shape kept, so a full page fills its own sheet and its editable text starts on the next. The picture is stored as the PDF size stores the page (`PDFImageEncoding.plan`: the size's resolution limit and JPEG quality, gray JPEG for gray pages), except that a black & white page, G4 in a PDF, is a lossless 1-bit gray PNG (Windows: `Bilevel.Pack` → WIC; the Mac: the same threshold → ImageIO); the inspector shows the size picker as "Page image size" for Word with pictures on. The writer takes encoded bytes, so its output is the same on both platforms; the encoders are each platform's own (`WpfImageCodec.EncodeDocxPicture`, `DocxWriter.picture(of:...)`), checked by decoding with WIC (`CompleteScanner.App.Tests/DocxPictureTests.cs`) and ImageIO (`DocxPictureTests` in `DocxWriterTests.swift`). Windows: a picture that cannot be encoded fails the save (the pages stay queued); the Mac leaves that page without its picture. `TextExport.WriteNewFile` (a hidden temporary file moved to a free name) is Windows only; the Mac writes with `Data.write`. `AppState` saves the collected pages as `settings.format.queueFormat` (`savePDF()`: a Word document or text file, else a PDF and, with `alsoSaveText`, its text beside it), a scan saved at once as Text or Word too, reads each page with OCR once per save (`PDFTextLayer`), and offers `copyPageText(id:)` (Copy Text in a queued page's menu: the page's `OCRText.pageText` on the pasteboard). A page whose text cannot be read fails a Text or Word save with `TextOutputError(TextExport.recognitionFailed(…))`; for the text beside a PDF the PDF is kept and `errorMessage` is `TextExport.sidecarFailed(…)`. A scan saved at once as Text or Word whose text cannot be read, whose file cannot be written, or whose save is cancelled, is put in the queue instead of being lost (`statusMessage` is `TextExport.keptInQueue(…)`, with `textUnreadable` true only when the error is a `TextOutputError` from OCR, so a file error is not told to wait for the text; on Windows the OCR error is a private `InvalidOperationException` subclass in `AppViewModel`). `FileActionService` gains `copyText(_:)` (Windows: `IFileActions.CopyText`, with "\r\n" line breaks). Windows: `AppViewModel.SavePdf` / `CopyPageText`, the inspector's "Also save text (.txt)" and format list, the page strip's menu.

### Output/PDFImageEncoding.swift, Pipeline/ColorAnalysis.swift (+ ScanSettings in Core/Models.swift)

```swift
// ScanSettings gains `output: OutputOptions` (the "output" object; `OutputOptions.pdfSize`
// defaults to .standard, also for files written before it existed).
public enum PDFSizePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, best, compact, smallest     // first case = default and fallback
    public var label: String                   // "Standard", "Best", ...
    public var hint: String                    // a few words: the segment's tooltip
    public var detail: String                  // how the size stores the pages: the segment's help (VoiceOver)
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

public enum PDFImageKind: Equatable, Sendable { case jpegColor, jpegGray, bilevelG4 }
public struct PDFSizeProfile: Equatable, Sendable {
    maxDPI: Int?, colorQuality, grayQuality: Double, autoGray: Bool, bilevelMaxDPI: Int? /* init default nil */
}
public struct PDFImagePlan: Equatable, Sendable {
    targetDPI: Int, kind: PDFImageKind, quality: Double
    var isGray: Bool      // kind != .jpegColor (a gray JPEG or a G4 page)
    var isBilevel: Bool   // kind == .bilevelG4
}
public struct JPEGHeader: Equatable, Sendable { width, height, components: Int }

public enum PDFImageEncoding {
    public static let downsampleSlack = 1.1
    /// best: scan dpi, 0.90/0.90, no auto-gray, G4 at scan dpi; standard: 300 dpi, 0.80/0.80,
    /// G4 ≤ 600 dpi; compact: 200 dpi, 0.65/0.70, G4 ≤ 300 dpi; smallest: 150 dpi, 0.50/0.55,
    /// G4 ≤ 300 dpi (color/gray quality; auto-gray on).
    /// The size alone sets the quality; the JPEG quality setting is for JPEG files only.
    public static func profile(_ size: PDFSizePreset) -> PDFSizeProfile
    /// Black & white pages: .bilevelG4 at the scan dpi, or bilevelMaxDPI above it × 1.1, with the
    /// size's gray quality (what a writer without G4 uses). Others: downsample only above
    /// maxDPI × 1.1; gray JPEG for gray pages and (except at best) for color pages without color;
    /// quality = the size's color or gray quality.
    public static func plan(mode: ColorMode, imageDPI: Int, size: PDFSizePreset, looksGray: Bool) -> PDFImagePlan
    public static func plan(mode: ColorMode, imageDPI: Int, size: PDFSizePreset, image: CGImage) -> PDFImagePlan
    public static func effectiveDPI(imageWidth: Int, pagePixelWidth: Int, pageDPI: Int) -> Int
    public static func targetSize(width: Int, height: Int, imageDPI: Int, targetDPI: Int) -> (width: Int, height: Int)
    public static func downsample(rgba: [UInt8], width: Int, height: Int, newWidth: Int, newHeight: Int) -> [UInt8]  // box filter
    // Apple only: the ImageIO JPEG PDFBuilder stores (and a JPEG-backed CGImage of it). A page
    // planned as G4 is given as a gray JPEG planned as a gray page (plan(mode: .grayscale, ...,
    // looksGray: true)), which is also the plan it returns; PDFBuilder never asks for one (it
    // stores a black & white page as G4 through PDFWriter).
    public static func encodedPage(_ image: CGImage, imageDPI: Int, mode: ColorMode,
                                   size: PDFSizePreset) -> PDFPageImage?   // plan, jpegData, image
    public static func encodeJPEG(_ image: CGImage, quality: Double) -> Data?
    public static func readJPEGHeader(_ data: Data) -> JPEGHeader?
}
```
Twins of `windows/CompleteScanner.Core/PdfImageEncoding.cs` (`PdfSizePreset`, `PdfSizePresets.DisplayOrder`, `ModelLabels.Label` / `Hint`, `PdfSizeProfile`, `PdfImagePlan`, `PdfImageEncoding.Plan` / `EffectiveDpi` / `TargetSize` / `Downsample`) and `ColorAnalysis.cs` (`IsEffectivelyGray`, `GrayPixels`); `PdfImageEncodingTests` and `ColorAnalysisTests` are the same cases on both sides. `readJPEGHeader` is the twin of `PdfBuilder.TryReadJpegHeader`, which declares a one-component JPEG `/DeviceGray`. Windows encodes the planned JPEG with WIC (`WpfImageCodec.EncodeJpeg(image, dpi, quality, gray)`) and a planned G4 page with `PdfCcittImage.Encode`; the Mac encodes the JPEG with ImageIO and a planned G4 page with `PDFImageData` / `CCITTG4Encoder` through `PDFWriter` (see "CCITT G4 for black & white pages"). The size details are the same on both platforms and name the black & white (G4) limit too ("Up to 300 dpi (black & white 600), gray pages saved in gray.", "Up to 200 dpi (black & white 300), more compression.", "Up to 150 dpi (black & white 300), most compression."); the hint case of `PdfImageEncodingTests` is the same on both sides.
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
// CompleteScannerMac/App/SystemFileActions.swift:
@MainActor public final class SystemFileActions: FileActionService { public init() }
extension FileAction { var systemImage: String; func hint(fileCount: Int) -> String }   // internal to CompleteScannerMac, UI only
```
Twin of `windows/CompleteScanner.Core/SaveActions.cs` (`AfterSaveAction`, `FileAction`, `ModelLabels.Label` / `Hint`, `SaveFollowUp` with `Paths` and `FileAction`, `ClipboardContent`, `SendRoute`, `SendProbe`, `SaveActions.Plan` / `Offered` / `IsImageFile` / `ClipboardContentFor` / `EmailRoute` / `ShareRoute` / `ShareTitle`, paths as strings); `SaveActionsTests` are the same cases on both sides, and the after-save cases of `ModelsCompatTests` match. `AppState` takes an optional `fileActions:` (the Mac app passes `SystemFileActions()`; without one every action is refused with `ScanError.unsupported`, showing a file does nothing and nothing can be sent), shows a file in its folder through it (`revealInFinder(_:)`, `FileActionService.reveal`), offers `savedFileActions` (for `lastSavedURLs`) and `runFileAction(_:urls:)`, which reports a missing file or a refusal in `errorMessage`, and runs the plan of `settings.output.afterSave` after `savePDF`, `saveImmediately` and `saveReviewedPhotos` finish. Windows (`App/Services/FileActions.cs`, `ShareService.cs`) has no compose route, so Email opens the share window there; nothing is ever sent without the user sending it. `TaskCatalog.apply` sets the after-save action: `.share` for the Email task, `.none` for the others.

### Pipeline/ReceiptProcessing.swift, App/AppState+Receipts.swift (+ TaskOptions in Core/Models.swift)

```swift
public enum ReceiptBasis: Sendable { case paper, text }      // cut along its paper, or around its print
public struct ReceiptRegion: Equatable { public let region: DetectedPhotoRegion; public let basis: ReceiptBasis }
public struct ReceiptDetectorOptions: Equatable, Sendable {
    public var maxReceipts: Int = ReceiptDetector.maxReceipts   // 12
    public var singleReceipt: Bool = false                      // a feeder sheet: everything printed is one receipt
    public init(maxReceipts: Int = ReceiptDetector.maxReceipts, singleReceipt: Bool = false)
}
public enum ReceiptDetector {
    // markContrast 0.09, closeInches 0.12, minBlockSquareInches 0.01, columnOverlap 0.5, columnGapInches 0.6,
    // sideGapInches 1.5, minShortSideInches 0.5, minLongSideInches 1.0, minAreaSquareInches 0.75, maxReceipts 12,
    // paddingInches 0.08, searchMarginsInches [0.4, 1.2], paperToleranceInches 0.05, minPaperSquareInches 0.5
    public static let pageSearch: PageSearchOptions              // contrast 0.02, fill 0.85, aspect 15
    public static func detectRegions(in image: RgbaImage, dpi: Int, options: ReceiptDetectorOptions = .init()) -> [DetectedPhotoRegion]
    public static func find(_ image: RgbaImage, dpi: Int, options: ReceiptDetectorOptions = .init()) -> [ReceiptRegion]   // full resolution
    public static func find(_ gray: GrayImage, options: ReceiptDetectorOptions = .init()) -> [ReceiptRegion]             // analysis pixels
    public static func extract(_ image: RgbaImage, region: DetectedPhotoRegion) -> RgbaImage?          // upright, white outside
    public static func extractEnhanced(_ image: RgbaImage, region: DetectedPhotoRegion, dpi: Int) -> RgbaImage?
}
public enum ReceiptEnhancer {
    // tileInches 0.25, backgroundPercentile 0.9, whitePoint 0.90, blackPercentile 0.01, maxBlackPoint 0.6,
    // gamma 1.6, minBackground 0.2, levels 1024
    public static func enhance(_ image: RgbaImage, dpi: Int) -> RgbaImage   // gray (R = G = B), same size
}
public enum ReceiptDateExtractor {
    public static let maxAgeYears: Int                            // 10
    public static let monthNames: [String: Int]                   // folded names and abbreviations, 8 languages
    public static let dateWords: [String], otherDateWords: [String]
    public static func findDate(_ lines: [String], today: DocumentDate, preferDayFirst: Bool) -> DocumentDate?
    public static func fold(_ line: String) -> String              // A–Z lowered, accents and Turkish letters plain, spaces plain
    public static func prefersDayFirst(_ shortDatePattern: String) -> Bool
    public static func prefersDayFirst(locale: Locale = .current) -> Bool   // DateFormatter "ddMMyyyy" pattern (Mac only)
    // internal: datesIn(_ folded: String, preferDayFirst: Bool) -> [DocumentDate]
    // internal: monthAlternation: String   // the month names, longest first, joined by "|": the only words the name patterns take
}
public enum Receipts {
    public static func reviewTitle(_ found: Int) -> String        // "Found 4 receipts"
    public static func saveTitle(included: Int, combine: Bool, format: OutputFormat) -> String   // "Save 3 Receipts", "Save as One PDF"
    public static func combines(_ combine: Bool, format: OutputFormat, count: Int) -> Bool       // asked, PDF, more than one
    public static func namesByDate(_ settings: ScanSettings) -> Bool   // receiptNameByDate and the template has "{docdate}"
    public static func readsText(_ settings: ScanSettings) -> Bool   // namesByDate, or a searchable PDF / its text file
    public static func textLines(_ lines: [OCRLine], pixelWidth: Int, pixelHeight: Int) -> [String]   // OCRText.readingOrder
    public static func combinedDate(_ dates: [DocumentDate?]) -> DocumentDate?                  // the earliest
    public static func savedMessage(count: Int, fileNames: [String], combined: Bool, undated: Int) -> String
    // ". No date was found on …; … named by today's date." after the names; one PDF only when undated == count
}
```
Twin of `windows/CompleteScanner.Core/ReceiptProcessing.cs` (`ReceiptBasis`, `ReceiptRegion`, `ReceiptDetectorOptions`, `ReceiptDetector.PageSearch` / `DetectRegions` / `Find` / `Extract` / `ExtractEnhanced`, `ReceiptEnhancer.Enhance`, `ReceiptDateExtractor.FindDate` / `Fold` / `PrefersDayFirst` / `MonthNames` / `DateWords` / `OtherDateWords`, `Receipts` with `NamesByDate`) and `TaskOptions.ReceiptNameByDate` / `ReceiptCombine`; `ReceiptTests` are the same cases on both sides, on the same synthetic beds (`TestPages.receiptBed`, checked by checksum) and the same 99-case date table (`ReceiptDateCases`, 3 known OCR-noise misses), and the receipt cases of `ScanTaskTests`, `ModelsCompatTests`, `NamingTemplateTests` and `MockScannerTests` match. Everything works on the scan's gray copy at the analysis resolution and the receipts' own pixels (`RgbaImage`), so both platforms find the same regions and write the same cleaned-up pixels; the date patterns are the same regular expressions (.NET `Regex`, `NSRegularExpression`) on the same folded text, the month-name ones built with `monthAlternation` so a word that is not a month never uses up the date after it. The rules: blocks of print (marks over 9 % off the lid's ring median, closed 0.12 in, opened 1 px) one above the other less than 0.6 in apart are one receipt; a block too small to be a receipt joins the receipt next to it (< 0.6 in) or beside it (< 1.5 in, half its height alongside); where the paper shows (a 3 × 3 median off the lid by `pageSearch`'s contrast or 3.7 times the ring's spread, opened, pieces ≥ 0.5 in²) blocks on different sheets never join and a small block joins the receipt on its sheet; each receipt's paper is looked for 0.4 in, then 1.2 in around its print with `findPage(_:options: pageSearch)` and taken when it holds all the print (snapped at full resolution through `DocumentGeometry.refined`), else the print is boxed at the angle of its text lines (`estimateTextLayout`, else its smallest rectangle) with 0.08 in margin; regions merge and sort as photos do. A date must exist and lie between `today.addingYears(-10)` and tomorrow; a part above 12 is the day, dots put the day first, else `preferDayFirst`; two-digit years are 20yy; a line with a date word wins, lines with another-date word are left out, else the first in reading order. The task (`ScanTask.receipt`, flow `.receiptSplit`, any source, 300 dpi grayscale, Compact PDF, searchable, "Receipt {docdate} {counter}") runs in `AppState.performScan`'s `.receiptSplit` case: `showReceipts` finds the receipts on each page (`splitReceipts`: several on the glass, one per feeder sheet, the whole page when none is found; since I13 a receipt a camera's shot was cut into, `CaptureObjects.isCutOut`, is one receipt, cleaned up with `ReceiptEnhancer`), cuts them out cleaned up and opens the photo review with `isReceiptReview` (its title `reviewTitle`, its button `reviewSaveTitle`, "Receipts discarded." on Cancel); Fix crop cuts out and cleans up again (`recutReceipt`); `saveReviewedPhotos` goes to `saveReceipts`: each kept receipt turned as shown, read once with `OCRService` when `Receipts.readsText` (the date only when `Receipts.namesByDate`) (a failure keeps the receipt without a text layer), its date found with `ReceiptDateExtractor.findDate(Receipts.textLines(…), preferDayFirst: prefersDayFirst())`, then a file each (`outputURL(fileExtension:documentDate:)`; PDF pages `.grayscale` at the PDF size, the text layer from the lines read, `writeTextBeside` with `alsoSaveText`, the text file it returns recorded for the rollback; images through `ImageExporter`) or one PDF named by the earliest date, all or nothing; the status is `Receipts.savedMessage`. `AppState` members relaxed for this file: `photoSourceImages`, `switchGeneration`, `PDFTextCollector`, `writeTextBeside`. `setReceiptNameByDate(_:)`, `setReceiptCombine(_:)`, `isReceiptFlow`. Windows has the same members in `AppViewModel.Receipts.cs` (`IsReceiptFlow`, `IsReceiptReview`, `ReviewTitle`, `ReviewSaveTitle`, `SetReceiptNameByDate`, `SetReceiptCombine`; `WritePdfAtomically`'s `knownLines`) and the inspector's Receipts section in `MainWindow.xaml` / `MainWindow.Receipts.cs`; it reads `CultureInfo.CurrentCulture.DateTimeFormat.ShortDatePattern` for the day-or-month preference.

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
    /// Fast reading for rotate pages upright (see Pipeline/Orientation.swift).
    public static func orientationScore(in image: CGImage) throws -> OrientationScore
}
public struct VisionOrientationScorer: OrientationScorer { public init() }
```

### Output/ImageExporter.swift

```swift
public enum ImageExporter {
    /// Write jpeg/png/tiff with DPI metadata. Throws ScanError.unsupported for .pdf, .text and .word.
    /// A black & white page (`colorMode`, the mode it was scanned in) saved as TIFF is a 1-bit CCITT
    /// G4 file (`BilevelTIFF.make`); every other TIFF is LZW (ImageIO).
    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, dpi: Int, jpegQuality: Double,
                             colorMode: ColorMode = .color) throws
}
```

### Core/DocumentSplitter.swift, Core/SavePlan.swift, Pipeline/PatchCodeDetector.swift, App/AppState+Split.swift

```swift
// DocumentOptions gains `splitMode: SplitMode` (.none) and `splitSheetCount: Int` (1) in the
// "document" object. ScannedPage gains `patch: PatchCode?` (what SeparatorStep found),
// `documentBreak: DocumentBreak` (.automatic) and `documentLabel: String?`; copyMeta(from:),
// withGeometry and withVersionsSwapped keep them; withPatch(_:), withDocumentBreak(_:) and
// withDocumentLabel(_:) return the page with one changed.
public enum SplitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, separatorSheet, blankSheet, sheetCount, barcode   // first case = default and fallback; .barcode (M22d) last
    public var label: String                              // "Off", "At separator sheets", "At blank sheets", "Every few sheets", "At QR codes or barcodes"
    public var hint: String                               // a few words: the choice's tooltip
    public var caption: String                            // the one line under the choice ("Separator sheets are left out"); "" where its own controls say it
    public var steps: String                              // how it works, step by step: what the info button next to "Split into documents" shows
    public static let displayOrder: [SplitMode]
}
public enum DocumentBreak: String, Sendable { case automatic, split, join }   // not persisted

public enum PatchCode: String, CaseIterable, Sendable {
    case patch1, patch2, patch3, patch4, patch6, patchT
    public var label: String                              // "Patch 1", "Patch T"
    public var bars: [Bool]                               // reading order, true = wide: 1 = 1100, 2 = 1001, 3 = 1010, 4 = 0110, 6 = 0011, T = 0101
    public static func fromBars(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool) -> PatchCode?   // nil unless exactly two wide
    public var reversed: PatchCode                        // 1 ↔ 6, 3 ↔ T; 2 and 4 read the same
}
public struct PatchCodeHit: Equatable, Sendable { code: PatchCode; verticalBars: Bool; bounds: CGRect; length: Int }   // analysis pixels
public enum PatchCodeDetector {
    // Hundredths of an inch: narrowBar 8, wideBar 20, gap 8 (printed); read as narrow 5–12, wide 15–26,
    // gaps 5–12; quietZone 30; minLength 150; maxStep 2; maxBreak 6; minCoverage 0.5; the sheet's bars
    // 600 long (less on narrow paper), sheetMargin 100.
    public static func detect(_ gray: GrayImage) -> PatchCodeHit?        // reduced to the analysis resolution first
    public static func detect(_ image: RgbaImage, dpi: Int) -> PatchCodeHit?
    public static func detect(_ image: CGImage, dpi: Int) -> PatchCodeHit?   // Mac only: GrayImage(cgImage:sourceDPI:)
    /// White; the code across the sheet 1 in from the top and, half a turn round, 1 in from the
    /// bottom; "SEPARATOR SHEET", the code and how to use and print it in a 5 × 7 dot type between them.
    public static func renderSheet(_ code: PatchCode, widthInches: Double, heightInches: Double, dpi: Int) -> GrayImage
}
public enum SeparatorSheet {                              // the sheet saved as a PDF to print anywhere
    public static let code: PatchCode                     // .patchT
    public static let dpi: Int                            // 300
    public static func paper(regionCode: String?) -> PaperSize    // PaperSizes.defaultForRegion: Letter or A4
    public static func fileBaseName(_ paper: PaperSize) -> String // "Separator sheet (Patch T, Letter)"
    public static func savedMessage(_ fileName: String) -> String // "Saved the separator sheet: …. Print it at actual size (100%), …"
}

public enum PageRole: Sendable { case content, skipped, separator }
public struct PageFacts: Equatable, Sendable {           // every field defaulted in init
    sheetIndex: Int?; side: PageSide?; looksBlank: Bool; patch: PatchCode?
    inclusion: PageInclusion; documentBreak: DocumentBreak; label: String?
    barcode: BarcodeReading?                              // BarcodeSeparators.splittingCode(page.barcodes, options:)
    public static func of(_ page: ScannedPage, options: DocumentOptions) -> PageFacts
}
public struct PlannedPage: Equatable, Sendable { role: PageRole; sheet: Int; document: Int?; startsDocument: Bool; code: BarcodeReading? }
    // document from 1; code: on the sides of a barcode or QR separator sheet, the sheet's code (read on either side), else nil
public struct PlannedDocument: Equatable, Sendable { number: Int; pages: [Int]; label: String? }
public struct SplitPlan: Equatable, Sendable {
    pages: [PlannedPage]; documents: [PlannedDocument]
    var separatorCount: Int; var skippedCount: Int; var pageCount: Int; var isSplit: Bool
}
public enum DocumentSplitter {
    public static let maxSheetCount = 999
    public static func clampSheetCount(_ count: Int) -> Int
    public static func sheets(_ facts: [PageFacts]) -> [Int]            // a front with its back right after it share a sheet
    public static func plan(_ facts: [PageFacts], options: DocumentOptions) -> SplitPlan
    public static func plan(_ pages: [ScannedPage], options: DocumentOptions) -> SplitPlan
    public static let maxLabelLength = 100
    public static func cleaned(_ label: String?) -> String?             // trimmed, cut to maxLabelLength characters, nil when empty
    /// The labels of `after` once a page's inclusion or break changed from `before`: a document whose
    /// first saved page changed keeps the name it showed, moved to its new first page (the old first
    /// page's cleared); otherwise names stay put, also on pages left out, so a document that is gone
    /// comes back with its name and a document split off has its own first page's name.
    public static func carriedLabels(_ before: [PageFacts], _ after: [PageFacts], options: DocumentOptions) -> [String?]
    /// The same once the settings changed too (`before` planned under `beforeOptions`); a name goes to
    /// one document only, the first holding a page of the document it named.
    public static func carriedLabels(_ before: [PageFacts], beforeOptions: DocumentOptions, _ after: [PageFacts], options: DocumentOptions) -> [String?]
    public static func blankPagesAreSeparators(_ options: DocumentOptions, sides: DuplexMode) -> Bool   // blankSheet and one-sided: Skip blank pages has no say
    public static let blankPagesAreSeparatorsHint: String               // why the switch is off then
    public static func canToggleBreak(_ plan: SplitPlan, _ index: Int) -> Bool   // a page saved, not the first one
    public static func toggledBreak(_ facts: [PageFacts], _ index: Int, options: DocumentOptions) -> DocumentBreak   // two clicks undo one
    public static func toggledInclusion(_ facts: [PageFacts], _ index: Int, options: DocumentOptions) -> PageInclusion
    public static func showsBreaks(_ plan: SplitPlan, options: DocumentOptions) -> Bool   // a split chosen, or the queue split by hand
    public static func documentTitle(_ document: PlannedDocument) -> String              // "Document 2 · Lease"
    public static func dividerTitle(_ plan: SplitPlan, _ index: Int) -> String?          // on each document's first page when split
    public static func breakLabel(_ plan: SplitPlan, _ index: Int) -> String?            // "Join with document 1", "Start a new document here"
    public static func badge(_ plan: SplitPlan, _ index: Int, page: ScannedPage, options: DocumentOptions) -> String?        // "Separator", else PageFilter.badge
    public static func toggleLabel(_ plan: SplitPlan, _ index: Int, page: ScannedPage, options: DocumentOptions) -> String?  // "Keep this page", else PageFilter.toggleLabel
    public static func separatorNote(_ plan: SplitPlan, _ index: Int, page: ScannedPage) -> String?   // "Separator sheet (Patch T): a new document starts after it. It is not saved."
                                                          // "Separator sheet (QR code “CS-SEP Lease”): a new document named “Lease” starts after it. It is not saved."
                                                          // (the sheet's code, and the name of the document the plan starts after it)
                                                          // "…: the pages after it are joined to the document before. It is not saved." (joined across the sheet)
    public static func queueSummary(_ pages: [ScannedPage], options: DocumentOptions) -> String       // "9 pages · 3 documents · 2 separator pages skipped"
    public static func scanNote(_ plan: SplitPlan, separatorsAdded: Int) -> String                    // " Found 2 separator pages: 3 documents to save."
}

public struct SaveDocument { number: Int; pages: [ScannedPage]; label: String? }
public struct SavePlan {
    public var documents: [SaveDocument]; public var separatorPages: Int; public var skippedPages: Int
    public static func make(_ queue: [ScannedPage], options: DocumentOptions) -> SavePlan
    public var pageCount: Int; public var isEmpty: Bool; public var isSplit: Bool
    public func fileIndex(_ document: SaveDocument) -> Int?             // its number when split ({index}), else nil
    public static func fileKind(_ format: OutputFormat, count: Int) -> String   // "PDFs", "Word documents", "text files"
    public func saveTitle(_ format: OutputFormat) -> String             // "Save 3 PDFs (7 pages)"; else format.saveTitle(pageCount:)
    public func leftOutNote() -> String                                 // " — 2 separator pages and 1 skipped page were left out"
    /// "Saved 3 PDFs (7 pages, 1.2 MB): A.pdf, B.pdf, C.pdf and their text, A.txt, B.txt, C.txt — 2 separator pages…";
    /// " — no text was found" (all) or " — no text was found in B.txt" for Word and text files with no text.
    public func savedMessage(_ format: OutputFormat, fileNames: [String], size: String? = nil,
                             textFileNames: [String] = [], noTextFound: [String] = []) -> String
    public static func notSavedMessage(_ reason: String) -> String      // "None of the documents was saved; the pages are still in the queue. …"
    public static func failureReason(_ error: Error) -> String          // ScanError.exportFailed's own message (no second "Saving failed: "), else localizedDescription
    public static func writeAllOrNothing(_ files: WrittenFiles, _ write: () async throws -> Void) async throws
}
public final class WrittenFiles { public private(set) var urls: [URL]; public func add(_ url: URL); public func rollBack() }
public struct NotSavedError: LocalizedError, Equatable { public let message: String }   // shown as it is; not a scanner failure
```
Twins of `windows/CompleteScanner.Core/DocumentSplitter.cs` (`PageRole`, `PageFacts.Of`, `PlannedPage`, `PlannedDocument`, `SplitPlan`, `DocumentSplitter` with the same members in PascalCase), `SavePlan.cs` (`SaveDocument`, `SavePlan.Make` / `FileIndex` / `FileKind` / `SaveTitle` / `LeftOutNote` / `SavedMessage` / `NotSavedMessage` / `WriteAllOrNothingAsync`, `WrittenFiles` with `Paths`), `PatchCode.cs` (`PatchCode`, `PatchCodes.Label` / `Bars` / `FromBars` / `Reversed` / `All`, `PatchCodeHit` with `RectD Bounds`, `PatchCodeDetector.Detect` / `RenderSheet`, `SeparatorSheet`) and `SplitMode`, `SplitModes.DisplayOrder`, `ModelLabels.Label` / `Hint`, `DocumentBreak`, `DocumentOptions.SplitMode` / `SplitSheetCount`, `ScannedPage.Patch` / `DocumentBreak` / `DocumentLabel` / `WithPatch` / `WithDocumentBreak` / `WithDocumentLabel` in `Models.cs`, `SeparatorStep` in `PageProcessor.cs`; `PatchCodeTests`, `DocumentSplitterTests` and `SavePlanTests` are the same cases on both sides, on the same synthetic pages (`TestPages.patchPage`, `ruledTable`, `halfTurned`, `quarterTurned`, checked by checksum, and the separator sheet `renderSheet(.patchT, 8.5, 11, 100)` pinned by checksum, so both platforms draw the same sheet), and the split cases of `ModelsCompatTests`, `ScanTaskTests`, `PageProcessorTests`, `NamingTemplateTests` and `MockScannerTests` match. Everything is decided in Core on the queue as it stands, so the user's edits are page facts (kept, skipped, a split, a join, a name) and saving acts on the same plan the strip shows. The patch code is read like a one-dimensional barcode, along the columns of the page's gray copy at the analysis resolution (and along its rows for bars running down the page): ink is darker than half the paper (its 90th percentile); four runs in a row match when each is narrow or wide, exactly two are wide, the gaps are in range and nothing is printed for 0.3 in before and after them; matches on neighbouring lines with the same code that move by at most 0.02 in are one code, which counts over at least 1.5 in on at least half the lines it spans, so a slant of a few degrees reads (±3° checked) and text, tables and rules do not. Every patch code is a separator: read backwards, 1 and 6, 3 and T are each other. The split: a sheet is a front with its back right after it (the same sheet index); at separator sheets, a sheet with a code on either side is a separator; at blank sheets, a sheet blank on every side (one-sided: each blank page; two-sided: only both sides blank, so the blank back of a printed sheet follows Skip blank pages); separators are left out, separators in a row count once, the next page saved starts a document and documents with no page are dropped; every N sheets counts every sheet, blank ones too; Keep on a page makes its sheet no separator; a split or join at a page wins over the setting; a document's name is the first among its pages saved, and a change that moves a document's first saved page (Keep, Skip, a split or join, or a change of Skip blank pages, what counts as blank or the split) moves its name with it (`carriedLabels`). `SeparatorStep` runs on every page collected in the queue whatever the split (so a split chosen later finds them), after crop and straighten. At barcode or QR sheets (`.barcode`, M22d, see "Pipeline/Barcodes.swift" below) a sheet with a code starting with `splitBarcodePrefix` on either side is a separator and the rest of the code's text (`BarcodeSeparators.codeLabel`) names the document after it, the last such sheet before it when several are in a row, while other codes are ignored; with `barcodeStartsDocument` a sheet with any code is kept and starts a document named by its code (without the prefix when it has it); the first code that counts on a sheet does (`splits`), and the separator sheet's sides carry it (`PlannedPage.code`) for `separatorNote`; a name the user gives wins, and `carriedLabels` moves only names the user gave (a code's name follows its code by itself). `AppState` (`App/AppState+Split.swift`): `queuePlan`, `queueSavePlan`, `queueScanNote(_:options:)` (the scan's status: blank pages among the added pages not counting separators, corrections, then `scanNote`), `toggleDocumentBreak(id:)` (and `togglePageInclusion(id:)`) then `carryDocumentLabels(from:options:)`, `carryDocumentLabels(settingsBefore:)` (from `settings`' didSet when `settings.document` changed), `documentLabel(of:)`, `setDocumentLabel(id:label:)` (the name goes on the document's first page, others in it are dropped), `setSplitMode(_:)`, `setSplitSheetCount(_:)`, `saveDocuments(_:settings:queued:flag:)` (called by `savePDF` for a split queue: a file per document, PDF with its text beside it when asked for, or Word or text, named with `index` = the document's number and `label` = its name, all or nothing: a failure or Cancel removes every file written, `NotSavedError(SavePlan.notSavedMessage(SavePlan.failureReason(…)))` or cancelled, the queue kept; the status gives the PDFs' size together, the text files beside them and the files with no text; the last PDF's size is the last document's), `saveSeparatorSheet()` (Patch T as a one-page PDF at 300 dpi on `SeparatorSheet.paper(regionCode:)`, in the scans folder under `SeparatorSheet.fileBaseName`, the next free name; recorded as saved; no printer needed), `printSeparatorSheet()` (Patch T on the printer chosen for copies, on the paper it has, whatever the scan's paper size, 300 dpi, actual size from the corner, one copy); `togglePageInclusion(id:)` goes through `toggledInclusion`, `savePDF` through `SavePlan` (one document saves as before, with its name and `leftOutNote`), `outputURL` gains `label:`. Members relaxed for this file: `textLayer`, `writeTextDocument`, `deleteSpoolFiles`, `destinationDirectory`. Windows has the same members in `AppViewModel.Split.cs` (`QueuePlan`, `QueueSavePlan`, `ToggleDocumentBreak`, `CarryDocumentLabels`, `CarryDocumentLabelsAcrossSettings` (from `SettingsEdited`), `DocumentLabelOf`, `SetDocumentLabel`, `SetSplitMode`, `SetSplitSheetCount`, `SaveDocuments`, `SaveSeparatorSheet`, `PrintSeparatorSheet`; `PageSplitView` on each `PageItem`) and the strip's gap, badges and name box in `MainWindow.xaml` / `MainWindow.Split.cs`.

### Pipeline/Barcodes.swift, Output/BarcodeServices.swift (+ SplitMode, DocumentOptions, ScannedPage in Core/Models.swift, BarcodeStep in Pipeline/PageProcessor.swift)

```swift
// ScannedPage gains `barcodes: [BarcodeReading]?` (nil: not read; [] none found; reading order);
// copyMeta(from:), withGeometry, withSpineShadow and withVersionsSwapped keep it; withBarcodes(_:) sets it.
// PatchCodeDetector's `drawText`, `fillRect` and `hasGlyph(_:)` are internal (the 5 × 7 type gains ? : / _ # + , & ' !).
public enum BarcodeSymbology: Int, CaseIterable, Sendable {
    case qrCode, code128, code39, dataMatrix
    public static let all: [BarcodeSymbology]; public var label: String   // "QR code", "Code 128", "Code 39", "Data Matrix"
}
public struct BarcodeReading: Equatable, Sendable { symbology: BarcodeSymbology; text: String; bounds: CGRect }   // pixels, top-left
public protocol BarcodeReader {                           // C# IBarcodeReader (Read(GrayImage, CancellationToken))
    var isAvailable: Bool { get }
    func read(_ image: GrayImage) throws -> [BarcodeReading]   // bounds in the image's pixels, any order
}
public enum BarcodeSeparators {
    public static let readingDPI = 200                    // pages are read as gray at 200 dpi (coarser: as they are)
    public static let defaultPrefix = "CS-SEP"            // what a separator sheet's code starts with
    public static let unnamedText = "SEPARATOR"           // a sheet that names nothing (compared ignoring a–z case)
    public static let maxNoteTextLength = 40
    public static func startsDocumentHint(_ on: Bool, prefix: String? = nil) -> String   // off: names the prefix
    public static func prefix(_ prefix: String?) -> String               // trimmed; empty: every code is a separator code
    public static func startsWithPrefix(_ text: String, _ prefix: String?) -> Bool
        // a–z matching A–Z, compared in UTF-16 code units after the spaces, control and format characters text starts with
    public static func splits(_ reading: BarcodeReading?, options: DocumentOptions) -> Bool   // barcodeStartsDocument: any code; else the prefix
    public static func splittingCode(_ readings: [BarcodeReading]?, options: DocumentOptions) -> BarcodeReading?   // the first that splits
    public static func codeLabel(_ text: String?, options: DocumentOptions) -> String?    // label of the text after the prefix (all of it without)
    public static func isSeparatorPage(_ page: ScannedPage, options: DocumentOptions) -> Bool   // .barcode, switch off, a separator code
    public static func readingImage(_ image: RgbaImage, dpi: Int) -> GrayImage
    public static func read(_ image: RgbaImage, dpi: Int, reader: any BarcodeReader) throws -> [BarcodeReading]
    public static func read(_ image: CGImage, dpi: Int, reader: any BarcodeReader) throws -> [BarcodeReading]   // Mac only
    public static func readPage(_ page: ScannedPage, reader: any BarcodeReader) throws -> [BarcodeReading]
        // the pixels the page holds (a spooled page's preview, at the resolution that gives); bounds in full-size pixels
    public static func readQueuedPage(_ page: ScannedPage, spoolImage: CGImage?, reader: any BarcodeReader) throws -> [BarcodeReading]?
        // C# RgbaImage? spoolImage: the spool file's pixels turned by rotationQuarterTurns, at page.dpi; without one, readPage,
        // and nil (not settled) when that read a coarser preview and found nothing
    public static func inReadingOrder(_ readings: [BarcodeReading]) -> [BarcodeReading]
        // by the bounds' top, then left, then kind, then as read; no empty texts; one reading per kind and text
    public static func first(_ readings: [BarcodeReading]?) -> BarcodeReading?
    public static func label(_ text: String?) -> String?  // format characters (BOM, zero-width, bidi) dropped, controls and
                                                          // space runs → one space, / \ : * ? " < > | → "-",
                                                          // DocumentSplitter.cleaned; nil for nothing or unnamedText
    public static func describe(_ reading: BarcodeReading) -> String   // "QR code “Lease”", the text cut to 40 with "…"
}
public struct QrModules: Equatable, Sendable {            // size × size, row by row, true dark, no quiet zone
    public init?(size: Int, dark: [Bool])                 // C# throws where this returns nil
    public let size: Int; public let dark: [Bool]; public subscript(x: Int, y: Int) -> Bool
}
public protocol QrEncoder { func encode(_ text: String) -> QrModules? }   // UTF-8, level M; C# IQrEncoder
public enum QrSeparatorSheet {
    public static let dpi = 300; codeSideHundredths = 250; codeTopHundredths = 180; jobName = "Separator sheet (QR code)"
    public static func text(_ name: String?, prefix: String = BarcodeSeparators.defaultPrefix) -> String
        // "CS-SEP Lease" (prefix, a space, label(name)); the prefix alone with no name; empty prefix: label(name) ?? unnamedText
    public static func caption(_ text: String) -> String  // the 5 × 7 type: accents dropped, a–z → A–Z, others "?"
    public static func render(_ code: QrModules, name: String?, widthInches: Double, heightInches: Double, dpi: Int) -> GrayImage
        // "SEPARATOR SHEET" 1 in down; the code (≤ 2.5 in with a 4-module quiet zone, whole pixels a module) 1.8 in down,
        // centred; "THE NEXT DOCUMENT IS NAMED" and the caption (0.04 in dots, down to 0.02, then cut with "...") or
        // "A NEW DOCUMENT STARTS AFTER THIS SHEET."; how to use it 1.5 and 1.2 in from the bottom
    static func drawCaption(_ pixels: inout [UInt8], _ w: Int, _ h: Int, _ caption: String, top: Int, dpi: Double) -> Int
    public static func fileBaseName(_ name: String?, paper: PaperSize) -> String   // "Separator sheet (QR code, Lease, Letter)"
    public static func savedMessage(_ fileName: String, name: String?) -> String
    public static func printedMessage(_ printer: String, name: String?) -> String
}
public enum Code39 {                                      // the demo scanner's barcode sheets and the tests' pages
    public static let wideRatio = 3
    public static func canEncode(_ text: String) -> Bool  // 0–9 A–Z space - . $ / + %
    public static func modules(_ text: String) -> [Bool]  // '*'-framed, a narrow space between characters
    public static func renderSheet(_ text: String, widthInches: Double, heightInches: Double, dpi: Int) -> GrayImage
        // "SEPARATOR SHEET", the code 1.8 in down (0.02 in modules, 0.8 in tall), the caption, "A NEW DOCUMENT STARTS AFTER THIS SHEET."
}
// Output/BarcodeServices.swift (Mac only):
public struct VisionBarcodeReader: BarcodeReader          // VNDetectBarcodesRequest for .qr, .code128, .code39, .dataMatrix
public struct CoreImageQrEncoder: QrEncoder               // CIQRCodeGenerator, level "M"; the modules are the box around its dark pixels
```
Twins of `windows/CompleteScanner.Core/Barcodes.cs` (`BarcodeSymbology`, `BarcodeSymbologies.All` / `Label`, `BarcodeReading` with `RectD Bounds`, `IBarcodeReader`, `BarcodeSeparators` with `ReadingDpi`, `DefaultPrefix`, `UnnamedText`, `ReadPage`, `ReadQueuedPage`, `SplittingCode`, `CodeLabel`, …, `QrModules`, `IQrEncoder`, `QrSeparatorSheet`, `Code39`), `SplitMode.Barcode`, `DocumentOptions.BarcodeStartsDocument` / `SplitBarcodePrefix`, `ScannedPage.Barcodes` / `WithBarcodes`, `PageFacts.Barcode`, `PlannedPage.Code`, `BarcodeStep`, `OrientationStep.Split` and `PageProcessor.ReadsBarcodes`; the rule (output.md): split at barcode or QR sheets with the switch off, only a code starting with `splitBarcodePrefix` (default "CS-SEP", which the QR sheets carry: "CS-SEP Lease") makes its sheet a separator, and the rest of its text names the document after it; other codes (a payment QR code, an order number printed on a document) are ignored, so a document page is never taken for a separator; an empty prefix makes every code one. With `barcodeStartsDocument` every code starts a document, named by its text (without the prefix when it has it). Separator pages are not saved, and saving deletes them with the rest of the queue's spool files, so a page wrongly taken for one is lost unless kept in the strip first; `BarcodeTests` is the same cases on both sides with a stand-in reader, the QR sheet (a made-up 25-module pattern at 100 and 150 dpi) and the demo's Code 39 sheet pinned by checksum, so both platforms draw the same sheets; the barcode cases of `ModelsCompatTests`, `MockScannerTests` and the summary in `TaskCatalog` match. Windows reads with ZXing.Net 0.16.11 in the app only (`ZXingBarcodeReader`: the image as given, then at half resolution, then likely Data Matrix spots one at a time, each only when nothing was found; `ZXingQrEncoder`: UTF-8 with its ECI marker, level M). Barcodes are read only while the split is `.barcode` (`readsBarcodes`; no task chooses it); choosing it (by hand or with a preset: `readsBarcodes` turning true in `settings`' didSet; Windows `SettingsEdited`, which tracks the last value) reads the pages already queued that were never read (`AppState.readQueuedBarcodes()`; Windows `AppViewModel.ReadQueuedBarcodes`), each on its full-resolution spool file (`readQueuedPage`; the preview only when there is none), with the count read in the status (and Windows' progress bar); other settings edits start nothing. A page the reading could not settle (the reader failed, or only a preview was read and showed nothing) stays nil and is kept in `barcodesUnsettled` (Windows `_barcodesUnsettled`), read again only when the split is chosen again. Cancel keeps what was read; the pages left are read after the next scan (`readBarcodesAfterWork`, set when a scan adds pages under the split, run from `endOfWork`; Windows `EndOfWork`), or when the split is chosen again, and the status says so. A reading asked for while another operation runs waits for it the same way. Windows' `SetSplitMode` and `ApplyPreset` leave the reading's status in place (the Mac's runs after them). `AppState`: `barcodeReader` (default `VisionBarcodeReader()`) and `qrEncoder` (default `CoreImageQrEncoder()`) are `init` parameters; `qrSheetName` (published, not stored) is the name the next QR sheet carries; `setBarcodeStartsDocument(_:)`; `saveSeparatorSheet()` and `printSeparatorSheet()` make the QR sheet (its code `QrSeparatorSheet.text(qrSheetName, prefix: splitBarcodePrefix)`) instead of Patch T when the split is `.barcode` and `barcodeStartsDocument` is off (`printsQrSheets`, `renderSeparatorSheet(code:name:widthInches:heightInches:)`), named `QrSeparatorSheet.fileBaseName`, with `savedMessage` / `printedMessage`; `setDocumentLabel` says when a removed name leaves the barcode's. Windows has the same members in `AppViewModel.Split.cs` (`QrSheetName`, `SetBarcodeStartsDocument`, `ReadQueuedBarcodes`, `SaveSeparatorSheet`, `PrintSeparatorSheet`) and the inspector's switch, name box and buttons in `MainWindow.xaml` / `MainWindow.Split.cs`.

### Output/NamingTemplate.swift

```swift
public struct NamingTemplate {
    public let template: String
    public init(_ template: String)
    /// Tokens: {date}=yyyy-MM-dd, {time}=HH.mm.ss, {year} {month} {day}, {counter} (also {counter:N}
    /// zero-padded), {intent} ("Document"/"Photos"), {index} (photo number in a batch, empty when nil),
    /// {task} (the task's `fileLabel`; the {intent} text without a task), {docdate} (the context's
    /// `documentDate`, yyyy-MM-dd; the date of `date` without one), {label} (the context's `label`,
    /// trimmed and cut to `maxLabelBytes` bytes of UTF-8 between characters; empty without one;
    /// tokens in it are not expanded).
    /// Unknown tokens pass through; result sanitized for the filesystem (no "/" or ":").
    public func baseFilename(_ context: NamingContext) -> String
    /// The same without a task (kept for existing callers).
    public func baseFilename(counter: Int, date: Date, intent: ScanIntent, index: Int?) -> String
    public static let maxLabelBytes = 120
    /// base.ext, appending " 2", " 3", … until the name is free.
    public static func uniqueURL(in directory: URL, base: String, fileExtension: String) -> URL
}
```

```swift
public struct NamingContext: Equatable, Sendable {
    public var counter: Int, date: Date, intent: ScanIntent
    public var index: Int?          // default nil
    public var task: ScanTask?      // default nil
    public var documentDate: DocumentDate?   // default nil: {docdate} is the scan date
    public var label: String?                // default nil: {label} is empty
    public init(counter: Int, date: Date, intent: ScanIntent, index: Int? = nil, task: ScanTask? = nil,
                documentDate: DocumentDate? = nil, label: String? = nil)
}

/// A calendar day with no time and no time zone: the date printed on a document.
public struct DocumentDate: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int)
    public init(date: Date, timeZone: TimeZone = .current)            // the Gregorian day of `date`
    public static func make(year: Int, month: Int, day: Int) -> DocumentDate?   // nil unless the day exists
    public static func isValid(year: Int, month: Int, day: Int) -> Bool
    public static func daysInMonth(year: Int, month: Int) -> Int
    public var dayNumber: Int { get }                                  // days since 1970-01-01
    public func addingYears(_ years: Int) -> DocumentDate              // 29 Feb → 28 Feb in a common year
    public var text: String { get }                                    // "2026-03-12" (also `description`)
}
```
Twin of C# `NamingContext` (a record with `Index` / `Task` / `DocumentDate` init properties) and `DocumentDate` (a record struct: `Of(DateTime)`, `TryCreate`, `IsValid`, `DaysInMonth`, `DayNumber`, `AddingYears`, `ToString()` "2026-03-12"); `NamingTemplateTests` and the `DocumentDate` cases of `ReceiptTests` are the same on both sides. Later tokens add optional properties here, so `baseFilename(_:)` keeps its signature.

```swift
// Output/NamingTokens.swift (I15): what the file name field offers around NamingTemplate
public struct NamingToken: Equatable, Sendable { public let label: String, token: String, help: String }
public struct NamingInsertion: Equatable, Sendable { public let text: String; public let caret: Int }
public enum NamingTokens {
    public static let all: [NamingToken]          // Date {date}, Time {time}, Number {counter}, Mode {intent}, Task {task},
                                                  // Document name {label}, Receipt date {docdate}
    public static let known: [String]             // every token NamingTemplate replaces; {counter:N} is known too
    public static let emptyProblem: String        // "Needs a file name"
    public static func unknownProblem(_ token: String) -> String   // "Unknown part {foo}"
    public static func insert(_ token: String, into text: String, at offset: Int) -> NamingInsertion
                                                  // offset kept within the text (C#: UTF-16 units, Swift: characters);
                                                  // a space before it unless after whitespace or at the start
    public static func problem(_ template: String) -> String?      // blank, else the first unknown token in braces; nil
    public static func isKnown(_ token: String) -> Bool
    public static func braced(_ template: String) -> [String]      // "{" to the next "}" with no "{" between
    public static func savedFormat(_ s: ScanSettings) -> OutputFormat   // receipts pageFormat, photos imageFormatOrJPEG,
                                                                        // collected pages queueFormat, else format
    public static func example(_ template: String, settings: ScanSettings, format: OutputFormat, counter: Int,
                               date: Date) -> String            // "Scan 2026-10-20 4.pdf", for the settings' task
}
```
Twin of C# `NamingTokens` (`All`, `Known`, `EmptyProblem`, `UnknownProblem`, `Insert`, `Problem`, `IsKnown`, `Braced`, `SavedFormat`, `Example(template, s, format, counter, DateTime)`); `NamingTokensTests` are the same on both sides. The Windows Insert menu, its caret insertion and the file name preview (`AppViewModel.FileNamePreview`) use it; the Mac's naming popover keeps its own list for now. `AppState.fileNameExample(_:format:)` (Swift only) is the example with the running number read, not taken (the Windows `FileNamePreview`).

### App shells: App/PlatformLifecycle.swift, AppState.ingest (Swift only)

```swift
/// When the app may end and when it comes to the front, as the platform reports it.
@MainActor public protocol PlatformLifecycle: AnyObject {
    func observeWillTerminate(_ handler: @escaping @MainActor () -> Void)    // the app may end now: it is quitting (iOS: also gone to the background)
    func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void)  // each time the app comes to the front
}
// CompleteScannerMac/App/AppKitLifecycle.swift:  @MainActor public final class AppKitLifecycle: PlatformLifecycle { public init(center: NotificationCenter = .default) }
//   NSApplication.willTerminateNotification, didBecomeActiveNotification, delivered on the main queue
// CompleteScannerIOS/UIKitLifecycle.swift:       @MainActor public final class UIKitLifecycle: PlatformLifecycle { public init(center: NotificationCenter = .default) }
//   UIApplication.didEnterBackgroundNotification and willTerminateNotification; didBecomeActiveNotification

/// Time the system gives the app to finish work once it is in the background (I11; a network scanner's job asks for it).
@MainActor public protocol BackgroundActivity: AnyObject {
    func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int?   // nil: no time given; `expired` runs (once) when it is nearly up;
                                                                                          // the work then stops and gives the time back itself (it ends by itself when fully up)
    func endActivity(_ token: Int)                                                        // a token that has ended already is ignored
}
// CompleteScannerIOS/UIKitBackgroundActivity.swift: @MainActor public final class UIKitBackgroundActivity: BackgroundActivity {
//   public typealias Begin = @MainActor (String, @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
//   public typealias End = @MainActor (UIBackgroundTaskIdentifier) -> Void
//   public typealias Remaining = @MainActor () -> TimeInterval
//   public static let windDownTime: TimeInterval   // 10: the time left at which the work is told to stop
//   public convenience init()                       // UIApplication.shared.beginBackgroundTask(withName:expirationHandler:) /
//                                                   // endBackgroundTask / backgroundTimeRemaining
//   public init(begin: @escaping Begin, end: @escaping End, remaining: @escaping Remaining = { .greatestFiniteMagnitude })
//   public var runningCount: Int { get }; func checkRemaining()   // internal; run every second while a task runs
//   time left <= windDownTime: the work's `expired`, the task kept until endActivity;
//   UIKit's expiration: the work's `expired` unless it ran already, then the task is ended }
// The Mac passes none (a Mac app keeps running in the background).

@MainActor public final class AppState: ObservableObject {   // the members the app shells use
    public convenience init(backends: [any ScannerBackend]? = nil, presetStore: PresetStore = PresetStore(),
                            fileActions: (any FileActionService)? = nil, troubleshooterService: (any TroubleshooterService)? = nil,
                            printService: (any PrintService)? = nil, orientationScorer: (any OrientationScorer)? = nil,
                            barcodeReader: (any BarcodeReader)? = nil, qrEncoder: (any QrEncoder)? = nil,
                            lifecycle: (any PlatformLifecycle)? = nil,
                            keepsQueue: Bool = false)   // files: AppStateFiles.standard; keepsQueue: .keepingQueue
                                                        // (makeForIOS, not under -demoScanner)
    init(/* the same */, files: AppStateFiles)                     // internal: tests pass AppStateFiles.all(in: folder)
    public static func makeDemoBackend() -> MockScannerBackend     // the demo scanner; its second sheet's back is blank
    public func revealInFinder(_ url: URL)                         // through FileActionService.reveal
    /// Pages captured outside a scanner session (a camera, a phone, a file): marked with `source`,
    /// cleaned up for it, recorded in the history and handled as the task says, as a scan's pages are.
    /// false when they were not taken (none, `canIngest` false, or the ID card's sides are in).
    @discardableResult public func ingest(_ pages: [ScannedPage], source: PageSource) -> Bool
    /// Not busy, not turning a stack over by hand, no photo or receipt review and no ID card review open.
    public var canIngest: Bool { get }
}
/// Where an AppState keeps its files (internal).
struct AppStateFiles {
    var settingsDirectory: URL      // settings.json, read when the AppState is made and written
    var spoolDirectory: URL         // the queued pages' (and spreads') spool TIFFs; emptied when the AppState is made,
                                    // but for a queue kept
    var diagnosticsFile: URL?       // devices.txt; nil: not written
    var keepsQueue: Bool = false    // the queue recorded beside the spool (queue.json, QueueRecord) and brought back
    static var standard: AppStateFiles             // Application Support, $TMPDIR/CompleteScanner-pages, ~/Library/Logs/CompleteScanner/devices.txt
    static var keepingQueue: AppStateFiles         // standard, the spool in Application Support/.../Pages (out of backups), keepsQueue
    static func all(in folder: URL) -> AppStateFiles   // folder, folder/pages, folder/devices.txt
}
// CompleteScannerMac/App/CompleteScannerApp.swift:
extension AppState { @MainActor static func makeForMac() -> AppState }   // [ICScannerBackend(), makeDemoBackend()], System* services, AppKitLifecycle(),
                                                                          // setUpCompanionHost with the keychain identity, MacNetworkSource, MacDnsSdAdvertiser

// CompleteScannerIOS/IOSShell.swift:
public struct IOSLaunchOptions: Equatable, Sendable {
    public static let demoScannerArgument = "-demoScanner"
    public static let importFixtureArgument = "-importFixture"     // the import UI test's: import one photo at launch
    public static let importFixtureVariable = "COMPLETESCANNER_IMPORT_FIXTURE"   // its PNG bytes, base64; I14: several, comma-separated
    public static let importFixtureName = "fixture.png"
    public static let importFixturePDFName = "fixture.pdf"         // I14: a file whose bytes start "%PDF" comes in as a PDF
    public let demoScannerOnly: Bool
    public let launchImports: [IOSImportItem]                      // I14: in order; empty without both the argument and readable bytes
    public var launchImport: IOSImportItem? { get }                // the first
    public static let importTaskArgument = "-importTask"           // I13: the next argument names the task (ScanTask's raw value)
    public let launchTask: ScanTask?                               // I13: the task the photo goes into; nil without a photo
    public init(demoScannerOnly: Bool)
    public init(arguments: [String])                               // ProcessInfo.processInfo.arguments
    public init(arguments: [String], environment: [String: String])
}
public enum IOSShell {
    @MainActor public static func backends(options: IOSLaunchOptions) -> [any ScannerBackend]   // [AppState.makeDemoBackend()]: tests, previews
    // I12, the app's: networkScanners.backend alone; the demo scanner alone under demoScannerOnly or without one
    @MainActor public static func backends(options: IOSLaunchOptions, networkScanners: IOSNetworkScanners?) -> [any ScannerBackend]
    public static func keepsScreenAwake(isBusy: Bool, device: ScannerInfo?) -> Bool   // I12: busy with an "escl" device
    // I11, internal: `network` alone, else (demoScannerOnly, or no network) the demo scanner alone; an eSCL connection to
    // `endpoints` whose jobs UIKitBackgroundActivity() covers
    @MainActor static func backends(options: IOSLaunchOptions, network: EsclScannerBackend?) -> [any ScannerBackend]
    @MainActor static func networkBackend(endpoints: [EsclEndpoint], trust: EsclTrustStore,
                                          clientOptions: EsclClientOptions = EsclClientOptions()) -> EsclScannerBackend
    public static func offers(_ task: ScanTask) -> Bool          // takesPhotos' flows (I13: Photos, Restore old photos, ID card and
                                                                  // Receipts too; I14: Quick scan and Archive document; I16: the photocopy)
    public static func takesPhotos(_ settings: ScanSettings) -> Bool   // I13: .documentQueue, .photoSplit, .receiptSplit, .idCard; I16: .copy
    public static func collectsPages(_ settings: ScanSettings) -> Bool // .documentQueue and documentMultiPage (Save and PDF or JPEG on the
                                                                  // scan screen; I14: not Quick scan, which saves from its own screen)
    public static func offersPDFOptions(_ settings: ScanSettings) -> Bool   // I14: collectsPages and Save writes a PDF (size, Archive, Password)
    // Save, its menu and Export (the printer screen's row and option group, camera mode's floating Save and drawer group):
    // collectsPages, or .documentQueue with pages queued (Collect pages before saving turned off over them, a failed
    // Word or Text save's pages put back)
    public static func offersSave(_ settings: ScanSettings, pageCount: Int) -> Bool
    public static let notYetReason = "Not in this version yet"
    public static func offersCamera(_ task: ScanTask?) -> Bool   // Apple's scanner: IOSDocumentCamera.tasks: .document, .email, .word
    public static func offersOwnCamera(_ settings: ScanSettings) -> Bool   // our camera (I8; the default since I9): takesPhotos (I13)
    public static let scanModeKey = "scan.mode"       // UserDefaults: IOSScanMode's raw value, camera by default
    public static let scannerKey = "scan.scanner"     // UserDefaults: the scanner printer mode scans with, kept in camera mode
    // printer mode's scanner, `scanner`, while it is listed and selected; nil in camera mode, or until it is found
    public static func printerScanner(_ mode: IOSScanMode, scanner: String, selected: String?,
                                      devices: [ScannerInfo]) -> ScannerInfo?
    // the listed row of that scanner, its own or another connection of it in `groups`; nil when not listed or none
    public static func listedScanner(_ scanner: String, devices: [ScannerInfo], groups: [DeviceGroup]) -> String?
    // what the selection follows: listedScanner in printer mode, none in camera mode
    public static func followedScanner(_ mode: IOSScanMode, scanner: String, devices: [ScannerInfo],
                                       groups: [DeviceGroup]) -> String?
    // internal: oldSourceKey ("scan.source"); migratedScanner(_ defaults:), once: its scanner when no mode is kept, key removed
    public static func capturesContinuously(_ settings: ScanSettings) -> Bool   // I9: the queue and documentMultiPage; I13: the ID card
    public static let exportFormats: [OutputFormat]                              // Options' Export: [.pdf, .jpeg, .word, .text]
    public static func exportFormat(_ settings: ScanSettings) -> OutputFormat    // picture formats as .jpeg
    public static func savesImages(_ settings: ScanSettings) -> Bool             // format.isImageFormat: AppState.saveImages
    public static func saveTitle(_ settings: ScanSettings, plan: SavePlan) -> String   // "Save 3 JPEGs", else plan.saveTitle
    // camera mode's floating Save: "Save PDF · 3"; "Add to <file>" with a target, saveTitle for pictures or a split queue
    public static func floatingSaveTitle(_ settings: ScanSettings, plan: SavePlan, target: URL?) -> String
    @MainActor public static func saveQueue(_ state: AppState)   // Save without After saving: savePDF (into the target), or saveImages
    // the keep-pages question (KeepPagesQuestion): "Keep the 3 pages?" / "Keep the page?"; the line is the reason then
    // "Save them first, or discard them.", or "They cannot be saved now: discard them, or cancel to keep them." without
    // Save first; "Discard 3 pages"; "Save PDF first", "Save 3 JPEGs first", "Add to Contract.pdf first"
    public static func keepPagesTitle(_ count: Int) -> String
    public static func keepPagesLine(_ reason: String, count: Int, canSave: Bool) -> String
    public static func keepPagesReason(_ kind: IOSScanKind) -> String          // "Photos does not collect pages."
    public static func keepPagesReason(preset name: String) -> String          // "The preset “Receipts” does not collect pages."
    public static func keepPagesReason(package fileName: String) -> String     // "“Trip.csdoc” opens in their place."
    public static func discardPagesLabel(_ count: Int) -> String
    public static func saveFirstLabel(_ settings: ScanSettings, pageCount: Int, target: URL?) -> String
    public static let cameraKinds: [IOSScanKind]       // camera mode's row: photos, receipts, document, idCard, book, text
    // I20: collectsPages and a desktop paired that still knows the phone (.checking, .reachable, .unreachable)
    public static func offersSendToComputer(_ settings: ScanSettings, status: CompanionStatus) -> Bool
    // I20, internal: setUpCompanion(in: folder, secrets:), the browse's seen ids and desktopFound, and on `lifecycle`:
    // becoming active with a desktop pulls, checks (browsing meanwhile; one that did not answer is checked again after 3 s
    // more of browsing) and drains; a desktop that did not answer and is found at new addresses is checked and drained there;
    // may-end (the background) stops pulling
    @MainActor static func setUpCompanion(_ state: AppState, folder: URL, secrets: any CompanionSecretStore,
                                          browser: IOSCompanionBrowser?, lifecycle: any PlatformLifecycle)
    public static func availability(_ card: TaskCard) -> TaskAvailability   // notYetReason (none since I16), else the card's own
    public static func systemImage(_ iconKey: String) -> String               // the Mac's TaskSymbols
    // Two modes on the iPhone: the task it opens on, the card before the camera's prompt, the step card
    public static func launchTask(_ settings: ScanSettings) -> ScanTask      // settings.task when offered, else .document;
                                                                  // .copy and .email as .document
    public static func savingActionsAsDocument(_ settings: ScanSettings) -> ScanSettings   // .copy / .email task: .document,
                                                                  // afterSave .none; pdfSize kept
    public static let cameraIntroKey = "camera.introShown"                   // UserDefaults: the card before the prompt was shown
    public static func cameraOnOpen(offersCamera: Bool, camera: IOSCameraAvailability, authorization: AVAuthorizationStatus,
                                    introShown: Bool, demo: Bool) -> IOSCameraOnOpen   // .stay under demo, in printer mode or
                                                                  // without camera.isAvailable; .introduce while .notDetermined and not shown
    // the camera's line in place of the step's: nil for the ID card, and in printer mode or turning over by hand unless a
    // back is due or a new document pending
    public static func cameraLine(_ task: ScanTask?, options: TaskOptions, sides: CameraSides?, newDocument: Bool,
                                  turningOverByHand: Bool, printer: Bool) -> CameraStepText?
    public static func showsStepCard(_ task: ScanTask?, options: TaskOptions, sides: CameraSides?, newDocument: Bool,
                                     turningOverByHand: Bool, printer: Bool) -> Bool   // back due, new document, or cameraLine nil
    // The kinds the printer screen's chips and camera mode's row offer and the options that change the task under the hood
    public static func kind(of task: ScanTask) -> IOSScanKind                  // document tasks and the copy: .document; .photoRestore: .photos
    public static func shownKind(_ settings: ScanSettings) -> IOSScanKind      // kind(of: TaskCatalog.infer(settings))
    public static func kindTiles(_ cards: [TaskCard], current: IOSScanKind,
                                 order: [IOSScanKind] = IOSScanKind.allCases) -> [IOSKindTile]
    public static func settingBothSides(_ on: Bool, in settings: ScanSettings) -> ScanSettings   // .twoSided / .document on the flatbed
    public static func separatesDocuments(_ settings: ScanSettings) -> Bool   // split at separator or QR sheets
    public static func settingSeparate(_ on: Bool, in settings: ScanSettings) -> ScanSettings    // .batch with its names / .document on the flatbed
    public static func savesEachPage(_ settings: ScanSettings) -> Bool        // .sheetCount, one sheet each
    public static func settingEachPage(_ on: Bool, in settings: ScanSettings) -> ScanSettings
    public static func eachPageTitle(_ settings: ScanSettings) -> String   // "One PDF per sheet" with the feeder's both sides, else "One PDF per page"
    public static func settingRestore(_ on: Bool, in settings: ScanSettings) -> ScanSettings     // .photoRestore / .photos
    public static func keepingKind(_ settings: ScanSettings) -> ScanSettings  // an unfit task: its kind's task when it fits, else none
}
public enum IOSScanKind: String, CaseIterable, Identifiable, Sendable { case document, photos, receipts, idCard, book, text }
    // title, subtitle, symbol, task (.document, .photos, .receipt, .idCard, .book, .quickScan)
public struct IOSKindTile: Identifiable, Equatable { kind, summary, availability, isCurrent; accessibilityValue }
public enum IOSCameraOnOpen: Equatable, Sendable { case open, introduce, stay }
public enum IOSScanMode: String, Sendable { case camera, printer }   // the phone's mode, also where the pages come from
extension AppState { @MainActor public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions) -> AppState
    // networkScanners: nil
    @MainActor public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions,
                                             networkScanners: IOSNetworkScanners?,
                                             passwordPrompt: IOSPasswordPrompt? = nil,
                                             printService: IOSPrintService? = nil,
                                             confirmAppend: (@MainActor (String) async -> Bool)? = nil,
                                             companion: IOSCompanionBrowser? = nil) -> AppState }
//   IOSShell.backends(options:networkScanners:), the given IOSFileActions, IOSTroubleshooterService(), UIKitLifecycle(),
//   platform .ios; I14: askPDFPassword asks passwordPrompt (none: a protected save saves nothing); I16: prints through printService
//   (none: IOSPrintService()); I17: accessPDFForAppend is always IOSPDFAppend.access, confirmAppend asks before adding
//   pages to a signed or PDF/A file (none: such a file gets no pages); I20: IOSShell.setUpCompanion in
//   IOSNetworkScanners.filesFolder() with IOSCompanionSecrets(), browsed by `companion` (none: not browsed), on the UIKitLifecycle;
//   C2: resolveSyncFolderBookmark is IOSSyncFolder.resolve

// CompleteScannerIOS/Network/ (I12):
public enum IOSNetworkText { /* explanationTitle "Find scanners on your Wi-Fi", explanationLine, explanationButton "Continue",
                               deniedLine "Local Network access is off.", settingsButton "Open Settings", pickerTitle "Scanners",
                               noScanner "No scanner found", troubleshoot "Troubleshoot", addButton "Add by address", removeAddress,
                               the add sheet's addTitle, addLine, addPlaceholder, addHelp, add "Add", networkOff; certificateTitle,
                               certificateLine, trustedBefore, newFingerprint, trustNew, notTrusted; connecting(_:) */ }
@MainActor public final class IOSNetworkScanners: ObservableObject {
    public static let explainedKey: String                         // "localNetworkExplained"
    public let backend: EsclScannerBackend
    @Published public private(set) var needsExplanation: Bool, certificateQuestion: EsclCertificateError?, revision: Int
    public convenience init()                                      // the app's: filesFolder(), EsclNWBrowser, EsclDnssdResolver, UIKitBackgroundActivity
    public init(backend: EsclScannerBackend, defaults: UserDefaults, center: NotificationCenter)
    public static func filesFolder() -> URL                        // Application Support/CompleteScanner/Network, excluded from backup
    public func continueAfterExplanation(); public var accessDenied: Bool { get }; public func reportDenied()
    public func answerCertificate(_ trust: Bool)
}
@MainActor public protocol IOSLocalNetworkChecking: AnyObject { func isDenied(host: String, port: Int) async -> Bool }
@MainActor public final class IOSLocalNetworkProbe: IOSLocalNetworkChecking {   // NWConnection, 3 s; closed at once
    public nonisolated static func isDenied(_ reason: NWPath.UnsatisfiedReason?) -> Bool }   // .localNetworkDenied
@MainActor public protocol IOSNetworkStatusReading: AnyObject { var status: NetworkStatus { get } }
@MainActor public final class IOSNetworkPath: IOSNetworkStatusReading {   // NWPathMonitor
    public nonisolated static func status(satisfied: Bool, wifi: Bool, wired: Bool) -> NetworkStatus }
@MainActor public final class IOSTroubleshooterService: TroubleshooterService {
    public convenience init(); public init(openURL: @escaping @MainActor (URL) -> Void, pasteboard: UIPasteboard,
                                           network: (any IOSNetworkStatusReading)?) }
public struct IOSScannerRow: Identifiable, Equatable { id, name, connection, note: String?, isSelected, isDemo, addedAddresses
    public var canRemoveAddress: Bool; public var detail: String; public var symbol: String }
@MainActor public final class IOSScannerPickerModel {
    public init(state: AppState, network: IOSNetworkScanners?)
    public var rows: [IOSScannerRow]; public static func rows(devices:selected:backend:) -> [IOSScannerRow]
    public var showsExplanation, showsDenied, showsSearching, showsEmpty, offersAddByAddress: Bool
    public func select(_:); func removeAddresses(_:); func continueAfterExplanation(); func openSettings() -> String?
    public func makeAddModel() -> IOSAddScannerModel
}
@MainActor public protocol IOSAddressChecking: AnyObject { checkAddress(_:firstUse:), addAddress(_:capabilities:), trustCertificate(_:deviceUuid:name:) }
extension EsclScannerBackend: IOSAddressChecking {}
@MainActor public final class IOSAddScannerModel: ObservableObject {
    @Published public var text: String; @Published public private(set) var message: String?, isChecking, accessDenied, certificateQuestion
    public private(set) var addedDeviceID: String?
    public init(checker: (any IOSAddressChecking)?, localNetwork: (any IOSLocalNetworkChecking)?, onDenied: (@MainActor () -> Void)? = nil)
    public func add() async -> Bool; func start(_ done:); func cancel(); func textChanged(); func answerCertificate(_ trust: Bool)
}
// internal: Views/ScannerPickerView.swift (ScannerPickerList, NetworkObserving, AddScannerView,
// CertificateChangedView), Views/TroubleshooterScreen.swift, Views/FlatbedPreview.swift (FlatbedPreview, FlatbedThumbnail,
// CropScreen, IOSCropGeometry, IOSCropHandle, IOSCropDragMode, IOSCropCommand); ScanScreen(picker:)

// CompleteScannerIOS/IOSFileActions.swift:
public struct ShareRequest: Identifiable, Equatable { public let urls: [URL]; public let title: String }
public struct MailRequest: Identifiable, Equatable { public let urls: [URL]; public let subject: String }   // I14
@MainActor public final class IOSFileActions: ObservableObject, FileActionService {
    @Published public var shareRequest: ShareRequest?             // the share sheet the root view shows
    @Published public var previewURL: URL?                        // the Quick Look preview the root view shows
    @Published public var mailRequest: MailRequest?               // I14: Mail's composer the root view shows (MailComposeView)
    public init(pasteboard: UIPasteboard? = nil, openSystemURL: (@MainActor (URL) -> Void)? = nil,
                mailAvailable: (@MainActor () -> Bool)? = nil)   // I14: nil = canSendMail()
    public static func canSendMail() -> Bool                       // MFMailComposeViewController.canSendMail(), inside #if canImport(MessageUI)
    public nonisolated static func filesAppURL(for urls: [URL]) -> URL?   // shareddocuments:// + the first file's folder
}
// I14: sendProbe answers canCompose = mailAvailable(), canShare true; composeEmail sets mailRequest when Mail is set
// up, else opens the share sheet. Views/MailComposeView.swift: public struct MailAttachment { data, mimeType, fileName;
// static func of(_ urls: [URL]) -> [MailAttachment] } and, inside #if canImport(MessageUI), MailComposeView with its
// MailComposeCoordinator (nothing is sent until the user taps Send).
// CompleteScannerIOS/CompleteScannerIOSApp.swift:  public struct CompleteScannerIOSApp: App   (ios/CompleteScanneriOS/main.swift: CompleteScannerIOSApp.main())
// CompleteScannerIOS/Views/IOSRootView.swift:      public struct IOSRootView: View { public init(fileActions: IOSFileActions, importer: IOSImportSession,
//                                                     picker: IOSScannerPickerModel, launchImports: [IOSImportItem] = [],
//                                                     launchTask: ScanTask? = nil, companion: IOSCompanionBrowser? = nil) }
//   also the troubleshooter sheet (state.showTroubleshooter), the changed-certificate sheet, and Troubleshoot in the error alert;
//   I15: Settings as a sheet, and on a regular width the sidebar layout (NavigationSplitView, IOSSidebar)

// App/AppState+Images.swift (CompleteScannerKit, Swift only): the queue saved as pictures, the iPhone's Save JPEG
extension AppState {
    public func saveImages()                                       // SavePlan's pages, one file a page, format.imageFormatOrJPEG
    public nonisolated static func imagesSaveTitle(_ format: OutputFormat, pageCount: Int) -> String     // "Save JPEG", "Save 3 JPEGs"
    public nonisolated static func imagesSavedMessage(_ urls: [URL], format: OutputFormat) -> String     // "Saved 3 JPEG files: ..."
}

// CompleteScannerIOS/Camera/IOSDocumentCamera.swift:
public enum IOSCameraAvailability: Equatable, Sendable {
    case available, noCamera, denied, restricted
    public static func resolve(isSupported: Bool, authorization: AVAuthorizationStatus) -> IOSCameraAvailability
    @MainActor public static var current: IOSCameraAvailability   // VNDocumentCameraViewController.isSupported, the camera permission
    @MainActor public static var ownCamera: IOSCameraAvailability // our camera (I8): IOSCameraLens.hasCamera, the camera permission
    public var isAvailable: Bool; public var reason: String?       // "No camera here", "Camera access is off", "Camera not allowed"
    public var opensSettings: Bool                                 // .denied
}
public enum IOSDocumentCamera {
    public static let tasks: [ScanTask]                            // [.document, .email, .word]
    public static func pages(_ images: [CGImage], createdAt: Date = Date()) -> [ScannedPage]
    public static func uprightImage(_ image: UIImage) -> CGImage?
}
// CompleteScannerIOS/Import/:
public struct IOSDecodedPhoto: Sendable { public let photo: RgbaImage; public let orientation: PhotoOrientation
    public let storedWidth: Int; public let storedHeight: Int; public let focalLength: Double?
    public let page: Int; public let pageCount: Int }
public struct IOSImportError: LocalizedError, Equatable { public let message: String }
public enum IOSPhotoDecoder {
    public static let maxLongSide: Int                             // 4000
    public static func pageCount(_ data: Data) -> Int               // a TIFF's pages, else 1 (PhotoFileReader.pageCount)
    public static func decode(_ data: Data, fileName: String, page: Int = 1,
                              maxLongSide: Int = maxLongSide) throws -> IOSDecodedPhoto
}
public struct IOSRenderedPage { public let image: CGImage; public let dpi: Int }
public enum IOSPDFPages {
    public static let dpi: Int; public static let maxLongSide: Int // 300, 7000
    public static let lockedDetail: String                         // "it needs a password."
    public static func open(_ data: Data, fileName: String) throws -> PDFDocument
    public static func shownSize(_ page: PDFPage) -> CGSize
    public static func resolution(for size: CGSize, dpi: Int = dpi, maxLongSide: Int = maxLongSide) -> Int
    public static func render(_ document: PDFDocument, index: Int, dpi: Int = dpi, maxLongSide: Int = maxLongSide) -> IOSRenderedPage?
}
public struct IOSFoundPage: Equatable, Sendable { public let corners: Quad; public let reason: PhotoReviewReason; public let byVision: Bool }
public enum IOSPageFinder {
    public static let minVisionConfidence: Double                  // 0.5
    public static let sureVisionConfidence: Double                 // 0.7: .none needs this and minSureSupport
    public static let minSureSupport: Double                       // 0.7 (QuadRefinement.support)
    public static func find(_ photo: RgbaImage) -> IOSFoundPage    // Vision, refined, else fallback
    public static func refined(_ corners: Quad, confidence: Double, in photo: RgbaImage) -> IOSFoundPage   // QuadRefiner, the sure rule
    public static func fallback(_ photo: RgbaImage) -> IOSFoundPage // PhotoImport.plan
    public static func accepted(_ candidate: QuadCandidate, width: Int, height: Int) -> Quad?
    public static func quad(fromNormalized points: [CGPoint], width: Int, height: Int) -> Quad
}
public struct IOSPickedImage: Transferable { public let data: Data }   // DataRepresentation(importedContentType: .image)
public struct IOSImportItem: Equatable, Sendable {
    public enum Kind { case image, pdf }
    public let name: String; public let data: Data; public let kind: Kind
    public static func kind(forFileName name: String, data: Data) -> Kind   // "%PDF" or a PDF's extension, else image
    public static func read(_ url: URL) throws -> IOSImportItem             // security-scoped, read once
}
public struct IOSImportSource {                                    // read when its turn comes
    public let name: String; public let expectedKind: IOSImportItem.Kind
    public let liveOutline: Quad?                                  // a camera photo's live outline, shares of the upright photo (I8)
    public let asksOnlyWhenUnsure: Bool                            // I9: continuous capture skips the editor for a page found clearly
    public init(name: String, expectedKind: IOSImportItem.Kind, liveOutline: Quad? = nil, asksOnlyWhenUnsure: Bool = false,
                read: @escaping @MainActor () async -> Result<IOSImportItem, IOSImportError>)
    public static func item(_ item: IOSImportItem) -> IOSImportSource
    public static func shot(_ shot: IOSCameraShot, asksOnlyWhenUnsure: Bool = false) -> IOSImportSource   // named shotName, with its live outline (I8)
    public static func file(_ url: URL) -> IOSImportSource         // IOSImportItem.read, off the main actor
    public static func notLoaded() -> IOSImportSource              // photoNotLoadedMessage
}
public struct IOSImportOutcome: Equatable, Sendable { public var added: Int; public var skipped: Int; public var problems: [String] }
public enum IOSImportText { /* cameraLabel "Camera" (our camera, I8), scannerLabel "Use Apple's scanner" (I9; "Doc scanner"
                               in I8; VoiceOver scannerName "Use Apple's document scanner"), shotName "Camera photo", scannedPagesName "Scanned pages",
                               photosLabel "Photos", filesLabel "Files", stopLabel "Stop",
                               importingPage(_:of:), importingFile(_:), notAddedMessage(_:), photoNotLoadedMessage */ }
@MainActor public final class IOSImportSession: ObservableObject {
    @Published public private(set) var cornerRequest: PhotoCornersRequest?   // the corner editor's item
    @Published public private(set) var isImporting: Bool
    @Published public private(set) var progressText: String?
    public private(set) var lastOutcome: IOSImportOutcome?
    public init(state: AppState, finder: (@Sendable (RgbaImage) -> IOSFoundPage)? = nil,
                objectFinder: (@Sendable (RgbaImage, CaptureKind) -> [Quad])? = nil)   // I13: nil, IOSObjectFinder.find
    public var canImport: Bool                                     // !isImporting, state.canIngest, PhotoImport.isOffered
    public var waitingCount: Int                                   // items waiting behind the import running
    @discardableResult public func importSources(_ sources: [IOSImportSource]) async -> IOSImportOutcome // waits behind a running import
    @discardableResult public func importItems(_ items: [IOSImportItem]) async -> IOSImportOutcome
    @discardableResult public func importPicked(_ photos: [Data?]) async -> IOSImportOutcome
    @discardableResult public func importFiles(_ urls: [URL]) async -> IOSImportOutcome
    @discardableResult public func bringInScans(_ pages: [ScannedPage]) async -> Bool
    @discardableResult public func importShot(_ shot: IOSCameraShot, asksOnlyWhenUnsure: Bool = false) async -> IOSImportOutcome   // our camera's photo (I8, I9)
    public func answer(_ answer: PhotoCornersAnswer)
    public func stop()                                             // drops what waits, Skip, ends after the item in hand
}
// internal: CornerEditorModel (the corner editor without a screen), CornerEditorView (I13: `fixesCrop`, Cancel and no Stop),
// CaptureBar, DocumentCameraView

// CompleteScannerIOS/Import/IOSObjectFinder.swift (I13):
public struct IOSRectangleSearch: Equatable, Sendable {           // what VNDetectRectanglesRequest is asked for
    public let maximumObservations: Int; public let minimumAspectRatio: Double; public let maximumAspectRatio: Double
    public let minimumSize: Double; public let quadratureTolerance: Double; public let minimumConfidence: Double
    public static func of(_ kind: CaptureKind) -> IOSRectangleSearch
    // receipt 16, 0.08...0.95, 0.08, 20°, 0.3; photo 16, 0.4...1, 0.1, 15°, 0.3; idCard 4, 0.45...0.85, 0.2, 15°, 0.3;
    // document 1, 0.4...1, 0.3, 20°, 0.5
}
public enum IOSObjectFinder {
    public static func find(_ photo: RgbaImage, kind: CaptureKind) -> [Quad]       // Vision, then pick; [] when none or no Vision
    public static func pick(_ candidates: [QuadCandidate], width: Int, height: Int, kind: CaptureKind) -> [Quad]
    public static func candidates(_ corners: [[CGPoint]], confidences: [Double], width: Int, height: Int) -> [QuadCandidate]
}
// CompleteScannerIOS/Review/IOSPhotoReviewModel.swift (I13):
public enum IOSReviewText { /* cancelLabel "Cancel", keepLabel "Keep", fixCropLabel "Fix crop", rotateLabel "Rotate", listHelp,
                              nameByDateLabel "Name by receipt date", combineLabel "One PDF for all", saveAsLabel "Save as",
                              idCardTitle "Check the ID card", privacyHelp, frontTitle "Front", backTitle "Back",
                              scanAgainLabel "Scan again", swapLabel "Swap sides", noBackLine "No back side",
                              scanBackLabel "Scan the back", pagePreviewName "Page preview", paperLabel "Paper",
                              sidesAsImagesLabel "Also save sides as images", discardLabel "Discard", discardHint,
                              cardFrontPrompt "Fit the front in the frame", cardBackPrompt "Fit the back in the frame",
                              guideName "Card frame"; idCardSaveTitle(_:) "Save PDF", sideAction(_:side:) "Scan the back again",
                              sizeCaption(width:height:dpi:) "6.0 × 4.0 in" */ }
public struct IOSCropRequest: Identifiable { public let photoID: UUID; public let request: PhotoCornersRequest }
@MainActor public final class IOSPhotoReviewModel {
    public init(state: AppState)
    public var title: String; public var saveTitle: String; public var photos: [DetectedPhoto]; public var isReceipts: Bool
    public var includedCount: Int; public var canSave: Bool
    public func isIncluded(_:) -> Bool; func setIncluded(_:_:); func toggle(_:); func rotate(_:); func save(); func cancel()
    public var nameByDate: Bool; func setNameByDate(_:); public var combine: Bool; func setCombine(_:)
    public var offersCombine: Bool; public var formats: [OutputFormat]; public var format: OutputFormat; func setFormat(_:)
    public func cropRequest(for photo: DetectedPhoto, name: String, number: Int, count: Int) async -> IOSCropRequest?
    public func applyCrop(_ crop: IOSCropRequest, answer: PhotoCornersAnswer)
    public nonisolated static func thumbnail(_ image: CGImage, maxSide: Int) -> CGImage
}
// CompleteScannerIOS/Views/IdCardGuide.swift (I13):
public enum IOSIdCardGuide {
    public static let aspect: Double; public static let widthShare: Double; public static let heightShare: Double   // ID-1, 0.86, 0.6
    public static func frame(in size: CGSize) -> CGRect
    public static func prompt(stepID: String?) -> String?                          // cardFrontPrompt, cardBackPrompt
    public static func glareLine(stepID: String?, frontNote: String?) -> String?   // GlareDetector.hint at the back after a glared front
}
// internal views (I13): Views/PhotoReviewScreen.swift (PhotoReviewScreen), Views/IdCardReviewScreen.swift (IdCardReviewScreen),
// Views/IdCardGuide.swift (IdCardGuide); ScanCover .photoReview and .idCardReview

// CompleteScannerIOS/Camera/ (our own camera, I8):
public struct IOSCameraFrame: Sendable { public let image: RgbaImage; public let timestampMs: Double   // small, as the sensor gives it
    public let page: QuadCandidate?                                // Vision's page in image's pixels; nil: none, or fixture frames
    public init(image: RgbaImage, timestampMs: Double, page: QuadCandidate? = nil) }
public protocol FrameSource: AnyObject {                           // the video output (IOSFrameFeed, internal), or fixture frames
    func startFrames(_ deliver: @escaping @Sendable (IOSCameraFrame) -> Void)   // one at a time, until stopFrames
    func stopFrames()
}
public struct LiveQuadUpdate: Equatable, Sendable {
    public let outline: Quad?                                      // shares of the frame (0...1, y down); nil: no page
    public let state: CaptureState; public let progress: Double; public let timestampMs: Double
    public let isSteady: Bool                                      // holds still now, drawn green: .steadying, or .captured while it stays put (display only)
    public let shouldCapture: Bool; public let quality: CaptureQuality   // I9: the shutter's decision and the frame's judgement
    public init(outline: Quad?, state: CaptureState, progress: Double, timestampMs: Double, isSteady: Bool? = nil,   // nil: state == .steadying
                shouldCapture: Bool = false, quality: CaptureQuality = .good)
}
public final class LiveQuadTracker: @unchecked Sendable {
    // frameIntervalMs 100, minFrameGapMs 90, analysisLongSide 480, holdMs 300
    public typealias Detector = @Sendable (RgbaImage, Quad?) -> PhotoDocumentDetection
    public typealias QualityMeasure = @Sendable (RgbaImage, Quad?) -> FrameQualityReading   // I9
    public init(detector: Detector? = nil, stability: CaptureStabilityOptions = .default,
                quality: QualityMeasure? = nil)                   // nil: detect(_:hint:), FrameQuality.measure
    public static var liveOptions: PhotoDocumentOptions           // analysisLongSide 480
    public static func detect(_ image: RgbaImage, hint: Quad?) -> PhotoDocumentDetection
    public static func detection(_ page: QuadCandidate, width: Int, height: Int) -> PhotoDocumentDetection?   // Vision's page, when accepted
    public func process(_ frame: IOSCameraFrame) -> LiveQuadUpdate?   // nil: passed over (too soon, or reset meanwhile)
    public func reset()
    public func markCaptured()                                     // I9: the page in view was taken
    public func follow(_ source: FrameSource, onUpdate: @escaping @Sendable (LiveQuadUpdate) -> Void)
    public func pauseFollowing()                                   // I9: stops the source, keeps the page (taken stays taken);
                                                                   // the first frame after it resumes CaptureStability (resume(atMs:))
    public func rearm()                                            // I9: reset() only when the page counts as taken with no photo of it
    public func stopFollowing()
    public static func normalized(_ quad: Quad, width: Int, height: Int) -> Quad
    public static func photoOutline(_ outline: Quad, rotationDegrees: Int) -> Quad?   // into the upright photo; nil unless 0/90/180/270
}
public struct LiveQuadFilter: Sendable {                          // the tracker's steadying, pure logic
    // smoothing 0.5, jitterShare 0.01, jumpShare 0.06 (of the frame's diagonal); holds LiveQuadTracker.holdMs
    public struct Output: Equatable, Sendable { public let page: Quad?; public let shown: Quad? }   // for CaptureStability; to draw
    public init()
    public mutating func update(_ found: Quad?, atMs t: Double, diagonal: Double) -> Output
}
public enum IOSFrameScaler {                                       // BGRA → RGBA, blocks of step × step, the mean of 4 pixels each
    public static func downscaled(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, maxLongSide: Int) -> RgbaImage?
}
public enum IOSLensKind: Int, CaseIterable, Sendable { case triple, dualWide, dual, wide, ultraWide, telephoto, trueDepth, other }
public enum IOSLensPosition: Equatable, Sendable { case back, front, unspecified }
public struct IOSLensOption: Equatable, Sendable { public let kind: IOSLensKind; public let position: IOSLensPosition }
public struct IOSPhotoSize: Equatable, Sendable { public let width: Int; public let height: Int; public var pixels: Int }
public enum IOSCameraLens {
    public static let preferred: [IOSLensKind]                     // [.triple, .dualWide, .wide]
    public static let maxPhotoPixels: Int                          // 12_600_000: 4032 × 3024 fits, 8064 × 6048 does not
    public static func rank(_ option: IOSLensOption) -> Int
    public static func choose(_ options: [IOSLensOption]) -> Int?  // the best's index, the first on a tie
    public static func photoSize(_ supported: [IOSPhotoSize], maxPixels: Int = maxPhotoPixels) -> IOSPhotoSize?
    public static func startZoom(kind: IOSLensKind, switchOverFactors: [Double], minZoom: Double = 1,
                                 maxZoom: Double = .greatestFiniteMagnitude) -> Double   // .triple/.dualWide: the first switch-over (the wide lens); else 1
    public static var hasCamera: Bool                              // AVCaptureDevice.DiscoverySession finds one (never in the Simulator)
}
public enum IOSCameraInterruption: Equatable, Sendable { case inUse, tooWarm, multitasking, other
    public static func from(_ reason: AVCaptureSession.InterruptionReason) -> IOSCameraInterruption; public var reason: String }
public enum IOSCameraEvent: Equatable, Sendable { case shown, hidden, background, foreground, ready(Bool),
    thermal(ProcessInfo.ThermalState), interrupted(IOSCameraInterruption), interruptionEnded, reviewStarted, reviewEnded, runtimeError }
public enum IOSCameraCommand: Equatable, Sendable { case keep, start, stop }
public struct IOSCameraLifecycle: Equatable, Sendable {
    public static let maxRestarts: Int                             // 3
    public private(set) var isShown, isInForeground, isReady, isTooWarm, isReviewing, isRunning, hasFailed: Bool
    public private(set) var interruption: IOSCameraInterruption?
    public var shouldRun: Bool; public var isLive: Bool; public var pauseReason: String?
    public mutating func handle(_ event: IOSCameraEvent) -> IOSCameraCommand
    public static func thermalAllows(_ state: ProcessInfo.ThermalState) -> Bool   // .nominal, .fair
}
public enum IOSCameraText { /* title "Camera", doneLabel "Done", shutterLabel "Take photo", shutterHint(_ kind: CaptureKind) (the page found again, the receipts or photos found, the card's side taken), flashLabel "Flash",
                              settingsLabel "Settings", notStarted "Camera did not start", tooWarm "Paused: too warm",
                              inUse "Camera in use", needsFullScreen "Needs full screen", paused "Camera paused",
                              photoFailed "Photo not taken", pageCount(_:) "1 page", "3 pages";
                              I9: autoLabel "Auto", autoHint, cameraHint (the scan screen's Camera button), onValue "On",
                              offValue "Off", holdStill "Hold still", tooDark "Too dark", lastPageLabel "Last page",
                              waitReason(_ quality: CaptureQuality) -> String? (nil for .good) */ }
public struct IOSCameraPhoto: Sendable { public let data: Data; public let rotationDegrees: Int?; public let mirrored: Bool }
public struct IOSCameraShot: Sendable { public let data: Data; public let liveOutline: Quad? }
@MainActor public protocol IOSCameraDriving: AnyObject {
    func prepare() async -> Bool; func startRunning(); func stopRunning(); var hasTorch: Bool { get }
    func setTorch(_ on: Bool) async -> Bool; func takePhoto() async -> IOSCameraPhoto?
    var frameSource: FrameSource? { get }; var onEvent: (@MainActor (IOSCameraEvent) -> Void)? { get set }
}
@MainActor public final class IOSCameraModel: ObservableObject {
    @Published public private(set) var availability: IOSCameraAvailability?   // nil until checked (and asked)
    @Published public private(set) var setupFailed: Bool, lifecycle: IOSCameraLifecycle, live: LiveQuadUpdate?, hasTorch: Bool,
                                       torchOn: Bool, isTakingPhoto: Bool, photoFailed: Bool, shotCount: Int
    @Published public private(set) var autoShutter: Bool          // I9: on unless turned off; remembered in UserDefaults
    public var onAutoShot: (@MainActor (IOSCameraShot) async -> Void)?   // I9: where the automatic shutter's photos go; nil: none taken
    public var canTakePage: (@MainActor () -> Bool)?               // I9: a page can be taken now (no photo being read); nil: always
    public static let autoShutterKey: String                       // "cameraAutoShutter"
    public let driver: any IOSCameraDriving
    public init(driver: any IOSCameraDriving, tracker: LiveQuadTracker? = nil, hasCamera: (@MainActor () -> Bool)? = nil,
                authorization: (@MainActor () -> AVAuthorizationStatus)? = nil, requestAccess: (@MainActor () async -> Bool)? = nil,
                thermalState: (@MainActor () -> ProcessInfo.ThermalState)? = nil, center: NotificationCenter = .default,
                defaults: UserDefaults = .standard)
    public static func makeLive() -> IOSCameraModel                // IOSCameraController
    public var message: String?; public var opensSettings: Bool; public var showsPreview: Bool; public var canShoot: Bool
    public func appear() async; public func disappear(); public func apply(_ event: IOSCameraEvent)
    public func toggleTorch() async; public func shoot() async -> IOSCameraShot?   // a failed photo: photoFailed for
                                                                   // failedNoticeNanoseconds (2.5 s), the page re-armed
    public static let failedNoticeNanoseconds: UInt64
    public func shotImported(_ outcome: IOSImportOutcome)          // nothing added, one skipped: the page in view judged afresh
    public func setAutoShutter(_ on: Bool)                         // I9
}
@MainActor public final class IOSCameraController: IOSCameraDriving {   // AVCaptureSession on its own queue
    public init(center: NotificationCenter = .default); public var session: AVCaptureSession
}
// internal: IOSCaptureSession, IOSFrameFeed, IOSPhotoDelegate, IOSObserverTokens; Views/CameraScreen.swift: camera mode,
// CameraScreen<Notices, SaveControls>(resting:waitsForIntro:scanner:onLibrary:onPrinter:onPages:onKind:onExportSheet:
// onAppleScanner:notices:saveControls:), CameraPreview, CameraPreviewView; Views/CameraDrawer.swift: KindsRow(onKind:),
// CameraDrawer, CameraDrawerGroup (export, colour, quality, flash, camera; shown(_:pageCount:torch:)); ScanCover (the scan screen's
// full-screen covers: Apple's scanner, the scan area, the reviews, Quick scan, the copy);
// Views/IOSRootView.swift: ErrorAlert (the error alert, on the root view and on the sheets that need it)

// CompleteScannerIOS/Library/ (I15): presets, this session's scans, the saved files
public enum IOSPresetText { /* title "Presets", groupTitle "My presets", saveLabel "Save preset", saveTitle, saveLine,
                               namePlaceholder "Preset name", renameLabel "Rename", renameTitle, deleteLabel "Delete",
                               emptyTitle "No presets", emptyLine, discardTitle "Discard the ID card?", discardLine, discardLabel */ }
public struct IOSPresetRow: Identifiable, Equatable { id, name, taskTitle, summary (TaskCatalog.summary), symbol
    public init(preset: Preset); public var accessibilityLabel: String /* "Invoices preset" */; public var accessibilityHint: String }
public enum IOSPresetApply: Equatable, Sendable { case applied, waitsForDiscard, waitsForPages(String /* the preset's name */), refused }
@MainActor public final class IOSPresetsModel {
    public init(state: AppState); public var rows: [IOSPresetRow]; public static func rows(_ presets: [Preset]) -> [IOSPresetRow]
    public static func isValidName(_ name: String) -> Bool           // not blank
    @discardableResult public func save(named: String) -> Bool        // AppState.saveCurrentAsPreset
    @discardableResult public func rename(_ id: UUID, to: String) -> Bool   // AppState.renamePreset
    public func delete(_ id: UUID)
    @discardableResult public func apply(_ id: UUID, discardingPages: Bool = false,
                                         then: @escaping @MainActor () -> Void) -> IOSPresetApply
                                                                      // settings that do not collect pages (collectsPages of
                                                                      // savingActionsAsDocument) over a queue: waitsForPages, nothing
                                                                      // applied; discardingPages: clearPages() first; then through
                                                                      // AppState.leaveIdCard: with a card side held it
                                                                      // waits for Discard (pendingIdCardLeave)
}
public struct IOSHistoryRow: Identifiable { id, thumbnail, title /* "Document · 300 dpi" */, time, symbol,
    accessibilityLabel /* "Document scan, 300 dpi, 2550 by 3510 pixels, 4:23 PM" */ }
public enum IOSHistory { /* title "Scans", emptyTitle "No scans yet", emptyLine */
    public static func countText(_ count: Int) -> String               // "1 scan", "13 scans"
    public static func rows(_ entries: [ScanHistoryEntry], now: Date, calendar: Calendar = .current,
                            locale: Locale = .current) -> [IOSHistoryRow]
    public static func timeText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String   // "jmm", "MMMdjmm"
}
public struct IOSSavedFile: Identifiable, Equatable { url, modified, byteCount, isNew   // isNew: in AppState.lastSavedURLs
    public var name, isPDF, isImage, symbol, detail /* "Oct 20, 2026 · 498 KB" */ }
public struct IOSSavedFolder: Equatable { public let files: [IOSSavedFile]; public let failed: Bool }
public enum IOSSavedFiles { /* title "Saved files", emptyTitle, emptyLine, failedLine, newBadge "New", revealLabel
                               "Show in Files", moreLabel */
    public static let knownExtensions: Set<String>                     // pdf jpg jpeg png tiff tif txt docx
    public static func folder(_ settings: ScanSettings) -> URL         // destinationPath, ~ expanded, moved into
                                                                       // this install's Documents (rebasedDestinationPath)
                                                                       // unless a bookmark is set
    public static func shownFolder(_ settings: ScanSettings) -> URL    // folder(_:), or the app's own folder while a picked
                                                                       // one is out of reach (where a save goes meanwhile)
    public static func list(in folder: URL, justSaved: [URL]) -> IOSSavedFolder   // newest first; hidden files, folders and
                                                                       // other kinds left out; a folder not made yet: empty, not failed
    public static var moreActions: [FileAction]                       // SaveActions.offered(fileCount: 1) without share and reveal
    public static func label(_ action: FileAction) -> String          // reveal: "Show in Files"
    public static func symbol(_ action: FileAction) -> String
    public static func thumbnail(of url: URL, maxSide: Int) -> CGImage?   // ImageIO; a PDF's first page with Core Graphics
}

// CompleteScannerIOS/Settings/ (I15): Settings and the file name editor
public enum IOSSettingsText { /* title "Settings", doneLabel, presetsLabel "Presets", historyLabel "Scans", savedLabel
                                 "Saved files", fileNameLabel "File name", saveToLabel "Save to", chooseFolderLabel
                                 "Choose…", appFolderLabel "Use app folder", troubleshootLabel,
                                 aboutLabel "About", companionLabel "My computer" (I20), resetLabel, notCollectingReason, docdateReason, onlyPDFReason,
                                 aboutBuiltWith, aboutPrivacy */
    public static func version(_ info: [String: Any]?) -> String       // "Version 0.1.0 (1)"
}
@MainActor public enum IOSSaveFolder {                                // a save folder picked in Files (I3)
    public static func choosing(_ folder: URL, in settings: ScanSettings) throws -> ScanSettings   // bookmark + path
    public static func appFolder(_ settings: ScanSettings) -> ScanSettings   // bookmark cleared, default path
    public static func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)?   // opened once, kept open
                                                                       // while reachable; a stale bookmark made again;
                                                                       // nil: out of reach now
}
public struct IOSSettingsSection: Identifiable, Equatable { id, title, summary, changed, locked, accessibilityLabel }
public enum IOSSettingsSections {
    public static let storageKey: String                               // "settings.openSections" (UserDefaults, @AppStorage)
    public static func savesPictures(_ s: ScanSettings) -> Bool        // IOSShell.collectsPages && savesImages
    public static func writesPDF(_ s: ScanSettings) -> Bool            // InspectorSections.writesPDF and not savesPictures
    public static func textApplies(_ s: ScanSettings) -> Bool
    public static func sections(_ s: ScanSettings) -> [IOSSettingsSection]   // InspectorSections.shown, Archive hidden
                                                                       // unless writesPDF here
    public static var defaultText: String                              // "task,scanner,output"
    public static func text(_ open: Set<String>) -> String; public static func open(_ text: String) -> Set<String>
    public static func isOpen(_ id: String, stored: Set<String>, openedByTask: Set<String>) -> Bool
}
public enum IOSAfterSave: String, CaseIterable, Identifiable { case send, print, email   // the order they run in
    public static let rows: [IOSAfterSave]                             // [.email, .print, .send], the rows' order
    public static let title: String; public static let footer: String // "After saving", "Runs each time a document is saved. ..."
    public var label: String                                           // "Send to PC", "Print", "Email"
    public var key: String                                             // "afterSave.send" ... (UserDefaults, @AppStorage)
    public static func steps(_ defaults: UserDefaults, paired: Bool) -> [IOSAfterSave]   // checked ones; .send only if paired
}
public enum IOSAdjustment: String, CaseIterable, Identifiable { case brightness, contrast, saturation, sharpness
    public var label: String; public func amount(_ a: AdjustmentSettings) -> Double   // -100...100, 0 neutral, as the Mac
    public func setting(_ amount: Double, in a: AdjustmentSettings) -> AdjustmentSettings
    public static func amountText(_ amount: Double) -> String          // "0", "+12", "-5"
    public static func neutral(_ a: AdjustmentSettings) -> AdjustmentSettings; public static func isNeutral(_:) -> Bool }
@MainActor public final class IOSNamingModel: ObservableObject {    // title "File name", insertTitle "Insert",
    @Published public private(set) var text: String                  // exampleLabel "Next file", resetLabel "Reset"
    public init(state: AppState); public var parts: [NamingToken]; public var problem: String?
    public var format: OutputFormat                                    // a picture a page when the scan screen saves pictures
    public var example: String                                         // AppState.fileNameExample
    public func setText(_ newText: String)                             // in use unless blank
    public func insert(_ token: String)                                // at the end
    public func reset()                                                // "Scan {date} {counter}"
}

// CompleteScannerIOS/IOSLayout.swift (I15): the iPad
public enum IOSLayout { public static func usesSidebar(_ horizontal: UserInterfaceSizeClass?) -> Bool }   // .regular
public struct IOSShortcut: Equatable { public let key: Character; public let command: Bool; public let title: String
    public var keyboardShortcut: KeyboardShortcut }
public enum IOSShortcuts { public static let save /* ⌘S */, newDocument /* ⌘N */, settings /* ⌘, */, shutter /* Space */: IOSShortcut
    public static let all: [IOSShortcut] }
public enum IOSPageDrop {
    public static func offset(moving: UUID, onto target: UUID, in ids: [UUID]) -> Int?
    public static func pageID(_ text: String) -> UUID?
    @MainActor @discardableResult public static func move(_ moving: UUID, onto target: UUID, in state: AppState) -> Bool
}                                                                      // AppState.movePage one place at a time
public struct IOSDroppedFile: Transferable, Sendable { public let data: Data; public let kind: IOSImportItem.Kind
    public init(data: Data, kind: IOSImportItem.Kind); public var item: IOSImportItem   // "Dropped PDF", "Dropped picture"
    public static let pdfName: String; public static let imageName: String }   // DataRepresentation: .pdf, then .image

// CompleteScannerIOS/Companion/ (I20): the phone's side of C1 on the iPhone
public struct IOSKeychainError: Error, Equatable, LocalizedError { public let status: OSStatus }   // said as notSavedMessage
public struct IOSCompanionSecrets: CompanionSecretStore {   // kSecClassGenericPassword, account = desktop id,
    public static let service = "com.completescanner.companion"   // WhenUnlockedThisDeviceOnly, the data protection keychain
    public let service: String; public init(service: String = IOSCompanionSecrets.service) }   // C2: also the sync key,
                                                               // account "<desktopId>.sync"
@MainActor public enum IOSSyncFolder {                         // the cloud folder of My computer (C2)
    public static func bookmark(of folder: URL) throws -> Data
    public static func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)?   // as IOSSaveFolder.resolve
    public static func close()
    public static func waitingCount(in folder: URL) -> Int }    // "*.cssync" files, hidden ones skipped
@MainActor public final class IOSCompanionBrowser: ObservableObject {   // EsclNWBrowser(type: serviceType) + EsclDnssdResolver
    @Published public private(set) var accessDenied: Bool          // a browser waiting or failed with PolicyDenied
    public var onFound: ((String, [String], Int) -> Void)?         // id, addresses, port: once for each desktop a browse
    public convenience init(); public var isBrowsing: Bool { get }
    public func begin(); public func end()                         // counted: browses while any began and did not end
    public func isSeen(_ desktopId: String) -> Bool                // among the services last reported (TXT id)
    nonisolated static func desktopId(_ result: EsclBrowseResult) -> String? }
public enum IOSCompanionText { /* title "My computer", pairTitle "Pair with a computer", pairLine, textLabel "Enter pairing text",
                                  textPlaceholder, compareLine "Compare with the code on the computer", phoneNameLabel
                                  "Name of this phone", pairButton "Pair", waitingLine,
                                  refreshButton, sendAgainButton "Send again", removeButton "Remove", unpairButton "Unpair",
                                  notPaired, checking, connected "Connected", nothingWaiting, sendButton "Send to computer",
                                  sendQuestion, newDocument "New document", intoOpenDocument "Into the open document",
                                  cloudFolderLabel "Cloud folder", noCloudFolder "None", cloudFolderOutOfReach
                                  "Cannot be opened", chooseFolderButton "Choose…", clearButton "Clear" */
    public static func status(_ status: CompanionStatus) -> String   // "Connected · 3 pages queued there"; the Kit's sentences
    public static func waiting(_ count: Int) -> String               // "2 documents waiting to be sent"
    public static func inCloudFolder(_ count: Int) -> String }       // "2 documents in the cloud folder"
@MainActor public final class IOSCompanionModel: ObservableObject {
    @Published public var text: String; @Published public var phoneName: String   // UIDevice's name to begin with
    @Published public private(set) var isPairing: Bool
    public init(state: AppState, browser: IOSCompanionBrowser?)
    public var code: PairingUri? { get }; public var problem: String? { get }   // PairingUri's message
    public var checkCode: String? { get }                          // "066 051"
    public var needsPairing: Bool { get }; public var canPair: Bool { get }
    public func scanned(_ value: String); public func appear(); public func disappear()   // browsing while shown
    public func refresh() async; public func pair() async          // under phoneName; pullFromDesktop once paired
    public func sendAgain() async; public func removeWaiting(); public func unpair() async
    @Published public private(set) var offersCloudFolder: Bool     // C2: AppState.canUseSyncFolder
    @Published public private(set) var cloudFolderName: String?; @Published public private(set) var inCloudFolder: Int
    public var cloudFolderValue: String { get }                    // the name, "None" or "Cannot be opened"
    public func chooseCloudFolder(_ folder: URL); public func clearCloudFolder(); public func lookAtCloudFolder() }
// internal: PairingScannerView(onCode:) (DataScannerViewController for .qr when isSupported && isAvailable, else
// AVCaptureMetadataOutput; static isPairingCode), Views/CompanionScreen.swift: CompanionScreen(state:browser:)
// internal views (I15): Views/SettingsScreen.swift (SettingsScreen, AboutScreen and the sections' rows),
// Views/PresetsScreen.swift (PresetsScreen, IdCardDiscardQuestion), Views/HistoryScreen.swift, Views/SavedFilesScreen.swift,
// Views/NamingEditorScreen.swift, Views/IOSSidebar.swift (IOSSidebar, IOSDetail); ScannerPickerView.swift: ScannerPickerSections,
// ScannerPickerSheets (the scanners, picked for printer mode, in its Scanner options, the wide column's list or the
// sidebar);
// ScanScreen(picker:pickerInSidebar:onOpenSettings:onOpenLibrary:waitsForIntro:), ScanOptionGroup (scanner, book, photos,
// export, afterSave), TaskStartScreen(onOpenScanner:onClose:), Views/LibraryScreen.swift (LibraryScreen(onOpenSettings:),
// LibraryPart); TaskControls.swift: AfterSaveSection; CaptureBar.swift: CaptureBar(onPages:), ImportProgressRow,
// ImportButtons(round:onPresenting:), ShutterButtonStyle, AppleScannerRow;
// PageStripView.swift: PageStripView(onEditSpread:), PageStripSheet(onEditSpread:onClose:);
// IOSRootView(fileActions:importer:picker:launchImports:launchTask:companion:demoScanner:)
```
Each app shell passes its scanner connections and its system services in; `CompleteScannerKit` never names a platform's own implementation. A shell that passes none gets the demo scanner alone (`makeDemoBackend()`), no printer, file and troubleshooter actions that are refused (see the sections of those services), and no lifecycle events; text recognition, barcode reading and QR codes default to Vision and Core Image (`VisionOrientationScorer`, `VisionBarcodeReader`, `CoreImageQrEncoder`), which both platforms have. The will-terminate handler is asked for when `AppState` is made (it writes the settings at once, cancelling the debounced write); the did-become-active handler when the app first starts (`start()`, once however often it is called), and it reads the printers again (`refreshPrinters()`).

`ingest(_:source:)` is the one way pages come in after they are captured. The scan path uses it too: `performScan()` hands the scanner's pages to the same stage (`ingestPages`, internal, with a `PageIntake` carrying the scan's own facts: its settings snapshot, the arrangement of its sides, both sides asked, the side of a stack turned over by hand, the ID card's side, the selection, the copy's printer setup, a feeder that stopped early). Each page is marked with its `PageSource`; the clean-up stage follows the source (`AppState.cleanUpStage(for:settings:arrangement:scorer:barcodes:)`: `.scanner` `PageProcessor.forScan` with the scan's arrangement, `.photo` `PageProcessor.forCapture` (a camera's page or a photo with capture facts not yet measured is cut out of its photo and cleaned up first, `PerspectiveStep` and `EnhanceStep` in `prepare`, which leave every other page alone, then `forPhotoImport`'s steps), `.phone` no step, since the phone cleaned its pages up, as the Windows app queues a phone's pages); then the last page is shown, as scanned (the canvas and the iPhone's preview card show a scan before its steps, a camera's page already cut out of its photo, not the scene around it), the pages go into the history (not an ID card's), and the task's flow handles them as it handles a scan: queued and spooled (or saved at once), searched for photos or receipts, taken as the ID card's side its steps are at (the review opens instead when the sides are in), or printed as a copy (which needs a printer, `PrintError.noPrinter` otherwise). A scan's pages are dropped when another scanner is chosen meanwhile; ingested pages belong to no scanner and are kept, in every flow (`isCurrent(nil)` is always true, and `showReceipts` takes the same optional generation). `ingest` takes pages only when `canIngest`: nothing else is running, no stack is being turned over by hand (its steps count the scanner's fronts and backs, so other pages would be recorded as backs), and neither the photo or receipt review nor the ID card's review is open (new pages would replace what is being reviewed); the rule of `canImportPhotos` without its settings check, and of the Windows `AppViewModel.CanTakePhonePages`. It answers whether it took them (false also with no pages, and when the ID card's sides are in already, which opens its review), so a caller keeps the pages it was refused and brings them in later, as the Windows app keeps a phone's documents waiting.

The iPhone's and iPad's shell (I2) passes the demo scanner (`IOSShell.backends`; since I12 the network scanners, `IOSShell.backends(options:networkScanners:)`, which since the camera-first work replace the demo scanner, so a real phone never lists or selects it and a source left on it at launch is the camera again; under `-demoScanner`, the UI tests' launch argument, the app has the demo scanner alone and never searches the network; the camera is not a scanner connection, see I7 below), its file actions, since I12 its troubleshooter service (`IOSTroubleshooterService`, see "Core/Troubleshooter.swift") and `UIKitLifecycle`. `IOSFileActions` carries out what iOS has: Open shows the file in Quick Look; Open With, Share and Email open the share sheet (`UIActivityViewController`; `sendProbe` answers `canCompose` false and `canShare` true, so `SaveActions` routes email there and the user picks Mail or another app); Show in folder opens the Files app at the file's folder (`shareddocuments://`); Copy puts the files, and a single image's picture, on the pasteboard of this device only (`localOnly`), and Copy Text the text. Sharing nothing is refused with `ScanError.unsupported`, a picture that cannot be read with `ScanError.exportFailed`. The shell passes no `PrintService` yet, so the Kit's stand-in refuses it: no printer (printing throws `PrintError.noPrinter`); until I12 it passed no `TroubleshooterService` either. The start screen shows every task of `TaskCatalog.sections` with the catalog's wording; the tasks it cannot finish yet are dimmed with `IOSShell.notYetReason`: those that need a printer (Photocopy), an area chosen on the preview (Quick scan) or the Archive & password settings (Archive document); until I13 also those that needed a review screen (Photos, Restore old photos, ID card, Receipts), offered since (see I13 below). The views (`Views/`: the start screen, then the scan screen with the step's prompt, the scanner, the last scan, the page strip, Scan, Save and, once saved, Share and Show in Files) save through `AppState.savePDF()`, the existing Core Graphics PDF builder, into `ScanSettings.destinationPath` (Documents/CompleteScanner in the app's container, which the Files app shows with `UIFileSharingEnabled`). The app's privacy manifest declares no tracking, no data collected, and the required-reason APIs the Kit calls: `UserDefaults` (CA92.1: the file-name counter; since I9 also the camera's Auto setting), `ProcessInfo.systemUptime` (SystemBootTime 35F9.1: timing the clean-up and orientation steps) and `FileManager.attributesOfItem` (FileTimestamp C617.1: the size of the files the app saved in its container). A new use of a required-reason API adds its category and reason there in the same change.

**Camera and imports on the iPhone (I7, Swift only).** What is offered now: the start screen offers the tasks I2 offered (`IOSShell.offers`: Document to PDF, Multi-page from feeder, Email a document, Two-sided, Scan to Word, Batch, Book on the demo scanner); the others stay dimmed with `notYetReason`. The scan screen of Document to PDF, Email a document and Scan to Word (`IOSShell.offersCamera`, `IOSDocumentCamera.tasks`) has Apple's document scanner (`VNDocumentCameraViewController`, VisionKit, in a full-screen cover; labelled **Camera** in I7, **Doc scanner** since I8, when our own camera took the name Camera): it finds the page, takes it when steady and hands back each page upright and cropped, with no corners and no original photo, so each page comes in whole (`IOSDocumentCamera.pages`): a color page from a photo (`PageSource.photo`) at the resolution its shape gives (`CaptureScale.fromAspect`: A4, Letter, Legal or an ID card within 3 %, `dpi = floor(px / inches + 0.5)` of the long side; else 200 dpi, the size made up), with capture facts saying it was taken whole and measured (`quad` the whole picture, `sourceWidth` × `sourceHeight` its pixels, `kind` `.document`, no focal length, `scale` set), so `PerspectiveStep` leaves it alone; the pages of one session come in together (`IOSImportSession.bringInScans`, `AppState.ingest(_:source: .photo)`). Where the scanner cannot run, its button is dimmed with one line (`IOSCameraAvailability`: "No camera here" where `VNDocumentCameraViewController.isSupported` is false, as in the Simulator; "Camera access is off" with a Settings button when the user denied the camera; "Camera not allowed" when restricted); iOS asks for the camera the first time (`NSCameraUsageDescription`). Every scan screen that collects pages (`PhotoImport.isOffered`) also has **Photos** (`PhotosPicker`: up to 50, in the order picked, images only, the current encoding; it runs in its own process, so the app needs no photo library permission and declares no `NSPhotoLibraryUsageDescription`; each photo is loaded as its file's own bytes through `IOSPickedImage`, a `Transferable` with `DataRepresentation(importedContentType: .image)`, so HEIC and JPEG come in unchanged, named "Photo") and **Files** (`.fileImporter`: images and PDFs, several at once, each read once through its security scope and never changed, `IOSImportItem.read`, off the main thread). Neither is read up front: each picked photo and each file is an `IOSImportSource` whose bytes are loaded only when its turn in the import comes, and let go once its photo is decoded (a TIFF's and a PDF's bytes while their pages come in), so a pick of 50 large photos never holds 50 files' bytes. Photos and PDFs opened in the app from another one ("Open in CompleteScanner": `CFBundleDocumentTypes` for `public.image` and `com.adobe.pdf`, handler rank Alternate, with `LSSupportsOpeningDocumentsInPlace`) arrive through `onOpenURL` and are imported the same way, into the task set up when it collects pages, else into Document to PDF, with the scan screen shown. What arrives while an import runs (a file opened in the app while the corner editor waits, a second pick) is not dropped: it waits (`IOSImportSession.waitingCount`) and is imported after what is in hand, counted in the same import ("Photo 2 of 2"). **The import pipeline** (`IOSImportSession`, one item at a time, one photo in memory at a time): a photo is decoded by `IOSPhotoDecoder` with ImageIO, each page of a TIFF of several pages as a photo of its own as on the Mac (`PhotoFileReader.pageCount`, `package`; the editor names it "fax.tif, page 2 of 3", `PhotoImport.pageName`, and the progress says "Importing page 2 of 3…", `PhotoImport.progressMessage(_:of:page:pageCount:)`): the size and orientation tag are read from the header first (a photo over `PhotoImport.maxPhotoPixels` is turned down before its pixels are decoded, `PhotoFileReader.headerPixelSize` and `tooLarge` as on the Mac), a long side over 4000 px is decoded straight to 4000 (ImageIO's thumbnail without its own turn), and the tag (all eight values) is applied by the shared `PhotoImport.oriented`, so the page search sees the photo upright; EXIF `FocalLenIn35mmFilm` becomes the focal length in pixels of that photo (`CaptureScale.focalLengthPixels`). The page is found by `IOSPageFinder`: Vision's document segmentation (`VNDetectDocumentSegmentationRequest`, its normalized corners at x · W, (1 − y) · H, `Quad.fromCorners`), taken when its confidence is at least 0.5, `MultiQuadPicker` keeps it as a document page (`.document`) and it is usable within the photo; otherwise the shared detector (`PhotoImport.plan`: the page found, else the outline seen, else the start rectangle, with its reason). The corner editor always opens (`cornerRequest`, a `PhotoCornersRequest`; the root view's full-screen `CornerEditorView`): the photo fitted to the screen with the four corners; a finger takes the nearest handle within 36 pt and moves its corner by as much as the finger moves (it never jumps under the finger), kept in the photo and on a convex outline (`PhotoImport.movedCorner`); a magnifier (120 pt, 2.5 ×) shows the photo around the corner being moved, diagonally away from the page's middle and kept on screen (the Mac editor's rule); VoiceOver reads each corner by name with where it is (the name from where the corner sits now, its place once the outline's corners are named again, `CornerEditorModel.cornerLabel`, `Quad.fromCorners`, so a corner dragged round to the page's top right is read as "Top right corner"; "12 percent from the left, 8 percent from the top", `CornerEditorModel.cornerValue`, both read again after each step, so a step the photo's edge stopped is heard) and swipes move it out or in by a hundredth of the photo's long side; the reason (`PhotoImport.reasonText`) and the counter ("Photo 2 of 5") above; Stop, Reset, Use whole photo, Skip photo and Use corners (`CornerEditorModel`, the editor without a screen). Use corners hands the upright photo to the queue as the page's picture with capture facts in its pixels (the corners named again, its size, kind `.document`, the focal length) at the nominal 200 dpi, and the clean-up stage cuts it out at its real size (`ingest(_:source: .photo)`: `PageProcessor.forCapture`, `PerspectiveStep`, `CaptureScale.measure`, `PerspectiveWarp`), keeping the photo as the other version ("As photographed"); Use whole photo takes `PhotoImport.wholePhotoPage`; Skip leaves the photo out. A PDF's pages are drawn by `IOSPDFPages` with PDFKit at 300 dpi on white, each page's crop box turned by its rotation (a page whose long side would pass 7000 px is drawn at the resolution that fits, recorded on the page), so a save keeps its size; a locked PDF is refused ("it needs a password."), as is one without pages. Each page is brought in once the state can take it (`canIngest`) and the import waits until it is in before the next, so only one photo or page is in memory at a time; while the state cannot take pages (a stack being turned over by hand, a review up) nothing is read and no editor opens: the item is listed as not added. **Stop** (`IOSImportSession.stop`: the scan screen's Stop beside the import's progress, `import.stop`, and the corner editor's Stop, `corners.stop`) drops what waits, answers a waiting editor with Skip and ends the import after the photo or PDF page in hand; going back from the scan screen stops the import too, and the start screen's task tiles are dimmed while an import runs, so its pages never land in another task. What could not be read (a file, a photo the library could not hand over, a page) is listed in one error at the end (`IOSImportOutcome.problems`, each line once), the others imported. The scan screen's Save offered **PDF or JPEG** (a segmented choice that sets `ScanSettings.format`) until the format moved to Options' Export (`IOSShell.exportFormats`, see What you scan below): PDF saves through `AppState.savePDF()`, JPEG through `AppState.saveImages()` (Kit, Swift only: the pages `SavePlan` saves, one file a page in `format.imageFormatOrJPEG` at each page's resolution, the full pixels from the spool turned as shown, named with `{index}`, all or nothing; then the queue is emptied, the steps start over and the after-save action runs, as `savePDF()` does; "Save 3 JPEGs", "Saved 3 JPEG files: …"); the saved files' Share opens the share sheet through `IOSFileActions` (Email a document's after-save action opens it at once). Nothing leaves the device without the user picking where in the share sheet. **Simulator:** VisionKit's document camera does not run there, so the UI smoke test keeps using `-demoScanner`, and the import UI test (`ImportTests`) launches with `-importFixture` and its fixture photo's bytes (base64) in `COMPLETESCANNER_IMPORT_FIXTURE` (`IOSLaunchOptions.launchImport`: imported at launch into Document to PDF as the Files app would hand it over, since a UI test cannot drive the system's pickers), through the page search, the corner editor (Use corners) and a PDF save, and checks the dimmed scanner button (`capture.camera` in I7 and I8, `capture.scanner` with `scanner.reason` since I9) with its reason; a second run taps the editor's Stop and checks that the import ended with no page. The fixture (`ios/CompleteScanneriOSUITests/Fixtures/document-photo.png`, a resource of the UI test target) is drawn by `scripts/make_ios_ui_fixture.py`: a sheet with grey bars on a dark table, no real document. The privacy manifest is unchanged: the camera, the photo picker, Vision, PDFKit and ImageIO use no required-reason API.

**Our own camera on the iPhone (I8, Swift only; as I8 built it; what I9 changed is in the next paragraph).** Apple's document scanner stays the default of the Document, Email and Word tasks (**Doc scanner**, the bar's first button there); our own camera is offered beside it as **Camera** on every scan screen that collects pages (`IOSShell.offersOwnCamera`: `PhotoImport.isOffered`, as Photos and Files are; I9 makes it the default). It opens `CameraScreen` in the scan screen's full-screen cover (`ScanCover`): the live preview, the page's outline over it (yellow, green once the page holds still), Done, the torch (where the camera has one), the shutter and how many pages the queue holds; one short line where the camera cannot run or waits. **The session** (`IOSCameraController`, `IOSCaptureSession` on a queue of its own): the camera `IOSCameraLens` picks among the device's cameras (`AVCaptureDevice.DiscoverySession`): the virtual camera that switches lenses by itself (`.builtInTripleCamera`, then `.builtInDualWideCamera`), so a page held close is taken with the lens that can focus on it, then the wide lens, then any other kind, a back camera before any other (`rank`, `choose`); on those two virtual cameras zoom 1 is the ultra wide lens's view, so the camera starts at the first of `virtualDeviceSwitchOverVideoZoomFactors` (the wide lens's view, `startZoom`, kept within the zoom the camera allows, set after the session is set up and again each time it starts), its lens switching left automatic so a close page still gets the close-focus lens; the `.photo` preset, then, where the camera has one, the smallest standard 4:3 video format (420f, not binned, 30 fps, at least 1920 × 1440) that takes photos of the size chosen below at the best quality (`IOSCaptureSession.outlineFormat`, `.inputPriority`), so the outline's frames are not 12 MP; photos of the largest size the format offers of at most `maxPhotoPixels` (12.6 MP: 4032 × 3024 on a 48 MP camera, never 8064 × 6048, whose RGBA pixels would take about 195 MB), else the smallest offered (`photoSize`, `photoOutput.maxPhotoDimensions`); quality first (`maxPhotoQualityPrioritization` and each photo's `.quality`), HEIC where the output writes it, else JPEG; focus continuous and kept near where the camera allows; BGRA video frames for the outline (`alwaysDiscardsLateVideoFrames`), the camera working without them when the session cannot add them. The turn comes from `AVCaptureDevice.RotationCoordinator` (iOS 17): the preview's connection follows `videoRotationAngleForHorizonLevelPreview` (watched by key-value observing) and each photo is taken at `videoRotationAngleForHorizonLevelCapture`, which the photo carries as its orientation tag. **The live outline** (`LiveQuadTracker`, fed through `FrameSource`: `IOSFrameFeed`, the video output's delegate, on the camera; fixture frames in tests): each frame is made small first (`IOSFrameScaler`: blocks of the smallest whole size that brings the long side to at most 480 px, the mean of four of each block's pixels, BGRA to RGBA), a frame sooner than 90 ms after the last one taken is passed over before that (about ten a second), and only one frame is searched at a time, on the frames' queue, never the main thread (late frames are dropped by the output); the shared page search (`PhotoDocumentDetector`, `analysisLongSide` 480, the frame before's outline as its hint) finds the page, a page missed for at most 300 ms keeps its outline (no flicker), and `CaptureStability` says how steady it is (as I8 built it; Vision finds the page first and the outline is steadied since, see **Page edges**); the outline is green (`isSteady`) while `.steadying`, and while `.captured` (which lasts until the page moves `newPageMovement` away) only as long as no corner strays `stayMovement` from where the page held still, green again once it holds still (no corner moved `enterMovement` since the frame before), so a page moved after it held still is drawn yellow; a frame from an earlier time (the session started again) or of another size starts over, and `reset()` (a photo taken, the camera stopped) drops a search running meanwhile. The outline is in shares of the sensor's frame and is drawn with the preview layer's own `layerPointConverted(fromCaptureDevicePoint:)`, which knows the preview's turn and where the frame sits in it. **The shutter** (manual in I8): `IOSCameraModel.shoot` takes the photo (`IOSCameraPhoto`: the file's bytes as the camera wrote them, with its orientation tag and EXIF, the turn, mirrored for a front camera) and hands an `IOSCameraShot` to `IOSImportSession.importShot`, which imports it exactly as a photo from the Files app (`IOSImportSource.shot`, named "Camera photo"): decoded by `IOSPhotoDecoder` (upright by its tag, at most 4000 px, the focal length in pixels from EXIF `FocalLenIn35mmFilm`), the page found again in the photo (`IOSPageFinder`: Vision, else the shared detector), the corner editor, then `AppState.ingest(_:source: .photo)` with the capture facts, so `PerspectiveStep` cuts it out at its real size; where the photo's own search finds no page clearly and Vision found no page in the photo (`IOSImportSession.seeded`, see **Page edges**), the outline the preview showed, turned into the upright photo's shares (`LiveQuadTracker.photoOutline`, by the capture's quarter turns; none for a mirrored photo), is the editor's start (`IOSImportSession.seeded`, kept within the photo and only when the page can be cut out along it). While the camera screen is open it shows the corner editor itself, over the preview (`editorInCamera`: the root view presents none meanwhile), and the camera stops until the editor closes; it shows the error alert itself too (`ErrorAlert`, the root view's alert, which cannot show over the cover), so a page not added or a photo that could not be read is said at once; Use corners puts the page in the queue and the camera comes back for the next page. The shutter waits while a photo is taken or read and while the queue cannot take pages (`canImport`). **Permission:** checked when the screen opens: no camera (`IOSCameraLens.hasCamera` false, as in the Simulator) says "No camera here" and asks nothing; access never asked is asked once (`AVCaptureDevice.requestAccess`, `NSCameraUsageDescription`), never again from the app; turned off says "Camera access is off" with a Settings button (`UIApplication.openSettingsURLString`); restricted says "Camera not allowed" (`IOSCameraAvailability.resolve`, the same states and lines as Apple's scanner, `ownCamera`); a session that cannot be set up says "Camera did not start". **When it runs** (`IOSCameraLifecycle`, a value the model feeds events, which answers start, stop or keep): only while the screen is shown, the app is in the front (`scenePhase`), access is given and the session set up, the thermal state is below `.serious` (`ProcessInfo.thermalStateDidChangeNotification`; "Paused: too warm") and no photo is in the corner editor; it starts again as soon as all of that holds. An interruption (`AVCaptureSession.wasInterruptedNotification`: a call or FaceTime, "Camera in use"; system pressure, "Paused: too warm"; other apps beside it on an iPad, "Needs full screen"; anything else, Control Center among it, "Camera paused") is the system stopping the session: it is not stopped again (a session stopped during an interruption is not started again by the system when it ends), the camera is not live (no outline, no shutter) and the line says why, until `interruptionEndedNotification`; coming back from the background or to the screen forgets an interruption whose end was not reported, while the app made active again without leaving the front (Control Center pulled down and closed) keeps it. A session error (`runtimeErrorNotification`) starts it again, up to three times while the screen is shown, then "Camera did not start". The torch goes off whenever the camera stops. Nothing is saved or sent: the photo goes into the queue as an imported photo does, and no photo is written to the Photos library. **Simulator:** it has no camera, so the camera screen shows "No camera here" there; `CameraTests` (UI) checks that, the shutter dimmed and Done back to the scan screen; the session itself, the wide lens's view at the start on Pro and dual-wide models, focus and macro switching, low light, the torch, the turn and memory over a long queue need a real iPhone. The privacy manifest is unchanged: AVFoundation's capture, the thermal state and the photo's EXIF use no required-reason API.

**Our own camera, part 2 (I9, Swift only on the iPhone; the shared pieces have twins).** **The default:** our camera is the first, prominent button of every scan screen that collects pages (**Camera**, `capture.camera`), and Apple's document scanner stays on the Document, Email and Word tasks as a secondary way in below it (**Use Apple's scanner**, `capture.scanner`, dimmed with its one line, `scanner.reason`, where it cannot run, as in the Simulator). **The automatic shutter:** each live frame searched is also measured (`FrameQuality` over the page found, see "Pipeline/FrameQuality.swift, DocumentEnhancer.swift"), so `CaptureStability` decides on steadiness, sharpness and light together, and `LiveQuadUpdate` carries its decision (`shouldCapture`) and judgement (`quality`); the shutter is driven by `shouldCapture`, never by the display-only `isSteady`. With **Auto** on (the camera screen's toggle, `camera.auto`, on by default, remembered in `UserDefaults` under `cameraAutoShutter`, the required-reason use CA92.1 the manifest declares already) `IOSCameraModel` takes the photo itself when an update says so and hands it to `onAutoShot` (the scan screen's import); a decision that comes while a photo is being taken or read (`canTakePage`) has the page judged again (`LiveQuadTracker.reset`), so it is taken once it can be; a photo that fails (`takePhoto` nil) says "Photo not taken" for 2.5 s (`failedNoticeNanoseconds`) and re-arms the page in view (`LiveQuadTracker.rearm`), so Auto takes it once it holds still again; a shot skipped in the corner editor (Skip or Stop: `IOSImportOutcome` with nothing added and one skipped) has the camera screen call `shotImported(_:)`, which judges the page still in view afresh (`LiveQuadTracker.reset`) so Auto retakes it, while a shot brought in, or one waiting behind another import (an empty outcome), changes nothing. A ring around the shutter fills while the page holds still (`progress`, Auto on only), the haptic tap follows every photo (`sensoryFeedback` on `shotCount`), and while a page held still waits for a better frame one line says why (`IOSCameraText.waitReason`: "Hold still" for a blurred frame, "Too dark"). Turning Auto on again has a page in view judged afresh only when it was decided on while Auto was off and no photo of it was taken (`LiveQuadTracker.rearm`); a page photographed by hand stays taken. Auto is a toggle to VoiceOver (`isToggle`, "On"/"Off"), the wait line is announced once per wait (`AccessibilityNotification.Announcement`, `IOSWaitAnnouncer`: when it is first shown while the page holds still, not again until the page is taken, moved or lost or Auto is turned off, however often frames near the limits flip it, and not while the import's progress or a message is shown in its place), and the scan screen's Camera button has a hint that holds whether Auto is on or off (`IOSCameraText.cameraHint`). **Continuous capture** (`IOSShell.capturesContinuously`: the task collects several pages): the camera stays open after each photo; after every photo, by hand or automatic, the page in view counts as taken (`LiveQuadTracker.markCaptured`, `CaptureStability.markCaptured`) and the outline starts again, so the next automatic photo waits for the page to go or move 15 % of the frame's diagonal (`newPageMovement`); stopping the camera for the corner editor, the background or heat keeps that (`pauseFollowing`), and the time it was stopped is not time without the page (`CaptureStability.resume(atMs:)` on the first frame after it), so a first frame that misses the page does not re-arm the shutter; only closing the screen forgets it. The photo is imported as in I8, except that a page the photo's own search found clearly (`IOSPageFinder`'s `.none`, before any live outline is used; I7's rule, as the Mac's and Windows' photo import cut a page found surely at once) goes into the queue along its corners without the corner editor (`IOSImportSource.asksOnlyWhenUnsure`, `importShot(_:asksOnlyWhenUnsure:)`); a page it was unsure of opens the editor, starting from the live outline only where Vision found no page in the photo. The bottom bar shows the last page taken (`camera.lastPage`) beside the count; Done goes back to the page strip. **The clean-up:** pages cut out of a photo are cleaned up by `EnhanceStep` in the clean-up stage (the task's color mode: color as auto, gray, black and white; photo tasks, photo prints and ID cards as photos), while Apple's scanner's pages, which it cleaned up itself, are left alone. **Simulator:** `CameraTests` (UI) opens our camera from `capture.camera`, checks "No camera here", the dimmed shutter, the Auto toggle, no last page and Done; `capture.scanner` is dimmed with `scanner.reason`, and `ImportTests` checks that too. The automatic shutter is checked without a camera (`LiveQuadTrackerTests`: blurred, dark and sharp frames through a `FrameSource`, a moving page, a photo taken by hand, a pause; `IOSCameraTests`: the model taking a page once, waiting for a sharp lit frame, Auto off and remembered, a decision that cannot be taken yet, continuous imports with and without the editor, the wait line said once per wait). Its timing, the thresholds on real frames, the clean-up on real photos and heat need a real iPhone. The privacy manifest is unchanged.

**Several objects per shot and the ID card on the iPhone (I13, Swift only on the iPhone; the shared pieces have twins).** **What is offered now:** besides the tasks that collect pages, Photos, Restore old photos and Receipts (several objects in one shot, then the photo review) and the ID card (front then back, then its review) are offered (`IOSShell.offers`, `takesPhotos`); the photocopy (a printer), Quick scan (an area on the preview) and Archive document stay dimmed. Their scan screens have Camera, Photos and Files as the others do (`offersOwnCamera`; `IOSImportSession.canImport` follows `takesPhotos`), and no Save of their own (`collectsPages`): each saves from its review. **The pipeline of a shot** (a camera's photo, a picked photo or a file, read and turned upright as in I7): for receipts and photos (`CaptureObjects.findsSeveral`) the photo is searched for its objects instead of a page (`IOSObjectFinder.find`: Vision's `VNDetectRectanglesRequest`, asked per kind as `IOSRectangleSearch.of` says, its shape window wider than the picker's since a tilted object looks narrower or wider than it is; its normalized corners in the photo's pixels, x · W, (1 − y) · H, named by where they are; `MultiQuadPicker.pick` for the kind; each kept within the photo and usable to cut along); the objects come in together with no corner editor (`CaptureObjects.pages`, `IOSImportSession.objectPages`, `AppState.ingest`), each cut out at its real size and cleaned up for its kind in the clean-up stage, and the photo review opens; a shot in which none was found comes in whole (`CaptureObjects.fallbackPage`) for the flatbed's search of the task: `ReceiptDetector` (thermal paper on a white table) or `PhotoDetector` (prints on a plain table), at 200 dpi. The next photo of the same import, the next page of a TIFF and the next page of a PDF are read once that review is closed (`IOSImportSession` waits; Stop ends the wait and the import without a problem). The review itself shows the import's progress ("Importing page 3 of 30…") and, while the import runs, Stop import, which ends it and leaves the review open: the import's own Stop is under the review. For the ID card the card is searched first (the same finder, the ID card's search and picker: one outline of about ID-1's shape); a card found in a camera's shot, which asks only when unsure (`IOSShell.capturesContinuously` is true for the ID card), goes in as the step's side without the corner editor only when its shape snaps to ID-1 (`CaptureScale.measure` with the photo's focal length, as the clean-up stage measures it; the picker's window is wider than the snap's 3 %); a card that would not snap opens the editor on its corners (reason `.unsure`), and a card not found opens it on the page finder's corners. Use corners takes the page as a card (`IOSImportSession.capturedPage(_:corners:focalLength:kind:)`, kind `.idCard`), and Use whole photo takes the whole photo as the card the same way, so every side is measured by `CaptureScale`'s ID-1 snap: one that snaps is at ID-1's size; one that does not is taken at 200 dpi, a made-up size, and its note says it is not at real size (`CaptureObjects.cardNote`). **The photo review** (`Views/PhotoReviewScreen.swift`, `IOSPhotoReviewModel`, the scan screen's full-screen cover `ScanCover.photoReview`, which takes the camera's place when the review opens): titled `AppState.reviewTitle` ("Found 3 photos", "Found 2 receipts"), a card per photo or receipt with Keep, Rotate (a quarter clockwise, applied when saved) and Fix crop (the touch corner editor, `CornerEditorView(fixesCrop: true)`, on the picture it was cut from with the corners it was cut along, `AppState.cropStart(for:)`; Use corners or Use whole photo cut it again, `recropPhoto(id:corners:)`: an object of a camera's shot with the perspective warp, one a scanner found at the scan's resolution as on the Mac; Cancel changes nothing), the receipts' Name by receipt date, One PDF for all (PDF only) and PDF or JPEG, Require a password while a PDF is saved (`IOSShell.reviewOffersPassword`, as the ID card's review has it: these kinds have no Export, so the password set in Settings would otherwise be in force unseen), Save (`reviewSaveTitle`, `saveReviewedPhotos`: photos as pictures in the task's format, receipts read once with text recognition and named by their date where it is found) and Cancel; it shows the error alert itself. **The ID card** (`Views/IdCardReviewScreen.swift`, `ScanCover.idCardReview`; `Views/IdCardGuide.swift`): our camera shows a guide frame of ID-1's shape (`IOSIdCardGuide.frame`: 0.86 of the screen's width, at most 0.6 of its height) with the side to take ("Fit the front in the frame", "Fit the back in the frame"), No back side at the back (`AppState.skipStep`, also on the scan screen's step card), and the glare hint in one line while the back is next after a front taken with glare (`IOSIdCardGuide.glareLine`: the front's note ends with `GlareDetector.hint` "Tilt to avoid glare"); the sides come in through the existing ID card flow (`IdCardSteps`, `recordIdCardSide`), each the card cut out at ID-1's size when it snapped (the side's dpi `CaptureScale`'s: its pixel width over 3.370 in), each side's note under it in the review, and the review (the Mac's; its Print came with AirPrint in I16) lays them out at real size (`IdCardComposer`: 85.60 × 53.98 mm on the page). **Memory only:** the card's photos, sides and corners are held in memory by the state (`idCardSourceImages`, `idCardCaptureFacts`, `idCardFront`, `idCardBack`), never spooled (the ID card's flow spools nothing), never in the scan history (`ingestPages` records none for a card's side), never written before the user saves (only `saveIdCard` writes, into the save folder), never saved to the Photos library (the app writes none) and never read by text recognition (`PageProcessor.forCapture` has no orientation step for the ID card, and the task's PDF is not searchable); Save, Discard, leaving the task or picking another drops all of it (`clearIdCard`). **Simulator:** it has no camera, so `PhotosTests` (UI) imports a drawn fixture of two prints on a dark table (`Fixtures/photos-on-table.png`, drawn by `scripts/make_ios_ui_fixture.py ... photos`, the same pixels as `ObjectShots.printsOnTable`) at launch into the Photos task (`-importFixture` with `-importTask photos`), checks the review's two cards and saves two JPEGs; `IOSObjectsTests` checks the rectangle search per kind, Vision's outlines mapped and picked (hand-made observations; Vision's own answer on a drawn photo where it runs, else skipped), the review model (Keep, Rotate, Fix crop, Save, receipts' choices), the next shot and the next page of a two-page PDF waiting for the review, a shot with no outline, the ID card from shots in memory only, and a card of 1.50 opening the editor and taken at 200 dpi with the not-at-real-size note; `CaptureFlowTests` and `CaptureObjectsTests` check the state and Core. Thermal and crumpled receipts, glossy prints, holograms and laminate glare, and Vision's rectangles on real photos need a real iPhone. The privacy manifest is unchanged: Vision's rectangle search uses no required-reason API.

**The remaining tasks on the iPhone (I14, Swift only on the iPhone; the shared pieces have twins).** **What is offered now:** every task but the photocopy (`IOSShell.offers`; the photocopy followed in I16, printed over AirPrint, see "PrintController"): Quick scan and Archive document join the rest. **The camera's words** (`Core/CameraTaskCatalog.swift`, Kit, Swift only, keyed by `ScanTask`; `TaskCatalog` stays the one source of titles and the scanner's steps on both platforms): `CameraStepText` (a `prompt` of ten words at most, a `help` of 25) for every task (`text(_:options:)`: what to point the phone at; the two-sided task's Flip & capture or fronts first, the book's page by page or whole spread), the lines while a back is due (`turnOverPrompt` "Turn the sheet over and take its back.", `backsPrompt` "Now take each back, first sheet first."), Flip & capture's front after the first sheet (`nextFrontPrompt` "Take the next sheet's front.") and after New document (`newDocumentPrompt`), `current(_:options:sides:newDocument:)` for the line now, and the buttons' and pickers' labels. Our camera shows the line under its top bar (`camera.prompt`, the help for VoiceOver; not for the ID card, whose guide frame speaks); the scan screen's step card shows the camera's line in place of the task's step for every task but the ID card (whose steps say which side is next) while the pages come from the camera, Photos or Files, and with a network scanner in use (or a stack turned over by hand) only while a back is due or a new document is pending (`IOSShell.cameraLine`, `usesNetworkScanner`); printer mode's card and Scan button say Document with the feeder as the source in Stack from feeder's words ("Load the pages in the feeder and scan.", Scan stack: `IOSShell.printerStep`, since the phone folds that task into Document). **Two-sided** (`Core/CameraSides.swift`, Kit, Swift only; `AppState.cameraSides`, set while the two-sided task is, in the way `TaskOptions.cameraFrontsFirst` says): pages from a photo (`ingest(_:source: .photo)`, our camera, Photos or Files, one page a shot or a PDF page) are marked with the side the steps are at through the camera arrangement (`ScanArrangement.cameraFront`, `.cameraBack`, `DocumentSides.markCamera`, shared with twins: a back is never turned for the binding, since the user turned the sheet over, and turning pages upright fixes one upside down). **Flip & capture** (the default): front, then its back, each given its sheet as it comes; No back (`skipCameraBack`, `task.noBack`) skips an empty back; the blank-page check still flags a back taken empty. Removing every page of the last shot from the strip steps back (`CameraSides.removed`, through `removePage`), so the shot taken again is the same side of the same sheet; only the last shot steps back, and a skipped back is no shot. **Fronts, then backs:** every front, Now the backs (`startCameraBacks`), then each back first sheet first; once there are as many backs as fronts the stack is put in reading order (`CameraSides.collation`: `DocumentSides.collateQueue` with the backs not reversed); Put in order before then (`putCameraSidesInOrder`) shows the manual interleave's mismatch (`sidesMismatch`, "2 fronts but 1 back") and a second press combines the pages as they are; a back taken meanwhile clears the mismatch, so the next press says the new counts first, and fronts first forgets a page removed from the strip. A save (or clearing the queue) starts the steps again. Turning a stack over by hand on a network scanner's one-sided feeder still takes over the steps and the camera waits for it, as `canIngest` says. Printer mode offers that stack's buttons as the Mac's banner does (`TurnedOverButtons`: Done with Fronts, Scan More Fronts, Keep Fronts Only, and Combine Anyway and Scan Back Sides Again with the mismatch shown), since its status line asks for them by name; a preset turned over by hand applied with no scanner selected comes in as both sides (`IOSPresetsModel.apply`), so the camera is not left waiting for a feeder. **Separate documents:** New document (`startNewDocument`, the main button between shots, `task.newDocument`) makes the next saved page that comes in (from a photo or a network scanner) start a new document (`DocumentBreak.split` on it; a separator sheet or a page left out as blank passes the mark on); the mark goes when another task is started or the settings no longer split into documents (`syncCameraSides`), and `applyNewDocument` sets it only while New document is offered; separator sheets are found on photographed pages as on scans: patch codes by the separator step (their bars are measured in inches, so a page must snap to a paper size: the screen says "Read once the page matches a paper size"), QR and barcode sheets by the barcode step with the Kit's `VisionBarcodeReader` (`Output/BarcodeServices.swift`, `VNDetectBarcodesRequest`; no ZXing on the iPhone) when the split is at barcode or QR sheets, reading the shared payload (`QrSeparatorSheet.text`, `BarcodeSeparators`); the scan screen picks Patch code or QR code (`setSplitMode`), names the QR sheet (`qrSheetName`) and saves the sheet as a PDF to print elsewhere (`saveSeparatorSheet`, then Share). **Book:** Page by page (the default: one page a shot) or Whole spread (`TaskOptions.cameraSpreads`: the open book in one shot, cut out of the photo and cleaned up first, `PageProcessor.prepare`, at its own pixels: `PerspectiveStep(spread: true)` matches it against no sheet size, so it keeps `CaptureScale.nominalDPI` rather than snapping to a sheet it only looks like, a Letter book's 17 × 11 in spread to an ID card or an A4 book's to A4; then cut at its spine by `BookSplitter.findGutter` in the reading order the settings say, Right to left beside the book's picker (`TaskOptions.bookRightToLeft`, `task.rightToLeft`; shown while spreads are cut for the source in use, Whole spread or a network scanner's scans, which are split whatever the camera's choice, `IOSShell.showsRightToLeft`), its shadow softened; each page keeps the spread's `source` and `capture`, so a page the clean-up made gray stays gray under the adjustments, with twins); the page strip's menu splits a spread again or joins it (`SpreadSplitSheet`, `AppState.spreadEditor(for:)`, `splitSpread`, `joinSpread`, as on the Mac); curved pages are not flattened. **Quick scan:** one shot through the corner editor; its page is held in memory (`AppState.quickScanPage`; `canIngest` is false meanwhile) for its screen (`QuickScanScreen`, `IOSQuickScanModel`, in place of the camera; on the phone a network scanner's page is held the same way, `holdsQuickScan(_:source:platform:)`, where the Mac saves a scan at once, and printer mode's step card says the area is chosen by tapping the preview, `IOSShell.printerStep`): Save JPEG (`saveQuickScan`, the task's picture format), Copy text (`copyQuickScanText`: the page's text through `OCRService` onto the pasteboard) and Discard; Live Text (VisionKit's `ImageAnalyzer` and `ImageAnalysisInteraction`, `LiveTextImageView`) selects part of the text on the page where the device supports it (`ImageAnalyzer.isSupported`; a plain picture otherwise, as in the Simulator). **Email a document:** as Document to PDF with the Compact size; its after-save action on the iPhone sends by email (`AppState.afterSaveFileAction`: `.share` becomes `.email` for the Email task on `.ios`), so `SaveActions.emailRoute` opens Mail's composer with the PDF attached when Mail is set up and the share sheet otherwise; nothing is sent without the user's tap. **Archive and password:** the Archive document card, and the PDF's choices on the scan screen (see "PDF/A-2b" and "Password-protected PDFs" above). **Text:** the Word task saves a .docx; a .txt comes from Also save text (.txt) among the PDF's choices (`OutputOptions.alsoSaveText`, `pdf.alsoSaveText`, as on the Mac), the pages' text beside the PDF. **The page strip** labels each page (`PageStripCell`: "1 · back" or "2 · left", the document it starts when the queue is saved as several, and the note on a page saving leaves out, "Separator"), read in full by VoiceOver ("Page 2, Sheet 1, back"). **Checks:** `CameraTaskTests` (shared: the catalog's words and budgets, `CameraSides`, the two-sided steps, New document, Quick scan, the email route and a whole spread through the state), the camera arrangement and spreads with their C# twins (`PageProcessorTests`, `DocumentSidesTests`, `CapturePageTests`), photographed separator sheets in both suites (`BarcodeTests`), the Vision reading of a photographed QR sheet (`VisionBarcodeTests`, skipped where the Simulator reads nothing), the camera options in `ModelsCompatTests` on both sides; `IOSCameraTasksTests` (the offered tasks' words, Archive and Password, the password form and prompt with a protected save, Quick scan's model, the strip's labels, and the two UI tests' imports without a screen), `IOSFileActionsTests` (Mail set up or not), `IOSShellTests`, `IOSCaptureTests` (several launch files); the UI tests `TwoSidedTests` (a two-page PDF under the two-sided task saves one PDF, its pages labelled front and back) and `BatchTests` (a page, the Patch T sheet and a page save two PDFs), their fixtures `Fixtures/two-sided.pdf` and `Fixtures/batch.pdf` drawn by `scripts/make_ios_ui_fixture.py`. A printed separator sheet photographed, a real book, Mail's composer and Live Text need a real iPhone. The privacy manifest is unchanged: VisionKit, MessageUI and Vision's barcode reading use no required-reason API.

**Presets, scans, saved files, the file name and Settings on the iPhone; the iPad (I15, Swift only on the iPhone; the shared pieces have twins).** **Settings** (printer mode's Settings row and, in camera mode, the library's toolbar, `library.settings`; on the iPad the sidebar's; Command-comma; a sheet on both layouts) lists Presets, Scans and Saved files, then the settings in the shared sections (`IOSSettingsSections` on `InspectorSections.shown`: the task's own for Receipts, Scanner, Output or Photos, Adjustments, Pages, Split into documents, Archive & password while a PDF is written, More options; each once, in the column's order, titled and summarized by `InspectorSections` with the dot and, for Archive with a password, the lock; the task's own, Scanner and Output open at first; which are open is kept in the user's defaults under `settings.openSections`, not in presets, and a task's section opens as on the Mac through `sectionsOpenedByTask`), then Troubleshoot (the troubleshooter's sheet) and About; while an import runs the sections cannot be changed, and the sheet presents the share sheet, Mail and Quick Look itself so Saved files works inside it (the version, "Built with Apple's frameworks only. No third-party code." since the iPhone app has no third-party code to acknowledge, and where scans stay). The iPhone differs from the desktop in one place: a queue saved as a picture a page (`IOSShell.savesImages`) writes no PDF, so Archive & password is hidden there and the text beside a PDF does not count. Scanner has Source (locked, with the Mac's reason, while an ID card side is held), Sides (with a feeder; "Needs the feeder" on the flatbed), Resolution and Color; Output has the format, the PDF's size, Searchable PDF, Collect pages before saving and Save to (the app's folder in Files with Show in Files; since I3 Choose… picks a folder elsewhere, kept as `destinationBookmark`, and Use app folder goes back). **Presets** (`IOSPresetsModel`; there are no built-in ones): Save preset asks for a name (blank is refused), a preset's menu or swipe renames or deletes it, tapping it applies it (`applyPreset`, fitted to the scanner, through `leaveIdCard`, so a held ID card side asks "Discard the ID card?" first, `IdCardDiscardQuestion`, the leave taken when the alert opens) and shows the scan screen, not while an import runs, whose title then names the preset's kind (`IOSShell.shownKind`; a preset's photocopy or Email task is applied as Document, `IOSShell.savingActionsAsDocument`, since they are Save's Print… and Email… on the iPhone, with nothing run after saving as Document starts, so an Email preset does not open the share sheet on every Save; its Compact size, shown in Options, stays), as the desktop's banner names its task; the task list (the iPad's start screen; on the iPhone the kinds row and chips took the task sheet's place) shows the presets first as tiles (My presets) as the Mac's does. **Scans** (`IOSHistory`): this session's `scanHistory`, newest first, read-only, each with its picture, "Document · 300 dpi" and its time (with the day for earlier days), shown larger on a tap. **Saved files** (`IOSSavedFiles`): the save folder's files newest first, as the desktop's Saved tab, the last save's marked New, each with Share, Show in Files and More (open, open with, email, copy, `AppState.runFileAction`); nothing is deleted there, as on the desktop. **File name** (`IOSNamingModel` on `NamingTokens`): the template, a button per part (put at the end with a space), the next file's name, and "Needs a file name" or "Unknown part {foo}"; a blank template keeps the last one in use, one with an unknown part is used as typed; one template for every task, as on the desktop. **The iPad:** on a regular width on an iPad (`IOSLayout.usesSidebar(_:pad:)`, `UIDevice.current.userInterfaceIdiom == .pad`, so a large iPhone turned sideways keeps the phone's layout; decided again as a Stage Manager window or Split View changes size) the window is a `NavigationSplitView`: the sidebar holds My presets, the six kinds and Add pages to a PDF as the task list has them (`IOSShell.kindTiles`, `sidebar.task.document` … `sidebar.task.text`, `sidebar.task.appendToPDF`, which picks the PDF in Files first), the scanners (`ScannerPickerSections`, the picker as a sidebar section, with Add by address and Troubleshoot) and the library (Presets, Scans, Saved files, Settings), and the detail the scan screen (its scanner row then only names the scanner) or the start screen or the library's screen; a compact width keeps the iPhone's stack. A kind picked in the sidebar goes through `leaveIdCard` as the Mac's tiles do. The scan screen's covers and the spread's sheet are the root view's (`ScanCovers`), so a resize across the width classes, which builds the scan screen anew, leaves the camera or the scan area open. Keyboard shortcuts (`IOSShortcuts`): Command-S saves, Command-N starts a new document where offered, Command-comma opens Settings, Space takes a photo while our camera is up and Escape closes it. Pages are reordered by dragging one onto another in the strip (`IOSPageDrop`, also Move left and Move right for VoiceOver), and PDFs or pictures dropped on the scan screen come in as Files' do (`IOSDroppedFile`, `importItems`, while the task takes photos). The scan screen's preview is sized from the visible height (`containerRelativeFrame`), not a fixed height. Checked by `IOSLibraryTests` (presets round trip through presets.json in a folder of the test's own, the history's rows and a page taken listed, the save folder listed, thumbnails, the file actions), `IOSSettingsTests` (the sections, the open sections' text, the sliders, the file name editor, the sidebar's width rule, the shortcuts, a dragged page, a dropped file) and the smoke test's second case (Settings, Presets, a preset saved and listed). The iPad's multitasking, a hardware keyboard and dragging in from another app need a real iPad.

**Two modes on the iPhone (Swift only).** The iPhone (a compact width) opens on the scan screen, the root of its `NavigationStack`, set up at launch for the task kept in the settings when this app offers it, else Document to PDF (`IOSShell.launchTask`; a task already set up is kept as it is, so a preset's settings stay, and settings left without a task by hand are kept too, the kinds then naming the one they look like; only the first run (`AppState.isFirstRun`) or a task not offered here goes through `startTask`; a photocopy or Email task kept from before opens as Document, since they are Save's Print… and Email… now). The screen is one of two modes (`IOSScanMode`, kept under `IOSShell.scanModeKey`; a fresh install starts in camera mode), which are also where the pages come from (the next paragraph). **Camera mode** (`CameraScreen`, the design's C3 Viewfinder) is the viewfinder as the screen, not a cover opened from it: a top bar with the library (`open.library`: `LibraryScreen`, pushed, Saved files or Scans picked with `library.part`, Settings in its toolbar, `library.settings`, Command-comma), a small round chevron (`drawer.toggle`, "Show options"/"Hide options") and the printer (`mode.printer`, to printer mode); the viewfinder (`camera.screen`), which shows the whole 4:3 photo (`videoGravity` `.resizeAspect`, black bands) with the live outline, one status line at its top (the ID card's glare hint `camera.glare`, why the automatic shutter waits `camera.wait`, "Page found · hold still" while the page holds still for it `camera.found`, else the task's camera line `camera.prompt`, as "Turn the sheet over and take its back."), the ID card's guide frame, and at its foot the notices on cards of the system's material (the `.csdoc` banner, while the app is busy outside an import (a save, a Word or text export, After saving's steps) printer mode's progress row `scan.progress` with the status line `camera.status` when the progress has no words and Cancel `cancel.button`, an import's progress with Stop `import.progress`/`import.stop`, and the files saved last with Share and Show in Files until the next page comes in, `saved.files`), the sides mismatch (white words, an orange icon, on a dark capsule), the task's buttons between shots (`CameraTaskButtons`: No back and Put in order white on dark capsules so they read over the white page, Now the backs, New document; the ID card's No back side `camera.skipBack`) and, once there are pages, Save on a capsule ("Save PDF · 3", `IOSShell.floatingSaveTitle`, `save.button`, Command-S) with Save's menu on a round button (`save.menu`); where the camera cannot run (no camera, as in the Simulator, "No camera here" `camera.message`; access off with Settings `camera.settings`; not allowed; too warm or interrupted) the line says why in the viewfinder's middle. Under the viewfinder the kinds as the Camera app's modes (`KindsRow`, `kinds.row`, `kinds.<kind>` in `IOSShell.cameraKinds`' order: Photos, Receipts, Document, ID card, Book, Text): a row that snaps one kind into its middle (`scrollTargetBehavior(.viewAligned)`, `scrollPosition(id:anchor:)`; every kind as wide, 96 pt grown with the text, `@ScaledMetric`, the text capped at the first accessibility size, as the drawer's icon row is), that one in the accent colour; a swipe that comes to rest (`onScrollPhaseChange`) or a tap picks it as a chip does, and a pick that does not happen (the ID card's or the pages' question cancelled, a kind not available) brings the row back. The chevron swaps the row for the options drawer (`CameraDrawer`, `drawer`), so options never cover the picture: an icon row of the groups that apply (`CameraDrawerGroup.shown(_:pageCount:torch:)`: Export while the pages are collected, Colour, Quality while Save writes a PDF, Flash where the camera has a torch (`IOSCameraModel.hasTorch`), Camera; `drawer.export`, `.colour`, `.quality`, `.flash`, `.camera`) and the chosen group's controls: Export the format (`drawer.format`) and chips for Separate documents, One PDF per page ("One PDF per sheet" with both sides, `IOSShell.eachPageTitle`, as the Export sheet's toggle says), PDF/A, Password and Also .txt where they apply (`chip.separate`, `chip.eachPage`, `chip.archival`, `chip.protect`, `chip.alsoSaveText`, the same switches as the Export sheet's) and More… (`chip.more`, the Export sheet itself, with the separator sheets and After saving); Colour the colour mode (`drawer.colourMode`, which the camera's clean-up follows, `DocumentEnhancer.mode(for:)`) and for Photos As taken or Restored (`drawer.restore`); Quality the PDF's size (`drawer.pdfSize`); Flash the torch, its switch named "Flash" as the group is (`IOSCameraText.flashLabel`), Off or On (`camera.torch`); Camera the automatic shutter (`camera.auto`, "Auto shutter"), Both sides for a Document (`options.bothSides`) with `TaskWayPicker`'s Flip & capture or Fronts, then backs and a book's way, and Use Apple's scanner where the task offers it (`AppleScannerRow`, `capture.scanner`). The bar at the bottom has the pages as a stack with a count badge (`camera.pages`, labelled "3 pages", which opens the page strip's sheet, `PageStripSheet`, Done `pages.done`, Split spread again included; it bumps and a tap is felt as a page comes in), the shutter (`camera.shutter`, "Take photo", a ring with a filled core and the automatic shutter's countdown round it, Space), and Photos and Files in grey circles (`ImportButtons(round: true)`, `import.photos`, `import.files`, Files offering `.csdoc` too, whose banner is now seen). The camera rests (`reviewStarted`/`reviewEnded`) while anything covers it: a cover of the root's (Apple's scanner, the scan area, the reviews, Quick scan, the copy screen), a sheet (the option groups, the page strip, the troubleshooter, and the root's Settings, share sheet, Mail and Quick Look), Files picking a PDF, Photos or Files, the ID card's and Send to computer's questions, the error alert, and the corner editor, which is always the root's full-screen cover now (`editorInCamera` is gone); it stops when the library is pushed. At launch, and when camera mode is switched to, `IOSShell.cameraOnOpen` decides whether the card saying why comes first, decided as the screen is drawn so the viewfinder never asks before it is up (`camera.intro`, "CompleteScanner scans with the camera.", Continue `camera.intro.continue`, remembered under `IOSShell.cameraIntroKey`): only while iOS has not asked yet and the card was never shown, never under `-demoScanner` nor where the camera cannot be used; the viewfinder waits for it before asking, and an iPad window narrowed to the scan screen alone counts that screen as shown, so the card is drawn there too. **Printer mode** is the printer screen (the design's C1 System): no navigation bar, a top row with the kinds as chips (`task.chips`, `task.<kind>`, tapping the one picked changes nothing) and the camera at their end (`mode.camera`, back to camera mode); the step card only while a step needs it (`IOSShell.showsStepCard`, in the step's own words, which speak of the scanner: `cameraLine` is nil in printer mode unless a camera back is due or a new document is pending); the flatbed preview or the last scan (`preview.area`); an inset grouped list with a row for each option group (`ScanOptionGroup`, `options.row.scanner`, always, `.book`, `.photos`, `.export`) that opens it as a sheet at half height that can grow (Done `options.done`), then the library and Settings rows (`open.library`, `scan.settings`); at the bottom the status line with a scan's progress, the capture bar (`CaptureBar`: the pages `capture.pages` and Photos and Files, an import's progress above them; no shutter) and Scan (`scan.button`, bordered, named for the step, `primaryActionLabel`, dimmed while the scanner cannot scan) beside Save (`save.button`, prominent) and its menu (`save.menu`). Save's menu is the same in both modes: Save as new PDF and Add to existing PDF… (and Stop Adding to… while a PDF is picked), After saving… (`save.afterSave`, its checks in a sheet of their own, `ScanOptionGroup.afterSave`), Print…, Email…, Share as CompleteScanner document and, with a computer paired, Send to computer. Anything the screen presents while an option group's sheet is up waits for it to close; the sheet closes as an import starts, as do the page strip, a spread's split sheet and Files picking a PDF, so the corner editor can show. Files opened in the app, a `.csdoc`, dropped files and the companion bring the scan screen to the front by closing the library. The iPad keeps its sidebar (kinds, presets, scanners, library); its detail shows camera mode's screen or the printer screen by the same mode, its navigation bar kept for the sidebar's button (with no background over the viewfinder) and holding the camera in printer mode. The task sheet and the camera's task chip are gone: presets are in Settings, and Add pages to a PDF is Save's menu's Add to existing PDF…. Checked by `IOSFlowTests` (the launch task, the card before the prompt, the step card, `cameraKinds`, the drawer's groups, the floating Save's title); the UI tests reach either mode with `switchToCamera()` and `switchToPrinter()` (the mode outlives the run; `waitForScanScreen()` says which is up), pick their task with `pickTask(_:)` (a chip, swiped into view, or camera mode's row a neighbour at a time; by way of another kind when it is already picked), open the drawer with `openDrawer(_:)` and close it with `closeDrawer()`, reach the printer screen's rows with `scrolledTo(_:)`, open an option group's sheet with `openOptions(_:)` and close it with `closeOptions()`, and the strip's sheet with `openPages(_:)` (which waits for the count on whichever pages button is shown) and `closePages()`; `CameraTests` checks camera mode's no-camera state, the drawer's Camera and Export groups and the switch between the modes.

**What you scan, options and Save's actions on the iPhone (Swift only).** The scan screen's top row asks only what is being scanned: six kinds (`IOSScanKind`: Document "Pages into a PDF", Photos "Prints and pictures", Receipts "Named by their date", ID card "Front and back on one page", Book "Pages or whole spreads", Text "One shot, copy the text"), each a chip there and a kind in camera mode's row (`task.document`, `task.photos`, `task.receipts`, `task.idCard`, `task.book`, `task.text`; `IOSShell.kindTiles`, dimmed with its task's card's reason) that starts its task (`IOSScanKind.task`: `.document`, `.photos`, `.receipt`, `.idCard`, `.book`, `.quickScan`) through `startTask` as the tiles did, so flows, camera prompts and reviews are unchanged; the pages taken go along to a kind that collects pages (Document and Book, `TaskCatalog.carriesPages`: the count, the page strip and the floating Save's count stay), and any other kind (Photos, Receipts, ID card, Text), which would leave them without a Save (`AppState.pagesLeftBehind(by:)`), asks first (`KeepPagesQuestion`, an alert like the ID card's: "Keep the 3 pages?", `IOSShell.keepPagesTitle`, "Photos does not collect pages. Save them first, or discard them.", `keepPagesLine`): Save first (`saveFirstLabel`, "Save PDF first", "Save 3 JPEGs first", "Add to Contract.pdf first"; Save's own save without After saving's steps, then the kind once the queue is empty, none when the save failed or was cancelled), Discard 3 pages (`discardPagesLabel`, destructive: `AppState.discardPages(andStart:)`) or Cancel (the kind and the pages kept, the row back); the camera rests while it is up, and with a side of an ID card held the card's question follows. The same question (keyed on what was asked for, `PagesLeave`: its reason, `IOSShell.keepPagesReason`, and the action, run once Save first's save has emptied the queue or with the pages to be dropped) comes before the iPad's sidebar and task list start a task (`IOSRootView.pickTask`, which then asks about an ID card held; the kind already set up only shows the scan screen again, its options, steps and PDF picked kept), before a preset whose settings do not collect pages (`IOSPresetApply.waitsForPages`; Settings' Presets, the sidebar and the task list; Discard drops the pages, then applies) and before the package banner's Open as new replaces queued pages ("“Trip.csdoc” opens in their place."). Save first is left out when it could write nothing (every page skipped) or cannot run now (an import, or on the scan screen a share or a send to the computer reading the spool, which also holds the kinds and Open as new). Save, its menu and Export stay while a document task holds pages (`IOSShell.offersSave`), so turning Collect pages before saving off, or a Word or Text save that puts its pages back, never hides them. Picking a scanner while a side of an ID card is held asks to discard the card first (`ScannerPickerSections`, `leaveIdCard`), since a scanner without a flatbed ends the task. Add pages to a PDF stays. The chip picked and camera mode's kind picked (selected for VoiceOver) name the kind (`IOSShell.shownKind`: `kind(of:)` of `TaskCatalog.infer`, so Stack from feeder, Two-sided, Separate documents, Email, Word, Archive and the photocopy show as Document, Restore old photos as Photos, Quick scan as Text, and a preset's or a hand-made setting's kind is the one it looks like). `TaskCatalog`, `ScanTask`, the Kit's flows and the desktop's tiles are unchanged; the iPad's sidebar offers the same kinds; every task is still offered (`IOSShell.offers`) for presets, `-importTask` and the companion. The rest is in the option groups, each only where it applies: Scanner in printer mode (the scanners, see "The mode is the source", then the scanner's settings: `ScannerSettingsRows`, the Settings rows, each picker beside its name, and the flatbed's Preview; the camera's Both sides, `options.bothSides`, with `TaskWayPicker`'s Flip & capture or Fronts, then backs, and Use Apple's scanner are in camera mode's drawer, "Two modes on the iPhone"), Book (`TaskWayPicker`), Photos (Restore faded colours, `options.restore`) and Export while the pages are collected (the format in a section of its own, `options.format`: PDF, JPEG, Word or Text, `IOSShell.exportFormats`, the picture segment naming PNG or TIFF instead when Settings chose one, since that is what is saved; Separate documents, `options.separate`, with `SeparatorSheetRow`; One PDF per page, `options.eachPage`, for a PDF not split otherwise, named One PDF per sheet while the feeder scans both sides, since a sheet's front and back stay together; `PDFOptionsSection`; and After saving, `IOSAfterSave`: Email, Print and Send to PC, `options.afterSave.email`, `.print`, `.send`, each a check kept in the user's defaults, "Runs each time a document is saved. Change it any time."). Save runs what is checked in the order Send to PC (only while a computer is paired, else skipped without a word; `sendQueueToDesktop(target: .new)`), Print, Email. Send to PC and Print take the queue, which the save empties, so they come before the file is written: Print is Print…'s copy screen and the save starts once it has closed; Email is Email…'s `saveAndEmail(images:)`. A send that fails shows its error and the file is saved without Print and Email, which could not show over the alert. Save's menu runs each of its items once, whatever is checked. The switches set only their own fields, never through `TaskCatalog.apply`, which resets the rest: Both sides is the two-sided task with the feeder and both sides (`IOSShell.settingBothSides`; off, Document on the flatbed), Separate documents the Batch task at patch code sheets (QR code kept when chosen) on the feeder, named "Document {label} {date} {counter}" as its tile named them (`settingSeparate`; off, Document on the flatbed, no split, and "Scan {date} {counter}" again unless the name was changed), Restore faded colours Restore old photos (`settingRestore`: the restore and enhance adjustments and PNG; off, Photos and JPEG), One PDF per page a new document every sheet (`settingEachPage`, `SplitMode.sheetCount` of one); Both sides and Separate documents are dimmed with "Needs a document feeder" when the scanner set up has none, as their tiles were, and each ends the other (Separate documents turns the sides, straightening and turning off with Both sides); both are fitted to the scanner as a task is (`SettingsAdapter.adapt`), so a scanner without a flatbed stays on its feeder. The Scanner rows' Source and Sides go through `keepingKind` too, so one that ends Both sides or Separate documents leaves Document, not no task. A format or PDF/A change that leaves the task unfit keeps its kind (`IOSShell.keepingKind`: Word saved as a PDF, or Archive turned off, is Document again). The queue is never touched: settings changes keep `scannedPages`. Save's menu (`save.menu`) keeps Save as new PDF and Add to existing PDF… and adds Print… (`save.print`: `AppState.printQueueAsCopy()` holds the pages Save would write, at full resolution, on the copy screen whatever the task; `copyIsOfQueue` keeps them held through settings changes outside the copy flow, the copy screen's Discard reads Close and only closes, the status then counting the queue, and a print that failed without the PDF's password leaves them held rather than queued again) and Email… (`save.email`: `AppState.saveAndEmail(images:)` saves as Save would and runs `.email` after that save alone, `emailsAfterSave`, cleared when the operation ends however it ended); the format moved to Export. Checked by `IOSFlowTests` (which kinds take the pages along, the pages' question's words, `kind(of:)` for every task, an Email preset applied as Document with nothing after saving, each kind's task and shown kind, the tiles, each switch both ways with the other choices kept, `keepingKind`, the Export format), `IOSShellTests` (the switches on an `AppState` with a page queued, Email… for one save only), `IOSCopyTests` (Print… at full size, held through Copies, Close keeps the queue), and the UI tests: `TwoSidedTests` and `BatchTests` import into their tasks at launch and check the chip says Document and the switch is on, then pick Document and turn Both sides or Separate documents on and off (`turnSwitch`, `chipTitle`, the picked chip's title, in `UITestSupport.swift`); `SmokeTests` opens Print… and closes the copy screen with the page kept; `ImportTests` picks Receipts and the ID card over an imported page, asked first both times, Cancel keeping Document and the page, then Book, which keeps it; `ScreenshotTests` shoots camera mode (01-camera), its kinds with Receipts picked (02-kinds-receipts), its drawer on Export (03-drawer-export), printer mode (04-printer), the Scanner sheet (05-scanner-sheet) and the Export sheet (08-export-options); `IOSSettingsTests` checks After saving's order and the skipped Send to PC.

**The mode is the source on the iPhone (Swift only).** The pages come from one source at a time, and the mode says which: camera mode takes them with our camera (and Photos, Files, Apple's scanner), printer mode with a scanner. The mode and the scanner picked last are kept apart in the user's defaults (`IOSShell.scanModeKey`, `camera` or `printer`; `IOSShell.scannerKey`, the scanner's id), so switching to camera mode leaves the scanner remembered and switching back finds it again. The `scan.source` key of before is read once at launch and removed (`IOSShell.migratedScanner`): a scanner kept there, not the demo scanner, comes back as printer mode's when no mode was kept yet. Printer mode's Scanner options list the scanners only (`ScannerPickerSections`, `scanner.row.<id>`, the one scanned with checked; "No scanner found" `scanners.empty` with Troubleshoot; the explanation card and the line about Local Network access; Add by address `scanner.add` and Troubleshoot), then the scanner's own settings (`ScannerSettingsRows`) and the flatbed's Preview; there is no Camera row. Settings' Scanner section shows those rows only with a scanner selected; with none it says "Pick a scanner in printer mode to change these." (`IOSSettingsSections.scannerRowsReason`), and its Source always lists the source chosen (`offeredSources`), so Both sides set up for the camera never shows as a blank Source; Source locked while a side of the ID card is held says so in the phone's words (`IOSSettingsText.idCardHeldReason`). The Scanner row reads the scanner's name and its Source ("Demo Scanner · Flatbed"), or "No scanner" until one is picked or found. Picking a scanner, adding one by address (in the picker or the troubleshooter) or picking one in the iPad's sidebar selects it, remembers it and switches to printer mode; the sidebar's pick (or add) brings the scan screen back as its detail (`ScannerPickerSections`' and `ScannerPickerSheets`' `onPicked`). Camera mode selects no scanner (`AppState.userSelectNoDevice`), so no scanner's capabilities apply to the camera (Both sides, Separate documents, the kinds' availability, Right to left), and the user's switch to it turns sides turned over by hand back to both. `IOSShell.printerScanner` is the scanner only in printer mode while the remembered id is listed and selected, so a scanner not found yet leaves printer mode with none until it is, and a scanner found on its own never takes its place; the root view keeps the selection on the mode (`followMode`, on the mode's, the list's and the connection's changes): in printer mode the remembered scanner once listed (`IOSShell.followedScanner`, by way of `listedScanner`, which also follows the scanner to another connection the app moved it to), picked again once connected so a scanner found later does not take its place; else none, keeping the sides as they are (`resetsManualSides: false`). At launch the state itself waits for that scanner (`AppState.start(onlySelecting:)`: nothing is selected on its own, the remembered id is opened as the user's pick once it is listed, nil in camera mode), so the first scanner discovery lists is never connected to first; the Mac's `start()` is unchanged. It waits while a scan, a review, an import or a cover is under way or a side of an ID card is held, and tries again when they end. At launch camera mode selects none (sides by hand back to both), as does printer mode with no scanner remembered; without `-demoScanner` a remembered demo scanner (`mock:`) is forgotten and the phone opens in camera mode. Checked by `IOSShellTests` (`printerScanner`, `listedScanner`, `followedScanner`, the step card in printer mode), `IOSFlowTests` and `EsclScannerBackendTests` (no scanner kept while the list changes; the sides by hand reset by the user's switch to the camera, kept by the phone's own deselect); the UI tests pick the demo scanner with `pickScanner(_:)` in printer mode (it drags the half-height sheet to full height, `growOptions()`): `SmokeTests` and `ScreenshotTests` before Scan, and `ScannerPickerTests` lists the demo scanner and no camera, then checks that printer mode scans with it, camera mode has the shutter and no Scan, and printer mode finds the demo scanner again.

**Page edges (the live outline on the iPhone, Swift only; the photo import's refinement on every platform).** **Live:** each frame the feed hands over (at most one per 90 ms) is searched whole by Vision's document segmentation on the camera's own pixel buffer (`IOSPageFinder.segmentation`, the request the photo import makes; the frame searched as the sensor gives it, `.up`, since the outline lives in the sensor's frame; the normalized corners at x · w, (1 − y) · h of the small frame), and the tracker takes that page when `IOSPageFinder.accepted` does (a document page's size and shape, usable corners) and Vision is at least as sure as holding still needs (`CaptureStability.enterConfidence`, 0.6, so a page it takes can be taken by the shutter); once Vision has found the page the shared search waits until Vision has missed it for 300 ms, so the two outlines do not take turns; otherwise, as before, the shared page search on the small frame (`analysisLongSide` stays 480: with Vision first the Kit search runs mostly on frames with no page, and the 90 ms budget was not measured on a phone). What either finds goes through `LiveQuadFilter` before it is drawn or judged: a corner within 1 % of the frame's diagonal of the outline before moves halfway (jitter damped), a corner further off is followed at once (a page slid along is not drawn behind it), a jump of more than 6 % is passed over once and believed when the next frame finds the page away from the outline too (a page swept fast is then followed frame by frame), a page seen for the first time is drawn from its second sighting, and a page drawn and then missed keeps its outline for 300 ms after it was last found; corners are paired with the outline before from whichever corner fits, as `CaptureStability.movement` pairs them. `CaptureStability` judges the steadied page (a jump passed over counts as a frame without the page), so the automatic shutter fires on the outline drawn. `reset()` (a page judged afresh, Auto turned on again) keeps the outline drawn and forgets only how steady the page was and whether it was taken. `LiveQuadTrackerTests` script the filter (jitter, a slide, a jump, a fast sweep, a stray outline, corners renamed, a loss held then cleared, a first sighting forgotten) and the Vision path with stand-in pages (the confidence floor, the search waiting while Vision answers, Vision flickering). **Photos:** `QuadRefiner` (Kit, C# twin) moves a rough outline onto the photo's edges: within 3 % of the diagonal either side of each side it scores every straight line by the points where it passes a ridge of the gradient across the side, takes the outermost of the lines within 70 % of the best (a header bar just inside a page scores as well as its edge), though a line more than a third of the band outside the side wins that way only as the best line (most points, the nearer on a tie), so a desk edge, a folder or a sheet under the page just outside it does not take the side; fits it to a fraction of a pixel, keeps a side in place when its edge is clear at fewer than half its points, and takes the crossings only while the outline stays convex, no corner moved more than twice the band and its sides lie on stronger gradient than the outline given; `support` is the share of the weakest side lying on a clear edge. `PhotoImport.plan(_:)` refines the page the detector found on every platform (the Mac and Windows import too; the decision and the reason are the detector's as before). On the iPhone `IOSPageFinder.find` refines Vision's outline and calls it found clearly (`.none`) only when Vision was at least 0.7 sure and the support is at least 0.7; otherwise `.unsure`, and the corner editor opens on the refined corners (a camera photo's live outline is the editor's start only where Vision found nothing in the photo, `IOSImportSession.seeded`). Checked by `QuadRefinerTests` on both sides (the synthetic photos' outlines put 1 % off or 2 % too large come back within 0.3 % of the diagonal, a page's own outline is backed all round and one 2 % too large is not, a header bar does not pull the top edge, a page on a folder stays on its own edges and an outline just inside it does not go to an equally sharp edge outside, a table with no page leaves the outline alone with no support, a large photo answered in its own pixels), `PhotoImportTests` and `IOSImportSessionTests` (the sure rule on a drawn photo). How the live outline holds on real pages, the Vision frame rate on older phones and the refiner on real photos (shadows, a table edge just outside the page) need a real iPhone.

Where an `AppState` keeps its files is `AppStateFiles`: the shells get `standard` (the settings in Application Support, the spool `CompleteScanner-pages` in the temporary folder, devices.txt in ~/Library/Logs/CompleteScanner); `AppStateSeamTests` pass `all(in:)` a folder of their own, so `swift test` never reads the user's settings, empties the spool of an app running beside it or overwrites its devices.txt. The iPhone's `makeForIOS` passes `keepsQueue` (not under `-demoScanner`, whose UI tests start empty): `keepingQueue` puts the spool in Application Support (out of backups), and the queue is recorded beside it (`QueueRecord`, queue.json: each page's spool file and the version not shown, with its facts; the spreads and the spine's shadow stay in memory) half a second after it changes and when the app goes to the background, the record removed with the last page. The next `AppState` brings the queue back when the record reads, every page's file is there and the settings it starts with save a queue (`.documentQueue`): the other files go, the previews are read from the files off the main actor, and the pages go before any added meanwhile; otherwise the spool is emptied as before (`AppStateQueueRecordTests`). Swift only: Windows still empties its spool at launch. Importing photos on the Mac (`importPhotos`) keeps its own loop for now, since the corner editor answers photo by photo.

### Backends/ICScannerBackend.swift (CompleteScannerMac)

```swift
public final class ICScannerBackend: NSObject, ScannerBackend { ... }
```
ImageCaptureCore implementation: `ICDeviceBrowser` (scanner mask, local + bonjour + shared), sessions via `ICScannerDevice` (see task brief).

### Backends/MockScannerBackend.swift

```swift
public final class MockScannerBackend: ScannerBackend { ... }
```
One demo device, `ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true)`; synthesizes deterministic flatbed images (see task brief). For the ID card task (`settings.task == .idCard`) its glass holds a made-up sample card (ID-1 size, rounded corners, "SAMPLE", a grey photo placeholder, field bars; a barcode and code blocks on the back; no real document and no flags), front down at (2.35, 1.75) in tilted 4°: a scan delivers the side facing the glass and then turns the card over where it lies (`idCardTurnedOver`, tilt mirrored), so scans alternate front, back; a preview shows the side without turning it (C# `IdCardTurnedOver`, drawn pixel by pixel there and with CoreGraphics here). It also has a document feeder (`sources: [.flatbed, .documentFeeder]`, `feederSizeInches` 8.5 × 14, `supportsDuplex` = `feederDuplex`, default true): a feeder scan returns `feederSheetCount` two-sided sheets (default `MockScannerBackend.defaultFeederSheetCount` = 3, read when the scan starts; letter size, or the paper size asked for; the front of sheet *n* carries *n* square marks near its bottom left corner, its back *n* marks near the bottom right, both upright), front and back of each sheet for `.both` on a two-sided feeder, otherwise the side facing up: a one-sided scan with `.manual` turns the stack over (`feederStackTurnedOver`), so the next one delivers the backs, last sheet first; any other feeder scan puts it back the right way up; a scan cut short by a jam leaves the stack as it is; `lastScanDuplex` says whether a scan asked for `.both` scanned both sides; and 0 sheets fails with `ScanError.scannerProblem(.feederEmpty)`. `feederJamsAfter` (default nil) makes the sheet after that many jam: the earlier sheets are returned and `lastScanStop` carries `.paperJam`; a jam on the first sheet fails with `ScanError.scannerProblem(.paperJam)`. `feederBlankBackSheets` (a `Set<Int>` of sheets counted from 0, default empty, read when the scan starts) makes those sheets' backs blank: off-white paper with noise, a few specks of dust and the front showing through mirrored at a tenth of its darkness (`BlankPageDetector` finds them blank; no sheet marks); the app's demo scanner (`AppState.makeDemoBackend()`, which the Mac app passes in and `AppState` uses alone when a shell passes no backends) has a blank back on its second sheet. For the Receipts task (`settings.task == .receipt`) the glass holds two made-up receipts ("DEMO CAFE" 3.15 × 3.2 in at (2.4, 3.2) in tilted 3°, "SAMPLE MART" 2.28 × 2.3 in at (6.3, 3.0) in tilted −3°; paper 237, print 153 in a plain stroke type of polylines on a 4 × 6 grid, dated 12.03.2026 and 2026-02-27), drawn pixel by pixel as the C# demo draws them (`MockScannerBackend.demoReceiptPlaces`, C# `MockBedRenderer.ReceiptPlaces`). For the Batch task (`settings.task == .batch`, document mode) the feeder holds `batchSheetCount` sheets (default `defaultBatchSheetCount` = 7) instead of `feederSheetCount`, the sheets in `batchSeparatorSheets` (default [2, 4]) being separator sheets: the Patch T sheet of `PatchCodeDetector.renderSheet` (toner 28, paper 247) on the front (split at barcode or QR sheets, `Code39.renderSheet` of `batchBarcodeText(n)`, "CS-SEP INVOICE 1002" in front of document 2, instead) and a blank back (`renderBlankBack` with that front showing through); the other sheets keep their marks, so the stack is documents of two, one and two sheets. Same behaviour as the C# `MockScannerBackend` (`FeederSheetCount`, `FeederJamsAfter`, `FeederDuplex`, `FeederStackTurnedOver`, `FeederBlankBackSheets`, `BatchSheetCount`, `BatchSeparatorSheets`).

### UI files (`Sources/CompleteScannerMac/UI/`, all `internal` to CompleteScannerMac, SwiftUI, bind to `@EnvironmentObject var state: AppState`)

- `CompleteScannerMac/UI/SidebarView.swift` — `struct SidebarView: View`: device list + refresh (`refreshScanners()`), the "Why isn't my scanner listed?" button in the Scanners header and, in the empty list, "No scanner found" with a Troubleshoot link, the troubleshooter sheet (`state.showTroubleshooter`), and the Phone button with its sheet (`PhoneView`).
- `CompleteScannerMac/UI/PhoneView.swift` — `struct PhoneView: View`, `PhonePairingQuestion`: "Send from your phone", the Mac's Phone window (see "The companion host on the Mac"). `PhoneBarView.swift` — `struct PhoneBarView: View`: the bar under the tab bar while `state.phoneBarMessage` is set, with a close button (`dismissPhoneBar`).
- `CompleteScannerMac/UI/TroubleshooterView.swift` — `struct TroubleshooterView: View`: one headline line (`Troubleshooter.overview`), the troubleshooter's checks as cards (title, one-line detail, buttons other than Refresh, "More help" with `more`) and passed checks as compact rows (their detail as help; `TroubleshootCheckCard`, which the Phone window shows too), Refresh, Copy Diagnostics and Done.
- `CompleteScannerMac/UI/InspectorView.swift` — `struct InspectorView: View`: the settings in disclosure sections (`InspectorSections`): the task's own section (Photocopy: Printer, its paper, Copies 1–99, Fit to page, the margin warning, Also save a PDF, Print Test Ruler…, without a printer the reason and Look Again; Receipts: Name by receipt date, One PDF for all, off for image formats), Scanner (Source, Sides with "Needs the feeder" on the flatbed, Flip on, Paper size with "Using the selected area" while an area is selected, Resolution, Color), Output (Format from `OutputFormat.offered(for:)`, PDF size and Last PDF, Include page images, Searchable PDF while the save writes a PDF, Collect pages before saving, Save to) or Photos in Photos mode, Adjustments, Pages (Skip blank pages and What counts as blank with the High warning, Crop to page, Straighten pages, Rotate pages upright, Split facing pages with "Not with two-sided" and the book options), Split into documents (`SplitMode.displayOrder` through `state.setSplitMode(_:)`, an info popover with `SplitMode.steps`, the mode's `caption`, New document every N sheets through `setSplitSheetCount(_:)`, at codes "Codes are on" with `startsDocumentCaption`, Name on sheet, Save Sheet and Print Sheet), Archive & password whenever the save writes a PDF (a queue of image pages too, a copy also saved as a PDF; the Windows `WritesPdf`: Archival PDF (PDF/A) and Require a password, each greyed out with its short reason and a lock while the other is on, see M19 and M20) and More options (Also save text (.txt), After saving, File name with the naming tokens popover); then presets and Preview/Scan/Cancel. The task's section, Scanner and Output start open; the others start collapsed, remembered per user in `@AppStorage` (`inspector.section.<id>`); a task opens the section it needs (`InspectorSections.openedBy`) without remembering it, and it stays open for the session until the user closes it (`AppState.sectionsOpenedByTask`, so switching tabs keeps it open, as the Windows window does); a collapsed header shows its summary and a dot when something differs from the default; what a control does is its help, and a line under it stays only for a greyed-out control's reason, a consequence or live state.
- `CompleteScannerMac/UI/StatusBarView.swift` — `struct StatusBarView: View`: the status in six words at most (`StatusLine.shown`: empty while a review shows its title, "Saved" while the saved files' actions show), with the whole sentence as its accessibility label, progress, and the actions for the files saved last (open, show, share, copy; More adds open with and email).
- `CompleteScannerMac/UI/PreviewCanvasView.swift` — `struct PreviewCanvasView: View`: shows `state.canvasImage`, marquee selection editing `state.selectionRect` (only when `state.overviewImage != nil`).
- `CompleteScannerMac/UI/PagesStripView.swift` — `struct PagesStripView: View`: page-queue thumbnails + Save PDF (or Save Word / Save Text: `format.saveTitle(pageCount:)`; "Save 3 PDFs (7 pages)" for a split queue: `SavePlan.saveTitle`; with a lock, read as "Save password-protected PDF", while the PDF gets a password) / Clear; the queue summary is `DocumentSplitter.queueSummary`; while `DocumentSplitter.showsBreaks`, a gap before each page (`breakLabel`, a bar where a document starts) calling `state.toggleDocumentBreak(id:)`; the first page of each document titled (`dividerTitle`) in place of its caption; separator pages badged "Separator" (help: `separatorNote`), dimmed, with Keep; each page's context menu adds its split or join (`breakLabel`) and Name This Document… (an alert with a text field, `state.setDocumentLabel(id:label:)`, prefilled with `documentLabel(of:)`); Copy Text in each page's context menu (`state.copyPageText(id:)`); the queue summary, each flagged page's badge and its Keep or Skip button (always shown), left-out pages dimmed, Save PDF counting the pages it writes; under a cropped or straightened page, its swap button (always shown: `PageCorrections.toggleLabel`, help = caption and label) calling `state.togglePageGeometry(id:)`.
- `CompleteScannerMac/UI/PhotoReviewView.swift` — `struct PhotoReviewView: View`: detected-photo grid sheet with the "After saving" choice; Save via `state.saveReviewedPhotos()`, cancel via `state.cancelPhotoReview()`; titled `state.reviewTitle` and saved with `state.reviewSaveTitle` ("Found 3 photos" and "Save 3 photos", `PhotoReview`; "Found 2 receipts", "Save as One PDF" for receipts).
- `CompleteScannerMac/UI/IdCardReviewView.swift` — `struct IdCardReviewView: View`: the ID card's sheet (`state.showIdCardReview`, presented from the detail in `ContentView`): the privacy line (`IdCardSteps.privacyNote`, its sentence as help), each side with Rotate, Fix crop (the crop editor) and Scan again (their names keep the side), a missing back with Scan the Back, Swap Sides, the page picture with its caption and the not-at-real-size warning, and Paper, Save as (PDF or an image format: `format.pageFormat`; a text format chosen in the inspector shows and saves as PDF), "Also save sides as images", Print…, Discard and Save.
- `CompleteScannerMac/UI/PDFPasswordWindow.swift` — `enum PDFPasswordWindow` (`static func ask() -> PDFProtection?`, `AppState.askPDFPassword` on the Mac), `PDFPasswordForm`, `PDFPasswordView`: the password dialog of a protected PDF, a modal window of its own (so it also comes up over a review sheet; it does not bind to `state`): the warning (`PdfProtection.DialogMessage`, `DialogHelp` for VoiceOver), Password and Confirm (secure fields, emptied when it closes), the strength bar and label, the problem line, Allow printing and Allow copying with the short note, Cancel and Save. Twin of the Windows `PdfPasswordWindow` (see "Password-protected PDFs").
- `CompleteScannerMac/UI/TaskStartView.swift` — `struct TaskStartView: View` (`onOpenScanner: () -> Void`): the user's preset tiles first (only when there are presets), then the task tiles (`state.taskCards`) in their groups (`TaskCatalog.sections`): an icon and the title, the subtitle and settings summary as help, a dimmed icon and the short reason for a task that cannot be started; also `enum TaskSymbols` (icon key → SF Symbol; "receipt" → `receipt`, "batch" → `square.stack.3d.down.right`, "book" → `book`).
- `CompleteScannerMac/UI/TaskBannerView.swift` — `struct TaskBannerView: View` (`definition: TaskDefinition?`, `onChangeTask: () -> Void`): the active task, or turning a stack over by hand without one (`definition` nil), above the preview, with Change Task and a leave-task button (without a task: scan one side only); fronts scanned without moving on (the feeder stopped early), Done with Fronts; while the backs are due, Keep Fronts Only, before any back is scanned Scan More Fronts, and on a count mismatch also Combine Anyway and Scan Back Sides Again; the back of an ID card (`state.canSkipStep`) offers "No back side" (`state.skipStep()`); the leave-task button goes through `state.leaveIdCard(then:)`. The banner shows the task's title (with "Front · Back · Check" for a task of several steps, the current step stressed), the step's one-line `prompt` and an info button with its `help`.
