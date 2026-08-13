import AppKit
import SwiftUI

/// The "Scans" tab: every scan of this session, newest first, as preview cards.
/// History holds small previews only — full pixels live in the page queue / photo
/// review / saved files.
struct ScanHistoryView: View {
    @EnvironmentObject var state: AppState

    @State private var enlarged: ScanHistoryEntry?

    var body: some View {
        Group {
            if state.scanHistory.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                        ForEach(state.scanHistory) { entry in
                            card(for: entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: $enlarged) { entry in
            enlargedView(entry)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No scans yet this session")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Every scan appears here as it happens.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private func card(for entry: ScanHistoryEntry) -> some View {
        VStack(spacing: 8) {
            Image(decorative: entry.thumbnail, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .onTapGesture { enlarged = entry }

            Text("\(entry.intent.label) · \(entry.dpi) dpi")
                .font(.caption)
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private func enlargedView(_ entry: ScanHistoryEntry) -> some View {
        VStack(spacing: 12) {
            Image(decorative: entry.thumbnail, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
            HStack {
                Text("\(entry.intent.label) · \(entry.dpi) dpi · \(Int(entry.pixelSize.width)) × \(Int(entry.pixelSize.height)) px · \(entry.date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { enlarged = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 760, minHeight: 460, idealHeight: 640)
    }
}
