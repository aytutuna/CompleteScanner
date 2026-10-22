#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation
import UIKit

/// The iPhone's and iPad's printing, over AirPrint. The Kit hands it a PDF the size of the paper
/// (`PrintDocument.makePDF`), drawn at real size; this draws that PDF onto the chosen printer's paper
/// at 100 % with a `UIPrintPageRenderer`, repeating the pages itself for the copies (UIKit's print info
/// has no copy count), and presents the system printer picker. The printer the user picks is kept, so
/// "Copy again" reaches it without asking again. Nothing is sent until the user taps Print.
///
/// iOS has no list of installed printers before the picker is shown, so `printerNames` reports a single
/// logical AirPrint printer when the OS can print at all, and `setup` lays pages out on the paper asked
/// for (else the region's usual one) inside `assumedMarginInches`; the real printer is chosen in the
/// picker at print time and asked for the sheet closest to that paper (`choosePaper`). Twin role to the
/// Mac's `SystemPrintService`, but driven by UIKit instead of the Mac's modal panel.
@MainActor public final class IOSPrintService: NSObject, PrintService, UIPrintInteractionControllerDelegate {
    /// The printer picked last, reused by "Copy again" and pre-selected in the picker. Also iOS-only
    /// state the copy screen reads for its "reuses the printer" line.
    public private(set) var lastPrinter: UIPrinter?

    /// The paper of the job being printed, in points.
    private var pageSize = CGSize(width: 612, height: 792)

    public override init() {}

    /// The name shown for the AirPrint printer: the one picked last, else the generic name. iOS cannot
    /// name a printer before one is picked.
    public static let genericPrinterName = "AirPrint printer"

    public var printerNames: [String] {
        UIPrintInteractionController.isPrintingAvailable ? [lastPrinterName ?? Self.genericPrinterName] : []
    }

    public var defaultPrinterName: String? {
        UIPrintInteractionController.isPrintingAvailable ? (lastPrinterName ?? Self.genericPrinterName) : nil
    }

    /// The display name of the printer picked last; nil until one is picked.
    public var lastPrinterName: String? { lastPrinter?.displayName }

    /// Whether a printer was picked, so "Copy again" can reuse it without the picker.
    public var hasPickedPrinter: Bool { lastPrinter != nil }

    public func setup(printerName: String?, requestedPaper: PaperSize?) -> PrinterSetup? {
        guard UIPrintInteractionController.isPrintingAvailable else { return nil }
        let paper = requestedPaper.flatMap { PaperSizes.inches($0) } ?? Self.defaultPaperInches
        // The printer's margins are known only once it is picked, after the layout: assume wide ones so Fit
        // to page stays clear of them and the margin warnings can show.
        let m = Self.assumedMarginInches
        let printable = CGRect(x: m, y: m, width: Double(paper.width) - 2 * m, height: Double(paper.height) - 2 * m)
        // No printer can be named before the picker; the job goes to the one picked there.
        return PrinterSetup(printerName: lastPrinterName ?? Self.genericPrinterName,
                            paper: PrinterPaper.make(paper: paper, printable: printable))
    }

    /// The margins assumed before a printer is picked: wider than most AirPrint printers'.
    static let assumedMarginInches = 0.25

    /// Prints `document` (a paper-sized PDF) through the picker, reusing the last printer when one was
    /// picked (`reusePrinter`), else letting the user choose. The pages are drawn at 100 % and repeated
    /// `job.copies` times by the renderer. True when printed, false when the user cancelled.
    public func print(_ document: Data, job: PrintJob) async throws -> Bool {
        try await present(document, job: job, reusePrinter: false)
    }

    /// Prints again on the printer picked last without showing the picker; the picker is shown when none
    /// was picked yet. Used by "Copy again".
    public func printAgain(_ document: Data, job: PrintJob) async throws -> Bool {
        try await present(document, job: job, reusePrinter: true)
    }

    private func present(_ document: Data, job: PrintJob, reusePrinter: Bool) async throws -> Bool {
        guard UIPrintInteractionController.isPrintingAvailable else { throw PrintError.noPrinter }
        guard let pdf = IOSPrintRenderer.pdf(from: document) else {
            throw PrintError.failed("The pages could not be prepared for printing.")
        }
        let copies = PrintCopies.clamp(job.copies)
        let renderer = IOSPrintRenderer(pdf: pdf, copies: copies)
        pageSize = CGSize(width: Double(job.paper.paper.width) * PrintDocument.unitsPerInch,
                          height: Double(job.paper.paper.height) * PrintDocument.unitsPerInch)
        let info = UIPrintInfo.printInfo()
        info.jobName = job.jobName
        info.outputType = .general
        info.orientation = .portrait

        if reusePrinter, let printer = lastPrinter {
            return try await printTo(printer, info: info, renderer: renderer)
        }
        guard let printer = await pickPrinter(initiallySelected: lastPrinter) else { return false }
        lastPrinter = printer
        return try await printTo(printer, info: info, renderer: renderer)
    }

    /// Shows the system printer picker from the top view controller; the picked printer, or nil when the
    /// user cancelled.
    private func pickPrinter(initiallySelected: UIPrinter?) async -> UIPrinter? {
        let picker = UIPrinterPickerController(initiallySelectedPrinter: initiallySelected)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIPrinter?, Never>) in
            let handler: UIPrinterPickerController.CompletionHandler = { controller, completed, error in
                continuation.resume(returning: completed && error == nil ? controller.selectedPrinter : nil)
            }
            if let anchor = Self.topViewController() {
                _ = picker.present(from: anchor.view.bounds, in: anchor.view, animated: true, completionHandler: handler)
            } else {
                _ = picker.present(animated: true, completionHandler: handler)
            }
        }
    }

    private func printTo(_ printer: UIPrinter, info: UIPrintInfo, renderer: IOSPrintRenderer) async throws -> Bool {
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printPageRenderer = renderer
        controller.delegate = self
        // Not left set: the share sheet's Print uses the same controller.
        defer { controller.delegate = nil }
        // The renderer repeats the pages for the copies, so the printer is asked for one.
        controller.showsNumberOfCopies = false
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            _ = controller.print(to: printer) { _, completed, error in
                if let error {
                    continuation.resume(throwing: PrintError.failed("Could not print on \(printer.displayName): \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: completed)
                }
            }
        }
    }

    /// The printer's sheet closest to the paper the pages were laid out on; without this AirPrint picks
    /// its own default and a page laid out on A4 could come out on Letter.
    public func printInteractionController(_ printInteractionController: UIPrintInteractionController,
                                           choosePaper paperList: [UIPrintPaper]) -> UIPrintPaper {
        UIPrintPaper.bestPaper(forPageSize: pageSize, withPapersFrom: paperList)
    }

    /// The region's usual paper, for laying pages out before a printer is picked.
    private static var defaultPaperInches: CGSize {
        PaperSizes.inches(PaperSizes.defaultForRegion(Locale.current.region?.identifier)) ?? CGSize(width: 8.5, height: 11)
    }

    /// The front-most view controller, to present the picker from (an anchor is required on iPad).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

/// Draws a paper-sized PDF onto the printer's paper at real size (100 %, points to points), repeating
/// its pages for the copies. Nothing is scaled to fit: the Kit already placed each page at real size on
/// a page the size of the paper, so the PDF is drawn 1:1 from the paper's top-left corner.
final class IOSPrintRenderer: UIPrintPageRenderer {
    private let pdf: CGPDFDocument
    private let pageCount: Int
    private let copies: Int

    init(pdf: CGPDFDocument, copies: Int) {
        self.pdf = pdf
        self.pageCount = pdf.numberOfPages
        self.copies = max(1, copies)
        super.init()
    }

    static func pdf(from data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    override var numberOfPages: Int { max(0, pageCount) * copies }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        guard pageCount > 0, let context = UIGraphicsGetCurrentContext() else { return }
        // CGPDFDocument pages are 1-based; repeat the document for each copy.
        guard let page = pdf.page(at: pageIndex % pageCount + 1) else { return }
        let box = page.getBoxRect(.cropBox)
        let paper = paperRect
        context.saveGState()
        // PDF space has its origin at the bottom left; flip so the PDF's top edge meets the paper's, 1:1.
        context.translateBy(x: paper.minX - box.minX, y: paper.minY + box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
#endif
