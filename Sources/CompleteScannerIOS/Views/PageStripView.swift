#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation
import SwiftUI

/// One page of the strip: its number and its picture.
struct PageStripCell: Identifiable {
    let id: UUID
    let number: Int
    let image: CGImage

    /// The queue's pages as cells, numbered from 1.
    static func cells(_ pages: [ScannedPage]) -> [PageStripCell] {
        var cells: [PageStripCell] = []
        var number: Int = 1
        for page in pages {
            cells.append(PageStripCell(id: page.id, number: number, image: page.image))
            number += 1
        }
        return cells
    }
}

/// The collected pages, left to right, with the queue's summary; a page's menu removes it.
struct PageStripView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let cells: [PageStripCell] = PageStripCell.cells(state.scannedPages)
        let summary: String = DocumentSplitter.queueSummary(state.scannedPages, options: state.settings.document)
        VStack(alignment: .leading, spacing: 6) {
            Text(cells.isEmpty ? "No pages yet" : summary)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("pages.summary")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(cells) { (cell: PageStripCell) in
                        thumbnail(cell)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 100)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pages.strip")
    }

    private func thumbnail(_ cell: PageStripCell) -> some View {
        let pageID: UUID = cell.id
        return Image(decorative: cell.image, scale: 1)
            .resizable()
            .scaledToFit()
            .frame(height: 96)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
            .contextMenu {
                Button(role: .destructive) {
                    state.removePage(id: pageID)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Page \(cell.number)"))
            .accessibilityIdentifier("page.\(cell.number)")
    }
}
#endif
