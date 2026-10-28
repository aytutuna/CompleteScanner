#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation
import SwiftUI

/// One page of the strip: its number and its picture; the side of a two-sided sheet ("1 · back") or the
/// page of a book's spread ("2 · left") it is; the title over it when it starts a document of a queue
/// saved as several ("Document 2"); and the note on a page saving leaves out ("Separator", "Blank").
struct PageStripCell: Identifiable {
    let id: UUID
    let number: Int
    let image: CGImage
    /// "1 · back", "2 · left"; nil for a page of neither.
    let badge: String?
    /// The badge spelled out for VoiceOver: "Sheet 1, back", "Spread 2, left page".
    let spokenBadge: String?
    /// "Document 2" over the first page of each document when the queue is saved as several; nil otherwise.
    let divider: String?
    /// "Separator", "Blank", "Skipped" for a page saving leaves out (or may); nil otherwise.
    let note: String?

    /// What VoiceOver reads: "Page 2, Sheet 1, back, Document 2, Separator".
    var accessibilityLabel: String {
        var parts: [String] = ["Page \(number)"]
        if let spokenBadge { parts.append(spokenBadge) }
        if let divider { parts.append(divider) }
        if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    /// The queue's pages as cells, numbered from 1, under the document settings `options`.
    static func cells(_ pages: [ScannedPage], options: DocumentOptions = DocumentOptions()) -> [PageStripCell] {
        let plan: SplitPlan = DocumentSplitter.plan(pages, options: options)
        let book: [BookPageLabel?] = BookPages.labels(pages)
        var cells: [PageStripCell] = []
        var index: Int = 0
        for page in pages {
            var badge: String? = DocumentSides.sideLabel(side: page.side, sheetIndex: page.sheetIndex)
            var spoken: String? = DocumentSides.sideName(side: page.side, sheetIndex: page.sheetIndex)
            if let bookLabel = book[index] {
                badge = bookLabel.label
                spoken = bookLabel.help
            }
            cells.append(PageStripCell(id: page.id, number: index + 1, image: page.image, badge: badge,
                                       spokenBadge: spoken, divider: DocumentSplitter.dividerTitle(plan, index),
                                       note: DocumentSplitter.badge(plan, index, page: page, options: options)))
            index += 1
        }
        return cells
    }
}

/// The collected pages as a grid of whole pages, two across on an iPhone held upright and more on a wider
/// screen, with the queue's summary: each page with its number, its side or book badge, the title of the
/// document it starts and its note (blank, separator) on a badge over it. A tap opens the page (`onOpen`);
/// its menu turns it, removes it, and for a book's page splits its spread again (`onEditSpread`) or joins its
/// two pages. A page dragged onto another takes its place (`IOSPageDrop`); VoiceOver has Move left and Move
/// right for the same. While the sheet is selecting (`selection`), a tap picks or drops the page instead, and
/// it has no menu and is not dragged.
struct PageStripView: View {
    @EnvironmentObject private var state: AppState
    /// Opens the split sheet for the spread the page with this id was cut from.
    var onEditSpread: (@MainActor (UUID) -> Void)?
    /// The pages picked; nil when the grid is not selecting.
    var selection: Binding<Set<UUID>>?
    let onOpen: @MainActor (UUID) -> Void

    /// At least 150 pt a page: two across the narrowest iPhone, more on an iPad or turned sideways.
    static let columns: [GridItem] = [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 14, alignment: .top)]

    var body: some View {
        let cells: [PageStripCell] = PageStripCell.cells(state.scannedPages, options: state.settings.document)
        let summary: String = DocumentSplitter.queueSummary(state.scannedPages, options: state.settings.document)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The sheet's title already gives the count; the line stays for what it adds (documents, separators).
                if cells.isEmpty || summary != IOSCameraText.pageCount(state.scannedPages.count) {
                    Text(cells.isEmpty ? "No pages yet" : summary)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("pages.summary")
                }
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
                    ForEach(cells) { (cell: PageStripCell) in
                        if let selection {
                            selectTile(cell, selection: selection)
                        } else {
                            tile(cell)
                        }
                    }
                }
            }
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pages.strip")
        }
    }

    private func tile(_ cell: PageStripCell) -> some View {
        let pageID: UUID = cell.id
        let page: ScannedPage? = state.scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == pageID })
        let splitLabel: String? = page.flatMap { (item: ScannedPage) -> String? in BookPages.splitActionLabel(item) }
        let joinLabel: String? = page.flatMap { (item: ScannedPage) -> String? in BookPages.joinActionLabel(item) }
        let canEdit: Bool = state.canEditSpread(id: pageID)
        return Button {
            onOpen(pageID)
        } label: {
            PageTile(cell: cell, working: state.recuttingPages.contains(pageID), selected: false)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                state.rotatePage(id: pageID)
            } label: {
                Label(PageViewerText.rotateLabel, systemImage: "rotate.right")
            }
            if let splitLabel, canEdit, let edit = onEditSpread {
                Button {
                    edit(pageID)
                } label: {
                    Label(splitLabel, systemImage: "rectangle.split.2x1")
                }
            }
            if let joinLabel, canEdit {
                Button {
                    state.joinSpread(id: pageID)
                } label: {
                    Label(joinLabel, systemImage: "rectangle")
                }
            }
            Button(role: .destructive) {
                state.removePage(id: pageID)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .draggable(pageID.uuidString)
        .dropDestination(for: String.self) { (items: [String], _: CGPoint) -> Bool in
            dropPage(items, onto: pageID)
        }
        .accessibilityLabel(Text(cell.accessibilityLabel))
        .accessibilityHint(Text(PageViewerText.openHint))
        .accessibilityAction(named: Text("Move left")) {
            state.movePage(id: pageID, by: -1)
        }
        .accessibilityAction(named: Text("Move right")) {
            state.movePage(id: pageID, by: 1)
        }
        .accessibilityIdentifier("page.\(cell.number)")
    }

    private func selectTile(_ cell: PageStripCell, selection: Binding<Set<UUID>>) -> some View {
        let pageID: UUID = cell.id
        let picked: Bool = selection.wrappedValue.contains(pageID)
        return Button {
            if picked {
                selection.wrappedValue.remove(pageID)
            } else {
                selection.wrappedValue.insert(pageID)
            }
        } label: {
            PageTile(cell: cell, working: state.recuttingPages.contains(pageID), selected: picked)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(cell.accessibilityLabel))
        .accessibilityAddTraits(picked ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier("page.\(cell.number)")
    }

    /// A page of the grid dropped here: it takes this page's place.
    private func dropPage(_ items: [String], onto target: UUID) -> Bool {
        guard let text = items.first, let moving = IOSPageDrop.pageID(text) else { return false }
        return IOSPageDrop.move(moving, onto: target, in: state)
    }
}

/// One page of the grid: the whole page fitted in a card of a sheet's shape, nothing of it cut off, its note
/// on a badge over its corner, a spinner while it is cut out again, and its number and badge under it. A page
/// picked in the grid's selection is dimmed a little and ticked in the other corner.
private struct PageTile: View {
    let cell: PageStripCell
    let working: Bool
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let divider = cell.divider {
                Text(divider)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            card
            HStack(spacing: 6) {
                Text("\(cell.number)")
                    .font(.footnote.weight(.semibold))
                if let badge = cell.badge {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(PageViewerText.cardAspect, contentMode: .fit)
            .overlay {
                page
                    .padding(8)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.15))
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(6)
                }
            }
    }

    private var page: some View {
        // The previews are about 1600 px tall; drawn this small they alias without a better filter.
        Image(decorative: cell.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .background(Color.white)
            .shadow(color: Color.black.opacity(0.2), radius: 2, y: 1)
            .overlay(alignment: .topLeading) {
                if let note = cell.note {
                    Text(note)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(4)
                }
            }
            .overlay {
                if working {
                    ProgressView()
                }
            }
    }
}

/// The page grid in a sheet that opens at full height and can be pulled down to half, opened from the scan
/// screen's pages button (`capture.pages`), with Done; a page tapped opens in the page viewer over it. Select
/// picks pages as the Photos app does: "2 Selected" as the title, Select All or Deselect All, and Cancel in
/// place of Done, with a bottom bar that turns the pages picked, shares them as pictures, moves them to the
/// start or the end, and deletes them once asked.
struct PageStripSheet: View {
    @EnvironmentObject private var state: AppState
    var onEditSpread: (@MainActor (UUID) -> Void)?
    let onClose: () -> Void
    @State private var detent: PresentationDetent = .large
    @State private var viewing: PageViewerStart?
    @State private var selecting: Bool = false
    @State private var selected: Set<UUID> = []
    @State private var asksDelete: Bool = false
    @State private var sharing: Bool = false
    @State private var share: ShareRequest?

    var body: some View {
        NavigationStack {
            PageStripView(onEditSpread: onEditSpread, selection: selecting ? $selected : nil, onOpen: openPage)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if selecting {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(allSelected ? PageViewerText.deselectAllLabel : PageViewerText.selectAllLabel,
                                   action: toggleAll)
                                .accessibilityIdentifier("pages.selectAll")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(PageViewerText.cancelLabel, action: stopSelecting)
                                .accessibilityIdentifier("pages.cancel")
                        }
                        ToolbarItemGroup(placement: .bottomBar) {
                            selectionActions
                        }
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(PageViewerText.selectLabel, action: startSelecting)
                                .accessibilityIdentifier("pages.select")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                onClose()
                            }
                            .accessibilityIdentifier("pages.done")
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .confirmationDialog(PageViewerText.deletePagesQuestion(selected.count), isPresented: $asksDelete,
                            titleVisibility: .visible) {
            Button(PageViewerText.deleteLabel, role: .destructive) {
                deleteSelected()
            }
            .accessibilityIdentifier("pages.confirmDelete")
        }
        .sheet(item: $share) { (request: ShareRequest) in
            ActivityView(items: request.urls, onDone: closeShare)
        }
        .fullScreenCover(item: $viewing) { (start: PageViewerStart) in
            PageViewer(startID: start.id, onClose: closeViewer)
                .environmentObject(state)
        }
        // The root's alert cannot show over a sheet.
        .modifier(ErrorAlert(state: state))
    }

    private var title: String {
        guard selecting else { return IOSCameraText.pageCount(state.scannedPages.count) }
        return PageViewerText.selectedTitle(selected.count)
    }

    private var allSelected: Bool {
        !state.scannedPages.isEmpty && state.scannedPages.allSatisfy { (page: ScannedPage) -> Bool in selected.contains(page.id) }
    }

    private func startSelecting() {
        selecting = true
        detent = .large
    }

    private func stopSelecting() {
        selecting = false
        selected = []
    }

    private func toggleAll() {
        if allSelected {
            selected = []
        } else {
            selected = Set(state.scannedPages.map { (page: ScannedPage) -> UUID in page.id })
        }
    }

    @ViewBuilder
    private var selectionActions: some View {
        let none: Bool = selected.isEmpty
        Button(action: rotateSelected) {
            Label(PageViewerText.rotateLabel, systemImage: "rotate.right")
        }
        .disabled(none)
        .accessibilityIdentifier("pages.rotateSelected")
        Spacer()
        Button(action: shareSelected) {
            Label(PageViewerText.shareLabel, systemImage: "square.and.arrow.up")
        }
        .disabled(none || sharing)
        .accessibilityIdentifier("pages.shareSelected")
        Spacer()
        Menu {
            Button {
                IOSPageSelection.move(selected, toStart: true, in: state)
            } label: {
                Label(PageViewerText.moveToStartLabel, systemImage: "arrow.up.to.line")
            }
            Button {
                IOSPageSelection.move(selected, toStart: false, in: state)
            } label: {
                Label(PageViewerText.moveToEndLabel, systemImage: "arrow.down.to.line")
            }
        } label: {
            Label(PageViewerText.moveLabel, systemImage: "arrow.up.arrow.down")
        }
        .disabled(none)
        .accessibilityIdentifier("pages.moveSelected")
        Spacer()
        Button(role: .destructive, action: askDelete) {
            Label(PageViewerText.deleteLabel, systemImage: "trash")
        }
        .disabled(none)
        .accessibilityIdentifier("pages.deleteSelected")
    }

    private func rotateSelected() {
        for id in IOSPageSelection.ordered(selected, in: state.scannedPages) {
            state.rotatePage(id: id)
        }
    }

    private func shareSelected() {
        let ids: Set<UUID> = selected
        let pages: [ScannedPage] = state.scannedPages
        let format: OutputFormat = state.settings.format.imageFormatOrJPEG
        let quality: Double = state.settings.jpegQuality
        let appState: AppState = state
        sharing = true
        Task { @MainActor in
            do {
                let urls: [URL] = try await IOSPageSelection.writeImages(ids, of: pages, format: format, jpegQuality: quality)
                share = ShareRequest(urls: urls, title: SaveActions.shareTitle(urls))
            } catch {
                appState.errorMessage = error.localizedDescription
            }
            sharing = false
        }
    }

    private func closeShare() {
        share = nil
    }

    private func askDelete() {
        asksDelete = true
    }

    private func deleteSelected() {
        for id in IOSPageSelection.ordered(selected, in: state.scannedPages) {
            state.removePage(id: id)
        }
        stopSelecting()
    }

    private func openPage(_ id: UUID) {
        viewing = PageViewerStart(id: id)
    }

    private func closeViewer() {
        viewing = nil
    }
}
#endif
