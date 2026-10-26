#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The presets: each with its task's icon, its name and its settings in one line; tapping one puts its
/// settings in use and opens the scan screen (`onApplied`), whose title then names the preset's task as the
/// desktop's task banner does. Save preset saves the current settings under a name; a preset's menu (or a
/// swipe) renames or deletes it. With an ID card side held, applying asks to discard the card first, and a
/// preset that would leave the queued pages without a Save asks about them (`KeepPagesQuestion`); while an
/// import runs, none is applied.
struct PresetsScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    /// Runs once a preset's settings are in use.
    let onApplied: @MainActor () -> Void
    @State private var naming: PresetNaming = PresetNaming.new
    @State private var showsNaming: Bool = false
    @State private var name: String = ""
    @State private var askedToDiscard: Bool = false
    /// A preset that would leave the queued pages without a Save, while the question about them is up.
    @State private var leavingPages: PagesLeave?

    var body: some View {
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: importer)
        let rows: [IOSPresetRow] = model.rows
        List {
            Section {
                Button {
                    startSaving()
                } label: {
                    Label(IOSPresetText.saveLabel, systemImage: "plus")
                }
                .disabled(state.isBusy)
                .accessibilityHint(Text(IOSPresetText.saveLine))
                .accessibilityIdentifier("presets.save")
            }
            Section {
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(IOSPresetText.emptyTitle)
                            .font(.headline)
                        Text(IOSPresetText.emptyLine)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("presets.empty")
                }
                ForEach(rows) { (row: IOSPresetRow) in
                    presetRow(row, model: model)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(IOSPresetText.title)
        .alert(namingTitle, isPresented: $showsNaming) {
            TextField(IOSPresetText.namePlaceholder, text: $name)
                .accessibilityIdentifier("presets.name")
            Button(naming == .new ? IOSPresetText.saveLabel : IOSPresetText.renameLabel) {
                finishNaming(model)
            }
            .disabled(!IOSPresetsModel.isValidName(name))
            .accessibilityIdentifier("presets.name.save")
            Button("Cancel", role: .cancel) {}
        } message: {
            if naming == .new {
                Text(IOSPresetText.saveLine)
            }
        }
        .modifier(IdCardDiscardQuestion(state: state, asked: $askedToDiscard))
        .modifier(KeepPagesQuestion(state: state, leave: $leavingPages, blocked: importer.isImporting))
    }

    private func presetRow(_ row: IOSPresetRow, model: IOSPresetsModel) -> some View {
        let id: UUID = row.id
        return Button {
            apply(id, model: model)
        } label: {
            PresetRowLabel(row: row)
        }
        .disabled(state.isBusy || importer.isImporting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.accessibilityLabel))
        .accessibilityHint(Text(row.accessibilityHint))
        .accessibilityIdentifier("preset.\(row.name)")
        .contextMenu {
            Button {
                startRenaming(row)
            } label: {
                Label(IOSPresetText.renameLabel, systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.delete(id)
            } label: {
                Label(IOSPresetText.deleteLabel, systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.delete(id)
            } label: {
                Label(IOSPresetText.deleteLabel, systemImage: "trash")
            }
            Button {
                startRenaming(row)
            } label: {
                Label(IOSPresetText.renameLabel, systemImage: "pencil")
            }
        }
    }

    private var namingTitle: String {
        naming == .new ? IOSPresetText.saveTitle : IOSPresetText.renameTitle
    }

    private func startSaving() {
        name = ""
        naming = PresetNaming.new
        showsNaming = true
    }

    private func startRenaming(_ row: IOSPresetRow) {
        name = row.name
        naming = PresetNaming.rename(row.id)
        showsNaming = true
    }

    /// The alert's Save: what it was opened for is kept until the next one opens, whatever order SwiftUI
    /// runs the button and the dismissal in.
    private func finishNaming(_ model: IOSPresetsModel) {
        switch naming {
        case .new:
            model.save(named: name)
        case .rename(let id):
            model.rename(id, to: name)
        }
    }

    private func apply(_ id: UUID, model: IOSPresetsModel, discardingPages: Bool = false) {
        let done: @MainActor () -> Void = onApplied
        switch model.apply(id, discardingPages: discardingPages, then: done) {
        case .waitsForDiscard:
            askedToDiscard = true
        case .waitsForPages(let name):
            leavingPages = PagesLeave(reason: IOSShell.keepPagesReason(preset: name)) { (discarding: Bool) in
                apply(id, model: model, discardingPages: discarding)
            }
        case .applied, .refused:
            break
        }
    }
}

/// What the name alert is for: a new preset, or renaming one.
private enum PresetNaming: Equatable {
    case new
    case rename(UUID)
}

/// A preset's row: its task's icon, its name, and the task and settings in one line.
private struct PresetRowLabel: View {
    let row: IOSPresetRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text("\(row.taskTitle) \u{00B7} \(row.summary)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Discard the ID card? Asked where something that ends the ID card task was asked for (a preset or a task
/// picked) while a side of the card is held and not saved (`AppState.pendingIdCardLeave`);
/// only by the screen that asked (`asked`), so a screen behind it never answers for it. Discard drops the card
/// and goes on. What was asked for is taken when the alert opens, as on the Mac: the alert's dismissal clears
/// it, and SwiftUI may run that before the button.
struct IdCardDiscardQuestion: ViewModifier {
    @ObservedObject var state: AppState
    @Binding var asked: Bool

    func body(content: Content) -> some View {
        content
            .alert(IOSPresetText.discardTitle, isPresented: shown,
                   presenting: state.pendingIdCardLeave) { (leave: IdCardLeave) in
                Button(IOSPresetText.discardLabel, role: .destructive) {
                    discard(leave)
                }
                Button("Cancel", role: .cancel) {}
            } message: { (_: IdCardLeave) in
                Text(IOSPresetText.discardLine)
            }
    }

    private var shown: Binding<Bool> {
        let appState: AppState = state
        let question: Binding<Bool> = $asked
        return Binding<Bool>(
            get: { question.wrappedValue && appState.pendingIdCardLeave != nil },
            set: { (isShown: Bool) in
                if !isShown {
                    question.wrappedValue = false
                    appState.pendingIdCardLeave = nil
                }
            })
    }

    private func discard(_ leave: IdCardLeave) {
        state.discardIdCard(andThen: leave)
        asked = false
    }
}
#endif
