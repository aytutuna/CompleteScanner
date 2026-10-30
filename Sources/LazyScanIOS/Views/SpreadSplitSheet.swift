#if os(iOS)
import LazyScanKit
import CoreGraphics
import SwiftUI

/// Splitting a book's spread again by hand, as on the Mac (`AppState.spreadEditor(for:)`): the spread as
/// taken with the cut drawn across it, a slider that moves the cut, and Split (Split here for a spread cut in
/// two already, which also has Keep as one page). Split and Keep as one page are off while the app is busy.
/// The pages in the strip are replaced by the new ones (`AppState.splitSpread`, `joinSpread`).
struct SpreadSplitSheet: View {
    @EnvironmentObject private var state: AppState
    let source: SpreadEditorSource
    let onClose: @MainActor () -> Void
    @State private var fraction: Double

    init(source: SpreadEditorSource, onClose: @escaping @MainActor () -> Void) {
        self.source = source
        self.onClose = onClose
        _fraction = State(initialValue: source.fraction)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { (proxy: GeometryProxy) in
                    let fitted: CGRect = SpreadSplitSheet.fittedRect(width: source.preview.width,
                                                                     height: source.preview.height, in: proxy.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: source.preview, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        Path { (path: inout Path) in
                            if source.axis == .vertical {
                                let x: CGFloat = fitted.minX + fitted.width * CGFloat(fraction)
                                path.move(to: CGPoint(x: x, y: fitted.minY))
                                path.addLine(to: CGPoint(x: x, y: fitted.maxY))
                            } else {
                                let y: CGFloat = fitted.minY + fitted.height * CGFloat(fraction)
                                path.move(to: CGPoint(x: fitted.minX, y: y))
                                path.addLine(to: CGPoint(x: fitted.maxX, y: y))
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Spread \(source.spreadNumber)"))
                Slider(value: $fraction, in: 0.1...0.9)
                    .accessibilityLabel(Text("Where the spread is cut"))
                    .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
                    .accessibilityIdentifier("spread.cut")
                if source.isSplit {
                    Button("Keep as one page") {
                        state.joinSpread(id: source.pageID)
                        onClose()
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .accessibilityIdentifier("spread.keep")
                }
            }
            .padding(16)
            .navigationTitle("Spread \(source.spreadNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onClose()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(splitLabel) {
                        state.splitSpread(id: source.pageID, axis: source.axis, fraction: fraction)
                        onClose()
                    }
                    .disabled(state.isBusy)
                    .accessibilityIdentifier("spread.split")
                }
            }
        }
    }

    private var splitLabel: String {
        source.isSplit ? "Split here" : "Split"
    }

    /// Where a picture of `width` × `height` lies when fitted into `size`, centred.
    static func fittedRect(width: Int, height: Int, in size: CGSize) -> CGRect {
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale: CGFloat = min(size.width / CGFloat(width), size.height / CGFloat(height))
        let w: CGFloat = CGFloat(width) * scale
        let h: CGFloat = CGFloat(height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
#endif
