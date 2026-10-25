#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The scanners to pick from as a list of their own (the column beside a wide scan screen), with the
/// sheets its buttons open: Add by address and the troubleshooter.
struct ScannerPickerList: View {
    let picker: IOSScannerPickerModel
    @State private var showsAdd: Bool = false
    @State private var showsTroubleshooter: Bool = false

    var body: some View {
        List {
            ScannerPickerSections(picker: picker, onAdd: openAdd, onTroubleshoot: openTroubleshooter)
        }
        .listStyle(.insetGrouped)
        .modifier(ScannerPickerSheets(picker: picker, showsAdd: $showsAdd, showsTroubleshooter: $showsTroubleshooter))
    }

    private func openAdd() {
        showsAdd = true
    }

    private func openTroubleshooter() {
        showsTroubleshooter = true
    }
}

/// Add by address and the troubleshooter, as sheets of the list (or the sidebar) the picker's sections are
/// in. A scanner added is selected and becomes the source.
struct ScannerPickerSheets: ViewModifier {
    @EnvironmentObject private var state: AppState
    @AppStorage(IOSShell.scanSourceKey) private var source: String = ""
    let picker: IOSScannerPickerModel
    @Binding var showsAdd: Bool
    @Binding var showsTroubleshooter: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsAdd) {
                AddScannerView(model: picker.makeAddModel(), onAdded: added, onClose: closeAdd)
                    .environmentObject(state)
            }
            .sheet(isPresented: $showsTroubleshooter) {
                TroubleshooterScreen(makeAddModel: makeAddModel, onClose: closeTroubleshooter)
                    .environmentObject(state)
            }
    }

    private func makeAddModel() -> IOSAddScannerModel {
        picker.makeAddModel()
    }

    private func added(_ deviceID: String) {
        showsAdd = false
        state.userSelectDevice(deviceID)
        source = deviceID
    }

    private func closeAdd() {
        showsAdd = false
    }

    private func closeTroubleshooter() {
        showsTroubleshooter = false
    }
}

/// Where the pages come from, as sections of a list (the scan screen's Scanner options on iPhone, a part of
/// the sidebar on iPad): Camera, then one row per scanner with how it is reached, the one that is the
/// source checked (`IOSShell.sourceScanner`); "Looking for scanners…" while the search has just started,
/// else "No scanner found" with Troubleshoot; the explanation card before the first search, the line about
/// Local Network access being off, and the buttons to add a scanner by address and open the troubleshooter.
/// Picking a scanner selects it and makes it the source; Camera leaves the scanner selected. The rows follow
/// the app's state, and the network scanners' when there are any.
struct ScannerPickerSections: View {
    let picker: IOSScannerPickerModel
    let onAdd: () -> Void
    let onTroubleshoot: () -> Void
    /// The rows' section header (the sidebar's "Scanners"); none in the options, whose title says it.
    var header: String?

    var body: some View {
        if let network = picker.network {
            NetworkObserving(network: network) {
                ScannerPickerContent(picker: picker, onAdd: onAdd, onTroubleshoot: onTroubleshoot, header: header)
            }
        } else {
            ScannerPickerContent(picker: picker, onAdd: onAdd, onTroubleshoot: onTroubleshoot, header: header)
        }
    }
}

/// The picker's sections themselves.
private struct ScannerPickerContent: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(IOSShell.scanSourceKey) private var source: String = ""
    let picker: IOSScannerPickerModel
    let onAdd: () -> Void
    let onTroubleshoot: () -> Void
    let header: String?

    var body: some View {
        let picked: String? = IOSShell.sourceScanner(source, selected: state.selectedDeviceID, devices: state.devices)?.id
        Section {
            CameraSourceRow(checked: picked == nil, enabled: !state.isBusy, onPick: pickCamera)
            ForEach(picker.rows) { (row: IOSScannerRow) in
                ScannerRowView(row: row, checked: row.id == picked, enabled: !state.isBusy, onPick: { pick(row) },
                               onRemove: { picker.removeAddresses(row) })
            }
            if picker.showsSearching {
                HStack(spacing: 8) {
                    ProgressView()
                        .accessibilityHidden(true)
                    Text(IOSNetworkText.searching)
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("scanners.searching")
            }
            if picker.showsEmpty && !picker.showsExplanation {
                HStack(spacing: 8) {
                    Text(IOSNetworkText.noScanner)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("scanners.empty")
                    Spacer(minLength: 0)
                    Button(IOSNetworkText.troubleshoot) {
                        onTroubleshoot()
                    }
                    .accessibilityIdentifier("scanners.troubleshoot")
                }
            }
        } header: {
            if let header {
                Text(header)
            }
        }
        if picker.showsExplanation {
            Section {
                ExplanationCard(onContinue: continueAfterExplanation)
            }
        }
        if picker.showsDenied {
            Section {
                DeniedRow(onSettings: openSettings)
            }
        }
        if !picker.showsExplanation {
            Section {
                if picker.offersAddByAddress {
                    Button {
                        onAdd()
                    } label: {
                        Label(IOSNetworkText.addButton, systemImage: "plus")
                    }
                    .accessibilityIdentifier("scanner.add")
                }
                if !picker.showsEmpty {
                    Button {
                        onTroubleshoot()
                    } label: {
                        Label(IOSNetworkText.troubleshoot, systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("scanners.troubleshoot.link")
                }
            }
        }
    }

    private func continueAfterExplanation() {
        picker.continueAfterExplanation()
    }

    private func pick(_ row: IOSScannerRow) {
        guard !state.isBusy else { return }
        picker.select(row)
        source = row.id
    }

    private func pickCamera() {
        guard !state.isBusy else { return }
        source = ""
    }

    private func openSettings() {
        if let problem = picker.openSettings() {
            state.errorMessage = problem
        }
    }
}

/// Redraws its content whenever the network scanners change (the explanation read, the search's state).
struct NetworkObserving<Content: View>: View {
    @ObservedObject var network: IOSNetworkScanners
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

/// Our own camera as the source, above the scanners, with a check mark when it is the source.
private struct CameraSourceRow: View {
    let checked: Bool
    let enabled: Bool
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(systemName: "camera")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IOSImportText.cameraLabel)
                        .foregroundStyle(Color.primary)
                    Text("Takes the pages as photos")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                if checked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier("source.camera")
    }
}

/// One scanner: its name, how it is reached (and "Not encrypted" when so), a check mark when it is the
/// source, and Remove address for one reached through an address added by hand.
private struct ScannerRowView: View {
    let row: IOSScannerRow
    let checked: Bool
    let enabled: Bool
    let onPick: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(row.note == nil ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 0)
                if checked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier("scanner.row.\(row.id)")
        .contextMenu {
            if row.canRemoveAddress {
                Button(role: .destructive, action: onRemove) {
                    Label(IOSNetworkText.removeAddress, systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if row.canRemoveAddress {
                Button(role: .destructive, action: onRemove) {
                    Label(IOSNetworkText.removeAddress, systemImage: "trash")
                }
            }
        }
    }
}

/// Before the first search: why the system is about to ask about the local network.
private struct ExplanationCard: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "wifi")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(IOSNetworkText.explanationTitle)
                .font(.headline)
            Text(IOSNetworkText.explanationLine)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onContinue) {
                Text(IOSNetworkText.explanationButton)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("localNetwork.continue")
        }
        .padding(.vertical, 6)
    }
}

/// Local Network access is off: the one-line reason and the way to Settings.
private struct DeniedRow: View {
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            Text(IOSNetworkText.deniedLine)
                .font(.subheadline)
                .accessibilityIdentifier("localNetwork.denied")
            Spacer(minLength: 0)
            Button(IOSNetworkText.settingsButton, action: onSettings)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("localNetwork.settings")
        }
    }
}

/// "Add a network scanner": the address field, Add, and what the check found.
struct AddScannerView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model: IOSAddScannerModel
    let onAdded: (String) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var showsHelp: Bool = false

    init(model: IOSAddScannerModel, onAdded: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onAdded = onAdded
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(IOSNetworkText.addPlaceholder, text: $model.text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.go)
                        .focused($focused)
                        .disabled(model.isChecking)
                        .onSubmit(add)
                        .accessibilityLabel(Text("Address"))
                        .accessibilityIdentifier("address.field")
                } header: {
                    HStack(spacing: 6) {
                        Text(IOSNetworkText.addLine)
                        Button {
                            showsHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel(Text("About the address"))
                        .accessibilityIdentifier("address.help")
                    }
                    .textCase(nil)
                } footer: {
                    messageView
                }
                if model.accessDenied {
                    Section {
                        Button(IOSNetworkText.settingsButton) {
                            if let problem = state.openTroubleshootLink(.openAppSettings) {
                                state.errorMessage = problem
                            }
                        }
                        .accessibilityIdentifier("address.settings")
                    }
                }
            }
            .navigationTitle(IOSNetworkText.addTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        onClose()
                    }
                    .accessibilityIdentifier("address.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSNetworkText.add, action: add)
                        .disabled(model.isChecking)
                        .accessibilityIdentifier("address.add")
                }
            }
            .onAppear {
                focused = true
            }
            .onDisappear {
                model.cancel()
            }
            .onChange(of: model.text) { (_: String, _: String) in
                model.textChanged()
            }
            .alert(IOSNetworkText.addTitle, isPresented: $showsHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(IOSNetworkText.addHelp)
            }
            .sheet(isPresented: certificateShown) {
                if let certificate = model.certificateQuestion {
                    CertificateChangedView(certificate: certificate, onAnswer: answerCertificate)
                }
            }
        }
    }

    @ViewBuilder
    private var messageView: some View {
        if model.isChecking {
            HStack(spacing: 8) {
                ProgressView()
                Text(model.message ?? "")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("address.progress")
        } else if let message = model.message {
            Text(message)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("address.message")
        }
    }

    private var certificateShown: Binding<Bool> {
        let adding: IOSAddScannerModel = model
        return Binding<Bool>(
            get: { adding.certificateQuestion != nil },
            set: { (shown: Bool) in
                if !shown {
                    adding.answerCertificate(false)
                }
            })
    }

    private func answerCertificate(_ trust: Bool) {
        model.answerCertificate(trust)
    }

    private func add() {
        let done: (String) -> Void = onAdded
        let adding: IOSAddScannerModel = model
        model.start { (added: Bool) in
            if added, let deviceID = adding.addedDeviceID {
                done(deviceID)
            }
        }
    }
}

/// A scanner's certificate changed since it was trusted: the scanner, both fingerprints, Cancel first and
/// "Trust the new certificate" as the destructive choice.
struct CertificateChangedView: View {
    let certificate: EsclCertificateError
    let onAnswer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(certificate.deviceName)
                        .font(.headline)
                    Text(IOSNetworkText.certificateLine)
                        .fixedSize(horizontal: false, vertical: true)
                    if let previous = certificate.previous {
                        Text(IOSNetworkText.trustedBefore)
                            .font(.subheadline.weight(.semibold))
                        Text(EsclCertificates.format(previous.fingerprint, bytesPerLine: 8))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(IOSNetworkText.newFingerprint)
                        .font(.subheadline.weight(.semibold))
                    Text(EsclCertificates.format(certificate.fingerprint, bytesPerLine: 8))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button(role: .destructive) {
                        onAnswer(true)
                    } label: {
                        Text(IOSNetworkText.trustNew)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("certificate.trust")
                }
                .padding(20)
            }
            .navigationTitle(IOSNetworkText.certificateTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onAnswer(false)
                    }
                    .accessibilityIdentifier("certificate.cancel")
                }
            }
        }
    }
}
#endif
