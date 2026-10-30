import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Twin of windows/LazyScan.Core/PdfImageEncoding.cs: the same table, the same rules and
// the same rounding. The Apple part (`encodedPage`, `encodeJPEG`) has no C# counterpart: Windows
// encodes with WIC in the app (black & white pages as CCITT G4), here ImageIO encodes the JPEG, and
// both embed the image through the same PDF writer (`PDFWriter`, here through
// `PDFBuilder.storedImage`), black & white pages as CCITT G4. `encodedPage` still gives a page
// planned as G4 as a gray JPEG, planned as a gray page is, for a caller that cannot store G4 (see
// CONTRACTS.md, "CCITT G4 for black & white pages").

/// How a page image is stored in the PDF.
public enum PDFImageKind: Equatable, Sendable {
    /// A three-component (RGB) JPEG.
    case jpegColor
    /// A one-component JPEG (DeviceGray).
    case jpegGray
    /// A 1-bit black & white image in CCITT G4 (DeviceGray, CCITTFaxDecode), on both platforms (the
    /// Mac through `PDFWriter`; `encodedPage` gives such a page as a gray JPEG).
    case bilevelG4
}

/// What one PDF size does.
public struct PDFSizeProfile: Equatable, Sendable {
    /// Pages scanned finer than this (with `PDFImageEncoding.downsampleSlack`) are downsampled
    /// to it; nil keeps the scan resolution.
    public let maxDPI: Int?
    /// JPEG quality for color pages.
    public let colorQuality: Double
    /// JPEG quality for gray and black & white pages.
    public let grayQuality: Double
    /// Pages scanned in color that have no color are stored as gray.
    public let autoGray: Bool
    /// The limit for black & white pages, stored as CCITT G4 (with the same slack); nil keeps the
    /// scan resolution. 1-bit pages need more pixels than gray ones to keep text smooth, and cost
    /// far fewer bytes per pixel.
    public let bilevelMaxDPI: Int?

    public init(maxDPI: Int?, colorQuality: Double, grayQuality: Double, autoGray: Bool,
                bilevelMaxDPI: Int? = nil) {
        self.maxDPI = maxDPI
        self.colorQuality = colorQuality
        self.grayQuality = grayQuality
        self.autoGray = autoGray
        self.bilevelMaxDPI = bilevelMaxDPI
    }
}

/// How to store one page image.
public struct PDFImagePlan: Equatable, Sendable {
    /// The resolution of the stored image (the page's own when it is not downsampled).
    public let targetDPI: Int
    public let kind: PDFImageKind
    /// JPEG quality, 0...1. For a G4 page, which is lossless, the size's gray quality: what a
    /// writer without G4 would use for the page as a gray JPEG.
    public let quality: Double

    public init(targetDPI: Int, kind: PDFImageKind, quality: Double) {
        self.targetDPI = targetDPI
        self.kind = kind
        self.quality = quality
    }

    /// The stored image has one gray component: a gray JPEG or a G4 page.
    public var isGray: Bool { kind != .jpegColor }

    /// The page is stored black & white, as CCITT G4.
    public var isBilevel: Bool { kind == .bilevelG4 }
}

/// Size and component count (1 = gray, 3 = color) from a JPEG's frame header.
public struct JPEGHeader: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let components: Int
}

/// A page image ready for the PDF: the JPEG and an image backed by it.
public struct PDFPageImage {
    public let plan: PDFImagePlan
    public let jpegData: Data
    /// Created from `jpegData` (`CGImage(jpegDataProviderSource:...)`): the JPEG-backed image, for
    /// callers that draw the stored pixels. `PDFBuilder` embeds `jpegData` itself.
    public let image: CGImage
}

/// The size presets of saved PDFs and the per-page plan they lead to: downsampling, gray
/// storage and JPEG quality. The page size in the PDF never changes; only the stored image gets
/// fewer pixels. Black & white pages are planned as CCITT G4 at every size.
public enum PDFImageEncoding {
    /// A page is downsampled only when it is finer than this many times the size's limit.
    public static let downsampleSlack = 1.1

    /// The size table. The size alone sets the JPEG quality of PDF pages; the JPEG quality
    /// setting is for JPEG files. Best stores what Windows PDFs held before sizes existed: the
    /// scan resolution at quality 0.9. Black & white pages keep up to 600 dpi at Standard and 300
    /// dpi at Compact and Smallest.
    public static func profile(_ size: PDFSizePreset) -> PDFSizeProfile {
        switch size {
        case .best:
            return PDFSizeProfile(maxDPI: nil, colorQuality: 0.90, grayQuality: 0.90, autoGray: false,
                                  bilevelMaxDPI: nil)
        case .standard:
            return PDFSizeProfile(maxDPI: 300, colorQuality: 0.80, grayQuality: 0.80, autoGray: true,
                                  bilevelMaxDPI: 600)
        case .compact:
            return PDFSizeProfile(maxDPI: 200, colorQuality: 0.65, grayQuality: 0.70, autoGray: true,
                                  bilevelMaxDPI: 300)
        case .smallest:
            return PDFSizeProfile(maxDPI: 150, colorQuality: 0.50, grayQuality: 0.55, autoGray: true,
                                  bilevelMaxDPI: 300)
        }
    }

    /// How to store a page. `imageDPI` is the resolution of the pixels at hand (see
    /// `effectiveDPI`); `mode` is the page's own color mode; `looksGray` says whether a color
    /// page has no color (`ColorAnalysis.isEffectivelyGray`), and only counts for sizes with
    /// `autoGray`. Black & white pages are G4 up to the size's `bilevelMaxDPI`.
    public static func plan(mode: ColorMode, imageDPI: Int, size: PDFSizePreset,
                            looksGray: Bool) -> PDFImagePlan {
        let sizeProfile = PDFImageEncoding.profile(size)
        let dpi = max(imageDPI, 1)
        if mode == .blackWhite {
            var bilevel = dpi
            if let limit = sizeProfile.bilevelMaxDPI, Double(dpi) > downsampleSlack * Double(limit) {
                bilevel = limit
            }
            return PDFImagePlan(targetDPI: bilevel, kind: .bilevelG4, quality: sizeProfile.grayQuality)
        }
        var target = dpi
        if let maxDPI = sizeProfile.maxDPI, Double(dpi) > downsampleSlack * Double(maxDPI) {
            target = maxDPI
        }
        let gray = mode != .color || (sizeProfile.autoGray && looksGray)
        let quality = gray ? sizeProfile.grayQuality : sizeProfile.colorQuality
        return PDFImagePlan(targetDPI: target, kind: gray ? .jpegGray : .jpegColor, quality: quality)
    }

    /// `plan(mode:imageDPI:size:looksGray:)` for a page image; the color check runs only for
    /// color pages with a size that stores gray pages as gray.
    public static func plan(mode: ColorMode, imageDPI: Int, size: PDFSizePreset,
                            image: CGImage) -> PDFImagePlan {
        let looksGray = mode == .color && PDFImageEncoding.profile(size).autoGray
            && ColorAnalysis.isEffectivelyGray(image)
        return PDFImageEncoding.plan(mode: mode, imageDPI: imageDPI, size: size, looksGray: looksGray)
    }

    /// The resolution of the pixels at hand: the page's own, or less when only a preview of the
    /// page is left (its spool file is missing).
    public static func effectiveDPI(imageWidth: Int, pagePixelWidth: Int, pageDPI: Int) -> Int {
        if pagePixelWidth <= 0 || imageWidth == pagePixelWidth { return pageDPI }
        return max(1, Int((Double(pageDPI) * Double(imageWidth) / Double(pagePixelWidth)).rounded()))
    }

    /// The pixel size of an image of `width` × `height` at `imageDPI` stored at `targetDPI`.
    public static func targetSize(width: Int, height: Int, imageDPI: Int, targetDPI: Int) -> (width: Int, height: Int) {
        if targetDPI >= imageDPI || imageDPI <= 0 { return (width, height) }
        let scale = Double(targetDPI) / Double(imageDPI)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// Box-filter minification of an RGBA8 buffer: each destination pixel is the mean of the
    /// source pixels it covers. A port of the minifying branch of C# `RgbaImage.Resized`, so both
    /// platforms store the same pixels. `newWidth`/`newHeight` must not exceed the source size.
    public static func downsample(rgba: [UInt8], width: Int, height: Int,
                                  newWidth: Int, newHeight: Int) -> [UInt8] {
        if newWidth == width && newHeight == height { return rgba }
        var output = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let xRatio = Double(width) / Double(newWidth)
        let yRatio = Double(height) / Double(newHeight)
        for dy in 0..<newHeight {
            let sy0 = Int(Double(dy) * yRatio)
            let sy1 = max(sy0 + 1, min(height, Int((Double(dy + 1) * yRatio).rounded(.up))))
            for dx in 0..<newWidth {
                let sx0 = Int(Double(dx) * xRatio)
                let sx1 = max(sx0 + 1, min(width, Int((Double(dx + 1) * xRatio).rounded(.up))))
                var r = 0, g = 0, b = 0, a = 0, count = 0
                for sy in sy0..<sy1 {
                    var i = (sy * width + sx0) * 4
                    for _ in sx0..<sx1 {
                        r += Int(rgba[i])
                        g += Int(rgba[i + 1])
                        b += Int(rgba[i + 2])
                        a += Int(rgba[i + 3])
                        i += 4
                        count += 1
                    }
                }
                let o = (dy * newWidth + dx) * 4
                output[o] = UInt8(r / count)
                output[o + 1] = UInt8(g / count)
                output[o + 2] = UInt8(b / count)
                output[o + 3] = UInt8(a / count)
            }
        }
        return output
    }

    // MARK: - Mac page encoding

    /// The page as it goes into the PDF: planned (`plan(mode:...:image:)`), downsampled with the
    /// box filter, converted to gray when planned, JPEG-encoded at the planned quality and
    /// turned back into a JPEG-backed image. The pixels are read once. Nil when the image
    /// cannot be read or encoded. A page planned as G4 (black & white), which a JPEG cannot carry, is
    /// given as a gray JPEG, planned as a gray page is; the returned plan is that gray plan.
    /// `PDFBuilder` never stores such a page this way: it stores it as G4 (`PDFBuilder.storedImage`).
    public static func encodedPage(_ image: CGImage, imageDPI: Int, mode: ColorMode,
                                   size: PDFSizePreset) -> PDFPageImage? {
        guard var rgba = ColorAnalysis.rgbaPixels(of: image) else { return nil }
        var width = image.width
        var height = image.height
        let looksGray = mode == .color && PDFImageEncoding.profile(size).autoGray
            && ColorAnalysis.isEffectivelyGray(rgba: rgba, width: width, height: height)
        var pagePlan = PDFImageEncoding.plan(mode: mode, imageDPI: imageDPI, size: size, looksGray: looksGray)
        if pagePlan.isBilevel {
            pagePlan = PDFImageEncoding.plan(mode: .grayscale, imageDPI: imageDPI, size: size, looksGray: true)
        }
        let target = targetSize(width: width, height: height, imageDPI: imageDPI, targetDPI: pagePlan.targetDPI)
        if target.width != width || target.height != height {
            rgba = downsample(rgba: rgba, width: width, height: height, newWidth: target.width, newHeight: target.height)
            width = target.width
            height = target.height
        }
        let bitmap = pagePlan.isGray
            ? grayImage(ColorAnalysis.grayPixels(rgba: rgba, width: width, height: height), width: width, height: height)
            : rgbImage(rgba, width: width, height: height)
        guard let bitmap, let jpeg = encodeJPEG(bitmap, quality: pagePlan.quality),
              let provider = CGDataProvider(data: jpeg as CFData),
              let backed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else {
            return nil
        }
        return PDFPageImage(plan: pagePlan, jpegData: jpeg, image: backed)
    }

    /// JPEG bytes of `image` at `quality` (ImageIO). A gray image gives a one-component JPEG.
    public static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Frame size and component count from a JPEG's start-of-frame segment (any SOFn). Walks
    /// the marker segments from SOI by their length fields, so APPn payloads that contain
    /// marker-like bytes are skipped, and gives up at SOS/EOI or on a malformed or truncated
    /// segment. Twin of C# `PdfBuilder.TryReadJpegHeader`.
    public static func readJPEGHeader(_ data: Data) -> JPEGHeader? {
        let jpeg = [UInt8](data)
        guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return nil }
        var pos = 2
        while pos < jpeg.count {
            guard jpeg[pos] == 0xFF else { return nil }
            // Any number of 0xFF fill bytes may precede a marker code.
            while pos < jpeg.count && jpeg[pos] == 0xFF { pos += 1 }
            guard pos < jpeg.count else { return nil }
            let marker = jpeg[pos]
            pos += 1

            // Standalone markers carry no length: TEM, RSTn, SOI.
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8) { continue }
            // Scan data or the end of the image before any frame header.
            if marker == 0xDA || marker == 0xD9 || marker == 0x00 { return nil }

            guard pos + 2 <= jpeg.count else { return nil }
            let length = (Int(jpeg[pos]) << 8) | Int(jpeg[pos + 1])
            guard length >= 2, pos + length <= jpeg.count else { return nil }

            // SOF0...SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
            let isFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrame {
                // Length(2) precision(1) height(2) width(2) components(1) ...
                guard length >= 8 else { return nil }
                let height = (Int(jpeg[pos + 3]) << 8) | Int(jpeg[pos + 4])
                let width = (Int(jpeg[pos + 5]) << 8) | Int(jpeg[pos + 6])
                let components = Int(jpeg[pos + 7])
                // Height 0 means "defined later by DNL"; treat it as unknown.
                guard width > 0, height > 0, components > 0 else { return nil }
                return JPEGHeader(width: width, height: height, components: components)
            }
            pos += length
        }
        return nil
    }

    private static func rgbImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // The pixels were drawn over white, so the fourth byte is padding.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func grayImage(_ gray: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
