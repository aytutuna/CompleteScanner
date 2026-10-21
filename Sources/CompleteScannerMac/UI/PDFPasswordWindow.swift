#if os(macOS)
import Accessibility
import AppKit
import CompleteScannerKit
import SwiftUI

/// What is typed in the password dialog, and what Save gave. The boxes are emptied when the dialog
/// closes; nothing here is stored anywhere.
@MainActor
final class PDFPasswordForm: ObservableObject {
    @Published var password = ""
    @Published var confirmation = ""
    @Published var allowPrinting = true
    @Published var allowCopying = true
    /// The message shown under the boxes; nil when none is.
    @Published var shownProblem: String?

    /// The password and permissions given; nil until Save.
    private(set) var protection: PDFProtection?

    var strength: PasswordStrength { PDFProtection.strengthOf(password) }

    /// Why Save can't take what is typed; nil when it can.
    var problem: String? { PDFProtection.problem(password, confirmation) }

    /// After a key: a difference between the two is pointed out once the second has as many
    /// characters as the first, a control character at once; an empty box needs no message.
    func refresh() {
        guard let problem else {
            shownProblem = nil
            return
        }
        var hasControl = false
        for unit in password.utf16 where unit <= 0x1F || (unit >= 0x7F && unit <= 0x9F) {
            hasControl = true
            break
        }
        let show: Bool = !password.isEmpty && (hasControl || confirmation.count >= password.count)
        shownProblem = show ? problem : nil
    }

    /// Leaving the second box with something typed in it points out a difference, also a shorter one.
    func confirmationLeft() {
        guard !confirmation.isEmpty, let problem else { return }
        shownProblem = problem
    }

    /// Takes the password when it can be used (true), else says why (false).
    func save() -> Bool {
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
    func clear() {
        password = ""
        confirmation = ""
    }
}

/// Asks for the password of a protected PDF at save time, in a window of its own over the app (also
/// over a review sheet), as the Windows `PdfPasswordWindow` does: typed twice, with a hint about its
/// strength, and what PDF apps may let a reader do (print, copy), both allowed unless unticked.
/// `AppState.askPDFPassword` on the Mac (`AppState.makeForMac`).
enum PDFPasswordWindow {
    /// Shows the dialog until Save or Cancel; the protection given, or nil when cancelled.
    @MainActor
    static func ask() -> PDFProtection? {
        let form = PDFPasswordForm()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = PDFProtection.dialogTitle
        let view = PDFPasswordView(form: form,
                                   onSave: {
                                       if form.save() { NSApp.stopModal(withCode: .OK) }
                                   },
                                   onCancel: {
                                       NSApp.stopModal(withCode: .cancel)
                                   })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        let response: NSApplication.ModalResponse = NSApp.runModal(for: window)
        window.orderOut(nil)
        form.clear()
        return response == .OK ? form.protection : nil
    }
}

/// The dialog's content. Twin of the Windows PdfPasswordWindow.xaml.
struct PDFPasswordView: View {
    @ObservedObject var form: PDFPasswordForm
    let onSave: () -> Void
    let onCancel: () -> Void

    private enum Field: Hashable {
        case password
        case confirmation
    }

    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PDFProtection.dialogTitle)
                .font(.title3.weight(.semibold))
            // What can't be undone, and that it applies to every save from now on: always shown.
            Label(PDFProtection.dialogMessage, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(WarningLabelStyle())
                .padding(.top, 8)
                .padding(.bottom, 16)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(PDFProtection.dialogHelp))

            // The password is read from the boxes only when needed, and the boxes are emptied when the
            // dialog closes; it is never put in settings or anywhere else.
            Text("Password")
            SecureField("Password", text: $form.password)
                .labelsHidden()
                .focused($focus, equals: .password)
                .onSubmit { submit() }
            strengthRow
                .padding(.top, 6)

            Text("Confirm")
                .padding(.top, 12)
            SecureField("Confirm", text: $form.confirmation)
                .labelsHidden()
                .focused($focus, equals: .confirmation)
                .onSubmit { submit() }
            // Its line stays when there is no message, so the message appearing does not move the
            // checkboxes under it.
            Label(form.shownProblem ?? " ", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .opacity(form.shownProblem == nil ? 0 : 1)
                .accessibilityHidden(form.shownProblem == nil)
                .padding(.top, 6)

            // What PDF apps may let a reader do once the file is open: advisory, and said so.
            Toggle("Allow printing", isOn: $form.allowPrinting)
                .toggleStyle(.checkbox)
                .padding(.top, 16)
            Toggle("Allow copying", isOn: $form.allowCopying)
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text("Allow copying text and images"))
                .padding(.top, 4)
            Label(PDFProtection.permissionsShortNote, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(PDFProtection.permissionsNote)
                .accessibilityHint(Text(PDFProtection.permissionsNote))
                .padding(.top, 6)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.problem != nil)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focus = .password }
        .onChange(of: form.password) { _, _ in form.refresh() }
        .onChange(of: form.confirmation) { _, _ in form.refresh() }
        .onChange(of: focus) { previous, _ in
            if previous == .confirmation { form.confirmationLeft() }
        }
        .onChange(of: PDFProtection.strengthHint(form.strength)) { _, hint in
            // Screen readers hear a new hint when the strength changes, not at every key.
            if !hint.isEmpty { AccessibilityNotification.Announcement(hint).post() }
        }
        .onChange(of: form.shownProblem) { _, problem in
            if let problem { AccessibilityNotification.Announcement(problem).post() }
        }
    }

    /// Return in a box, or Save: saves when the password can be used, else shows why.
    private func submit() {
        onSave()
    }

    /// How hard the password is to guess: a bar of four segments and a few words; the full advice on
    /// hover and for screen readers. Nothing while the box is empty.
    @ViewBuilder
    private var strengthRow: some View {
        let strength: PasswordStrength = form.strength
        let label: String = PDFProtection.strengthLabel(strength)
        if !label.isEmpty {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index < PDFProtection.strengthSegments(strength) ? color(strength) : Color.secondary.opacity(0.3))
                            .frame(width: 21, height: 4)
                    }
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(PDFProtection.strengthHint(strength))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(PDFProtection.strengthHint(strength)))
        }
    }

    private func color(_ strength: PasswordStrength) -> Color {
        switch strength {
        case .weak: return .red
        case .fair: return .orange
        default: return .green
        }
    }
}

/// The warning's icon in the caution color, beside its text.
private struct WarningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .foregroundStyle(.orange)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
