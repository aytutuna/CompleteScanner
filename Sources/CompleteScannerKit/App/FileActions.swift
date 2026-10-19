import AppKit
import Foundation
import UniformTypeIdentifiers

/// What the app can do with saved files through macOS: open, open with, show in Finder, share,
/// email and copy. `AppState` decides what to do (with `SaveActions`); this carries it out, so
/// tests can stand in for the system. Twin of the Windows `IFileActions`.
@MainActor
public protocol FileActionService: AnyObject {
    /// Opens the file with its default app.
    func open(_ url: URL) throws
    /// A menu of the apps that can open the file (default first, then the others, then
    /// "Other…"); the user picks one there or dismisses it.
    func openWith(_ url: URL) throws
    /// Shows the files in Finder, selected.
    func reveal(_ urls: [URL])
    /// What the platform offers for sending these files (see `SaveActions.emailRoute`).
    func sendProbe(for urls: [URL]) -> SendProbe
    /// The share menu for the files (Mail, Messages, AirDrop, …).
    func share(_ urls: [URL], title: String) throws
    /// A new Mail message with the files attached; nothing is sent until the user sends it.
    func composeEmail(_ urls: [URL]) throws
    /// Puts the files (and the picture of a single image) on the pasteboard.
    func copy(_ content: ClipboardContent) throws
}

/// The macOS implementation: NSWorkspace, NSSharingServicePicker, the Mail sharing service and
/// NSPasteboard. Menus and pickers open at the mouse pointer in the key window (in the window
/// underneath when the key window is a sheet).
@MainActor
public final class SystemFileActions: FileActionService {
    public init() {}

    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ScanError.exportFailed("No app could open \(url.lastPathComponent).")
        }
    }

    public func openWith(_ url: URL) throws {
        guard let anchor = Self.anchor() else {
            throw ScanError.unsupported("The app window is not open.")
        }
        let menu = NSMenu(title: "Open With")
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            menu.addItem(Self.appItem(defaultApp, file: url, isDefault: true))
            if !apps.isEmpty { menu.addItem(.separator()) }
        }
        let sorted = apps.sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        for app in sorted {
            menu.addItem(Self.appItem(app, file: url, isDefault: false))
        }
        menu.addItem(.separator())
        menu.addItem(Self.actionItem("Other\u{2026}") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.prompt = "Open"
            panel.message = "Choose an app to open \(url.lastPathComponent) with."
            if panel.runModal() == .OK, let app = panel.url {
                NSWorkspace.shared.open([url], withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        })
        menu.popUp(positioning: nil, at: anchor.point, in: anchor.view)
    }

    public func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func sendProbe(for urls: [URL]) -> SendProbe {
        let items: [Any] = urls
        let mail = NSSharingService(named: .composeEmail)
        return SendProbe(canCompose: mail?.canPerform(withItems: items) ?? false,
                         canShare: Self.anchor() != nil)
    }

    public func share(_ urls: [URL], title: String) throws {
        guard let anchor = Self.anchor() else {
            throw ScanError.unsupported("The app window is not open.")
        }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: NSRect(x: anchor.point.x, y: anchor.point.y, width: 1, height: 1),
                    of: anchor.view, preferredEdge: .minY)
    }

    public func composeEmail(_ urls: [URL]) throws {
        let items: [Any] = urls
        guard let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) else {
            throw ScanError.unsupported("No mail app is set up.")
        }
        mail.perform(withItems: items)
    }

    public func copy(_ content: ClipboardContent) throws {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        if let imageFile = content.imageFile, content.files.count == 1 {
            // One item that is both the file (for Finder) and its picture (for documents and editors).
            let item = NSPasteboardItem()
            _ = item.setString(imageFile.absoluteString, forType: .fileURL)
            if let picture = NSImage(contentsOf: imageFile)?.tiffRepresentation {
                _ = item.setData(picture, forType: .tiff)
            }
            guard pasteboard.writeObjects([item]) else {
                throw ScanError.exportFailed("The pasteboard did not take the file.")
            }
        } else {
            guard pasteboard.writeObjects(content.files.map { $0 as NSURL }) else {
                throw ScanError.exportFailed("The pasteboard did not take the files.")
            }
        }
    }

    // MARK: Helpers

    /// The anchor window's content view and the point in it where menus and the share picker
    /// open (see `anchorPoint`); nil without a window.
    private static func anchor() -> (view: NSView, point: NSPoint)? {
        guard let target = anchorWindow(), let view = target.window.contentView else { return nil }
        let pointer = view.convert(target.window.mouseLocationOutsideOfEventStream, from: nil)
        return (view: view, point: anchorPoint(pointer: pointer, bounds: view.bounds, overSheet: target.overSheet))
    }

    /// The window menus and the share picker attach to: the key window, or the window a sheet
    /// hangs from when the key window is a sheet. A sheet can be closing at that moment (the photo
    /// review is dismissed just before its after-save action runs), and a picker attached to it
    /// would go away with it. `overSheet` is true when a sheet was skipped.
    private static func anchorWindow() -> (window: NSWindow, overSheet: Bool)? {
        if let key = NSApp.keyWindow {
            var window = key
            while let parent = window.sheetParent {
                window = parent
            }
            if !window.isSheet {
                return (window: window, overSheet: window !== key)
            }
        }
        if let main = NSApp.mainWindow, !main.isSheet {
            return (window: main, overSheet: NSApp.keyWindow?.isSheet ?? false)
        }
        return nil
    }

    /// Where a menu or the share picker opens in a content view with `bounds`: at the pointer
    /// when it is inside, otherwise at the centre. When the key window is a sheet, the pointer is
    /// over the sheet rather than the window the picker attaches to, so the centre is used too.
    nonisolated static func anchorPoint(pointer: NSPoint, bounds: NSRect, overSheet: Bool) -> NSPoint {
        if overSheet || !bounds.contains(pointer) {
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }
        return pointer
    }

    private static func appItem(_ app: URL, file: URL, isDefault: Bool) -> NSMenuItem {
        let name = FileManager.default.displayName(atPath: app.path)
        let item = actionItem(isDefault ? "\(name) (default)" : name) {
            NSWorkspace.shared.open([file], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    /// A menu item that runs `handler`. The item keeps its target alive (menu targets are weak).
    private static func actionItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}

/// Runs a closure when its menu item is chosen.
private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}

extension FileAction {
    /// The SF Symbol shown for the action (status bar, Saved tab, menus).
    var systemImage: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .openWith: return "square.grid.2x2"
        case .reveal: return "folder"
        case .share: return "square.and.arrow.up"
        case .email: return "envelope"
        case .copy: return "doc.on.doc"
        }
    }

    /// What the action does, for tooltips and VoiceOver hints.
    func hint(fileCount: Int) -> String {
        switch self {
        case .open: return "Open with the default app"
        case .openWith: return "Choose the app to open it with"
        case .reveal: return "Show in Finder"
        case .share: return "Send with Mail, Messages, AirDrop or another app"
        case .email: return "Attach to a new email in Mail"
        case .copy: return fileCount == 1 ? "Copy the file to the clipboard" : "Copy the files to the clipboard"
        }
    }
}
