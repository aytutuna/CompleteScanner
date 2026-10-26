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
/// saved file with Share and Show in Files. The pages come from one source at a time, picked in the Scanner
/// options (`IOSShell.sourceScanner`): our own camera (`CameraScreen`), the default, whose shutter is on the
/// capture bar, or a scanner, with Scan beside Save and no shutter; Use Apple's scanner opens Apple's
/// document scanner. On iPad the scanners are listed beside the screen. The screen stays awake while a
/// network scanner's job runs (`IOSRootView`, since resizing the window builds this screen anew).
/// Save is shown for the tasks that collect pages; photos and receipts open the photo review once found
/// and the ID card its review once its sides are in, each full screen (in place of the camera). Since I14:
/// the camera's buttons between shots (No back, Now the backs, New document), how the two-sided task and
/// a book are taken, Separate documents' separator sheets, the PDF's size, Archive and Password, a book
/// page's spread split again (`SpreadSplitSheet`), and Quick scan's page full screen once taken. Since I15:
/// PDFs and pictures dropped on the screen are imported as Files' are, Command-S saves, and Settings
/// (Command-comma) is a row under the options where the sidebar does not offer it. Since I16: the photocopy's pages
/// full screen once taken, to print over AirPrint (`CopyScreen`). While Save writes a PDF, the menu beside
/// it can also add the pages to the end of a PDF picked in Files (`AppState.appendToPDF(at:)`); with a PDF
/// picked in the task list (`AppState.appendTarget`) Save adds them to that one. Since I18: a
/// CompleteScanner document opened in the app or picked in Files is offered on a banner (Add to pages,
/// Open as new), and the queue can be shared as one (`IOSShell.sharePackage`). Since I20: with a computer
/// paired, Send to computer sends the queue to it as a new document or into the one open there
/// (`AppState.sendQueueToDesktop`), the status line saying how it went. Its covers and the
/// spread's sheet are the root view's (`ScanCovers`), so resizing the window across the width classes,
/// which builds this screen anew, leaves them open. On the iPhone it is the app's first screen, with no
/// navigation bar: its top row has only the kinds as chips, each starting its task as the task list's tile
/// does. Below, the step card shows only while
/// a step needs it (`IOSShell.showsStepCard`), then the viewfinder card with the preview once there is one
/// (else the camera's line, centred in its place), then a row for each option group that applies, which
/// opens it as a sheet (`ScanOptionGroup`): Scanner (Camera or a scanner, then the chosen one's settings:
/// Both sides and how and Apple's scanner for the camera; Source, Sides, Resolution, Color and the
/// flatbed's Preview for a scanner), Book, Photos (Restore faded colours)
/// and Export (the format, Separate documents, One PDF per page, the PDF's choices, After saving), and last
/// the library (`onOpenLibrary`) and Settings (`onOpenSettings`). While a group's sheet is up, anything
/// else the screen presents (a review, the library, the ID card's question) waits for it to close. The bar
/// at the bottom has the capture bar (`CaptureBar`, whose shutter opens the camera, or scans with a scanner as
/// the source) over Save. Save's menu adds the pages to a PDF, prints them as a copy (Print…), saves and emails them
/// (Email…), shares them as a CompleteScanner document or sends them to the computer; Save itself runs what After saving has checked (`IOSAfterSave`).
/// The capture bar's last page opens the page strip in a sheet.
struct ScanScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.horizontalSizeClass) private var sizeClass: UserInterfaceSizeClass?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    /// The scanners to pick from.
    let picker: IOSScannerPickerModel
    @Binding var cover: ScanCover?
    @Binding var spreadEditor: SpreadEditorSource?
    /// The iPad's sidebar lists the scanners and the tasks, so the Scanner options only name the source and
    /// the top row is left out.
    var pickerInSidebar: Bool = false
    /// Opens Settings; nil when the sidebar has it.
    var onOpenSettings: (() -> Void)?
    /// Opens the library (iPhone); nil when the sidebar has it.
    var onOpenLibrary: (() -> Void)?
    @State private var scanner: IOSCameraAvailability = .noCamera
    /// The source picked in the Scanner options: empty for our camera, else the scanner's ID.
    @AppStorage(IOSShell.scanSourceKey) private var source: String = ""
    /// The page strip's sheet, opened from the capture bar's last page.
    @State private var pagesShown: Bool = false
    /// A book page whose spread is split again once the page strip's sheet has closed.
    @State private var spreadAfterPages: UUID?
    /// The option group open in a sheet.
    @State private var openGroup: ScanOptionGroup?
    /// What waits for the option group's sheet to close: nothing else can be presented while it is up.
    @State private var afterOptionsClosed: (() -> Void)?
    @State private var showsAdd: Bool = false
    @State private var showsTroubleshooter: Bool = false
    @State private var askedToDiscard: Bool = false
    /// Files is open to pick the PDF the pages are added to.
    @State private var picksPDF: Bool = false
    /// The queue is being written to be shared as a CompleteScanner document.
    @State private var sharesPackage: Bool = false
    /// Send to computer asks where the pages go.
    @State private var asksSendTarget: Bool = false
    /// The queue is being written and sent to the paired computer.
    @State private var sendsToComputer: Bool = false
    /// Save waits for the copy screen After saving's Print opened, then emails when `emailsAfterPrint`.
    @State private var savesAfterPrint: Bool = false
    @State private var emailsAfterPrint: Bool = false
    @Namespace private var kindSpace: Namespace.ID

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
        .toolbar(pickerInSidebar ? Visibility.automatic : Visibility.hidden, for: .navigationBar)
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
            if empty && savesAfterPrint {
                savesAfterPrint = false
                saveNow(emails: emailsAfterPrint)
            }
        }
        .onChange(of: state.isBusy) { (_: Bool, busy: Bool) in
            // Print… held nothing (nothing to print, or cancelled), so no copy screen will close.
            if !busy && savesAfterPrint && state.copyPages.isEmpty {
                savesAfterPrint = false
            }
        }
        .onChange(of: cover) { (_: ScanCover?, shown: ScanCover?) in
            if shown == nil {
                scanner = IOSCameraAvailability.current
            }
        }
        .onChange(of: IOSShell.shownKind(state.settings)) { (_: IOSScanKind, _: IOSScanKind) in
            openGroup = nil
        }
        .onChange(of: importer.isImporting) { (_: Bool, importing: Bool) in
            // The root's corner editor cannot show over the sheet (files opened in the app, the companion).
            if importing {
                openGroup = nil
            }
        }
        .sheet(item: $openGroup, onDismiss: optionsClosed) { (group: ScanOptionGroup) in
            optionsSheet(group)
                .environmentObject(state)
                .environmentObject(importer)
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
        .modifier(IdCardDiscardQuestion(state: state, asked: $askedToDiscard))
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if !pickerInSidebar {
                topRow
            }
            List {
                Section {
                    stepCard
                    if CameraTaskButtons.showsAny(state) {
                        CameraTaskButtons()
                    }
                    if let mismatch = state.sidesMismatch, state.cameraSides != nil {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                            .accessibilityIdentifier("task.mismatch")
                    }
                    viewfinder
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if !optionGroups.isEmpty {
                    Section {
                        ForEach(optionGroups) { (group: ScanOptionGroup) in
                            optionRow(group)
                        }
                    }
                }
                if onOpenLibrary != nil || onOpenSettings != nil {
                    Section {
                        appRows
                    }
                }
            }
            .listStyle(.insetGrouped)
            Divider()
            bottomBar
        }
        .background {
            // The Settings row is built lazily, so the shortcut lives on a button that always exists.
            if let open = onOpenSettings {
                Button("") {
                    afterOptions(open)
                }
                .keyboardShortcut(IOSShortcuts.settings.keyboardShortcut)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: The top row

    /// The kinds, in place of the navigation bar.
    private var topRow: some View {
        kindChips
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    /// The library and Settings, last in the list now that the top row holds only the kinds.
    @ViewBuilder
    private var appRows: some View {
        if let open = onOpenLibrary {
            Button {
                afterOptions(open)
            } label: {
                Label(IOSSettingsText.libraryLabel, systemImage: "books.vertical")
            }
            .accessibilityIdentifier("open.library")
        }
        if let open = onOpenSettings {
            Button {
                afterOptions(open)
            } label: {
                Label(IOSSettingsText.title, systemImage: "gearshape")
            }
            .accessibilityIdentifier("scan.settings")
        }
    }

    /// One chip per kind (`IOSShell.kindTiles`), the one set up filled; one capsule moves between them.
    private var kindChips: some View {
        let current: IOSScanKind = IOSShell.shownKind(state.settings)
        let tiles: [IOSKindTile] = IOSShell.kindTiles(state.taskCards, current: current)
        let busy: Bool = state.isBusy || importer.isImporting
        return ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tiles) { (tile: IOSKindTile) in
                        kindChip(tile, busy: busy)
                            .id(tile.kind)
                    }
                }
                .padding(.horizontal, 4)
                .animation(chipAnimation, value: current)
            }
            .accessibilityIdentifier("task.chips")
            .onAppear {
                proxy.scrollTo(current, anchor: .center)
            }
            .onChange(of: current) { (_: IOSScanKind, kind: IOSScanKind) in
                withAnimation(chipAnimation) {
                    proxy.scrollTo(kind, anchor: .center)
                }
            }
        }
        .sensoryFeedback(SensoryFeedback.selection, trigger: current)
    }

    private func kindChip(_ tile: IOSKindTile, busy: Bool) -> some View {
        let kind: IOSScanKind = tile.kind
        let available: Bool = tile.availability.isAvailable
        let hint: String = available ? kind.subtitle : "\(kind.subtitle). Not available: \(tile.availability.reason ?? "")"
        return Button {
            pickKind(kind)
        } label: {
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tile.isCurrent ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                    if tile.isCurrent {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "kind", in: kindSpace)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available || busy)
        .opacity(available ? 1 : 0.5)
        .accessibilityAddTraits(tile.isCurrent ? AccessibilityTraits.isSelected : [])
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("task.\(kind.rawValue)")
    }

    private var chipAnimation: Animation {
        reduceMotion ? Animation.easeInOut(duration: 0.2) : Animation.spring(duration: 0.45, bounce: 0.25)
    }

    /// Picking a kind starts its task as the task list's tile does (its own choices back to their defaults,
    /// and no PDF picked to add to); with a side of an ID card held it asks first. The chip already picked
    /// changes nothing, so a stray tap keeps Both sides, the steps and the PDF picked.
    private func pickKind(_ kind: IOSScanKind) {
        guard kind != IOSShell.shownKind(state.settings) || state.activeTask == nil else { return }
        let appState: AppState = state
        afterOptions {
            appState.leaveIdCard {
                if appState.startTask(kind.task) {
                    appState.clearAppendTarget()
                }
            }
            if appState.pendingIdCardLeave != nil {
                askedToDiscard = true
            }
        }
    }

    // MARK: The viewfinder

    /// The flatbed preview or the last scan; with neither, the camera's line centred where the preview
    /// would be, unless the step card already says what to do.
    @ViewBuilder
    private var viewfinder: some View {
        if state.canvasImage != nil {
            PreviewArea(image: state.canvasImage, overview: state.overviewImage, onChooseArea: openCrop)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("preview.area")
        } else if !showsStepCard, let camera = cameraLine {
            VStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
                Text(camera.prompt)
                    .font(.headline)
            }
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(Axis.Set.vertical) { (length: CGFloat, _: Axis) -> CGFloat in
                PreviewArea.height(for: length)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("preview.area")
        }
    }

    // MARK: The options

    /// The option groups that apply: Scanner (where the pages come from) while the camera or a scanner can
    /// take them, the book's and the photos' for their kinds, and Export while the pages are collected and
    /// saved here.
    private var optionGroups: [ScanOptionGroup] {
        var groups: [ScanOptionGroup] = []
        if IOSShell.offersOwnCamera(state.settings) || !state.devices.isEmpty {
            groups.append(.scanner)
        }
        if state.activeTask == .book {
            groups.append(.book)
        }
        if IOSShell.shownKind(state.settings) == .photos {
            groups.append(.photos)
        }
        if IOSShell.collectsPages(state.settings) {
            groups.append(.export)
        }
        return groups
    }

    private func optionRow(_ group: ScanOptionGroup) -> some View {
        Button {
            openGroup = group
        } label: {
            HStack(spacing: 8) {
                Text(group.title)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                Text(optionValue(group))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        // An import's corner editor needs the screen; the sheet closes as one starts.
        .disabled(importer.isImporting)
        .accessibilityIdentifier("options.row.\(group.rawValue)")
    }

    /// What the row says the group is set to: Camera, or the scanner and its source; the book's way,
    /// whether old prints are restored, the format with the PDF's size.
    private func optionValue(_ group: ScanOptionGroup) -> String {
        let s: ScanSettings = state.settings
        switch group {
        case .scanner:
            guard let device = sourceDevice else { return IOSImportText.cameraLabel }
            return "\(device.name) \u{00B7} \(s.source.label)"
        case .book:
            return s.taskOptions.cameraSpreads ? CameraTaskCatalog.wholeSpreadLabel : CameraTaskCatalog.pageByPageLabel
        case .photos:
            return s.adjustments.restoreFadedColors ? "Restored" : "As taken"
        case .export:
            let format: String = ExportOptions.label(IOSShell.exportFormat(s))
            return IOSShell.offersPDFOptions(s) ? "\(format) \u{00B7} \(s.output.pdfSize.label)" : format
        }
    }

    /// A group's sheet, half height first, with the screen still usable above it.
    private func optionsSheet(_ group: ScanOptionGroup) -> some View {
        NavigationStack {
            Form {
                optionsContent(group)
            }
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSSettingsText.doneLabel) {
                        openGroup = nil
                    }
                    .accessibilityIdentifier("options.done")
                }
            }
            .modifier(ScannerPickerSheets(picker: picker, showsAdd: $showsAdd, showsTroubleshooter: $showsTroubleshooter))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // The root's alert cannot show over a sheet, nor its troubleshooter until the sheet has closed.
        .modifier(ErrorAlert(state: state, onTroubleshoot: openTroubleshooter))
    }

    private func openTroubleshooter() {
        let appState: AppState = state
        afterOptions {
            appState.showTroubleshooter = true
        }
    }

    @ViewBuilder
    private func optionsContent(_ group: ScanOptionGroup) -> some View {
        switch group {
        case .scanner:
            if pickerBeside {
                Section {
                    sourceRow
                }
            } else {
                ScannerPickerSections(picker: picker, onAdd: openAdd, onTroubleshoot: openPickerTroubleshooter)
            }
            if let device = sourceDevice {
                Section {
                    ScannerSettingsRows()
                } header: {
                    Text(device.name)
                }
                if usesFlatbed {
                    Section {
                        previewControls
                    }
                }
            } else if showsCameraOptions {
                Section {
                    BothSidesToggle()
                    TaskWayPicker()
                    if IOSShell.offersCamera(state.activeTask) {
                        AppleScannerRow(scanner: scanner, onScanner: openScanner)
                    }
                } header: {
                    Text(IOSImportText.cameraLabel)
                }
            }
        case .book:
            Section {
                TaskWayPicker()
            }
        case .photos:
            Section {
                RestoreToggle()
            }
        case .export:
            ExportOptions()
        }
    }

    private var showsCameraOptions: Bool {
        IOSShell.shownKind(state.settings) == .document
    }

    /// Runs `action` at once, or once the option group's sheet has closed.
    private func afterOptions(_ action: @escaping () -> Void) {
        guard openGroup != nil else {
            action()
            return
        }
        afterOptionsClosed = action
        openGroup = nil
    }

    private func optionsClosed() {
        let action: (() -> Void)? = afterOptionsClosed
        afterOptionsClosed = nil
        action?()
    }

    // MARK: The page strip

    private func openPages() {
        afterOptions {
            pagesShown = true
        }
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

    private func openAdd() {
        showsAdd = true
    }

    private func openPickerTroubleshooter() {
        showsTroubleshooter = true
    }

    // MARK: Cameras

    private func openScanner() {
        scanner = IOSCameraAvailability.current
        guard scanner.isAvailable, importer.canImport else { return }
        afterOptions {
            cover = .scanner
        }
    }

    /// Our own camera; its screen checks for a camera and asks for access the first time.
    private func openOwnCamera() {
        guard importer.canImport else { return }
        afterOptions {
            cover = .camera
        }
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
    /// the ID card to take again). One that opens while an option group's sheet is up waits for it to close.
    private func showReview(_ shown: Bool, as review: ScanCover) {
        if shown {
            afterOptions {
                if wantsReview(review) {
                    cover = review
                }
            }
        } else if cover == review {
            cover = nil
        }
    }

    /// Whether the review is still due once the sheet it waited for has closed.
    private func wantsReview(_ review: ScanCover) -> Bool {
        switch review {
        case .photoReview: return state.showPhotoReview
        case .idCardReview: return state.showIdCardReview
        case .quickScan: return state.quickScanPage != nil
        case .copy: return !state.copyPages.isEmpty
        case .scanner, .camera, .crop: return true
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
        afterOptions {
            cover = .crop
        }
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
                               device: sourceDevice)
    }

    private var cameraLine: CameraStepText? {
        IOSShell.cameraLine(state.activeTask, options: state.settings.taskOptions, sides: state.cameraSides,
                            newDocument: state.newDocumentPending, turningOverByHand: state.isTurningOverByHand,
                            device: sourceDevice)
    }

    /// The source named, with how a scanner is reached, where the list beside the screen picks it.
    private var sourceRow: some View {
        let name: String = sourceDevice?.name ?? IOSImportText.cameraLabel
        return HStack(spacing: 8) {
            Image(systemName: sourceDevice == nil ? "camera" : "scanner")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 8)
            if sourceDevice != nil, let note = deviceNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .accessibilityIdentifier("scanner.note")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Scanner: \(name)"))
        .accessibilityIdentifier("scanner.menu")
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
                    .buttonStyle(.borderless)
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

    /// The scanner the pages come from; nil while our camera takes them.
    private var sourceDevice: ScannerInfo? {
        IOSShell.sourceScanner(source, selected: state.selectedDeviceID, devices: state.devices)
    }

    /// Scan once the scanner is connected and nothing else runs.
    private var canScan: Bool {
        state.capabilities != nil && !state.isBusy
    }

    private func scan() {
        state.performScan()
    }

    // MARK: Saving

    /// Save, then what After saving has checked, in its order (`IOSAfterSave.steps`). Send to PC and Print
    /// take the queue, which the save empties, so they go first: the save waits for the copy screen Print
    /// opens to close. Email goes out with the saved file.
    private func saveWithActions() {
        let paired: Bool = IOSShell.offersSendToComputer(state.settings, status: state.companionStatus)
        let steps: [IOSAfterSave] = IOSAfterSave.steps(UserDefaults.standard, paired: paired)
        guard !steps.isEmpty else {
            save()
            return
        }
        let emails: Bool = steps.contains(.email)
        let appState: AppState = state
        Task { @MainActor in
            if steps.contains(.send) {
                sendsToComputer = true
                await appState.sendQueueToDesktop(target: .new)
                sendsToComputer = false
                // The send failed and its alert is up: the copy screen and Mail could not show over it.
                if appState.errorMessage != nil {
                    save()
                    return
                }
            }
            if steps.contains(.print) {
                savesAfterPrint = true
                emailsAfterPrint = emails
                appState.printQueueAsCopy()
                if !appState.isBusy {
                    savesAfterPrint = false
                }
            } else {
                saveNow(emails: emails)
            }
        }
    }

    private func saveNow(emails: Bool) {
        if emails {
            saveAndEmail()
        } else {
            save()
        }
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

    // MARK: The bottom bar

    private var bottomBar: some View {
        let options: DocumentOptions = state.settings.document
        let plan: SavePlan = SavePlan.make(state.scannedPages, options: options)
        let saveTitle: String = Self.saveTitle(state.settings, plan: plan, target: state.appendTarget)
        let saveCount: Int = plan.pageCount
        let collects: Bool = IOSShell.collectsPages(state.settings)
        let scans: Bool = sourceDevice != nil
        // Saving deletes the spooled pages a share or a send may still be writing.
        let blocked: Bool = state.isBusy || importer.isImporting || sharesPackage || sendsToComputer
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
            CaptureBar(offersCamera: !scans && IOSShell.offersOwnCamera(state.settings), onCamera: openOwnCamera,
                       onScan: scans ? scan : nil, canScan: canScan, onPages: openPages)
            if collects {
                HStack(spacing: 12) {
                    Button {
                        saveWithActions()
                    } label: {
                        Text(saveTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(blocked || saveCount == 0)
                    .keyboardShortcut(IOSShortcuts.save.keyboardShortcut)
                    .accessibilityIdentifier("save.button")
                    saveMenu(canSave: saveCount > 0)
                        .disabled(blocked)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), ignoresSafeAreaEdges: .bottom)
        .confirmationDialog(IOSCompanionText.sendQuestion, isPresented: $asksSendTarget, titleVisibility: .visible) {
            Button(IOSCompanionText.newDocument) {
                sendToComputer(.new)
            }
            .accessibilityIdentifier("send.computer.new")
            Button(IOSCompanionText.intoOpenDocument) {
                sendToComputer(.current)
            }
            .accessibilityIdentifier("send.computer.current")
        }
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
    /// back to saving new files; then Print… (the pages as a copy on the copy screen, the queue kept),
    /// Email… (saved as Save would, then sent by email), the queue shared as a CompleteScanner document and,
    /// with a computer paired, Send to computer. Each runs once, whatever After saving has checked.
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
            Button {
                sharePackage()
            } label: {
                Label(IOSShell.sharePackageLabel, systemImage: "square.and.arrow.up")
            }
            .disabled(state.scannedPages.isEmpty)
            .accessibilityIdentifier("share.package")
            if IOSShell.offersSendToComputer(state.settings, status: state.companionStatus) {
                Button {
                    asksSendTarget = true
                } label: {
                    Label(IOSCompanionText.sendButton, systemImage: "laptopcomputer")
                }
                .disabled(state.scannedPages.isEmpty)
                .accessibilityIdentifier("send.computer")
            }
        } label: {
            Label("More ways to save", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.headline)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 12))
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

/// A group of the scan screen's options: a row on the screen that opens the group as a sheet.
enum ScanOptionGroup: String, Identifiable {
    case scanner
    case book
    case photos
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanner: return "Scanner"
        case .book: return "Book"
        case .photos: return "Photos"
        case .export: return "Export"
        }
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
            RoundedRectangle(cornerRadius: 10)
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
                    .interpolation(.high)
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
