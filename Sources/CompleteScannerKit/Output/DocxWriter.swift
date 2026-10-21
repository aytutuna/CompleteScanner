import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Twin of windows/CompleteScanner.Core/DocxWriter.cs: the same package, byte for byte.

/// How the picture of a page is stored in a Word document. Twin of C# `DocxPictureFormat`.
public enum DocxPictureFormat: Equatable, Sendable {
    /// Color and gray pages, as the PDF size stores them in a PDF.
    case jpeg
    /// Black & white pages, one bit per pixel and lossless.
    case png
}

/// The picture of a page as it goes into a Word document: its encoded bytes and their format.
/// Twin of C# `DocxPicture`.
public struct DocxPicture: Equatable, Sendable {
    public let data: Data
    public let format: DocxPictureFormat

    public init(data: Data, format: DocxPictureFormat) {
        self.data = data
        self.format = format
    }
}

/// The Word document of a save (`OutputFormat.word`): the recognized text of the pages, one Word
/// paragraph per paragraph found (`OCRText.paragraphs(_:)`), each page after the first starting on
/// a new page. The smallest package Word and LibreOffice open: "[Content_Types].xml", "_rels/.rels"
/// and "word/document.xml", stored in a zip by `ZipStore`. No styles part, so the text takes the
/// reader's default font. The paper is the first page's size, with one-inch margins (less on a
/// page under 8 inches).
///
/// With page pictures (`OutputOptions.wordPageImages`) each page starts with its picture, an
/// inline DrawingML picture in a centred paragraph of its own, at the page's real size or shrunk
/// to fit inside the margins with its shape kept, and its text follows: a full page's picture
/// fills the paper and its text starts on the next one. The pictures are
/// "word/media/image1.jpeg" (or .png) and on, linked from "word/_rels/document.xml.rels".
/// Without pictures the package is byte for byte the text-only one.
public enum DocxWriter {
    /// One inch in twentieths of a point, Word's unit for page sizes.
    public static let twipsPerInch = 1440
    /// Word's smallest and largest paper side, in twips (0.1 in and 22 in).
    public static let minPageTwips = 144
    public static let maxPageTwips = 31680
    /// DrawingML's unit: English Metric Units per point and per twip (914,400 per inch).
    public static let emuPerPoint = 12700
    public static let emuPerTwip = 635

    /// The page pictures switch (`OutputOptions.wordPageImages`) as the inspector shows it.
    public static let pageImagesLabel = "Include page images"

    /// What the page pictures switch does, on and off: its tooltip.
    public static func pageImagesHint(on: Bool) -> String {
        on
            ? "Each page's picture, then its editable text"
            : "Only the editable text, without page pictures"
    }

    /// The relationship type of a picture's part.
    public static let imageRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

    public static let contentTypesXML =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        + "</Types>"

    public static let relationshipsXML =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        + "</Relationships>"

    /// The .docx file for `pages`; `pictures` holds each page's picture by index (nil, or no
    /// entry, for a page without one).
    public static func make(_ pages: [OCRPage], pictures: [DocxPicture?] = []) -> Data {
        ZipStore.make(packageEntries(pages, pictures: pictures))
    }

    /// The largest Word document a save writes, in bytes (2 GB): within what a zip without zip64
    /// addresses and what one array holds in memory, on both platforms alike.
    public static let maxPackageBytes = 2_000_000_000

    /// Why a Word document over `maxPackageBytes` is not written, and what to do instead.
    public static let tooLargeMessage: String =
        "The Word document would be larger than 2 GB, too large to write. Save fewer pages in each document, "
        + "choose a smaller page image size, or turn off \"Include page images\"."

    /// The size in bytes of the .docx file `make` writes for `pages` and `pictures`, worked out
    /// without writing it; a save checks it against `maxPackageBytes` first.
    public static func packageSize(_ pages: [OCRPage], pictures: [DocxPicture?] = []) -> Int {
        ZipStore.packageSize(packageEntries(pages, pictures: pictures))
    }

    /// The parts of the package, in the order they are stored.
    private static func packageEntries(_ pages: [OCRPage], pictures: [DocxPicture?]) -> [ZipStoreEntry] {
        let placed = placedPictures(pages, pictures)
        var entries = [
            ZipStoreEntry(name: "[Content_Types].xml", data: Data(packageContentTypesXML(placed).utf8)),
            ZipStoreEntry(name: "_rels/.rels", data: Data(relationshipsXML.utf8)),
            ZipStoreEntry(name: "word/document.xml", data: Data(documentXML(pages, pictures: pictures).utf8)),
        ]
        if !placed.isEmpty {
            entries.append(ZipStoreEntry(name: "word/_rels/document.xml.rels",
                                         data: Data(documentRelationshipsXML(placed).utf8)))
            for (index, picture) in placed.enumerated() {
                entries.append(ZipStoreEntry(name: "word/media/" + mediaName(index + 1, format: picture.format),
                                             data: picture.data))
            }
        }
        return entries
    }

    /// "word/document.xml": the paragraphs of every page (after its picture, when it has one),
    /// then the paper and margins.
    public static func documentXML(_ pages: [OCRPage], pictures: [DocxPicture?] = []) -> String {
        let size = pageSizeTwips(pages.first)
        let margin = marginTwips(width: size.width, height: size.height)
        let anyPicture = !placedPictures(pages, pictures).isEmpty

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        if anyPicture { xml += pictureNamespaces }
        xml += "><w:body>"
        var pictureNumber = 0
        for (index, page) in pages.enumerated() {
            let paragraphs = OCRText.paragraphs(page)
            var breakBefore = index > 0
            if let picture = pictureAt(pictures, index) {
                pictureNumber += 1
                let extent = pictureSizeEMU(page, paperWidthTwips: size.width, paperHeightTwips: size.height)
                appendPicture(&xml, number: pictureNumber, pageNumber: index + 1, format: picture.format,
                              cx: extent.width, cy: extent.height, pageBreakBefore: breakBefore)
                breakBefore = false
            } else if paragraphs.isEmpty {
                appendParagraph(&xml, text: "", pageBreakBefore: breakBefore)
                continue
            }
            for (number, paragraph) in paragraphs.enumerated() {
                appendParagraph(&xml, text: paragraph.text, pageBreakBefore: breakBefore && number == 0)
            }
        }
        if pages.isEmpty { appendParagraph(&xml, text: "", pageBreakBefore: false) }

        xml += "<w:sectPr><w:pgSz w:w=\"\(size.width)\" w:h=\"\(size.height)\""
        if size.width > size.height { xml += " w:orient=\"landscape\"" }
        xml += "/><w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\""
        xml += " w:header=\"\(margin / 2)\" w:footer=\"\(margin / 2)\" w:gutter=\"0\"/></w:sectPr>"
        xml += "</w:body></w:document>"
        return xml
    }

    /// The paper of the document in twips: the page's size in points × 20, each side kept within
    /// `minPageTwips`...`maxPageTwips`; US Letter without a page.
    public static func pageSizeTwips(_ page: OCRPage?) -> (width: Int, height: Int) {
        guard let page, page.widthPoints > 0, page.heightPoints > 0 else { return (12240, 15840) }
        return (twips(page.widthPoints), twips(page.heightPoints))
    }

    /// One inch, or an eighth of the shorter side of a smaller page.
    public static func marginTwips(width: Int, height: Int) -> Int {
        min(twipsPerInch, min(width, height) / 8)
    }

    /// `text` made safe for an XML text node: &, < and > escaped, and the characters XML cannot
    /// hold (control characters other than tab, line feed and carriage return, U+FFFE, U+FFFF) left out.
    public static func escapeXML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// "[Content_Types].xml" for a package holding `pictures` (the pictures in document order):
    /// `contentTypesXML` with a default content type for each picture format used, JPEG first,
    /// before the document's override.
    public static func packageContentTypesXML(_ pictures: [DocxPicture]) -> String {
        let jpeg = pictures.contains { $0.format == .jpeg }
        let png = pictures.contains { $0.format == .png }
        if !jpeg && !png { return contentTypesXML }
        let defaults = (jpeg ? defaultContentType(.jpeg) : "") + (png ? defaultContentType(.png) : "")
        guard let at = contentTypesXML.range(of: "<Override ") else { return contentTypesXML }
        return String(contentTypesXML[..<at.lowerBound]) + defaults + String(contentTypesXML[at.lowerBound...])
    }

    /// "word/_rels/document.xml.rels": one image relationship per picture, "rId1" to
    /// "media/image1.jpeg" and on, in document order.
    public static func documentRelationshipsXML(_ pictures: [DocxPicture]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (index, picture) in pictures.enumerated() {
            xml += "<Relationship Id=\"rId\(index + 1)\" Type=\"" + imageRelationshipType
                + "\" Target=\"media/" + mediaName(index + 1, format: picture.format) + "\"/>"
        }
        xml += "</Relationships>"
        return xml
    }

    /// The file name of the `number`th picture (from 1) in "word/media": "image1.jpeg".
    public static func mediaName(_ number: Int, format: DocxPictureFormat) -> String {
        "image\(number)." + pictureExtension(format)
    }

    /// "jpeg" or "png".
    public static func pictureExtension(_ format: DocxPictureFormat) -> String {
        format == .png ? "png" : "jpeg"
    }

    /// "image/jpeg" or "image/png".
    public static func pictureContentType(_ format: DocxPictureFormat) -> String {
        format == .png ? "image/png" : "image/jpeg"
    }

    /// How a page planned for a PDF (`PDFImageEncoding.plan(mode:imageDPI:size:looksGray:)`) is
    /// stored as a picture: a black & white page (G4 in a PDF) as PNG, the others as the planned JPEG.
    public static func pictureFormat(_ plan: PDFImagePlan) -> DocxPictureFormat {
        plan.isBilevel ? .png : .jpeg
    }

    /// The picture's size on the paper in EMU: the page's real size (points × 12,700), shrunk with
    /// its shape kept until it fits inside the margins of a paper of `paperWidthTwips` ×
    /// `paperHeightTwips`, never enlarged. Whole EMU, rounded down where shrunk; a page without a
    /// size fills the space inside the margins.
    public static func pictureSizeEMU(_ page: OCRPage, paperWidthTwips: Int,
                                      paperHeightTwips: Int) -> (width: Int, height: Int) {
        let margin = marginTwips(width: paperWidthTwips, height: paperHeightTwips)
        let boxWidth = max(1, paperWidthTwips - 2 * margin) * emuPerTwip
        let boxHeight = max(1, paperHeightTwips - 2 * margin) * emuPerTwip
        if !(page.widthPoints > 0) || !(page.heightPoints > 0) { return (boxWidth, boxHeight) }
        let width = emu(page.widthPoints)
        let height = emu(page.heightPoints)
        if width <= boxWidth && height <= boxHeight { return (width, height) }
        if width * boxHeight >= height * boxWidth { return (boxWidth, max(1, height * boxWidth / width)) }
        return (max(1, width * boxHeight / height), boxHeight)
    }

    /// The namespaces a document with pictures declares on its root, after w.
    private static let pictureNamespaces =
        " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        + " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
        + " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        + " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""

    /// The largest page side taken as it is, in EMU (over 100,000 inches), so that the products in
    /// `pictureSizeEMU` stay within 64 bits.
    private static let maxEMU = 1e11

    private static func emu(_ points: Double) -> Int {
        Int(min(max((points * Double(emuPerPoint)).rounded(), 1), maxEMU))
    }

    private static func defaultContentType(_ format: DocxPictureFormat) -> String {
        "<Default Extension=\"" + pictureExtension(format) + "\" ContentType=\"" + pictureContentType(format) + "\"/>"
    }

    private static func pictureAt(_ pictures: [DocxPicture?], _ index: Int) -> DocxPicture? {
        index < pictures.count ? pictures[index] : nil
    }

    /// The pictures that go into the document: one per page that has one, in page order.
    private static func placedPictures(_ pages: [OCRPage], _ pictures: [DocxPicture?]) -> [DocxPicture] {
        var placed: [DocxPicture] = []
        for index in pages.indices {
            if let picture = pictureAt(pictures, index) { placed.append(picture) }
        }
        return placed
    }

    /// The paragraph holding a page's picture: centred, no space around it, the picture inline
    /// (it moves with the text) with its shape locked, named after the page for screen readers.
    private static func appendPicture(_ xml: inout String, number: Int, pageNumber: Int, format: DocxPictureFormat,
                                      cx: Int, cy: Int, pageBreakBefore: Bool) {
        let extent = "cx=\"\(cx)\" cy=\"\(cy)\""
        xml += "<w:p><w:pPr>"
        if pageBreakBefore { xml += "<w:pageBreakBefore/>" }
        xml += "<w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"center\"/></w:pPr>"
        xml += "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
        xml += "<wp:extent " + extent + "/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
        xml += "<wp:docPr id=\"\(number)\" name=\"Page \(pageNumber)\" descr=\"Page \(pageNumber) as scanned\"/>"
        xml += "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
        xml += "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
        xml += "<pic:nvPicPr><pic:cNvPr id=\"\(number)\" name=\"" + mediaName(number, format: format)
            + "\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>"
        xml += "<pic:blipFill><a:blip r:embed=\"rId\(number)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
        xml += "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext " + extent
            + "/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
        xml += "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }

    /// One paragraph: its text in one run, a line break (between the rows of a table) as `w:br`, a
    /// tab (between the pieces of a row) as `w:tab`.
    private static func appendParagraph(_ xml: inout String, text: String, pageBreakBefore: Bool) {
        xml += "<w:p>"
        if pageBreakBefore { xml += "<w:pPr><w:pageBreakBefore/></w:pPr>" }
        let clean = escapeXML(text).replacingOccurrences(of: "\r", with: "")
        if !clean.isEmpty {
            xml += "<w:r>"
            let lines = clean.components(separatedBy: "\n")
            for (l, line) in lines.enumerated() {
                if l > 0 { xml += "<w:br/>" }
                let pieces = line.components(separatedBy: "\t")
                for (i, piece) in pieces.enumerated() {
                    if i > 0 { xml += "<w:tab/>" }
                    if !piece.isEmpty { xml += "<w:t xml:space=\"preserve\">" + piece + "</w:t>" }
                }
            }
            xml += "</w:r>"
        }
        xml += "</w:p>"
    }

    private static func twips(_ points: Double) -> Int {
        Int(min(max((points * 20).rounded(), Double(minPageTwips)), Double(maxPageTwips)))
    }
}

// MARK: - Mac picture encoding

extension DocxWriter {
    /// A page's picture for a Word document, stored as the PDF size stores the page in a PDF
    /// (`PDFImageEncoding.plan`): a color or gray page as the JPEG `PDFImageEncoding.encodedPage`
    /// makes, a black & white page downsampled to its planned resolution, thresholded as C#
    /// `Bilevel.Pack` does and written as a 1-bit PNG (ImageIO). `imageDPI` is the resolution of the
    /// pixels at hand (`PDFImageEncoding.effectiveDPI`). Nil when the image cannot be read or
    /// encoded; the page then goes into the document without its picture. Mac only: Windows
    /// encodes with WIC (`WpfImageCodec.EncodeDocxPicture`).
    public static func picture(of image: CGImage, imageDPI: Int, mode: ColorMode,
                               size: PDFSizePreset) -> DocxPicture? {
        if mode != .blackWhite {
            guard let page = PDFImageEncoding.encodedPage(image, imageDPI: imageDPI, mode: mode, size: size) else {
                return nil
            }
            return DocxPicture(data: page.jpegData, format: .jpeg)
        }
        let plan = PDFImageEncoding.plan(mode: .blackWhite, imageDPI: imageDPI, size: size, looksGray: false)
        guard var rgba = ColorAnalysis.rgbaPixels(of: image) else { return nil }
        var width = image.width
        var height = image.height
        let target = PDFImageEncoding.targetSize(width: width, height: height, imageDPI: imageDPI,
                                                 targetDPI: plan.targetDPI)
        if target.width != width || target.height != height {
            rgba = PDFImageEncoding.downsample(rgba: rgba, width: width, height: height,
                                               newWidth: target.width, newHeight: target.height)
            width = target.width
            height = target.height
        }
        guard let png = bilevelPNG(rgba: rgba, width: width, height: height) else { return nil }
        return DocxPicture(data: png, format: .png)
    }

    /// A 1-bit gray PNG of an RGBA8 buffer: luma (`ColorAnalysis.grayPixels`) below 128 is black.
    private static func bilevelPNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let gray = ColorAnalysis.grayPixels(rgba: rgba, width: width, height: height)
        let stride = (width + 7) / 8
        var packed = [UInt8](repeating: 0xFF, count: stride * height)
        for y in 0..<height {
            for x in 0..<width where gray[y * width + x] < 128 {
                packed[y * stride + (x >> 3)] &= ~(UInt8(0x80) >> UInt8(x & 7))
            }
        }
        // DeviceGray, 1 bit: 0 is black and 1 is white, as packed.
        guard let provider = CGDataProvider(data: Data(packed) as CFData),
              let bitmap = CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
                                   bytesPerRow: stride, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
