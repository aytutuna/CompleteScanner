import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            HStack(spacing: 0) {
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
                Divider()
                InspectorView()
                    .frame(width: 330)
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
        .task { state.start() }
    }
}
