#if os(iOS)
import LazyScanKit
import UIKit
import XCTest
@testable import LazyScanIOS

// The iPhone's file actions: Open previews, Open With, Share and Email ask for the share sheet, Show
// in folder opens the Files app at the folder, Copy puts the files and a single image's picture on
// the pasteboard. Each test uses a pasteboard of its own and records the address the Files app would
// be opened at, so nothing of the simulator's is changed and no other app opens.

/// The addresses the file actions asked the system to open.
@MainActor
private final class OpenedAddresses {
    var urls: [URL] = []
}

final class IOSFileActionsTests: XCTestCase {
    private var pasteboard: UIPasteboard?
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSFileActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await removeOwnPasteboard()
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func removeOwnPasteboard() {
        if let pasteboard {
            UIPasteboard.remove(withName: pasteboard.name)
        }
        pasteboard = nil
    }

    /// File actions with a pasteboard of their own, on a device where Mail is set up (`mail`) or not.
    @MainActor
    private func makeActions(_ opened: OpenedAddresses, mail: Bool = false) -> IOSFileActions {
        let own: UIPasteboard = UIPasteboard.withUniqueName()
        pasteboard = own
        return IOSFileActions(pasteboard: own, openSystemURL: { (url: URL) -> Void in
            opened.urls.append(url)
        }, mailAvailable: { () -> Bool in
            mail
        })
    }

    private func file(_ name: String) throws -> URL {
        let url: URL = folder.appendingPathComponent(name)
        try Data("%PDF-1.4\n".utf8).write(to: url)
        return url
    }

    @MainActor
    func test_share_asksForTheShareSheet_withTheFilesAndTitle() throws {
        let actions = makeActions(OpenedAddresses())
        let first = try file("Scan 1.pdf")
        let second = try file("Scan 2.pdf")
        try actions.share([first, second], title: "2 files")
        XCTAssertEqual(actions.shareRequest?.urls, [first, second])
        XCTAssertEqual(actions.shareRequest?.title, "2 files")
        XCTAssertNil(actions.previewURL)
    }

    @MainActor
    func test_shareNothing_isRefused() {
        let actions = makeActions(OpenedAddresses())
        XCTAssertThrowsError(try actions.share([], title: "Nothing"))
        XCTAssertNil(actions.shareRequest)
    }

    @MainActor
    func test_openWith_andEmail_useTheShareSheet() throws {
        let actions = makeActions(OpenedAddresses())
        let scan = try file("Scan 1.pdf")
        try actions.openWith(scan)
        XCTAssertEqual(actions.shareRequest?.urls, [scan])
        actions.shareRequest = nil
        try actions.composeEmail([scan])
        XCTAssertEqual(actions.shareRequest?.urls, [scan])
        XCTAssertEqual(actions.shareRequest?.title, SaveActions.shareTitle([scan]))
    }

    @MainActor
    func test_email_withMailSetUp_composesAMessage_withTheFilesAttached() throws {
        let actions = makeActions(OpenedAddresses(), mail: true)
        let first = try file("Scan 1.pdf")
        let second = try file("Scan 2.pdf")
        let probe: SendProbe = actions.sendProbe(for: [first])
        XCTAssertEqual(probe, SendProbe(canCompose: true, canShare: true))
        XCTAssertEqual(SaveActions.emailRoute(probe), SendRoute.compose)
        try actions.composeEmail([first, second])
        XCTAssertEqual(actions.mailRequest?.urls, [first, second])
        XCTAssertEqual(actions.mailRequest?.subject, "2 files")
        XCTAssertNil(actions.shareRequest)
        // Share still opens the share sheet.
        try actions.share([first], title: first.lastPathComponent)
        XCTAssertEqual(actions.shareRequest?.urls, [first])
        // The attachments as the composer adds them: each file's bytes and type.
        let attachments: [MailAttachment] = MailAttachment.of([first])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.mimeType, "application/pdf")
        XCTAssertEqual(attachments.first?.fileName, "Scan 1.pdf")
        XCTAssertEqual(attachments.first?.data, try Data(contentsOf: first))
        XCTAssertTrue(MailAttachment.of([folder.appendingPathComponent("gone.pdf")]).isEmpty)
    }

    @MainActor
    func test_open_previewsTheFile() throws {
        let actions = makeActions(OpenedAddresses())
        let scan = try file("Scan 1.pdf")
        try actions.open(scan)
        XCTAssertEqual(actions.previewURL, scan)
        XCTAssertNil(actions.shareRequest)
    }

    @MainActor
    func test_sendProbe_sharesButDoesNotCompose_soEmailGoesToTheShareSheet() throws {
        let actions = makeActions(OpenedAddresses())
        let scan = try file("Scan 1.pdf")
        let probe: SendProbe = actions.sendProbe(for: [scan])
        XCTAssertEqual(probe, SendProbe(canCompose: false, canShare: true))
        XCTAssertEqual(SaveActions.emailRoute(probe), SendRoute.shareSheet)
        XCTAssertEqual(SaveActions.shareRoute(probe), SendRoute.shareSheet)
    }

    @MainActor
    func test_reveal_opensTheFilesAppAtTheFolder() throws {
        let opened = OpenedAddresses()
        let actions = makeActions(opened)
        let scan = try file("Scan 1.pdf")
        actions.reveal([scan])
        XCTAssertEqual(opened.urls.count, 1)
        let address: URL = try XCTUnwrap(opened.urls.first)
        XCTAssertEqual(address.scheme, "shareddocuments")
        XCTAssertEqual(address.path, scan.deletingLastPathComponent().path)
        actions.reveal([])
        XCTAssertEqual(opened.urls.count, 1)
    }

    func test_filesAppURL_keepsTheFoldersPathEncoded_andNeedsALocalFile() throws {
        let scan = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Documents/CompleteScanner/My Scan.pdf")
        let address: URL = try XCTUnwrap(IOSFileActions.filesAppURL(for: [scan]))
        XCTAssertEqual(address.absoluteString,
                       "shareddocuments:///var/mobile/Containers/Data/Application/ABC/Documents/CompleteScanner/")
        let spaced = URL(fileURLWithPath: "/var/mobile/Documents/My Scans/Scan 1.pdf")
        XCTAssertEqual(IOSFileActions.filesAppURL(for: [spaced])?.absoluteString,
                       "shareddocuments:///var/mobile/Documents/My%20Scans/")
        let saveFolder = URL(fileURLWithPath: "/var/mobile/Documents/My Scans", isDirectory: true)
        XCTAssertEqual(IOSFileActions.filesAppURL(for: [saveFolder])?.absoluteString,
                       "shareddocuments:///var/mobile/Documents/My%20Scans/")
        XCTAssertNil(IOSFileActions.filesAppURL(for: []))
        let web: URL = try XCTUnwrap(URL(string: "https://example.com/scan.pdf"))
        XCTAssertNil(IOSFileActions.filesAppURL(for: [web]))
    }

    @MainActor
    func test_copyText_putsTheTextOnThePasteboard() throws {
        let actions = makeActions(OpenedAddresses())
        try actions.copyText("Invoice 1002")
        XCTAssertEqual(pasteboard?.string, "Invoice 1002")
    }

    @MainActor
    func test_copy_putsTheFiles_andASingleImagesPicture() throws {
        let actions = makeActions(OpenedAddresses())
        let pdf = try file("Scan 1.pdf")
        try actions.copy(ClipboardContent(files: [pdf], imageFile: nil))
        XCTAssertEqual(pasteboard?.numberOfItems, 1)
        XCTAssertEqual(pasteboard?.hasImages, false)

        let picture: URL = folder.appendingPathComponent("Photo 1.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image: UIImage = renderer.image { (context: UIGraphicsImageRendererContext) -> Void in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let png: Data = try XCTUnwrap(image.pngData())
        try png.write(to: picture)
        try actions.copy(ClipboardContent(files: [picture], imageFile: picture))
        XCTAssertEqual(pasteboard?.numberOfItems, 2)
        XCTAssertEqual(pasteboard?.hasImages, true)
    }

    @MainActor
    func test_copy_anUnreadablePicture_isRefused() throws {
        let actions = makeActions(OpenedAddresses())
        let broken = try file("Photo 1.png")
        XCTAssertThrowsError(try actions.copy(ClipboardContent(files: [broken], imageFile: broken)))
    }
}
#endif
