import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/ZipStoreReaderTests.cs: the same cases, the same
// hand-built archives (RawZip), the same error kinds and messages. The Windows-only case that reads
// System.IO.Compression's output has no twin here (Foundation writes no zip).

final class ZipStoreReaderTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func test_readsWhatZipStoreWrites() throws {
        let big = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let zip = ZipStore.make([
            ZipStoreEntry(name: "[Content_Types].xml", data: data("<x/>")),
            ZipStoreEntry(name: "dir/empty.bin", data: Data()),
            ZipStoreEntry(name: "dir/big.bin", data: big),
            ZipStoreEntry(name: "naïve.txt", data: data("é")),
        ])
        let reader = try ZipStoreReader(data: zip)
        XCTAssertEqual(reader.entries.map(\.name), ["[Content_Types].xml", "dir/empty.bin", "dir/big.bin", "naïve.txt"])
        XCTAssertEqual(reader.entries.map(\.size), [4, 0, 70_000, 2])
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entry(named: "dir/big.bin"))), big)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entry(named: "dir/empty.bin"))), Data())
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entry(named: "naïve.txt"))), data("é"))
        XCTAssertEqual(reader.entry(named: "dir/big.bin")?.crc32, ZipStore.crc32(big))
        XCTAssertEqual(reader.entries[0].dataOffset, 30 + 19)
    }

    func test_readsAnEmptyArchive() throws {
        XCTAssertTrue(try ZipStoreReader(data: ZipStore.make([])).entries.isEmpty)
    }

    func test_readAll_returnsEveryEntry() throws {
        let entries = try ZipStoreReader.readAll(ZipStore.make([
            ZipStoreEntry(name: "a.txt", data: data("hi")), ZipStoreEntry(name: "b/c.txt", data: data("yo")),
        ]))
        XCTAssertEqual(entries.map(\.name), ["a.txt", "b/c.txt"])
        XCTAssertEqual(entries[1].data, data("yo"))
    }

    func test_readsStoredArchivesFromOtherTools() throws {
        // As Info-ZIP's "zip -0" writes them: Unix attributes, timestamp extras that differ
        // between the local header and the directory, a folder entry and an archive comment.
        let zip = RawZip.build([
            RawEntry("pages/", []).with {
                $0.madeBy = 0x031E; $0.external = (0x41ED << 16) | 0x10
                $0.localExtra = RawZip.extra(0x5455, 9); $0.centralExtra = RawZip.extra(0x5455, 5)
            },
            RawEntry("pages/a.txt", bytes("hello")).with {
                $0.madeBy = 0x031E; $0.external = 0x81A4 << 16
                $0.localExtra = RawZip.extra(0x5455, 9); $0.centralExtra = RawZip.extra(0x5455, 5)
            },
            RawEntry("b.txt", bytes("bye")).with {
                $0.madeBy = 0x003F; $0.external = 0x20; $0.centralExtra = RawZip.extra(0x000A, 32)
            },
        ], RawEnd().with { $0.comment = Array("made by hand".utf8) })
        let reader = try ZipStoreReader(data: zip)
        XCTAssertEqual(reader.entries.map(\.name), ["pages/a.txt", "b.txt"])
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entry(named: "pages/a.txt"))), data("hello"))
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entry(named: "b.txt"))), data("bye"))
    }

    func test_find_isExact() throws {
        let reader = try ZipStoreReader(data: ZipStore.make([ZipStoreEntry(name: "Pages/A.jpg", data: Data([1]))]))
        XCTAssertNotNil(reader.entry(named: "Pages/A.jpg"))
        XCTAssertNil(reader.entry(named: "pages/a.jpg"))
        XCTAssertNil(reader.entry(named: "A.jpg"))
        // Exact bytes: the same name in another Unicode form is another name (Swift String
        // equality alone would match it).
        let composed = try ZipStoreReader(data: ZipStore.make([ZipStoreEntry(name: "caf\u{E9}.txt", data: Data([1]))]))
        XCTAssertNotNil(composed.entry(named: "caf\u{E9}.txt"))
        XCTAssertNil(composed.entry(named: "cafe\u{301}.txt"))
    }

    func test_copy_streamsTheEntry() throws {
        let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let reader = try ZipStoreReader(data: ZipStore.make([ZipStoreEntry(name: "big.bin", data: big)]))
        var output = Data()
        var pieces = 0
        try reader.copy(reader.entries[0]) { output.append($0); pieces += 1 }
        XCTAssertEqual(output, big)
        XCTAssertGreaterThan(pieces, 1)
    }

    func test_openFile_readsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zipstorereader-\(UUID().uuidString).zip")
        try ZipStore.make([ZipStoreEntry(name: "a.txt", data: data("hi")), ZipStoreEntry(name: "b.txt", data: data("there"))])
            .write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try ZipStoreReader(contentsOf: url)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entry(named: "b.txt"))), data("there"))
        reader.close()
    }

    func test_refusesCompressedEntries() {
        assertRefused(.unsupportedMethod, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.method = 8 }]))
        assertRefused(.unsupportedMethod, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.method = 12 }]))
    }

    func test_refusesEncryptedEntries() {
        assertRefused(.encrypted, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.flags = 0x0001 }]))
        assertRefused(.encrypted, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.flags = 0x0041 }]))
        assertRefused(.encrypted, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.method = 99 }]))
        assertRefused(.encrypted, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.centralExtra = RawZip.extra(0x9901, 7) }]))
        assertRefused(.encrypted, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localExtra = RawZip.extra(0x9901, 7) }]))
    }

    func test_refusesDataDescriptors() {
        assertRefused(.dataDescriptor, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.flags = 0x0008 }]))
    }

    func test_refusesZip64() {
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.centralExtra = RawZip.extra(0x0001, 16) }]))
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localExtra = RawZip.extra(0x0001, 16) }]))
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.compressed = 0xFFFF_FFFF; $0.size = 0xFFFF_FFFF }]))
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.centralOffset = 0xFFFF_FFFF }]))
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi"))], RawEnd().with { $0.zip64Locator = true }))
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi"))], RawEnd().with { $0.count = 0xFFFF; $0.onDisk = 0xFFFF }))
        assertRefused(.zip64, RawZip.build([RawEntry("a.txt", bytes("hi"))], RawEnd().with { $0.directoryOffset = 0xFFFF_FFFF }))
    }

    func test_refusesUnsafeNames() {
        let names = [
            "../a.txt", "a/../b.txt", "a/..", "..", "/etc/passwd", "C:/x.txt", "C:x.txt", "a\\b.txt", "a\u{0}b.txt",
            "a//b.txt", "./a.txt", "a/./b.txt", "con.", "a /b.txt", "a.txt ", "\u{1}x", "x\u{7F}", "file.txt:stream",
            String(repeating: "a", count: 256), "",
        ]
        for name in names {
            assertRefused(.unsafeName, RawZip.build([RawEntry(name, bytes("hi"))]), name)
        }
        // Not UTF-8: a lone continuation byte, a truncated sequence, an overlong "/".
        for name: [UInt8] in [[0x61, 0x80], [0xC3, 0x28], [0x61, 0xC0, 0xAF, 0x62]] {
            assertRefused(.unsafeName, RawZip.build([RawEntry(bytes: name, bytes("hi"))]))
        }
        for name in Self.separatorNextToAMark {
            assertRefused(.unsafeName, RawZip.build([RawEntry(bytes: name, bytes("hi"))]), "\(name)")
        }
    }

    /// Unsafe names whose "/" is followed by a combining mark (U+0301, CC 81) or a joiner
    /// (U+200D, E2 80 8D), or preceded by a prepended mark (U+0600, D8 80): one Character with
    /// the "/", still a separator. Built from bytes, as the C# twin's strings encode.
    private static let separatorNextToAMark: [[UInt8]] = [
        [0x2E, 0x2E, 0x2F, 0xCC, 0x81, 0x78], // "../" U+0301 "x"
        [0x2F, 0xCC, 0x81, 0x61], // "/" U+0301 "a"
        [0x2F, 0xCC, 0x81, 0x65, 0x74, 0x63, 0x2F, 0x70, 0x61, 0x73, 0x73, 0x77, 0x64], // "/" U+0301 "etc/passwd"
        [0x61, 0x2F, 0x2F, 0xCC, 0x81, 0x62], // "a//" U+0301 "b"
        [0x2E, 0x2F, 0xCC, 0x81, 0x61], // "./" U+0301 "a"
        [0x2E, 0x2E, 0x2F, 0xE2, 0x80, 0x8D, 0x78], // "../" U+200D "x"
        [0xD8, 0x80, 0x2F, 0x2E, 0x2E, 0x2F, 0x78], // U+0600 "/../x"
    ]

    func test_isSafeName_cases() {
        XCTAssertTrue(ZipStoreReader.isSafeName("manifest.json"))
        XCTAssertTrue(ZipStoreReader.isSafeName("pages/0001.jpg"))
        XCTAssertTrue(ZipStoreReader.isSafeName("pages/"))
        XCTAssertTrue(ZipStoreReader.isSafeName("naïve dir/日本.txt"))
        XCTAssertTrue(ZipStoreReader.isSafeName(".hidden"))
        XCTAssertTrue(ZipStoreReader.isSafeName("a..b"))
        XCTAssertTrue(ZipStoreReader.isSafeName(String(repeating: "a", count: 255)))
        XCTAssertFalse(ZipStoreReader.isSafeName(String(repeating: "a", count: 256)))
        XCTAssertFalse(ZipStoreReader.isSafeName(String(repeating: "é", count: 128)))
        XCTAssertFalse(ZipStoreReader.isSafeName("pages//"))
        XCTAssertFalse(ZipStoreReader.isSafeName("/"))
        XCTAssertFalse(ZipStoreReader.isSafeName("a/b/../../c"))
        for name in Self.separatorNextToAMark {
            XCTAssertFalse(ZipStoreReader.isSafeName(String(decoding: name, as: UTF8.self)), "\(name)")
        }
        XCTAssertTrue(ZipStoreReader.isSafeName(String(decoding: [0x61, 0x2F, 0xCC, 0x81, 0x62] as [UInt8], as: UTF8.self)))
        XCTAssertTrue(ZipStoreReader.isSafeName(String(decoding: [0x61, 0xD8, 0x80, 0x2F, 0x62] as [UInt8], as: UTF8.self)))
        XCTAssertTrue(ZipStoreReader.isSafeName(String(decoding: [0x61, 0xD8, 0x80, 0x2F] as [UInt8], as: UTF8.self)))
    }

    func test_folderNames_endWithTheSlashByte() throws {
        // "a" U+0600 "/": a folder, though its last Character is U+0600 and "/" together.
        let folder: [UInt8] = [0x61, 0xD8, 0x80, 0x2F]
        let reader = try ZipStoreReader(data: RawZip.build([RawEntry(bytes: folder, []), RawEntry("b.txt", [1])]))
        XCTAssertEqual(reader.entries.map(\.name), ["b.txt"])
        assertRefused(.duplicateName, RawZip.build([RawEntry(bytes: Array(folder.dropLast()), [1]), RawEntry(bytes: folder, [])]))
    }

    func test_refusesDuplicateNamesIgnoringCase() {
        assertRefused(.duplicateName, RawZip.build([RawEntry("a.jpg", [1]), RawEntry("a.jpg", [2])]))
        assertRefused(.duplicateName, RawZip.build([RawEntry("pages/a.jpg", [1]), RawEntry("PAGES/A.JPG", [2])]))
        // The same name composed and decomposed (as macOS file names often are). Built from bytes:
        // a Swift String literal would treat the two as equal before they reach the archive.
        assertRefused(.duplicateName, RawZip.build([
            RawEntry(bytes: [0x63, 0x61, 0x66, 0xC3, 0xA9] + Array(".txt".utf8), [1]),
            RawEntry(bytes: [0x63, 0x61, 0x66, 0x65, 0xCC, 0x81] + Array(".txt".utf8), [2]),
        ]))
        assertRefused(.duplicateName, RawZip.build([RawEntry("Pages/", []), RawEntry("pages/", [])]))
        assertRefused(.duplicateName, RawZip.build([RawEntry("pages", [1]), RawEntry("pages/", [])]))
    }

    func test_refusesLinksAndSpecialFiles() {
        let unixTypes: [UInt32] = [0xA000, 0x2000, 0x6000, 0x1000, 0xC000]
        for type in unixTypes {
            assertRefused(.specialFile, RawZip.build([RawEntry("link", bytes("target")).with {
                $0.madeBy = 0x031E; $0.external = (type | 0x1FF) << 16
            }]))
        }
        // macOS's own host code, a symlink.
        assertRefused(.specialFile, RawZip.build([RawEntry("link", bytes("target")).with {
            $0.madeBy = 0x1314; $0.external = 0xA1ED << 16
        }]))
        // A folder's type or attribute on a file, a file's type on a folder.
        assertRefused(.specialFile, RawZip.build([RawEntry("a.txt", []).with { $0.madeBy = 0x031E; $0.external = 0x41ED << 16 }]))
        assertRefused(.specialFile, RawZip.build([RawEntry("a.txt", []).with { $0.external = 0x10 }]))
        assertRefused(.specialFile, RawZip.build([RawEntry("dir/", []).with { $0.madeBy = 0x031E; $0.external = 0x81A4 << 16 }]))
        // Windows: a reparse point (a link) and a device.
        assertRefused(.specialFile, RawZip.build([RawEntry("a.txt", [1]).with { $0.madeBy = 0x0A3F; $0.external = 0x420 }]))
        assertRefused(.specialFile, RawZip.build([RawEntry("a.txt", [1]).with { $0.external = 0x40 }]))
    }

    func test_refusesTooManyEntries() throws {
        var limits = ZipReadLimits.standard
        limits.maxEntries = 2
        let zip = ZipStore.make([ZipStoreEntry(name: "a", data: Data([1])), ZipStoreEntry(name: "b", data: Data([2])),
                                 ZipStoreEntry(name: "c", data: Data([3]))])
        let error = assertRefused(.tooManyEntries, zip, limits: limits)
        XCTAssertEqual(error?.message, "The archive holds more than 2 entries.")
        let reader = try ZipStoreReader(data: ZipStore.make([ZipStoreEntry(name: "a", data: Data([1])),
                                                             ZipStoreEntry(name: "b", data: Data([2]))]), limits: limits)
        XCTAssertEqual(reader.entries.count, 2)
    }

    func test_refusesEntriesPastTheSizeLimits() throws {
        var limits = ZipReadLimits.standard
        limits.maxEntryBytes = 10
        limits.maxTotalBytes = 15
        let one = assertRefused(.tooLarge, ZipStore.make([ZipStoreEntry(name: "big.bin", data: Data(count: 11))]), limits: limits)
        XCTAssertEqual(one?.entryName, "big.bin")
        let all = assertRefused(.tooLarge, ZipStore.make([ZipStoreEntry(name: "a.bin", data: Data(count: 10)),
                                                          ZipStoreEntry(name: "b.bin", data: Data(count: 10))]), limits: limits)
        XCTAssertNotNil(all)
        XCTAssertNil(all?.entryName)
        let reader = try ZipStoreReader(data: ZipStore.make([ZipStoreEntry(name: "a.bin", data: Data(count: 10)),
                                                             ZipStoreEntry(name: "b.bin", data: Data(count: 5))]), limits: limits)
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(ZipStoreReader.message(.tooLarge, entryName: "big.bin"), "\"big.bin\" is larger than 256 MB.")
        XCTAssertEqual(ZipStoreReader.message(.tooLarge), "The archive's contents are larger than 512 MB.")
    }

    func test_refusesBombSizes() {
        // A stored entry that claims to expand, and a local header that disagrees with the directory.
        assertRefused(.sizeMismatch, RawZip.build([RawEntry("bomb.bin", [UInt8](repeating: 0, count: 10)).with { $0.size = 10_000_000 }]))
        assertRefused(.sizeMismatch, RawZip.build([RawEntry("bomb.bin", [UInt8](repeating: 0, count: 10)).with {
            $0.compressed = 10_000_000; $0.size = 10_000_000
        }]))
        assertRefused(.sizeMismatch, RawZip.build([RawEntry("bomb.bin", [UInt8](repeating: 0, count: 10)).with {
            $0.localSize = 10_000_000; $0.localCompressed = 10_000_000
        }]))
        assertRefused(.sizeMismatch, RawZip.build([RawEntry("dir/", [1, 2])]))
        // Two directory records sharing one entry's bytes (an overlapping bomb).
        let zip = RawZip.build([RawEntry("a.bin", [UInt8](repeating: 0, count: 10)), RawEntry("b.bin", [UInt8](repeating: 0, count: 10))],
                               RawEnd().with { $0.secondOffsetFromFirst = true })
        assertRefused(.corrupt, zip)
    }

    func test_refusesLocalHeadersThatDisagree() {
        // The directory says stored, plain and this CRC; the local header says otherwise.
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localFlags = 0x0008 }]))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localFlags = 0x0001 }]))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localFlags = 0x0800 }]))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localMethod = 8 }]))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", bytes("hi")).with { $0.localCrc = ZipStore.crc32(Data("hi".utf8)) &+ 1 }]))
        let error = assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1]), RawEntry("b.txt", [2]).with { $0.localMethod = 8 }]))
        XCTAssertEqual(error?.entryName, "b.txt")
    }

    func test_refusesADirectoryPastItsLimit() throws {
        XCTAssertEqual(ZipReadLimits.standard.maxDirectoryBytes, ZipStoreReader.maxCentralDirectoryBytes)
        XCTAssertEqual(ZipStoreReader.maxCentralDirectoryBytes, 64 * 1024 * 1024)
        var limits = ZipReadLimits.standard
        limits.maxDirectoryBytes = 100
        // Each directory record here is 46 bytes and a 5-byte name: 153 bytes for three, 102 for two, 51 for one.
        let three = ZipStore.make([ZipStoreEntry(name: "a.txt", data: Data([1])), ZipStoreEntry(name: "b.txt", data: Data([2])),
                                   ZipStoreEntry(name: "c.txt", data: Data([3]))])
        let two = ZipStore.make([ZipStoreEntry(name: "a.txt", data: Data([1])), ZipStoreEntry(name: "b.txt", data: Data([2]))])
        let error = assertRefused(.tooLarge, three, limits: limits)
        XCTAssertNotNil(error)
        XCTAssertNil(error?.entryName)
        assertRefused(.tooLarge, two, limits: limits)
        XCTAssertEqual(try ZipStoreReader(data: ZipStore.make([ZipStoreEntry(name: "a.txt", data: Data([1]))]), limits: limits).entries.count, 1)
        limits.maxDirectoryBytes = 102
        XCTAssertEqual(try ZipStoreReader(data: two, limits: limits).entries.count, 2)
    }

    func test_refusesACrcMismatchWhenReading() throws {
        var zip = ZipStore.make([ZipStoreEntry(name: "a.txt", data: data("hello"))])
        zip[30 + 5] ^= 0x01 // the first byte of the data
        let reader = try ZipStoreReader(data: zip)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
            XCTAssertEqual((error as? ZipReadError)?.kind, .crcMismatch)
            XCTAssertEqual((error as? ZipReadError)?.message, "\"a.txt\" is damaged: its checksum does not match its data.")
        }
        XCTAssertThrowsError(try reader.copy(reader.entries[0]) { _ in })
    }

    func test_refusesTruncatedAndCorruptArchives() {
        let zip = ZipStore.make([ZipStoreEntry(name: "a.txt", data: data("hello")), ZipStoreEntry(name: "b.txt", data: data("world"))])
        assertRefused(.corrupt, Data())
        assertRefused(.corrupt, data("not a zip archive at all, just some text"))
        assertRefused(.corrupt, zip.prefix(zip.count - 1))
        assertRefused(.corrupt, zip.prefix(zip.count / 2))
        assertRefused(.corrupt, zip.prefix(zip.count - 22))
        // The directory's size or offset off by one, a record's signature broken.
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.directorySizeDelta = -1 }))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.directorySizeDelta = 1 }))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.count = 2; $0.onDisk = 2 }))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.count = 0; $0.onDisk = 0 }))
        var broken = zip
        broken[30 + 5 + 5] = 0 // the second local header's signature
        assertRefused(.corrupt, broken)
        // A local header naming another file than its record, a second disk, bytes before the
        // first entry (a self-extractor) or after the last.
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1]).with { $0.localName = Array("b.txt".utf8) }]))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.disk = 1 }))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.prefix = Array("MZ".utf8) }))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1])], RawEnd().with { $0.gap = 3 }))
        // An extra field whose blocks do not add up.
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1]).with { $0.centralExtra = [0x55, 0x54, 0x09] }]))
        assertRefused(.corrupt, RawZip.build([RawEntry("a.txt", [1]).with { $0.localExtra = [0x55, 0x54, 0x09, 0x00, 0x01] }]))
    }

    func test_rawZip_matchesZipStoreForPlainEntries() {
        let expected = ZipStore.make([ZipStoreEntry(name: "a.txt", data: data("hi")), ZipStoreEntry(name: "naïve.txt", data: data("é"))])
        let raw = RawZip.build([RawEntry("a.txt", bytes("hi")), RawEntry("naïve.txt", bytes("é")).with { $0.flags = 0x0800 }])
        XCTAssertEqual(raw, expected)
    }

    func test_messages() {
        XCTAssertEqual(ZipStoreReader.message(.corrupt), "The archive is damaged or cut short.")
        XCTAssertEqual(ZipStoreReader.message(.unsupportedMethod, entryName: "a.bin"),
                       "\"a.bin\" is compressed. Only archives of uncompressed (stored) entries can be read.")
        XCTAssertEqual(ZipStoreReader.message(.encrypted, entryName: "a.bin"), "\"a.bin\" is encrypted. Encrypted archives cannot be read.")
        XCTAssertEqual(ZipStoreReader.message(.zip64),
                       "The archive uses ZIP64 (for archives past 4 GB or 65,535 entries), which is not supported.")
        XCTAssertEqual(ZipStoreReader.message(.dataDescriptor, entryName: "a.bin"),
                       "\"a.bin\" keeps its sizes after its data (a data descriptor), which is not supported.")
        XCTAssertEqual(ZipStoreReader.message(.unsafeName, entryName: "../a"), "The archive holds an entry with an unsafe name (\"../a\").")
        XCTAssertEqual(ZipStoreReader.message(.duplicateName, entryName: "a.bin"), "The archive holds \"a.bin\" more than once.")
        XCTAssertEqual(ZipStoreReader.message(.specialFile, entryName: "a"), "\"a\" is a link or a special file, not a plain file.")
        XCTAssertEqual(ZipStoreReader.message(.tooManyEntries), "The archive holds more than 4096 entries.")
        XCTAssertEqual(ZipStoreReader.message(.sizeMismatch, entryName: "a.bin"), "\"a.bin\" declares sizes that do not match its data.")
    }

    func test_messages_showHostileNamesSafely() {
        // Controls, line separators and text-reordering marks become U+FFFD; past 80 scalars the name is cut.
        XCTAssertEqual(ZipStoreReader.displayName("a\u{0}b\u{1F}c\u{7F}d\u{85}e\u{202E}f\u{2028}g\u{2066}h"),
                       "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e\u{FFFD}f\u{FFFD}g\u{FFFD}h")
        XCTAssertEqual(ZipStoreReader.displayName("a\u{200E}\u{200F}\u{61C}\u{2069}b"), "a\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}b")
        XCTAssertEqual(Array(ZipStoreReader.displayName("na\u{EF}ve \u{65E5}\u{672C} e\u{301} \u{200D}").unicodeScalars),
                       Array("na\u{EF}ve \u{65E5}\u{672C} e\u{301} \u{200D}".unicodeScalars))
        XCTAssertEqual(ZipStoreReader.displayName(String(repeating: "a", count: 80)), String(repeating: "a", count: 80))
        XCTAssertEqual(ZipStoreReader.displayName(String(repeating: "a", count: 81)), String(repeating: "a", count: 80) + "\u{2026}")
        // Scalars, not Characters or UTF-16 units: an astral character counts once.
        XCTAssertEqual(ZipStoreReader.displayName(String(repeating: "a", count: 79) + "\u{1F600}b"),
                       String(repeating: "a", count: 79) + "\u{1F600}\u{2026}")
        XCTAssertEqual(ZipStoreReader.displayName(""), "")

        let hostile = "x\n\nThis file needs an update. Go to evil.example and sign in.\n" + String(repeating: "a", count: 60_000)
        let shown = "x\u{FFFD}\u{FFFD}This file needs an update. Go to evil.example and sign in.\u{FFFD}"
            + String(repeating: "a", count: 18) + "\u{2026}"
        XCTAssertEqual(ZipStoreReader.message(.unsafeName, entryName: hostile), "The archive holds an entry with an unsafe name (\"\(shown)\").")
        var error = assertRefused(.unsafeName, RawZip.build([RawEntry(hostile, bytes("hi"))]))
        XCTAssertEqual(error?.message, "The archive holds an entry with an unsafe name (\"\(shown)\").")
        XCTAssertEqual(error?.entryName, hostile)
        // A name that is safe as a path but reorders its text, refused for its method.
        error = assertRefused(.unsupportedMethod, RawZip.build([RawEntry("invoice\u{202E}fdp.exe", bytes("hi")).with { $0.method = 8 }]))
        XCTAssertEqual(error?.message,
                       "\"invoice\u{FFFD}fdp.exe\" is compressed. Only archives of uncompressed (stored) entries can be read.")
    }

    @discardableResult
    private func assertRefused(_ kind: ZipReadErrorKind, _ zip: Data, _ label: String = "", limits: ZipReadLimits = .standard,
                               file: StaticString = #filePath, line: UInt = #line) -> ZipReadError? {
        do {
            let reader = try ZipStoreReader(data: zip, limits: limits)
            for entry in reader.entries { _ = try reader.read(entry) }
            XCTFail("Not refused: \(label)", file: file, line: line)
            return nil
        } catch let error as ZipReadError {
            XCTAssertEqual(error.kind, kind, label, file: file, line: line)
            XCTAssertEqual(error.message, ZipStoreReader.message(kind, entryName: error.entryName, limits: limits), file: file, line: line)
            return error
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
            return nil
        }
    }
}

/// One entry of a hand-built archive; every field the tests bend is settable.
struct RawEntry {
    var name: [UInt8]
    var data: [UInt8]
    var flags: UInt16 = 0
    var method: UInt16 = 0
    var crc: UInt32?
    var localFlags: UInt16?
    var localMethod: UInt16?
    var localCrc: UInt32?
    var compressed: UInt32?
    var size: UInt32?
    var madeBy: UInt16 = 20
    var external: UInt32 = 0
    var localExtra: [UInt8] = []
    var centralExtra: [UInt8] = []
    var localCompressed: UInt32?
    var localSize: UInt32?
    var localName: [UInt8]?
    var centralOffset: UInt32?

    init(_ name: String, _ data: [UInt8]) {
        self.name = Array(name.utf8)
        self.data = data
    }

    init(bytes name: [UInt8], _ data: [UInt8]) {
        self.name = name
        self.data = data
    }

    func with(_ change: (inout RawEntry) -> Void) -> RawEntry {
        var copy = self
        change(&copy)
        return copy
    }
}

/// How a hand-built archive's end record and layout are bent.
struct RawEnd {
    var prefix: [UInt8] = []
    var gap = 0
    var comment: [UInt8] = []
    var zip64Locator = false
    var disk: UInt16 = 0
    var count: UInt16?
    var onDisk: UInt16?
    var directorySizeDelta = 0
    var directoryOffset: UInt32?
    var secondOffsetFromFirst = false

    func with(_ change: (inout RawEnd) -> Void) -> RawEnd {
        var copy = self
        change(&copy)
        return copy
    }
}

/// Builds archives byte by byte the way ZipStore does (stored, 1980-01-01), with any field bent for
/// the malicious cases; the same builder is in ZipStoreReaderTests.cs.
enum RawZip {
    /// An extra-field block: its id, its size and that many zero bytes.
    static func extra(_ id: UInt16, _ size: Int) -> [UInt8] {
        [UInt8(id & 0xFF), UInt8(id >> 8), UInt8(size & 0xFF), UInt8(size >> 8)] + [UInt8](repeating: 0, count: size)
    }

    static func build(_ entries: [RawEntry], _ end: RawEnd = RawEnd()) -> Data {
        var output = end.prefix
        var central: [UInt8] = []
        var offsets: [UInt32] = []
        for entry in entries {
            let crc = entry.crc ?? ZipStore.crc32(entry.data)
            let size = entry.size ?? UInt32(entry.data.count)
            let compressed = entry.compressed ?? UInt32(entry.data.count)
            let offset = UInt32(output.count)
            offsets.append(offset)
            let localName = entry.localName ?? entry.name
            u32(&output, 0x0403_4B50); u16(&output, 10); u16(&output, entry.localFlags ?? entry.flags)
            u16(&output, entry.localMethod ?? entry.method)
            u16(&output, 0); u16(&output, 0x21); u32(&output, entry.localCrc ?? crc)
            u32(&output, entry.localCompressed ?? compressed); u32(&output, entry.localSize ?? size)
            u16(&output, UInt16(localName.count)); u16(&output, UInt16(entry.localExtra.count))
            output += localName
            output += entry.localExtra
            output += entry.data

            let centralOffset = entry.centralOffset ?? (end.secondOffsetFromFirst && offsets.count == 2 ? offsets[0] : offset)
            u32(&central, 0x0201_4B50); u16(&central, entry.madeBy); u16(&central, 10); u16(&central, entry.flags)
            u16(&central, entry.method); u16(&central, 0); u16(&central, 0x21); u32(&central, crc)
            u32(&central, compressed); u32(&central, size); u16(&central, UInt16(entry.name.count))
            u16(&central, UInt16(entry.centralExtra.count)); u16(&central, 0); u16(&central, 0); u16(&central, 0)
            u32(&central, entry.external); u32(&central, centralOffset)
            central += entry.name
            central += entry.centralExtra
        }
        output += [UInt8](repeating: 0, count: end.gap)
        let directoryOffset = UInt32(output.count)
        output += central
        if end.zip64Locator {
            u32(&output, 0x0706_4B50); u32(&output, 0); u32(&output, 0); u32(&output, 0); u32(&output, 1)
        }
        u32(&output, 0x0605_4B50); u16(&output, end.disk); u16(&output, 0)
        u16(&output, end.onDisk ?? UInt16(entries.count)); u16(&output, end.count ?? UInt16(entries.count))
        u32(&output, UInt32(central.count + end.directorySizeDelta)); u32(&output, end.directoryOffset ?? directoryOffset)
        u16(&output, UInt16(end.comment.count))
        output += end.comment
        return Data(output)
    }

    private static func u16(_ b: inout [UInt8], _ v: UInt16) {
        b.append(UInt8(v & 0xFF))
        b.append(UInt8(v >> 8))
    }

    private static func u32(_ b: inout [UInt8], _ v: UInt32) {
        for i in 0..<4 { b.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }
}
