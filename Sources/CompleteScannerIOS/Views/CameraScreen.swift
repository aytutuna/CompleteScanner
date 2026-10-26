#if os(iOS)
import AVFoundation
import CompleteScannerKit
import QuartzCore
import SwiftUI
import UIKit

/// Our own camera, full screen: the live preview, the whole photo as it will be taken (black above and below
/// it on a tall screen, where the bars sit), with the page's outline over it (yellow, green once the page
/// holds still), Done, Auto (the automatic shutter), the torch, the shutter with a ring that fills
/// while the page holds still, and the last page taken with how many pages the queue holds. With Auto on
/// the photo is taken by itself once the page held still on a sharp, lit frame (`IOSCameraModel`,
/// `LiveQuadUpdate.shouldCapture`), with a short tap felt; while it waits for a sharper or brighter frame,
/// one line says so ("Hold still", "Too dark"), and VoiceOver says it once per wait (`IOSWaitAnnouncer`).
/// Each photo goes through the photo import (`IOSImportSession.importShot`): the page is found again in
/// the photo; in continuous capture (`IOSShell.capturesContinuously`) a page found clearly goes straight
/// into the queue and the camera stays on for the next page, which is taken once the page in view changed;
/// otherwise the corner editor opens here, in place of the preview (the camera stops meanwhile), and Use
/// corners puts the page in the queue. Done goes back to the page strip. Where the camera cannot be used
/// (no camera, as in the Simulator; access off, with Settings; not allowed) or waits (too warm,
/// interrupted), one short line says why. For photos and receipts (I13) the objects of each shot go to the
/// photo review, which takes the camera's place; for the ID card a guide frame of the card's shape asks for
/// the front, then the back (with No back side), the glare hint follows a side taken with glare on it, and
/// the card's review takes the camera's place once the sides are in. Since I14 the task's camera line
/// (`CameraTaskCatalog`: what to point at, "Turn the sheet over and take its back." while a back is due,
/// "The next page starts a new document." after New document) shows under the top bar, with the task's
/// buttons between shots (No back, Now the backs, New document, `CameraTaskButtons`) over the shutter;
/// Quick scan's page takes the camera's place once taken. With a keyboard (I15), Space takes a photo and
/// Escape is Done. On the iPhone the camera is what the app opens on: the task chip under the top bar opens
/// the task sheet here, the last page with the count goes back to the page strip as Done does, and Photos
/// and Files sit beside the shutter; the camera rests while the sheet, Photos or Files covers it, so Auto
/// takes nothing meanwhile.
struct CameraScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: IOSCameraModel
    @State private var waitAnnouncer: IOSWaitAnnouncer = IOSWaitAnnouncer()
    @State private var showsTasks: Bool = false
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
            let session: IOSImportSession = importer
            let appState: AppState = state
            // Read at each shot: a task picked in the task sheet here changes it.
            shown.onAutoShot = { (shot: IOSCameraShot) async -> Void in
                _ = await session.importShot(shot, asksOnlyWhenUnsure: IOSShell.capturesContinuously(appState.settings))
            }
            shown.canTakePage = { () -> Bool in
                !session.isImporting && session.canImport
            }
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
        .onChange(of: showsTasks) { (_: Bool, shown: Bool) in
            rest(shown)
        }
        .sheet(isPresented: $showsTasks) {
            TaskSheet(onPicked: closeTasks, onClose: closeTasks)
                .environmentObject(state)
                .environmentObject(importer)
        }
        .onChange(of: waitCue) { (_: IOSWaitCue, cue: IOSWaitCue) in
            // Spoken once per wait, when the line is first shown, so a VoiceOver user knows why nothing is
            // taken yet without hearing it again each time a frame flips it.
            if let reason = waitAnnouncer.next(cue) {
                AccessibilityNotification.Announcement(reason).post()
            }
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
            if model.message == nil, let prompt = cardPrompt {
                IdCardGuide(prompt: prompt)
            }
            VStack(spacing: 0) {
                topBar
                TaskChip(title: IOSShell.shownKind(state.settings).title, onTap: openTasks)
                    .padding(.top, 6)
                if model.message == nil, cardPrompt == nil, let line = taskLine {
                    Text(line.prompt)
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(.top, 10)
                        .accessibilityHint(Text(line.help))
                        .accessibilityIdentifier("camera.prompt")
                }
                Spacer(minLength: 0)
                notice
                Spacer(minLength: 0)
                CameraTaskButtons(onDark: true)
                    .padding(.bottom, 12)
                if state.canSkipStep {
                    Button(IdCardSteps.skipBackLabel) {
                        state.skipStep()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy || importer.isImporting)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("camera.skipBack")
                }
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
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("camera.done")
            Spacer(minLength: 0)
            Button {
                model.setAutoShutter(!model.autoShutter)
            } label: {
                Label(IOSCameraText.autoLabel, systemImage: model.autoShutter ? "a.circle.fill" : "a.circle")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .tint(model.autoShutter ? Color.yellow : Color.white)
            .accessibilityLabel(Text(IOSCameraText.autoLabel))
            .accessibilityValue(Text(model.autoShutter ? IOSCameraText.onValue : IOSCameraText.offValue))
            .accessibilityHint(Text(IOSCameraText.autoHint))
            .accessibilityAddTraits(AccessibilityTraits.isToggle)
            .accessibilityIdentifier("camera.auto")
            if model.hasTorch {
                Button {
                    let shown: IOSCameraModel = model
                    Task { @MainActor in
                        await shown.toggleTorch()
                    }
                } label: {
                    // The button's own padding makes this a full tap target; any taller and the bar and the
                    // chip spill out of the black band above the picture.
                    Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3)
                        .frame(width: 44, height: 30)
                }
                .buttonStyle(.bordered)
                .tint(Color.white)
                .disabled(!model.lifecycle.isLive)
                .accessibilityLabel(Text(IOSCameraText.torchLabel))
                .accessibilityValue(Text(model.torchOn ? IOSCameraText.onValue : IOSCameraText.offValue))
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
        } else if let glare = glareLine {
            Label(glare, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.white)
                .padding(12)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .accessibilityIdentifier("camera.glare")
        } else if let reason = waitLine {
            Text(reason)
                .font(.headline)
                .foregroundStyle(Color.white)
                .padding(12)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .accessibilityIdentifier("camera.wait")
        }
    }

    /// The task's camera line now (`CameraTaskCatalog.current`); nil without a task.
    private var taskLine: CameraStepText? {
        CameraTaskCatalog.current(state.activeTask, options: state.settings.taskOptions, sides: state.cameraSides,
                                  newDocument: state.newDocumentPending)
    }

    /// The ID card's guide frame's line: the side to take ("Fit the front in the frame"); nil for other tasks.
    private var cardPrompt: String? {
        guard CaptureObjects.kind(for: state.settings) == .idCard else { return nil }
        return IOSIdCardGuide.prompt(stepID: state.taskFlow?.current?.id)
    }

    /// The glare hint while the back is next and the front was taken with glare on it.
    private var glareLine: String? {
        guard CaptureObjects.kind(for: state.settings) == .idCard else { return nil }
        return IOSIdCardGuide.glareLine(stepID: state.taskFlow?.current?.id, frontNote: state.idCardFrontNote)
    }

    /// Why the page held still is not taken yet (a blurred or dark frame), while the automatic shutter waits.
    private var waitLine: String? {
        guard model.autoShutter, let update = model.live, update.state == CaptureState.steadying else { return nil }
        return IOSCameraText.waitReason(update.quality)
    }

    /// Whether a page held still waits, and the wait line as `notice` shows it (nil while a message or the
    /// import's progress is shown in its place), for VoiceOver (`IOSWaitAnnouncer`).
    private var waitCue: IOSWaitCue {
        let steadying: Bool = model.autoShutter && model.live?.state == CaptureState.steadying
        let covered: Bool = model.message != nil || (importer.isImporting && importer.progressText != nil)
        return IOSWaitCue(steadying: steadying, line: covered ? nil : waitLine)
    }

    /// How far the page is through the steady time, for the ring around the shutter (Auto on only).
    private var ringProgress: CGFloat {
        guard model.autoShutter, let update = model.live, update.state == CaptureState.steadying else { return 0 }
        return CGFloat(update.progress)
    }

    private var bottomBar: some View {
        let count: Int = state.scannedPages.count
        let last: CGImage? = state.scannedPages.last?.image
        let ring: CGFloat = ringProgress
        return HStack(alignment: .center) {
            Button {
                onClose()
            } label: {
                HStack(spacing: 8) {
                    if let image = last {
                        Image(image, scale: 1, label: Text(IOSCameraText.lastPageLabel))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 56)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .accessibilityIdentifier("camera.lastPage")
                    }
                    Text(IOSCameraText.pageCount(count))
                        .font(.footnote)
                        .foregroundStyle(Color.white)
                        .accessibilityIdentifier("camera.count")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(IOSCameraText.pagesHint))
            .accessibilityIdentifier("camera.pages")
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    // The automatic shutter's countdown: full when the page held still long enough.
                    Circle()
                        .trim(from: 0, to: ring)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(Angle.degrees(-90))
                        .frame(width: 76, height: 76)
                        .animation(Animation.linear(duration: 0.1), value: ring)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canShoot)
            .keyboardShortcut(IOSShortcuts.shutter.keyboardShortcut)
            .opacity(canShoot ? 1 : 0.4)
            .accessibilityLabel(Text(IOSCameraText.shutterLabel))
            .accessibilityHint(Text(IOSCameraText.shutterHint))
            .accessibilityIdentifier("camera.shutter")
            ImportButtons(onDark: true, onPresenting: rest)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func openTasks() {
        showsTasks = true
    }

    private func closeTasks() {
        showsTasks = false
    }

    /// The session stops while something covers the camera (as for the corner editor) and runs again once
    /// nothing does.
    private func rest(_ covered: Bool) {
        let reviewing: Bool = covered || importer.cornerRequest != nil
        model.apply(reviewing ? IOSCameraEvent.reviewStarted : IOSCameraEvent.reviewEnded)
    }

    /// The camera is live, no photo is being taken or read, and the queue can take a page.
    private var canShoot: Bool {
        model.canShoot && !importer.isImporting && importer.canImport
    }

    private func shoot() {
        guard canShoot else { return }
        let shown: IOSCameraModel = model
        let session: IOSImportSession = importer
        let continuous: Bool = IOSShell.capturesContinuously(state.settings)
        Task { @MainActor in
            if let shot = await shown.shoot() {
                await session.importShot(shot, asksOnlyWhenUnsure: continuous)
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
/// and where the whole frame sits in the view.
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
