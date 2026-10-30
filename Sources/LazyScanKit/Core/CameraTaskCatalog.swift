import Foundation

/// What the camera says for a step: one line to act on (ten words at most) and the fuller help behind it
/// (25 words at most), as a task's `TaskStep` does for the scanner glass.
public struct CameraStepText: Equatable, Sendable {
    public let prompt: String
    public let help: String

    public init(prompt: String, help: String) {
        self.prompt = prompt
        self.help = help
    }
}

/// The camera's words for every task (I14): what to point the phone at and how the steps go, where
/// `TaskCatalog` speaks of the scanner glass and the feeder. Keyed by `ScanTask`; the two-sided task and
/// the book have a line for each way the camera takes them (`TaskOptions.cameraFrontsFirst`,
/// `cameraSpreads`). Swift only: the Windows app takes no camera shots, so `TaskCatalog` stays the one
/// source of the tasks' titles and the scanner's steps on both platforms.
public enum CameraTaskCatalog {
    /// Flip & capture: after each front, its back.
    public static let turnOverPrompt = "Turn the sheet over and take its back."
    public static let turnOverHelp = "No back skips an empty back. Then take the next sheet's front."
    /// Flip & capture, once a sheet's back is in or skipped.
    public static let nextFrontPrompt = "Take the next sheet's front."
    /// Fronts first, once every front is in.
    public static let backsPrompt = "Now take each back, first sheet first."
    public static let backsHelp = "Turn the sheets over. The fronts and backs are put in order when the last back is in."
    /// The batch's next page starts a new document.
    public static let newDocumentPrompt = "The next page starts a new document."

    public static let noBackLabel = "No back"
    public static let startBacksLabel = "Now the backs"
    public static let putInOrderLabel = "Put in order"
    public static let combineLabel = "Combine anyway"
    public static let newDocumentLabel = "New document"
    public static let flipLabel = "Flip & capture"
    public static let frontsFirstLabel = "Fronts, then backs"
    public static let pageByPageLabel = "Page by page"
    public static let wholeSpreadLabel = "Whole spread"
    /// A book read from right to left: the right page of each spread comes first.
    public static let rightToLeftLabel = "Right to left"
    public static let rightToLeftHint = "Arabic, Hebrew, manga: the right page of each spread comes first."
    public static let separatorSheetLabel = "Separator sheet"
    public static let patchCodeLabel = "Patch code"
    public static let qrCodeLabel = "QR code"
    /// Why a patch code on a photographed page may not be read: its bars are measured in inches.
    public static let separatorHint = "Read once the page matches a paper size"

    /// The camera's words for `task`, as `options` take it: the two-sided task's flip & capture or fronts
    /// first, the book's page by page or whole spread.
    public static func text(_ task: ScanTask, options: TaskOptions = TaskOptions()) -> CameraStepText {
        switch task {
        case .document:
            return CameraStepText(prompt: "Hold the phone over each page.",
                                  help: "Each page is taken once it holds still. Save the PDF when they are all in.")
        case .feeder:
            return CameraStepText(prompt: "Take the pages one by one.",
                                  help: "The phone has no feeder: hold it over each page in turn, then save the PDF.")
        case .photos:
            return CameraStepText(prompt: "Lay the photos apart on a dark table.",
                                  help: "Each photo is found, cut out and straightened. Check them before saving.")
        case .photoRestore:
            return CameraStepText(prompt: "Lay the old photos apart on a dark table.",
                                  help: "Faded colors are restored. Check each photo before saving.")
        case .quickScan:
            return CameraStepText(prompt: "Hold the phone over the page and take it.",
                                  help: "Then save it as a picture or copy its text. Press on the text to select part of it.")
        case .email:
            return CameraStepText(prompt: "Hold the phone over each page.",
                                  help: "Saving makes a small PDF and opens Mail, or the share sheet. Nothing is sent until you send it.")
        case .twoSided:
            if options.cameraFrontsFirst {
                return CameraStepText(prompt: "Take the front of every sheet.",
                                      help: "Then tap Now the backs and take each back, first sheet first.")
            }
            return CameraStepText(prompt: "Take the front of the first sheet.",
                                  help: "After each front, turn the sheet over and take its back.")
        case .idCard:
            return CameraStepText(prompt: "Fit the card in the frame.",
                                  help: "Front, then back. Nothing is kept once you save or discard it.")
        case .copy:
            return CameraStepText(prompt: "Hold the phone over the original.",
                                  help: "Real size only when the page matches a paper size.")
        case .word:
            return CameraStepText(prompt: "Hold the phone over each page.",
                                  help: "The text is read into a Word document you can edit.")
        case .receipt:
            return CameraStepText(prompt: "Lay up to six receipts apart on a dark table.",
                                  help: "Each one is found, straightened and made easy to read. Check them before saving.")
        case .batch:
            return CameraStepText(prompt: "Take each page, then tap New document.",
                                  help: "Separator sheets work too, once a page matches a paper size. Check the splits in the strip, then save.")
        case .book:
            if options.cameraSpreads {
                return CameraStepText(prompt: "Take the open book, both pages at once.",
                                      help: "Each spread is cut at the spine into two pages. Curved pages are not flattened.")
            }
            return CameraStepText(prompt: "Take one page at a time, in order.",
                                  help: "Hold the book open and flat. Curved pages are not flattened.")
        case .archive:
            return CameraStepText(prompt: "Hold the phone over each page.",
                                  help: "Saved as a PDF/A, made to be kept for years.")
        }
    }

    /// What the camera says now for `task`: the two-sided camera's turn line while a back is due
    /// (`sides`) and flip & capture's next front after the first sheet, the batch's line while the next
    /// page starts a new document (`newDocument`), else the task's own words; nil without a task.
    public static func current(_ task: ScanTask?, options: TaskOptions, sides: CameraSides?,
                               newDocument: Bool) -> CameraStepText? {
        guard let task else { return nil }
        if task == .twoSided, let sides {
            if sides.next == .back {
                if sides.mode == .flip {
                    return CameraStepText(prompt: turnOverPrompt, help: turnOverHelp)
                }
                return CameraStepText(prompt: backsPrompt, help: backsHelp)
            }
            if sides.mode == .flip && sides.sheet > 0 {
                return CameraStepText(prompt: nextFrontPrompt, help: text(task, options: options).help)
            }
        }
        if task == .batch && newDocument {
            return CameraStepText(prompt: newDocumentPrompt, help: text(task, options: options).help)
        }
        return text(task, options: options)
    }
}
