#if os(iOS)
import CompleteScannerKit
import Foundation

/// The settings screen's words that are the iPhone's own; the sections' titles and summaries are the
/// shared `InspectorSections`.
public enum IOSSettingsText {
    public static let title = "Settings"
    public static let doneLabel = "Done"
    public static let presetsLabel = "Presets"
    public static let historyLabel = "Scans"
    public static let savedLabel = "Saved files"
    public static let fileNameLabel = "File name"
    public static let saveToLabel = "Save to"
    /// Picks a save folder in Files (iCloud Drive, a USB drive); Use app folder goes back to the app's own.
    public static let chooseFolderLabel = "Choose\u{2026}"
    public static let appFolderLabel = "Use app folder"
    public static let troubleshootLabel = "Troubleshoot"
    public static let aboutLabel = "About"
    /// The ruler test page, to check that AirPrint copies come out at real size (I16).
    public static let rulerLabel = "Print test ruler"
    public static let rulerHint = "Prints a ruler to check copies come out at real size"
    public static let resetLabel = "Reset"
    public static let notCollectingReason = "Needs Collect pages"
    public static let docdateReason = "Needs {docdate} in File name"
    public static let onlyPDFReason = "Only for PDFs"
    public static let importingReason = "Can be changed once the import has finished"
    /// The Mac's words for its Source and Mode while a side of an ID card is held.
    public static let idCardHeldReason =
        "The ID card task needs the flatbed in Document mode. Save or discard the card, or leave the task, to change this."
    /// The About screen: what the app is built with (Apple's frameworks only: no third-party code to
    /// acknowledge) and where scans stay.
    public static let aboutBuiltWith = "Built with Apple\u{2019}s frameworks only. No third-party code."
    public static let aboutPrivacy = "Your scans stay on this device unless you share them."

    /// "Version 0.1.0 (1)" from the app's Info.plist; "Version 0.1.0" without a build number.
    public static func version(_ info: [String: Any]?) -> String {
        let short: String = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }
}

/// A section of the settings screen: its header (title, the summary while it is collapsed, the dot when
/// something in it differs from the default, the lock while a password is on) and the name VoiceOver reads.
public struct IOSSettingsSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let changed: Bool
    public let locked: Bool
    public let accessibilityLabel: String
}

/// The settings screen's sections: the shared `InspectorSections` (which are shown, in which order, their
/// titles, summaries and which start open), as the Mac's inspector and the Windows window lay them out.
/// The iPhone differs in one place: a queue saved as pictures (`IOSShell.savesImages`) writes no PDF, so
/// Archive & password is hidden there and the text beside a PDF does not count. Which sections the user
/// left open is kept in the user's defaults (`storageKey`), not in presets, as on the desktop.
public enum IOSSettingsSections {
    public static let storageKey = "settings.openSections"

    /// The scan screen saves the queue as a picture a page, so no PDF is written.
    public static func savesPictures(_ s: ScanSettings) -> Bool {
        IOSShell.collectsPages(s) && IOSShell.savesImages(s)
    }

    /// Archive & password and Searchable PDF apply: a save of `s` writes a PDF here.
    public static func writesPDF(_ s: ScanSettings) -> Bool {
        InspectorSections.writesPDF(s) && !savesPictures(s)
    }

    /// Also save text applies here.
    public static func textApplies(_ s: ScanSettings) -> Bool {
        InspectorSections.textApplies(s) && !savesPictures(s)
    }

    public static func sections(_ s: ScanSettings) -> [IOSSettingsSection] {
        var result: [IOSSettingsSection] = []
        for id in InspectorSections.shown(s) {
            if id == InspectorSections.archive && !writesPDF(s) { continue }
            let title: String = InspectorSections.title(id, for: s)
            var summary: String = InspectorSections.summary(id, for: s)
            var changed: Bool = InspectorSections.changed(id, for: s)
            if id == InspectorSections.more {
                summary = InspectorSections.moreSummary(s.output, textShown: textApplies(s))
                changed = !summary.isEmpty
            }
            let name: String = id == InspectorSections.pages
                ? InspectorSections.pagesHeaderName(s.document)
                : InspectorSections.headerName(title, summary: summary)
            let locked: Bool = id == InspectorSections.archive && s.output.protect
            result.append(IOSSettingsSection(id: id, title: title, summary: summary, changed: changed, locked: locked,
                                             accessibilityLabel: name))
        }
        return result
    }

    /// The sections open at first: those `InspectorSections.openByDefault` names, as stored text.
    public static var defaultText: String {
        var open: Set<String> = []
        for id in InspectorSections.all where InspectorSections.openByDefault(id) {
            open.insert(id)
        }
        return text(open)
    }

    /// The open sections kept as text: their ids in the column's order, comma-separated ("" for none).
    public static func text(_ open: Set<String>) -> String {
        var ids: [String] = []
        for id in InspectorSections.all where open.contains(id) {
            ids.append(id)
        }
        return ids.joined(separator: ",")
    }

    /// The open sections read back; an id this version does not know is left out.
    public static func open(_ text: String) -> Set<String> {
        var open: Set<String> = []
        for part in text.split(separator: ",") {
            let id: String = String(part)
            if InspectorSections.all.contains(id) { open.insert(id) }
        }
        return open
    }

    /// A section is open as the user left it, or because the task started opened it (until the user closes it).
    public static func isOpen(_ id: String, stored: Set<String>, openedByTask: Set<String>) -> Bool {
        stored.contains(id) || openedByTask.contains(id)
    }
}

/// The four sliders of Adjustments on one -100...+100 scale (0 neutral), mapped onto the settings' own
/// ranges as on the Mac: brightness -1...1, contrast 0.25...4 (exponential, so 0 is exactly 1), saturation
/// 0...2, sharpness -2...2.
public enum IOSAdjustment: String, CaseIterable, Identifiable {
    case brightness
    case contrast
    case saturation
    case sharpness

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .sharpness: return "Sharpness"
        }
    }

    public func amount(_ a: AdjustmentSettings) -> Double {
        switch self {
        case .brightness: return a.brightness * 100
        case .contrast: return log(max(a.contrast, 0.25)) / log(4.0) * 100
        case .saturation: return (a.saturation - 1) * 100
        case .sharpness: return a.sharpness * 50
        }
    }

    public func setting(_ amount: Double, in a: AdjustmentSettings) -> AdjustmentSettings {
        var changed: AdjustmentSettings = a
        switch self {
        case .brightness: changed.brightness = amount / 100
        case .contrast: changed.contrast = pow(4.0, amount / 100)
        case .saturation: changed.saturation = 1 + amount / 100
        case .sharpness: changed.sharpness = amount / 50
        }
        return changed
    }

    /// "0", "+12", "-5".
    public static func amountText(_ amount: Double) -> String {
        let rounded: Int = Int(amount.rounded())
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// The four sliders back to neutral; the switches stay as they are.
    public static func neutral(_ a: AdjustmentSettings) -> AdjustmentSettings {
        var changed: AdjustmentSettings = a
        changed.brightness = 0
        changed.contrast = 1
        changed.saturation = 1
        changed.sharpness = 0
        return changed
    }

    public static func isNeutral(_ a: AdjustmentSettings) -> Bool {
        a.brightness == 0 && a.contrast == 1 && a.saturation == 1 && a.sharpness == 0
    }
}
#endif
