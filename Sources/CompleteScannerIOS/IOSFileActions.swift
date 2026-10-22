#if os(iOS)
import CompleteScannerKit
import Foundation
#if canImport(MessageUI)
import MessageUI
#endif
import UIKit
import UniformTypeIdentifiers

/// The share sheet a file action asks for: the files, and the title the Mac's share menu would show.
public struct ShareRequest: Identifiable, Equatable {
    public let id: UUID
    public let urls: [URL]
    public let title: String

    public init(urls: [URL], title: String) {
        self.id = UUID()
        self.urls = urls
        self.title = title
    }
}

/// A mail message with files attached, for the Mail composer (`MailComposeView`): the files and its subject.
public struct MailRequest: Identifiable, Equatable {
    public let id: UUID
    public let urls: [URL]
    public let subject: String

    public init(urls: [URL], subject: String) {
        self.id = UUID()
        self.urls = urls
        self.subject = subject
    }
}

/// The iPhone's and iPad's `FileActionService`. iOS has no Finder and no "Open With" menu, so: Open
/// previews the file (Quick Look), Open With and Share open the share sheet (`UIActivityViewController`,
/// where the user picks Mail, Files or another app), Email opens a Mail message with the files attached
/// when Mail is set up (`MFMailComposeViewController.canSendMail`) and the share sheet otherwise, Show in
/// folder opens the Files app at the file's folder, and Copy puts the files (and the picture of a single
/// image) on the pasteboard, on this device only. Show in folder for a folder opens that folder. The app's root view presents what `shareRequest`,
/// `mailRequest` and `previewURL` ask for; nothing leaves the device unless the user sends the message or
/// picks where it goes in the share sheet.
@MainActor
public final class IOSFileActions: ObservableObject, FileActionService {
    /// The share sheet to show; the root view sets it back to nil when the sheet closes.
    @Published public var shareRequest: ShareRequest?
    /// The file to preview with Quick Look; nil when none is shown.
    @Published public var previewURL: URL?
    /// The Mail message to compose; the root view sets it back to nil when the composer closes.
    @Published public var mailRequest: MailRequest?

    private let pasteboard: UIPasteboard
    private let openSystemURL: @MainActor (URL) -> Void
    private let mailAvailable: @MainActor () -> Bool

    /// `pasteboard` nil: the general pasteboard. `openSystemURL` nil: `UIApplication.open` (tests
    /// pass their own to see the Files app's address without opening it). `mailAvailable` nil: whether
    /// Mail is set up on the device (`canSendMail`; tests say).
    public init(pasteboard: UIPasteboard? = nil, openSystemURL: (@MainActor (URL) -> Void)? = nil,
                mailAvailable: (@MainActor () -> Bool)? = nil) {
        self.pasteboard = pasteboard ?? UIPasteboard.general
        if let openSystemURL {
            self.openSystemURL = openSystemURL
        } else {
            self.openSystemURL = { (url: URL) -> Void in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        if let mailAvailable {
            self.mailAvailable = mailAvailable
        } else {
            self.mailAvailable = { () -> Bool in
                IOSFileActions.canSendMail()
            }
        }
    }

    /// Mail is set up on this device, so a message can be composed here.
    public static func canSendMail() -> Bool {
        #if canImport(MessageUI)
        return MFMailComposeViewController.canSendMail()
        #else
        return false
        #endif
    }

    public func open(_ url: URL) throws {
        previewURL = url
    }

    public func openWith(_ url: URL) throws {
        shareRequest = ShareRequest(urls: [url], title: url.lastPathComponent)
    }

    public func reveal(_ urls: [URL]) {
        guard let target = IOSFileActions.filesAppURL(for: urls) else { return }
        openSystemURL(target)
    }

    public func sendProbe(for urls: [URL]) -> SendProbe {
        SendProbe(canCompose: mailAvailable(), canShare: true)
    }

    public func share(_ urls: [URL], title: String) throws {
        guard !urls.isEmpty else {
            throw ScanError.unsupported("There is nothing to share.")
        }
        shareRequest = ShareRequest(urls: urls, title: title)
    }

    public func composeEmail(_ urls: [URL]) throws {
        guard mailAvailable(), !urls.isEmpty else {
            try share(urls, title: SaveActions.shareTitle(urls))
            return
        }
        mailRequest = MailRequest(urls: urls, subject: SaveActions.shareTitle(urls))
    }

    public func copy(_ content: ClipboardContent) throws {
        var items: [[String: Any]] = []
        for url in content.files {
            let item: [String: Any] = [UTType.fileURL.identifier: url]
            items.append(item)
        }
        if let imageURL = content.imageFile {
            // The file's own bytes, under its own type (PNG, JPEG, TIFF), once they read as a picture.
            let data: Data? = try? Data(contentsOf: imageURL)
            let type: UTType? = UTType(filenameExtension: imageURL.pathExtension)
            guard let data, let type, type.conforms(to: UTType.image), UIImage(data: data) != nil else {
                throw ScanError.exportFailed("\(imageURL.lastPathComponent) could not be read.")
            }
            let item: [String: Any] = [type.identifier: data]
            items.append(item)
        }
        guard !items.isEmpty else {
            throw ScanError.unsupported("There is nothing to copy.")
        }
        pasteboard.setItems(items, options: [UIPasteboard.OptionsKey.localOnly: true])
    }

    public func copyText(_ text: String) throws {
        let item: [String: Any] = [UTType.utf8PlainText.identifier: text]
        pasteboard.setItems([item], options: [UIPasteboard.OptionsKey.localOnly: true])
    }

    /// The Files app's address of the folder holding the first file (`shareddocuments://` and the
    /// folder's path), or of the folder itself when the first is a folder (Show in Files for the save
    /// folder); nil for none or one that is not local.
    public nonisolated static func filesAppURL(for urls: [URL]) -> URL? {
        guard let first = urls.first, first.isFileURL else { return nil }
        let folder: URL = first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        let text: String = folder.absoluteString
        let prefix: String = "file://"
        guard text.hasPrefix(prefix) else { return nil }
        let path: String = String(text.dropFirst(prefix.count))
        return URL(string: "shareddocuments://" + path)
    }
}
#endif
