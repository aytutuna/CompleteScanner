#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI
import UIKit

/// The full-screen covers the scan screen opens: Apple's document scanner, our own camera, or the flatbed
/// preview to choose the scan area on.
enum ScanCover: String, Identifiable {
    case scanner
    case camera
    case crop

    var id: String { rawValue }
}

/// The scan screen: the task's step, the cameras and imports (`CaptureBar`), the scanner, the flatbed
/// preview with the scan area (or the last scan), the page strip, the status line with a scan's progress,
/// and Scan and Save (as a PDF or a JPEG a page, `IOSShell.saveFormats`); once saved, the saved file with
/// Share and Show in Files. Camera opens our own camera (`CameraScreen`), the default; Use Apple's scanner
/// opens Apple's document scanner. The scanner row opens the scanner picker as a sheet on iPhone; on iPad
/// the picker is a sidebar beside the screen. The screen stays awake while a network scanner's job runs.
struct ScanScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.horizontalSizeClass) private var sizeClass: UserInterfaceSizeClass?
    /// The scanners to pick from.
    let picker: IOSScannerPickerModel
    @State private var cover: ScanCover?
    @State private var scanner: IOSCameraAvailability = .noCamera
    @State private var showsPicker: Bool = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    ScannerPickerList(picker: picker)
                        .frame(width: 320)
                        .accessibilityIdentifier("scanners.sidebar")
                    Divider()
                    mainColumn
                }
            } else {
                mainColumn
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(state.activeTaskDefinition?.title ?? "Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            scanner = IOSCameraAvailability.current
        }
        .onChange(of: state.isBusy) { (_: Bool, busy: Bool) in
            keepAwake(busy)
        }
        .onDisappear {
            keepAwake(false)
        }
        .sheet(isPresented: $showsPicker) {
            ScannerPickerSheet(picker: picker, onClose: closePicker)
                .environmentObject(state)
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
            case .crop:
                CropScreen(onClose: closeCrop)
                    .environmentObject(state)
            }
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stepCard
                    CaptureBar(offersScanner: IOSShell.offersCamera(state.activeTask), scanner: scanner,
                               onScanner: openScanner, offersCamera: IOSShell.offersOwnCamera(state.settings),
                               onCamera: openOwnCamera)
                    scannerRow
                    PreviewArea(image: state.canvasImage, overview: state.overviewImage, onChooseArea: openCrop)
                    previewControls
                }
                .padding(16)
            }
            Divider()
            PageStripView()
            Divider()
            bottomBar
        }
    }

    // MARK: The screen kept awake

    /// While a network scanner's job runs, the screen stays on: iOS would suspend the app soon after it
    /// locked, cutting a feeder batch short.
    private func keepAwake(_ busy: Bool) {
        let selected: String? = state.selectedDeviceID
        let device: ScannerInfo? = state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })
        UIApplication.shared.isIdleTimerDisabled = IOSShell.keepsScreenAwake(isBusy: busy, device: device)
    }

    // MARK: The scanner picker

    private func openPicker() {
        showsPicker = true
    }

    private func closePicker() {
        showsPicker = false
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

    // MARK: The scan area

    /// The flatbed preview full screen, to choose the scan area on (`CropScreen`).
    private func openCrop() {
        guard state.overviewImage != nil, !state.isBusy else { return }
        cover = .crop
    }

    private func closeCrop() {
        cover = nil
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

    /// The scanner in use, with how it is reached; on iPhone it opens the scanner picker.
    private var scannerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "scanner")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Button(action: openPicker) {
                HStack(spacing: 6) {
                    Text(deviceName)
                        .lineLimit(1)
                    if let note = deviceNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                            .accessibilityIdentifier("scanner.note")
                    }
                    if sizeClass != .regular {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(sizeClass == .regular)
            .accessibilityLabel(Text("Scanner: \(deviceName)"))
            .accessibilityIdentifier("scanner.menu")
            Spacer(minLength: 0)
            if state.isBusy {
                ProgressView()
                    .accessibilityIdentifier("busy")
            }
        }
    }

    /// "Not encrypted" for a network scanner reached over plain HTTP after HTTPS could not be used.
    private var deviceNote: String? {
        let selected: String? = state.selectedDeviceID
        for row in picker.rows where row.id == selected {
            return row.note
        }
        return nil
    }

    /// Preview (the flatbed's overview) while the flatbed is used, Choose area once there is one (the
    /// preview full screen, `CropScreen`), and Clear selection once an area is chosen.
    @ViewBuilder
    private var previewControls: some View {
        let flatbed: Bool = state.capabilities?.sources.contains(.flatbed) == true && state.settings.source == .flatbed
        if flatbed {
            HStack(spacing: 12) {
                Button {
                    state.performOverview()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy)
                .accessibilityIdentifier("preview.button")
                if state.overviewImage != nil {
                    Button {
                        openCrop()
                    } label: {
                        Label("Choose area", systemImage: "crop")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .accessibilityIdentifier("crop.open")
                }
                if state.overviewImage != nil && state.selectionRect != nil {
                    Button {
                        state.selectionRect = nil
                    } label: {
                        Label("Clear selection", systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(state.isBusy)
                    .accessibilityLabel(Text("Clear selection"))
                    .accessibilityIdentifier("crop.clear")
                }
                Spacer(minLength: 0)
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
            if state.isBusy {
                ScanProgressRow(progress: state.progress)
            }
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

/// A scan's progress: the scanner's message ("Transferring page 3…", which counts a feeder's pages) with a
/// bar, determinate when the scanner says how far it is.
private struct ScanProgressRow: View {
    let progress: ScanProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if let message = progress?.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan.progress")
    }
}

/// The flatbed preview with its scan area when there is one, else the last scan (or "No scan yet"). The
/// preview is only shown here, in the scrolling column (a drag on it scrolls); tapping it opens it full
/// screen to choose the area on (`onChooseArea`).
private struct PreviewArea: View {
    @EnvironmentObject private var state: AppState
    let image: CGImage?
    let overview: CGImage?
    let onChooseArea: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
            if let overview {
                Button(action: onChooseArea) {
                    FlatbedThumbnail(image: overview)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
                .accessibilityLabel(Text("Flatbed preview"))
                .accessibilityValue(Text("Scan area: " + IOSCropGeometry.describe(state.selectionRect)))
                .accessibilityHint(Text("Opens it full screen to choose the scan area."))
                .accessibilityIdentifier("flatbed.preview")
            } else if let image {
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
