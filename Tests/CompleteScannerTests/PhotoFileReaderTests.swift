import XCTest
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CompleteScannerKit

// Photos of documents read for import with ImageIO (`PhotoFileReader`, App/AppState+Import.swift): a
// photo too large is turned down from its header, before its pixels are decoded, and every page of a
// TIFF is read in turn. Twin of the Windows CompleteScanner.App.Tests/PhotoFileReaderTests.cs (WIC).

/// A plain picture of `width` × `height`.
private func makePicture(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return ctx.makeImage()!
}

/// A file of `type` holding one picture of each of `sizes`, in order.
private func makeFile(_ type: UTType, sizes: [(Int, Int)]) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, sizes.count, nil)!
    for size in sizes {
        CGImageDestinationAddImage(destination, makePicture(width: size.0, height: size.1), nil)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A PNG whose header says `width` × `height`, with next to no pixel data.
private func makePngClaiming(width: Int, height: Int) -> Data {
    func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    func chunk(_ type: String, _ body: [UInt8]) {
        png += bigEndian(UInt32(body.count))
        let typed = Array(type.utf8) + body
        png += typed
        png += bigEndian(ZipStore.crc32(typed))
    }
    // 8 bits a channel, RGBA, no interlacing.
    chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, 6, 0, 0, 0])
    chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
    chunk("IEND", [])
    return Data(png)
}

/// `tiff` with the header of its first page changed to claim `width` × `height` pixels, as a damaged
/// file might; the pages after it are left as they are.
private func firstPageClaiming(_ tiff: Data, width: UInt32, height: UInt32) -> Data {
    var bytes = [UInt8](tiff)
    let little = bytes[0] == UInt8(ascii: "I")
    func read16(_ at: Int) -> Int {
        let first = Int(bytes[at]), second = Int(bytes[at + 1])
        return little ? first | (second << 8) : (first << 8) | second
    }
    func read32(_ at: Int) -> Int {
        let first = read16(at), second = read16(at + 2)
        return little ? first | (second << 16) : (first << 16) | second
    }
    func write16(_ at: Int, _ value: UInt16) {
        let big: [UInt8] = [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        for i in 0..<2 { bytes[at + i] = little ? big[1 - i] : big[i] }
    }
    func write32(_ at: Int, _ value: UInt32) {
        let big: [UInt8] = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        for i in 0..<4 { bytes[at + i] = little ? big[3 - i] : big[i] }
    }
    let ifd = read32(4)
    let entries = read16(ifd)
    var changed = 0
    for i in 0..<entries {
        let entry = ifd + 2 + i * 12
        let tag = read16(entry)
        guard tag == 256 || tag == 257 || tag == 278 else { continue }
        // ImageWidth, ImageLength and RowsPerStrip (one strip, as the header then expects), one LONG each.
        write16(entry + 2, 4)
        write32(entry + 4, 1)
        write32(entry + 8, tag == 256 ? width : height)
        if tag != 278 { changed += 1 }
    }
    XCTAssertEqual(changed, 2)
    return Data(bytes)
}

final class PhotoFileReaderTests: XCTestCase {
    func testAPhotoTooLargeIsTurnedDownBeforeItsPixelsAreDecoded() {
        // More than 150 megapixels; then a damaged header no memory could hold.
        for (width, height) in [(13000, 12000), (60000, 60000)] {
            XCTAssertThrowsError(try PhotoFileReader.decode(makePngClaiming(width: width, height: height), fileName: "huge.png")) { error in
                XCTAssertEqual((error as? PhotoUnreadableError)?.message,
                               PhotoImport.unreadableMessage("huge.png", detail: PhotoImport.tooLargeDetail))
            }
        }
    }

    func testAJpegTooLargeIsTurnedDownFromItsHeader() throws {
        // A real JPEG whose start-of-frame is changed to claim 20000 × 10000 pixels.
        var bytes = [UInt8](makeFile(.jpeg, sizes: [(40, 30)]))
        let sof = try XCTUnwrap((2..<bytes.count - 9).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xC0 })
        bytes.replaceSubrange(sof + 5..<sof + 9, with: [0x27, 0x10, 0x4E, 0x20])
        XCTAssertEqual(PhotoFileReader.headerPixelSize(Data(bytes))?.width, 20000)
        XCTAssertEqual(PhotoFileReader.headerPixelSize(Data(bytes))?.height, 10000)
        XCTAssertThrowsError(try PhotoFileReader.decode(Data(bytes), fileName: "huge.jpg")) { error in
            XCTAssertEqual((error as? PhotoUnreadableError)?.message,
                           PhotoImport.unreadableMessage("huge.jpg", detail: PhotoImport.tooLargeDetail))
        }
    }

    func testTheHeaderSizeIsThatOfThePicture() {
        for type in [UTType.png, .jpeg] {
            let size = PhotoFileReader.headerPixelSize(makeFile(type, sizes: [(40, 30)]))
            XCTAssertEqual(size?.width, 40, type.identifier)
            XCTAssertEqual(size?.height, 30, type.identifier)
        }
        XCTAssertNil(PhotoFileReader.headerPixelSize(makeFile(.tiff, sizes: [(40, 30)])))
        XCTAssertNil(PhotoFileReader.headerPixelSize(Data([0xFF, 0xD8, 0xFF])))
        XCTAssertNil(PhotoFileReader.headerPixelSize(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])))
    }

    func testEveryPageOfATiffIsReadInTurn() throws {
        let data = makeFile(.tiff, sizes: [(40, 30), (50, 20), (24, 36)])
        let first = try PhotoFileReader.decode(data, fileName: "fax.tif")
        XCTAssertEqual(first.page, 1)
        XCTAssertEqual(first.pageCount, 3)
        XCTAssertEqual(first.fileName, "fax.tif")
        XCTAssertEqual(first.displayName, "fax.tif, page 1 of 3")
        XCTAssertEqual(first.stored.width, 40)
        XCTAssertEqual(first.stored.height, 30)
        let second = try PhotoFileReader.decode(data, fileName: "fax.tif", page: 2)
        XCTAssertEqual(second.page, 2)
        XCTAssertEqual(second.stored.width, 50)
        XCTAssertEqual(second.stored.height, 20)
        let third = try PhotoFileReader.decode(data, fileName: "fax.tif", page: 3)
        XCTAssertEqual(third.stored.width, 24)
        XCTAssertEqual(third.stored.height, 36)
        XCTAssertEqual(third.displayName, "fax.tif, page 3 of 3")
        XCTAssertThrowsError(try PhotoFileReader.decode(data, fileName: "fax.tif", page: 4))
        // Other files are one page, named by the file alone.
        let png = try PhotoFileReader.decode(makeFile(.png, sizes: [(30, 20)]), fileName: "one.png")
        XCTAssertEqual(png.page, 1)
        XCTAssertEqual(png.pageCount, 1)
        XCTAssertEqual(png.displayName, "one.png")
    }

    func testAPageThatCannotBeReadDoesNotHideThePagesAfterIt() throws {
        // The first page claims 20000 × 20000 pixels, more than 150 megapixels.
        let data = firstPageClaiming(makeFile(.tiff, sizes: [(40, 30), (50, 20), (24, 36)]), width: 20000, height: 20000)
        // The count comes from the file's header, not from decoding its first page.
        XCTAssertEqual(PhotoFileReader.pageCount(data), 3)
        XCTAssertThrowsError(try PhotoFileReader.decode(data, fileName: "fax.tif", page: 1))
        let second = try PhotoFileReader.decode(data, fileName: "fax.tif", page: 2)
        XCTAssertEqual(second.pageCount, 3)
        XCTAssertEqual(second.stored.width, 50)
        XCTAssertEqual(second.stored.height, 20)
        let third = try PhotoFileReader.decode(data, fileName: "fax.tif", page: 3)
        XCTAssertEqual(third.stored.width, 24)
        XCTAssertEqual(third.stored.height, 36)
    }

    func testAPageClaimingSizesBeyondAnyNumberIsTurnedDown() {
        // 4294967295 × 4294967295: the pixel count does not fit in 64 bits.
        let data = firstPageClaiming(makeFile(.tiff, sizes: [(40, 30), (50, 20)]), width: .max, height: .max)
        XCTAssertThrowsError(try PhotoFileReader.decode(data, fileName: "fax.tif", page: 1))
    }

    func testOtherFilesAndFilesThatAreNoPictureAreOnePage() {
        XCTAssertEqual(PhotoFileReader.pageCount(makeFile(.tiff, sizes: [(40, 30), (50, 20), (24, 36)])), 3)
        XCTAssertEqual(PhotoFileReader.pageCount(makeFile(.tiff, sizes: [(40, 30)])), 1)
        XCTAssertEqual(PhotoFileReader.pageCount(makeFile(.png, sizes: [(30, 20)])), 1)
        XCTAssertEqual(PhotoFileReader.pageCount(Data("These are notes; they are not a photo.".utf8)), 1)
        XCTAssertEqual(PhotoFileReader.pageCount(Data()), 1)
    }

    func testAFileThatIsNoPictureSaysSo() {
        XCTAssertThrowsError(try PhotoFileReader.decode(Data("These are notes; they are not a photo.".utf8), fileName: "notes.jpg")) { error in
            XCTAssertEqual((error as? PhotoUnreadableError)?.message,
                           PhotoImport.unreadableMessage("notes.jpg", detail: PhotoImport.unreadableDetail))
        }
    }
}
