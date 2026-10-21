#if os(iOS)
import CompleteScannerKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The ways pages come in besides the scanner: Doc scanner (Apple's document scanner, on the Document,
/// Email and Word tasks, still their default; dimmed with one short line where there is none, as in the
/// Simulator), Camera (our own camera, `CameraScreen`, on every task that collects pages; its screen
/// says why when there is no camera or access is off), Photos (the system's photo picker, several in
/// the order picked) and Files (photos and PDFs). Imported photos go to the corner editor one by one
/// (`IOSImportSession`); the root view shows it. Each picked photo is loaded only when its turn comes;
/// while an import runs, its progress shows with Stop.
struct CaptureBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    /// Whether the task opens Apple's scanner.
    let offersScanner: Bool
    /// Whether Apple's scanner can be opened here.
    let scanner: IOSCameraAvailability
    /// Opens Apple's scanner.
    let onScanner: @MainActor () -> Void
    /// Whether our own camera is offered (the task collects pages).
    let offersCamera: Bool
    /// Opens our own camera.
    let onCamera: @MainActor () -> Void

    @State private var picked: [PhotosPickerItem] = []
    @State private var showsFiles: Bool = false

    /// The most photos picked at once.
    static let maxPicked: Int = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if offersScanner {
                // Four ways in: the two cameras above, the imports below.
                HStack(spacing: 10) {
                    scannerButton
                    if offersCamera {
                        cameraButton
                    }
                }
                HStack(spacing: 10) {
                    photosButton
                    filesButton
                }
            } else {
                HStack(spacing: 10) {
                    if offersCamera {
                        cameraButton
                    }
                    photosButton
                    filesButton
                }
            }
            if offersScanner, let reason = scanner.reason {
                HStack(spacing: 6) {
                    Image(systemName: "camera.badge.ellipsis")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(reason)
                        .font(.caption)
                        .accessibilityIdentifier("camera.reason")
                    if scanner.opensSettings {
                        Button("Settings") {
                            openSettings()
                        }
                        .font(.caption)
                    }
                }
                .foregroundStyle(Color.secondary)
            }
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
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [UTType.image, UTType.pdf],
                      allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
            switch result {
            case .success(let urls):
                let session: IOSImportSession = importer
                Task { @MainActor in
                    await session.importFiles(urls)
                }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
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

    /// Apple's document scanner (the Document, Email and Word tasks' default), dimmed where it cannot run.
    private var scannerButton: some View {
        Button {
            onScanner()
        } label: {
            Label(IOSImportText.scannerLabel, systemImage: "doc.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!scanner.isAvailable || !importer.canImport)
        .accessibilityLabel(Text(IOSImportText.scannerName))
        .accessibilityHint(Text(scanner.reason ?? "Finds each page and takes it when steady"))
        .accessibilityIdentifier("capture.camera")
    }

    /// Our own camera; its screen says why when there is no camera or access is off.
    private var cameraButton: some View {
        Button {
            onCamera()
        } label: {
            Label(IOSImportText.cameraLabel, systemImage: "camera")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!importer.canImport)
        .accessibilityHint(Text("Shows the page's outline live; you take each photo"))
        .accessibilityIdentifier("capture.live")
    }

    private var photosButton: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: CaptureBar.maxPicked, selectionBehavior: .ordered,
                     matching: .images, preferredItemEncoding: .current) {
            Label(IOSImportText.photosLabel, systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!importer.canImport)
        .accessibilityIdentifier("import.photos")
    }

    private var filesButton: some View {
        Button {
            showsFiles = true
        } label: {
            Label(IOSImportText.filesLabel, systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!importer.canImport)
        .accessibilityIdentifier("import.files")
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

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
#endif
