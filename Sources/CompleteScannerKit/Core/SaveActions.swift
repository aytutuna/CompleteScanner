import Foundation

// Twin of windows/LazyScan.Core/SaveActions.cs: what can be done with saved files (open,
// open with, show in folder, share, email, copy) and what happens on its own after a save. The
// platform carries the actions out; the choices are made here so both apps make the same ones.

/// What happens on its own once a save has finished (`OutputOptions.afterSave`). `none` comes
/// first: it is the default and the fallback for an action a newer version adds. Add new cases
/// after the existing ones. Twin of C# `AfterSaveAction` (`ModelLabels.Label` / `Hint`).
public enum AfterSaveAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case open
    case reveal
    case share

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "Do nothing"
        case .open: return "Open"
        case .reveal: return "Show in folder"
        case .share: return "Share\u{2026}"
        }
    }

    /// What the after-save action does, in a few words: its tooltip.
    public var hint: String {
        switch self {
        case .none: return "Stay here"
        case .open: return "Open the file (several: show the folder)"
        case .reveal: return "Show the files in their folder"
        case .share: return "Email or send to an app"
        }
    }
}

/// Something the user can do with saved files: the Saved tab's cards and the status bar after a
/// save. Twin of C# `FileAction`.
public enum FileAction: String, CaseIterable, Identifiable, Sendable {
    case open
    case openWith
    case reveal
    case share
    case email
    case copy

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .open: return "Open"
        case .openWith: return "Open with\u{2026}"
        case .reveal: return "Show in folder"
        case .share: return "Share\u{2026}"
        case .email: return "Email\u{2026}"
        case .copy: return "Copy"
        }
    }
}

/// The step an after-save action comes down to for the files just saved.
public struct SaveFollowUp: Equatable, Sendable {
    /// What to do; never `.none`.
    public let action: AfterSaveAction
    /// The files to do it with, in the order they were saved.
    public let urls: [URL]

    public init(action: AfterSaveAction, urls: [URL]) {
        self.action = action
        self.urls = urls
    }

    /// The file action that carries the step out.
    public var fileAction: FileAction {
        switch action {
        case .open: return .open
        case .share: return .share
        case .none, .reveal: return .reveal
        }
    }
}

/// What Copy puts on the clipboard.
public struct ClipboardContent: Equatable, Sendable {
    /// Every file, as files (pasting into a folder copies them).
    public let files: [URL]
    /// The one image file whose picture is put on the clipboard too, so it can be pasted into a
    /// document or an image editor; nil for a PDF or several files.
    public let imageFile: URL?

    public init(files: [URL], imageFile: URL?) {
        self.files = files
        self.imageFile = imageFile
    }
}

/// How files are sent to another app or a person.
public enum SendRoute: Equatable, Sendable {
    /// A new mail message with the files attached, in the user's mail app (nothing is sent until
    /// the user sends it).
    case compose
    /// The system share window, where the user picks Mail or another app.
    case shareSheet
    /// Neither is available: the files are shown in their folder so they can be attached by hand.
    case showInFolder
}

/// What the platform can do to send files.
public struct SendProbe: Equatable, Sendable {
    /// A mail message with the files attached can be started directly (macOS Mail).
    public let canCompose: Bool
    /// The system share window is available.
    public let canShare: Bool

    public init(canCompose: Bool, canShare: Bool) {
        self.canCompose = canCompose
        self.canShare = canShare
    }
}

public enum SaveActions {
    /// Shown when the files are shown in their folder because they could not be shared.
    public static let showInFolderMessage =
        "Sharing is not available here, so the file is shown in its folder. Attach it from there."

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    /// The step `action` comes down to for `saved`, the files a save wrote; nil when there is
    /// nothing to do. The caller runs it only after a save that finished: not after one that was
    /// cancelled or failed part-way. Opening several files (a batch of photos) would start one
    /// viewer per file, so they are shown in their folder instead.
    public static func plan(_ action: AfterSaveAction, saved: [URL]) -> SaveFollowUp? {
        guard !saved.isEmpty else { return nil }
        switch action {
        case .none:
            return nil
        case .open:
            return SaveFollowUp(action: saved.count > 1 ? .reveal : .open, urls: saved)
        case .reveal, .share:
            return SaveFollowUp(action: action, urls: saved)
        }
    }

    /// The actions offered for `fileCount` saved files, in menu order. Open and Open with work on
    /// one file; showing, sharing, emailing and copying take several.
    public static func offered(fileCount: Int) -> [FileAction] {
        if fileCount <= 0 { return [] }
        if fileCount == 1 { return [.open, .openWith, .reveal, .share, .email, .copy] }
        return [.reveal, .share, .email, .copy]
    }

    /// A JPEG, PNG or TIFF file (by its extension, in any case).
    public static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// What Copy puts on the clipboard: the files, and the picture of a single image file.
    public static func clipboardContent(for urls: [URL]) -> ClipboardContent {
        ClipboardContent(files: urls, imageFile: urls.count == 1 && isImageFile(urls[0]) ? urls[0] : nil)
    }

    /// How Email sends the files: a new message in the mail app when the platform can start one
    /// with attachments, otherwise the share window (it lists the mail apps), otherwise the
    /// folder. Nothing is ever sent without the user sending it.
    public static func emailRoute(_ probe: SendProbe) -> SendRoute {
        if probe.canCompose { return .compose }
        return probe.canShare ? .shareSheet : .showInFolder
    }

    /// How Share sends the files: the share window, otherwise the folder.
    public static func shareRoute(_ probe: SendProbe) -> SendRoute {
        probe.canShare ? .shareSheet : .showInFolder
    }

    /// The title of the share window: the file's name, or "3 files".
    public static func shareTitle(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }
}
