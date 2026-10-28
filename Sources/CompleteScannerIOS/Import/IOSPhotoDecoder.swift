#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation
import ImageIO

/// A photo read for import: upright, at most `IOSPhotoDecoder.maxLongSide` pixels on its long side.
public struct IOSDecodedPhoto: Sendable {
    /// The pixels the right way up (the orientation tag applied).
    public let photo: RgbaImage
    /// The orientation tag the file carried (`kCGImagePropertyOrientation`), as a turn.
    public let orientation: PhotoOrientation
    /// The pixel size the file stores, before it was turned or made smaller.
    public let storedWidth: Int
    public let storedHeight: Int
    /// The camera's focal length in pixels of `photo` (from EXIF FocalLenIn35mmFilm); nil when the
    /// file does not say.
    public let focalLength: Double?
    /// Which page of the file this is (from 1), and how many the file holds (a TIFF may hold several).
    public let page: Int
    public let pageCount: Int
}

/// Why a photo or PDF could not be imported; `message` is for the user.
public struct IOSImportError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// Reads photos for import with ImageIO (JPEG, HEIC, PNG, TIFF and the rest), from their bytes as the
/// Photos picker or the Files app hands them over. A TIFF may hold several pages (a fax, a scan): each
/// is read as a photo of its own (`pageCount`, then `decode` with its page), as on the Mac. The size and the orientation tag are read from the
/// file's header first: a photo of more than `PhotoImport.maxPhotoPixels` is turned down before any
/// pixel is decoded, and a large photo is decoded straight to at most `maxLongSide` pixels (ImageIO's
/// thumbnail, without its own turn), so a 48 MP HEIC never sits in memory whole. The orientation tag
/// (all eight values) is then applied by the shared `PhotoImport.oriented`, the Mac's and Windows'
/// way, so the page search and the corner editor see the photo the right way up.
public enum IOSPhotoDecoder {
    /// The long side a photo is decoded to at most: a 12 MP shot (4032 × 3024) is read whole.
    public static let maxLongSide: Int = 4096

    /// How many pages the photo file `data` holds: a TIFF's pages, 1 for other files and for files that
    /// cannot be read (`decode` says why). The Mac's count (`PhotoFileReader.pageCount`).
    public static func pageCount(_ data: Data) -> Int {
        PhotoFileReader.pageCount(data)
    }

    /// Page `page` (from 1) of the photo in `data`, named `fileName` in the messages (with the page,
    /// `PhotoImport.pageName`, when the file holds several); throws `IOSImportError`.
    public static func decode(_ data: Data, fileName: String, page: Int = 1,
                              maxLongSide: Int = IOSPhotoDecoder.maxLongSide) throws -> IOSDecodedPhoto {
        // ImageIO takes no PNG or JPEG that claims more pixels than it holds: read such a header first.
        if let claimed = PhotoFileReader.headerPixelSize(data),
           PhotoFileReader.tooLarge(width: claimed.width, height: claimed.height) {
            throw IOSImportError(message: PhotoImport.unreadableMessage(fileName, detail: PhotoImport.tooLargeDetail))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw IOSImportError(message: PhotoImport.unreadableMessage(fileName, detail: PhotoImport.unreadableDetail))
        }
        let pageCount: Int = PhotoFileReader.pagesIn(source)
        let shown: String = PhotoImport.pageName(fileName, page: page, pageCount: pageCount)
        guard page >= 1, page <= pageCount else {
            throw IOSImportError(message: PhotoImport.unreadableMessage(shown, detail: PhotoImport.unreadableDetail))
        }
        let index: Int = page - 1
        let properties: [CFString: Any] = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        let width: Int = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height: Int = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if PhotoFileReader.tooLarge(width: width, height: height) {
            throw IOSImportError(message: PhotoImport.unreadableMessage(shown, detail: PhotoImport.tooLargeDetail))
        }
        let tag: Int = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation: PhotoOrientation = PhotoOrientation.fromExif(tag)
        guard let image = storedImage(source, index: index, width: width, height: height, maxLongSide: maxLongSide),
              let stored = RgbaImage(cgImage: image) else {
            throw IOSImportError(message: PhotoImport.unreadableMessage(shown, detail: PhotoImport.unreadableDetail))
        }
        let upright: RgbaImage = PhotoImport.oriented(stored, orientation: orientation)
        var focalLength: Double?
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let f35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue {
            focalLength = CaptureScale.focalLengthPixels(f35, width: upright.width, height: upright.height)
        }
        return IOSDecodedPhoto(photo: upright, orientation: orientation, storedWidth: width, storedHeight: height,
                               focalLength: focalLength, page: page, pageCount: pageCount)
    }

    /// The stored pixels of image `index`, unturned: whole when the long side is at most `maxLongSide`,
    /// else decoded to that long side.
    static func storedImage(_ source: CGImageSource, index: Int, width: Int, height: Int, maxLongSide: Int) -> CGImage? {
        let longSide: Int = max(width, height)
        if longSide > 0 && longSide <= maxLongSide {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}
#endif
