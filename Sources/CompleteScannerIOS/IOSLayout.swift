#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// How the window is laid out for its width. A regular width on an iPad (`pad`; full screen or in a wide
/// Stage Manager window) gets the sidebar: the tasks, the presets, the scanners and the library beside the
/// screen in use; a compact width (a narrow iPad window, Slide Over) and every iPhone, a large one turned
/// sideways too, get the scan screen with the task list in a sheet over it. Decided again whenever the
/// width class changes, so resizing a window moves between the two.
public enum IOSLayout {
    public static func usesSidebar(_ horizontal: UserInterfaceSizeClass?, pad: Bool) -> Bool {
        pad && horizontal == .regular
    }
}

/// A keyboard shortcut of the iPad's main actions: its key, whether it takes Command, and its name.
public struct IOSShortcut: Equatable {
    public let key: Character
    public let command: Bool
    public let title: String

    @MainActor
    public var keyboardShortcut: KeyboardShortcut {
        let modifiers: EventModifiers = command ? EventModifiers.command : []
        return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }
}

/// The keyboard shortcuts, as the iPad's Command key overlay lists them: Command-S saves the pages,
/// Command-N starts a new document (Separate documents), Command-comma opens Settings, Space takes a photo
/// in camera mode.
public enum IOSShortcuts {
    public static let save = IOSShortcut(key: "s", command: true, title: "Save")
    public static let newDocument = IOSShortcut(key: "n", command: true, title: "New document")
    public static let settings = IOSShortcut(key: ",", command: true, title: "Settings")
    public static let shutter = IOSShortcut(key: " ", command: false, title: "Take photo")

    public static let all: [IOSShortcut] = [save, newDocument, settings, shutter]
}

/// Moving a page of the strip by dragging it onto another: it takes that page's place, the pages between
/// moving up or down one (`AppState.movePage`, one place at a time).
public enum IOSPageDrop {
    /// The signed number of places the page `moving` goes to take `target`'s place; nil when either is not
    /// in `ids` or they are the same page.
    public static func offset(moving: UUID, onto target: UUID, in ids: [UUID]) -> Int? {
        guard let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: target), from != to else { return nil }
        return to - from
    }

    /// The dragged page's id, carried as its text.
    public static func pageID(_ text: String) -> UUID? {
        UUID(uuidString: text)
    }

    /// Moves the page `moving` to `target`'s place in the queue; false when nothing moved (an unknown page,
    /// the same page, or an operation running).
    @MainActor
    @discardableResult
    public static func move(_ moving: UUID, onto target: UUID, in state: AppState) -> Bool {
        guard !state.isBusy else { return false }
        var ids: [UUID] = []
        for page in state.scannedPages {
            ids.append(page.id)
        }
        guard let offset = offset(moving: moving, onto: target, in: ids) else { return false }
        let step: Int = offset > 0 ? 1 : -1
        var moved: Int = 0
        while moved < abs(offset) {
            state.movePage(id: moving, by: step)
            moved += 1
        }
        return true
    }
}

/// What the page grid does to the pages picked in it, through the queue's one-page edits (`AppState.movePage`,
/// `rotatePage`, `removePage`) and always by id, since each edit shifts the places of the pages after it.
public enum IOSPageSelection {
    /// The folder the shared pages are written in, emptied before each share.
    static var shareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Shared pages", isDirectory: true)
    }

    /// The ids of `selected` in the order of `pages`.
    public static func ordered(_ selected: Set<UUID>, in pages: [ScannedPage]) -> [UUID] {
        var ids: [UUID] = []
        for page in pages where selected.contains(page.id) {
            ids.append(page.id)
        }
        return ids
    }

    /// Moves the pages `selected` to the start of the queue (or its end), in the order they had among
    /// themselves; nothing while an operation runs.
    @MainActor
    public static func move(_ selected: Set<UUID>, toStart: Bool, in state: AppState) {
        guard !state.isBusy else { return }
        var ids: [UUID] = ordered(selected, in: state.scannedPages)
        if !toStart {
            ids.reverse()
        }
        var placed: Int = 0
        for id in ids {
            guard let index = state.scannedPages.firstIndex(where: { (page: ScannedPage) -> Bool in page.id == id }) else { continue }
            let target: Int = toStart ? placed : state.scannedPages.count - 1 - placed
            let step: Int = toStart ? -1 : 1
            var moved: Int = 0
            while moved < abs(target - index) {
                state.movePage(id: id, by: step)
                moved += 1
            }
            placed += 1
        }
    }

    /// Writes the pages `selected` as pictures in `format`, one file a page in the queue's order named by its
    /// number ("Page 3.jpg"), at full resolution and turned as shown, for the share sheet.
    public static func writeImages(_ selected: Set<UUID>, of pages: [ScannedPage], format: OutputFormat,
                                   jpegQuality: Double) async throws -> [URL] {
        let folder: URL = shareFolder
        return try await Task.detached(priority: .userInitiated) { () -> [URL] in
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var urls: [URL] = []
            var number: Int = 1
            for page in pages {
                if selected.contains(page.id) {
                    let url: URL = folder.appendingPathComponent("Page \(number).\(format.fileExtension)")
                    try ImageExporter.write(IOSPageSelection.fullImage(of: page), to: url, format: format, dpi: page.dpi,
                                            jpegQuality: jpegQuality, colorMode: page.colorMode)
                    urls.append(url)
                }
                number += 1
            }
            return urls
        }.value
    }

    /// The page's full pixels from its spool file, turned by its rotation as `AppState.saveImages` does; the
    /// preview in memory when it has no file.
    static func fullImage(of page: ScannedPage) -> CGImage {
        guard let url = page.fileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let spooled = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return page.image }
        let turns: Int = ((page.rotationQuarterTurns % 4) + 4) % 4
        if turns == 0 { return spooled }
        return ImagePipeline.rotate(spooled, quarterTurns: turns)
    }
}

/// A PDF or a picture dropped on the scan screen (from Files, Photos or another app beside this one), as
/// its file's bytes; it comes in through the same import as a file picked in Files.
public struct IOSDroppedFile: Transferable, Sendable {
    public let data: Data
    public let kind: IOSImportItem.Kind

    public init(data: Data, kind: IOSImportItem.Kind) {
        self.data = data
        self.kind = kind
    }

    public static let pdfName = "Dropped PDF"
    public static let imageName = "Dropped picture"

    /// The item the import reads: named by its kind, since a drop carries no file name here.
    public var item: IOSImportItem {
        let name: String = kind == .pdf ? IOSDroppedFile.pdfName : IOSDroppedFile.imageName
        return IOSImportItem(name: name, data: data, kind: kind)
    }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: UTType.pdf) { (data: Data) -> IOSDroppedFile in
            IOSDroppedFile(data: data, kind: IOSImportItem.Kind.pdf)
        }
        DataRepresentation(importedContentType: UTType.image) { (data: Data) -> IOSDroppedFile in
            IOSDroppedFile(data: data, kind: IOSImportItem.Kind.image)
        }
    }
}
#endif
