#if os(iOS)
import Foundation
#if canImport(MessageUI)
import MessageUI
#endif
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file attached to a Mail message: its bytes, its type and its name.
public struct MailAttachment: Equatable {
    public let data: Data
    public let mimeType: String
    public let fileName: String

    public init(data: Data, mimeType: String, fileName: String) {
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// The files at `urls` as attachments, each read once; a file that cannot be read is left out.
    public static func of(_ urls: [URL]) -> [MailAttachment] {
        var attachments: [MailAttachment] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let type: UTType? = UTType(filenameExtension: url.pathExtension)
            let mimeType: String = type?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(MailAttachment(data: data, mimeType: mimeType, fileName: url.lastPathComponent))
        }
        return attachments
    }
}

#if canImport(MessageUI)
/// Mail's composer with the saved files attached (the Email task's after-save, `IOSFileActions.mailRequest`),
/// in a SwiftUI sheet. Nothing is sent until the user taps Send; `onDone` runs when the composer closes,
/// sent, saved as a draft or cancelled.
struct MailComposeView: UIViewControllerRepresentable {
    let request: MailRequest
    let onDone: @MainActor () -> Void

    func makeCoordinator() -> MailComposeCoordinator {
        MailComposeCoordinator(onDone: onDone)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller: MFMailComposeViewController = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject(request.subject)
        for attachment in MailAttachment.of(request.urls) {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
}

/// Hears when Mail's composer is done and closes its sheet.
final class MailComposeCoordinator: NSObject, MFMailComposeViewControllerDelegate {
    private let onDone: @MainActor () -> Void

    init(onDone: @escaping @MainActor () -> Void) {
        self.onDone = onDone
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                               error: Error?) {
        let done: @MainActor () -> Void = onDone
        Task { @MainActor in
            done()
        }
    }
}
#endif
#endif
