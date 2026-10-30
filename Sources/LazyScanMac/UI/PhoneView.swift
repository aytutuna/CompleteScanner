#if os(macOS)
import AppKit
import LazyScanKit
import SwiftUI

/// "Send from your phone": whether this Mac receives from phones and on which networks (with "Allow
/// receiving on this network" for each), pairing a phone by QR code (asking the user to allow the
/// phone that presents it), the paired phones with Remove, the cloud folder phones put documents in
/// when they cannot reach this Mac (C2), the connection checks (`CompanionTroubleshooter`) and Reset
/// pairing. Shown as a sheet from the sidebar, like the troubleshooter; the pairing code stops working
/// when it closes. It changes no system setting. Twin of the Windows `PhoneWindow`.
struct PhoneView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var question = PhonePairingQuestion()
    /// The pairing code shown, with its picture; nil when none is.
    @State private var code: PairingUri?
    @State private var qr: CGImage?
    /// Why no code could be shown, or the phone just paired.
    @State private var pairNote: String?
    @State private var footerMessage: String?
    @State private var opening = false
    @State private var confirmReset = false

    var body: some View {
        let service = state.companionService
        let snapshot = service?.snapshot()
            ?? CompanionSnapshot(platform: .mac, listen: state.companionHostStatus.state == .elsewhere ? .elsewhere : .failed,
                                 listenError: state.companionHostError)
        let checks = CompanionTroubleshooter.diagnose(snapshot)
        let devices = service?.devices.devices ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send from your phone")
                    .font(.title2.weight(.semibold))
                Text(headline(snapshot))
                    .font(.headline)
                    .padding(.top, 4)
                Text("Documents scanned with Lazy Scan on a paired phone are added to the page queue here. "
                     + "Nothing goes through the internet: the phone and this Mac talk directly, encrypted, on networks you allow.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Networks")
                    if snapshot.networks.isEmpty {
                        Text("Not connected to a network.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.networks, id: \.network.id) { network in
                        networkCard(network, service: service)
                    }

                    sectionTitle("Pair a phone")
                    pairCard(service)

                    sectionTitle("Paired phones")
                    if devices.isEmpty {
                        Text("No phone is paired yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices, id: \.id) { device in
                        phoneRow(device, service: service)
                    }

                    sectionTitle("Cloud folder")
                    syncFolderCard(service)

                    sectionTitle("Connection checks")
                    Text(CompanionTroubleshooter.summary(checks))
                        .foregroundStyle(.secondary)
                    ForEach(checks, id: \.id) { check in
                        TroubleshootCheckCard(check: check) { action in perform(action) }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Reset pairing\u{2026}") {
                    confirmReset = true
                }
                .disabled(service == nil)
                .help("Unpair every phone and make a new security key for this Mac")
                if let footerMessage {
                    Text(footerMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(footerMessage)
                }
                Spacer()
                Button {
                    Task { await service?.refresh() }
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
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 720)
        .onChange(of: devices.map(\.id)) { before, after in
            // A phone that presented the code was allowed and is paired now.
            guard let added = after.first(where: { !before.contains($0) }),
                  let device = state.companionService?.devices.devices.first(where: { $0.id == added }) else { return }
            code = nil
            pairNote = "Paired with \(device.name). Documents sent from it are added to the queue."
        }
        .onAppear {
            state.ensureCompanionHost()
            let question = question
            state.confirmPhonePairing = { request in await question.ask(request) }
            Task { await state.companionService?.refresh() }
        }
        .onDisappear {
            question.settle(false)
            state.confirmPhonePairing = nil
            if let service = state.companionService, service.pairing != nil {
                Task { await service.closePairing() }
            }
        }
        .alert("Reset pairing?", isPresented: $confirmReset) {
            Button("Reset pairing", role: .destructive) {
                Task { await resetPairing() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every paired phone will be removed and this Mac gets a new security key. Phones then pair again with a new code.")
        }
    }

    private func headline(_ snapshot: CompanionSnapshot) -> String {
        guard state.companionService == nil else { return CompanionTroubleshooter.headline(snapshot) }
        if state.companionHostStatus.state == .elsewhere { return CompanionHostText.elsewhereMessage }
        return CompanionHostText.notStartedMessage(state.companionHostError ?? "unknown error")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Networks

    private func networkCard(_ network: CompanionNetworkState, service: CompanionService?) -> some View {
        let name = network.network.name.isEmpty ? "Unnamed network" : network.network.name
        let receiving = network.trust != .notTrusted
        return VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.headline)
            Text(network.network.id.isEmpty ? "Waiting for the network's details" : receiving ? "Receiving allowed" : "Not receiving")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Allow receiving on this network", isOn: Binding(
                get: { receiving },
                set: { allowed in Task { await setAllowed(network.network, allowed, service: service) } }))
                .toggleStyle(.switch)
                .disabled(service == nil || network.network.id.isEmpty)
                .help("For a network you trust, such as your home Wi-Fi. Only phones you paired can send.")
                .accessibilityLabel("Allow receiving on \(name)")
                .padding(.top, 4)
            if receiving {
                Text("macOS may ask once whether Lazy Scan may find devices on local networks. Choose Allow, so phones can find this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneCard()
        .accessibilityElement(children: .contain)
    }

    private func setAllowed(_ network: CompanionNetwork, _ allowed: Bool, service: CompanionService?) async {
        guard let service else { return }
        if !(await service.setNetworkApproved(network, allowed)) {
            footerMessage = "The setting could not be saved."
        }
    }

    // MARK: - Pairing

    /// The code stays up while its question waits: the session is used by then, but not settled.
    private func codeShown(_ service: CompanionService?) -> Bool {
        code != nil && (service?.pairing != nil || question.phoneName != nil)
    }

    private func pairCard(_ service: CompanionService?) -> some View {
        let shown = codeShown(service)
        let title: String = shown ? "Show a new code" : "Pair a phone"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Open Lazy Scan on your phone, go to Settings \u{203A} My computer, and scan the code shown here. "
                 + "The code works once, for 5 minutes.")
                .fixedSize(horizontal: false, vertical: true)
            Button(title) {
                Task { await pair() }
            }
            .disabled(service == nil || opening)
            if shown, let code {
                codeDetails(code, service: service)
            }
            if let name = question.phoneName {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow \u{201C}\(name)\u{201D} to send documents to this Mac?")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Allow") { question.settle(true) }
                        Button("Don't allow") { question.settle(false) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            if !shown, let pairNote {
                Text(pairNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneCard()
    }

    private func codeDetails(_ code: PairingUri, service: CompanionService?) -> some View {
        let pairingText = (try? code.format()) ?? ""
        return HStack(alignment: .top, spacing: 16) {
            if let qr {
                Image(qr, scale: 1, label: Text("Pairing code to scan with your phone"))
                    .interpolation(.none)
                    .background(Color.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(expiry(at: context.date, service: service))
                        .font(.headline)
                }
                Text("Cannot scan the code? Get this pairing text onto the phone (a message to yourself, say) and paste it "
                     + "under Settings \u{203A} My computer \u{203A} Enter pairing text, then compare the check code.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing text").foregroundStyle(.secondary)
                    Text(pairingText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy") {
                        copyPairingText(pairingText)
                    }
                    .accessibilityLabel("Copy the pairing text")
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Check code").foregroundStyle(.secondary)
                        Text(code.fingerprintBytes.map { SpkiFingerprint.formatCheckCode(SpkiFingerprint.checkCode($0)) } ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Button("Stop pairing") {
                    Task { await stopPairing() }
                }
                .padding(.top, 4)
            }
        }
    }

    private func expiry(at now: Date, service: CompanionService?) -> String {
        if let session = service?.pairing {
            let left = Int(session.remaining(at: now).rounded(.up))
            return "Scan this code with your phone. It works for \(left / 60):\(String(format: "%02d", left % 60)) more."
        }
        return question.phoneName != nil ? "A phone scanned this code. Allow it below, or not." : ""
    }

    /// Shows a new pairing code, or says why none can be shown.
    private func pair() async {
        guard let service = state.ensureCompanionHost() else { return }
        footerMessage = nil
        opening = true
        let opened = await service.openPairing()
        opening = false
        code = opened
        if let opened, let text = try? opened.format() {
            qr = PhoneView.qrImage(text)
            pairNote = nil
        } else {
            code = nil
            qr = nil
            pairNote = PhoneView.whyNoCode(service.status)
        }
    }

    private func stopPairing() async {
        question.settle(false)
        await state.companionService?.closePairing()
        code = nil
    }

    private func copyPairingText(_ text: String) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        footerMessage = pasteboard.setString(text, forType: .string) ? "Copied to the clipboard." : "Copy did not work."
    }

    static func whyNoCode(_ status: CompanionHostStatus) -> String {
        switch status.state {
        case .offline:
            return "Connect this Mac to a network first, then choose Pair a phone again."
        case .noTrustedNetwork:
            return "This Mac does not receive on the network it is on. Turn on Allow receiving on this network above, "
                + "then choose Pair a phone again."
        case .failed:
            return status.error ?? "Receiving from phones could not start."
        default:
            return "No pairing code could be made."
        }
    }

    /// The QR code with a quiet zone of four modules, black on white, at whole pixels per module, so it
    /// stays sharp when drawn without interpolation.
    static func qrImage(_ text: String) -> CGImage? {
        guard let modules = CoreImageQrEncoder().encode(text) else { return nil }
        let quiet = 4
        let span = modules.size + 2 * quiet
        let scale = max(3, 232 / span)
        let side = span * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<modules.size {
            for x in 0..<modules.size where modules[x, y] {
                for dy in 0..<scale {
                    let row = ((y + quiet) * scale + dy) * side + (x + quiet) * scale
                    for dx in 0..<scale {
                        pixels[row + dx] = 0
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Paired phones

    private func phoneRow(_ device: PairedDevice, service: CompanionService?) -> some View {
        let name = device.name.isEmpty ? "Phone" : device.name
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(PhoneView.caption(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service?.devices.hasSyncKey(device.id) == false {
                    Text("Pair again to use the cloud folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Remove") {
                Task { await remove(device.id, service: service) }
            }
            .help("This phone can no longer send documents here, until it is paired again")
            .accessibilityLabel("Remove \(name)")
        }
        .phoneCard()
        .accessibilityElement(children: .contain)
    }

    private func remove(_ id: String, service: CompanionService?) async {
        guard let service else { return }
        await service.removeDevice(id)
        footerMessage = "Removed. That phone can no longer send documents here."
    }

    /// "Paired 20/10/2026 · last seen today at 14:05".
    static func caption(_ device: PairedDevice) -> String {
        var parts: [String] = []
        if let paired = device.paired {
            parts.append("Paired \(paired.formatted(date: .numeric, time: .omitted))")
        }
        if let seen = device.lastSeen {
            parts.append(Calendar.current.isDateInToday(seen)
                ? "last seen today at \(seen.formatted(date: .omitted, time: .shortened))"
                : "last seen \(seen.formatted(date: .numeric, time: .omitted))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Cloud folder

    private func syncFolderCard(_ service: CompanionService?) -> some View {
        let folder = service?.syncFolder
        let problem = service == nil ? nil : state.syncFolderProblem
        return VStack(alignment: .leading, spacing: 8) {
            Text("A folder synced by iCloud Drive or OneDrive. The phone puts documents here when it cannot reach this Mac; "
                 + "they are encrypted with a key only this Mac and the phone know.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(folder?.path ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder?.path ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose\u{2026}") {
                    chooseSyncFolder(folder)
                }
                .disabled(service == nil)
                .help("Choose the cloud folder")
                Button("Clear") {
                    setSyncFolder(nil)
                }
                .disabled(folder == nil)
                .help("Stop watching the cloud folder")
            }
            Text(PhoneView.syncFolderStatus(folder, running: service != nil))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneCard()
        .accessibilityElement(children: .contain)
    }

    static func syncFolderStatus(_ folder: URL?, running: Bool) -> String {
        guard running else { return "Not watching." }
        guard let folder else { return "Not watching: no folder chosen." }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return "Waiting for \(folder.path): the folder is not there now."
        }
        return "Watching \(folder.path)."
    }

    /// Starts in the folder chosen now, or else in iCloud Drive when it is set up on this Mac.
    private func chooseSyncFolder(_ current: URL?) {
        let panel = NSOpenPanel()
        panel.title = "Choose the cloud folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if let current, FileManager.default.fileExists(atPath: current.path) {
            panel.directoryURL = current
        } else if FileManager.default.fileExists(atPath: iCloud.path) {
            panel.directoryURL = iCloud
        }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSyncFolder(url)
    }

    private func setSyncFolder(_ folder: URL?) {
        if !state.setPhoneSyncFolder(folder) {
            footerMessage = "The setting could not be saved."
        }
    }

    // MARK: - Reset and checks

    private func resetPairing() async {
        guard let service = state.companionService else { return }
        question.settle(false)
        do {
            try await service.resetPairing()
            code = nil
            pairNote = nil
            footerMessage = "Pairing was reset."
        } catch {
            let reason = (error as? SelfSignedCertificateError)?.message ?? error.localizedDescription
            footerMessage = "Pairing could not be reset: \(reason)"
        }
    }

    private func perform(_ action: TroubleshootAction) {
        switch action {
        case .refresh:
            Task { await state.companionService?.refresh() }
        case .openNetworkSettings:
            footerMessage = state.openTroubleshootLink(action)
        default:
            break
        }
    }
}

/// The question the Phone window asks when a phone presents the pairing code (`AppState.confirmPhonePairing`):
/// answered with Allow or Don't allow, and declined when it is cancelled (no answer within two
/// minutes, or the phone went away), when another phone asks, or when the window closes.
@MainActor
final class PhonePairingQuestion: ObservableObject {
    /// The name of the phone asking; nil when nothing is asked.
    @Published private(set) var phoneName: String?
    private var answer: CheckedContinuation<Bool, Never>?
    private var asked = 0

    func ask(_ request: PairRequest) async -> Bool {
        settle(false)
        asked += 1
        let number = asked
        phoneName = request.phoneName
        if !NSApp.isActive { _ = NSApp.requestUserAttention(.informationalRequest) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                answer = continuation
            }
        } onCancel: {
            Task { @MainActor in
                if self.asked == number { self.settle(false) }
            }
        }
    }

    /// Answers the question asked now, if any.
    func settle(_ allow: Bool) {
        let waiting = answer
        answer = nil
        phoneName = nil
        waiting?.resume(returning: allow)
    }
}

private extension View {
    /// The card the Phone window shows each network, phone and the pairing in.
    func phoneCard() -> some View {
        padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
            }
    }
}
#endif
