import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/CaptureStabilityTests.cs: the same scripted frame sequences.

private let frameWidth = 1000, frameHeight = 750 // diagonal 1250: 1 % = 12.5 px
private let frameMs = 33.0

private let page = Quad(topLeft: CGPoint(x: 200, y: 100), topRight: CGPoint(x: 780, y: 130),
                        bottomRight: CGPoint(x: 800, y: 650), bottomLeft: CGPoint(x: 180, y: 640))

private func shifted(_ q: Quad, _ dx: Double, _ dy: Double) -> Quad {
    Quad(topLeft: CGPoint(x: Double(q.topLeft.x) + dx, y: Double(q.topLeft.y) + dy),
         topRight: CGPoint(x: Double(q.topRight.x) + dx, y: Double(q.topRight.y) + dy),
         bottomRight: CGPoint(x: Double(q.bottomRight.x) + dx, y: Double(q.bottomRight.y) + dy),
         bottomLeft: CGPoint(x: Double(q.bottomLeft.x) + dx, y: Double(q.bottomLeft.y) + dy))
}

private typealias Step = (quad: Quad?, confidence: Double)

/// Feeds frames from `start` on; returns the indices of frames that fired.
private func feedFrames(_ stability: inout CaptureStability, _ start: Int, _ frames: [Step],
                 _ log: inout [CaptureDecision]) -> [Int] {
    var fired: [Int] = []
    var i = start
    for step in frames {
        let decision = stability.update(CaptureObservation(quad: step.quad, confidence: step.confidence,
                                                           timestampMs: Double(i) * frameMs,
                                                           frameWidth: frameWidth, frameHeight: frameHeight))
        log.append(decision)
        if decision.shouldCapture { fired.append(i) }
        i += 1
    }
    return fired
}

private func feedFrames(_ stability: inout CaptureStability, _ start: Int, _ frames: [Step]) -> [Int] {
    var log: [CaptureDecision] = []
    return feedFrames(&stability, start, frames, &log)
}

/// The page held with a tremor of ±1 px (0.1 % of the diagonal), `count` frames.
private func held(_ q: Quad, _ count: Int, _ confidence: Double = 0.9) -> [Step] {
    var steps: [Step] = []
    steps.reserveCapacity(count)
    for i in 0..<count {
        let dx: Double = (i % 2 == 0) ? 1 : -1
        let dy: Double = Double(i % 3 - 1)
        let quad: Quad = shifted(q, dx, dy)
        steps.append((quad: quad, confidence: confidence))
    }
    return steps
}

private func missing(_ count: Int) -> [Step] {
    [Step](repeating: (nil, 0.0), count: count)
}

final class CaptureStabilityTests: XCTestCase {
    func testFiresOnceWhenThePageHoldsStillLongEnough() {
        var stability = CaptureStability()
        var log: [CaptureDecision] = []
        let fired = feedFrames(&stability, 0, held(page, 60), &log)
        // Steadying starts on frame 1 (33 ms); 600 ms later is frame 20 (660 ms).
        XCTAssertEqual(fired, [20])
        XCTAssertEqual(stability.state, .captured)
        XCTAssertEqual(log[0].state, .moving)
        XCTAssertEqual(log[1].state, .steadying)
        XCTAssertTrue(log[10].progress > 0.45 && log[10].progress < 0.6, "progress \(log[10].progress)")
        for i in 2..<20 { XCTAssertGreaterThanOrEqual(log[i].progress, log[i - 1].progress) }
    }

    func testNeverFiresWhileThePageMoves() {
        var stability = CaptureStability()
        // 20 px per frame (1.6 % of the diagonal) for 3 s.
        var frames: [Step] = []
        for i in 0..<90 {
            let dx: Double = Double(20 * (i % 10))
            frames.append((quad: shifted(page, dx, 0), confidence: 0.9))
        }
        XCTAssertEqual(feedFrames(&stability, 0, frames), [])
        XCTAssertEqual(stability.state, .moving)
    }

    func testNeverFiresWhenTheDetectionIsUnsure() {
        var stability = CaptureStability()
        XCTAssertEqual(feedFrames(&stability, 0, held(page, 60, 0.55)), [])
        XCTAssertEqual(stability.state, .moving)
        XCTAssertEqual(feedFrames(&stability, 60, held(page, 60, 0.3)), [])
        XCTAssertEqual(stability.state, .noPage)
    }

    func testAConfidenceDipAboveTheStayLevelKeepsSteadying() {
        var stability = CaptureStability()
        let frames = held(page, 8) + held(page, 8, 0.5) + held(page, 30)
        XCTAssertEqual(feedFrames(&stability, 0, frames), [20])
    }

    func testAConfidenceDropBelowTheStayLevelStartsOver() {
        var stability = CaptureStability()
        let frames = held(page, 8) + held(page, 1, 0.4) + held(page, 40)
        // Frame 8 drops out of steadying; frame 9 holds still against it: steady from 9, fires at frame 28.
        XCTAssertEqual(feedFrames(&stability, 0, frames), [28])
    }

    func testSmallDriftIsToleratedButAJumpStartsOver() {
        var drift = CaptureStability()
        // Drifting 1 px per frame: after 20 frames the page is 20 px (1.6 %) from where it was, within the 2.5 % to stay.
        var slow: [Step] = []
        for i in 0..<40 {
            slow.append((quad: shifted(page, Double(i), 0), confidence: 0.9))
        }
        XCTAssertEqual(feedFrames(&drift, 0, slow), [20])

        var jump = CaptureStability()
        // A jump of 35 px (2.8 %) from where holding started on frame 10 starts over: steady from 11, fires at frame 30.
        let frames = held(page, 10) + held(shifted(page, 35, 0), 40)
        XCTAssertEqual(feedFrames(&jump, 0, frames), [30])
    }

    func testAShortDropoutIsBridgedAndALongOneStartsOver() {
        var bridged = CaptureStability()
        // Five frames missing (165 ms) are waited for, but the time from frame 7 to 13 does not
        // count: steady from 1 to 7 (198 ms) and from 13 on, 600 ms are reached at frame 26.
        XCTAssertEqual(feedFrames(&bridged, 0, held(page, 8) + missing(5) + held(page, 30)), [26])

        var lost = CaptureStability()
        // Ten frames missing (330 ms): the page is new again from frame 18; steady from 19, fires at 38.
        XCTAssertEqual(feedFrames(&lost, 0, held(page, 8) + missing(10) + held(page, 40)), [38])
    }

    func testTheTimeThePageIsMissingDoesNotCountAsHoldingStill() {
        var stability = CaptureStability()
        var log: [CaptureDecision] = []
        // Steady from frame 1 (33 ms), last seen at frame 13 (429 ms), a hand over it until frame 20
        // (660 ms, 231 ms later): 396 ms were held still, 204 more are needed after it comes back.
        XCTAssertEqual(feedFrames(&stability, 0, held(page, 14) + missing(6) + held(page, 30), &log), [27])
        for i in 14..<20 {
            XCTAssertEqual(log[i].state, .steadying)
            XCTAssertEqual(log[i].progress, log[13].progress)
        }
        XCTAssertLessThanOrEqual(log[20].progress, log[13].progress)
    }

    func testThePageIsTheSameWhicheverCornerItsQuadNamesFirst() {
        // The same outline named from its top edge and from its right edge, frame by frame.
        let renamed = Quad(topLeft: page.topRight, topRight: page.bottomRight, bottomRight: page.bottomLeft,
                           bottomLeft: page.topLeft)
        XCTAssertGreaterThan(page.maxCornerDistance(renamed), 500)
        XCTAssertEqual(CaptureStability.movement(page, renamed), 0)
        var stability = CaptureStability()
        var frames: [Step] = []
        for (i, step) in held(page, 120).enumerated() {
            if i % 2 == 1, let q = step.quad {
                let named = Quad(topLeft: q.topRight, topRight: q.bottomRight, bottomRight: q.bottomLeft, bottomLeft: q.topLeft)
                frames.append((quad: named, confidence: step.confidence))
            } else {
                frames.append(step)
            }
        }
        XCTAssertEqual(feedFrames(&stability, 0, frames), [20])
        XCTAssertEqual(stability.state, .captured)
    }

    func testASheetTurnedWhereItsCornersAreRenamedIsStillHeldStill() {
        // An A4 sheet (420 × 594 px) turned 54.6° and 54.8°: on either side of the angle where its
        // two upper edges' midpoints are equally high, so fromCorners starts from different corners.
        func turned(_ degrees: Double) -> Quad {
            let angle = degrees * Double.pi / 180, c = cos(angle), s = sin(angle)
            let us: [Double] = [-210, 210, 210, -210], vs: [Double] = [-297, -297, 297, 297]
            var corners: [CGPoint] = []
            for k in 0..<4 {
                corners.append(CGPoint(x: 500 + us[k] * c - vs[k] * s, y: 375 + us[k] * s + vs[k] * c))
            }
            return Quad.fromCorners(corners)
        }
        let a = turned(54.6), b = turned(54.8)
        XCTAssertGreaterThan(a.maxCornerDistance(b), 200, "the names did not change: \(a) \(b)")
        XCTAssertLessThan(CaptureStability.movement(a, b), 3)
        var stability = CaptureStability()
        var frames: [Step] = []
        for i in 0..<61 {
            let quad: Quad = (i % 2 == 0) ? a : b
            frames.append((quad: quad, confidence: 0.9))
        }
        XCTAssertEqual(feedFrames(&stability, 0, frames), [20])
    }

    func testAPauseBetweenFramesDoesNotTakeTheSamePageAgain() {
        // A 300 ms pause in the frames right after the shutter fired (the photo being taken), the page
        // still there: it stays taken. Laid 200 px aside afterwards, the next page is taken.
        var stability = CaptureStability()
        var fired: [Int] = []
        let frames = held(page, 61) + held(shifted(page, 200, 0), 40)
        for (i, step) in frames.enumerated() {
            let t = Double(i) * frameMs + (i > 20 ? 300 : 0)
            let decision = stability.update(CaptureObservation(quad: step.quad, confidence: step.confidence, timestampMs: t,
                                                               frameWidth: frameWidth, frameHeight: frameHeight))
            if decision.shouldCapture { fired.append(i) }
        }
        XCTAssertEqual(fired, [20, 81])
    }

    func testTheSamePageIsNotTakenTwice() {
        var stability = CaptureStability()
        XCTAssertEqual(feedFrames(&stability, 0, held(page, 120)), [20])
        XCTAssertEqual(stability.state, .captured)
    }

    func testTheNextPageIsTakenAfterThePageLeavesOrMoves() {
        var removed = CaptureStability()
        // Captured at 20; gone from 30 to 39; back at 40, steady from 41, fires at 60.
        XCTAssertEqual(feedFrames(&removed, 0, held(page, 30) + missing(10) + held(page, 40)), [20, 60])

        var moved = CaptureStability()
        // The next page laid 200 px (16 %) aside: re-armed at 30, steady from 31, fires at 50.
        XCTAssertEqual(feedFrames(&moved, 0, held(page, 30) + held(shifted(page, 200, 0), 40)), [20, 50])
    }

    func testResetArmsTheShutterAgain() {
        var stability = CaptureStability()
        XCTAssertEqual(feedFrames(&stability, 0, held(page, 30)), [20])
        stability.reset()
        XCTAssertEqual(stability.state, .noPage)
        // After a reset the next frame is a page seen again: steady from 31, fires at 50.
        XCTAssertEqual(feedFrames(&stability, 30, held(page, 30)), [50])
    }
}
