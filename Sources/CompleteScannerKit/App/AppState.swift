import AppKit
import Combine
import CoreGraphics
import Foundation

/// Where document pages are spilled to disk while they wait in the queue,
/// so a long high-dpi batch doesn't hold gigabytes of pixels in memory.
private let pageSpoolDirectory: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("CompleteScanner-pages", isDirectory: true)

/// Central controller: owns backends, the open scanner session, settings, scan results,
/// and every user-triggered operation. All UI binds to this object.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Published state

    @Published public private(set) var devices: [ScannerInfo] = []
    @Published public private(set) var selectedDeviceID: String?
    @Published public private(set) var capabilities: ScannerCapabilities?
    @Published public var settings: ScanSettings {
        didSet { scheduleSettingsSave() }
    }

    /// Low-res preview of the full bed; the selection marquee is only valid over this image.
    @Published public private(set) var overviewImage: CGImage?
    /// The most recent full scan (shown in the canvas when there is no overview).
    @Published public private(set) var lastScanImage: CGImage?
    /// Normalized (0...1) crop rect within the flatbed, origin top-left. nil = full bed.
    @Published public var selectionRect: CGRect?

    @Published public private(set) var scannedPages: [ScannedPage] = []
    @Published public var detectedPhotos: [DetectedPhoto] = []
    @Published public var showPhotoReview = false

    @Published public private(set) var isBusy = false
    @Published public private(set) var progress: ScanProgress?
    @Published public private(set) var statusMessage = "Looking for scanners…"
    @Published public var errorMessage: String?
    @Published public private(set) var lastSavedURLs: [URL] = []

    @Published public private(set) var presets: [Preset] = []

    // MARK: Private

    private let backends: [any ScannerBackend]
    private let presetStore: PresetStore
    private var session: (any ScannerSession)?
    private var sessionDeviceID: String?
    private var userPickedDevice = false
    /// Device switches are serialized through this chain; concurrent clicks
    /// must never interleave open/close on hardware sessions.
    private var switchTask: Task<Void, Never>?
    private var switchGeneration = 0
    private var settingsSaveTask: Task<Void, Never>?

    /// Image shown in the preview canvas.
    public var canvasImage: CGImage? { overviewImage ?? lastScanImage }

    public static let fallbackResolutions = [75, 150, 200, 300, 600, 1200]

    public init(backends: [any ScannerBackend]? = nil, presetStore: PresetStore = PresetStore()) {
        self.settings = SettingsStore.load() ?? ScanSettings()
        self.backends = backends ?? [ICScannerBackend(), MockScannerBackend()]
        self.presetStore = presetStore
        self.presets = presetStore.load()
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

    private func mergeDevices() {
        devices = backends.flatMap { $0.devices }
        if let sel = selectedDeviceID {
            if !devices.contains(where: { $0.id == sel }) {
                userPickedDevice = false
                selectDevice(preferredDefaultDevice())
            } else if !userPickedDevice, let real = preferredDefaultDevice(),
                      devices.first(where: { $0.id == sel })?.isDemo == true,
                      devices.first(where: { $0.id == real })?.isDemo == false {
                // A real scanner appeared while we were auto-parked on the demo device.
                selectDevice(real)
            }
        } else if let def = preferredDefaultDevice() {
            selectDevice(def)
        }
    }

    private func preferredDefaultDevice() -> String? {
        (devices.first(where: { !$0.isDemo }) ?? devices.first)?.id
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
        selectionRect = nil
        detectedPhotos = []
        showPhotoReview = false

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
            settings.resolution = caps.nearestResolution(to: settings.resolution)
            if !caps.sources.contains(settings.source) {
                settings.source = caps.sources.first ?? .flatbed
            }
            statusMessage = "Ready — \(s.info.name)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not connect to \(name)."
        }
    }

    // MARK: Scanning

    public func performOverview() {
        guard let session else { return noDevice() }
        let generation = switchGeneration
        runExclusive {
            self.statusMessage = "Scanning overview…"
            let image = try await session.performOverviewScan(settings: self.settings)
            // Discard results that arrive after the user switched devices.
            guard self.switchGeneration == generation else { return }
            self.overviewImage = image
            self.statusMessage = "Overview ready — drag on the preview to select an area, then Scan."
        }
    }

    public func performScan() {
        guard let session else { return noDevice() }
        let generation = switchGeneration
        runExclusive {
            self.statusMessage = "Scanning…"
            let raw = try await session.performScan(settings: self.settings,
                                                   selection: self.settings.source == .flatbed ? self.selectionRect : nil)
            // Discard results that arrive after the user switched devices.
            guard self.switchGeneration == generation else { return }
            guard !raw.isEmpty else { throw ScanError.scanFailed("The scanner returned no pages.") }
            let s = self.settings
            self.statusMessage = "Processing…"
            // Pixel-heavy work runs off the main actor so the UI stays live.
            let processed: [ScannedPage] = await Task.detached(priority: .userInitiated) {
                raw.map { page in
                    if s.adjustments.isIdentity && s.colorMode == .color { return page }
                    let adjusted = ImagePipeline.apply(s.adjustments, to: page.image, colorMode: s.colorMode)
                    return ScannedPage(image: adjusted, dpi: page.dpi, colorMode: s.colorMode,
                                       id: page.id, createdAt: page.createdAt)
                }
            }.value
            guard self.switchGeneration == generation else { return }

            switch s.intent {
            case .document:
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
                    self.lastScanImage = spooled.last?.image
                    let n = processed.count
                    self.statusMessage = "Added \(n) page\(n == 1 ? "" : "s") — \(self.scannedPages.count) in queue. Scan more or Save PDF."
                } else {
                    self.lastScanImage = processed.last?.image
                    try await self.saveImmediately(processed)
                }
            case .photo:
                // Full resolution here: the detection overlay maps source-pixel
                // coordinates onto this image.
                self.lastScanImage = processed.last?.image
                let found: [DetectedPhoto] = await Task.detached(priority: .userInitiated) {
                    processed.flatMap { Self.splitPhotos(from: $0, settings: s) }
                }.value
                guard self.switchGeneration == generation else { return }
                self.detectedPhotos = found
                self.showPhotoReview = !found.isEmpty
                self.statusMessage = "Found \(found.count) photo\(found.count == 1 ? "" : "s") on the bed."
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
                .map { DetectedPhoto(region: region, image: $0, dpi: page.dpi) }
        }
    }

    private nonisolated static func wholePagePhoto(_ page: ScannedPage) -> DetectedPhoto {
        let w = CGFloat(page.image.width), h = CGFloat(page.image.height)
        let region = DetectedPhotoRegion(center: CGPoint(x: w / 2, y: h / 2),
                                         size: CGSize(width: w, height: h), angleDegrees: 0)
        return DetectedPhoto(region: region, image: page.image, dpi: page.dpi)
    }

    public func cancelScan() {
        session?.cancelScan()
    }

    // MARK: Saving

    public func savePDF() {
        guard !scannedPages.isEmpty else { return }
        let pages = scannedPages
        let s = settings
        runExclusive {
            self.statusMessage = s.pdfSearchable ? "Running OCR and building PDF…" : "Building PDF…"
            let url = try self.outputURL(fileExtension: "pdf")
            try await Task.detached(priority: .userInitiated) {
                try Self.writePDFAtomically(pages: pages, searchable: s.pdfSearchable,
                                            languages: s.ocrLanguages, to: url) { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            }.value
            self.lastSavedURLs = [url]
            self.deleteSpoolFiles(of: pages)
            self.scannedPages = []
            self.statusMessage = "Saved \(pages.count)-page PDF: \(url.lastPathComponent)"
        }
    }

    /// Used when documentMultiPage is off: write each scan to disk as soon as it lands.
    private func saveImmediately(_ pages: [ScannedPage]) async throws {
        let s = settings
        var saved: [URL] = []
        if s.format == .pdf {
            let url = try outputURL(fileExtension: "pdf")
            try await Task.detached(priority: .userInitiated) {
                try Self.writePDFAtomically(pages: pages, searchable: s.pdfSearchable,
                                            languages: s.ocrLanguages, to: url) { [weak self] msg in
                    Task { @MainActor in self?.statusMessage = msg }
                }
            }.value
            saved = [url]
        } else {
            for page in pages {
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
        runExclusive {
            var saved: [URL] = []
            for (index, photo) in photos.enumerated() {
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
            self.statusMessage = "Saved \(saved.count) photo\(saved.count == 1 ? "" : "s") to \(s.destinationPath)"
        }
    }

    public func cancelPhotoReview() {
        detectedPhotos = []
        showPhotoReview = false
        statusMessage = "Photo batch discarded."
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

    public func clearPages() {
        guard !isBusy else { return }
        deleteSpoolFiles(of: scannedPages)
        scannedPages = []
        statusMessage = "Page queue cleared."
    }

    // MARK: Presets

    public func applyPreset(_ preset: Preset) {
        var s = preset.settings
        if let caps = capabilities {
            s.resolution = caps.nearestResolution(to: s.resolution)
            if !caps.sources.contains(s.source) { s.source = caps.sources.first ?? .flatbed }
        }
        settings = s
        statusMessage = "Applied preset “\(preset.name)”."
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
                                                       progress: ((String) -> Void)?) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pdf.tmp")
        do {
            try PDFBuilder.writePDF(pages: pages, searchable: searchable, ocrLanguages: languages,
                                    to: tmp, progress: progress)
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
            .baseFilename(counter: nextCounter(), date: Date(), intent: settings.intent, index: index)
        return NamingTemplate.uniqueURL(in: dir, base: base, fileExtension: fileExtension)
    }

    /// Run one long operation at a time; surface errors; manage busy state.
    private func runExclusive(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do {
                try await operation()
            } catch ScanError.cancelled {
                statusMessage = "Cancelled."
            } catch is CancellationError {
                statusMessage = "Cancelled."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Ready."
            }
            progress = nil
            isBusy = false
        }
    }
}
