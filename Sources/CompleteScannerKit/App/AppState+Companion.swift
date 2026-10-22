import Foundation

// The phone's side of C1 (I20): pairing with a desktop from its code, checking the link, sending the
// queue as a `.csdoc` and taking what the desktop holds for the phone. The desktop is the server
// (windows/CompleteScanner.Core/Companion); this is the client, through `CompanionClient`. When the
// desktop cannot be reached, documents go through the cloud sync folder instead (C2, `SyncPackage`).

/// The companion's texts on the phone.
public enum CompanionText {
    public static let clientIsolationReason = "This network keeps devices apart (client isolation). Use another Wi-Fi."
    public static let clientIsolationSyncFolderReason =
        "This network keeps devices apart (client isolation). Documents go to the cloud folder instead."
    public static let notPairedMessage =
        "Pair this phone with a computer first: choose Pair a phone in CompleteScanner on the computer and scan its code."
    public static let outboxFullMessage =
        "\(PhoneOutbox.maxItems) documents are waiting to be sent already. Send them, or remove some first."
    public static let unreachableMessage = "The computer cannot be reached."
    public static let wrongCertificateMessage =
        "The computer that answered is not the one this phone was paired with. If pairing was reset there, pair again."
    public static let badResponseMessage = "The computer's answer could not be read."
    public static let notSavedMessage = "The pairing could not be saved on this phone. Try again."
    public static let syncFolderHint = "Set a cloud folder in My computer to send when the PC cannot be reached."
    public static let syncFolderUnavailableMessage =
        "The cloud folder could not be opened. Choose it again in My computer."
    public static let syncFolderLine =
        "A folder in iCloud Drive or OneDrive that your computer also syncs. Documents go here, encrypted, when the computer cannot be reached."

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

    /// "Put Scan 12 in the cloud folder for Office PC."
    public static func putInSyncFolderMessage(_ documentName: String, desktopName: String) -> String {
        "Put \(documentName) in the cloud folder for \(desktopName)."
    }

    /// "Put 3 documents in the cloud folder for Office PC."
    public static func putInSyncFolderMessage(count: Int, desktopName: String) -> String {
        "Put \(count) documents in the cloud folder for \(desktopName)."
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
    /// the one the code names. On success the desktop, its secret and its sync key (from a desktop that
    /// has the sync folder) are kept, replacing a desktop paired before; pairing the same desktop again
    /// keeps its sync folder. A refusal is said in `errorMessage` with the desktop's own message, and the
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
            if let before = companionDesktop, before.id == desktop.id {
                desktop.received = before.received
                desktop.syncFolderBookmark = before.syncFolderBookmark
            }
            let syncKey = CompanionProtocol.decodeBase64Url(response.syncKey)
            try store.save(desktop, secret: secret, syncKey: syncKey?.count == SyncPackage.keyByteCount ? syncKey : nil)
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
    /// `errorMessage`, and the next is sent; when the desktop is busy or no longer knows this phone, the
    /// rest wait. When it does not answer, the rest go through the sync folder if the desktop handed out
    /// a sync key and a folder is set (`sendThroughSyncFolder`), except those it refused as too large or
    /// not readable (another error status sends the next too, but keeps the folder open); with a key but no
    /// folder, the status says once this session where to set one. One that failed to go into the folder
    /// before tries the folder first. One in the folder leaves once its file has left it (the desktop took
    /// it), or once it is sent over the network, its file then taken out of the folder. "Sent 3 pages to
    /// Office PC."
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
            if item.inSyncFolder, let folder = openSyncFolder(), !syncFolder(folder, holds: item.id) {
                outbox.markSent(item.id)
                companionOutboxCount = outbox.count
                continue
            }
            if item.viaSyncFolder, sendThroughSyncFolder(itemId: item.id) { continue }
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
                if item.inSyncFolder, let folder = openSyncFolder() {
                    try? AppState.coordinateWriting(folder.appendingPathComponent(SyncPackage.fileName(item.id)),
                                                    options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
                }
                outbox.markSent(item.id)
                pages += response.pageCount
                companionOutboxCount = outbox.count
            } catch {
                outbox.markFailed(item.id, error: error.localizedDescription)
                switch error as? CompanionClientError {
                case .tooLarge?, .invalidPackage?:
                    outbox.markRefused(item.id)
                    errorMessage = CompanionText.notSentMessage(item.fileName, reason: error.localizedDescription)
                    continue
                case .refused?:
                    // Not about the document itself (a 500, say): it may still go through the folder.
                    errorMessage = CompanionText.notSentMessage(item.fileName, reason: error.localizedDescription)
                    continue
                case .unreachable?:
                    companionFailed(error, desktop)
                    statusMessage = CompanionText.cannotReachMessage(desktop.name)
                    putInSyncFolder(for: desktop)
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

    /// The paired desktop handed out a sync key, so documents can go through a cloud sync folder.
    public var canUseSyncFolder: Bool {
        guard let desktop = companionDesktop else { return false }
        return companionStore?.syncKey(for: desktop) != nil
    }

    /// Keeps `bookmark` (made by the shell of the folder picked in My computer, in iCloud Drive or
    /// OneDrive) as the paired desktop's sync folder; nil forgets it. The desktop watches the same folder.
    /// Documents put in the folder set before go again, into this one or over the network.
    public func setSyncFolder(bookmark: Data?) {
        guard var desktop = companionDesktop else { return }
        if bookmark != desktop.syncFolderBookmark, let outbox = companionOutbox {
            for item in outbox.items where item.desktopId == desktop.id && item.inSyncFolder {
                outbox.markInSyncFolder(item.id, false)
            }
        }
        desktop.syncFolderBookmark = bookmark
        companionStore?.update(desktop)
        companionDesktop = desktop
    }

    /// The sync folder of the paired desktop, opened through `resolveSyncFolderBookmark`, its bookmark
    /// brought up to date; nil without a folder or a resolver, or when it does not resolve now (the
    /// bookmark is kept).
    public func openSyncFolder() -> URL? {
        guard var desktop = companionDesktop, let bookmark = desktop.syncFolderBookmark,
              let resolve = resolveSyncFolderBookmark, let resolved = resolve(bookmark) else { return nil }
        if resolved.bookmark != bookmark {
            desktop.syncFolderBookmark = resolved.bookmark
            companionStore?.update(desktop)
            companionDesktop = desktop
        }
        return resolved.folder
    }

    /// Seals the waiting document `itemId` with the paired desktop's sync key (`SyncPackage`) and puts it
    /// in the sync folder as "<id>.cssync", written whole in a coordinated write, so the provider (iCloud
    /// Drive, OneDrive) takes it as a new file and the desktop never takes half of it; it stays in the
    /// outbox, marked in the folder, until the desktop has it (`drainOutbox`). False when it is not for the
    /// paired desktop, the desktop refused it, it is in the folder already, or there is no key or folder;
    /// a folder that does not open or a write that fails is said in `errorMessage`, and the document waits,
    /// to try the folder first the next time (one too large to seal counts as refused). "Put Scan 12 in the
    /// cloud folder for Office PC."
    @discardableResult
    public func sendThroughSyncFolder(itemId: String) -> Bool {
        guard let outbox = companionOutbox, let desktop = companionDesktop,
              let item = outbox.items.first(where: { $0.id == itemId }), item.desktopId == desktop.id,
              !item.refused, !item.inSyncFolder,
              let key = companionStore?.syncKey(for: desktop), desktop.syncFolderBookmark != nil else { return false }
        guard let folder = openSyncFolder() else {
            outbox.markViaSyncFolder(item.id)
            errorMessage = CompanionText.syncFolderUnavailableMessage
            return false
        }
        do {
            let data = try Data(contentsOf: outbox.fileURL(of: item), options: .mappedIfSafe)
            let sealed = try SyncPackage.seal(packageId: item.id, phoneId: desktop.phoneId, target: item.target,
                                              plaintext: data, key: key)
            try AppState.coordinateWriting(folder.appendingPathComponent(SyncPackage.fileName(item.id)),
                                           options: .forReplacing) { try sealed.write(to: $0, options: .atomic) }
        } catch {
            outbox.markFailed(item.id, error: error.localizedDescription)
            // The desktop refuses it over the network too: the same limit.
            if (error as? SyncPackageError) == .tooLarge {
                outbox.markRefused(item.id)
            } else {
                outbox.markViaSyncFolder(item.id)
            }
            errorMessage = CompanionText.notSentMessage(item.fileName, reason: error.localizedDescription)
            return false
        }
        outbox.markInSyncFolder(item.id)
        let name = URL(fileURLWithPath: item.fileName).deletingPathExtension().lastPathComponent
        statusMessage = CompanionText.putInSyncFolderMessage(name, desktopName: desktop.name)
        return true
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
    /// seen on it (`companionDesktopSeenOnNetwork`), and then the cloud folder is used when one is set
    /// for a desktop that handed out a sync key; else it is not on this network.
    func companionUnreachableReason(_ desktop: PairedDesktop) -> String {
        guard companionDesktopSeenOnNetwork?(desktop.id) == true else {
            return CompanionText.notOnNetworkReason(desktop.name)
        }
        if desktop.syncFolderBookmark != nil, companionStore?.syncKey(for: desktop) != nil {
            return CompanionText.clientIsolationSyncFolderReason
        }
        return CompanionText.clientIsolationReason
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

    /// `desktop` did not answer: what waits for it goes through the sync folder when it handed out a sync
    /// key and a folder is set; with a key but no folder, the status says where to set one, once.
    private func putInSyncFolder(for desktop: PairedDesktop) {
        guard let outbox = companionOutbox, companionStore?.syncKey(for: desktop) != nil else { return }
        guard companionDesktop?.syncFolderBookmark != nil else {
            if !companionSyncFolderHinted {
                companionSyncFolderHinted = true
                statusMessage = CompanionText.cannotReachMessage(desktop.name) + " " + CompanionText.syncFolderHint
            }
            return
        }
        var put = 0
        for item in outbox.items where item.desktopId == desktop.id && !item.inSyncFolder && !item.refused {
            if sendThroughSyncFolder(itemId: item.id) {
                put += 1
            } else if openSyncFolder() == nil {
                break
            }
        }
        if put > 1 { statusMessage = CompanionText.putInSyncFolderMessage(count: put, desktopName: desktop.name) }
    }

    /// Whether `id`'s file is still in the sync folder `folder` (an iCloud file moved off the phone shows
    /// as ".<name>.icloud"); a folder that cannot be listed holds it.
    private func syncFolder(_ folder: URL, holds id: String) -> Bool {
        let name = SyncPackage.fileName(id)
        var holds = true
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: .immediatelyAvailableMetadataOnly,
                                                         error: &coordinationError) { listed in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: listed.path) else { return }
            holds = names.contains(name) || names.contains("." + name + ".icloud")
        }
        return holds
    }

    /// Runs `body` on `url` in a coordinated write, so the provider of a folder picked in Files learns of
    /// the change (an uncoordinated one may never be uploaded).
    private static func coordinateWriting(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                          _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options,
                                                         error: &coordinationError) { file in
            do {
                try body(file)
            } catch {
                failure = error
            }
        }
        if let failure = failure { throw failure }
        if let coordinationError = coordinationError { throw coordinationError }
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
