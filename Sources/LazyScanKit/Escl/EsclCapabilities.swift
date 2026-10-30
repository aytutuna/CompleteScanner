import Foundation
import CoreGraphics

// Twin of windows/LazyScan.Core/Escl/EsclCapabilitiesParser.cs: the eSCL (AirScan) protocol
// logic both apps share, tested against the fixtures in Tests/Fixtures/Escl that the C# tests read
// too. Only Foundation: it builds for macOS and iOS.

/// A document from an eSCL scanner that could not be read, or an address that is not one: the twin
/// of the C# code's `FormatException`. `message` is written for the user.
public struct EsclFormatError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// What one eSCL input source (platen, feeder simplex, feeder duplex) offers.
public struct EsclInputCaps: Equatable, Sendable {
    /// Largest scan area in inches (MaxWidth × MaxHeight); nil when not reported.
    public var maxSizeInches: CGSize?
    /// Smallest scan area in inches (MinWidth × MinHeight); nil when not reported.
    public var minSizeInches: CGSize?
    /// Resolutions as the C# `ResolutionList.Build` lists them: ascending, no duplicates.
    public var resolutions: [Int]
    /// eSCL color modes as written by the device, e.g. "RGB24", "Grayscale8", "BlackAndWhite1".
    public var colorModes: [String]
    /// MIME types, e.g. "image/jpeg", "application/pdf".
    public var documentFormats: [String]

    public init(maxSizeInches: CGSize? = nil, minSizeInches: CGSize? = nil, resolutions: [Int] = [],
                colorModes: [String] = [], documentFormats: [String] = []) {
        self.maxSizeInches = maxSizeInches
        self.minSizeInches = minSizeInches
        self.resolutions = resolutions
        self.colorModes = colorModes
        self.documentFormats = documentFormats
    }
}

/// A parsed eSCL ScannerCapabilities document.
public struct EsclCapabilities: Equatable, Sendable {
    /// Scan area used when a device reports no platen size (US Letter width, A4 height).
    public static let defaultAreaInches = CGSize(width: 8.5, height: 11.7)
    /// Resolutions offered when a device lists none.
    public static let fallbackResolutions: [Int] = [75, 150, 200, 300, 600]

    public var version: String?
    public var makeAndModel: String?
    /// The device's UUID (scan:UUID), used to recognize it across addresses.
    public var uuid: String?
    public var platen: EsclInputCaps?
    public var adfSimplex: EsclInputCaps?
    public var adfDuplex: EsclInputCaps?
    /// The feeder scans both sides: AdfDuplexInputCaps, or "Duplex" among the AdfOptions.
    public var supportsDuplex: Bool

    public init(version: String? = nil, makeAndModel: String? = nil, uuid: String? = nil,
                platen: EsclInputCaps? = nil, adfSimplex: EsclInputCaps? = nil, adfDuplex: EsclInputCaps? = nil,
                supportsDuplex: Bool = false) {
        self.version = version
        self.makeAndModel = makeAndModel
        self.uuid = uuid
        self.platen = platen
        self.adfSimplex = adfSimplex
        self.adfDuplex = adfDuplex
        self.supportsDuplex = supportsDuplex
    }

    public var hasPlaten: Bool { platen != nil }
    public var hasAdf: Bool { feeder != nil }
    /// The feeder's one-sided capabilities (or the two-sided ones when that is all it lists).
    public var feeder: EsclInputCaps? { adfSimplex ?? adfDuplex }

    /// The input capabilities a scan from `source` uses.
    public func inputCaps(_ source: ScanSource) -> EsclInputCaps? {
        source == .documentFeeder ? feeder : platen
    }

    /// The backend-neutral capabilities. Sources are the inputs the device lists (a device listing
    /// neither is treated as a flatbed); the resolution list is the platen's, or the feeder's on a
    /// feeder-only device; the overview needs a platen.
    public func toScannerCapabilities() -> ScannerCapabilities {
        let flatbed: Bool = hasPlaten || !hasAdf
        var sources: [ScanSource] = []
        if flatbed {
            sources.append(.flatbed)
        }
        if hasAdf {
            sources.append(.documentFeeder)
        }
        let primary: EsclInputCaps? = platen ?? feeder
        var resolutions: [Int] = EsclCapabilities.fallbackResolutions
        if let listed = primary?.resolutions, !listed.isEmpty {
            resolutions = listed
        }
        let flatbedSize: CGSize = platen?.maxSizeInches ?? EsclCapabilities.defaultAreaInches
        return ScannerCapabilities(supportedResolutions: resolutions,
                                   sources: sources,
                                   flatbedSizeInches: flatbedSize,
                                   supportsOverview: flatbed,
                                   feederSizeInches: feeder?.maxSizeInches,
                                   supportsDuplex: supportsDuplex)
    }
}

public enum EsclCapabilitiesParser {
    /// Parses a ScannerCapabilities document. Elements are matched by local name, so the namespace
    /// prefixes devices use do not matter. Throws `EsclFormatError` when the text is not XML.
    public static func parse(_ xml: String) throws -> EsclCapabilities {
        try parse(data: Data(xml.utf8))
    }

    /// Same as `parse(_:)` for the document's bytes as the scanner sent them.
    public static func parse(data: Data) throws -> EsclCapabilities {
        var problem: String = ""
        guard let root = EsclXml.parse(data, error: &problem) else {
            throw EsclFormatError("The scanner capabilities are not valid XML: \(problem)")
        }

        var platen: EsclInputCaps?
        if let platenElement = root.child("Platen") {
            platen = parseInputCaps(platenElement.child("PlatenInputCaps") ?? platenElement)
        }

        var simplex: EsclInputCaps?
        var duplex: EsclInputCaps?
        var duplexOption = false
        if let adf = root.child("Adf") {
            if let element = adf.child("AdfSimplexInputCaps") {
                simplex = parseInputCaps(element)
            }
            if let element = adf.child("AdfDuplexInputCaps") {
                duplex = parseInputCaps(element)
            }
            // An Adf section without input caps still means there is a feeder.
            if simplex == nil && duplex == nil {
                simplex = parseInputCaps(adf)
            }
            for option in adf.descendants("AdfOption") {
                if option.value.trimmingCharacters(in: .whitespacesAndNewlines) == "Duplex" {
                    duplexOption = true
                }
            }
        }

        return EsclCapabilities(version: root.child("Version")?.text,
                                makeAndModel: root.child("MakeAndModel")?.text,
                                uuid: root.child("UUID")?.text,
                                platen: platen,
                                adfSimplex: simplex,
                                adfDuplex: duplex,
                                supportsDuplex: duplex != nil || duplexOption)
    }

    private static func parseInputCaps(_ caps: EsclXmlElement) -> EsclInputCaps {
        // Resolutions arrive as discrete values and/or min/max/step ranges, and are listed by the same
        // accuracy rules as the C# `ResolutionList`. Only square resolutions are offered, since
        // requests always use the same X and Y resolution.
        var supported: [Int] = []
        for resolution in caps.descendants("DiscreteResolution") {
            let x: Int? = int(resolution.child("XResolution"))
            let y: Int? = int(resolution.child("YResolution"))
            if let dpi = x, y == nil || y == dpi {
                supported.append(dpi)
            }
        }
        for range in caps.descendants("XResolutionRange") {
            guard let low = int(range.child("Min")), let high = int(range.child("Max")), low > 0, high >= low else {
                continue
            }
            let step: Int = int(range.child("Step")) ?? 1
            supported.append(contentsOf: EsclResolutions.expandRange(min: low, max: high, step: step))
        }

        var colorModes: [String] = []
        for element in caps.descendants("ColorMode") {
            let value: String = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !colorModes.contains(value) {
                colorModes.append(value)
            }
        }
        // eSCL 2.1+ lists DocumentFormatExt next to the older DocumentFormat.
        var formats: [String] = []
        var seenFormats: Set<String> = []
        let formatElements: [EsclXmlElement] = caps.descendants("DocumentFormat") + caps.descendants("DocumentFormatExt")
        for element in formatElements {
            let value: String = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String = value.uppercased()
            if !value.isEmpty && !seenFormats.contains(key) {
                seenFormats.insert(key)
                formats.append(value)
            }
        }

        return EsclInputCaps(maxSizeInches: size(caps.child("MaxWidth"), caps.child("MaxHeight")),
                             minSizeInches: size(caps.child("MinWidth"), caps.child("MinHeight")),
                             resolutions: EsclResolutions.build(supported),
                             colorModes: colorModes,
                             documentFormats: formats)
    }

    /// Dimensions arrive in 1/300ths of an inch.
    private static func size(_ width: EsclXmlElement?, _ height: EsclXmlElement?) -> CGSize? {
        guard let w = double(width), let h = double(height), w > 0, h > 0 else { return nil }
        return CGSize(width: w / 300.0, height: h / 300.0)
    }

    /// A whole number in the range of a C# `int`, with an optional sign; nil otherwise.
    private static func int(_ element: EsclXmlElement?) -> Int? {
        guard let element = element else { return nil }
        let text: String = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(text) else { return nil }
        return Int(value)
    }

    /// A decimal number (sign, digits, point, exponent); nil otherwise.
    private static func double(_ element: EsclXmlElement?) -> Double? {
        guard let element = element else { return nil }
        let text: String = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", ".", "e", "E"]
        guard !text.isEmpty else { return nil }
        for character in text where !allowed.contains(character) {
            return nil
        }
        return Double(text)
    }
}

/// The resolution rules of the C# `ResolutionList` that eSCL uses (`Build` without a preferred list
/// or an optical resolution, and `ExpandRange`).
enum EsclResolutions {
    /// Standard ladder used to thin a huge contiguous range.
    static let standardLadder: [Int] = [50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800,
                                        1200, 1600, 2400, 3200, 4800, 6400, 9600, 12800]

    /// Upper bound for `expandRange`, as C# `ResolutionList.MaxRangeDpi`.
    static let maxRangeDpi = 100_000

    /// The positive values of `supported`, ascending, without duplicates: all of them when there are
    /// at most 64 (a discrete list), otherwise the standard ladder values among them plus the smallest
    /// and the largest (a huge contiguous range).
    static func build(_ supported: [Int]) -> [Int] {
        var set: Set<Int> = []
        for dpi in supported where dpi > 0 {
            set.insert(dpi)
        }
        if set.isEmpty {
            return []
        }
        if set.count <= 64 {
            return set.sorted()
        }
        var thinned: Set<Int> = []
        for dpi in standardLadder where set.contains(dpi) {
            thinned.insert(dpi)
        }
        if let lowest = set.min() {
            thinned.insert(lowest)
        }
        if let highest = set.max() {
            thinned.insert(highest)
        }
        return thinned.sorted()
    }

    /// The values of a min/max/step range. A non-positive step means 1; values on the range's lattice
    /// that are not positive or above `maxRangeDpi` are skipped.
    static func expandRange(min low: Int, max high: Int, step: Int) -> [Int] {
        let increment: Int = step <= 0 ? 1 : step
        var first: Int = low
        if first <= 0 {
            first += ((1 - first) + increment - 1) / increment * increment   // the first positive lattice value
        }
        let last: Int = Swift.min(high, maxRangeDpi)
        var values: [Int] = []
        var dpi: Int = first
        while dpi <= last {
            values.append(dpi)
            dpi += increment
        }
        return values
    }
}
