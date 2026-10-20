import AppKit
import CoreGraphics
import SwiftUI

/// The corner editor of a photo of a document whose page was not found clearly
/// (`PhotoImport.plan(_:)`): the whole photo with the page's four corners, each dragged on its own
/// onto a corner of the page (a magnifier shows the photo around the corner being moved), or moved
/// with the arrow keys. Use these corners cuts the page out along them, Use whole photo takes the
/// photo as it is, and Skip leaves the photo out (`AppState.answerCorners`). Built like the crop
/// editor (`PhotoCropEditorView`). Twin of the Windows `PhotoCornersWindow`.
///
/// Coordinates: `corners` are in the photo's pixels (top-left origin, y down); the view maps them onto
/// the letterboxed display frame with a scale and an offset.
struct PhotoCornersEditorView: View {
    @EnvironmentObject var state: AppState

    let request: PhotoCornersRequest

    /// The corners as placed, in the photo's pixels.
    @State private var corners: Quad
    /// Downsampled photo for display.
    @State private var display: CGImage?
    /// The corner being dragged, if any.
    @State private var dragging: Int?
    /// The corner the arrow keys move (0 top-left … 3 bottom-left, as placed).
    @State private var selected = 0
    /// The magnifier is shown: while a corner is dragged or moved with the keys.
    @State private var showLoupe = false
    /// The stage has the keyboard, so the corners take the arrow keys right away.
    @FocusState private var stageFocused: Bool

    private let handleHitRadius: CGFloat = 16
    private let loupeSize: CGFloat = 132
    private let loupeZoom: CGFloat = 3
    private let loupeGap: CGFloat = 18

    init(request: PhotoCornersRequest) {
        self.request = request
        _corners = State(initialValue: request.plan.corners)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let display {
                        Image(decorative: display, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    } else {
                        ProgressView()
                    }
                    outline(frame: frame, in: geo.size)
                    loupe(frame: frame, in: geo.size)
                }
                .contentShape(Rectangle())
                .gesture(cornerDrag(frame: frame))
            }
            .focusable()
            .focusEffectDisabled()
            .focused($stageFocused)
            .onAppear { stageFocused = true }
            .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
                guard let digit = press.characters.first, let value = Int(String(digit)) else { return .ignored }
                selected = value - 1
                showLoupe = true
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                nudge(press.key, bigger: press.modifiers.contains(.shift))
                return .handled
            }
            .accessibilityLabel("Page corners")
            .accessibilityHint(PhotoImport.editorHelp)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 520, idealHeight: 720)
        .task {
            let photo = request.photo
            display = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let scale = min(1, 2200 / Double(max(photo.width, photo.height, 1)))
                let shown = scale < 1
                    ? photo.resized(width: max(1, Int(Double(photo.width) * scale)), height: max(1, Int(Double(photo.height) * scale)))
                    : photo
                return shown.makeCGImage()
            }.value
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PhotoImport.editorTitle)
                    .font(.title3.bold())
                let reason = PhotoImport.reasonText(request.plan.reason)
                if !reason.isEmpty {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                }
                Text(PhotoImport.editorHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(PhotoImport.counter(request.number, of: request.count, fileName: request.fileName), systemImage: "photo")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(request.fileName)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Reset") { corners = request.plan.corners }
                .disabled(corners == request.plan.corners)
                .help("Go back to the corners found in the photo")
            Button(PhotoImport.wholePhotoLabel) {
                state.answerCorners(PhotoCornersAnswer(choice: .wholePhoto))
            }
            .help("Add the whole photo as the page, as it is")
            Spacer()
            Button(PhotoImport.skipLabel) { state.answerCorners(.skip) }
                .keyboardShortcut(.cancelAction)
            Button(PhotoImport.useCornersLabel) {
                state.answerCorners(PhotoCornersAnswer(choice: .useCorners, corners: corners))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!PhotoImport.canUseCorners(corners))
        }
        .padding()
    }

    // MARK: - Geometry

    private var photoSize: CGSize {
        CGSize(width: max(request.photo.width, 1), height: max(request.photo.height, 1))
    }

    /// Aspect-fit frame of the photo in the editor viewport.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 20)
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let pixel = photoSize
        let scale = min(bounds.width / pixel.width, bounds.height / pixel.height)
        let w = pixel.width * scale, h = pixel.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func viewPoint(_ imagePoint: CGPoint, frame: CGRect) -> CGPoint {
        let pixel = photoSize
        return CGPoint(x: frame.minX + imagePoint.x / pixel.width * frame.width,
                       y: frame.minY + imagePoint.y / pixel.height * frame.height)
    }

    private func imagePoint(_ viewPoint: CGPoint, frame: CGRect) -> CGPoint {
        let pixel = photoSize
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - frame.minX) / frame.width * pixel.width,
                       y: (viewPoint.y - frame.minY) / frame.height * pixel.height)
    }

    // MARK: - Overlay

    /// The page's outline, the photo outside it dimmed, and the four handles (the selected one larger).
    private func outline(frame: CGRect, in size: CGSize) -> some View {
        let points = corners.corners.map { viewPoint($0, frame: frame) }
        return ZStack {
            Path { p in
                p.addRect(frame)
                p.move(to: points[0])
                p.addLine(to: points[1])
                p.addLine(to: points[2])
                p.addLine(to: points[3])
                p.closeSubpath()
            }
            .fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
            Path { p in
                p.move(to: points[0])
                p.addLine(to: points[1])
                p.addLine(to: points[2])
                p.addLine(to: points[3])
                p.closeSubpath()
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2))
            ForEach(0..<4, id: \.self) { index in
                let side: CGFloat = index == selected ? 18 : 14
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: index == selected ? 3 : 2))
                    .frame(width: side, height: side)
                    .position(points[index])
            }
        }
        .allowsHitTesting(false)
    }

    /// The magnifier over the selected corner's surroundings, beside the corner away from the page's
    /// middle, kept in the viewport.
    @ViewBuilder
    private func loupe(frame: CGRect, in size: CGSize) -> some View {
        if showLoupe, let display, frame.width > 0 {
            let points = corners.corners.map { viewPoint($0, frame: frame) }
            let corner = points[selected]
            let middle = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
            let center = loupeCenter(corner: corner, middle: middle, in: size)
            ZStack(alignment: .topLeading) {
                Image(decorative: display, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width * loupeZoom, height: frame.height * loupeZoom)
                    .offset(x: loupeSize / 2 - (corner.x - frame.minX) * loupeZoom,
                            y: loupeSize / 2 - (corner.y - frame.minY) * loupeZoom)
            }
            .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .overlay(
                Path { p in
                    p.move(to: CGPoint(x: loupeSize / 2, y: loupeSize / 2 - 14))
                    p.addLine(to: CGPoint(x: loupeSize / 2, y: loupeSize / 2 + 14))
                    p.move(to: CGPoint(x: loupeSize / 2 - 14, y: loupeSize / 2))
                    p.addLine(to: CGPoint(x: loupeSize / 2 + 14, y: loupeSize / 2))
                }
                .stroke(Color.accentColor, lineWidth: 1)
            )
            .position(center)
            .allowsHitTesting(false)
        }
    }

    /// Where the magnifier sits: diagonally outward from the corner (away from the page's middle), else
    /// the first of the other diagonals that keeps it in the viewport.
    private func loupeCenter(corner: CGPoint, middle: CGPoint, in size: CGSize) -> CGPoint {
        let dx: CGFloat = corner.x >= middle.x ? 1 : -1, dy: CGFloat = corner.y >= middle.y ? 1 : -1
        let reach = loupeSize / 2 + loupeGap
        let candidates = [(dx, dy), (-dx, dy), (dx, -dy), (-dx, -dy)].map {
            CGPoint(x: corner.x + $0.0 * reach, y: corner.y + $0.1 * reach)
        }
        let half = loupeSize / 2
        return candidates.first { $0.x - half >= 0 && $0.y - half >= 0 && $0.x + half <= size.width && $0.y + half <= size.height }
            ?? candidates[3]
    }

    // MARK: - Dragging and keys

    private func cornerDrag(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    guard let index = handle(at: value.startLocation, frame: frame) else { return }
                    dragging = index
                    selected = index
                    showLoupe = true
                }
                guard let index = dragging else { return }
                // The corner stays on the photo when the pointer leaves it.
                corners = PhotoImport.movedCorner(corners, index: index, to: imagePoint(value.location, frame: frame),
                                                  width: request.photo.width, height: request.photo.height)
            }
            .onEnded { _ in
                dragging = nil
                showLoupe = false
            }
    }

    /// The corner whose handle is under `location`, the nearest when handles overlap.
    private func handle(at location: CGPoint, frame: CGRect) -> Int? {
        var best: Int?
        var bestDistance = handleHitRadius
        for index in 0..<4 {
            let p = viewPoint(corners[index], frame: frame)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// The selected corner moved by one display pixel (ten with Shift) with an arrow key.
    private func nudge(_ key: KeyEquivalent, bigger: Bool) {
        var dx = 0.0, dy = 0.0
        switch key {
        case .leftArrow: dx = -1
        case .rightArrow: dx = 1
        case .upArrow: dy = -1
        case .downArrow: dy = 1
        default: return
        }
        // One display pixel of a photo shown at about 800 points across.
        var step = max(1, Double(request.photo.width) / 800)
        if bigger { step *= 10 }
        let at = corners[selected]
        corners = PhotoImport.movedCorner(corners, index: selected,
                                          to: CGPoint(x: Double(at.x) + dx * step, y: Double(at.y) + dy * step),
                                          width: request.photo.width, height: request.photo.height)
        showLoupe = true
    }
}
