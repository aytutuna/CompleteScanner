#if os(iOS)
import CompleteScannerKit
import QuickLook
import SwiftUI
import UIKit

/// The app's window: on a compact width (iPhone, a narrow iPad window) the task start screen with the scan
/// screen pushed over it; on a regular width (iPad, `IOSLayout.usesSidebar`) a sidebar with the tasks, the
/// presets, the scanners and the library beside the scan screen (or the start screen, the presets, the
/// scans or the saved files). Settings opens as a sheet (Command-comma). Also the share sheet, Mail's
/// composer and the Quick Look preview the file actions ask for (`FileActionPresenters`, which the Settings
/// sheet has too), the scan screen's covers (`ScanCovers`, kept here so they outlive a change of layout),
/// the corner editor of an imported photo, the troubleshooter,
/// the question about a network scanner's changed certificate, and the error alert (with Troubleshoot
/// when it is about a scanner; in the Settings sheet it opens Settings' own troubleshooter). It keeps the
/// screen on while a network scanner's job runs. Photos and PDFs opened in this app from another one ("Open in
/// CompleteScanner") are imported: into the task set up when it takes photos (`IOSShell.takesPhotos`), else
/// into Document to PDF; while an import runs they wait for it (`IOSImportSession`). A CompleteScanner
/// document (`.csdoc`, I18) is not imported: the scan screen offers it on its banner. Leaving the scan screen
/// stops an import and closes the scan screen's covers. The scan screen opens the photo and ID card reviews.
public struct IOSRootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.horizontalSizeClass) private var sizeClass: UserInterfaceSizeClass?
    @ObservedObject private var fileActions: IOSFileActions
    @ObservedObject private var importer: IOSImportSession
    private let launchImports: [IOSImportItem]
    private let launchTask: ScanTask?
    private let picker: IOSScannerPickerModel
    private let companion: IOSCompanionBrowser?
    @State private var showsScanner: Bool = false
    @State private var detail: IOSDetail = IOSDetail.start
    @State private var showsSettings: Bool = false
    @State private var showsSettingsTroubleshooter: Bool = false
    @State private var scanCover: ScanCover?
    @State private var spreadEditor: SpreadEditorSource?
    @State private var columns: NavigationSplitViewVisibility = NavigationSplitViewVisibility.all
    @State private var started: Bool = false

    /// `importer` brings photos and PDFs in for the state the view is given; `launchImports` are the files
    /// imported at launch (`IOSLaunchOptions`), in order, into `launchTask` when given; `picker` lists the
    /// scanners (with the network scanners, unless the app was launched with the demo scanner alone);
    /// `companion` browses the computers on the network for Settings' My computer.
    public init(fileActions: IOSFileActions, importer: IOSImportSession, picker: IOSScannerPickerModel,
                launchImports: [IOSImportItem] = [], launchTask: ScanTask? = nil,
                companion: IOSCompanionBrowser? = nil) {
        _fileActions = ObservedObject(wrappedValue: fileActions)
        _importer = ObservedObject(wrappedValue: importer)
        self.picker = picker
        self.companion = companion
        self.launchImports = launchImports
        self.launchTask = launchTask
    }

    public var body: some View {
        Group {
            if IOSLayout.usesSidebar(sizeClass) {
                sidebarLayout
            } else {
                stackLayout
            }
        }
        .onChange(of: showsScanner) { (_: Bool, shown: Bool) in
            // Pages of an import must not land in a task picked after leaving its scan screen.
            if !shown {
                importer.stop()
                scanCover = nil
                spreadEditor = nil
            }
        }
        .onChange(of: state.isBusy) { (_: Bool, busy: Bool) in
            keepAwake(busy)
        }
        .environmentObject(importer)
        .task {
            startOnce()
        }
        .onOpenURL { (url: URL) in
            openFiles([url])
        }
        .modifier(FileActionPresenters(fileActions: fileActions, state: state))
        .modifier(ScanCovers(state: state, importer: importer, cover: $scanCover, spreadEditor: $spreadEditor))
        .fullScreenCover(item: cornerRequest) { (request: PhotoCornersRequest) in
            CornerEditorView(request: request, onAnswer: answerCorners, onStop: stopImport)
        }
        .sheet(isPresented: $state.showTroubleshooter) {
            TroubleshooterScreen(makeAddModel: makeAddModel, onClose: closeTroubleshooter)
                .environmentObject(state)
        }
        .background {
            if let network = picker.network {
                CertificateQuestion(network: network)
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsScreen(makeAddModel: makeAddModel, onPresetApplied: presetApplied, onClose: closeSettings,
                               showsTroubleshooter: $showsSettingsTroubleshooter, companion: companion)
            }
            .modifier(FileActionPresenters(fileActions: fileActions, state: state,
                                           onTroubleshoot: openSettingsTroubleshooter))
            .environmentObject(state)
            .environmentObject(importer)
        }
    }

    /// iPhone: the start screen, the scan screen pushed over it.
    private var stackLayout: some View {
        NavigationStack {
            TaskStartScreen(onOpenScanner: openScanner, onOpenSettings: openSettings)
                .navigationDestination(isPresented: $showsScanner) {
                    ScanScreen(picker: picker, cover: $scanCover, spreadEditor: $spreadEditor,
                               onOpenSettings: openSettings)
                }
        }
    }

    /// iPad: the sidebar, and the scan screen (or what the sidebar's library picked) beside it.
    private var sidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columns) {
            IOSSidebar(picker: picker, scannerShown: showsScanner, detail: detail, onTask: pickTask,
                       onPresetApplied: openScanner, onDetail: showDetail, onSettings: openSettings)
                .navigationTitle("CompleteScanner")
        } detail: {
            NavigationStack {
                splitDetail
            }
        }
    }

    @ViewBuilder
    private var splitDetail: some View {
        if showsScanner {
            ScanScreen(picker: picker, cover: $scanCover, spreadEditor: $spreadEditor, pickerInSidebar: true)
        } else {
            switch detail {
            case .start:
                TaskStartScreen(onOpenScanner: openScanner)
            case .presets:
                PresetsScreen(onApplied: openScanner)
            case .history:
                HistoryScreen()
            case .saved:
                SavedFilesScreen()
            }
        }
    }

    private func pickTask(_ task: ScanTask) {
        if state.startTask(task) {
            state.clearAppendTarget()
            openScanner()
        }
    }

    private func showDetail(_ shown: IOSDetail) {
        detail = shown
        showsScanner = false
    }

    private func openSettings() {
        showsSettingsTroubleshooter = false
        showsSettings = true
    }

    private func closeSettings() {
        showsSettings = false
    }

    /// The root cannot present the troubleshooter over Settings, so the error alert there opens Settings' own.
    private func openSettingsTroubleshooter() {
        showsSettingsTroubleshooter = true
    }

    /// A preset picked in Settings is in use: Settings closes and the scan screen opens.
    private func presetApplied() {
        showsSettings = false
        openScanner()
    }

    private func makeAddModel() -> IOSAddScannerModel {
        picker.makeAddModel()
    }

    private func closeTroubleshooter() {
        state.showTroubleshooter = false
    }

    /// While a network scanner's job runs, the screen stays on: iOS would suspend the app soon after it
    /// locked, cutting a feeder batch short. Set here, not by the scan screen: a change of layout builds that
    /// screen anew, and the old copy's onDisappear may run after the new copy's onAppear.
    private func keepAwake(_ busy: Bool) {
        let selected: String? = state.selectedDeviceID
        let device: ScannerInfo? = state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })
        UIApplication.shared.isIdleTimerDisabled = IOSShell.keepsScreenAwake(isBusy: busy, device: device)
    }

    /// The corner editor waiting for an answer; closing it any other way skips the photo. While our
    /// camera's screen is open it shows the editor itself (`editorInCamera`), so none is presented here.
    private var cornerRequest: Binding<PhotoCornersRequest?> {
        let session: IOSImportSession = importer
        return Binding<PhotoCornersRequest?>(
            get: { session.editorInCamera ? nil : session.cornerRequest },
            set: { (request: PhotoCornersRequest?) in
                if request == nil {
                    session.answer(PhotoCornersAnswer.skip)
                }
            })
    }

    private func answerCorners(_ answer: PhotoCornersAnswer) {
        importer.answer(answer)
    }

    private func stopImport() {
        importer.stop()
    }

    private func openScanner() {
        showsScanner = true
    }

    private func startOnce() {
        guard !started else { return }
        started = true
        state.start()
        if !launchImports.isEmpty {
            let items: [IOSImportItem] = launchImports
            let pushed: Bool = prepareForImport(launchTask)
            let session: IOSImportSession = importer
            Task { @MainActor in
                await IOSRootView.settle(pushed)
                await session.importItems(items)
            }
        }
    }

    /// Files opened in this app: a CompleteScanner document to the scan screen's banner, the others
    /// imported into the queue; the scan screen shown.
    private func openFiles(_ urls: [URL]) {
        var imports: [URL] = []
        for url in urls {
            if IOSShell.isPackage(url) {
                openPackage(url)
            } else {
                imports.append(url)
            }
        }
        guard !imports.isEmpty else { return }
        let pushed: Bool = prepareForImport(nil)
        let session: IOSImportSession = importer
        Task { @MainActor in
            await IOSRootView.settle(pushed)
            await session.importFiles(imports)
        }
    }

    /// A `.csdoc` opened in this app, offered on the scan screen's banner. Document to PDF is set up when no
    /// task is; a task set up is kept (an ID card half taken, say), and the banner says when it does not
    /// collect pages.
    private func openPackage(_ url: URL) {
        if state.activeTask == nil {
            _ = state.startTask(.document)
        }
        showsScanner = true
        let appState: AppState = state
        Task { @MainActor in
            await IOSShell.openPackage(url, in: appState)
        }
    }

    /// `task` is set up when given; otherwise the task set up takes photos (not the photocopy, which holds
    /// one batch of pages; a copy still held keeps its task and the import is refused as a held Quick scan is), or
    /// Document to PDF is set up; the scan screen is shown. True when it was pushed now.
    private func prepareForImport(_ task: ScanTask?) -> Bool {
        if let wanted = task {
            if state.activeTask != wanted {
                _ = state.startTask(wanted)
            }
        } else if state.activeTask == nil || !IOSShell.takesPhotos(state.settings) || (state.isCopyFlow && state.copyPages.isEmpty) {
            _ = state.startTask(.document)
        }
        let pushed: Bool = !showsScanner
        showsScanner = true
        return pushed
    }

    /// Lets the scan screen's push finish before the corner editor is presented over it.
    private static func settle(_ pushed: Bool) async {
        if pushed {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
}

/// The share sheet, Mail's composer and the Quick Look preview the file actions ask for, and the error
/// alert. The root view has them, and so does the Settings sheet: a sheet's view cannot present while
/// another is up over it, so Saved files in Settings would otherwise show nothing until Settings closed.
@MainActor
private struct FileActionPresenters: ViewModifier {
    @ObservedObject var fileActions: IOSFileActions
    @ObservedObject var state: AppState
    /// The error alert's Troubleshoot (`ErrorAlert.onTroubleshoot`).
    var onTroubleshoot: (@MainActor () -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .sheet(item: $fileActions.shareRequest) { (request: ShareRequest) in
                ActivityView(items: request.urls, onDone: closeShareSheet)
            }
            .background {
                MailSheet(fileActions: fileActions)
            }
            .quickLookPreview($fileActions.previewURL)
            .modifier(ErrorAlert(state: state, onTroubleshoot: onTroubleshoot))
    }

    private func closeShareSheet() {
        fileActions.shareRequest = nil
    }
}

/// Mail's composer for the files the Email task saved (`IOSFileActions.mailRequest`), in a sheet of its own
/// beside the share sheet's.
private struct MailSheet: View {
    @ObservedObject var fileActions: IOSFileActions

    var body: some View {
        Color.clear
            .sheet(item: $fileActions.mailRequest) { (request: MailRequest) in
                #if canImport(MessageUI)
                MailComposeView(request: request, onDone: close)
                    .ignoresSafeArea()
                #else
                ActivityView(items: request.urls, onDone: close)
                #endif
            }
    }

    private func close() {
        fileActions.mailRequest = nil
    }
}

/// The question about a network scanner whose certificate changed since it was trusted, asked when the user
/// picks it (`IOSNetworkScanners.certificateQuestion`).
private struct CertificateQuestion: View {
    @ObservedObject var network: IOSNetworkScanners

    var body: some View {
        Color.clear
            .sheet(isPresented: shown) {
                if let certificate = network.certificateQuestion {
                    CertificateChangedView(certificate: certificate, onAnswer: answer)
                }
            }
    }

    private var shown: Binding<Bool> {
        let scanners: IOSNetworkScanners = network
        return Binding<Bool>(
            get: { scanners.certificateQuestion != nil },
            set: { (isShown: Bool) in
                if !isShown {
                    scanners.answerCertificate(false)
                }
            })
    }

    private func answer(_ trust: Bool) {
        network.answerCertificate(trust)
    }
}

/// The error alert: `state.errorMessage` as its title and message (as on the Mac), cleared when it is
/// dismissed; Troubleshoot opens the troubleshooter when the error is about a scanner that would not
/// connect or scan. The root view has it, and so does our camera's screen, since the root's alert cannot
/// show over the full-screen cover the camera is in.
@MainActor
struct ErrorAlert: ViewModifier {
    @ObservedObject var state: AppState
    /// Opens a troubleshooter where the root's cannot show (the Settings sheet); nil: the root's
    /// (`AppState.showTroubleshooter`).
    var onTroubleshoot: (@MainActor () -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .alert(notice.title, isPresented: shown) {
                if state.errorSuggestsTroubleshooter {
                    Button(IOSNetworkText.troubleshoot) {
                        openTroubleshooter()
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice.message)
            }
    }

    /// Opens the troubleshooter once the alert has gone.
    private func openTroubleshooter() {
        let appState: AppState = state
        let open: (@MainActor () -> Void)? = onTroubleshoot
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let troubleshoot = open {
                troubleshoot()
            } else {
                appState.showTroubleshooter = true
            }
        }
    }

    /// The error the alert shows, as its title and message.
    private var notice: ProblemNotice {
        ScannerProblems.notice(state.errorMessage ?? "")
    }

    private var shown: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.errorMessage != nil },
            set: { (isShown: Bool) in
                if !isShown {
                    appState.errorMessage = nil
                    appState.errorSuggestsTroubleshooter = false
                }
            })
    }
}
#endif
