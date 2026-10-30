#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit

// Photos read for import on the iPhone (`IOSPhotoDecoder`): every one of the eight EXIF orientations
// comes in the right way up, in lossless TIFF (pixel for pixel) and in JPEG (the camera's format); a
// large photo is decoded to the long side asked for; the focal length comes from EXIF; too large and
// unreadable files say why. The fixtures are made here with ImageIO: the upright picture is fixed, and
// each orientation's stored pixels are laid out by the EXIF definition of the tag (where row 0 and
// column 0 of the stored picture are seen), independently of the code under test.

/// The upright picture: `width` × `height`, four flat quadrants (red, green, blue, yellow from the top
/// left, clockwise) and a white mark near the top-left corner, so every turn and mirror is visible.
private func uprightPixels(width: Int, height: Int) -> RgbaImage {
    var pixels: [UInt8] = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let top: Bool = y < height / 2
            let left: Bool = x < width / 2
            var r: UInt8 = 0
            var g: UInt8 = 0
            var b: UInt8 = 0
            if top && left {
                r = 220; g = 30; b = 30
            } else if top {
                r = 30; g = 200; b = 40
            } else if !left {
                r = 30; g = 40; b = 210
            } else {
                r = 230; g = 210; b = 30
            }
            if x >= 2 && x < 6 && y >= 2 && y < 6 {
                r = 255; g = 255; b = 255
            }
            let at: Int = (y * width + x) * 4
            pixels[at] = r
            pixels[at + 1] = g
            pixels[at + 2] = b
            pixels[at + 3] = 255
        }
    }
    return RgbaImage(width: width, height: height, pixels: pixels)
}

/// The stored pixels whose display under orientation `tag` is `upright` (EXIF: tag 1 row 0 top, column
/// 0 left; 2 top, right; 3 bottom, right; 4 bottom, left; 5 left, top; 6 right, top; 7 right, bottom;
/// 8 left, bottom). For each displayed pixel (x, y) of a W × H display, the stored pixel it shows.
private func storedPixels(_ upright: RgbaImage, tag: Int) -> RgbaImage {
    let w: Int = upright.width
    let h: Int = upright.height
    let swaps: Bool = tag >= 5
    let sw: Int = swaps ? h : w
    let sh: Int = swaps ? w : h
    var pixels: [UInt8] = [UInt8](repeating: 0, count: sw * sh * 4)
    for y in 0..<h {
        for x in 0..<w {
            var sx: Int = x
            var sy: Int = y
            switch tag {
            case 2: sx = w - 1 - x; sy = y
            case 3: sx = w - 1 - x; sy = h - 1 - y
            case 4: sx = x; sy = h - 1 - y
            case 5: sx = y; sy = x
            case 6: sx = y; sy = w - 1 - x
            case 7: sx = h - 1 - y; sy = w - 1 - x
            case 8: sx = h - 1 - y; sy = x
            default: sx = x; sy = y
            }
            let from: Int = (y * w + x) * 4
            let to: Int = (sy * sw + sx) * 4
            for k in 0..<4 {
                pixels[to + k] = upright.pixels[from + k]
            }
        }
    }
    return RgbaImage(width: sw, height: sh, pixels: pixels)
}

/// A file of `type` holding `upright` stored for orientation `tag`, with the tag written.
private func orientedFile(_ upright: RgbaImage, tag: Int, type: UTType) -> Data {
    let stored: RgbaImage = storedPixels(upright, tag: tag)
    let image: CGImage = stored.makeCGImage()!
    var properties: [CFString: Any] = [kCGImagePropertyOrientation: tag]
    if type == UTType.jpeg {
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
    }
    return ImportTestSupport.file(type, images: [image], properties: properties)
}

/// The largest difference of any channel between `a` and `b` at pixel (x, y).
private func difference(_ a: RgbaImage, _ b: RgbaImage, x: Int, y: Int) -> Int {
    let at: Int = (y * a.width + x) * 4
    var worst: Int = 0
    for k in 0..<3 {
        worst = max(worst, abs(Int(a.pixels[at + k]) - Int(b.pixels[at + k])))
    }
    return worst
}

final class IOSPhotoDecoderTests: XCTestCase {
    func test_everyExifOrientation_comesInUpright_pixelForPixel_inTiff() throws {
        let upright: RgbaImage = uprightPixels(width: 24, height: 16)
        for tag in 1...8 {
            let data: Data = orientedFile(upright, tag: tag, type: UTType.tiff)
            // The fixture is what it says: the tag is in the file.
            XCTAssertEqual(ImportTestSupport.orientationTag(data), tag)
            let decoded: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: "tag\(tag).tiff")
            XCTAssertEqual(decoded.orientation, PhotoOrientation.fromExif(tag), "tag \(tag)")
            XCTAssertEqual(decoded.storedWidth, tag >= 5 ? 16 : 24, "tag \(tag)")
            XCTAssertEqual(decoded.photo.width, 24, "tag \(tag)")
            XCTAssertEqual(decoded.photo.height, 16, "tag \(tag)")
            var worst: Int = 0
            for y in 0..<16 {
                for x in 0..<24 {
                    worst = max(worst, difference(decoded.photo, upright, x: x, y: y))
                }
            }
            XCTAssertLessThanOrEqual(worst, 2, "tag \(tag)")
        }
    }

    func test_everyExifOrientation_comesInUpright_inJpeg() throws {
        let upright: RgbaImage = uprightPixels(width: 64, height: 48)
        // The middle of each quadrant, away from JPEG's blurred edges.
        let xs: [Int] = [16, 48, 48, 16]
        let ys: [Int] = [12, 12, 36, 36]
        for tag in 1...8 {
            let data: Data = orientedFile(upright, tag: tag, type: UTType.jpeg)
            XCTAssertEqual(ImportTestSupport.orientationTag(data), tag)
            let decoded: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: "tag\(tag).jpg")
            XCTAssertEqual(decoded.photo.width, 64, "tag \(tag)")
            XCTAssertEqual(decoded.photo.height, 48, "tag \(tag)")
            for index in 0..<4 {
                XCTAssertLessThanOrEqual(difference(decoded.photo, upright, x: xs[index], y: ys[index]), 24,
                                         "tag \(tag), quadrant \(index)")
            }
            // The white mark stays at the top left.
            let at: Int = (3 * 64 + 3) * 4
            XCTAssertGreaterThan(Int(decoded.photo.pixels[at + 2]), 100, "tag \(tag)")
        }
    }

    func test_aLargePhoto_isDecodedToTheLongSide_thenTurned() throws {
        let upright: RgbaImage = uprightPixels(width: 200, height: 120)
        let data: Data = orientedFile(upright, tag: 6, type: UTType.tiff)
        let decoded: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: "big.tiff", maxLongSide: 50)
        XCTAssertEqual(decoded.storedWidth, 120)
        XCTAssertEqual(decoded.storedHeight, 200)
        XCTAssertEqual(max(decoded.photo.width, decoded.photo.height), 50)
        // Upright: wider than tall, as the picture is seen.
        XCTAssertEqual(decoded.photo.width, 50)
        XCTAssertEqual(decoded.photo.height, 30)
        // Red still at the top left, blue at the bottom right.
        let topLeft: Int = (5 * decoded.photo.width + 10) * 4
        let bottomRight: Int = (25 * decoded.photo.width + 40) * 4
        XCTAssertGreaterThan(Int(decoded.photo.pixels[topLeft]), 150)
        XCTAssertGreaterThan(Int(decoded.photo.pixels[bottomRight + 2]), 150)
        // A photo within the long side is decoded whole.
        let whole: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: "big.tiff")
        XCTAssertEqual(whole.photo.width, 200)
        XCTAssertEqual(whole.photo.height, 120)
        XCTAssertEqual(IOSPhotoDecoder.maxLongSide, 8192)
    }

    func test_theFocalLength_comesFromExif_inPixelsOfThePhoto() throws {
        let upright: RgbaImage = uprightPixels(width: 64, height: 48)
        let image: CGImage = upright.makeCGImage()!
        let exif: [CFString: Any] = [kCGImagePropertyExifFocalLenIn35mmFilm: 26]
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
        let data: Data = ImportTestSupport.file(UTType.jpeg, images: [image], properties: properties)
        let decoded: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: "f.jpg")
        let expected: Double? = CaptureScale.focalLengthPixels(26, width: 64, height: 48)
        XCTAssertNotNil(expected)
        XCTAssertEqual(decoded.focalLength, expected)
        // Without it, none is made up.
        let plain: IOSDecodedPhoto = try IOSPhotoDecoder.decode(ImportTestSupport.file(UTType.png, images: [image]),
                                                                fileName: "plain.png")
        XCTAssertNil(plain.focalLength)
        XCTAssertTrue(plain.orientation.isUpright)
    }

    func test_aPhotoTooLarge_isTurnedDownFromItsHeader() {
        // A PNG whose header claims 13000 × 12000 pixels (more than 150 megapixels), with next to no data.
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let header: [UInt8] = [0, 0, 0x32, 0xC8, 0, 0, 0x2E, 0xE0, 8, 6, 0, 0, 0]
        let typed: [UInt8] = Array("IHDR".utf8) + header
        png += [0, 0, 0, 13]
        png += typed
        let crc: UInt32 = ZipStore.crc32(typed)
        png += [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
                UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        XCTAssertThrowsError(try IOSPhotoDecoder.decode(Data(png), fileName: "huge.png")) { (error: Error) in
            XCTAssertEqual((error as? IOSImportError)?.message,
                           PhotoImport.unreadableMessage("huge.png", detail: PhotoImport.tooLargeDetail))
        }
    }

    func test_aTiffOfSeveralPages_givesEachPage_asTheMacDoes() throws {
        // Three pages of different sizes, so each is known by its size.
        let sizes: [(Int, Int)] = [(24, 16), (30, 20), (16, 24)]
        var images: [CGImage] = []
        for size in sizes {
            images.append(uprightPixels(width: size.0, height: size.1).makeCGImage()!)
        }
        let data: Data = ImportTestSupport.file(UTType.tiff, images: images)
        XCTAssertEqual(IOSPhotoDecoder.pageCount(data), 3)
        XCTAssertEqual(IOSPhotoDecoder.pageCount(data), PhotoFileReader.pageCount(data))
        for (index, size) in sizes.enumerated() {
            let decoded: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: "fax.tif", page: index + 1)
            XCTAssertEqual(decoded.photo.width, size.0, "page \(index + 1)")
            XCTAssertEqual(decoded.photo.height, size.1, "page \(index + 1)")
            XCTAssertEqual(decoded.page, index + 1)
            XCTAssertEqual(decoded.pageCount, 3)
            let upright: RgbaImage = uprightPixels(width: size.0, height: size.1)
            XCTAssertLessThanOrEqual(difference(decoded.photo, upright, x: 3, y: 3), 2, "page \(index + 1)")
        }
        // The first page when none is named; no page past the last, named with its page.
        XCTAssertEqual(try IOSPhotoDecoder.decode(data, fileName: "fax.tif").photo.width, 24)
        XCTAssertThrowsError(try IOSPhotoDecoder.decode(data, fileName: "fax.tif", page: 4)) { (error: Error) in
            XCTAssertEqual((error as? IOSImportError)?.message,
                           PhotoImport.unreadableMessage("fax.tif, page 4 of 3", detail: PhotoImport.unreadableDetail))
        }
        // Other files hold one page.
        let png: Data = ImportTestSupport.file(UTType.png, images: [images[0]])
        XCTAssertEqual(IOSPhotoDecoder.pageCount(png), 1)
        let single: IOSDecodedPhoto = try IOSPhotoDecoder.decode(png, fileName: "one.png")
        XCTAssertEqual(single.page, 1)
        XCTAssertEqual(single.pageCount, 1)
    }

    func test_aFileThatIsNoPicture_saysSo() {
        XCTAssertThrowsError(try IOSPhotoDecoder.decode(Data("These are notes.".utf8), fileName: "notes.jpg")) { (error: Error) in
            XCTAssertEqual((error as? IOSImportError)?.message,
                           PhotoImport.unreadableMessage("notes.jpg", detail: PhotoImport.unreadableDetail))
        }
    }
}
#endif
