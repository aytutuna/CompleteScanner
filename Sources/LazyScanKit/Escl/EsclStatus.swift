import Foundation

// Twin of windows/LazyScan.Core/Escl/EsclStatus.cs: the same status mapping and tests.

/// A parsed eSCL ScannerStatus document: the device state (pwg:State) and the feeder state
/// (scan:AdfState), read after a job fails to tell the user what is wrong at the scanner.
public struct EsclScannerStatus: Equatable, Sendable {
    /// "Idle", "Processing", "Testing", "Stopped" or "Down".
    public var state: String?
    /// e.g. "ScannerAdfLoaded", "ScannerAdfEmpty", "ScannerAdfJam"; nil without a feeder.
    public var adfState: String?

    public init(state: String? = nil, adfState: String? = nil) {
        self.state = state
        self.adfState = adfState
    }

    /// The status document, or nil when the text is not XML.
    public static func parse(_ xml: String) -> EsclScannerStatus? {
        parse(data: Data(xml.utf8))
    }

    /// Same as `parse(_:)` for the document's bytes as the scanner sent them.
    public static func parse(data: Data) -> EsclScannerStatus? {
        var problem: String = ""
        guard let root = EsclXml.parse(data, error: &problem) else { return nil }
        return EsclScannerStatus(state: root.descendants("State").first?.text,
                                 adfState: root.descendants("AdfState").first?.text)
    }

    /// What stops a scan from `source`: the feeder state first for feeder jobs (the platen ignores
    /// it), then the device state. nil when nothing is wrong.
    public func problem(_ source: ScanSource) -> ScannerProblem? {
        if source == .documentFeeder, let adf = EsclScannerStatus.adfProblem(adfState) {
            return adf
        }
        switch state ?? "" {
        case "Down": return .offline
        case "Stopped": return .needsAttention
        case "Testing": return .warmingUp
        case "Processing": return .busy
        default: return nil
        }
    }

    private static func adfProblem(_ adfState: String?) -> ScannerProblem? {
        switch adfState ?? "" {
        case "ScannerAdfEmpty": return .feederEmpty
        case "ScannerAdfJam": return .paperJam
        case "ScannerAdfHatchOpen": return .coverOpen
        case "ScannerAdfMultipickDetected": return .multiFeed
        case "ScannerAdfMispick", "ScannerAdfDuplexPageTooShort", "ScannerAdfDuplexPageTooLong",
             "ScannerAdfInputTrayFailed", "ScannerAdfInputTrayOverloaded":
            return .paperProblem
        default: return nil
        }
    }
}
