#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// Everything in the save folder, newest first (`IOSSavedFiles`): each file with its picture, name, date
/// and size, the files of the last save marked New; Share and Show in Files on each, and its other actions
/// (open, open with, email, copy) in its menu, through `AppState.runFileAction` as on the desktop. Read
/// again whenever something is saved and when pulled down.
struct SavedFilesScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var folder: IOSSavedFolder = IOSSavedFolder(files: [], failed: false)

    var body: some View {
        let place: URL = IOSSavedFiles.shownFolder(state.settings)
        List {
            if folder.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.failed ? IOSSavedFiles.failedLine : IOSSavedFiles.emptyTitle)
                        .font(.headline)
                    if !folder.failed {
                        Text(IOSSavedFiles.emptyLine)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("saved.empty")
            }
            Section {
                ForEach(folder.files) { (file: IOSSavedFile) in
                    SavedFileRow(file: file, onAction: run)
                }
            } header: {
                Text(place.lastPathComponent)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(IOSSavedFiles.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.revealInFinder(place)
                } label: {
                    Label(IOSSavedFiles.revealLabel, systemImage: "folder")
                }
                .accessibilityIdentifier("saved.folder")
            }
        }
        .refreshable {
            reload()
        }
        .task(id: state.lastSavedURLs) {
            reload()
        }
    }

    private func reload() {
        folder = IOSSavedFiles.list(in: IOSSavedFiles.shownFolder(state.settings), justSaved: state.lastSavedURLs)
    }

    private func run(_ action: FileAction, _ file: IOSSavedFile) {
        state.runFileAction(action, urls: [file.url])
    }
}

/// One saved file: its picture (or icon), name, "New" for the last save's, date and size, then Share,
/// Show in Files and More.
private struct SavedFileRow: View {
    let file: IOSSavedFile
    let onAction: (FileAction, IOSSavedFile) -> Void
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 44, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.isNew {
                        Text(IOSSavedFiles.newBadge)
                            .font(.caption2)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                Text(file.detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                onAction(FileAction.share, file)
            } label: {
                Image(systemName: IOSSavedFiles.symbol(FileAction.share))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Share"))
            .accessibilityIdentifier("saved.share")
            Button {
                onAction(FileAction.reveal, file)
            } label: {
                Image(systemName: IOSSavedFiles.symbol(FileAction.reveal))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(IOSSavedFiles.revealLabel))
            Menu {
                actionMenu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text(IOSSavedFiles.moreLabel))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onAction(FileAction.open, file)
        }
        .contextMenu {
            Button {
                onAction(FileAction.share, file)
            } label: {
                Label(IOSSavedFiles.label(FileAction.share), systemImage: IOSSavedFiles.symbol(FileAction.share))
            }
            Button {
                onAction(FileAction.reveal, file)
            } label: {
                Label(IOSSavedFiles.label(FileAction.reveal), systemImage: IOSSavedFiles.symbol(FileAction.reveal))
            }
            actionMenu
        }
        .accessibilityIdentifier("saved.file")
        .task(id: file.id) {
            thumbnail = await SavedFileRow.loadThumbnail(file.url)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: file.symbol)
                .font(.title2)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private var actionMenu: some View {
        ForEach(IOSSavedFiles.moreActions) { (action: FileAction) in
            Button {
                onAction(action, file)
            } label: {
                Label(IOSSavedFiles.label(action), systemImage: IOSSavedFiles.symbol(action))
            }
        }
    }

    private static func loadThumbnail(_ url: URL) async -> CGImage? {
        let task: Task<CGImage?, Never> = Task.detached(priority: .utility) { () -> CGImage? in
            IOSSavedFiles.thumbnail(of: url, maxSide: 160)
        }
        return await task.value
    }
}
#endif
