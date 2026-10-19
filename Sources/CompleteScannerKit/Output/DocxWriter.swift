import Foundation

// Twin of windows/CompleteScanner.Core/DocxWriter.cs: the same package, byte for byte.

/// The Word document of a save (`OutputFormat.word`): the recognized text of the pages, one Word
/// paragraph per paragraph found (`OCRText.paragraphs(_:)`), each page after the first starting on
/// a new page. The smallest package Word and LibreOffice open: "[Content_Types].xml", "_rels/.rels"
/// and "word/document.xml", stored in a zip by `ZipStore`. No styles part, so the text takes the
/// reader's default font. The paper is the first page's size, with one-inch margins (less on a
/// page under 8 inches).
public enum DocxWriter {
    /// One inch in twentieths of a point, Word's unit for page sizes.
    public static let twipsPerInch = 1440
    /// Word's smallest and largest paper side, in twips (0.1 in and 22 in).
    public static let minPageTwips = 144
    public static let maxPageTwips = 31680

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

    /// The .docx file for `pages`.
    public static func make(_ pages: [OCRPage]) -> Data {
        ZipStore.make([
            ZipStoreEntry(name: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            ZipStoreEntry(name: "_rels/.rels", data: Data(relationshipsXML.utf8)),
            ZipStoreEntry(name: "word/document.xml", data: Data(documentXML(pages).utf8)),
        ])
    }

    /// "word/document.xml": the paragraphs of every page, then the paper and margins.
    public static func documentXML(_ pages: [OCRPage]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
        for (index, page) in pages.enumerated() {
            let paragraphs = OCRText.paragraphs(page)
            if paragraphs.isEmpty {
                appendParagraph(&xml, text: "", pageBreakBefore: index > 0)
                continue
            }
            for (number, paragraph) in paragraphs.enumerated() {
                appendParagraph(&xml, text: paragraph.text, pageBreakBefore: index > 0 && number == 0)
            }
        }
        if pages.isEmpty { appendParagraph(&xml, text: "", pageBreakBefore: false) }

        let size = pageSizeTwips(pages.first)
        let margin = marginTwips(width: size.width, height: size.height)
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
