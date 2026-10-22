#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// This session's scans, newest first, as small pictures with their mode, resolution and time
/// (`IOSHistory`); tapping one shows it larger. Read-only, as on the desktop: the pages themselves are in
/// the page strip, the reviews and the saved files.
struct HistoryScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var enlarged: UUID?

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 12, alignment: .top)]

    var body: some View {
        let rows: [IOSHistoryRow] = IOSHistory.rows(state.scanHistory, now: Date())
        Group {
            if rows.isEmpty {
                ContentUnavailableView(IOSHistory.emptyTitle, systemImage: "clock.arrow.circlepath",
                                       description: Text(IOSHistory.emptyLine))
                    .accessibilityIdentifier("history.empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(IOSHistory.countText(rows.count))
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .accessibilityIdentifier("history.count")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(rows) { (row: IOSHistoryRow) in
                                card(row)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(IOSHistory.title)
        .sheet(item: enlargedRow(rows)) { (row: IOSHistoryRow) in
            HistoryEnlarged(row: row, onClose: closeEnlarged)
        }
    }

    private func card(_ row: IOSHistoryRow) -> some View {
        let id: UUID = row.id
        return Button {
            enlarged = id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(decorative: row.thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Label(row.title, systemImage: row.symbol)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(row.time)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.accessibilityLabel))
        .accessibilityHint(Text("Shows it larger"))
        .accessibilityIdentifier("history.scan")
    }

    /// The scan shown larger, while it is still in the history.
    private func enlargedRow(_ rows: [IOSHistoryRow]) -> Binding<IOSHistoryRow?> {
        let shown: UUID? = enlarged
        var match: IOSHistoryRow?
        for row in rows where row.id == shown {
            match = row
        }
        let found: IOSHistoryRow? = match
        return Binding<IOSHistoryRow?>(
            get: { found },
            set: { (row: IOSHistoryRow?) in
                if row == nil {
                    enlarged = nil
                }
            })
    }

    private func closeEnlarged() {
        enlarged = nil
    }
}

/// One scan larger, with all it is in one line.
private struct HistoryEnlarged: View {
    let row: IOSHistoryRow
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(decorative: row.thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(Text(row.accessibilityLabel))
                Text(row.accessibilityLabel)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle(row.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
#endif
