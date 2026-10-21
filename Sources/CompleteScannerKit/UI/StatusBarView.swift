import SwiftUI

/// Slim bar under the preview canvas: current status, a busy spinner, and what can be done with
/// the files saved last (open, show in Finder, share, copy; open with and email in More). The
/// twin of the bar Windows shows after a save. The status shows at most six words, facts only
/// (`StatusLine`); VoiceOver reads the whole sentence.
struct StatusBarView: View {
    @EnvironmentObject var state: AppState

    /// The actions with their own button; the rest are in More.
    private static let barActions: [FileAction] = [.open, .reveal, .share, .copy]

    var body: some View {
        HStack(spacing: 8) {
            Text(shownStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text(state.statusMessage))
            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 16)
            if !state.lastSavedURLs.isEmpty {
                if state.lastSavedURLs.count > 1 {
                    Text("\(state.lastSavedURLs.count) files saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                savedActions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// The status in six words at most: empty while a review shows its own title, "Saved" while the
    /// saved files' actions show (with any warning a setting changed for the scanner adds).
    private var shownStatus: String {
        let idle: Bool = !state.isBusy
        let device: String? = state.devices.first(where: { $0.id == state.selectedDeviceID })?.name
        let reviewShown: Bool = idle && (state.showPhotoReview || state.showIdCardReview)
        let savedShown: Bool = idle && !state.lastSavedURLs.isEmpty
        return StatusLine.shown(state.statusMessage, deviceName: device, reviewShown: reviewShown, savedShown: savedShown)
    }

    private var savedActions: some View {
        let urls = state.lastSavedURLs
        let offered = state.savedFileActions
        return HStack(spacing: 10) {
            ForEach(offered.filter { Self.barActions.contains($0) }) { action in
                Button {
                    state.runFileAction(action, urls: urls)
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
                .labelStyle(.iconOnly)
                .help(action.hint(fileCount: urls.count))
            }
            Menu {
                ForEach(offered) { action in
                    Button {
                        state.runFileAction(action, urls: urls)
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                    }
                }
            } label: {
                Label("More actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: open with, email")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
