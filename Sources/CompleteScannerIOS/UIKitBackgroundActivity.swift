#if os(iOS)
import CompleteScannerKit
import Foundation
import UIKit

/// The iPhone's and iPad's `BackgroundActivity`: UIKit's background tasks
/// (`UIApplication.beginBackgroundTask`). While a task runs, the time the system has left
/// (`UIApplication.backgroundTimeRemaining`) is checked every second; once it is down to `windDownTime`,
/// the work's `expired` handler runs, while there is still time for it to wind down (a network scan
/// sends the deletion of its job then), and the task stays until the work gives it back. Should the
/// system's own expiration come first, `expired` runs then (once) and the task is ended at once, as UIKit
/// requires before the app is suspended. Tests pass their own begin, end and time left, so the test
/// host's application is never involved.
@MainActor
public final class UIKitBackgroundActivity: BackgroundActivity {
    /// Begins a background task named as given, with its expiration handler; returns its identifier
    /// (`.invalid` when the system gives no time).
    public typealias Begin = @MainActor (String, @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    /// Ends a background task.
    public typealias End = @MainActor (UIBackgroundTaskIdentifier) -> Void
    /// The background time the system has left, in seconds (very large while the app is in front).
    public typealias Remaining = @MainActor () -> TimeInterval

    /// The time left at which the work is told to stop: enough for a request on a new connection.
    public static let windDownTime: TimeInterval = 10
    /// How often the time left is checked while a task runs.
    static let checkInterval: TimeInterval = 1

    /// A background task begun and not ended yet.
    private struct Running {
        var identifier: UIBackgroundTaskIdentifier
        var expired: @MainActor () -> Void
        /// `expired` has run.
        var stopped: Bool
    }

    private let begin: Begin
    private let end: End
    private let remaining: Remaining
    private var running: [Int: Running] = [:]
    private var nextToken: Int = 1
    private var watcher: Task<Void, Never>?

    /// UIApplication's background tasks.
    public convenience init() {
        self.init(begin: { (name: String, expired: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier in
            UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: {
                MainActor.assumeIsolated {
                    expired()
                }
            })
        }, end: { (identifier: UIBackgroundTaskIdentifier) in
            UIApplication.shared.endBackgroundTask(identifier)
        }, remaining: { () -> TimeInterval in
            UIApplication.shared.backgroundTimeRemaining
        })
    }

    /// - Parameter remaining: the time left; without it the work is told to stop only by the system's
    ///   own expiration.
    public init(begin: @escaping Begin, end: @escaping End,
                remaining: @escaping Remaining = { () -> TimeInterval in TimeInterval.greatestFiniteMagnitude }) {
        self.begin = begin
        self.end = end
        self.remaining = remaining
    }

    /// The background tasks begun and not ended yet.
    public var runningCount: Int { running.count }

    public func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int? {
        let token: Int = nextToken
        nextToken += 1
        let identifier: UIBackgroundTaskIdentifier = begin(name, { [weak self] in
            self?.systemExpired(token)
        })
        if identifier == .invalid {
            return nil
        }
        running[token] = Running(identifier: identifier, expired: expired, stopped: false)
        watch()
        return token
    }

    public func endActivity(_ token: Int) {
        finish(token)
    }

    /// Tells the work under way to stop once the time left is down to `windDownTime`; its tasks stay
    /// until the work gives them back. Each work is told once.
    func checkRemaining() {
        guard !running.isEmpty, remaining() <= UIKitBackgroundActivity.windDownTime else { return }
        let tokens: [Int] = running.keys.sorted()
        for token in tokens {
            stop(token)
        }
    }

    /// The system's time is up: the work is told to stop (unless it was already), and the task ends now.
    private func systemExpired(_ token: Int) {
        stop(token)
        finish(token)
    }

    private func stop(_ token: Int) {
        guard var entry: Running = running[token], !entry.stopped else { return }
        entry.stopped = true
        running[token] = entry
        entry.expired()
    }

    private func finish(_ token: Int) {
        guard let entry: Running = running.removeValue(forKey: token) else { return }
        end(entry.identifier)
        if running.isEmpty {
            watcher?.cancel()
            watcher = nil
        }
    }

    /// Checks the time left every `checkInterval` while a task runs.
    private func watch() {
        guard watcher == nil else { return }
        let interval: UInt64 = UInt64(UIKitBackgroundActivity.checkInterval * 1_000_000_000)
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled {
                    return
                }
                guard let activity: UIKitBackgroundActivity = self else { return }
                activity.checkRemaining()
            }
        }
    }
}
#endif
