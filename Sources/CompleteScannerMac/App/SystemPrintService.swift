#if os(macOS)
import AppKit
import CompleteScannerKit
import CoreGraphics
import Foundation
import PDFKit

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
#endif
