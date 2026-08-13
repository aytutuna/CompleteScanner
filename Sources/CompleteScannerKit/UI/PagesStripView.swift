import AppKit
import CoreGraphics
import SwiftUI

/// Bottom strip listing the document page queue. The parent only shows this view
/// when `state.scannedPages` is non-empty.
struct PagesStripView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(state.scannedPages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnailCell(
                            page: page,
                            pageNumber: index + 1,
                            canMoveLeft: index > 0,
                            canMoveRight: index < state.scannedPages.count - 1,
                            onRemove: { state.removePage(id: page.id) },
                            onMove: { state.movePage(id: page.id, by: $0) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()
                .padding(.vertical, 10)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    state.savePDF()
                } label: {
                    let n = state.scannedPages.count
                    Text("Save PDF (\(n) page\(n == 1 ? "" : "s"))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || state.scannedPages.isEmpty)

                Button("Clear") {
                    state.clearPages()
                }
                .disabled(state.isBusy)
            }
            .padding(.trailing, 12)
        }
        .frame(height: 92)
        .background(.bar)
    }
}

// MARK: - File-private cell

fileprivate struct PageThumbnailCell: View {
    let page: ScannedPage
    let pageNumber: Int
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onRemove: () -> Void
    let onMove: (Int) -> Void

    @State private var thumbnail: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            thumbnailView
                .frame(height: 58)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay { if hovering { hoverControls } }
                .onHover { hovering = $0 }

            Text("Page \(pageNumber)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            if thumbnail == nil {
                thumbnail = stripThumbnail(page.image, maxDimension: 200)
            }
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
            Color.black.opacity(0.3)
            HStack {
                Button {
                    onMove(-1)
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                }
                .disabled(!canMoveLeft)
                .help("Move page left")

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
