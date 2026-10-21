#if os(macOS)
import AppKit
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// Bottom strip listing the document page queue. The parent only shows this view
/// when `state.scannedPages` is non-empty. Pages that look blank carry a badge; with Skip blank
/// pages on they are dimmed and left out when saving, and one click on Keep (or Skip) changes
/// that for the page (`PageFilter`). When the queue is split into documents (`DocumentSplitter`)
/// separator pages are flagged and dimmed, each document's first page is titled, and the gap before
/// a page splits or joins there with one click; a page's menu also names its document. A page cut from
/// a spread of a book says which spread it is, and its menu splits the spread again (the split sheet,
/// `SpreadSplitView`) or joins its two pages.
struct PagesStripView: View {
    @EnvironmentObject var state: AppState
    /// The page whose document is being named (the name alert), and the name typed.
    @State private var namingPage: UUID?
    @State private var nameDraft = ""
    /// The spread being split by hand (the split sheet).
    @State private var editingSpread: SpreadEditorSource?

    var body: some View {
        let options = state.settings.document
        let plan = DocumentSplitter.plan(state.scannedPages, options: options)
        let savePlan = SavePlan.make(state.scannedPages, options: options)
        let showsBreaks = DocumentSplitter.showsBreaks(plan, options: options)
        let saveCount = savePlan.pageCount
        let saveTitle = savePlan.saveTitle(state.settings.format)
        let saveHelp: String = saveCount == 0 && !state.scannedPages.isEmpty ? PageFilter.nothingToSaveMessage : ""
        // Worked out once per refresh, in one pass over the queue.
        let bookLabels = BookPages.labels(state.scannedPages)
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(state.scannedPages.enumerated()), id: \.element.id) { index, page in
                        HStack(spacing: 4) {
                            if showsBreaks {
                                BreakGap(label: DocumentSplitter.breakLabel(plan, index),
                                         startsDocument: plan.isSplit && plan.pages[index].startsDocument
                                            && (plan.pages[index].document ?? 1) > 1,
                                         onToggle: { state.toggleDocumentBreak(id: page.id) })
                            }
                            PageThumbnailCell(
                                page: page,
                                pageNumber: index + 1,
                                options: options,
                                split: PageSplitInfo(plan: plan, index: index, page: page, options: options),
                                book: PageBookInfo(page: page, label: bookLabels[index],
                                                   editable: state.canEditSpread(of: page)),
                                canMoveLeft: index > 0,
                                canMoveRight: index < state.scannedPages.count - 1,
                                onRemove: { state.removePage(id: page.id) },
                                onMove: { state.movePage(id: page.id, by: $0) },
                                onRotate: { state.rotatePage(id: page.id) },
                                onToggle: { state.togglePageInclusion(id: page.id) },
                                onSwap: { state.togglePageGeometry(id: page.id) },
                                onUpright: { state.togglePageUpright(id: page.id) },
                                onCopyText: { state.copyPageText(id: page.id) },
                                onBreak: { state.toggleDocumentBreak(id: page.id) },
                                onName: {
                                    nameDraft = state.documentLabel(of: page.id)
                                    namingPage = page.id
                                },
                                onSplitSpread: {
                                    Task { editingSpread = await state.spreadEditor(for: page.id) }
                                },
                                onJoinSpread: { state.joinSpread(id: page.id) })
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()
                .padding(.vertical, 10)

            VStack(alignment: .trailing, spacing: 6) {
                // "24 pages · 5 blank skipped", "9 pages · 3 documents · 2 separator pages skipped"
                Text(DocumentSplitter.queueSummary(state.scannedPages, options: options))
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
                .help("Remove all pages")
                .accessibilityHint(Text("Remove every page from the queue"))
            }
            .padding(.trailing, 12)
        }
        .frame(height: 104)
        .background(.bar)
        .alert("Name This Document", isPresented: Binding(get: { namingPage != nil },
                                                           set: { if !$0 { namingPage = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                if let id = namingPage { state.setDocumentLabel(id: id, label: nameDraft) }
                namingPage = nil
            }
            Button("Cancel", role: .cancel) { namingPage = nil }
        } message: {
            Text("Used for {label} in the file name.")
        }
        .sheet(item: $editingSpread) { source in
            SpreadSplitView(source: source) { choice in
                switch choice {
                case .split(let axis, let fraction):
                    state.splitSpread(id: source.pageID, axis: axis, fraction: fraction)
                case .keepWhole:
                    state.joinSpread(id: source.pageID)
                }
            }
        }
    }
}

/// What the strip says about a page cut from a spread of a book. Twin of the Windows `PageBookView`.
fileprivate struct PageBookInfo {
    /// "2 · left", "2 · not split"; nil for other pages.
    let label: String?
    /// The label spelled out for VoiceOver: "Spread 2, left page".
    let help: String?
    /// The spread was kept whole: the caption says so.
    let isWhole: Bool
    /// The page menu's "Split this spread…" or "Change the split…"; nil when the spread is not at hand.
    let splitLabel: String?
    /// The page menu's "Join the two pages"; nil for a whole spread, or when the spread is not at hand.
    let joinLabel: String?

    init(page: ScannedPage, label bookLabel: BookPageLabel?, editable: Bool) {
        label = bookLabel?.label
        help = bookLabel?.help
        isWhole = page.spread?.isWhole == true
        splitLabel = editable ? BookPages.splitActionLabel(page) : nil
        joinLabel = editable ? BookPages.joinActionLabel(page) : nil
    }
}

/// What the split plan says about a queued page, for its cell. Twin of the Windows `PageSplitView`.
fileprivate struct PageSplitInfo {
    let badge: String?
    let isExcluded: Bool
    let toggleLabel: String?
    /// "Document 2 · Lease" on the first page of each document when the queue is split.
    let dividerTitle: String?
    /// "Separator sheet (Patch T): a new document starts after it. It is not saved."
    let separatorNote: String?
    /// The page menu's split or join item.
    let menuBreakLabel: String?
    /// The page is saved in a document, so the document can be named.
    let canNameDocument: Bool

    init(plan: SplitPlan, index: Int, page: ScannedPage, options: DocumentOptions) {
        badge = DocumentSplitter.badge(plan, index, page: page, options: options)
        isExcluded = plan.pages[index].role != .content
        toggleLabel = DocumentSplitter.toggleLabel(plan, index, page: page, options: options)
        dividerTitle = DocumentSplitter.dividerTitle(plan, index)
        separatorNote = DocumentSplitter.separatorNote(plan, index, page: page)
        menuBreakLabel = DocumentSplitter.breakLabel(plan, index)
        canNameDocument = plan.pages[index].document != nil
    }
}

/// The gap before a page while the strip shows documents: one click starts a new document there or
/// joins the page to the document before. A document's start is drawn as a bar.
fileprivate struct BreakGap: View {
    let label: String?
    let startsDocument: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        if let label {
            Button(action: onToggle) {
                Rectangle()
                    .fill(startsDocument ? Color.accentColor : Color.secondary)
                    .frame(width: startsDocument ? 3 : 1)
                    .opacity(startsDocument || hovering ? 1 : 0)
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(label)
            .accessibilityLabel(label)
        } else {
            Color.clear.frame(width: 10)
        }
    }
}

// MARK: - File-private cell

fileprivate struct PageThumbnailCell: View {
    let page: ScannedPage
    let pageNumber: Int
    /// The blank-page settings the page is shown with.
    let options: DocumentOptions
    /// Its place in the split plan: badge, separator, document title.
    let split: PageSplitInfo
    /// Its spread, for a page of a book.
    let book: PageBookInfo
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onRemove: () -> Void
    let onMove: (Int) -> Void
    let onRotate: () -> Void
    /// Keep or skip the page (`AppState.togglePageInclusion`).
    let onToggle: () -> Void
    /// Show the page as scanned, or cropped and straightened again (`AppState.togglePageGeometry`).
    let onSwap: () -> Void
    /// Undo the turn that made the page upright, or make it again (`AppState.togglePageUpright`).
    let onUpright: () -> Void
    /// The page's text, read with OCR, on the pasteboard (`AppState.copyPageText`).
    let onCopyText: () -> Void
    /// Start a new document at the page, or join it to the one before (`AppState.toggleDocumentBreak`).
    let onBreak: () -> Void
    /// Name the page's document (the strip's name alert).
    let onName: () -> Void
    /// Split the page's spread again, or split a spread kept whole (the split sheet).
    let onSplitSpread: () -> Void
    /// Join the two pages of the page's spread (`AppState.joinSpread`).
    let onJoinSpread: () -> Void

    @State private var thumbnail: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            thumbnailView
                .frame(height: 58)
                // Left out when saving: the page is dimmed.
                .opacity(split.isExcluded ? 0.35 : 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay { if hovering { hoverControls } }
                // Above the hover controls, so the pointer that shows them can still reach Keep
                // or Skip; the button sits at the bottom edge, clear of the centred hover row.
                .overlay(alignment: .topLeading) { blankBadge }
                .overlay(alignment: .bottom) { blankToggle }
                .onHover { hovering = $0 }

            // Below the page, clear of the hover controls on it.
            HStack(spacing: 3) {
                if let title = split.dividerTitle {
                    // The first page of a document when the queue is split: its title instead.
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 90)
                        .help("\(title), \(caption)")
                } else {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(DocumentSides.sideName(side: page.side, sheetIndex: page.sheetIndex) ?? book.help
                              ?? (PhotoImport.sourceHelp(page) ?? ""))
                }
                // A spread kept as one page (its spine was not found, or it was joined): split it here.
                if book.isWhole, book.splitLabel != nil {
                    Button("Split\u{2026}", action: onSplitSpread)
                        .buttonStyle(.link)
                        .font(.caption2)
                        .help(book.splitLabel ?? "")
                }
                geometryToggle
                uprightToggle
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
        .contextMenu {
            Button("Copy Text", action: onCopyText)
            if split.menuBreakLabel != nil || split.canNameDocument {
                Divider()
            }
            if let label = split.menuBreakLabel {
                Button(label, action: onBreak)
            }
            if split.canNameDocument {
                Button("Name This Document\u{2026}", action: onName)
            }
            if book.splitLabel != nil || book.joinLabel != nil {
                Divider()
            }
            if let label = book.splitLabel {
                Button(label, action: onSplitSpread)
            }
            if let label = book.joinLabel {
                Button(label, action: onJoinSpread)
            }
        }
        // Re-render when the page is rotated, shown as scanned or turned back (the cell keeps its
        // identity, so a plain run-once task would show stale pixels).
        .task(id: thumbnailKey) {
            thumbnail = stripThumbnail(page.image, maxDimension: 200)
        }
    }

    /// What the thumbnail shows: the page's turn, the version shown and whether a turn upright was undone.
    private var thumbnailKey: Int {
        let undone = page.upright?.undone == true ? 8 : 0
        let original = page.showsOriginal ? 1 : 0
        return page.rotationQuarterTurns * 2 + original + undone
    }

    /// "Page 3", "Page 3 · back" for a page of a two-sided stack, "Page 3 · not split" for a spread
    /// of a book kept whole, "Page 3 · photo" for a page imported from a photo, or "Page 3 · from
    /// phone" for one a paired phone sent.
    private var caption: String {
        guard let side = page.side else {
            if book.isWhole { return "Page \(pageNumber) \u{00B7} not split" }
            switch page.source {
            case .photo: return "Page \(pageNumber) \u{00B7} photo"
            case .phone: return "Page \(pageNumber) \u{00B7} from phone"
            case .scanner: return "Page \(pageNumber)"
            }
        }
        return "Page \(pageNumber) \u{00B7} \(side == .front ? "front" : "back")"
    }

    /// "Page 3, Sheet 2, back, Blank, skipped, Straightened 1.5°, Turned upright 180°" for screen
    /// readers; the first page of a document after the first starts with its title ("Document 2, Page 3").
    private var accessibilityName: String {
        var name = "Page \(pageNumber)"
        if let title = split.dividerTitle { name = "\(title), \(name)" }
        if let label = DocumentSides.sideName(side: page.side, sheetIndex: page.sheetIndex) ?? book.help
            ?? PhotoImport.sourceLabel(page) {
            name += ", \(label)"
        }
        if let note = split.separatorNote {
            name += ", \(note)"
        } else if let badge = split.badge {
            name += ", \(badge)"
        }
        if let caption = PageCorrections.caption(page) {
            name += ", \(caption)"
        }
        if let turn = PageTurns.caption(page) {
            name += ", \(turn)"
        }
        return name
    }

    /// A page turned upright: one click (always shown, not only on hover) turns it back as scanned,
    /// and again. What was done and what a click does show on hover and to screen readers.
    @ViewBuilder
    private var uprightToggle: some View {
        if let label = PageTurns.toggleLabel(page), let caption = PageTurns.caption(page) {
            Button(action: onUpright) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("\(caption). \(label).")
            .accessibilityLabel(label)
            .accessibilityHint(caption)
        }
    }

    /// A page crop and straighten changed: one click (always shown, not only on hover) shows it as
    /// scanned, and back. What was done and what a click does show on hover and to screen readers.
    @ViewBuilder
    private var geometryToggle: some View {
        if let label = PageCorrections.toggleLabel(page), let caption = PageCorrections.caption(page) {
            Button(action: onSwap) {
                Image(systemName: page.showsOriginal ? "arrow.uturn.forward" : "arrow.uturn.backward")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("\(caption). \(label).")
            .accessibilityLabel(label)
            .accessibilityHint(caption)
        }
    }

    /// A page that looks blank, or was skipped: a small mark in the corner that fits the cell,
    /// with what saving does with the page ("Blank, skipped") on hover and for screen readers.
    @ViewBuilder
    private var blankBadge: some View {
        if let badge = split.badge {
            Image(systemName: "doc")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                .padding(2)
                .help(split.separatorNote ?? badge)
                .accessibilityLabel(badge)
        }
    }

    /// One click (always shown, not only on hover) to keep or skip the page. It sits on the page
    /// itself, so it gets an opaque backing: the dark appearance's light text would otherwise
    /// land on white paper.
    @ViewBuilder
    private var blankToggle: some View {
        if let toggleLabel = split.toggleLabel {
            let toggleTitle: String = split.isExcluded ? "Keep" : "Skip"
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
#endif
