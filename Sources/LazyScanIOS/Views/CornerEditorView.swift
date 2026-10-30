#if os(iOS)
import LazyScanKit
import CoreGraphics
import SwiftUI

/// The corner editor on the iPhone and iPad, after a photo was imported: the photo with the page's four
/// corners as found (`IOSPageFinder`); each corner is dragged with a finger onto a corner of the page while
/// a magnifier shows the photo around it. Use corners cuts the page out along them, Use whole photo takes
/// the photo as it is, Skip photo leaves it out, and Stop, there while more photos or pages follow, skips it
/// and ends the import. VoiceOver reads each corner by the name of where it sits now on the outline, with
/// where it is in the photo. What it does is `CornerEditorModel`; this view draws it.
/// A photo our camera just took (`isShot`) has Retake in place of Skip photo, and no caption, since it has no
/// file name.
/// For Fix crop in a review (`fixesCrop`, I13) the same editor opens on the picture an object was cut from:
/// Cancel in place of Skip photo, and no Stop, since no import runs.
/// The reason, the help line and the photo's name for VoiceOver speak of what is cut out (`request.kind`):
/// the ID card, a photo or a receipt, else the page.
struct CornerEditorView: View {
    let request: PhotoCornersRequest
    let onAnswer: @MainActor (PhotoCornersAnswer) -> Void
    /// Ends the import: this photo is skipped and the ones after it are not imported; nil, and no Stop, when
    /// nothing follows it.
    let onStop: (@MainActor () -> Void)?
    /// Fix crop in a review rather than an import.
    let fixesCrop: Bool
    /// A photo our camera just took.
    let isShot: Bool

    @State private var model: CornerEditorModel
    /// The photo as shown, made smaller when it is large.
    @State private var display: CGImage?

    init(request: PhotoCornersRequest, onAnswer: @escaping @MainActor (PhotoCornersAnswer) -> Void,
         onStop: (@MainActor () -> Void)? = nil, fixesCrop: Bool = false, isShot: Bool = false) {
        self.request = request
        self.onAnswer = onAnswer
        self.onStop = onStop
        self.fixesCrop = fixesCrop
        self.isShot = isShot
        _model = State(initialValue: CornerEditorModel(request: request))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                GeometryReader { (geometry: GeometryProxy) in
                    stage(size: geometry.size)
                }
                footer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(fixesCrop ? IOSReviewText.fixCropLabel : PhotoImport.editorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isShot {
                        // Skip, as for any photo: Auto then takes the page still in view again (`IOSCameraModel.shotImported`).
                        Button(IOSImportText.retakeLabel) {
                            onAnswer(PhotoCornersAnswer.skip)
                        }
                        .accessibilityHint(Text(IOSImportText.retakeHint))
                        .accessibilityIdentifier("corners.retake")
                    } else {
                        Button(fixesCrop ? IOSReviewText.cancelLabel : PhotoImport.skipLabel) {
                            onAnswer(PhotoCornersAnswer.skip)
                        }
                        .accessibilityIdentifier(fixesCrop ? "corners.cancel" : "corners.skip")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PhotoImport.useCornersLabel) {
                        onAnswer(model.useCornersAnswer)
                    }
                    .disabled(!model.canUseCorners)
                    .accessibilityIdentifier("corners.use")
                }
            }
        }
        .task {
            await loadDisplay()
        }
    }

    // MARK: Header and footer

    /// Why the corners need a look (when they do), the help line, and which photo this is; no caption for a
    /// shot, which has no file name, or for a lone photo from the Photos library, which is only "Photo".
    private var header: some View {
        let reason: String = PhotoImport.reasonText(request.plan.reason, kind: request.kind)
        let counter: String = PhotoImport.counter(request.number, of: request.count, fileName: request.fileName)
        // The Photos library's photos are all named "Photo": VoiceOver reads "Photo 2 of 5" without ": Photo".
        let counterName: String = request.fileName == PhotoImport.label
            ? counter
            : PhotoImport.counterName(request.number, of: request.count, fileName: request.fileName)
        let showsCounter: Bool = !isShot && counter != PhotoImport.label
        return VStack(alignment: .leading, spacing: 4) {
            if !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .accessibilityIdentifier("corners.reason")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(PhotoImport.cornersHelp(request.kind))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if showsCounter {
                    Text(counter)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(counterName))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let onStop {
                Button(IOSImportText.stopLabel, role: .cancel) {
                    onStop()
                }
                .accessibilityHint(Text("Skips this photo and ends the import"))
                .accessibilityIdentifier("corners.stop")
            }
            Button("Reset") {
                model.reset()
            }
            .disabled(!model.canReset)
            .accessibilityHint(Text("Back to the corners found"))
            .accessibilityIdentifier("corners.reset")
            Spacer(minLength: 0)
            Button(PhotoImport.wholePhotoLabel) {
                onAnswer(PhotoCornersAnswer(choice: .wholePhoto))
            }
            .accessibilityIdentifier("corners.whole")
        }
        .buttonStyle(.bordered)
        .padding(16)
    }

    // MARK: The photo and its corners

    private func stage(size: CGSize) -> some View {
        let frame: CGRect = model.fittedFrame(in: size)
        let points: [CGPoint] = model.viewCorners(frame: frame)
        return ZStack {
            Color.black.opacity(0.85)
            if let display {
                Image(decorative: display, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            } else {
                ProgressView()
                    .tint(Color.white)
            }
            CornerOutline(points: points, frame: frame, selected: model.selected, moving: model.dragging)
            ForEach(0..<4, id: \.self) { (index: Int) in
                cornerElement(index, at: points[index])
            }
            if model.showsLoupe, let display {
                loupe(display, frame: frame, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(cornerDrag(frame: frame))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(PhotoImport.cornersName(request.kind)))
        .accessibilityIdentifier("corners.stage")
    }

    /// Corner `index` for VoiceOver: swipe up moves it outward, down inward.
    private func cornerElement(_ index: Int, at point: CGPoint) -> some View {
        Color.clear
            .frame(width: 44, height: 44)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(model.cornerLabel(index)))
            .accessibilityValue(Text(model.cornerValue(index)))
            .accessibilityHint(Text(PhotoImport.cornersHelp(request.kind)))
            .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                switch direction {
                case .increment:
                    model.nudge(index, outward: true)
                default:
                    model.nudge(index, outward: false)
                }
            }
            .accessibilityIdentifier("corner.\(index)")
    }

    private func cornerDrag(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { (value: DragGesture.Value) in
                if model.dragging == nil {
                    // A finger that came down away from every handle moves nothing.
                    if !model.beginDrag(at: value.startLocation, frame: frame) { return }
                }
                model.drag(from: value.startLocation, to: value.location, frame: frame)
            }
            .onEnded { (_: DragGesture.Value) in
                model.endDrag()
            }
    }

    /// The magnifier over the moved corner, diagonally away from the page's middle.
    private func loupe(_ image: CGImage, frame: CGRect, size: CGSize) -> some View {
        let center: CGPoint = model.loupeCenter(frame: frame, in: size)
        let offset: CGSize = model.loupeImageOffset(frame: frame)
        let side: CGFloat = CornerEditorModel.loupeSize
        let zoom: CGFloat = CornerEditorModel.loupeZoom
        return ZStack(alignment: .topLeading) {
            Color.black
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width * zoom, height: frame.height * zoom)
                .offset(x: offset.width, y: offset.height)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
        .overlay(LoupeCrosshair().stroke(Color.accentColor, lineWidth: 1))
        .position(center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The photo made at most 4096 pixels long, off the main actor: a 12 MP photo is shown whole, so the
    /// magnifier zooms its own pixels. The corners stay in the photo's pixels whatever size it is shown at.
    private func loadDisplay() async {
        let photo: RgbaImage = request.photo
        let shown: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let longSide: Int = max(photo.width, photo.height, 1)
            if longSide <= 4096 {
                return photo.makeCGImage()
            }
            let scale: Double = 4096.0 / Double(longSide)
            let width: Int = max(1, Int(Double(photo.width) * scale))
            let height: Int = max(1, Int(Double(photo.height) * scale))
            return photo.resized(width: width, height: height).makeCGImage()
        }.value
        display = shown
    }
}

/// The page's outline over the photo: the photo outside it dimmed, its edges, and the four handles (the
/// one moved last larger).
private struct CornerOutline: View {
    let points: [CGPoint]
    let frame: CGRect
    let selected: Int
    let moving: Int?

    var body: some View {
        ZStack {
            Path { (path: inout Path) in
                path.addRect(frame)
                addOutline(&path)
            }
            .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
            Path { (path: inout Path) in
                addOutline(&path)
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2))
            ForEach(0..<4, id: \.self) { (index: Int) in
                handle(index)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func addOutline(_ path: inout Path) {
        guard points.count == 4 else { return }
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.addLine(to: points[3])
        path.closeSubpath()
    }

    private func handle(_ index: Int) -> some View {
        let big: Bool = index == selected || index == moving
        let side: CGFloat = big ? 26 : 20
        return Circle()
            .fill(Color.accentColor.opacity(0.35))
            .overlay(Circle().strokeBorder(Color.white, lineWidth: big ? 3 : 2))
            .frame(width: side, height: side)
            .position(points[index])
    }
}

/// The magnifier's cross at its center.
private struct LoupeCrosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: middle.x, y: middle.y - 14))
        path.addLine(to: CGPoint(x: middle.x, y: middle.y + 14))
        path.move(to: CGPoint(x: middle.x - 14, y: middle.y))
        path.addLine(to: CGPoint(x: middle.x + 14, y: middle.y))
        return path
    }
}
#endif
