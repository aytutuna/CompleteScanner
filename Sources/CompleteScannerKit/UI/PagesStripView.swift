import AppKit
import CoreGraphics
import SwiftUI

/// Bottom strip listing the document page queue. The parent only shows this view
/// when `state.scannedPages` is non-empty. Pages that look blank carry a badge; with Skip blank
/// pages on they are dimmed and left out when saving, and one click on Keep (or Skip) changes
/// that for the page (`PageFilter`).
struct PagesStripView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let options = state.settings.document
        let saveCount = PageFilter.pagesToSave(state.scannedPages, options: options).count
        let saveTitle: String = saveCount > 0 ? "Save PDF (\(saveCount) page\(saveCount == 1 ? "" : "s"))" : "Save PDF"
        let saveHelp: String = saveCount == 0 && !state.scannedPages.isEmpty ? PageFilter.nothingToSaveMessage : ""
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(state.scannedPages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnailCell(
                            page: page,
                            pageNumber: index + 1,
                            options: options,
                            canMoveLeft: index > 0,
                            canMoveRight: index < state.scannedPages.count - 1,
                            onRemove: { state.removePage(id: page.id) },
                            onMove: { state.movePage(id: page.id, by: $0) },
                            onRotate: { state.rotatePage(id: page.id) },
                            onToggle: { state.togglePageInclusion(id: page.id) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()
                .padding(.vertical, 10)

            VStack(alignment: .trailing, spacing: 6) {
                // "24 pages in queue, 5 blank skipped"
                Text(PageFilter.queueSummary(state.scannedPages, options: options))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    state.savePDF()
                } label: {
                    Text(saveTitle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || saveCount == 0)
                .help(saveHelp)

                Button("Clear") {
                    state.clearPages()
                }
                .disabled(state.isBusy)
            }
            .padding(.trailing, 12)
        }
        .frame(height: 104)
        .background(.bar)
    }
}

// MARK: - File-private cell

fileprivate struct PageThumbnailCell: View {
    let page: ScannedPage
    let pageNumber: Int
    /// The blank-page settings the page is shown with.
    let options: DocumentOptions
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onRemove: () -> Void
    let onMove: (Int) -> Void
    let onRotate: () -> Void
    /// Keep or skip the page (`AppState.togglePageInclusion`).
    let onToggle: () -> Void

    @State private var thumbnail: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            thumbnailView
                .frame(height: 58)
                // Left out when saving: the page is dimmed.
                .opacity(PageFilter.isExcluded(page, options: options) ? 0.35 : 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay { if hovering { hoverControls } }
                // Above the hover controls, so the pointer that shows them can still reach Keep
                // or Skip; the button sits at the bottom edge, clear of the centred hover row.
                .overlay(alignment: .topLeading) { blankBadge }
                .overlay(alignment: .bottom) { blankToggle }
                .onHover { hovering = $0 }

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(DocumentSides.sideLabel(side: page.side, sheetIndex: page.sheetIndex) ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
        // Re-render when the page is rotated (the cell keeps its identity, so a
        // plain run-once task would show the stale orientation).
        .task(id: page.rotationQuarterTurns) {
            thumbnail = stripThumbnail(page.image, maxDimension: 200)
        }
    }

    /// "Page 3", or "Page 3 · back" for a page of a two-sided stack.
    private var caption: String {
        guard let side = page.side else { return "Page \(pageNumber)" }
        return "Page \(pageNumber) \u{00B7} \(side == .front ? "front" : "back")"
    }

    /// "Page 3, Sheet 2 · back, Blank, skipped" for screen readers.
    private var accessibilityName: String {
        var name = "Page \(pageNumber)"
        if let label = DocumentSides.sideLabel(side: page.side, sheetIndex: page.sheetIndex) {
            name += ", \(label)"
        }
        if let badge = PageFilter.badge(page, options: options) {
            name += ", \(badge)"
        }
        return name
    }

    /// A page that looks blank, or was skipped: a small mark in the corner that fits the cell,
    /// with what saving does with the page ("Blank, skipped") on hover and for screen readers.
    @ViewBuilder
    private var blankBadge: some View {
        if let badge = PageFilter.badge(page, options: options) {
            Image(systemName: "doc")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                .padding(2)
                .help(badge)
                .accessibilityLabel(badge)
        }
    }

    /// One click (always shown, not only on hover) to keep or skip the page. It sits on the page
    /// itself, so it gets an opaque backing: the dark appearance's light text would otherwise
    /// land on white paper.
    @ViewBuilder
    private var blankToggle: some View {
        if let toggleLabel = PageFilter.toggleLabel(page, options: options) {
            let toggleTitle: String = PageFilter.isExcluded(page, options: options) ? "Keep" : "Skip"
            Button(toggleTitle, action: onToggle)
                .controlSize(.mini)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.bottom, 2)
                .help(toggleLabel)
                .accessibilityLabel(toggleLabel)
        }
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(CGSize(width: max(page.image.width, 1), height: max(page.image.height, 1)),
                                 contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 44)
            }
        }
    }

    private var hoverControls: some View {
        ZStack {
            // Dims the page only: clicks go to the buttons, never to the backdrop.
            Color.black.opacity(0.3)
                .allowsHitTesting(false)
            HStack {
                Button {
                    onMove(-1)
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                }
                .disabled(!canMoveLeft)
                .help("Move page left")

                Spacer(minLength: 2)

                Button(action: onRotate) {
                    Image(systemName: "rotate.right.fill")
                }
                .help("Rotate page 90° clockwise")

                Spacer(minLength: 2)

                Button {
                    onMove(1)
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                }
                .disabled(!canMoveRight)
                .help("Move page right")
            }
            .padding(.horizontal, 2)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Remove page")
            .padding(2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .imageScale(.medium)
    }
}

// MARK: - File-private helpers

/// Downsample a full-resolution scanned page to a small strip thumbnail.
fileprivate func stripThumbnail(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    guard w > 0, h > 0 else { return image }
    let scale = maxDimension / max(w, h)
    guard scale < 1 else { return image }
    let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
    return ctx.makeImage() ?? image
}
