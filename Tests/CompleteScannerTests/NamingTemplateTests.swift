import XCTest
import Foundation
@testable import CompleteScannerKit

// MARK: - Helpers

/// 2026-08-13 14:05:09 in the current calendar/time zone, so formatter output is deterministic.
private func fixedDate() -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 13
    components.hour = 14
    components.minute = 5
    components.second = 9
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: components)!
}

private func render(_ template: String, counter: Int = 1,
                    intent: ScanIntent = .document, index: Int? = nil) -> String {
    NamingTemplate(template).baseFilename(counter: counter, date: fixedDate(), intent: intent, index: index)
}

// MARK: - Tests

final class NamingTemplateTests: XCTestCase {

    func test_dateToken() {
        XCTAssertEqual(render("{date}"), "2026-08-13")
    }

    func test_timeToken() {
        XCTAssertEqual(render("{time}"), "14.05.09")
    }

    func test_yearMonthDayTokens() {
        XCTAssertEqual(render("{year}"), "2026")
        XCTAssertTrue(["08", "8"].contains(render("{month}")), "Got \(render("{month}"))")
        XCTAssertEqual(render("{day}"), "13")
    }

    func test_counterToken() {
        XCTAssertEqual(render("{counter}", counter: 7), "7")
        XCTAssertEqual(render("{counter}", counter: 123), "123")
    }

    func test_counterZeroPadding() {
        XCTAssertEqual(render("{counter:4}", counter: 7), "0007")
        XCTAssertEqual(render("{counter:4}", counter: 123), "0123")
    }

    func test_intentToken() {
        XCTAssertEqual(render("{intent}", intent: .document), "Document")
        XCTAssertEqual(render("{intent}", intent: .photo), "Photos")
    }

    func test_indexTokenSubstituted() {
        XCTAssertEqual(render("Photo {index}", index: 7), "Photo 7")
    }

    func test_indexNilLeavesNoResidue() {
        let result = render("Photo {index}", index: nil)
        XCTAssertFalse(result.contains("{"), "Unsubstituted token residue in \(result)")
        XCTAssertFalse(result.contains("}"), "Unsubstituted token residue in \(result)")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespaces), "Photo")
    }

    func test_indexAppendedWhenTokenAbsent() {
        let result = render("Photo", index: 3)
        XCTAssertTrue(result.hasPrefix("Photo"), "Got \(result)")
        XCTAssertTrue(result.contains("3"), "Index must be appended when {index} is absent; got \(result)")
    }

    func test_unknownTokenPassesThrough() {
        XCTAssertEqual(render("{bogus}"), "{bogus}")
    }

    func test_sanitization() {
        XCTAssertEqual(render("a/b:c"), "a-b-c")
    }

    func test_combinedTemplate() {
        XCTAssertEqual(render("Scan {date} {counter}", counter: 4), "Scan 2026-08-13 4")
    }

    // MARK: NamingContext and {task}

    private func renderContext(_ template: String, _ context: NamingContext) -> String {
        NamingTemplate(template).baseFilename(context)
    }

    func test_taskToken_isTheTasksFileLabel() {
        XCTAssertEqual(renderContext("{task} {date}", NamingContext(counter: 1, date: fixedDate(), intent: .photo, task: .photoRestore)),
                       "Restored photo 2026-08-13")
        XCTAssertEqual(renderContext("{task} {counter}", NamingContext(counter: 3, date: fixedDate(), intent: .document, task: .feeder)),
                       "Document 3")
        XCTAssertEqual(renderContext("{task}", NamingContext(counter: 1, date: fixedDate(), intent: .document, task: .quickScan)),
                       "Scan")
    }

    func test_taskToken_withoutATask_isTheIntent() {
        XCTAssertEqual(renderContext("{task} {date}", NamingContext(counter: 1, date: fixedDate(), intent: .photo)), "Photos 2026-08-13")
        XCTAssertEqual(renderContext("{task}", NamingContext(counter: 1, date: fixedDate(), intent: .document)), "Document")
        // The old overload has no task.
        XCTAssertEqual(render("{task}", intent: .photo), "Photos")
    }

    func test_context_givesTheSameNamesAsTheOldOverload() {
        for template in ["Scan {date} {counter}", "{counter:3} {intent} {time}", "Photo", "Photo {index}"] {
            for index in [nil, 4] as [Int?] {
                XCTAssertEqual(render(template, counter: 12, intent: .photo, index: index),
                               renderContext(template, NamingContext(counter: 12, date: fixedDate(), intent: .photo, index: index)))
            }
        }
    }

    func test_context_indexAndTaskTogether() {
        let context = NamingContext(counter: 7, date: fixedDate(), intent: .photo, index: 2, task: .photos)
        XCTAssertEqual(renderContext("{task} {counter}", context), "Photo 7 2")
        XCTAssertEqual(renderContext("{task} {index} of batch {counter}", context), "Photo 2 of batch 7")
    }

    func test_uniqueURLSuffixes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("NamingTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let first = NamingTemplate.uniqueURL(in: dir, base: "Report", fileExtension: "pdf")
        XCTAssertEqual(first.lastPathComponent, "Report.pdf")
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = NamingTemplate.uniqueURL(in: dir, base: "Report", fileExtension: "pdf")
        XCTAssertEqual(second.lastPathComponent, "Report 2.pdf")
        XCTAssertTrue(fm.createFile(atPath: second.path, contents: Data()))

        let third = NamingTemplate.uniqueURL(in: dir, base: "Report", fileExtension: "pdf")
        XCTAssertEqual(third.lastPathComponent, "Report 3.pdf")
    }
}
