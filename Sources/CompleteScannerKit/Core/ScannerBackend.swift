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

    func cancelScan()
    func close() async
}
