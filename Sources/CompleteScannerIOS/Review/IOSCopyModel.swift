#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation

/// The iPhone's short texts of the copy screen (I16), the Mac inspector's Photocopy words where it has them.
public enum IOSCopyText {
    public static let title = "Copy"
    public static let pageName = "Page to copy"
    public static let fitLabel = "Fit to page"
    public static let fitHint = "Off: real size. On: shrinks to fit the paper."
    public static let pdfLabel = "Also save a PDF"
    public static let pdfHint = "Keeps a PDF of each copy in your save folder"
    public static let printLabel = "Print"
    public static let printHint = "Choose an AirPrint printer, then print"
    public static let againLabel = "Copy again"
    public static let discardLabel = "Discard"
    public static let discardHint = "Delete the page; can't be undone"
    public static let noPrinterYet = "You choose the printer when printing"
    /// Settings' Photocopy section: its choices are on the copy screen.
    public static let settingsNote = "Copies, Fit to page and the PDF are chosen on the copy screen."

    /// "Copies: 2".
    public static func copiesTitle(_ count: Int) -> String {
        "Copies: \(count)"
    }

    /// "Prints on Office Printer".
    public static func printsOn(_ printerName: String) -> String {
        "Prints on \(printerName)"
    }

    /// "Print again on Office Printer", for VoiceOver.
    public static func againHint(_ printerName: String) -> String {
        "Print again on \(printerName)"
    }

    /// "3 pages".
    public static func pageCount(_ count: Int) -> String {
        "\(count) pages"
    }
}

/// The copy screen without a screen (I16): the pages a photocopy holds (`AppState.copyPages`, in memory
/// only), how many copies, Fit to page (on and fixed when a page has no known size,
/// `AppState.copyNeedsFit`), Also save a PDF, the printer the copy goes to, and Print, Copy again on the
/// printer picked last, or Discard.
@MainActor
public final class IOSCopyModel: ObservableObject {
    public let state: AppState
    private let pickedPrinter: @MainActor () -> String?

    /// `pickedPrinter` nil: the printer picked last in AirPrint's picker (`IOSPrintService.lastPrinterName`);
    /// tests say.
    public init(state: AppState, pickedPrinter: (@MainActor () -> String?)? = nil) {
        self.state = state
        if let pickedPrinter {
            self.pickedPrinter = pickedPrinter
        } else {
            let service: IOSPrintService? = state.printService as? IOSPrintService
            self.pickedPrinter = { () -> String? in service?.lastPrinterName }
        }
    }

    /// The first page, shown large; nil once discarded.
    public var image: CGImage? { state.copyPages.first?.image }

    /// "2 pages" when the copy has several; nil for one.
    public var pageCountLine: String? {
        let count: Int = state.copyPages.count
        return count > 1 ? IOSCopyText.pageCount(count) : nil
    }

    /// Pages are held: the screen is shown.
    public var isShown: Bool { !state.copyPages.isEmpty }

    /// Print, Copy again and Discard can be pressed: pages are held and nothing runs.
    public var canAct: Bool { isShown && !state.isBusy }

    public var copies: Int { PrintCopies.clamp(state.settings.taskOptions.copyCount) }

    public func setCopies(_ count: Int) {
        state.setCopyCount(count)
    }

    /// Fit to page can't be turned off: some page's real size is not known.
    public var fitIsForced: Bool { state.copyNeedsFit }

    public var fitsToPage: Bool { fitIsForced || state.settings.taskOptions.copyFitToPage }

    public func setFitsToPage(_ fit: Bool) {
        guard !fitIsForced else { return }
        state.setCopyFitToPage(fit)
    }

    public var alsoSavesPDF: Bool { state.settings.taskOptions.copyAlsoSavePdf }

    public func setAlsoSavesPDF(_ save: Bool) {
        state.setCopyAlsoSavePdf(save)
    }

    /// The printer picked last; nil until one is picked.
    public var printerName: String? { pickedPrinter() }

    /// "Prints on Office Printer" once a printer was picked, else that it is chosen when printing.
    public var printerLine: String {
        printerName.map { IOSCopyText.printsOn($0) } ?? IOSCopyText.noPrinterYet
    }

    /// Copy again is offered once a printer was picked.
    public var offersCopyAgain: Bool { printerName != nil }

    public func print() {
        guard canAct else { return }
        state.printHeldCopy()
    }

    public func printAgain() {
        guard canAct, offersCopyAgain else { return }
        state.printHeldCopyAgain()
    }

    public func discard() {
        guard canAct else { return }
        state.discardHeldCopy()
    }
}
#endif
