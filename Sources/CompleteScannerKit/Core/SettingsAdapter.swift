import Foundation

/// Which setting `SettingsAdapter.adapt` changed. Twin of C# `SettingsChange`
/// (`windows/CompleteScanner.Core/SettingsAdapter.cs`).
public enum SettingsChange: String, Sendable {
    case source
    case resolution
}

/// A setting changed to suit the scanner, with a sentence saying so.
public struct SettingsNote: Equatable, Sendable {
    public let change: SettingsChange
    public let message: String

    public init(change: SettingsChange, message: String) {
        self.change = change
        self.message = message
    }
}

/// The settings as the scanner can use them, and what had to change.
public struct AdaptedSettings: Equatable, Sendable {
    public let settings: ScanSettings
    public let notes: [SettingsNote]
}

/// Fits settings to what a scanner offers: a source it has (the first one it lists when the
/// chosen one is missing; the flatbed when it lists none) and the nearest resolution it
/// supports. Used whenever settings meet a scanner: applying a preset or task, and connecting
/// to another scanner. Twin of C# `SettingsAdapter`.
public enum SettingsAdapter {
    /// `settings` adapted to `capabilities` (unchanged when nil: no scanner connected yet).
    public static func adapt(_ settings: ScanSettings, to capabilities: ScannerCapabilities?) -> AdaptedSettings {
        var s = settings
        var notes: [SettingsNote] = []
        guard let capabilities else { return AdaptedSettings(settings: s, notes: notes) }

        if !capabilities.sources.contains(s.source) {
            let fallback = capabilities.sources.first ?? .flatbed
            if fallback != s.source {
                notes.append(SettingsNote(change: .source, message: fallback == .documentFeeder
                    ? "This scanner has no flatbed, so the document feeder is used."
                    : "This scanner has no document feeder, so the flatbed is used."))
                s.source = fallback
            }
        }

        let resolution = capabilities.nearestResolution(to: s.resolution)
        if resolution != s.resolution {
            notes.append(SettingsNote(change: .resolution,
                                      message: "This scanner does not offer \(s.resolution) dpi, so \(resolution) dpi is used."))
            s.resolution = resolution
        }
        return AdaptedSettings(settings: s, notes: notes)
    }
}
