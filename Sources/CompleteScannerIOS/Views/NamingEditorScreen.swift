#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The file name: the template as typed, a button for each part it can be built from (Date, Time, Number,
/// Mode, Task, Document name, Receipt date: `NamingTokens.all`, each put at the end with its token), the
/// name the next file gets, and what is wrong with the template (a blank one keeps the last name in use).
struct NamingEditorScreen: View {
    @StateObject private var model: IOSNamingModel

    init(model: IOSNamingModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Form {
            Section {
                TextField(IOSNamingModel.title, text: text)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("naming.field")
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                        .accessibilityIdentifier("naming.problem")
                }
                LabeledContent(IOSNamingModel.exampleLabel) {
                    Text(model.example)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("naming.example")
                }
            }
            Section(IOSNamingModel.insertTitle) {
                ForEach(model.parts, id: \.token) { (part: NamingToken) in
                    Button {
                        model.insert(part.token)
                    } label: {
                        LabeledContent(part.label) {
                            Text(part.token)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .accessibilityHint(Text(part.help))
                    .accessibilityIdentifier("naming.insert.\(part.token)")
                }
            }
            Section {
                Button(IOSNamingModel.resetLabel) {
                    model.reset()
                }
                .accessibilityIdentifier("naming.reset")
            }
        }
        .navigationTitle(IOSNamingModel.title)
    }

    private var text: Binding<String> {
        let naming: IOSNamingModel = model
        return Binding<String>(
            get: { naming.text },
            set: { (newText: String) in
                naming.setText(newText)
            })
    }
}
#endif
