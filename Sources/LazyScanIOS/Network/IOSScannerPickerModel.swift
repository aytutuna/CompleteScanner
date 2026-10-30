#if os(iOS)
import LazyScanKit
import Foundation

/// A row of the scanner picker: the scanner's name, how it is reached (as Windows labels connections,
/// `DeviceMerge.connectionLabel`: "Network (eSCL)", "Demo"), "Not encrypted" for a network scanner reached
/// over plain HTTP after HTTPS could not be used, and the addresses added by hand that reach it.
public struct IOSScannerRow: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let connection: String
    public let note: String?
    public let isSelected: Bool
    public let isDemo: Bool
    /// Addresses added by hand that reach this scanner; the row's menu removes them.
    public let addedAddresses: [ScannerAddress]

    public init(id: String, name: String, connection: String, note: String?, isSelected: Bool, isDemo: Bool,
                addedAddresses: [ScannerAddress]) {
        self.id = id
        self.name = name
        self.connection = connection
        self.note = note
        self.isSelected = isSelected
        self.isDemo = isDemo
        self.addedAddresses = addedAddresses
    }

    /// The row's menu offers Remove address.
    public var canRemoveAddress: Bool {
        !addedAddresses.isEmpty
    }

    /// The row's one line under the name: the connection, and the note when there is one.
    public var detail: String {
        guard let note else { return connection }
        return connection + " \u{00B7} " + note
    }

    /// The SF Symbol of the row.
    public var symbol: String {
        isDemo ? "sparkles.rectangle.stack" : "scanner"
    }
}

/// The scanner picker (a sheet on iPhone, the sidebar on iPad): the scanners listed, the explanation card
/// before the first search, the line about Local Network access being off, the empty state with the
/// troubleshooter, and adding a scanner by address. A value over the app's state and its network
/// scanners (nil under `-demoScanner`, where only the demo scanner is offered and nothing is searched).
@MainActor
public final class IOSScannerPickerModel {
    public let state: AppState
    public let network: IOSNetworkScanners?

    public init(state: AppState, network: IOSNetworkScanners?) {
        self.state = state
        self.network = network
    }

    /// The scanners listed, one row each, in the app's order.
    public var rows: [IOSScannerRow] {
        IOSScannerPickerModel.rows(devices: state.devices, selected: state.selectedDeviceID, backend: network?.backend)
    }

    /// The rows for `devices`, the one `selected` marked.
    public static func rows(devices: [ScannerInfo], selected: String?, backend: EsclScannerBackend?) -> [IOSScannerRow] {
        var rows: [IOSScannerRow] = []
        for device in devices {
            var note: String?
            var added: [ScannerAddress] = []
            if let backend, device.backend == "escl" {
                if backend.isNotEncrypted(device.id) {
                    note = EsclScannerBackend.notEncryptedLabel
                }
                added = backend.manualAddresses(device.id)
            }
            rows.append(IOSScannerRow(id: device.id, name: device.name, connection: DeviceMerge.connectionLabel(device),
                                      note: note, isSelected: device.id == selected, isDemo: device.isDemo,
                                      addedAddresses: added))
        }
        return rows
    }

    /// The explanation card is shown instead of searching (the first time).
    public var showsExplanation: Bool {
        network?.needsExplanation ?? false
    }

    /// Local Network access is off: the one-line reason with the Settings button.
    public var showsDenied: Bool {
        guard let network else { return false }
        return !network.needsExplanation && network.accessDenied
    }

    /// No scanner other than the demo scanner is listed yet while the search has just started or resolves
    /// what it found: "Looking for scanners…" instead of the empty state.
    public var showsSearching: Bool {
        guard let network, !network.needsExplanation, !network.accessDenied else { return false }
        return !state.hasRealDevices && network.backend.isSearching
    }

    /// No scanner other than the demo scanner is listed, and the search is not still looking:
    /// "No scanner found" with Troubleshoot.
    public var showsEmpty: Bool {
        !state.hasRealDevices && !showsSearching
    }

    /// Adding by address is offered once the card is read (it reaches the local network too). Under
    /// `-demoScanner` it is offered, and says that network scanners are off there.
    public var offersAddByAddress: Bool {
        !showsExplanation
    }

    public func select(_ row: IOSScannerRow) {
        guard !state.isBusy else { return }
        state.userSelectDevice(row.id)
    }

    /// Removes every address added by hand that reaches the row's scanner.
    public func removeAddresses(_ row: IOSScannerRow) {
        guard let backend = network?.backend else { return }
        for address in row.addedAddresses {
            backend.removeAddress(address)
        }
    }

    public func continueAfterExplanation() {
        network?.continueAfterExplanation()
    }

    /// Opens the app's page in Settings; returns why it did not (nil when it did).
    @discardableResult
    public func openSettings() -> String? {
        state.openTroubleshootLink(.openAppSettings)
    }

    /// The model of the add-by-address sheet.
    public func makeAddModel() -> IOSAddScannerModel {
        let scanners: IOSNetworkScanners? = network
        return IOSAddScannerModel(checker: network?.backend, localNetwork: network == nil ? nil : IOSLocalNetworkProbe(),
                                  onDenied: { () -> Void in
                                      scanners?.reportDenied()
                                  })
    }
}

/// What adding a scanner by address needs of the network connection (`EsclScannerBackend`; tests pass a stand-in).
@MainActor
public protocol IOSAddressChecking: AnyObject {
    func checkAddress(_ address: ScannerAddress, firstUse: String?) async throws -> EsclAddressCheck
    func addAddress(_ address: ScannerAddress, capabilities: EsclCapabilities) -> String
    func trustCertificate(_ certificate: EsclCertificateError, deviceUuid: String?, name: String)
}

extension EsclScannerBackend: IOSAddressChecking {}

/// "Add a network scanner": the address typed is read with the Windows rules and messages
/// (`ScannerAddress.tryParse`), then checked (a scanner must answer there) and added to escl-hosts.json. A
/// certificate seen for the first time is trusted without asking (trust on first use, as when the app finds
/// a scanner); one that changed since it was trusted is asked about (`certificateQuestion`). When nothing
/// answers, a refused Local Network access is told apart (`accessDenied`, with the Settings button).
@MainActor
public final class IOSAddScannerModel: ObservableObject {
    /// The address as typed.
    @Published public var text: String = ""
    /// What the sheet says under the field: progress while checking, else why the address was not added.
    @Published public private(set) var message: String?
    @Published public private(set) var isChecking: Bool = false
    /// Nothing answered because Local Network access is off.
    @Published public private(set) var accessDenied: Bool = false
    /// A changed certificate waiting for the user's answer.
    @Published public private(set) var certificateQuestion: EsclCertificateError?
    /// The added scanner's device ID; nil until one was added.
    public private(set) var addedDeviceID: String?

    private let checker: (any IOSAddressChecking)?
    private let localNetwork: (any IOSLocalNetworkChecking)?
    private let onDenied: (@MainActor () -> Void)?
    private var answer: CheckedContinuation<Bool, Never>?
    private var check: Task<Bool, Never>?

    /// - Parameters:
    ///   - checker: the network connection; nil where network scanners are off (`-demoScanner`).
    ///   - localNetwork: tells a refused Local Network access apart when nothing answers.
    ///   - onDenied: runs when it was refused.
    public init(checker: (any IOSAddressChecking)?, localNetwork: (any IOSLocalNetworkChecking)?,
                onDenied: (@MainActor () -> Void)? = nil) {
        self.checker = checker
        self.localNetwork = localNetwork
        self.onDenied = onDenied
    }

    /// Checks and adds in the background (the Add button); `done` runs with true once added.
    public func start(_ done: @escaping @MainActor (Bool) -> Void) {
        guard check == nil else { return }
        check = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let added: Bool = await self.add()
            self.check = nil
            done(added)
            return added
        }
    }

    /// The sheet closed: a check under way is abandoned and nothing is added or trusted after it.
    public func cancel() {
        check?.cancel()
        check = nil
        answerCertificate(false)
    }

    /// The text changed: a message about the previous text no longer applies.
    public func textChanged() {
        if !isChecking {
            message = nil
            accessDenied = false
        }
    }

    /// Reads, checks and adds the typed address; true once it was added.
    public func add() async -> Bool {
        guard !isChecking else { return false }
        var problem: String = ""
        guard let address = ScannerAddress.tryParse(text, error: &problem) else {
            message = problem
            return false
        }
        guard let checker else {
            message = IOSNetworkText.networkOff
            return false
        }
        isChecking = true
        accessDenied = false
        message = IOSNetworkText.connecting(address)
        let added: Bool = await checkAndAdd(address, checker: checker)
        isChecking = false
        return added
    }

    private func checkAndAdd(_ address: ScannerAddress, checker: any IOSAddressChecking) async -> Bool {
        do {
            var result: EsclAddressCheck = try await checker.checkAddress(address, firstUse: nil)
            if Task.isCancelled {
                return false
            }
            // A certificate seen for the first time is trusted once the UUID the scanner reports shows it
            // is not a changed certificate of a scanner trusted before.
            if let certificate = result.certificate, certificate.canTrust, certificate.verdict == .unknown {
                result = try await checker.checkAddress(address, firstUse: certificate.fingerprint)
                if Task.isCancelled {
                    return false
                }
            }
            // A changed certificate is the user's call, as when they pick the scanner.
            if let certificate = result.certificate, certificate.canTrust, certificate.verdict == .changed {
                let trusted: Bool = await ask(certificate)
                if Task.isCancelled {
                    return false
                }
                guard trusted else {
                    message = IOSNetworkText.notTrusted
                    return false
                }
                checker.trustCertificate(certificate, deviceUuid: nil, name: certificate.deviceName)
                result = try await checker.checkAddress(address, firstUse: nil)
                if Task.isCancelled {
                    return false
                }
            }
            if let capabilities = result.capabilities {
                addedDeviceID = checker.addAddress(address, capabilities: capabilities)
                message = nil
                return true
            }
            if result.noAnswer, let probe = localNetwork {
                let denied: Bool = await probe.isDenied(host: address.host, port: address.port)
                if denied {
                    accessDenied = true
                    message = IOSNetworkText.deniedLine
                    onDenied?()
                    return false
                }
            }
            message = result.certificate?.message ?? result.error ?? "No scanner answered at \(address)."
            return false
        } catch {
            // Cancelled: the sheet is gone.
            message = nil
            return false
        }
    }

    private func ask(_ certificate: EsclCertificateError) async -> Bool {
        certificateQuestion = certificate
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            answer = continuation
        }
    }

    /// The user's answer about `certificateQuestion`: true trusts the new certificate.
    public func answerCertificate(_ trust: Bool) {
        certificateQuestion = nil
        guard let open = answer else { return }
        answer = nil
        open.resume(returning: trust)
    }
}
#endif
