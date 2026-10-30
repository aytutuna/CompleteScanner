#if os(macOS)
import AppKit
import LazyScanKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The "Saved" tab: everything in the destination folder, newest first, with open, open with,
/// show in Finder, share, email, copy (`AppState.runFileAction`), 90°-rotation for saved image
/// files and, for a PDF, adding the queued pages to its end (`AppState.appendToPDF(at:)`). Every
/// action is also in the card's More menu and context menu.
struct SavedFilesView: View {
    @EnvironmentObject var state: AppState

    @State private var files: [SavedFileItem] = []
    @State private var loadFailed = false
    /// Paths with a rotate in flight — their buttons are disabled so a double-click
    /// can't race two rewrites of the same file.
    @State private var rotatingPaths: Set<String> = []

    var body: some View {
        Group {
            if files.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                        ForEach(files) { file in
                            SavedFileCard(file: file,
                                          rotating: rotatingPaths.contains(file.url.path),
                                          canAppend: state.canAppendPages,
                                          onAction: { state.runFileAction($0, urls: [file.url]) },
                                          onRotate: { rotate(file) },
                                          onAppend: { state.appendToPDF(at: file.url) })
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        // Refresh whenever something new is saved, and on every appearance.
        .task(id: state.lastSavedURLs) { reload() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read the destination folder")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text(loadFailed ? "The destination folder could not be read."
                            : "Nothing saved yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(destinationURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Button("Show in Finder") { state.revealInFinder(destinationURL) }
        }
        .padding(40)
    }

    private var destinationURL: URL {
        URL(fileURLWithPath: (state.settings.destinationPath as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    private func reload() {
        let dir = destinationURL
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            files = []
            loadFailed = FileManager.default.fileExists(atPath: dir.path)
            return
        }
        loadFailed = false
        let known: Set<String> = ["pdf", "jpg", "jpeg", "png", "tiff", "tif", "txt", "docx"]
        files = urls
            .filter { known.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> SavedFileItem? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return SavedFileItem(url: url,
                                     modified: values?.contentModificationDate ?? .distantPast,
                                     fileSize: values?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// "Turn after save": rewrite a saved image file rotated 90° clockwise, keeping its
    /// format and DPI metadata. (PDFs are not rotatable here — rotate pages before saving.)
    ///
    /// Safety: the rotated file is written beside the original and swapped in atomically,
    /// so a failed write never destroys the only copy; concurrent rotates of the same file
    /// are blocked via `rotatingPaths`; multi-page TIFFs are refused rather than silently
    /// truncated to their first page.
    private func rotate(_ file: SavedFileItem) {
        guard let format = file.imageFormat else { return }
        let url = file.url
        guard !rotatingPaths.contains(url.path) else { return }
        rotatingPaths.insert(url.path)
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return "The file could not be read."
                }
                guard CGImageSourceGetCount(source) == 1 else {
                    return "It has multiple pages — rotate it in Preview instead."
                }
                // Full-size decode with the EXIF orientation baked in, so the pixels
                // match what the user sees before rotating them.
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 100_000,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return "The image could not be decoded."
                }
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue ?? 300
                // A black & white TIFF (1 bit per pixel; the app writes them as CCITT G4) stays G4.
                let depth = (props?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
                let mode: ColorMode = format == .tiff && depth == 1 ? .blackWhite : .color
                let rotated = ImagePipeline.rotate(image, quarterTurns: 1)
                let tmp = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
                do {
                    // High quality to limit generation loss on repeated JPEG rotates.
                    try ImageExporter.write(rotated, to: tmp, format: format, dpi: dpi, jpegQuality: 0.95,
                                            colorMode: mode)
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                    return nil
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    return "The rotated copy could not be written."
                }
            }.value
            rotatingPaths.remove(url.path)
            if let failure {
                state.errorMessage = "Could not rotate \(url.lastPathComponent): \(failure)"
            } else {
                reload()
            }
        }
    }
}

// MARK: - File-private model

fileprivate struct SavedFileItem: Identifiable, Equatable {
    let url: URL
    let modified: Date
    let fileSize: Int

    /// Identity includes the modification date so a rotate-in-place refreshes the card.
    var id: String { "\(url.path)|\(modified.timeIntervalSince1970)" }

    var isPdf: Bool { url.pathExtension.lowercased() == "pdf" }

    /// A text file or Word document: no picture to show.
    var isTextDocument: Bool { ["txt", "docx"].contains(url.pathExtension.lowercased()) }

    var imageFormat: OutputFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "tiff", "tif": return .tiff
        default: return nil
        }
    }
}

// MARK: - File-private card

fileprivate struct SavedFileCard: View {
    let file: SavedFileItem
    let rotating: Bool
    /// There are queued pages to add to a PDF (`AppState.canAppendPages`).
    let canAppend: Bool
    let onAction: (FileAction) -> Void
    let onRotate: () -> Void
    let onAppend: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(6)
                } else {
                    Image(systemName: file.isTextDocument ? "doc.text" : file.isPdf ? "doc.richtext" : "photo")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 140)
            .onTapGesture(count: 2) { onAction(.open) }

            Text(file.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.url.lastPathComponent)

            Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(sizeText)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Open") { onAction(.open) }
                Button {
                    onAction(.share)
                } label: {
                    Label(FileAction.share.label, systemImage: FileAction.share.systemImage)
                        .labelStyle(.iconOnly)
                }
                .help(FileAction.share.hint(fileCount: 1))
                Button {
                    onAction(.reveal)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                if file.imageFormat != nil {
                    Button {
                        onRotate()
                    } label: {
                        if rotating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "rotate.right")
                        }
                    }
                    .disabled(rotating)
                    .help("Rotate the saved file 90° clockwise")
                }
                Menu {
                    actionMenu
                } label: {
                    Label("More actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More: open with, email, copy")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .contextMenu { actionMenu }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .task(id: file.id) {
            thumbnail = await loadThumbnail(for: file)
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file)
    }

    /// Every action on the file, then Rotate for image files and adding the queued pages for a PDF:
    /// the More menu and the context menu.
    @ViewBuilder
    private var actionMenu: some View {
        ForEach(SaveActions.offered(fileCount: 1)) { action in
            Button {
                onAction(action)
            } label: {
                Label(action.label, systemImage: action.systemImage)
            }
        }
        if file.imageFormat != nil {
            Divider()
            Button {
                onRotate()
            } label: {
                Label("Rotate 90\u{00B0} Clockwise", systemImage: "rotate.right")
            }
            .disabled(rotating)
        }
        if file.isPdf {
            Divider()
            Button {
                onAppend()
            } label: {
                Label(PDFAppender.savedMenuLabel, systemImage: "doc.badge.plus")
            }
            .disabled(!canAppend)
            .help(PDFAppender.savedMenuHint)
        }
    }
}

// MARK: - File-private helpers

/// Small preview of a saved file: CGImageSource thumbnailing for images, first-page
/// rasterization via NSImage for PDFs; none for text files and Word documents, which show their icon.
fileprivate func loadThumbnail(for file: SavedFileItem) async -> CGImage? {
    if file.isTextDocument { return nil }
    let url = file.url
    let isPdf = file.isPdf
    return await Task.detached(priority: .utility) { () -> CGImage? in
        if isPdf {
            guard let nsImage = NSImage(contentsOf: url) else { return nil }
            var rect = CGRect(origin: .zero, size: nsImage.size)
            return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }.value
}
#endif
