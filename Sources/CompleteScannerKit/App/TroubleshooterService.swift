import Foundation

/// What the troubleshooter does outside the app: open Image Capture or a System Settings pane,
/// and copy text. It never changes a setting. `AppState` takes it as a stand-in in tests. Each app
/// shell passes its own: the Mac's is `SystemTroubleshooterService` (CompleteScannerMac). Twin of
/// the Windows `ISystemDiagnostics` (which also reads the WIA service and the network; the Mac
/// reads neither).
@MainActor
public protocol TroubleshooterService: AnyObject {
    /// Opens what `action` names (`.openScannerSettings`, `.openNetworkSettings`,
    /// `.openImageCapture`); throws when the system refuses or the action opens nothing.
    func open(_ action: TroubleshootAction) throws
    /// Puts the text on the pasteboard.
    func copy(_ text: String) throws
}

/// The troubleshooter's system side of an `AppState` whose app shell passed none: nothing opens and
/// nothing is copied; both are refused with `ScanError.unsupported`.
@MainActor
final class UnavailableTroubleshooterService: TroubleshooterService {
    func open(_ action: TroubleshootAction) throws {
        throw ScanError.unsupported("\(action.rawValue) does not open anything here.")
    }

    func copy(_ text: String) throws {
        throw ScanError.unsupported("The text cannot be copied here.")
    }
}
