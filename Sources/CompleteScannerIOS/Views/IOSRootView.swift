#if os(iOS)
import AVFoundation
import CompleteScannerKit
import QuickLook
import SwiftUI
import UIKit

/// The app's window: on a compact width (iPhone, a narrow iPad window) the scan screen, set up at launch
/// for the task used last (`IOSShell.launchTask`) with our camera opened at once where it can be used
/// (`IOSShell.cameraOnOpen`; the first time, after a card saying why), the task list in a sheet over it and
/// the library pushed; on a regular width (iPad, `IOSLayout.usesSidebar`) a sidebar with the tasks, the
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
    private let demoScanner: Bool
    /// On the iPad, whether the detail is the scan screen; on the iPhone it always is.
    @State private var showsScanner: Bool = false
    @State private var showsTasks: Bool = false
    /// A tile or a preset was picked in the task sheet: the camera opens once it has closed.
    @State private var taskPicked: Bool = false
    @State private var showsLibrary: Bool = false
    @State private var showsCameraIntro: Bool = false
    @AppStorage(IOSShell.cameraIntroKey) private var cameraIntroShown: Bool = false
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
    /// `companion` browses the computers on the network for Settings' My computer; `demoScanner` (the UI
    /// tests' `-demoScanner`) keeps the camera from opening by itself.
    public init(fileActions: IOSFileActions, importer: IOSImportSession, picker: IOSScannerPickerModel,
                launchImports: [IOSImportItem] = [], launchTask: ScanTask? = nil,
                companion: IOSCompanionBrowser? = nil, demoScanner: Bool = false) {
        _fileActions = ObservedObject(wrappedValue: fileActions)
        _importer = ObservedObject(wrappedValue: importer)
        self.picker = picker
        self.companion = companion
        self.demoScanner = demoScanner
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

    /// iPhone: the scan screen, with the task sheet over it and the library pushed.
    private var stackLayout: some View {
        NavigationStack {
            ScanScreen(picker: picker, cover: $scanCover, spreadEditor: $spreadEditor, onOpenSettings: openSettings,
                       onOpenTasks: openTasks, onOpenLibrary: openLibrary)
                .navigationDestination(isPresented: $showsLibrary) {
                    LibraryScreen()
                }
        }
        .overlay {
            if showsCameraIntro {
                CameraIntroCard(onContinue: continueToCamera)
            }
        }
        .sheet(isPresented: $showsTasks, onDismiss: tasksClosed) {
            TaskSheet(onPicked: pickedInSheet, onClose: closeTasks)
                .environmentObject(state)
                .environmentObject(importer)
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

    private func pickTask(_ task: ScanTask, target: URL?) {
        if state.startTask(task) {
            if let target {
                state.setAppendTarget(target)
            } else {
                state.clearAppendTarget()
            }
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

    private func openTasks() {
        taskPicked = false
        showsTasks = true
    }

    private func closeTasks() {
        showsTasks = false
    }

    private func pickedInSheet() {
        taskPicked = true
        showsTasks = false
    }

    /// The camera opens only once the sheet has gone: a cover cannot be presented while it is still up.
    private func tasksClosed() {
        if taskPicked {
            taskPicked = false
            openCameraAtOnce()
        }
    }

    private func openLibrary() {
        showsLibrary = true
    }

    /// Our camera at once on the iPhone, for a task that takes photos where the camera can be used; the
    /// first time, the card saying why comes before iOS asks for it.
    private func openCameraAtOnce() {
        guard !IOSLayout.usesSidebar(sizeClass), scanCover == nil, importer.canImport else { return }
        let action: IOSCameraOnOpen = IOSShell.cameraOnOpen(
            offersCamera: IOSShell.offersOwnCamera(state.settings), camera: IOSCameraAvailability.ownCamera,
            authorization: AVCaptureDevice.authorizationStatus(for: .video), introShown: cameraIntroShown,
            demo: demoScanner)
        switch action {
        case .open:
            scanCover = .camera
        case .introduce:
            showsCameraIntro = true
        case .stay:
            break
        }
    }

    private func continueToCamera() {
        cameraIntroShown = true
        showsCameraIntro = false
        if scanCover == nil && importer.canImport {
            scanCover = .camera
        }
    }

    private func closeSettings() {
        showsSettings = false
    }

    /// The root cannot present the troubleshooter over Settings, so the error alert there opens Settings' own.
    private func openSettingsTroubleshooter() {
        showsSettingsTroubleshooter = true
    }

    /// A preset picked in Settings is in use: Settings closes and the scan screen shows.
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

    /// The scan screen in front: the iPad's detail, and on the iPhone the library and the task sheet gone.
    private func openScanner() {
        showsScanner = true
        showsLibrary = false
        showsTasks = false
    }

    private func startOnce() {
        guard !started else { return }
        started = true
        state.start()
        // Settings left without a task by hand are kept: only a first run or a task not offered here starts one.
        let task: ScanTask = IOSShell.launchTask(state.settings)
        if state.activeTask != task && (state.activeTask != nil || state.isFirstRun) {
            _ = state.startTask(task)
        }
        if !launchImports.isEmpty {
            let items: [IOSImportItem] = launchImports
            let pushed: Bool = prepareForImport(launchTask)
            let session: IOSImportSession = importer
            Task { @MainActor in
                await IOSRootView.settle(pushed)
                await session.importItems(items)
            }
        } else if !IOSLayout.usesSidebar(sizeClass) {
            showsScanner = true
            openCameraAtOnce()
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
    /// collect pages. Our camera closes so the banner is seen.
    private func openPackage(_ url: URL) {
        if state.activeTask == nil {
            _ = state.startTask(.document)
        }
        openScanner()
        if scanCover == .camera {
            scanCover = nil
        }
        let appState: AppState = state
        Task { @MainActor in
            await IOSShell.openPackage(url, in: appState)
        }
    }

    /// `task` is set up when given; otherwise the task set up takes photos (not the photocopy, which holds
    /// one batch of pages; a copy still held keeps its task and the import is refused as a held Quick scan is), or
    /// Document to PDF is set up; the scan screen is shown. True when it was brought to the front now (shown
    /// on the iPad, or the library or the task sheet closed on the iPhone).
    private func prepareForImport(_ task: ScanTask?) -> Bool {
        if let wanted = task {
            if state.activeTask != wanted {
                _ = state.startTask(wanted)
            }
        } else if state.activeTask == nil || !IOSShell.takesPhotos(state.settings) || (state.isCopyFlow && state.copyPages.isEmpty) {
            _ = state.startTask(.document)
        }
        let pushed: Bool = !showsScanner || showsLibrary || showsTasks
        openScanner()
        return pushed
    }

    /// Lets the scan screen come to the front before the corner editor is presented over it.
    private static func settle(_ pushed: Bool) async {
        if pushed {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }
}

/// The card over the scan screen before iOS first asks for the camera, so the question has a reason.
private struct CameraIntroCard: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(IOSCameraText.introLine)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(IOSCameraText.introHelp)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onContinue()
                } label: {
                    Text(IOSCameraText.continueLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("camera.intro.continue")
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .systemBackground)))
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("camera.intro")
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
