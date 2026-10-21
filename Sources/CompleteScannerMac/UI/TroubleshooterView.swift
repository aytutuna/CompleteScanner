#if os(macOS)
import CompleteScannerKit
import SwiftUI

/// "Why isn't my scanner listed?": one line saying what is listed and how many problems and
/// warnings there are (`Troubleshooter.overview`), then the troubleshooter's checks
/// (`Troubleshooter.diagnose`): a card for each one to look at, with its status, one line, the
/// buttons that help (Image Capture, Printers & Scanners) and "More help" with the rest; a compact
/// row for each check that passed. Copy Diagnostics and Refresh are in the footer. Shown as a sheet
/// from the sidebar and from an error about a scanner; it follows `AppState` while open. Twin of the
/// Windows `TroubleshooterWindow`.
struct TroubleshooterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// What the footer says after Copy Diagnostics or a button that opens something, including
    /// why it did not work (the only place that is reported while the sheet is open).
    @State private var footerMessage: String?
    /// Refresh is waiting for the connections to answer; a Refresh meanwhile is ignored, and the
    /// buttons stay enabled so keyboard focus stays where it is.
    @State private var refreshing = false

    var body: some View {
        let snapshot = state.troubleshootSnapshot()
        let checks = Troubleshooter.diagnose(snapshot)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Why isn't my scanner listed?")
                    .font(.title2.weight(.semibold))
                Text(refreshing ? "Looking for scanners\u{2026}" : Troubleshooter.overview(snapshot, checks: checks))
                    .font(.headline)
                    .padding(.top, 4)
            }
            .padding(20)
            .accessibilityElement(children: .combine)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks, id: \.id) { check in
                        TroubleshootCheckCard(check: check) { action in perform(action) }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    copyDiagnostics()
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
                .help("Copy the results to send to support")
                if let footerMessage {
                    Text(footerMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(footerMessage)
                }
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Check again")
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 440, idealHeight: 620)
    }

    @MainActor
    private func perform(_ action: TroubleshootAction) {
        switch action {
        case .refresh:
            refresh()
        case .copyDiagnostics:
            copyDiagnostics()
        case .openScannerSettings, .openNetworkSettings, .openImageCapture:
            footerMessage = state.openTroubleshootLink(action)
        case .addByAddress:
            // Windows only: macOS has no way to add a network scanner by its address.
            break
        }
    }

    /// Looks for scanners again; the checks follow the list as it changes, and the summary says
    /// so for a few seconds. A Refresh meanwhile is ignored, so the search is not restarted
    /// before it can answer.
    @MainActor
    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        state.refreshScanners()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refreshing = false
        }
    }

    @MainActor
    private func copyDiagnostics() {
        footerMessage = state.copyDiagnostics(state.troubleshootSnapshot()) ?? "Copied to the clipboard."
    }
}

/// One check: the status symbol (named for VoiceOver), the title, the one-line detail, its buttons and
/// "More help" with the rest. A check that passed and offers nothing to do is a compact row: its title,
/// with what it found as its help. Refresh is the footer's, not repeated in a card.
private struct TroubleshootCheckCard: View {
    let check: TroubleshootCheck
    let perform: (TroubleshootAction) -> Void

    /// The buttons of the card: every action but Refresh.
    private var actions: [TroubleshootAction] { check.actions.filter { $0 != .refresh } }

    var body: some View {
        if check.status == .ok && actions.isEmpty {
            passedRow
        } else {
            card
        }
    }

    private var passedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityLabel(Troubleshooter.statusLabel(check.status))
            Text(check.title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(check.fullDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Troubleshooter.statusLabel(check.status)): \(check.title)")
        .accessibilityHint(Text(check.fullDetail))
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityLabel(Troubleshooter.statusLabel(check.status))
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(check.detail)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.self) { action in
                            Button(Troubleshooter.label(action, platform: .mac)) { perform(action) }
                                .help(check.title)
                        }
                    }
                    .padding(.top, 4)
                }
                if !check.more.isEmpty {
                    DisclosureGroup("More help") {
                        Text(check.more)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    .padding(.top, 2)
                    .accessibilityLabel(Text("More help: \(check.title)"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Troubleshooter.statusLabel(check.status)): \(check.title)")
        .accessibilityHint(Text(check.fullDetail))
    }

    private var symbol: String {
        switch check.status {
        case .problem: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.circle.fill"
        case .tip: return "lightbulb"
        }
    }

    private var color: Color {
        switch check.status {
        case .problem: return .red
        case .warning: return .yellow
        case .ok: return .green
        case .tip: return .accentColor
        }
    }
}
#endif
