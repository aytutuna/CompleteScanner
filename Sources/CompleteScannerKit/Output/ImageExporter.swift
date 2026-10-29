import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExporter {
    /// Write jpeg/png/tiff with DPI metadata. Throws ScanError.unsupported for .pdf, .text and .word.
    /// A black & white page (`colorMode`, the mode it was scanned in) saved as TIFF is a 1-bit CCITT
    /// G4 file (`BilevelTIFF`); everything else is written by ImageIO, TIFFs as LZW. Twin of C#
    /// `WpfImageCodec.SaveAsNew`'s choice.
    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, dpi: Int, jpegQuality: Double,
                             colorMode: ColorMode = .color) throws {
        let utType: UTType
        switch format {
        case .jpeg: utType = .jpeg
        case .png: utType = .png
        case .tiff: utType = .tiff
        case .pdf: throw ScanError.unsupported("Use PDFBuilder to write PDF files.")
        case .text, .word: throw ScanError.unsupported("Use TextExport or DocxWriter to write text.")
        }

        if BilevelTIFF.applies(format, colorMode) {
            guard let pixels = RgbaImage(cgImage: image) else {
                throw ScanError.exportFailed("Could not read the page to write \(url.lastPathComponent).")
            }
            do {
                try BilevelTIFF.make(pixels, dpi: dpi).write(to: url, options: .atomic)
            } catch {
                throw ScanError.exportFailed("Could not write \(url.lastPathComponent).")
            }
            return
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
        case .png, .pdf, .text, .word:
            break
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScanError.exportFailed("Could not write \(url.lastPathComponent).")
        }
    }
}
