import Darwin
import Foundation

// Twin of windows/LazyScan.Core/Companion/SyncFolderWatcher.cs: the same rules for taking,
// skipping and leaving a file; a DispatchSource on the folder where Windows has a FileSystemWatcher,
// and the C# events are closures.

/// Watches the cloud sync folder (C2) for the packages phones put there (`SyncPackage`) and receives them
/// as if they had been uploaded. A "<packageId>.cssync" file is taken once its size has not changed for
/// `settleTime` (the sync client may still be writing it): the phone that sealed it is found by trying
/// each paired phone's sync key, its package is received into the inbox under that phone, passed to
/// `onPackageReceived` and the file deleted. A package the inbox has received before (over the network
/// or from the folder) is only deleted. A file no paired phone's key opens is left where it is and
/// reported once (`onProblem`), then tried again only once its size or modification date changes or
/// `retryTime` has passed. A phone whose key cannot be read (a locked keychain) is reported once and
/// skipped for the rest of the poll; a file no key opened while that was so is not reported (it may be
/// that phone's) but waits the same way. One that cannot be read now (an evicted iCloud file still
/// downloading) is tried again on the next poll. The folder is looked at every `pollInterval`, at once
/// when it changes, and again after `settleTime` while a file is still settling. Safe to use from any
/// thread.
public final class SyncFolderWatcher: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 5
    public static let settleTime: TimeInterval = 2
    public static let retryTime: TimeInterval = 60

    public let folder: URL
    private let devices: PairedDeviceStore
    private let inbox: CompanionInbox
    private let clock: () -> Date
    private let lock = NSLock()
    /// Each file's size and modification date, and since when it has had them (touched by one poll at a
    /// time).
    private var seen: [String: (size: Int, modified: Date?, since: Date)] = [:]
    /// The files reported, not reported again while they stay as they are.
    private var reported: Set<String> = []
    /// When each file that did not open was last tried.
    private var failed: [String: Date] = [:]
    /// The phones whose key could not be read: reported until it can be again, skipped for the poll.
    private var reportedKeys: Set<String> = []
    private var unreadKeys: Set<String> = []
    private var polling = false
    private var loop: Task<Void, Never>?
    private var source: DispatchSourceFileSystemObject?
    /// When the loop looks next (sooner while a file settles).
    private var nextPoll: TimeInterval = SyncFolderWatcher.pollInterval

    /// A phone's package was received from the folder (on the poll's task). Release it from the inbox
    /// once imported.
    public var onPackageReceived: ((ReceivedPackage, PairedDevice) -> Void)?
    /// A file in the folder could not be opened, or a phone's key read: the message to show, once per file
    /// or phone.
    public var onProblem: ((String) -> Void)?

    public init(folder: URL, devices: PairedDeviceStore, inbox: CompanionInbox, clock: @escaping () -> Date = { Date() }) {
        self.folder = folder
        self.devices = devices
        self.inbox = inbox
        self.clock = clock
    }

    /// "A file in the cloud folder could not be read: 1a2b3c4d.cssync. …"
    public static func unreadableMessage(_ fileName: String, reason: String) -> String {
        "A file in the cloud folder could not be read: \(fileName). \(reason)"
    }

    /// "The key for Aytu's iPhone could not be read, so files from it cannot be opened. Pair the phone again."
    public static func keyUnreadableMessage(_ phoneName: String) -> String {
        "The key for \(phoneName) could not be read, so files from it cannot be opened. Pair the phone again."
    }

    /// Starts polling and watching; a folder that is not there now is polled until it is.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let wait = self?.takeNextPoll() ?? SyncFolderWatcher.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename],
                                                              queue: .global(qos: .utility))
        watch.setEventHandler { [weak self] in
            Task {
                await self?.poll()
                try? await Task.sleep(nanoseconds: UInt64(SyncFolderWatcher.settleTime * 1_000_000_000))
                await self?.poll()
            }
        }
        watch.setCancelHandler {
            Darwin.close(descriptor)
        }
        watch.resume()
        source = watch
    }

    public func stop() {
        lock.lock()
        loop?.cancel()
        loop = nil
        source?.cancel()
        source = nil
        lock.unlock()
    }

    /// Looks at the folder once; does nothing while another look runs.
    public func poll() async {
        guard claimPoll() else { return }
        defer { releasePoll() }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        let packages = files.filter { $0.pathExtension == SyncPackage.fileExtension }
        let now = clock()
        let names = Set(packages.map(\.lastPathComponent))
        seen = seen.filter { names.contains($0.key) }
        reported = reported.filter { names.contains($0) }
        failed = failed.filter { names.contains($0.key) }
        unreadKeys = []
        var settling = false
        for url in packages {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { continue }
            let modified = values.contentModificationDate
            if let known = seen[name], known.size == size, known.modified == modified {
                if now.timeIntervalSince(known.since) < SyncFolderWatcher.settleTime {
                    settling = true
                } else if failed[name].map({ now.timeIntervalSince($0) >= SyncFolderWatcher.retryTime }) ?? true {
                    await take(url, name: name, size: size)
                }
            } else {
                seen[name] = (size, modified, now)
                reported.remove(name)
                failed[name] = nil
                settling = true
            }
        }
        if settling { pollSoon() }
    }

    deinit {
        loop?.cancel()
        source?.cancel()
    }

    private func claimPoll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !polling else { return false }
        polling = true
        return true
    }

    private func releasePoll() {
        lock.lock()
        polling = false
        lock.unlock()
    }

    private func pollSoon() {
        lock.lock()
        nextPoll = SyncFolderWatcher.settleTime
        lock.unlock()
    }

    private func takeNextPoll() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let wait = nextPoll
        nextPoll = SyncFolderWatcher.pollInterval
        return wait
    }

    private func take(_ url: URL, name: String, size: Int) async {
        let packageId = url.deletingPathExtension().lastPathComponent
        guard CompanionProtocol.isValidId(packageId) else {
            report(name, SyncPackageError.notASyncPackage.localizedDescription)
            return
        }
        guard size <= SyncPackage.maxFileBytes else {
            report(name, SyncPackageError.tooLarge.localizedDescription)
            return
        }
        // Reading an evicted file downloads it; until it is here, the next poll tries again.
        guard let data = try? Data(contentsOf: url) else { return }
        var found: (device: PairedDevice, target: CompanionTarget, plaintext: Data)?
        var keyUnread = false
        do {
            for device in devices.devices {
                guard !unreadKeys.contains(device.id) else {
                    keyUnread = true
                    continue
                }
                let key: Data
                do {
                    guard let read = try devices.syncKey(for: device.id) else { continue }
                    key = read
                    reportedKeys.remove(device.id)
                } catch {
                    keyUnread = true
                    unreadKeys.insert(device.id)
                    if reportedKeys.insert(device.id).inserted {
                        onProblem?(SyncFolderWatcher.keyUnreadableMessage(device.name.isEmpty ? "a phone" : device.name))
                    }
                    continue
                }
                do {
                    let opened = try SyncPackage.open(data, packageId: packageId, phoneId: device.id, key: key)
                    found = (device, opened.target, opened.plaintext)
                    break
                } catch SyncPackageError.wrongKeyOrTampered {
                    continue
                }
            }
        } catch {
            report(name, error.localizedDescription)
            return
        }
        guard let match = found else {
            if keyUnread {
                failed[name] = clock()
            } else {
                report(name, SyncPackageError.wrongKeyOrTampered.localizedDescription)
            }
            return
        }
        let device = match.device
        if inbox.find(deviceId: device.id, packageId: packageId) != nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // An upload of the same package runs: the next poll finds it received.
        guard inbox.tryBegin(deviceId: device.id, packageId: packageId) else { return }
        defer { inbox.end(deviceId: device.id, packageId: packageId) }
        if inbox.find(deviceId: device.id, packageId: packageId) != nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let plaintext = Data(match.plaintext)
        let length = Int64(plaintext.count)
        var offset = 0
        let body = CompanionRequestBody(length: length) { maxLength in
            let end = min(offset + maxLength, plaintext.count)
            defer { offset = end }
            return plaintext.subdata(in: offset..<end)
        }
        do {
            let package = try await inbox.receive(deviceId: device.id, packageId: packageId, target: match.target, body: body,
                                                  length: length, now: clock())
            // One left behind is found received by the next poll and deleted then.
            try? FileManager.default.removeItem(at: url)
            onPackageReceived?(package, device)
        } catch let error as CompanionPackageError {
            report(name, error.message)
        } catch {
            // Tried again on the next poll.
        }
    }

    private func report(_ name: String, _ reason: String) {
        failed[name] = clock()
        guard reported.insert(name).inserted else { return }
        onProblem?(SyncFolderWatcher.unreadableMessage(name, reason: reason))
    }
}
