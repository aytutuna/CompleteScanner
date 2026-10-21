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
    /// The system suspended the app in the background before the scanner had finished (the pages
    /// received are kept). Only the iPhone and iPad produce it, through their eSCL connection; the
    /// Windows app never does, but knows its text.
    case appSuspended
}

/// An error as the error bar or alert shows it: what went wrong in a few words, and what to do.
/// Twin of C# `ProblemNotice`.
public struct ProblemNotice: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
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
        case .appSuspended:
            return "The system suspended CompleteScanner in the background before the scan finished. Keep the app open while scanning, then scan again."
        case .unknown:
            return "The scanner reported a problem. Check the scanner, then try again."
        }
    }

    /// The title of an error that names no scanner problem.
    public static let genericTitle = "Something went wrong"

    /// The problem in two or three words, for the title of the error alert: "Paper jam", "Scanner offline".
    public static func title(_ problem: ScannerProblem) -> String {
        switch problem {
        case .feederEmpty: return "Feeder empty"
        case .paperJam: return "Paper jam"
        case .paperProblem: return "Paper problem"
        case .multiFeed: return "Several sheets fed"
        case .coverOpen: return "Cover open"
        case .offline: return "Scanner offline"
        case .busy: return "Scanner busy"
        case .warmingUp: return "Warming up"
        case .needsAttention: return "Needs attention"
        case .communicationError: return "Connection lost"
        case .appSuspended: return "App suspended"
        case .unknown: return genericTitle
        }
    }

    /// What to do, in ten words at most, shown under `title`; `describe` is the sentence that stands on
    /// its own (error messages, the status line, the troubleshooter).
    public static func advice(_ problem: ScannerProblem) -> String {
        switch problem {
        case .feederEmpty: return "Load paper in the feeder, then scan again."
        case .paperJam: return "Clear the jam, then scan again."
        case .paperProblem: return "Check the sheets in the feeder, then scan again."
        case .multiFeed: return "Fan the stack, load it again, then scan again."
        case .coverOpen: return "Close the cover, then scan again."
        case .offline: return "Turn it on and check the cable or network."
        case .busy: return "Wait until it has finished, then try again."
        case .warmingUp: return "Try again in a moment."
        case .needsAttention: return "Check its display or control panel."
        case .communicationError: return "Check the cable or network, then try again."
        case .appSuspended: return "Keep the app open while scanning, then scan again."
        case .unknown: return "Check the scanner, then try again."
        }
    }

    /// The scanner problem an error message describes (its `describe` text is in it); nil when none is.
    public static func find(_ message: String?) -> ScannerProblem? {
        guard let message, !message.isEmpty else { return nil }
        for problem in ScannerProblem.allCases where message.contains(describe(problem)) {
            return problem
        }
        return nil
    }

    /// How the error alert shows `message`: a title naming the problem ("Paper jam") and the message
    /// with the problem's sentence cut to what to do ("Clear the jam, then scan again."); "Something
    /// went wrong" and the message as it is when it names no problem.
    public static func notice(_ message: String) -> ProblemNotice {
        let trimmed: String = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let problem = find(message) else {
            return ProblemNotice(title: genericTitle, message: trimmed)
        }
        let shortened: String = message.replacingOccurrences(of: describe(problem), with: advice(problem))
        return ProblemNotice(title: title(problem),
                             message: shortened.trimmingCharacters(in: .whitespacesAndNewlines))
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
