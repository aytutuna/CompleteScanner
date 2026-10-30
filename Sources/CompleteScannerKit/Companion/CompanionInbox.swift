import Foundation

// Twin of windows/LazyScan.Core/Companion/CompanionInbox.cs: where uploads from paired phones
// land on the desktop, with the same checks, the same received.json per phone and the same
// idempotence by package id.

/// A package a paired phone sent, checked and waiting to be added to the queue. `url` is the package
/// file in the inbox; `CompanionInbox.release` deletes it once imported.
public struct ReceivedPackage {
    public var deviceId: String
    public var packageId: String
    public var url: URL
    public var document: CompanionDocument
    public var target: CompanionTarget
    public var received: Date

    public init(deviceId: String, packageId: String, url: URL, document: CompanionDocument, target: CompanionTarget,
                received: Date) {
        self.deviceId = deviceId
        self.packageId = packageId
        self.url = url
        self.document = document
        self.target = target
        self.received = received
    }
}

/// A package received before (an entry of received.json).
public struct ReceivedEntry: Codable, Equatable, Sendable {
    public var packageId = ""
    public var pageCount = 0
    public var received: Date?

    enum CodingKeys: String, CodingKey {
        case packageId, pageCount, received
    }

    public init() {}
}

extension ReceivedEntry {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        packageId = c.decodeLenient(forKey: .packageId, default: packageId)
        pageCount = c.decodeLenient(forKey: .pageCount, default: pageCount)
        received = c.decodeLenient(forKey: .received, default: received)
    }
}

/// The contents of a phone's received.json.
public struct ReceivedLog: Codable, Equatable, Sendable {
    public var packages: [ReceivedEntry] = []

    enum CodingKeys: String, CodingKey {
        case packages
    }

    public init() {}
}

extension ReceivedLog {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        packages = c.decodeLenient(forKey: .packages, default: packages)
    }
}

/// Why an upload was not received (besides a refused package, `CompanionPackageError`, and the file
/// system's errors).
public enum CompanionInboxError: Error, Equatable, Sendable {
    /// The phone's or the package's id is not valid (`CompanionProtocol.isValidId`).
    case invalidId
    /// The upload ended before all of it arrived.
    case endedEarly
    /// The list of received documents could not be saved.
    case notSaved
}

/// Where uploads from paired phones land (one folder per phone under the inbox folder). A body is
/// streamed to "<id>.part", must be exactly as long as announced, is read in full as a
/// `CompanionPackage` (every picture's checksum and format checked) and only then renamed to
/// "<id>.csdoc" and logged in received.json, so a package is either received whole and valid or not
/// at all. Uploads are idempotent by package id: one received before is answered from the log (the
/// last `maxLoggedPackages` per phone), and the same id cannot be received twice at once. Ids are
/// checked by `CompanionProtocol.isValidId`, so they are safe file names. Safe to use from any thread.
public final class CompanionInbox: @unchecked Sendable {
    public static let maxLoggedPackages = 1000
    public static let logFileName = "received.json"

    public let directory: URL
    private let lock = NSLock()
    private var inProgress: Set<String> = []

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default inbox: Application Support/CompleteScanner/Companion/Inbox.
    public static var defaultDirectory: URL {
        StoreFiles.defaultDirectory.appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// The package `packageId` received from `deviceId` before; nil when it was not (or an id is not valid).
    public func find(deviceId: String, packageId: String) -> ReceivedEntry? {
        guard CompanionInbox.valid(deviceId, packageId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return log(deviceId).packages.first { $0.packageId == packageId }
    }

    /// Claims the package id for one upload; false while another upload of it runs (or an id is not valid).
    public func tryBegin(deviceId: String, packageId: String) -> Bool {
        guard CompanionInbox.valid(deviceId, packageId) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return inProgress.insert(deviceId + "/" + packageId).inserted
    }

    /// Ends the claim of `tryBegin`.
    public func end(deviceId: String, packageId: String) {
        lock.lock()
        inProgress.remove(deviceId + "/" + packageId)
        lock.unlock()
    }

    /// Receives the package: copies exactly `length` bytes of `body`, checks it and logs it. Throws
    /// `CompanionPackageError` for a package that is refused, `CompanionInboxError.endedEarly` when the
    /// body ends early, `.notSaved` or the file system's error when it cannot be stored, and the body's
    /// own error when the connection breaks; nothing is kept then.
    public func receive(deviceId: String, packageId: String, target: CompanionTarget, body: CompanionRequestBody,
                        length: Int64, now: Date) async throws -> ReceivedPackage {
        guard CompanionInbox.valid(deviceId, packageId) else { throw CompanionInboxError.invalidId }
        let folder = deviceFolder(deviceId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(packageId + ".part")
        let final = folder.appendingPathComponent(packageId + "." + CompanionPackage.fileExtension)
        defer { CompanionInbox.tryDelete(part) }
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: part.path])
        }
        let file = try FileHandle(forWritingTo: part)
        do {
            defer { try? file.close() }
            var remaining = length
            while remaining > 0 {
                let chunk = try await body.read(maxLength: Int(min(81920, remaining)))
                if chunk.isEmpty { throw CompanionInboxError.endedEarly }
                try file.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        }
        let document = try CompanionPackage.read(contentsOf: part)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: part, to: final)
        guard record(deviceId: deviceId, packageId: packageId, pageCount: document.pages.count, now: now) else {
            try? FileManager.default.removeItem(at: final)
            throw CompanionInboxError.notSaved
        }
        return ReceivedPackage(deviceId: deviceId, packageId: packageId, url: final, document: document, target: target,
                               received: now)
    }

    /// Deletes a received package's file once its pages are in the queue; its log entry stays, so a
    /// retry is still a duplicate.
    public func release(_ package: ReceivedPackage) {
        CompanionInbox.tryDelete(package.url)
    }

    /// The packages received but not released (the app ended before adding them), oldest first, each
    /// read again; a file that no longer reads is deleted.
    public func pending() -> [ReceivedPackage] {
        var pending: [ReceivedPackage] = []
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        for folder in folders {
            let deviceId = folder.lastPathComponent
            guard CompanionProtocol.isValidId(deviceId),
                  let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == CompanionPackage.fileExtension {
                let packageId = file.deletingPathExtension().lastPathComponent
                guard CompanionProtocol.isValidId(packageId) else { continue }
                do {
                    let document = try CompanionPackage.read(contentsOf: file)
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    pending.append(ReceivedPackage(deviceId: deviceId, packageId: packageId, url: file, document: document,
                                                   target: .new, received: values?.contentModificationDate ?? Date.distantPast))
                } catch {
                    CompanionInbox.tryDelete(file)
                }
            }
        }
        pending.sort { $0.received < $1.received }
        return pending
    }

    /// Deletes everything received from `deviceId` (the phone was removed).
    public func removeDevice(_ deviceId: String) {
        guard CompanionProtocol.isValidId(deviceId) else { return }
        try? FileManager.default.removeItem(at: deviceFolder(deviceId))
    }

    /// Logs the package in the phone's received.json; false when that could not be saved.
    private func record(deviceId: String, packageId: String, pageCount: Int, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var log = self.log(deviceId)
        log.packages.removeAll { $0.packageId == packageId }
        var entry = ReceivedEntry()
        entry.packageId = packageId
        entry.pageCount = pageCount
        entry.received = now
        log.packages.append(entry)
        if log.packages.count > CompanionInbox.maxLoggedPackages {
            log.packages.removeFirst(log.packages.count - CompanionInbox.maxLoggedPackages)
        }
        return StoreFiles.write(log, to: logURL(deviceId))
    }

    private func deviceFolder(_ deviceId: String) -> URL {
        directory.appendingPathComponent(deviceId, isDirectory: true)
    }

    private func logURL(_ deviceId: String) -> URL {
        deviceFolder(deviceId).appendingPathComponent(CompanionInbox.logFileName)
    }

    /// The phone's received.json (with the lock held).
    private func log(_ deviceId: String) -> ReceivedLog {
        StoreFiles.load(ReceivedLog.self, from: logURL(deviceId)) ?? ReceivedLog()
    }

    private static func valid(_ deviceId: String, _ packageId: String) -> Bool {
        CompanionProtocol.isValidId(deviceId) && CompanionProtocol.isValidId(packageId)
    }

    private static func tryDelete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
