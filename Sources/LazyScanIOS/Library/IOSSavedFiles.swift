#if os(iOS)
import LazyScanKit
import CoreGraphics
import Foundation
import ImageIO

/// A file in the save folder as the Saved files screen lists it.
public struct IOSSavedFile: Identifiable, Equatable {
    public let url: URL
    public let modified: Date
    public let byteCount: Int
    /// Saved by the last save of this session (`AppState.lastSavedURLs`).
    public let isNew: Bool

    public init(url: URL, modified: Date, byteCount: Int, isNew: Bool) {
        self.url = url
        self.modified = modified
        self.byteCount = byteCount
        self.isNew = isNew
    }

    /// The modification date is part of it, so a file written again gets a fresh row.
    public var id: String { "\(url.path)|\(modified.timeIntervalSince1970)" }
    public var name: String { url.lastPathComponent }
    public var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
    public var isImage: Bool { SaveActions.isImageFile(url) }

    /// The icon shown until (or instead of) its picture.
    public var symbol: String {
        if isPDF { return "doc.richtext" }
        if isImage { return "photo" }
        return "doc.text"
    }

    /// "Oct 20, 2026 · 498 KB".
    public var detail: String {
        let date: String = modified.formatted(date: .abbreviated, time: .shortened)
        let size: String = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(date) \u{00B7} \(size)"
    }
}

/// The save folder read: its files newest first, or that it could not be read.
public struct IOSSavedFolder: Equatable {
    public let files: [IOSSavedFile]
    /// The folder is there but could not be listed.
    public let failed: Bool
}

/// The Saved files screen without a screen: everything in the save folder the app writes (PDF, JPEG,
/// PNG, TIFF, text and Word files), newest first, as on the Mac and Windows; the files of the last save
/// are marked. Each file offers what iOS has of the saved files' actions (`SaveActions.offered`): Share and
/// Show in Files first. Nothing is deleted here, as on the desktop: the Files app does that.
public enum IOSSavedFiles {
    public static let title = "Saved files"
    public static let emptyTitle = "Nothing saved yet"
    public static let emptyLine = "Saved files appear here, newest first."
    public static let failedLine = "The save folder could not be read."
    public static let newBadge = "New"
    public static let revealLabel = "Show in Files"
    public static let moreLabel = "More"

    /// The extensions of the files the app saves.
    public static let knownExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "tiff", "tif", "txt", "docx"]

    /// The folder the settings save to, in this install's Documents folder when it was the app's own
    /// folder of an earlier one. A picked folder's path is its own, even in another app's Documents.
    public static func folder(_ settings: ScanSettings) -> URL {
        var path: String = (settings.destinationPath as NSString).expandingTildeInPath
        if settings.destinationBookmark == nil {
            path = ScanSettings.rebasedDestinationPath(path, documents: IOSShell.documentsFolder)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The folder the Saved files list and the Save to row show: the app's own folder while a picked
    /// folder is out of reach (its drive unplugged, say), since a save goes there meanwhile
    /// (`AppState.destinationDirectory`); else `folder(_:)`.
    public static func shownFolder(_ settings: ScanSettings) -> URL {
        let picked: URL = folder(settings)
        guard settings.destinationBookmark != nil, (try? picked.checkResourceIsReachable()) != true else { return picked }
        let path: String = ScanSettings.rebasedDestinationPath(ScanSettings.defaultDestinationPath, documents: IOSShell.documentsFolder)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The files of `folder` the app saves, newest first (a hidden file, a folder or another kind of file
    /// is left out); those in `justSaved` marked new. A folder not made yet is empty, not a failure.
    public static func list(in folder: URL, justSaved: [URL]) -> IOSSavedFolder {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        } catch {
            return IOSSavedFolder(files: [], failed: FileManager.default.fileExists(atPath: folder.path))
        }
        var saved: Set<String> = []
        for url in justSaved {
            saved.insert(url.standardizedFileURL.path)
        }
        var files: [IOSSavedFile] = []
        for url in urls {
            guard knownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values: URLResourceValues? = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            let file: IOSSavedFile = IOSSavedFile(url: url, modified: values?.contentModificationDate ?? Date.distantPast,
                                                  byteCount: values?.fileSize ?? 0,
                                                  isNew: saved.contains(url.standardizedFileURL.path))
            files.append(file)
        }
        files.sort { (a: IOSSavedFile, b: IOSSavedFile) -> Bool in
            if a.modified != b.modified { return a.modified > b.modified }
            return a.name < b.name
        }
        return IOSSavedFolder(files: files, failed: false)
    }

    /// The actions of a file's More menu: what `SaveActions` offers for one file, but Share and Show in
    /// Files, which have their own buttons.
    public static var moreActions: [FileAction] {
        var actions: [FileAction] = []
        for action in SaveActions.offered(fileCount: 1) where action != .share && action != .reveal {
            actions.append(action)
        }
        return actions
    }

    /// An action's name here: Show in folder is the Files app on iOS.
    public static func label(_ action: FileAction) -> String {
        action == .reveal ? revealLabel : action.label
    }

    public static func symbol(_ action: FileAction) -> String {
        switch action {
        case .open: return "eye"
        case .openWith: return "arrow.up.forward.app"
        case .reveal: return "folder"
        case .share: return "square.and.arrow.up"
        case .email: return "envelope"
        case .copy: return "doc.on.doc"
        }
    }

    /// A small picture of a saved file: a picture's own (ImageIO), a PDF's first page (Core Graphics);
    /// nil for text and Word files, which show their icon. Safe off the main thread.
    public static func thumbnail(of url: URL, maxSide: Int) -> CGImage? {
        let ext: String = url.pathExtension.lowercased()
        if ext == "pdf" { return pdfThumbnail(url, maxSide: maxSide) }
        guard SaveActions.isImageFile(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func pdfThumbnail(_ url: URL, maxSide: Int) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let box: CGRect = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale: CGFloat = CGFloat(maxSide) / max(box.width, box.height)
        let width: Int = max(1, Int((box.width * scale).rounded()))
        let height: Int = max(1, Int((box.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
#endif
