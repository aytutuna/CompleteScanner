import Foundation

// What the phone has still to send to its desktop. Not the twin of the desktop's CompanionOutbox
// (windows/CompleteScanner.Core/Companion/CompanionOutbox.cs, what the desktop holds for a phone),
// whose Swift twin comes with the Mac's server under that name.

extension CompanionTarget: Codable {}

/// A document waiting to be sent (an entry of outbox.json).
public struct PhoneOutboxItem: Codable, Equatable, Sendable {
    /// The package id the desktop receives it under (`PUT /v1/inbox/{id}`), so sending it again is
    /// harmless.
    public var id = ""
    /// The package's file in the outbox folder ("Scan 12.csdoc").
    public var fileName = ""
    /// The desktop it was sent to (`PairedDesktop.id`); no other desktop gets it.
    public var desktopId = ""
    public var target = CompanionTarget.new
    public var created: Date?
    /// How often sending it failed.
    public var attempts = 0
    /// Why it failed last; "" when it has not.
    public var lastError = ""

    enum CodingKeys: String, CodingKey {
        case id, fileName, desktopId, target, created, attempts, lastError
    }

    public init() {}
}

extension PhoneOutboxItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        fileName = c.decodeLenient(forKey: .fileName, default: fileName)
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        target = c.decodeLenient(forKey: .target, default: target)
        created = c.decodeLenient(forKey: .created, default: created)
        attempts = c.decodeLenient(forKey: .attempts, default: attempts)
        lastError = c.decodeLenient(forKey: .lastError, default: lastError)
    }
}

/// The contents of outbox.json.
public struct PhoneOutboxFile: Codable, Equatable, Sendable {
    public var items: [PhoneOutboxItem] = []

    enum CodingKeys: String, CodingKey {
        case items
    }

    public init() {}
}

extension PhoneOutboxFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        items = c.decodeLenient(forKey: .items, default: items)
    }
}

/// Why a document could not be queued for sending.
public enum PhoneOutboxError: Error, Equatable, LocalizedError, Sendable {
    /// `PhoneOutbox.maxItems` documents wait already.
    case full

    public var errorDescription: String? { CompanionText.outboxFullMessage }
}

/// The documents waiting to be sent to the paired desktop, oldest first: a folder of `.csdoc` files
/// and outbox.json listing them (rule 6). A document stays until the desktop has it (201, or 200 for
/// one it had already) or the user removes it, across launches; entries whose file went are dropped
/// when the folder is opened. Safe to use from any thread.
public final class PhoneOutbox: @unchecked Sendable {
    public static let fileName = "outbox.json"
    public static let maxItems = 50

    public let directory: URL
    private let url: URL
    private let lock = NSLock()
    private var file: PhoneOutboxFile

    public init(directory: URL) {
        self.directory = directory
        url = directory.appendingPathComponent(PhoneOutbox.fileName)
        file = StoreFiles.load(PhoneOutboxFile.self, from: url) ?? PhoneOutboxFile()
        let before = file.items.count
        file.items.removeAll {
            !CompanionProtocol.isValidId($0.id) || $0.fileName.isEmpty
                || !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path)
        }
        if file.items.count != before { StoreFiles.write(file, to: url) }
    }

    public var items: [PhoneOutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        return file.items
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return file.items.count
    }

    public func fileURL(of item: PhoneOutboxItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    /// Queues the package at `package` for the desktop `desktopId`, moved into the outbox folder unless it
    /// is there already, under a new package id. Throws `PhoneOutboxError.full`, or the file system's error.
    @discardableResult
    public func enqueue(_ package: URL, target: CompanionTarget, desktopId: String,
                        now: Date = Date()) throws -> PhoneOutboxItem {
        lock.lock()
        defer { lock.unlock() }
        guard file.items.count < PhoneOutbox.maxItems else { throw PhoneOutboxError.full }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent(package.lastPathComponent)
        if destination.resolvingSymlinksInPath().path != package.resolvingSymlinksInPath().path {
            destination = NamingTemplate.uniqueURL(in: directory, base: package.deletingPathExtension().lastPathComponent,
                                                   fileExtension: CompanionPackage.fileExtension)
            try FileManager.default.moveItem(at: package, to: destination)
        }
        var item = PhoneOutboxItem()
        item.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        item.fileName = destination.lastPathComponent
        item.desktopId = desktopId
        item.target = target
        item.created = now
        file.items.append(item)
        StoreFiles.write(file, to: url)
        return item
    }

    /// The oldest waiting document not in `excluding` (those tried already in this round).
    public func next(excluding: Set<String> = []) -> PhoneOutboxItem? {
        lock.lock()
        defer { lock.unlock() }
        return file.items.first { !excluding.contains($0.id) }
    }

    /// The desktop has it: its file and entry go.
    public func markSent(_ id: String) {
        remove(id)
    }

    /// Counts a failed attempt and keeps why.
    public func markFailed(_ id: String, error: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { return }
        file.items[index].attempts += 1
        file.items[index].lastError = error
        StoreFiles.write(file, to: url)
    }

    /// Takes a document out unsent (the user removed it), with its file.
    public func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.items[index].fileName))
        file.items.remove(at: index)
        StoreFiles.write(file, to: url)
    }
}
