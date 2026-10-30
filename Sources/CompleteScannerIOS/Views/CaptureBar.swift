#if os(iOS)
import CompleteScannerKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The capture bar of the printer screen: the last page with how many the queue holds (it opens the page
/// strip in a sheet, `onPages`, and bumps with a tap felt as a page comes in) and Photos and Files
/// (`ImportButtons`), with an import's progress above them while one runs (Stop while more photos or
/// pages follow). Imported photos go to the corner editor one by one (`IOSImportSession`); the root view
/// shows it. Scan is on the action row beside Save, and the camera's shutter is camera mode's
/// (`CameraScreen`).
struct CaptureBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Opens the page strip.
    let onPages: @MainActor () -> Void

    /// The most photos picked at once.
    static let maxPicked: Int = 50

    @State private var bumped: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if importer.progressText != nil {
                ImportProgressRow()
            }
            HStack(alignment: .center, spacing: 12) {
                pagesButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                ImportButtons()
            }
        }
    }

    /// The last page taken and the count; it opens the page strip.
    private var pagesButton: some View {
        let count: Int = state.scannedPages.count
        let last: CGImage? = state.scannedPages.last?.image
        return Button {
            onPages()
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let image = last {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 40, height: 52)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(uiColor: .separator), lineWidth: 1))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(uiColor: .tertiaryLabel), style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .frame(width: 40, height: 52)
                    }
                }
                .scaleEffect(bumped ? 1.3 : 1)
                Text(IOSCameraText.pageCount(count))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .onChange(of: count) { (old: Int, new: Int) in
            guard new > old, !reduceMotion else { return }
            withAnimation(.spring(duration: 0.15)) {
                bumped = true
            } completion: {
                withAnimation(.spring(duration: 0.55, bounce: 0.25)) {
                    bumped = false
                }
            }
        }
        .sensoryFeedback(SensoryFeedback.impact(weight: SensoryFeedback.Weight.medium), trigger: count) { (old: Int, new: Int) -> Bool in
            new > old
        }
        .accessibilityLabel(Text(IOSCameraText.pageCount(count)))
        .accessibilityHint(Text(IOSCameraText.pagesHint))
        .accessibilityIdentifier("capture.pages")
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

/// An import's progress ("Importing photo 2 of 5…", a shot's "Reading the photo…") with Stop while more
/// photos or pages follow the one in hand, on the capture bar and over camera mode's viewfinder.
struct ImportProgressRow: View {
    @EnvironmentObject private var importer: IOSImportSession

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                Text(importer.progressText ?? "")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("import.progress")
            Spacer(minLength: 0)
            if importer.canStop {
                Button(role: .cancel) {
                    importer.stop()
                } label: {
                    Text(IOSImportText.stopLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(Text("Ends the import after this photo or page"))
                .accessibilityIdentifier("import.stop")
            }
        }
    }
}

/// Photos (the system's photo picker, several in the order picked) and Files (photos and PDFs, and a
/// CompleteScanner document, which goes to the scan screen's banner instead), as icons on the capture bar
/// and, in grey circles (`round`), on camera mode's bar, which rests its camera while one is open
/// (`onPresenting`). Each picked photo is loaded only when its turn comes.
struct ImportButtons: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    var round: Bool = false
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
                      allowedContentTypes: [UTType.image, UTType.pdf, IOSShell.packageType],
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
        Image(systemName: symbol)
            .font(round ? Font.body : Font.title3)
            .foregroundStyle(round ? Color.primary : Color.accentColor)
            .frame(width: 44, height: 44)
            .background {
                if round {
                    Circle()
                        .fill(Color(uiColor: .tertiarySystemFill))
                }
            }
            .contentShape(Rectangle())
    }
}

/// The shutter shrinks while pressed; with Reduce Motion it only dims.
struct ShutterButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(reduceMotion ? Animation.easeInOut(duration: 0.2) : Animation.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Apple's document scanner on the Document, Email and Word tasks: a secondary way in, in camera mode's
/// options drawer (Camera), dimmed with one short line where it cannot run (as in the Simulator).
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
