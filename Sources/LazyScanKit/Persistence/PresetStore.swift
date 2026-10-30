import Foundation
import os

// MARK: - PresetStore

public final class PresetStore {
    private let directory: URL

    public init() {
        directory = StoreFiles.defaultDirectory
    }

    /// Stores `presets.json` in `directory` instead of Application Support (tests).
    init(directory: URL) {
        self.directory = directory
    }

    private var presetsURL: URL { StoreFiles.presetsURL(in: directory) }

    /// Loads saved presets; on first run returns (and persists) an empty list.
    /// A presets file that does not decode is moved aside as
    /// `presets.unreadable-<yyyyMMdd-HHmmss>.json` before the empty list is written.
    /// A presets file that cannot be read at all (permissions, I/O) is left in place:
    /// an empty list is returned without saving and writes to it are refused for the
    /// session, so the user's file is never overwritten.
    public func load() -> [Preset] {
        switch StoreFiles.read([Preset].self, from: presetsURL) {
        case .loaded(let presets):
            return presets
        case .missing:
            break
        case .corrupt(let error):
            StoreFiles.keepUnreadable(presetsURL, error: error)
        case .inaccessible(let error):
            StoreFiles.leaveInaccessible(presetsURL, error: error)
            return PresetStore.builtInPresets()
        }
        let builtIns = PresetStore.builtInPresets()
        save(builtIns)
        return builtIns
    }

    public func save(_ presets: [Preset]) {
        StoreFiles.write(presets, to: presetsURL)
    }

    // MARK: First run

    /// What a first run starts with: no presets. The start screen's task cards replaced the
    /// five starter presets earlier versions wrote here; files that already hold them keep
    /// them, like any other saved preset.
    private static func builtInPresets() -> [Preset] {
        []
    }
}

// MARK: - SettingsStore

public enum SettingsStore {
    /// nil when there are no saved settings yet, or the file could not be loaded. A file
    /// that does not decode is moved aside as `settings.unreadable-<yyyyMMdd-HHmmss>.json`;
    /// a file that cannot be read at all is left in place and not overwritten this session.
    public static func load() -> ScanSettings? {
        load(directory: StoreFiles.defaultDirectory)
    }

    public static func save(_ settings: ScanSettings) {
        save(settings, directory: StoreFiles.defaultDirectory)
    }

    /// Same as `load()`, reading `settings.json` from `directory` (tests).
    static func load(directory: URL) -> ScanSettings? {
        let url = StoreFiles.settingsURL(in: directory)
        switch StoreFiles.read(ScanSettings.self, from: url) {
        case .loaded(let settings):
            return settings
        case .missing:
            return nil
        case .corrupt(let error):
            StoreFiles.keepUnreadable(url, error: error)
            return nil
        case .inaccessible(let error):
            StoreFiles.leaveInaccessible(url, error: error)
            return nil
        }
    }

    /// Same as `save(_:)`, writing `settings.json` into `directory` (tests).
    static func save(_ settings: ScanSettings, directory: URL) {
        StoreFiles.write(settings, to: StoreFiles.settingsURL(in: directory))
    }
}

// MARK: - Shared file plumbing

private let storeLog = Logger(subsystem: "LazyScan", category: "Persistence")

enum StoreReadResult<Value> {
    /// No file yet (first run).
    case missing
    /// The file was read but its contents do not decode; it is safe to move aside.
    case corrupt(Error)
    /// The file could not be read (permissions, I/O, not a regular file). Its contents
    /// may be perfectly valid, so it is left where it is.
    case inaccessible(Error)
    case loaded(Value)
}

/// Files that could not be read, or did not decode and could not be moved aside; writes to
/// them are refused for the rest of the session so the original is never overwritten.
private final class ProtectedFiles: @unchecked Sendable {
    static let shared = ProtectedFiles()

    private let lock = NSLock()
    private var paths: Set<String> = []

    func protect(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        paths.insert(url.standardizedFileURL.path)
    }

    func isProtected(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(url.standardizedFileURL.path)
    }
}

/// JSON storage under `~/Library/Application Support/Lazy Scan/` (created on demand). Also used
/// by the phone link's files (`PairedDeviceStore`), which follow the same settings-file rules.
enum StoreFiles {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Lazy Scan", isDirectory: true)
    }

    static func presetsURL(in directory: URL) -> URL { directory.appendingPathComponent("presets.json") }
    static func settingsURL(in directory: URL) -> URL { directory.appendingPathComponent("settings.json") }

    /// Distinguishes "no file yet", "file cannot be read" and "file read but does not decode".
    /// There is no separate existence check, so a file removed just before the read is
    /// reported as missing rather than as a read failure.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> StoreReadResult<T> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return isNoSuchFile(error) ? .missing : .inaccessible(error)
        }
        do {
            return .loaded(try JSONDecoder().decode(type, from: utf8JSON(data)))
        } catch {
            return .corrupt(error)
        }
    }

    /// The file's value under the settings-file rules, as C# `StoreFiles.Load`: nil when there is no
    /// file, or it could not be read (left in place and protected from writes for the session), or it
    /// did not decode (moved aside first).
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        switch read(type, from: url) {
        case .loaded(let value):
            return value
        case .missing:
            return nil
        case .corrupt(let error):
            keepUnreadable(url, error: error)
            return nil
        case .inaccessible(let error):
            leaveInaccessible(url, error: error)
            return nil
        }
    }

    /// The text encodings a settings file may be in.
    enum TextEncoding: Equatable {
        case utf8
        case utf16(bigEndian: Bool)
        case utf32(bigEndian: Bool)
    }

    /// A settings file's text that does not decode: invalid in its encoding, or JSON that the C#
    /// twin's reader refuses although JSONDecoder may take it.
    struct TextError: Error, CustomStringConvertible {
        let description: String
    }

    /// The encoding of a settings file, as C# `StoreFiles.DetectEncoding` determines it: a leading
    /// UTF-8, UTF-32 or UTF-16 byte-order mark wins; without one, the pattern of zero bytes around
    /// the first (always ASCII) JSON character identifies UTF-32 or UTF-16, and anything else is
    /// UTF-8. Also returns the length of the byte-order mark. Done here rather than left to
    /// JSONDecoder, whose own detection differs between Foundation versions (macOS 15's takes a
    /// UTF-32LE byte-order mark for UTF-16LE).
    static func detectEncoding(_ b: [UInt8]) -> (encoding: TextEncoding, bomLength: Int) {
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32(bigEndian: true), 4) }
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32(bigEndian: false), 4) }
        if b.starts(with: [0xFE, 0xFF]) { return (.utf16(bigEndian: true), 2) }
        if b.starts(with: [0xFF, 0xFE]) { return (.utf16(bigEndian: false), 2) }
        if b.count >= 4 {
            let z0 = b[0] == 0
            let z1 = b[1] == 0
            let z2 = b[2] == 0
            let z3 = b[3] == 0
            if z0 && z1 && z2 { return (.utf32(bigEndian: true), 0) }
            if z1 && z2 && z3 { return (.utf32(bigEndian: false), 0) }
            if z0 && z2 { return (.utf16(bigEndian: true), 0) }
            if z1 && z3 { return (.utf16(bigEndian: false), 0) }
            return (.utf8, 0)
        }
        if b.count >= 2 {
            if b[0] == 0 { return (.utf16(bigEndian: true), 0) }
            if b[1] == 0 { return (.utf16(bigEndian: false), 0) }
        }
        return (.utf8, 0)
    }

    /// A settings file's JSON as UTF-8 for JSONDecoder, read the way the C# twin reads it
    /// (`StoreFiles.Decode`): in the encoding `detectEncoding` finds, without its byte-order mark;
    /// text that is not valid in that encoding, or JSON with a comma before a closing bracket or
    /// brace (which JSONDecoder takes and System.Text.Json refuses), does not decode.
    static func utf8JSON(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let (encoding, bomLength) = detectEncoding(bytes)
        let body = Array(bytes[bomLength...])
        let utf8: [UInt8]?
        switch encoding {
        case .utf8:
            utf8 = transcoded(body, from: Unicode.UTF8.self)
        case .utf16(let bigEndian):
            utf8 = codeUnits16(body, bigEndian: bigEndian).flatMap { transcoded($0, from: Unicode.UTF16.self) }
        case .utf32(let bigEndian):
            utf8 = codeUnits32(body, bigEndian: bigEndian).flatMap { transcoded($0, from: Unicode.UTF32.self) }
        }
        guard let utf8 else { throw TextError(description: "The file is not valid \(encoding).") }
        if hasTrailingComma(utf8) { throw TextError(description: "The file has a comma before a closing bracket.") }
        return Data(utf8)
    }

    /// `units` as UTF-8; nil when they are not valid in `encoding`.
    private static func transcoded<E: Unicode.Encoding>(_ units: [E.CodeUnit], from encoding: E.Type) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(units.count)
        let failed = transcode(units.makeIterator(), from: encoding, to: Unicode.UTF8.self, stoppingOnError: true) {
            out.append($0)
        }
        return failed ? nil : out
    }

    private static func codeUnits16(_ bytes: [UInt8], bigEndian: Bool) -> [UInt16]? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            let first = UInt16(bytes[i])
            let second = UInt16(bytes[i + 1])
            units.append(bigEndian ? (first << 8) | second : (second << 8) | first)
            i += 2
        }
        return units
    }

    private static func codeUnits32(_ bytes: [UInt8], bigEndian: Bool) -> [UInt32]? {
        guard bytes.count % 4 == 0 else { return nil }
        var units: [UInt32] = []
        units.reserveCapacity(bytes.count / 4)
        var i = 0
        while i < bytes.count {
            var value: UInt32 = 0
            for k in 0..<4 {
                let byte = UInt32(bytes[bigEndian ? i + k : i + 3 - k])
                value = (value << 8) | byte
            }
            units.append(value)
            i += 4
        }
        return units
    }

    /// Whether UTF-8 JSON has a comma (outside strings) right before a `]` or `}`, whitespace aside.
    static func hasTrailingComma(_ json: [UInt8]) -> Bool {
        var inString = false
        var escaped = false
        var last: UInt8 = 0
        for byte in json {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                last = byte
                continue
            }
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if last == UInt8(ascii: ",") { return true }
            default:
                break
            }
            last = byte
        }
        return false
    }

    /// True when `error` (or an error it wraps) means the file does not exist.
    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        let missingCodes = [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue]
        if nsError.domain == NSCocoaErrorDomain, missingCodes.contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNoSuchFile(underlying)
        }
        return false
    }

    /// Leaves a file that could not be read where it is and refuses further writes to it
    /// for the rest of the session, so a transient failure never replaces valid contents.
    static func leaveInaccessible(_ url: URL, error: Error) {
        ProtectedFiles.shared.protect(url)
        let message = "Could not read \(url.lastPathComponent) (\(error)); "
            + "left it in place and will not overwrite it this session"
        storeLog.error("\(message, privacy: .public)")
    }

    /// Moves a file that does not decode aside to `<name>.unreadable-<yyyyMMdd-HHmmss>.json`
    /// in the same folder. When it cannot be moved, further writes to `url` are refused
    /// instead, unless the move failed because the file is already gone.
    static func keepUnreadable(_ url: URL, error: Error) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(url.deletingPathExtension().lastPathComponent).unreadable-\(formatter.string(from: Date()))"
        let folder = url.deletingLastPathComponent()
        var target = folder.appendingPathComponent("\(stem).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)-\(suffix).json")
            suffix += 1
        }
        let problem = "Could not decode \(url.lastPathComponent) (\(error))"
        do {
            try FileManager.default.moveItem(at: url, to: target)
            let message = "\(problem); kept it as \(target.lastPathComponent)"
            storeLog.error("\(message, privacy: .public)")
        } catch let moveError where isNoSuchFile(moveError) {
            let message = "\(problem); it was removed before it could be kept (\(moveError))"
            storeLog.error("\(message, privacy: .public)")
        } catch let moveError {
            ProtectedFiles.shared.protect(url)
            let message = "\(problem) and could not move it aside (\(moveError)); it will not be overwritten"
            storeLog.fault("\(message, privacy: .public)")
        }
    }

    /// Best-effort atomic write; creates the directory on demand. Refuses to replace a file
    /// that could not be read, or that did not decode and could not be moved aside. Returns
    /// whether the file was written.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard !ProtectedFiles.shared.isProtected(url) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
