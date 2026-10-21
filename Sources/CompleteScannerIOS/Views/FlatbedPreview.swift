#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// A corner of the scan area the user drags.
enum IOSCropHandle: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// Where it sits on a rectangle, as fractions of its width and height.
    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

/// What a drag on the flatbed preview does, decided where it starts.
enum IOSCropDragMode: Equatable {
    /// A new area, from the start point.
    case creating
    /// The area moves as a whole.
    case moving(original: CGRect)
    /// One corner moves.
    case resizing(handle: IOSCropHandle, original: CGRect)
}

/// What changes the scan area without dragging (VoiceOver's and Full Keyboard Access's actions, the crop
/// screen's Presets menu): a part of the glass, a move, or a larger or smaller area.
enum IOSCropCommand: CaseIterable {
    case wholeGlass
    case topHalf
    case bottomHalf
    case leftHalf
    case rightHalf
    case moveUp
    case moveDown
    case moveLeft
    case moveRight
    case larger
    case smaller

    /// The parts of the glass the Presets menu offers.
    static let presets: [IOSCropCommand] = [.wholeGlass, .topHalf, .bottomHalf, .leftHalf, .rightHalf]

    var name: String {
        switch self {
        case .wholeGlass: return "Whole glass"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .moveUp: return "Move area up"
        case .moveDown: return "Move area down"
        case .moveLeft: return "Move area left"
        case .moveRight: return "Move area right"
        case .larger: return "Make area larger"
        case .smaller: return "Make area smaller"
        }
    }
}

/// The scan area on the flatbed preview, as the Mac's preview canvas draws it: a rectangle in fractions of
/// the glass (0...1, origin top-left, `AppState.selectionRect`), made by dragging, moved by dragging inside
/// it, resized by its corners, never smaller than `minSide` nor beyond the glass.
enum IOSCropGeometry {
    /// The smallest side of an area resized by a corner.
    static let minSide: CGFloat = 0.04
    /// A drag that makes an area narrower or lower than this makes none.
    static let minCreated: CGFloat = 0.01
    /// How close to a corner, in points, a touch picks it up.
    static let handleReach: CGFloat = 28

    /// The frame an image of `imageSize` fills when fitted into `bounds`, centered.
    static func fitted(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: CGPoint.zero, size: bounds)
        }
        let scale: CGFloat = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width: CGFloat = imageSize.width * scale
        let height: CGFloat = imageSize.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// A point of the view as fractions of `frame`, kept on the glass.
    static func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return CGPoint.zero }
        let x: CGFloat = clamp((point.x - frame.minX) / frame.width, 0, 1)
        let y: CGFloat = clamp((point.y - frame.minY) / frame.height, 0, 1)
        return CGPoint(x: x, y: y)
    }

    /// An area in fractions of the glass, in the view's points.
    static func viewRect(_ area: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + area.minX * frame.width, y: frame.minY + area.minY * frame.height,
               width: area.width * frame.width, height: area.height * frame.height)
    }

    /// A corner of a rectangle.
    static func point(_ handle: IOSCropHandle, of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + handle.unit.x * rect.width, y: rect.minY + handle.unit.y * rect.height)
    }

    /// What a drag starting at `start` (view points) does with `area` shown in `frame`.
    static func mode(at start: CGPoint, area: CGRect?, frame: CGRect) -> IOSCropDragMode {
        guard let area else { return IOSCropDragMode.creating }
        let shown: CGRect = viewRect(area, in: frame)
        for handle in IOSCropHandle.allCases {
            let corner: CGPoint = point(handle, of: shown)
            let distance: CGFloat = hypot(corner.x - start.x, corner.y - start.y)
            if distance <= handleReach {
                return IOSCropDragMode.resizing(handle: handle, original: area)
            }
        }
        if shown.contains(start) {
            return IOSCropDragMode.moving(original: area)
        }
        return IOSCropDragMode.creating
    }

    /// The area during a drag from `start` to `location` (view points) in `frame`.
    static func dragged(_ mode: IOSCropDragMode, from start: CGPoint, to location: CGPoint, frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let dx: CGFloat = (location.x - start.x) / frame.width
        let dy: CGFloat = (location.y - start.y) / frame.height
        switch mode {
        case .creating:
            let a: CGPoint = normalized(start, in: frame)
            let b: CGPoint = normalized(location, in: frame)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .moving(let original):
            return moved(original, dx: dx, dy: dy)
        case .resizing(let handle, let original):
            return resized(original, handle: handle, dx: dx, dy: dy)
        }
    }

    /// The area at the end of a drag: nil for a new area too small to mean anything (a tap).
    static func finished(_ mode: IOSCropDragMode, area: CGRect) -> CGRect? {
        if mode == IOSCropDragMode.creating && (area.width < minCreated || area.height < minCreated) {
            return nil
        }
        return area
    }

    /// `rect` moved by fractions of the glass, kept on it.
    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let width: CGFloat = min(rect.width, 1)
        let height: CGFloat = min(rect.height, 1)
        let x: CGFloat = clamp(rect.minX + dx, 0, max(0, 1 - width))
        let y: CGFloat = clamp(rect.minY + dy, 0, max(0, 1 - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `rect` with one corner moved by fractions of the glass, kept on it and at least `minSide` a side.
    static func resized(_ rect: CGRect, handle: IOSCropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX: CGFloat = rect.minX
        var maxX: CGFloat = rect.maxX
        var minY: CGFloat = rect.minY
        var maxY: CGFloat = rect.maxY
        if handle.unit.x == 0 {
            minX = clamp(rect.minX + dx, 0, max(0, maxX - minSide))
        } else {
            maxX = clamp(rect.maxX + dx, min(1, minX + minSide), 1)
        }
        if handle.unit.y == 0 {
            minY = clamp(rect.minY + dy, 0, max(0, maxY - minSide))
        } else {
            maxY = clamp(rect.maxY + dy, min(1, minY + minSide), 1)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// How far a command (`apply`) moves an area, or moves each of its sides out or in, in fractions of the glass.
    static let commandStep: CGFloat = 0.05

    /// The area after `command`; nil is the whole glass (no area). Moving, or making larger, the whole
    /// glass changes nothing; making it smaller makes an area in its middle.
    static func apply(_ command: IOSCropCommand, to area: CGRect?) -> CGRect? {
        let step: CGFloat = commandStep
        switch command {
        case .wholeGlass:
            return nil
        case .topHalf:
            return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf:
            return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .leftHalf:
            return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf:
            return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .moveUp:
            guard let area else { return nil }
            return moved(area, dx: 0, dy: -step)
        case .moveDown:
            guard let area else { return nil }
            return moved(area, dx: 0, dy: step)
        case .moveLeft:
            guard let area else { return nil }
            return moved(area, dx: -step, dy: 0)
        case .moveRight:
            guard let area else { return nil }
            return moved(area, dx: step, dy: 0)
        case .larger:
            guard let area else { return nil }
            let minX: CGFloat = max(0, area.minX - step)
            let minY: CGFloat = max(0, area.minY - step)
            let maxX: CGFloat = min(1, area.maxX + step)
            let maxY: CGFloat = min(1, area.maxY + step)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .smaller:
            let base: CGRect = area ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let width: CGFloat = max(minSide, base.width - 2 * step)
            let height: CGFloat = max(minSide, base.height - 2 * step)
            return CGRect(x: base.midX - width / 2, y: base.midY - height / 2, width: width, height: height)
        }
    }

    /// The area as VoiceOver reads it: "Whole glass", or its size and place in percent of the glass.
    static func describe(_ area: CGRect?) -> String {
        guard let area else { return "Whole glass" }
        return "\(percent(area.width)) wide, \(percent(area.height)) high, \(percent(area.minX)) from the left, "
            + "\(percent(area.minY)) from the top"
    }

    private static func percent(_ value: CGFloat) -> String {
        let whole: Int = Int((value * 100).rounded())
        return "\(whole)%"
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}

/// The flatbed preview as the scan screen shows it, in its scrolling column: the scan area drawn, nothing
/// to drag (a drag there scrolls the screen). Tapping it opens `CropScreen`, where the area is chosen.
struct FlatbedThumbnail: View {
    @EnvironmentObject private var state: AppState
    let image: CGImage

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            FlatbedStage(image: image, area: state.selectionRect, size: geometry.size)
        }
    }
}

/// The flatbed preview full screen, to choose the scan area on: drag on the glass to make an area, inside
/// it to move it, a corner to resize it; Presets (and VoiceOver's actions) choose a part of the glass, and
/// Done goes back to the scan screen. The area is `AppState.selectionRect`, which the next flatbed scan uses.
struct CropScreen: View {
    @EnvironmentObject private var state: AppState
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image = state.overviewImage {
                    FlatbedPreview(image: image)
                        .padding(16)
                } else {
                    Spacer(minLength: 0)
                    Text("No preview")
                        .foregroundStyle(Color.secondary)
                    Spacer(minLength: 0)
                }
                Divider()
                HStack(spacing: 12) {
                    Menu {
                        ForEach(IOSCropCommand.presets, id: \.self) { (command: IOSCropCommand) in
                            Button(command.name) {
                                state.selectionRect = IOSCropGeometry.apply(command, to: state.selectionRect)
                            }
                        }
                    } label: {
                        Label("Presets", systemImage: "rectangle.dashed")
                    }
                    .disabled(state.overviewImage == nil)
                    .accessibilityIdentifier("crop.presets")
                    Spacer(minLength: 0)
                    Text(IOSCropGeometry.describe(state.selectionRect))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .accessibilityHidden(true)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Scan area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onClose()
                    }
                    .accessibilityIdentifier("crop.done")
                }
            }
        }
    }
}

/// The flatbed preview (the overview scan) with the scan area on it, to edit (`CropScreen`): drag on the
/// glass to choose an area, drag inside it to move it, drag a corner to resize it. For VoiceOver it is one
/// element, the scan area: swipe up or down makes it larger or smaller, and its actions choose a part of
/// the glass or move it.
struct FlatbedPreview: View {
    @EnvironmentObject private var state: AppState
    let image: CGImage
    @State private var drag: IOSCropDragMode?

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            let frame: CGRect = IOSCropGeometry.fitted(imageSize: CGSize(width: image.width, height: image.height),
                                                       in: geometry.size)
            FlatbedStage(image: image, area: state.selectionRect, size: geometry.size)
                .contentShape(Rectangle())
                .gesture(cropDrag(frame))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Scan area"))
                .accessibilityValue(Text(IOSCropGeometry.describe(state.selectionRect)))
                .accessibilityHint(Text("Swipe up or down to make it larger or smaller."))
                .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                    switch direction {
                    case .increment:
                        apply(IOSCropCommand.larger)
                    default:
                        apply(IOSCropCommand.smaller)
                    }
                }
                .accessibilityActions {
                    ForEach(IOSCropCommand.allCases, id: \.self) { (command: IOSCropCommand) in
                        Button(command.name) {
                            apply(command)
                        }
                    }
                }
                .accessibilityIdentifier("crop.editor")
        }
    }

    private func apply(_ command: IOSCropCommand) {
        state.selectionRect = IOSCropGeometry.apply(command, to: state.selectionRect)
    }

    private func cropDrag(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { (value: DragGesture.Value) in
                let mode: IOSCropDragMode
                if let current = drag {
                    mode = current
                } else {
                    mode = IOSCropGeometry.mode(at: value.startLocation, area: state.selectionRect, frame: frame)
                    drag = mode
                }
                state.selectionRect = IOSCropGeometry.dragged(mode, from: value.startLocation, to: value.location, frame: frame)
            }
            .onEnded { (value: DragGesture.Value) in
                if let mode = drag {
                    let area: CGRect = IOSCropGeometry.dragged(mode, from: value.startLocation, to: value.location, frame: frame)
                    state.selectionRect = IOSCropGeometry.finished(mode, area: area)
                }
                drag = nil
            }
    }
}

/// The preview fitted into `size`, with the scan area drawn over it when there is one (`area`, in fractions
/// of the glass).
private struct FlatbedStage: View {
    let image: CGImage
    let area: CGRect?
    let size: CGSize

    var body: some View {
        let frame: CGRect = IOSCropGeometry.fitted(imageSize: CGSize(width: image.width, height: image.height), in: size)
        return ZStack(alignment: Alignment.topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            if let area {
                CropOverlay(area: IOSCropGeometry.viewRect(area, in: frame), size: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The scan area drawn over the preview: the rest dimmed, a dashed outline and the four corners.
private struct CropOverlay: View {
    let area: CGRect
    let size: CGSize

    var body: some View {
        ZStack(alignment: Alignment.topLeading) {
            Path { (path: inout Path) in
                path.addRect(CGRect(x: 0, y: 0, width: size.width, height: max(0, area.minY)))
                path.addRect(CGRect(x: 0, y: area.maxY, width: size.width, height: max(0, size.height - area.maxY)))
                path.addRect(CGRect(x: 0, y: area.minY, width: max(0, area.minX), height: area.height))
                path.addRect(CGRect(x: area.maxX, y: area.minY, width: max(0, size.width - area.maxX), height: area.height))
            }
            .fill(Color.black.opacity(0.35))
            Rectangle()
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: max(area.width, 1), height: max(area.height, 1))
                .position(x: area.midX, y: area.midY)
            ForEach(IOSCropHandle.allCases, id: \.self) { (handle: IOSCropHandle) in
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .position(IOSCropGeometry.point(handle, of: area))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
