import SwiftUI

/// Slim bar under the preview canvas: current status, a busy spinner, and quick
/// access to the most recently saved file.
struct StatusBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text(state.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 16)
            if let lastURL = state.lastSavedURLs.last {
                if state.lastSavedURLs.count > 1 {
                    Text("\(state.lastSavedURLs.count) files saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Show in Finder") {
                    state.revealInFinder(lastURL)
                }
                .buttonStyle(.link)
                .font(.callout)
                .help("Reveal the most recently saved file in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
