import Foundation
import CoreGraphics

/// A source of scanner devices (ImageCaptureCore for real hardware, Mock for the demo device).
@MainActor
public protocol ScannerBackend: AnyObject {
    /// Called whenever `devices` changes.
    var onDevicesChanged: (() -> Void)? { get set }
    var devices: [ScannerInfo] { get }
    func startBrowsing()
    func stopBrowsing()
    /// Open a session with one of `devices`. Throws ScanError on failure.
    func openSession(deviceID: String) async throws -> any ScannerSession
}

/// An open connection to one scanner.
@MainActor
public protocol ScannerSession: AnyObject {
    var info: ScannerInfo { get }
    var progressHandler: ((ScanProgress) -> Void)? { get set }

    func capabilities() async throws -> ScannerCapabilities

    /// Fast low-resolution preview of the whole flatbed.
    func performOverviewScan(settings: ScanSettings) async throws -> CGImage

    /// Perform a real scan.
    /// - Parameter selection: normalized (0...1) rect within the flatbed area, origin TOP-LEFT;
    ///   nil scans the full bed. Ignored for the document feeder.
    /// - Returns: one ScannedPage per sheet (the ADF may produce several).
    func performScan(settings: ScanSettings, selection: CGRect?) async throws -> [ScannedPage]

    /// Why the last `performScan` ended early while still returning the pages that
    /// transferred; nil when it ran to the end (or failed outright). Reset by every scan.
    /// Sessions that never stop a batch early can leave the default.
    var lastScanStop: ScanStop? { get }

    /// Whether the last `performScan` asked for both sides of each sheet (`.both` on the feeder)
    /// scanned both: false when the scanner fell back to one side (its feeder cannot), so the
    /// app does not arrange the pages as fronts and backs. nil when both sides were not asked
    /// for, or when the session cannot tell. Reset by every scan.
    var lastScanDuplex: Bool? { get }

    /// The session tells whether the feeder scans both sides only once the feeder is selected
    /// (`feederSupportsDuplex`, ImageCaptureCore); until then `capabilities().supportsDuplex`
    /// means "not known yet". Default false: the capabilities say it.
    var feederDuplexNeedsSelection: Bool { get }

    /// Whether the feeder scans both sides, for sessions that can tell only once the feeder is
    /// selected (ImageCaptureCore): selecting it can take a while on a sleeping scanner, so the
    /// app asks only when the feeder is used. nil: not known this time (the scanner did not
    /// answer, or another operation runs), or already in `capabilities()`.
    func feederSupportsDuplex() async -> Bool?

    func cancelScan()
    func close() async
}

extension ScannerSession {
    public var lastScanStop: ScanStop? { nil }
    public var lastScanDuplex: Bool? { nil }
    public var feederDuplexNeedsSelection: Bool { false }
    public func feederSupportsDuplex() async -> Bool? { nil }
}
