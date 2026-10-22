#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The iPhone's library, out of the capture path: the saved files or this session's scans, picked with a
/// segmented control in the navigation bar. The iPad's sidebar lists them on their own.
struct LibraryScreen: View {
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
        }
    }
}

enum LibraryPart: Hashable {
    case saved
    case history
}
#endif
