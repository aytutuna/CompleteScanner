#if os(iOS)
import LazyScanKit
import CoreGraphics
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The page the viewer opens on.
struct PageViewerStart: Identifiable {
    let id: UUID
}

/// What the page grid and the page viewer say.
enum PageViewerText {
    static let rotateLabel = "Rotate"
    static let filtersLabel = "Filters"
    static let cropLabel = "Crop"
    static let textLabel = "Text"
    static let textTitle = "Text on this page"
    static let readingText = "Reading the text\u{2026}"
    static let noText = "No text found on this page"
    static let textFailed = "The text could not be read"
    static let copyLabel = "Copy"
    static let deleteLabel = "Delete"
    static let deleteAllLabel = "Delete All"
    static let openHint = "Opens the page"
    static let deleteQuestion = "Delete this page?"
    static let deleteMessage = "It is taken out of the pages to save."
    static let selectLabel = "Select"
    static let selectAllLabel = "Select All"
    static let deselectAllLabel = "Deselect All"
    static let cancelLabel = "Cancel"
    static let shareLabel = "Share"
    static let moveLabel = "Move"
    static let moveToStartLabel = "Move to Beginning"
    static let moveToEndLabel = "Move to End"
    /// The cards of the grid have a sheet's shape (between A4 and Letter); every page is fitted whole in one.
    static let cardAspect: CGFloat = 0.75

    /// "3 of 7"
    static func title(number: Int, count: Int) -> String {
        "\(number) of \(count)"
    }

    /// The filter as VoiceOver says it: "Black and white" for B&W.
    static func filterName(_ filter: CaptureFilter) -> String {
        filter == .blackAndWhite ? "Black and white" : filter.label
    }

    /// "Page 3"
    static func pageName(_ number: Int) -> String {
        "Page \(number)"
    }

    /// The page grid's title while pages are picked: "Select Pages", "2 Selected".
    static func selectedTitle(_ count: Int) -> String {
        count == 0 ? "Select Pages" : "\(count) Selected"
    }

    /// "Delete 3 pages?" for the pages picked in the grid.
    static func deletePagesQuestion(_ count: Int) -> String {
        count == 1 ? "Delete 1 page?" : "Delete \(count) pages?"
    }

    /// "Delete all 3 pages?" for Delete All in the page grid.
    static func deleteAllQuestion(_ count: Int) -> String {
        count == 1 ? "Delete 1 page?" : "Delete all \(count) pages?"
    }
}

/// One page at a time over the whole screen, fitted whole within the safe area: pinch or double-tap to zoom,
/// swipe to the next page, "3 of 7" over it and Done, and the grid's note on a page saving leaves out (or
/// may) on a badge in its corner. Its toolbar shows the filters of a camera's page (a row of small pictures
/// of this page with each, `AppState.filterPreviews`), turns it a quarter, opens the corner editor on its
/// photo for Crop (`AppState.pageCropStart`, `recropPage`), shows the text on it (`PageTextSheet`), keeps or
/// skips it as the grid's menu does (`PageStripCell.toggle`), and deletes it once asked; the edits are off
/// while the app is busy.
/// Filters and Crop are left out for pages that cannot be cut again (`PageRecut.canRecut`): scans, imported
/// PDFs, the pages of a book's spread taken whole.
struct PageViewer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    let onClose: () -> Void
    @State private var selection: UUID?
    @State private var showsFilters: Bool = false
    @State private var previews: [CaptureFilter: CGImage] = [:]
    /// The previews are being made; once they are in, a filter without one shows a plain tile.
    @State private var loadingPreviews: Bool = false
    @State private var asksDelete: Bool = false
    /// The page whose text is shown.
    @State private var textOf: PageViewerStart?
    @State private var crop: IOSCropRequest?
    @State private var preparesCrop: Bool = false
    /// The page's rotation when the corner editor's picture was turned for it.
    @State private var cropRotation: Int = 0
    /// The filter tapped last for each page, shown as chosen while the page is cut again.
    @State private var requested: [UUID: CaptureFilter] = [:]
    /// The page shown and the ones either side of it read from their spool files, sharper than the queue's previews.
    @State private var sharpCache: SharpCache = SharpCache()
    /// Set by a memory warning: only the page shown is read until the plan changes.
    @State private var shownOnly: Bool = false
    /// The pager's longest side so far, in points: it only grows, so turning the phone reads nothing again.
    @State private var viewSide: CGFloat = 0

    /// What a page is read from: its spool file, at `side` pixels on its longer side (`pixels` in all), turned
    /// `turns`. `preview` is the queue's preview the page has: turned, cut again, swapped or replaced, a page
    /// gets a new one, so a picture read before is never shown for it.
    struct SharpRead: Equatable {
        let page: UUID
        let preview: ObjectIdentifier
        let url: URL
        let side: Int
        let turns: Int
        let pixels: Int
    }

    /// The pages read sharper that the viewer holds: at most `limit`, and a big one alone.
    struct SharpCache {
        struct Entry {
            let read: SharpRead
            /// Kept alive with the picture, so `read.preview` cannot come back as another preview's identifier.
            let preview: CGImage
            let image: CGImage
        }

        static let limit: Int = 3
        /// A page read over this many pixels is held alone: three of them would take a few hundred MB.
        static let bigPixels: Int = 20_000_000

        private(set) var entries: [Entry] = []

        /// The pages to hold read with the page shown `current`: it and the ones either side of it, or only it
        /// when it is big; a big page either side is left out.
        static func kept(current: SharpRead?, neighbours: [SharpRead]) -> [SharpRead] {
            if let current, current.pixels > Self.bigPixels { return [current] }
            let small: [SharpRead] = neighbours.filter { (read: SharpRead) -> Bool in read.pixels <= Self.bigPixels }
            guard let current else { return small }
            return [current] + small
        }

        func image(for read: SharpRead) -> CGImage? {
            entries.first(where: { (entry: Entry) -> Bool in entry.read == read })?.image
        }

        /// Lets go of every picture not read for one of `reads`.
        mutating func keep(_ reads: [SharpRead]) {
            entries.removeAll { (entry: Entry) -> Bool in !reads.contains(entry.read) }
        }

        /// Lets go of every picture but the one read for `page` (the page shown), on a memory warning.
        mutating func keepOnly(_ page: UUID?) {
            entries.removeAll { (entry: Entry) -> Bool in entry.read.page != page }
        }

        /// Holds `image`, read for `read` from the page whose preview is `preview`, in place of what was read
        /// for that page before; the oldest go past `limit`, and all the others with a big one.
        mutating func add(_ image: CGImage, read: SharpRead, preview: CGImage) {
            let big: Bool = read.pixels > Self.bigPixels
            entries.removeAll { (entry: Entry) -> Bool in big || entry.read.page == read.page }
            entries.append(Entry(read: read, preview: preview, image: image))
            if entries.count > Self.limit {
                entries.removeFirst(entries.count - Self.limit)
            }
        }
    }

    init(startID: UUID, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _selection = State(initialValue: startID)
    }

    /// The page after `id` once it is deleted, or the one before it when it was the last; nil when none is left.
    nonisolated static func pageAfterRemoving(_ id: UUID, from ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }

    /// The longer side, in pixels, the page shown is read at from its spool file: three times the view's, so
    /// a zoom stays sharp, but no more than the page has; 0 when the queue's preview has as many already.
    nonisolated static func sharpSide(view: Int, page: Int, preview: Int) -> Int {
        let side: Int = min(view * 3, page)
        return side > preview ? side : 0
    }

    /// The pixels of a page `page` pixels large read at `side` pixels on its longer side.
    nonisolated static func readPixels(side: Int, page: CGSize) -> Int {
        let long: Double = Double(max(page.width, page.height, 1))
        let short: Double = Double(min(page.width, page.height))
        return Int(Double(side) * Double(side) * short / long)
    }

    /// The picture in the spool file `url`, at most `maxSide` pixels on its longer side and turned as
    /// `AppState.fullImage(of:)` turns the file; nil when it cannot be read.
    nonisolated static func readPage(_ url: URL, maxSide: Int, quarterTurns: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return ImagePipeline.rotate(image, quarterTurns: quarterTurns)
    }

    /// Whether two pictures have the same proportions, but for the rounding of a smaller copy's sides.
    nonisolated static func sameShape(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width * b.height - b.width * a.height) <= max(a.width, a.height, b.width, b.height)
    }

    private var current: ScannedPage? {
        state.scannedPages.first(where: { (page: ScannedPage) -> Bool in page.id == selection })
    }

    private var number: Int {
        let index: Int? = state.scannedPages.firstIndex(where: { (page: ScannedPage) -> Bool in page.id == selection })
        return (index ?? 0) + 1
    }

    private var canRecut: Bool {
        current.map { (page: ScannedPage) -> Bool in PageRecut.canRecut(page) } ?? false
    }

    /// The page shown as the grid has it, for its Keep or Skip.
    private var currentCell: PageStripCell? {
        let cells: [PageStripCell] = PageStripCell.cells(state.scannedPages, options: state.settings.document)
        return cells.first(where: { (cell: PageStripCell) -> Bool in cell.id == selection })
    }

    /// Each page's note as the grid shows it ("Blank, skipped", "Separator"), by page.
    private var pageNotes: [UUID: String] {
        var notes: [UUID: String] = [:]
        for cell in PageStripCell.cells(state.scannedPages, options: state.settings.document) {
            notes[cell.id] = cell.note
        }
        return notes
    }

    /// What `page` is read from for a sharper picture; nil for a page without a spool file, or one whose preview
    /// is as sharp as the view needs.
    private func sharpRead(of page: ScannedPage) -> SharpRead? {
        guard let url = page.fileURL, let size = page.fullPixelSize else { return nil }
        let side: Int = Self.sharpSide(view: Int(viewSide * displayScale), page: Int(max(size.width, size.height)),
                                       preview: max(page.image.width, page.image.height))
        guard side > 0 else { return nil }
        return SharpRead(page: page.id, preview: ObjectIdentifier(page.image), url: url, side: side,
                         turns: page.rotationQuarterTurns, pixels: Self.readPixels(side: side, page: size))
    }

    /// What the viewer holds read sharper: the page shown, then the next and the one before (`SharpCache.kept`).
    private var sharpPlan: [SharpRead] {
        let pages: [ScannedPage] = state.scannedPages
        guard let index = pages.firstIndex(where: { (page: ScannedPage) -> Bool in page.id == selection }) else { return [] }
        var neighbours: [SharpRead] = []
        for other in [index + 1, index - 1] where other >= 0 && other < pages.count {
            if let read = sharpRead(of: pages[other]) {
                neighbours.append(read)
            }
        }
        return SharpCache.kept(current: sharpRead(of: pages[index]), neighbours: neighbours)
    }

    /// What the filter previews are made from: the page, its turn and its corners (not its filter).
    private var previewKey: String {
        guard let page = current, showsFilters, canRecut else { return "" }
        return "\(page.id.uuidString) \(page.rotationQuarterTurns) \(String(describing: page.capture?.quad))"
    }

    var body: some View {
        NavigationStack {
            pager
                .background(Color(uiColor: .systemGroupedBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsFilters, canRecut, let page = current {
                        filterRow(page)
                    }
                }
                .navigationTitle(PageViewerText.title(number: number, count: state.scannedPages.count))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onClose()
                        }
                        .accessibilityIdentifier("viewer.done")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        actions
                    }
                }
                .toolbarBackground(Visibility.visible, for: .bottomBar)
        }
        .confirmationDialog(PageViewerText.deleteQuestion, isPresented: $asksDelete, titleVisibility: .visible) {
            Button(PageViewerText.deleteLabel, role: .destructive) {
                deleteCurrent()
            }
            .accessibilityIdentifier("viewer.confirmDelete")
        } message: {
            Text(PageViewerText.deleteMessage)
        }
        .sheet(item: $textOf) { (shown: PageViewerStart) in
            PageTextSheet(pageID: shown.id)
                .environmentObject(state)
        }
        .fullScreenCover(item: $crop) { (request: IOSCropRequest) in
            CornerEditorView(request: request.request, onAnswer: { (answer: PhotoCornersAnswer) -> Void in
                finishCrop(request, answer: answer)
            }, fixesCrop: true)
        }
        .task(id: previewKey) {
            await loadPreviews()
        }
        .task(id: sharpPlan) {
            await loadSharp()
        }
        // The neighbours are read again on the next swipe; the page shown stays sharp.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { (_: Notification) in
            shownOnly = true
            sharpCache.keepOnly(selection)
        }
        .modifier(ErrorAlert(state: state))
    }

    // MARK: The pages

    private var pager: some View {
        let notes: [UUID: String] = pageNotes
        return TabView(selection: $selection) {
            ForEach(state.scannedPages) { (page: ScannedPage) in
                pageView(page, note: notes[page.id])
                    .tag(Optional(page.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The page being cropped stays on screen while its photo is read.
        .allowsHitTesting(!preparesCrop)
        .accessibilityIdentifier("viewer.pages")
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
            max(proxy.size.width, proxy.size.height)
        } action: { (side: CGFloat) in
            if side > viewSide {
                viewSide = side
            }
        }
    }

    private func pageView(_ page: ScannedPage, note: String?) -> some View {
        let index: Int = state.scannedPages.firstIndex(where: { (item: ScannedPage) -> Bool in item.id == page.id }) ?? 0
        let label: String = PageViewerText.title(number: index + 1, count: state.scannedPages.count)
        let spoken: String = note.map { (text: String) -> String in "Page \(label), \(text)" } ?? "Page \(label)"
        return ZoomablePage(image: shownImage(page))
            .overlay {
                if state.recuttingPages.contains(page.id) {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .overlay(alignment: .topLeading) {
                if let note {
                    noteBadge(note)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spoken))
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: Text("Next page")) {
                step(by: 1)
            }
            .accessibilityAction(named: Text("Previous page")) {
                step(by: -1)
            }
            .accessibilityIdentifier("viewer.page.\(index + 1)")
    }

    /// The grid's note on the page, on a badge in the corner as the grid has it.
    private func noteBadge(_ note: String) -> some View {
        Text(note)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.65)))
            .padding(12)
            .allowsHitTesting(false)
    }

    /// The page's preview, or its sharper picture once it is read as the page is now.
    private func shownImage(_ page: ScannedPage) -> CGImage {
        guard let read = sharpRead(of: page), let sharp = sharpCache.image(for: read) else { return page.image }
        return sharp
    }

    /// Reads the page shown, then the ones either side of it, from their spool files off the main actor, to show
    /// in place of their previews; a swipe then lands on a page read already. What was read for pages no longer
    /// near, or for a page as it was before a change, is let go first.
    private func loadSharp() async {
        shownOnly = false
        sharpCache.keep(sharpPlan)
        // Turns and filters clicked earlier land first, so the files read are the ones the pages end up with.
        await state.pageEditChain?.value
        for read in sharpPlan where sharpCache.image(for: read) == nil {
            guard !Task.isCancelled else { return }
            // A memory warning while this runs leaves the neighbours to the next plan.
            guard !shownOnly || read.page == selection else { return }
            guard let preview = state.scannedPages.first(where: { (page: ScannedPage) -> Bool in page.id == read.page })?.image,
                  ObjectIdentifier(preview) == read.preview else { continue }
            let priority: TaskPriority = read.page == selection ? .userInitiated : .utility
            let image: CGImage? = await Task.detached(priority: priority) { () -> CGImage? in
                PageViewer.readPage(read.url, maxSide: read.side, quarterTurns: read.turns)
            }.value
            // The read can land after a swipe or edit but before SwiftUI cancels this task; one no longer planned
            // would only push out entries that are.
            guard !Task.isCancelled, sharpPlan.contains(read), !shownOnly || read.page == selection else { return }
            if let image {
                sharpCache.add(image, read: read, preview: preview)
            }
        }
    }

    private func step(by offset: Int) {
        guard let index = state.scannedPages.firstIndex(where: { (page: ScannedPage) -> Bool in page.id == selection }) else { return }
        let next: Int = index + offset
        guard next >= 0 && next < state.scannedPages.count else { return }
        show(state.scannedPages[next].id)
    }

    private func show(_ id: UUID) {
        if reduceMotion {
            selection = id
        } else {
            withAnimation {
                selection = id
            }
        }
    }

    // MARK: The toolbar

    @ViewBuilder
    private var actions: some View {
        // The queue's edits do nothing while an import, a scan or a save runs.
        let blocked: Bool = state.isBusy || preparesCrop
        if canRecut {
            Button(action: toggleFilters) {
                Label(PageViewerText.filtersLabel, systemImage: "camera.filters")
            }
            .accessibilityValue(Text(showsFilters ? "Shown" : "Hidden"))
            .accessibilityIdentifier("viewer.filters")
            Spacer()
        }
        Button(action: rotateCurrent) {
            Label(PageViewerText.rotateLabel, systemImage: "rotate.right")
        }
        .disabled(blocked)
        .accessibilityIdentifier("viewer.rotate")
        Spacer()
        if canRecut {
            Button(action: openCrop) {
                Label(PageViewerText.cropLabel, systemImage: "crop")
            }
            .disabled(blocked)
            .accessibilityIdentifier("viewer.crop")
            Spacer()
        }
        Button(action: showText) {
            Label(PageViewerText.textLabel, systemImage: "text.viewfinder")
        }
        .disabled(preparesCrop)
        .accessibilityIdentifier("viewer.text")
        Spacer()
        if let cell = currentCell, let toggle = cell.toggle {
            Button(action: toggleInclusion) {
                Label(toggle, systemImage: cell.toggleSymbol)
            }
            .disabled(state.isBusy)
            .accessibilityIdentifier("viewer.keep")
            Spacer()
        }
        Button(role: .destructive, action: askDelete) {
            Label(PageViewerText.deleteLabel, systemImage: "trash")
        }
        .disabled(state.isBusy)
        .accessibilityIdentifier("viewer.delete")
    }

    private func toggleFilters() {
        showsFilters.toggle()
    }

    private func rotateCurrent() {
        guard let id = selection else { return }
        state.rotatePage(id: id)
    }

    private func toggleInclusion() {
        guard let id = selection else { return }
        state.togglePageInclusion(id: id)
    }

    private func showText() {
        guard let id = selection else { return }
        textOf = PageViewerStart(id: id)
    }

    private func askDelete() {
        asksDelete = true
    }

    private func deleteCurrent() {
        guard let id = selection else { return }
        var ids: [UUID] = []
        for page in state.scannedPages {
            ids.append(page.id)
        }
        let next: UUID? = Self.pageAfterRemoving(id, from: ids)
        state.removePage(id: id)
        guard let next, !state.scannedPages.contains(where: { (page: ScannedPage) -> Bool in page.id == id }) else {
            if state.scannedPages.isEmpty { onClose() }
            return
        }
        show(next)
    }

    // MARK: Filters

    private func filterRow(_ page: ScannedPage) -> some View {
        let working: Bool = state.recuttingPages.contains(page.id)
        let chosen: CaptureFilter? = (working ? requested[page.id] : nil) ?? PageRecut.filter(of: page)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(CaptureFilter.displayOrder, id: \.self) { (filter: CaptureFilter) in
                    filterButton(filter, page: page.id, chosen: filter == chosen)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.filterRow")
    }

    private func filterButton(_ filter: CaptureFilter, page: UUID, chosen: Bool) -> some View {
        Button {
            requested[page] = filter
            state.setPageFilter(id: page, filter)
        } label: {
            VStack(spacing: 4) {
                filterPicture(filter)
                    .frame(width: 60, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chosen ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: chosen ? 3 : 1))
                Text(filter.label)
                    .font(.caption)
                    .foregroundStyle(chosen ? Color.accentColor : Color.primary)
            }
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .accessibilityLabel(Text(PageViewerText.filterName(filter)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("filter.\(filter.rawValue)")
    }

    @ViewBuilder
    private func filterPicture(_ filter: CaptureFilter) -> some View {
        if let picture = previews[filter] {
            Image(decorative: picture, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    if loadingPreviews {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(Color.secondary)
                    }
                }
        }
    }

    private func loadPreviews() async {
        guard let id = current?.id, !previewKey.isEmpty else { return }
        previews = [:]
        loadingPreviews = true
        let made: [CaptureFilter: CGImage] = await state.filterPreviews(id: id, maxSide: 160)
        guard !Task.isCancelled else { return }
        previews = made
        loadingPreviews = false
    }

    // MARK: Crop

    private func openCrop() {
        guard let id = selection, !preparesCrop else { return }
        preparesCrop = true
        let name: String = PageViewerText.pageName(number)
        Task { @MainActor in
            let request: IOSCropRequest? = await cropRequest(id: id, name: name)
            preparesCrop = false
            if let request {
                let cropped: ScannedPage? = state.scannedPages.first(where: { (page: ScannedPage) -> Bool in page.id == id })
                cropRotation = cropped?.rotationQuarterTurns ?? 0
                crop = request
            } else {
                state.errorMessage = PageRecut.failedMessage
            }
        }
    }

    /// The corner editor's request on the page's photo, read and turned off the main actor.
    private func cropRequest(id: UUID, name: String) async -> IOSCropRequest? {
        guard let start = await state.pageCropStart(id: id) else { return nil }
        let source: CGImage = start.source
        let pixels: RgbaImage? = await Task.detached(priority: .userInitiated) { () -> RgbaImage? in
            RgbaImage(cgImage: source)
        }.value
        guard let picture = pixels else { return nil }
        let plan = PhotoImportPlan(action: .review, corners: start.corners, reason: PhotoReviewReason.none,
                                   detection: PhotoDocumentDetection.nothing)
        // One "photo": the editor's counter then shows the page's name.
        let request = PhotoCornersRequest(photo: picture, plan: plan, fileName: name, number: 1, count: 1)
        return IOSCropRequest(photoID: id, request: request)
    }

    /// Use corners cuts the page again along them, Use whole photo along the whole photo; Cancel changes nothing.
    private func finishCrop(_ request: IOSCropRequest, answer: PhotoCornersAnswer) {
        crop = nil
        // The crop keeps the page's filter: an earlier tap is not the one to show while it runs.
        requested[request.photoID] = nil
        switch answer.choice {
        case .useCorners:
            if let corners = answer.corners {
                state.recropPage(id: request.photoID, corners: corners, rotation: cropRotation)
            }
        case .wholePhoto:
            let photo: RgbaImage = request.request.photo
            state.recropPage(id: request.photoID, corners: PhotoImport.wholePhoto(width: photo.width, height: photo.height),
                             rotation: cropRotation)
        case .skip:
            break
        }
    }
}

/// A page fitted whole in the space it is given, zoomed with a pinch or a double tap (back with another), and
/// panned while zoomed; not zoomed, a swipe goes to the page viewer's next page.
private struct ZoomablePage: UIViewRepresentable {
    let image: CGImage

    func makeUIView(context: Context) -> ZoomingImageView {
        ZoomingImageView()
    }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        view.show(image)
    }
}

private final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView = UIImageView()
    private var shown: CGImage?
    /// The size the page was last fitted to.
    private var fittedSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.2
        imageView.layer.shadowRadius = 4
        imageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        // The page read from its file is several times the screen; without mipmaps its print aliases until zoomed.
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(_ image: CGImage) {
        guard image !== shown else { return }
        // The page read sharper, or cut again with another filter, keeps its zoom; a page turned or cropped is fitted again.
        let kept: Bool = shown.map { (old: CGImage) -> Bool in
            PageViewer.sameShape(CGSize(width: old.width, height: old.height), CGSize(width: image.width, height: image.height))
        } ?? false
        shown = image
        imageView.image = UIImage(cgImage: image)
        guard !kept else { return }
        fittedSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedSize {
            fit()
        }
        centre()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
    }

    /// The page at zoom 1, as large as it fits.
    private func fit() {
        fittedSize = bounds.size
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        zoomScale = 1
        let scale: CGFloat = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
    }

    /// Keeps a page smaller than the view in its middle.
    private func centre() {
        let x: CGFloat = max((bounds.width - contentSize.width) / 2, 0)
        let y: CGFloat = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let animated: Bool = !UIAccessibility.isReduceMotionEnabled
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: animated)
            return
        }
        let point: CGPoint = gesture.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
             animated: animated)
    }
}

/// The text on a page of the viewer, read as Quick scan's Copy text reads its shot (`AppState.readText`) once
/// the page's edits under way have landed: selectable, with Copy (on this device only, as Copy text) and Share.
struct PageTextSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let pageID: UUID
    /// The text read; nil while it is read.
    @State private var text: String?
    /// Why it could not be read.
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(PageViewerText.textTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                        .accessibilityIdentifier("text.done")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(action: copy) {
                            Label(PageViewerText.copyLabel, systemImage: "doc.on.doc")
                        }
                        .disabled(found == nil)
                        .accessibilityIdentifier("text.copy")
                        Spacer()
                        ShareLink(item: found ?? "") {
                            Label(PageViewerText.shareLabel, systemImage: "square.and.arrow.up")
                        }
                        .disabled(found == nil)
                        .accessibilityIdentifier("text.share")
                    }
                }
        }
        .task {
            await read()
        }
    }

    private var found: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    @ViewBuilder
    private var content: some View {
        if let problem {
            ContentUnavailableView(PageViewerText.textFailed, systemImage: "exclamationmark.triangle",
                                   description: Text(problem))
        } else if let found {
            ScrollView {
                Text(found)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .accessibilityIdentifier("text.body")
        } else if text != nil {
            ContentUnavailableView(PageViewerText.noText, systemImage: "text.magnifyingglass")
                .accessibilityIdentifier("text.none")
        } else {
            ProgressView(PageViewerText.readingText)
        }
    }

    private func read() async {
        guard text == nil, problem == nil else { return }
        await state.pageEditChain?.value
        if Task.isCancelled { return }
        guard let page = state.scannedPages.first(where: { (item: ScannedPage) -> Bool in item.id == pageID }) else {
            text = ""
            return
        }
        // Closing the sheet cancels its task and the read with it: one not begun yet never starts, and the
        // text of one under way is dropped.
        let reading: Task<String, Error> = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
            return try AppState.readText(page)
        }
        do {
            text = try await withTaskCancellationHandler {
                try await reading.value
            } onCancel: {
                reading.cancel()
            }
        } catch is CancellationError {
            return
        } catch {
            // The Kit's message starts with the title: the description is the reason alone.
            let lead: String = PageViewerText.textFailed + ": "
            let message: String = error.localizedDescription
            problem = message.hasPrefix(lead) ? String(message.dropFirst(lead.count)) : message
        }
    }

    private func copy() {
        guard let found else { return }
        let item: [String: Any] = [UTType.utf8PlainText.identifier: found]
        UIPasteboard.general.setItems([item], options: [UIPasteboard.OptionsKey.localOnly: true])
    }
}
#endif
