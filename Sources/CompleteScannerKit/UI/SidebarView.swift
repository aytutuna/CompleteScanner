import SwiftUI

/// Left column: the list of discovered scanner devices.
struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: deviceSelection) {
            Section("Scanners") {
                ForEach(state.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                }
                if !hasRealDevices {
                    Text("No scanners found — check the connection/power, or pick Demo Scanner…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footerHint
        }
        .toolbar {
            Button {
                state.start()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Look for scanners again")
        }
    }

    // MARK: Helpers

    /// Selection is owned by AppState: the setter routes through `userSelectDevice`
    /// so the model can distinguish user picks from automatic ones.
    private var deviceSelection: Binding<String?> {
        Binding(
            get: { state.selectedDeviceID },
            set: { state.userSelectDevice($0) }
        )
    }

    private var hasRealDevices: Bool {
        state.devices.contains { !$0.isDemo }
    }

    private var footerHint: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("If a USB scanner isn't listed, install the manufacturer's macOS driver.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
    }
}

// MARK: - Row

private struct DeviceRow: View {
    let device: ScannerInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.isDemo ? "sparkles.rectangle.stack" : "scanner")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if device.isDemo {
                        Text("Demo")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(device.transport)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
