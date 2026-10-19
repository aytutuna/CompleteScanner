import AppKit
import Foundation

/// What the troubleshooter does outside the app: open Image Capture or a System Settings pane,
/// and copy text. It never changes a setting. `AppState` takes it as a stand-in in tests. Twin of
/// the Windows `ISystemDiagnostics` (which also reads the WIA service and the network; the Mac
/// reads neither).
@MainActor
public protocol TroubleshooterService: AnyObject {
    /// Opens what `action` names (`.openScannerSettings`, `.openNetworkSettings`,
    /// `.openImageCapture`); throws when macOS refuses or the action opens nothing.
    func open(_ action: TroubleshootAction) throws
    /// Puts the text on the pasteboard.
    func copy(_ text: String) throws
}

/// The macOS implementation: NSWorkspace for System Settings and Image Capture, NSPasteboard.
@MainActor
public final class SystemTroubleshooterService: TroubleshooterService {
    /// System Settings, Printers & Scanners.
    public static let printersAndScannersURL = URL(string: "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension")!
    /// System Settings, Network.
    public static let networkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
    /// Image Capture, which lists every scanner macOS sees.
    public static let imageCaptureBundleID = "com.apple.Image_Capture"

    public init() {}

    public func open(_ action: TroubleshootAction) throws {
        switch action {
        case .openScannerSettings:
            guard NSWorkspace.shared.open(Self.printersAndScannersURL) else {
                throw ScanError.exportFailed("System Settings did not open.")
            }
        case .openNetworkSettings:
            guard NSWorkspace.shared.open(Self.networkSettingsURL) else {
                throw ScanError.exportFailed("System Settings did not open.")
            }
        case .openImageCapture:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.imageCaptureBundleID) else {
                throw ScanError.exportFailed("Image Capture was not found on this Mac.")
            }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        case .refresh, .addByAddress, .copyDiagnostics:
            throw ScanError.unsupported("\(action.rawValue) does not open anything.")
        }
    }

    public func copy(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ScanError.exportFailed("The text could not be put on the pasteboard.")
        }
    }
}
