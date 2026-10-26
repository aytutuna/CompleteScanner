#if os(iOS)
import AVFoundation
import CompleteScannerKit
import QuartzCore
import SwiftUI
import UIKit

/// Where camera mode's photo goes on the screen.
enum CameraLayout {
    /// The coordinate space the viewfinder and the controls are measured in.
    static let space: String = "camera"
    /// The photo's short side over its long side.
    static let photoAspect: CGFloat = 3.0 / 4.0
    /// How far the controls may reach over the photo's edge before it is fitted between them: the few points
    /// of a capsule's rim on a 6.1-inch phone hide nothing.
    static let allowedOverlap: CGFloat = 8

    /// No insets when the photo, fitted to the `screen` and centred, lies between `freeTop` and `freeBottom`
    /// within `allowedOverlap` (or they are not measured yet); else the insets that fit it into that band.
    static func previewInsets(screen: CGSize, freeTop: CGFloat, freeBottom: CGFloat) -> EdgeInsets {
        guard screen.width > 0, screen.height > 0, freeTop >= 0, freeBottom > freeTop, freeBottom <= screen.height else {
            return EdgeInsets()
        }
        let widthOverHeight: CGFloat = screen.height >= screen.width ? photoAspect : 1 / photoAspect
        let height: CGFloat = min(screen.height, screen.width / widthOverHeight)
        let top: CGFloat = (screen.height - height) / 2
        if top >= freeTop - allowedOverlap && top + height <= freeBottom + allowedOverlap { return EdgeInsets() }
        return EdgeInsets(top: freeTop, leading: 0, bottom: screen.height - freeBottom, trailing: 0)
    }
}

/// Camera mode, the iPhone's scan screen unless printer mode was picked (`IOSScanMode`): the viewfinder is
/// the screen, edge to edge, and the controls float over it on glass (`CameraGlass`). Its top bar has the
/// library (`onLibrary`; none where the sidebar has it), a round chevron that swaps the kinds for the
/// options drawer (`CameraDrawer`), and the printer, which switches to printer mode (`onPrinter`). The
/// viewfinder shows the whole photo as it will be taken (black bands where the screen is taller or wider,
/// which the top bar and the bottom bar mostly sit in), the page's outline over it (yellow, green once the page holds
/// still), one status line at its top (the glare hint, why the automatic shutter waits, "Page found · hold
/// still", else the task's camera line, `CameraTaskCatalog`), the ID card's guide frame, and at its foot
/// what the scan screen hands in (`notices`: the package banner, the app's progress with Cancel while it is
/// busy, an import's progress with Stop, the files saved last), the task's buttons between shots (`CameraTaskButtons`, No back side for the ID card) and
/// Save with its menu once there are pages (`saveControls`). Where the camera cannot be used (no camera,
/// as in the Simulator; access off, with Settings; not allowed) or waits (too warm, interrupted), one short
/// line says why in its place. Under it the kinds as a snapping row on a glass capsule (`KindsRow`) or the
/// drawer on a glass panel, the one glass morphing into the other, then the bar: the pages as a stack with
/// their count (`onPages`, the page strip's sheet), the shutter with a ring that fills while the page holds
/// still, and Photos and Files. With Auto on the photo is taken by itself
/// once the page held still on a sharp, lit frame (`IOSCameraModel`), with a short tap felt; VoiceOver
/// says the wait once per wait (`IOSWaitAnnouncer`). Each photo goes through the photo import
/// (`IOSImportSession.importShot`); in continuous capture (`IOSShell.capturesContinuously`) a page found
/// clearly goes straight into the queue, otherwise the root view's corner editor opens. The camera rests
/// while anything covers it (`resting`: a sheet, a cover, the corner editor; Photos or Files), so Auto
/// takes nothing meanwhile, and waits for the card saying why it is asked for (`waitsForIntro`) before
/// iOS asks. With a keyboard, Space takes a photo.
struct CameraScreen<Notices: View, SaveControls: View>: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: IOSCameraModel
    @State private var waitAnnouncer: IOSWaitAnnouncer = IOSWaitAnnouncer()
    @State private var showsDrawer: Bool = false
    @State private var drawerGroup: CameraDrawerGroup = .export
    /// The foot of the top bar and the top of the kinds row in `CameraLayout.space` (0 until measured), between
    /// which the whole photo should be seen.
    @State private var chromeTop: CGFloat = 0
    @State private var chromeBottom: CGFloat = 0
    /// Photos or Files is open over the camera.
    @State private var picking: Bool = false
    @Namespace private var glassSpace: Namespace.ID
    private let resting: Bool
    private let waitsForIntro: Bool
    private let scanner: IOSCameraAvailability
    private let onLibrary: (() -> Void)?
    private let onPrinter: () -> Void
    private let onPages: () -> Void
    private let onKind: (IOSScanKind) -> Void
    private let onExportSheet: () -> Void
    private let onAppleScanner: () -> Void
    private let notices: () -> Notices
    private let saveControls: () -> SaveControls

    /// `scanner` says whether Apple's scanner can run, for the drawer's Use Apple's scanner
    /// (`onAppleScanner`); `onKind` picks a kind as the printer screen's chips do; `onExportSheet` opens
    /// the Export options in full.
    init(resting: Bool, waitsForIntro: Bool, scanner: IOSCameraAvailability, onLibrary: (() -> Void)?,
         onPrinter: @escaping () -> Void, onPages: @escaping () -> Void, onKind: @escaping (IOSScanKind) -> Void,
         onExportSheet: @escaping () -> Void, onAppleScanner: @escaping () -> Void,
         @ViewBuilder notices: @escaping () -> Notices, @ViewBuilder saveControls: @escaping () -> SaveControls) {
        _model = StateObject(wrappedValue: IOSCameraModel.makeLive())
        self.resting = resting
        self.waitsForIntro = waitsForIntro
        self.scanner = scanner
        self.onLibrary = onLibrary
        self.onPrinter = onPrinter
        self.onPages = onPages
        self.onKind = onKind
        self.onExportSheet = onExportSheet
        self.onAppleScanner = onAppleScanner
        self.notices = notices
        self.saveControls = saveControls
    }

    var body: some View {
        ZStack {
            viewfinder
            VStack(spacing: 0) {
                topBar
                overlays
                    .padding(12)
                lowerRow
                bottomBar
            }
        }
        .coordinateSpace(.named(CameraLayout.space))
        .background(Color.black)
        .onAppear {
            if !waitsForIntro {
                start()
            }
        }
        .onDisappear {
            model.disappear()
        }
        .onChange(of: waitsForIntro) { (_: Bool, waits: Bool) in
            if !waits {
                start()
            }
        }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .background {
                model.apply(IOSCameraEvent.background)
            } else if phase == .active {
                model.apply(IOSCameraEvent.foreground)
            }
        }
        .onChange(of: covered) { (_: Bool, rests: Bool) in
            model.apply(rests ? IOSCameraEvent.reviewStarted : IOSCameraEvent.reviewEnded)
        }
        .onChange(of: waitCue) { (_: IOSWaitCue, cue: IOSWaitCue) in
            // Spoken once per wait, when the line is first shown, so a VoiceOver user knows why nothing is
            // taken yet without hearing it again each time a frame flips it.
            if let reason = waitAnnouncer.next(cue) {
                AccessibilityNotification.Announcement(reason).post()
            }
        }
        .sensoryFeedback(SensoryFeedback.impact(weight: SensoryFeedback.Weight.medium), trigger: model.shotCount)
    }

    // MARK: The top bar

    /// Round glass buttons over the top band.
    private var topBar: some View {
        CameraGlassGroup {
            HStack(spacing: 0) {
                libraryButton
                Spacer(minLength: 0)
                drawerToggle
                Spacer(minLength: 0)
                printerButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
            proxy.frame(in: .named(CameraLayout.space)).maxY
        } action: { (bottom: CGFloat) in
            chromeTop = bottom
        }
    }

    @ViewBuilder
    private var libraryButton: some View {
        if let open = onLibrary {
            Button {
                open()
            } label: {
                RoundGlassLabel(symbol: "books.vertical")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(IOSSettingsText.libraryLabel))
            .accessibilityIdentifier("open.library")
        } else {
            Color.clear
                .frame(width: 44, height: 44)
        }
    }

    private var printerButton: some View {
        Button {
            onPrinter()
        } label: {
            RoundGlassLabel(symbol: "printer")
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .opacity(state.isBusy ? 0.4 : 1)
        .accessibilityLabel(Text(IOSCameraText.printerLabel))
        .accessibilityHint(Text(IOSCameraText.printerHint))
        .accessibilityIdentifier("mode.printer")
    }

    private var drawerToggle: some View {
        let open: Bool = showsDrawer
        return Button {
            withAnimation(Animation.snappy) {
                showsDrawer.toggle()
            }
        } label: {
            RoundGlassLabel(symbol: open ? "chevron.down" : "chevron.up", tint: open ? Color.accentColor : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(open ? IOSCameraText.hideOptions : IOSCameraText.showOptions))
        .accessibilityIdentifier("drawer.toggle")
    }

    // MARK: The viewfinder

    /// Edge to edge behind the controls, the whole photo centred in it: the bands above and below it are
    /// where the glass floats. Where they are too short for the controls (an iPhone SE or mini), the photo is
    /// fitted between the top bar and the kinds row instead (`CameraLayout.previewInsets`), so none of it is
    /// hidden; the outline follows the preview layer.
    private var viewfinder: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack {
                Color.black
                framed
                    .padding(previewInsets(proxy))
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.screen")
    }

    private func previewInsets(_ proxy: GeometryProxy) -> EdgeInsets {
        let origin: CGFloat = proxy.frame(in: .named(CameraLayout.space)).minY
        return CameraLayout.previewInsets(screen: proxy.size, freeTop: chromeTop - origin,
                                          freeBottom: chromeBottom - origin)
    }

    /// The preview with the outline, the ID card's guide and the line saying why the camera waits.
    private var framed: some View {
        ZStack {
            if model.showsPreview, let controller = model.driver as? IOSCameraController {
                CameraPreview(controller: controller, outline: model.live?.outline,
                              steady: model.live?.isSteady ?? false)
                    .accessibilityHidden(true)
            }
            if model.message == nil, let prompt = cardPrompt {
                IdCardGuide(prompt: prompt)
            }
            if let line = model.message {
                messageCard(line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The status line at the top; at the foot the notices, the task's buttons and Save.
    private var overlays: some View {
        VStack(spacing: 8) {
            if model.message == nil, let status = statusLine {
                StatusPill(text: status.text, hint: status.hint)
                    .accessibilityIdentifier(status.identifier)
            }
            Spacer(minLength: 0)
            notices()
            if let mismatch = state.sidesMismatch, state.cameraSides != nil {
                Label {
                    Text(mismatch)
                        .foregroundStyle(Color.white)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .cameraGlass(in: Capsule(), tint: Color.cameraShade)
                .accessibilityIdentifier("task.mismatch")
            }
            CameraTaskButtons(onDark: true)
            if state.canSkipStep {
                Button(IdCardSteps.skipBackLabel) {
                    state.skipStep()
                }
                .modifier(CameraProminentButton())
                .disabled(state.isBusy || importer.isImporting)
                .accessibilityIdentifier("camera.skipBack")
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CameraGlassGroup {
                    saveControls()
                }
            }
        }
    }

    /// Why the camera cannot be used or waits, with Settings when access is off.
    private func messageCard(_ line: String) -> some View {
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
        .cameraGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The one line at the viewfinder's top: the glare hint for the ID card's back, why a page held still
    /// is not taken yet, that it is about to be, else the task's camera line (none under the ID card's
    /// guide, which says the side itself).
    private var statusLine: CameraStatus? {
        if let glare = glareLine {
            return CameraStatus(text: glare, hint: nil, identifier: "camera.glare")
        }
        if let reason = waitLine {
            return CameraStatus(text: reason, hint: nil, identifier: "camera.wait")
        }
        if model.autoShutter && model.live?.state == CaptureState.steadying {
            return CameraStatus(text: IOSCameraText.pageFound, hint: nil, identifier: "camera.found")
        }
        guard cardPrompt == nil, let line = taskLine else { return nil }
        return CameraStatus(text: line.prompt, hint: line.help, identifier: "camera.prompt")
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

    /// Whether a page held still waits, and the wait line as shown (nil while a message or the glare hint
    /// is shown in its place), for VoiceOver (`IOSWaitAnnouncer`).
    private var waitCue: IOSWaitCue {
        let steadying: Bool = model.autoShutter && model.live?.state == CaptureState.steadying
        let hidden: Bool = model.message != nil || glareLine != nil
        return IOSWaitCue(steadying: steadying, line: hidden ? nil : waitLine)
    }

    // MARK: Under the viewfinder

    /// The kinds' capsule or the drawer's panel, one glass that morphs into the other as the chevron turns.
    private var lowerRow: some View {
        CameraGlassGroup {
            if showsDrawer {
                CameraDrawer(model: model, group: $drawerGroup, scanner: scanner, onExportSheet: onExportSheet,
                             onAppleScanner: onAppleScanner)
                    .padding(.top, 4)
                    .cameraGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), tint: Color.cameraShade)
                    .cameraGlassID("lower", in: glassSpace)
                    .transition(.opacity)
            } else {
                KindsRow(onKind: onKind)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .cameraGlass(in: Capsule(), tint: Color.cameraShade)
                    .cameraGlassID("lower", in: glassSpace)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
            proxy.frame(in: .named(CameraLayout.space)).minY
        } action: { (top: CGFloat) in
            // The open drawer is a panel over the photo's foot: the photo keeps the room the kinds row leaves.
            if !showsDrawer {
                chromeBottom = top
            }
        }
    }

    private var bottomBar: some View {
        CameraGlassGroup {
            HStack(alignment: .center, spacing: 12) {
                PagesStack(onPages: onPages)
                    .frame(maxWidth: .infinity, alignment: .leading)
                shutter
                ImportButtons(round: true, onPresenting: setPicking)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// The Camera app's shutter: a white ring round the accent colour.
    private var shutter: some View {
        let ring: CGFloat = ringProgress
        let enabled: Bool = canShoot
        return Button {
            shoot()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                Circle()
                    .fill(Color.accentColor)
                    .padding(8)
                // The automatic shutter's countdown: full when the page held still long enough.
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(Angle.degrees(-90))
                    .padding(2)
                    .animation(Animation.linear(duration: 0.1), value: ring)
            }
            .frame(width: 74, height: 74)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .keyboardShortcut(IOSShortcuts.shutter.keyboardShortcut)
        .accessibilityLabel(Text(IOSCameraText.shutterLabel))
        .accessibilityHint(Text(IOSCameraText.shutterHint(CaptureObjects.kind(for: state.settings))))
        .accessibilityIdentifier("camera.shutter")
    }

    /// How far the page is through the steady time, for the ring around the shutter (Auto on only).
    private var ringProgress: CGFloat {
        guard model.autoShutter, let update = model.live, update.state == CaptureState.steadying else { return 0 }
        return CGFloat(update.progress)
    }

    // MARK: The camera's life

    /// The automatic shutter's way into the import, then the camera, resting first when it is covered.
    private func start() {
        let shown: IOSCameraModel = model
        let session: IOSImportSession = importer
        let appState: AppState = state
        // Read at each shot: a kind picked meanwhile changes it.
        shown.onAutoShot = { [weak shown] (shot: IOSCameraShot) async -> Void in
            let continuous: Bool = IOSShell.capturesContinuously(appState.settings)
            let outcome: IOSImportOutcome = await session.importShot(shot, asksOnlyWhenUnsure: continuous)
            shown?.shotImported(outcome)
        }
        shown.canTakePage = { () -> Bool in
            !session.isImporting && session.canImport
        }
        shown.apply(covered ? IOSCameraEvent.reviewStarted : IOSCameraEvent.reviewEnded)
        Task { @MainActor in
            await shown.appear()
        }
    }

    /// The session stops while something covers the camera (the corner editor among them) and runs again
    /// once nothing does.
    private var covered: Bool {
        resting || picking || importer.cornerRequest != nil
    }

    private func setPicking(_ shown: Bool) {
        picking = shown
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
                let outcome: IOSImportOutcome = await session.importShot(shot, asksOnlyWhenUnsure: continuous)
                shown.shotImported(outcome)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// The viewfinder's status line: its words, what VoiceOver says after them, and its identifier.
private struct CameraStatus {
    let text: String
    let hint: String?
    let identifier: String
}

/// A line on shaded glass over the viewfinder.
private struct StatusPill: View {
    let text: String
    let hint: String?

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .cameraGlass(in: Capsule(), tint: Color.cameraShade)
            .accessibilityHint(Text(hint ?? ""))
    }
}

/// A round glass button's face in the top bar: the symbol in white, the glass tinted while it is on.
private struct RoundGlassLabel: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .cameraGlass(in: Circle(), interactive: true, tint: tint)
            .contentShape(Circle())
    }
}

/// The pages taken, as the last one whole on a glass-framed card shaped as the page is, a second card behind
/// it once there are two, and the count on a badge inside the card; it opens the page strip. It springs and
/// a tap is felt as a page comes in.
private struct PagesStack: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    let onPages: () -> Void
    @State private var bumped: Bool = false

    /// The page's long side on the card, inside its glass rim.
    private static let longSide: CGFloat = 62
    private static let rim: CGFloat = 3

    var body: some View {
        let count: Int = state.scannedPages.count
        Button {
            onPages()
        } label: {
            stack(count: count)
                .scaleEffect(bumped ? 1.1 : 1)
                .animation(reduceMotion ? nil : Animation.spring(duration: 0.4, bounce: 0.3), value: count)
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .onChange(of: count) { (old: Int, new: Int) in
            guard new > old, !reduceMotion else { return }
            withAnimation(.spring(duration: 0.15)) {
                bumped = true
            } completion: {
                withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                    bumped = false
                }
            }
        }
        .sensoryFeedback(SensoryFeedback.impact(weight: SensoryFeedback.Weight.light), trigger: count) { (old: Int, new: Int) -> Bool in
            new > old
        }
        .accessibilityLabel(Text(IOSCameraText.pageCount(count)))
        .accessibilityHint(Text(IOSCameraText.pagesHint))
        .accessibilityIdentifier("camera.pages")
    }

    @ViewBuilder
    private func stack(count: Int) -> some View {
        if let image = state.scannedPages.last?.image {
            let page: CGSize = Self.pageSize(image)
            let card: CGSize = CGSize(width: page.width + Self.rim * 2, height: page.height + Self.rim * 2)
            ZStack {
                if count > 1 {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.5))
                        .frame(width: card.width, height: card.height)
                        .rotationEffect(Angle.degrees(6))
                        .offset(x: 3, y: -2)
                }
                front(image, page: page, count: count)
            }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: 48, height: 64)
        }
    }

    private func front(_ image: CGImage, page: CGSize, count: Int) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: page.width, height: page.height)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(Self.rim)
            .cameraGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), interactive: true)
            .overlay(alignment: .topTrailing) {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.accentColor))
                    .padding(Self.rim + 1)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
    }

    /// The page in the card's box, its own shape kept: a landscape page lies on its side. Only a page
    /// narrower than a long receipt has its ends cut a little, so the card never gets thinner than its badge.
    static func pageSize(_ image: CGImage) -> CGSize {
        let width: CGFloat = CGFloat(max(image.width, 1))
        let height: CGFloat = CGFloat(max(image.height, 1))
        if height >= width {
            return CGSize(width: max(20, longSide * width / height), height: longSide)
        }
        return CGSize(width: longSide, height: max(20, longSide * height / width))
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
