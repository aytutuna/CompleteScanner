import XCTest
import Foundation
import CoreGraphics
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/CompanionPackageTests.cs: the same cases, the same
// golden package (CompanionFixtures: written by the Windows writer and pinned there as hex, length
// and SHA-256), which this writer must reproduce byte for byte and this reader must decode. The
// Windows-only case that opens the package with System.IO.Compression has no twin here.

final class CompanionPackageTests: XCTestCase {
    func test_golden_manifestText() {
        XCTAssertEqual(CompanionPackage.manifestJSON(CompanionFixtures.sample), CompanionFixtures.goldenManifest)
    }

    func test_golden_packageBytesArePinned() throws {
        let package = try CompanionPackage.make(CompanionFixtures.sample)
        XCTAssertEqual(package.count, CompanionFixtures.goldenLength)
        XCTAssertEqual(CompanionPackage.sha256Hex(package), CompanionFixtures.goldenSha256)
        XCTAssertEqual(package, DocxFixtures.bytes(CompanionFixtures.goldenHex))
        XCTAssertEqual(package, try CompanionPackage.make(CompanionFixtures.sample))
    }

    func test_golden_entriesInPackageOrder() throws {
        let reader = try ZipStoreReader(data: DocxFixtures.bytes(CompanionFixtures.goldenHex))
        XCTAssertEqual(reader.entries.map(\.name), ["manifest.json", "pages/0001.jpg", "pages/0001-original.png", "pages/0002.png"])
    }

    func test_golden_decodes() throws {
        let document = try CompanionPackage.read(DocxFixtures.bytes(CompanionFixtures.goldenHex))
        XCTAssertEqual(document.title, "Résumé \"draft\" \\ 1\t\u{1}")
        XCTAssertEqual(document.writer, CompanionWriterInfo(app: "Lazy Scan", appVersion: "1.0", platform: "test"))
        XCTAssertEqual(document.created, Date(timeIntervalSince1970: 1_792_485_000))
        XCTAssertEqual(document.taskId, "receipts")
        XCTAssertEqual(document.suggestedName, "Scan 1")
        XCTAssertEqual(document.namingTemplate, "{date} {title}")
        XCTAssertEqual(document.pages.count, 2)

        let first = document.pages[0]
        assertImage(first.image, DocxFixtures.jpeg, .jpeg, 16, 12, 300, .grayscale)
        XCTAssertEqual(first.rotationQuarterTurns, 1)
        XCTAssertEqual(first.side, .front)
        XCTAssertEqual(first.sheetIndex, 0)
        assertLines(first.ocrLines, [
            OCRLine(text: "Hello", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.125), confidence: 0.98),
            OCRLine(text: "naïve 日本", boundingBox: CGRect(x: 0.000123, y: 0.75, width: 0.333333, height: 0.05), confidence: 0.5),
        ])
        assertImage(try XCTUnwrap(first.original), DocxFixtures.png, .png, 16, 12, 300, .blackWhite)
        XCTAssertEqual(first.capture, CompanionFixtures.sampleCapture)

        let second = document.pages[1]
        assertImage(second.image, DocxFixtures.png, .png, 16, 12, 200, .blackWhite)
        XCTAssertEqual(second.rotationQuarterTurns, 0)
        XCTAssertEqual(second.side, .back)
        XCTAssertEqual(second.sheetIndex, 0)
        XCTAssertEqual(second.ocrLines?.count, 0)
        XCTAssertNil(second.original)
        XCTAssertNil(second.capture)
    }

    func test_capture_roundTripsEveryKindAndBasis() throws {
        for kind in CaptureKind.allCases {
            for basis in CaptureScaleBasis.allCases {
                var capture = CompanionFixtures.sampleCapture
                capture.kind = kind
                capture.focalLength = nil
                capture.scale = CaptureScaleResult(basis: basis, size: basis == .nominal ? nil : "x", dpi: 200,
                                                   pixelWidth: 900, pixelHeight: 600, widthInches: 4.5, heightInches: 3)
                var document = CompanionFixtures.minimal
                document.pages[0].capture = capture
                let read = try CompanionPackage.read(CompanionPackage.make(document))
                XCTAssertEqual(read.pages[0].capture, capture, "\(kind) \(basis)")
            }
        }
        var unmeasured = CompanionFixtures.sampleCapture
        unmeasured.scale = nil
        unmeasured.kind = .idCard
        var plain = CompanionFixtures.minimal
        plain.pages[0].capture = unmeasured
        let expected = #""capture":{"quad":[12.5,8.25,1500,20,1490.75,2010.125,3,1998],"sourceWidth":1512,"sourceHeight":2016,"kind":"idCard","focalLength":1234.567891}}"#
        XCTAssertTrue(CompanionPackage.manifestJSON(plain).contains(expected))
        XCTAssertEqual(try CompanionPackage.read(CompanionPackage.make(plain)).pages[0].capture, unmeasured)
    }

    func test_capture_readsLenientlyAndOldPackagesHaveNone() throws {
        let m = CompanionFixtures.minimalManifest
        let facts = #""capture":{"quad":[1,2,30,2,30,40,1,40],"sourceWidth":64,"sourceHeight":48,"kind":"receipt""#

        // A package written before capture facts existed reads with none.
        XCTAssertNil(try readManifest(m.replacingOccurrences(of: "\"formatMinor\":1", with: "\"formatMinor\":0")).pages[0].capture)
        let quad = Quad(topLeft: CGPoint(x: 1, y: 2), topRight: CGPoint(x: 30, y: 2),
                        bottomRight: CGPoint(x: 30, y: 40), bottomLeft: CGPoint(x: 1, y: 40))
        XCTAssertEqual(try readCapture(m, facts + "}"), CaptureFacts(quad: quad, sourceWidth: 64, sourceHeight: 48, kind: .receipt))
        // Unknown and wrong-typed values fall back; unknown keys are ignored.
        XCTAssertEqual(try readCapture(m, facts.replacingOccurrences(of: "receipt", with: "poster") + #","glare":true}"#)?.kind,
                       .document)
        XCTAssertNil(try XCTUnwrap(try readCapture(m, facts + #","focalLength":"wide"}"#)).focalLength)
        XCTAssertNil(try XCTUnwrap(try readCapture(m, facts + #","focalLength":-3}"#)).focalLength)
        let moon = facts + #","scale":{"basis":"moon","dpi":200,"pixelWidth":29,"pixelHeight":38,"widthInches":0.145,"heightInches":0.19}}"#
        XCTAssertEqual(try readCapture(m, moon)?.scale?.basis, .nominal)
        let noDpi = facts + #","scale":{"basis":"paper","dpi":0,"pixelWidth":29,"pixelHeight":38,"widthInches":1,"heightInches":1}}"#
        XCTAssertNil(try XCTUnwrap(try readCapture(m, noDpi)).scale)
        XCTAssertNil(try XCTUnwrap(try readCapture(m, facts + #","scale":"a4"}"#)).scale)
        // Facts that cannot be used are left out, and the page still reads.
        XCTAssertNil(try readCapture(m, facts.replacingOccurrences(of: "[1,2,30,2,30,40,1,40]", with: "[1,2,30,2,30,40,1]") + "}"))
        XCTAssertNil(try readCapture(m, facts.replacingOccurrences(of: "[1,2,30,2,30,40,1,40]", with: #"[1,2,30,2,30,40,1,"x"]"#) + "}"))
        XCTAssertNil(try readCapture(m, facts.replacingOccurrences(of: #""sourceWidth":64"#, with: #""sourceWidth":0"#) + "}"))
        XCTAssertNil(try readCapture(m, facts.replacingOccurrences(of: #","sourceHeight":48"#, with: "") + "}"))
        XCTAssertNil(try readCapture(m, #""capture":[1,2]"#))
        XCTAssertNil(try readCapture(m, #""capture":null"#))
    }

    func test_minimal_roundTripsWithDefaults() throws {
        XCTAssertEqual(CompanionPackage.manifestJSON(CompanionFixtures.minimal), CompanionFixtures.minimalManifest)
        let document = try CompanionPackage.read(CompanionPackage.make(CompanionFixtures.minimal))
        XCTAssertEqual(document.title, "Scan")
        XCTAssertEqual(document.writer, CompanionWriterInfo(app: "Lazy Scan", appVersion: "", platform: ""))
        XCTAssertNil(document.created)
        XCTAssertNil(document.taskId)
        XCTAssertNil(document.suggestedName)
        XCTAssertNil(document.namingTemplate)
        XCTAssertEqual(document.pages.count, 1)
        let page = document.pages[0]
        assertImage(page.image, DocxFixtures.jpeg, .jpeg, 16, 12, 300, .color)
        XCTAssertEqual(page.rotationQuarterTurns, 0)
        XCTAssertNil(page.side)
        XCTAssertNil(page.sheetIndex)
        XCTAssertNil(page.ocrLines)
        XCTAssertNil(page.original)
    }

    func test_tiff_forBlackAndWhitePages() throws {
        let tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        let document = CompanionDocument(title: "T", pages: [CompanionPage(image: CompanionImage(
            data: tiff, format: .tiff, pixelWidth: 8, pixelHeight: 8, dpi: 300, colorMode: .blackWhite))])
        let package = try CompanionPackage.make(document)
        XCTAssertEqual(try ZipStoreReader(data: package).entries[1].name, "pages/0001.tif")
        let read = try CompanionPackage.read(package)
        assertImage(read.pages[0].image, tiff, .tiff, 8, 8, 300, .blackWhite)

        let gray = CompanionDocument(title: "T", pages: [CompanionPage(image: CompanionImage(
            data: tiff, format: .tiff, pixelWidth: 8, pixelHeight: 8, dpi: 300, colorMode: .grayscale))])
        let error = assertWriteRefused(.invalidDocument, gray)
        XCTAssertEqual(error?.message, "Page 1's picture is a TIFF, which only black & white pages can be.")
    }

    func test_created_isWrittenInUtcToTheSecond() {
        var document = CompanionFixtures.minimal
        document.created = Date(timeIntervalSince1970: 1_792_485_000.5)
        XCTAssertTrue(CompanionPackage.manifestJSON(document).contains("\"created\":\"2026-10-20T08:30:00Z\","))
    }

    func test_write_refusals() {
        let jpeg = CompanionImage(data: DocxFixtures.jpeg, format: .jpeg, pixelWidth: 16, pixelHeight: 12, dpi: 300, colorMode: .color)
        func with(_ change: (inout CompanionImage) -> Void) -> CompanionImage {
            var copy = jpeg
            change(&copy)
            return copy
        }
        XCTAssertEqual(assertWriteRefused(.noPages, CompanionDocument(title: "x", pages: []))?.message, "This document has no pages.")
        XCTAssertEqual(assertWriteRefused(.tooManyPages, CompanionDocument(
            title: "x", pages: Array(repeating: CompanionPage(image: jpeg), count: 2001)))?.message,
                       "This document has more than 2000 pages.")
        XCTAssertEqual(assertWriteRefused(.invalidDocument, CompanionDocument(
            title: "x", pages: [CompanionPage(image: with { $0.format = .png })]))?.message,
                       "Page 1's picture is not a PNG file.")
        XCTAssertEqual(assertWriteRefused(.invalidDocument, CompanionDocument(
            title: "x", pages: [CompanionPage(image: jpeg), CompanionPage(image: jpeg, original: with { $0.data = Data([1, 2, 3]) })]))?.message,
                       "Page 2's original picture is not a JPEG file.")
        XCTAssertEqual(assertWriteRefused(.invalidDocument, CompanionDocument(
            title: "x", pages: [CompanionPage(image: with { $0.dpi = 0 })]))?.message,
                       "Page 1's picture needs a size in pixels and a resolution.")
        assertWriteRefused(.invalidDocument, CompanionDocument(title: "x", pages: [CompanionPage(image: with { $0.pixelWidth = 0 })]))
        XCTAssertEqual(assertWriteRefused(.invalidDocument, CompanionDocument(
            title: "x", pages: [CompanionPage(image: jpeg, rotationQuarterTurns: 4)]))?.message,
                       "Page 1's rotation must be 0 to 3 quarter turns.")
        XCTAssertEqual(assertWriteRefused(.invalidDocument, CompanionDocument(
            title: "x", pages: [CompanionPage(image: jpeg, sheetIndex: -1)]))?.message,
                       "Page 1's sheet cannot be negative.")
        XCTAssertEqual(CompanionPackage.tooLargeMessage, "The document is larger than 512 MB, too large for one package.")
    }

    func test_read_isLenient() throws {
        let m = CompanionFixtures.minimalManifest
        // Unknown keys anywhere are ignored; a newer minor version reads.
        var document = try readManifest(m.replacingOccurrences(of: "\"title\":", with: "\"future\":{\"x\":[1,2]},\"title\":")
            .replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":0,\"stamp\":\"x\"")
            .replacingOccurrences(of: "\"formatMinor\":1", with: "\"formatMinor\":9"))
        XCTAssertEqual(document.title, "Scan")
        // Unknown and wrong-typed values fall back.
        var page = try readManifest(m.replacingOccurrences(of: "\"colorMode\":\"color\"", with: "\"colorMode\":\"sepia\"")
            .replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":7,\"side\":\"middle\",\"sheetIndex\":-1")
            .replacingOccurrences(of: "\"dpi\":300", with: "\"dpi\":\"x\"")
            .replacingOccurrences(of: "\"pixelWidth\":16,", with: "")).pages[0]
        XCTAssertEqual(page.image.colorMode, .color)
        XCTAssertEqual(page.rotationQuarterTurns, 0)
        XCTAssertNil(page.side)
        XCTAssertNil(page.sheetIndex)
        XCTAssertEqual(page.image.dpi, CompanionPackage.defaultDpi)
        XCTAssertEqual(page.image.pixelWidth, 0)
        XCTAssertEqual(page.image.pixelHeight, 12)

        page = try readManifest(m.replacingOccurrences(of: "\"colorMode\":\"color\"", with: "\"colorMode\":\"grayscale\"")
            .replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":\"2\",\"side\":\"back\",\"sheetIndex\":\"x\"")
            .replacingOccurrences(of: "\"dpi\":300", with: "\"dpi\":0")).pages[0]
        XCTAssertEqual(page.image.colorMode, .grayscale)
        XCTAssertEqual(page.rotationQuarterTurns, 0)
        XCTAssertEqual(page.side, .back)
        XCTAssertNil(page.sheetIndex)
        XCTAssertEqual(page.image.dpi, CompanionPackage.defaultDpi)

        page = try readManifest(m.replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":3,\"sheetIndex\":4")).pages[0]
        XCTAssertEqual(page.rotationQuarterTurns, 3)
        XCTAssertEqual(page.sheetIndex, 4)

        // Writer, created, title, OCR lines.
        document = try readManifest(m.replacingOccurrences(of: "\"writer\":{\"app\":\"Lazy Scan\",\"appVersion\":\"\",\"platform\":\"\"}",
                                                           with: "\"writer\":5,\"created\":\"yesterday\"")
            .replacingOccurrences(of: "\"title\":\"Scan\",", with: "")
            .replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":0,\"ocrLines\":[{\"text\":5,\"x\":\"a\",\"y\":0.5},{}]"))
        XCTAssertEqual(document.writer, CompanionWriterInfo(app: "", appVersion: "", platform: ""))
        XCTAssertNil(document.created)
        XCTAssertEqual(document.title, "")
        assertLines(document.pages[0].ocrLines, [
            OCRLine(text: "", boundingBox: CGRect(x: 0, y: 0.5, width: 0, height: 0), confidence: 0),
            OCRLine(text: "", boundingBox: CGRect(x: 0, y: 0, width: 0, height: 0), confidence: 0),
        ])

        XCTAssertNil(try readManifest(m.replacingOccurrences(of: "\"rotationQuarterTurns\":0",
                                                             with: "\"rotationQuarterTurns\":0,\"ocrLines\":\"none\"")).pages[0].ocrLines)
        XCTAssertEqual(try readManifest(m.replacingOccurrences(of: "\"title\":", with: "\"created\":\"2026-01-02T03:04:05Z\",\"title\":")).created,
                       Date(timeIntervalSince1970: 1_767_323_045))

        // A picture without a format is taken for what its bytes are.
        XCTAssertEqual(try readManifest(m.replacingOccurrences(of: "\"format\":\"jpeg\",", with: "")).pages[0].image.format, .jpeg)
        // A byte BOM before the JSON is skipped.
        XCTAssertEqual(try CompanionPackage.read(package("\u{FEFF}" + m)).title, "Scan")
        // UTF-16 with its byte-order mark reads.
        let utf16 = Data([0xFF, 0xFE]) + Data(m.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        XCTAssertEqual(try CompanionPackage.read(package(data: utf16)).title, "Scan")

        // Whole numbers written with a fraction or an exponent read as JSONDecoder reads them;
        // a fraction that is not whole falls back.
        document = try readManifest(m.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":1.0")
            .replacingOccurrences(of: "\"formatMinor\":1", with: "\"formatMinor\":1e0"))
        XCTAssertEqual(document.title, "Scan")
        XCTAssertEqual(try readManifest(m.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":1e0")).title, "Scan")
        page = try readManifest(m.replacingOccurrences(of: "\"pixelWidth\":16", with: "\"pixelWidth\":16.0")
            .replacingOccurrences(of: "\"pixelHeight\":12", with: "\"pixelHeight\":1.2e1")
            .replacingOccurrences(of: "\"dpi\":300", with: "\"dpi\":200.5")
            .replacingOccurrences(of: "\"byteCount\":421", with: "\"byteCount\":421.0")
            .replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":2.0,\"sheetIndex\":1E0")).pages[0]
        XCTAssertEqual(page.image.pixelWidth, 16)
        XCTAssertEqual(page.image.pixelHeight, 12)
        XCTAssertEqual(page.image.dpi, CompanionPackage.defaultDpi)
        XCTAssertEqual(page.rotationQuarterTurns, 2)
        XCTAssertEqual(page.sheetIndex, 1)
        page = try readManifest(m.replacingOccurrences(of: "\"pixelWidth\":16", with: "\"pixelWidth\":16.5")
            .replacingOccurrences(of: "\"byteCount\":421", with: "\"byteCount\":420.5")
            .replacingOccurrences(of: "\"rotationQuarterTurns\":0", with: "\"rotationQuarterTurns\":1.5,\"sheetIndex\":2147483648.0")).pages[0]
        XCTAssertEqual(page.image.pixelWidth, 0)
        XCTAssertEqual(page.rotationQuarterTurns, 0)
        XCTAssertNil(page.sheetIndex)
    }

    func test_read_refusesWhatIsNotAPackage() {
        let m = CompanionFixtures.minimalManifest
        assertReadRefused(.notPackage, ZipStore.make([ZipStoreEntry(name: "pages/0001.jpg", data: DocxFixtures.jpeg)]),
                          "This file is not a Lazy Scan document.")
        assertReadRefused(.notPackage, package(m.replacingOccurrences(of: "\"format\":\"lsdoc\"", with: "\"format\":\"other\"")))
        assertReadRefused(.notPackage, package(m.replacingOccurrences(of: "\"format\":\"lsdoc\",", with: "")))
        assertReadRefused(.notPackage, package(m.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":0")))
        assertReadRefused(.newerVersion, package(m.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2")),
                          "This document was made by a newer version of Lazy Scan (package format 2). Update Lazy Scan to open it.")
        assertReadRefused(.newerVersion, package(m.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2.0")),
                          "This document was made by a newer version of Lazy Scan (package format 2). Update Lazy Scan to open it.")
        assertReadRefused(.notPackage, package(m.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":1.5")))
        // Text that is not valid UTF-8 anywhere, in a known key's value or an unknown one's, damages
        // the whole manifest, not just that value.
        assertReadRefused(.invalidManifest,
                          package(data: withByte(m.replacingOccurrences(of: "\"title\":\"Scan\"", with: "\"title\":\"S#an\""), 0xFF)),
                          "This document cannot be opened: its list of pages is damaged.")
        assertReadRefused(.invalidManifest,
                          package(data: withByte(m.replacingOccurrences(of: "\"title\":", with: "\"future\":\"#\",\"title\":"), 0xC3)),
                          "This document cannot be opened: its list of pages is damaged.")
        for json in ["{not json", "[]", "null", "", "{\"format\":\"lsdoc\",}"] {
            assertReadRefused(.invalidManifest, package(json), "This document cannot be opened: its list of pages is damaged.")
        }
        assertReadRefused(.noPages, package(regex(m, "\"pages\":\\[.*\\]", "\"pages\":[]")), "This document has no pages.")
        assertReadRefused(.noPages, package(regex(m, "\"pages\":\\[.*\\]", "\"pages\":[null]")))
        assertReadRefused(.tooManyPages,
                          package(regex(m, "\"pages\":\\[.*\\]", "\"pages\":[" + Array(repeating: "{}", count: 2001).joined(separator: ",") + "]")),
                          "This document has more than 2000 pages.")
    }

    func test_read_refusesDamagedOrMissingPictures() throws {
        let m = CompanionFixtures.minimalManifest
        let sha = CompanionPackage.sha256Hex(DocxFixtures.jpeg)
        let damaged = "Page 1's picture is damaged: its checksum does not match."
        assertReadRefused(.checksumMismatch, package(m.replacingOccurrences(of: sha, with: "0" + sha.dropFirst())), damaged)
        assertReadRefused(.checksumMismatch, package(m.replacingOccurrences(of: "\"sha256\":\"\(sha)\",", with: "")), damaged)
        assertReadRefused(.checksumMismatch, package(m.replacingOccurrences(of: "\"byteCount\":421", with: "\"byteCount\":420")), damaged)
        // Upper-case hex is the same checksum.
        XCTAssertEqual(try readManifest(m.replacingOccurrences(of: sha, with: sha.uppercased())).title, "Scan")

        let missing = "Page 1's picture is missing from the document."
        assertReadRefused(.missingImage, package(m.replacingOccurrences(of: "pages/0001.jpg", with: "pages/0009.jpg")), missing)
        assertReadRefused(.missingImage, package(regex(m, "\"image\":\\{[^}]*\\}", "\"image\":null")), missing)
        assertReadRefused(.missingImage, package(m.replacingOccurrences(of: "\"rotationQuarterTurns\":0",
                                                                        with: "\"rotationQuarterTurns\":0,\"original\":{\"file\":\"x.png\"}")),
                          "Page 1's original picture is missing from the document.")
        assertReadRefused(.missingImage, package(m.replacingOccurrences(of: "pages/0001.jpg", with: "manifest.json")))

        let page = regex(m, "^.*\"pages\":\\[(.*)\\]\\}\\n$", "$1")
        assertReadRefused(.invalidManifest, package(m.replacingOccurrences(of: page, with: page + "," + page)),
                          "This document cannot be opened: Page 2's picture is listed twice.")

        let unsupported = "Page 1's picture is in a format this version of Lazy Scan cannot read."
        assertReadRefused(.unsupportedImage, package(m.replacingOccurrences(of: "\"format\":\"jpeg\"", with: "\"format\":\"png\"")), unsupported)
        assertReadRefused(.unsupportedImage, package(m.replacingOccurrences(of: "\"format\":\"jpeg\"", with: "\"format\":\"heic\"")), unsupported)
        let text = Data("not a picture".utf8)
        let textManifest = m.replacingOccurrences(of: sha, with: CompanionPackage.sha256Hex(text))
            .replacingOccurrences(of: "\"byteCount\":421", with: "\"byteCount\":\(text.count)")
        assertReadRefused(.unsupportedImage, ZipStore.make([ZipStoreEntry(name: "manifest.json", data: Data(textManifest.utf8)),
                                                            ZipStoreEntry(name: "pages/0001.jpg", data: text)]), unsupported)
    }

    func test_read_refusesArchivesTheZipReaderRefuses() throws {
        var damagedPackage = try CompanionPackage.make(CompanionFixtures.minimal)
        let dataOffset = try XCTUnwrap(ZipStoreReader(data: damagedPackage).entry(named: "pages/0001.jpg")).dataOffset
        damagedPackage[dataOffset + 100] ^= 0xFF
        assertReadRefused(.invalidArchive, damagedPackage,
                          "This document cannot be opened: \"pages/0001.jpg\" is damaged: its checksum does not match its data.")
        assertReadRefused(.invalidArchive,
                          RawZip.build([RawEntry("manifest.json", Array(CompanionFixtures.minimalManifest.utf8)).with { $0.method = 8 }]),
                          "This document cannot be opened: \"manifest.json\" is compressed. Only archives of uncompressed (stored) entries can be read.")
        assertReadRefused(.invalidArchive, RawZip.build([RawEntry("../manifest.json", [1])]))
        // An entry name never reaches the message as it is.
        assertReadRefused(.invalidArchive, RawZip.build([RawEntry("x\nGo to evil.example\n", [1])]),
                          "This document cannot be opened: The archive holds an entry with an unsafe name (\"x\u{FFFD}Go to evil.example\u{FFFD}\").")
        let whole = try CompanionPackage.make(CompanionFixtures.minimal)
        assertReadRefused(.invalidArchive, whole.prefix(whole.count - 5))
        var limits = ZipReadLimits.standard
        limits.maxTotalBytes = 400
        assertReadRefused(.invalidArchive, whole, limits: limits)
    }

    func test_readFile_readsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString).lsdoc")
        try DocxFixtures.bytes(CompanionFixtures.goldenHex).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try CompanionPackage.read(contentsOf: url).pages.count, 2)
    }

    func test_number_format() {
        XCTAssertEqual(CompanionPackage.number(0), "0")
        XCTAssertEqual(CompanionPackage.number(-0.0000001), "0")
        XCTAssertEqual(CompanionPackage.number(0.5), "0.5")
        XCTAssertEqual(CompanionPackage.number(-0.25), "-0.25")
        XCTAssertEqual(CompanionPackage.number(1.5), "1.5")
        XCTAssertEqual(CompanionPackage.number(2.0000004), "2")
        XCTAssertEqual(CompanionPackage.number(123.456789), "123.456789")
        XCTAssertEqual(CompanionPackage.number(0.0001234567), "0.000123")
        XCTAssertEqual(CompanionPackage.number(1.0 / 3), "0.333333")
        XCTAssertEqual(CompanionPackage.number(2.0 / 3), "0.666667")
        XCTAssertEqual(CompanionPackage.number(-2.0 / 3), "-0.666667")
        XCTAssertEqual(CompanionPackage.number(Double(Float(0.98))), "0.98")
        XCTAssertEqual(CompanionPackage.number(1e6), "1000000")
        XCTAssertEqual(CompanionPackage.number(.nan), "0")
        XCTAssertEqual(CompanionPackage.number(.infinity), "0")
        XCTAssertEqual(CompanionPackage.number(1e20), "0")
    }

    func test_quote_escapes() {
        XCTAssertEqual(CompanionPackage.quote("plain"), "\"plain\"")
        XCTAssertEqual(CompanionPackage.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(CompanionPackage.quote("\n\r\t\u{8}\u{C}\u{0}\u{1F}"), "\"\\n\\r\\t\\b\\f\\u0000\\u001f\"")
        XCTAssertEqual(CompanionPackage.quote("/ é 日本 \u{7F}"), "\"/ é 日本 \u{7F}\"")
        XCTAssertEqual(CompanionPackage.quote("\u{1F4C4}"), "\"\u{1F4C4}\"")
    }

    func test_dates() {
        XCTAssertEqual(CompanionPackage.formatDate(Date(timeIntervalSince1970: 1_792_485_000)), "2026-10-20T08:30:00Z")
        XCTAssertEqual(CompanionPackage.parseDate("2026-10-20T08:30:00Z"), Date(timeIntervalSince1970: 1_792_485_000))
        XCTAssertEqual(CompanionPackage.parseDate("2024-02-29T23:59:59Z"), Date(timeIntervalSince1970: 1_709_251_199))
        let refused = [
            "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-20T24:00:00Z", "2026-10-20T08:30:00+01:00",
            "2026-10-20T08:30:00.5Z", "2026-10-20 08:30:00Z", "2026-10-20T08:30:00", "0000-01-01T00:00:00Z", "", "yesterday",
        ]
        for text in refused { XCTAssertNil(CompanionPackage.parseDate(text), text) }
    }

    func test_sha256_knownValues() {
        func repeated(_ count: Int) -> Data { Data(repeating: UInt8(ascii: "a"), count: count) }
        XCTAssertEqual(CompanionPackage.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(CompanionPackage.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(CompanionPackage.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(CompanionPackage.sha256Hex(repeated(55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(CompanionPackage.sha256Hex(repeated(56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        XCTAssertEqual(CompanionPackage.sha256Hex(repeated(64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        XCTAssertEqual(CompanionPackage.sha256Hex(repeated(1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(CompanionPackage.sha256Hex(DocxFixtures.jpeg), "f1794218ec714df25067c3eb5ac220220d81e9eaaaac9535d5dfb163c87503b7")
        XCTAssertEqual(CompanionPackage.sha256Hex(DocxFixtures.png), "f45eb33d36e152c974c50a807e04f6e45b357376a1f584016f27ef19829b5861")
        // A slice whose indices do not start at 0 hashes like its bytes.
        let slice = Data("xxabc".utf8).dropFirst(2)
        XCTAssertEqual(CompanionPackage.sha256Hex(slice), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_sniff_andNames() {
        XCTAssertEqual(CompanionPackage.sniff(DocxFixtures.jpeg), .jpeg)
        XCTAssertEqual(CompanionPackage.sniff(DocxFixtures.png), .png)
        XCTAssertEqual(CompanionPackage.sniff(Data([0x49, 0x49, 0x2A, 0x00])), .tiff)
        XCTAssertEqual(CompanionPackage.sniff(Data([0x4D, 0x4D, 0x00, 0x2A])), .tiff)
        XCTAssertNil(CompanionPackage.sniff(Data([0xFF, 0xD8])))
        XCTAssertNil(CompanionPackage.sniff(Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertNil(CompanionPackage.sniff(Data("GIF89a".utf8)))
        XCTAssertNil(CompanionPackage.sniff(Data()))
        XCTAssertEqual(CompanionPackage.imageEntryName(1, format: .jpeg, original: false), "pages/0001.jpg")
        XCTAssertEqual(CompanionPackage.imageEntryName(12, format: .png, original: true), "pages/0012-original.png")
        XCTAssertEqual(CompanionPackage.imageEntryName(2000, format: .tiff, original: false), "pages/2000.tif")
    }

    // MARK: - Helpers

    private func assertImage(_ image: CompanionImage, _ data: Data, _ format: CompanionImageFormat, _ width: Int, _ height: Int,
                             _ dpi: Int, _ mode: ColorMode, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.data, data, file: file, line: line)
        XCTAssertEqual(image.format, format, file: file, line: line)
        XCTAssertEqual(image.pixelWidth, width, file: file, line: line)
        XCTAssertEqual(image.pixelHeight, height, file: file, line: line)
        XCTAssertEqual(image.dpi, dpi, file: file, line: line)
        XCTAssertEqual(image.colorMode, mode, file: file, line: line)
    }

    private func assertLines(_ actual: [OCRLine]?, _ expected: [OCRLine], file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("No OCR lines", file: file, line: line) }
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.text, e.text, file: file, line: line)
            XCTAssertEqual(a.boundingBox, e.boundingBox, file: file, line: line)
            XCTAssertEqual(a.confidence, e.confidence, file: file, line: line)
        }
    }

    /// A package of `manifest` and the minimal document's picture.
    private func package(_ manifest: String) -> Data {
        package(data: Data(manifest.utf8))
    }

    /// A package of the manifest bytes `manifest` and the minimal document's picture.
    private func package(data manifest: Data) -> Data {
        ZipStore.make([ZipStoreEntry(name: "manifest.json", data: manifest),
                       ZipStoreEntry(name: "pages/0001.jpg", data: DocxFixtures.jpeg)])
    }

    /// `text` as UTF-8 with its one "#" replaced by the byte `value`.
    private func withByte(_ text: String, _ value: UInt8, file: StaticString = #filePath, line: UInt = #line) -> Data {
        var bytes = Array(text.utf8)
        let hash = UInt8(ascii: "#")
        XCTAssertEqual(bytes.filter { $0 == hash }.count, 1, file: file, line: line)
        if let at = bytes.firstIndex(of: hash) { bytes[at] = value }
        return Data(bytes)
    }

    private func readManifest(_ manifest: String) throws -> CompanionDocument {
        try CompanionPackage.read(package(manifest))
    }

    /// The capture facts read back from `manifest` with `capture` (a key and its value) added to its page.
    private func readCapture(_ manifest: String, _ capture: String) throws -> CaptureFacts? {
        let edited = manifest.replacingOccurrences(of: "\"rotationQuarterTurns\":0",
                                                   with: "\"rotationQuarterTurns\":0," + capture)
        return try readManifest(edited).pages[0].capture
    }

    private func regex(_ input: String, _ pattern: String, _ template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            XCTFail("Bad pattern \(pattern)")
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return expression.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    @discardableResult
    private func assertWriteRefused(_ kind: CompanionPackageErrorKind, _ document: CompanionDocument,
                                    file: StaticString = #filePath, line: UInt = #line) -> CompanionPackageError? {
        do {
            _ = try CompanionPackage.make(document)
            XCTFail("Not refused", file: file, line: line)
            return nil
        } catch let error as CompanionPackageError {
            XCTAssertEqual(error.kind, kind, file: file, line: line)
            return error
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertReadRefused(_ kind: CompanionPackageErrorKind, _ package: Data, _ message: String? = nil,
                                   limits: ZipReadLimits = .standard, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try CompanionPackage.read(package, limits: limits)
            XCTFail("Not refused", file: file, line: line)
        } catch let error as CompanionPackageError {
            XCTAssertEqual(error.kind, kind, file: file, line: line)
            if let message { XCTAssertEqual(error.message, message, file: file, line: line) }
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}

/// The documents both suites package: `sample` is the golden package (its bytes pinned below, the
/// same in CompanionPackageTests.cs), `minimal` the one the lenient-reading cases bend.
enum CompanionFixtures {
    static var sample: CompanionDocument {
        CompanionDocument(
            title: "Résumé \"draft\" \\ 1\t\u{1}",
            pages: [
                CompanionPage(
                    image: CompanionImage(data: DocxFixtures.jpeg, format: .jpeg, pixelWidth: 16, pixelHeight: 12, dpi: 300,
                                          colorMode: .grayscale),
                    rotationQuarterTurns: 1, side: .front, sheetIndex: 0,
                    ocrLines: [
                        OCRLine(text: "Hello", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.125), confidence: 0.98),
                        OCRLine(text: "naïve 日本", boundingBox: CGRect(x: 0.0001234567, y: 0.75, width: 0.333333333, height: 0.05),
                                confidence: 0.5),
                    ],
                    original: CompanionImage(data: DocxFixtures.png, format: .png, pixelWidth: 16, pixelHeight: 12, dpi: 300,
                                             colorMode: .blackWhite),
                    capture: sampleCapture),
                CompanionPage(
                    image: CompanionImage(data: DocxFixtures.png, format: .png, pixelWidth: 16, pixelHeight: 12, dpi: 200,
                                          colorMode: .blackWhite),
                    side: .back, sheetIndex: 0, ocrLines: []),
            ],
            writer: CompanionWriterInfo(app: "Lazy Scan", appVersion: "1.0", platform: "test"),
            created: Date(timeIntervalSince1970: 1_792_485_000),
            taskId: "receipts", suggestedName: "Scan 1", namingTemplate: "{date} {title}")
    }

    /// The first sample page's capture facts: corners with fractions, a focal length, an A4 scale.
    static var sampleCapture: CaptureFacts {
        let quad = Quad(topLeft: CGPoint(x: 12.5, y: 8.25), topRight: CGPoint(x: 1500, y: 20),
                        bottomRight: CGPoint(x: 1490.75, y: 2010.125), bottomLeft: CGPoint(x: 3, y: 1998))
        let scale = CaptureScaleResult(basis: .paper, size: "a4", dpi: 300, pixelWidth: 2480, pixelHeight: 3508,
                                       widthInches: 8.2677, heightInches: 11.6929)
        return CaptureFacts(quad: quad, sourceWidth: 1512, sourceHeight: 2016, kind: .document,
                            focalLength: 1234.567891, scale: scale)
    }

    static var minimal: CompanionDocument {
        CompanionDocument(title: "Scan", pages: [CompanionPage(image: CompanionImage(
            data: DocxFixtures.jpeg, format: .jpeg, pixelWidth: 16, pixelHeight: 12, dpi: 300, colorMode: .color))])
    }

    static let goldenManifest =
        #"{"format":"lsdoc","formatVersion":1,"formatMinor":1,"writer":{"app":"Lazy Scan","appVersion":"1.0","platform":"test"},"created":"2026-10-20T08:30:00Z","title":"Résumé \"draft\" \\ 1\t\u0001","taskId":"receipts","naming":{"suggestedName":"Scan 1","template":"{date} {title}"},"pages":[{"image":{"file":"pages/0001.jpg","format":"jpeg","byteCount":421,"sha256":"f1794218ec714df25067c3eb5ac220220d81e9eaaaac9535d5dfb163c87503b7","pixelWidth":16,"pixelHeight":12,"dpi":300,"colorMode":"grayscale"},"rotationQuarterTurns":1,"side":"front","sheetIndex":0,"ocrLines":[{"text":"Hello","x":0.1,"y":0.2,"width":0.5,"height":0.125,"confidence":0.98},{"text":"naïve 日本","x":0.000123,"y":0.75,"width":0.333333,"height":0.05,"confidence":0.5}],"capture":{"quad":[12.5,8.25,1500,20,1490.75,2010.125,3,1998],"sourceWidth":1512,"sourceHeight":2016,"kind":"document","focalLength":1234.567891,"scale":{"basis":"paper","size":"a4","dpi":300,"pixelWidth":2480,"pixelHeight":3508,"widthInches":8.2677,"heightInches":11.6929}},"original":{"file":"pages/0001-original.png","format":"png","byteCount":127,"sha256":"f45eb33d36e152c974c50a807e04f6e45b357376a1f584016f27ef19829b5861","pixelWidth":16,"pixelHeight":12,"dpi":300,"colorMode":"blackWhite"}},{"image":{"file":"pages/0002.png","format":"png","byteCount":127,"sha256":"f45eb33d36e152c974c50a807e04f6e45b357376a1f584016f27ef19829b5861","pixelWidth":16,"pixelHeight":12,"dpi":200,"colorMode":"blackWhite"},"rotationQuarterTurns":0,"side":"back","sheetIndex":0,"ocrLines":[]}]}"#
        + "\n"

    static let minimalManifest =
        #"{"format":"lsdoc","formatVersion":1,"formatMinor":1,"writer":{"app":"Lazy Scan","appVersion":"","platform":""},"title":"Scan","pages":[{"image":{"file":"pages/0001.jpg","format":"jpeg","byteCount":421,"sha256":"f1794218ec714df25067c3eb5ac220220d81e9eaaaac9535d5dfb163c87503b7","pixelWidth":16,"pixelHeight":12,"dpi":300,"colorMode":"color"},"rotationQuarterTurns":0}]}"#
        + "\n"

    static let goldenLength = 2644
    static let goldenSha256 = "f4798fb2ee373b4964e35f6296cd228e14847948f212a9168550c6ef94ccba61"
    static let goldenHex = [
        "504B03040A000000000000002100D62C74B7EB050000EB0500000D0000006D616E69666573742E6A736F6E7B22666F72",
        "6D6174223A226C73646F63222C22666F726D617456657273696F6E223A312C22666F726D61744D696E6F72223A312C22",
        "777269746572223A7B22617070223A224C617A79205363616E222C2261707056657273696F6E223A22312E30222C2270",
        "6C6174666F726D223A2274657374227D2C2263726561746564223A22323032362D31302D32305430383A33303A30305A",
        "222C227469746C65223A2252C3A973756DC3A9205C2264726166745C22205C5C20315C745C7530303031222C22746173",
        "6B4964223A227265636569707473222C226E616D696E67223A7B227375676765737465644E616D65223A225363616E20",
        "31222C2274656D706C617465223A227B646174657D207B7469746C657D227D2C227061676573223A5B7B22696D616765",
        "223A7B2266696C65223A2270616765732F303030312E6A7067222C22666F726D6174223A226A706567222C2262797465",
        "436F756E74223A3432312C22736861323536223A22663137393432313865633731346466323530363763336562356163",
        "32323032323064383165396561616161633935333564356466623136336338373530336237222C22706978656C576964",
        "7468223A31362C22706978656C486569676874223A31322C22647069223A3330302C22636F6C6F724D6F6465223A2267",
        "7261797363616C65227D2C22726F746174696F6E517561727465725475726E73223A312C2273696465223A2266726F6E",
        "74222C227368656574496E646578223A302C226F63724C696E6573223A5B7B2274657874223A2248656C6C6F222C2278",
        "223A302E312C2279223A302E322C227769647468223A302E352C22686569676874223A302E3132352C22636F6E666964",
        "656E6365223A302E39387D2C7B2274657874223A226E61C3AF766520E697A5E69CAC222C2278223A302E303030313233",
        "2C2279223A302E37352C227769647468223A302E3333333333332C22686569676874223A302E30352C22636F6E666964",
        "656E6365223A302E357D5D2C2263617074757265223A7B2271756164223A5B31322E352C382E32352C313530302C3230",
        "2C313439302E37352C323031302E3132352C332C313939385D2C22736F757263655769647468223A313531322C22736F",
        "75726365486569676874223A323031362C226B696E64223A22646F63756D656E74222C22666F63616C4C656E67746822",
        "3A313233342E3536373839312C227363616C65223A7B226261736973223A227061706572222C2273697A65223A226134",
        "222C22647069223A3330302C22706978656C5769647468223A323438302C22706978656C486569676874223A33353038",
        "2C227769647468496E63686573223A382E323637372C22686569676874496E63686573223A31312E363932397D7D2C22",
        "6F726967696E616C223A7B2266696C65223A2270616765732F303030312D6F726967696E616C2E706E67222C22666F72",
        "6D6174223A22706E67222C2262797465436F756E74223A3132372C22736861323536223A226634356562333364333665",
        "313532633937346335306138303765303466366534356233353733373661316635383430313666323765663139383239",
        "6235383631222C22706978656C5769647468223A31362C22706978656C486569676874223A31322C22647069223A3330",
        "302C22636F6C6F724D6F6465223A22626C61636B5768697465227D7D2C7B22696D616765223A7B2266696C65223A2270",
        "616765732F303030322E706E67222C22666F726D6174223A22706E67222C2262797465436F756E74223A3132372C2273",
        "6861323536223A2266343565623333643336653135326339373463353061383037653034663665343562333537333736",
        "613166353834303136663237656631393832396235383631222C22706978656C5769647468223A31362C22706978656C",
        "486569676874223A31322C22647069223A3230302C22636F6C6F724D6F6465223A22626C61636B5768697465227D2C22",
        "726F746174696F6E517561727465725475726E73223A302C2273696465223A226261636B222C227368656574496E6465",
        "78223A302C226F63724C696E6573223A5B5D7D5D7D0A504B03040A00000000000000210085915458A5010000A5010000",
        "0E00000070616765732F303030312E6A7067FFD8FFE000104A46494600010101012C012C0000FFDB0043000604050605",
        "0406060506070706080A100A0A09090A140E0F0C1017141818171416161A1D251F1A1B231C1616202C20232627292A29",
        "191F2D302D283025282928FFC0000B08000C001001011100FFC4001F0000010501010101010100000000000000000102",
        "030405060708090A0BFFC400B5100002010303020403050504040000017D010203000411051221314106135161072271",
        "14328191A1082342B1C11552D1F02433627282090A161718191A25262728292A3435363738393A434445464748494A53",
        "5455565758595A636465666768696A737475767778797A838485868788898A92939495969798999AA2A3A4A5A6A7A8A9",
        "AAB2B3B4B5B6B7B8B9BAC2C3C4C5C6C7C8C9CAD2D3D4D5D6D7D8D9DAE1E2E3E4E5E6E7E8E9EAF1F2F3F4F5F6F7F8F9FA",
        "FFDA0008010100003F00E13E1B685FEABE4F4AF6BF166B7FF0807C38BCD560F97529B16761F2E7F7EE0E1B9561F2A867",
        "C30C1D9B73C8AE73E1B59C3FBAF97D2B9FFDA4A5925F1FF8774D77CD95BE982E228F68F96492575739C64E4451F04E06",
        "DE3A9CFF00FFD9504B03040A000000000000002100063A73A67F0000007F0000001700000070616765732F303030312D",
        "6F726967696E616C2E706E6789504E470D0A1A0A0000000D49484452000000100000000C0100000000439C002C000000",
        "017352474200AECE1CE90000000467414D410000B18F0BFC6105000000097048597300002E2300002E230178A53F7600",
        "0000144944415418D363C8DDC6703B9761DB6D06DC0C0019EB0FF11F837D3C0000000049454E44AE426082504B03040A",
        "000000000000002100063A73A67F0000007F0000000E00000070616765732F303030322E706E6789504E470D0A1A0A00",
        "00000D49484452000000100000000C0100000000439C002C000000017352474200AECE1CE90000000467414D410000B1",
        "8F0BFC6105000000097048597300002E2300002E230178A53F76000000144944415418D363C8DDC6703B9761DB6D06DC",
        "0C0019EB0FF11F837D3C0000000049454E44AE426082504B010214000A000000000000002100D62C74B7EB050000EB05",
        "00000D00000000000000000000000000000000006D616E69666573742E6A736F6E504B010214000A0000000000000021",
        "0085915458A5010000A50100000E000000000000000000000000001606000070616765732F303030312E6A7067504B01",
        "0214000A000000000000002100063A73A67F0000007F0000001700000000000000000000000000E70700007061676573",
        "2F303030312D6F726967696E616C2E706E67504B010214000A000000000000002100063A73A67F0000007F0000000E00",
        "0000000000000000000000009B08000070616765732F303030322E706E67504B05060000000004000400F80000004609",
        "00000000",
    ].joined()
}
