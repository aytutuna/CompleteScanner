#if os(iOS)
import AVFoundation
import CompleteScannerKit
import QuartzCore
import SwiftUI
import UIKit

/// Our own camera, full screen: the live preview with the page's outline over it (yellow, green once the
/// page holds still), Done, the torch, the shutter and how many pages the queue holds. After the shutter
/// the photo goes through the photo import (`IOSImportSession.importShot`): the page is found again in
/// the photo, and the corner editor opens here, in place of the preview (the camera stops meanwhile);
/// Use corners puts the page in the queue and the camera comes back for the next one. Where the camera
/// cannot be used (no camera, as in the Simulator; access off, with Settings; not allowed) or waits (too
/// warm, interrupted), one short line says why.
struct CameraScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: IOSCameraModel
    let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        _model = StateObject(wrappedValue: IOSCameraModel.makeLive())
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            // The preview stays under the editor (the camera is stopped meanwhile), so it comes back as it was.
            camera
                .accessibilityHidden(importer.cornerRequest != nil)
            if let request = importer.cornerRequest {
                CornerEditorView(request: request, onAnswer: answerCorners, onStop: stopImport)
                    .id(request.id)
            }
        }
        .onAppear {
            importer.editorInCamera = true
            let shown: IOSCameraModel = model
            Task { @MainActor in
                await shown.appear()
            }
        }
        .onDisappear {
            importer.editorInCamera = false
            model.disappear()
        }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .background {
                model.apply(IOSCameraEvent.background)
            } else if phase == .active {
                model.apply(IOSCameraEvent.foreground)
            }
        }
        .onChange(of: importer.cornerRequest != nil) { (_: Bool, reviewing: Bool) in
            model.apply(reviewing ? IOSCameraEvent.reviewStarted : IOSCameraEvent.reviewEnded)
        }
        .sensoryFeedback(SensoryFeedback.impact(weight: SensoryFeedback.Weight.medium), trigger: model.shotCount)
        .modifier(ErrorAlert(state: state))
    }

    // MARK: The camera

    private var camera: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            if model.showsPreview, let controller = model.driver as? IOSCameraController {
                CameraPreview(controller: controller, outline: model.live?.outline,
                              steady: model.live?.isSteady ?? false)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                notice
                Spacer(minLength: 0)
                bottomBar
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.screen")
    }

    private var topBar: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Text(IOSCameraText.doneLabel)
                    .bold()
            }
            .buttonStyle(.bordered)
            .tint(Color.white)
            .accessibilityIdentifier("camera.done")
            Spacer(minLength: 0)
            if model.hasTorch {
                Button {
                    let shown: IOSCameraModel = model
                    Task { @MainActor in
                        await shown.toggleTorch()
                    }
                } label: {
                    Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.white)
                .disabled(!model.lifecycle.isLive)
                .accessibilityLabel(Text(IOSCameraText.torchLabel))
                .accessibilityValue(Text(model.torchOn ? "On" : "Off"))
                .accessibilityIdentifier("camera.torch")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Why the camera cannot be used or waits, in one line (with Settings when access is off); the
    /// import's progress while a photo is read.
    @ViewBuilder
    private var notice: some View {
        if let line = model.message {
            VStack(spacing: 10) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.largeTitle)
                    .foregroundStyle(Color.white)
                    .accessibilityHidden(true)
                Text(line)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("camera.message")
                if model.opensSettings {
                    Button(IOSCameraText.settingsLabel) {
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("camera.settings")
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
            .accessibilityElement(children: .contain)
        } else if importer.isImporting, let progress = importer.progressText {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Color.white)
                Text(progress)
                    .font(.footnote)
                    .foregroundStyle(Color.white)
            }
            .padding(12)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("camera.progress")
        }
    }

    private var bottomBar: some View {
        let count: Int = state.scannedPages.count
        return HStack(alignment: .center) {
            Text(IOSCameraText.pageCount(count))
                .font(.footnote)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("camera.count")
            Button {
                shoot()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 64, height: 64)
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canShoot)
            .opacity(canShoot ? 1 : 0.4)
            .accessibilityLabel(Text(IOSCameraText.shutterLabel))
            .accessibilityHint(Text(IOSCameraText.shutterHint))
            .accessibilityIdentifier("camera.shutter")
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    /// The camera is live, no photo is being taken or read, and the queue can take a page.
    private var canShoot: Bool {
        model.canShoot && !importer.isImporting && importer.canImport
    }

    private func shoot() {
        guard canShoot else { return }
        let shown: IOSCameraModel = model
        let session: IOSImportSession = importer
        Task { @MainActor in
            if let shot = await shown.shoot() {
                await session.importShot(shot)
            }
        }
    }

    private func answerCorners(_ answer: PhotoCornersAnswer) {
        importer.answer(answer)
    }

    private func stopImport() {
        importer.stop()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// The camera's live preview with the page's outline drawn over it. The outline comes as shares of the
/// sensor's frame (as the live frames are searched) and is placed with the preview layer's own
/// conversion (`layerPointConverted(fromCaptureDevicePoint:)`), which knows how the preview is turned
/// and cropped to fill the screen.
struct CameraPreview: UIViewRepresentable {
    let controller: IOSCameraController
    let outline: Quad?
    let steady: Bool

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        controller.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.show(outline: outline, steady: steady)
    }
}

/// A view whose layer is the session's preview, with the outline in a shape layer over it.
final class CameraPreviewView: UIView {
    private let outlineLayer = CAShapeLayer()
    private var outline: Quad?
    private var steady: Bool = false

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // The layer class above makes this cast always succeed.
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black
        outlineLayer.lineWidth = 3
        outlineLayer.lineJoin = .round
        layer.addSublayer(outlineLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(outlineLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outlineLayer.frame = bounds
        redraw()
    }

    func show(outline: Quad?, steady: Bool) {
        self.outline = outline
        self.steady = steady
        redraw()
    }

    private func redraw() {
        guard let quad = outline else {
            outlineLayer.path = nil
            return
        }
        let path = UIBezierPath()
        var index: Int = 0
        for corner in quad.corners {
            let point: CGPoint = previewLayer.layerPointConverted(fromCaptureDevicePoint: corner)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            index += 1
        }
        path.close()
        let color: UIColor = steady ? UIColor.systemGreen : UIColor.systemYellow
        outlineLayer.strokeColor = color.cgColor
        outlineLayer.fillColor = color.withAlphaComponent(0.15).cgColor
        outlineLayer.path = path.cgPath
    }
}
#endif
