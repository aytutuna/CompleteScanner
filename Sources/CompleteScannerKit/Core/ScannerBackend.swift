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

    func cancelScan()
    func close() async
}

extension ScannerSession {
    public var lastScanStop: ScanStop? { nil }
}
