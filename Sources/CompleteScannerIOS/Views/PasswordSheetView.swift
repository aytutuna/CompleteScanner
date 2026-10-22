#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The password sheet of a protected PDF (`IOSPasswordPrompt`): what can't be undone, always shown; the
/// password twice in secure fields, with the strength bar and its word as it is typed (the full advice for
/// VoiceOver, said when it changes) and the problem with what is typed; what a reader may do with the file
/// (advisory, and said so); Cancel and Save. Twin of the Mac's `PDFPasswordView`.
struct PasswordSheetView: View {
    @ObservedObject var form: IOSPasswordForm
    let onSave: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    private enum Field: Hashable {
        case password
        case confirmation
    }

    @FocusState private var focus: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(PDFProtection.dialogMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.primary)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(Text(PDFProtection.dialogHelp))
                }
                Section {
                    SecureField("Password", text: $form.password)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit {
                            focus = .confirmation
                        }
                        .accessibilityIdentifier("password.field")
                    strengthRow
                    SecureField("Confirm", text: $form.confirmation)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .confirmation)
                        .submitLabel(.done)
                        .onSubmit {
                            onSave()
                        }
                        .accessibilityIdentifier("password.confirm")
                    if let problem = form.shownProblem {
                        Label(problem, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Color.red)
                            .font(.callout)
                            .accessibilityIdentifier("password.problem")
                    }
                }
                Section {
                    Toggle("Allow printing", isOn: $form.allowPrinting)
                    Toggle("Allow copying", isOn: $form.allowCopying)
                        .accessibilityLabel(Text("Allow copying text and images"))
                } footer: {
                    Text(PDFProtection.permissionsShortNote)
                        .accessibilityHint(Text(PDFProtection.permissionsNote))
                }
            }
            .navigationTitle(PDFProtection.dialogTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .accessibilityIdentifier("password.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(!form.canSave)
                    .accessibilityIdentifier("password.save")
                }
            }
        }
        .onAppear {
            focus = .password
        }
        .onChange(of: form.password) { (_: String, _: String) in
            form.refresh()
        }
        .onChange(of: form.confirmation) { (_: String, _: String) in
            form.refresh()
        }
        .onChange(of: focus) { (previous: Field?, _: Field?) in
            if previous == .confirmation {
                form.confirmationLeft()
            }
        }
        .onChange(of: form.strengthHint) { (_: String, hint: String) in
            // VoiceOver hears a new hint when the strength changes, not at every key.
            if !hint.isEmpty {
                AccessibilityNotification.Announcement(hint).post()
            }
        }
    }

    /// How hard the password is to guess: a bar of four segments and a word; nothing while the box is empty.
    @ViewBuilder
    private var strengthRow: some View {
        let label: String = form.strengthLabel
        if !label.isEmpty {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { (index: Int) in
                        Capsule()
                            .fill(index < form.strengthSegments ? color : Color.secondary.opacity(0.3))
                            .frame(width: 24, height: 4)
                    }
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(form.strengthHint))
            .accessibilityIdentifier("password.strength")
        }
    }

    private var color: Color {
        switch form.strength {
        case .weak:
            return Color.red
        case .fair:
            return Color.orange
        default:
            return Color.green
        }
    }
}
#endif
