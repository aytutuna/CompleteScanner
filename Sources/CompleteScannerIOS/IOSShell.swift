#if os(iOS)
import AVFoundation
import CompleteScannerKit
import Foundation
import UniformTypeIdentifiers

/// What the app was launched with. `-demoScanner` (the UI smoke test's) keeps the app on the demo
/// scanner alone: the iPhone has no other connection yet, and once it has (eSCL), a test launched this
/// way still scans the same made-up pages. `-importFixture` (the import UI test's) imports one photo at
/// launch into the Document task, as the Files app would hand it over: its PNG bytes, base64, in the
/// environment variable `importFixtureVariable`, since a UI test cannot drive the system's pickers;
/// `-importTask` followed by a task's name (`ScanTask`'s raw value, "photos") imports it into that task
/// instead (I13: the photos UI test). Since I14 the variable may hold several files, comma-separated, and
/// a file whose bytes start as a PDF comes in as one (the two-sided and batch UI tests).
public struct IOSLaunchOptions: Equatable, Sendable {
    /// The launch argument for the demo scanner alone.
    public static let demoScannerArgument = "-demoScanner"
    /// The launch argument that imports the photo in `importFixtureVariable` at launch.
    public static let importFixtureArgument = "-importFixture"
    /// The environment variable holding that photo's bytes, base64.
    public static let importFixtureVariable = "COMPLETESCANNER_IMPORT_FIXTURE"
    /// The name the photo imported at launch is shown with.
    public static let importFixtureName = "fixture.png"
    /// The name a PDF imported at launch is shown with.
    public static let importFixturePDFName = "fixture.pdf"
    /// The launch argument naming the task the photo imported at launch goes into (the next argument).
    public static let importTaskArgument = "-importTask"

    /// Only the demo scanner is offered.
    public let demoScannerOnly: Bool
    /// The files to import at launch, in order; none when the app was not launched to import.
    public let launchImports: [IOSImportItem]
    /// The task the photo imported at launch goes into; nil: the task set up when it takes photos, else
    /// Document to PDF.
    public let launchTask: ScanTask?

    public init(demoScannerOnly: Bool) {
        self.demoScannerOnly = demoScannerOnly
        self.launchImports = []
        self.launchTask = nil
    }

    /// The first file to import at launch; nil for none.
    public var launchImport: IOSImportItem? { launchImports.first }

    /// The options in the process's launch arguments.
    public init(arguments: [String]) {
        self.init(arguments: arguments, environment: [:])
    }

    /// The options in the process's launch arguments and environment (`ProcessInfo`).
    public init(arguments: [String], environment: [String: String]) {
        self.demoScannerOnly = arguments.contains(IOSLaunchOptions.demoScannerArgument)
        var items: [IOSImportItem] = []
        if arguments.contains(IOSLaunchOptions.importFixtureArgument),
           let text = environment[IOSLaunchOptions.importFixtureVariable] {
            for part in text.split(separator: ",") {
                guard let data = Data(base64Encoded: String(part), options: [.ignoreUnknownCharacters]),
                      !data.isEmpty else { continue }
                let kind: IOSImportItem.Kind = IOSImportItem.kind(forFileName: IOSLaunchOptions.importFixtureName, data: data)
                let name: String = kind == .pdf ? IOSLaunchOptions.importFixturePDFName : IOSLaunchOptions.importFixtureName
                items.append(IOSImportItem(name: name, data: data, kind: kind))
            }
        }
        self.launchImports = items
        var task: ScanTask?
        if !items.isEmpty, let index = arguments.firstIndex(of: IOSLaunchOptions.importTaskArgument),
           index + 1 < arguments.count {
            task = ScanTask(rawValue: arguments[index + 1])
        }
        self.launchTask = task
    }
}

/// What the iPhone's and iPad's app shell passes `AppState`: its scanner connections, its file actions,
/// its troubleshooter service, its lifecycle and AirPrint printing (`IOSPrintService`, I16).
public enum IOSShell {
    /// The app's Documents folder in this install; the save folder kept from an earlier one is moved into
    /// it (`ScanSettings.rebasedDestinationPath`).
    public static var documentsFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// The demo scanner alone, whatever `options` say: the connections without the network, for tests and
    /// previews. The app's are `backends(options:networkScanners:)`.
    @MainActor
    public static func backends(options: IOSLaunchOptions) -> [any ScannerBackend] {
        backends(options: options, network: nil)
    }

    /// The app's scanner connections: the network scanners (eSCL: found on the network, added by address),
    /// or the demo scanner alone where `options` ask for it (`-demoScanner`, the UI tests: then nothing is
    /// searched for) or no network scanners are passed in.
    @MainActor
    public static func backends(options: IOSLaunchOptions, networkScanners: IOSNetworkScanners?) -> [any ScannerBackend] {
        backends(options: options, network: networkScanners?.backend)
    }

    /// The network scanner connection (eSCL), or the demo scanner alone when `options` ask for it or there
    /// is no network connection. A real phone never lists the demo scanner, which the app would otherwise
    /// select as soon as it starts.
    @MainActor
    static func backends(options: IOSLaunchOptions, network: EsclScannerBackend?) -> [any ScannerBackend] {
        if let network, !options.demoScannerOnly {
            return [network]
        }
        return [AppState.makeDemoBackend()]
    }

    /// A network scanner connection to `endpoints`, its certificates pinned in `trust`, each job covered
    /// by UIKit's background time (`UIKitBackgroundActivity`).
    @MainActor
    static func networkBackend(endpoints: [EsclEndpoint], trust: EsclTrustStore,
                               clientOptions: EsclClientOptions = EsclClientOptions()) -> EsclScannerBackend {
        EsclScannerBackend(trust: trust, endpoints: endpoints, clientOptions: clientOptions,
                           background: UIKitBackgroundActivity())
    }

    /// The screen stays on while `isBusy` with a network scanner (`device`): iOS would suspend the app soon
    /// after the screen locked, cutting a feeder batch short. Other work (the demo scanner, saving) lets it
    /// sleep as usual.
    public static func keepsScreenAwake(isBusy: Bool, device: ScannerInfo?) -> Bool {
        isBusy && usesNetworkScanner(device)
    }

    /// Whether `device` is a network scanner (eSCL), not the demo scanner; nil, with no scanner selected,
    /// is not.
    public static func usesNetworkScanner(_ device: ScannerInfo?) -> Bool {
        device?.backend == "escl"
    }

    /// The camera's line the scan screen's step card shows in place of the task's step, which speaks of the
    /// glass and the feeder (`CameraTaskCatalog.current`): for every task but the ID card, whose steps say
    /// which side is next, while the pages come from the camera, Photos or Files. With a scanner as the
    /// source (`device`, `sourceScanner`), or a stack turned over by hand, only while a back is due in the
    /// camera's two-sided steps or the next page starts a new document. Nil when the step's own words stay.
    public static func cameraLine(_ task: ScanTask?, options: TaskOptions, sides: CameraSides?, newDocument: Bool,
                                  turningOverByHand: Bool, device: ScannerInfo?) -> CameraStepText? {
        guard task != .idCard else { return nil }
        let pending: Bool = sides?.next == .back || newDocument
        guard pending || !(turningOverByHand || device != nil) else { return nil }
        return CameraTaskCatalog.current(task, options: options, sides: sides, newDocument: newDocument)
    }

    /// Whether the scan screen shows the step card: while the step's own words stay (the ID card's sides, a
    /// scanner as the source, a stack turned over by hand: `cameraLine` is nil), a back is due or the next
    /// page starts a new document. Otherwise the camera's line is on our camera's screen only.
    public static func showsStepCard(_ task: ScanTask?, options: TaskOptions, sides: CameraSides?, newDocument: Bool,
                                     turningOverByHand: Bool, device: ScannerInfo?) -> Bool {
        if sides?.next == .back || newDocument { return true }
        return cameraLine(task, options: options, sides: sides, newDocument: newDocument,
                          turningOverByHand: turningOverByHand, device: device) == nil
    }

    /// The task the iPhone opens on: the one set up last time (kept in the settings), else Document to PDF.
    /// A photocopy or Email kept from before opens as Document: they are Save's Print… and Email… now.
    public static func launchTask(_ settings: ScanSettings) -> ScanTask {
        if let task = savingActionsAsDocument(settings).task, offers(task) {
            return task
        }
        return .document
    }

    /// The settings with a photocopy or Email task (a preset's, or one kept from before) as Document, the
    /// rest kept: on the iPhone they are Save's Print… and Email…, and the chip could not show them. Nothing
    /// runs after saving, as Document starts: Email's share sheet would open on every Save with nothing on
    /// the scan screen saying why. Its Compact size stays, which Options shows.
    public static func savingActionsAsDocument(_ settings: ScanSettings) -> ScanSettings {
        guard settings.task == .copy || settings.task == .email else { return settings }
        var s: ScanSettings = settings
        s.taskId = ScanTask.document.rawValue
        s.output.afterSave = AfterSaveAction.none
        return s
    }

    /// The user's defaults key: the card saying why the camera is asked for was shown (`cameraOnOpen`).
    public static let cameraIntroKey = "camera.introShown"

    /// What the iPhone does with our camera when the scan screen opens at launch: opens it for a task that
    /// takes photos where it can be used, first with the card saying why while iOS has not asked for the
    /// camera yet and the card was never shown; stays on the scan screen without a camera (the Simulator),
    /// with access off or not allowed, and under `-demoScanner` (the UI tests).
    public static func cameraOnOpen(offersCamera: Bool, camera: IOSCameraAvailability, authorization: AVAuthorizationStatus,
                                    introShown: Bool, demo: Bool) -> IOSCameraOnOpen {
        guard !demo, offersCamera, camera.isAvailable else { return .stay }
        if authorization == .notDetermined && !introShown {
            return .introduce
        }
        return .open
    }

    /// Whether the book's Right to left switch is shown: while its spreads are cut at the spine for the
    /// source in use, a network scanner's scans (`PageProcessor.forScan`; `device` is the selected scanner,
    /// none while the camera is the source) or the camera's whole spreads (`PageProcessor.splitsCameraSpreads`).
    public static func showsRightToLeft(_ settings: ScanSettings, device: ScannerInfo?) -> Bool {
        PageProcessor.splitsFacingPages(settings) && (settings.taskOptions.cameraSpreads || usesNetworkScanner(device))
    }

    /// Whether this app offers a task: the tasks whose pages are collected and saved, since I13 Photos,
    /// Restore old photos and Receipts (several objects in one shot, then the photo review) and the ID card
    /// (front then back, then its review), since I14 Quick scan (one shot, then a picture or its text) and
    /// Archive document (with the Archive & password choices), and since I16 the photocopy (the page held on
    /// the copy screen, then printed over AirPrint). Every task is offered now.
    public static func offers(_ task: ScanTask) -> Bool {
        takesPhotos(flow: TaskCatalog.definition(task).flow)
    }

    /// Whether the scan screen takes photos for the settings' task (our camera, Photos and Files): pages
    /// collected in the queue, the objects of a shot for the photo review (photos, receipts), a side of the
    /// ID card, or the page of a photocopy.
    public static func takesPhotos(_ settings: ScanSettings) -> Bool {
        takesPhotos(flow: TaskCatalog.flow(of: settings))
    }

    private static func takesPhotos(flow: TaskFlowKind) -> Bool {
        switch flow {
        case .documentQueue, .photoSplit, .receiptSplit, .idCard, .copy:
            return true
        }
    }

    /// Whether the scan screen collects pages to save (Save and the PDF or JPEG choice): the document
    /// tasks that collect pages. Photos, receipts and the ID card are saved from their reviews, a Quick scan
    /// from its own screen.
    public static func collectsPages(_ settings: ScanSettings) -> Bool {
        TaskCatalog.flow(of: settings) == .documentQueue && settings.documentMultiPage
    }

    /// Whether the scan screen offers the PDF's choices (its size, Archive and Password): its Save writes a
    /// PDF.
    public static func offersPDFOptions(_ settings: ScanSettings) -> Bool {
        collectsPages(settings) && !savesImages(settings) && settings.format.savesPDF(collectsPages: true)
    }

    /// Why a task is not offered yet: the tile's one visible line.
    public static let notYetReason = "Not in this version yet"

    /// Whether a task's scan screen also offers Apple's document scanner (Document, Email, Word), as
    /// "Use Apple's scanner" beside our own camera, the default since I9.
    public static func offersCamera(_ task: ScanTask?) -> Bool {
        guard let task else { return false }
        return IOSDocumentCamera.tasks.contains(task)
    }

    /// Whether the scan screen can offer our own camera (`CameraScreen`), the default way to take pages:
    /// wherever photos are taken (`takesPhotos`), as photos are imported. Its shutter shows only while the
    /// camera is the source (`sourceScanner`).
    public static func offersOwnCamera(_ settings: ScanSettings) -> Bool {
        takesPhotos(settings)
    }

    /// The user's defaults key of the scan screen's source: empty for our camera, the default, else the ID
    /// of the scanner picked in the Scanner options (`sourceScanner`).
    public static let scanSourceKey = "scan.source"

    /// The scanner the pages come from: the one picked as the source (`source`, its ID) while it is listed
    /// and selected; nil while our camera takes them, as it does until that scanner is found again. A
    /// scanner found on its own never becomes the source.
    public static func sourceScanner(_ source: String, selected: String?, devices: [ScannerInfo]) -> ScannerInfo? {
        guard !source.isEmpty, source == selected else { return nil }
        for device in devices where device.id == source {
            return device
        }
        return nil
    }

    /// The listed row of the scanner picked as the source: its own, or the one of the connection the app
    /// moved that scanner to (`groups`, `DeviceMerge`); nil when the scanner is not listed, or none is picked.
    public static func listedSource(_ source: String, devices: [ScannerInfo], groups: [DeviceGroup]) -> String? {
        guard !source.isEmpty else { return nil }
        var connections: [String] = [source]
        for group in groups where group.members.contains(where: { (member: ScannerInfo) -> Bool in member.id == source }) {
            for member in group.members {
                connections.append(member.id)
            }
        }
        for device in devices where connections.contains(device.id) {
            return device.id
        }
        return nil
    }

    /// Whether our camera takes page after page (continuous capture): the task collects several pages in
    /// the queue, or takes the ID card's front then its back, so the camera stays open after each photo
    /// and the corner editor opens only for a page (or card) its photo's own search is unsure of.
    public static func capturesContinuously(_ settings: ScanSettings) -> Bool {
        let flow: TaskFlowKind = TaskCatalog.flow(of: settings)
        if flow == .idCard { return true }
        return flow == .documentQueue && settings.documentMultiPage
    }

    /// The formats Options' Export offers for the collected pages: a PDF, a JPEG a page, a Word document or
    /// a text file. A .txt beside the PDF is one of the PDF's choices (`PDFOptionsSection`).
    public static let exportFormats: [OutputFormat] = [.pdf, .jpeg, .word, .text]

    /// The Export format the settings save as: JPEG for any picture format (PNG and TIFF come from Settings).
    public static func exportFormat(_ settings: ScanSettings) -> OutputFormat {
        settings.format.isImageFormat ? .jpeg : settings.format
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

    /// The `.csdoc` type the app declares (Info.plist's UTExportedTypeDeclarations), which Files offers
    /// beside photos and PDFs.
    public static let packageType: UTType = UTType(exportedAs: "com.completescanner.package", conformingTo: .data)

    /// The Save row's button that shares the queue as one `.csdoc` (`sharePackage`).
    public static let sharePackageLabel = "Share as CompleteScanner document"

    /// Whether a file opened in this app (AirDrop, Files, Mail) or picked in Files is a CompleteScanner
    /// document: it goes to the scan screen's banner (`openPackage`), never into a task's import.
    public static func isPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == CompanionPackage.fileExtension
    }

    /// Offers the `.csdoc` at `url` on the scan screen's banner (`AppState.openPackage(at:)`). It is copied
    /// into a folder of its own first, through its security scope and a coordinated read: the package is
    /// read a picture at a time while its pages are decoded, and a file opened in place may be another
    /// app's (iCloud Drive, a file provider). The copy goes once it is read.
    @MainActor
    public static func openPackage(_ url: URL, in state: AppState) async {
        // One open after another, so the file opened last is the one offered however long its copy
        // takes (a file in iCloud Drive is downloaded first).
        let previous: Task<Void, Never>? = lastPackageOpen
        let open: Task<Void, Never> = Task { @MainActor in
            await previous?.value
            await openPackageNow(url, in: state)
        }
        lastPackageOpen = open
        await open.value
    }

    @MainActor private static var lastPackageOpen: Task<Void, Never>?

    @MainActor private static func openPackageNow(_ url: URL, in state: AppState) async {
        let copied: Result<URL, Error> = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result { try IOSShell.copyPackage(url) }
        }.value
        switch copied {
        case .success(let copy):
            await state.openPackage(at: copy)
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
        case .failure(let error):
            state.errorMessage = PhotoImport.unreadableMessage(url.lastPathComponent, detail: error.localizedDescription)
        }
    }

    /// A copy of the file at `url`, under its own name, in a new folder in the temporary folder.
    static func copyPackage(_ url: URL) throws -> URL {
        let folder: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy: URL = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try IOSPDFAppend.access(url, writing: false) { (file: URL) throws -> Void in
                try FileManager.default.copyItem(at: file, to: copy)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return copy
    }

    /// The folder the queue is written in to be shared, emptied before each `.csdoc` is written.
    static var packageShareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Shared documents", isDirectory: true)
    }

    /// Share as CompleteScanner document: the queue written as one `.csdoc` in `packageShareFolder`
    /// (`AppState.exportPackage(to:)`, named as the next saved file would be), then the share sheet with
    /// it. Returns the file; nil when it could not be written, which the error alert says.
    @MainActor
    @discardableResult
    public static func sharePackage(_ state: AppState) async -> URL? {
        let folder: URL = packageShareFolder
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url: URL = try await state.exportPackage(to: folder)
            state.runFileAction(.share, urls: [url])
            return url
        } catch {
            state.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Whether the scan screen offers Send to computer: it collects pages (`collectsPages`) and a computer
    /// is paired that still knows this phone.
    public static func offersSendToComputer(_ settings: ScanSettings, status: CompanionStatus) -> Bool {
        guard collectsPages(settings) else { return false }
        switch status {
        case .notPaired, .unpaired:
            return false
        case .checking, .reachable, .unreachable:
            return true
        }
    }

    /// The companion (I20): its files in `folder` (the network folder, out of backups), the device secret
    /// in `secrets` (the Keychain), whether a desktop that does not answer is on the network and where it
    /// is now from `browser`'s DNS-SD browse. While the app is in front with a desktop paired, what the
    /// desktop holds for the phone is taken (`pullFromDesktop`, from becoming active until the app goes to
    /// the background); each time it comes to the front the desktop is checked, browsing while the check
    /// runs and, when it did not answer, a few seconds more before it is checked again, and what waits in
    /// the outbox is sent. A desktop that did not answer and is found at new addresses is checked there.
    @MainActor
    static func setUpCompanion(_ state: AppState, folder: URL, secrets: any CompanionSecretStore,
                               browser: IOSCompanionBrowser?, lifecycle: any PlatformLifecycle) {
        state.setUpCompanion(in: folder, secrets: secrets)
        if let browser {
            state.companionDesktopSeenOnNetwork = { [weak browser] (desktopId: String) -> Bool in
                browser?.isSeen(desktopId) ?? false
            }
            browser.onFound = { [weak state] (desktopId: String, addresses: [String], port: Int) -> Void in
                guard let state else { return }
                Task { @MainActor in
                    if await state.desktopFound(id: desktopId, addresses: addresses, port: port),
                       case .unreachable = state.companionStatus {
                        await state.checkDesktop()
                        await state.drainOutbox()
                    }
                }
            }
        }
        lifecycle.observeDidBecomeActive { [weak state] in
            guard let state, state.companionDesktop != nil else { return }
            state.pullFromDesktop()
            Task { @MainActor in
                browser?.begin()
                await state.checkDesktop()
                if browser != nil, case .unreachable = state.companionStatus {
                    // A refusal comes sooner than the browse: let it see the desktop, or find it elsewhere.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if case .unreachable = state.companionStatus {
                        await state.checkDesktop()
                    }
                }
                browser?.end()
                await state.drainOutbox()
            }
        }
        lifecycle.observeWillTerminate { [weak state] in
            state?.stopPulling()
        }
    }

    /// The kind a task is shown as on the iPhone (the scan screen's chips, the camera's task chip): the
    /// document tasks are a Document with its options set (the feeder, both sides, separate documents, the
    /// format, PDF/A, Email…, Print…), Restore old photos is Photos with faded colours restored, Quick scan
    /// is Text.
    public static func kind(of task: ScanTask) -> IOSScanKind {
        switch task {
        case .document, .feeder, .twoSided, .batch, .email, .word, .archive, .copy:
            return .document
        case .photos, .photoRestore:
            return .photos
        case .receipt:
            return .receipts
        case .idCard:
            return .idCard
        case .book:
            return .book
        case .quickScan:
            return .text
        }
    }

    /// The kind the settings are shown as, settings left without a task included (`TaskCatalog.infer`).
    public static func shownKind(_ settings: ScanSettings) -> IOSScanKind {
        kind(of: TaskCatalog.infer(settings))
    }

    /// The task sheet's tiles and the iPad sidebar's rows: one per kind, in order, each as its task's card
    /// can be picked.
    public static func kindTiles(_ cards: [TaskCard], current: IOSScanKind) -> [IOSKindTile] {
        var tiles: [IOSKindTile] = []
        for kind in IOSScanKind.allCases {
            guard let card = cards.first(where: { (candidate: TaskCard) -> Bool in
                candidate.definition.task == kind.task
            }) else { continue }
            tiles.append(IOSKindTile(kind: kind, summary: card.summary, availability: availability(card),
                                     isCurrent: kind == current))
        }
        return tiles
    }

    // The Options switches below set only what they are about, never through `TaskCatalog.apply`, which
    // would reset the other choices; the task changes under the hood where its flow needs it.

    /// Both sides on the camera: the two-sided task, whose camera steps (flip & capture, or fronts first)
    /// need it, with the feeder and both sides it fits; off, Document again on the flatbed, as its tile was.
    public static func settingBothSides(_ on: Bool, in settings: ScanSettings) -> ScanSettings {
        var s: ScanSettings = settings
        if on {
            // One task at a time: separator sheets belong to Separate documents.
            if separatesDocuments(s) { s = settingSeparate(false, in: s) }
            s.source = .documentFeeder
            s.duplex = .both
        } else {
            s.source = .flatbed
            s.duplex = .off
        }
        s.document.removeBlankPages = on
        s.document.autoStraighten = on
        s.document.autoRotate = on
        s.taskId = (on ? ScanTask.twoSided : ScanTask.document).rawValue
        return s
    }

    /// Separate documents is on: the pages are split at patch code or QR sheets.
    public static func separatesDocuments(_ settings: ScanSettings) -> Bool {
        settings.document.splitMode == .separatorSheet || settings.document.splitMode == .barcode
    }

    /// Separate documents: the Separate documents task (its New document button and separator sheets),
    /// split at patch code sheets unless QR codes were chosen, on the feeder it needs, each file named with
    /// its document's name as the task names them; off, one document on the flatbed.
    public static func settingSeparate(_ on: Bool, in settings: ScanSettings) -> ScanSettings {
        var s: ScanSettings = settings
        if on {
            // One task at a time: Both sides ends, its sides and straightening with it.
            if s.task == .twoSided { s = settingBothSides(false, in: s) }
            if s.document.splitMode != .barcode { s.document.splitMode = .separatorSheet }
            s.source = .documentFeeder
            s.namingTemplate = separateNames
        } else {
            s.document.splitMode = SplitMode.none
            s.source = .flatbed
            if s.namingTemplate == separateNames { s.namingTemplate = "Scan {date} {counter}" }
        }
        s.document.removeBlankPages = on
        s.taskId = (on ? ScanTask.batch : ScanTask.document).rawValue
        return s
    }

    /// The Separate documents task's file names (`TaskCatalog.apply`), with each document's name.
    static let separateNames = "Document {label} {date} {counter}"

    /// One PDF per page: a new document every sheet (`SplitMode.sheetCount`, one sheet each).
    public static func savesEachPage(_ settings: ScanSettings) -> Bool {
        settings.document.splitMode == .sheetCount
            && DocumentSplitter.clampSheetCount(settings.document.splitSheetCount) == 1
    }

    public static func settingEachPage(_ on: Bool, in settings: ScanSettings) -> ScanSettings {
        var s: ScanSettings = settings
        s.document.splitMode = on ? .sheetCount : SplitMode.none
        if on { s.document.splitSheetCount = 1 }
        return s
    }

    /// Restore faded colours for Photos: the Restore old photos task's adjustments and PNG files; off,
    /// Photos as JPEGs again.
    public static func settingRestore(_ on: Bool, in settings: ScanSettings) -> ScanSettings {
        var s: ScanSettings = settings
        s.adjustments.restoreFadedColors = on
        s.adjustments.autoEnhance = on
        s.format = on ? .png : .jpeg
        s.taskId = (on ? ScanTask.photoRestore : ScanTask.photos).rawValue
        return s
    }

    /// An option that leaves the task unfit (Word saved as a PDF, PDF/A turned off) keeps its kind: the
    /// kind's own task when the settings fit it, else none, as a change by hand does.
    public static func keepingKind(_ settings: ScanSettings) -> ScanSettings {
        guard let task = settings.task, !TaskCatalog.fits(task, settings) else { return settings }
        var s: ScanSettings = settings
        let base: ScanTask = kind(of: task).task
        s.taskId = TaskCatalog.fits(base, s) ? base.rawValue : nil
        return s
    }

    /// Whether a start-screen tile can be picked, and if not, why: a task this app does not offer
    /// yet says so; otherwise the card's own availability (a scanner without a feeder, say).
    public static func availability(_ card: TaskCard) -> TaskAvailability {
        if !offers(card.definition.task) {
            return TaskAvailability(isAvailable: false, reason: notYetReason)
        }
        return card.availability
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

/// What the iPhone's scan screen asks first, as chips in its top row: what is being scanned. The rest (the
/// feeder, both sides, separate documents, the format, PDF/A, email and printing) is an option of the scan
/// screen or an action of Save.
public enum IOSScanKind: String, CaseIterable, Identifiable, Sendable {
    case document
    case photos
    case receipts
    case idCard
    case book
    case text

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .document: return "Document"
        case .photos: return "Photos"
        case .receipts: return "Receipts"
        case .idCard: return "ID card"
        case .book: return "Book"
        case .text: return "Text"
        }
    }

    public var subtitle: String {
        switch self {
        case .document: return "Pages into a PDF"
        case .photos: return "Prints and pictures"
        case .receipts: return "Named by their date"
        case .idCard: return "Front and back on one page"
        case .book: return "Pages or whole spreads"
        case .text: return "One shot, copy the text"
        }
    }

    public var symbol: String {
        switch self {
        case .document: return "doc.text"
        case .photos: return "photo.on.rectangle.angled"
        case .receipts: return "receipt"
        case .idCard: return "person.text.rectangle"
        case .book: return "book"
        case .text: return "text.viewfinder"
        }
    }

    /// The task picking the kind starts, as its tile did.
    public var task: ScanTask {
        switch self {
        case .document: return .document
        case .photos: return .photos
        case .receipts: return .receipt
        case .idCard: return .idCard
        case .book: return .book
        case .text: return .quickScan
        }
    }
}

/// A tile of the iPhone's task sheet: the kind, what its task sets, whether it can be picked, and whether
/// it is the kind set up now.
public struct IOSKindTile: Identifiable, Equatable {
    public let kind: IOSScanKind
    public let summary: String
    public let availability: TaskAvailability
    public let isCurrent: Bool

    public var id: IOSScanKind { kind }

    /// What VoiceOver reads after the title: "Current" for the kind set up now.
    public var accessibilityValue: String { isCurrent ? "Current" : "" }
}

/// What the scan screen does with our camera when it opens (`IOSShell.cameraOnOpen`).
public enum IOSCameraOnOpen: Equatable, Sendable {
    case open
    /// The card saying why the camera is asked for, then the camera.
    case introduce
    case stay
}

extension AppState {
    /// The iPhone's and iPad's state without network scanners (the demo scanner alone).
    @MainActor
    public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions) -> AppState {
        makeForIOS(options: options, fileActions: fileActions, networkScanners: nil, passwordPrompt: nil)
    }

    /// The iPhone's and iPad's state: the scanner connections of `IOSShell.backends(options:networkScanners:)`,
    /// the iOS file actions (share sheet, Quick Look, the Files app), the iOS troubleshooter service (the
    /// app's page in Settings, the pasteboard, the network path) and UIKit's lifecycle; the iPhone's
    /// troubleshooter checks and connection ranking (`platform` `.ios`); the password of a protected PDF
    /// asked for by `passwordPrompt` (none: such a save saves nothing); AirPrint printing through
    /// `IOSPrintService` (I16), used for the photocopy, the ID card page and the ruler test page; a PDF
    /// pages are added to read and replaced through its security scope and a coordinated access
    /// (`IOSPDFAppend.access`), with the question before adding pages to a signed or PDF/A file asked by
    /// `confirmAppend` (none: such a file gets no pages); the companion (`IOSShell.setUpCompanion`) in the
    /// network folder with its secrets in the Keychain, the computers on the network browsed by
    /// `companion` (none: not browsed), and its cloud folder opened through `IOSSyncFolder`.
    @MainActor
    public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions,
                                  networkScanners: IOSNetworkScanners?,
                                  passwordPrompt: IOSPasswordPrompt? = nil,
                                  printService: IOSPrintService? = nil,
                                  confirmAppend: (@MainActor (String) async -> Bool)? = nil,
                                  companion: IOSCompanionBrowser? = nil) -> AppState {
        let backends: [any ScannerBackend] = IOSShell.backends(options: options, networkScanners: networkScanners)
        let lifecycle: UIKitLifecycle = UIKitLifecycle()
        let state: AppState = AppState(backends: backends, fileActions: fileActions,
                                       troubleshooterService: IOSTroubleshooterService(),
                                       printService: printService ?? IOSPrintService(), lifecycle: lifecycle)
        state.platform = .ios
        if let prompt = passwordPrompt {
            state.askPDFPassword = { () async -> PDFProtection? in
                await prompt.ask()
            }
        }
        state.confirmAppend = confirmAppend
        state.accessPDFForAppend = { (url: URL, writing: Bool, body: (URL) throws -> Void) throws -> Void in
            try IOSPDFAppend.access(url, writing: writing, body)
        }
        state.documentsFolder = IOSShell.documentsFolder
        state.resolveDestinationBookmark = { (bookmark: Data) -> (folder: URL, bookmark: Data)? in
            IOSSaveFolder.resolve(bookmark)
        }
        state.openBookmarkedFolder()
        state.resolveSyncFolderBookmark = { (bookmark: Data) -> (folder: URL, bookmark: Data)? in
            IOSSyncFolder.resolve(bookmark)
        }
        IOSShell.setUpCompanion(state, folder: IOSNetworkScanners.filesFolder(), secrets: IOSCompanionSecrets(),
                                browser: companion, lifecycle: lifecycle)
        return state
    }
}
#endif
