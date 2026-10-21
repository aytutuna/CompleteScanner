#if os(iOS)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// Our own camera without a camera: which camera it picks from fake device lists and how large its
// photos are (`IOSCameraLens`); when the session runs (`IOSCameraLifecycle`, driven by fake events);
// the screen's model (`IOSCameraModel`) with a stand-in session: no camera, access asked once and a
// denial leading to Settings, the session started and stopped by the app going to the background, heat,
// interruptions and the corner editor, the torch, and the shutter with the live outline turned into the
// photo; then the shutter's photo from a fixture still through the corner editor into the queue with
// its focal length (`IOSImportSession.importShot`), and the live outline as the editor's start. The
// Simulator has no camera: the real model says so there.

/// A stand-in for the capture session: counts what it was asked and hands over the photo it is given.
@MainActor
final class FakeCameraDriver: IOSCameraDriving {
    var prepareResult: Bool = true
    var hasTorch: Bool = true
    var frameSource: FrameSource?
    var onEvent: (@MainActor (IOSCameraEvent) -> Void)?
    var photo: IOSCameraPhoto?
    private(set) var prepares: Int = 0
    private(set) var starts: Int = 0
    private(set) var stops: Int = 0
    private(set) var photos: Int = 0
    private(set) var torch: Bool = false

    func prepare() async -> Bool {
        prepares += 1
        return prepareResult
    }

    func startRunning() {
        starts += 1
    }

    func stopRunning() {
        stops += 1
        torch = false
    }

    func setTorch(_ on: Bool) async -> Bool {
        torch = on
        return on
    }

    func takePhoto() async -> IOSCameraPhoto? {
        photos += 1
        return photo
    }
}

/// The camera permission as a stand-in: its status, what the prompt answers, and how often it was shown.
@MainActor
final class FakeCameraAccess {
    var status: AVAuthorizationStatus
    var grants: Bool
    private(set) var asks: Int = 0
    var thermal: ProcessInfo.ThermalState = .nominal

    init(status: AVAuthorizationStatus, grants: Bool) {
        self.status = status
        self.grants = grants
    }

    func ask() -> Bool {
        asks += 1
        status = grants ? .authorized : .denied
        return grants
    }
}

/// A model of the stand-in session, the permission stand-in and a notification center of its own.
@MainActor
private func makeModel(_ driver: FakeCameraDriver, access: FakeCameraAccess, hasCamera: Bool,
                       center: NotificationCenter) -> IOSCameraModel {
    IOSCameraModel(driver: driver, tracker: nil,
                   hasCamera: { () -> Bool in hasCamera },
                   authorization: { () -> AVAuthorizationStatus in access.status },
                   requestAccess: { () async -> Bool in access.ask() },
                   thermalState: { () -> ProcessInfo.ThermalState in access.thermal },
                   center: center)
}

/// Ten frames of the fixture page held still, 100 ms apart.
private func stillFrames() -> [IOSCameraFrame] {
    let still: RgbaImage = TrackerFrames.frame(seed: 11, centerX: 170, centerY: 120, page: true)
    var frames: [IOSCameraFrame] = []
    var index: Int = 0
    while index < 10 {
        frames.append(IOSCameraFrame(image: still, timestampMs: Double(index) * 100.0))
        index += 1
    }
    return frames
}

/// A 600 × 450 photo with an A4-shaped sheet (200 × 283 px) square on.
private let sheetCorners: [CGPoint] = [CGPoint(x: 150, y: 80), CGPoint(x: 350, y: 80), CGPoint(x: 350, y: 363),
                                       CGPoint(x: 150, y: 363)]
private let sheetQuad = Quad(topLeft: sheetCorners[0], topRight: sheetCorners[1], bottomRight: sheetCorners[2],
                             bottomLeft: sheetCorners[3])

/// The camera's photo of the sheet as a JPEG with the EXIF a phone writes: a 26 mm (35 mm equivalent) lens.
private func cameraStill() -> Data {
    let photo: CGImage = ImportTestSupport.sheetPhoto(width: 600, height: 450, corners: sheetCorners)
    let exif: [CFString: Any] = [kCGImagePropertyExifFocalLenIn35mmFilm: 26]
    let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif, kCGImagePropertyOrientation: 1]
    return ImportTestSupport.file(UTType.jpeg, images: [photo], properties: properties)
}

/// A page search that answers `corners` with `reason`.
private func fixedFinder(_ corners: Quad, reason: PhotoReviewReason) -> @Sendable (RgbaImage) -> IOSFoundPage {
    let found = IOSFoundPage(corners: corners, reason: reason, byVision: false)
    return { (_: RgbaImage) -> IOSFoundPage in
        found
    }
}

private func words(_ text: String) -> Int {
    text.split(separator: " ").count
}

final class IOSCameraTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSCameraTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Which camera, how large

    func test_theCamera_isTheVirtualOneThatSwitchesLenses_thenTheWideLens_thenWhateverThereIs() {
        let tripleBack = IOSLensOption(kind: .triple, position: .back)
        let dualWideBack = IOSLensOption(kind: .dualWide, position: .back)
        let wideBack = IOSLensOption(kind: .wide, position: .back)
        let ultraWideBack = IOSLensOption(kind: .ultraWide, position: .back)
        let teleBack = IOSLensOption(kind: .telephoto, position: .back)
        let dualBack = IOSLensOption(kind: .dual, position: .back)
        let wideFront = IOSLensOption(kind: .wide, position: .front)
        let trueDepthFront = IOSLensOption(kind: .trueDepth, position: .front)
        // A Pro model: the triple camera, wherever it is listed.
        XCTAssertEqual(IOSCameraLens.choose([wideBack, ultraWideBack, teleBack, tripleBack, dualWideBack, wideFront]), 3)
        // Two lenses: the wide pair.
        XCTAssertEqual(IOSCameraLens.choose([wideFront, wideBack, ultraWideBack, dualWideBack]), 3)
        // The wide lens before the other single lenses and the wide-telephoto pair.
        XCTAssertEqual(IOSCameraLens.choose([dualBack, teleBack, wideBack, ultraWideBack]), 2)
        // No wide lens: whatever faces back.
        XCTAssertEqual(IOSCameraLens.choose([trueDepthFront, teleBack]), 1)
        // Only front cameras (no back camera): the wide one.
        XCTAssertEqual(IOSCameraLens.choose([trueDepthFront, wideFront]), 1)
        // The first of two the same.
        XCTAssertEqual(IOSCameraLens.choose([wideBack, wideBack]), 0)
        // None.
        XCTAssertNil(IOSCameraLens.choose([]))
        XCTAssertEqual(IOSCameraLens.preferred, [.triple, .dualWide, .wide])
        XCTAssertLessThan(IOSCameraLens.rank(wideBack), IOSCameraLens.rank(dualBack))
        XCTAssertLessThan(IOSCameraLens.rank(teleBack), IOSCameraLens.rank(wideFront))
        // The device's camera types map onto the kinds.
        XCTAssertEqual(IOSCameraLens.kind(.builtInTripleCamera), .triple)
        XCTAssertEqual(IOSCameraLens.kind(.builtInDualWideCamera), .dualWide)
        XCTAssertEqual(IOSCameraLens.kind(.builtInWideAngleCamera), .wide)
        XCTAssertEqual(IOSCameraLens.kind(.builtInTrueDepthCamera), .trueDepth)
        XCTAssertEqual(IOSCameraLens.position(.back), .back)
        XCTAssertEqual(IOSCameraLens.position(.front), .front)
        XCTAssertEqual(IOSCameraLens.position(.unspecified), .unspecified)
    }

    func test_aVirtualCameraWithTheUltraWideLens_startsAtTheWideLensZoom() {
        // A Pro model's triple camera and the wide pair: zoom 1 is the ultra wide lens, the wide lens takes over at 2.
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .triple, switchOverFactors: [2, 6]), 2)
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .dualWide, switchOverFactors: [2]), 2)
        // Within what the camera allows now.
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .triple, switchOverFactors: [2, 6], minZoom: 1, maxZoom: 1.5), 1.5)
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .dualWide, switchOverFactors: [2], minZoom: 3, maxZoom: 10), 3)
        // No switch-over reported, or none above 1: as it is.
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .triple, switchOverFactors: []), 1)
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .dualWide, switchOverFactors: [1]), 1)
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .dualWide, switchOverFactors: [Double.nan]), 1)
        // The wide-telephoto pair's zoom 1 is the wide lens already; single lenses have nothing to switch to.
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .dual, switchOverFactors: [2]), 1)
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .wide, switchOverFactors: []), 1)
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .ultraWide, switchOverFactors: [2]), 1)
        // Never below 1, whatever the camera reports.
        XCTAssertEqual(IOSCameraLens.startZoom(kind: .wide, switchOverFactors: [], minZoom: 0.5, maxZoom: 0.5), 1)
    }

    func test_photos_areTheLargestOfAbout12MPAtMost() {
        let twelve = IOSPhotoSize(width: 4032, height: 3024)
        let fortyEight = IOSPhotoSize(width: 8064, height: 6048)
        let small = IOSPhotoSize(width: 1920, height: 1440)
        XCTAssertEqual(IOSCameraLens.photoSize([small, twelve, fortyEight]), twelve)
        XCTAssertEqual(IOSCameraLens.photoSize([fortyEight, twelve]), twelve)
        // 13.4 MP is over the cap.
        XCTAssertEqual(IOSCameraLens.photoSize([IOSPhotoSize(width: 4224, height: 3168), IOSPhotoSize(width: 3264, height: 2448)]),
                       IOSPhotoSize(width: 3264, height: 2448))
        // Nothing small enough: the smallest offered.
        XCTAssertEqual(IOSCameraLens.photoSize([fortyEight, IOSPhotoSize(width: 5712, height: 4284)]),
                       IOSPhotoSize(width: 5712, height: 4284))
        XCTAssertNil(IOSCameraLens.photoSize([]))
        XCTAssertNil(IOSCameraLens.photoSize([IOSPhotoSize(width: 0, height: 0)]))
        XCTAssertEqual(IOSCameraLens.maxPhotoPixels, 12_600_000)
        XCTAssertEqual(twelve.pixels, 12_192_768)
    }

    // MARK: When the camera runs

    func test_theLifecycle_runsTheCameraOnlyWhileEverythingAllowsIt() {
        var life = IOSCameraLifecycle()
        XCTAssertFalse(life.shouldRun)
        XCTAssertEqual(life.handle(.shown), .keep)               // not set up yet
        XCTAssertEqual(life.handle(.ready(true)), .start)
        XCTAssertTrue(life.isRunning)
        XCTAssertTrue(life.isLive)
        XCTAssertNil(life.pauseReason)
        XCTAssertEqual(life.handle(.ready(true)), .keep)         // nothing changed
        // The app goes to the background and comes back.
        XCTAssertEqual(life.handle(.background), .stop)
        XCTAssertFalse(life.isRunning)
        XCTAssertNil(life.pauseReason)
        XCTAssertEqual(life.handle(.foreground), .start)
        // Too warm: stopped at .serious and .critical, started again once it cools down.
        XCTAssertEqual(life.handle(.thermal(.fair)), .keep)
        XCTAssertEqual(life.handle(.thermal(.serious)), .stop)
        XCTAssertEqual(life.pauseReason, "Paused: too warm")
        XCTAssertEqual(life.handle(.thermal(.critical)), .keep)
        XCTAssertEqual(life.handle(.thermal(.fair)), .start)
        XCTAssertNil(life.pauseReason)
        // An interruption: the system stops the session and starts it again; it is not stopped here.
        XCTAssertEqual(life.handle(.interrupted(.inUse)), .keep)
        XCTAssertTrue(life.isRunning)
        XCTAssertFalse(life.isLive)
        XCTAssertEqual(life.pauseReason, "Camera in use")
        XCTAssertEqual(life.handle(.interruptionEnded), .keep)
        XCTAssertTrue(life.isLive)
        // An interruption whose end was not reported is forgotten back in the front.
        XCTAssertEqual(life.handle(.interrupted(.other)), .keep)
        XCTAssertEqual(life.handle(.background), .stop)
        XCTAssertEqual(life.handle(.foreground), .start)
        XCTAssertTrue(life.isLive)
        // Made active again without going to the background (Control Center pulled down and closed, the
        // iPad still showing two apps): the interruption is still in effect, so it stays.
        XCTAssertEqual(life.handle(.interrupted(.multitasking)), .keep)
        XCTAssertEqual(life.handle(.foreground), .keep)
        XCTAssertEqual(life.interruption, .multitasking)
        XCTAssertFalse(life.isLive)
        XCTAssertEqual(life.pauseReason, "Needs full screen")
        XCTAssertEqual(life.handle(.interruptionEnded), .keep)
        XCTAssertTrue(life.isLive)
        // A photo in the corner editor.
        XCTAssertEqual(life.handle(.reviewStarted), .stop)
        XCTAssertEqual(life.handle(.reviewEnded), .start)
        // Session errors: started again three times, then it stays stopped and says so.
        XCTAssertEqual(life.handle(.runtimeError), .start)
        XCTAssertEqual(life.handle(.runtimeError), .start)
        XCTAssertEqual(life.handle(.runtimeError), .start)
        XCTAssertEqual(life.handle(.runtimeError), .keep)
        XCTAssertFalse(life.isRunning)
        XCTAssertTrue(life.hasFailed)
        XCTAssertEqual(life.pauseReason, "Camera did not start")
        // Shown again: tried afresh.
        XCTAssertEqual(life.handle(.hidden), .keep)
        XCTAssertEqual(life.handle(.shown), .start)
        XCTAssertFalse(life.hasFailed)
        // Gone: stopped; nothing starts it while hidden.
        XCTAssertEqual(life.handle(.hidden), .stop)
        XCTAssertEqual(life.handle(.foreground), .keep)
        XCTAssertEqual(life.handle(.reviewEnded), .keep)
        XCTAssertFalse(life.isRunning)
        // Too warm when shown: waits.
        var warm = IOSCameraLifecycle()
        XCTAssertEqual(warm.handle(.thermal(.serious)), .keep)
        XCTAssertEqual(warm.handle(.shown), .keep)
        XCTAssertEqual(warm.handle(.ready(true)), .keep)
        XCTAssertEqual(warm.handle(.thermal(.nominal)), .start)
        // Not allowed: never runs.
        var denied = IOSCameraLifecycle()
        XCTAssertEqual(denied.handle(.shown), .keep)
        XCTAssertEqual(denied.handle(.ready(false)), .keep)
        XCTAssertFalse(denied.shouldRun)
    }

    func test_theThermalStates_andTheInterruptions_eachHaveTheirLine() {
        XCTAssertTrue(IOSCameraLifecycle.thermalAllows(.nominal))
        XCTAssertTrue(IOSCameraLifecycle.thermalAllows(.fair))
        XCTAssertFalse(IOSCameraLifecycle.thermalAllows(.serious))
        XCTAssertFalse(IOSCameraLifecycle.thermalAllows(.critical))
        XCTAssertEqual(IOSCameraInterruption.from(.videoDeviceInUseByAnotherClient), .inUse)
        XCTAssertEqual(IOSCameraInterruption.from(.videoDeviceNotAvailableDueToSystemPressure), .tooWarm)
        XCTAssertEqual(IOSCameraInterruption.from(.videoDeviceNotAvailableWithMultipleForegroundApps), .multitasking)
        XCTAssertEqual(IOSCameraInterruption.from(.videoDeviceNotAvailableInBackground), .other)
        XCTAssertEqual(IOSCameraInterruption.from(.audioDeviceInUseByAnotherClient), .other)
        XCTAssertEqual(IOSCameraInterruption.inUse.reason, "Camera in use")
        XCTAssertEqual(IOSCameraInterruption.tooWarm.reason, "Paused: too warm")
        XCTAssertEqual(IOSCameraInterruption.multitasking.reason, "Needs full screen")
        XCTAssertEqual(IOSCameraInterruption.other.reason, "Camera paused")
        // A session's notification carries its reason as a number.
        let note = Notification(name: AVCaptureSession.wasInterruptedNotification, object: nil,
                                userInfo: [AVCaptureSessionInterruptionReasonKey: NSNumber(value: AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue)])
        XCTAssertEqual(IOSCameraController.interruptionEvent(note), .interrupted(.inUse))
        let bare = Notification(name: AVCaptureSession.wasInterruptedNotification, object: nil, userInfo: nil)
        XCTAssertEqual(IOSCameraController.interruptionEvent(bare), .interrupted(.other))
        // Every line is short: a few words; buttons one or two.
        let lines: [String] = [IOSCameraText.notStarted, IOSCameraText.tooWarm, IOSCameraText.inUse,
                               IOSCameraText.needsFullScreen, IOSCameraText.paused, IOSCameraText.photoFailed]
        for line in lines {
            XCTAssertLessThanOrEqual(words(line), 4, line)
        }
        let buttons: [String] = [IOSCameraText.doneLabel, IOSCameraText.shutterLabel, IOSCameraText.torchLabel,
                                 IOSCameraText.settingsLabel, IOSImportText.cameraLabel, IOSImportText.scannerLabel]
        for button in buttons {
            XCTAssertLessThanOrEqual(words(button), 2, button)
        }
        XCTAssertLessThanOrEqual(words(IOSCameraText.shutterHint), 15)
        XCTAssertEqual(IOSCameraText.pageCount(1), "1 page")
        XCTAssertEqual(IOSCameraText.pageCount(0), "0 pages")
        XCTAssertEqual(IOSCameraText.pageCount(3), "3 pages")
    }

    // MARK: The screen's model

    @MainActor
    func test_withNoCamera_theScreenSaysSo_andAsksForNothing() async {
        let driver = FakeCameraDriver()
        let access = FakeCameraAccess(status: .notDetermined, grants: true)
        let model: IOSCameraModel = makeModel(driver, access: access, hasCamera: false, center: NotificationCenter())
        await model.appear()
        XCTAssertEqual(model.availability, .noCamera)
        XCTAssertEqual(model.message, "No camera here")
        XCTAssertFalse(model.opensSettings)
        XCTAssertFalse(model.showsPreview)
        XCTAssertFalse(model.canShoot)
        XCTAssertEqual(access.asks, 0)
        XCTAssertEqual(driver.prepares, 0)
        XCTAssertEqual(driver.starts, 0)
        let shot: IOSCameraShot? = await model.shoot()
        XCTAssertNil(shot)
        XCTAssertEqual(driver.photos, 0)
        model.disappear()
        XCTAssertEqual(driver.stops, 0)
    }

    @MainActor
    func test_access_isAskedOnce_andADenialOffersSettings() async {
        let driver = FakeCameraDriver()
        let access = FakeCameraAccess(status: .notDetermined, grants: false)
        let model: IOSCameraModel = makeModel(driver, access: access, hasCamera: true, center: NotificationCenter())
        await model.appear()
        XCTAssertEqual(access.asks, 1)
        XCTAssertEqual(model.availability, .denied)
        XCTAssertEqual(model.message, "Camera access is off")
        XCTAssertTrue(model.opensSettings)
        XCTAssertEqual(driver.prepares, 0)
        XCTAssertEqual(driver.starts, 0)
        // Opened again: not asked again.
        model.disappear()
        await model.appear()
        XCTAssertEqual(access.asks, 1)
        XCTAssertEqual(model.message, "Camera access is off")
        // Not allowed at all (Screen Time, a profile): said so, never asked, no Settings.
        let limited = FakeCameraAccess(status: .restricted, grants: true)
        let other: IOSCameraModel = makeModel(FakeCameraDriver(), access: limited, hasCamera: true, center: NotificationCenter())
        await other.appear()
        XCTAssertEqual(limited.asks, 0)
        XCTAssertEqual(other.message, "Camera not allowed")
        XCTAssertFalse(other.opensSettings)
        // A camera that cannot be set up says it did not start.
        let broken = FakeCameraDriver()
        broken.prepareResult = false
        let failing: IOSCameraModel = makeModel(broken, access: FakeCameraAccess(status: .authorized, grants: true),
                                                hasCamera: true, center: NotificationCenter())
        await failing.appear()
        XCTAssertEqual(failing.message, "Camera did not start")
        XCTAssertEqual(broken.starts, 0)
        XCTAssertFalse(failing.showsPreview)
    }

    @MainActor
    func test_theCamera_isSetUpOnce_andStartsAndStops_asTheAppAndTheDeviceAllow() async throws {
        let driver = FakeCameraDriver()
        driver.frameSource = FixtureFrameSource(stillFrames())
        let access = FakeCameraAccess(status: .notDetermined, grants: true)
        let center = NotificationCenter()
        let model: IOSCameraModel = makeModel(driver, access: access, hasCamera: true, center: center)
        await model.appear()
        XCTAssertEqual(access.asks, 1)
        XCTAssertEqual(model.availability, .available)
        XCTAssertEqual(driver.prepares, 1)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(model.showsPreview)
        XCTAssertTrue(model.hasTorch)
        XCTAssertNil(model.message)
        // The live frames give the page's outline.
        try await ImportTestSupport.waitUntil(timeout: 60) { model.live?.outline != nil }
        XCTAssertTrue(model.canShoot)

        // The background stops it, the front starts it again.
        model.apply(IOSCameraEvent.background)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertNil(model.live)
        XCTAssertFalse(model.canShoot)
        model.apply(IOSCameraEvent.foreground)
        XCTAssertEqual(driver.starts, 2)

        // Heat, as the system reports it.
        access.thermal = .serious
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await ImportTestSupport.waitUntil(timeout: 10) { model.lifecycle.isTooWarm }
        XCTAssertEqual(driver.stops, 2)
        XCTAssertEqual(model.message, "Paused: too warm")
        access.thermal = .nominal
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await ImportTestSupport.waitUntil(timeout: 10) { !model.lifecycle.isTooWarm }
        XCTAssertEqual(driver.starts, 3)
        XCTAssertNil(model.message)

        // An interruption the session reports: not stopped here, no shutter meanwhile.
        let report: (@MainActor (IOSCameraEvent) -> Void)? = driver.onEvent
        XCTAssertNotNil(report)
        report?(IOSCameraEvent.interrupted(.inUse))
        XCTAssertEqual(driver.stops, 2)
        XCTAssertEqual(model.message, "Camera in use")
        XCTAssertFalse(model.canShoot)
        report?(IOSCameraEvent.interruptionEnded)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.canShoot)

        // A photo in the corner editor stops it until the editor closes.
        model.apply(IOSCameraEvent.reviewStarted)
        XCTAssertEqual(driver.stops, 3)
        model.apply(IOSCameraEvent.reviewEnded)
        XCTAssertEqual(driver.starts, 4)

        // Closed, then opened again: set up once, asked once.
        model.disappear()
        XCTAssertEqual(driver.stops, 4)
        await model.appear()
        XCTAssertEqual(driver.prepares, 1)
        XCTAssertEqual(access.asks, 1)
        XCTAssertEqual(driver.starts, 5)
        model.disappear()
    }

    @MainActor
    func test_theTorch_turnsOnAndIsOffAgainWhenTheCameraStops() async {
        let driver = FakeCameraDriver()
        let model: IOSCameraModel = makeModel(driver, access: FakeCameraAccess(status: .authorized, grants: true),
                                              hasCamera: true, center: NotificationCenter())
        await model.appear()
        await model.toggleTorch()
        XCTAssertTrue(model.torchOn)
        XCTAssertTrue(driver.torch)
        await model.toggleTorch()
        XCTAssertFalse(model.torchOn)
        await model.toggleTorch()
        model.apply(IOSCameraEvent.background)
        XCTAssertFalse(model.torchOn)
        // No torch: nothing to turn on.
        let plain = FakeCameraDriver()
        plain.hasTorch = false
        let dark: IOSCameraModel = makeModel(plain, access: FakeCameraAccess(status: .authorized, grants: true),
                                             hasCamera: true, center: NotificationCenter())
        await dark.appear()
        XCTAssertFalse(dark.hasTorch)
        await dark.toggleTorch()
        XCTAssertFalse(dark.torchOn)
        model.disappear()
        dark.disappear()
    }

    @MainActor
    func test_theShutter_takesAPhoto_withTheLiveOutlineTurnedIntoThePhoto() async throws {
        let driver = FakeCameraDriver()
        driver.frameSource = FixtureFrameSource(stillFrames())
        let model: IOSCameraModel = makeModel(driver, access: FakeCameraAccess(status: .authorized, grants: true),
                                              hasCamera: true, center: NotificationCenter())
        await model.appear()
        try await ImportTestSupport.waitUntil(timeout: 60) { model.live?.outline != nil }
        let outline: Quad = try XCTUnwrap(model.live?.outline)
        driver.photo = IOSCameraPhoto(data: Data([1, 2, 3]), rotationDegrees: 90, mirrored: false)
        let first: IOSCameraShot? = await model.shoot()
        let shot: IOSCameraShot = try XCTUnwrap(first)
        XCTAssertEqual(shot.data, Data([1, 2, 3]))
        XCTAssertEqual(shot.liveOutline, LiveQuadTracker.photoOutline(outline, rotationDegrees: 90))
        XCTAssertEqual(model.shotCount, 1)
        XCTAssertEqual(driver.photos, 1)
        XCTAssertFalse(model.isTakingPhoto)
        // A mirrored photo (a front camera's), or one whose turn is not known: no outline to start from.
        driver.photo = IOSCameraPhoto(data: Data([4]), rotationDegrees: 90, mirrored: true)
        let second: IOSCameraShot? = await model.shoot()
        let mirrored: IOSCameraShot = try XCTUnwrap(second)
        XCTAssertNil(mirrored.liveOutline)
        driver.photo = IOSCameraPhoto(data: Data([5]), rotationDegrees: nil, mirrored: false)
        let third: IOSCameraShot? = await model.shoot()
        let unturned: IOSCameraShot = try XCTUnwrap(third)
        XCTAssertNil(unturned.liveOutline)
        XCTAssertEqual(model.shotCount, 3)
        // A photo that fails says so, and the next one clears it.
        driver.photo = nil
        let failed: IOSCameraShot? = await model.shoot()
        XCTAssertNil(failed)
        XCTAssertEqual(model.message, "Photo not taken")
        XCTAssertEqual(model.shotCount, 3)
        driver.photo = IOSCameraPhoto(data: Data([6]), rotationDegrees: 0, mirrored: false)
        let again: IOSCameraShot? = await model.shoot()
        XCTAssertNotNil(again)
        XCTAssertNil(model.message)
        // Stopped: no photo.
        model.apply(IOSCameraEvent.background)
        let stopped: IOSCameraShot? = await model.shoot()
        XCTAssertNil(stopped)
        XCTAssertEqual(driver.photos, 5)
        model.disappear()
    }

    // MARK: From the shutter into the queue

    @MainActor
    func test_aShot_goesThroughTheCornerEditor_intoTheQueue_withItsFocalLength() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .unsure))
        let shot = IOSCameraShot(data: cameraStill(), liveOutline: nil)
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importShot(shot)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let request: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(request.fileName, "Camera photo")
        XCTAssertEqual(request.plan.corners, sheetQuad)
        XCTAssertEqual(request.plan.reason, PhotoReviewReason.unsure)
        XCTAssertEqual(request.photo.width, 600)
        XCTAssertEqual(request.photo.height, 450)
        XCTAssertEqual(importer.progressText, PhotoImport.progressMessage(1, of: 1))
        importer.answer(PhotoCornersAnswer(choice: .useCorners, corners: request.plan.corners))
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertNil(state.errorMessage)

        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.count, 1)
        let page: ScannedPage = try XCTUnwrap(state.scannedPages.first)
        XCTAssertEqual(page.source, .photo)
        let capture: CaptureFacts = try XCTUnwrap(page.capture)
        // The camera's focal length (EXIF, 26 mm as on 35 mm film) in pixels of the photo.
        let focal: Double = try XCTUnwrap(CaptureScale.focalLengthPixels(26, width: 600, height: 450))
        XCTAssertEqual(try XCTUnwrap(capture.focalLength), focal, accuracy: 1e-9)
        XCTAssertEqual(capture.quad, sheetQuad)
        XCTAssertEqual(capture.sourceWidth, 600)
        XCTAssertEqual(capture.sourceHeight, 450)
        XCTAssertEqual(capture.kind, .document)
        // Cut out at its real size, the photo kept as the other version.
        let scale: CaptureScaleResult = try XCTUnwrap(capture.scale)
        XCTAssertEqual(scale.size, "a4")
        XCTAssertEqual(page.dpi, scale.dpi)
        XCTAssertEqual(page.geometry?.basis, .perspective)
        XCTAssertEqual(page.fullPixelSize, CGSize(width: scale.pixelWidth, height: scale.pixelHeight))
    }

    @MainActor
    func test_aShot_whosePageIsNotFoundClearly_startsFromTheLiveOutline() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let start: Quad = PhotoImport.startCorners(width: 600, height: 450)
        let importer = IOSImportSession(state: state, finder: fixedFinder(start, reason: .nothingFound))
        let live: Quad = sheetQuad.scaled(1.0 / 600.0, 1.0 / 450.0)
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importShot(IOSCameraShot(data: cameraStill(), liveOutline: live))
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let request: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(request.plan.reason, PhotoReviewReason.none)
        XCTAssertLessThan(request.plan.corners.maxCornerDistance(sheetQuad), 1e-6)
        importer.answer(PhotoCornersAnswer.skip)
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertTrue(state.scannedPages.isEmpty)
    }

    func test_theLiveOutline_isOnlyAStartWhereThePhotoGivesNone() {
        let start: Quad = PhotoImport.startCorners(width: 600, height: 450)
        let unsure = IOSFoundPage(corners: start, reason: PhotoReviewReason.unsure, byVision: false)
        let clear = IOSFoundPage(corners: sheetQuad, reason: PhotoReviewReason.none, byVision: true)
        let live: Quad = sheetQuad.scaled(1.0 / 600.0, 1.0 / 450.0)
        // Found clearly in the photo: the photo's own page.
        XCTAssertEqual(IOSImportSession.seeded(clear, liveOutline: live, width: 600, height: 450), clear)
        // No live outline: the search's start.
        XCTAssertEqual(IOSImportSession.seeded(unsure, liveOutline: nil, width: 600, height: 450), unsure)
        // The live outline, in the photo's pixels.
        let seeded: IOSFoundPage = IOSImportSession.seeded(unsure, liveOutline: live, width: 600, height: 450)
        XCTAssertEqual(seeded.reason, PhotoReviewReason.none)
        XCTAssertFalse(seeded.byVision)
        XCTAssertLessThan(seeded.corners.maxCornerDistance(sheetQuad), 1e-6)
        // Partly outside the photo: kept within it.
        let wide = Quad(topLeft: CGPoint(x: -0.1, y: 0.1), topRight: CGPoint(x: 0.9, y: 0.1),
                        bottomRight: CGPoint(x: 0.9, y: 1.2), bottomLeft: CGPoint(x: -0.1, y: 1.2))
        let kept: IOSFoundPage = IOSImportSession.seeded(unsure, liveOutline: wide, width: 600, height: 450)
        XCTAssertTrue(kept.corners.isInside(width: 600, height: 450))
        XCTAssertEqual(Double(kept.corners.topLeft.x), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(kept.corners.bottomRight.y), 450, accuracy: 1e-9)
        // An outline no page can be cut out along (a sliver): the search's start.
        let sliver = Quad(topLeft: CGPoint(x: 0.5, y: 0.1), topRight: CGPoint(x: 0.501, y: 0.1),
                          bottomRight: CGPoint(x: 0.501, y: 0.9), bottomLeft: CGPoint(x: 0.5, y: 0.9))
        XCTAssertEqual(IOSImportSession.seeded(unsure, liveOutline: sliver, width: 600, height: 450), unsure)
        XCTAssertEqual(IOSImportText.shotName, "Camera photo")
    }

    // MARK: Where it is offered, and the Simulator

    @MainActor
    func test_ourCamera_isOfferedWherePagesAreCollected_besideApplesScanner() {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        XCTAssertTrue(IOSShell.offersOwnCamera(state.settings))
        var photos: ScanSettings = state.settings
        photos.intent = .photo
        XCTAssertFalse(IOSShell.offersOwnCamera(photos))
        // Apple's scanner stays on its three tasks.
        XCTAssertTrue(IOSShell.offersCamera(.document))
        XCTAssertFalse(IOSShell.offersCamera(.feeder))
        XCTAssertEqual(IOSImportText.cameraLabel, "Camera")
        XCTAssertEqual(IOSImportText.scannerLabel, "Doc scanner")
    }

    @MainActor
    func test_theSimulator_hasNoCamera_soOurCameraScreenSaysSo() async throws {
        #if targetEnvironment(simulator)
        XCTAssertFalse(IOSCameraLens.hasCamera)
        XCTAssertEqual(IOSCameraAvailability.ownCamera, .noCamera)
        let model: IOSCameraModel = IOSCameraModel.makeLive()
        await model.appear()
        XCTAssertEqual(model.availability, .noCamera)
        XCTAssertEqual(model.message, "No camera here")
        XCTAssertFalse(model.lifecycle.isRunning)
        XCTAssertFalse(model.showsPreview)
        model.disappear()
        #else
        throw XCTSkip("Runs on the Simulator, which has no camera.")
        #endif
    }
}
#endif
