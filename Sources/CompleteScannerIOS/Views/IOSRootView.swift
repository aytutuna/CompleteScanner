#if os(iOS)
import CompleteScannerKit
import QuickLook
import SwiftUI

/// The app's window: the task start screen, the scan screen pushed over it, the share sheet and the
/// Quick Look preview the file actions ask for, and the error alert.
public struct IOSRootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fileActions: IOSFileActions
    @State private var showsScanner: Bool = false
    @State private var started: Bool = false

    public init(fileActions: IOSFileActions) {
        _fileActions = ObservedObject(wrappedValue: fileActions)
    }

    public var body: some View {
        NavigationStack {
            TaskStartScreen(onOpenScanner: openScanner)
                .navigationDestination(isPresented: $showsScanner) {
                    ScanScreen()
                }
        }
        .task {
            startOnce()
        }
        .sheet(item: $fileActions.shareRequest) { (request: ShareRequest) in
            ActivityView(items: request.urls, onDone: closeShareSheet)
        }
        .quickLookPreview($fileActions.previewURL)
        .alert(errorNotice.title, isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorNotice.message)
        }
    }

    /// The error the alert shows, as its title and message (as on the Mac).
    private var errorNotice: ProblemNotice {
        ScannerProblems.notice(state.errorMessage ?? "")
    }

    private var errorShown: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.errorMessage != nil },
            set: { (shown: Bool) in
                if !shown {
                    appState.errorMessage = nil
                    appState.errorSuggestsTroubleshooter = false
                }
            })
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
    }
}
#endif
