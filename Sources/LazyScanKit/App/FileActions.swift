import Foundation

/// What the app can do with saved files through the system: open, open with, show in Finder, share,
/// email and copy. `AppState` decides what to do (with `SaveActions`); this carries it out, so
/// tests can stand in for the system. Each app shell passes its own: the Mac's is `SystemFileActions`
/// (LazyScanMac). Twin of the Windows `IFileActions`.
@MainActor
public protocol FileActionService: AnyObject {
    /// Opens the file with its default app.
    func open(_ url: URL) throws
    /// A menu of the apps that can open the file (default first, then the others, then
    /// "Other…"); the user picks one there or dismisses it.
    func openWith(_ url: URL) throws
    /// Shows the files in Finder, selected (`AppState.revealInFinder` too).
    func reveal(_ urls: [URL])
    /// What the platform offers for sending these files (see `SaveActions.emailRoute`).
    func sendProbe(for urls: [URL]) -> SendProbe
    /// The share menu for the files (Mail, Messages, AirDrop, …).
    func share(_ urls: [URL], title: String) throws
    /// A new Mail message with the files attached; nothing is sent until the user sends it.
    func composeEmail(_ urls: [URL]) throws
    /// Puts the files (and the picture of a single image) on the pasteboard.
    func copy(_ content: ClipboardContent) throws
    /// Puts `text` on the pasteboard (Copy Text on a scanned page).
    func copyText(_ text: String) throws
}

/// The file actions of an `AppState` whose app shell passed none: every action is refused with
/// `ScanError.unsupported`, showing does nothing, and nothing can be sent.
@MainActor
final class UnavailableFileActions: FileActionService {
    private static let reason = "Files cannot be opened or shared here."

    func open(_ url: URL) throws {
        throw ScanError.unsupported(Self.reason)
    }

    func openWith(_ url: URL) throws {
        throw ScanError.unsupported(Self.reason)
    }

    func reveal(_ urls: [URL]) {}

    func sendProbe(for urls: [URL]) -> SendProbe {
        SendProbe(canCompose: false, canShare: false)
    }

    func share(_ urls: [URL], title: String) throws {
        throw ScanError.unsupported(Self.reason)
    }

    func composeEmail(_ urls: [URL]) throws {
        throw ScanError.unsupported(Self.reason)
    }

    func copy(_ content: ClipboardContent) throws {
        throw ScanError.unsupported(Self.reason)
    }

    func copyText(_ text: String) throws {
        throw ScanError.unsupported(Self.reason)
    }
}
