import CoreGraphics
import Foundation

// Twin of windows/LazyScan.Core/PaperSize.cs: one paper size model for scan areas, and
// later for the ID card page and printing.

/// A paper size (`ScanSettings.paperSize`). `.auto` comes first: it is the default and the
/// fallback for a size a newer version adds, and it scans the whole glass or the feeder's own
/// sheet size, as before the setting existed. Add new sizes after the existing ones. Twin of C#
/// `PaperSize` (labels: `PaperSizes.Label` / `Detail`).
public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case letter
    case legal
    case executive
    case a4
    case a5
    case a6
    case b5Jis
    /// An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.
    case idCard

    public var id: String { rawValue }

    /// What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".
    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .executive: return "Executive"
        case .a4: return "A4"
        case .a5: return "A5"
        case .a6: return "A6"
        case .b5Jis: return "B5 (JIS)"
        case .idCard: return "ID card"
        }
    }

    /// The dimensions as people know them: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it scans.
    public var detail: String {
        switch self {
        case .auto: return "The whole glass, or the sheet in the feeder"
        case .letter: return "8.5 \u{00D7} 11 in"
        case .legal: return "8.5 \u{00D7} 14 in"
        case .executive: return "7.25 \u{00D7} 10.5 in"
        case .a4: return "210 \u{00D7} 297 mm"
        case .a5: return "148 \u{00D7} 210 mm"
        case .a6: return "105 \u{00D7} 148 mm"
        case .b5Jis: return "182 \u{00D7} 257 mm"
        case .idCard: return "85.6 \u{00D7} 54 mm"
        }
    }
}

/// Dimensions of the paper sizes and where they apply. Twin of C# `PaperSizes`.
public enum PaperSizes {
    /// A size fits an area when it is at most this much larger (in inches): A4's 11.69 in on an
    /// 11.7 in glass, rounding in drivers.
    public static let fitTolerance = 0.05

    /// Countries and territories that use US Letter (the ICU paper-size list): everywhere else
    /// uses A4.
    public static let letterRegions = ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"]

    /// Portrait width × height in inches; nil for `.auto`.
    public static func inches(_ size: PaperSize) -> CGSize? {
        switch size {
        case .auto: return nil
        case .letter: return CGSize(width: 8.5, height: 11)
        case .legal: return CGSize(width: 8.5, height: 14)
        case .executive: return CGSize(width: 7.25, height: 10.5)
        case .a4: return CGSize(width: 8.2677, height: 11.6929)
        case .a5: return CGSize(width: 5.8268, height: 8.2677)
        case .a6: return CGSize(width: 4.1339, height: 5.8268)
        case .b5Jis: return CGSize(width: 7.1654, height: 10.1181)
        case .idCard: return CGSize(width: 2.125, height: 3.370)
        }
    }

    /// The size stored as `text` (its raw value, compared without regard to case and surrounding
    /// spaces); `.auto` for nil and anything else.
    public static func parse(_ text: String?) -> PaperSize {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        return PaperSize.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) ?? .auto
    }

    /// The usual paper where the user lives: Letter in `letterRegions`, A4 everywhere else and
    /// when the region is unknown. `regionCode` is a two-letter ISO 3166 code in any case.
    public static func defaultForRegion(_ regionCode: String?) -> PaperSize {
        let code = (regionCode ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return letterRegions.contains(code) ? .letter : .a4
    }

    /// The named size a sheet of `inches` is (a printer's paper), either way round, each side within
    /// `fitTolerance`; nil for a size without a name here.
    public static func match(_ inches: CGSize) -> PaperSize? {
        let shortSide = min(Double(inches.width), Double(inches.height))
        let longSide = max(Double(inches.width), Double(inches.height))
        guard shortSide > 0 else { return nil }
        for size in PaperSize.allCases {
            guard let paper = self.inches(size) else { continue }
            if abs(Double(paper.width) - shortSide) <= fitTolerance && abs(Double(paper.height) - longSide) <= fitTolerance {
                return size
            }
        }
        return nil
    }

    /// The sizes as pickers list them: Automatic, the region's usual size, then the others in
    /// declaration order.
    public static func displayOrder(region regionCode: String?) -> [PaperSize] {
        let usual = defaultForRegion(regionCode)
        return [.auto, usual] + PaperSize.allCases.filter { $0 != .auto && $0 != usual }
    }

    /// The size fits `area` (portrait, within `fitTolerance`). Automatic always fits, and so does
    /// every size when the area is unknown.
    public static func fits(_ size: PaperSize, in area: CGSize?) -> Bool {
        guard let paper = inches(size), let area, area.width > 0, area.height > 0 else { return true }
        return Double(paper.width) <= Double(area.width) + fitTolerance
            && Double(paper.height) <= Double(area.height) + fitTolerance
    }

    /// The part of the glass a paper size covers, as a selection (normalized 0...1, origin
    /// top-left, where sheets are laid against the corner), clamped to the glass; nil for
    /// Automatic (the whole glass) and for an unknown glass size.
    public static func flatbedSelection(_ size: PaperSize, bed: CGSize) -> CGRect? {
        guard let paper = inches(size), bed.width > 0, bed.height > 0 else { return nil }
        return CGRect(x: 0, y: 0, width: min(1, paper.width / bed.width), height: min(1, paper.height / bed.height))
    }

    /// The area a feeder scan asks for, in inches from the top-left corner: the paper size,
    /// clamped to the feeder's largest sheet `max`; the largest sheet itself for Automatic.
    public static func feederRegionInches(_ size: PaperSize, max maxSheet: CGSize) -> CGRect {
        guard let paper = inches(size) else {
            return CGRect(x: 0, y: 0, width: maxSheet.width, height: maxSheet.height)
        }
        return CGRect(x: 0, y: 0, width: min(paper.width, maxSheet.width), height: min(paper.height, maxSheet.height))
    }

    /// What a size scans from `source`, in a line: its item's tooltip in the paper size picker.
    public static func hint(_ size: PaperSize, source: ScanSource) -> String {
        let feeder = source == .documentFeeder
        if size == .auto {
            return feeder ? "The sheet size the feeder takes." : "The whole glass, or the area selected on the preview."
        }
        return feeder
            ? "Sheets of this size, from the feeder."
            : "From the glass corner. A preview selection replaces it."
    }

    /// Why a size is not offered: it is larger than the glass or the feeder of the scanner. The picker
    /// shows it after the size's name, greyed out ("A3 (297 × 420 mm) · Too big for this glass").
    public static func doesNotFitReason(source: ScanSource) -> String {
        let part: String = source == .documentFeeder ? "feeder" : "glass"
        return "Too big for this \(part)"
    }

    /// The live line under the paper size while an area of the preview is selected: the scan takes
    /// that area, whatever the size says.
    public static let selectedAreaNote = "Using the selected area"
}
