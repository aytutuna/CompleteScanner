#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
/// and Scan and Save (as a PDF, a JPEG a page, Word or text, `IOSShell.exportFormats`); once saved, the
/// saved file with Share and Show in Files. Camera opens our own camera (`CameraScreen`), the default; Use Apple's scanner
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
/// full screen once taken, to print over AirPrint (`CopyScreen`). While Save writes a PDF, the menu beside
/// it can also add the pages to the end of a PDF picked in Files (`AppState.appendToPDF(at:)`); with a PDF
/// picked in the task list (`AppState.appendTarget`) Save adds them to that one. Since I18: a
/// CompleteScanner document opened in the app or picked in Files is offered on a banner (Add to pages,
/// Open as new), and the queue can be shared as one (`IOSShell.sharePackage`). Since I20: with a computer
/// paired, Send to computer sends the queue to it as a new document or into the one open there
/// (`AppState.sendQueueToDesktop`), the status line saying how it went. Its covers and the
/// spread's sheet are the root view's (`ScanCovers`), so resizing the window across the width classes,
/// which builds this screen anew, leaves them open. On the iPhone it is the app's first screen: the task
/// chip at the top opens the task sheet (`onOpenTasks`), the library (`onOpenLibrary`) and Settings sit
/// beside it, and the capture bar (`CaptureBar`) is right above Save; the step card shows only while a step
/// needs it (`IOSShell.showsStepCard`), the scanner row while a scanner is listed, and the preview once
/// there is one (else the camera's line, centred in its place). Options below it, collapsed, holds what
/// the task sheet no longer asks: the flatbed's Preview, then Scanner (Source, Sides, Resolution, Color),
/// Camera (Both sides and how, Apple's scanner), Book, Photos (Restore faded colours) and Export (the
/// format, Separate documents, One PDF per page, the PDF's choices), each where it applies. Save's menu
/// adds the pages to a PDF, prints them as a copy (Print…) or saves and emails them (Email…). The capture
/// bar's last page opens the page strip in a sheet.
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
    /// Opens the task sheet (iPhone); nil when the sidebar lists the tasks.
    var onOpenTasks: (() -> Void)?
    /// Opens the library (iPhone); nil when the sidebar has it.
    var onOpenLibrary: (() -> Void)?
    @State private var scanner: IOSCameraAvailability = .noCamera
    /// The page strip's sheet, opened from the capture bar's last page.
    @State private var pagesShown: Bool = false
    /// A book page whose spread is split again once the page strip's sheet has closed.
    @State private var spreadAfterPages: UUID?
    @State private var optionsShown: Bool = false
    @State private var showsPicker: Bool = false
    /// Files is open to pick the PDF the pages are added to.
    @State private var picksPDF: Bool = false
    /// The queue is being written to be shared as a CompleteScanner document.
    @State private var sharesPackage: Bool = false
    /// Send to computer asks where the pages go.
    @State private var asksSendTarget: Bool = false
    /// The queue is being written and sent to the paired computer.
    @State private var sendsToComputer: Bool = false

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
        .navigationTitle(IOSShell.shownKind(state.settings).title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let open = onOpenLibrary {
                    Button {
                        open()
                    } label: {
                        Label(IOSSettingsText.libraryLabel, systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("open.library")
                }
            }
            ToolbarItem(placement: .principal) {
                if let open = onOpenTasks {
                    TaskChip(title: IOSShell.shownKind(state.settings).title, onTap: open)
                }
            }
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
        .sheet(isPresented: $pagesShown, onDismiss: pagesClosed) {
            PageStripSheet(onEditSpread: editSpreadFromPages, onClose: closePages)
                .environmentObject(state)
        }
        .onChange(of: state.scannedPages.isEmpty) { (_: Bool, empty: Bool) in
            if empty {
                pagesShown = false
            }
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stepCard
                    CameraTaskButtons()
                    if let mismatch = state.sidesMismatch, state.cameraSides != nil {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                            .accessibilityIdentifier("task.mismatch")
                    }
                    if !state.devices.isEmpty {
                        scannerRow
                    }
                    previewOrHint
                    if hasOptions {
                        DisclosureGroup(isExpanded: $optionsShown) {
                            options
                                .padding(.top, 8)
                        } label: {
                            Text("Options")
                                .accessibilityIdentifier("options.group")
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            bottomBar
        }
    }

    /// The flatbed preview or the last scan; with neither, the camera's line centred where the preview
    /// would be, unless the step card already says what to do.
    @ViewBuilder
    private var previewOrHint: some View {
        if state.canvasImage != nil {
            PreviewArea(image: state.canvasImage, overview: state.overviewImage, onChooseArea: openCrop)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("preview.area")
        } else if !showsStepCard, let camera = cameraLine {
            VStack(spacing: 6) {
                Text(camera.prompt)
                if let device = selectedDevice {
                    Text("Or scan from \(device.name).")
                        .font(.footnote)
                }
            }
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(Axis.Set.vertical) { (length: CGFloat, _: Axis) -> CGFloat in
                PreviewArea.height(for: length)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("preview.area")
        }
    }

    /// Options' sections, each only where it applies: the scanner's while one is selected, the camera's for a
    /// document (the shutter takes pages whatever scanner is selected), the book's and the photos' for their
    /// kinds, and Export while the pages are collected and saved here.
    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            previewControls
            if selectedDevice != nil {
                optionsGroup("Scanner") {
                    ScannerSettingsRows()
                }
            }
            if showsCameraOptions {
                optionsGroup("Camera") {
                    BothSidesToggle()
                    TaskWayPicker()
                    if IOSShell.offersCamera(state.activeTask) {
                        AppleScannerRow(scanner: scanner, onScanner: openScanner)
                    }
                }
            }
            if state.activeTask == .book {
                optionsGroup("Book") {
                    TaskWayPicker()
                }
            }
            if IOSShell.shownKind(state.settings) == .photos {
                optionsGroup("Photos") {
                    RestoreToggle()
                }
            }
            if IOSShell.collectsPages(state.settings) {
                optionsGroup("Export") {
                    ExportOptions()
                }
            }
        }
    }

    private func optionsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var showsCameraOptions: Bool {
        IOSShell.shownKind(state.settings) == .document
    }

    /// Whether Options has anything in it for this task and scanner.
    private var hasOptions: Bool {
        usesFlatbed || selectedDevice != nil || showsCameraOptions || state.activeTask == .book
            || IOSShell.shownKind(state.settings) == .photos || IOSShell.collectsPages(state.settings)
    }

    // MARK: The page strip

    private func openPages() {
        pagesShown = true
    }

    private func closePages() {
        pagesShown = false
    }

    /// The root view presents the split sheet, which it cannot while the strip's sheet is up.
    private func editSpreadFromPages(_ pageID: UUID) {
        spreadAfterPages = pageID
        pagesShown = false
    }

    private func pagesClosed() {
        guard let pageID = spreadAfterPages else { return }
        spreadAfterPages = nil
        openSpreadEditor(pageID)
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
        if let step = state.taskFlow?.current, showsStepCard {
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

    private var showsStepCard: Bool {
        IOSShell.showsStepCard(state.activeTask, options: state.settings.taskOptions, sides: state.cameraSides,
                               newDocument: state.newDocumentPending, turningOverByHand: state.isTurningOverByHand,
                               device: selectedDevice)
    }

    private var cameraLine: CameraStepText? {
        IOSShell.cameraLine(state.activeTask, options: state.settings.taskOptions, sides: state.cameraSides,
                            newDocument: state.newDocumentPending, turningOverByHand: state.isTurningOverByHand,
                            device: selectedDevice)
    }

    /// The scanner in use, with how it is reached (on iPhone it opens the scanner picker), and Scan.
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
            Button {
                state.performScan()
            } label: {
                Text(state.primaryActionLabel)
            }
            .buttonStyle(.bordered)
            .disabled(!canScan)
            .accessibilityIdentifier("scan.button")
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
        if usesFlatbed {
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

    private var usesFlatbed: Bool {
        state.capabilities?.sources.contains(.flatbed) == true && state.settings.source == .flatbed
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

    private func save() {
        if savesImages {
            state.saveImages()
        } else {
            state.savePDF()
        }
    }

    /// Email… in Save's menu: this save only is sent by email once written.
    private func saveAndEmail() {
        state.saveAndEmail(images: savesImages)
    }

    private var savesImages: Bool {
        state.appendTarget == nil && IOSShell.savesImages(state.settings)
    }

    private func sharePackage() {
        sharesPackage = true
        let appState: AppState = state
        Task { @MainActor in
            await IOSShell.sharePackage(appState)
            sharesPackage = false
        }
    }

    private func sendToComputer(_ target: CompanionTarget) {
        sendsToComputer = true
        let appState: AppState = state
        Task { @MainActor in
            await appState.sendQueueToDesktop(target: target)
            sendsToComputer = false
        }
    }

    private var bottomBar: some View {
        let options: DocumentOptions = state.settings.document
        let plan: SavePlan = SavePlan.make(state.scannedPages, options: options)
        let saveTitle: String = Self.saveTitle(state.settings, plan: plan, target: state.appendTarget)
        let saveCount: Int = plan.pageCount
        let collects: Bool = IOSShell.collectsPages(state.settings)
        return VStack(alignment: .leading, spacing: 10) {
            if state.isBusy {
                HStack(spacing: 12) {
                    ScanProgressRow(progress: state.progress)
                    Button(role: .cancel) {
                        state.cancelScan()
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel.button")
                }
            }
            if let offered = state.pendingPackage {
                PackageBanner(offered: offered)
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
            CaptureBar(offersCamera: IOSShell.offersOwnCamera(state.settings), onCamera: openOwnCamera,
                       onPages: openPages)
            if collects {
                HStack(spacing: 12) {
                    Button {
                        save()
                    } label: {
                        Text(saveTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    // Saving deletes the spooled pages a share may still be writing.
                    .disabled(state.isBusy || importer.isImporting || sharesPackage || sendsToComputer || saveCount == 0)
                    .keyboardShortcut(IOSShortcuts.save.keyboardShortcut)
                    .accessibilityIdentifier("save.button")
                    saveMenu(canSave: saveCount > 0)
                        .disabled(state.isBusy || importer.isImporting || sharesPackage || sendsToComputer)
                    Button {
                        sharePackage()
                    } label: {
                        Label(IOSShell.sharePackageLabel, systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy || importer.isImporting || sharesPackage || sendsToComputer
                        || state.scannedPages.isEmpty)
                    .accessibilityLabel(Text(IOSShell.sharePackageLabel))
                    .accessibilityIdentifier("share.package")
                }
            }
            if IOSShell.offersSendToComputer(state.settings, status: state.companionStatus) {
                Button {
                    asksSendTarget = true
                } label: {
                    Label(IOSCompanionText.sendButton, systemImage: "laptopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy || importer.isImporting || sharesPackage || sendsToComputer
                    || state.scannedPages.isEmpty)
                .accessibilityIdentifier("send.computer")
                .confirmationDialog(IOSCompanionText.sendQuestion, isPresented: $asksSendTarget,
                                    titleVisibility: .visible) {
                    Button(IOSCompanionText.newDocument) {
                        sendToComputer(.new)
                    }
                    .accessibilityIdentifier("send.computer.new")
                    Button(IOSCompanionText.intoOpenDocument) {
                        sendToComputer(.current)
                    }
                    .accessibilityIdentifier("send.computer.current")
                }
            }
        }
        .padding(16)
        .fileImporter(isPresented: $picksPDF, allowedContentTypes: [UTType.pdf]) { (result: Result<URL, Error>) in
            switch result {
            case .success(let url):
                state.appendToPDF(at: url)
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
    }

    /// The menu beside Save: while Save writes a PDF or a picked PDF takes the pages, as on Windows, a new
    /// PDF even while a picked PDF takes them, the pages added to a PDF picked now, and while one is picked,
    /// back to saving new files; then Print… (the pages as a copy on the copy screen, the queue kept) and
    /// Email… (saved as Save would, then sent by email). The format is Options' Export.
    private func saveMenu(canSave: Bool) -> some View {
        Menu {
            if IOSShell.offersPDFOptions(state.settings) || state.appendTarget != nil {
                saveMenuItems(canSave: canSave)
            }
            Button {
                state.printQueueAsCopy()
            } label: {
                Label("Print\u{2026}", systemImage: "printer")
            }
            .disabled(!canSave)
            .accessibilityIdentifier("save.print")
            Button {
                saveAndEmail()
            } label: {
                Label("Email\u{2026}", systemImage: "envelope")
            }
            .disabled(!canSave)
            .accessibilityIdentifier("save.email")
        } label: {
            Label("More ways to save", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("More ways to save"))
        .accessibilityIdentifier("save.menu")
    }

    @ViewBuilder
    private func saveMenuItems(canSave: Bool) -> some View {
        // Word and text queues save their own format once the target is cleared.
        if state.settings.format.queueFormat == .pdf {
            Button {
                state.clearAppendTarget()
                state.savePDF()
            } label: {
                Label(PDFAppender.saveAsNewLabel, systemImage: "doc.badge.arrow.up")
            }
            .disabled(!canSave)
            .accessibilityIdentifier("save.new")
        }
        Button {
            picksPDF = true
        } label: {
            Label(PDFAppender.buttonLabel, systemImage: "doc.badge.plus")
        }
        .disabled(!canSave)
        .accessibilityHint(Text(PDFAppender.buttonHint))
        .accessibilityIdentifier("append.button")
        if let target = state.appendTarget {
            Button {
                state.clearAppendTarget()
            } label: {
                Label(Self.clearTargetLabel(target), systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("append.target.clear")
        }
    }

    /// The Save button's title: "Add to Contract.pdf" while the pages go into a PDF picked in the task
    /// list, else the queue's own (`IOSShell.saveTitle`).
    static func saveTitle(_ settings: ScanSettings, plan: SavePlan, target: URL?) -> String {
        if let target {
            return PDFAppender.saveTitle(target.lastPathComponent)
        }
        return IOSShell.saveTitle(settings, plan: plan)
    }

    /// The Save menu's item that goes back to saving new files.
    static func clearTargetLabel(_ target: URL) -> String {
        "Stop Adding to \(target.lastPathComponent)"
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

/// The flatbed preview with its scan area when there is one, else the last scan. The preview is only
/// shown here, in the scrolling column (a drag on it scrolls); tapping it opens it full
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

/// A CompleteScanner document opened in the app or picked in Files, offered until it is taken or closed:
/// "Opened Receipt.csdoc: 3 pages", with Add to pages (after the queued pages) and Open as new (in place
/// of them).
private struct PackageBanner: View {
    @EnvironmentObject private var state: AppState
    let offered: PendingPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(PackageText.openedMessage(offered.fileName, pageCount: offered.pageCount))
                    .font(.subheadline)
                    .lineLimit(2)
                    .accessibilityIdentifier("package.opened")
                Spacer(minLength: 0)
                Button {
                    state.dismissPendingPackage()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(Text("Close"))
                .accessibilityIdentifier("package.close")
            }
            HStack(spacing: 12) {
                Button(PackageText.addToPages) {
                    _ = state.addPendingPackageToPages()
                }
                .accessibilityIdentifier("package.add")
                Button(PackageText.openAsNew) {
                    _ = state.openPendingPackageAsNew()
                }
                .accessibilityIdentifier("package.new")
            }
            .buttonStyle(.bordered)
            .disabled(!state.canIngest)
        }
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
