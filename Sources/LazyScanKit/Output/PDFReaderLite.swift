import Foundation

// Twin of windows/LazyScan.Core/PdfReaderLite.cs: the same cross-reference layouts, limits,
// page tree walk and facts, with the same refusals and error texts. A file is opened with a
// FileHandle and read through `PDFStreamBytes` where C# takes a Stream; a source the caller owns is
// a read closure, which the reader never closes. The XMP is read with Foundation's XMLParser where
// C# uses XDocument, taking the same pdfaid values in the same order. The facts read when asked
// (`isSigned` and the rest) throw where C#'s properties do.

/// Just enough of a PDF reader to add pages to an existing file: the cross-reference data — classic
/// tables and cross-reference streams (with their PNG predictors), every earlier revision through
/// /Prev, the hybrid files' /XRefStm — objects stored on their own or inside object streams, the
/// trailer, the catalog and the page tree, and a few facts about the file (encrypted, signed,
/// PDF/A). It reads the bytes where the cross-reference data says objects are and refuses a file
/// whose data does not hold up (`PDFReadError`): it never guesses or repairs. Page contents, fonts
/// and images are never read.
public final class PDFReaderLite {
    /// Longest /Prev chain followed (a loop is caught before that).
    private static let maxSections = 4096
    /// Deepest page tree walked (a cycle is caught before that).
    private static let maxTreeDepth = 256
    /// The highest object number a PDF may use (ISO 32000-1 Annex C): a file whose cross-reference
    /// data goes past it is refused, and an update never numbers an object above it.
    static let maxObjectNumber = 8_388_607

    private enum EntryKind { case free, inUse, compressed }

    /// One cross-reference entry: in use at an offset, in an object stream at an index, or free.
    private struct Entry {
        var kind: EntryKind
        var offset = 0
        var generation = 0
        var streamNumber = 0
        var index = 0
    }

    private let bytes: any PDFBytes
    private var handle: FileHandle?
    private var entries: [Int: Entry] = [:]
    private var objects: [Int: any PDFObject] = [:]
    private var objectStreams: [Int: (data: [UInt8], offsets: [Int: Int])] = [:]
    private var resolving: Set<Int> = []
    private var pageList: [PDFReference]?
    private var pdfA: (part: Int?, conformance: String?)?

    /// Opens `path` for reading; the file stays open until `close()` or the reader goes away.
    public static func open(path: String) throws -> PDFReaderLite {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let bytes: PDFStreamBytes
        do {
            bytes = try PDFStreamBytes(handle)
        } catch {
            try? handle.close()
            throw error
        }
        return try PDFReaderLite(bytes: bytes, handle: handle)
    }

    /// A PDF in memory.
    public convenience init(data: Data) throws {
        try self.init(bytes: PDFArrayBytes([UInt8](data)), handle: nil)
    }

    /// A PDF of `length` bytes read a block at a time through `read`, which gives `count` bytes from
    /// `offset`; whatever `read` reads from stays the caller's to close.
    public convenience init(length: Int, read: @escaping (_ offset: Int, _ count: Int) throws -> [UInt8]) throws {
        try self.init(bytes: PDFStreamBytes(length: length, read: read), handle: nil)
    }

    private init(bytes: any PDFBytes, handle: FileHandle?) throws {
        self.bytes = bytes
        self.handle = handle
        do {
            try load()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    /// Closes the file `open(path:)` opened; nothing to do for the other sources.
    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func load() throws {
        version = try readHeader()
        startXref = try findStartXref()
        try loadCrossReferences()
        if let encrypt = trailer["Encrypt"], !(encrypt is PDFNull) {
            isEncrypted = true
            return // nothing else can be read without the key
        }
        guard let root = trailer["Root"] as? PDFReference else {
            throw PDFReadError.damaged("The trailer names no catalog (/Root).")
        }
        self.root = root
        guard let catalog = try resolve(root) as? PDFDictionary else {
            throw PDFReadError.damaged("The catalog is not a dictionary.")
        }
        self.catalog = catalog
        guard let pages = catalog["Pages"] as? PDFReference else {
            throw PDFReadError.damaged("The catalog has no page tree (/Pages).")
        }
        pagesRoot = pages
        guard let pagesDictionary = try resolve(pages) as? PDFDictionary else {
            throw PDFReadError.damaged("The page tree's root is not a dictionary.")
        }
        pagesRootDictionary = pagesDictionary
        // New pages are added to the root's /Kids: a root that is a page itself has none.
        if !(try resolve(pagesDictionary["Kids"]) is PDFArray) {
            throw PDFReadError.damaged("The page tree's root has no /Kids.")
        }
        pageList = try walkPageTree(pages)
    }

    // MARK: - What the file is

    /// The bytes in the file; an update starts after them.
    public var length: Int { bytes.length }

    /// The header's version, "1.4" in "%PDF-1.4".
    public private(set) var version = ""

    /// Where the newest cross-reference section starts (the last "startxref" value).
    public private(set) var startXref = 0

    /// The newest section is a cross-reference stream, so an update writes one too.
    public private(set) var xrefIsStream = false

    /// Where the newest section's /Prev points (the section before it); nil for a file never updated.
    public private(set) var latestPrev: Int?

    /// Some section is a classic table that also points at a cross-reference stream (/XRefStm).
    public private(set) var isHybrid = false

    /// Cross-reference sections read: 1 for a file never updated, one more per incremental update.
    public private(set) var sectionCount = 0

    /// Some objects are stored inside object streams.
    public var hasObjectStreams: Bool {
        entries.values.contains { $0.kind == .compressed }
    }

    /// The file has an /Encrypt dictionary; nothing past the trailer is read then.
    public private(set) var isEncrypted = false

    /// The first object number an update can use: the trailer's /Size, or one past the highest
    /// number any section lists when that is higher.
    public private(set) var nextObjectNumber = 0

    /// The pages in reading order; 0 for an encrypted file.
    public var pageCount: Int { pageList?.count ?? 0 }

    /// The file is signed: its form says signatures exist (/SigFlags bit 1) or the catalog carries
    /// signature permissions (/Perms). Adding pages keeps the signed revision intact, but viewers
    /// show the signature as followed by changes. Read when asked (throws `PDFReadError`).
    public var isSigned: Bool {
        get throws {
            guard let catalog else { return false }
            if let perms = try resolve(catalog["Perms"]) as? PDFDictionary, !perms.entries.isEmpty { return true }
            guard let form = try resolve(catalog["AcroForm"]) as? PDFDictionary,
                  let flags = try (resolve(form["SigFlags"]) as? PDFNumber)?.integer else { return false }
            return flags & 1 != 0
        }
    }

    /// The file is certified: its catalog's /Perms has a /DocMDP signature. No certification
    /// allows adding pages (ISO 32000-1 12.8.2.2), so viewers show it as no longer valid after.
    public var isCertified: Bool {
        get throws {
            guard let catalog, let perms = try resolve(catalog["Perms"]) as? PDFDictionary else { return false }
            return try resolve(perms["DocMDP"]) != nil
        }
    }

    /// The PDF/A part its XMP metadata claims (1, 2, 3, 4), or nil when it claims none.
    public var pdfAPart: Int? {
        get throws { try pdfAIdentification().part }
    }

    /// The PDF/A conformance level its metadata claims ("A", "B", "U"), or nil.
    public var pdfAConformance: String? {
        get throws { try pdfAIdentification().conformance }
    }

    /// The number of components of the PDF/A output intent's profile (3 for RGB, 4 for CMYK, 1 for
    /// gray); nil without one.
    public var outputIntentComponents: Int? {
        get throws {
            guard let catalog, let intents = try resolve(catalog["OutputIntents"]) as? PDFArray else { return nil }
            for item in intents.items {
                guard let intent = try resolve(item) as? PDFDictionary,
                      try (resolve(intent["S"]) as? PDFName)?.value == "GTS_PDFA1" else { continue }
                if let profile = try resolve(intent["DestOutputProfile"]) as? PDFStream,
                   let n = try (resolve(profile.dictionary["N"]) as? PDFNumber)?.integer {
                    return n
                }
            }
            return nil
        }
    }

    // MARK: - Objects (for the appender and the tests)

    /// The newest trailer, with /Root, /Info and /ID taken from an older one when the newest lacks them.
    private(set) var trailer = PDFDictionary()

    private(set) var root: PDFReference?
    private(set) var catalog: PDFDictionary?
    private(set) var pagesRoot: PDFReference?
    private(set) var pagesRootDictionary: PDFDictionary?

    /// The page objects in reading order.
    var pages: [PDFReference] { pageList ?? [] }

    /// The object an indirect reference points to (nil when it is free or missing: PDF's null).
    func resolve(_ value: (any PDFObject)?) throws -> (any PDFObject)? {
        var value = value
        var hops = 0
        while let reference = value as? PDFReference {
            hops += 1
            if hops > 32 { throw PDFReadError.damaged("References point at each other.") }
            value = try get(reference.number)
        }
        return value is PDFNull ? nil : value
    }

    /// Object `number` as the newest revision has it; nil when free or not listed.
    func get(_ number: Int) throws -> (any PDFObject)? {
        if let cached = objects[number] { return cached }
        guard let entry = entries[number], entry.kind != .free else { return nil }
        if !resolving.insert(number).inserted { throw PDFReadError.damaged("Object \(number) refers to itself.") }
        defer { resolving.remove(number) }
        let value = try entry.kind == .inUse ? readObject(at: entry.offset, number) : readCompressed(number, entry)
        objects[number] = value
        return value
    }

    /// The generation the newest revision gives object `number`.
    func generationOf(_ number: Int) -> Int {
        guard let entry = entries[number], entry.kind == .inUse else { return 0 }
        return entry.generation
    }

    /// The file's byte at `position`; -1 outside it.
    func byteAt(_ position: Int) throws -> Int {
        try bytes[position]
    }

    /// A stream's data, its filters undone.
    func decodedData(_ stream: PDFStream) throws -> [UInt8] {
        try PDFFilters.decode(rawData(stream), filter: resolve(stream.dictionary["Filter"]),
                              parameters: resolve(stream.dictionary["DecodeParms"]))
    }

    // MARK: - Header and startxref

    private func readHeader() throws -> String {
        // The header must be the file's first bytes: an update's offsets count from byte 0, and a
        // file with something before its header counts them from elsewhere.
        let head = try bytes.read(0, count: 16)
        if !head.starts(with: "%PDF-".utf8) {
            let more = try bytes.read(0, count: 1024)
            if PDFReaderLite.find("%PDF-", in: more) != nil {
                throw PDFReadError(.unsupported, "The file has bytes before its %PDF header.")
            }
            throw PDFReadError(.notPdf, "The file does not start with %PDF.")
        }
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        if head.count >= 8 && isDigit(head[5]) && head[6] == UInt8(ascii: ".") && isDigit(head[7]) {
            return String(decoding: head[5..<8], as: UTF8.self)
        }
        return ""
    }

    private func findStartXref() throws -> Int {
        // The last "startxref" in the file's last few KB.
        let tailLength = min(bytes.length, 4096)
        let tailStart = bytes.length - tailLength
        let tail = try bytes.read(tailStart, count: tailLength)
        guard let at = PDFReaderLite.find("startxref", in: tail, backwards: true) else {
            throw PDFReadError.damaged("No startxref at the end of the file (it may be cut short).")
        }
        if PDFReaderLite.find("%%EOF", in: tail, from: at) == nil {
            throw PDFReadError.damaged("No %%EOF after startxref (the file may be cut short).")
        }
        let lexer = PDFLexer(bytes, position: tailStart + at + "startxref".utf8.count)
        guard let offset = try lexer.tryReadUnsigned(), offset > 0, offset < bytes.length else {
            throw PDFReadError.damaged("startxref does not point into the file.")
        }
        return offset
    }

    /// Where ASCII `needle` starts in `data`: the first place at or after `from`, or the last one
    /// when `backwards`.
    private static func find(_ needle: String, in data: [UInt8], from: Int = 0, backwards: Bool = false) -> Int? {
        let pattern = Array(needle.utf8)
        var start = backwards ? data.count - pattern.count : from
        while start >= from && start <= data.count - pattern.count {
            var found = true
            for i in 0..<pattern.count where data[start + i] != pattern[i] {
                found = false
                break
            }
            if found { return start }
            start += backwards ? -1 : 1
        }
        return nil
    }

    // MARK: - Cross-reference sections

    private func loadCrossReferences() throws {
        let limit = PDFReaderLite.maxObjectNumber
        var visited = Set<Int>()
        var offset: Int? = startXref
        var newest = true
        var highest = 0
        var trailer = PDFDictionary()
        while let at = offset {
            if !visited.insert(at).inserted {
                throw PDFReadError.damaged("The cross-reference sections point back at each other (/Prev).")
            }
            if visited.count > PDFReaderLite.maxSections { throw PDFReadError.damaged("Too many cross-reference sections.") }
            let section = try readSection(at)
            highest = max(highest, section.highest)
            if newest {
                xrefIsStream = section.isStream
                trailer = section.trailer.copy()
                newest = false
            } else {
                // Entries a newer trailer lacks come from the older one.
                for key in ["Root", "Info", "ID", "Encrypt"] where !trailer.contains(key) {
                    if let value = section.trailer[key] { trailer[key] = value }
                }
            }
            if let size = (section.trailer["Size"] as? PDFNumber)?.integer {
                if size > limit + 1 {
                    throw PDFReadError.damaged("/Size \(size) is past PDF's highest object number (\(limit)).")
                }
                if size > 0 { highest = max(highest, size - 1) }
            }
            sectionCount += 1
            if let prev = section.trailer["Prev"] {
                guard let p = (prev as? PDFNumber)?.integer, p > 0, p < bytes.length else {
                    throw PDFReadError.damaged("/Prev does not point into the file.")
                }
                offset = p
            } else {
                offset = nil
            }
            if sectionCount == 1 { latestPrev = offset }
        }
        self.trailer = trailer
        nextObjectNumber = highest + 1
    }

    /// One section at `offset`: its trailer dictionary and the highest number it lists; its entries
    /// are merged (newer ones already read win).
    private func readSection(_ offset: Int) throws -> (trailer: PDFDictionary, isStream: Bool, highest: Int) {
        let lexer = PDFLexer(bytes, position: offset)
        try lexer.skipWhiteSpace()
        let start = lexer.position
        if try lexer.readKeyword() == "xref" {
            var (section, highest) = try readTable(lexer)
            try lexer.skipWhiteSpace()
            if try lexer.readKeyword() != "trailer" { throw PDFReadError.damaged("A cross-reference table has no trailer.") }
            guard let trailer = try lexer.readObject(allowStream: false) as? PDFDictionary else {
                throw PDFReadError.damaged("The trailer is not a dictionary.")
            }
            // A hybrid file: the classic table's objects, then the ones only its stream lists
            // (the table gives those as free, or not at all).
            if let streamOffset = trailer["XRefStm"] {
                guard let so = (streamOffset as? PDFNumber)?.integer, so > 0, so < bytes.length else {
                    throw PDFReadError.damaged("/XRefStm does not point into the file.")
                }
                isHybrid = true
                let stream = try readStreamSection(so)
                highest = max(highest, stream.highest)
                for (number, entry) in stream.entries {
                    if let listed = section[number], listed.kind != .free { continue }
                    section[number] = entry
                }
            }
            merge(section)
            return (trailer: trailer, isStream: false, highest: highest)
        }
        let stream = try readStreamSection(start)
        merge(stream.entries)
        return (trailer: stream.dictionary, isStream: true, highest: stream.highest)
    }

    /// Entries of an older section count only where no newer one has spoken.
    private func merge(_ section: [Int: Entry]) {
        for (number, entry) in section where entries[number] == nil {
            entries[number] = entry
        }
    }

    /// A classic table's subsections ("first count", then count lines of "offset generation n|f").
    private func readTable(_ lexer: PDFLexer) throws -> (entries: [Int: Entry], highest: Int) {
        let limit = PDFReaderLite.maxObjectNumber
        var section: [Int: Entry] = [:]
        var highest = 0
        while true {
            let save = lexer.position
            guard let first = try lexer.tryReadUnsigned() else {
                lexer.position = save
                return (entries: section, highest: highest)
            }
            guard let count = try lexer.tryReadUnsigned() else {
                throw PDFReadError.damaged("A cross-reference subsection header is not two numbers.")
            }
            if first > limit + 1 || count > limit + 1 - first {
                throw PDFReadError.damaged("A cross-reference subsection goes past PDF's highest object number (\(limit)).")
            }
            for i in 0..<count {
                let entryOffset = try lexer.tryReadUnsigned()
                var generationRead: Int?
                if entryOffset != nil { generationRead = try lexer.tryReadUnsigned() }
                var kind = ""
                if generationRead != nil { kind = try lexer.readKeyword() }
                guard let entryAt = entryOffset, let generation = generationRead, kind == "n" || kind == "f",
                      generation <= 65535 else {
                    throw PDFReadError.damaged("Cross-reference entry \(first + i) is not \"offset generation n|f\".")
                }
                let number = first + i
                // Object 0 is the head of the free list, whatever a table says.
                if number == 0 { continue }
                if kind == "n" && (entryAt <= 0 || entryAt >= bytes.length) {
                    throw PDFReadError.damaged("Object \(number) is listed outside the file.")
                }
                if section[number] == nil {
                    section[number] = kind == "n"
                        ? Entry(kind: .inUse, offset: entryAt, generation: generation)
                        : Entry(kind: .free, generation: generation)
                }
                if kind == "n" { highest = max(highest, number) }
            }
        }
    }

    /// A cross-reference stream (/Type /XRef) at `offset`: its dictionary, its entries and the
    /// highest number it lists.
    private func readStreamSection(_ offset: Int) throws -> (dictionary: PDFDictionary, entries: [Int: Entry], highest: Int) {
        let limit = PDFReaderLite.maxObjectNumber
        let lexer = PDFLexer(bytes, position: offset)
        _ = try lexer.readObjectHeader()
        guard let stream = try lexer.readObject() as? PDFStream,
              (stream.dictionary["Type"] as? PDFName)?.value == "XRef" else {
            throw PDFReadError.damaged("startxref points at neither a cross-reference table nor a cross-reference stream.")
        }
        let dictionary = stream.dictionary
        // A cross-reference stream's own entries are direct: nothing can be looked up yet.
        var widths: [Int] = []
        if let w = dictionary["W"] as? PDFArray, w.items.count == 3 {
            for item in w.items {
                guard let width = (item as? PDFNumber)?.integer, width >= 0, width <= 8 else { break }
                widths.append(width)
            }
        }
        if widths.count != 3 { throw PDFReadError.damaged("A cross-reference stream's /W is not three field widths.") }
        guard let size = (dictionary["Size"] as? PDFNumber)?.integer, size >= 0 else {
            throw PDFReadError.damaged("A cross-reference stream has no /Size.")
        }
        if size > limit + 1 { throw PDFReadError.damaged("/Size \(size) is past PDF's highest object number (\(limit)).") }
        var index: [Int] = []
        if let indexArray = dictionary["Index"] as? PDFArray {
            for item in indexArray.items {
                guard let n = (item as? PDFNumber)?.integer, n >= 0 else {
                    throw PDFReadError.damaged("A cross-reference stream's /Index is not numbers.")
                }
                index.append(n)
            }
        } else {
            index = [0, size]
        }
        if index.count % 2 != 0 { throw PDFReadError.damaged("A cross-reference stream's /Index has an odd count.") }
        guard let length = (dictionary["Length"] as? PDFNumber)?.integer, length >= 0 else {
            throw PDFReadError.damaged("A cross-reference stream's /Length is not a number.")
        }
        let raw = try streamData(stream.dataOffset, length)
        let data = try PDFFilters.decode(raw, filter: dictionary["Filter"], parameters: dictionary["DecodeParms"])
        let entryLength = widths[0] + widths[1] + widths[2]
        if entryLength == 0 { throw PDFReadError.damaged("A cross-reference stream's entries are empty.") }
        var section: [Int: Entry] = [:]
        var highest = 0
        var at = 0
        for k in stride(from: 0, to: index.count, by: 2) {
            let first = index[k]
            let count = index[k + 1]
            if first > limit + 1 || count > limit + 1 - first {
                throw PDFReadError.damaged("A cross-reference stream's /Index goes past PDF's highest object number (\(limit)).")
            }
            for i in 0..<count {
                if at + entryLength > data.count {
                    throw PDFReadError.damaged("A cross-reference stream is shorter than its /Index says.")
                }
                // A missing first field means type 1.
                let type = widths[0] == 0 ? 1 : PDFReaderLite.field(data, at, widths[0])
                let second = PDFReaderLite.field(data, at + widths[0], widths[1])
                let third = PDFReaderLite.field(data, at + widths[0] + widths[1], widths[2])
                at += entryLength
                let number = first + i
                if number == 0 { continue }
                let entry: Entry
                switch type {
                case 0:
                    entry = Entry(kind: .free, generation: min(third, 65535))
                case 1:
                    if second <= 0 || second >= bytes.length {
                        throw PDFReadError.damaged("Object \(number) is listed outside the file.")
                    }
                    entry = Entry(kind: .inUse, offset: second, generation: min(third, 65535))
                    highest = max(highest, number)
                case 2:
                    if second <= 0 || second > Int(Int32.max) {
                        throw PDFReadError.damaged("Object \(number) is listed in an object stream that cannot exist.")
                    }
                    entry = Entry(kind: .compressed, streamNumber: second, index: min(third, Int(Int32.max)))
                    highest = max(highest, number)
                default:
                    // Types a later PDF version may add read as null (7.5.8.3).
                    continue
                }
                if section[number] == nil { section[number] = entry }
            }
        }
        return (dictionary: dictionary, entries: section, highest: highest)
    }

    private static func field(_ data: [UInt8], _ at: Int, _ width: Int) -> Int {
        var value = 0
        for i in 0..<width { value = (value << 8) | Int(data[at + i]) }
        return value
    }

    // MARK: - Objects

    private func readObject(at offset: Int, _ number: Int) throws -> any PDFObject {
        let lexer = PDFLexer(bytes, position: offset)
        let found = try lexer.readObjectHeader().number
        if found != number { throw PDFReadError.damaged("Object \(number) is listed at byte \(offset), where object \(found) is.") }
        return try lexer.readObject()
    }

    private func readCompressed(_ number: Int, _ entry: Entry) throws -> any PDFObject {
        let objectStream: (data: [UInt8], offsets: [Int: Int])
        if let known = objectStreams[entry.streamNumber] {
            objectStream = known
        } else {
            guard let stream = try get(entry.streamNumber) as? PDFStream,
                  (stream.dictionary["Type"] as? PDFName)?.value == "ObjStm" else {
                throw PDFReadError.damaged("Object \(number) is listed in object \(entry.streamNumber), which is not an object stream.")
            }
            guard let n = try (resolve(stream.dictionary["N"]) as? PDFNumber)?.integer, n >= 0,
                  let first = try (resolve(stream.dictionary["First"]) as? PDFNumber)?.integer, first >= 0 else {
                throw PDFReadError.damaged("Object stream \(entry.streamNumber) has no /N or /First.")
            }
            let data = try decodedData(stream)
            let header = PDFLexer(PDFArrayBytes(data))
            var offsets: [Int: Int] = [:]
            for _ in 0..<n {
                let objectNumber = try header.tryReadUnsigned()
                var relative: Int?
                if objectNumber != nil { relative = try header.tryReadUnsigned() }
                guard let listed = objectNumber, let relativeAt = relative, listed <= Int(Int32.max),
                      relativeAt < data.count - first else {
                    throw PDFReadError.damaged("Object stream \(entry.streamNumber)'s header is not \(n) pairs of numbers.")
                }
                if offsets[listed] == nil { offsets[listed] = first + relativeAt }
            }
            objectStream = (data: data, offsets: offsets)
            objectStreams[entry.streamNumber] = objectStream
        }
        // Found by number: where the entry's index agrees with the header, it names this same offset.
        guard let at = objectStream.offsets[number] else {
            throw PDFReadError.damaged("Object \(number) is not in object stream \(entry.streamNumber).")
        }
        let lexer = PDFLexer(PDFArrayBytes(objectStream.data), position: at)
        return try lexer.readObject(allowStream: false)
    }

    /// A stream's bytes as stored: /Length of them, which must be followed by "endstream".
    private func rawData(_ stream: PDFStream) throws -> [UInt8] {
        guard let length = try (resolve(stream.dictionary["Length"]) as? PDFNumber)?.integer, length >= 0 else {
            throw PDFReadError.damaged("A stream's /Length is not a number.")
        }
        return try streamData(stream.dataOffset, length)
    }

    private func streamData(_ start: Int, _ length: Int) throws -> [UInt8] {
        if length > bytes.length - start || length > Int(Int32.max) {
            throw PDFReadError.damaged("A stream runs past the end of the file.")
        }
        let lexer = PDFLexer(bytes, position: start + length)
        try lexer.skipWhiteSpace()
        if try lexer.readKeyword() != "endstream" {
            throw PDFReadError.damaged("A stream's /Length (\(length)) does not end at \"endstream\".")
        }
        return try bytes.read(start, count: length)
    }

    // MARK: - Page tree

    private func walkPageTree(_ root: PDFReference) throws -> [PDFReference] {
        var pages: [PDFReference] = []
        var visited = Set<Int>()

        func walk(_ node: PDFReference, _ depth: Int) throws {
            if depth > PDFReaderLite.maxTreeDepth { throw PDFReadError.damaged("The page tree is too deep.") }
            if !visited.insert(node.number).inserted { throw PDFReadError.damaged("The page tree has a loop.") }
            guard let dictionary = try resolve(node) as? PDFDictionary else {
                throw PDFReadError.damaged("Page tree node \(node.number) is not a dictionary.")
            }
            let type = try (resolve(dictionary["Type"]) as? PDFName)?.value
            let kids = try resolve(dictionary["Kids"])
            // A node with kids is an intermediate node, whatever its /Type says (some writers omit it).
            if type == "Pages" || (type == nil && kids is PDFArray) {
                guard let array = kids as? PDFArray else {
                    throw PDFReadError.damaged("Page tree node \(node.number) has no /Kids.")
                }
                for kid in array.items {
                    guard let reference = kid as? PDFReference else {
                        throw PDFReadError.damaged("Page tree node \(node.number) has a kid that is not a reference.")
                    }
                    try walk(reference, depth + 1)
                }
                return
            }
            if type == "Page" || type == nil {
                pages.append(node)
                return
            }
            throw PDFReadError.damaged("Page tree node \(node.number) is a /\(type ?? "").")
        }

        try walk(root, 0)
        return pages
    }

    // MARK: - PDF/A identification

    private func pdfAIdentification() throws -> (part: Int?, conformance: String?) {
        if let known = pdfA { return known }
        var result: (part: Int?, conformance: String?) = (part: nil, conformance: nil)
        do {
            if let catalog, let metadata = try resolve(catalog["Metadata"]) as? PDFStream {
                result = try PDFReaderLite.readPdfAId(xmp: decodedData(metadata))
            }
        } catch is PDFReadError {
            // Metadata that cannot be read claims nothing.
        }
        pdfA = result
        return result
    }

    /// pdfaid:part and pdfaid:conformance from XMP, as attributes or elements.
    static func readPdfAId(xmp: [UInt8]) -> (part: Int?, conformance: String?) {
        let text = String(decoding: xmp, as: UTF8.self)
        var start = text.range(of: "<x:xmpmeta", options: .literal)?.lowerBound
        if start == nil { start = text.range(of: "<rdf:RDF", options: .literal)?.lowerBound }
        var xml = Substring(text)
        if let start {
            if let end = text.range(of: "</x:xmpmeta>", options: [.literal, .backwards]), end.lowerBound > start {
                xml = text[start..<end.upperBound]
            } else {
                xml = text[start...]
            }
        }
        let collector = PDFAIdCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        var part: String?
        var conformance: String?
        // Not well-formed: claims nothing.
        if parser.parse() {
            part = collector.parts.first
            conformance = collector.conformances.first
        }
        var number: Int?
        if let part, let value = Int32(part.trimmingCharacters(in: .whitespacesAndNewlines)) { number = Int(value) }
        var level: String?
        if let trimmed = conformance?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            level = trimmed.uppercased()
        }
        return (part: number, conformance: number == nil ? nil : level)
    }
}

/// Collects every pdfaid:part and pdfaid:conformance while XMLParser reads XMP, in document order
/// with an element's attributes before its own text, as C# walks the XDocument and keeps the first.
/// Attribute names come with their prefix, so the prefixes in scope are kept to find the namespace.
private final class PDFAIdCollector: NSObject, XMLParserDelegate {
    private static let namespace = "http://www.aiim.org/pdfa/ns/id/"

    var parts: [String] = []
    var conformances: [String] = []
    private var prefixes: [String: [String]] = [:]
    private var openElements: [(part: Int?, conformance: Int?)] = []

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        if prefixes[prefix]?.isEmpty == false { prefixes[prefix]?.removeLast() }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        for (name, value) in attributeDict {
            guard let colon = name.firstIndex(of: ":"),
                  prefixes[String(name[..<colon])]?.last == PDFAIdCollector.namespace else { continue }
            let localName = name[name.index(after: colon)...]
            if localName == "part" { parts.append(value) }
            if localName == "conformance" { conformances.append(value) }
        }
        var element: (part: Int?, conformance: Int?) = (part: nil, conformance: nil)
        if namespaceURI == PDFAIdCollector.namespace {
            if elementName == "part" {
                element.part = parts.count
                parts.append("")
            } else if elementName == "conformance" {
                element.conformance = conformances.count
                conformances.append("")
            }
        }
        openElements.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !openElements.isEmpty { openElements.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(String(decoding: CDATABlock, as: UTF8.self))
    }

    /// Text belongs to the value of every element it is inside.
    private func append(_ text: String) {
        for element in openElements {
            if let i = element.part { parts[i] += text }
            if let i = element.conformance { conformances[i] += text }
        }
    }
}
