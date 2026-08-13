import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExporter {
    /// Write jpeg/png/tiff with DPI metadata. Throws ScanError.unsupported for .pdf.
    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, dpi: Int, jpegQuality: Double) throws {
        let utType: UTType
        switch format {
        case .jpeg: utType = .jpeg
        case .png: utType = .png
        case .tiff: utType = .tiff
        case .pdf: throw ScanError.unsupported("Use PDFBuilder to write PDF files.")
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                utType.identifier as CFString,
                                                                1, nil) else {
            throw ScanError.exportFailed("Could not create \(format.label) file at \(url.path).")
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        switch format {
        case .jpeg:
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        case .tiff:
            // 5 = LZW compression.
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        case .png, .pdf:
            break
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScanError.exportFailed("Could not write \(url.lastPathComponent).")
        }
    }
}
