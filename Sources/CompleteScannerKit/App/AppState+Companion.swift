import Foundation

// The phone's side of C1 (I20): pairing with a desktop from its code, checking the link, sending the
// queue as a `.csdoc` and taking what the desktop holds for the phone. The desktop is the server
// (windows/CompleteScanner.Core/Companion); this is the client, through `CompanionClient`.

/// The companion's texts on the phone.
public enum CompanionText {
    public static let clientIsolationReason = "This network keeps devices apart (client isolation). Use another Wi-Fi."
    public static let notPairedMessage =
        "Pair this phone with a computer first: choose Pair a phone in CompleteScanner on the computer and scan its code."
    public static let outboxFullMessage =
        "\(PhoneOutbox.maxItems) documents are waiting to be sent already. Send them, or remove some first."
    public static let unreachableMessage = "The computer cannot be reached."
    public static let wrongCertificateMessage =
        "The computer that answered is not the one this phone was paired with. If pairing was reset there, pair again."
    public static let badResponseMessage = "The computer's answer could not be read."
    public static let notSavedMessage = "The pairing could not be saved on this phone. Try again."

    /// "Office PC is not on this network."
    public static func notOnNetworkReason(_ desktopName: String) -> String {
        "\(desktopName) is not on this network."
    }

    /// "Office PC cannot be reached on this network."
    public static func cannotReachMessage(_ desktopName: String) -> String {
        "\(desktopName) cannot be reached on this network."
    }

    /// "Paired with Office PC."
    public static func pairedMessage(_ desktopName: String) -> String {
        "Paired with \(desktopName)."
    }

    /// "This phone is no longer paired with Office PC."
    public static func unpairedMessage(_ desktopName: String) -> String {
        "This phone is no longer paired with \(desktopName)."
    }

    /// "Sent 3 pages to Office PC."
    public static func sentMessage(_ pageCount: Int, desktopName: String) -> String {
        "Sent \(pageCount == 1 ? "1 page" : "\(pageCount) pages") to \(desktopName)."
    }

    /// "Scan 12.csdoc was not sent: This document is too large to send in one piece."
    public static func notSentMessage(_ fileName: String, reason: String) -> String {
        "\(fileName) was not sent: \(reason)"
    }

    /// "Received Invoice.pdf from Office PC."
    public static func receivedMessage(_ fileName: String, desktopName: String) -> String {
        "Received \(fileName) from \(desktopName)."
    }

    /// "The computer refused the request (HTTP 501)."
    public static func refusedMessage(_ status: Int) -> String {
        "The computer refused the request (HTTP \(status))."
    }
}

/// Where the link to the paired desktop stands.
public enum CompanionStatus: Equatable, Sendable {
    case notPaired
    /// A check or a pairing is under way, or the paired desktop has not been checked yet.
    case checking
    /// The desktop answered: its name and the pages in its queue.
    case reachable(desktopName: String, queuedPages: Int)
    /// The desktop did not answer, or refused: why, as a sentence.
    case unreachable(reason: String)
    /// The desktop named no longer knows this phone (it was removed there): pair again.
    case unpaired(byDesktop: String)
}

extension AppState {
    /// Keeps the companion's files in `folder` (companion-desktop.json, the "Outbox" and "Inbox"
    /// folders; the iPhone's network folder, out of backups) and the device secret in `secrets` (the
    /// Keychain), and loads the paired desktop, `.checking` until `checkDesktop` runs; a package received
    /// before and not yet taken or dismissed is offered again. Set by the shell; without it the phone
    /// cannot pair.
    public func setUpCompanion(in folder: URL, secrets: any CompanionSecretStore) {
        stopPulling()
        let store = PairedDesktopStore(directory: folder, secrets: secrets)
        let outbox = PhoneOutbox(directory: folder.appendingPathComponent("Outbox", isDirectory: true))
        companionStore = store
        companionOutbox = outbox
        companionInbox = folder.appendingPathComponent("Inbox", isDirectory: true)
        companionClient = nil
        companionOutboxCount = outbox.count
        companionDesktop = store.load()
        if let desktop = companionDesktop {
            companionStatus = store.secret(for: desktop) == nil ? .unpaired(byDesktop: desktop.name) : .checking
        } else {
            companionStatus = .notPaired
        }
        Task { [weak self] in
            await self?.offerReceivedPackage()
        }
    }

    /// Pairs with the desktop whose code is `uri` (scanned, or its text pasted), as `phoneName`. The
    /// desktop asks its user first, so this can take two minutes. The certificate that answers must be
    /// the one the code names. On success the desktop and its secret are kept, replacing a desktop
    /// paired before; a refusal is said in `errorMessage` with the desktop's own message, and the
    /// pairing kept before stays.
    public func pairDesktop(uri: String, phoneName: String) async {
        guard let store = companionStore else { return }
        let code: PairingUri
        do {
            code = try PairingUri.parse(uri)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var phoneId = companionDesktop?.phoneId ?? ""
        if !CompanionProtocol.isValidId(phoneId) { phoneId = PairedDesktop.makePhoneId() }
        var desktop = PairedDesktop(id: code.desktopId, name: code.name, fingerprint: code.fingerprint,
                                    addresses: code.addresses, port: code.port, phoneId: phoneId)
        guard !desktop.addresses.isEmpty else {
            errorMessage = CompanionText.notOnNetworkReason(code.name)
            return
        }
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let before = companionStatus
        companionStatus = .checking
        let client = CompanionClient(desktop: desktop, secret: nil, protocolClasses: companionProtocolClasses)
        do {
            let response = try await client.pair(token: code.token, phoneId: phoneId, phoneName: phoneName,
                                                 platform: platform, appVersion: version)
            guard let secret = CompanionProtocol.decodeBase64Url(response.deviceSecret) else {
                throw CompanionClientError.badResponse
            }
            desktop.id = response.desktopId
            if !response.desktopName.isEmpty { desktop.name = response.desktopName }
            desktop.pairedAt = Date()
            desktop.lastSeen = desktop.pairedAt
            if let before = companionDesktop, before.id == desktop.id { desktop.received = before.received }
            try store.save(desktop, secret: secret)
        } catch {
            companionStatus = before
            if case .unreachable? = error as? CompanionClientError {
                errorMessage = companionUnreachableReason(desktop)
            } else {
                errorMessage = error.localizedDescription
            }
            return
        }
        stopPulling()
        companionDesktop = desktop
        companionClient = client
        companionStatus = .reachable(desktopName: desktop.name, queuedPages: 0)
        statusMessage = CompanionText.pairedMessage(desktop.name)
    }

    /// Tells the desktop to forget this phone (best effort: it may be off), then forgets the desktop
    /// and its secret. Documents waiting to be sent stay, for that desktop only.
    public func unpairDesktop() async {
        guard let desktop = companionDesktop else { return }
        stopPulling()
        if let client = desktopClient() {
            try? await client.unpair()
        }
        companionStore?.remove()
        companionClient = nil
        companionDesktop = nil
        companionStatus = .notPaired
        statusMessage = CompanionText.unpairedMessage(desktop.name)
    }

    /// Asks the desktop how it is (`hello`) at its addresses: `.reachable` with its queue, keeping the
    /// name it gives now; a desktop that no longer knows this phone (401) loses its secret here and is
    /// `.unpaired`; one that does not answer is `.unreachable` with the reason
    /// (`companionUnreachableReason`), everything kept.
    public func checkDesktop() async {
        guard let desktop = companionDesktop else {
            companionStatus = .notPaired
            return
        }
        guard let client = desktopClient() else {
            companionStatus = .unpaired(byDesktop: desktop.name)
            return
        }
        companionStatus = .checking
        do {
            let hello = try await client.hello()
            // Unpaired or found at new addresses meanwhile: only what the answer says is kept.
            guard var current = companionDesktop, current.id == desktop.id else { return }
            if !hello.desktopName.isEmpty { current.name = hello.desktopName }
            current.lastSeen = Date()
            companionStore?.update(current)
            companionDesktop = current
            companionStatus = .reachable(desktopName: current.name, queuedPages: hello.queuedPages)
        } catch {
            companionFailed(error, desktop)
        }
    }

    /// Writes the queue as a `.csdoc` (`exportPackage`) into the outbox for the paired desktop and sends
    /// what waits there (`drainOutbox`); the queue is not touched. A document that cannot be sent now
    /// waits in the outbox for the next time.
    public func sendQueueToDesktop(target: CompanionTarget) async {
        guard let outbox = companionOutbox, let desktop = companionDesktop, desktopClient() != nil else {
            errorMessage = CompanionText.notPairedMessage
            return
        }
        guard outbox.count < PhoneOutbox.maxItems else {
            errorMessage = CompanionText.outboxFullMessage
            return
        }
        do {
            try FileManager.default.createDirectory(at: outbox.directory, withIntermediateDirectories: true)
            let url = try await exportPackage(to: outbox.directory)
            try outbox.enqueue(url, target: target, desktopId: desktop.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        companionOutboxCount = outbox.count
        await drainOutbox()
    }

    /// Sends the documents waiting in the outbox for the paired desktop one by one, oldest first (those
    /// queued for a desktop paired before wait for it), each removed once the desktop has it (a duplicate
    /// counts: it had it already). One the desktop refuses (too large, not readable) stays, said in
    /// `errorMessage`, and the next is sent; when the desktop does not answer, is busy or no longer knows
    /// this phone, the rest wait. "Sent 3 pages to Office PC."
    public func drainOutbox() async {
        guard !companionDraining, let outbox = companionOutbox, let desktop = companionDesktop,
              let client = desktopClient() else { return }
        companionDraining = true
        defer {
            companionDraining = false
            companionOutboxCount = outbox.count
        }
        var tried: Set<String> = []
        var pages = 0
        while let item = outbox.next(excluding: tried) {
            tried.insert(item.id)
            guard item.desktopId == desktop.id else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: outbox.fileURL(of: item), options: .mappedIfSafe)
            } catch {
                if FileManager.default.fileExists(atPath: outbox.fileURL(of: item).path) {
                    outbox.markFailed(item.id, error: error.localizedDescription)
                } else {
                    outbox.remove(item.id)
                }
                continue
            }
            do {
                let response = try await client.send(packageId: item.id, data: data, target: item.target)
                outbox.markSent(item.id)
                pages += response.pageCount
                companionOutboxCount = outbox.count
            } catch {
                outbox.markFailed(item.id, error: error.localizedDescription)
                switch error as? CompanionClientError {
                case .tooLarge?, .invalidPackage?, .refused?:
                    errorMessage = CompanionText.notSentMessage(item.fileName, reason: error.localizedDescription)
                    continue
                case .unreachable?:
                    companionFailed(error, desktop)
                    statusMessage = CompanionText.cannotReachMessage(desktop.name)
                default:
                    companionFailed(error, desktop)
                    statusMessage = error.localizedDescription
                }
                return
            }
        }
        if pages > 0 {
            statusMessage = CompanionText.sentMessage(pages, desktopName: desktop.name)
            await checkDesktop()
        }
    }

    /// Starts taking what the desktop holds for this phone: a long poll (`outbox(wait: 25)`) for as long
    /// as it runs. A `.csdoc` is downloaded into the inbox folder and offered on the banner as one opened
    /// by hand (`openPackage(at:)`) once nothing else is offered, its file kept until it is taken or
    /// dismissed (`offerReceivedPackage`); any other file goes to the save folder and is said. Each is
    /// acknowledged once written, so the desktop drops it, and its id kept (`PairedDesktop.received`):
    /// one listed again is acknowledged again, never saved twice. A desktop that no longer knows this
    /// phone stops it (`.unpaired`); other failures wait 5 s, then 30 s each, and try again. Nothing
    /// while it runs.
    public func pullFromDesktop() {
        guard companionPull == nil, companionDesktop != nil, companionInbox != nil else { return }
        companionPull = Task { [weak self] in
            await self?.pullLoop()
        }
    }

    public func stopPulling() {
        companionPull?.cancel()
        companionPull = nil
    }

    /// Removes the documents waiting to be sent, unsent.
    public func clearOutbox() {
        guard let outbox = companionOutbox else { return }
        for item in outbox.items {
            outbox.remove(item.id)
        }
        companionOutboxCount = outbox.count
    }

    /// The desktop with this id was found on the network (its DNS-SD service, TXT `id`) at `addresses`
    /// and `port`. When that is the paired desktop and they differ from the ones kept (a new DHCP
    /// lease), they replace them, IPv4 first, once the pinned certificate answers there, since anyone
    /// can advertise that id; the next request looks for its address anew. Returns whether they did.
    @discardableResult
    public func desktopFound(id: String, addresses: [String], port: Int) async -> Bool {
        guard let desktop = companionDesktop, desktop.id == id, (1...65535).contains(port) else { return false }
        var ipv4: [String] = []
        var ipv6: [String] = []
        for address in addresses where PairingUri.isValidAddress(address) && !ipv4.contains(address)
            && !ipv6.contains(address) {
            if address.contains(":") {
                ipv6.append(address)
            } else {
                ipv4.append(address)
            }
        }
        let found = Array((ipv4 + ipv6).prefix(PairingUri.maxAddresses))
        guard !found.isEmpty, Set(found) != Set(desktop.addresses) || port != desktop.port else { return false }
        var moved = desktop
        moved.addresses = found
        moved.port = port
        let probe = CompanionClient(desktop: moved, secret: nil, protocolClasses: companionProtocolClasses)
        guard (try? await probe.health()) != nil, var current = companionDesktop, current.id == id else { return false }
        current.addresses = found
        current.port = port
        companionStore?.update(current)
        companionDesktop = current
        companionClient = nil
        return true
    }

    /// Offers the oldest package received from the desktop and still in the inbox folder on the banner,
    /// unless a package is offered already; one that cannot be read is said and removed.
    func offerReceivedPackage() async {
        guard pendingPackage == nil, let folder = companionInbox else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        var oldest: URL?
        var oldestDate = Date.distantFuture
        for file in files where file.pathExtension.lowercased() == CompanionPackage.fileExtension {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < oldestDate {
                oldest = file
                oldestDate = created
            }
        }
        guard let url = oldest else { return }
        let opening = packageOpens + 1
        await openPackage(at: url)
        // Nothing offered and nothing else opened meanwhile: the read failed, and would again.
        if pendingPackage == nil, packageOpens == opening {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The offered `package` was taken or dismissed: one received from the desktop leaves the inbox
    /// folder, and the next one received is offered.
    func receivedPackageAnswered(_ package: PendingPackage) {
        guard let folder = companionInbox else { return }
        let from = package.url.deletingLastPathComponent().resolvingSymlinksInPath()
        if from.path == folder.resolvingSymlinksInPath().path {
            try? FileManager.default.removeItem(at: package.url)
        }
        Task { [weak self] in
            await self?.offerReceivedPackage()
        }
    }

    /// Why the paired desktop does not answer: the network keeps devices apart when the desktop is
    /// seen on it (`companionDesktopSeenOnNetwork`), else it is not on this network.
    func companionUnreachableReason(_ desktop: PairedDesktop) -> String {
        companionDesktopSeenOnNetwork?(desktop.id) == true
            ? CompanionText.clientIsolationReason : CompanionText.notOnNetworkReason(desktop.name)
    }

    // MARK: - Private

    /// The client of the paired desktop, made with its secret the first time; nil without either.
    private func desktopClient() -> CompanionClient? {
        if let client = companionClient { return client }
        guard let desktop = companionDesktop, let secret = companionStore?.secret(for: desktop) else { return nil }
        let client = CompanionClient(desktop: desktop, secret: secret, protocolClasses: companionProtocolClasses)
        companionClient = client
        return client
    }

    /// What a failed request means for the link.
    private func companionFailed(_ error: Error, _ desktop: PairedDesktop) {
        // Unpaired, or another desktop paired, while the request ran.
        guard companionDesktop?.id == desktop.id else { return }
        switch error as? CompanionClientError {
        case .unauthorized?:
            stopPulling()
            companionStore?.forgetSecret(of: desktop)
            companionClient = nil
            companionStatus = .unpaired(byDesktop: desktop.name)
        case .unreachable?:
            companionStatus = .unreachable(reason: companionUnreachableReason(desktop))
        default:
            companionStatus = .unreachable(reason: error.localizedDescription)
        }
    }

    private func pullLoop() async {
        var failures = 0
        while !Task.isCancelled, let desktop = companionDesktop, let client = desktopClient() {
            var wait: TimeInterval = 0
            do {
                let list = try await client.outbox(wait: CompanionProtocol.maxOutboxWaitSeconds)
                for item in list.items {
                    try Task.checkCancellation()
                    try await receive(item, from: client, desktop: desktop)
                }
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                switch error as? CompanionClientError {
                case .unauthorized?:
                    companionFailed(error, desktop)
                    return
                case .rateLimited(let seconds)?:
                    wait = TimeInterval(seconds)
                default:
                    wait = failures == 0 ? 5 : 30
                }
                failures += 1
            }
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        if !Task.isCancelled { companionPull = nil }
    }

    /// Downloads one document the desktop holds, keeps it (a package in the inbox folder until it is
    /// answered, any other file in the save folder), notes its id and acknowledges it, then offers or
    /// says it. One received before is only acknowledged again.
    private func receive(_ item: OutboxItem, from client: CompanionClient, desktop: PairedDesktop) async throws {
        if companionDesktop?.received.contains(item.id) == true {
            try await acknowledge(item.id, from: client)
            return
        }
        let data = try await client.outboxItem(id: item.id)
        guard let inbox = companionInbox else { return }
        let packageExtension = CompanionPackage.fileExtension
        let isPackage = item.contentType == CompanionProtocol.packageContentType
            || item.name.lowercased().hasSuffix("." + packageExtension)
        let folder = try isPackage ? inbox : destinationDirectory()
        var name = PairedDeviceStore.cleanName(item.name)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name.hasPrefix(".") { name = item.id + name }
        let named = URL(fileURLWithPath: name)
        var fileExtension = isPackage ? packageExtension : named.pathExtension
        if fileExtension.isEmpty { fileExtension = "bin" }
        let url = NamingTemplate.uniqueURL(in: folder, base: named.deletingPathExtension().lastPathComponent,
                                           fileExtension: fileExtension)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if var current = companionDesktop, current.id == desktop.id {
            current.noteReceived(item.id)
            companionStore?.update(current)
            companionDesktop = current
        }
        // Acknowledged before the offer, which decodes every picture: the file is kept already.
        var failure: Error?
        do {
            try await acknowledge(item.id, from: client)
        } catch {
            failure = error
        }
        if isPackage {
            await offerReceivedPackage()
        } else {
            statusMessage = CompanionText.receivedMessage(url.lastPathComponent, desktopName: desktop.name)
        }
        if let failure = failure { throw failure }
    }

    /// Tells the desktop the phone has the item.
    private func acknowledge(_ id: String, from client: CompanionClient) async throws {
        do {
            try await client.ack(id: id)
        } catch CompanionClientError.refused(let status, _) where status == 404 {
            // Gone already (acknowledged before, or expired on the desktop).
        }
    }
}
