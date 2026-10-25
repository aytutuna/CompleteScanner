#if os(iOS)
import CompleteScannerKit
import SwiftUI
import UniformTypeIdentifiers

/// The task list: what are you scanning? On the iPhone the task sheet over our camera (`TaskSheet`; the scan
/// screen has the kinds as chips in its top row), on the iPad the detail beside the sidebar. The user's presets first (when there are any, as on the
/// Mac), then one tile per kind (`IOSScanKind`: Document, Photos, Receipts, ID card, Book, Text): an icon,
/// the title and the one-line subtitle; the feeder, both sides, the format and the rest are the scan
/// screen's Options and Save's menu. A kind whose task cannot be started (no feeder or flatbed,
/// `IOSShell.availability`) is dimmed with one short line saying why. Picking a tile starts the kind's
/// task (or sets the preset's settings) up and opens the scan screen (`onOpenScanner`); not while an
/// import runs, whose pages belong to the task set up. With a side of an ID card held, either kind of
/// tile asks to discard the card first (`IdCardDiscardQuestion`). After the kinds, "Add pages to a PDF"
/// (`IOSAppendTile`) picks a PDF in Files first, then sets up Document to PDF with that file as the append
/// target, so Save adds the pages to it.
struct TaskStartScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    /// Opens the scan screen (after a tile was set up, or for the Scanner button).
    let onOpenScanner: @MainActor () -> Void
    /// Closes the task sheet (iPhone): Done in place of the Scanner button.
    var onClose: (() -> Void)?
    @State private var askedToDiscard: Bool = false
    /// Files is open to pick the PDF for "Add pages to a PDF".
    @State private var picksPDF: Bool = false

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        let tiles: [IOSKindTile] = IOSShell.kindTiles(state.taskCards, current: IOSShell.shownKind(state.settings))
        let presets: [IOSPresetRow] = IOSPresetsModel.rows(state.presets)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !presets.isEmpty {
                    Text(IOSPresetText.groupTitle)
                        .font(.headline)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(presets) { (row: IOSPresetRow) in
                            presetButton(row)
                        }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(tiles) { (tile: IOSKindTile) in
                        tileButton(tile)
                    }
                    appendButton(IOSAppendTile.availability(state.taskCards))
                }
                .padding(.top, presets.isEmpty ? 0 : 8)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("What are you scanning?")
        .modifier(IdCardDiscardQuestion(state: state, asked: $askedToDiscard))
        .fileImporter(isPresented: $picksPDF, allowedContentTypes: [UTType.pdf]) { (result: Result<URL, Error>) in
            switch result {
            case .success(let url):
                // The URL as Files gives it: its security scope is opened when the pages are added.
                pick(.document, target: url)
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let close = onClose {
                    Button(IOSSettingsText.doneLabel) {
                        close()
                    }
                    .accessibilityIdentifier("tasks.done")
                } else {
                    Button {
                        onOpenScanner()
                    } label: {
                        Label("Scanner", systemImage: "scanner")
                    }
                    .accessibilityIdentifier("open.scanner")
                }
            }
        }
    }

    private func tileButton(_ tile: IOSKindTile) -> some View {
        let kind: IOSScanKind = tile.kind
        let available: Bool = tile.availability.isAvailable
        let reason: String = tile.availability.reason ?? ""
        let hint: String = available ? "\(kind.subtitle). \(tile.summary)." : "\(kind.subtitle). Not available: \(reason)"
        return Button {
            pick(kind.task)
        } label: {
            TaskTileLabel(symbol: kind.symbol, title: kind.title, subtitle: kind.subtitle,
                          availability: tile.availability, isCurrent: tile.isCurrent)
        }
        .buttonStyle(TaskTileButtonStyle())
        .disabled(!available || state.isBusy || importer.isImporting)
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(Text(tile.accessibilityValue))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("task.\(kind.rawValue)")
    }

    private func appendButton(_ availability: TaskAvailability) -> some View {
        let available: Bool = availability.isAvailable
        let hint: String = available ? IOSAppendTile.subtitle
            : "\(IOSAppendTile.subtitle) Not available: \(availability.reason ?? "")"
        return Button {
            picksPDF = true
        } label: {
            TaskTileLabel(symbol: IOSAppendTile.symbol, title: IOSAppendTile.title, subtitle: IOSAppendTile.subtitle,
                          availability: availability, isCurrent: false)
        }
        .buttonStyle(TaskTileButtonStyle())
        .disabled(!available || state.isBusy || importer.isImporting)
        .accessibilityLabel(Text(IOSAppendTile.title))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("task.appendToPDF")
    }

    /// Picking a task ends the ID card task, so with a side of the card held it asks first, as a preset does.
    /// Any other tile ends adding to a picked PDF.
    private func pick(_ task: ScanTask, target: URL? = nil) {
        let appState: AppState = state
        let open: @MainActor () -> Void = onOpenScanner
        state.leaveIdCard {
            if appState.startTask(task) {
                if let target {
                    appState.setAppendTarget(target)
                } else {
                    appState.clearAppendTarget()
                }
                open()
            }
        }
        if state.pendingIdCardLeave != nil {
            askedToDiscard = true
        }
    }

    /// A preset's tile: its task's icon and its name, the task and settings for VoiceOver.
    private func presetButton(_ row: IOSPresetRow) -> some View {
        let id: UUID = row.id
        return Button {
            applyPreset(id)
        } label: {
            PresetTileLabel(row: row)
        }
        .buttonStyle(TaskTileButtonStyle())
        .disabled(state.isBusy || importer.isImporting)
        .accessibilityLabel(Text(row.accessibilityLabel))
        .accessibilityHint(Text(row.accessibilityHint))
        .accessibilityIdentifier("start.preset.\(row.name)")
    }

    private func applyPreset(_ id: UUID) {
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: importer)
        let open: @MainActor () -> Void = onOpenScanner
        let applied: IOSPresetApply = model.apply(id) {
            open()
        }
        if applied == IOSPresetApply.waitsForDiscard {
            askedToDiscard = true
        }
    }
}

/// The task list in a sheet over our camera on the iPhone, half height first: picking a tile or a preset
/// sets it up and closes the sheet (`onPicked`); Done closes it as it was.
struct TaskSheet: View {
    @EnvironmentObject private var state: AppState
    let onPicked: @MainActor () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            TaskStartScreen(onOpenScanner: onPicked, onClose: onClose)
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        // The root's alert cannot show over a sheet.
        .modifier(ErrorAlert(state: state))
    }
}

/// The kind set up (`IOSShell.shownKind`) under our camera's top bar, white on a dark capsule: its title
/// with a chevron; it opens the task sheet.
struct TaskChip: View {
    let title: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Task: \(title)"))
        .accessibilityHint(Text("Opens the list of tasks"))
        .accessibilityIdentifier("task.chip")
    }
}

/// The inside of a preset's tile: its task's icon, its name, and the task it brings back.
private struct PresetTileLabel: View {
    let row: IOSPresetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: row.symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text(row.name)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.taskTitle)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The inside of a tile: the icon (with "Current" for the task set up now), the title, the subtitle,
/// and for a task that cannot be started, why.
private struct TaskTileLabel: View {
    let symbol: String
    let title: String
    let subtitle: String
    let availability: TaskAvailability
    let isCurrent: Bool

    var body: some View {
        let available: Bool = availability.isAvailable
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .opacity(available ? 1 : 0.4)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                }
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(available ? Color.primary : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(available ? subtitle : (availability.reason ?? ""))
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The start screen's "Add pages to a PDF": not a task of the catalog but Document to PDF with a PDF picked
/// first (`AppState.setAppendTarget`), so it can be picked when Document to PDF can.
enum IOSAppendTile {
    static let title = "Add pages to a PDF"
    static let subtitle = "Pick a PDF, then scan the pages to add"
    static let symbol = "doc.badge.plus"

    static func availability(_ cards: [TaskCard]) -> TaskAvailability {
        guard let card = cards.first(where: { (candidate: TaskCard) -> Bool in
            candidate.definition.task == .document
        }) else {
            return TaskAvailability(isAvailable: false, reason: IOSShell.notYetReason)
        }
        return IOSShell.availability(card)
    }
}

/// A whole-tile button: card surface, hairline border, pressed feedback.
private struct TaskTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(configuration.isPressed ? 0.5 : 0.2), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
#endif
