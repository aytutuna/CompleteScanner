import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO

/// Where document pages are spilled to disk while they wait in the queue,
/// so a long high-dpi batch doesn't hold gigabytes of pixels in memory (and the spreads book pages
/// were cut from, AppState+Book.swift).
let pageSpoolDirectory: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("CompleteScanner-pages", isDirectory: true)

/// Cooperative cancellation for the busy phases hardware cancel can't reach:
/// processing, photo detection, OCR, PDF assembly, and file exports all poll this
/// between work units. (Detached tasks don't inherit Swift task cancellation, so an
/// explicit flag is threaded through instead.)
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// The recognized text of a PDF's pages, collected while the PDF is written for the text file
/// beside it (`OutputOptions.alsoSaveText`), so OCR reads each page once. Filled by the one task
/// that writes the PDF and read once that task has finished. Twin of the Windows `PdfText`.
final class PDFTextCollector: @unchecked Sendable {
    var pages: [OCRPage] = []
    /// The OCR error of the first page whose text could not be read; no text file is written then.
    var problem: String?
}

/// Central controller: owns backends, the open scanner session, settings, scan results,
/// and every user-triggered operation. All UI binds to this object.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Published state

    /// One entry per physical scanner (see `DeviceMerge`): the connection in use for the
    /// selected scanner, the preferred connection for the others.
    @Published public private(set) var devices: [ScannerInfo] = []
    /// Every backend entry grouped by physical scanner, in sidebar order.
    public private(set) var deviceGroups: [DeviceGroup] = []
    @Published public private(set) var selectedDeviceID: String?
    @Published public private(set) var capabilities: ScannerCapabilities?
    @Published public var settings: ScanSettings {
        didSet {
            // A feeder known to scan one side turns two-sided scanning into turning over by hand
            // (one not asked yet is taken to scan both: `sidesCapabilities`).
            if settings.duplex == .both,
               DocumentSides.effective(settings, capabilities: sidesCapabilities) == .manual {
                settings.duplex = .manual
            }
            // A task the settings no longer fit (the mode changed by hand, or a scanner without
            // the task's source) ends; its steps follow the task (AppState+Tasks.swift).
            if let task = settings.task, !TaskCatalog.fits(task, settings) { settings.taskId = nil }
            syncTaskFlow()
            // A named document whose first page the settings now leave out keeps its name.
            if settings.document != oldValue.document { carryDocumentLabels(settingsBefore: oldValue.document) }
            scheduleSettingsSave()
            // ImageCaptureCore tells whether the feeder scans both sides only once it is used.
            if settings.source == .documentFeeder && oldValue.source != .documentFeeder { checkFeederDuplexSoon() }
            // The Copies section shows the paper the printer is asked for.
            if isCopyFlow && Self.requestedPaper(settings) != Self.requestedPaper(oldValue) { refreshCopySetup() }
        }
    }

    /// Low-res preview of the full bed; the selection marquee is only valid over this image.
    @Published public internal(set) var overviewImage: CGImage? {
        didSet { canvasRevision &+= 1 }
    }
    /// The most recent full scan (shown in the canvas when there is no overview).
    @Published public internal(set) var lastScanImage: CGImage? {
        didSet { canvasRevision &+= 1 }
    }
    /// Bumped whenever either canvas image changes, so views can key decode work on it
    /// (object identity of a CGImage is unreliable — addresses get reused).
    @Published public private(set) var canvasRevision = 0
    /// True pixel dimensions of the last scan. `lastScanImage` holds only a downsampled
    /// preview (full-resolution raws would pin hundreds of MB at high dpi); detected-photo
    /// outlines use this to map full-resolution region coordinates onto the preview.
    @Published public internal(set) var lastScanPixelSize: CGSize?
    /// Normalized (0...1) crop rect within the flatbed, origin top-left. nil = full bed.
    @Published public var selectionRect: CGRect?

    /// The page queue. Spreads no page is cut from any more are dropped whenever it changes
    /// (`pruneSpreads`, AppState+Book.swift).
    @Published public internal(set) var scannedPages: [ScannedPage] = [] {
        didSet { pruneSpreads() }
    }
    /// The spreads the book pages in the queue were cut from, by spread id (AppState+Book.swift).
    var spreadSources: [UUID: SpreadSource] = [:]
    @Published public var detectedPhotos: [DetectedPhoto] = []
    @Published public var showPhotoReview = false
    /// The review holds receipts rather than photos: it is titled and saved as receipts (AppState+Receipts.swift).
    @Published public internal(set) var isReceiptReview = false
    /// This session's scans, newest first (small previews only) — the "Scans" tab.
    @Published public private(set) var scanHistory: [ScanHistoryEntry] = []
    /// Full-resolution sources of the current photo batch, keyed by scanned-page id and
    /// retained only while the photo review is open, so manual crop corrections can
    /// re-extract each photo from the correct sheet at full quality.
    var photoSourceImages: [UUID: CGImage] = [:]

    /// The full-resolution page a detected photo, or a side of the ID card, was extracted from
    /// (nil once the review is closed).
    public func photoSource(for photo: DetectedPhoto) -> CGImage? {
        photo.sourcePageID.flatMap { photoSourceImages[$0] ?? idCardSourceImages[$0] }
    }

    /// The front of the ID card, cut out of its scan; nil until it is scanned (AppState+IdCard.swift).
    @Published public internal(set) var idCardFront: DetectedPhoto?
    /// The back of the ID card; nil until it is scanned, and when it was skipped.
    @Published public internal(set) var idCardBack: DetectedPhoto?
    /// What to check about the front's crop (`IdCardPick.note`); nil when the card was found.
    @Published public internal(set) var idCardFrontNote: String?
    /// What to check about the back's crop; nil when the card was found.
    @Published public internal(set) var idCardBackNote: String?
    /// The sides are in (or the back was skipped): the review to check and save them is open.
    @Published public var showIdCardReview = false
    /// A small picture of the page the sides are saved on; nil while there is no front.
    @Published public internal(set) var idCardPreview: CGImage?
    /// What the page holds: "Front and back on one A4 page, at real size."
    @Published public internal(set) var idCardLayoutCaption = ""
    /// Set when the sides had to be made smaller to fit the page (`IdCardLayout.notRealSizeMessage`).
    @Published public internal(set) var idCardSizeWarning: String?
    /// The scans the ID card's sides were cut from, by scanned-page id, so a crop can be fixed. In
    /// memory only (ID card scans are never spooled), and dropped with the sides.
    var idCardSourceImages: [UUID: CGImage] = [:]
    /// What each of those scans covers (resolution, size, selection), so a back that does not stand
    /// out takes the front's place only on a scan of the same part of the glass.
    var idCardScanAreas: [UUID: IdCardScanArea] = [:]
    /// Something asked for that would end the ID card task while a side is held and not saved
    /// (leaving it, picking a task or a preset): it waits until the user discards the card
    /// (`ContentView` asks; AppState+IdCard.swift).
    @Published public var pendingIdCardLeave: IdCardLeave?
    /// Bumped for every new picture of the ID card's page; a late one is dropped.
    var idCardPreviewRevision = 0

    /// The installed printers' names, as last read (`refreshPrinters()`, AppState+Copy.swift).
    @Published public internal(set) var printerNames: [String] = []
    /// The paper in the default printer, when it is a named size; Automatic paper for the ID card follows it.
    @Published public internal(set) var defaultPrinterPaper: PaperSize?
    /// What the printer chosen for copies offers (paper, margins), for the inspector.
    @Published public internal(set) var copySetup: PrinterSetup?
    /// Reads the printers again each time the app comes to the front; set once, by `start()`.
    private var activationObserver: NSObjectProtocol?

    @Published public private(set) var isBusy = false
    @Published public private(set) var progress: ScanProgress?
    @Published public internal(set) var statusMessage = "Looking for scanners…"
    @Published public var errorMessage: String?
    @Published public internal(set) var lastSavedURLs: [URL] = []
    /// Size of the PDF saved last in this session, in bytes; nil before the first one. Shown
    /// under the PDF size choice.
    @Published public private(set) var lastPDFByteCount: Int64?

    @Published public private(set) var presets: [Preset] = []

    /// "Why isn't my scanner listed?" is open (`TroubleshooterView`, shown from the sidebar and
    /// from an error about a scanner).
    @Published public var showTroubleshooter = false
    /// The last failed connection or scan, for the troubleshooter; cleared by the next one that works.
    @Published public private(set) var lastFailure: ScannerFailure?
    /// `errorMessage` is about a scanner that would not connect or scan, so its alert offers the
    /// troubleshooter. Cleared when the alert closes.
    @Published public var errorSuggestsTroubleshooter = false

    /// No settings were saved before this start: the app opens on the start screen.
    public let isFirstRun: Bool
    /// Where the user is in the guided steps: the active task's, or turning a stack over by hand
    /// (`DocumentSides.manualSteps`); nil when nothing is guided (see AppState+Tasks.swift).
    @Published public internal(set) var taskFlow: TaskFlow?
    /// The task `taskFlow` was made for (nil for turning over by hand).
    var flowTask: ScanTask?
    /// `taskFlow` guides turning a stack over by hand.
    var flowIsManual = false
    /// Turning over by hand, the fronts and backs did not pair up, e.g. "3 fronts but 2 backs";
    /// nil otherwise. The user scans the backs again, combines the pages as they are, or keeps
    /// the fronts only.
    @Published public internal(set) var sidesMismatch: String?
    /// Whether the connected scanner's feeder scans both sides is known: ImageCaptureCore reports it
    /// only once the feeder has been selected (`ScannerSession.feederSupportsDuplex`). Set once the
    /// scanner has answered; one that did not answer is asked again the next time.
    var feederDuplexChecked = false

    /// The capabilities the sides are decided with (the settings, the steps, the inspector): until
    /// a session that tells only once the feeder is selected has answered, its feeder is taken to
    /// scan both sides (`DocumentSides.capabilitiesForSides`).
    var sidesCapabilities: ScannerCapabilities? {
        let known = feederDuplexChecked || !(session?.feederDuplexNeedsSelection ?? false)
        return DocumentSides.capabilitiesForSides(capabilities, duplexKnown: known)
    }

    // MARK: Private

    private let backends: [any ScannerBackend]
    private let presetStore: PresetStore
    /// Opens, shows, shares and copies saved files through macOS (a stand-in in tests).
    private let fileActions: any FileActionService
    /// Opens Image Capture and System Settings and copies for the troubleshooter (a stand-in in tests).
    private let troubleshooterService: any TroubleshooterService
    /// Lists the printers and prints through the print panel (a stand-in in tests; AppState+Copy.swift).
    let printService: any PrintService
    /// Reads pages for "Rotate pages upright" (`OrientationStep`; a stand-in in tests).
    let orientationScorer: any OrientationScorer
    private var session: (any ScannerSession)?
    private var sessionDeviceID: String?
    private var userPickedDevice = false
    /// The backend entry of the selected device, kept so its scanner is found again when
    /// that entry goes away.
    private var selectedEntry: ScannerInfo?
    /// The selected scanner should move to another connection (or it went away) during an
    /// operation or photo review; switch once those end (`endOfWork`).
    private var connectionSwitchDeferred = false
    /// The device diagnostics last written (see `writeDeviceDiagnostics`).
    private var lastDeviceReport = ""
    /// Device switches are serialized through this chain; concurrent clicks
    /// must never interleave open/close on hardware sessions.
    private var switchTask: Task<Void, Never>?
    var switchGeneration = 0
    private var settingsSaveTask: Task<Void, Never>?
    /// The current exclusive operation's cancel flag (nil when idle).
    private var currentCancelFlag: CancelFlag?
    /// The feeder check under way (`checkFeederDuplex`): scans and previews wait for it, since the
    /// session selects one unit at a time.
    private var feederDuplexCheck: Task<Void, Never>?
    /// The last page swap (or the turn clicked behind one) queued; nil when none is under way.
    /// Swaps and turns run in click order, and a save waits for them (`enqueuePageEdit`), and so
    /// does joining or splitting a spread (AppState+Book.swift).
    var pageEditChain: Task<Void, Never>?
    private var pageEditCount = 0

    /// Image shown in the preview canvas.
    public var canvasImage: CGImage? { overviewImage ?? lastScanImage }

    public static let fallbackResolutions = [75, 150, 200, 300, 600, 1200]

    public init(backends: [any ScannerBackend]? = nil, presetStore: PresetStore = PresetStore(),
                fileActions: (any FileActionService)? = nil,
                troubleshooterService: (any TroubleshooterService)? = nil,
                printService: (any PrintService)? = nil,
                orientationScorer: (any OrientationScorer)? = nil) {
        let saved = SettingsStore.load()
        self.isFirstRun = saved == nil
        // A task saved last time is still active: its banner comes back with the settings.
        var initial = saved ?? ScanSettings()
        if let task = initial.task, !TaskCatalog.fits(task, initial) { initial.taskId = nil }
        self.settings = initial
        self.backends = backends ?? [ICScannerBackend(), AppState.makeDemoBackend()]
        self.presetStore = presetStore
        self.fileActions = fileActions ?? SystemFileActions()
        self.troubleshooterService = troubleshooterService ?? SystemTroubleshooterService()
        self.printService = printService ?? SystemPrintService()
        self.orientationScorer = orientationScorer ?? VisionOrientationScorer()
        self.presets = presetStore.load()
        syncTaskFlow()
        // Clear page spill files left behind by a previous run.
        try? FileManager.default.removeItem(at: pageSpoolDirectory)
        try? FileManager.default.createDirectory(at: pageSpoolDirectory, withIntermediateDirectories: true)
        // Flush any debounced settings write on quit so a change made just
        // before Cmd-Q is not lost.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsSaveTask?.cancel()
                SettingsStore.save(self.settings)
            }
        }
    }

    /// The demo scanner. Its second sheet has a blank back, to show blank pages being flagged.
    private static func makeDemoBackend() -> MockScannerBackend {
        let demo = MockScannerBackend()
        demo.feederBlankBackSheets = [1]
        return demo
    }

    // MARK: Devices

    public func start() {
        for backend in backends {
            backend.onDevicesChanged = { [weak self] in self?.mergeDevices() }
            backend.startBrowsing()
        }
        mergeDevices()
        // The Copy card needs a printer; Automatic paper for the ID card is the default printer's.
        refreshPrinters()
        // A printer added or removed while the app was in the background (in System Settings, say)
        // is seen when the app is back in front.
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshPrinters()
                }
            }
        }
    }

    /// Rebuilds the scanner list from every backend: entries for the same physical scanner
    /// (the same MFP over USB and Bonjour) are grouped with `DeviceMerge.group` and ranked
    /// USB, then Bonjour, then shared; the selection follows its scanner. When another
    /// connection to the selected scanner becomes the preferred one (a better one appeared,
    /// or the one in use went away), the session moves to it.
    private func mergeDevices() {
        let entries = backends.flatMap { $0.devices }
        deviceGroups = DeviceMerge.group(entries, rankPatterns: DeviceMerge.macRanking)
        writeDeviceDiagnostics()

        if let sel = selectedDeviceID {
            if let current = entries.first(where: { $0.id == sel }) { selectedEntry = current }
            if let group = groupOfSelection(sel) {
                if group.primary.id != sel {
                    // Same scanner, another connection. Switching would discard a running
                    // operation, an open photo review or an ID card's sides, so wait for those
                    // to end (endOfWork re-runs this merge).
                    if autoSwitchMustWait {
                        connectionSwitchDeferred = true
                    } else {
                        selectDevice(group.primary.id)
                    }
                } else if !userPickedDevice, let real = preferredDefaultDevice(), group.primary.isDemo,
                          deviceGroups.first(where: { $0.primary.id == real })?.primary.isDemo == false {
                    // A real scanner appeared while we were auto-parked on the demo device: the
                    // same deferral applies.
                    if autoSwitchMustWait {
                        connectionSwitchDeferred = true
                    } else {
                        selectDevice(real)
                    }
                }
            } else if autoSwitchMustWait {
                // The scanner went away (unplugged, powered off): the same deferral applies.
                connectionSwitchDeferred = true
            } else {
                userPickedDevice = false
                selectDevice(preferredDefaultDevice())
            }
        } else if let def = preferredDefaultDevice() {
            selectDevice(def)
        }
        refreshDeviceRows()
    }

    /// A switch of scanner made by the app (the scanner went away, another connection or a real
    /// scanner appeared) waits: it would discard a running operation or the open photo review, or
    /// the ID card's sides, whose other side and new scans need this scanner's glass. The switch is
    /// made once these end (`endOfWork`). Twin of the Windows `AppViewModel.AutoSwitchMustWait`.
    var autoSwitchMustWait: Bool { isBusy || showPhotoReview || showIdCardReview || hasIdCardCaptures }

    /// Re-evaluate a deferred connection switch once nothing is in progress.
    func endOfWork() {
        guard connectionSwitchDeferred, !autoSwitchMustWait else { return }
        connectionSwitchDeferred = false
        mergeDevices()
    }

    /// The first real scanner (else the demo device), through its preferred connection.
    private func preferredDefaultDevice() -> String? {
        (deviceGroups.first(where: { !$0.primary.isDemo }) ?? deviceGroups.first)?.primary.id
    }

    /// The scanner the selected device belongs to: the group listing it, or, when that entry
    /// went away, the group holding another connection to the same scanner.
    private func groupOfSelection(_ id: String) -> DeviceGroup? {
        if let group = deviceGroups.first(where: { group in group.members.contains(where: { $0.id == id }) }) {
            return group
        }
        guard let entry = selectedEntry, entry.id == id else { return nil }
        return deviceGroups.first(where: { group in
            group.members.contains(where: { DeviceMerge.sameDevice($0, entry) })
        })
    }

    /// One entry per scanner: the selected scanner shows the connection in use (until a
    /// deferred switch moves it), the others the connection they would use.
    private func refreshDeviceRows() {
        let sel = selectedDeviceID
        let rows = deviceGroups.map { group in
            group.members.first(where: { $0.id == sel }) ?? group.primary
        }
        if rows != devices { devices = rows }
    }

    /// Writes the raw device names, how they were grouped and the troubleshooter's checks to
    /// ~/Library/Logs/CompleteScanner/devices.txt whenever they change, so the names real
    /// devices report can be collected to tune `DeviceMerge` and a user's setup can be read
    /// from one file. Best effort.
    private func writeDeviceDiagnostics() {
        let report = diagnosticsText(troubleshootSnapshot())
        guard report != lastDeviceReport else { return }
        lastDeviceReport = report
        let fileManager = FileManager.default
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let folder = library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("CompleteScanner", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(report.utf8).write(to: folder.appendingPathComponent("devices.txt"), options: .atomic)
    }

    // MARK: Troubleshooter ("Why isn't my scanner listed?")

    /// A scanner other than the demo scanner is listed; without one the sidebar offers the troubleshooter.
    public var hasRealDevices: Bool { deviceGroups.contains { !$0.primary.isDemo } }

    /// What the troubleshooter looks at now: the scanners listed, the last failure, and what each
    /// connection adds (`ScannerBackendDiagnostics`). The Mac reads no service or network state.
    public func troubleshootSnapshot() -> DiscoverySnapshot {
        var snapshot = DiscoverySnapshot(platform: .mac, devices: deviceGroups.map { $0.primary },
                                         lastFailure: lastFailure)
        for backend in backends {
            if let diagnostics = backend as? any ScannerBackendDiagnostics {
                snapshot = diagnostics.addStatus(to: snapshot)
            }
        }
        return snapshot
    }

    /// The troubleshooter's Refresh: every connection that can looks for scanners again; the list
    /// updates as they answer.
    public func refreshScanners() {
        for backend in backends {
            if let diagnostics = backend as? any ScannerBackendDiagnostics { diagnostics.rescan() }
        }
        mergeDevices()
    }

    /// The text of devices.txt and of Copy Diagnostics: how the device list was grouped, then the
    /// troubleshooter's checks for `snapshot`.
    public func diagnosticsText(_ snapshot: DiscoverySnapshot) -> String {
        DeviceMerge.diagnosticsReport(deviceGroups) + "\n"
            + Troubleshooter.report(snapshot, checks: Troubleshooter.diagnose(snapshot))
    }

    /// Copies `diagnosticsText` to the pasteboard. Returns why it did not work, nil when it did.
    /// The troubleshooter sheet shows that itself: `errorMessage` is left alone, since its alert
    /// would only appear behind the sheet, after it closes.
    @discardableResult
    public func copyDiagnostics(_ snapshot: DiscoverySnapshot) -> String? {
        do {
            try troubleshooterService.copy(diagnosticsText(snapshot))
            return nil
        } catch {
            return "Copy diagnostics did not work: \(Self.describe(error))"
        }
    }

    /// Opens Image Capture or the System Settings pane an action names; nothing is changed there.
    /// Returns why it did not open, nil when it did (shown by the sheet, as for `copyDiagnostics`).
    @discardableResult
    public func openTroubleshootLink(_ action: TroubleshootAction) -> String? {
        do {
            try troubleshooterService.open(action)
            return nil
        } catch {
            return "\(Troubleshooter.label(action, platform: .mac)) did not work: \(Self.describe(error))"
        }
    }

    /// Keeps a failed connection or scan for the troubleshooter (errors that say nothing about the
    /// scanner are skipped), and lets the error's alert offer it.
    private func recordFailure(deviceName: String, error: Error) {
        guard let failure = Troubleshooter.failure(deviceName: deviceName, error: error) else { return }
        lastFailure = failure
        errorSuggestsTroubleshooter = true
        writeDeviceDiagnostics()
    }

    private func clearFailure() {
        guard lastFailure != nil else { return }
        lastFailure = nil
        writeDeviceDiagnostics()
    }

    /// Device selection driven by the user (sidebar click).
    public func userSelectDevice(_ id: String?) {
        userPickedDevice = true
        selectDevice(id)
    }

    private func selectDevice(_ id: String?) {
        // Ignore re-clicks on a device that is already connected or connecting.
        guard id != selectedDeviceID || (session == nil && switchTask == nil) else { return }
        selectedDeviceID = id
        if let id {
            selectedEntry = deviceGroups.flatMap { $0.members }.first(where: { $0.id == id }) ?? selectedEntry
        } else {
            selectedEntry = nil
        }
        refreshDeviceRows()
        switchGeneration += 1
        let generation = switchGeneration
        let previous = switchTask
        switchTask = Task { [weak self] in
            await previous?.value
            guard let self, self.switchGeneration == generation else { return }
            await self.switchSession(to: id)
            if self.switchGeneration == generation { self.switchTask = nil }
        }
    }

    private func switchSession(to id: String?) async {
        if let old = session {
            old.progressHandler = nil
            // Abort any in-flight scan so its results can't land after the switch.
            old.cancelScan()
            await old.close()
        }
        session = nil
        sessionDeviceID = nil
        capabilities = nil
        feederDuplexChecked = false
        feederDuplexCheck = nil
        // The preview, marquee and detections belong to the previous device's bed.
        overviewImage = nil
        lastScanImage = nil
        lastScanPixelSize = nil
        selectionRect = nil
        detectedPhotos = []
        showPhotoReview = false
        isReceiptReview = false
        photoSourceImages = [:]

        guard let id else {
            statusMessage = "No scanner selected."
            return
        }
        guard let backend = backends.first(where: { b in b.devices.contains { $0.id == id } }) else {
            statusMessage = "Scanner is no longer available."
            return
        }
        let name = devices.first(where: { $0.id == id })?.name ?? "scanner"
        statusMessage = "Connecting to \(name)…"
        do {
            let s = try await backend.openSession(deviceID: id)
            guard selectedDeviceID == id else { await s.close(); return }
            s.progressHandler = { [weak self] p in
                self?.progress = p
                if !p.message.isEmpty { self?.statusMessage = p.message }
            }
            session = s
            sessionDeviceID = id
            let caps = try await s.capabilities()
            capabilities = caps
            clearFailure()
            // Settings that use the feeder need to know whether it scans both sides first.
            if settings.source == .documentFeeder || !caps.sources.contains(.flatbed) {
                await checkFeederDuplex()
            }
            guard selectedDeviceID == id else { return }
            // A task the scanner cannot do (the feeder task on a flatbed) ends here.
            let adapted = SettingsAdapter.adapt(settings, to: sidesCapabilities)
            settings = adapted.settings
            statusMessage = Self.withNotes("Ready — \(s.info.name)", adapted.notes)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not connect to \(name)."
            recordFailure(deviceName: name, error: error)
        }
    }

    // MARK: Scanning

    public func performOverview() {
        guard let session else { return noDevice() }
        // The preview shows the flatbed; a feeder scan would ignore a selection drawn on it.
        guard settings.source != .documentFeeder else {
            statusMessage = "Preview needs the flatbed. Choose Flatbed as the source to preview."
            return
        }
        let generation = switchGeneration
        runExclusive { flag in
            // The session selects one unit at a time: a feeder check under way goes first.
            await self.feederDuplexCheck?.value
            guard self.switchGeneration == generation else { return }
            self.statusMessage = "Scanning overview…"
            let image = try await session.performOverviewScan(settings: self.settings)
            // Discard results that arrive after the user switched devices.
            guard self.switchGeneration == generation else { return }
            self.clearFailure()
            if flag.isCancelled { throw ScanError.cancelled }
            self.overviewImage = image
            self.statusMessage = "Overview ready — drag on the preview to select an area, then Scan."
        }
    }

    public func performScan() {
        guard let session else { return noDevice() }
        // The ID card task scans the side its steps are at; once the sides are in, Scan opens the
        // review again.
        let idCard = TaskCatalog.flow(of: settings) == .idCard
        let cardSide: PageSide? = idCard ? IdCardSteps.sideOf(taskFlow?.current?.id) : nil
        if idCard && cardSide == nil {
            openIdCardReview()
            return
        }
        let copy = TaskCatalog.flow(of: settings) == .copy
        // A copy of an area selected on the preview is centred on the paper; of a page, it lies in the corner.
        let areaSelected = settings.source == .flatbed && selectionRect != nil
        let generation = switchGeneration
        runExclusive { flag in
            if self.settings.source == .documentFeeder { await self.checkFeederDuplex() }
            guard self.switchGeneration == generation else { return }
            self.statusMessage = "Scanning…"
            // One snapshot for the whole scan. The scanner is asked for a two-sided scan only
            // when its feeder can do one; turning the stack over by hand scans one side at a
            // time, and the steps say which.
            var scanSettings = self.settings
            let sides = DocumentSides.effective(scanSettings, capabilities: self.sidesCapabilities)
            scanSettings.duplex = sides
            let s = scanSettings
            let manualSide: PageSide? = sides == .manual && self.isTurningOverByHand
                ? (self.taskFlow?.current?.id == DocumentSides.backsStepID ? .back : .front)
                : nil
            // A copy needs a printer first, and the printer's paper says what part of the glass to scan.
            var copySetup: PrinterSetup?
            if copy {
                guard let setup = self.setupForPrinting(s, requestedPaper: Self.requestedPaper(s)) else {
                    throw PrintError.noPrinter
                }
                copySetup = setup
            }
            // The flatbed scans the selection, else the paper size's part of the glass; an ID card
            // may lie anywhere on it, so its scans take the whole glass. A copy with Automatic paper
            // scans the part the printer's paper covers.
            var paperArea: CGRect? = idCard ? nil : self.capabilities.flatMap {
                PaperSizes.flatbedSelection(s.paperSize, bed: $0.flatbedSizeInches)
            }
            if let copySetup, let area = self.copyScanArea(s, setup: copySetup) { paperArea = area }
            let selection: CGRect? = s.source == .flatbed ? (self.selectionRect ?? paperArea) : nil
            let scanned = try await session.performScan(settings: s, selection: selection)
            // Discard results that arrive after the user switched devices.
            guard self.switchGeneration == generation else { return }
            guard !scanned.isEmpty else { throw ScanError.scanFailed("The scanner returned no pages.") }
            self.clearFailure()
            if flag.isCancelled { throw ScanError.cancelled }
            // A feeder batch cut short (a jam, a dropped connection) still returns its pages;
            // once they are handled the user is told the stack was not finished.
            let stop = session.lastScanStop
            // A scanner that fell back to one side (its feeder could not scan both, or was never
            // asked) delivered one side of each sheet.
            let twoSided = sides == .both && session.lastScanDuplex != false
            self.statusMessage = "Processing…"
            // The clean-up stage: two-sided pages in reading order with their sides marked and the
            // backs turned upright, then the blank-page check and the adjustments. Pixel-heavy work
            // runs off the main actor so the UI stays live; the cancel flag is polled between
            // pages and steps.
            let arrangement: ScanArrangement = twoSided ? .twoSided
                : manualSide == .back ? .turnedOverBacks
                : manualSide == .front ? .turnedOverFronts
                : .asScanned
            let scorer = self.orientationScorer
            let cleaned: ProcessedScan = try await Task.detached(priority: .userInitiated) {
                try PageProcessor.forScan(s, arrangement: arrangement, scorer: scorer)
                    .process(scanned, shouldContinue: { !flag.isCancelled })
            }.value
            guard self.switchGeneration == generation else { return }
            if flag.isCancelled { throw ScanError.cancelled }
            let raw = cleaned.arranged
            let processed = cleaned.pages

            // The canvas shows the RAW scan: PreviewCanvasView applies the current
            // adjustment settings to it live, so slider changes are visible
            // immediately without rescanning. Only a downsampled preview is retained —
            // a full-resolution raw at high dpi would pin hundreds of MB in memory.
            let rawLast = raw.last?.image
            let rawPreview: CGImage? = await Task.detached(priority: .userInitiated) {
                rawLast.map { Self.makePreview($0, maxSide: 2600) ?? $0 }
            }.value
            guard self.switchGeneration == generation else { return }
            let rawPixelSize = rawLast.map { CGSize(width: $0.width, height: $0.height) }

            // Record every scanned page in the session history (small previews only). ID cards are
            // kept out of it: nothing of them is left once saved or discarded.
            if !idCard {
                let historyThumbs: [(CGImage, CGSize, Int)] = await Task.detached(priority: .utility) {
                    raw.map { page in
                        (Self.makePreview(page.image, maxSide: 700) ?? page.image,
                         CGSize(width: page.image.width, height: page.image.height),
                         page.dpi)
                    }
                }.value
                guard self.switchGeneration == generation else { return }
                let now = Date()
                let entries = historyThumbs.map {
                    ScanHistoryEntry(date: now, intent: s.intent, dpi: $0.2,
                                     thumbnail: $0.0, pixelSize: $0.1)
                }
                self.scanHistory.insert(contentsOf: entries.reversed(), at: 0)
                if self.scanHistory.count > 50 {
                    self.scanHistory.removeSubrange(50...)
                }
            }

            switch TaskCatalog.flow(of: s) {
            case .documentQueue:
                if s.documentMultiPage {
                    // Spill full-resolution pages to disk; keep only previews in the queue. The
                    // spreads book pages were cut from are kept too, to join or split them again.
                    let spreads = cleaned.spreads
                    let spooled = await Task.detached(priority: .userInitiated) {
                        Self.spoolPages(processed)
                    }.value
                    let spreadSources = await Task.detached(priority: .userInitiated) {
                        Self.spoolSpreads(spreads)
                    }.value
                    guard self.switchGeneration == generation else {
                        self.deleteSpoolFiles(of: spooled)
                        Self.deleteSpreadFiles(Array(spreadSources.values))
                        return
                    }
                    // The spreads first: adding the pages drops the spreads no page is cut from.
                    self.spreadSources.merge(spreadSources) { _, new in new }
                    self.scannedPages.append(contentsOf: spooled)
                    self.recordCaptures(spooled.map(\.id))
                    self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                    let n = processed.count
                    if let manualSide {
                        self.afterTurnedOverScan(manualSide, count: n, stopped: stop != nil)
                    } else if twoSided {
                        let sheets = Set(processed.compactMap(\.sheetIndex)).count
                        self.statusMessage = "Added \(n) page\(n == 1 ? "" : "s") from \(sheets) sheet\(sheets == 1 ? "" : "s"), both sides — \(self.scannedPages.count) in queue. Scan more or \(self.settings.format.saveTitle)."
                    } else if sides == .both {
                        self.statusMessage = "Added \(n) page\(n == 1 ? "" : "s"), one side of each sheet: the scanner did not scan both sides — \(self.scannedPages.count) in queue. Scan more or \(self.settings.format.saveTitle)."
                    } else {
                        self.statusMessage = "Added \(n) page\(n == 1 ? "" : "s") — \(self.scannedPages.count) in queue. Scan more or \(self.settings.format.saveTitle)."
                    }
                    // " 2 look blank and will be skipped.", " Found 2 separator pages: 3 documents to save."
                    self.statusMessage += self.queueScanNote(processed, options: s.document)
                    if PageProcessor.turnsPagesUpright(s) && !scorer.isAvailable {
                        self.statusMessage += PageTurns.unavailableNote
                    }
                } else {
                    self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                    try await self.saveImmediately(processed, settings: s, flag: flag)
                    self.recordCaptures(processed.map(\.id))
                }
            case .photoSplit:
                // Full resolution here: the detection overlay maps source-pixel
                // coordinates onto this image (raw and processed share dimensions).
                self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                self.statusMessage = "Detecting photos…"
                let found: [DetectedPhoto] = try await Task.detached(priority: .userInitiated) {
                    var all: [DetectedPhoto] = []
                    for page in processed {
                        if flag.isCancelled { throw ScanError.cancelled }
                        all.append(contentsOf: Self.splitPhotos(from: page, settings: s))
                    }
                    return all
                }.value
                guard self.switchGeneration == generation else { return }
                if flag.isCancelled { throw ScanError.cancelled }
                // Keep every sheet's full-resolution source while the review is open so
                // manual crop corrections can re-extract from the correct page.
                self.photoSourceImages = Dictionary(uniqueKeysWithValues: processed.map { ($0.id, $0.image) })
                self.detectedPhotos = found
                self.isReceiptReview = false
                self.recordCaptures(found.map(\.id))
                self.showPhotoReview = !found.isEmpty
                self.statusMessage = "Found \(found.count) photo\(found.count == 1 ? "" : "s") on the bed."
            case .idCard:
                guard self.isIdCardFlow else {
                    self.dropIdCardScanOutsideTask()
                    break
                }
                self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                guard let side = cardSide, let page = processed.last else { break }
                self.statusMessage = "Finding the card\u{2026}"
                // A back that does not stand out takes the front's place, the card turned over where it
                // lay, when both scans cover the same part of the glass.
                let area = IdCardScanArea(dpi: page.dpi,
                                          pixelSize: CGSize(width: page.image.width, height: page.image.height),
                                          selection: selection)
                var frontPlace: DetectedPhotoRegion?
                if side == .back, let front = self.idCardFront, let frontScan = front.sourcePageID,
                   let frontArea = self.idCardScanAreas[frontScan] {
                    frontPlace = IdCardDetector.frontPlaceOnBack(front.region, front: frontArea, back: area)
                }
                let fallback = frontPlace
                let found: (DetectedPhoto, String?) = try await Task.detached(priority: .userInitiated) { () throws -> (DetectedPhoto, String?) in
                    let pick = IdCardDetector.detect(page.image, dpi: page.dpi, fallback: fallback)
                    if flag.isCancelled { throw ScanError.cancelled }
                    let image = IdCardDetector.extract(page.image, pick: pick)
                    return (DetectedPhoto(region: pick.region, image: image, dpi: page.dpi, sourcePageID: page.id,
                                          colorMode: page.colorMode),
                            pick.note)
                }.value
                guard self.switchGeneration == generation else { return }
                if flag.isCancelled { throw ScanError.cancelled }
                self.recordIdCardSide(side, photo: found.0, note: found.1, source: page.image, area: area)
            case .copy:
                self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                guard let copySetup else { throw PrintError.noPrinter }
                try await self.printCopyPages(processed, settings: s, setup: copySetup, areaSelected: areaSelected,
                                              flag: flag)
                self.recordCaptures(processed.map(\.id))
            case .receiptSplit:
                self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                try await self.showReceipts(processed, settings: s, flag: flag, generation: generation)
            }
            if let stop {
                self.errorMessage = stop.message(pagesKept: raw.count)
            }
            if self.capabilities == nil { await self.readCapabilitiesAfterScan(session, generation: generation) }
        }
    }

    /// The capabilities could not be read on connect (the scanner was off, say) yet a scan just
    /// worked: read them now, so the inspector shows what the scanner can do and the next scan
    /// knows whether its feeder scans both sides. Still unknown when that fails too. Twin of the
    /// Windows `AppViewModel.ReadCapabilitiesAfterScan`.
    private func readCapabilitiesAfterScan(_ session: any ScannerSession, generation: Int) async {
        guard let caps = try? await session.capabilities() else { return }
        guard switchGeneration == generation, capabilities == nil else { return }
        capabilities = caps
        let adapted = SettingsAdapter.adapt(settings, to: sidesCapabilities)
        settings = adapted.settings
        syncTaskFlow()
        statusMessage = Self.withNotes(statusMessage, adapted.notes)
    }

    private nonisolated static func splitPhotos(from page: ScannedPage, settings s: ScanSettings) -> [DetectedPhoto] {
        guard s.photoAutoSplit else {
            return [wholePagePhoto(page)]
        }
        var options = PhotoDetectorOptions()
        options.minPhotoSideInches = s.photoMinSideInches
        options.edgeInsetPixels = s.photoCropInsetPixels
        let regions = PhotoDetector.detectRegions(in: page.image, dpi: page.dpi, options: options)
        guard !regions.isEmpty else { return [wholePagePhoto(page)] }
        return regions.compactMap { region in
            PhotoDetector.extractPhoto(from: page.image, region: region, deskew: s.photoAutoDeskew)
                .map { DetectedPhoto(region: region, image: $0, dpi: page.dpi, sourcePageID: page.id, colorMode: page.colorMode) }
        }
    }

    private nonisolated static func wholePagePhoto(_ page: ScannedPage) -> DetectedPhoto {
        let w = CGFloat(page.image.width), h = CGFloat(page.image.height)
        let region = DetectedPhotoRegion(center: CGPoint(x: w / 2, y: h / 2),
                                         size: CGSize(width: w, height: h), angleDegrees: 0)
        return DetectedPhoto(region: region, image: page.image, dpi: page.dpi, sourcePageID: page.id,
                             colorMode: page.colorMode)
    }

    public func cancelScan() {
        // Stop the hardware if it's mid-scan, AND flag the software phases
        // (processing, OCR, PDF build, exports) — either may be the one running.
        session?.cancelScan()
        currentCancelFlag?.cancel()
    }

    // MARK: Saving

    /// Saves the collected pages as one file: a PDF (with its text beside it when
    /// `OutputOptions.alsoSaveText` is on), or a Word document or text file when that is the format
    /// chosen (`OutputFormat.queueFormat`). OCR reads each page once.
    public func savePDF() {
        guard !scannedPages.isEmpty else { return }
        let s = settings
        runExclusive { flag in
            // Let page swaps and turns that were clicked before the save land first.
            await self.pageEditChain?.value
            let queued = self.scannedPages
            guard !queued.isEmpty else { return }
            // Pages flagged in the strip (blank, separator sheets, or skipped by hand) are left out
            // now, and only now; the documents are the ones the strip shows.
            let plan = SavePlan.make(queued, options: s.document)
            guard !plan.isEmpty else {
                self.errorMessage = PageFilter.nothingToSaveMessage
                self.statusMessage = DocumentSplitter.queueSummary(queued, options: s.document) + "."
                return
            }
            if plan.isSplit {
                try await self.saveDocuments(plan, settings: s, queued: queued, flag: flag)
                return
            }
            let document = plan.documents[0]
            let pages = document.pages
            let left = plan.leftOutNote()
            let format = s.format.queueFormat
            if format.isTextFormat {
                self.statusMessage = "Reading the text of the pages…"
                let url = try self.outputURL(fileExtension: format.fileExtension, label: document.label)
                let hasText = try await Task.detached(priority: .userInitiated) {
                    try Self.writeTextDocument(pages: pages, format: format, to: url,
                                               shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                        Task { @MainActor in self?.statusMessage = msg }
                    }
                }.value
                self.lastSavedURLs = [url]
                self.deleteSpoolFiles(of: queued)
                self.scannedPages = []
                self.resetFlow()
                self.statusMessage = TextExport.savedMessage(format: format, pageCount: pages.count,
                                                             fileName: url.lastPathComponent, hasText: hasText) + left
                self.runAfterSave(s.output.afterSave, saved: [url])
                return
            }
            let text = s.output.alsoSaveText ? PDFTextCollector() : nil
            self.statusMessage = s.pdfSearchable || text != nil ? "Running OCR and building PDF…" : "Building PDF…"
            let url = try self.outputURL(fileExtension: "pdf", label: document.label)
            let textResult = try await Task.detached(priority: .userInitiated) { () throws -> (url: URL?, problem: String?)? in
                try Self.writePDFAtomically(pages: pages, pdfSize: s.output.pdfSize, to: url,
                                            textLayer: Self.textLayer(searchable: s.pdfSearchable, collecting: text,
                                                                      pages: pages),
                                            shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
                return text.map { Self.writeTextBeside(pdf: url, text: $0) }
            }.value
            self.lastSavedURLs = [url]
            self.notePDFSize(of: url)
            self.deleteSpoolFiles(of: queued)
            self.scannedPages = []
            self.resetFlow()
            if let problem = textResult?.problem { self.errorMessage = TextExport.sidecarFailed(problem) }
            let textNote = textResult?.url.map { TextExport.sidecarSuffix($0.lastPathComponent) } ?? ""
            self.statusMessage = "Saved \(pages.count)-page PDF: \(url.lastPathComponent)\(self.pdfSizeSuffix)\(textNote)\(left)"
            self.runAfterSave(s.output.afterSave, saved: [url])
        }
    }

    /// Used when documentMultiPage is off: write each scan to disk as soon as it lands, with the
    /// settings it was scanned with. A Word document or text file is one file: when its text cannot
    /// be read or it cannot be written (or the save is cancelled) the pages are put in the queue
    /// instead, as the pages are held nowhere else.
    private func saveImmediately(_ pages: [ScannedPage], settings s: ScanSettings, flag: CancelFlag) async throws {
        var saved: [URL] = []
        var note = ""
        if s.format.isTextFormat {
            let url: URL
            let hasText: Bool
            do {
                let target = try outputURL(fileExtension: s.format.fileExtension)
                hasText = try await Task.detached(priority: .userInitiated) {
                    try Self.writeTextDocument(pages: pages, format: s.format, to: target,
                                               shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                        Task { @MainActor in self?.statusMessage = msg }
                    }
                }.value
                url = target
            } catch {
                // Nothing was written: the pages go to the queue rather than being lost, to be
                // saved once the text can be read or the file written, or in another format.
                let spooled = await Task.detached(priority: .userInitiated) {
                    Self.spoolPages(pages)
                }.value
                scannedPages.append(contentsOf: spooled)
                let cancelled: Bool
                switch error {
                case ScanError.cancelled, is CancellationError:
                    cancelled = true
                default:
                    cancelled = false
                }
                if !cancelled { errorMessage = error.localizedDescription }
                statusMessage = TextExport.keptInQueue(format: s.format, pageCount: pages.count, cancelled: cancelled,
                                                       textUnreadable: error is TextOutputError)
                return
            }
            lastSavedURLs = [url]
            statusMessage = TextExport.savedMessage(format: s.format, pageCount: pages.count,
                                                    fileName: url.lastPathComponent, hasText: hasText)
            runAfterSave(s.output.afterSave, saved: [url])
            return
        }
        if s.format == .pdf {
            let url = try outputURL(fileExtension: "pdf")
            let text = s.output.alsoSaveText ? PDFTextCollector() : nil
            let textResult = try await Task.detached(priority: .userInitiated) { () throws -> (url: URL?, problem: String?)? in
                try Self.writePDFAtomically(pages: pages, pdfSize: s.output.pdfSize, to: url,
                                            textLayer: Self.textLayer(searchable: s.pdfSearchable, collecting: text,
                                                                      pages: pages),
                                            shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
                return text.map { Self.writeTextBeside(pdf: url, text: $0) }
            }.value
            saved = [url]
            notePDFSize(of: url)
            if let problem = textResult?.problem { errorMessage = TextExport.sidecarFailed(problem) }
            note = pdfSizeSuffix + (textResult?.url.map { TextExport.sidecarSuffix($0.lastPathComponent) } ?? "")
        } else {
            for page in pages {
                if flag.isCancelled { throw ScanError.cancelled }
                let url = try outputURL(fileExtension: s.format.fileExtension)
                try await Task.detached(priority: .userInitiated) {
                    try ImageExporter.write(page.image, to: url, format: s.format,
                                            dpi: page.dpi, jpegQuality: s.jpegQuality)
                }.value
                saved.append(url)
            }
        }
        lastSavedURLs = saved
        statusMessage = "Saved \(saved.map(\.lastPathComponent).joined(separator: ", "))\(note)"
        runAfterSave(s.output.afterSave, saved: saved)
    }

    public func saveReviewedPhotos() {
        let photos = detectedPhotos.filter(\.included)
        guard !photos.isEmpty else { return cancelPhotoReview() }
        // Receipts are named by their date and saved as PDFs or images (AppState+Receipts.swift).
        if isReceiptReview { return saveReceipts() }
        let s = settings
        let format = s.format.imageFormatOrJPEG
        runExclusive { flag in
            var saved: [URL] = []
            for (index, photo) in photos.enumerated() {
                if flag.isCancelled { throw ScanError.cancelled }
                let url = try self.outputURL(fileExtension: format.fileExtension, index: index + 1)
                try await Task.detached(priority: .userInitiated) {
                    let image = photo.rotationQuarterTurns == 0
                        ? photo.image
                        : ImagePipeline.rotate(photo.image, quarterTurns: photo.rotationQuarterTurns)
                    try ImageExporter.write(image, to: url, format: format,
                                            dpi: photo.dpi, jpegQuality: s.jpegQuality)
                }.value
                saved.append(url)
            }
            self.lastSavedURLs = saved
            self.detectedPhotos = []
            self.showPhotoReview = false
            self.photoSourceImages = [:]
            self.resetFlow()
            self.statusMessage = "Saved \(saved.count) photo\(saved.count == 1 ? "" : "s") to \(s.destinationPath)"
            self.runAfterSave(s.output.afterSave, saved: saved)
        }
    }

    public func cancelPhotoReview() {
        let receipts = isReceiptReview
        detectedPhotos = []
        showPhotoReview = false
        isReceiptReview = false
        photoSourceImages = [:]
        resetFlow()
        statusMessage = receipts ? "Receipts discarded." : "Photo batch discarded."
        endOfWork()
    }

    /// Manual crop correction from the review sheet: re-extract one photo from its
    /// (full-resolution) source page with a user-adjusted region. The extraction runs
    /// off the main actor — at high dpi it renders hundreds of MB of pixels.
    public func recropPhoto(id: UUID, region: DetectedPhotoRegion) {
        guard !isBusy else { return }
        if let side = idCardSide(ofPhoto: id) {
            recropIdCardSide(side, region: region)
            return
        }
        guard let photo = detectedPhotos.first(where: { $0.id == id }),
              let source = photoSource(for: photo) else { return }
        let deskew = settings.photoAutoDeskew
        let receipt = isReceiptReview
        let dpi = photo.dpi
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                // A receipt is cut out upright and cleaned up again, as it was found.
                receipt
                    ? Self.recutReceipt(source, region: region, dpi: dpi)
                    : PhotoDetector.extractPhoto(from: source, region: region, deskew: deskew)
            }.value
            guard let self, let image, !self.isBusy,
                  let idx = self.detectedPhotos.firstIndex(where: { $0.id == id }) else { return }
            let old = self.detectedPhotos[idx]
            var updated = DetectedPhoto(region: region, image: image, dpi: old.dpi,
                                        id: old.id, sourcePageID: old.sourcePageID, colorMode: old.colorMode)
            updated.included = old.included
            updated.rotationQuarterTurns = old.rotationQuarterTurns
            self.detectedPhotos[idx] = updated
        }
    }

    // MARK: Page queue

    public func removePage(id: UUID) {
        // Never mutate the queue (or unlink spool files) while a save is
        // reading from it.
        guard !isBusy else { return }
        if let page = scannedPages.first(where: { $0.id == id }) {
            deleteSpoolFiles(of: [page])
        }
        scannedPages.removeAll { $0.id == id }
    }

    public func movePage(id: UUID, by offset: Int) {
        guard !isBusy else { return }
        guard let idx = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let newIdx = idx + offset
        guard newIdx >= 0 && newIdx < scannedPages.count else { return }
        scannedPages.swapAt(idx, newIdx)
    }

    func setLastScan(preview: CGImage?, pixelSize: CGSize?) {
        lastScanImage = preview
        lastScanPixelSize = pixelSize
    }

    /// Rotate a queued page 90° clockwise. The in-memory preview is rotated right away
    /// (the strip thumbnail follows it); the full-resolution spool file stays untouched
    /// and PDFBuilder applies the accumulated rotation at save time.
    public func rotatePage(id: UUID) {
        guard !isBusy else { return }
        // Behind a swap still reading its file, so the clicks land in the order they were made.
        if pageEditChain != nil {
            enqueuePageEdit { state in state.applyRotation(id: id) }
        } else {
            applyRotation(id: id)
        }
    }

    private func applyRotation(id: UUID) {
        guard let idx = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let page = scannedPages[idx]
        // withImage keeps the page's facts (its side and sheet) and its spool file.
        var updated = page.withImage(ImagePipeline.rotate(page.image, quarterTurns: 1),
                                     fileURL: page.fileURL, fullPixelSize: page.fullPixelSize)
        updated.rotationQuarterTurns = (page.rotationQuarterTurns + 1) % 4
        // The other version's pixels in memory turn with the page; a spooled one is turned when shown.
        if var version = page.alternate, let other = version.image {
            version.image = ImagePipeline.rotate(other, quarterTurns: 1)
            updated = updated.withAlternate(version)
        }
        scannedPages[idx] = updated
    }

    /// Whether pages can be turned upright: text recognition can read them.
    public var canTurnPagesUpright: Bool { orientationScorer.isAvailable }

    /// One click on a turned page's turn button: the turn is undone and the page saved the way it
    /// was scanned; a second click turns it upright again. The preview turns at once, the spool file
    /// through the page's rotation when it is saved (`ScannedPage.withUprightToggled`); behind a swap
    /// still reading its file, like a turn by hand. Twin of the Windows `AppViewModel.TogglePageUpright`.
    public func togglePageUpright(id: UUID) {
        guard !isBusy else { return }
        if pageEditChain != nil {
            enqueuePageEdit { state in state.applyUprightToggle(id: id) }
        } else {
            applyUprightToggle(id: id)
        }
    }

    private func applyUprightToggle(id: UUID) {
        guard let idx = scannedPages.firstIndex(where: { $0.id == id }), scannedPages[idx].upright != nil else { return }
        let toggled = scannedPages[idx].withUprightToggled()
        scannedPages[idx] = toggled
        statusMessage = PageTurns.toggleNote(toggled, number: idx + 1)
    }

    /// One click on a cropped or straightened page's swap button: the page as scanned is shown, and
    /// saved, instead; a second click brings the cropped and straightened page back. The other
    /// version is read from its spool file off the main actor; swaps and the turns clicked while one
    /// is under way run one after another, and a save waits for them. Twin of the Windows
    /// `AppViewModel.TogglePageGeometry`.
    public func togglePageGeometry(id: UUID) {
        guard !isBusy else { return }
        enqueuePageEdit { state in await state.swapVersions(id: id) }
    }

    /// Runs `edit` after every page swap and turn queued before it (the Windows `_pageRotateChain`).
    private func enqueuePageEdit(_ edit: @escaping @MainActor (AppState) async -> Void) {
        let previous = pageEditChain
        pageEditCount += 1
        let ticket = pageEditCount
        pageEditChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await edit(self)
            if self.pageEditCount == ticket { self.pageEditChain = nil }
        }
    }

    /// Shows the other version of the page as it is now: from memory, or read from its spool file
    /// off the main actor. The swap applies if the page is still in the queue as it was when the
    /// read started (not removed, saved, turned or swapped meanwhile).
    private func swapVersions(id: UUID) async {
        guard let page = scannedPages.first(where: { $0.id == id }), page.canSwapVersions,
              let other = page.alternate else { return }
        let shown: CGImage
        if let image = other.image {
            shown = image
        } else {
            guard let url = other.fileURL else { return }
            let turns = page.rotationQuarterTurns
            let read: CGImage? = await Task.detached(priority: .userInitiated) {
                Self.previewOfSpoolFile(url, quarterTurns: turns)
            }.value
            // Removed while its file was read: nothing to switch, and nothing to report.
            guard scannedPages.contains(where: { $0.id == id }) else { return }
            guard let read else {
                errorMessage = "The page could not be switched: its file could not be read."
                return
            }
            shown = read
        }
        guard let idx = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let current = scannedPages[idx]
        guard current.canSwapVersions, current.showsOriginal == page.showsOriginal,
              current.rotationQuarterTurns == page.rotationQuarterTurns else { return }
        let swapped = current.withVersionsSwapped(shown)
        scannedPages[idx] = swapped
        statusMessage = PageCorrections.swapNote(swapped, number: idx + 1)
    }

    /// A preview of a spooled page version as the queue shows a page, turned by `quarterTurns`.
    private nonisolated static func previewOfSpoolFile(_ url: URL, quarterTurns: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let preview = makePreview(full, maxSide: 1600) ?? full
        return quarterTurns == 0 ? preview : ImagePipeline.rotate(preview, quarterTurns: quarterTurns)
    }

    /// One click on a queued page's Keep or Skip button: the page is saved or left out, whatever
    /// the blank-page setting says (a separator page kept is saved, and its sheet no longer splits);
    /// a second click goes back to what the settings say. Twin of the Windows
    /// `AppViewModel.TogglePageInclusion`.
    public func togglePageInclusion(id: UUID) {
        guard !isBusy, let idx = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let facts = scannedPages.map { PageFacts.of($0, options: settings.document) }
        let updated = scannedPages[idx].withInclusion(DocumentSplitter.toggledInclusion(facts, idx, options: settings.document))
        scannedPages[idx] = updated
        // A document whose first page is now left out (or now saved) keeps its name.
        carryDocumentLabels(from: facts)
        let summary = DocumentSplitter.queueSummary(scannedPages, options: settings.document)
        statusMessage = DocumentSplitter.plan(scannedPages, options: settings.document).pages[idx].role != .content
            ? "Page \(idx + 1) will be left out when you save. \(summary)."
            : "Page \(idx + 1) will be saved. \(summary)."
    }

    public func clearPages() {
        guard !isBusy else { return }
        deleteSpoolFiles(of: scannedPages)
        scannedPages = []
        resetFlow()
        statusMessage = "Page queue cleared."
    }

    // MARK: Two-sided scanning

    /// Reads whether the connected scanner's feeder scans both sides, for sessions that tell only
    /// once the feeder is selected (ImageCaptureCore). Selecting it can take a while on a sleeping
    /// scanner, so this runs only when the feeder is used, until the scanner has answered (one that
    /// did not answer is asked again the next time). A check under way is waited for, never
    /// started twice. Once the answer is in, a feeder that scans one side turns "Both sides" into
    /// turning over by hand, and the steps follow. Other backends report it in their capabilities.
    func checkFeederDuplex() async {
        if let running = feederDuplexCheck {
            await running.value
            return
        }
        guard !feederDuplexChecked, let session, session.feederDuplexNeedsSelection,
              capabilities?.sources.contains(.documentFeeder) == true else { return }
        let generation = switchGeneration
        let check = Task { @MainActor [weak self] in
            guard let self, self.switchGeneration == generation, let session = self.session else { return }
            let supported = await session.feederSupportsDuplex()
            // A check for a scanner no longer connected is dropped (switchSession starts over).
            guard self.switchGeneration == generation else { return }
            self.feederDuplexCheck = nil
            // nil: no answer this time; asked again the next time the feeder is used.
            guard let supported else { return }
            self.feederDuplexChecked = true
            self.capabilities?.supportsDuplex = supported
            self.feederDuplexAnswered()
        }
        feederDuplexCheck = check
        await check.value
    }

    /// The scanner said whether its feeder scans both sides: one that scans one side turns "Both
    /// sides" into turning over by hand (the settings' didSet brings the steps); otherwise the
    /// steps follow the capabilities.
    private func feederDuplexAnswered() {
        if settings.duplex == .both,
           DocumentSides.effective(settings, capabilities: sidesCapabilities) == .manual {
            settings.duplex = .manual
            statusMessage = "This scanner's feeder scans one side at a time, so you'll turn the stack over by hand."
        } else {
            syncTaskFlow()
        }
    }

    /// `checkFeederDuplex` for a change of source in the inspector or a task.
    private func checkFeederDuplexSoon() {
        guard !feederDuplexChecked, feederDuplexCheck == nil, session != nil, !isBusy else { return }
        Task { @MainActor [weak self] in
            await self?.checkFeederDuplex()
        }
    }

    /// What to do while the fronts are scanned a part at a time.
    private static let moreFrontsPrompt =
        "Load the sheets not scanned yet and scan more fronts; once every front is scanned, choose Done with Fronts."

    /// After a scan of a stack turned over by hand: the fronts move the steps on to the backs,
    /// unless the feeder stopped early (`stopped`, a jam): then the steps stay at the fronts so the
    /// rest of them can be scanned (`finishFronts()` moves on). The backs put the stack in reading
    /// order when they pair up with the fronts, otherwise the mismatch is shown (`sidesMismatch`).
    /// Twin of the Windows `AppViewModel.AfterTurnedOverScan`.
    private func afterTurnedOverScan(_ side: PageSide, count: Int, stopped: Bool) {
        guard taskFlow != nil else { return }
        if side == .front {
            if stopped {
                statusMessage = "Scanned \(count) front side\(count == 1 ? "" : "s") before the feeder stopped. \(Self.moreFrontsPrompt)"
                return
            }
            taskFlow?.advance()
            statusMessage = "Scanned \(count) front side\(count == 1 ? "" : "s"). Turn the stack over and scan the back sides."
            return
        }
        collateTurnedOverStack(combineAnyway: false)
    }

    /// Every front is scanned: on to the backs (after a batch cut short, or more fronts).
    public func finishFronts() {
        guard !isBusy, canFinishFronts, taskFlow != nil else { return }
        let fronts = queuedCaptures(DocumentSides.frontsStepID)
        taskFlow?.advance()
        statusMessage = "\(fronts) front side\(fronts == 1 ? "" : "s") scanned. Turn the stack over and scan the back sides."
    }

    /// Back to the fronts before any back was scanned, keeping the fronts scanned so far: for a
    /// stack larger than the feeder holds, scanned a part at a time.
    public func scanMoreFronts() {
        guard !isBusy, canScanMoreFronts, var flow = taskFlow else { return }
        // Retake makes the fronts the current step; the fronts already scanned are kept, in order.
        for id in flow.retake(stepID: DocumentSides.frontsStepID) {
            flow.record(stepID: DocumentSides.frontsStepID, captureID: id)
        }
        taskFlow = flow
        sidesMismatch = nil
        statusMessage = Self.moreFrontsPrompt
    }

    /// How many captures of a step are still in the queue.
    func queuedCaptures(_ stepID: String) -> Int {
        guard let flow = taskFlow else { return 0 }
        let queued = Set(scannedPages.map(\.id))
        return flow.captures(for: stepID).filter { queued.contains($0) }.count
    }

    /// Puts the fronts and backs of the stack in reading order in the queue, unless their counts
    /// differ and `combineAnyway` is false: then the mismatch is shown and the steps stay at the backs.
    private func collateTurnedOverStack(combineAnyway: Bool) {
        guard let flow = taskFlow else { return }
        let collation = DocumentSides.collateQueue(scannedPages.map(\.id),
                                                   fronts: flow.captures(for: DocumentSides.frontsStepID),
                                                   backs: flow.captures(for: DocumentSides.backsStepID))
        let counts = collation.interleave
        if counts.mismatch && !combineAnyway {
            sidesMismatch = counts.mismatchMessage
            statusMessage = "\(counts.mismatchMessage ?? ""). Scan the rest of the back sides, scan them again, or combine the pages as they are."
            return
        }
        var byID: [UUID: ScannedPage] = [:]
        for page in scannedPages { byID[page.id] = page }
        scannedPages = collation.order.compactMap { id -> ScannedPage? in
            guard let page = byID[id] else { return nil }
            guard let position = collation.positions[id] else { return page }
            return page.withSide(position.side, sheetIndex: position.sheetIndex)
        }
        resetFlow()
        let sheets = max(counts.fronts, counts.backs)
        let pages = counts.fronts + counts.backs
        statusMessage = "Put \(sheets) sheet\(sheets == 1 ? "" : "s") in order (\(pages) page\(pages == 1 ? "" : "s")) — \(scannedPages.count) in queue. Scan another stack or \(settings.format.saveTitle)."
    }

    /// The backs did not pair up with the fronts, but the pages are combined as they are (the
    /// extra pages at the end).
    public func combineSidesAnyway() {
        guard !isBusy, awaitingBacks else { return }
        collateTurnedOverStack(combineAnyway: true)
    }

    /// The back sides scanned so far leave the queue, to be scanned again.
    public func scanBacksAgain() {
        guard !isBusy, awaitingBacks, taskFlow != nil else { return }
        let removed = taskFlow?.retake(stepID: DocumentSides.backsStepID) ?? []
        removeQueuedPages(removed)
        sidesMismatch = nil
        statusMessage = "Load the turned-over stack in the feeder again and scan the back sides."
    }

    /// The stack stays one-sided: the backs scanned so far leave the queue, the fronts stay (in
    /// scan order), and the next scan starts a new stack.
    public func keepFrontsOnly() {
        guard !isBusy, awaitingBacks, let flow = taskFlow else { return }
        removeQueuedPages(flow.captures(for: DocumentSides.backsStepID))
        let queued = Set(scannedPages.map(\.id))
        let fronts = flow.captures(for: DocumentSides.frontsStepID).filter { queued.contains($0) }.count
        resetFlow()
        statusMessage = "Kept \(fronts) front side\(fronts == 1 ? "" : "s") — \(scannedPages.count) in queue. Scan another stack or \(settings.format.saveTitle)."
    }

    /// Stops turning stacks over by hand (the close button of its banner without a task): feeder
    /// scans are one-sided again. Pages already in the queue stay.
    public func scanOneSideOnly() {
        guard !isBusy, settings.duplex != .off else { return }
        settings.duplex = .off
        statusMessage = "Scanning one side of each sheet."
    }

    private func removeQueuedPages(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        deleteSpoolFiles(of: scannedPages.filter { set.contains($0.id) })
        scannedPages.removeAll { set.contains($0.id) }
    }

    // MARK: Presets

    /// Replaces the settings with the preset's, fitted to the connected scanner. A preset saved
    /// while a task was active brings that task (and its banner) back.
    public func applyPreset(_ preset: Preset) {
        let adapted = SettingsAdapter.adapt(preset.settings, to: sidesCapabilities)
        settings = adapted.settings
        statusMessage = Self.withNotes("Applied preset “\(preset.name)”.", adapted.notes)
    }

    public func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets.append(Preset(name: trimmed, settings: settings))
        presetStore.save(presets)
    }

    public func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        presetStore.save(presets)
    }

    // MARK: Helpers

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Saved files: open, share, copy

    /// The actions offered for the last save's files (the status bar).
    public var savedFileActions: [FileAction] { SaveActions.offered(fileCount: lastSavedURLs.count) }

    /// Opens, shows, shares, emails or copies saved files (the Saved tab and the status bar after
    /// a save). Nothing leaves the Mac here: sharing and email open the share menu or a new Mail
    /// message, and the user decides where the files go. A file that is gone, or an action macOS
    /// refuses, is reported. Open and Open with use the first file. Returns whether the action
    /// was carried out. Twin of the Windows `AppViewModel.RunFileAction`.
    @discardableResult
    public func runFileAction(_ action: FileAction, urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            errorMessage = missing.count == 1
                ? "\(missing[0].lastPathComponent) is no longer in its folder. It may have been moved, renamed or deleted."
                : "\(missing.count) of the files are no longer in their folder. They may have been moved, renamed or deleted."
            return false
        }
        do {
            switch action {
            case .open:
                try fileActions.open(urls[0])
            case .openWith:
                try fileActions.openWith(urls[0])
            case .reveal:
                fileActions.reveal(urls)
            case .share:
                try send(SaveActions.shareRoute(fileActions.sendProbe(for: urls)), urls: urls)
            case .email:
                try send(SaveActions.emailRoute(fileActions.sendProbe(for: urls)), urls: urls)
            case .copy:
                let content = SaveActions.clipboardContent(for: urls)
                try fileActions.copy(content)
                statusMessage = urls.count == 1
                    ? "Copied \(urls[0].lastPathComponent)\(content.imageFile == nil ? "" : " and its picture") to the clipboard."
                    : "Copied \(urls.count) files to the clipboard."
            }
        } catch {
            let name = action.label.replacingOccurrences(of: "\u{2026}", with: "")
            errorMessage = "\(name) did not work: \(Self.describe(error))"
            return false
        }
        return true
    }

    private func send(_ route: SendRoute, urls: [URL]) throws {
        switch route {
        case .compose:
            try fileActions.composeEmail(urls)
        case .shareSheet:
            try fileActions.share(urls, title: SaveActions.shareTitle(urls))
        case .showInFolder:
            fileActions.reveal(urls)
            statusMessage = SaveActions.showInFolderMessage
        }
    }

    /// The after-save action of the settings the files were saved with, once a save has finished
    /// (never after a cancelled or failed one). A refusal is reported; the save stands.
    func runAfterSave(_ action: AfterSaveAction, saved: [URL]) {
        guard let step = SaveActions.plan(action, saved: saved) else { return }
        runFileAction(step.fileAction, urls: step.urls)
    }

    /// The message of a refused file action, without ScanError's "Saving failed:" style prefix.
    private static func describe(_ error: Error) -> String {
        if let scanError = error as? ScanError {
            switch scanError {
            case .exportFailed(let message), .unsupported(let message):
                return message
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func noDevice() {
        errorMessage = "No scanner is connected. Select a device in the sidebar (or use the Demo Scanner)."
    }

    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        let snapshot = settings
        settingsSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            SettingsStore.save(snapshot)
        }
    }

    /// Write each full-resolution page to a spool TIFF and return queue entries
    /// that carry only a preview in memory. A page whose spill fails is kept
    /// fully in memory instead. The page as scanned, kept by crop and straighten, gets a spool
    /// file of its own (and keeps its pixels in memory when that fails), so one click can show it.
    nonisolated static func spoolPages(_ pages: [ScannedPage]) -> [ScannedPage] {
        try? FileManager.default.createDirectory(at: pageSpoolDirectory, withIntermediateDirectories: true)
        return pages.map { page in
            let url = pageSpoolDirectory.appendingPathComponent("\(page.id.uuidString).tiff")
            do {
                try ImageExporter.write(page.image, to: url, format: .tiff,
                                        dpi: page.dpi, jpegQuality: 1.0)
            } catch {
                return page
            }
            let preview = makePreview(page.image, maxSide: 1600) ?? page.image
            var spooled = page.withImage(preview, fileURL: url,
                                         fullPixelSize: CGSize(width: page.image.width, height: page.image.height))
            if let other = page.alternate?.image {
                let otherURL = pageSpoolDirectory.appendingPathComponent("\(page.id.uuidString)-other.tiff")
                do {
                    try ImageExporter.write(other, to: otherURL, format: .tiff, dpi: page.dpi, jpegQuality: 1.0)
                    spooled = spooled.withAlternate(PageVersion(image: nil, fileURL: otherURL,
                                                                fullPixelSize: CGSize(width: other.width, height: other.height)))
                } catch {
                    // Kept in memory: the page can still be shown as scanned.
                }
            }
            return spooled
        }
    }

    nonisolated static func makePreview(_ image: CGImage, maxSide: Int) -> CGImage? {
        let w = image.width, h = image.height
        let longSide = max(w, h)
        guard longSide > maxSide else { return image }
        let scale = Double(maxSide) / Double(longSide)
        let nw = max(1, Int(Double(w) * scale)), nh = max(1, Int(Double(h) * scale))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }

    /// Remember the size of the PDF just written at `url` (nil when it cannot be read).
    func notePDFSize(of url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        lastPDFByteCount = size?.int64Value
    }

    /// " (412 KB)" after the name of the PDF just saved, or nothing when its size is unknown.
    var pdfSizeSuffix: String {
        guard let bytes = lastPDFByteCount else { return "" }
        return " (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
    }

    /// Write the PDF to a hidden temp name and move it into place, so a failed
    /// or interrupted build never leaves a truncated PDF at the destination.
    nonisolated static func writePDFAtomically(pages: [ScannedPage], searchable: Bool,
                                                       languages: [String], pdfSize: PDFSizePreset,
                                                       to url: URL,
                                                       shouldContinue: (() -> Bool)? = nil,
                                                       progress: ((String) -> Void)?) throws {
        let layer: PDFTextLayer? = searchable
            ? { _, page in try? OCRService.recognizeLines(in: page.image, languages: languages) }
            : nil
        try writePDFAtomically(pages: pages, pdfSize: pdfSize, to: url, textLayer: layer,
                               shouldContinue: shouldContinue, progress: progress)
    }

    /// The same, with each page's text layer from `textLayer` (none when nil).
    nonisolated static func writePDFAtomically(pages: [ScannedPage], pdfSize: PDFSizePreset, to url: URL,
                                               textLayer: PDFTextLayer?, shouldContinue: (() -> Bool)? = nil,
                                               progress: ((String) -> Void)?) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pdf.tmp")
        do {
            try PDFBuilder.writePDF(pages: pages, pdfSize: pdfSize, to: tmp, progress: progress,
                                    shouldContinue: shouldContinue, textLayer: textLayer)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// The text layer of a PDF being saved: OCR reads each page once, for the searchable text
    /// layer (when `searchable`) and for the text file beside the PDF (when `collecting`, which
    /// keeps the lines, or the first OCR error, page by page).
    nonisolated static func textLayer(searchable: Bool, collecting text: PDFTextCollector?,
                                                  pages: [ScannedPage]) -> PDFTextLayer? {
        guard searchable || text != nil else { return nil }
        return { index, prepared in
            // Once the text file is known to be lost, a PDF that is not searchable needs no more OCR.
            if !searchable && (text == nil || text?.problem != nil) { return nil }
            let lines: [OCRLine]?
            do {
                lines = try OCRService.recognizeLines(in: prepared.image)
            } catch {
                lines = nil
                if let text, text.problem == nil { text.problem = error.localizedDescription }
            }
            if let lines, let text, text.problem == nil {
                text.pages.append(OCRPage.of(lines, pixelWidth: prepared.pixelWidth,
                                             pixelHeight: prepared.pixelHeight, dpi: pages[index].dpi))
            }
            return searchable ? lines : nil
        }
    }

    /// The text file beside a PDF just written, with the PDF's name (the next free one when that is
    /// taken): its URL, or why it was not written (the PDF is saved either way).
    nonisolated static func writeTextBeside(pdf url: URL, text: PDFTextCollector) -> (url: URL?, problem: String?) {
        if let problem = text.problem { return (nil, problem) }
        let target = NamingTemplate.uniqueURL(in: url.deletingLastPathComponent(),
                                              base: url.deletingPathExtension().lastPathComponent,
                                              fileExtension: "txt")
        do {
            try TextExport.encode(text.pages).write(to: target, options: .withoutOverwriting)
            return (target, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Reads the text of every page with OCR, on full-resolution pixels with the page's rotation,
    /// and writes it as a Word document or a text file (`format`). A page whose text cannot be read
    /// fails the save, saying why. Returns whether any text was found.
    nonisolated static func writeTextDocument(pages: [ScannedPage], format: OutputFormat, to url: URL,
                                                          shouldContinue: () -> Bool,
                                                          progress: (String) -> Void) throws -> Bool {
        var ocrPages: [OCRPage] = []
        for (index, page) in pages.enumerated() {
            if !shouldContinue() { throw ScanError.cancelled }
            progress("Reading the text of page \(index + 1) of \(pages.count)…")
            let prepared = PDFBuilder.preparePage(page)
            let lines = try recognizeForText(prepared.image)
            ocrPages.append(OCRPage.of(lines, pixelWidth: prepared.pixelWidth,
                                       pixelHeight: prepared.pixelHeight, dpi: page.dpi))
        }
        if !shouldContinue() { throw ScanError.cancelled }
        progress(format == .word ? "Writing the Word document…" : "Writing the text file…")
        let data = format == .word ? DocxWriter.make(ocrPages) : TextExport.encode(ocrPages)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScanError.exportFailed("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return TextExport.hasText(ocrPages)
    }

    /// The lines OCR finds on `image`, for text the user asked for: a failure is an error that says
    /// why (`TextOutputError`, not a scanner failure, so the troubleshooter does not record it).
    nonisolated fileprivate static func recognizeForText(_ image: CGImage) throws -> [OCRLine] {
        do {
            return try OCRService.recognizeLines(in: image)
        } catch {
            throw TextOutputError(TextExport.recognitionFailed(error.localizedDescription))
        }
    }

    /// Copy Text on a page in the queue: reads its text with OCR (full resolution, as turned) and
    /// puts it on the pasteboard, a blank line between paragraphs. Twin of the Windows
    /// `AppViewModel.CopyPageText`.
    public func copyPageText(id: UUID) {
        guard !isBusy, scannedPages.contains(where: { $0.id == id }) else { return }
        runExclusive { flag in
            // A turn clicked just before must be in the text's reading order.
            await self.pageEditChain?.value
            guard let index = self.scannedPages.firstIndex(where: { $0.id == id }) else { return }
            let page = self.scannedPages[index]
            self.statusMessage = "Reading the text of page \(index + 1)…"
            let text = try await Task.detached(priority: .userInitiated) { () throws -> String in
                let prepared = PDFBuilder.preparePage(page)
                let lines = try Self.recognizeForText(prepared.image)
                return OCRText.pageText(OCRPage.of(lines, pixelWidth: prepared.pixelWidth,
                                                   pixelHeight: prepared.pixelHeight, dpi: page.dpi))
            }.value
            if flag.isCancelled { throw ScanError.cancelled }
            if !text.isEmpty {
                do {
                    try self.fileActions.copyText(text)
                } catch {
                    throw TextOutputError("Copy did not work: \(Self.describe(error))")
                }
            }
            self.statusMessage = TextExport.copiedMessage(pageNumber: index + 1, hasText: !text.isEmpty)
        }
    }

    func deleteSpoolFiles(of pages: [ScannedPage]) {
        for page in pages {
            for url in [page.fileURL, page.alternate?.fileURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func destinationDirectory() throws -> URL {
        let url = URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func nextCounter() -> Int {
        let key = "CompleteScanner.counter"
        let value = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func outputURL(fileExtension: String, index: Int? = nil, documentDate: DocumentDate? = nil,
                   label: String? = nil) throws -> URL {
        let dir = try destinationDirectory()
        let base = NamingTemplate(settings.namingTemplate)
            .baseFilename(NamingContext(counter: nextCounter(), date: Date(), intent: settings.intent,
                                        index: index, task: TaskCatalog.infer(settings), documentDate: documentDate,
                                        label: label))
        return NamingTemplate.uniqueURL(in: dir, base: base, fileExtension: fileExtension)
    }

    /// Run one long operation at a time; surface errors; manage busy state. The
    /// operation receives a CancelFlag it must poll between heavy work units.
    func runExclusive(_ operation: @escaping (CancelFlag) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        let flag = CancelFlag()
        currentCancelFlag = flag
        Task { @MainActor in
            do {
                try await operation(flag)
            } catch ScanError.cancelled {
                statusMessage = "Cancelled."
            } catch is CancellationError {
                statusMessage = "Cancelled."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Ready."
                // A scan the scanner refused (busy, offline, ...) is what the troubleshooter explains.
                if error is ScanError, let session = self.session {
                    self.recordFailure(deviceName: session.info.name, error: error)
                }
            }
            currentCancelFlag = nil
            progress = nil
            isBusy = false
            endOfWork()
        }
    }
}
