import CoreGraphics
import Foundation
import ImageCaptureCore
import ImageIO
import UniformTypeIdentifiers

/// Real scanner hardware via ImageCaptureCore.
///
/// Browses local USB, Bonjour and shared scanners with `ICDeviceBrowser` and
/// opens sessions on `ICScannerDevice`s. Every ImageCaptureCore delegate
/// callback pair is bridged to async/await with a `CheckedContinuation` that
/// is resumed exactly once.
public final class ICScannerBackend: NSObject, ScannerBackend, ICDeviceBrowserDelegate {

    public var onDevicesChanged: (() -> Void)?
    public private(set) var devices: [ScannerInfo] = []

    private var browser: ICDeviceBrowser?
    private var scannersByID: [String: ICScannerDevice] = [:]
    /// Re-kicks enumeration while no scanner is visible — some drivers never deliver
    /// `didAdd` for a device plugged in after browsing started.
    private var replugWatchdog: Task<Void, Never>?
    /// Backoff between watchdog re-browses. Long enough that a slow Bonjour/shared
    /// enumeration (which can take several seconds) always finishes before a restart
    /// could discard it; doubled after each fruitless restart, reset on discovery.
    private static let initialRebrowseDelay: UInt64 = 10_000_000_000
    private var rebrowseDelay: UInt64 = ICScannerBackend.initialRebrowseDelay

    public override init() {
        super.init()
    }

    // MARK: - ScannerBackend

    public func startBrowsing() {
        guard browser == nil else { return }
        startBrowser()
        rebrowseDelay = Self.initialRebrowseDelay
        replugWatchdog?.cancel()
        replugWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.rebrowseDelay else { return }
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                if self.devices.isEmpty, self.browser != nil {
                    // Only restart while nothing was found: a restart while a session
                    // is open would tear the device out from under it.
                    self.restartBrowser()
                    self.rebrowseDelay = min(self.rebrowseDelay * 2, 60_000_000_000)
                } else {
                    self.rebrowseDelay = Self.initialRebrowseDelay
                }
            }
        }
    }

    public func stopBrowsing() {
        replugWatchdog?.cancel()
        replugWatchdog = nil
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        guard !devices.isEmpty || !scannersByID.isEmpty else { return }
        scannersByID = [:]
        devices = []
        onDevicesChanged?()
    }

    private func startBrowser() {
        let b = ICDeviceBrowser()
        b.delegate = self
        b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue
                | ICDeviceLocationTypeMask.local.rawValue
                | ICDeviceLocationTypeMask.bonjour.rawValue
                | ICDeviceLocationTypeMask.shared.rawValue)!
        browser = b
        b.start()
    }

    private func restartBrowser() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        startBrowser()
    }

    public func openSession(deviceID: String) async throws -> any ScannerSession {
        guard let device = scannersByID[deviceID] else {
            throw ScanError.deviceUnavailable("The selected scanner is not connected.")
        }
        let info = devices.first(where: { $0.id == deviceID }) ?? Self.makeInfo(for: device)
        let session = ICHardwareScannerSession(device: device, info: info)
        try await session.open()
        return session
    }

    // MARK: - ICDeviceBrowserDelegate

    public nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        performOnMainActor {
            // Ignore stragglers from a browser the watchdog already tore down — they
            // would register a device object no didRemove will ever clean up.
            guard browser === self.browser else { return }
            self.register(scanner)
        }
    }

    public nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        performOnMainActor {
            guard browser === self.browser else { return }
            self.unregister(scanner)
        }
    }

    // MARK: - Device bookkeeping

    private func register(_ scanner: ICScannerDevice) {
        let info = Self.makeInfo(for: scanner)
        scannersByID[info.id] = scanner
        if let idx = devices.firstIndex(where: { $0.id == info.id }) {
            devices[idx] = info
        } else {
            devices.append(info)
        }
        onDevicesChanged?()
    }

    private func unregister(_ scanner: ICScannerDevice) {
        guard let id = scannersByID.first(where: { $0.value === scanner })?.key else { return }
        scannersByID[id] = nil
        devices.removeAll { $0.id == id }
        onDevicesChanged?()
    }

    private static func makeInfo(for device: ICScannerDevice) -> ScannerInfo {
        let name = device.name ?? "Scanner"
        let id = device.uuidString ?? name
        let raw = device.type.rawValue
        let transport: String
        if raw & ICDeviceLocationTypeMask.local.rawValue != 0 {
            transport = "USB"
        } else if raw & ICDeviceLocationTypeMask.shared.rawValue != 0 {
            transport = "Shared"
        } else {
            transport = "Network"
        }
        // The model is the name the device reports. ImageCaptureCore gives every connection its
        // own uuidString, so it identifies the entry, not the physical scanner (no hardwareID).
        return ScannerInfo(id: id, name: name, transport: transport, backend: "ic", model: device.name)
    }
}

// MARK: - Session

/// One open ImageCaptureCore scanner session. All state lives on the main
/// actor; delegate callbacks (which ImageCaptureCore delivers on the main
/// thread) are funneled back onto it before touching any state.
@MainActor
private final class ICHardwareScannerSession: NSObject, ScannerSession, ICScannerDeviceDelegate {

    let info: ScannerInfo
    var progressHandler: ((ScanProgress) -> Void)?
    private(set) var lastScanStop: ScanStop?
    private(set) var lastScanDuplex: Bool?
    /// ImageCaptureCore reports two-sided feeding on the feeder unit, once it is selected.
    var feederDuplexNeedsSelection: Bool { true }

    private let device: ICScannerDevice

    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var selectContinuation: CheckedContinuation<Void, Error>?
    private var overviewContinuation: CheckedContinuation<CGImage, Error>?
    private var scanContinuation: CheckedContinuation<[URL], Error>?

    private var scannedURLs: [URL] = []
    private var cancelRequested = false
    private var isClosing = false

    init(device: ICScannerDevice, info: ScannerInfo) {
        self.device = device
        self.info = info
        super.init()
    }

    // MARK: Open / close

    func open() async throws {
        device.delegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation
            // A sleeping or vanished network scanner may never answer
            // requestOpenSession while the browser still lists it; rescue the
            // continuation so the connect flow cannot hang forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.openContinuation != nil else { return }
                self.device.delegate = nil
                self.resumeOpen(.failure(ScanError.deviceUnavailable("\(self.info.name) did not respond.")))
            }
            device.requestOpenSession()
        }
    }

    func close() async {
        guard !isClosing else { return }
        isClosing = true
        failPendingWork(with: ScanError.sessionFailed("The session was closed."))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closeContinuation = continuation
            // Do not hang forever if the device never answers: race a 3s timeout.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.resumeClose()
            }
            device.requestCloseSession()
        }
        device.delegate = nil
    }

    func cancelScan() {
        cancelRequested = true
        device.cancelScan()
    }

    // MARK: Capabilities

    func capabilities() async throws -> ScannerCapabilities {
        var caps = ScannerCapabilities()

        var sources: [ScanSource] = []
        for number in device.availableFunctionalUnitTypes {
            switch ICScannerFunctionalUnitType(rawValue: number.uintValue) {
            case .some(.flatbed):
                if !sources.contains(.flatbed) { sources.append(.flatbed) }
            case .some(.documentFeeder):
                if !sources.contains(.documentFeeder) { sources.append(.documentFeeder) }
            default:
                break
            }
        }
        if sources.isEmpty { sources = [.flatbed] }
        caps.sources = sources
        caps.supportsOverview = sources.contains(.flatbed)

        // A combo flatbed/ADF device may open with the feeder selected; report
        // the flatbed's size and resolution list, not the ADF path's.
        if sources.contains(.flatbed) {
            try? await selectFunctionalUnit(.flatbed)
        }
        let unit = device.selectedFunctionalUnit
        let resolutions = Self.resolutionList(for: unit)
        if !resolutions.isEmpty { caps.supportedResolutions = resolutions }

        unit.measurementUnit = .inches
        let physical = unit.physicalSize
        if physical.width > 0, physical.height > 0 {
            caps.flatbedSizeInches = CGSize(width: physical.width, height: physical.height)
        }
        return caps
    }

    /// Whether the feeder scans both sides: ImageCaptureCore reports it on the feeder unit, so
    /// the feeder is selected (and stays selected, since the app is about to use it). nil while
    /// another operation runs, without a feeder, or when the scanner does not answer.
    func feederSupportsDuplex() async -> Bool? {
        guard !isClosing, openContinuation == nil, selectContinuation == nil,
              overviewContinuation == nil, scanContinuation == nil,
              device.availableFunctionalUnitTypes.contains(NSNumber(value: ICScannerFunctionalUnitType.documentFeeder.rawValue))
        else { return nil }
        do {
            try await selectFunctionalUnit(.documentFeeder)
        } catch {
            return nil
        }
        return (device.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning
    }

    /// The ImageCaptureCore document type of a paper size (`ICScannerDocumentType` raw values,
    /// which follow TWAIN's paper sizes); nil for Automatic and the ID card, which has none.
    private static func documentType(for size: PaperSize) -> ICScannerDocumentType? {
        let raw: UInt
        switch size {
        case .auto, .idCard: return nil
        case .a4: raw = 1
        case .b5Jis: raw = 2
        case .letter: raw = 3
        case .legal: raw = 4
        case .a5: raw = 5
        case .executive: raw = 10
        case .a6: raw = 13
        }
        return ICScannerDocumentType(rawValue: raw)
    }

    // MARK: Overview scan

    func performOverviewScan(settings: ScanSettings) async throws -> CGImage {
        try ensureIdle()
        cancelRequested = false
        try await selectFunctionalUnit(.flatbed)

        let unit = device.selectedFunctionalUnit
        unit.measurementUnit = .inches
        if let lowest = unit.supportedResolutions.sorted().first(where: { $0 >= 150 }) {
            unit.overviewResolution = lowest
        }

        guard !cancelRequested else { throw ScanError.cancelled }
        progressHandler?(ScanProgress(message: "Warming up…"))
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            overviewContinuation = continuation
            device.requestOverviewScan()
        }
    }

    // MARK: Scan

    func performScan(settings: ScanSettings, selection: CGRect?) async throws -> [ScannedPage] {
        try ensureIdle()
        cancelRequested = false
        scannedURLs = []
        lastScanStop = nil
        lastScanDuplex = nil

        let unitType: ICScannerFunctionalUnitType = settings.source == .documentFeeder ? .documentFeeder : .flatbed
        try await selectFunctionalUnit(unitType)

        let unit = device.selectedFunctionalUnit
        unit.measurementUnit = .inches

        // The feeder: both sides when asked for and it can, the paper size, and the order it
        // delivers the sheets in. Back sides are turned upright by the app (DocumentSides), not
        // through evenPageOrientation, so both platforms treat them the same.
        var twoSided = false
        var reverseOrder = false
        if unitType == .documentFeeder, let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            twoSided = settings.duplex == .both && feeder.supportsDuplexScanning
            feeder.duplexScanningEnabled = twoSided
            if let type = Self.documentType(for: settings.paperSize) {
                feeder.documentType = type
            }
            reverseOrder = feeder.reverseFeederPageOrder
        }
        // A feeder that scans one side says so, so the app does not take its pages for pairs.
        if unitType == .documentFeeder && settings.duplex == .both { lastScanDuplex = twoSided }

        let dpi = unit.supportedResolutions.sorted()
            .min(by: { abs($0 - settings.resolution) < abs($1 - settings.resolution) }) ?? settings.resolution
        unit.resolution = dpi

        switch settings.colorMode {
        case .color:
            unit.pixelDataType = .RGB
            unit.bitDepth = .depth8Bits
        case .grayscale:
            unit.pixelDataType = .gray
            unit.bitDepth = .depth8Bits
        case .blackWhite:
            unit.pixelDataType = .BW
            unit.bitDepth = .depth1Bit
        }

        // Scan area in inches. The selection is a normalized rect of the bed
        // with a top-left origin; scale it by the physical bed size.
        let bed = unit.physicalSize
        if bed.width > 0, bed.height > 0 {
            var areaInches = CGRect(x: 0, y: 0, width: bed.width, height: bed.height)
            if unitType == .documentFeeder {
                areaInches = PaperSizes.feederRegionInches(settings.paperSize, max: bed)
            }
            if unitType == .flatbed, let selection {
                let clamped = selection.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if clamped.width > 0.001, clamped.height > 0.001 {
                    areaInches = CGRect(x: clamped.origin.x * bed.width,
                                        y: clamped.origin.y * bed.height,
                                        width: clamped.width * bed.width,
                                        height: clamped.height * bed.height)
                }
            }
            unit.scanArea = areaInches
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompleteScanner-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            throw ScanError.scanFailed("Could not create a download folder: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        device.transferMode = .fileBased
        device.downloadsDirectory = tempDir
        device.documentName = "scan"
        device.documentUTI = UTType.tiff.identifier

        // Cancel pressed during functional-unit selection/warm-up must not
        // kick off the full scan anyway.
        guard !cancelRequested else { throw ScanError.cancelled }
        progressHandler?(ScanProgress(message: "Scanning…"))
        let urls = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URL], Error>) in
            scanContinuation = continuation
            device.requestScan()
        }

        var pages: [ScannedPage] = []
        for url in urls {
            if let image = Self.loadImage(at: url) {
                pages.append(ScannedPage(image: image, dpi: dpi, colorMode: settings.colorMode))
            }
            try? FileManager.default.removeItem(at: url)
        }
        guard !pages.isEmpty else {
            throw ScanError.scanFailed("The scanner did not return any image data.")
        }
        // A feeder that reads the last sheet first: back into reading order, each sheet's front
        // before its back, as the app expects of every backend.
        if reverseOrder {
            pages = DocumentSides.assignSides(transferCount: pages.count, duplex: twoSided, reverseOrder: true)
                .map { pages[$0.transferIndex] }
        }
        return pages
    }

    // MARK: Helpers

    /// The resolutions this device really offers, up to and including its true maximum.
    ///
    /// Accuracy rules, in order:
    /// 1. `preferredResolutions` — when the driver provides it, that IS the device's
    ///    accurate list (it's what Image Capture shows); use it verbatim.
    /// 2. Otherwise `supportedResolutions`: a small discrete set is used as-is; a huge
    ///    contiguous range (thousands of values) is thinned to the standard ladder.
    /// In both fallback shapes, values above `nativeXResolution` (the optical
    /// resolution) are software interpolation, not hardware capability — they are
    /// dropped so the picker never advertises resolutions the scanner can't deliver.
    private static func resolutionList(for unit: ICScannerFunctionalUnit) -> [Int] {
        let native = Int(unit.nativeXResolution)

        let preferred = unit.preferredResolutions
        if !preferred.isEmpty {
            return preferred.sorted()
        }

        let supported = unit.supportedResolutions
        guard let minDPI = supported.min(), let maxDPI = supported.max() else { return [] }

        var set = Set<Int>()
        if supported.count <= 64 {
            // A discrete list (even a generous one): offer every reported value.
            set.formUnion(supported)
        } else {
            let ladder = [50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800,
                          1200, 1600, 2400, 3200, 4800, 6400, 9600, 12800]
            set.formUnion(ladder.filter { supported.contains($0) })
            set.insert(minDPI)
            set.insert(maxDPI)
        }
        if native > 0 {
            set = set.filter { $0 <= native }
            if supported.contains(native) { set.insert(native) }
        }
        return set.sorted()
    }

    private func ensureIdle() throws {
        guard !isClosing else { throw ScanError.sessionFailed("The session is closed.") }
        guard openContinuation == nil, selectContinuation == nil,
              overviewContinuation == nil, scanContinuation == nil else {
            throw ScanError.scanFailed("Another scan is already in progress.")
        }
    }

    private func selectFunctionalUnit(_ type: ICScannerFunctionalUnitType) async throws {
        guard device.selectedFunctionalUnit.type != type else { return }
        guard device.availableFunctionalUnitTypes.contains(NSNumber(value: type.rawValue)) else {
            throw ScanError.unsupported("This scanner has no \(type == .documentFeeder ? "document feeder" : "flatbed").")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            selectContinuation = continuation
            // Same rescue as open(): a sleeping device may never answer
            // requestSelect, and this runs inside the app's serialized
            // device-switch chain — it must not wedge forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.selectContinuation != nil else { return }
                self.resumeSelect(.failure(ScanError.deviceUnavailable(
                    "\(self.info.name) did not respond while switching scan source.")))
            }
            device.requestSelect(type)
        }
    }

    private nonisolated static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let lazy = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        // The image source decodes pixels from the file lazily — on first DRAW, not now —
        // and the caller deletes the scan file right after this returns. A lazy image
        // would then decode to nothing (blank previews, blank PDFs). Render it into an
        // owned bitmap immediately so the pixels live in memory, not in the file.
        return materialized(lazy) ?? lazy
    }

    /// Copy of `image` backed by memory instead of a file. Grayscale/1-bit sources stay
    /// 8-bit gray so a big text scan doesn't inflate to 4-byte RGBA; everything else
    /// becomes standard 8-bit sRGB.
    private nonisolated static func materialized(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let ctx: CGContext?
        if image.bitsPerPixel <= 8, let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        } else {
            ctx = nil
        }
        guard let ctx else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Maps ImageCaptureCore errors to ScanError, turning cancellations into `.cancelled`.
    private func mapScanError(_ error: Error?) -> ScanError {
        guard let error else {
            return cancelRequested ? .cancelled : .scanFailed("An unknown scanner error occurred.")
        }
        let ns = error as NSError
        if ns.domain == ICErrorDomain, let code = ICReturn.Code(rawValue: ns.code) {
            switch code {
            case .scanOperationCanceled, .downloadCanceled, .deleteFilesCanceled:
                return .cancelled
            default:
                break
            }
        }
        if cancelRequested { return .cancelled }
        return .scanFailed(error.localizedDescription)
    }

    // MARK: Continuation plumbing (each resumed exactly once)

    private func resumeOpen(_ result: Result<Void, Error>) {
        guard let continuation = openContinuation else { return }
        openContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeSelect(_ result: Result<Void, Error>) {
        guard let continuation = selectContinuation else { return }
        selectContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeOverview(_ result: Result<CGImage, Error>) {
        guard let continuation = overviewContinuation else { return }
        overviewContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeScan(_ result: Result<[URL], Error>) {
        guard let continuation = scanContinuation else { return }
        scanContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeClose() {
        guard let continuation = closeContinuation else { return }
        closeContinuation = nil
        continuation.resume()
    }

    private func failPendingWork(with error: ScanError) {
        resumeOpen(.failure(error))
        resumeSelect(.failure(error))
        resumeOverview(.failure(error))
        resumeScan(.failure(error))
    }

    // MARK: ICDeviceDelegate

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        performOnMainActor {
            if let error {
                self.resumeOpen(.failure(ScanError.sessionFailed(error.localizedDescription)))
            } else {
                self.resumeOpen(.success(()))
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        performOnMainActor {
            self.resumeClose()
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        performOnMainActor {
            self.failPendingWork(with: ScanError.deviceUnavailable("\(self.info.name) was disconnected."))
            self.resumeClose()
        }
    }

    nonisolated func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {
        let state = status[.statusNotificationKey] as? String
        let localized = status[.localizedStatusNotificationKey] as? String
        performOnMainActor {
            let message: String
            if state == ICScannerStatusWarmingUp {
                message = "Warming up…"
            } else if state == ICScannerStatusWarmUpDone {
                message = "Scanning…"
            } else if let localized, !localized.isEmpty {
                message = localized
            } else {
                return
            }
            self.progressHandler?(ScanProgress(message: message))
        }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: Error?) {
        performOnMainActor {
            let mapped = self.mapScanError(error)
            self.failPendingWork(with: mapped)
        }
    }

    // MARK: ICScannerDeviceDelegate

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        performOnMainActor {
            if let error {
                self.resumeSelect(.failure(ScanError.scanFailed(error.localizedDescription)))
            } else {
                self.resumeSelect(.success(()))
            }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        performOnMainActor {
            self.scannedURLs.append(url)
            self.progressHandler?(ScanProgress(message: "Transferring…"))
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
        performOnMainActor {
            if let error {
                self.resumeOverview(.failure(self.mapScanError(error)))
            } else if let image = self.device.selectedFunctionalUnit.overviewImage {
                self.resumeOverview(.success(image))
            } else {
                self.resumeOverview(.failure(ScanError.scanFailed("The scanner returned no overview image.")))
            }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        performOnMainActor {
            if let error {
                let mapped = self.mapScanError(error)
                // A failure mid-batch (e.g. an ADF jam on sheet 20 of 20) must
                // not throw away the sheets that already transferred; keep them
                // and record why the batch stopped (lastScanStop), which the app
                // reports once the pages are handled. Deliberate cancellation
                // still discards.
                if case .scanFailed = mapped, !self.scannedURLs.isEmpty {
                    self.lastScanStop = ScanStop.from(mapped)
                    self.resumeScan(.success(self.scannedURLs))
                } else {
                    self.resumeScan(.failure(mapped))
                }
            } else {
                self.resumeScan(.success(self.scannedURLs))
            }
        }
    }
}

// MARK: - Main-actor funneling

/// Runs `body` on the main actor. ImageCaptureCore delivers its delegate
/// callbacks on the main thread (the browser and sessions are created there),
/// in which case `body` runs synchronously and in order; any off-main
/// delivery is hopped over safely.
private func performOnMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            body()
        }
    } else {
        Task { @MainActor in
            body()
        }
    }
}
