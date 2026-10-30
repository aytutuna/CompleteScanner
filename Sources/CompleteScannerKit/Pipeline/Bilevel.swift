import Foundation

// Twin of windows/LazyScan.Core/Bilevel.cs: the same layout, threshold and rounding, so both
// platforms give CCITTG4Encoder the same bits (see CONTRACTS.md, "CCITT G4 for black & white pages").

/// Black & white pages as one bit per pixel, the form CCITT G4 (`CCITTG4Encoder`) encodes: rows top
/// to bottom, each starting on a byte boundary (`stride(_:)` bytes), pixels left to right from the
/// most significant bit, **0 = black, 1 = white** (a 1-bit /DeviceGray image with /BlackIs1 false).
/// The bits past the last pixel of a row are 1.
public enum Bilevel {
    /// A pixel whose luma (`ColorAnalysis.grayPixels`) is below this is black.
    public static let threshold = 128

    /// Bytes per packed row.
    public static func stride(_ width: Int) -> Int {
        (width + 7) / 8
    }

    /// The page as packed bits: luma (Rec. 601, rounded as in `ColorAnalysis.grayPixels`) below
    /// `threshold` is black. A page the black & white mode made (every pixel 0 or 255) keeps every
    /// pixel; a downsampled one is thresholded again.
    public static func pack(_ image: RgbaImage) -> [UInt8] {
        pack(rgba: image.pixels, width: image.width, height: image.height)
    }

    /// `pack(_:)` on a raw RGBA8 buffer (row-major, 4 bytes per pixel).
    public static func pack(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        precondition(width >= 0 && height >= 0, "The size must not be negative.")
        precondition(rgba.count >= width * height * 4,
                     "Pixel buffer must be \(width * height * 4) bytes, got \(rgba.count).")
        let rowBytes = stride(width)
        var packed = [UInt8](repeating: 0xFF, count: rowBytes * height)
        for y in 0..<height {
            let row = y * rowBytes
            var i = y * width * 4
            for x in 0..<width {
                // Integer luma (×1000), rounded half up: the weights grayPixels uses.
                let red = 299 * Int(rgba[i])
                let green = 587 * Int(rgba[i + 1])
                let blue = 114 * Int(rgba[i + 2])
                let luma = (red + green + blue + 500) / 1000
                if luma < threshold {
                    let mask = UInt8(0x80 >> (x & 7))
                    packed[row + (x >> 3)] &= ~mask
                }
                i += 4
            }
        }
        return packed
    }

    /// Whether pixel (`x`, `y`) of a packed image `width` pixels wide is black.
    public static func isBlack(_ packed: [UInt8], width: Int, x: Int, y: Int) -> Bool {
        let byte = packed[y * stride(width) + (x >> 3)]
        let mask = UInt8(0x80 >> (x & 7))
        return (byte & mask) == 0
    }

    /// A packed image as an opaque RGBA image: black (0, 0, 0) and white (255, 255, 255).
    /// `width` and `height` must be positive (an `RgbaImage` has pixels).
    public static func unpack(_ packed: [UInt8], width: Int, height: Int) -> RgbaImage {
        let rowBytes = stride(width)
        precondition(packed.count >= rowBytes * height,
                     "Packed buffer must be \(rowBytes * height) bytes, got \(packed.count).")
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var i = 0
        for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width {
                let mask = UInt8(0x80 >> (x & 7))
                if (packed[row + (x >> 3)] & mask) == 0 {
                    pixels[i] = 0
                    pixels[i + 1] = 0
                    pixels[i + 2] = 0
                }
                i += 4
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }
}
