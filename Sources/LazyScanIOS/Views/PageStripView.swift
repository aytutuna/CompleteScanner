#if os(iOS)
import LazyScanKit
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// One page of the strip: its number and its picture; the side of a two-sided sheet ("1 · back") or the
/// page of a book's spread ("2 · left") it is; the title over it when it starts a document of a queue
/// saved as several ("Document 2"); the note on a page saving leaves out ("Separator", "Blank"); and the
/// Keep or Skip its menu and the page viewer offer.
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
    /// "Keep this page" for a page saving leaves out, "Skip this page" for one that looks blank or was kept;
    /// nil for other pages (`DocumentSplitter.toggleLabel`).
    let toggle: String?
    /// Saving leaves the page out: a separator, a blank page skipped, a page skipped by hand.
    let excluded: Bool

    /// The symbol beside `toggle`: a tick to keep the page, a slash to skip it.
    var toggleSymbol: String {
        excluded ? "checkmark.rectangle" : "rectangle.slash"
    }

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
                                       note: DocumentSplitter.badge(plan, index, page: page, options: options),
                                       toggle: DocumentSplitter.toggleLabel(plan, index, page: page, options: options),
                                       excluded: plan.pages[index].role != .content))
            index += 1
        }
        return cells
    }
}

/// The collected pages as a grid of whole pages, two across on an iPhone held upright and more on a wider
/// screen until a pinch changes it (one to six across an iPhone, up to ten on an iPad; kept in the defaults
/// under `columnsKey`), with the queue's summary: each page with its number, its side or book badge, the
/// title of the document it starts and its note (blank, separator) on a badge over it. A tap opens the page
/// (`onOpen`); its menu turns it, keeps or skips it (`PageStripCell.toggle`), deletes it once asked
/// (`onDelete`), and for a book's page splits its spread again (`onEditSpread`) or joins its two pages, each
/// off while the app is busy, Delete also while a share or a send reads the pages (`AppState.readsQueue`). A
/// page dragged onto another takes its place (`IOSPageDrop`); VoiceOver has Move left and Move right for the
/// same. While the sheet is selecting (`selection`), a tap picks or drops the page instead, and it has no menu
/// and is not dragged.
struct PageStripView: View {
    @EnvironmentObject private var state: AppState
    /// Opens the split sheet for the spread the page with this id was cut from.
    var onEditSpread: (@MainActor (UUID) -> Void)?
    /// The pages picked; nil when the grid is not selecting.
    var selection: Binding<Set<UUID>>?
    let onOpen: @MainActor (UUID) -> Void
    /// The menu's Delete for the page with this id; the sheet asks first.
    let onDelete: @MainActor (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pages across chosen with a pinch; 0 until one is.
    @AppStorage(PageStripView.columnsKey) private var chosenColumns: Int = 0
    /// The pinch under way has taken its step.
    @State private var pinched: Bool = false
    /// A pinch is under way; back to false when it ends or the system cancels it.
    @GestureState private var pinching: Bool = false

    static let columnsKey = "pages.columns"

    /// As many pages across as fit at 150 pt each within the grid's margins: two on an iPhone held upright,
    /// more on an iPad or turned sideways.
    nonisolated static func defaultColumns(width: CGFloat) -> Int {
        max(1, Int((width - 32 + 14) / 164))
    }

    /// The most pages across a pinch gives: six on an iPhone, turned sideways too, up to ten on a wide iPad.
    nonisolated static func maxColumns(width: CGFloat, pad: Bool) -> Int {
        guard pad else { return 6 }
        return min(10, max(6, Int(width / 100)))
    }

    /// The pages across at `width`: the number chosen, as far as the width allows, or the default.
    nonisolated static func columnCount(chosen: Int, width: CGFloat, pad: Bool) -> Int {
        guard chosen > 0 else { return defaultColumns(width: width) }
        return min(chosen, maxColumns(width: width, pad: pad))
    }

    /// The gap between pages, tighter as they get smaller: 14 pt up to two across, 6 pt from five.
    nonisolated static func spacing(columns: Int) -> CGFloat {
        min(14, max(6, 28 / CGFloat(columns)))
    }

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            grid(width: geometry.size.width)
        }
    }

    private func grid(width: CGFloat) -> some View {
        let cells: [PageStripCell] = PageStripCell.cells(state.scannedPages, options: state.settings.document)
        let summary: String = DocumentSplitter.queueSummary(state.scannedPages, options: state.settings.document)
        let pad: Bool = UIDevice.current.userInterfaceIdiom == .pad
        let count: Int = Self.columnCount(chosen: chosenColumns, width: width, pad: pad)
        let spacing: CGFloat = Self.spacing(columns: count)
        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
        let compact: Bool = count >= 4
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The sheet's title already gives the count; the line stays for what it adds (documents, separators).
                if cells.isEmpty || summary != IOSCameraText.pageCount(state.scannedPages.count) {
                    Text(cells.isEmpty ? "No pages yet" : summary)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("pages.summary")
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing + 4) {
                    ForEach(cells) { (cell: PageStripCell) in
                        if let selection {
                            selectTile(cell, selection: selection, compact: compact)
                        } else {
                            tile(cell, compact: compact)
                        }
                    }
                }
            }
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pages.strip")
        }
        .simultaneousGesture(pinch(columns: count, most: Self.maxColumns(width: width, pad: pad)))
        .onChange(of: pinching) { (_: Bool, now: Bool) in
            if !now {
                pinched = false
            }
        }
    }

    /// Pinching out shows fewer, larger pages and pinching in more, smaller ones, a step a pinch.
    private func pinch(columns: Int, most: Int) -> some Gesture {
        MagnifyGesture()
            .updating($pinching) { (_: MagnifyGesture.Value, active: inout Bool, _: inout Transaction) in
                active = true
            }
            .onChanged { (value: MagnifyGesture.Value) in
                guard !pinched else { return }
                if value.magnification > 1.15 && columns > 1 {
                    pinched = true
                    show(columns: columns - 1)
                } else if value.magnification < 0.87 && columns < most {
                    pinched = true
                    show(columns: columns + 1)
                }
            }
    }

    private func show(columns: Int) {
        if reduceMotion {
            chosenColumns = columns
        } else {
            withAnimation(Animation.snappy) {
                chosenColumns = columns
            }
        }
    }

    private func tile(_ cell: PageStripCell, compact: Bool) -> some View {
        let pageID: UUID = cell.id
        let page: ScannedPage? = state.scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == pageID })
        let splitLabel: String? = page.flatMap { (item: ScannedPage) -> String? in BookPages.splitActionLabel(item) }
        let joinLabel: String? = page.flatMap { (item: ScannedPage) -> String? in BookPages.joinActionLabel(item) }
        let canEdit: Bool = state.canEditSpread(id: pageID)
        return Button {
            onOpen(pageID)
        } label: {
            PageTile(cell: cell, working: state.recuttingPages.contains(pageID), compact: compact, selected: false)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                state.rotatePage(id: pageID)
            } label: {
                Label(PageViewerText.rotateLabel, systemImage: "rotate.right")
            }
            .disabled(state.isBusy)
            if let splitLabel, canEdit, let edit = onEditSpread {
                Button {
                    edit(pageID)
                } label: {
                    Label(splitLabel, systemImage: "rectangle.split.2x1")
                }
                .disabled(state.isBusy)
            }
            if let joinLabel, canEdit {
                Button {
                    state.joinSpread(id: pageID)
                } label: {
                    Label(joinLabel, systemImage: "rectangle")
                }
                .disabled(state.isBusy)
            }
            if let toggle = cell.toggle {
                Button {
                    state.togglePageInclusion(id: pageID)
                } label: {
                    Label(toggle, systemImage: cell.toggleSymbol)
                }
                .disabled(state.isBusy)
            }
            Button(role: .destructive) {
                onDelete(pageID)
            } label: {
                Label(PageViewerText.deleteLabel, systemImage: "trash")
            }
            .disabled(state.isBusy || state.readsQueue)
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

    private func selectTile(_ cell: PageStripCell, selection: Binding<Set<UUID>>, compact: Bool) -> some View {
        let pageID: UUID = cell.id
        let picked: Bool = selection.wrappedValue.contains(pageID)
        return Button {
            if picked {
                selection.wrappedValue.remove(pageID)
            } else {
                selection.wrappedValue.insert(pageID)
            }
        } label: {
            PageTile(cell: cell, working: state.recuttingPages.contains(pageID), compact: compact, selected: picked)
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
/// picked in the grid's selection is dimmed a little and ticked in the other corner. Four or more across
/// (`compact`), the margins, corners and words shrink with the card.
private struct PageTile: View {
    let cell: PageStripCell
    let working: Bool
    let compact: Bool
    let selected: Bool

    private var radius: CGFloat { compact ? 6 : 10 }
    private var gap: CGFloat { compact ? 3 : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            if let divider = cell.divider {
                Text(divider)
                    .font(compact ? Font.caption2.weight(.semibold) : Font.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            card
            HStack(spacing: gap) {
                Text("\(cell.number)")
                    .font(compact ? Font.caption2.weight(.semibold) : Font.footnote.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let badge = cell.badge {
                    Text(badge)
                        .font(compact ? Font.caption2 : Font.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(PageViewerText.cardAspect, contentMode: .fit)
            .overlay {
                page
                    .padding(compact ? 3 : 8)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.black.opacity(0.15))
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(compact ? Font.body : Font.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(gap)
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
                        .lineLimit(1)
                        .padding(.horizontal, compact ? 3 : 6)
                        .padding(.vertical, compact ? 1 : 3)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(compact ? 2 : 4)
                }
            }
            .overlay {
                if working {
                    ProgressView()
                }
            }
    }
}

/// The page grid in a sheet that opens at full height and can be pulled down to half (`detents`: not in
/// camera mode, whose camera rests under the sheet), opened from the scan screen's pages button
/// (`capture.pages`), with Done; a page tapped opens in the page viewer over it. Select
/// picks pages as the Photos app does: "2 Selected" as the title, Select All or Deselect All, and Cancel in
/// place of Done, with a bottom bar that turns the pages picked, shares them as pictures, moves them to the
/// start or the end, and deletes them once asked. Outside Select a bottom bar has Delete All, which empties the
/// queue once asked; the sheet then closes, as it does whenever the pages run out. Delete in a page's menu
/// asks first too, as in the viewer. The deletes are off while a share or a send reads the pages
/// (`AppState.readsQueue`).
struct PageStripSheet: View {
    @EnvironmentObject private var state: AppState
    var onEditSpread: (@MainActor (UUID) -> Void)?
    let onClose: () -> Void
    var detents: Set<PresentationDetent> = [.medium, .large]
    @State private var detent: PresentationDetent = .large
    @State private var viewing: PageViewerStart?
    @State private var selecting: Bool = false
    @State private var selected: Set<UUID> = []
    @State private var asksDelete: Bool = false
    @State private var asksDeleteAll: Bool = false
    /// The page whose menu asked to delete it, until the question is answered.
    @State private var deleting: UUID?
    @State private var sharing: Bool = false
    @State private var share: ShareRequest?

    var body: some View {
        NavigationStack {
            PageStripView(onEditSpread: onEditSpread, selection: selecting ? $selected : nil, onOpen: openPage,
                          onDelete: askDeletePage)
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
                        // In the bottom bar: beside Select or Done it would crowd the title on an iPhone.
                        if !state.scannedPages.isEmpty {
                            ToolbarItemGroup(placement: .bottomBar) {
                                Spacer()
                                Button(PageViewerText.deleteAllLabel, role: .destructive, action: askDeleteAll)
                                    .tint(Color.red)
                                    .disabled(state.isBusy || state.readsQueue)
                                    .accessibilityIdentifier("pages.deleteAll")
                            }
                        }
                    }
                }
        }
        .presentationDetents(detents, selection: $detent)
        // A save or a send that ends while picking takes its pages out of the queue, and out of the pick.
        .onChange(of: state.scannedPages.map { (page: ScannedPage) -> UUID in page.id }) { (_: [UUID], ids: [UUID]) in
            selected.formIntersection(ids)
        }
        .confirmationDialog(PageViewerText.deletePagesQuestion(selected.count), isPresented: $asksDelete,
                            titleVisibility: .visible) {
            Button(PageViewerText.deleteLabel, role: .destructive) {
                deleteSelected()
            }
            .accessibilityIdentifier("pages.confirmDelete")
        }
        .confirmationDialog(PageViewerText.deleteAllQuestion(state.scannedPages.count), isPresented: $asksDeleteAll,
                            titleVisibility: .visible) {
            Button(PageViewerText.deleteAllLabel, role: .destructive) {
                state.clearPages()
            }
            .accessibilityIdentifier("pages.confirmDeleteAll")
        }
        .confirmationDialog(PageViewerText.deleteQuestion, isPresented: asksDeletePage, titleVisibility: .visible,
                            presenting: deleting) { (id: UUID) in
            Button(PageViewerText.deleteLabel, role: .destructive) {
                state.removePage(id: id)
            }
            .accessibilityIdentifier("pages.confirmDeleteOne")
        } message: { (_: UUID) in
            Text(PageViewerText.deleteMessage)
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

    private var asksDeletePage: Binding<Bool> {
        Binding<Bool>(
            get: { deleting != nil },
            set: { (shown: Bool) in
                if !shown {
                    deleting = nil
                }
            })
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
        // The queue's edits do nothing while an import, a scan or a save runs.
        let blocked: Bool = none || state.isBusy
        Button(action: rotateSelected) {
            Label(PageViewerText.rotateLabel, systemImage: "rotate.right")
        }
        .disabled(blocked)
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
        .disabled(blocked)
        .accessibilityIdentifier("pages.moveSelected")
        Spacer()
        Button(role: .destructive, action: askDelete) {
            Label(PageViewerText.deleteLabel, systemImage: "trash")
        }
        .disabled(blocked || state.readsQueue)
        .accessibilityIdentifier("pages.deleteSelected")
    }

    private func rotateSelected() {
        for id in IOSPageSelection.ordered(selected, in: state.scannedPages) {
            state.rotatePage(id: id)
        }
    }

    private func shareSelected() {
        let ids: Set<UUID> = selected
        let format: OutputFormat = state.settings.format.imageFormatOrJPEG
        let quality: Double = state.settings.jpegQuality
        let appState: AppState = state
        sharing = true
        Task { @MainActor in
            // Turns queued behind a page swap land before the pages are read, as for a save.
            await appState.pageEditChain?.value
            let pages: [ScannedPage] = appState.scannedPages
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

    private func askDeleteAll() {
        asksDeleteAll = true
    }

    private func askDeletePage(_ id: UUID) {
        deleting = id
    }

    private func deleteSelected() {
        guard !state.isBusy, !state.readsQueue else { return }
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
