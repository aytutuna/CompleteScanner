import Foundation

// Twin of windows/LazyScan.Core/ZipStoreReader.cs: the same checks, in the same order,
// with the same error kinds and messages.

/// Why `ZipStoreReader` refused an archive.
public enum ZipReadErrorKind: String, Equatable, Sendable {
    /// Not a zip, cut short, or its records disagree (gaps, overlaps, bad signatures, several disks).
    case corrupt
    /// An entry is compressed (Deflate or any other method): only stored entries are read.
    case unsupportedMethod
    /// An entry is encrypted (traditional, strong or AES encryption).
    case encrypted
    /// The archive or an entry uses ZIP64, which `ZipStore` never writes.
    case zip64
    /// An entry keeps its sizes in a data descriptor after its data.
    case dataDescriptor
    /// An entry's name could escape a folder or is not plain text (see `ZipStoreReader.isSafeName`).
    case unsafeName
    /// Two entries have the same name, ignoring case.
    case duplicateName
    /// An entry is marked as a link, device or other special file.
    case specialFile
    /// More entries than `ZipReadLimits.maxEntries`.
    case tooManyEntries
    /// An entry, all entries together, or the central directory are past their limit.
    case tooLarge
    /// An entry's sizes disagree with each other or with its local header (a zip bomb's trick).
    case sizeMismatch
    /// An entry's data does not match its CRC-32.
    case crcMismatch
}

/// An archive `ZipStoreReader` refuses: what is wrong, and the entry it is about.
public struct ZipReadError: LocalizedError, Equatable, Sendable {
    public let kind: ZipReadErrorKind
    public let message: String
    /// The entry the error is about, when it is about one.
    public let entryName: String?

    public init(_ kind: ZipReadErrorKind, entryName: String? = nil, limits: ZipReadLimits = .standard) {
        self.kind = kind
        self.entryName = entryName
        self.message = ZipStoreReader.message(kind, entryName: entryName, limits: limits)
    }

    public var errorDescription: String? { message }
}

/// The limits `ZipStoreReader` holds an archive to, checked from its directory before any entry is
/// read. `standard` suits scanned documents: 4096 entries, 256 MB per entry, 512 MB in all, names
/// of up to 255 bytes, a central directory of up to 64 MB.
public struct ZipReadLimits: Equatable, Sendable {
    public var maxEntries: Int
    public var maxEntryBytes: Int
    public var maxTotalBytes: Int
    public var maxNameBytes: Int
    /// The largest central directory read (`ZipStoreReader.maxCentralDirectoryBytes` by default).
    public var maxDirectoryBytes: Int

    public init(maxEntries: Int = 4096, maxEntryBytes: Int = 256 * 1024 * 1024,
                maxTotalBytes: Int = 512 * 1024 * 1024, maxNameBytes: Int = 255,
                maxDirectoryBytes: Int = ZipStoreReader.maxCentralDirectoryBytes) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxNameBytes = maxNameBytes
        self.maxDirectoryBytes = maxDirectoryBytes
    }

    public static let standard = ZipReadLimits()
}

/// One file in an archive `ZipStoreReader` opened: its name, its size and where its data is.
public struct ZipStoreReaderEntry: Equatable, Sendable {
    public let name: String
    public let size: Int
    public let crc32: UInt32
    /// Where its bytes start in the archive.
    public let dataOffset: Int
}

/// Reads the zip archives `ZipStore` writes, and archives of stored (uncompressed) entries from
/// other tools, refusing anything it cannot read safely with a `ZipReadError`. Opening checks the
/// whole directory and every local header: compressed, encrypted, ZIP64 and data-descriptor
/// entries, unsafe or duplicate names, links and special files, entries past the `ZipReadLimits`,
/// sizes that disagree, and entries that do not follow one another exactly from the start of the
/// archive to its directory (no gaps, no overlaps, nothing before or between them). Entries are
/// then read one at a time from the file or data, their CRC-32 checked; a file is never loaded
/// whole. Folder entries ("pages/") are checked and left out of `entries`. Not thread-safe.
public final class ZipStoreReader {
    /// The largest central directory read by default (64 MB; see `ZipReadLimits.maxDirectoryBytes`).
    public static let maxCentralDirectoryBytes = 64 * 1024 * 1024

    /// The archive's files in directory order, without folder entries.
    public let entries: [ZipStoreReaderEntry]

    private let source: ZipByteSource
    private let byName: [String: ZipStoreReaderEntry]

    private init(source: ZipByteSource, limits: ZipReadLimits) throws {
        self.source = source
        let entries = try ZipStoreReader.readDirectory(source, limits: limits)
        self.entries = entries
        var byName: [String: ZipStoreReaderEntry] = [:]
        for entry in entries { byName[entry.name] = entry }
        self.byName = byName
    }

    /// Opens the archive held in `data`.
    public convenience init(data: Data, limits: ZipReadLimits = .standard) throws {
        try self.init(source: ZipDataSource(data), limits: limits)
    }

    /// Opens the archive at `url`, read from the file as entries are read.
    public convenience init(contentsOf url: URL, limits: ZipReadLimits = .standard) throws {
        try self.init(source: try ZipFileSource(url), limits: limits)
    }

    deinit {
        source.close()
    }

    /// Closes the file behind the reader; later reads fail.
    public func close() {
        source.close()
    }

    /// Every file of the archive in `data` with its bytes, CRC-checked.
    public static func readAll(_ data: Data, limits: ZipReadLimits = .standard) throws -> [ZipStoreEntry] {
        let reader = try ZipStoreReader(data: data, limits: limits)
        return try reader.entries.map { ZipStoreEntry(name: $0.name, data: try reader.read($0)) }
    }

    /// The file named exactly `name` (the same UTF-8 bytes, as the C# twin compares ordinally;
    /// Swift `String` equality would also match a canonically equivalent name), or nil.
    public func entry(named name: String) -> ZipStoreReaderEntry? {
        guard let entry = byName[name], entry.name.utf8.elementsEqual(name.utf8) else { return nil }
        return entry
    }

    /// The bytes of `entry`, after checking their CRC-32.
    public func read(_ entry: ZipStoreReaderEntry) throws -> Data {
        var data = Data()
        data.reserveCapacity(entry.size)
        try copy(entry) { data.append($0) }
        return data
    }

    /// Hands the bytes of `entry` to `sink` a piece at a time and checks their CRC-32 at the end;
    /// when that throws, what was handed over must be discarded.
    public func copy(_ entry: ZipStoreReaderEntry, to sink: (Data) throws -> Void) throws {
        guard let own = byName[entry.name], own == entry else {
            preconditionFailure("The entry is not one of this archive's.")
        }
        var crc: UInt32 = 0xFFFF_FFFF
        var left = entry.size
        var offset = entry.dataOffset
        while left > 0 {
            let count = min(left, 81920)
            let chunk = try ZipStoreReader.read(source, at: offset, count: count)
            crc = ZipStoreReader.crc32Update(crc, chunk)
            try sink(Data(chunk))
            left -= count
            offset += count
        }
        if crc ^ 0xFFFF_FFFF != entry.crc32 { throw ZipReadError(.crcMismatch, entryName: entry.name) }
    }

    /// Whether `name` is safe as a path inside a folder: 1 to `maxNameBytes` bytes of UTF-8, no
    /// control characters (NUL included), no backslash or colon (so no drive letters or Windows
    /// streams), not starting with "/", and made of "/"-separated parts that are neither empty,
    /// "." nor "..", and do not end with a dot or a space (which Windows drops). A folder's name
    /// ends with one "/".
    ///
    /// The path checks work on the UTF-8 bytes, as the C# twin works on UTF-16 code units: a "/"
    /// followed by a combining mark, or preceded by a prepended mark, is one `Character` that is
    /// not "/", so a check on `Character`s would not see that separator.
    public static func isSafeName(_ name: String, maxNameBytes: Int = 255) -> Bool {
        let bytes = Array(name.utf8)
        if bytes.isEmpty || bytes.count > maxNameBytes { return false }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F || v == 0x5C || v == 0x3A { return false }
        }
        if bytes[0] == slash { return false }
        let path = bytes.last == slash ? bytes.dropLast() : bytes[...]
        for part in path.split(separator: slash, omittingEmptySubsequences: false) {
            if part.isEmpty || part.elementsEqual([dot]) || part.elementsEqual([dot, dot]) { return false }
            if part.last == dot || part.last == space { return false }
        }
        return true
    }

    /// Whether `name` is a folder's: its last byte is "/".
    static func isFolderName(_ name: String) -> Bool {
        name.utf8.last == slash
    }

    /// The form two names are compared in for `.duplicateName`.
    static func duplicateKey(_ name: String) -> String {
        let path = isFolderName(name) ? String(decoding: name.utf8.dropLast(), as: UTF8.self) : name
        return path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")
    private static let space = UInt8(ascii: " ")

    /// The most characters (Unicode scalars) of an entry name a message shows.
    public static let displayNameLimit = 80

    /// `name` made safe to show in a message: control characters (C0, DEL, C1), line and paragraph
    /// separators and the invisible marks that reorder text (U+061C, U+200E, U+200F, U+202A to
    /// U+202E, U+2066 to U+2069) become U+FFFD, and a name of more than `displayNameLimit` scalars
    /// is cut to that many followed by "…". The twin of C# `ZipStoreReader.DisplayName`.
    public static func displayName(_ name: String) -> String {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        let ellipsis: Unicode.Scalar = "\u{2026}"
        var shown = String.UnicodeScalarView()
        var count = 0
        for scalar in name.unicodeScalars {
            if count == displayNameLimit {
                shown.append(ellipsis)
                break
            }
            shown.append(isHiddenOrControl(scalar.value) ? replacement : scalar)
            count += 1
        }
        return String(shown)
    }

    private static func isHiddenOrControl(_ v: UInt32) -> Bool {
        v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x061C || v == 0x200E || v == 0x200F
            || (v >= 0x2028 && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
    }

    /// The message for `kind`; the twin of C# `ZipStoreReader.Message`. The entry name is shown
    /// through `displayName`.
    public static func message(_ kind: ZipReadErrorKind, entryName: String? = nil,
                               limits: ZipReadLimits = .standard) -> String {
        let name = "\"\(displayName(entryName ?? ""))\""
        switch kind {
        case .corrupt:
            return "The archive is damaged or cut short."
        case .unsupportedMethod:
            return "\(name) is compressed. Only archives of uncompressed (stored) entries can be read."
        case .encrypted:
            return "\(name) is encrypted. Encrypted archives cannot be read."
        case .zip64:
            return "The archive uses ZIP64 (for archives past 4 GB or 65,535 entries), which is not supported."
        case .dataDescriptor:
            return "\(name) keeps its sizes after its data (a data descriptor), which is not supported."
        case .unsafeName:
            return "The archive holds an entry with an unsafe name (\(name))."
        case .duplicateName:
            return "The archive holds \(name) more than once."
        case .specialFile:
            return "\(name) is a link or a special file, not a plain file."
        case .tooManyEntries:
            return "The archive holds more than \(limits.maxEntries) entries."
        case .tooLarge:
            return entryName == nil
                ? "The archive's contents are larger than \(limits.maxTotalBytes / (1024 * 1024)) MB."
                : "\(name) is larger than \(limits.maxEntryBytes / (1024 * 1024)) MB."
        case .sizeMismatch:
            return "\(name) declares sizes that do not match its data."
        case .crcMismatch:
            return "\(name) is damaged: its checksum does not match its data."
        }
    }

    // MARK: - Directory

    private static let localSignature: UInt32 = 0x0403_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let localHeaderSize = 30
    private static let centralRecordSize = 46
    private static let endRecordSize = 22
    private static let zip64LocatorSize = 20
    private static let zip64ExtraID: UInt16 = 0x0001
    private static let aesExtraID: UInt16 = 0x9901
    private static let flagEncrypted: UInt16 = 0x0001
    private static let flagDataDescriptor: UInt16 = 0x0008
    private static let flagStrongEncryption: UInt16 = 0x0040
    private static let flagMaskedHeader: UInt16 = 0x2000
    private static let methodStored: UInt16 = 0
    private static let methodAES: UInt16 = 99

    private struct Record {
        let name: String
        let nameBytes: [UInt8]
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let size: Int
        let localOffset: Int
        let isFolder: Bool
    }

    private static func readDirectory(_ source: ZipByteSource, limits: ZipReadLimits) throws -> [ZipStoreReaderEntry] {
        let length = source.length
        if length < endRecordSize { throw ZipReadError(.corrupt) }

        // The end record: the last signature whose comment ends exactly at the end of the file.
        let tail = min(length, endRecordSize + Int(UInt16.max))
        let end = try read(source, at: length - tail, count: tail)
        var at = -1
        var i = tail - endRecordSize
        while i >= 0 {
            if u32(end, i) == endSignature && i + endRecordSize + Int(u16(end, i + 20)) == tail {
                at = i
                break
            }
            i -= 1
        }
        if at < 0 { throw ZipReadError(.corrupt) }
        let endOffset = length - tail + at
        if endOffset >= zip64LocatorSize {
            let locator = try read(source, at: endOffset - zip64LocatorSize, count: 4)
            if u32(locator, 0) == zip64LocatorSignature { throw ZipReadError(.zip64) }
        }
        let disk = u16(end, at + 4), directoryDisk = u16(end, at + 6)
        let onDisk = u16(end, at + 8), count = u16(end, at + 10)
        let directorySize = u32(end, at + 12), directoryOffset32 = u32(end, at + 16)
        if disk == 0xFFFF || directoryDisk == 0xFFFF || onDisk == 0xFFFF || count == 0xFFFF
            || directorySize == 0xFFFF_FFFF || directoryOffset32 == 0xFFFF_FFFF {
            throw ZipReadError(.zip64)
        }
        if disk != 0 || directoryDisk != 0 || onDisk != count { throw ZipReadError(.corrupt) }
        if Int(count) > limits.maxEntries { throw ZipReadError(.tooManyEntries, limits: limits) }
        let directoryOffset = Int(directoryOffset32)
        if directoryOffset + Int(directorySize) != endOffset { throw ZipReadError(.corrupt) }
        if Int(directorySize) > limits.maxDirectoryBytes { throw ZipReadError(.tooLarge, limits: limits) }
        if Int(directorySize) < Int(count) * centralRecordSize { throw ZipReadError(.corrupt) }

        let directory = try read(source, at: directoryOffset, count: Int(directorySize))
        var records: [Record] = []
        records.reserveCapacity(Int(count))
        var seen = Set<String>()
        var total = 0
        var p = 0
        for _ in 0..<Int(count) {
            if p + centralRecordSize > directory.count || u32(directory, p) != centralSignature {
                throw ZipReadError(.corrupt)
            }
            let madeBy = u16(directory, p + 4)
            let flags = u16(directory, p + 8), method = u16(directory, p + 10)
            let crc = u32(directory, p + 16), compressed = u32(directory, p + 20), size = u32(directory, p + 24)
            let nameLength = Int(u16(directory, p + 28)), extraLength = Int(u16(directory, p + 30))
            let commentLength = Int(u16(directory, p + 32))
            let startDisk = u16(directory, p + 34)
            let external = u32(directory, p + 38), localOffset = u32(directory, p + 42)
            let next = p + centralRecordSize + nameLength + extraLength + commentLength
            if next > directory.count { throw ZipReadError(.corrupt) }
            let nameBytes = Array(directory[(p + centralRecordSize)..<(p + centralRecordSize + nameLength)])
            let shownName = String(decoding: nameBytes, as: UTF8.self)
            let extraStart = p + centralRecordSize + nameLength
            let extras = try extraIDs(Array(directory[extraStart..<(extraStart + extraLength)]))

            if flags & (flagEncrypted | flagStrongEncryption | flagMaskedHeader) != 0 || method == methodAES
                || extras.contains(aesExtraID) {
                throw ZipReadError(.encrypted, entryName: shownName)
            }
            if flags & flagDataDescriptor != 0 { throw ZipReadError(.dataDescriptor, entryName: shownName) }
            if extras.contains(zip64ExtraID) || compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF || startDisk == 0xFFFF {
                throw ZipReadError(.zip64, entryName: shownName)
            }
            if method != methodStored { throw ZipReadError(.unsupportedMethod, entryName: shownName) }
            if compressed != size { throw ZipReadError(.sizeMismatch, entryName: shownName) }
            if startDisk != 0 { throw ZipReadError(.corrupt, entryName: shownName) }

            guard let name = decodeName(nameBytes), nameBytes.count <= limits.maxNameBytes,
                  isSafeName(name, maxNameBytes: limits.maxNameBytes) else {
                throw ZipReadError(.unsafeName, entryName: shownName)
            }
            let folder = isFolderName(name)
            if isSpecial(madeBy: madeBy, external: external, folder: folder) {
                throw ZipReadError(.specialFile, entryName: name)
            }
            if folder && size != 0 { throw ZipReadError(.sizeMismatch, entryName: name) }
            if !seen.insert(duplicateKey(name)).inserted { throw ZipReadError(.duplicateName, entryName: name) }
            if Int(size) > limits.maxEntryBytes { throw ZipReadError(.tooLarge, entryName: name, limits: limits) }
            total += Int(size)
            if total > limits.maxTotalBytes { throw ZipReadError(.tooLarge, limits: limits) }

            records.append(Record(name: name, nameBytes: nameBytes, flags: flags, method: method, crc: crc,
                                  size: Int(size), localOffset: Int(localOffset), isFolder: folder))
            p = next
        }
        if p != directory.count { throw ZipReadError(.corrupt) }

        // The local headers: each agrees with its record, and the entries follow one another
        // from the start of the archive to its directory.
        var dataOffsets = [Int](repeating: 0, count: records.count)
        var expected = 0
        let order = records.indices.sorted { a, b in
            records[a].localOffset != records[b].localOffset ? records[a].localOffset < records[b].localOffset : a < b
        }
        for index in order {
            let record = records[index]
            if record.localOffset != expected { throw ZipReadError(.corrupt, entryName: record.name) }
            if record.localOffset + localHeaderSize > directoryOffset { throw ZipReadError(.corrupt, entryName: record.name) }
            let header = try read(source, at: record.localOffset, count: localHeaderSize)
            if u32(header, 0) != localSignature { throw ZipReadError(.corrupt, entryName: record.name) }
            let flags = u16(header, 6), method = u16(header, 8)
            let crc = u32(header, 14), compressed = u32(header, 18), size = u32(header, 22)
            let nameLength = Int(u16(header, 26)), extraLength = Int(u16(header, 28))
            let dataOffset = record.localOffset + localHeaderSize + nameLength + extraLength
            if dataOffset > directoryOffset { throw ZipReadError(.corrupt, entryName: record.name) }
            let nameAndExtra = try read(source, at: record.localOffset + localHeaderSize, count: nameLength + extraLength)
            let extras = try extraIDs(Array(nameAndExtra[nameLength..<(nameLength + extraLength)]))
            if extras.contains(aesExtraID) { throw ZipReadError(.encrypted, entryName: record.name) }
            if extras.contains(zip64ExtraID) { throw ZipReadError(.zip64, entryName: record.name) }
            if Int(compressed) != record.size || Int(size) != record.size {
                throw ZipReadError(.sizeMismatch, entryName: record.name)
            }
            if flags != record.flags || method != record.method || crc != record.crc
                || Array(nameAndExtra[0..<nameLength]) != record.nameBytes {
                throw ZipReadError(.corrupt, entryName: record.name)
            }
            expected = dataOffset + record.size
            if expected > directoryOffset { throw ZipReadError(.sizeMismatch, entryName: record.name) }
            dataOffsets[index] = dataOffset
        }
        if expected != directoryOffset { throw ZipReadError(.corrupt) }
        return records.indices.filter { !records[$0].isFolder }.map { index in
            let record = records[index]
            return ZipStoreReaderEntry(name: record.name, size: record.size, crc32: record.crc,
                                       dataOffset: dataOffsets[index])
        }
    }

    /// Whether the external attributes mark a link, device or other special file: a Unix file type
    /// other than a regular file or a folder (or a folder type on a file name), or MS-DOS attributes
    /// for a folder on a file name, a reparse point (Windows links) or a device.
    private static func isSpecial(madeBy: UInt16, external: UInt32, folder: Bool) -> Bool {
        let host = madeBy >> 8
        if host == 3 || host == 19 {
            let type = (external >> 16) & 0xF000
            if type != 0 && type != 0x8000 && type != 0x4000 { return true }
            if type == 0x4000 && !folder { return true }
            if type == 0x8000 && folder { return true }
        }
        if external & 0x10 != 0 && !folder { return true }
        return external & (0x400 | 0x40) != 0
    }

    /// The ids of an extra field's blocks; a field whose blocks do not add up is corrupt.
    private static func extraIDs(_ extra: [UInt8]) throws -> Set<UInt16> {
        var ids = Set<UInt16>()
        var p = 0
        while p < extra.count {
            if p + 4 > extra.count { throw ZipReadError(.corrupt) }
            let id = UInt16(extra[p]) | UInt16(extra[p + 1]) << 8
            let size = Int(extra[p + 2]) | Int(extra[p + 3]) << 8
            if p + 4 + size > extra.count { throw ZipReadError(.corrupt) }
            ids.insert(id)
            p += 4 + size
        }
        return ids
    }

    /// The name as strict UTF-8 (ASCII included); nil when it is not valid UTF-8 (the decoder
    /// replaces bad sequences, so the text no longer encodes to the same bytes).
    private static func decodeName(_ bytes: [UInt8]) -> String? {
        let name = String(decoding: bytes, as: UTF8.self)
        return Array(name.utf8) == bytes ? name : nil
    }

    private static func read(_ source: ZipByteSource, at offset: Int, count: Int) throws -> [UInt8] {
        if offset < 0 || count < 0 || offset + count > source.length { throw ZipReadError(.corrupt) }
        let bytes = try source.read(at: offset, count: count)
        if bytes.count != count { throw ZipReadError(.corrupt) }
        return bytes
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func crc32Update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var crc = crc
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc
    }
}

// MARK: - Byte sources

/// Random access to an archive's bytes: in memory or from a file.
private protocol ZipByteSource: AnyObject {
    var length: Int { get }
    func read(at offset: Int, count: Int) throws -> [UInt8]
    func close()
}

private final class ZipDataSource: ZipByteSource {
    private let data: Data

    /// `data` may be a slice: offsets count from its `startIndex`.
    init(_ data: Data) {
        self.data = data
    }

    var length: Int { data.count }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        let start = data.startIndex + offset
        return [UInt8](data[start..<(start + count)])
    }

    func close() {}
}

private final class ZipFileSource: ZipByteSource {
    private var handle: FileHandle?
    let length: Int

    init(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
        self.length = Int(clamping: end)
    }

    deinit {
        close()
    }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        guard let handle else { throw ZipReadError(.corrupt) }
        if count == 0 { return [] }
        try handle.seek(toOffset: UInt64(offset))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else { break }
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
