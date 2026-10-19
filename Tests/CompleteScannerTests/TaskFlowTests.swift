import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/TaskFlowTests.cs: the same cases.

/// A two-sided card: front, then an optional back, then a review that captures nothing.
private func cardFlow() -> TaskFlow {
    TaskFlow(steps: [
        TaskStep(id: "front", title: "Front", prompt: "Place the card face down.", primaryActionLabel: "Scan front"),
        TaskStep(id: "back", title: "Back", prompt: "Turn the card over.", primaryActionLabel: "Scan back",
                 skippable: true, requiresCapture: false),
        TaskStep(id: "review", title: "Review", prompt: "Check both sides.", primaryActionLabel: "Save",
                 requiresCapture: false),
    ])
}

private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

final class TaskFlowTests: XCTestCase {

    func test_startsAtTheFirstStep() {
        let flow = cardFlow()
        XCTAssertEqual(flow.stepIndex, 0)
        XCTAssertEqual(flow.stepCount, 3)
        XCTAssertEqual(flow.current?.id, "front")
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.canFinish)
    }

    func test_advance_needsTheCapture() {
        var flow = cardFlow()
        XCTAssertFalse(flow.advance())
        XCTAssertEqual(flow.current?.id, "front")

        XCTAssertEqual(flow.record(stepID: "front", captureID: a), [])
        XCTAssertTrue(flow.canFinish)
        XCTAssertEqual(flow.current?.id, "front")
        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.current?.id, "back")
    }

    func test_finishOnlyAfterTheFront() {
        var flow = cardFlow()
        flow.record(stepID: "back", captureID: b)
        XCTAssertFalse(flow.canFinish)
        flow.record(stepID: "front", captureID: a)
        XCTAssertTrue(flow.canFinish)
    }

    func test_nonRepeatingStep_keepsTheNewestCapture() {
        var flow = cardFlow()
        flow.record(stepID: "front", captureID: a)
        XCTAssertEqual(flow.record(stepID: "front", captureID: b), [a])
        XCTAssertEqual(flow.captures(for: "front"), [b])
    }

    func test_repeatingStep_keepsEveryCapture() {
        var flow = TaskFlow(steps: [TaskStep(id: "scan", title: "Scan", prompt: "Scan each page.",
                                             primaryActionLabel: "Scan page", repeats: true)])
        XCTAssertFalse(flow.canFinish)
        XCTAssertEqual(flow.record(stepID: "scan", captureID: a), [])
        XCTAssertEqual(flow.record(stepID: "scan", captureID: b), [])
        XCTAssertEqual(flow.captures(for: "scan"), [a, b])
        XCTAssertTrue(flow.canFinish)
        XCTAssertEqual(flow.current?.id, "scan")
        XCTAssertTrue(flow.advance())
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.current)
        XCTAssertFalse(flow.advance())
    }

    func test_skip_theBack() {
        var flow = cardFlow()
        XCTAssertFalse(flow.skip()) // the front cannot be skipped
        flow.record(stepID: "front", captureID: a)
        flow.advance()
        flow.record(stepID: "back", captureID: b)
        XCTAssertTrue(flow.skip())
        XCTAssertEqual(flow.current?.id, "review")
        XCTAssertTrue(flow.isSkipped("back"))
        XCTAssertEqual(flow.captures(for: "back"), [])
        XCTAssertTrue(flow.canFinish)
        XCTAssertFalse(flow.skip()) // the review cannot be skipped
    }

    func test_retake_theFront_fromTheReview() {
        var flow = cardFlow()
        flow.record(stepID: "front", captureID: a)
        flow.advance()
        flow.record(stepID: "back", captureID: b)
        flow.advance()
        XCTAssertEqual(flow.current?.id, "review")

        XCTAssertEqual(flow.retake(stepID: "front"), [a])
        XCTAssertEqual(flow.current?.id, "front")
        XCTAssertEqual(flow.captures(for: "front"), [])
        XCTAssertEqual(flow.captures(for: "back"), [b])
        XCTAssertFalse(flow.canFinish)

        flow.record(stepID: "front", captureID: c)
        XCTAssertTrue(flow.advance())
        XCTAssertEqual(flow.current?.id, "back")
        XCTAssertEqual(flow.captures(for: "back"), [b])
    }

    func test_retake_aSkippedStep_unskipsIt() {
        var flow = cardFlow()
        flow.record(stepID: "front", captureID: a)
        flow.advance()
        flow.skip()
        XCTAssertEqual(flow.retake(stepID: "back"), [])
        XCTAssertFalse(flow.isSkipped("back"))
        XCTAssertEqual(flow.current?.id, "back")
    }

    func test_record_unskipsAStep() {
        var flow = cardFlow()
        flow.record(stepID: "front", captureID: a)
        flow.advance()
        flow.skip()
        flow.record(stepID: "back", captureID: b)
        XCTAssertFalse(flow.isSkipped("back"))
        XCTAssertEqual(flow.captures(for: "back"), [b])
    }

    func test_unknownStep_isIgnored() {
        var flow = cardFlow()
        XCTAssertEqual(flow.record(stepID: "side", captureID: a), [])
        XCTAssertEqual(flow.captures(for: "side"), [])
        XCTAssertEqual(flow.retake(stepID: "side"), [])
        XCTAssertEqual(flow.stepIndex, 0)
        XCTAssertFalse(flow.canFinish)
    }

    func test_reset_startsOver() {
        var flow = cardFlow()
        flow.record(stepID: "front", captureID: a)
        flow.advance()
        flow.skip()
        flow.reset()
        XCTAssertEqual(flow.stepIndex, 0)
        XCTAssertEqual(flow.captures(for: "front"), [])
        XCTAssertFalse(flow.isSkipped("back"))
        XCTAssertFalse(flow.canFinish)
    }

    func test_captures_areACopy() {
        var flow = cardFlow()
        flow.record(stepID: "front", captureID: a)
        let captures = flow.captures(for: "front")
        flow.record(stepID: "front", captureID: b)
        XCTAssertEqual(captures, [a])
    }

    func test_noSteps_isCompleteAndFinishable() {
        var flow = TaskFlow(steps: [])
        XCTAssertTrue(flow.isComplete)
        XCTAssertTrue(flow.canFinish)
        XCTAssertNil(flow.current)
        XCTAssertFalse(flow.advance())
        XCTAssertFalse(flow.skip())
    }

    func test_catalogFlows_oneRepeatingScanStep() {
        for definition in TaskCatalog.all {
            var flow = TaskFlow(steps: definition.steps)
            XCTAssertEqual(flow.stepCount, 1)
            XCTAssertFalse(flow.canFinish)
            flow.record(stepID: "scan", captureID: a)
            flow.record(stepID: "scan", captureID: b)
            XCTAssertTrue(flow.canFinish)
            XCTAssertEqual(flow.current?.id, "scan")
        }
    }
}
