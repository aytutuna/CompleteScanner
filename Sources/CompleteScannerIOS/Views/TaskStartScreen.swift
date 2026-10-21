#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The start screen: what are you scanning? One tile per task (`TaskCatalog.sections`) in its group:
/// an icon, the title and the one-line subtitle. A task that cannot be started (no feeder, or not in
/// this version yet, `IOSShell.availability`) is dimmed with one short line saying why. Picking a
/// tile sets the task up and opens the scan screen (`onOpenScanner`); not while an import runs, whose
/// pages belong to the task set up.
struct TaskStartScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    /// Opens the scan screen (after a tile was set up, or for the Scanner button).
    let onOpenScanner: @MainActor () -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        let groups: [IOSTaskGroup] = IOSShell.groups(state.taskCards)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { (group: IOSTaskGroup) in
                    Text(group.title)
                        .font(.headline)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(group.tiles) { (tile: IOSTaskTile) in
                            tileButton(tile)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("What are you scanning?")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onOpenScanner()
                } label: {
                    Label("Scanner", systemImage: "scanner")
                }
                .accessibilityIdentifier("open.scanner")
            }
        }
    }

    private func tileButton(_ tile: IOSTaskTile) -> some View {
        let available: Bool = tile.availability.isAvailable
        let reason: String = tile.availability.reason ?? ""
        let hint: String = available ? "\(tile.subtitle) \(tile.summary)." : "\(tile.subtitle) Not available: \(reason)"
        return Button {
            pick(tile.task)
        } label: {
            TaskTileLabel(tile: tile)
        }
        .buttonStyle(TaskTileButtonStyle())
        .disabled(!available || state.isBusy || importer.isImporting)
        .accessibilityLabel(Text(tile.title))
        .accessibilityValue(Text(tile.accessibilityValue))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("task.\(tile.task.rawValue)")
    }

    private func pick(_ task: ScanTask) {
        if state.startTask(task) {
            onOpenScanner()
        }
    }
}

/// The inside of a tile: the icon (with "Current" for the task set up now), the title, the subtitle,
/// and for a task that cannot be started, why.
private struct TaskTileLabel: View {
    let tile: IOSTaskTile

    var body: some View {
        let available: Bool = tile.availability.isAvailable
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .opacity(available ? 1 : 0.4)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if tile.isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                }
            }
            Text(tile.title)
                .font(.headline)
                .foregroundStyle(available ? Color.primary : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(available ? tile.subtitle : (tile.availability.reason ?? ""))
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
