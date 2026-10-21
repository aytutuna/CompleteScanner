#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// The full-screen covers the scan screen opens: Apple's document scanner, or our own camera.
enum ScanCover: String, Identifiable {
    case scanner
    case camera

    var id: String { rawValue }
}

/// The scan screen: the task's step, the cameras and imports (`CaptureBar`), the scanner, the last scan,
/// the page strip, the status line, and Scan and Save (as a PDF or a JPEG a page, `IOSShell.saveFormats`);
/// once saved, the saved file with Share and Show in Files. Doc scanner opens Apple's document scanner,
/// Camera our own camera (`CameraScreen`).
struct ScanScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @State private var cover: ScanCover?
    @State private var scanner: IOSCameraAvailability = .noCamera

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stepCard
                    CaptureBar(offersScanner: IOSShell.offersCamera(state.activeTask), scanner: scanner,
                               onScanner: openScanner, offersCamera: IOSShell.offersOwnCamera(state.settings),
                               onCamera: openOwnCamera)
                    scannerRow
                    PreviewArea(image: state.canvasImage)
                }
                .padding(16)
            }
            Divider()
            PageStripView()
            Divider()
            bottomBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(state.activeTaskDefinition?.title ?? "Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            scanner = IOSCameraAvailability.current
        }
        .fullScreenCover(item: $cover) { (shown: ScanCover) in
            switch shown {
            case .scanner:
                DocumentCameraView(onFinish: cameraFinished, onCancel: closeCamera, onFail: cameraFailed)
                    .ignoresSafeArea()
            case .camera:
                CameraScreen(onClose: closeCamera)
                    .environmentObject(state)
                    .environmentObject(importer)
            }
        }
    }

    // MARK: Cameras

    private func openScanner() {
        scanner = IOSCameraAvailability.current
        guard scanner.isAvailable, importer.canImport else { return }
        cover = .scanner
    }

    /// Our own camera; its screen checks for a camera and asks for access the first time.
    private func openOwnCamera() {
        guard importer.canImport else { return }
        cover = .camera
    }

    private func closeCamera() {
        cover = nil
        scanner = IOSCameraAvailability.current
    }

    private func cameraFinished(_ images: [CGImage]) {
        closeCamera()
        let pages: [ScannedPage] = IOSDocumentCamera.pages(images)
        let session: IOSImportSession = importer
        Task { @MainActor in
            await session.bringInScans(pages)
        }
    }

    private func cameraFailed(_ message: String) {
        closeCamera()
        state.errorMessage = message
    }

    /// The current step's one-line prompt, with its fuller help below.
    @ViewBuilder
    private var stepCard: some View {
        if let step = state.taskFlow?.current {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.prompt)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.help)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("step.prompt")
        }
    }

    /// The scanner in use, with the others to pick from.
    private var scannerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "scanner")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Menu {
                ForEach(state.devices) { (device: ScannerInfo) in
                    Button(device.name) {
                        state.userSelectDevice(device.id)
                    }
                }
            } label: {
                Text(deviceName)
                    .lineLimit(1)
            }
            .disabled(state.isBusy)
            .accessibilityLabel(Text("Scanner: \(deviceName)"))
            .accessibilityIdentifier("scanner.menu")
            Spacer(minLength: 0)
            if state.isBusy {
                ProgressView()
                    .accessibilityIdentifier("busy")
            }
        }
    }

    private var deviceName: String {
        let selected: String? = state.selectedDeviceID
        let device: ScannerInfo? = state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })
        return device?.name ?? "No scanner"
    }

    /// Scan once the scanner is connected and nothing else runs.
    private var canScan: Bool {
        state.capabilities != nil && !state.isBusy
    }

    /// PDF or JPEG, while the queue is saved as one of them.
    private var formatChoice: Binding<OutputFormat> {
        let appState: AppState = state
        return Binding<OutputFormat>(
            get: { appState.settings.format.isImageFormat ? OutputFormat.jpeg : OutputFormat.pdf },
            set: { (format: OutputFormat) in
                appState.settings.format = format
            })
    }

    private func save() {
        if IOSShell.savesImages(state.settings) {
            state.saveImages()
        } else {
            state.savePDF()
        }
    }

    private var bottomBar: some View {
        let options: DocumentOptions = state.settings.document
        let plan: SavePlan = SavePlan.make(state.scannedPages, options: options)
        let saveTitle: String = IOSShell.saveTitle(state.settings, plan: plan)
        let saveCount: Int = plan.pageCount
        let formats: [OutputFormat] = IOSShell.saveFormats(state.settings)
        return VStack(alignment: .leading, spacing: 10) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .accessibilityLabel(Text(state.statusMessage))
                .accessibilityIdentifier("status.line")
            if !state.lastSavedURLs.isEmpty && !state.isBusy {
                SavedFilesRow()
            }
            if !formats.isEmpty {
                Picker("Save as", selection: formatChoice) {
                    ForEach(formats) { (format: OutputFormat) in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(state.isBusy)
                .accessibilityIdentifier("save.format")
            }
            HStack(spacing: 12) {
                if state.isBusy {
                    Button(role: .cancel) {
                        state.cancelScan()
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel.button")
                }
                Button {
                    state.performScan()
                } label: {
                    Text(state.primaryActionLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canScan)
                .accessibilityIdentifier("scan.button")
                Button {
                    save()
                } label: {
                    Text(saveTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy || importer.isImporting || saveCount == 0)
                .accessibilityIdentifier("save.button")
            }
        }
        .padding(16)
    }

    /// The status in six words at most (`StatusLine.shown`), as on the Mac's status bar.
    private var statusText: String {
        let idle: Bool = !state.isBusy
        let selected: String? = state.selectedDeviceID
        let device: String? = state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })?.name
        let savedShown: Bool = idle && !state.lastSavedURLs.isEmpty
        return StatusLine.shown(state.statusMessage, deviceName: device, reviewShown: false, savedShown: savedShown)
    }
}

/// The last scan (or "No scan yet").
private struct PreviewArea: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .accessibilityLabel(Text("Last scan"))
                    .accessibilityIdentifier("last.scan")
            } else {
                Text("No scan yet")
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }
}

/// The files saved last, with Share and Show in Files.
private struct SavedFilesRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let urls: [URL] = state.lastSavedURLs
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)
            Text(savedNames(urls))
                .font(.subheadline)
                .lineLimit(2)
                .accessibilityIdentifier("saved.files")
            Spacer(minLength: 0)
            Button {
                state.runFileAction(.share, urls: urls)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("share.button")
            Button {
                state.runFileAction(.reveal, urls: urls)
            } label: {
                Label("Show in Files", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(Text("Show in Files"))
            .accessibilityIdentifier("reveal.button")
        }
    }

    private func savedNames(_ urls: [URL]) -> String {
        var names: [String] = []
        for url in urls {
            names.append(url.lastPathComponent)
        }
        return names.joined(separator: ", ")
    }
}
#endif
