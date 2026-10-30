import XCTest
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/TextExportTests.cs: the same cases, except
// WriteNewFile (the Mac writes the files in AppState with Data.write).

final class TextExportTests: XCTestCase {
    private static func L(_ text: String, _ left: Double, _ top: Double, _ width: Double,
                          _ height: Double = 20) -> OCRLine {
        OCRFixtures.line(text, left, top, width, height)
    }

    /// Two pages with accents, Chinese, Hebrew, a row of two pieces and a broken word.
    static func samplePages() -> [OCRPage] {
        [
            OCRFixtures.page(
                L("Café menu", 400, 50, 200, 30),
                L("Soupe à l'oignon", 50, 120, 300), L("4,50 €", 800, 121, 100),
                L("東京 ラーメン", 50, 150, 300), L("9.00", 800, 150, 100),
                L("This line is forward-", 50, 220, 800), L("ing the rest.", 50, 246, 300)),
            OCRFixtures.page(L("שלום עולם", 600, 100, 300), L("Fish & Chips <b>", 50, 160, 400)),
        ]
    }

    func test_encode_exactBytes_utf8WithoutBOM_lineFeeds() {
        let expected = "Café menu\n\nSoupe à l'oignon\t4,50 €\n東京 ラーメン\t9.00\n\nThis line is forward-\ning the rest.\n\n\n"
            + "שלום עולם\n\nFish & Chips <b>\n"
        let bytes = TextExport.encode(Self.samplePages())
        XCTAssertEqual(bytes, Data(expected.utf8))
        XCTAssertNotEqual(bytes.first, 0xEF)
        XCTAssertFalse(bytes.contains(0x0D))
        XCTAssertEqual(String(data: bytes, encoding: .utf8), expected)
        XCTAssertTrue(TextExport.hasText(Self.samplePages()))
        XCTAssertTrue(TextExport.encode([OCRFixtures.page()]).isEmpty)
        XCTAssertFalse(TextExport.hasText([OCRFixtures.page()]))
    }

    func test_encode_fingerprint_matchesWindows() {
        // The same number in TextExportTests.cs: both platforms write the same bytes.
        let bytes = TextExport.encode(Self.samplePages())
        XCTAssertEqual(bytes.count, 139)
        XCTAssertEqual(ZipStore.crc32(bytes), 0x7EF2_6B65)
    }

    func test_messages() {
        XCTAssertEqual(TextExport.savedMessage(format: .word, pageCount: 3, fileName: "Scan 1.docx", hasText: true),
                       "Saved 3-page Word document: Scan 1.docx")
        XCTAssertEqual(TextExport.savedMessage(format: .text, pageCount: 1, fileName: "Scan 1.txt", hasText: false),
                       "Saved 1-page text file: Scan 1.txt \u{2014} no text was found")
        XCTAssertEqual(TextExport.sidecarSuffix("Scan 1.txt"), " and its text, Scan 1.txt")
        XCTAssertEqual(TextExport.copiedMessage(pageNumber: 2, hasText: true), "Copied the text of page 2.")
        XCTAssertEqual(TextExport.copiedMessage(pageNumber: 1, hasText: false), "No text was found on page 1.")
        XCTAssertEqual(
            TextExport.recognitionFailed(
                "Scan failed: OCR failed: no OCR language pack is installed (Settings \u{2192} Time & Language \u{2192} Language)."),
            "The text could not be read: no OCR language pack is installed (Settings \u{2192} Time & Language \u{2192} Language).")
        XCTAssertEqual(TextExport.recognitionFailed("OCR failed: the request failed"),
                       "The text could not be read: the request failed.")
        XCTAssertEqual(TextExport.recognitionFailed("  "),
                       "The text could not be read: the text recognition did not work.")
        XCTAssertEqual(TextExport.sidecarFailed("Scan failed: OCR failed: no OCR language pack is installed."),
                       "The PDF was saved, but not its text file: no OCR language pack is installed.")
        XCTAssertEqual(TextExport.sidecarFailed("Access to the path is denied."),
                       "The PDF was saved, but not its text file: Access to the path is denied.")
        XCTAssertEqual(TextExport.keptInQueue(format: .word, pageCount: 3, cancelled: false),
                       "The 3 pages are kept in the queue: press Save Word once the text can be read, or choose PDF to save them as scanned.")
        XCTAssertEqual(TextExport.keptInQueue(format: .text, pageCount: 1, cancelled: false),
                       "The page is kept in the queue: press Save Text once the text can be read, or choose PDF to save it as scanned.")
        // The text was read but the file could not be written: no advice about reading the text.
        XCTAssertEqual(TextExport.keptInQueue(format: .word, pageCount: 3, cancelled: false, textUnreadable: false),
                       "The 3 pages are kept in the queue: press Save Word to try again, or choose PDF to save them as scanned.")
        XCTAssertEqual(TextExport.keptInQueue(format: .text, pageCount: 1, cancelled: false, textUnreadable: false),
                       "The page is kept in the queue: press Save Text to try again, or choose PDF to save it as scanned.")
        XCTAssertEqual(TextExport.keptInQueue(format: .word, pageCount: 2, cancelled: true),
                       "Cancelled \u{2014} the 2 pages are kept in the queue.")
        XCTAssertEqual(TextExport.keptInQueue(format: .text, pageCount: 1, cancelled: true),
                       "Cancelled \u{2014} the page is kept in the queue.")
        XCTAssertEqual(TextExport.keptInQueue(format: .text, pageCount: 1, cancelled: true, textUnreadable: false),
                       "Cancelled \u{2014} the page is kept in the queue.")
        // The error the app shows says the same.
        XCTAssertEqual(TextOutputError("Copy did not work.").localizedDescription, "Copy did not work.")
    }
}

final class OutputFormatsTests: XCTestCase {
    func test_imageAndTextFormats() {
        XCTAssertEqual(OutputFormat.allCases.filter(\.isImageFormat), [.jpeg, .png, .tiff])
        XCTAssertEqual(OutputFormat.allCases.filter(\.isTextFormat), [.text, .word])
        XCTAssertEqual(OutputFormat.allCases.map(\.label), ["PDF", "JPEG", "PNG", "TIFF", "Text (.txt)", "Word (.docx)"])
        XCTAssertEqual(OutputFormat.allCases.map(\.fileExtension), ["pdf", "jpg", "png", "tiff", "txt", "docx"])
    }

    func test_offered_documentsGetEveryFormat_photosTheImageFormats() {
        XCTAssertEqual(OutputFormat.offered(for: .document), [.pdf, .word, .text, .jpeg, .png, .tiff])
        XCTAssertEqual(OutputFormat.offered(for: .photo), [.jpeg, .png, .tiff])
    }

    func test_whatEachSaveWrites() {
        XCTAssertEqual(OutputFormat.allCases.map(\.imageFormatOrJPEG), [.jpeg, .jpeg, .png, .tiff, .jpeg, .jpeg])
        XCTAssertEqual(OutputFormat.allCases.map(\.queueFormat), [.pdf, .pdf, .pdf, .pdf, .text, .word])
        XCTAssertEqual(OutputFormat.allCases.map(\.pageFormat), [.pdf, .jpeg, .png, .tiff, .pdf, .pdf])
    }

    func test_savesPDF_collectedPagesInAnyFormatButText_aScanAtOnceInPDFOnly() {
        XCTAssertEqual(OutputFormat.allCases.map { $0.savesPDF(collectsPages: true) },
                       [true, true, true, true, false, false])
        XCTAssertEqual(OutputFormat.allCases.map { $0.savesPDF(collectsPages: false) },
                       [true, false, false, false, false, false])
    }

    func test_saveTitles() {
        XCTAssertEqual(OutputFormat.allCases.map(\.saveTitle),
                       ["Save PDF", "Save PDF", "Save PDF", "Save PDF", "Save Text", "Save Word"])
        XCTAssertEqual(OutputFormat.word.saveTitle(pageCount: 3), "Save Word (3 pages)")
        XCTAssertEqual(OutputFormat.jpeg.saveTitle(pageCount: 1), "Save PDF (1 page)")
        XCTAssertEqual(OutputFormat.text.saveTitle(pageCount: 0), "Save Text")
    }
}
