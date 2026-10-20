import Foundation

// Twin of windows/CompleteScanner.Core/Companion/PairingSession.cs: the same lifetime, attempt limit
// and answers.

/// Where a pairing session is.
public enum PairingSessionState: Equatable, Sendable {
    /// Waiting for a phone to present the token.
    case open
    /// A phone presented the token; it cannot be used again.
    case used
    /// Its five minutes are over.
    case expired
    /// Closed by the desktop, or after too many wrong tokens.
    case closed
}

/// The answer to a token presented to a pairing session.
public enum PairingRedeemResult: Equatable, Sendable {
    case accepted
    case wrongToken
    case expired
    case alreadyUsed
    case closed
}

/// A pairing session made with a token that is not 16 bytes.
public struct PairingSessionError: Error, Equatable, Sendable {}

/// One pairing window on the desktop: a random 128-bit token shown in the QR code, good for one
/// pairing within `lifetime`. Tokens are compared in constant time; after `maxFailedAttempts` wrong
/// ones the session closes, so a token cannot be guessed. The clock is passed in, so tests control it.
/// Safe to use from any thread.
public final class PairingSession: @unchecked Sendable {
    public static let lifetime: TimeInterval = 5 * 60
    public static let maxFailedAttempts = 5

    private let lock = NSLock()
    private let tokenBytes: [UInt8]
    private var current: PairingSessionState = .open
    private var failed = 0

    /// The token as the pairing code carries it (base64url, 22 characters).
    public let token: String
    public let opened: Date
    public let expires: Date

    /// - Parameters:
    ///   - opened: When the session opens; it expires `lifetime` later.
    ///   - token: The token's 16 bytes; random when nil (tests pass their own).
    public init(opened: Date, token: Data? = nil) throws {
        let bytes: [UInt8]
        if let token = token {
            guard token.count == PairingUri.tokenByteCount else { throw PairingSessionError() }
            bytes = [UInt8](token)
        } else {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<PairingUri.tokenByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        }
        tokenBytes = bytes
        self.token = CompanionProtocol.encodeBase64Url(Data(bytes))
        self.opened = opened
        expires = opened.addingTimeInterval(PairingSession.lifetime)
    }

    public var failedAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// Where the session is at `now`.
    public func state(at now: Date) -> PairingSessionState {
        lock.lock()
        defer { lock.unlock() }
        return current == .open && now >= expires ? .expired : current
    }

    /// How long the session stays open after `now`; zero once it is not open.
    public func remaining(at now: Date) -> TimeInterval {
        state(at: now) == .open ? expires.timeIntervalSince(now) : 0
    }

    /// Presents `token` at `now`. The right token while the session is open is accepted once; a wrong
    /// one counts towards `maxFailedAttempts`, after which the session is closed.
    public func redeem(_ token: String?, now: Date) -> PairingRedeemResult {
        lock.lock()
        defer { lock.unlock() }
        switch current {
        case .used: return .alreadyUsed
        case .closed: return .closed
        case .open, .expired: break
        }
        if now >= expires {
            current = .expired
            return .expired
        }
        if current == .expired { return .expired }
        var matches = false
        if let presented = CompanionProtocol.decodeBase64Url(token), presented.count == PairingUri.tokenByteCount {
            let bytes = [UInt8](presented)
            var difference: UInt8 = 0
            for i in 0..<tokenBytes.count {
                difference |= bytes[i] ^ tokenBytes[i]
            }
            matches = difference == 0
        }
        if !matches {
            failed += 1
            if failed >= PairingSession.maxFailedAttempts { current = .closed }
            return .wrongToken
        }
        current = .used
        return .accepted
    }

    /// Closes the session: no token is accepted any more.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if current == .open { current = .closed }
    }
}
