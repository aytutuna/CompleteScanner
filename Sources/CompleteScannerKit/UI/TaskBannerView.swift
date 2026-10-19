import SwiftUI

/// The banner above the preview while a task is active or a stack is turned over by hand: the
/// task, what to do now, a way back to the start screen (`onChangeTask`) and a button that
/// leaves the task, keeping its settings (without a task: that scans one side again). Fronts
/// scanned without moving on to the backs (the feeder stopped early) offer Done with Fronts.
/// While the backs are due it offers keeping the fronts only and, before any back is scanned,
/// scanning more fronts; when the counts did not pair up, scanning the backs again or combining
/// the pages as they are. Twin of the Windows task banner (MainWindow.xaml).
struct TaskBannerView: View {
    @EnvironmentObject var state: AppState

    /// The active task; nil while a stack is turned over by hand without one.
    let definition: TaskDefinition?
    var onChangeTask: () -> Void

    /// Title of the banner that guides turning a stack over by hand without a task.
    static let turningOverTitle = "Two-sided scanning"

    private var name: String { definition?.title ?? Self.turningOverTitle }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: TaskSymbols.systemImage(definition?.iconKey ?? "twoSided"))
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.taskFlow?.current?.prompt ?? definition?.subtitle ?? DuplexMode.manual.hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.awaitingBacks || state.canFinishFronts {
                    sidesActions
                        .padding(.top, 4)
                }
                // The back of a card with nothing printed on it may be left out. (The backs of a stack
                // turned over by hand are left out with Keep Fronts Only.)
                if state.canSkipStep, let step = state.taskFlow?.current {
                    Button("Skip \(step.title.lowercased())") { state.skipStep() }
                        .controlSize(.small)
                        .disabled(state.isBusy)
                        .help("Nothing is printed on the back: save the front only")
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            Button {
                onChangeTask()
            } label: {
                Label("Change Task", systemImage: "square.grid.2x2")
            }
            .help("Pick another task on the start screen")
            Button {
                if definition != nil {
                    // Leaving the ID card task with a side scanned asks first.
                    let appState = state
                    appState.leaveIdCard { appState.exitTask() }
                } else {
                    state.scanOneSideOnly()
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            // Not while a scan runs: its result belongs to the task's steps.
            .disabled(state.isBusy)
            .help(exitHelp)
            .accessibilityLabel(exitLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bannerLabel)
    }

    private var exitHelp: String {
        definition != nil
            ? "Leave the task. Its settings stay, without the guidance."
            : "Stop turning stacks over by hand: scan one side of each sheet."
    }

    private var exitLabel: String { definition != nil ? "Leave the task" : "Scan one side only" }

    private var bannerLabel: String { definition != nil ? "Task: \(name)" : name }

    private var title: String {
        guard let flow = state.taskFlow, flow.stepCount > 1, let step = flow.current else {
            return name
        }
        return "\(name) \u{00B7} Step \(flow.stepIndex + 1) of \(flow.stepCount): \(step.title)"
    }

    /// Moving on from the fronts, the backs' choices, and the count mismatch ("3 fronts but 2
    /// backs") when there is one.
    private var sidesActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.awaitingBacks, let mismatch = state.sidesMismatch {
                Label("\(mismatch). Scan the rest of the back sides, scan them again, or combine the pages as they are.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if state.canFinishFronts {
                    Button("Done with Fronts") { state.finishFronts() }
                        .help("Every front side is scanned: turn the stack over and scan the back sides")
                }
                if state.awaitingBacks && state.sidesMismatch != nil {
                    Button("Combine Anyway") { state.combineSidesAnyway() }
                        .help("Put the pages in order as they are; the extra pages go at the end")
                    Button("Scan Back Sides Again") { state.scanBacksAgain() }
                        .help("Remove the back sides scanned so far and scan them again")
                }
                if state.canScanMoreFronts {
                    Button("Scan More Fronts") { state.scanMoreFronts() }
                        .help("The stack did not fit in the feeder: scan the fronts of the other sheets before turning it over")
                }
                if state.awaitingBacks {
                    Button("Keep Fronts Only") { state.keepFrontsOnly() }
                        .help("Leave out the back sides: the fronts stay as they are")
                }
            }
            .controlSize(.small)
            .disabled(state.isBusy)
        }
    }
}
