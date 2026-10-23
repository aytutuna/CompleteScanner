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

/// The collected pages, left to right, with the queue's summary: each page with its side or book badge
/// and the title of the document it starts; a page's menu removes it, and for a book's page splits its
/// spread again (`onEditSpread`) or joins its two pages. A page dragged onto another takes its place
/// (`IOSPageDrop`); VoiceOver has Move left and Move right for the same.
struct PageStripView: View {
    @EnvironmentObject private var state: AppState
    /// Opens the split sheet for the spread the page with this id was cut from.
    var onEditSpread: (@MainActor (UUID) -> Void)?

    var body: some View {
        let cells: [PageStripCell] = PageStripCell.cells(state.scannedPages, options: state.settings.document)
        let summary: String = DocumentSplitter.queueSummary(state.scannedPages, options: state.settings.document)
        VStack(alignment: .leading, spacing: 6) {
            Text(cells.isEmpty ? "No pages yet" : summary)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("pages.summary")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(cells) { (cell: PageStripCell) in
                        if let divider = cell.divider {
                            Text(divider)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                                .frame(maxWidth: 90)
                                .accessibilityHidden(true)
                        }
                        thumbnail(cell)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 112)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pages.strip")
    }

    private func thumbnail(_ cell: PageStripCell) -> some View {
        let pageID: UUID = cell.id
        let page: ScannedPage? = state.scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == pageID })
        let splitLabel: String? = page.flatMap { (item: ScannedPage) -> String? in BookPages.splitActionLabel(item) }
        let joinLabel: String? = page.flatMap { (item: ScannedPage) -> String? in BookPages.joinActionLabel(item) }
        let canEdit: Bool = state.canEditSpread(id: pageID)
        return VStack(spacing: 2) {
            Image(decorative: cell.image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(height: 92)
                .background(Color.white)
                .opacity(cell.note == nil ? 1 : 0.5)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
            Text(cell.badge ?? cell.note ?? " ")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .contextMenu {
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
        .accessibilityElement()
        .accessibilityLabel(Text(cell.accessibilityLabel))
        .accessibilityAction(named: Text("Move left")) {
            state.movePage(id: pageID, by: -1)
        }
        .accessibilityAction(named: Text("Move right")) {
            state.movePage(id: pageID, by: 1)
        }
        .accessibilityIdentifier("page.\(cell.number)")
    }

    /// A page of the strip dropped here: it takes this page's place.
    private func dropPage(_ items: [String], onto target: UUID) -> Bool {
        guard let text = items.first, let moving = IOSPageDrop.pageID(text) else { return false }
        return IOSPageDrop.move(moving, onto: target, in: state)
    }
}

/// The page strip in a sheet at half height that can grow, opened from the scan screen's capture bar
/// (`capture.pages`), with Done.
struct PageStripSheet: View {
    @EnvironmentObject private var state: AppState
    var onEditSpread: (@MainActor (UUID) -> Void)?
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageStripView(onEditSpread: onEditSpread)
                Spacer(minLength: 0)
            }
            .navigationTitle(IOSCameraText.pageCount(state.scannedPages.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onClose()
                    }
                    .accessibilityIdentifier("pages.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        // The root's alert cannot show over a sheet.
        .modifier(ErrorAlert(state: state))
    }
}
#endif
