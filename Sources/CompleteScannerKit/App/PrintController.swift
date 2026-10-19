import AppKit
import CoreGraphics
import Foundation
import PDFKit

// Printing on the Mac: the Copy task, the ID card's page and the ruler test page. The pages are
// laid out with `PrintLayout` on a PDF the size of the paper and printed through the standard print
// panel at 100 % (`PDFDocument.printOperation(for:scalingMode: .pageScaleNone, autoRotate: false)`),
// already set to the printer, the paper and the number of copies. Twin of the Windows
// `Services/PrintService.cs`, which prints with no panel.

/// One page of a print job: the image as scanned, its resolution, and where it goes on the paper.
public struct PrintPage {
    public let image: CGImage
    public let dpi: Int
    public let placement: PrintPlacement

    public init(image: CGImage, dpi: Int, placement: PrintPlacement) {
        self.image = image
        self.dpi = dpi
        self.placement = placement
    }
}

/// What printing on a printer would use: the paper and the part of it the printer prints on.
public struct PrinterSetup: Equatable, Sendable {
    public let printerName: String
    public let paper: PrinterPaper

    public init(printerName: String, paper: PrinterPaper) {
        self.printerName = printerName
        self.paper = paper
    }
}

/// A print job: the document's pages are on `paper`; `copies` is asked of the printer (the print
/// panel shows it). `printerName` nil is the default printer.
public struct PrintJob {
    public let printerName: String?
    public let jobName: String
    public let paper: PrinterPaper
    public let copies: Int

    public init(printerName: String?, jobName: String, paper: PrinterPaper, copies: Int) {
        self.printerName = printerName
        self.jobName = jobName
        self.paper = paper
        self.copies = copies
    }
}

/// Printing could not be done; the description says why. Not a `ScanError`: the troubleshooter is
/// about scanners. Twin of the Windows `PrintException`.
public enum PrintError: LocalizedError, Equatable {
    case noPrinter
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noPrinter: return PrintText.noPrinterMessage
        case .failed(let reason): return reason
        }
    }
}

/// The system side of printing, injected into `AppState` so tests can stand in for it.
@MainActor public protocol PrintService: AnyObject {
    /// The installed printers' names.
    var printerNames: [String] { get }
    /// The default printer's name; nil when there is none.
    var defaultPrinterName: String? { get }
    /// What printing on `printerName` (nil: the default printer) would use, on `requestedPaper` (nil:
    /// the printer's own paper); nil when no printer is installed.
    func setup(printerName: String?, requestedPaper: PaperSize?) -> PrinterSetup?
    /// Shows the print panel for `document` (a PDF the size of the paper), set to the job's printer,
    /// paper and copies at 100 %; true when the user printed, false when they cancelled.
    func print(_ document: Data, job: PrintJob) throws -> Bool
}

/// The PDF a print job prints: one page the size of the paper per page, each image (turned as
/// placed) drawn in its `PrintPlacement` rectangle in points, nothing scaled to the page.
public enum PrintDocument {
    /// Points per inch.
    public static let unitsPerInch = 72.0

    /// The pages on `paper` (inches) as a PDF; nil when it cannot be drawn.
    public static func makePDF(pages: [PrintPage], paper: CGSize) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        let size = PrintLayout.toUnits(paper, unitsPerInch: unitsPerInch)
        var mediaBox = CGRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        for page in pages {
            context.beginPDFPage(nil)
            let turns = ((page.placement.quarterTurns % 4) + 4) % 4
            let image = turns == 0 ? page.image : ImagePipeline.rotate(page.image, quarterTurns: turns)
            let rect = PrintLayout.toUnits(page.placement.rect, unitsPerInch: unitsPerInch)
            // PDF space has its origin at the bottom left; the placement's is at the top left.
            let drawn = CGRect(x: Double(rect.minX), y: Double(mediaBox.height) - Double(rect.maxY),
                               width: Double(rect.width), height: Double(rect.height))
            context.interpolationQuality = .high
            context.draw(image, in: drawn)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Whether a printer has a paper size, from the sizes of the papers its driver names (PPD page size
/// names). The Windows twin matches the sizes the printer lists (`PrintService.cs`, `SameMedia`).
enum PrinterPapers {
    /// The names drivers give `size`; empty for a size no printer is asked for.
    static func names(_ size: PaperSize) -> [String] {
        switch size {
        case .letter: return ["Letter", "na-letter", "na_letter_8.5x11in"]
        case .legal: return ["Legal", "na-legal", "na_legal_8.5x14in"]
        case .executive: return ["Executive", "na-executive", "na_executive_7.25x10.5in"]
        case .a4: return ["A4", "iso-a4", "iso_a4_210x297mm"]
        case .a5: return ["A5", "iso-a5", "iso_a5_148x210mm"]
        case .a6: return ["A6", "iso-a6", "iso_a6_105x148mm"]
        case .b5Jis: return ["B5", "JISB5", "jis-b5", "jis_b5_182x257mm"]
        case .auto, .idCard: return []
        }
    }

    /// Whether a printer has `size`: one of its names has, on that printer, a paper of that size
    /// (`pageSize` gives the printer's paper of a name in points, zero when it has none).
    static func offers(_ size: PaperSize, pageSize: (String) -> CGSize) -> Bool {
        names(size).contains { name in
            let points = pageSize(name)
            guard points.width > 0, points.height > 0 else { return false }
            return PaperSizes.match(CGSize(width: Double(points.width) / 72, height: Double(points.height) / 72)) == size
        }
    }
}

/// The macOS implementation: the printers from `NSPrinter`, the paper from `NSPrintInfo`, printing
/// through `PDFDocument`'s print operation with the standard print panel.
@MainActor public final class SystemPrintService: PrintService {
    public init() {}

    public var printerNames: [String] { NSPrinter.printerNames }

    public var defaultPrinterName: String? { NSPrintInfo.defaultPrinter?.name }

    public func setup(printerName: String?, requestedPaper: PaperSize?) -> PrinterSetup? {
        guard !NSPrinter.printerNames.isEmpty else { return nil }
        let info = printInfo(printerName: printerName, paper: nil)
        // The paper asked for when the printer has it; else the printer's own, as on Windows.
        if let requestedPaper, let inches = PaperSizes.inches(requestedPaper) {
            let printer = info.printer
            let offered = PrinterPapers.offers(requestedPaper) { name in
                let points = printer.pageSize(forPaper: NSPrinter.PaperName(name))
                return CGSize(width: Double(points.width), height: Double(points.height))
            }
            if offered {
                info.paperSize = NSSize(width: Double(inches.width) * 72, height: Double(inches.height) * 72)
            }
        }
        let size = info.paperSize
        guard size.width > 0, size.height > 0 else { return nil }
        let bounds = info.imageablePageBounds
        let paper = CGSize(width: Double(size.width) / 72, height: Double(size.height) / 72)
        // The imageable bounds have their origin at the bottom left; the layout's is at the top left.
        let printable = CGRect(x: Double(bounds.minX) / 72, y: (Double(size.height) - Double(bounds.maxY)) / 72,
                               width: Double(bounds.width) / 72, height: Double(bounds.height) / 72)
        return PrinterSetup(printerName: info.printer.name, paper: PrinterPaper.make(paper: paper, printable: printable))
    }

    public func print(_ document: Data, job: PrintJob) throws -> Bool {
        guard let pdf = PDFDocument(data: document) else { throw PrintError.failed("The pages could not be prepared for printing.") }
        let info = printInfo(printerName: job.printerName, paper: job.paper.paper)
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.dictionary()[NSPrintInfo.AttributeKey.copies.rawValue] = NSNumber(value: PrintCopies.clamp(job.copies))
        guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else {
            throw PrintError.failed("The print panel could not be opened.")
        }
        operation.jobTitle = job.jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
    }

    /// A copy of the shared print info on `printerName` (the default printer when nil or no longer
    /// installed), portrait, on `paper` (inches) when given.
    private func printInfo(printerName: String?, paper: CGSize?) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        if let printerName, let printer = NSPrinter(name: printerName) {
            info.printer = printer
        } else if let printer = NSPrintInfo.defaultPrinter {
            info.printer = printer
        }
        info.orientation = .portrait
        if let paper {
            info.paperSize = NSSize(width: Double(paper.width) * 72, height: Double(paper.height) * 72)
        }
        return info
    }
}
