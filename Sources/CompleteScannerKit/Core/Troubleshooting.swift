import Foundation

// Scanner problems every backend reports the same way, so the user sees one wording whatever
// the connection. Twin of windows/CompleteScanner.Core/Troubleshooting.cs (same cases, same
// text).

/// A condition at the scanner that stops a scan and that the user can usually fix. The first
/// case is the safe default; add new cases after the existing ones.
public enum ScannerProblem: String, CaseIterable, Sendable {
    /// The scanner reported a problem this version does not recognize.
    case unknown
    case feederEmpty
    case paperJam
    /// A misfeed or a sheet the feeder could not handle (too short, too long, ...).
    case paperProblem
    /// Several sheets were pulled in at once.
    case multiFeed
    case coverOpen
    case offline
    case busy
    case warmingUp
    /// The scanner wants someone at its panel (lamp off, a message on its display, ...).
    case needsAttention
    case communicationError
}

public enum ScannerProblems {
    /// User-facing text: what happened and what to do about it.
    public static func describe(_ problem: ScannerProblem) -> String {
        switch problem {
        case .feederEmpty:
            return "Load paper in the feeder, then scan again."
        case .paperJam:
            return "Paper is jammed in the scanner. Clear the jam, then scan again."
        case .paperProblem:
            return "The scanner could not feed the paper. Check the sheets in the feeder, then scan again."
        case .multiFeed:
            return "The scanner pulled in several sheets at once. Fan the stack, load it again, then scan again."
        case .coverOpen:
            return "The scanner's cover is open. Close it, then scan again."
        case .offline:
            return "The scanner is offline. Check that it is turned on and connected."
        case .busy:
            return "The scanner is busy. Wait until it has finished, then try again."
        case .warmingUp:
            return "The scanner is warming up. Try again in a moment."
        case .needsAttention:
            return "The scanner needs attention. Check its display or control panel."
        case .communicationError:
            return "The connection to the scanner was interrupted. Check the cable or network, then try again."
        case .unknown:
            return "The scanner reported a problem. Check the scanner, then try again."
        }
    }
}

/// Why a feeder batch ended before the feeder ran out (a jam, a dropped connection, ...). The
/// scan still returns the pages that transferred; the session keeps this in
/// `ScannerSession.lastScanStop` so the app can tell the user the stack was not finished.
/// Twin of C# `ScanStop`.
public struct ScanStop: Equatable, Sendable {
    /// User-facing text of the failure that stopped the batch.
    public var reason: String
    /// The scanner condition behind it, when the backend could tell.
    public var problem: ScannerProblem?

    public init(reason: String, problem: ScannerProblem? = nil) {
        self.reason = reason
        self.problem = problem
    }

    /// The stop for `error`: its user-facing text and, for a `ScanError`, its problem.
    public static func from(_ error: Error) -> ScanStop {
        ScanStop(reason: error.localizedDescription, problem: (error as? ScanError)?.problem)
    }

    /// User-facing text: how many pages were kept, then why scanning stopped.
    public func message(pagesKept: Int) -> String {
        let kept = pagesKept == 1
            ? "Scanning stopped after 1 page; it was kept."
            : "Scanning stopped after \(pagesKept) pages; they were kept."
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kept : "\(kept) \(trimmed)"
    }
}
