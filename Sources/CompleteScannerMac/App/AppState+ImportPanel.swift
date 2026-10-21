#if os(macOS)
import AppKit
import CompleteScannerKit
import Foundation
import UniformTypeIdentifiers

extension AppState {
    /// Picks photo files with the open panel and imports them (`importPhotos`).
    public func chooseAndImportPhotos() {
        guard canImportPhotos else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoImport.pickerTitle
        panel.message = PhotoImport.buttonHint
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PhotoImport.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pictures
        }
        guard panel.runModal() == .OK else { return }
        importPhotos(panel.urls)
    }
}
#endif
