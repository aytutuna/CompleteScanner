#if os(iOS)
import CompleteScannerKit
import Foundation

/// The cloud folder of My computer (C2): a folder in iCloud Drive or OneDrive that the computer also syncs,
/// where documents go, sealed, when the computer cannot be reached. Picked in Files and kept as a bookmark
/// (`PairedDesktop.syncFolderBookmark`), opened like the save folder and kept open while the app runs
/// (`AppState.resolveSyncFolderBookmark`, set by `makeForIOS`).
@MainActor
public enum IOSSyncFolder {
    private static let kept: IOSBookmarkedFolder = IOSBookmarkedFolder()

    /// The bookmark of `folder`, picked in Files; throws when none can be made of it.
    public static func bookmark(of folder: URL) throws -> Data {
        try IOSBookmarkedFolder.bookmark(of: folder)
    }

    /// The folder `bookmark` stands for, opened, and the bookmark to keep (made again when iOS says it is
    /// stale); nil when it does not resolve.
    public static func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)? {
        kept.resolve(bookmark)
    }

    /// The folder is no longer used.
    public static func close() {
        kept.close()
    }

    /// The sealed documents in `folder` the computer has not taken yet (it deletes each once it has it).
    /// Those of another phone syncing the same folder count too. Listed in a coordinated read, as the
    /// provider sees the folder.
    public static func waitingCount(in folder: URL) -> Int {
        var files: [URL] = []
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: .immediatelyAvailableMetadataOnly,
                                                         error: &coordinationError) { (listed: URL) -> Void in
            files = (try? FileManager.default.contentsOfDirectory(
                at: listed, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        return files.filter { $0.pathExtension.lowercased() == SyncPackage.fileExtension }.count
    }
}
#endif
