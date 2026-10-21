import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/Escl/EsclScannerSession.cs: the same rules and tests
// (EsclClientTests). On the iPhone each job also asks the system for background time
// (`BackgroundActivity`), so a page in flight and the deletion of a job cut short finish when the user
// switches apps; when that time is nearly up the job stops, keeping the pages received (`appSuspended`),
// and the time is given back once its deletion has been sent.

/// An open eSCL scanner: the app's scan calls turned into eSCL jobs on an `EsclClient` (which it owns).
/// The capabilities were read when it was opened.
@MainActor
public final class EsclScannerSession: ScannerSession {
    public let info: ScannerInfo
    public var progressHandler: ((ScanProgress) -> Void)?
    public private(set) var lastScanStop: ScanStop?
    public private(set) var lastScanDuplex: Bool?

    /// The device's capabilities as read when the session opened.
    public let esclCapabilities: EsclCapabilities
    /// The connection in use.
    public let client: EsclClient
    /// The system's background time for each job; nil where the app keeps running (the Mac, tests).
    public let background: (any BackgroundActivity)?

    private var job: Task<EsclJobResult, Error>?
    /// The last job started; the connection is released only after it has ended.
    private var lastJob: Task<EsclJobResult, Error>?
    private var cancelRequested = false
    /// Set when the system is about to suspend the app during the current job.
    private var suspension: CancelFlag?

    public init(info: ScannerInfo, client: EsclClient, capabilities: EsclCapabilities,
                background: (any BackgroundActivity)? = nil) {
        self.info = info
        self.client = client
        self.esclCapabilities = capabilities
        self.background = background
    }

    public func capabilities() async throws -> ScannerCapabilities {
        esclCapabilities.toScannerCapabilities()
    }

    public func performOverviewScan(settings: ScanSettings) async throws -> CGImage {
        cancelRequested = false
        guard esclCapabilities.hasPlaten, let platen: EsclInputCaps = esclCapabilities.platen else {
            throw ScanError.unsupported("This scanner has no flatbed to preview.")
        }
        progressHandler?(ScanProgress(message: "Scanning overview…"))
        var dpi: Int = 150
        for resolution in platen.resolutions where resolution >= 150 {
            dpi = resolution
            break
        }
        let result: EsclJobResult = try await runJob(dpi: dpi, colorMode: .color, source: .flatbed, selection: nil)
        guard let first: ScannedPage = result.pages.first else {
            throw ScanError.scanFailed("The scanner returned no overview image.")
        }
        return first.image
    }

    public func performScan(settings: ScanSettings, selection: CGRect?) async throws -> [ScannedPage] {
        cancelRequested = false
        lastScanStop = nil
        lastScanDuplex = nil
        progressHandler?(ScanProgress(message: "Scanning…"))
        // Black & white arrives as grayscale; the app's pipeline thresholds every page that is not a
        // color scan, so the pages keep the requested color mode. A two-sided job delivers front, back,
        // front, back…, as the app expects.
        let flatbedSelection: CGRect? = settings.source == .flatbed ? selection : nil
        let result: EsclJobResult = try await runJob(dpi: settings.resolution, colorMode: settings.colorMode,
                                                     source: settings.source, selection: flatbedSelection,
                                                     duplex: settings.duplex == .both, paperSize: settings.paperSize)
        if result.pages.isEmpty {
            throw ScanError.scanFailed("The scanner did not return any image data.")
        }
        lastScanStop = result.stop
        // A device that does not list two-sided feeding scans one side (EsclScanRequest.create).
        if settings.source == .documentFeeder && settings.duplex == .both {
            lastScanDuplex = esclCapabilities.supportsDuplex
        }
        return result.pages
    }

    /// Stops the job: its requests are abandoned, and the job is deleted on the device on the way out.
    public func cancelScan() {
        cancelRequested = true
        job?.cancel()
    }

    /// Closes at once. The connection is released in the background, once a cancelled job has wound
    /// down and its deletion has been sent to the device.
    public func close() async {
        cancelScan()
        let last: Task<EsclJobResult, Error>? = lastJob
        let client: EsclClient = self.client
        Task.detached {
            if let last {
                _ = await last.result
            }
            await client.whenCleanedUp()
        }
    }

    /// The system's background time is nearly up: the job stops now, its deletion is sent at once (the
    /// time is given back once it has been, in `runJob`), and the pages received are kept with the
    /// `appSuspended` stop.
    private func suspend() {
        suspension?.cancel()
        client.abandonJob()
        job?.cancel()
    }

    private func runJob(dpi: Int, colorMode: ColorMode, source: ScanSource, selection: CGRect?,
                        duplex: Bool = false, paperSize: PaperSize = .auto) async throws -> EsclJobResult {
        let request: EsclScanRequest = EsclScanRequest.create(esclCapabilities, source: source, colorMode: colorMode,
                                                              dpi: dpi, selection: selection, duplex: duplex,
                                                              paperSize: paperSize)
        let client: EsclClient = self.client
        let flag: CancelFlag = CancelFlag()
        suspension = flag
        let report: @Sendable (ScanProgress) -> Void = { (progress: ScanProgress) in
            Task { @MainActor in
                self.progressHandler?(progress)
            }
        }
        let isSuspended: @Sendable () -> Bool = {
            flag.isCancelled
        }
        let started: Task<EsclJobResult, Error> = Task.detached {
            try await client.scan(request, colorMode: colorMode, source: source, progress: report, suspended: isSuspended)
        }
        job = started
        lastJob = started
        if cancelRequested {
            started.cancel()
        }
        var token: Int?
        if let cover = background {
            token = cover.beginActivity("Scanning on \(info.name)", expired: { [weak self] in
                self?.suspend()
            })
        }
        let outcome: Result<EsclJobResult, Error> = await started.result
        job = nil
        suspension = nil
        // The background time also covers the deletion of a job cut short; it is given back once that
        // has been sent, without holding up the pages.
        if let token, let cover = background {
            Task { @MainActor in
                await client.whenCleanedUp()
                cover.endActivity(token)
            }
        }
        return try outcome.get()
    }
}
