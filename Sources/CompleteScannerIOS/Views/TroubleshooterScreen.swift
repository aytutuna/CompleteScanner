#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// "Why isn't my scanner listed?" on the iPhone and iPad, with the shared texts (`Troubleshooter`): the
/// one-line headline, then a card for each problem and warning (title, its one line, its buttons, and
/// More help when there is more), a compact row for each check that is fine, and the tips. Refresh and
/// Copy diagnostics are at the bottom. It reads the app's state again every two seconds while shown, so
/// scanners and the search's state appear as they change.
struct TroubleshooterScreen: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(IOSShell.scanSourceKey) private var source: String = ""
    /// The add-by-address sheet's model; nil where it is not offered.
    let makeAddModel: (() -> IOSAddScannerModel)?
    let onClose: () -> Void
    @State private var snapshot: DiscoverySnapshot = DiscoverySnapshot(platform: .ios)
    @State private var footer: String?
    @State private var showsAdd: Bool = false

    /// The screen's title, as the Windows window's.
    static let title = "Why isn't my scanner listed?"

    var body: some View {
        let checks: [TroubleshootCheck] = Troubleshooter.diagnose(snapshot)
        NavigationStack {
            List {
                Section {
                    Text(Troubleshooter.overview(snapshot, checks: checks))
                        .font(.headline)
                        .accessibilityIdentifier("troubleshooter.headline")
                }
                Section {
                    ForEach(checks, id: \.id) { (check: TroubleshootCheck) in
                        TroubleshootCheckRow(check: check, perform: perform)
                    }
                }
                if let footer {
                    Section {
                        Text(footer)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .accessibilityIdentifier("troubleshooter.footer")
                    }
                }
            }
            .navigationTitle(TroubleshooterScreen.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("troubleshooter.done")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(Troubleshooter.label(.copyDiagnostics, platform: .ios)) {
                        perform(.copyDiagnostics)
                    }
                    .accessibilityIdentifier("troubleshooter.copy")
                    Spacer()
                    Button(Troubleshooter.label(.refresh, platform: .ios)) {
                        perform(.refresh)
                    }
                    .accessibilityIdentifier("troubleshooter.refresh")
                }
            }
            .task {
                while !Task.isCancelled {
                    reload()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .sheet(isPresented: $showsAdd) {
                if let makeAddModel {
                    AddScannerView(model: makeAddModel(), onAdded: added, onClose: closeAdd)
                        .environmentObject(state)
                }
            }
        }
    }

    private func reload() {
        snapshot = state.troubleshootSnapshot()
    }

    private func perform(_ action: TroubleshootAction) {
        switch action {
        case .refresh:
            state.refreshScanners()
            reload()
            footer = nil
        case .copyDiagnostics:
            footer = state.copyDiagnostics(snapshot) ?? "Copied."
        case .addByAddress:
            if makeAddModel != nil {
                showsAdd = true
            }
        case .openAppSettings:
            footer = state.openTroubleshootLink(.openAppSettings)
        case .openScannerSettings, .openNetworkSettings, .openImageCapture:
            // The computers' settings; never offered here.
            break
        }
    }

    private func added(_ deviceID: String) {
        showsAdd = false
        state.userSelectDevice(deviceID)
        source = deviceID
        reload()
    }

    private func closeAdd() {
        showsAdd = false
    }
}

/// One check: a compact row when it is fine, otherwise a card with its line, its buttons (Refresh is at
/// the bottom of the screen) and More help.
private struct TroubleshootCheckRow: View {
    let check: TroubleshootCheck
    let perform: (TroubleshootAction) -> Void

    var body: some View {
        if check.status == .ok {
            Label(check.title, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.primary)
                .accessibilityLabel(Text("\(Troubleshooter.statusLabel(check.status)): \(check.title)"))
                .accessibilityHint(Text(check.fullDetail))
                .accessibilityIdentifier("check.\(check.id)")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(check.title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(check.detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !buttons.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(buttons, id: \.self) { (action: TroubleshootAction) in
                            Button(Troubleshooter.label(action, platform: .ios)) {
                                perform(action)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if !check.more.isEmpty {
                    DisclosureGroup("More help") {
                        Text(check.more)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(Troubleshooter.statusLabel(check.status)): \(check.title)"))
            .accessibilityIdentifier("check.\(check.id)")
        }
    }

    /// The check's buttons, without Refresh (the screen's own button).
    private var buttons: [TroubleshootAction] {
        var list: [TroubleshootAction] = []
        for action in check.actions where action != .refresh {
            list.append(action)
        }
        return list
    }

    private var symbol: String {
        switch check.status {
        case .problem: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .tip: return "lightbulb"
        case .ok: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch check.status {
        case .problem: return Color.red
        case .warning: return Color.orange
        case .tip: return Color.accentColor
        case .ok: return Color.green
        }
    }
}
#endif
