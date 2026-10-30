#if os(macOS)
import AppKit
import LazyScanKit
import Foundation
import UniformTypeIdentifiers

extension AppState {
    /// Picks photo files, or a `.lsdoc`, with the open panel: the photos are imported (`importPhotos`),
    /// the first `.lsdoc` is offered on the banner (`openPackage(at:)`).
    public func chooseAndImportPhotos() {
        guard canImportPhotos else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoImport.pickerTitle
        panel.message = PhotoImport.buttonHint
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (PhotoImport.fileExtensions + [CompanionPackage.fileExtension])
            .compactMap { UTType(filenameExtension: $0) }
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pictures
        }
        guard panel.runModal() == .OK else { return }
        let isPackage = { (url: URL) -> Bool in url.pathExtension.lowercased() == CompanionPackage.fileExtension }
        let photos = panel.urls.filter { !isPackage($0) }
        if !photos.isEmpty { importPhotos(photos) }
        if let package = panel.urls.first(where: isPackage) {
            Task { await openPackage(at: package) }
        }
    }

    /// The pictures Continuity Camera hands over (File > Import from iPhone or iPad: a photo, a scanned
    /// document) are imported as photo files dropped on the window are: each is written to a file in
    /// the temporary folder and the files go to `importPhotos`. Returns whether there was anything to take.
    /// While something runs they are refused and said in `errorMessage`: the menu stays enabled, and
    /// `importPhotos` would drop them without a word, with no file left anywhere else.
    func importFromDevice(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        guard !isBusy else {
            errorMessage = Self.deviceBusyMessage
            return false
        }
        // A folder per hand-over, so pictures named for the same second do not overwrite each other.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Continuity Camera", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let taken = Date()
        Task {
            var files: [URL] = []
            for (index, provider) in providers.enumerated() {
                if let file = await Self.pictureFile(provider, number: index + 1, taken: taken, in: folder) {
                    files.append(file)
                }
            }
            // A scan may have started while the pictures came over.
            guard !isBusy else {
                errorMessage = Self.deviceBusyMessage
                return
            }
            // TODO: the files stay until the system empties the temporary folder; importPhotos reads them later.
            importPhotos(files)
        }
        return true
    }

    private static let deviceBusyMessage =
        "The picture from your iPhone or iPad was not added while another task was running. Import it again once it has finished."

    /// The file's name is shown by the corner editor and in an error, so it is the provider's suggested
    /// name or the time the picture came over, written like a screenshot's: "Picture 2026-10-29 at
    /// 14.03.22.jpeg". Further pictures of a hand-over get " 2", " 3" before the extension.
    private nonisolated static func pictureFile(_ provider: NSItemProvider, number: Int, taken: Date,
                                                in folder: URL) async -> URL? {
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = provider.suggestedName.map { ($0 as NSString).deletingPathExtension }
            ?? "Picture \(stamp.string(from: taken))"
        let ext = type.preferredFilenameExtension ?? "jpg"
        let name = number == 1 ? "\(base).\(ext)" : "\(base) \(number).\(ext)"
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(name)
                    try data.write(to: url)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
#endif
