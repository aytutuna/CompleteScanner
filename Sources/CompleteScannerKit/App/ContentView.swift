import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    private enum DetailTab: Hashable {
        case scanner
        case scans
        case saved
    }

    @State private var detailTab: DetailTab = .scanner
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                switch detailTab {
                case .scanner:
                    scannerDetail
                case .scans:
                    scansDetail
                case .saved:
                    savedDetail
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $detailTab) {
                        Label("Scanner", systemImage: "scanner").tag(DetailTab.scanner)
                        Label("Scans", systemImage: "clock.arrow.circlepath").tag(DetailTab.scans)
                        Label("Saved", systemImage: "tray.full").tag(DetailTab.saved)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .sheet(isPresented: $state.showPhotoReview) {
            PhotoReviewView()
                .environmentObject(state)
        }
        .alert("CompleteScanner", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        // Below this the layout cannot stay usable; the inspector adds its own
        // width requirement only while shown.
        .frame(minWidth: 700, minHeight: 560)
        .task { state.start() }
    }

    private var scannerDetail: some View {
        // The controls live in a native inspector panel: it manages its own width,
        // counts into the window's minimum size (so nothing gets clipped in small
        // windows), is user-resizable, and can be toggled to give the page preview
        // the whole window.
        VStack(spacing: 0) {
            PreviewCanvasView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.settings.intent == .document && !state.scannedPages.isEmpty {
                Divider()
                PagesStripView()
            }
            Divider()
            StatusBarView()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 280, ideal: 330, max: 430)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Scan Settings", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the scan settings")
            }
        }
    }

    private var scansDetail: some View {
        VStack(spacing: 0) {
            ScanHistoryView()
            Divider()
            StatusBarView()
        }
    }

    private var savedDetail: some View {
        VStack(spacing: 0) {
            SavedFilesView()
            Divider()
            StatusBarView()
        }
    }
}
