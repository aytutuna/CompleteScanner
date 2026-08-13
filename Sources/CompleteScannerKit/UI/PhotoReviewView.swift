import AppKit
import CoreGraphics
import SwiftUI

/// Sheet shown after a photo-mode scan: review the auto-split batch, drop false
/// detections, rotate as needed, then save the kept photos.
struct PhotoReviewView: View {
    @EnvironmentObject var state: AppState

    /// Photo whose crop is being corrected manually (drives the editor sheet).
    @State private var editingPhoto: DetectedPhoto?

    private var includedCount: Int {
        state.detectedPhotos.filter(\.included).count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Detected photos (\(state.detectedPhotos.count))")
                    .font(.title2.bold())
                Text("Uncheck any false detections, rotate if needed, then save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                    ForEach(state.detectedPhotos) { photo in
                        PhotoReviewCard(
                            photo: photo,
                            included: includedBinding(id: photo.id),
                            cropDisabled: state.isBusy,
                            onRotate: { rotate(id: photo.id, by: $0) },
                            onAdjustCrop: { editingPhoto = photo })
                    }
                }
                .padding()
            }

            Divider()

            HStack(spacing: 12) {
                Text("Want more? Lay the next photos on the bed and scan another batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    state.cancelPhotoReview()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save \(includedCount) Photo\(includedCount == 1 ? "" : "s")") {
                    state.saveReviewedPhotos()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(includedCount == 0 || state.isBusy)
            }
            .padding()
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity,
               minHeight: 440, idealHeight: 560, maxHeight: .infinity)
        .sheet(item: $editingPhoto) { photo in
            PhotoCropEditorView(photo: photo)
                .environmentObject(state)
        }
    }

    // MARK: File-local mutation helpers

    /// Binding to the `included` flag of the photo with `id` inside `state.detectedPhotos`.
    private func includedBinding(id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                state.detectedPhotos.first(where: { $0.id == id })?.included ?? false
            },
            set: { newValue in
                guard let idx = state.detectedPhotos.firstIndex(where: { $0.id == id }) else { return }
                state.detectedPhotos[idx].included = newValue
            })
    }

    private func rotate(id: UUID, by delta: Int) {
        guard let idx = state.detectedPhotos.firstIndex(where: { $0.id == id }) else { return }
        let turns = state.detectedPhotos[idx].rotationQuarterTurns + delta
        state.detectedPhotos[idx].rotationQuarterTurns = ((turns % 4) + 4) % 4
    }
}

// MARK: - File-private card

fileprivate struct PhotoReviewCard: View {
    let photo: DetectedPhoto
    @Binding var included: Bool
    let cropDisabled: Bool
    let onRotate: (Int) -> Void
    let onAdjustCrop: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .rotationEffect(.degrees(Double(photo.rotationQuarterTurns) * 90))
                        .animation(.easeInOut(duration: 0.15), value: photo.rotationQuarterTurns)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 150, height: 150)
            .opacity(included ? 1 : 0.35)

            Text(sizeCaption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 10) {
                Toggle("Include", isOn: $included)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Spacer(minLength: 4)

                Button(action: onAdjustCrop) {
                    Image(systemName: "crop")
                }
                .disabled(cropDisabled)
                .help("Adjust the crop manually")

                Button {
                    onRotate(-1)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate 90° counterclockwise")

                Button {
                    onRotate(1)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate 90° clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        // Keyed on the region so a manual re-crop re-renders the thumbnail.
        .task(id: photo.region) {
            thumbnail = reviewThumbnail(photo.image, maxDimension: 340)
        }
    }

    private var sizeCaption: String {
        let w = photo.image.width, h = photo.image.height
        let dpi = Double(max(photo.dpi, 1))
        return String(format: "%d × %d px · %.1f × %.1f in", w, h, Double(w) / dpi, Double(h) / dpi)
    }
}

// MARK: - File-private helpers

/// Downsample a full-resolution extracted photo for its ~150 pt review thumbnail.
fileprivate func reviewThumbnail(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
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
