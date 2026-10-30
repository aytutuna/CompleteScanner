#if os(iOS)
import LazyScanKit
import CoreGraphics
import SwiftUI

/// The ID card's review on the iPhone and iPad (I13), a port of the Mac's `IdCardReviewView`: the privacy
/// line (`IdCardSteps.privacyNote`), each side with Rotate, Fix crop (the touch corner editor on the photo
/// it was cut from) and Scan again, its note (what to check, or the glare hint), a missing back with Scan
/// the back, Swap sides, the page both go on with what it holds and whether it is at real size, then Paper,
/// Save as, Also save sides as images, Discard and Save. The card stays in memory only until it is saved or
/// discarded (AppState+IdCard.swift); Print prints both sides at real size over AirPrint
/// (`IOSPrintService`, I16). It shows the error alert itself,
/// since the root's cannot show over it.
struct IdCardReviewScreen: View {
    @EnvironmentObject private var state: AppState
    let model: IOSPhotoReviewModel
    @State private var cropping: IOSCropRequest?
    @State private var preparing: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(IdCardSteps.privacyNote, systemImage: "lock.shield")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .accessibilityHint(Text(IOSReviewText.privacyHelp))
                            .accessibilityIdentifier("idcard.privacy")
                        SideCard(side: .front, photo: state.idCardFront, note: state.idCardFrontNote,
                                 busy: state.isBusy || preparing,
                                 onRotate: { state.rotateIdCardSide(.front) },
                                 onCrop: { fixCrop(.front) },
                                 onRetake: { state.retakeIdCardSide(.front) })
                        SideCard(side: .back, photo: state.idCardBack, note: state.idCardBackNote,
                                 busy: state.isBusy || preparing,
                                 onRotate: { state.rotateIdCardSide(.back) },
                                 onCrop: { fixCrop(.back) },
                                 onRetake: { state.retakeIdCardSide(.back) })
                        if state.idCardBack != nil {
                            Button {
                                state.swapIdCardSides()
                            } label: {
                                Label(IOSReviewText.swapLabel, systemImage: "arrow.up.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.isBusy)
                            .accessibilityIdentifier("idcard.swap")
                        }
                        pagePreview
                    }
                    .padding(16)
                }
                Divider()
                footer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(IOSReviewText.idCardTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSReviewText.discardLabel, role: .destructive) {
                        state.discardIdCard()
                    }
                    .disabled(state.isBusy)
                    .accessibilityHint(Text(IOSReviewText.discardHint))
                    .accessibilityIdentifier("idcard.discard")
                }
            }
        }
        .fullScreenCover(item: $cropping) { (crop: IOSCropRequest) in
            CornerEditorView(request: crop.request, onAnswer: { (answer: PhotoCornersAnswer) -> Void in
                finishCrop(crop, answer: answer)
            }, fixesCrop: true)
        }
        .modifier(ErrorAlert(state: state))
    }

    /// The page the sides go on, small, with what it holds and whether it is at real size.
    private var pagePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let page = state.idCardPreview {
                    Image(decorative: page, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Color.white)
                        .aspectRatio(8.5 / 11, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 320)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel(Text(IOSReviewText.pagePreviewName))
            .accessibilityValue(Text(state.idCardLayoutCaption))
            .accessibilityIdentifier("idcard.page")
            Text(state.idCardLayoutCaption)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("idcard.caption")
            if let warning = state.idCardSizeWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Paper, Save as, Also save sides as images, the progress of a save, and Save.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(IOSReviewText.paperLabel, selection: paper) {
                    ForEach(IdCardPaper.allCases) { (choice: IdCardPaper) in
                        Text(state.idCardPaperChoiceLabel(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("idcard.paper")
                Picker(IOSReviewText.saveAsLabel, selection: format) {
                    ForEach(pageFormats) { (choice: OutputFormat) in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("idcard.format")
                Spacer(minLength: 0)
            }
            Toggle(IOSReviewText.sidesAsImagesLabel, isOn: sidesAsImages)
                .accessibilityIdentifier("idcard.sides")
            if IOSShell.reviewOffersPassword(state.settings) {
                Toggle(PDFProtection.optionLabel, isOn: protect)
                    .disabled(IOSPDFOptions.archivalShown(state.settings.output))
                    .accessibilityHint(Text(PDFProtection.optionHint))
                    .accessibilityIdentifier("idcard.password")
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
            }
            HStack(spacing: 12) {
                Button {
                    state.printIdCard()
                } label: {
                    Label(IOSReviewText.printLabel, systemImage: "printer")
                }
                .buttonStyle(.bordered)
                .disabled(state.idCardFront == nil || state.isBusy)
                .accessibilityHint(Text(IOSReviewText.printIdCardHint))
                .accessibilityIdentifier("idcard.print")
                Button {
                    state.saveIdCard()
                } label: {
                    Text(IOSReviewText.idCardSaveTitle(state.settings.format))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.idCardFront == nil || state.isBusy)
                .accessibilityIdentifier("idcard.save")
            }
        }
        .disabled(state.isBusy)
        .padding(16)
    }

    /// The formats a card is saved in: a PDF or a picture.
    private var pageFormats: [OutputFormat] {
        var formats: [OutputFormat] = []
        for format in OutputFormat.allCases where format.pageFormat == format {
            formats.append(format)
        }
        return formats
    }

    private var paper: Binding<IdCardPaper> {
        let appState: AppState = state
        return Binding<IdCardPaper>(get: { appState.settings.taskOptions.idCardPaper },
                                    set: { (choice: IdCardPaper) in appState.setIdCardPaper(choice) })
    }

    /// A text format chosen elsewhere shows (and saves) as PDF here.
    private var format: Binding<OutputFormat> {
        let appState: AppState = state
        return Binding<OutputFormat>(get: { appState.settings.format.pageFormat },
                                     set: { (choice: OutputFormat) in appState.settings.format = choice })
    }

    private var protect: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(get: { appState.settings.output.protect },
                             set: { (on: Bool) in
                                 appState.settings.output = IOSPDFOptions.settingProtect(on, in: appState.settings.output)
                             })
    }

    private var sidesAsImages: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(get: { appState.settings.taskOptions.idCardSaveSidesAsImages },
                             set: { (on: Bool) in appState.settings.taskOptions.idCardSaveSidesAsImages = on })
    }

    /// Opens the corner editor on the photo `side` was cut from, once it is read.
    private func fixCrop(_ side: PageSide) {
        guard !preparing, !state.isBusy else { return }
        let held: DetectedPhoto? = side == .front ? state.idCardFront : state.idCardBack
        guard let photo = held else { return }
        preparing = true
        let review: IOSPhotoReviewModel = model
        let name: String = side == .front ? IOSReviewText.frontTitle : IOSReviewText.backTitle
        Task { @MainActor in
            let crop: IOSCropRequest? = await review.cropRequest(for: photo, name: name, number: 1, count: 1)
            preparing = false
            cropping = crop
        }
    }

    private func finishCrop(_ crop: IOSCropRequest, answer: PhotoCornersAnswer) {
        cropping = nil
        model.applyCrop(crop, answer: answer)
    }
}

/// One side of the card: its picture turned as the user turned it, the note about it, and Rotate, Fix crop
/// and Scan again; a missing back says so and offers to scan it.
private struct SideCard: View {
    let side: PageSide
    let photo: DetectedPhoto?
    let note: String?
    let busy: Bool
    let onRotate: () -> Void
    let onCrop: () -> Void
    let onRetake: () -> Void

    @State private var thumbnail: CGImage?

    private var title: String { side == .front ? IOSReviewText.frontTitle : IOSReviewText.backTitle }
    private var key: String {
        guard let held = photo else { return "none" }
        return "\(held.region.id.uuidString)-\(held.rotationQuarterTurns)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
                if photo != nil {
                    Button(action: onRotate) {
                        Image(systemName: "rotate.right")
                    }
                    .accessibilityLabel(Text(IOSReviewText.sideAction(IOSReviewText.rotateLabel, side: side)))
                    Button(action: onCrop) {
                        Image(systemName: "crop")
                    }
                    .accessibilityLabel(Text(IOSReviewText.sideAction(IOSReviewText.fixCropLabel, side: side)))
                    .accessibilityIdentifier("idcard.crop.\(title.lowercased())")
                    Button(action: onRetake) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text(IOSReviewText.sideAction(IOSReviewText.scanAgainLabel, side: side)))
                    .accessibilityIdentifier("idcard.retake.\(title.lowercased())")
                }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            if photo != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                    if let picture = thumbnail {
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(6)
                    }
                }
                .frame(height: 170)
                .accessibilityHidden(true)
                if let line = note {
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("idcard.note.\(title.lowercased())")
                }
            } else {
                Text(IOSReviewText.noBackLine)
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
                Button(IOSReviewText.scanBackLabel, action: onRetake)
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .accessibilityIdentifier("idcard.scanBack")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .task(id: key) {
            guard let held = photo else {
                thumbnail = nil
                return
            }
            let image: CGImage = held.image
            let turns: Int = held.rotationQuarterTurns
            let small: CGImage = await Task.detached(priority: .userInitiated) { () -> CGImage in
                let reduced: CGImage = IOSPhotoReviewModel.thumbnail(image, maxSide: 500)
                return turns == 0 ? reduced : ImagePipeline.rotate(reduced, quarterTurns: turns)
            }.value
            thumbnail = small
        }
    }
}
#endif
