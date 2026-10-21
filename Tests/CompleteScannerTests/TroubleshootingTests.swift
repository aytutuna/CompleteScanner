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

    func test_everyProblem_hasATitleOfThreeWords_andAdviceOfTen() {
        XCTAssertEqual(ScannerProblem.allCases.map { ScannerProblems.title($0) },
                       ["Something went wrong", "Feeder empty", "Paper jam", "Paper problem", "Several sheets fed", "Cover open",
                        "Scanner offline", "Scanner busy", "Warming up", "Needs attention", "Connection lost"])
        XCTAssertEqual(ScannerProblems.advice(.offline), "Turn it on and check the cable or network.")
        XCTAssertEqual(ScannerProblems.advice(.paperJam), "Clear the jam, then scan again.")
        for problem in ScannerProblem.allCases {
            XCTAssertTrue((1...3).contains(StatusLine.words(ScannerProblems.title(problem))))
            XCTAssertTrue((1...10).contains(StatusLine.words(ScannerProblems.advice(problem))))
            XCTAssertEqual(ScannerProblems.find(ScannerProblems.describe(problem)), problem)
        }
        XCTAssertEqual(ScannerProblems.genericTitle, "Something went wrong")
    }

    func test_notice_titlesTheErrorByItsProblem_andKeepsWhatToDo() {
        XCTAssertEqual(ScannerProblems.notice(ScannerProblems.describe(.offline)),
                       ProblemNotice(title: "Scanner offline", message: "Turn it on and check the cable or network."))
        // A connection's code after the text stays; the sentence before it is cut to what to do.
        XCTAssertEqual(ScannerProblems.notice(ScannerProblems.describe(.paperJam) + " (WIA error 0x80210002)"),
                       ProblemNotice(title: "Paper jam", message: "Clear the jam, then scan again. (WIA error 0x80210002)"))
        // A feeder batch that stopped: what was kept, then what to do.
        let stopped: String = ScanStop(reason: ScannerProblems.describe(.multiFeed), problem: .multiFeed).message(pagesKept: 3)
        XCTAssertEqual(ScannerProblems.notice(stopped),
                       ProblemNotice(title: "Several sheets fed",
                                     message: "Scanning stopped after 3 pages; they were kept. Fan the stack, load it again, then scan again."))
        // Any other error: the generic title and the message as it is.
        XCTAssertEqual(ScannerProblems.notice(" Saving failed: the disk is full. "),
                       ProblemNotice(title: "Something went wrong", message: "Saving failed: the disk is full."))
        XCTAssertNil(ScannerProblems.find("Saving failed: the disk is full."))
        XCTAssertNil(ScannerProblems.find(nil))
        XCTAssertNil(ScannerProblems.find(""))
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
