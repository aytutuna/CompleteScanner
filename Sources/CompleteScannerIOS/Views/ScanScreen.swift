#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI
import UIKit

/// The full-screen covers the scan screen opens: Apple's document scanner, our own camera, the flatbed
/// preview to choose the scan area on, (I13) the photo or receipt review and the ID card's review, (I14)
/// Quick scan's page and (I16) the photocopy's screen, which take the camera's place when they open.
enum ScanCover: String, Identifiable {
    case scanner
    case camera
    case crop
    case photoReview
    case idCardReview
    case quickScan
    case copy

    var id: String { rawValue }
}

/// The scan screen: the task's step, the cameras and imports (`CaptureBar`), the scanner, the flatbed
/// preview with the scan area (or the last scan), the page strip, the status line with a scan's progress,
/// and Scan and Save (as a PDF or a JPEG a page, `IOSShell.saveFormats`); once saved, the saved file with
/// Share and Show in Files. Camera opens our own camera (`CameraScreen`), the default; Use Apple's scanner
/// opens Apple's document scanner. The scanner row opens the scanner picker as a sheet on iPhone; on iPad
/// the picker is a sidebar beside the screen. The screen stays awake while a network scanner's job runs
/// (`IOSRootView`, since resizing the window builds this screen anew).
/// Save is shown for the tasks that collect pages; photos and receipts open the photo review once found
/// and the ID card its review once its sides are in, each full screen (in place of the camera). Since I14:
/// the camera's buttons between shots (No back, Now the backs, New document), how the two-sided task and
/// a book are taken, Separate documents' separator sheets, the PDF's size, Archive and Password, a book
/// page's spread split again (`SpreadSplitSheet`), and Quick scan's page full screen once taken. Since I15:
/// PDFs and pictures dropped on the screen are imported as Files' are, Command-S saves, and Settings
/// (Command-comma) is in the toolbar where the sidebar does not offer it. Since I16: the photocopy's pages
/// full screen once taken, to print over AirPrint (`CopyScreen`). Its covers and the spread's sheet
/// are the root view's (`ScanCovers`), so resizing the window across the width classes, which builds this
/// screen anew, leaves them open.
struct ScanScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.horizontalSizeClass) private var sizeClass: UserInterfaceSizeClass?
    /// The scanners to pick from.
    let picker: IOSScannerPickerModel
    @Binding var cover: ScanCover?
    @Binding var spreadEditor: SpreadEditorSource?
    /// The iPad's sidebar lists the scanners, so the scanner row only names the one in use.
    var pickerInSidebar: Bool = false
    /// Opens Settings; nil when the sidebar has it.
    var onOpenSettings: (() -> Void)?
    @State private var scanner: IOSCameraAvailability = .noCamera
    @State private var showsPicker: Bool = false

    var body: some View {
        Group {
            if sizeClass == .regular && !pickerInSidebar {
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let open = onOpenSettings {
                    Button {
                        open()
                    } label: {
                        Label(IOSSettingsText.title, systemImage: "gearshape")
                    }
                    .keyboardShortcut(IOSShortcuts.settings.keyboardShortcut)
                    .accessibilityIdentifier("scan.settings")
                }
            }
        }
        .dropDestination(for: IOSDroppedFile.self) { (items: [IOSDroppedFile], _: CGPoint) -> Bool in
            importDropped(items)
        }
        .onAppear {
            scanner = IOSCameraAvailability.current
            if state.showPhotoReview {
                cover = .photoReview
            } else if state.showIdCardReview {
                cover = .idCardReview
            } else if state.quickScanPage != nil {
                cover = .quickScan
            } else if !state.copyPages.isEmpty {
                cover = .copy
            }
        }
        .onChange(of: state.showPhotoReview) { (_: Bool, shown: Bool) in
            showReview(shown, as: .photoReview)
        }
        .onChange(of: state.showIdCardReview) { (_: Bool, shown: Bool) in
            showReview(shown, as: .idCardReview)
        }
        .onChange(of: state.quickScanPage != nil) { (_: Bool, shown: Bool) in
            showReview(shown, as: .quickScan)
        }
        .onChange(of: state.copyPages.isEmpty) { (_: Bool, empty: Bool) in
            showReview(!empty, as: .copy)
        }
        .onChange(of: cover) { (_: ScanCover?, shown: ScanCover?) in
            if shown == nil {
                scanner = IOSCameraAvailability.current
            }
        }
        .sheet(isPresented: $showsPicker) {
            ScannerPickerSheet(picker: picker, onClose: closePicker)
                .environmentObject(state)
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stepCard
                    TaskWayPicker()
                    CaptureBar(offersScanner: IOSShell.offersCamera(state.activeTask), scanner: scanner,
                               onScanner: openScanner, offersCamera: IOSShell.offersOwnCamera(state.settings),
                               onCamera: openOwnCamera)
                    CameraTaskButtons()
                    if let mismatch = state.sidesMismatch, state.cameraSides != nil {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                            .accessibilityIdentifier("task.mismatch")
                    }
                    SeparatorSheetRow()
                    scannerRow
                    PreviewArea(image: state.canvasImage, overview: state.overviewImage, onChooseArea: openCrop)
                    previewControls
                    if IOSShell.offersPDFOptions(state.settings) {
                        PDFOptionsSection()
                    }
                }
                .padding(16)
            }
            Divider()
            PageStripView(onEditSpread: openSpreadEditor)
            Divider()
            bottomBar
        }
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

    // MARK: Dropped files

    /// PDFs and pictures dropped on the screen come in as files picked in Files do, while this task takes
    /// photos and nothing else is being brought in.
    private func importDropped(_ items: [IOSDroppedFile]) -> Bool {
        guard !items.isEmpty, importer.canImport, IOSShell.takesPhotos(state.settings) else { return false }
        var imports: [IOSImportItem] = []
        for dropped in items {
            imports.append(dropped.item)
        }
        let session: IOSImportSession = importer
        Task { @MainActor in
            await session.importItems(imports)
        }
        return true
    }

    // MARK: The reviews

    /// A review opened (in place of the camera or another cover) or closed (saved, discarded, or a side of
    /// the ID card to take again).
    private func showReview(_ shown: Bool, as review: ScanCover) {
        if shown {
            cover = review
        } else if cover == review {
            cover = nil
        }
    }

    // MARK: A book's spread

    /// The split sheet for the spread the page was cut from, once its picture is read.
    private func openSpreadEditor(_ pageID: UUID) {
        let appState: AppState = state
        Task { @MainActor in
            spreadEditor = await appState.spreadEditor(for: pageID)
        }
    }

    // MARK: The scan area

    /// The flatbed preview full screen, to choose the scan area on (`CropScreen`).
    private func openCrop() {
        guard state.overviewImage != nil, !state.isBusy else { return }
        cover = .crop
    }

    /// The current step's one-line prompt, with its fuller help below (the camera's line in its place,
    /// `IOSShell.cameraLine`); the back of an ID card offers "No back side".
    @ViewBuilder
    private var stepCard: some View {
        if let step = state.taskFlow?.current {
            let camera: CameraStepText? = cameraLine
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera?.prompt ?? step.prompt)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(camera?.help ?? step.help)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("step.prompt")
                if state.canSkipStep {
                    Button(IdCardSteps.skipBackLabel) {
                        state.skipStep()
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .accessibilityIdentifier("step.skip")
                }
            }
        }
    }

    private var cameraLine: CameraStepText? {
        IOSShell.cameraLine(state.activeTask, options: state.settings.taskOptions, sides: state.cameraSides,
                            newDocument: state.newDocumentPending, turningOverByHand: state.isTurningOverByHand,
                            device: selectedDevice)
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
                    if !pickerBeside {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(pickerBeside)
            .accessibilityLabel(Text("Scanner: \(deviceName)"))
            .accessibilityIdentifier("scanner.menu")
            Spacer(minLength: 0)
            if state.isBusy {
                ProgressView()
                    .accessibilityIdentifier("busy")
            }
        }
    }

    /// The scanners are listed beside the screen (the iPad's sidebar, or the column of a wide window).
    private var pickerBeside: Bool {
        pickerInSidebar || sizeClass == .regular
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
        selectedDevice?.name ?? "No scanner"
    }

    private var selectedDevice: ScannerInfo? {
        let selected: String? = state.selectedDeviceID
        return state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })
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
        let collects: Bool = IOSShell.collectsPages(state.settings)
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
            if collects && !formats.isEmpty {
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
                if collects {
                    Button {
                        save()
                    } label: {
                        Text(saveTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy || importer.isImporting || saveCount == 0)
                    .keyboardShortcut(IOSShortcuts.save.keyboardShortcut)
                    .accessibilityIdentifier("save.button")
                }
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
        .containerRelativeFrame(Axis.Set.vertical) { (length: CGFloat, _: Axis) -> CGFloat in
            PreviewArea.height(for: length)
        }
    }

    /// About half the visible height, so it fits a phone, an iPad and any Stage Manager window size.
    static func height(for visible: CGFloat) -> CGFloat {
        min(max(visible * 0.45, 200), 560)
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

/// The scan screen's full-screen covers (Apple's scanner, our camera, the scan area, the reviews, Quick
/// scan's page) and a book spread's split sheet. The root view presents them, not the scan screen: the
/// window's two layouts each build their own scan screen, and one going away would close them mid-task.
@MainActor
struct ScanCovers: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var importer: IOSImportSession
    @Binding var cover: ScanCover?
    @Binding var spreadEditor: SpreadEditorSource?

    func body(content: Content) -> some View {
        content
            .sheet(item: $spreadEditor) { (source: SpreadEditorSource) in
                SpreadSplitSheet(source: source, onClose: closeSpreadEditor)
                    .environmentObject(state)
            }
            .fullScreenCover(item: $cover) { (shown: ScanCover) in
                switch shown {
                case .scanner:
                    DocumentCameraView(onFinish: cameraFinished, onCancel: closeCover, onFail: cameraFailed)
                        .ignoresSafeArea()
                case .camera:
                    CameraScreen(onClose: closeCover)
                        .environmentObject(state)
                        .environmentObject(importer)
                case .crop:
                    CropScreen(onClose: closeCover)
                        .environmentObject(state)
                case .photoReview:
                    PhotoReviewScreen(model: IOSPhotoReviewModel(state: state))
                        .environmentObject(state)
                case .idCardReview:
                    IdCardReviewScreen(model: IOSPhotoReviewModel(state: state))
                        .environmentObject(state)
                case .quickScan:
                    QuickScanScreen(model: IOSQuickScanModel(state: state))
                        .environmentObject(state)
                case .copy:
                    CopyScreen(model: IOSCopyModel(state: state))
                        .environmentObject(state)
                }
            }
    }

    private func closeCover() {
        cover = nil
    }

    private func closeSpreadEditor() {
        spreadEditor = nil
    }

    private func cameraFinished(_ images: [CGImage]) {
        closeCover()
        let pages: [ScannedPage] = IOSDocumentCamera.pages(images)
        let session: IOSImportSession = importer
        Task { @MainActor in
            await session.bringInScans(pages)
        }
    }

    private func cameraFailed(_ message: String) {
        closeCover()
        state.errorMessage = message
    }
}
#endif
