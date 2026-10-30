import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Reads barcodes and QR codes (`BarcodeSymbology.all`) on a page's gray copy with Vision's barcode
/// detection, which finds codes anywhere on the page, at a slant and of any size it can resolve. The
/// Mac counterpart of the Windows `ZXingBarcodeReader`; no library is needed.
public struct VisionBarcodeReader: BarcodeReader {
    public init() {}

    /// Vision's barcode detection is always there on macOS 14.
    public var isAvailable: Bool { true }

    /// The kinds read, in Vision's terms.
    static let kinds: [(VNBarcodeSymbology, BarcodeSymbology)] = [
        (.qr, .qrCode), (.code128, .code128), (.code39, .code39), (.dataMatrix, .dataMatrix),
    ]

    public func read(_ image: GrayImage) throws -> [BarcodeReading] {
        guard let cgImage = Self.makeCGImage(image) else {
            throw ScanError.scanFailed("Barcode reading failed: the page could not be prepared for reading.")
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = Self.kinds.map { $0.0 }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScanError.scanFailed("Barcode reading failed: \(error.localizedDescription)")
        }
        let width = Double(image.width)
        let height = Double(image.height)
        var found: [BarcodeReading] = []
        for observation in request.results ?? [] {
            guard let text = observation.payloadStringValue, !text.isEmpty,
                  let kind = Self.kinds.first(where: { $0.0 == observation.symbology })?.1 else { continue }
            // Vision's box is normalized with its origin at the bottom left (CONTRACTS.md, rule 4).
            let box = observation.boundingBox
            let bounds = CGRect(x: Double(box.minX) * width, y: (1 - Double(box.maxY)) * height,
                                width: Double(box.width) * width, height: Double(box.height) * height)
            found.append(BarcodeReading(symbology: kind, text: text, bounds: bounds))
        }
        return found
    }

    /// `image` as an 8-bit gray `CGImage`, row by row from the top.
    static func makeCGImage(_ image: GrayImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Makes the QR code of a QR separator sheet (`QrSeparatorSheet`) with Core Image's QR generator: the
/// text's UTF-8 bytes, error correction level M, one module per pixel; the code's modules are the box
/// around its dark pixels (the generator adds a quiet zone, which the sheet draws itself). The Mac
/// counterpart of the Windows `ZXingQrEncoder`; no library is needed.
public struct CoreImageQrEncoder: QrEncoder {
    public init() {}

    public func encode(_ text: String) -> QrModules? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(output, from: output.extent.integral),
              let gray = GrayImage(cgImage: cgImage, sourceDPI: 72, analysisDPI: 72) else { return nil }
        var minX = gray.width, minY = gray.height, maxX = -1, maxY = -1
        for y in 0..<gray.height {
            for x in 0..<gray.width where gray[x, y] < 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let size = maxX - minX + 1
        guard size == maxY - minY + 1, size >= 21, (size - 21) % 4 == 0 else { return nil }
        var dark: [Bool] = []
        dark.reserveCapacity(size * size)
        for y in minY...maxY {
            for x in minX...maxX {
                dark.append(gray[x, y] < 128)
            }
        }
        return QrModules(size: size, dark: dark)
    }
}
