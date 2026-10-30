import Darwin
import Foundation

// Twin of windows/LazyScan.App/AppViewModel.Companion.cs: the desktop's side of C1 (I21), the
// Mac receiving from paired phones. The phone's side is AppState+Companion.swift; the two roles share
// the protocol and nothing else. The shell passes the platform's pieces (`setUpCompanionHost`); the
// Phone window answers `confirmPhonePairing`.

/// The desktop's companion texts.
public enum CompanionHostText {
    public static let elsewhereMessage =
        "Another copy of Lazy Scan receives from phones. Pair and manage phones there."

    /// "The phone link could not start: …"
    public static func notStartedMessage(_ reason: String) -> String {
        "The phone link could not start: \(reason)"
    }

    /// "Adding pages from Aytu's iPhone…"
    public static func addingMessage(_ phoneName: String) -> String {
        "Adding pages from \(phoneName)\u{2026}"
    }

    /// "2 pages from Aytu's iPhone will be added to the queue when the current step is done.", or what to
    /// choose when the settings do not collect pages.
    public static func waitingMessage(pageCount: Int, from: String, collectsPages: Bool) -> String {
        let what = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        if collectsPages { return "\(what) from \(from) will be added to the queue when the current step is done." }
        let them = pageCount == 1 ? "it" : "them"
        return "\(what) from \(from) \(pageCount == 1 ? "is" : "are") waiting: choose Document mode, or a document task, "
            + "with Collect pages before saving on, to add \(them) to the queue."
    }

    /// "The document from Aytu's iPhone could not be added: one of its pictures could not be read."
    public static func unreadableMessage(_ phoneName: String) -> String {
        "The document from \(phoneName) could not be added: one of its pictures could not be read."
    }

    /// The document could not be read now; it stays in the inbox.
    public static func notAddedMessage(_ phoneName: String, reason: String) -> String {
        "The document from \(phoneName) could not be added to the queue now (\(reason)). "
            + "It is kept on this Mac and added the next time Lazy Scan starts."
    }
}

extension AppState {
    /// Keeps the platform's pieces of the phone link (the Mac's keychain identity, interfaces, DNS-SD and
    /// the phones' sync keys) and starts it when a phone is paired; nothing listens otherwise, and no
    /// certificate is made. The cloud folder is watched while it runs.
    public func setUpCompanionHost(_ options: CompanionServiceOptions) {
        companionHostOptions = options
        if PairedDeviceStore(directory: options.settingsDirectory).count > 0 {
            ensureCompanionHost()
        }
    }

    /// The phone link, started now if it was not (the Phone window opens); nil when another copy of
    /// the app has it (`companionHostStatus.state == .elsewhere`) or it could not start
    /// (`companionHostError`).
    @discardableResult
    public func ensureCompanionHost() -> CompanionService? {
        if let companionService { return companionService }
        guard let options = companionHostOptions, companionHostStatus.state != .elsewhere else { return nil }
        // One copy of the app receives: the one holding the lock (released by the system when it quits).
        let folder = options.dataDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor: Int32 = Darwin.open(folder.appendingPathComponent("companion.lock").path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            companionHostError = String(cString: strerror(errno))
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            companionHostStatus = CompanionHostStatus(state: .elsewhere, networks: [], endpoints: [])
            return nil
        }
        companionHostLock = descriptor
        let service = CompanionService(options)
        service.router.approvePairing = { [weak self] request in
            await self?.askToPair(request) ?? false
        }
        service.onPackageReceived = { [weak self] package, device in
            Task { @MainActor in self?.queuePhoneDocument(package, phoneName: device.name) }
        }
        service.onSyncFolderProblem = { [weak self] message in
            Task { @MainActor in
                self?.syncFolderProblem = message
                self?.statusMessage = message
            }
        }
        service.onChange = { [weak self] in
            Task { @MainActor in self?.companionHostChanged() }
        }
        service.queuedPages = scannedPages.count
        companionService = service
        companionHostError = nil
        Task { await service.start() }
        var names: [String: String] = [:]
        for device in service.devices.devices {
            names[device.id] = device.name
        }
        // Documents received before the app last closed and not yet in the queue.
        for package in service.inbox.pending() {
            queuePhoneDocument(package, phoneName: names[package.deviceId] ?? "")
        }
        return service
    }

    /// Chooses the cloud folder phones put documents in (nil: none); false when that could not be saved.
    /// Twin of C# `SetPhoneSyncFolder`.
    @discardableResult
    public func setPhoneSyncFolder(_ folder: URL?) -> Bool {
        guard let service = companionService, service.setSyncFolder(folder) else { return false }
        syncFolderProblem = nil
        return true
    }

    /// Closes the bar above the window.
    public func dismissPhoneBar() {
        phoneBarMessage = nil
    }

    /// The queue can take a phone's pages now: it collects pages (`PhotoImport.isOffered` with Collect
    /// pages before saving on, as for a `.lsdoc` opened by hand) and nothing else is going on
    /// (`canIngest`). Twin of C# `CanTakePhonePages`.
    public var canTakePhonePages: Bool {
        PhotoImport.isOffered(settings) && settings.documentMultiPage && canIngest
    }

    /// The pages of a phone's document as the queue takes them: a document sent as new starts a
    /// document of its own (a split before its first page, when pages are queued already) and carries
    /// its name. Twin of the end of C# `CompanionPages.ToScannedPages`.
    nonisolated static func phonePages(_ package: PendingPackage, target: CompanionTarget, queueHasPages: Bool) -> [ScannedPage] {
        var pages = package.pages
        guard target == .new, var first = pages.first else { return pages }
        if queueHasPages { first = first.withDocumentBreak(.split) }
        if !package.documentName.isEmpty { first = first.withDocumentLabel(package.documentName) }
        pages[0] = first
        return pages
    }

    /// A document a phone sent, or put in the cloud folder (C2): added to the queue now, or as soon as the
    /// queue can take it.
    func queuePhoneDocument(_ package: ReceivedPackage, phoneName: String) {
        phoneDocuments.append((package, phoneName.isEmpty ? "a phone" : phoneName))
        addWaitingPhoneDocuments()
    }

    /// Adds the oldest waiting document when the queue can take it; otherwise says what waits and tries
    /// again shortly (and when the work running now ends, `endOfWork`).
    func addWaitingPhoneDocuments() {
        guard !phoneDocuments.isEmpty else {
            phoneRetry?.cancel()
            phoneRetry = nil
            if phoneDocumentsWaitingMessage != nil { phoneDocumentsWaitingMessage = nil }
            return
        }
        guard canTakePhonePages else {
            var pages = 0
            var names: [String] = []
            for document in phoneDocuments {
                pages += document.package.document.pages.count
                if !names.contains(document.phoneName) { names.append(document.phoneName) }
            }
            let waiting = CompanionHostText.waitingMessage(pageCount: pages, from: names.count == 1 ? names[0] : "your phones",
                                                           collectsPages: PhotoImport.isOffered(settings) && settings.documentMultiPage)
            if waiting != phoneDocumentsWaitingMessage {
                phoneDocumentsWaitingMessage = waiting
                // Only the reason the user can act on is shown on the bar; being busy passes on its own.
                if !isBusy { phoneBarMessage = waiting }
            }
            if phoneRetry == nil {
                phoneRetry = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.phoneRetry = nil
                    self.addWaitingPhoneDocuments()
                }
            }
            return
        }
        phoneRetry?.cancel()
        phoneRetry = nil
        let next = phoneDocuments.removeFirst()
        phoneDocumentsWaitingMessage = nil
        addPhoneDocument(next.package, phoneName: next.phoneName)
    }

    /// Decodes the document's pictures and queues its pages (`ingestPages`, as a phone's pages); the
    /// package is then released from the inbox and the bar says what arrived. A document with a picture
    /// that cannot be read is released too (it never will be); one that could not be read now, or
    /// whose adding was cancelled, stays in the inbox and is added the next time the app starts.
    private func addPhoneDocument(_ package: ReceivedPackage, phoneName: String) {
        let s = settings
        let queueHasPages = !scannedPages.isEmpty
        runExclusive { flag in
            self.statusMessage = CompanionHostText.addingMessage(phoneName)
            let url = package.url
            let read: Result<PendingPackage, Error> = await Task.detached(priority: .userInitiated) {
                Result { try PendingPackage.read(url) }
            }.value
            let decoded: PendingPackage
            switch read {
            case .success(let pending):
                decoded = pending
            case .failure(let error as CompanionPackageError):
                self.companionService?.inbox.release(package)
                self.errorMessage = error.kind == .unsupportedImage
                    ? CompanionHostText.unreadableMessage(phoneName) : error.localizedDescription
                self.statusMessage = "Ready."
                return
            case .failure(let error):
                self.errorMessage = CompanionHostText.notAddedMessage(phoneName, reason: error.localizedDescription)
                self.statusMessage = "Ready."
                return
            }
            let pages = AppState.phonePages(decoded, target: package.target, queueHasPages: queueHasPages)
            let intake = PageIntake(settings: s, source: .phone, generation: nil)
            guard try await self.ingestPages(pages, intake: intake, flag: flag) != nil else { return }
            let added = CompanionProtocol.addedMessage(pages.count, phoneName: phoneName)
            self.statusMessage = "\(added) \(self.scannedPages.count) in queue."
            self.companionService?.inbox.release(package)
            self.phoneBarMessage = added
        }
    }

    /// Asks `confirmPhonePairing`; allows the pairing when nobody is there to ask.
    private func askToPair(_ request: PairRequest) async -> Bool {
        guard let ask = confirmPhonePairing else { return true }
        return await ask(request)
    }

    private func companionHostChanged() {
        guard let service = companionService else { return }
        // Set every time, so a view showing the phones or the pairing follows too.
        companionHostStatus = service.status
    }
}
