import Foundation
import CoreGraphics

// Twin of windows/LazyScan.Core/Escl/EsclScanRequest.cs: the same job settings and a
// ScanSettings document byte for byte the same as the C# one (checked against the shared request
// fixtures in Tests/Fixtures/Escl).

/// A scan region in eSCL units (1/300 inch), origin top-left.
public struct EsclRegion: Equatable, Hashable, Sendable {
    public var xOffset: Int
    public var yOffset: Int
    public var width: Int
    public var height: Int

    public init(xOffset: Int, yOffset: Int, width: Int, height: Int) {
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.width = width
        self.height = height
    }
}

/// The settings of one eSCL scan job, chosen from what the device offers, and the ScanSettings
/// document that requests them.
public struct EsclScanRequest: Equatable, Sendable {
    /// Tallest default feeder region, in inches (tabloid / ledger). Feeders that also take long paper
    /// report heights of several feet; asking for that much could produce one enormous image per sheet.
    public static let maxFeederHeightInches: Double = 17

    /// "Platen" or "Feeder".
    public var inputSource: String
    /// eSCL color mode, e.g. "RGB24" or "Grayscale8". Never "BlackAndWhite1": see `create`.
    public var colorMode: String
    public var documentFormat: String
    public var resolution: Int
    public var region: EsclRegion
    /// Scan both sides of each sheet (feeder jobs on a device with a two-sided feeder only).
    public var duplex: Bool

    public init(inputSource: String, colorMode: String, documentFormat: String, resolution: Int,
                region: EsclRegion, duplex: Bool = false) {
        self.inputSource = inputSource
        self.colorMode = colorMode
        self.documentFormat = documentFormat
        self.resolution = resolution
        self.region = region
        self.duplex = duplex
    }

    /// Chooses the job settings for a scan.
    /// - Flatbed: the whole platen, or `selection` (normalized 0...1, top-left origin) of it.
    /// - Feeder: `paperSize` from the top-left corner, clamped to the feeder's largest sheet; for
    ///   Automatic the feeder's own maximum sheet size (height capped at `maxFeederHeightInches`). The
    ///   selection is ignored.
    /// - Two-sided (`duplex`): only for feeder jobs on a device that lists two-sided feeding; the job
    ///   then uses the feeder's two-sided capabilities when it lists them separately.
    /// - Black & white is requested as 8-bit grayscale: most devices reject 1-bit JPEG, and the app's
    ///   image pipeline thresholds the page afterwards, as it does for every non-color scan.
    /// - The resolution snaps to the nearest one the input offers.
    /// - The format is JPEG, else PNG, else TIFF, whichever the input offers first.
    public static func create(_ caps: EsclCapabilities, source: ScanSource, colorMode: ColorMode, dpi: Int,
                              selection: CGRect?, duplex: Bool = false,
                              paperSize: PaperSize = .auto) -> EsclScanRequest {
        let feeder: Bool = source == .documentFeeder
        let twoSided: Bool = feeder && duplex && caps.supportsDuplex
        var input: EsclInputCaps? = caps.inputCaps(source)
        if twoSided {
            input = caps.adfDuplex ?? caps.feeder
        }

        let area: CGSize
        if feeder {
            var maxSheet: CGSize = EsclCapabilities.defaultAreaInches
            if let size = input?.maxSizeInches {
                maxSheet = size
            } else if let size = caps.feeder?.maxSizeInches {
                maxSheet = size
            } else if let size = caps.platen?.maxSizeInches {
                maxSheet = size
            }
            let paper: CGRect = PaperSizes.feederRegionInches(paperSize, max: maxSheet)
            let height: Double = Swift.min(Double(paper.height), maxFeederHeightInches)
            area = CGSize(width: Double(paper.width), height: height)
        } else {
            area = caps.platen?.maxSizeInches ?? EsclCapabilities.defaultAreaInches
        }
        let region: EsclRegion = makeRegion(area, minimum: input?.minSizeInches, selection: feeder ? nil : selection)

        var resolution: Int = dpi
        if let listed = input?.resolutions, !listed.isEmpty {
            // The first of the nearest ones (the list is ascending), as C#'s MinBy picks it.
            var best: Int = listed[0]
            for candidate in listed where abs(candidate - dpi) < abs(best - dpi) {
                best = candidate
            }
            resolution = best
        }

        let colorPreference: [String] = colorMode == .color ? ["RGB24"] : ["Grayscale8", "RGB24"]
        let formatPreference: [String] = ["image/jpeg", "image/png", "image/tiff"]

        return EsclScanRequest(inputSource: feeder ? "Feeder" : "Platen",
                               colorMode: pick(colorPreference, offered: input?.colorModes, ignoringCase: false),
                               documentFormat: pick(formatPreference, offered: input?.documentFormats, ignoringCase: true),
                               resolution: resolution,
                               region: region,
                               duplex: twoSided)
    }

    /// The first preferred value the device offers; the first preference when it lists nothing usable.
    private static func pick(_ preference: [String], offered: [String]?, ignoringCase: Bool) -> String {
        guard let offered = offered, !offered.isEmpty else { return preference[0] }
        for wanted in preference {
            for value in offered {
                let same: Bool = ignoringCase ? value.uppercased() == wanted.uppercased() : value == wanted
                if same {
                    return wanted
                }
            }
        }
        return preference[0]
    }

    private static func makeRegion(_ area: CGSize, minimum: CGSize?, selection: CGRect?) -> EsclRegion {
        let fullWidth: Int = Swift.max(1, roundToInt(Double(area.width) * 300))
        let fullHeight: Int = Swift.max(1, roundToInt(Double(area.height) * 300))
        let whole: EsclRegion = EsclRegion(xOffset: 0, yOffset: 0, width: fullWidth, height: fullHeight)
        guard let selected = selection else { return whole }

        let clamped: CGRect = selected.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if clamped.isNull || Double(clamped.width) <= 0.001 || Double(clamped.height) <= 0.001 {
            return whole
        }

        // Devices state the minimum in whole 1/300 inch units, so rounding recovers it exactly.
        var minWidth: Int = 1
        var minHeight: Int = 1
        if let smallest = minimum {
            minWidth = roundToInt(Double(smallest.width) * 300)
            minHeight = roundToInt(Double(smallest.height) * 300)
        }
        let x: Span = span(start: Double(clamped.minX), length: Double(clamped.width), full: fullWidth, minimum: minWidth)
        let y: Span = span(start: Double(clamped.minY), length: Double(clamped.height), full: fullHeight, minimum: minHeight)
        return EsclRegion(xOffset: x.offset, yOffset: y.offset, width: x.length, height: y.length)
    }

    /// One axis of a region.
    private struct Span {
        let offset: Int
        let length: Int
    }

    /// One axis of a selection in 1/300 inch: never past the far edge (rounding could otherwise
    /// overshoot the device maximum by one unit) and never under the device minimum.
    private static func span(start: Double, length: Double, full: Int, minimum: Int) -> Span {
        var offset: Int = Swift.min(Swift.max(roundToInt(start * Double(full)), 0), full - 1)
        var size: Int = Swift.max(1, roundToInt(length * Double(full)))
        size = Swift.min(size, full - offset)
        let floor: Int = Swift.min(Swift.max(1, minimum), full)
        if size < floor {
            size = floor
            offset = Swift.min(offset, full - size)
        }
        return Span(offset: offset, length: size)
    }

    /// C#'s `(int)Math.Round(value)`: halves go to the even neighbour.
    private static func roundToInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded: Double = value.rounded(.toNearestOrEven)
        if rounded >= Double(Int32.max) {
            return Int(Int32.max)
        }
        if rounded <= Double(Int32.min) {
            return Int(Int32.min)
        }
        return Int(rounded)
    }

    /// The eSCL ScanSettings document for this job (UTF-8 text, "\n" line breaks).
    public func toXml() -> String {
        var xml: String = ""
        func line(_ text: String) {
            xml += text
            xml += "\n"
        }
        line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        line("<scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\">")
        line("  <pwg:Version>2.0</pwg:Version>")
        line("  <pwg:ScanRegions>")
        line("    <pwg:ScanRegion>")
        line("      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>")
        line("      <pwg:XOffset>" + String(region.xOffset) + "</pwg:XOffset>")
        line("      <pwg:YOffset>" + String(region.yOffset) + "</pwg:YOffset>")
        line("      <pwg:Width>" + String(region.width) + "</pwg:Width>")
        line("      <pwg:Height>" + String(region.height) + "</pwg:Height>")
        line("    </pwg:ScanRegion>")
        line("  </pwg:ScanRegions>")
        line("  <pwg:InputSource>" + inputSource + "</pwg:InputSource>")
        line("  <scan:ColorMode>" + EsclScanRequest.escape(colorMode) + "</scan:ColorMode>")
        line("  <scan:XResolution>" + String(resolution) + "</scan:XResolution>")
        line("  <scan:YResolution>" + String(resolution) + "</scan:YResolution>")
        // After the resolutions, where sane-airscan writes it; left out for one-sided jobs.
        if duplex {
            line("  <scan:Duplex>true</scan:Duplex>")
        }
        line("  <pwg:DocumentFormat>" + EsclScanRequest.escape(documentFormat) + "</pwg:DocumentFormat>")
        line("</scan:ScanSettings>")
        return xml
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Addresses of an eSCL scan job.
public enum EsclJob {
    /// The job's address from the Location header of the ScanJobs response. Devices send an absolute
    /// URL, a host-relative path ("/eSCL/ScanJobs/12") or a path relative to the ScanJobs URL
    /// ("ScanJobs/12"); a trailing slash is dropped so "/NextDocument" can be appended. nil when the
    /// header is missing or unusable.
    public static func resolveLocation(_ scanJobs: URL, _ location: String?) -> URL? {
        let value: String = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        var resolved: URL?
        if value.hasPrefix("/") && !value.hasPrefix("//") {
            // Host-relative: the ScanJobs URL's scheme and authority, then the path.
            guard let prefix = origin(of: scanJobs.absoluteString) else { return nil }
            resolved = URL(string: prefix + value)
        } else if value.contains("://"), let absolute = URL(string: value),
                  let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            resolved = absolute
        } else {
            resolved = URL(string: value, relativeTo: scanJobs)?.absoluteURL
        }
        guard let url = resolved else { return nil }
        var text: String = url.absoluteString
        if !text.hasSuffix("/") {
            return url
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if let root = origin(of: text), root == text {
            text += "/"   // the root of the host keeps its slash
        }
        return URL(string: text)
    }

    /// The URL that delivers the job's next page.
    public static func nextDocument(_ job: URL) -> URL {
        var text: String = job.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return URL(string: text + "/NextDocument") ?? job.appendingPathComponent("NextDocument")
    }

    /// "http://host:port" of a URL's text: everything before its path, query or fragment.
    private static func origin(of text: String) -> String? {
        guard let separator = text.range(of: "://") else { return nil }
        let rest: Substring = text[separator.upperBound...]
        var end: String.Index = text.endIndex
        if let index = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            end = index
        }
        return String(text[..<end])
    }
}
