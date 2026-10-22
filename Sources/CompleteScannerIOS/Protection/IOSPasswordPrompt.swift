#if os(iOS)
import CompleteScannerKit
import Foundation
import SwiftUI
import UIKit

/// What is typed in the password sheet, and what Save gave: the password twice, the strength hint
/// (`PasswordStrength`), what a reader may do with the file, and the problem with what is typed. The boxes
/// are emptied when the sheet closes; nothing here is stored anywhere, the Keychain neither. The iPhone's
/// twin of the Mac's `PDFPasswordForm`.
@MainActor
public final class IOSPasswordForm: ObservableObject {
    @Published public var password: String = ""
    @Published public var confirmation: String = ""
    @Published public var allowPrinting: Bool = true
    @Published public var allowCopying: Bool = true
    /// The message shown under the boxes; nil when none is.
    @Published public private(set) var shownProblem: String?

    /// The password and permissions given; nil until Save.
    public private(set) var protection: PDFProtection?

    public init() {}

    public var strength: PasswordStrength { PDFProtection.strengthOf(password) }

    /// "Weak", "Fair", "Strong"; empty while the box is empty.
    public var strengthLabel: String { PDFProtection.strengthLabel(strength) }

    /// How much of the strength bar is filled (0 to 4).
    public var strengthSegments: Int { PDFProtection.strengthSegments(strength) }

    /// The full advice behind the strength, for VoiceOver.
    public var strengthHint: String { PDFProtection.strengthHint(strength) }

    /// Why Save can't take what is typed; nil when it can.
    public var problem: String? { PDFProtection.problem(password, confirmation) }

    public var canSave: Bool { problem == nil }

    /// After a key: a difference between the two is pointed out once the second has as many characters
    /// as the first, a control character at once; an empty box needs no message.
    public func refresh() {
        guard let problem else {
            shownProblem = nil
            return
        }
        var hasControl: Bool = false
        for unit in password.utf16 where unit <= 0x1F || (unit >= 0x7F && unit <= 0x9F) {
            hasControl = true
            break
        }
        let show: Bool = !password.isEmpty && (hasControl || confirmation.count >= password.count)
        shownProblem = show ? problem : nil
    }

    /// Leaving the second box with something typed in it points out a difference, also a shorter one.
    public func confirmationLeft() {
        guard !confirmation.isEmpty, let problem else { return }
        shownProblem = problem
    }

    /// Takes the password when it can be used (true), else says why (false). The boxes are emptied.
    public func save() -> Bool {
        if let problem {
            shownProblem = problem
            return false
        }
        guard let given = try? PDFProtection(password, allowPrinting: allowPrinting, allowCopying: allowCopying) else {
            return false
        }
        protection = given
        clear()
        return true
    }

    /// Empties the boxes.
    public func clear() {
        password = ""
        confirmation = ""
        shownProblem = nil
    }
}

/// Hands one answer to the save waiting for the sheet; a second answer changes nothing.
@MainActor
final class IOSPasswordAnswer {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func give(_ saved: Bool) {
        continuation?.resume(returning: saved)
        continuation = nil
    }
}

/// Asks for the password of a protected PDF when a save needs one (`AppState.askPDFPassword` on the
/// iPhone and iPad, set by `AppState.makeForIOS`): the password sheet (`PasswordSheetView`) over whatever is
/// shown, the scan screen or a review, as the Mac's own window comes up over its sheets. Save gives the
/// password for every PDF of that save; Cancel gives nil, and nothing is saved. `present` shows the sheet
/// and calls back with whether it was saved (tests pass a stand-in that answers).
@MainActor
public final class IOSPasswordPrompt {
    public typealias Presenter = @MainActor (IOSPasswordForm, @escaping @MainActor (Bool) -> Void) -> Void

    private let present: Presenter
    /// A sheet is up: a second save asking meanwhile gets no password.
    public private(set) var isAsking: Bool = false

    public init(present: Presenter? = nil) {
        if let present {
            self.present = present
        } else {
            self.present = { (form, finish) in
                IOSPasswordPrompt.presentSheet(form, finish: finish)
            }
        }
    }

    /// Shows the sheet until Save or Cancel: the protection given, or nil.
    public func ask() async -> PDFProtection? {
        guard !isAsking else { return nil }
        isAsking = true
        let form: IOSPasswordForm = IOSPasswordForm()
        let show: Presenter = present
        let saved: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer: IOSPasswordAnswer = IOSPasswordAnswer(continuation)
            show(form) { (ok: Bool) -> Void in
                answer.give(ok)
            }
        }
        isAsking = false
        let given: PDFProtection? = saved ? form.protection : nil
        form.clear()
        return given
    }

    /// The sheet over the view controller on top, kept up until Save or Cancel (a swipe does not close it).
    static func presentSheet(_ form: IOSPasswordForm, finish: @escaping @MainActor (Bool) -> Void) {
        guard let top = IOSPasswordPrompt.topViewController() else {
            finish(false)
            return
        }
        let placeholder: PasswordSheetView = PasswordSheetView(form: form, onSave: {}, onCancel: {})
        let controller: UIHostingController<PasswordSheetView> = UIHostingController(rootView: placeholder)
        weak var shown: UIHostingController<PasswordSheetView>? = controller
        let save: @MainActor () -> Void = { () -> Void in
            guard form.save() else { return }
            shown?.dismiss(animated: true, completion: nil)
            finish(true)
        }
        let cancel: @MainActor () -> Void = { () -> Void in
            form.clear()
            shown?.dismiss(animated: true, completion: nil)
            finish(false)
        }
        controller.rootView = PasswordSheetView(form: form, onSave: save, onCancel: cancel)
        controller.isModalInPresentation = true
        top.present(controller, animated: true, completion: nil)
    }

    /// The view controller shown on top of the key window: the root's, or the last one it presented.
    static func topViewController() -> UIViewController? {
        var root: UIViewController?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                root = window.rootViewController
            }
        }
        var top: UIViewController? = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
