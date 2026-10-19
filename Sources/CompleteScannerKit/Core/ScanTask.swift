import Foundation

/// What the user is scanning, as picked on the start screen. Settings files store it as its
/// raw value (`ScanSettings.taskId`), never as this enum, so a task added by a newer version
/// survives a round trip through an older one. Only tasks whose features exist get a case;
/// later features add theirs after the existing ones. Twin of
/// `windows/CompleteScanner.Core/ScanTask.cs`.
public enum ScanTask: String, CaseIterable, Identifiable, Sendable {
    case document
    case feeder
    case photos
    case photoRestore
    case quickScan
    case email
    case twoSided
    case idCard
    case copy
    case word
    case receipt

    public var id: String { rawValue }

    /// The task stored as `rawValue`; nil for nil and for any other text (compared exactly),
    /// such as a task of a newer version.
    public static func tryParse(_ rawValue: String?) -> ScanTask? {
        guard let rawValue else { return nil }
        return ScanTask(rawValue: rawValue)
    }
}
