#if os(macOS)
import AppKit
import CompleteScannerKit
import SwiftUI

/// SF Symbols for the task icons (`TaskDefinition.iconKey`); the Windows app maps the same
/// keys to Segoe Fluent Icons glyphs.
enum TaskSymbols {
    static func systemImage(_ iconKey: String) -> String {
        switch iconKey {
        case "document": return "doc.text"
        case "feeder": return "doc.on.doc"
        case "photos": return "photo.on.rectangle.angled"
        case "restore": return "wand.and.stars"
        case "quick": return "bolt"
        case "email": return "envelope"
        case "twoSided": return "arrow.left.arrow.right.square"
        case "idCard": return "person.text.rectangle"
        case "copy": return "printer"
        case "word": return "doc.richtext"
        case "receipt": return "receipt"
        case "batch": return "square.stack.3d.down.right"
        case "book": return "book"
        case "archive": return "archivebox"
        default: return "scanner"
        }
    }
}

/// The start screen: what are you scanning? The user's presets first (when there are any), then one
/// tile per task (`TaskCatalog.sections`) in its group: an icon and the title. What the task does and
/// what it sets are the tile's help; a task the connected scanner cannot do is dimmed with one short
/// line saying why. Picking a tile sets it up and opens the scanner view (`onOpenScanner`). After the
/// tasks comes "Add pages to a PDF" (`addPagesTile`). Twin of the Windows `TaskStartView`.
struct TaskStartView: View {
    @EnvironmentObject var state: AppState

    /// Opens the scanner view (after a tile was set up, or for "Go to Scanner").
    var onOpenScanner: () -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !state.presets.isEmpty {
                    groupHeading("My presets")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(state.presets) { preset in
                            presetTile(preset)
                        }
                    }
                }
                ForEach(groups, id: \.group) { group in
                    groupHeading(group.group.title)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(group.cards) { card in
                            taskTile(card)
                        }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    addPagesTile
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text("Picking a task sets everything up. You can change any setting later."))
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// The tasks' tiles in their groups, in start-screen order.
    private var groups: [TaskTileGroup] {
        let cards: [TaskCard] = state.taskCards
        return TaskCatalog.sections.map { (section: TaskGroupSection) -> TaskTileGroup in
            let tiles: [TaskCard] = section.definitions.compactMap { (definition: TaskDefinition) -> TaskCard? in
                cards.first(where: { $0.definition.task == definition.task })
            }
            return TaskTileGroup(group: section.group, cards: tiles)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("What are you scanning?")
                .font(.largeTitle.weight(.semibold))
            Spacer(minLength: 0)
            Button {
                onOpenScanner()
            } label: {
                Label("Go to Scanner", systemImage: "scanner")
            }
            .help("Scan with your current settings")
        }
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func taskTile(_ card: TaskCard) -> some View {
        let available: Bool = card.availability.isAvailable
        let subtitle: String = card.definition.subtitle
        let help: String = subtitle + "\n" + card.summary
        let reason: String = card.availability.reason ?? ""
        let hint: String = available ? "\(subtitle) \(card.summary)." : "\(subtitle) \(card.summary). Not available: \(reason)"
        return Button {
            // Picking a task while the ID card task holds a side asks first.
            let appState = state
            let openScanner = onOpenScanner
            let task = card.definition.task
            appState.leaveIdCard {
                if appState.startTask(task) {
                    appState.clearAppendTarget()
                    openScanner()
                }
            }
        } label: {
            TaskTileLabel(symbol: TaskSymbols.systemImage(card.definition.iconKey),
                          title: card.definition.title,
                          reason: available ? nil : reason,
                          isCurrent: card.isCurrent)
        }
        .buttonStyle(TaskCardButtonStyle())
        .disabled(!available || state.isBusy)
        .help(help)
        .accessibilityLabel(Text(card.definition.title))
        .accessibilityHint(Text(hint))
    }

    /// "Add pages to a PDF" is not a task of the catalog: the PDF is picked first, then Document to PDF
    /// is set up with it as the append target, so Save adds the pages scanned next to its end.
    private var addPagesTile: some View {
        let title = "Add pages to a PDF"
        let subtitle = "Pick a PDF, then scan the pages to add"
        return Button {
            // The file first: cancelling the panel keeps a held ID card side.
            let appState = state
            let openScanner = onOpenScanner
            guard let url = appState.choosePDFForAppend(prompt: "Choose") else { return }
            appState.leaveIdCard {
                if appState.startTask(.document) {
                    appState.setAppendTarget(url)
                    openScanner()
                }
            }
        } label: {
            TaskTileLabel(symbol: "doc.badge.plus", title: title, reason: nil, isCurrent: false)
        }
        .buttonStyle(TaskCardButtonStyle())
        .disabled(state.isBusy)
        .help(subtitle)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }

    private func presetTile(_ preset: Preset) -> some View {
        let task: ScanTask = TaskCatalog.infer(preset.settings)
        let taskTitle: String = TaskCatalog.definition(task).title
        let summary: String = TaskCatalog.summary(preset.settings)
        return Button {
            guard !state.isBusy else { return }
            let appState = state
            let openScanner = onOpenScanner
            appState.leaveIdCard {
                appState.applyPreset(preset)
                appState.clearAppendTarget()
                openScanner()
            }
        } label: {
            TaskTileLabel(symbol: TaskSymbols.systemImage(TaskCatalog.definition(task).iconKey),
                          title: preset.name,
                          reason: nil,
                          isCurrent: false)
        }
        .buttonStyle(TaskCardButtonStyle())
        .disabled(state.isBusy)
        .help(taskTitle + "\n" + summary)
        .accessibilityLabel(Text("\(preset.name) preset"))
        .accessibilityHint(Text("Preset for \(taskTitle). \(summary)."))
    }
}

/// A group of the start screen with its tiles.
private struct TaskTileGroup {
    let group: TaskGroup
    let cards: [TaskCard]
}

/// The inside of a start-screen tile: the icon, the title (two lines at most, never cut), and for a
/// task that cannot be started, one line saying why.
private struct TaskTileLabel: View {
    let symbol: String
    let title: String
    let reason: String?
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .opacity(reason == nil ? 1 : 0.4)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                }
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A whole-tile button: card surface, hairline border, pressed feedback.
private struct TaskCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(configuration.isPressed ? 0.5 : 0.22), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
#endif
