#if os(iOS)
import LazyScanKit
import CoreGraphics
import ImageIO
import SwiftUI
import UIKit
import VisionKit

/// Quick scan's screen, full screen once a shot's page is in (`AppState.quickScanPage`): the page, with
/// Live Text where the device has it (press on the text to select part of it, `LiveTextImageView`), Save
/// JPEG, Copy text (the whole page's text, `OCRService`) and Discard. It closes once the page is saved or
/// discarded.
struct QuickScanScreen: View {
    @ObservedObject var model: IOSQuickScanModel
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let image = model.image {
                        if model.offersLiveText {
                            LiveTextImageView(image: image)
                                .padding(12)
                                .accessibilityLabel(Text("Page"))
                                .accessibilityIdentifier("quick.image")
                        } else {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .accessibilityLabel(Text("Page"))
                                .accessibilityIdentifier("quick.image")
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(StatusLine.shown(state.statusMessage, deviceName: nil, reviewShown: true, savedShown: false))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("quick.status")
                    HStack(spacing: 12) {
                        Button {
                            model.copyText()
                        } label: {
                            Label(IOSQuickScanModel.copyTextLabel, systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.canAct)
                        .accessibilityIdentifier("quick.copy")
                        Button {
                            model.save()
                        } label: {
                            Text(model.saveLabel)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canAct)
                        .accessibilityIdentifier("quick.save")
                    }
                }
                .padding(16)
            }
            .navigationTitle(IOSQuickScanModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSQuickScanModel.discardLabel, role: .destructive) {
                        model.discard()
                    }
                    .disabled(!model.canAct)
                    .accessibilityIdentifier("quick.discard")
                }
                ToolbarItem(placement: .primaryAction) {
                    if state.isBusy {
                        ProgressView()
                    }
                }
            }
        }
        .modifier(ErrorAlert(state: state))
    }
}

/// The page with Live Text over it: VisionKit reads its text once, and a press on the text selects it as in
/// Photos (copy, look up, translate are the system's own menu).
struct LiveTextImageView: UIViewRepresentable {
    let image: CGImage

    func makeCoordinator() -> LiveTextCoordinator {
        LiveTextCoordinator()
    }

    func makeUIView(context: Context) -> UIImageView {
        let view: UIImageView = UIImageView(image: UIImage(cgImage: image))
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        let interaction: ImageAnalysisInteraction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .automatic
        view.addInteraction(interaction)
        context.coordinator.analyze(image, interaction: interaction)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    static func dismantleUIView(_ uiView: UIImageView, coordinator: LiveTextCoordinator) {
        coordinator.cancel()
    }
}

/// Reads the page's text for Live Text once, off the screen's way; dropped when the view goes.
@MainActor
final class LiveTextCoordinator {
    private var analysis: Task<Void, Never>?

    func analyze(_ image: CGImage, interaction: ImageAnalysisInteraction) {
        analysis?.cancel()
        analysis = Task { @MainActor [weak interaction] in
            let analyzer: ImageAnalyzer = ImageAnalyzer()
            let configuration: ImageAnalyzer.Configuration = ImageAnalyzer.Configuration([.text])
            guard let result = try? await analyzer.analyze(image, orientation: .up, configuration: configuration) else {
                return
            }
            if Task.isCancelled { return }
            interaction?.analysis = result
        }
    }

    func cancel() {
        analysis?.cancel()
        analysis = nil
    }
}
#endif
