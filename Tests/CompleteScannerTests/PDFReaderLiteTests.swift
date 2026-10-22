import XCTest
import CoreGraphics
import Foundation
@testable import CompleteScannerKit

// Mirrors the cross-reference, page tree, facts and refusal cases of
// windows/CompleteScanner.Core.Tests/PdfReaderLiteTests.cs, over the same fixtures (PDFFixtures.swift)
// and our own files from PDFWriter; its syntax and filter cases are PDFSyntaxTests'. C#'s theories
// are loops over the same inline data. The stream case also opens the file from disk, the path
// C#'s Open takes.

final class PDFReaderLiteTests: XCTestCase {
    private func read(_ pdf: [UInt8]) throws -> PDFReaderLite {
        try PDFReaderLite(data: Data(pdf))
    }

    /// The error reading `pdf` throws; nil (and a failure) when it reads.
    private func refused(_ pdf: [UInt8], line: UInt = #line) -> PDFReadError? {
        do {
            _ = try read(pdf)
            XCTFail("The file was read.", line: line)
            return nil
        } catch {
            XCTAssertTrue(error is PDFReadError, "\(error)", line: line)
            return error as? PDFReadError
        }
    }

    private func replace(_ pdf: [UInt8], _ from: String, _ to: String, line: UInt = #line) -> [UInt8] {
        let text = String(bytes: pdf, encoding: .isoLatin1)!
        XCTAssertNotNil(text.range(of: from, options: .literal), from, line: line)
        return PDFFixture.latin1(text.replacingOccurrences(of: from, with: to, options: .literal))
    }

    /// Where `needle` first is in `pdf`; -1 when it is not.
    private func offset(of needle: String, in pdf: [UInt8]) -> Int {
        let pattern = PDFFixture.latin1(needle)
        var start = 0
        while start + pattern.count <= pdf.count {
            if Array(pdf[start..<(start + pattern.count)]) == pattern { return start }
            start += 1
        }
        return -1
    }

    // MARK: - Cross-reference layouts

    func test_classic_readsTheTreeAndTheTrailer() throws {
        let reader = try read(PDFFixture.classic())
        XCTAssertEqual(reader.version, "1.4")
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertEqual(reader.sectionCount, 1)
        XCTAssertNil(reader.latestPrev)
        XCTAssertFalse(reader.xrefIsStream)
        XCTAssertFalse(reader.isHybrid)
        XCTAssertFalse(reader.hasObjectStreams)
        XCTAssertFalse(reader.isEncrypted)
        XCTAssertFalse(try reader.isSigned)
        XCTAssertNil(try reader.pdfAPart)
        XCTAssertEqual(reader.nextObjectNumber, 9)
        XCTAssertEqual(reader.pages.map(\.number), [3, 4])
        XCTAssertEqual(reader.trailer["Info"] as? PDFReference, PDFReference(8, 0))
    }

    func test_classic_readsAnyEndOfLine_andAFileWithoutAFinalOne() throws {
        let cases: [(newline: String, finalNewline: Bool)] = [("\r\n", true), ("\r", true), ("\n", false)]
        for (newline, finalNewline) in cases {
            let reader = try read(PDFFixture.classic(newline: newline, finalNewline: finalNewline))
            XCTAssertEqual(reader.pageCount, 2, "\(Array(newline.utf8)) \(finalNewline)")
        }
    }

    func test_alreadyUpdated_theNewestRevisionWins() throws {
        let reader = try read(PDFFixture.alreadyUpdated())
        XCTAssertEqual(reader.sectionCount, 2)
        XCTAssertEqual(reader.latestPrev, PDFFixture.startXrefOf(PDFFixture.classic()))
        XCTAssertEqual(reader.pages.map(\.number), [3, 4, 9])
        XCTAssertEqual(reader.nextObjectNumber, 11)
        // Root and Info come from the newest trailer; the /ID only the first one has.
        XCTAssertTrue(reader.trailer["ID"] is PDFArray)
        let pages = try XCTUnwrap(reader.get(2) as? PDFDictionary)
        XCTAssertEqual((pages["Count"] as? PDFNumber)?.integer, 3)
    }

    func test_objectStreams_readsCompressedObjects() throws {
        let cases: [(flate: Bool, predictor: Int)] = [(true, 12), (true, 10), (false, 12)]
        for (flate, predictor) in cases {
            let label = "flate \(flate), predictor \(predictor)"
            let reader = try read(PDFFixture.objectStreams(flateObjectStream: flate, predictor: predictor))
            XCTAssertTrue(reader.xrefIsStream, label)
            XCTAssertTrue(reader.hasObjectStreams, label)
            XCTAssertEqual(reader.version, "1.5", label)
            XCTAssertEqual(reader.pageCount, 2, label)
            XCTAssertEqual(reader.nextObjectNumber, 12, label)
            let font = try XCTUnwrap(reader.get(7) as? PDFDictionary, label)
            XCTAssertEqual((font["Type"] as? PDFName)?.value, "Font", label)
        }
    }

    func test_hybrid_findsWhatOnlyTheStreamLists() throws {
        let reader = try read(PDFFixture.hybrid())
        XCTAssertTrue(reader.isHybrid)
        XCTAssertFalse(reader.xrefIsStream)
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertTrue(try reader.get(1) is PDFDictionary)
        XCTAssertTrue(try reader.get(5) is PDFStream)
    }

    func test_pageTree_nestedNodesAndIndirectKids_inReadingOrder() throws {
        XCTAssertEqual(try read(PDFFixture.nested()).pages.map(\.number), [4, 5, 6])
        let indirect = try read(PDFFixture.indirectKids())
        XCTAssertEqual(indirect.pageCount, 1)
        XCTAssertEqual(indirect.generationOf(2), 1)
    }

    func test_ourOwnFiles_readBack() throws {
        let line = OCRLine(text: "Çağrı", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1), confidence: 1)
        let page = PDFPageInput(jpegData: PDFWriterTests.tinyJPEGData, pixelWidth: 100, pixelHeight: 150, dpi: 300,
                                ocrLines: [line])
        let plain = try PDFReaderLite(data: PDFWriter.make([page, page, page]))
        XCTAssertEqual(plain.pageCount, 3)
        let archival = try PDFReaderLite(data: PDFWriter.make([page], options: PDFWriteOptions(conformance: .pdfA2b)))
        XCTAssertEqual(try archival.pdfAPart, 2)
        XCTAssertEqual(try archival.pdfAConformance, "B")
        XCTAssertEqual(try archival.outputIntentComponents, 3)
        let protection = try PDFProtection("pw")
        let encrypted = try PDFReaderLite(data: PDFWriter.make([page], options: PDFWriteOptions(protection: protection)))
        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertEqual(encrypted.pageCount, 0)
    }

    func test_readsFromAStream_aFewBlocksAtATime() throws {
        let page = PDFPageInput(jpegData: Data(count: 200_000), pixelWidth: 100, pixelHeight: 150, dpi: 300, ocrLines: nil)
        let pdf = try PDFWriter.make([page, page, page])
        let reader = try PDFReaderLite(length: pdf.count) { offset, count in
            [UInt8](pdf.subdata(in: offset..<(offset + count)))
        }
        XCTAssertEqual(reader.pageCount, 3)
        XCTAssertEqual(reader.length, pdf.count)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString).pdf")
        try pdf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PDFReaderLite.open(path: url.path)
        defer { file.close() }
        XCTAssertEqual(file.pageCount, 3)
        XCTAssertEqual(file.length, pdf.count)
    }

    // MARK: - Facts

    func test_signed_bySignatureFlagsOrPermissions() throws {
        XCTAssertTrue(try read(PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 3>>")).isSigned)
        XCTAssertTrue(try read(PDFFixture.withCatalog("/Perms <</DocMDP 4 0 R>>", extra: { f in _ = f.obj(4, "<<>>") })).isSigned)
        XCTAssertFalse(try read(PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 2>>")).isSigned)
    }

    func test_certified_byADocMDPSignatureOnly() throws {
        let certified = try read(PDFFixture.withCatalog("/Perms 4 0 R", extra: { f in
            _ = f.obj(4, "<</DocMDP 5 0 R>>").obj(5, "<</Type /Sig>>")
        }))
        XCTAssertTrue(try certified.isCertified)
        XCTAssertTrue(try certified.isSigned)
        let usageRights = try read(PDFFixture.withCatalog("/Perms <</UR3 4 0 R>>", extra: { f in _ = f.obj(4, "<<>>") }))
        XCTAssertFalse(try usageRights.isCertified)
        XCTAssertTrue(try usageRights.isSigned)
        XCTAssertFalse(try read(PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 3>>")).isCertified)
        XCTAssertFalse(try read(PDFFixture.classic()).isCertified)
    }

    func test_objectsReadWhenAskedFor_throwWhenTheyDoNotHoldUp() throws {
        // The page tree reads fine; the form's entry points at another object.
        let pdf = replace(PDFFixture.withCatalog("/AcroForm 4 0 R", extra: { f in _ = f.obj(4, "<</Fields [] /SigFlags 3>>") }),
                          "4 0 obj", "5 0 obj")
        let reader = try read(pdf)
        XCTAssertEqual(reader.pageCount, 1)
        XCTAssertThrowsError(try reader.isSigned) { error in
            XCTAssertEqual((error as? PDFReadError)?.problem, .damaged)
        }
    }

    func test_pdfA_readFromTheMetadata() throws {
        let a1 = try read(PDFFixture.pdfA(part: 1, conformance: "A"))
        XCTAssertEqual(try a1.pdfAPart, 1)
        XCTAssertEqual(try a1.pdfAConformance, "A")
        let compressed = try read(PDFFixture.pdfA(part: 3, conformance: "u", components: 4, compressedXmp: true))
        XCTAssertEqual(try compressed.pdfAPart, 3)
        XCTAssertEqual(try compressed.pdfAConformance, "U")
        XCTAssertEqual(try compressed.outputIntentComponents, 4)
        let elements = PDFReaderLite.readPdfAId(xmp: PDFFixture.xmp(part: 2, conformance: "B", asElements: true))
        XCTAssertEqual(elements.part, 2)
        XCTAssertEqual(elements.conformance, "B")
        let broken = PDFReaderLite.readPdfAId(xmp: Array("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><broken".utf8))
        XCTAssertNil(broken.part)
        XCTAssertNil(broken.conformance)
        XCTAssertNil(try read(PDFFixture.classic()).pdfAPart)
    }

    // MARK: - Refused

    func test_refuses_notAPdf_andBytesBeforeTheHeader() {
        XCTAssertEqual(refused(Array("hello, this is text".utf8))?.problem, .notPdf)
        XCTAssertEqual(refused(Array("junk\n".utf8) + PDFFixture.classic())?.problem, .unsupported)
    }

    func test_refuses_aTruncatedFile() {
        let pdf = PDFFixture.classic()
        XCTAssertEqual(refused(Array(pdf[..<(pdf.count / 2)]))?.problem, .damaged)
        XCTAssertEqual(refused(Array(pdf.dropLast(8)))?.problem, .damaged)
    }

    func test_refuses_offsetsThatDoNotHoldUp() {
        let pdf = PDFFixture.classic()
        let xref = PDFFixture.startXrefOf(pdf)
        // startxref off by one byte into the table.
        XCTAssertEqual(refused(replace(pdf, "startxref\n\(xref)", "startxref\n\(xref + 1)"))?.problem, .damaged)
        // An object listed where another one is.
        let catalogEntry = "\(PDFObjectWriter.padded(offset(of: "1 0 obj", in: pdf), digits: 10)) 00000 n"
        let pagesEntry = "\(PDFObjectWriter.padded(offset(of: "2 0 obj", in: pdf), digits: 10)) 00000 n"
        XCTAssertEqual(refused(replace(pdf, catalogEntry, pagesEntry))?.problem, .damaged)
    }

    func test_refuses_aPrevLoop() {
        let pdf = PDFFixture.alreadyUpdated()
        let first = PDFFixture.startXrefOf(PDFFixture.classic())
        let last = PDFFixture.startXrefOf(pdf)
        XCTAssertEqual(refused(replace(pdf, "/Prev \(first)", "/Prev \(last)"))?.problem, .damaged)
    }

    func test_refuses_aPageTreeLoop_andAMissingTree() {
        XCTAssertEqual(refused(replace(PDFFixture.classic(), "/Kids [3 0 R 4 0 R]", "/Kids [2 0 R 4 0 R]"))?.problem, .damaged)
        XCTAssertEqual(refused(replace(PDFFixture.classic(), "/Pages 2 0 R>>", "/Pagez 2 0 R>>"))?.problem, .damaged)
    }

    func test_refuses_aTreeWhoseRootIsAPage() throws {
        let f = PDFFixture()
        f.obj(1, "<</Type /Catalog /Pages 3 0 R>>")
        f.obj(3, "<</Type /Page /MediaBox [0 0 612 792] /Resources <<>>>>")
        f.table("/Size 4 /Root 1 0 R")
        let error = refused(f.toArray())
        XCTAssertEqual(error?.problem, .damaged)
        XCTAssertEqual(error?.detail, "The page tree's root has no /Kids.")
        // A root without /Type still counts as a node when it has kids.
        let untyped = replace(PDFFixture.withCatalog(""), "<</Type /Pages /Kids", "<<             /Kids")
        XCTAssertEqual(try read(untyped).pageCount, 1)
    }

    func test_refuses_objectNumbersPastPdfsLimit() throws {
        let pdf = PDFFixture.withCatalog("")
        XCTAssertEqual(try read(replace(pdf, "/Size 6 ", "/Size 8388608 ")).nextObjectNumber, 8_388_608)
        XCTAssertEqual(refused(replace(pdf, "/Size 6 ", "/Size 8388609 "))?.problem, .damaged)
        XCTAssertEqual(refused(replace(pdf, "/Size 6 ", "/Size 2147483647 "))?.problem, .damaged)
        // A table subsection that runs past it.
        let subsection = refused(replace(pdf, "xref\n0 4\n", "xref\n8388605 4\n"))
        XCTAssertTrue(subsection?.detail.contains("highest object number") == true, subsection?.detail ?? "")
        // A cross-reference stream's /Size and /Index.
        let streams = PDFFixture.objectStreams()
        XCTAssertEqual(refused(replace(streams, "/Size 12 ", "/Size 8388609 "))?.problem, .damaged)
        let index = refused(replace(streams, "/Index [0 ", "/Index [8388605 "))
        XCTAssertTrue(index?.detail.contains("highest object number") == true, index?.detail ?? "")
    }

    func test_refuses_aStreamFilterItCannotUndo() {
        let pdf = PDFFixture.objectStreams()
        XCTAssertEqual(refused(replace(pdf, "/Filter /FlateDecode /DecodeParms", "/Filter /LZWDecode /DecodeParms"))?.problem,
                       .unsupported)
    }

    func test_encrypted_isReported_notRead() throws {
        let pdf = PDFFixture.withCatalog("", extra: { f in _ = f.obj(4, "<</Filter /Standard /V 2 /R 3>>") })
        let reader = try read(replace(pdf, "/Size 6 /Root 1 0 R", "/Size 6 /Root 1 0 R /Encrypt 4 0 R"))
        XCTAssertTrue(reader.isEncrypted)
        XCTAssertEqual(reader.pageCount, 0)
    }
}
