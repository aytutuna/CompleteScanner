import AppKit
import CoreGraphics
import SwiftUI

/// Central preview area: shows the overview / last scan, hosts the marquee selection
/// (only meaningful over an overview image, which maps 1:1 to the flatbed), and draws
/// informational outlines for detected photos.
struct PreviewCanvasView: View {
    @EnvironmentObject var state: AppState

    /// Downsampled copy of `state.canvasImage` actually handed to SwiftUI.
    @State private var displayImage: CGImage?
    /// In-flight marquee drag, captured on the first `onChanged`.
    @State private var dragState: CanvasDragState?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = state.canvasImage {
                GeometryReader { geo in
                    let frame = fittedImageFrame(imageSize: CGSize(width: image.width, height: image.height),
                                                 in: canvasBounds(for: geo.size))
                    imageLayer(frame: frame)
                    if state.overviewImage != nil {
                        selectionLayer(frame: frame, viewSize: geo.size)
                    } else if !state.detectedPhotos.isEmpty {
                        detectedPhotosOverlay(image: image, frame: frame)
                    }
                }
                .task(id: ObjectIdentifier(image)) {
                    displayImage = canvasDownsample(image, maxDimension: 2600)
                }
            } else {
                emptyState
            }
        }
        .clipped()
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "scanner")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Press Preview to see the flatbed, or Scan to go straight ahead")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No scanner around? Pick the Demo Scanner in the sidebar to try everything out.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Image

    private func imageLayer(frame: CGRect) -> some View {
        Group {
            if let displayImage {
                Image(decorative: displayImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .position(x: frame.midX, y: frame.midY)
    }

    // MARK: Selection (overview only)

    private func selectionLayer(frame: CGRect, viewSize: CGSize) -> some View {
        ZStack {
            if let sel = state.selectionRect {
                let rect = viewRect(forNormalized: sel, in: frame)
                dimmedExterior(around: rect, viewSize: viewSize)
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                selectionHandles(rect: rect)
                sizeChip(selection: sel, rect: rect, viewSize: viewSize)
                clearChip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.selectionRect = nil }
        .gesture(selectionDrag(frame: frame))
    }

    /// Four rects dimming everything outside the selection.
    private func dimmedExterior(around rect: CGRect, viewSize: CGSize) -> some View {
        Path { p in
            let full = CGRect(origin: .zero, size: viewSize)
            p.addRect(CGRect(x: 0, y: 0, width: full.width, height: max(0, rect.minY)))                                // top
            p.addRect(CGRect(x: 0, y: rect.maxY, width: full.width, height: max(0, full.height - rect.maxY)))          // bottom
            p.addRect(CGRect(x: 0, y: rect.minY, width: max(0, rect.minX), height: rect.height))                       // left
            p.addRect(CGRect(x: rect.maxX, y: rect.minY, width: max(0, full.width - rect.maxX), height: rect.height))  // right
        }
        .fill(Color.black.opacity(0.35))
        .allowsHitTesting(false)
    }

    private func selectionHandles(rect: CGRect) -> some View {
        ForEach(SelectionHandle.allCases, id: \.self) { handle in
            Rectangle()
                .fill(Color.accentColor)
                .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1))
                .frame(width: 7, height: 7)
                .position(handle.point(in: rect))
                .allowsHitTesting(false)
        }
    }

    private func sizeChip(selection: CGRect, rect: CGRect, viewSize: CGSize) -> some View {
        Group {
            if let caps = state.capabilities {
                let w = Double(selection.width * caps.flatbedSizeInches.width)
                let h = Double(selection.height * caps.flatbedSizeInches.height)
                Text(String(format: "%.1f × %.1f in", w, h))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .position(x: min(max(rect.midX, 50), max(50, viewSize.width - 50)),
                              y: min(rect.maxY + 16, max(12, viewSize.height - 14)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var clearChip: some View {
        Button {
            state.selectionRect = nil
        } label: {
            Label("Clear selection", systemImage: "xmark.circle.fill")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove the scan area selection (or double-click the preview)")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }

    private func selectionDrag(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragState == nil {
                    dragState = beginDrag(at: value.startLocation, frame: frame)
                }
                if let dragState {
                    state.selectionRect = updatedSelection(dragState, value: value, frame: frame)
                }
            }
            .onEnded { value in
                if let ds = dragState {
                    var rect = updatedSelection(ds, value: value, frame: frame)
                    if case .creating = ds.mode, let r = rect, r.width < 0.01 || r.height < 0.01 {
                        rect = nil // Degenerate drag: treat as no selection.
                    }
                    state.selectionRect = rect
                }
                dragState = nil
            }
    }

    private func beginDrag(at start: CGPoint, frame: CGRect) -> CanvasDragState {
        if let sel = state.selectionRect {
            let rect = viewRect(forNormalized: sel, in: frame)
            for handle in SelectionHandle.allCases {
                let p = handle.point(in: rect)
                if hypot(p.x - start.x, p.y - start.y) <= 10 {
                    return CanvasDragState(mode: .resizing(handle: handle, original: sel))
                }
            }
            if rect.contains(start) {
                return CanvasDragState(mode: .moving(original: sel))
            }
        }
        return CanvasDragState(mode: .creating)
    }

    private func updatedSelection(_ ds: CanvasDragState, value: DragGesture.Value, frame: CGRect) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return state.selectionRect }
        let dx = (value.location.x - value.startLocation.x) / frame.width
        let dy = (value.location.y - value.startLocation.y) / frame.height

        switch ds.mode {
        case .creating:
            let a = normalizedPoint(value.startLocation, in: frame)
            let b = normalizedPoint(value.location, in: frame)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))

        case .moving(let orig):
            let x = clampUnit(orig.minX + dx, 0, max(0, 1 - orig.width))
            let y = clampUnit(orig.minY + dy, 0, max(0, 1 - orig.height))
            return CGRect(x: x, y: y, width: min(orig.width, 1), height: min(orig.height, 1))

        case .resizing(let handle, let orig):
            let minSide: CGFloat = 0.04
            var minX = orig.minX, maxX = orig.maxX, minY = orig.minY, maxY = orig.maxY
            if handle.movesLeft { minX = clampUnit(orig.minX + dx, 0, max(0, maxX - minSide)) }
            if handle.movesRight { maxX = clampUnit(orig.maxX + dx, min(1, minX + minSide), 1) }
            if handle.movesTop { minY = clampUnit(orig.minY + dy, 0, max(0, maxY - minSide)) }
            if handle.movesBottom { maxY = clampUnit(orig.maxY + dy, min(1, minY + minSide), 1) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    // MARK: Detected photo outlines (informational, scan image only)

    private func detectedPhotosOverlay(image: CGImage, frame: CGRect) -> some View {
        let sx = frame.width / CGFloat(image.width)
        let sy = frame.height / CGFloat(image.height)
        return ForEach(Array(state.detectedPhotos.enumerated()), id: \.element.id) { index, photo in
            let pts = photo.region.corners.map {
                CGPoint(x: frame.minX + $0.x * sx, y: frame.minY + $0.y * sy)
            }
            let center = CGPoint(x: frame.minX + photo.region.center.x * sx,
                                 y: frame.minY + photo.region.center.y * sy)
            ZStack {
                Path { p in
                    guard pts.count == 4 else { return }
                    p.move(to: pts[0])
                    p.addLine(to: pts[1])
                    p.addLine(to: pts[2])
                    p.addLine(to: pts[3])
                    p.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                Text("\(index + 1)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color.accentColor))
                    .position(center)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - File-private geometry helpers

/// The in-flight marquee interaction, decided from where the drag started.
fileprivate struct CanvasDragState {
    enum Mode {
        case creating
        case moving(original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
    }
    var mode: Mode
}

/// The 8 square resize handles of the marquee, addressed by their unit position on the rect.
fileprivate enum SelectionHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
    }

    var movesLeft: Bool { unit.x == 0 }
    var movesRight: Bool { unit.x == 1 }
    var movesTop: Bool { unit.y == 0 }
    var movesBottom: Bool { unit.y == 1 }
}

/// Bounds the image is fitted into: the canvas with a comfortable margin.
fileprivate func canvasBounds(for size: CGSize) -> CGRect {
    let inset = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
    return (inset.isNull || inset.isEmpty) ? CGRect(origin: .zero, size: size) : inset
}

/// Aspect-fit frame (view coordinates) for an image of `imageSize` centered in `bounds`.
/// All selection math is done relative to this rect.
fileprivate func fittedImageFrame(imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
        return bounds
    }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
}

/// Normalized (0...1, top-left origin) selection rect -> view coordinates.
fileprivate func viewRect(forNormalized r: CGRect, in frame: CGRect) -> CGRect {
    CGRect(x: frame.minX + r.minX * frame.width,
           y: frame.minY + r.minY * frame.height,
           width: r.width * frame.width,
           height: r.height * frame.height)
}

/// View-coordinate point -> normalized (clamped 0...1) point relative to the fitted frame.
fileprivate func normalizedPoint(_ p: CGPoint, in frame: CGRect) -> CGPoint {
    CGPoint(x: clampUnit((p.x - frame.minX) / frame.width, 0, 1),
            y: clampUnit((p.y - frame.minY) / frame.height, 0, 1))
}

fileprivate func clampUnit(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(v, lo), hi)
}

/// Downsample the (possibly huge) scan for on-screen display.
fileprivate func canvasDownsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
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
