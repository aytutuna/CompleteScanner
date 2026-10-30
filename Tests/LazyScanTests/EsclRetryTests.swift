import XCTest
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/EsclRetryTests.cs (same cases). Time is simulated: the
// fake delay advances a fake clock instead of waiting. A response is its status code and Retry-After.

final class EsclRetryTests: XCTestCase {
    private struct StubResponse: Sendable {
        let status: Int
        let retryAfter: TimeInterval?
    }

    /// Answers with the queued statuses in order, then 200; counts every request.
    private final class StubScanner: @unchecked Sendable {
        private var statuses: [Int]
        private(set) var requests = 0
        let retryAfter: TimeInterval?

        init(_ statuses: [Int], retryAfter: TimeInterval? = nil) {
            self.statuses = statuses
            self.retryAfter = retryAfter
        }

        func answer() -> StubResponse {
            requests += 1
            var status: Int = 200
            if !statuses.isEmpty {
                status = statuses.removeFirst()
            }
            return StubResponse(status: status, retryAfter: status == 503 ? retryAfter : nil)
        }
    }

    private final class FakeClock: @unchecked Sendable {
        private(set) var now: TimeInterval = 0
        private(set) var delays: [TimeInterval] = []

        func delay(_ wait: TimeInterval) throws {
            try Task.checkCancellation()
            delays.append(wait)
            now += wait
        }
    }

    private func send(_ scanner: StubScanner, _ clock: FakeClock) async throws -> StubResponse {
        try await EsclRetry.send({ () async throws -> StubResponse in scanner.answer() },
                                 statusCode: { (response: StubResponse) -> Int in response.status },
                                 retryAfter: { (response: StubResponse) -> TimeInterval? in response.retryAfter },
                                 delay: { (wait: TimeInterval) async throws -> Void in try clock.delay(wait) },
                                 elapsed: { () -> TimeInterval in clock.now })
    }

    func testRetriesBusyThenSucceeds() async throws {
        let scanner: StubScanner = StubScanner([503, 503])
        let clock: FakeClock = FakeClock()
        let response: StubResponse = try await send(scanner, clock)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(scanner.requests, 3)
        XCTAssertEqual(clock.delays, [0.5, 0.75])
    }

    func testOtherStatusesAreNotRetried() async throws {
        let statuses: [Int] = [404, 409, 500, 201]
        for status in statuses {
            let scanner: StubScanner = StubScanner([status])
            let clock: FakeClock = FakeClock()
            let response: StubResponse = try await send(scanner, clock)
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(scanner.requests, 1)
            XCTAssertTrue(clock.delays.isEmpty)
        }
    }

    func testGivesUpAfterSixtySecondsWithTheLast503() async throws {
        let scanner: StubScanner = StubScanner([Int](repeating: 503, count: 100))
        let clock: FakeClock = FakeClock()
        let response: StubResponse = try await send(scanner, clock)
        XCTAssertEqual(response.status, 503)
        // 0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875 (10.390625 s), then nine waits of 5 s
        // (55.390625 s); one more would pass 60 s.
        XCTAssertEqual(clock.delays.count, 15)
        XCTAssertEqual(scanner.requests, 16)
        XCTAssertLessThanOrEqual(clock.now, 60)
        XCTAssertGreaterThan(clock.now + 5, 60)
    }

    func testBackoffGrowsByHalfAndCapsAtFiveSeconds() {
        let policy: EsclRetryPolicy = .default
        let expected: [Double] = [0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875, 5, 5]
        for retry in 0..<8 {
            XCTAssertEqual(policy.delayBefore(retry), expected[retry], accuracy: 1e-12, "retry \(retry)")
        }
    }

    func testRetryAfterIsHonoredWithinTheBounds() async throws {
        let scanner: StubScanner = StubScanner([503], retryAfter: 2)
        let clock: FakeClock = FakeClock()
        _ = try await send(scanner, clock)
        XCTAssertEqual(clock.delays, [2])

        XCTAssertEqual(EsclRetryPolicy.default.delayBefore(0, retryAfter: 120), 5)
        XCTAssertEqual(EsclRetryPolicy.default.delayBefore(3, retryAfter: 0), 0.5)
    }

    func testCancellationStopsRetrying() async throws {
        let scanner: StubScanner = StubScanner([Int](repeating: 503, count: 100))
        let clock: FakeClock = FakeClock()
        let task: Task<StubResponse, Error> = Task {
            try await EsclRetry.send({ () async throws -> StubResponse in scanner.answer() },
                                     statusCode: { (response: StubResponse) -> Int in response.status },
                                     retryAfter: { (response: StubResponse) -> TimeInterval? in response.retryAfter },
                                     delay: { (wait: TimeInterval) async throws -> Void in
                                         if clock.delays.count == 2 {
                                             withUnsafeCurrentTask { (current: UnsafeCurrentTask?) -> Void in
                                                 current?.cancel()
                                             }
                                         }
                                         try clock.delay(wait)
                                     },
                                     elapsed: { () -> TimeInterval in clock.now })
        }
        do {
            _ = try await task.value
            XCTFail("The retries went on after the cancellation")
        } catch is CancellationError {
            // Stopped.
        }
        XCTAssertEqual(scanner.requests, 3)
    }
}
