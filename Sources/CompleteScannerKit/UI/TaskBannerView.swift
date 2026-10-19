import SwiftUI

/// The banner above the preview while a task is active: the task, what to do now, a way back
/// to the start screen (`onChangeTask`) and a button that leaves the task, keeping its
/// settings. Twin of the Windows task banner (MainWindow.xaml).
struct TaskBannerView: View {
    @EnvironmentObject var state: AppState

    let definition: TaskDefinition
    var onChangeTask: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: TaskSymbols.systemImage(definition.iconKey))
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.taskFlow?.current?.prompt ?? definition.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                onChangeTask()
            } label: {
                Label("Change Task", systemImage: "square.grid.2x2")
            }
            .help("Pick another task on the start screen")
            Button {
                state.exitTask()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Leave the task. Its settings stay, without the guidance.")
            .accessibilityLabel("Leave the task")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task: \(definition.title)")
    }

    private var title: String {
        guard let flow = state.taskFlow, flow.stepCount > 1, let step = flow.current else {
            return definition.title
        }
        return "\(definition.title) \u{00B7} Step \(flow.stepIndex + 1) of \(flow.stepCount): \(step.title)"
    }
}
