import Foundation
import Network

// Twin of windows/LazyScan.Core/Companion/CompanionRateLimiter.cs: the same limits, per address.

/// Limits what one address can try: after `maxFailures` failed authentications or pairing tokens
/// within `window` it is refused until that window has passed without more, and it may make at most
/// `maxRequestsPerWindow` requests per window. At most `maxTrackedAddresses` addresses are remembered
/// (the oldest are forgotten). An IPv4-mapped IPv6 address counts as its IPv4 address. The clock is
/// passed in. Safe to use from any thread.
public final class CompanionRateLimiter: @unchecked Sendable {
    public static let maxFailures = 10
    public static let maxRequestsPerWindow = 300
    public static let maxTrackedAddresses = 1024
    public static let window: TimeInterval = 60

    private struct Entry {
        var failures: [Date] = []
        var requests: [Date] = []
        var lastUsed = Date.distantPast
    }

    private let lock = NSLock()
    private var entries: [[UInt8]: Entry] = [:]

    public init() {}

    /// Whether `address` is refused at `now` for its failures.
    public func isBlocked(_ address: NWEndpoint.Host, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = CompanionRateLimiter.key(address)
        guard var entry = entries[key] else { return false }
        CompanionRateLimiter.prune(&entry.failures, now: now)
        entries[key] = entry
        return entry.failures.count >= CompanionRateLimiter.maxFailures
    }

    /// Counts a request; false when `address` is over its limit or blocked.
    public func tryRequest(_ address: NWEndpoint.Host, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = CompanionRateLimiter.key(address)
        var entry = entryFor(key, now: now)
        CompanionRateLimiter.prune(&entry.failures, now: now)
        CompanionRateLimiter.prune(&entry.requests, now: now)
        let allowed = entry.failures.count < CompanionRateLimiter.maxFailures
            && entry.requests.count < CompanionRateLimiter.maxRequestsPerWindow
        if allowed { entry.requests.append(now) }
        entries[key] = entry
        return allowed
    }

    /// Counts a failed authentication or pairing token from `address`.
    public func recordFailure(_ address: NWEndpoint.Host, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        let key = CompanionRateLimiter.key(address)
        var entry = entryFor(key, now: now)
        CompanionRateLimiter.prune(&entry.failures, now: now)
        entry.failures.append(now)
        if entry.failures.count > CompanionRateLimiter.maxFailures {
            entry.failures.removeFirst(entry.failures.count - CompanionRateLimiter.maxFailures)
        }
        entries[key] = entry
    }

    /// The entry of `key` (with the lock held), made when there is none; its last use is now.
    private func entryFor(_ key: [UInt8], now: Date) -> Entry {
        var entry: Entry
        if let found = entries[key] {
            entry = found
        } else {
            if entries.count >= CompanionRateLimiter.maxTrackedAddresses,
               let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                entries.removeValue(forKey: oldest)
            }
            entry = Entry()
        }
        entry.lastUsed = now
        return entry
    }

    private static func prune(_ times: inout [Date], now: Date) {
        while let first = times.first, now.timeIntervalSince(first) >= window || first > now {
            times.removeFirst()
        }
    }

    /// The address's bytes; a name (never a peer's address) counts as one address.
    private static func key(_ address: NWEndpoint.Host) -> [UInt8] {
        LocalSubnet.bytes(address) ?? []
    }
}
