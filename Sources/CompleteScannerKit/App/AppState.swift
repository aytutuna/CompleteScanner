import AppKit
import Combine
import CoreGraphics
import Foundation

/// Where document pages are spilled to disk while they wait in the queue,
/// so a long high-dpi batch doesn't hold gigabytes of pixels in memory.
private let pageSpoolDirectory: URL = FileManager.default.temporaryDirectory
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
            // A task the settings no longer fit (the mode changed by hand, or a scanner without
            // the task's source) ends; its steps follow the task (AppState+Tasks.swift).
            if let task = settings.task, !TaskCatalog.fits(task, settings) { settings.taskId = nil }
            syncTaskFlow()
            scheduleSettingsSave()
        }
    }

    /// Low-res preview of the full bed; the selection marquee is only valid over this image.
    @Published public private(set) var overviewImage: CGImage? {
        didSet { canvasRevision &+= 1 }
    }
    /// The most recent full scan (shown in the canvas when there is no overview).
    @Published public private(set) var lastScanImage: CGImage? {
        didSet { canvasRevision &+= 1 }
    }
    /// Bumped whenever either canvas image changes, so views can key decode work on it
    /// (object identity of a CGImage is unreliable — addresses get reused).
    @Published public private(set) var canvasRevision = 0
    /// True pixel dimensions of the last scan. `lastScanImage` holds only a downsampled
    /// preview (full-resolution raws would pin hundreds of MB at high dpi); detected-photo
    /// outlines use this to map full-resolution region coordinates onto the preview.
    @Published public private(set) var lastScanPixelSize: CGSize?
    /// Normalized (0...1) crop rect within the flatbed, origin top-left. nil = full bed.
    @Published public var selectionRect: CGRect?

    @Published public private(set) var scannedPages: [ScannedPage] = []
    @Published public var detectedPhotos: [DetectedPhoto] = []
    @Published public var showPhotoReview = false
    /// This session's scans, newest first (small previews only) — the "Scans" tab.
    @Published public private(set) var scanHistory: [ScanHistoryEntry] = []
    /// Full-resolution sources of the current photo batch, keyed by scanned-page id and
    /// retained only while the photo review is open, so manual crop corrections can
    /// re-extract each photo from the correct sheet at full quality.
    private var photoSourceImages: [UUID: CGImage] = [:]

    /// The full-resolution page a detected photo was extracted from (nil once the
    /// review is closed).
    public func photoSource(for photo: DetectedPhoto) -> CGImage? {
        photo.sourcePageID.flatMap { photoSourceImages[$0] }
    }

    @Published public private(set) var isBusy = false
    @Published public private(set) var progress: ScanProgress?
    @Published public internal(set) var statusMessage = "Looking for scanners…"
    @Published public var errorMessage: String?
    @Published public private(set) var lastSavedURLs: [URL] = []

    @Published public private(set) var presets: [Preset] = []

    /// No settings were saved before this start: the app opens on the start screen.
    public let isFirstRun: Bool
    /// Where the user is in the active task; nil without one (see AppState+Tasks.swift).
    @Published public internal(set) var taskFlow: TaskFlow?
    /// The task `taskFlow` was made for.
    var flowTask: ScanTask?

    // MARK: Private

    private let backends: [any ScannerBackend]
    private let presetStore: PresetStore
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
    private var switchGeneration = 0
    private var settingsSaveTask: Task<Void, Never>?
    /// The current exclusive operation's cancel flag (nil when idle).
    private var currentCancelFlag: CancelFlag?

    /// Image shown in the preview canvas.
    public var canvasImage: CGImage? { overviewImage ?? lastScanImage }

    public static let fallbackResolutions = [75, 150, 200, 300, 600, 1200]

    public init(backends: [any ScannerBackend]? = nil, presetStore: PresetStore = PresetStore()) {
        let saved = SettingsStore.load()
        self.isFirstRun = saved == nil
        // A task saved last time is still active: its banner comes back with the settings.
        var initial = saved ?? ScanSettings()
        if let task = initial.task, !TaskCatalog.fits(task, initial) { initial.taskId = nil }
        self.settings = initial
        self.backends = backends ?? [ICScannerBackend(), MockScannerBackend()]
        self.presetStore = presetStore
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

    // MARK: Devices

    public func start() {
        for backend in backends {
            backend.onDevicesChanged = { [weak self] in self?.mergeDevices() }
            backend.startBrowsing()
        }
        mergeDevices()
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
                    // operation or an open photo review, whose pixels no longer need the
                    // scanner, so wait for those to end (endOfWork re-runs this merge).
                    if isBusy || showPhotoReview {
                        connectionSwitchDeferred = true
                    } else {
                        selectDevice(group.primary.id)
                    }
                } else if !userPickedDevice, let real = preferredDefaultDevice(), group.primary.isDemo,
                          deviceGroups.first(where: { $0.primary.id == real })?.primary.isDemo == false {
                    // A real scanner appeared while we were auto-parked on the demo device.
                    selectDevice(real)
                }
            } else if isBusy || showPhotoReview {
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

    /// Re-evaluate a deferred connection switch once nothing is in progress.
    private func endOfWork() {
        guard connectionSwitchDeferred, !isBusy, !showPhotoReview else { return }
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

    /// Writes the raw device names and how they were grouped to
    /// ~/Library/Logs/CompleteScanner/devices.txt whenever they change, so the names real
    /// devices report can be collected to tune `DeviceMerge`. Best effort.
    private func writeDeviceDiagnostics() {
        let report = DeviceMerge.diagnosticsReport(deviceGroups)
        guard report != lastDeviceReport else { return }
        lastDeviceReport = report
        let fileManager = FileManager.default
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let folder = library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("CompleteScanner", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(report.utf8).write(to: folder.appendingPathComponent("devices.txt"), options: .atomic)
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
        // The preview, marquee and detections belong to the previous device's bed.
        overviewImage = nil
        lastScanImage = nil
        lastScanPixelSize = nil
        selectionRect = nil
        detectedPhotos = []
        showPhotoReview = false
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
            // A task the scanner cannot do (the feeder task on a flatbed) ends here.
            let adapted = SettingsAdapter.adapt(settings, to: caps)
            settings = adapted.settings
            statusMessage = Self.withNotes("Ready — \(s.info.name)", adapted.notes)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not connect to \(name)."
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
            self.statusMessage = "Scanning overview…"
            let image = try await session.performOverviewScan(settings: self.settings)
            // Discard results that arrive after the user switched devices.
            guard self.switchGeneration == generation else { return }
            if flag.isCancelled { throw ScanError.cancelled }
            self.overviewImage = image
            self.statusMessage = "Overview ready — drag on the preview to select an area, then Scan."
        }
    }

    public func performScan() {
        guard let session else { return noDevice() }
        let generation = switchGeneration
        runExclusive { flag in
            self.statusMessage = "Scanning…"
            let raw = try await session.performScan(settings: self.settings,
                                                   selection: self.settings.source == .flatbed ? self.selectionRect : nil)
            // Discard results that arrive after the user switched devices.
            guard self.switchGeneration == generation else { return }
            guard !raw.isEmpty else { throw ScanError.scanFailed("The scanner returned no pages.") }
            if flag.isCancelled { throw ScanError.cancelled }
            // A feeder batch cut short (a jam, a dropped connection) still returns its pages;
            // once they are handled the user is told the stack was not finished.
            let stop = session.lastScanStop
            let s = self.settings
            self.statusMessage = "Processing…"
            // Pixel-heavy work runs off the main actor so the UI stays live; the cancel
            // flag is polled between pages.
            let processed: [ScannedPage] = try await Task.detached(priority: .userInitiated) {
                var result: [ScannedPage] = []
                for page in raw {
                    if flag.isCancelled { throw ScanError.cancelled }
                    if s.adjustments.isIdentity && s.colorMode == .color {
                        result.append(page)
                        continue
                    }
                    let adjusted = ImagePipeline.apply(s.adjustments, to: page.image, colorMode: s.colorMode)
                    result.append(ScannedPage(image: adjusted, dpi: page.dpi, colorMode: s.colorMode,
                                              id: page.id, createdAt: page.createdAt))
                }
                return result
            }.value
            guard self.switchGeneration == generation else { return }
            if flag.isCancelled { throw ScanError.cancelled }

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

            // Record every scanned page in the session history (small previews only).
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

            switch TaskCatalog.flow(of: s) {
            case .documentQueue:
                if s.documentMultiPage {
                    // Spill full-resolution pages to disk; keep only previews in the queue.
                    let spooled = await Task.detached(priority: .userInitiated) {
                        Self.spoolPages(processed)
                    }.value
                    guard self.switchGeneration == generation else {
                        self.deleteSpoolFiles(of: spooled)
                        return
                    }
                    self.scannedPages.append(contentsOf: spooled)
                    self.recordCaptures(spooled.map(\.id))
                    self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                    let n = processed.count
                    self.statusMessage = "Added \(n) page\(n == 1 ? "" : "s") — \(self.scannedPages.count) in queue. Scan more or Save PDF."
                } else {
                    self.setLastScan(preview: rawPreview, pixelSize: rawPixelSize)
                    try await self.saveImmediately(processed, flag: flag)
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
                self.recordCaptures(found.map(\.id))
                self.showPhotoReview = !found.isEmpty
                self.statusMessage = "Found \(found.count) photo\(found.count == 1 ? "" : "s") on the bed."
            }
            if let stop {
                self.errorMessage = stop.message(pagesKept: raw.count)
            }
        }
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
                .map { DetectedPhoto(region: region, image: $0, dpi: page.dpi, sourcePageID: page.id) }
        }
    }

    private nonisolated static func wholePagePhoto(_ page: ScannedPage) -> DetectedPhoto {
        let w = CGFloat(page.image.width), h = CGFloat(page.image.height)
        let region = DetectedPhotoRegion(center: CGPoint(x: w / 2, y: h / 2),
                                         size: CGSize(width: w, height: h), angleDegrees: 0)
        return DetectedPhoto(region: region, image: page.image, dpi: page.dpi, sourcePageID: page.id)
    }

    public func cancelScan() {
        // Stop the hardware if it's mid-scan, AND flag the software phases
        // (processing, OCR, PDF build, exports) — either may be the one running.
        session?.cancelScan()
        currentCancelFlag?.cancel()
    }

    // MARK: Saving

    public func savePDF() {
        guard !scannedPages.isEmpty else { return }
        let pages = scannedPages
        let s = settings
        runExclusive { flag in
            self.statusMessage = s.pdfSearchable ? "Running OCR and building PDF…" : "Building PDF…"
            let url = try self.outputURL(fileExtension: "pdf")
            try await Task.detached(priority: .userInitiated) {
                try Self.writePDFAtomically(pages: pages, searchable: s.pdfSearchable,
                                            languages: s.ocrLanguages, to: url,
                                            shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            }.value
            self.lastSavedURLs = [url]
            self.deleteSpoolFiles(of: pages)
            self.scannedPages = []
            self.taskFlow?.reset()
            self.statusMessage = "Saved \(pages.count)-page PDF: \(url.lastPathComponent)"
        }
    }

    /// Used when documentMultiPage is off: write each scan to disk as soon as it lands.
    private func saveImmediately(_ pages: [ScannedPage], flag: CancelFlag) async throws {
        let s = settings
        var saved: [URL] = []
        if s.format == .pdf {
            let url = try outputURL(fileExtension: "pdf")
            try await Task.detached(priority: .userInitiated) {
                try Self.writePDFAtomically(pages: pages, searchable: s.pdfSearchable,
                                            languages: s.ocrLanguages, to: url,
                                            shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            }.value
            saved = [url]
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
        statusMessage = "Saved \(saved.map(\.lastPathComponent).joined(separator: ", "))"
    }

    public func saveReviewedPhotos() {
        let photos = detectedPhotos.filter(\.included)
        guard !photos.isEmpty else { return cancelPhotoReview() }
        let s = settings
        let format: OutputFormat = s.format == .pdf ? .jpeg : s.format
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
            self.taskFlow?.reset()
            self.statusMessage = "Saved \(saved.count) photo\(saved.count == 1 ? "" : "s") to \(s.destinationPath)"
        }
    }

    public func cancelPhotoReview() {
        detectedPhotos = []
        showPhotoReview = false
        photoSourceImages = [:]
        taskFlow?.reset()
        statusMessage = "Photo batch discarded."
        endOfWork()
    }

    /// Manual crop correction from the review sheet: re-extract one photo from its
    /// (full-resolution) source page with a user-adjusted region. The extraction runs
    /// off the main actor — at high dpi it renders hundreds of MB of pixels.
    public func recropPhoto(id: UUID, region: DetectedPhotoRegion) {
        guard !isBusy else { return }
        guard let photo = detectedPhotos.first(where: { $0.id == id }),
              let source = photoSource(for: photo) else { return }
        let deskew = settings.photoAutoDeskew
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                PhotoDetector.extractPhoto(from: source, region: region, deskew: deskew)
            }.value
            guard let self, let image, !self.isBusy,
                  let idx = self.detectedPhotos.firstIndex(where: { $0.id == id }) else { return }
            let old = self.detectedPhotos[idx]
            var updated = DetectedPhoto(region: region, image: image, dpi: old.dpi,
                                        id: old.id, sourcePageID: old.sourcePageID)
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

    private func setLastScan(preview: CGImage?, pixelSize: CGSize?) {
        lastScanImage = preview
        lastScanPixelSize = pixelSize
    }

    /// Rotate a queued page 90° clockwise. The in-memory preview is rotated right away
    /// (the strip thumbnail follows it); the full-resolution spool file stays untouched
    /// and PDFBuilder applies the accumulated rotation at save time.
    public func rotatePage(id: UUID) {
        guard !isBusy else { return }
        guard let idx = scannedPages.firstIndex(where: { $0.id == id }) else { return }
        let page = scannedPages[idx]
        var updated = ScannedPage(image: ImagePipeline.rotate(page.image, quarterTurns: 1),
                                  dpi: page.dpi, colorMode: page.colorMode,
                                  id: page.id, createdAt: page.createdAt,
                                  fileURL: page.fileURL, fullPixelSize: page.fullPixelSize)
        updated.rotationQuarterTurns = (page.rotationQuarterTurns + 1) % 4
        scannedPages[idx] = updated
    }

    public func clearPages() {
        guard !isBusy else { return }
        deleteSpoolFiles(of: scannedPages)
        scannedPages = []
        taskFlow?.reset()
        statusMessage = "Page queue cleared."
    }

    // MARK: Presets

    /// Replaces the settings with the preset's, fitted to the connected scanner. A preset saved
    /// while a task was active brings that task (and its banner) back.
    public func applyPreset(_ preset: Preset) {
        let adapted = SettingsAdapter.adapt(preset.settings, to: capabilities)
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
    /// fully in memory instead.
    private nonisolated static func spoolPages(_ pages: [ScannedPage]) -> [ScannedPage] {
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
            return ScannedPage(image: preview, dpi: page.dpi, colorMode: page.colorMode,
                               id: page.id, createdAt: page.createdAt, fileURL: url,
                               fullPixelSize: CGSize(width: page.image.width, height: page.image.height))
        }
    }

    private nonisolated static func makePreview(_ image: CGImage, maxSide: Int) -> CGImage? {
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

    /// Write the PDF to a hidden temp name and move it into place, so a failed
    /// or interrupted build never leaves a truncated PDF at the destination.
    private nonisolated static func writePDFAtomically(pages: [ScannedPage], searchable: Bool,
                                                       languages: [String], to url: URL,
                                                       shouldContinue: (() -> Bool)? = nil,
                                                       progress: ((String) -> Void)?) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pdf.tmp")
        do {
            try PDFBuilder.writePDF(pages: pages, searchable: searchable, ocrLanguages: languages,
                                    to: tmp, progress: progress, shouldContinue: shouldContinue)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private func deleteSpoolFiles(of pages: [ScannedPage]) {
        for page in pages {
            if let url = page.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func destinationDirectory() throws -> URL {
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

    private func outputURL(fileExtension: String, index: Int? = nil) throws -> URL {
        let dir = try destinationDirectory()
        let base = NamingTemplate(settings.namingTemplate)
            .baseFilename(NamingContext(counter: nextCounter(), date: Date(), intent: settings.intent,
                                        index: index, task: TaskCatalog.infer(settings)))
        return NamingTemplate.uniqueURL(in: dir, base: base, fileExtension: fileExtension)
    }

    /// Run one long operation at a time; surface errors; manage busy state. The
    /// operation receives a CancelFlag it must poll between heavy work units.
    private func runExclusive(_ operation: @escaping (CancelFlag) async throws -> Void) {
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
            }
            currentCancelFlag = nil
            progress = nil
            isBusy = false
            endOfWork()
        }
    }
}
