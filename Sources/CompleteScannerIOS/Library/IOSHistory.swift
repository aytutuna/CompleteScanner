#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation

/// A scan of this session as the Scans screen lists it: its small picture, "Document · 300 dpi", the
/// time it was taken (with the day for earlier days), and the whole of it for VoiceOver.
public struct IOSHistoryRow: Identifiable {
    public let id: UUID
    public let thumbnail: CGImage
    public let title: String
    public let time: String
    public let symbol: String
    public let accessibilityLabel: String
}

/// The Scans screen without a screen: `AppState.scanHistory` (this session's scans, newest first, small
/// pictures only), read-only as on the Mac and Windows.
public enum IOSHistory {
    public static let title = "Scans"
    public static let emptyTitle = "No scans yet"
    public static let emptyLine = "Scans from this session appear here, newest first."

    /// "1 scan", "13 scans".
    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 scan" : "\(count) scans"
    }

    public static func rows(_ entries: [ScanHistoryEntry], now: Date, calendar: Calendar = Calendar.current,
                            locale: Locale = Locale.current) -> [IOSHistoryRow] {
        var rows: [IOSHistoryRow] = []
        for entry in entries {
            let time: String = timeText(entry.date, now: now, calendar: calendar, locale: locale)
            let width: Int = Int(entry.pixelSize.width)
            let height: Int = Int(entry.pixelSize.height)
            let photo: Bool = entry.intent == .photo
            let spoken: String = "\(photo ? "Photo" : "Document") scan, \(entry.dpi) dpi, \(width) by \(height) pixels, \(time)"
            rows.append(IOSHistoryRow(id: entry.id, thumbnail: entry.thumbnail,
                                      title: "\(entry.intent.label) \u{00B7} \(entry.dpi) dpi", time: time,
                                      symbol: photo ? "photo" : "doc.text", accessibilityLabel: spoken))
        }
        return rows
    }

    /// The time of a scan of today ("4:23 PM"), with the day for an earlier one ("Oct 19, 4:23 PM").
    public static func timeText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let template: String = calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMdjmm"
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
#endif
