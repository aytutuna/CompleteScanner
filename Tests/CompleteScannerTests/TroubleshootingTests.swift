import XCTest
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/TroubleshootingTests.cs. C#-only cases: the
// error kind (Swift's ScanError has no kind) and the appended detail.

final class TroubleshootingTests: XCTestCase {

    func test_unknownIsTheFirstCase() {
        XCTAssertEqual(ScannerProblem.allCases.first, ScannerProblem.unknown)
    }

    func test_everyProblemHasItsOwnText() {
        let texts = ScannerProblem.allCases.map { ScannerProblems.describe($0) }
        for text in texts {
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(Set(texts).count, texts.count)
    }

    func test_emptyFeederAsksForPaper() {
        XCTAssertEqual(ScannerProblems.describe(.feederEmpty), "Load paper in the feeder, then scan again.")
    }

    func test_scannerProblemErrorCarriesTheProblemAndItsText() {
        let error = ScanError.scannerProblem(.feederEmpty)
        XCTAssertEqual(error.problem, ScannerProblem.feederEmpty)
        XCTAssertEqual(error.errorDescription, ScannerProblems.describe(.feederEmpty))
    }

    func test_otherErrorsHaveNoProblem() {
        XCTAssertNil(ScanError.scanFailed("x").problem)
        XCTAssertNil(ScanError.cancelled.problem)
    }

    func test_scanStopSaysHowManyPagesWereKeptAndWhy() {
        let stop = ScanStop.from(ScanError.scannerProblem(.paperJam))
        XCTAssertEqual(stop.problem, ScannerProblem.paperJam)
        XCTAssertEqual(stop.message(pagesKept: 3),
                       "Scanning stopped after 3 pages; they were kept. "
                       + "Paper is jammed in the scanner. Clear the jam, then scan again.")
        XCTAssertEqual(stop.message(pagesKept: 1),
                       "Scanning stopped after 1 page; it was kept. "
                       + "Paper is jammed in the scanner. Clear the jam, then scan again.")
    }

    func test_scanStopWithoutAReasonStillSaysPagesWereKept() {
        let stop = ScanStop(reason: "  ")
        XCTAssertNil(stop.problem)
        XCTAssertEqual(stop.message(pagesKept: 2), "Scanning stopped after 2 pages; they were kept.")
    }
}
