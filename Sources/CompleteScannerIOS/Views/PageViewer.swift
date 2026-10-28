#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI
import UIKit

/// The page the viewer opens on.
struct PageViewerStart: Identifiable {
    let id: UUID
}

/// What the page grid and the page viewer say.
enum PageViewerText {
    static let rotateLabel = "Rotate"
    static let filtersLabel = "Filters"
    static let cropLabel = "Crop"
    static let deleteLabel = "Delete"
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
}

/// One page at a time over the whole screen, fitted whole within the safe area: pinch or double-tap to zoom,
/// swipe to the next page, "3 of 7" over it and Done. Its toolbar shows the filters of a camera's page (a row
/// of small pictures of this page with each, `AppState.filterPreviews`), turns it a quarter, opens the
/// corner editor on its photo for Crop (`AppState.pageCropStart`, `recropPage`), and deletes it once asked.
/// Filters and Crop are left out for pages that cannot be cut again (`PageRecut.canRecut`): scans, imported
/// PDFs, the pages of a book's spread taken whole.
struct PageViewer: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void
    @State private var selection: UUID?
    @State private var showsFilters: Bool = false
    @State private var previews: [CaptureFilter: CGImage] = [:]
    /// The previews are being made; once they are in, a filter without one shows a plain tile.
    @State private var loadingPreviews: Bool = false
    @State private var asksDelete: Bool = false
    @State private var crop: IOSCropRequest?
    @State private var preparesCrop: Bool = false
    /// The page's rotation when the corner editor's picture was turned for it.
    @State private var cropRotation: Int = 0
    /// The filter tapped last for each page, shown as chosen while the page is cut again.
    @State private var requested: [UUID: CaptureFilter] = [:]

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
        .fullScreenCover(item: $crop) { (request: IOSCropRequest) in
            CornerEditorView(request: request.request, onAnswer: { (answer: PhotoCornersAnswer) -> Void in
                finishCrop(request, answer: answer)
            }, onStop: closeCrop, fixesCrop: true)
        }
        .task(id: previewKey) {
            await loadPreviews()
        }
        .modifier(ErrorAlert(state: state))
    }

    // MARK: The pages

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(state.scannedPages) { (page: ScannedPage) in
                pageView(page)
                    .tag(Optional(page.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The page being cropped stays on screen while its photo is read.
        .allowsHitTesting(!preparesCrop)
        .accessibilityIdentifier("viewer.pages")
    }

    private func pageView(_ page: ScannedPage) -> some View {
        let index: Int = state.scannedPages.firstIndex(where: { (item: ScannedPage) -> Bool in item.id == page.id }) ?? 0
        let label: String = PageViewerText.title(number: index + 1, count: state.scannedPages.count)
        return ZoomablePage(image: page.image)
            .overlay {
                if state.recuttingPages.contains(page.id) {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Page \(label)"))
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: Text("Next page")) {
                step(by: 1)
            }
            .accessibilityAction(named: Text("Previous page")) {
                step(by: -1)
            }
            .accessibilityIdentifier("viewer.page.\(index + 1)")
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
        .disabled(preparesCrop)
        .accessibilityIdentifier("viewer.rotate")
        Spacer()
        if canRecut {
            Button(action: openCrop) {
                Label(PageViewerText.cropLabel, systemImage: "crop")
            }
            .disabled(preparesCrop)
            .accessibilityIdentifier("viewer.crop")
            Spacer()
        }
        Button(role: .destructive, action: askDelete) {
            Label(PageViewerText.deleteLabel, systemImage: "trash")
        }
        .accessibilityIdentifier("viewer.delete")
    }

    private func toggleFilters() {
        showsFilters.toggle()
    }

    private func rotateCurrent() {
        guard let id = selection else { return }
        state.rotatePage(id: id)
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

    private func closeCrop() {
        crop = nil
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
        shown = image
        imageView.image = UIImage(cgImage: image)
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
#endif
