import Foundation
import XCTest
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/NamingTokensTests.cs: the file name field's parts, putting
// one in, what is wrong with a template, and the name the next file gets.

/// 2026-10-20 14:05:32 in the current time zone.
private func namingDate() -> Date {
    var components: DateComponents = DateComponents()
    components.year = 2026
    components.month = 10
    components.day = 20
    components.hour = 14
    components.minute = 5
    components.second = 32
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: components)!
}

final class NamingTokensTests: XCTestCase {

    func test_theInsertMenu_offersSevenParts_eachKnownAndShort() {
        var labels: [String] = []
        var tokens: [String] = []
        for part in NamingTokens.all {
            labels.append(part.label)
            tokens.append(part.token)
            XCTAssertTrue(NamingTokens.isKnown(part.token), part.token)
            XCTAssertTrue((1...3).contains(StatusLine.words(part.label)), part.label)
            XCTAssertTrue((1...15).contains(StatusLine.words(part.help)), part.help)
        }
        XCTAssertEqual(labels, ["Date", "Time", "Number", "Mode", "Task", "Document name", "Receipt date"])
        XCTAssertEqual(tokens, ["{date}", "{time}", "{counter}", "{intent}", "{task}", "{label}", "{docdate}"])
    }

    func test_insert_putsASpaceBefore_unlessAfterASpaceOrAtTheStart_andMovesTheCaretPastIt() {
        XCTAssertEqual(NamingTokens.insert("{date}", into: "Scan", at: 4), NamingInsertion(text: "Scan {date}", caret: 11))
        XCTAssertEqual(NamingTokens.insert("{date}", into: "Scan ", at: 5), NamingInsertion(text: "Scan {date}", caret: 11))
        XCTAssertEqual(NamingTokens.insert("{counter}", into: "", at: 0), NamingInsertion(text: "{counter}", caret: 9))
        XCTAssertEqual(NamingTokens.insert("{date}", into: "AB", at: 1), NamingInsertion(text: "A {date}B", caret: 8))
        XCTAssertEqual(NamingTokens.insert("{date}", into: "Scan", at: -3), NamingInsertion(text: "{date}Scan", caret: 6))
        XCTAssertEqual(NamingTokens.insert("{time}", into: "A", at: 99), NamingInsertion(text: "A {time}", caret: 8))
    }

    func test_problem_namesABlankTemplate_andTheFirstUnknownPart() {
        XCTAssertEqual(NamingTokens.problem(""), NamingTokens.emptyProblem)
        XCTAssertEqual(NamingTokens.problem("   "), "Needs a file name")
        XCTAssertNil(NamingTokens.problem("Scan {date} {counter}"))
        XCTAssertNil(NamingTokens.problem("Scan {counter:3} {year}-{month}-{day} {time} {intent} {index}"))
        XCTAssertNil(NamingTokens.problem("{task} {label} {docdate}"))
        XCTAssertEqual(NamingTokens.problem("Scan {foo} {bar}"), "Unknown part {foo}")
        XCTAssertEqual(NamingTokens.problem("Scan {counter:}"), "Unknown part {counter:}")
        XCTAssertEqual(NamingTokens.problem("Scan {counter:x}"), "Unknown part {counter:x}")
        XCTAssertEqual(NamingTokens.problem("{Date}"), "Unknown part {Date}")
        // An unclosed brace is text; a brace inside braces starts the part again.
        XCTAssertNil(NamingTokens.problem("Scan {date"))
        XCTAssertNil(NamingTokens.problem("{{date}}"))
        XCTAssertEqual(NamingTokens.braced("x{a}y{b}"), ["{a}", "{b}"])
    }

    func test_savedFormat_isWhatTheSaveWrites() {
        var s: ScanSettings = ScanSettings()
        XCTAssertEqual(NamingTokens.savedFormat(s), .pdf)
        s.format = .png
        XCTAssertEqual(NamingTokens.savedFormat(s), .pdf)
        s.documentMultiPage = false
        XCTAssertEqual(NamingTokens.savedFormat(s), .png)
        s.format = .word
        s.documentMultiPage = true
        XCTAssertEqual(NamingTokens.savedFormat(s), .word)

        var photos: ScanSettings = ScanSettings()
        photos.intent = .photo
        photos.format = .pdf
        XCTAssertEqual(NamingTokens.savedFormat(photos), .jpeg)

        var receipts: ScanSettings = TaskCatalog.apply(.receipt, to: ScanSettings())
        receipts.format = .word
        XCTAssertEqual(NamingTokens.savedFormat(receipts), .pdf)
        receipts.format = .jpeg
        XCTAssertEqual(NamingTokens.savedFormat(receipts), .jpeg)
    }

    func test_example_isTheNextFilesName() {
        let s: ScanSettings = ScanSettings()
        XCTAssertEqual(NamingTokens.example("Scan {date} {counter:3}", settings: s, format: .pdf, counter: 7, date: namingDate()),
                       "Scan 2026-10-20 007.pdf")
        XCTAssertEqual(NamingTokens.example("   ", settings: s, format: .pdf, counter: 1, date: namingDate()), "Scan.pdf")
        XCTAssertEqual(NamingTokens.example("Scan {time} {counter}", settings: s, format: .jpeg, counter: 4, date: namingDate()),
                       "Scan 14.05.32 4.jpg")

        let receipts: ScanSettings = TaskCatalog.apply(.receipt, to: ScanSettings())
        let label: String = TaskCatalog.definition(.receipt).fileLabel
        XCTAssertEqual(NamingTokens.example("{task} {docdate}", settings: receipts, format: .pdf, counter: 1, date: namingDate()),
                       "\(label) 2026-10-20.pdf")
    }
}
