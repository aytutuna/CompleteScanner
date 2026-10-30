#if os(iOS)
import LazyScanKit
import CoreGraphics
import Foundation
import VisionKit

/// Quick scan's screen without a screen (I14): the page one shot gave (`AppState.quickScanPage`, held in
/// memory), saved as a picture (JPEG unless an image format is chosen) or its text copied
/// (`OCRService`), or discarded; Live Text on the page (VisionKit's `ImageAnalyzer` with an
/// `ImageAnalysisInteraction`) selects part of its text where the device supports it.
@MainActor
public final class IOSQuickScanModel: ObservableObject {
    public let state: AppState
    private let liveTextSupported: @MainActor () -> Bool

    /// `liveTextSupported` nil: whether this device can run Live Text (`ImageAnalyzer.isSupported`; tests say).
    public init(state: AppState, liveTextSupported: (@MainActor () -> Bool)? = nil) {
        self.state = state
        if let liveTextSupported {
            self.liveTextSupported = liveTextSupported
        } else {
            self.liveTextSupported = { () -> Bool in
                IOSQuickScanModel.deviceSupportsLiveText()
            }
        }
    }

    /// Live Text runs on this device (not in every Simulator).
    public static func deviceSupportsLiveText() -> Bool {
        ImageAnalyzer.isSupported
    }

    /// The page to show; nil once saved or discarded.
    public var image: CGImage? { state.quickScanPage?.image }

    /// A page is held: the screen is shown.
    public var isShown: Bool { state.quickScanPage != nil }

    /// The page is shown with Live Text, so its text can be selected on it.
    public var offersLiveText: Bool { isShown && liveTextSupported() }

    /// Save and Copy text can be pressed: a page is held and nothing runs.
    public var canAct: Bool { isShown && !state.isBusy }

    /// The format the page is saved in: the task's picture format, JPEG otherwise.
    public var format: OutputFormat { state.settings.format.imageFormatOrJPEG }

    /// "Save JPEG".
    public var saveLabel: String { "Save \(format.label)" }

    public static let copyTextLabel = "Copy text"
    public static let discardLabel = "Discard"
    public static let title = IOSScanKind.text.title

    public func save() {
        guard canAct else { return }
        state.saveQuickScan()
    }

    public func copyText() {
        guard canAct else { return }
        state.copyQuickScanText()
    }

    public func discard() {
        guard canAct else { return }
        state.discardQuickScan()
    }
}
#endif
