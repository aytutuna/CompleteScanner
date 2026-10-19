import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    private enum DetailTab: Hashable {
        case start
        case scanner
        case scans
        case saved
    }

    @State private var detailTab: DetailTab = .scanner
    @State private var showInspector = true
    /// The first appearance picked the opening view: the start screen on a first run, the
    /// scanner view (with the task the user had last) afterwards.
    @State private var choseOpeningView = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            // The tab switcher lives in the content, not the toolbar: toolbar
            // `.principal` items merge the title bar on newer macOS and push the
            // sidebar under the traffic-light buttons.
            VStack(spacing: 0) {
                HStack {
                    Picker("View", selection: $detailTab) {
                        Text("Start").tag(DetailTab.start)
                        Text("Scanner").tag(DetailTab.scanner)
                        Text("Scans").tag(DetailTab.scans)
                        Text("Saved").tag(DetailTab.saved)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 360)
                    Spacer()
                    if detailTab == .scanner {
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Scan Settings", systemImage: "sidebar.trailing")
                        }
                        .labelStyle(.iconOnly)
                        .help("Show or hide the scan settings")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
                switch detailTab {
                case .start:
                    startDetail
                case .scanner:
                    scannerDetail
                case .scans:
                    scansDetail
                case .saved:
                    savedDetail
                }
            }
        }
        .sheet(isPresented: $state.showPhotoReview) {
            PhotoReviewView()
                .environmentObject(state)
        }
        .alert("CompleteScanner", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil; state.errorSuggestsTroubleshooter = false } }
        )) {
            // A scanner that would not connect or scan: the alert offers the troubleshooter.
            if state.errorSuggestsTroubleshooter {
                Button("Troubleshoot\u{2026}") { state.showTroubleshooter = true }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        // Below this the layout cannot stay usable; the inspector adds its own
        // width requirement only while shown.
        .frame(minWidth: 700, minHeight: 560)
        .onAppear {
            guard !choseOpeningView else { return }
            choseOpeningView = true
            if state.isFirstRun { detailTab = .start }
        }
        .task { state.start() }
    }

    private var scannerDetail: some View {
        // The controls live in a native inspector panel: it manages its own width,
        // counts into the window's minimum size (so nothing gets clipped in small
        // windows), is user-resizable, and can be toggled to give the page preview
        // the whole window.
        VStack(spacing: 0) {
            if state.activeTaskDefinition != nil || state.isTurningOverByHand {
                TaskBannerView(definition: state.activeTaskDefinition, onChangeTask: { detailTab = .start })
                Divider()
            }
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
    }

    private var startDetail: some View {
        VStack(spacing: 0) {
            TaskStartView(onOpenScanner: { detailTab = .scanner })
            Divider()
            StatusBarView()
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
