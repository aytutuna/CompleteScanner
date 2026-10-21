#if os(iOS)
import CompleteScannerKit
import QuickLook
import SwiftUI

/// The app's window: the task start screen, the scan screen pushed over it, the share sheet and the
/// Quick Look preview the file actions ask for, the corner editor of an imported photo, and the error
/// alert. Photos and PDFs opened in this app from another one ("Open in CompleteScanner") are imported
/// into the queue: into the task set up when it collects pages, else into Document to PDF; while an
/// import runs they wait for it (`IOSImportSession`). Going back from the scan screen stops an import.
public struct IOSRootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fileActions: IOSFileActions
    @ObservedObject private var importer: IOSImportSession
    private let launchImport: IOSImportItem?
    @State private var showsScanner: Bool = false
    @State private var started: Bool = false

    /// `importer` brings photos and PDFs in for the state the view is given; `launchImport` is the photo
    /// imported at launch (`IOSLaunchOptions`), nil for none.
    public init(fileActions: IOSFileActions, importer: IOSImportSession, launchImport: IOSImportItem? = nil) {
        _fileActions = ObservedObject(wrappedValue: fileActions)
        _importer = ObservedObject(wrappedValue: importer)
        self.launchImport = launchImport
    }

    public var body: some View {
        NavigationStack {
            TaskStartScreen(onOpenScanner: openScanner)
                .navigationDestination(isPresented: $showsScanner) {
                    ScanScreen()
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
        .fullScreenCover(item: cornerRequest) { (request: PhotoCornersRequest) in
            CornerEditorView(request: request, onAnswer: answerCorners, onStop: stopImport)
        }
        .quickLookPreview($fileActions.previewURL)
        .modifier(ErrorAlert(state: state))
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
        if let item = launchImport {
            let pushed: Bool = prepareForImport()
            let session: IOSImportSession = importer
            Task { @MainActor in
                await IOSRootView.settle(pushed)
                await session.importItems([item])
            }
        }
    }

    /// Files opened in this app: imported into the queue, the scan screen shown.
    private func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pushed: Bool = prepareForImport()
        let session: IOSImportSession = importer
        Task { @MainActor in
            await IOSRootView.settle(pushed)
            await session.importFiles(urls)
        }
    }

    /// The task set up collects pages, or Document to PDF is set up; the scan screen is shown. True when
    /// it was pushed now.
    private func prepareForImport() -> Bool {
        if state.activeTask == nil || !PhotoImport.isOffered(state.settings) {
            state.startTask(.document)
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

/// The error alert: `state.errorMessage` as its title and message (as on the Mac), cleared when it is
/// dismissed. The root view has it, and so does our camera's screen, since the root's alert cannot show
/// over the full-screen cover the camera is in.
@MainActor
struct ErrorAlert: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content
            .alert(notice.title, isPresented: shown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice.message)
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
