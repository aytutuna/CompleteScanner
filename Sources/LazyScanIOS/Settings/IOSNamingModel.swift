#if os(iOS)
import LazyScanKit
import Foundation

/// The file name editor without a screen: the template as typed, the parts to insert (`NamingTokens.all`),
/// the name the next file gets and what is wrong with the template. A template that is not blank is put in
/// use as it is typed (one with an unknown part too, which stays as typed, as on Windows); a blank one
/// keeps the last name in use. The same template names every task's files, as on the desktop.
@MainActor
public final class IOSNamingModel: ObservableObject {
    public static let title = "File name"
    public static let insertTitle = "Insert"
    public static let exampleLabel = "Next file"
    public static let resetLabel = "Reset"

    @Published public private(set) var text: String
    private let state: AppState

    public init(state: AppState) {
        self.state = state
        self.text = state.settings.namingTemplate
    }

    public var parts: [NamingToken] { NamingTokens.all }

    /// What is wrong with the template typed; nil when it is fine.
    public var problem: String? { NamingTokens.problem(text) }

    /// The format the next file is saved in: a picture a page when the scan screen saves its pages as
    /// pictures (`IOSShell.savesImages`), else what the desktop's save writes.
    public var format: OutputFormat {
        let settings: ScanSettings = state.settings
        if IOSShell.collectsPages(settings) && IOSShell.savesImages(settings) {
            return settings.format.imageFormatOrJPEG
        }
        return NamingTokens.savedFormat(settings)
    }

    /// The name the next file gets ("Scan 2026-10-20 4.pdf"), with the template in use.
    public var example: String {
        state.fileNameExample(state.settings.namingTemplate, format: format)
    }

    /// The template typed: in use at once unless it is blank.
    public func setText(_ newText: String) {
        text = newText
        if NamingTokens.problem(newText) != NamingTokens.emptyProblem {
            state.settings.namingTemplate = newText
        }
    }

    /// A part put at the end of the template (`NamingTokens.insert`), with a space before it.
    public func insert(_ token: String) {
        let insertion: NamingInsertion = NamingTokens.insert(token, into: text, at: text.count)
        setText(insertion.text)
    }

    /// Back to a fresh install's template, "Scan {date} {counter}".
    public func reset() {
        setText(ScanSettings().namingTemplate)
    }
}
#endif
