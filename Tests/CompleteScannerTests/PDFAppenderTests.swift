import XCTest
import CoreGraphics
import Foundation
import PDFKit
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/PdfAppenderTests.cs: adding scanned pages to an existing
// PDF as an incremental update, over the same fixtures (PDFFixtures.swift) and our own files from
// PDFWriter, with the same fixed identifier. C# reads the results back with PdfPig, its lenient
// parsing off; here PDFReaderLite reads them strictly and PDFKit opens them (page count, sizes,
// rotation, text, the title), though PDFKit repairs what it can. A page's images are counted in its
// /Resources. The file cases use POSIX permissions and flock where C# uses ACLs, attributes and
// sharing modes: the permissions case keeps the POSIX permissions only (there are no alternate data
// streams here), a folder that takes no new files is one without write permission, another app
// holding the file is a descriptor that holds it locked, and the backup that cannot be moved back
// is one whose way back leads into a folder that is gone.

private struct Cause: Error, Equatable {
    let text: String
}

final class PDFAppenderTests: XCTestCase {
    private static let newId: [UInt8] = [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                                         0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F]
    private static let newIdHex = "101112131415161718191A1B1C1D1E1F"
    private static let fixed = PDFAppendOptions(documentId: newId)

    private static let lines: [OCRLine] = [
        OCRLine(text: "Ek sayfa: imza Çağrı Işık", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
                confidence: 0.9),
    ]

    /// A Letter page at 300 dpi (612 × 792 pt), with the text layer when asked.
    private static func page(text: Bool = false, width: Int = 2550, height: Int = 3300) -> PDFPageInput {
        PDFPageInput(jpegData: PDFWriterTests.tinyJPEGData, pixelWidth: width, pixelHeight: height, dpi: 300,
                     ocrLines: text ? lines : nil)
    }

    private static func latin1(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// The update: everything after the original.
    private static func update(_ original: [UInt8], _ appended: [UInt8]) -> String {
        latin1(Array(appended[original.count...]))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func append(_ original: [UInt8], _ pages: [PDFPageInput], _ options: PDFAppendOptions? = nil) throws -> [UInt8] {
        try [UInt8](PDFAppender.append(Data(original), pages: pages, options: options))
    }

    private func describe(_ pdf: [UInt8], _ path: String) throws -> PDFAppendTarget {
        try PDFAppender.describe(PDFReaderLite(data: Data(pdf)), path: path)
    }

    private func open(_ pdf: [UInt8], line: UInt = #line) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: Data(pdf)), line: line)
    }

    private func mediaBox(_ document: PDFDocument, _ index: Int) -> CGSize {
        document.page(at: index)?.bounds(for: .mediaBox).size ?? .zero
    }

    private func pageText(_ document: PDFDocument, _ index: Int) -> String {
        document.page(at: index)?.string ?? ""
    }

    /// The images page `index` names in its /Resources (C# counts them through PdfPig).
    private func imageCount(_ reader: PDFReaderLite, _ index: Int) throws -> Int {
        let page = try XCTUnwrap(reader.resolve(reader.pages[index]) as? PDFDictionary)
        let resources = try XCTUnwrap(reader.resolve(page["Resources"]) as? PDFDictionary)
        let images = try XCTUnwrap(reader.resolve(resources["XObject"]) as? PDFDictionary)
        return images.entries.count
    }

    /// The original is an unchanged prefix, the result reads back with every page, and its newest
    /// section points at the original's.
    @discardableResult
    private func checkAppended(_ original: [UInt8], _ appended: [UInt8], _ added: Int,
                               line: UInt = #line) throws -> PDFReaderLite {
        XCTAssertEqual(Array(appended.prefix(original.count)), original, "the original bytes are unchanged at the start",
                       line: line)
        let before = try PDFReaderLite(data: Data(original))
        let after = try PDFReaderLite(data: Data(appended))
        XCTAssertEqual(after.pageCount, before.pageCount + added, line: line)
        XCTAssertEqual(after.sectionCount, before.sectionCount + 1, line: line)
        XCTAssertEqual(after.latestPrev, before.startXref, line: line)
        XCTAssertEqual(Array(after.pages.prefix(before.pageCount)), before.pages, line: line)
        let document = try open(appended, line: line)
        XCTAssertEqual(document.pageCount, before.pageCount + added, line: line)
        return after
    }

    /// The PDFReadError `body` throws; nil (and a failure) when it throws none or another error.
    private func readError(_ body: () throws -> Void, line: UInt = #line) -> PDFReadError? {
        do {
            try body()
            XCTFail("Nothing was thrown.", line: line)
            return nil
        } catch let error as PDFReadError {
            return error
        } catch {
            XCTFail("\(error)", line: line)
            return nil
        }
    }

    /// The PDFAppendError `body` throws; nil (and a failure) when it throws none or another error.
    private func appendError(_ body: () throws -> Void, line: UInt = #line) -> PDFAppendError? {
        do {
            try body()
            XCTFail("Nothing was thrown.", line: line)
            return nil
        } catch let error as PDFAppendError {
            return error
        } catch {
            XCTFail("\(error)", line: line)
            return nil
        }
    }

    // MARK: - Our own files

    func test_ourPdf_getsPagesAfterItsUnchangedBytes() throws {
        let original = try [UInt8](PDFWriter.make([Self.page(), Self.page()]))
        let appended = try append(original, [Self.page(text: true), Self.page()], Self.fixed)
        let reader = try checkAppended(original, appended, 2)

        let document = try open(appended)
        for index in 0..<4 {
            let size = mediaBox(document, index)
            XCTAssertEqual(Double(size.width), 612, accuracy: 0.01)
            XCTAssertEqual(Double(size.height), 792, accuracy: 0.01)
            XCTAssertEqual(try imageCount(reader, index), 1)
        }
        XCTAssertTrue(pageText(document, 2).contains("Çağrı"), pageText(document, 2))
        XCTAssertEqual(pageText(document, 3).trimmingCharacters(in: .whitespacesAndNewlines), "")

        // A plain PDF's update: a classic table of the font, the pages and the tree root again.
        let update = Self.update(original, appended)
        XCTAssertTrue(update.hasPrefix("9 0 obj\n<</Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont"))
        XCTAssertTrue(update.contains("15 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</XObject <</Im0 16 0 R>> /Font <</F1 9 0 R>>>> /Contents 17 0 R /Rotate 0>>"))
        XCTAssertTrue(update.contains("18 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</XObject <</Im1 19 0 R>>>> /Contents 20 0 R /Rotate 0>>"))
        XCTAssertTrue(update.contains("2 0 obj\n<</Type /Pages /Kids [3 0 R 6 0 R 15 0 R 18 0 R] /Count 4>>\nendobj\n"))
        XCTAssertTrue(Self.matches(update, #"xref\n2 1\n\d{10} 00000 n \n9 12\n(\d{10} 00000 n \n){12}trailer\n"#))
        let id = Self.newIdHex
        let prev = reader.latestPrev ?? -1
        XCTAssertTrue(update.hasSuffix("trailer\n<</Size 21 /Root 1 0 R /ID [<\(id)> <\(id)>] /Prev \(prev)>>\nstartxref\n\(reader.startXref)\n%%EOF\n"))
    }

    func test_twice_chainsTheUpdates() throws {
        let original = try [UInt8](PDFWriter.make([Self.page()]))
        let once = try append(original, [Self.page()])
        let twice = try append(once, [Self.page(text: true), Self.page(), Self.page()])
        let reader = try checkAppended(once, twice, 3)
        XCTAssertEqual(reader.sectionCount, 3)
        XCTAssertEqual(reader.pageCount, 5)
        let document = try open(twice)
        XCTAssertTrue(pageText(document, 2).contains("Çağrı"), pageText(document, 2))
    }

    func test_pdfA_keepsItsIdentifierMetadataAndConformance() throws {
        let documentId: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
                                   0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF]
        // 2026-10-19 21:30:05 +03:00.
        let options = PDFWriteOptions(conformance: .pdfA2b, title: "Sözleşme",
                                      creationDate: Date(timeIntervalSince1970: 1_792_434_605),
                                      timeZone: TimeZone(secondsFromGMT: 3 * 3600), documentId: documentId)
        let original = try [UInt8](PDFWriter.make([Self.page(text: true)], options: options))
        let target = try describe(original, "Sözleşme.pdf")
        XCTAssertTrue(target.isPdfA)
        XCTAssertTrue(target.keepsPdfA)
        XCTAssertEqual(target.warnings, [])
        XCTAssertNil(target.confirmMessage)

        let appended = try append(original, [Self.page(text: true)], Self.fixed)
        try checkAppended(original, appended, 1)
        let update = Self.update(original, appended)
        // The first half of the identifier stays; the catalog, Info and metadata are not rewritten.
        XCTAssertTrue(update.contains("/Info 9 0 R /ID [<A0A1A2A3A4A5A6A7A8A9AAABACADAEAF> <\(Self.newIdHex)>]"))
        XCTAssertFalse(update.contains("/Type /Catalog"))
        XCTAssertFalse(update.contains("/Metadata"))
        let document = try open(appended)
        let attributes: [AnyHashable: Any] = document.documentAttributes ?? [:]
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Sözleşme")
        XCTAssertEqual(document.pageCount, 2)
    }

    func test_encrypted_isRefused_andLeftAsItWas() throws {
        let protection = try PDFProtection("Şifre 2026")
        let original = try [UInt8](PDFWriter.make([Self.page()], options: PDFWriteOptions(protection: protection)))
        XCTAssertEqual(readError { _ = try append(original, [Self.page()]) }?.problem, .encrypted)
        let error = appendError { _ = try describe(original, "/x/Gizli.pdf") }
        XCTAssertEqual(error?.problem, .encrypted)
        XCTAssertEqual(error?.message,
                       "Gizli.pdf is password-protected, so pages can't be added to it. Save them as a new PDF instead.")
    }

    // MARK: - Other writers' layouts

    func test_classic_withEveryEndOfLine_andNoFinalOne() throws {
        let cases: [(newline: String, finalNewline: Bool)] = [("\n", true), ("\r\n", true), ("\r", true), ("\n", false)]
        for (newline, finalNewline) in cases {
            let label = "\(Array(newline.utf8)) \(finalNewline)"
            let original = PDFFixture.classic(newline: newline, finalNewline: finalNewline)
            let appended = try append(original, [Self.page()])
            try checkAppended(original, appended, 1)
            // An end of line is added only where the original has none.
            XCTAssertTrue(Self.update(original, appended).hasPrefix(finalNewline ? "9 0 obj" : "\n9 0 obj"), label)
            let document = try open(appended)
            XCTAssertTrue(pageText(document, 0).contains("one"), label)
            XCTAssertTrue(pageText(document, 1).contains("two"), label)
        }
    }

    func test_alreadyUpdated_addsAThirdSection() throws {
        let original = PDFFixture.alreadyUpdated()
        let appended = try append(original, [Self.page()])
        let reader = try checkAppended(original, appended, 1)
        XCTAssertEqual(reader.sectionCount, 3)
        XCTAssertEqual(reader.pages.map(\.number), [3, 4, 9, 11])
        // The Info reference and the identifier come through from the older trailers.
        let pattern = #"/Root 1 0 R /Info 8 0 R /ID \[<00112233445566778899AABBCCDDEEFF> <[0-9A-F]{32}>\]"#
        XCTAssertTrue(Self.matches(Self.update(original, appended), pattern))
    }

    func test_objectStreams_getAnUncompressedCrossReferenceStream() throws {
        for hasText in [true, false] {
            let label = "text \(hasText)"
            let original = PDFFixture.objectStreams()
            let appended = try append(original, [Self.page(text: hasText), Self.page()], Self.fixed)
            let reader = try checkAppended(original, appended, 2)
            XCTAssertTrue(reader.xrefIsStream, label)
            let update = Self.update(original, appended)
            // The tree root lived in an object stream; the update gives it a place of its own.
            XCTAssertTrue(update.contains("2 0 obj\n<</Type /Pages /Kids [3 0 R 4 0 R "), label)
            let first = 12
            let xref = first + (hasText ? 6 : 0) + 6
            var expected = "\(xref) 0 obj\n<</Type /XRef /W [1 4 2] /Index [2 1 \(first) \(xref - first + 1)] "
            expected += "/Size \(xref + 1) /Root 1 0 R /ID [<A0A1A2A3A4A5A6A7A8A9AAABACADAEAF> <\(Self.newIdHex)>] "
            expected += "/Prev \(reader.latestPrev ?? -1) /Length \(7 * (xref - first + 2))>>\nstream\n"
            XCTAssertTrue(update.contains(expected), label)
            XCTAssertTrue(update.hasSuffix("\nendstream\nendobj\nstartxref\n\(reader.startXref)\n%%EOF\n"), label)
            let document = try open(appended)
            XCTAssertTrue(pageText(document, 1).contains("two"), label)
            XCTAssertEqual(try imageCount(reader, 3), 1, label)
        }
    }

    func test_hybrid_getsAClassicTable() throws {
        let original = PDFFixture.hybrid()
        let appended = try append(original, [Self.page()])
        let reader = try checkAppended(original, appended, 1)
        XCTAssertFalse(reader.xrefIsStream)
        XCTAssertTrue(reader.isHybrid)
        XCTAssertTrue(Self.update(original, appended).contains("\nxref\n2 1\n"))
    }

    func test_inheritedAttributes_doNotReachTheNewPages() throws {
        let original = PDFFixture.inherited()
        let appended = try append(original, [Self.page()])
        try checkAppended(original, appended, 1)
        let update = Self.update(original, appended)
        XCTAssertTrue(update.contains("/Contents 10 0 R /Rotate 0 /CropBox [0 0 612 792]>>"))
        // The root keeps what it passes down to the pages that were there.
        XCTAssertTrue(update.contains("/MediaBox [0 0 200 300] /CropBox [10 10 190 290] /Rotate 90 /Resources <</Font <</F1 7 0 R>>>>>>"))
        let document = try open(appended)
        XCTAssertEqual(document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(document.page(at: 1)?.rotation, 0)
        let size = mediaBox(document, 1)
        XCTAssertEqual(Double(size.width), 612, accuracy: 0.01)
        XCTAssertEqual(Double(size.height), 792, accuracy: 0.01)
    }

    func test_nestedTree_newPagesComeLast() throws {
        let original = PDFFixture.nested()
        let appended = try append(original, [Self.page(width: 1250, height: 1250)])
        try checkAppended(original, appended, 1)
        XCTAssertTrue(Self.update(original, appended).contains("2 0 obj\n<</Type /Pages /Kids [3 0 R 6 0 R 10 0 R] /Count 4>>"))
        let document = try open(appended)
        var widths: [Int] = []
        for index in 0..<4 { widths.append(Int(mediaBox(document, index).width.rounded())) }
        XCTAssertEqual(widths, [100, 200, 300, 300])
    }

    func test_indirectKidsAndCount_namesStringsAndGeneration_writtenBackAsTheyWere() throws {
        let original = PDFFixture.indirectKids()
        let appended = try append(original, [Self.page()])
        try checkAppended(original, appended, 1)
        let update = Self.update(original, appended)
        XCTAssertTrue(update.contains("6 0 obj\n<</Type /Page /Parent 2 1 R "))
        XCTAssertTrue(update.contains("2 1 obj\n<</Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /Odd#20Name (a\\(b\\)c\\\\ \\r end) /Hex <4142> /Real -.5>>"))
        XCTAssertTrue(Self.matches(update, #"xref\n2 1\n\d{10} 00001 n \n6 3\n"#))
    }

    // MARK: - Before adding: warnings and refusals

    func test_warnings_signedFiles_andPdfALevelsThatAreNotKept() throws {
        let signed = try describe(PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 3>>"), "/x/Contract.pdf")
        XCTAssertTrue(signed.isSigned)
        XCTAssertEqual(signed.warnings, ["Contract.pdf is signed. Adding pages keeps the signature, but PDF apps will show that the file was changed after it was signed."])
        XCTAssertEqual(signed.confirmMessage, (signed.warnings.first ?? "") + "\n\nAdd the pages anyway?")

        let a1 = try describe(PDFFixture.pdfA(part: 1, conformance: "A"), "Old.pdf")
        XCTAssertFalse(a1.keepsPdfA)
        XCTAssertEqual(a1.warnings, ["Old.pdf is a PDF/A-1a file. The added pages may not meet that standard, so it may no longer pass as PDF/A."])
        XCTAssertFalse(try describe(PDFFixture.pdfA(part: 2, conformance: "B", components: 4), "Print.pdf").keepsPdfA)
        XCTAssertTrue(try describe(PDFFixture.pdfA(part: 3, conformance: "U"), "Kept.pdf").keepsPdfA)
    }

    func test_warnings_certifiedFiles_areToldTheCertificationBreaks() throws {
        let pdf = PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 3>> /Perms <</DocMDP 4 0 R>>",
                                         extra: { f in _ = f.obj(4, "<</Type /Sig>>") })
        let certified = try describe(pdf, "/x/Form.pdf")
        XCTAssertTrue(certified.isSigned)
        XCTAssertTrue(certified.isCertified)
        XCTAssertEqual(certified.warnings, ["Form.pdf is certified. Its certification does not allow adding pages, so PDF apps will show the certification as no longer valid."])
        XCTAssertFalse(try describe(PDFFixture.withCatalog("/AcroForm <</Fields [] /SigFlags 3>>"), "a.pdf").isCertified)
    }

    private func replace(_ pdf: [UInt8], _ from: String, _ to: String, line: UInt = #line) -> [UInt8] {
        let text = Self.latin1(pdf)
        XCTAssertNotNil(text.range(of: from, options: .literal), from, line: line)
        return PDFFixture.latin1(text.replacingOccurrences(of: from, with: to, options: .literal))
    }

    func test_objectsReadWhenAskedFor_areRefusedInWords_beforeAnyPageIsMade() throws {
        // The page tree reads fine; the form, or the PDF/A output intent's profile, is listed where another object is.
        let form = PDFFixture.withCatalog("/AcroForm 4 0 R", extra: { f in _ = f.obj(4, "<</Fields [] /SigFlags 3>>") })
        let cases: [[UInt8]] = [
            replace(form, "4 0 obj", "5 0 obj"),
            replace(PDFFixture.pdfA(part: 2, conformance: "B"), "5 0 obj", "6 0 obj"),
        ]
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        for bytes in cases {
            let error = appendError { _ = try describe(bytes, "/x/Form.pdf") }
            XCTAssertEqual(error?.problem, .damaged)
            XCTAssertEqual(error?.message, PDFAppender.message(.damaged, "Form.pdf"))
            XCTAssertTrue(error?.underlying is PDFReadError)

            let path = try write(folder, "Form.pdf", bytes)
            XCTAssertEqual(appendError { _ = try PDFAppender.inspect(path: path) }?.problem, .damaged)
            XCTAssertEqual(appendError { _ = try PDFAppender.appendToFile(path: path, pages: [Self.page()]) }?.problem,
                           .damaged)
            XCTAssertEqual(contents(path), bytes)
            XCTAssertEqual(names(folder), ["Form.pdf"])
        }
    }

    func test_aTreeWhoseRootIsAPage_isRefusedWhenInspected() throws {
        let f = PDFFixture()
        f.obj(1, "<</Type /Catalog /Pages 3 0 R>>")
        f.obj(3, "<</Type /Page /MediaBox [0 0 612 792] /Resources <<>>>>")
        f.table("/Size 4 /Root 1 0 R")
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let path = try write(folder, "One.pdf", f.toArray())
        let error = appendError { _ = try PDFAppender.inspect(path: path) }
        XCTAssertEqual(error?.problem, .damaged)
        XCTAssertEqual(error?.message, PDFAppender.message(.damaged, "One.pdf"))
    }

    func test_objectNumbers_stayWithinPdfsLimit() throws {
        // All numbers used: refused before anything is written.
        let full = replace(PDFFixture.withCatalog(""), "/Size 6 ", "/Size 8388608 ")
        XCTAssertEqual(readError { _ = try append(full, [Self.page()]) }?.problem, .unsupported)
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let path = try write(folder, "Full.pdf", full)
        let error = appendError { _ = try PDFAppender.appendToFile(path: path, pages: [Self.page()]) }
        XCTAssertEqual(error?.problem, .unsupported)
        XCTAssertEqual(contents(path), full)
        XCTAssertEqual(names(folder), ["Full.pdf"])

        // Room for exactly one page (three objects) in a classic table.
        let nearly = replace(PDFFixture.withCatalog(""), "/Size 6 ", "/Size 8388605 ")
        let reader = try PDFReaderLite(data: Data(append(nearly, [Self.page()])))
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertEqual(reader.pages.last?.number, 8_388_605)
        XCTAssertEqual(readError { _ = try append(nearly, [Self.page(), Self.page()]) }?.problem, .unsupported)
    }

    func test_writeUpdate_noObjectNumbersLeft_leavesTheCallersOutputAsItWas() throws {
        // A file that does not end with an end of line: the refusal comes before that end of line is written.
        let full = replace(PDFFixture.withCatalog(""), "/Size 6 ", "/Size 8388608 ")
        var end = full.count
        while end > 0 && (full[end - 1] == 10 || full[end - 1] == 13) { end -= 1 }
        let unterminated = Array(full[..<end])
        let reader = try PDFReaderLite(data: Data(unterminated))
        var output = Data(unterminated)
        let error = readError {
            try PDFAppender.writeUpdate(reader, into: { chunk in output.append(chunk) }, pages: [Self.page()])
        }
        XCTAssertEqual(error?.problem, .unsupported)
        XCTAssertEqual(output, Data(unterminated))
    }

    func test_keepsPdfA_table() {
        let cases: [(part: Int, conformance: String?, components: Int?, keeps: Bool)] = [
            (1, "B", 3, true),
            (1, "U", 3, false),
            (1, "A", 3, false),
            (2, "B", 3, true),
            (2, "U", 3, true),
            (2, "A", 3, false),
            (3, "B", 3, true),
            (4, nil, 3, false),
            (2, "B", 4, false),
            (2, "B", nil, false),
        ]
        for c in cases {
            XCTAssertEqual(PDFAppender.keepsPdfA(part: c.part, conformance: c.conformance,
                                                 outputIntentComponents: c.components), c.keeps, "\(c)")
        }
    }

    func test_messages_sayWhatToDo() {
        XCTAssertEqual(PDFAppender.message(.damaged, "Scan.pdf"),
                       "Scan.pdf looks damaged, so pages can't be added to it safely. Save them as a new PDF instead.")
        XCTAssertEqual(PDFAppender.message(.inUse, "Scan.pdf"),
                       "Scan.pdf is open in another app. Close it there, then add the pages again.")
        XCTAssertEqual(PDFAppender.leftAsBackupMessage("Scan.pdf", backupName: ".1234.pdf.bak"),
                       "The pages could not be added to Scan.pdf, and the file could not be put back under its name. It is unchanged, "
                       + "in the same folder, named .1234.pdf.bak. Rename it back to Scan.pdf, then add the pages again.")
        XCTAssertEqual(PDFAppender.message(.leftAsBackup, "Scan.pdf"),
                       "The pages could not be added to Scan.pdf, and the file could not be put back under its name. It is unchanged, "
                       + "in the same folder, under a name ending in .pdf.bak. Rename it back to Scan.pdf, then add the pages again.")
        XCTAssertEqual(PDFAppender.addedMessage(1, fileName: "Scan.pdf", pageCount: 2, size: "1.4 MB"),
                       "Added 1 page to Scan.pdf (now 2 pages, 1.4 MB)")
        XCTAssertEqual(PDFAppender.addedMessage(3, fileName: "Scan.pdf", pageCount: 4, size: nil),
                       "Added 3 pages to Scan.pdf (now 4 pages)")
        var messages = Set<String>()
        for problem in PDFAppendProblem.allCases { messages.insert(PDFAppender.message(problem, "x.pdf")) }
        XCTAssertEqual(messages.count, PDFAppendProblem.allCases.count)
    }

    // MARK: - The file on disk

    private func makeFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PDFAppenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func removeFolder(_ folder: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func write(_ folder: String, _ name: String, _ bytes: [UInt8]) throws -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func contents(_ path: String) -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return [UInt8](data)
    }

    /// The names in `folder`, hidden ones too.
    private func names(_ folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.sorted()
    }

    func test_appendToFile_replacesTheFile_keepingItsCreationDate() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let original = PDFFixture.objectStreams()
        let path = try write(folder, "Sözleşme.pdf", original)
        let created = Date(timeIntervalSince1970: 1_577_934_245) // 2020-01-02 03:04:05 UTC
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path)
        var messages: [String] = []
        let result = try PDFAppender.appendToFile(path: path, pages: [Self.page(text: true), Self.page()],
                                                  progress: { message in messages.append(message) })
        let full = URL(fileURLWithPath: path).standardized.path
        XCTAssertEqual(result, PDFAppendResult(path: full, pagesBefore: 2, pagesAdded: 2, bytes: contents(path).count))
        XCTAssertEqual(result.pageCount, 4)
        XCTAssertEqual(messages, ["Adding page 1 of 2…", "Adding page 2 of 2…"])
        try checkAppended(original, contents(path), 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.creationDate] as? Date, created)
        XCTAssertEqual(names(folder), ["Sözleşme.pdf"]) // no temporary file left
        XCTAssertEqual(try PDFAppender.inspect(path: path).pageCount, 4)
    }

    func test_appendToFile_keepsTheFilesPermissions() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let path = try write(folder, "Downloaded.pdf", PDFFixture.classic())
        try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: path)

        try PDFAppender.appendToFile(path: path, pages: [Self.page()])

        XCTAssertEqual(try PDFAppender.inspect(path: path).pageCount, 3)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o604)
        XCTAssertEqual(names(folder), ["Downloaded.pdf"]) // neither the temporary file nor the backup is left
    }

    func test_appendToFile_aFolderThatTakesNoNewFiles_isRefusedAsReadOnly() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let original = PDFFixture.classic()
        let path = try write(folder, "Shared.pdf", original)
        // The file may be changed, but no file may be created next to it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        let error = appendError { _ = try PDFAppender.appendToFile(path: path, pages: [Self.page()]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        XCTAssertEqual(error?.problem, .readOnly)
        XCTAssertEqual(error?.message, PDFAppender.message(.readOnly, "Shared.pdf"))
        XCTAssertEqual(contents(path), original)
        XCTAssertEqual(names(folder), ["Shared.pdf"])
    }

    func test_appendToFile_refusesWithoutTouchingTheFile() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let damaged = Array(PDFFixture.classic().dropLast(30))
        let junk = PDFFixture.latin1("junk\n") + PDFFixture.classic()
        let protection = try PDFProtection("pw")
        let locked = try [UInt8](PDFWriter.make([Self.page()], options: PDFWriteOptions(protection: protection)))
        let cases: [(name: String, bytes: [UInt8], problem: PDFAppendProblem)] = [
            (name: "damaged.pdf", bytes: damaged, problem: .damaged),
            (name: "text.pdf", bytes: PDFFixture.latin1("not a pdf"), problem: .notPdf),
            (name: "junk.pdf", bytes: junk, problem: .unsupported),
            (name: "locked.pdf", bytes: locked, problem: .encrypted),
        ]
        for c in cases {
            let path = try write(folder, c.name, c.bytes)
            let error = appendError { _ = try PDFAppender.appendToFile(path: path, pages: [Self.page()]) }
            XCTAssertEqual(error?.problem, c.problem, c.name)
            XCTAssertEqual(error?.message, PDFAppender.message(c.problem, c.name))
            XCTAssertEqual(appendError { _ = try PDFAppender.inspect(path: path) }?.problem, c.problem, c.name)
            XCTAssertEqual(contents(path), c.bytes, c.name)
        }
        XCTAssertEqual(names(folder).count, cases.count)
        let gone = (folder as NSString).appendingPathComponent("gone.pdf")
        XCTAssertEqual(appendError { _ = try PDFAppender.appendToFile(path: gone, pages: [Self.page()]) }?.problem,
                       .missing)
    }

    func test_appendToFile_readOnlyOrOpenElsewhere_isRefused() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let original = PDFFixture.classic()
        let readOnly = try write(folder, "read-only.pdf", original)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly)
        XCTAssertEqual(appendError { _ = try PDFAppender.appendToFile(path: readOnly, pages: [Self.page()]) }?.problem,
                       .readOnly)

        let held = try write(folder, "open.pdf", original)
        // An app that holds the file locked while it works on it.
        let descriptor = Darwin.open(held, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let error = appendError { _ = try PDFAppender.appendToFile(path: held, pages: [Self.page()]) }
        XCTAssertEqual(error?.problem, .inUse)
        XCTAssertEqual(appendError { _ = try PDFAppender.inspect(path: held) }?.problem, .inUse)
        _ = Darwin.close(descriptor)

        XCTAssertEqual(contents(held), original)
        XCTAssertEqual(contents(readOnly), original)
        XCTAssertEqual(names(folder).count, 2)
    }

    func test_aReplacementThatFailedAfterMovingTheOriginalAside_putsItBackOrNamesTheBackup() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let original = PDFFixture.classic()
        let cause = Cause(text: "Unable to move the replacement file to the file to be replaced.")

        // Moved back: the user is asked to close the other app and try again.
        let path = (folder as NSString).appendingPathComponent("Report.pdf")
        let backup = try write(folder, ".1111.pdf.bak", original)
        let back = PDFAppender.putBack(backup, path, cause: cause)
        XCTAssertEqual(back.problem, .inUse)
        XCTAssertEqual(back.message, PDFAppender.message(.inUse, "Report.pdf"))
        XCTAssertEqual(contents(path), original)
        XCTAssertEqual(names(folder), ["Report.pdf"])

        // Not moved back (the way back leads into a folder that is gone): the refusal says where the file is.
        let other = ((folder as NSString).appendingPathComponent("gone") as NSString).appendingPathComponent("Contract.pdf")
        let held = try write(folder, ".2222.pdf.bak", original)
        let left = PDFAppender.putBack(held, other, cause: cause)
        XCTAssertEqual(left.problem, .leftAsBackup)
        XCTAssertEqual(left.message, PDFAppender.leftAsBackupMessage("Contract.pdf", backupName: ".2222.pdf.bak"))
        XCTAssertEqual(left.underlying as? Cause, cause)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other))
        XCTAssertEqual(contents(held), original)
    }

    func test_appendToFile_cancelled_leavesTheFile() throws {
        let folder = try makeFolder()
        defer { removeFolder(folder) }
        let original = PDFFixture.classic()
        let path = try write(folder, "a.pdf", original)
        var stop = false
        XCTAssertThrowsError(try PDFAppender.appendToFile(path: path, pages: [Self.page(), Self.page()],
                                                          progress: { _ in stop = true },
                                                          shouldContinue: { !stop })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(contents(path), original)
        XCTAssertEqual(names(folder), ["a.pdf"])
    }

    /// PDF/A files with pages added, for veraPDF in CI next to PDFATests' samples
    /// (COMPLETESCANNER_PDFA_SAMPLES); without that folder they are written, read back and removed.
    func test_pdfA_validationSamples() throws {
        let samples: String = ProcessInfo.processInfo.environment["COMPLETESCANNER_PDFA_SAMPLES"] ?? ""
        let keep = !samples.trimmingCharacters(in: .whitespaces).isEmpty
        let folder: URL = keep
            ? URL(fileURLWithPath: samples, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("PDFAppenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            if !keep { try? FileManager.default.removeItem(at: folder) }
        }
        let url = folder.appendingPathComponent("pdfa-pages-added.pdf")
        try PDFWriter.writeFile([Self.page(text: true)], to: url,
                                options: PDFWriteOptions(conformance: .pdfA2b, title: "Pages added"))
        XCTAssertTrue(try PDFAppender.inspect(path: url.path).keepsPdfA)
        try PDFAppender.appendToFile(path: url.path, pages: [Self.page(text: true), Self.page()])
        try PDFAppender.appendToFile(path: url.path, pages: [Self.page()])
        XCTAssertEqual(try PDFReaderLite.open(path: url.path).pageCount, 4)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 4)
    }

    // MARK: - The object writer's update sections

    func test_objectWriter_updateTable_listsRunsWithTheirGenerations() throws {
        var output = Data()
        let w = try PDFObjectWriter(position: 1000) { chunk in output.append(chunk) }
        try w.writeObject(7, "<<>>")
        try w.writeObject(2, generation: 3, "<<>>")
        try w.writeObject(8, "<<>>")
        try w.finishUpdate("/Size 9 /Prev 500")
        var expected = "7 0 obj\n<<>>\nendobj\n2 3 obj\n<<>>\nendobj\n8 0 obj\n<<>>\nendobj\n"
        expected += "xref\n2 1\n0000001020 00003 n \n7 2\n0000001000 00000 n \n0000001040 00000 n \n"
        expected += "trailer\n<</Size 9 /Prev 500>>\nstartxref\n1060\n%%EOF\n"
        XCTAssertEqual(Self.latin1([UInt8](output)), expected)
    }

    func test_objectWriter_updateStream_listsItself() throws {
        var output = Data()
        let w = try PDFObjectWriter(position: 0x1_0000_0000) { chunk in output.append(chunk) } // past 4 GB: offsets take 5 bytes
        try w.writeObject(3, "<<>>")
        try w.finishUpdateStream(4, "/Size 5 /Prev 9")
        let bytes = [UInt8](output)
        let text = Self.latin1(bytes)
        let head = "3 0 obj\n<<>>\nendobj\n4 0 obj\n<</Type /XRef /W [1 5 2] /Index [3 2] /Size 5 /Prev 9 /Length 16>>\nstream\n"
        XCTAssertTrue(text.hasPrefix(head), text)
        let data = head.utf8.count
        XCTAssertGreaterThanOrEqual(bytes.count, data + 16)
        if bytes.count >= data + 16 {
            XCTAssertEqual(Array(bytes[data..<(data + 16)]), [1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 20, 0, 0])
        }
        XCTAssertTrue(text.hasSuffix("\nendstream\nendobj\nstartxref\n4294967316\n%%EOF\n"), text)
    }
}
