import Foundation

// Twin of windows/LazyScan.Core/Escl/EsclRetry.cs: the same policy and retry loop. The C#
// loop sends HttpClient requests; this one sends whatever the caller's closure sends (URLSession in
// the app) and reads the status and Retry-After through two more closures, so it stays free of any
// HTTP stack and is tested with a fake clock as the C# one is.

/// How long to keep retrying an eSCL request the device answers with HTTP 503 (busy, or the next
/// page is not ready yet): the wait starts at `initialDelay`, grows by `multiplier` up to `maxDelay`,
/// and retrying stops once another wait would pass `giveUpAfter` since the first attempt. Times are
/// in seconds.
public struct EsclRetryPolicy: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var giveUpAfter: TimeInterval

    public init(initialDelay: TimeInterval, multiplier: Double, maxDelay: TimeInterval, giveUpAfter: TimeInterval) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.giveUpAfter = giveUpAfter
    }

    public static let `default` = EsclRetryPolicy(initialDelay: 0.5, multiplier: 1.5, maxDelay: 5, giveUpAfter: 60)

    /// The wait before retry number `retry` (0-based). A Retry-After the device sent replaces the
    /// computed wait, kept within [initialDelay, maxDelay].
    public func delayBefore(_ retry: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let asked = retryAfter {
            if asked < initialDelay {
                return initialDelay
            }
            if asked > maxDelay {
                return maxDelay
            }
            return asked
        }
        let seconds: Double = initialDelay * pow(multiplier, Double(Swift.max(0, retry)))
        return seconds >= maxDelay ? maxDelay : seconds
    }
}

public enum EsclRetry {
    /// The only status that is retried: 503 Service Unavailable.
    public static func isRetryable(_ statusCode: Int) -> Bool {
        statusCode == 503
    }

    /// Sends a request, repeating it while the device answers 503, per `policy`. Returns the first
    /// other response, or the last 503 once the policy gives up. `request` must send a fresh request
    /// each time; `statusCode` and `retryAfter` (the Retry-After header in seconds, nil when there is
    /// none) read its response. `delay` and `elapsed` (time since the first attempt) default to real
    /// time and exist so tests can run without waiting. Cancelling the task stops the retries with
    /// `CancellationError`.
    public static func send<Response>(_ request: () async throws -> Response,
                                      statusCode: (Response) -> Int,
                                      retryAfter: (Response) -> TimeInterval?,
                                      policy: EsclRetryPolicy = .default,
                                      delay: ((TimeInterval) async throws -> Void)? = nil,
                                      elapsed: (() -> TimeInterval)? = nil) async throws -> Response {
        let start: TimeInterval = ProcessInfo.processInfo.systemUptime
        var retry: Int = 0
        while true {
            try Task.checkCancellation()
            let response: Response = try await request()
            if !isRetryable(statusCode(response)) {
                return response
            }
            let wait: TimeInterval = policy.delayBefore(retry, retryAfter: retryAfter(response))
            var spent: TimeInterval = ProcessInfo.processInfo.systemUptime - start
            if let clock = elapsed {
                spent = clock()
            }
            if spent + wait > policy.giveUpAfter {
                return response
            }
            if let pause = delay {
                try await pause(wait)
            } else {
                try await EsclRetry.sleep(wait)
            }
            retry += 1
        }
    }

    /// Waits `seconds` of real time; throws `CancellationError` when the task is cancelled meanwhile.
    static func sleep(_ seconds: TimeInterval) async throws {
        let nanoseconds: UInt64 = UInt64(Swift.max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
