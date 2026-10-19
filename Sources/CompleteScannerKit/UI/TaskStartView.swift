import AppKit
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
        default: return "scanner"
        }
    }
}

/// The start screen: what are you scanning? One card per task (`TaskCatalog`), greyed out
/// with the reason when the connected scanner cannot do it, then the user's presets badged
/// with their task. Picking a card sets it up and opens the scanner view (`onOpenScanner`).
/// Twin of the Windows `TaskStartView`.
struct TaskStartView: View {
    @EnvironmentObject var state: AppState

    /// Opens the scanner view (after a card was set up, or for "Go to Scanner").
    var onOpenScanner: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text("Tasks")
                    .font(.headline)
                    .padding(.top, 8)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(state.taskCards) { card in
                        taskCard(card)
                    }
                }
                Text("My presets")
                    .font(.headline)
                    .padding(.top, 12)
                if state.presets.isEmpty {
                    Text("Settings you save as a preset (Presets \u{25B8} Save current as preset\u{2026} in the scan settings) appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(state.presets) { preset in
                            presetCard(preset)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What are you scanning?")
                    .font(.largeTitle.weight(.semibold))
                Text("Pick a task and everything is set up for it. Every setting can still be changed in the scanner view.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                onOpenScanner()
            } label: {
                Label("Go to Scanner", systemImage: "scanner")
            }
            .help("Open the scanner view with the settings as they are")
        }
    }

    private func taskCard(_ card: TaskCard) -> some View {
        let available = card.availability.isAvailable
        let hint: String = available
            ? "\(card.definition.subtitle) \(card.summary)."
            : "\(card.definition.subtitle) Not available: \(card.availability.reason ?? "")"
        return Button {
            // Picking a task while the ID card task holds a side asks first.
            let appState = state
            let openScanner = onOpenScanner
            let task = card.definition.task
            appState.leaveIdCard {
                if appState.startTask(task) { openScanner() }
            }
        } label: {
            TaskCardLabel(symbol: TaskSymbols.systemImage(card.definition.iconKey),
                          title: card.definition.title,
                          subtitle: card.definition.subtitle,
                          footer: card.availability.reason ?? card.summary,
                          footerIsReason: !available,
                          isCurrent: card.isCurrent)
        }
        .buttonStyle(TaskCardButtonStyle())
        .opacity(available ? 1 : 0.55)
        .disabled(!available || state.isBusy)
        .help(card.availability.reason ?? card.definition.subtitle)
        .accessibilityLabel(Text(card.definition.title))
        .accessibilityHint(Text(hint))
    }

    private func presetCard(_ preset: Preset) -> some View {
        let task = TaskCatalog.infer(preset.settings)
        let taskTitle = TaskCatalog.definition(task).title
        let hint = "Preset for \(taskTitle). \(TaskCatalog.summary(preset.settings))."
        return Button {
            guard !state.isBusy else { return }
            let appState = state
            let openScanner = onOpenScanner
            appState.leaveIdCard {
                appState.applyPreset(preset)
                openScanner()
            }
        } label: {
            TaskCardLabel(symbol: TaskSymbols.systemImage(TaskCatalog.definition(task).iconKey),
                          title: preset.name,
                          subtitle: taskTitle,
                          footer: TaskCatalog.summary(preset.settings),
                          footerIsReason: false,
                          isCurrent: false)
        }
        .buttonStyle(TaskCardButtonStyle())
        .disabled(state.isBusy)
        .help(preset.name)
        .accessibilityLabel(Text(preset.name))
        .accessibilityHint(Text(hint))
    }
}

/// The inside of a start-screen card: icon, title, description and a footer line.
private struct TaskCardLabel: View {
    let symbol: String
    let title: String
    let subtitle: String
    let footer: String
    let footerIsReason: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
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
                .padding(.top, 6)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if footerIsReason {
                    Image(systemName: "info.circle")
                }
                Text(footer)
                    .lineLimit(2)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A whole-card button: card surface, hairline border, pressed feedback.
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
