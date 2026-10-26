#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// The photo and receipt review on the iPhone and iPad (I13), a port of the Mac's `PhotoReviewView` and
/// the Windows review: titled "Found 3 photos" (or "Found 2 receipts"), a card per photo or receipt with
/// Keep, Rotate and Fix crop (the touch corner editor on the picture it was cut from), the receipts' name by
/// date, one PDF for all and PDF or JPEG, then Save ("Save 3 photos", "Save as One PDF") or Cancel. What it
/// does is `IOSPhotoReviewModel`; this view draws it. It shows the error alert itself, since the root's
/// cannot show over it.
struct PhotoReviewScreen: View {
    @EnvironmentObject private var state: AppState
    let model: IOSPhotoReviewModel
    @State private var cropping: IOSCropRequest?
    @State private var preparing: Bool = false

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12, alignment: .top)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(entries) { (entry: ReviewEntry) in
                            ReviewCard(photo: entry.photo, number: entry.number, busy: state.isBusy || preparing,
                                       onToggle: { model.toggle(entry.id) },
                                       onRotate: { model.rotate(entry.id) },
                                       onCrop: { fixCrop(entry.photo, number: entry.number) })
                        }
                    }
                    .padding(16)
                }
                .accessibilityHint(Text(IOSReviewText.listHelp))
                Divider()
                footer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSReviewText.cancelLabel) {
                        model.cancel()
                    }
                    .disabled(state.isBusy)
                    .accessibilityIdentifier("review.cancel")
                }
            }
        }
        .fullScreenCover(item: $cropping) { (crop: IOSCropRequest) in
            CornerEditorView(request: crop.request, onAnswer: { (answer: PhotoCornersAnswer) -> Void in
                finishCrop(crop, answer: answer)
            }, onStop: closeCrop, fixesCrop: true)
        }
        .modifier(ErrorAlert(state: state))
    }

    /// The photos with their numbers (from 1), in order.
    private var entries: [ReviewEntry] {
        var list: [ReviewEntry] = []
        var number: Int = 1
        for photo in state.detectedPhotos {
            list.append(ReviewEntry(photo: photo, number: number))
            number += 1
        }
        return list
    }

    /// The receipts' choices, the progress of a save, and Save.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isReceipts {
                Toggle(IOSReviewText.nameByDateLabel, isOn: nameByDate)
                    .disabled(state.isBusy)
                    .accessibilityIdentifier("review.nameByDate")
                if model.offersCombine {
                    Toggle(IOSReviewText.combineLabel, isOn: combine)
                        .disabled(state.isBusy)
                        .accessibilityIdentifier("review.combine")
                }
                Picker(IOSReviewText.saveAsLabel, selection: format) {
                    ForEach(model.formats) { (choice: OutputFormat) in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(state.isBusy)
                .accessibilityIdentifier("review.format")
                if IOSShell.reviewOffersPassword(state.settings) {
                    Toggle(PDFProtection.optionLabel, isOn: protect)
                        .disabled(state.isBusy || IOSPDFOptions.archivalShown(state.settings.output))
                        .accessibilityHint(Text(PDFProtection.optionHint))
                        .accessibilityIdentifier("review.password")
                }
            }
            if state.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(state.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.progress")
            }
            Button {
                model.save()
            } label: {
                Text(model.saveTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)
            .accessibilityIdentifier("review.save")
        }
        .padding(16)
    }

    private var nameByDate: Binding<Bool> {
        let review: IOSPhotoReviewModel = model
        return Binding<Bool>(get: { review.nameByDate }, set: { (on: Bool) in review.setNameByDate(on) })
    }

    private var combine: Binding<Bool> {
        let review: IOSPhotoReviewModel = model
        return Binding<Bool>(get: { review.combine }, set: { (on: Bool) in review.setCombine(on) })
    }

    private var protect: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(get: { appState.settings.output.protect },
                             set: { (on: Bool) in
                                 appState.settings.output = IOSPDFOptions.settingProtect(on, in: appState.settings.output)
                             })
    }

    private var format: Binding<OutputFormat> {
        let review: IOSPhotoReviewModel = model
        return Binding<OutputFormat>(get: { review.format }, set: { (choice: OutputFormat) in review.setFormat(choice) })
    }

    /// Opens the corner editor on the picture `photo` was cut from, once it is read.
    private func fixCrop(_ photo: DetectedPhoto, number: Int) {
        guard !preparing, !state.isBusy else { return }
        preparing = true
        let review: IOSPhotoReviewModel = model
        let count: Int = state.detectedPhotos.count
        let name: String = model.isReceipts ? "Receipt" : PhotoImport.label
        Task { @MainActor in
            let crop: IOSCropRequest? = await review.cropRequest(for: photo, name: name, number: number, count: count)
            preparing = false
            cropping = crop
        }
    }

    private func finishCrop(_ crop: IOSCropRequest, answer: PhotoCornersAnswer) {
        cropping = nil
        model.applyCrop(crop, answer: answer)
    }

    private func closeCrop() {
        cropping = nil
    }
}

/// A photo of the review with its number (from 1), for its card and the ids the UI tests read.
private struct ReviewEntry: Identifiable {
    let photo: DetectedPhoto
    let number: Int

    var id: UUID { photo.id }
}

/// One photo or receipt of the review: its picture (turned as it will be saved, dimmed when left out), its
/// size on paper, Keep, Rotate and Fix crop.
private struct ReviewCard: View {
    let photo: DetectedPhoto
    let number: Int
    let busy: Bool
    let onToggle: () -> Void
    let onRotate: () -> Void
    let onCrop: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                if let picture = thumbnail {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .rotationEffect(Angle.degrees(Double(photo.rotationQuarterTurns) * 90))
                        .padding(6)
                }
            }
            .frame(height: 150)
            .opacity(photo.included ? 1 : 0.35)
            .accessibilityHidden(true)
            Text(IOSReviewText.sizeCaption(width: photo.image.width, height: photo.image.height, dpi: photo.dpi))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
            HStack(spacing: 12) {
                Button(action: onToggle) {
                    Label(IOSReviewText.keepLabel, systemImage: photo.included ? "checkmark.circle.fill" : "circle")
                        .font(.footnote)
                }
                .accessibilityLabel(Text(IOSReviewText.keepLabel))
                .accessibilityValue(Text(photo.included ? "On" : "Off"))
                .accessibilityAddTraits(AccessibilityTraits.isToggle)
                .accessibilityIdentifier("review.keep.\(number)")
                Spacer(minLength: 0)
                Button(action: onRotate) {
                    Image(systemName: "rotate.right")
                }
                .accessibilityLabel(Text(IOSReviewText.rotateLabel))
                .accessibilityIdentifier("review.rotate.\(number)")
                Button(action: onCrop) {
                    Image(systemName: "crop")
                }
                .disabled(busy)
                .accessibilityLabel(Text(IOSReviewText.fixCropLabel))
                .accessibilityIdentifier("review.crop.\(number)")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.card.\(number)")
        .task(id: photo.region.id) {
            let image: CGImage = photo.image
            let small: CGImage = await Task.detached(priority: .userInitiated) { () -> CGImage in
                IOSPhotoReviewModel.thumbnail(image, maxSide: 400)
            }.value
            thumbnail = small
        }
    }
}
#endif
