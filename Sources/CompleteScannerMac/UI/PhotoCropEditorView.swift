#if os(macOS)
import AppKit
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// Manual crop correction for one detected photo: shows the whole bed scan with the
/// photo's (rotated) crop rectangle; corners drag to resize against the fixed opposite
/// corner, and dragging inside moves the crop. "Apply" re-extracts the photo from the
/// full-resolution source.
struct PhotoCropEditorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let photo: DetectedPhoto

    /// The crop being edited, in full-resolution source pixel coordinates.
    @State private var region: DetectedPhotoRegion
    /// Downsampled bed image for display.
    @State private var display: CGImage?
    @State private var dragMode: DragMode?

    init(photo: DetectedPhoto) {
        self.photo = photo
        _region = State(initialValue: photo.region)
    }

    private enum DragMode {
        case corner(Int, fixed: CGPoint)   // dragged corner index + the opposite corner (image coords)
        case move(originalCenter: CGPoint)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adjust Crop")
                        .font(.title3.bold())
                    // No keyboard help here: unlike the Windows editor, this view has no arrow-key handling.
                    Text("Drag corners to resize, or inside to move.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(sizeCaption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding()

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
                    cropOverlay(frame: frame)
                }
                .contentShape(Rectangle())
                .gesture(cropDrag(frame: frame))
            }

            Divider()

            HStack {
                Button("Reset") { region = photo.region }
                    .disabled(region == photo.region)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    state.recropPhoto(id: photo.id, region: region)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 520, idealHeight: 680)
        .task {
            if let source = state.photoSource(for: photo) {
                display = await Task.detached(priority: .userInitiated) {
                    editorDownsample(source, maxDimension: 2200)
                }.value
            }
        }
    }

    // MARK: - Geometry

    private var sourcePixelSize: CGSize {
        guard let source = state.photoSource(for: photo) else { return CGSize(width: 1, height: 1) }
        return CGSize(width: max(source.width, 1), height: max(source.height, 1))
    }

    private var sizeCaption: String {
        String(format: "%.0f × %.0f px  ·  %.1f°",
               region.size.width, region.size.height, region.angleDegrees)
    }

    /// Aspect-fit frame of the bed image in the editor viewport.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 20)
        let pixel = sourcePixelSize
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / pixel.width, bounds.height / pixel.height)
        let w = pixel.width * scale, h = pixel.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func viewPoint(_ imagePoint: CGPoint, frame: CGRect) -> CGPoint {
        let pixel = sourcePixelSize
        return CGPoint(x: frame.minX + imagePoint.x / pixel.width * frame.width,
                       y: frame.minY + imagePoint.y / pixel.height * frame.height)
    }

    private func imagePoint(_ viewPoint: CGPoint, frame: CGRect) -> CGPoint {
        let pixel = sourcePixelSize
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - frame.minX) / frame.width * pixel.width,
                       y: (viewPoint.y - frame.minY) / frame.height * pixel.height)
    }

    // MARK: - Overlay

    private func cropOverlay(frame: CGRect) -> some View {
        let corners = region.corners.map { viewPoint($0, frame: frame) }
        return ZStack {
            Path { p in
                guard corners.count == 4 else { return }
                p.move(to: corners[0])
                p.addLine(to: corners[1])
                p.addLine(to: corners[2])
                p.addLine(to: corners[3])
                p.closeSubpath()
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2))

            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    .frame(width: 13, height: 13)
                    .position(corners[index])
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dragging

    private func cropDrag(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == nil {
                    dragMode = beginDrag(at: value.startLocation, frame: frame)
                }
                guard let mode = dragMode else { return }
                switch mode {
                case .corner(_, let fixed):
                    resize(draggedTo: imagePoint(value.location, frame: frame), fixedCorner: fixed)
                case .move(let originalCenter):
                    let start = imagePoint(value.startLocation, frame: frame)
                    let now = imagePoint(value.location, frame: frame)
                    region.center = CGPoint(x: originalCenter.x + (now.x - start.x),
                                            y: originalCenter.y + (now.y - start.y))
                }
            }
            .onEnded { _ in dragMode = nil }
    }

    private func beginDrag(at start: CGPoint, frame: CGRect) -> DragMode? {
        let corners = region.corners
        let viewCorners = corners.map { viewPoint($0, frame: frame) }
        for (index, corner) in viewCorners.enumerated() {
            if hypot(corner.x - start.x, corner.y - start.y) <= 14 {
                return .corner(index, fixed: corners[(index + 2) % 4])
            }
        }
        if pointInsidePolygon(imagePoint(start, frame: frame), corners) {
            return .move(originalCenter: region.center)
        }
        return nil
    }

    /// Resize keeping `fixedCorner` in place: express the dragged point in the region's
    /// rotated frame relative to the fixed corner; the absolute components are the new
    /// width/height and the center sits halfway along the diagonal.
    private func resize(draggedTo dragged: CGPoint, fixedCorner: CGPoint) {
        let a = region.angleDegrees * .pi / 180
        let ux = CGPoint(x: cos(a), y: sin(a))    // local +x axis in image coords
        let uy = CGPoint(x: -sin(a), y: cos(a))   // local +y axis
        let vx = dragged.x - fixedCorner.x
        let vy = dragged.y - fixedCorner.y
        var lx = vx * ux.x + vy * ux.y
        var ly = vx * uy.x + vy * uy.y
        let minSide: CGFloat = 24
        lx = lx < 0 ? min(lx, -minSide) : max(lx, minSide)
        ly = ly < 0 ? min(ly, -minSide) : max(ly, minSide)
        region.size = CGSize(width: abs(lx), height: abs(ly))
        region.center = CGPoint(x: fixedCorner.x + (ux.x * lx + uy.x * ly) / 2,
                                y: fixedCorner.y + (ux.y * lx + uy.y * ly) / 2)
    }
}

// MARK: - File-private helpers

fileprivate func pointInsidePolygon(_ p: CGPoint, _ corners: [CGPoint]) -> Bool {
    guard corners.count >= 3 else { return false }
    var sign = 0.0
    for i in 0..<corners.count {
        let a = corners[i], b = corners[(i + 1) % corners.count]
        let cross = Double((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x))
        if cross != 0 {
            if sign == 0 { sign = cross > 0 ? 1 : -1 }
            else if (cross > 0 ? 1.0 : -1.0) != sign { return false }
        }
    }
    return true
}

fileprivate func editorDownsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
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
#endif
