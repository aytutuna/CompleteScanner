#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The iPhone's library, out of the capture path: the saved files or this session's scans, picked with a
/// segmented control in the navigation bar, and Settings in its toolbar (`onOpenSettings`, Command-comma).
/// The iPad's sidebar lists them on their own.
struct LibraryScreen: View {
    /// Opens Settings; nil where it is offered elsewhere.
    var onOpenSettings: (() -> Void)?
    @State private var part: LibraryPart = .saved

    var body: some View {
        Group {
            switch part {
            case .saved:
                SavedFilesScreen()
            case .history:
                HistoryScreen()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(IOSSettingsText.libraryLabel, selection: $part) {
                    Text(IOSSettingsText.savedLabel).tag(LibraryPart.saved)
                    Text(IOSSettingsText.historyLabel).tag(LibraryPart.history)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("library.part")
            }
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if let open = onOpenSettings {
            Button {
                open()
            } label: {
                Label(IOSSettingsText.title, systemImage: "gearshape")
            }
            .keyboardShortcut(IOSShortcuts.settings.keyboardShortcut)
            .accessibilityIdentifier("library.settings")
        }
    }
}

enum LibraryPart: Hashable {
    case saved
    case history
}
#endif
