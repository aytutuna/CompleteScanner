#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// The scan screen: the task's step, the scanner, the last scan, the page strip, the status line,
/// and Scan and Save; once saved, the saved file with Share and Show in Files.
struct ScanScreen: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stepCard
                    scannerRow
                    PreviewArea(image: state.canvasImage)
                }
                .padding(16)
            }
            Divider()
            PageStripView()
            Divider()
            bottomBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(state.activeTaskDefinition?.title ?? "Scanner")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The current step's one-line prompt, with its fuller help below.
    @ViewBuilder
    private var stepCard: some View {
        if let step = state.taskFlow?.current {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.prompt)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.help)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("step.prompt")
        }
    }

    /// The scanner in use, with the others to pick from.
    private var scannerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "scanner")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Menu {
                ForEach(state.devices) { (device: ScannerInfo) in
                    Button(device.name) {
                        state.userSelectDevice(device.id)
                    }
                }
            } label: {
                Text(deviceName)
                    .lineLimit(1)
            }
            .disabled(state.isBusy)
            .accessibilityLabel(Text("Scanner: \(deviceName)"))
            .accessibilityIdentifier("scanner.menu")
            Spacer(minLength: 0)
            if state.isBusy {
                ProgressView()
                    .accessibilityIdentifier("busy")
            }
        }
    }

    private var deviceName: String {
        let selected: String? = state.selectedDeviceID
        let device: ScannerInfo? = state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })
        return device?.name ?? "No scanner"
    }

    /// Scan once the scanner is connected and nothing else runs.
    private var canScan: Bool {
        state.capabilities != nil && !state.isBusy
    }

    private var bottomBar: some View {
        let options: DocumentOptions = state.settings.document
        let plan: SavePlan = SavePlan.make(state.scannedPages, options: options)
        let saveTitle: String = plan.saveTitle(state.settings.format)
        let saveCount: Int = plan.pageCount
        return VStack(alignment: .leading, spacing: 10) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .accessibilityLabel(Text(state.statusMessage))
                .accessibilityIdentifier("status.line")
            if !state.lastSavedURLs.isEmpty && !state.isBusy {
                SavedFilesRow()
            }
            HStack(spacing: 12) {
                if state.isBusy {
                    Button(role: .cancel) {
                        state.cancelScan()
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel.button")
                }
                Button {
                    state.performScan()
                } label: {
                    Text(state.primaryActionLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canScan)
                .accessibilityIdentifier("scan.button")
                Button {
                    state.savePDF()
                } label: {
                    Text(saveTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy || saveCount == 0)
                .accessibilityIdentifier("save.button")
            }
        }
        .padding(16)
    }

    /// The status in six words at most (`StatusLine.shown`), as on the Mac's status bar.
    private var statusText: String {
        let idle: Bool = !state.isBusy
        let selected: String? = state.selectedDeviceID
        let device: String? = state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })?.name
        let savedShown: Bool = idle && !state.lastSavedURLs.isEmpty
        return StatusLine.shown(state.statusMessage, deviceName: device, reviewShown: false, savedShown: savedShown)
    }
}

/// The last scan (or "No scan yet").
private struct PreviewArea: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .accessibilityLabel(Text("Last scan"))
                    .accessibilityIdentifier("last.scan")
            } else {
                Text("No scan yet")
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }
}

/// The files saved last, with Share and Show in Files.
private struct SavedFilesRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let urls: [URL] = state.lastSavedURLs
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)
            Text(savedNames(urls))
                .font(.subheadline)
                .lineLimit(2)
                .accessibilityIdentifier("saved.files")
            Spacer(minLength: 0)
            Button {
                state.runFileAction(.share, urls: urls)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("share.button")
            Button {
                state.runFileAction(.reveal, urls: urls)
            } label: {
                Label("Show in Files", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(Text("Show in Files"))
            .accessibilityIdentifier("reveal.button")
        }
    }

    private func savedNames(_ urls: [URL]) -> String {
        var names: [String] = []
        for url in urls {
            names.append(url.lastPathComponent)
        }
        return names.joined(separator: ", ")
    }
}
#endif
