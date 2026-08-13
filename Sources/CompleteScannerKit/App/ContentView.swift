import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    private enum DetailTab: Hashable {
        case scanner
        case scans
        case saved
    }

    @State private var detailTab: DetailTab = .scanner

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
        // Below this the layout cannot stay usable (sidebar + canvas + inspector).
        .frame(minWidth: 960, minHeight: 620)
        .task { state.start() }
    }

    private var scannerDetail: some View {
        // A draggable split instead of a fixed-width inspector: in small windows the
        // canvas keeps its share (and the page preview keeps fitting), and the user can
        // trade space between preview and controls.
        HSplitView {
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
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            InspectorView()
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 430)
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
