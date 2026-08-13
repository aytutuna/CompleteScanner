import Foundation
import CoreGraphics

// MARK: - Core enums

public enum ScanIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case document
    case photo

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .document: return "Document"
        case .photo: return "Photos"
        }
    }
}

public enum ColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case color
    case grayscale
    case blackWhite

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .color: return "Color"
        case .grayscale: return "Grayscale"
        case .blackWhite: return "Black & White"
        }
    }
}

public enum ScanSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case flatbed
    case documentFeeder

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .flatbed: return "Flatbed"
        case .documentFeeder: return "Document Feeder (ADF)"
        }
    }
}

public enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf, jpeg, png, tiff

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }
    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }
}

// MARK: - Settings

public struct AdjustmentSettings: Codable, Equatable, Sendable {
    public var autoEnhance: Bool = false
    /// -1 ... 1, neutral 0
    public var brightness: Double = 0.0
    /// 0.25 ... 4, neutral 1
    public var contrast: Double = 1.0
    /// 0 ... 2, neutral 1
    public var saturation: Double = 1.0
    /// 0 ... 2, neutral 0
    public var sharpness: Double = 0.0
    /// Reduce moiré from scanning printed material.
    public var descreen: Bool = false
    /// Boost faded colors of old photos.
    public var restoreFadedColors: Bool = false
    /// 0 ... 1 luminance threshold used for ColorMode.blackWhite conversion.
    public var blackWhiteThreshold: Double = 0.5

    public init() {}

    public var isIdentity: Bool {
        !autoEnhance && brightness == 0 && contrast == 1 && saturation == 1
            && sharpness == 0 && !descreen && !restoreFadedColors
    }
}

public struct ScanSettings: Codable, Equatable, Sendable {
    public var intent: ScanIntent = .document
    public var source: ScanSource = .flatbed
    public var resolution: Int = 300
    public var colorMode: ColorMode = .color
    public var format: OutputFormat = .pdf
    /// 0 ... 1
    public var jpegQuality: Double = 0.9
    public var destinationPath: String = ScanSettings.defaultDestinationPath
    public var namingTemplate: String = "Scan {date} {counter}"

    // Photo mode
    public var photoAutoSplit: Bool = true
    public var photoAutoDeskew: Bool = true
    /// Smallest photo side considered a real photo (inches).
    public var photoMinSideInches: Double = 1.2
    /// Pixels (at scan resolution) shaved off each detected photo edge to remove background slivers.
    public var photoCropInsetPixels: Int = 0

    // Document / PDF mode
    /// true: scans accumulate as pages and are saved together with "Save PDF".
    /// false: every scan is written to disk immediately as its own file.
    public var documentMultiPage: Bool = true
    /// Run OCR and embed an invisible text layer in saved PDFs.
    public var pdfSearchable: Bool = true
    public var ocrLanguages: [String] = ["en-US"]

    public var adjustments: AdjustmentSettings = AdjustmentSettings()

    public init() {}

    public static var defaultDestinationPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/CompleteScanner")
    }
}

// MARK: - Runtime objects

public struct ScannedPage: Identifiable {
    public let id: UUID
    /// Page pixels. When `fileURL` is set this is a lower-resolution preview;
    /// the full-resolution original lives in the file.
    public let image: CGImage
    public let dpi: Int
    public let colorMode: ColorMode
    public let createdAt: Date
    /// Full-resolution spill file (TIFF) backing this page when it was offloaded
    /// from memory. Consumers that need full pixels (PDFBuilder) reload from it.
    public let fileURL: URL?
    /// Pixel dimensions of the full-resolution original (recorded when the page
    /// is spooled), so physical page size stays correct even if only the preview
    /// is available.
    public let fullPixelSize: CGSize?

    public init(image: CGImage, dpi: Int, colorMode: ColorMode, id: UUID = UUID(),
                createdAt: Date = Date(), fileURL: URL? = nil, fullPixelSize: CGSize? = nil) {
        self.id = id
        self.image = image
        self.dpi = dpi
        self.colorMode = colorMode
        self.createdAt = createdAt
        self.fileURL = fileURL
        self.fullPixelSize = fullPixelSize
    }
}

/// A rotated rectangle found on a scanned flatbed image.
///
/// Coordinate convention: source-image pixels, origin at TOP-LEFT, x right, y down.
/// `angleDegrees` is the rotation of the rectangle; a positive angle appears as a
/// CLOCKWISE rotation on screen. Normalized to (-45, 45]. A point (x, y) in the
/// rectangle's local frame maps to the image as:
///   ix = center.x + x*cos(a) - y*sin(a)
///   iy = center.y + x*sin(a) + y*cos(a)
public struct DetectedPhotoRegion: Identifiable, Equatable {
    public let id: UUID
    public var center: CGPoint
    public var size: CGSize
    public var angleDegrees: Double

    public init(center: CGPoint, size: CGSize, angleDegrees: Double, id: UUID = UUID()) {
        self.id = id
        self.center = center
        self.size = size
        self.angleDegrees = angleDegrees
    }

    /// Corners in source-image pixel coordinates (top-left origin), order: TL, TR, BR, BL of the local frame.
    public var corners: [CGPoint] {
        let a = angleDegrees * .pi / 180
        let (c, s) = (cos(a), sin(a))
        let (hw, hh) = (size.width / 2, size.height / 2)
        return [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)].map {
            CGPoint(x: center.x + $0.x * c - $0.y * s, y: center.y + $0.x * s + $0.y * c)
        }
    }

    /// Axis-aligned bounding box of `corners`.
    public var boundingBox: CGRect {
        let pts = corners
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

public struct DetectedPhoto: Identifiable {
    public let id: UUID
    public let region: DetectedPhotoRegion
    public let image: CGImage
    public let dpi: Int
    public var included: Bool = true
    /// Extra user-requested rotation applied at save time (0...3 quarter turns clockwise).
    public var rotationQuarterTurns: Int = 0

    public init(region: DetectedPhotoRegion, image: CGImage, dpi: Int, id: UUID = UUID()) {
        self.id = id
        self.region = region
        self.image = image
        self.dpi = dpi
    }
}

// MARK: - Devices

public struct ScannerInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// "USB", "Network", "Shared", "Demo", ...
    public let transport: String
    public let isDemo: Bool

    public init(id: String, name: String, transport: String, isDemo: Bool = false) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isDemo = isDemo
    }
}

public struct ScannerCapabilities: Equatable, Sendable {
    public var supportedResolutions: [Int]
    public var sources: [ScanSource]
    /// Physical flatbed size in inches.
    public var flatbedSizeInches: CGSize
    public var supportsOverview: Bool

    public init(supportedResolutions: [Int] = [75, 150, 200, 300, 600, 1200],
                sources: [ScanSource] = [.flatbed],
                flatbedSizeInches: CGSize = CGSize(width: 8.5, height: 11.7),
                supportsOverview: Bool = true) {
        self.supportedResolutions = supportedResolutions
        self.sources = sources
        self.flatbedSizeInches = flatbedSizeInches
        self.supportsOverview = supportsOverview
    }

    public func nearestResolution(to dpi: Int) -> Int {
        supportedResolutions.min(by: { abs($0 - dpi) < abs($1 - dpi) }) ?? dpi
    }
}

public struct ScanProgress: Equatable, Sendable {
    /// nil = indeterminate
    public var fraction: Double?
    public var message: String

    public init(fraction: Double? = nil, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

// MARK: - Presets

public struct Preset: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var settings: ScanSettings

    public init(id: UUID = UUID(), name: String, settings: ScanSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

// MARK: - Errors

public enum ScanError: LocalizedError {
    case deviceUnavailable(String)
    case sessionFailed(String)
    case scanFailed(String)
    case cancelled
    case exportFailed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let s): return "Scanner unavailable: \(s)"
        case .sessionFailed(let s): return "Could not open a session with the scanner: \(s)"
        case .scanFailed(let s): return "Scan failed: \(s)"
        case .cancelled: return "The scan was cancelled."
        case .exportFailed(let s): return "Saving failed: \(s)"
        case .unsupported(let s): return "Unsupported: \(s)"
        }
    }
}
