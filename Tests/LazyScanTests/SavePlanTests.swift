import CoreGraphics
import XCTest
@testable import LazyScanKit

// Twin of windows/LazyScan.Core.Tests/SavePlanTests.cs: the same cases.

private let paperImage: CGImage = RgbaImage.filled(width: 4, height: 4, r: 255, g: 255, b: 255).makeCGImage()!

private func makePage(patch: PatchCode? = nil, blank: Bool = false) -> ScannedPage {
    ScannedPage(image: paperImage, dpi: 300, colorMode: .color)
        .withPatch(patch)
        .withBlank(blank ? BlankPageResult(inkCoverage: 0, inkComponents: 0, hasLargeDarkArea: false, isBlank: true) : nil)
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

final class SavePlanTests: XCTestCase {
    func test_make_theDocumentsOfTheSplit_withTheQueuesPages() {
        let queue = [makePage(), makePage(), makePage(patch: .patchT), makePage(blank: true), makePage().withDocumentLabel("Lease")]
        var options = DocumentOptions()
        options.splitMode = .separatorSheet
        options.removeBlankPages = true
        let plan = SavePlan.make(queue, options: options)
        XCTAssertEqual(plan.documents.count, 2)
        XCTAssertEqual(plan.documents[0].pages.map(\.id), [queue[0].id, queue[1].id])
        XCTAssertEqual(plan.documents[1].pages.map(\.id), [queue[4].id])
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Lease"])
        XCTAssertEqual(plan.pageCount, 3)
        XCTAssertEqual(plan.separatorPages, 1)
        XCTAssertEqual(plan.skippedPages, 1)
        XCTAssertTrue(plan.isSplit)
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.documents.map { plan.fileIndex($0) }, [1, 2])

        let whole = SavePlan.make(queue, options: DocumentOptions())
        XCTAssertEqual(whole.documents.count, 1)
        XCTAssertNil(whole.fileIndex(whole.documents[0]))
        XCTAssertEqual(whole.pageCount, 5)
        XCTAssertEqual(whole.separatorPages, 0)
        XCTAssertEqual(whole.skippedPages, 0)

        XCTAssertTrue(SavePlan.make([makePage(patch: .patch2)], options: options).isEmpty)
    }

    func test_texts() {
        let one = SavePlan(documents: [SaveDocument(number: 1, pages: [makePage(), makePage()], label: nil)],
                           separatorPages: 0, skippedPages: 0)
        XCTAssertEqual(one.saveTitle(.pdf), "Save PDF (2 pages)")
        XCTAssertEqual(one.saveTitle(.word), OutputFormat.word.saveTitle(pageCount: 2))
        XCTAssertEqual(one.leftOutNote(), "")

        let three = SavePlan(documents: [SaveDocument(number: 1, pages: [makePage(), makePage()], label: nil),
                                         SaveDocument(number: 2, pages: [makePage()], label: "Lease"),
                                         SaveDocument(number: 3, pages: [makePage()], label: nil)],
                             separatorPages: 2, skippedPages: 1)
        XCTAssertEqual(three.saveTitle(.pdf), "Save 3 PDFs (4 pages)")
        XCTAssertEqual(three.saveTitle(.jpeg), "Save 3 PDFs (4 pages)")
        XCTAssertEqual(three.saveTitle(.word), "Save 3 Word documents (4 pages)")
        XCTAssertEqual(three.saveTitle(.text), "Save 3 text files (4 pages)")
        XCTAssertEqual(three.leftOutNote(), " — 2 separator pages and 1 skipped page were left out")
        XCTAssertEqual(three.savedMessage(.pdf, fileNames: ["A.pdf", "B.pdf", "C.pdf"]),
                       "Saved 3 PDFs (4 pages): A.pdf, B.pdf, C.pdf — 2 separator pages and 1 skipped page were left out")
        // Like a single save: the size, the text beside the PDFs, and files with no text in them.
        XCTAssertEqual(three.savedMessage(.pdf, fileNames: ["A.pdf", "B.pdf", "C.pdf"], size: "1.2 MB",
                                          textFileNames: ["A.txt", "B.txt", "C.txt"]),
                       "Saved 3 PDFs (4 pages, 1.2 MB): A.pdf, B.pdf, C.pdf and their text, A.txt, B.txt, C.txt — 2 separator pages and 1 skipped page were left out")
        XCTAssertEqual(three.savedMessage(.text, fileNames: ["A.txt", "B.txt", "C.txt"], noTextFound: ["A.txt", "B.txt", "C.txt"]),
                       "Saved 3 text files (4 pages): A.txt, B.txt, C.txt — no text was found — 2 separator pages and 1 skipped page were left out")
        XCTAssertEqual(three.savedMessage(.word, fileNames: ["A.docx", "B.docx", "C.docx"], noTextFound: ["B.docx"]),
                       "Saved 3 Word documents (4 pages): A.docx, B.docx, C.docx — no text was found in B.docx — 2 separator pages and 1 skipped page were left out")
        XCTAssertEqual(three.savedMessage(.pdf, fileNames: ["A.pdf", "B.pdf", "C.pdf"], size: nil, textFileNames: [], noTextFound: []),
                       "Saved 3 PDFs (4 pages): A.pdf, B.pdf, C.pdf — 2 separator pages and 1 skipped page were left out")
        // A saving error's own "Saving failed: " is not repeated in the message that says nothing was saved.
        XCTAssertEqual(SavePlan.failureReason(ScanError.exportFailed("Could not write A.pdf.")), "Could not write A.pdf.")
        XCTAssertEqual(SavePlan.failureReason(NotSavedError("The disk is full.")), "The disk is full.")
        XCTAssertEqual(NotSavedError(SavePlan.notSavedMessage("Could not write A.pdf.")).localizedDescription,
                       "None of the documents was saved; the pages are still in the queue. Could not write A.pdf.")

        func note(separators: Int, skipped: Int) -> String {
            var plan = one
            plan.separatorPages = separators
            plan.skippedPages = skipped
            return plan.leftOutNote()
        }
        XCTAssertEqual(note(separators: 0, skipped: 1), " — 1 skipped page was left out")
        XCTAssertEqual(note(separators: 0, skipped: 3), " — 3 skipped pages were left out")
        XCTAssertEqual(note(separators: 1, skipped: 0), " — 1 separator page was left out")
        XCTAssertEqual(note(separators: 2, skipped: 0), " — 2 separator pages were left out")
        XCTAssertEqual(note(separators: 1, skipped: 2), " — 1 separator page and 2 skipped pages were left out")
        XCTAssertEqual(SavePlan.notSavedMessage("The disk is full."),
                       "None of the documents was saved; the pages are still in the queue. The disk is full.")
        XCTAssertEqual([(OutputFormat.pdf, 1), (OutputFormat.pdf, 2), (OutputFormat.word, 1), (OutputFormat.word, 2),
                        (OutputFormat.text, 1), (OutputFormat.text, 2)]
                        .map { SavePlan.fileKind($0.0, count: $0.1) },
                       ["PDF", "PDFs", "Word document", "Word documents", "text file", "text files"])
    }

    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LazyScanTests", isDirectory: true)
            .appendingPathComponent("SavePlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func test_writeAllOrNothing_keepsEveryFile_whenItFinishes() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = WrittenFiles()
        try await SavePlan.writeAllOrNothing(files) {
            for name in ["a.pdf", "a.txt", "b.pdf"] {
                let url = folder.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                files.add(url)
            }
        }
        XCTAssertEqual(files.urls.count, 3)
        XCTAssertTrue(files.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func test_writeAllOrNothing_removesWhatItWrote_whenItFailsOrIsCancelled() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failures: [Error] = [DiskFull(), ScanError.cancelled]
        for failure in failures {
            let files = WrittenFiles()
            let other = folder.appendingPathComponent("not ours.pdf")
            try Data("kept".utf8).write(to: other)
            do {
                try await SavePlan.writeAllOrNothing(files) {
                    let url = folder.appendingPathComponent("a.pdf")
                    try Data("a".utf8).write(to: url)
                    files.add(url)
                    files.add(folder.appendingPathComponent("never written.pdf"))
                    throw failure
                }
                XCTFail("the failure goes on")
            } catch {
                XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
            }
            XCTAssertTrue(files.urls.isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(left, ["not ours.pdf"])
        }
    }
}
