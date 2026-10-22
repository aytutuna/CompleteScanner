#if os(iOS)
import CompleteScannerKit
import QuickLook
import SwiftUI

/// The app's window: the task start screen, the scan screen pushed over it, the share sheet, Mail's
/// composer and the Quick Look preview the file actions ask for, the corner editor of an imported photo, the troubleshooter,
/// the question about a network scanner's changed certificate, and the error alert (with Troubleshoot
/// when it is about a scanner). Photos and PDFs opened in this app from another one ("Open in
/// CompleteScanner") are imported: into the task set up when it takes photos (`IOSShell.takesPhotos`), else
/// into Document to PDF; while an import runs they wait for it (`IOSImportSession`). Going back from the
/// scan screen stops an import. The photo and ID card reviews are the scan screen's.
public struct IOSRootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fileActions: IOSFileActions
    @ObservedObject private var importer: IOSImportSession
    private let launchImports: [IOSImportItem]
    private let launchTask: ScanTask?
    private let picker: IOSScannerPickerModel
    @State private var showsScanner: Bool = false
    @State private var started: Bool = false

    /// `importer` brings photos and PDFs in for the state the view is given; `launchImports` are the files
    /// imported at launch (`IOSLaunchOptions`), in order, into `launchTask` when given; `picker` lists the
    /// scanners (with the network scanners, unless the app was launched with the demo scanner alone).
    public init(fileActions: IOSFileActions, importer: IOSImportSession, picker: IOSScannerPickerModel,
                launchImports: [IOSImportItem] = [], launchTask: ScanTask? = nil) {
        _fileActions = ObservedObject(wrappedValue: fileActions)
        _importer = ObservedObject(wrappedValue: importer)
        self.picker = picker
        self.launchImports = launchImports
        self.launchTask = launchTask
    }

    public var body: some View {
        NavigationStack {
            TaskStartScreen(onOpenScanner: openScanner)
                .navigationDestination(isPresented: $showsScanner) {
                    ScanScreen(picker: picker)
                }
        }
        .onChange(of: showsScanner) { (_: Bool, shown: Bool) in
            // Pages of an import must not land in a task picked after leaving its scan screen.
            if !shown {
                importer.stop()
            }
        }
        .environmentObject(importer)
        .task {
            startOnce()
        }
        .onOpenURL { (url: URL) in
            openFiles([url])
        }
        .sheet(item: $fileActions.shareRequest) { (request: ShareRequest) in
            ActivityView(items: request.urls, onDone: closeShareSheet)
        }
        .background {
            MailSheet(fileActions: fileActions)
        }
        .fullScreenCover(item: cornerRequest) { (request: PhotoCornersRequest) in
            CornerEditorView(request: request, onAnswer: answerCorners, onStop: stopImport)
        }
        .quickLookPreview($fileActions.previewURL)
        .modifier(ErrorAlert(state: state))
        .sheet(isPresented: $state.showTroubleshooter) {
            TroubleshooterScreen(makeAddModel: makeAddModel, onClose: closeTroubleshooter)
                .environmentObject(state)
        }
        .background {
            if let network = picker.network {
                CertificateQuestion(network: network)
            }
        }
    }

    private func makeAddModel() -> IOSAddScannerModel {
        picker.makeAddModel()
    }

    private func closeTroubleshooter() {
        state.showTroubleshooter = false
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

    private func closeShareSheet() {
        fileActions.shareRequest = nil
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

    /// Files opened in this app: imported into the queue, the scan screen shown.
    private func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pushed: Bool = prepareForImport(nil)
        let session: IOSImportSession = importer
        Task { @MainActor in
            await IOSRootView.settle(pushed)
            await session.importFiles(urls)
        }
    }

    /// `task` is set up when given; otherwise the task set up takes photos, or Document to PDF is set up;
    /// the scan screen is shown. True when it was pushed now.
    private func prepareForImport(_ task: ScanTask?) -> Bool {
        if let wanted = task {
            if state.activeTask != wanted {
                _ = state.startTask(wanted)
            }
        } else if state.activeTask == nil || !IOSShell.takesPhotos(state.settings) {
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            appState.showTroubleshooter = true
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
