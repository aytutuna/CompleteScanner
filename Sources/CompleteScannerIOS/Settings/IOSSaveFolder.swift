#if os(iOS)
import CompleteScannerKit
import Foundation

/// A save folder outside the app (iCloud Drive, a USB drive) picked in Settings. iOS lets the app back into
/// such a folder only through a bookmark (`ScanSettings.destinationBookmark`); its path is kept too, so what
/// reads `destinationPath` works on. The folder is opened once and kept open while the app runs, since it is
/// written to again and again (`AppState.resolveDestinationBookmark`, set by `makeForIOS`).
@MainActor
public enum IOSSaveFolder {
    /// The folder open now and the bookmark it was opened with.
    private static var opened: (folder: URL, bookmark: Data)?
    /// The folder whose security-scoped access was started, stopped when another is opened.
    private static var accessed: URL?

    /// `settings` saving to `folder`, picked in Files; throws when no bookmark can be made of it. The folder
    /// is opened by `AppState.openBookmarkedFolder()`.
    public static func choosing(_ folder: URL, in settings: ScanSettings) throws -> ScanSettings {
        let started: Bool = folder.startAccessingSecurityScopedResource()
        defer {
            if started { folder.stopAccessingSecurityScopedResource() }
        }
        var changed: ScanSettings = settings
        changed.destinationBookmark = try folder.bookmarkData()
        changed.destinationPath = folder.path
        return changed
    }

    /// `settings` saving to the app's own folder again; the folder picked before is closed.
    public static func appFolder(_ settings: ScanSettings) -> ScanSettings {
        close()
        var changed: ScanSettings = settings
        changed.destinationBookmark = nil
        changed.destinationPath = ScanSettings.defaultDestinationPath
        return changed
    }

    /// The folder `bookmark` stands for, opened, and the bookmark to keep (made again when iOS says it is
    /// stale); nil when it does not resolve. The folder kept open is resolved again once it is out of reach.
    public static func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)? {
        if let current = opened, current.bookmark == bookmark,
           (try? current.folder.checkResourceIsReachable()) == true {
            return current
        }
        var stale: Bool = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                    bookmarkDataIsStale: &stale) else {
            close()
            return nil
        }
        if opened?.folder != folder {
            close()
            if folder.startAccessingSecurityScopedResource() {
                accessed = folder
            }
        }
        var kept: Data = bookmark
        if stale, let fresh = try? folder.bookmarkData() {
            kept = fresh
        }
        opened = (folder: folder, bookmark: kept)
        return (folder: folder, bookmark: kept)
    }

    private static func close() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        opened = nil
    }
}
#endif
