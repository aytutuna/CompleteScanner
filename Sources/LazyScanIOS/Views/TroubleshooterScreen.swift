#if os(iOS)
import LazyScanKit
import SwiftUI

/// "Why isn't my scanner listed?" on the iPhone and iPad, with the shared texts (`Troubleshooter`): the
/// one-line headline, then a card for each problem and warning (title, its one line, its buttons, and
/// More help when there is more), a compact row for each check that is fine, and the tips. Refresh and
/// Copy diagnostics are at the bottom. It reads the app's state again every two seconds while shown, so
/// scanners and the search's state appear as they change. While the card explaining the Wi-Fi search is
/// unread the search is on hold, so the card comes first here too (`network`). A scanner added by address is
/// picked as in the picker (`ScannerPickerSheets`), once its sheet has closed, asking here first about a side
/// of an ID card held.
struct TroubleshooterScreen: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(IOSShell.scanModeKey) private var mode: IOSScanMode = .camera
    @AppStorage(IOSShell.scannerKey) private var scanner: String = ""
    /// The add-by-address sheet's model; nil where it is not offered.
    let makeAddModel: (() -> IOSAddScannerModel)?
    /// The network scanners, for the explanation card; nil where there are none (`-demoScanner`).
    var network: IOSNetworkScanners? = nil
    let onClose: () -> Void
    @State private var snapshot: DiscoverySnapshot = DiscoverySnapshot(platform: .ios)
    @State private var footer: String?
    @State private var showsAdd: Bool = false
    @State private var addedID: String?
    @State private var asksAboutCard: Bool = false

    /// The screen's title, as the Windows window's.
    static let title = "Why isn't my scanner listed?"

    var body: some View {
        let checks: [TroubleshootCheck] = Troubleshooter.diagnose(snapshot)
        NavigationStack {
            List {
                if let network {
                    ExplanationSection(network: network, onContinue: reload)
                }
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
            .sheet(isPresented: $showsAdd, onDismiss: addClosed) {
                if let makeAddModel {
                    AddScannerView(model: makeAddModel(), onAdded: added, onClose: closeAdd)
                        .environmentObject(state)
                }
            }
        }
        .modifier(IdCardDiscardQuestion(state: state, asked: $asksAboutCard))
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
        addedID = deviceID
        showsAdd = false
    }

    private func addClosed() {
        guard let id = addedID else { return }
        addedID = nil
        let appState: AppState = state
        state.leaveIdCard {
            scanner = id
            mode = .printer
            appState.userSelectDevice(id)
            reload()
        }
        if state.pendingIdCardLeave != nil {
            asksAboutCard = true
        }
    }

    private func closeAdd() {
        showsAdd = false
    }
}

/// The explanation card while it is unread; Continue starts the search, and the screen reads it again.
private struct ExplanationSection: View {
    @ObservedObject var network: IOSNetworkScanners
    let onContinue: () -> Void

    var body: some View {
        if network.needsExplanation {
            Section {
                ExplanationCard(onContinue: continueAfterExplanation)
            }
        }
    }

    private func continueAfterExplanation() {
        network.continueAfterExplanation()
        onContinue()
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
