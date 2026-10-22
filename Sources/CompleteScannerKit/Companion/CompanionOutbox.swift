import Foundation

// Twin of windows/CompleteScanner.Core/Companion/CompanionOutbox.cs: what the desktop holds for each
// paired phone, served by GET /v1/outbox. Not PhoneOutbox (PhoneOutbox.swift), which is what a phone
// has still to send to its desktop.

/// A file waiting for a phone (an entry of a phone's outbox.json).
public struct OutboxEntry: Codable, Equatable, Sendable {
    public var id = ""
    public var name = ""
    public var contentType = ""
    public var byteCount: Int64 = 0
    public var created: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, contentType, byteCount, created
    }

    public init() {}
}

extension OutboxEntry {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        name = c.decodeLenient(forKey: .name, default: name)
        contentType = c.decodeLenient(forKey: .contentType, default: contentType)
        byteCount = c.decodeLenient(forKey: .byteCount, default: byteCount)
        created = c.decodeLenient(forKey: .created, default: created)
    }
}

/// The contents of a phone's outbox.json.
public struct OutboxIndex: Codable, Equatable, Sendable {
    public var items: [OutboxEntry] = []

    enum CodingKeys: String, CodingKey {
        case items
    }

    public init() {}
}

extension OutboxIndex {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        items = c.decodeLenient(forKey: .items, default: items)
    }
}

/// Why a file could not be put in a phone's outbox (besides the file system's errors).
public enum CompanionOutboxError: Error, Equatable, Sendable {
    /// The phone's id is not valid (`CompanionProtocol.isValidId`).
    case invalidId
    /// The phone's outbox.json could not be saved.
    case notSaved
}

/// What the desktop sends a phone: files copied into the phone's folder under the outbox folder
/// ("<id>.bin" plus outbox.json), listed and fetched by the phone and deleted when it acknowledges
/// them (`DELETE /v1/outbox/{id}`) or after `keepFor`. The phone pulls, since it cannot be reached
/// while its app is closed; a listing may wait (`wait`) until something arrives. Safe to use from any
/// thread.
public final class CompanionOutbox: @unchecked Sendable {
    public static let keepFor: TimeInterval = 7 * 24 * 60 * 60
    public static let indexFileName = "outbox.json"

    public let directory: URL
    private let lock = NSLock()
    /// The listings waiting per phone, by their token.
    private var waiters: [String: [Int: CheckedContinuation<Void, Never>]] = [:]
    /// Waits not over yet, and those of them woken before they were parked.
    private var active: Set<Int> = []
    private var woken: Set<Int> = []
    private var nextToken = 0

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default outbox: Application Support/CompleteScanner/Companion/Outbox.
    public static var defaultDirectory: URL {
        StoreFiles.defaultDirectory.appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    /// Copies `source` into the phone's outbox under `name` (its last path component).
    @discardableResult
    public func add(deviceId: String, source: URL, name: String, contentType: String, now: Date) throws -> OutboxItem {
        guard CompanionProtocol.isValidId(deviceId) else { throw CompanionOutboxError.invalidId }
        var generator = SystemRandomNumberGenerator()
        var id = ""
        for _ in 0..<16 {
            id += String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        let folder = directory.appendingPathComponent(deviceId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = fileURL(deviceId, id)
        try FileManager.default.copyItem(at: source, to: target)
        let size = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber
        var entry = OutboxEntry()
        entry.id = id
        entry.name = String(name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
        entry.contentType = contentType
        entry.byteCount = size?.int64Value ?? 0
        entry.created = now
        lock.lock()
        var index = self.index(deviceId)
        index.items.append(entry)
        guard StoreFiles.write(index, to: indexURL(deviceId)) else {
            lock.unlock()
            try? FileManager.default.removeItem(at: target)
            throw CompanionOutboxError.notSaved
        }
        let waiting = waiters.removeValue(forKey: deviceId) ?? [:]
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume()
        }
        return CompanionOutbox.item(entry)
    }

    /// What waits for the phone, oldest first; items past `keepFor` or without their file are dropped.
    public func list(deviceId: String, now: Date) -> [OutboxItem] {
        guard CompanionProtocol.isValidId(deviceId) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var index = self.index(deviceId)
        var kept: [OutboxEntry] = []
        for entry in index.items {
            let valid = CompanionProtocol.isValidId(entry.id)
            if valid, let created = entry.created, now.timeIntervalSince(created) <= CompanionOutbox.keepFor,
               FileManager.default.fileExists(atPath: fileURL(deviceId, entry.id).path) {
                kept.append(entry)
            } else if valid {
                try? FileManager.default.removeItem(at: fileURL(deviceId, entry.id))
            }
        }
        if kept.count != index.items.count {
            index.items = kept
            StoreFiles.write(index, to: indexURL(deviceId))
        }
        return kept.map(CompanionOutbox.item)
    }

    /// The item `id` and its file, open for reading, with the file's length; nil when there is none.
    public func open(deviceId: String, id: String) -> (item: OutboxItem, file: FileHandle, length: Int64)? {
        guard CompanionProtocol.isValidId(deviceId), CompanionProtocol.isValidId(id) else { return nil }
        lock.lock()
        let entry = index(deviceId).items.first { $0.id == id }
        lock.unlock()
        guard let entry, let file = try? FileHandle(forReadingFrom: fileURL(deviceId, id)) else { return nil }
        do {
            let length = try file.seekToEnd()
            try file.seek(toOffset: 0)
            return (CompanionOutbox.item(entry), file, Int64(length))
        } catch {
            try? file.close()
            return nil
        }
    }

    /// Deletes the item (the phone has it); false when there was none.
    @discardableResult
    public func remove(deviceId: String, id: String) -> Bool {
        guard CompanionProtocol.isValidId(deviceId), CompanionProtocol.isValidId(id) else { return false }
        lock.lock()
        var index = self.index(deviceId)
        let before = index.items.count
        index.items.removeAll { $0.id == id }
        guard index.items.count != before else {
            lock.unlock()
            return false
        }
        StoreFiles.write(index, to: indexURL(deviceId))
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL(deviceId, id))
        return true
    }

    /// Deletes the phone's outbox (it was removed); a listing waiting for it answers at once.
    public func removeDevice(_ deviceId: String) {
        guard CompanionProtocol.isValidId(deviceId) else { return }
        lock.lock()
        let waiting = waiters.removeValue(forKey: deviceId) ?? [:]
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(deviceId, isDirectory: true))
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume()
        }
    }

    /// Returns when something is added for the phone, after `timeout`, or when the task is cancelled.
    public func wait(deviceId: String, timeout: TimeInterval) async {
        guard CompanionProtocol.isValidId(deviceId) else { return }
        let token = begin()
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            } catch {
                return
            }
            self?.wake(deviceId, token: token)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.park(continuation, deviceId: deviceId, token: token)
            }
        } onCancel: {
            self.wake(deviceId, token: token)
        }
        timer.cancel()
        finish(token)
    }

    private func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        active.insert(nextToken)
        return nextToken
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>, deviceId: String, token: Int) {
        lock.lock()
        if woken.remove(token) != nil {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters[deviceId, default: [:]][token] = continuation
        lock.unlock()
    }

    private func wake(_ deviceId: String, token: Int) {
        lock.lock()
        let continuation = waiters[deviceId]?.removeValue(forKey: token)
        if continuation == nil && active.contains(token) { woken.insert(token) }
        lock.unlock()
        continuation?.resume()
    }

    private func finish(_ token: Int) {
        lock.lock()
        active.remove(token)
        woken.remove(token)
        lock.unlock()
    }

    private static func item(_ entry: OutboxEntry) -> OutboxItem {
        OutboxItem(id: entry.id, name: entry.name, contentType: entry.contentType, byteCount: Int(entry.byteCount),
                   created: entry.created ?? Date(timeIntervalSince1970: 0))
    }

    /// The phone's outbox.json (with the lock held).
    private func index(_ deviceId: String) -> OutboxIndex {
        StoreFiles.load(OutboxIndex.self, from: indexURL(deviceId)) ?? OutboxIndex()
    }

    private func indexURL(_ deviceId: String) -> URL {
        directory.appendingPathComponent(deviceId, isDirectory: true).appendingPathComponent(CompanionOutbox.indexFileName)
    }

    private func fileURL(_ deviceId: String, _ id: String) -> URL {
        directory.appendingPathComponent(deviceId, isDirectory: true).appendingPathComponent(id + ".bin")
    }
}
