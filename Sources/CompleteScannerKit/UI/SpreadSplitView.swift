import CoreGraphics
import SwiftUI

/// What the split sheet was closed with (`SpreadSplitView`). Twin of the Windows `SpreadSplitChoice`.
enum SpreadSplitChoice: Equatable {
    /// Cut the spread at `fraction` of it along `axis`.
    case split(axis: GutterAxis, fraction: Double)
    /// Keep the spread as one page.
    case keepWhole
}

/// Splitting a spread by hand: the spread as scanned with the cut drawn across it; a click or drag on
/// the spread, or the slider, moves the cut, and the pages lie side by side or one above the other.
/// The strip splits or joins the spread with the choice (`AppState.splitSpread`,
/// `AppState.joinSpread`). Twin of the Windows `SpreadSplitWindow`.
struct SpreadSplitView: View {
    let source: SpreadEditorSource
    /// Called with the user's choice when the sheet closes with Split or Keep as One Page; not on Cancel.
    let onDone: (SpreadSplitChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var axis: GutterAxis
    @State private var fraction: Double

    /// The slider's range: the cut stays this far from the spread's edges.
    private static let range: ClosedRange<Double> = 0.05...0.95

    init(source: SpreadEditorSource, onDone: @escaping (SpreadSplitChoice) -> Void) {
        self.source = source
        self.onDone = onDone
        _axis = State(initialValue: source.axis)
        _fraction = State(initialValue: min(max(source.fraction, Self.range.lowerBound), Self.range.upperBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split Spread \(source.spreadNumber)")
                .font(.headline)
            Text("Click or drag on the spread to place the cut at the spine, or use the slider. Choose how the pages lie if the book was on its side.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                let size = fittedSize(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: source.preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .shadow(radius: 4)
                    cutLine(size: size)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    moveCut(to: value.location, in: size)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement()
                .accessibilityLabel("Spread")
                .accessibilityValue("Cut \(Int((fraction * 100).rounded()))% from the \(axis == .vertical ? "left" : "top")")
            }
            .frame(minHeight: 360)
            Picker("Pages lie", selection: $axis) {
                Text("Side by Side").tag(GutterAxis.vertical)
                Text("One Above the Other").tag(GutterAxis.horizontal)
            }
            .pickerStyle(.segmented)
            .help("Side by side: the spine runs up and down the scan. One above the other: the book lay on its side.")
            Slider(value: $fraction, in: Self.range) {
                Text("Cut")
            }
            .accessibilityLabel("Where the spread is cut")
            HStack {
                if source.isSplit {
                    Button("Keep as One Page") {
                        onDone(.keepWhole)
                        dismiss()
                    }
                    .help("Join the two pages: the spread is saved as one page.")
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(source.isSplit ? "Split Here" : "Split") {
                    onDone(.split(axis: axis, fraction: fraction))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
    }

    /// The spread's size fitted into `available`, keeping its shape.
    private func fittedSize(in available: CGSize) -> CGSize {
        let w = CGFloat(source.preview.width), h = CGFloat(source.preview.height)
        guard w > 0, h > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / w, available.height / h)
        return CGSize(width: w * scale, height: h * scale)
    }

    /// The cut, drawn across the spread.
    @ViewBuilder
    private func cutLine(size: CGSize) -> some View {
        if axis == .vertical {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: size.height)
                .offset(x: CGFloat(fraction) * size.width - 1, y: 0)
        } else {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: size.width, height: 2)
                .offset(x: 0, y: CGFloat(fraction) * size.height - 1)
        }
    }

    /// The cut moved to where the spread was clicked or dragged, kept within the slider's range.
    private func moveCut(to location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let share = axis == .vertical ? Double(location.x / size.width) : Double(location.y / size.height)
        fraction = min(max(share, Self.range.lowerBound), Self.range.upperBound)
    }
}
