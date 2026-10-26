#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The full-screen covers the scan screen opens: Apple's document scanner, the flatbed preview to choose
/// the scan area on, (I13) the photo or receipt review and the ID card's review, (I14) Quick scan's page
/// and (I16) the photocopy's screen. Camera mode's camera rests while one is up.
enum ScanCover: String, Identifiable {
    case scanner
    case crop
    case photoReview
    case idCardReview
    case quickScan
    case copy

    var id: String { rawValue }
}

/// The scan screen, in the phone's mode (`IOSScanMode`), which is also where the pages come from. Camera
/// mode, the default, is the viewfinder as the screen (`CameraScreen`): this screen hands it the notices
/// (the package banner, an import's progress, the files saved last), Save floating on the viewfinder once
/// there are pages ("Save PDF · 3", `IOSShell.floatingSaveTitle`) with the menu beside it, the kinds it
/// picks, the page strip, the Export sheet behind the drawer's More… and Apple's scanner. Printer mode is
/// the printer screen: the kinds as chips in its top row with the camera at their end (`mode.camera`,
/// back to camera mode, which selects no scanner so none of its limits apply to the camera), the step
/// card only while a step needs it (`IOSShell.showsStepCard`, in the step's own words, which speak of the
/// scanner), the flatbed preview or the last scan, then a row for each option group that applies, which
/// opens it as a sheet (`ScanOptionGroup`): Scanner (the scanners, "No scanner found", Add by address and
/// Troubleshoot, then the scanner's Source, Sides, Resolution, Color and the flatbed's Preview; the row
/// reads the scanner and its source, or "No scanner"), Book, Photos (Restore faded colours) and Export (the
/// format, Separate documents, One PDF per page, the PDF's choices, After saving), and last the library
/// (`onOpenLibrary`) and Settings (`onOpenSettings`, Command-comma). While a group's sheet is up, anything
/// else the screen presents (a review, the library, the ID card's question) waits for it to close. At the
/// bottom the status line with a scan's progress, the capture bar (`CaptureBar`: the pages, Photos and
/// Files) and Scan (named for the step, `primaryActionLabel`) beside Save (as a PDF, a JPEG a page, Word or
/// text, `IOSShell.exportFormats`) and its menu; once saved, the saved file with Share and Show in Files.
/// Save's menu, in both modes, saves as a new PDF or adds the pages to the end of a PDF picked in Files
/// (`AppState.appendToPDF(at:)`; with a PDF picked in the task list, `AppState.appendTarget`, Save adds
/// them to that one), opens After saving, prints them as a copy (Print…), saves and emails them (Email…),
/// shares them as a CompleteScanner document (`IOSShell.sharePackage`) or, with a computer paired, sends
/// them to it (`AppState.sendQueueToDesktop`); Save itself runs what After saving has checked
/// (`IOSAfterSave`). Photos and receipts open the photo review once found, the ID card its review once its
/// sides are in, Quick scan its page and the photocopy its copy screen, each full screen; a book page's
/// spread can be split again (`SpreadSplitSheet`). PDFs and pictures dropped on the screen are imported as
/// Files' are, and Command-S saves. Its covers and the spread's sheet are the root view's (`ScanCovers`),
/// so resizing the window across the width classes, which builds this screen anew, leaves them open. On
/// the iPad's sidebar layout (`pickerInSidebar`) the sidebar has the kinds and the scanners, and printer
/// mode's navigation bar has the camera.
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
    /// The card saying why the camera is asked for is up, or the app has not started: camera mode's camera
    /// waits for it.
    var waitsForIntro: Bool = false
    /// The root presents something over the screen (Settings, the share sheet, Mail, Quick Look): camera
    /// mode's camera rests.
    var rests: Bool = false
    @State private var scanner: IOSCameraAvailability = .noCamera
    /// The camera or printer mode, switched with the top row's printer and camera buttons; picking a
    /// scanner also switches to printer mode.
    @AppStorage(IOSShell.scanModeKey) private var mode: IOSScanMode = .camera
    /// The scanner printer mode scans with, remembered while the camera is in use.
    @AppStorage(IOSShell.scannerKey) private var printerID: String = ""
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
    /// A scanner picked in the Scanner options asks there about a side of an ID card held.
    @State private var cardAskedInOptions: Bool = false
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
    /// What was asked for that would leave the pages without a Save, while the question about them is up.
    @State private var leavingPages: PagesLeave?
    @Namespace private var kindSpace: Namespace.ID

    var body: some View {
        following
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
            .modifier(KeepPagesQuestion(state: state, leave: $leavingPages, blocked: saveBlocked))
            .modifier(SaveDialogs(state: state, asksSendTarget: $asksSendTarget, picksPDF: $picksPDF,
                                  onSend: sendToComputer))
    }

    /// The screen of the mode in use: camera mode, or the printer screen (beside the scanners on a wide
    /// window without the sidebar).
    @ViewBuilder
    private var content: some View {
        if cameraMode {
            cameraLayout
        } else if IOSLayout.usesSidebar(sizeClass, pad: UIDevice.current.userInterfaceIdiom == .pad) && !pickerInSidebar {
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

    private var screen: some View {
        content
            .background(cameraMode ? Color(uiColor: .systemBackground) : Color(uiColor: .systemGroupedBackground))
            .navigationTitle(IOSShell.shownKind(state.settings).title)
            .navigationBarTitleDisplayMode(.inline)
            // The iPad keeps its bar in camera mode too, for the sidebar's button.
            .toolbar(pickerInSidebar ? Visibility.automatic : Visibility.hidden, for: .navigationBar)
            .toolbarBackground(cameraMode ? Visibility.hidden : Visibility.automatic, for: .navigationBar)
            .toolbar {
                if pickerInSidebar && !cameraMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        cameraModeButton
                    }
                }
            }
            .dropDestination(for: IOSDroppedFile.self) { (items: [IOSDroppedFile], _: CGPoint) -> Bool in
                importDropped(items)
            }
            .background {
                settingsShortcut
            }
    }

    /// The reviews follow the state: each opens as a cover once it is due, and closes with it.
    private var following: some View {
        screen
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
    }

    /// The Settings row is built lazily, so the shortcut lives on a button that always exists.
    @ViewBuilder
    private var settingsShortcut: some View {
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

    private var cameraMode: Bool {
        mode == .camera
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
                    if TurnedOverButtons.showsAny(state) {
                        TurnedOverButtons()
                    }
                    if let mismatch = state.sidesMismatch, state.cameraSides != nil || state.isTurningOverByHand {
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
    }

    // MARK: Camera mode

    /// The viewfinder as the screen (`CameraScreen`), with what this screen hands it: the notices at the
    /// viewfinder's foot and Save with its menu.
    private var cameraLayout: some View {
        CameraScreen(resting: cameraCovered, waitsForIntro: waitsForIntro, scanner: scanner, onLibrary: libraryAction,
                     onPrinter: switchToPrinter, onPages: openPages, onKind: pickKind, onExportSheet: openExportSheet,
                     onAppleScanner: openScanner) {
            cameraNotices
        } saveControls: {
            floatingSave
        }
    }

    /// Something covers the camera: what the root presents, a cover, a sheet, Files to pick a PDF in, a
    /// question or the error alert.
    private var cameraCovered: Bool {
        let presented: Bool = cover != nil || openGroup != nil || pagesShown || picksPDF || spreadEditor != nil
        let asked: Bool = askedToDiscard || leavingPages != nil || asksSendTarget || state.errorMessage != nil
            || state.showTroubleshooter
        return rests || presented || asked
    }

    /// The library, once the option group's sheet has closed; nil where the sidebar has it.
    private var libraryAction: (() -> Void)? {
        guard let open = onOpenLibrary else { return nil }
        return { () -> Void in
            afterOptions(open)
        }
    }

    /// Printer mode: the root view selects its scanner once listed.
    private func switchToPrinter() {
        afterOptions {
            mode = .printer
        }
    }

    private func openExportSheet() {
        openGroup = .export
    }

    /// The package banner, an import's progress with Stop, and the files saved last until the next page
    /// comes in, each on a card over the viewfinder.
    @ViewBuilder
    private var cameraNotices: some View {
        if let offered = state.pendingPackage {
            PackageBanner(offered: offered, onOpenAsNew: openPackageAsNew)
                .modifier(NoticeCard())
        }
        if importer.progressText != nil {
            ImportProgressRow()
                .modifier(NoticeCard())
        }
        if !state.lastSavedURLs.isEmpty && state.scannedPages.isEmpty && !state.isBusy {
            SavedFilesRow()
                .modifier(NoticeCard())
        }
    }

    /// Save on a capsule with the menu beside it, once there are pages to save.
    @ViewBuilder
    private var floatingSave: some View {
        if !state.scannedPages.isEmpty && IOSShell.offersSave(state.settings, pageCount: state.scannedPages.count) {
            HStack(spacing: 6) {
                floatingSaveButton
                floatingSaveMenu
            }
        }
    }

    private var floatingSaveButton: some View {
        let plan: SavePlan = savePlan
        let title: String = IOSShell.floatingSaveTitle(state.settings, plan: plan, target: state.appendTarget)
        let enabled: Bool = !saveBlocked && plan.pageCount > 0
        return Button {
            saveWithActions()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(Capsule().fill(Color.accentColor))
                .shadow(color: Color.black.opacity(0.25), radius: 7, y: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .keyboardShortcut(IOSShortcuts.save.keyboardShortcut)
        .accessibilityIdentifier("save.button")
    }

    private var floatingSaveMenu: some View {
        let canSave: Bool = savePlan.pageCount > 0
        return Menu {
            saveMenuContent(canSave: canSave)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .disabled(saveBlocked)
        .accessibilityLabel(Text("More ways to save"))
        .accessibilityIdentifier("save.menu")
    }

    // MARK: The top row

    /// The kinds, in place of the navigation bar, and the camera at their end.
    private var topRow: some View {
        HStack(spacing: 4) {
            kindChips
            cameraModeButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Back to camera mode.
    private var cameraModeButton: some View {
        Button {
            switchToCamera()
        } label: {
            Image(systemName: "camera")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(state.isBusy)
        .accessibilityLabel(Text(IOSImportText.cameraLabel))
        .accessibilityHint(Text(IOSCameraText.cameraModeHint))
        .accessibilityIdentifier("mode.camera")
    }

    /// Camera mode, with no scanner selected, so none of its limits apply to the camera (the sides turned
    /// over by hand back to both, `AppState.userSelectNoDevice`).
    private func switchToCamera() {
        let appState: AppState = state
        afterOptions {
            mode = .camera
            appState.userSelectNoDevice()
        }
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
        let busy: Bool = saveBlocked
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
            .modifier(EdgeFade(leading: 0, trailing: 28))
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
    /// and no PDF picked to add to). The pages taken stay when the kind collects pages too (Document, Book);
    /// any other kind would leave them without a Save, so it asks first (`KeepPagesQuestion`). With a side of
    /// an ID card held it asks about the card too. The chip already picked changes nothing, so a stray tap
    /// keeps Both sides, the steps and the PDF picked. Nothing changes while a share or a send reads the
    /// spooled pages, which Discard would delete.
    private func pickKind(_ kind: IOSScanKind) {
        guard !saveBlocked else { return }
        guard kind != IOSShell.shownKind(state.settings) || state.activeTask == nil else { return }
        let appState: AppState = state
        afterOptions {
            if appState.pagesLeftBehind(by: kind.task) > 0 {
                leavingPages = PagesLeave(reason: IOSShell.keepPagesReason(kind)) { (discarding: Bool) in
                    switchKind(kind, discardingPages: discarding)
                }
            } else {
                switchKind(kind)
            }
        }
    }

    /// Starts the kind's task, dropping the pages first when asked to, once the ID card's question (when a
    /// side is held) is answered.
    private func switchKind(_ kind: IOSScanKind, discardingPages: Bool = false) {
        let appState: AppState = state
        appState.leaveIdCard {
            let started: Bool = discardingPages ? appState.discardPages(andStart: kind.task) : appState.startTask(kind.task)
            if started {
                appState.clearAppendTarget()
            }
        }
        if appState.pendingIdCardLeave != nil {
            askedToDiscard = true
        }
    }

    /// Open as new replaces the queued pages, so with pages queued it asks about them first. Not while a
    /// share or a send reads them.
    private func openPackageAsNew() {
        guard !saveBlocked else { return }
        let appState: AppState = state
        guard !state.scannedPages.isEmpty, let offered = state.pendingPackage else {
            appState.openPendingPackageAsNew()
            return
        }
        leavingPages = PagesLeave(reason: IOSShell.keepPagesReason(package: offered.fileName)) { (_: Bool) in
            appState.openPendingPackageAsNew()
        }
    }

    // MARK: The viewfinder

    /// The flatbed preview (only while the flatbed is the source, `IOSShell.showsFlatbedPreview`) or the last
    /// scan; with neither, the camera's line centred where the preview would be, unless the step card already
    /// says what to do.
    @ViewBuilder
    private var viewfinder: some View {
        let flatbed: Bool = IOSShell.showsFlatbedPreview(state.settings)
        let shown: CGImage? = flatbed ? state.canvasImage : state.lastScanImage
        if shown != nil {
            PreviewArea(image: shown, overview: flatbed ? state.overviewImage : nil, onChooseArea: openCrop)
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

    /// The option groups that apply: Scanner always, the book's and the photos' for their kinds, and Export
    /// while the pages are saved here (`IOSShell.offersSave`).
    private var optionGroups: [ScanOptionGroup] {
        var groups: [ScanOptionGroup] = [.scanner]
        if state.activeTask == .book {
            groups.append(.book)
        }
        if IOSShell.shownKind(state.settings) == .photos {
            groups.append(.photos)
        }
        if IOSShell.offersSave(state.settings, pageCount: state.scannedPages.count) {
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

    /// What the row says the group is set to: the scanner and its source ("No scanner" until one is picked
    /// or found); the book's way, whether old prints are restored, the format with the PDF's size.
    private func optionValue(_ group: ScanOptionGroup) -> String {
        let s: ScanSettings = state.settings
        switch group {
        case .scanner:
            guard let device = sourceDevice else { return IOSNetworkText.noScannerPicked }
            return "\(device.name) \u{00B7} \(s.source.label)"
        case .book:
            return s.taskOptions.cameraSpreads ? CameraTaskCatalog.wholeSpreadLabel : CameraTaskCatalog.pageByPageLabel
        case .photos:
            return s.adjustments.restoreFadedColors ? "Restored" : "As taken"
        case .export:
            let format: String = ExportOptions.label(IOSShell.exportFormat(s))
            return IOSShell.offersPDFOptions(s) ? "\(format) \u{00B7} \(s.output.pdfSize.label)" : format
        case .afterSave:
            return ""
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
            .modifier(IdCardDiscardQuestion(state: state, asked: $cardAskedInOptions))
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
                ScannerPickerSections(picker: picker, onAdd: openAdd, onTroubleshoot: openPickerTroubleshooter,
                                      asksAboutCard: $cardAskedInOptions)
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
        case .afterSave:
            AfterSaveSection()
        }
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
        case .scanner, .crop: return true
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
        guard state.overviewImage != nil, IOSShell.showsFlatbedPreview(state.settings), !state.isBusy else { return }
        afterOptions {
            cover = .crop
        }
    }

    /// The current step's one-line prompt, with its fuller help below (as printer mode says it,
    /// `IOSShell.printerStep`, or the camera's line in its place, `IOSShell.cameraLine`); the back of an ID
    /// card offers "No back side".
    @ViewBuilder
    private var stepCard: some View {
        if let current = state.taskFlow?.current, showsStepCard {
            let step: TaskStep = IOSShell.printerStep(current, settings: state.settings)
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
                               printer: mode == .printer)
    }

    private var cameraLine: CameraStepText? {
        IOSShell.cameraLine(state.activeTask, options: state.settings.taskOptions, sides: state.cameraSides,
                            newDocument: state.newDocumentPending, turningOverByHand: state.isTurningOverByHand,
                            printer: mode == .printer)
    }

    /// The scanner named, with how it is reached, where the list beside the screen picks it.
    private var sourceRow: some View {
        let name: String = sourceDevice?.name ?? IOSNetworkText.noScannerPicked
        return HStack(spacing: 8) {
            Image(systemName: "scanner")
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
        pickerInSidebar || IOSLayout.usesSidebar(sizeClass, pad: UIDevice.current.userInterfaceIdiom == .pad)
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

    /// The scanner the pages come from; nil in camera mode, or until printer mode's scanner is found.
    private var sourceDevice: ScannerInfo? {
        IOSShell.printerScanner(mode, scanner: printerID, selected: state.selectedDeviceID, devices: state.devices)
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
        IOSShell.saveQueue(state)
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

    /// The queue as Save would save it.
    private var savePlan: SavePlan {
        SavePlan.make(state.scannedPages, options: state.settings.document)
    }

    /// Saving deletes the spooled pages a share or a send may still be writing.
    private var saveBlocked: Bool {
        state.isBusy || importer.isImporting || sharesPackage || sendsToComputer
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRows
            CaptureBar(onPages: openPages)
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), ignoresSafeAreaEdges: .bottom)
    }

    /// A scan's progress with Cancel, the package banner, the status line and the files saved last.
    @ViewBuilder
    private var statusRows: some View {
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
            PackageBanner(offered: offered, onOpenAsNew: openPackageAsNew)
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
    }

    /// Scan beside Save, with Save's menu, while the pages are saved here (`IOSShell.offersSave`).
    private var actionRow: some View {
        HStack(spacing: 12) {
            scanButton
            if IOSShell.offersSave(state.settings, pageCount: state.scannedPages.count) {
                saveButton
                saveMenu(canSave: savePlan.pageCount > 0)
                    .disabled(saveBlocked)
            }
        }
    }

    /// Scan, named for the step as printer mode says it ("Scan page", "Scan stack"), once the scanner is
    /// connected and nothing else runs.
    private var scanButton: some View {
        Button {
            scan()
        } label: {
            Text(scanLabel)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!canScan)
        .accessibilityIdentifier("scan.button")
    }

    private var scanLabel: String {
        guard let step = state.taskFlow?.current else { return state.primaryActionLabel }
        return IOSShell.printerStep(step, settings: state.settings).primaryActionLabel
    }

    private var saveButton: some View {
        let plan: SavePlan = savePlan
        let title: String = Self.saveTitle(state.settings, plan: plan, target: state.appendTarget)
        return Button {
            saveWithActions()
        } label: {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(saveBlocked || plan.pageCount == 0)
        .keyboardShortcut(IOSShortcuts.save.keyboardShortcut)
        .accessibilityIdentifier("save.button")
    }

    /// The menu beside Save (`saveMenuContent`), as a bordered button.
    private func saveMenu(canSave: Bool) -> some View {
        Menu {
            saveMenuContent(canSave: canSave)
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

    /// Save's menu: while Save writes a PDF or a picked PDF takes the pages, as on Windows, a new PDF even
    /// while a picked PDF takes them, the pages added to a PDF picked now, and while one is picked, back to
    /// saving new files; After saving… (its choices in a sheet); then Print… (the pages as a copy on the
    /// copy screen, the queue kept), Email… (saved as Save would, then sent by email), the queue shared as a
    /// CompleteScanner document and, with a computer paired, Send to computer. Each runs once, whatever
    /// After saving has checked.
    @ViewBuilder
    private func saveMenuContent(canSave: Bool) -> some View {
        if IOSShell.offersPDFOptions(state.settings) || state.appendTarget != nil {
            saveMenuItems(canSave: canSave)
        }
        Button {
            openGroup = .afterSave
        } label: {
            Label("After saving\u{2026}", systemImage: "checklist")
        }
        .accessibilityIdentifier("save.afterSave")
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
    /// Opened from Save's menu, not a row.
    case afterSave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanner: return "Scanner"
        case .book: return "Book"
        case .photos: return "Photos"
        case .export: return "Export"
        case .afterSave: return IOSAfterSave.title
        }
    }
}

/// The confirmation asking where Send to computer sends the pages, and Files to pick the PDF Save's menu
/// adds them to; on the screen whichever mode is shown.
@MainActor
private struct SaveDialogs: ViewModifier {
    @ObservedObject var state: AppState
    @Binding var asksSendTarget: Bool
    @Binding var picksPDF: Bool
    let onSend: (CompanionTarget) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(IOSCompanionText.sendQuestion, isPresented: $asksSendTarget, titleVisibility: .visible) {
                Button(IOSCompanionText.newDocument) {
                    onSend(.new)
                }
                .accessibilityIdentifier("send.computer.new")
                Button(IOSCompanionText.intoOpenDocument) {
                    onSend(.current)
                }
                .accessibilityIdentifier("send.computer.current")
            }
            .fileImporter(isPresented: $picksPDF, allowedContentTypes: [UTType.pdf]) { (result: Result<URL, Error>) in
                picked(result)
            }
    }

    private func picked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            state.appendToPDF(at: url)
        case .failure(let error):
            state.errorMessage = error.localizedDescription
        }
    }
}

/// What waits on the keep-pages question: why the pages would be left without a Save
/// (`IOSShell.keepPagesReason`), and what was asked for, run once a save has emptied the queue (`discarding`
/// false) or to go on with the pages dropped (`discarding` true).
struct PagesLeave {
    let reason: String
    let action: @MainActor (_ discarding: Bool) -> Void
}

/// Keep the 3 pages? Asked before something that would leave the queued pages without a Save: a kind or a
/// task that does not collect pages (`AppState.pagesLeftBehind(by:)`), a preset that does not, a document
/// opened as new. Save first (`IOSShell.saveFirstLabel`) saves them as Save would, without After saving's
/// steps, and goes on once the save has emptied the queue; a save that fails or is cancelled keeps the pages
/// and changes nothing. It is left out when the save could write nothing (every page skipped) or cannot run
/// now (`blocked`). Discard goes on and drops the pages, Cancel keeps both, and camera mode's row goes back.
/// What was asked for is taken when the alert opens, as the ID card's question takes it: the alert's
/// dismissal clears it, and SwiftUI may run that before the button.
@MainActor
struct KeepPagesQuestion: ViewModifier {
    @ObservedObject var state: AppState
    @Binding var leave: PagesLeave?
    let blocked: Bool
    /// What Save first was asked for, until its save ends.
    @State private var afterSave: PagesLeave?

    func body(content: Content) -> some View {
        let count: Int = state.scannedPages.count
        content
            .alert(IOSShell.keepPagesTitle(count), isPresented: shown, presenting: leave) { (asked: PagesLeave) in
                if canSave {
                    Button(saveFirstLabel) {
                        saveFirst(asked)
                    }
                    .accessibilityIdentifier("keepPages.save")
                }
                Button(IOSShell.discardPagesLabel(count), role: .destructive) {
                    asked.action(true)
                }
                .accessibilityIdentifier("keepPages.discard")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("keepPages.cancel")
            } message: { (asked: PagesLeave) in
                Text(IOSShell.keepPagesLine(asked.reason, count: count, canSave: canSave))
            }
            .onChange(of: state.isBusy) { (_: Bool, busy: Bool) in
                if !busy {
                    saveEnded()
                }
            }
    }

    private var plan: SavePlan {
        SavePlan.make(state.scannedPages, options: state.settings.document)
    }

    private var canSave: Bool {
        !blocked && !state.isBusy && plan.pageCount > 0
    }

    private var saveFirstLabel: String {
        IOSShell.saveFirstLabel(state.settings, pageCount: plan.pageCount, target: state.appendTarget)
    }

    private func saveFirst(_ asked: PagesLeave) {
        afterSave = asked
        IOSShell.saveQueue(state)
        if !state.isBusy {
            afterSave = nil
        }
    }

    private func saveEnded() {
        guard let waiting = afterSave else { return }
        afterSave = nil
        if state.scannedPages.isEmpty {
            waiting.action(false)
        }
    }

    private var shown: Binding<Bool> {
        let question: Binding<PagesLeave?> = $leave
        return Binding<Bool>(
            get: { question.wrappedValue != nil },
            set: { (isShown: Bool) in
                if !isShown {
                    question.wrappedValue = nil
                }
            })
    }
}

/// A notice over camera mode's viewfinder: on a rounded card of the system's material.
private struct NoticeCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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

/// A stack turned over by hand, as the Mac's banner offers it: on to the backs after a feeder stopped early,
/// more fronts for a stack larger than the feeder, and once the backs did not pair up, combining the pages
/// anyway or scanning the backs again; the fronts alone while the backs are due. The status line asks for
/// these by name.
struct TurnedOverButtons: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if state.canFinishFronts {
                    Button("Done with Fronts") {
                        state.finishFronts()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(Text("Turn the stack over and scan the back sides"))
                    .accessibilityIdentifier("sides.doneWithFronts")
                }
                if state.awaitingBacks && state.sidesMismatch != nil {
                    Button("Combine Anyway") {
                        state.combineSidesAnyway()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(Text("Puts the pages in order as they are; the extra pages go at the end"))
                    .accessibilityIdentifier("sides.combine")
                    Button("Scan Back Sides Again") {
                        state.scanBacksAgain()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(Text("Removes the back sides scanned so far"))
                    .accessibilityIdentifier("sides.backsAgain")
                }
                if state.canScanMoreFronts {
                    Button("Scan More Fronts") {
                        state.scanMoreFronts()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(Text("For the sheets that did not fit in the feeder"))
                    .accessibilityIdentifier("sides.moreFronts")
                }
                if state.awaitingBacks {
                    Button("Keep Fronts Only") {
                        state.keepFrontsOnly()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(Text("Leaves out the back sides"))
                    .accessibilityIdentifier("sides.frontsOnly")
                }
            }
        }
        .disabled(state.isBusy)
    }

    /// Whether any button shows, so the scan screen leaves out an empty row.
    static func showsAny(_ state: AppState) -> Bool {
        state.canFinishFronts || state.awaitingBacks
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
/// of them, `onOpenAsNew`).
private struct PackageBanner: View {
    @EnvironmentObject private var state: AppState
    let offered: PendingPackage
    let onOpenAsNew: () -> Void

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
                    onOpenAsNew()
                }
                .accessibilityIdentifier("package.new")
            }
            .buttonStyle(.bordered)
            .disabled(!state.canIngest)
        }
    }
}

/// The scan screen's full-screen covers (Apple's scanner, the scan area, the reviews, Quick scan's page,
/// the copy screen) and a book spread's split sheet. The root view presents them, not the scan screen: the
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
