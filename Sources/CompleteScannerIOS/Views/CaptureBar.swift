#if os(iOS)
import CompleteScannerKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The capture bar along the bottom of the scan screen: the last page taken with how many the queue holds
/// (it shows or hides the page strip, `onPages`), the shutter, which opens our own camera (`CameraScreen`,
/// the default way to take pages on every task that takes photos; its screen says why when there is no
/// camera or access is off), and Photos and Files (`ImportButtons`). Imported photos go to the corner
/// editor one by one (`IOSImportSession`); the root view shows it. While an import runs, its progress shows
/// with Stop. Apple's document scanner is further up, below the preview (`AppleScannerRow`).
struct CaptureBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    /// Whether our own camera is offered (the task takes photos).
    let offersCamera: Bool
    /// Opens our own camera.
    let onCamera: @MainActor () -> Void
    /// The page strip is shown.
    let stripShown: Bool
    /// Shows or hides the page strip.
    let onPages: @MainActor () -> Void

    /// The most photos picked at once.
    static let maxPicked: Int = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = importer.progressText {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("import.progress")
                    Spacer(minLength: 0)
                    if importer.isImporting {
                        Button(role: .cancel) {
                            importer.stop()
                        } label: {
                            Text(IOSImportText.stopLabel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint(Text("Ends the import after this photo"))
                        .accessibilityIdentifier("import.stop")
                    }
                }
            }
            HStack(alignment: .center, spacing: 12) {
                pagesButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                if offersCamera {
                    shutterButton
                }
                ImportButtons()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// The last page taken and the count; it shows or hides the page strip.
    private var pagesButton: some View {
        let count: Int = state.scannedPages.count
        let last: CGImage? = state.scannedPages.last?.image
        return Button {
            onPages()
        } label: {
            HStack(spacing: 8) {
                if let image = last {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 46)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 36, height: 46)
                }
                Text(IOSCameraText.pageCount(count))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel(Text(IOSCameraText.pageCount(count)))
        .accessibilityValue(Text(stripShown ? "Page strip shown" : "Page strip hidden"))
        .accessibilityHint(Text(IOSCameraText.pagesHint))
        .accessibilityIdentifier("capture.pages")
    }

    /// Our own camera, the default way to take pages; its screen says why when there is no camera or
    /// access is off.
    private var shutterButton: some View {
        Button {
            onCamera()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 60, height: 60)
                Circle()
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 4)
                    .frame(width: 70, height: 70)
                Image(systemName: "camera.fill")
                    .font(.title2)
                    .foregroundStyle(Color.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!importer.canImport)
        .opacity(importer.canImport ? 1 : 0.4)
        .accessibilityLabel(Text(IOSImportText.cameraLabel))
        .accessibilityHint(Text(IOSCameraText.cameraHint))
        .accessibilityIdentifier("capture.camera")
    }

    /// The picked photos in the order picked, each loaded only when its turn comes (`load`), so one
    /// photo's bytes are in memory at a time.
    static func sources(_ items: [PhotosPickerItem]) -> [IOSImportSource] {
        var sources: [IOSImportSource] = []
        for item in items {
            let source = IOSImportSource(name: PhotoImport.label, expectedKind: .image) { () async -> Result<IOSImportItem, IOSImportError> in
                await CaptureBar.load(item)
            }
            sources.append(source)
        }
        return sources
    }

    /// The picked photo's own bytes, named "Photo"; `photoNotLoadedMessage` when the library could not
    /// hand it over.
    static func load(_ item: PhotosPickerItem) async -> Result<IOSImportItem, IOSImportError> {
        do {
            let image: IOSPickedImage? = try await item.loadTransferable(type: IOSPickedImage.self)
            if let loaded = image {
                return .success(IOSImportItem(name: PhotoImport.label, data: loaded.data, kind: .image))
            }
        } catch {
            // Told below, as for a photo that did not come.
        }
        return .failure(IOSImportError(message: IOSImportText.photoNotLoadedMessage))
    }
}

/// Photos (the system's photo picker, several in the order picked) and Files (photos and PDFs, and a
/// CompleteScanner document, which goes to the scan screen's banner instead), on the capture bar and, white
/// on black (`onDark`), on our camera's screen, which rests its camera while one is open (`onPresenting`)
/// and offers no CompleteScanner document, as its banner would be hidden under the camera.
/// Each picked photo is loaded only when its turn comes.
struct ImportButtons: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    var onDark: Bool = false
    /// Photos or Files opened (true) or closed.
    var onPresenting: (@MainActor (Bool) -> Void)?

    @State private var picked: [PhotosPickerItem] = []
    @State private var showsPhotos: Bool = false
    @State private var showsFiles: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showsPhotos = true
            } label: {
                label(IOSImportText.photosLabel, symbol: "photo.on.rectangle")
            }
            .accessibilityLabel(Text(IOSImportText.photosLabel))
            .accessibilityIdentifier("import.photos")
            Button {
                showsFiles = true
            } label: {
                label(IOSImportText.filesLabel, symbol: "folder")
            }
            .accessibilityLabel(Text(IOSImportText.filesLabel))
            .accessibilityIdentifier("import.files")
        }
        .buttonStyle(.plain)
        .disabled(!importer.canImport)
        .opacity(importer.canImport ? 1 : 0.4)
        .photosPicker(isPresented: $showsPhotos, selection: $picked, maxSelectionCount: CaptureBar.maxPicked,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .fileImporter(isPresented: $showsFiles,
                      allowedContentTypes: onDark ? [UTType.image, UTType.pdf] : [UTType.image, UTType.pdf, IOSShell.packageType],
                      allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
            switch result {
            case .success(let urls):
                let session: IOSImportSession = importer
                let appState: AppState = state
                var imports: [URL] = []
                for url in urls {
                    if IOSShell.isPackage(url) {
                        Task { @MainActor in
                            await IOSShell.openPackage(url, in: appState)
                        }
                    } else {
                        imports.append(url)
                    }
                }
                let files: [URL] = imports
                Task { @MainActor in
                    await session.importFiles(files)
                }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: showsPhotos || showsFiles) { (_: Bool, shown: Bool) in
            onPresenting?(shown)
        }
        .onChange(of: picked) { (_: [PhotosPickerItem], items: [PhotosPickerItem]) in
            guard !items.isEmpty else { return }
            picked = []
            let session: IOSImportSession = importer
            let sources: [IOSImportSource] = CaptureBar.sources(items)
            Task { @MainActor in
                await session.importSources(sources)
            }
        }
    }

    private func label(_ title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
            Text(title)
                .font(.caption2)
        }
        .foregroundStyle(onDark ? Color.white : Color.accentColor)
        .frame(width: 56, height: 48)
        .contentShape(Rectangle())
    }
}

/// Apple's document scanner on the Document, Email and Word tasks: a secondary way in, below the scan
/// screen's preview, dimmed with one short line where it cannot run (as in the Simulator).
struct AppleScannerRow: View {
    @EnvironmentObject private var importer: IOSImportSession
    /// Whether Apple's scanner can be opened here.
    let scanner: IOSCameraAvailability
    /// Opens Apple's scanner.
    let onScanner: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onScanner()
            } label: {
                Label(IOSImportText.scannerLabel, systemImage: "doc.viewfinder")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
            .disabled(!scanner.isAvailable || !importer.canImport)
            .accessibilityLabel(Text(IOSImportText.scannerName))
            .accessibilityHint(Text(scanner.reason ?? "Apple's scanner finds each page and takes it"))
            .accessibilityIdentifier("capture.scanner")
            if let reason = scanner.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("scanner.reason")
                if scanner.opensSettings {
                    Button(IOSCameraText.settingsLabel) {
                        openSettings()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
#endif
