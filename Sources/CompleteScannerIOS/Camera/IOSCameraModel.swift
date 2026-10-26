#if os(iOS)
import AVFoundation
import Combine
import CompleteScannerKit
import Foundation

/// A photo the camera took: its file's bytes as the camera wrote them (HEIC or JPEG, with the
/// orientation tag and the EXIF the camera recorded, its focal length among them), the clockwise turn it
/// was taken with (the capture's rotation angle; nil when not known) and whether it is mirrored (a front
/// camera's).
public struct IOSCameraPhoto: Sendable {
    public let data: Data
    public let rotationDegrees: Int?
    public let mirrored: Bool

    public init(data: Data, rotationDegrees: Int?, mirrored: Bool) {
        self.data = data
        self.rotationDegrees = rotationDegrees
        self.mirrored = mirrored
    }
}

/// A photo from our camera on its way into the queue (`IOSImportSession.importShot`): its file's bytes,
/// and the page's outline the live preview showed when it was taken, as shares of the upright photo
/// (nil when none was shown), the start for the corner editor when the page is not found clearly in the
/// photo itself.
public struct IOSCameraShot: Sendable {
    public let data: Data
    public let liveOutline: Quad?

    public init(data: Data, liveOutline: Quad?) {
        self.data = data
        self.liveOutline = liveOutline
    }
}

/// The capture session as the camera screen drives it: `IOSCameraController` on a device, a stand-in
/// in tests. Every call is made on the main actor; the session's own work runs on its queue.
@MainActor
public protocol IOSCameraDriving: AnyObject {
    /// Sets the session up once (the camera, `IOSCameraLens`; its outputs); false when it could not be.
    func prepare() async -> Bool
    func startRunning()
    func stopRunning()
    /// The camera has a torch (known once prepared).
    var hasTorch: Bool { get }
    /// Turns the torch on or off; whether it is on afterwards.
    func setTorch(_ on: Bool) async -> Bool
    /// Takes a photo; nil when it could not be taken.
    func takePhoto() async -> IOSCameraPhoto?
    /// The live frames for the page outline; nil when there are none.
    var frameSource: FrameSource? { get }
    /// What the session reports (interruptions, errors), as events of `IOSCameraLifecycle`.
    var onEvent: (@MainActor (IOSCameraEvent) -> Void)? { get set }
}

/// Our own camera screen without a screen: whether the camera can be used here (and if not, why, with
/// Settings when access is off), asking for access the first time only, when the session runs
/// (`IOSCameraLifecycle`: shown, in the front, not too warm, not interrupted, no photo in the corner
/// editor), the page's live outline (`LiveQuadTracker` on the session's frames), the torch and the
/// shutter. A photo taken comes back as an `IOSCameraShot` with the live outline turned into the
/// photo's shares; the scan screen hands it to the import (`IOSImportSession.importShot`). The automatic
/// shutter (`autoShutter`, on unless turned off; remembered in `UserDefaults`) takes the photo itself when
/// a live update says so (`LiveQuadUpdate.shouldCapture`: the page held still on a sharp, lit frame) and
/// hands it to `onAutoShot`; a decision that comes while a photo cannot be taken (one being taken or read,
/// `canTakePage` false) has the page judged again, so it is taken once it can be. After every photo the
/// page in view counts as taken (`LiveQuadTracker.markCaptured`), so the next photo waits for the next page.
@MainActor
public final class IOSCameraModel: ObservableObject {
    /// Whether the camera can be used here; nil until checked (and asked, the first time).
    @Published public private(set) var availability: IOSCameraAvailability?
    /// The session could not be set up.
    @Published public private(set) var setupFailed: Bool = false
    /// When the session runs.
    @Published public private(set) var lifecycle: IOSCameraLifecycle = IOSCameraLifecycle()
    /// The last live search; nil while the camera does not run.
    @Published public private(set) var live: LiveQuadUpdate?
    @Published public private(set) var hasTorch: Bool = false
    @Published public private(set) var torchOn: Bool = false
    @Published public private(set) var isTakingPhoto: Bool = false
    /// The last photo could not be taken.
    @Published public private(set) var photoFailed: Bool = false
    /// Photos taken while the screen was open (the haptic tap follows it).
    @Published public private(set) var shotCount: Int = 0
    /// The automatic shutter is on (`setAutoShutter`).
    @Published public private(set) var autoShutter: Bool = true
    /// Where the automatic shutter's photos go (the scan screen: `IOSImportSession.importShot`); nil: the
    /// automatic shutter takes nothing.
    public var onAutoShot: (@MainActor (IOSCameraShot) async -> Void)?
    /// Whether a page can be taken now besides the camera being live (no photo being read, the queue takes
    /// pages); nil: always.
    public var canTakePage: (@MainActor () -> Bool)?

    /// Where the automatic shutter's setting is remembered.
    public static let autoShutterKey: String = "cameraAutoShutter"

    public let driver: any IOSCameraDriving
    private let tracker: LiveQuadTracker
    private let hasCamera: @MainActor () -> Bool
    private let authorization: @MainActor () -> AVAuthorizationStatus
    private let requestAccess: @MainActor () async -> Bool
    private let thermalState: @MainActor () -> ProcessInfo.ThermalState
    private let center: NotificationCenter
    private let defaults: UserDefaults
    private var asked: Bool = false
    /// The session is set up (the preview can show it).
    @Published private var prepared: Bool = false
    private var thermalObserver: NSObjectProtocol?
    /// Takes "Photo not taken" away again (`failedNoticeNanoseconds` after the photo failed).
    private var failedNoticeClear: Task<Void, Never>?

    /// How long "Photo not taken" stays over the viewfinder.
    public static let failedNoticeNanoseconds: UInt64 = 2_500_000_000

    /// `driver` runs the session. The others default to the device's own: its cameras
    /// (`IOSCameraLens.hasCamera`), the camera permission and its prompt, the thermal state with its
    /// notifications on `center`, and the app's `UserDefaults` for the automatic shutter's setting; tests
    /// pass stand-ins.
    public init(driver: any IOSCameraDriving, tracker: LiveQuadTracker? = nil,
                hasCamera: (@MainActor () -> Bool)? = nil,
                authorization: (@MainActor () -> AVAuthorizationStatus)? = nil,
                requestAccess: (@MainActor () async -> Bool)? = nil,
                thermalState: (@MainActor () -> ProcessInfo.ThermalState)? = nil,
                center: NotificationCenter = .default, defaults: UserDefaults = .standard) {
        self.driver = driver
        if let given = tracker {
            self.tracker = given
        } else {
            self.tracker = LiveQuadTracker()
        }
        if let given = hasCamera {
            self.hasCamera = given
        } else {
            self.hasCamera = { () -> Bool in
                IOSCameraLens.hasCamera
            }
        }
        if let given = authorization {
            self.authorization = given
        } else {
            self.authorization = { () -> AVAuthorizationStatus in
                AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        if let given = requestAccess {
            self.requestAccess = given
        } else {
            self.requestAccess = { () async -> Bool in
                await AVCaptureDevice.requestAccess(for: .video)
            }
        }
        if let given = thermalState {
            self.thermalState = given
        } else {
            self.thermalState = { () -> ProcessInfo.ThermalState in
                ProcessInfo.processInfo.thermalState
            }
        }
        self.center = center
        self.defaults = defaults
        if let stored = defaults.object(forKey: IOSCameraModel.autoShutterKey) as? Bool {
            autoShutter = stored
        }
    }

    /// The model of the device's own camera (`IOSCameraController`).
    public static func makeLive() -> IOSCameraModel {
        IOSCameraModel(driver: IOSCameraController())
    }

    // MARK: What the screen shows

    /// The one line the screen shows instead of (or over) the preview: why the camera cannot be used, that
    /// it did not start, why it waits, or that the last photo was not taken; nil for none.
    public var message: String? {
        if let checked = availability, let reason = checked.reason { return reason }
        if setupFailed { return IOSCameraText.notStarted }
        if let paused = lifecycle.pauseReason { return paused }
        if photoFailed { return IOSCameraText.photoFailed }
        return nil
    }

    /// Settings can turn camera access back on (access is off).
    public var opensSettings: Bool {
        availability?.opensSettings ?? false
    }

    /// The preview can be shown: the camera can be used and is set up.
    public var showsPreview: Bool {
        (availability?.isAvailable ?? false) && prepared && !setupFailed
    }

    /// The shutter can be pressed: the camera is live (running, not interrupted) and no photo is being
    /// taken.
    public var canShoot: Bool {
        lifecycle.isLive && !isTakingPhoto
    }

    // MARK: The screen's life

    /// The screen is shown: the camera is looked for, access asked for when it never was (once), the
    /// session set up and started when everything allows it.
    public func appear() async {
        startObserving()
        apply(.shown)
        apply(.thermal(thermalState()))
        let found: Bool = hasCamera()
        var status: AVAuthorizationStatus = authorization()
        if found && status == .notDetermined && !asked {
            asked = true
            let granted: Bool = await requestAccess()
            status = granted ? .authorized : .denied
        }
        let resolved: IOSCameraAvailability = IOSCameraAvailability.resolve(isSupported: found, authorization: status)
        availability = resolved
        guard resolved.isAvailable, status == .authorized else {
            apply(.ready(false))
            return
        }
        if !prepared {
            let ready: Bool = await driver.prepare()
            prepared = ready
            setupFailed = !ready
            if ready {
                hasTorch = driver.hasTorch
                driver.onEvent = { [weak self] (event: IOSCameraEvent) -> Void in
                    self?.apply(event)
                }
            }
        }
        apply(.ready(prepared))
    }

    /// The screen is gone: the session stops and the page is forgotten.
    public func disappear() {
        apply(.hidden)
        stopObserving()
        tracker.reset()
    }

    /// Turns the automatic shutter on or off, remembered for the next time. Turned on, a page in view that
    /// was decided on while it was off, with no photo taken, is judged afresh, so it is taken once it holds
    /// still; a page photographed by hand stays taken (`LiveQuadTracker.rearm`).
    public func setAutoShutter(_ on: Bool) {
        guard on != autoShutter else { return }
        autoShutter = on
        defaults.set(on, forKey: IOSCameraModel.autoShutterKey)
        if on {
            tracker.rearm()
        }
    }

    /// Takes `event` in and starts or stops the session as `IOSCameraLifecycle` answers.
    public func apply(_ event: IOSCameraEvent) {
        var next: IOSCameraLifecycle = lifecycle
        let command: IOSCameraCommand = next.handle(event)
        lifecycle = next
        switch command {
        case .start:
            start()
        case .stop:
            stop()
        case .keep:
            break
        }
        if !lifecycle.isLive {
            live = nil
        }
    }

    /// Turns the torch on or off.
    public func toggleTorch() async {
        guard hasTorch, lifecycle.isLive else { return }
        let wanted: Bool = !torchOn
        torchOn = await driver.setTorch(wanted)
    }

    /// Takes a photo: the shot with the live outline turned into the upright photo's shares (none for a
    /// mirrored photo, or with no outline shown); nil when the camera does not run or the photo failed. A
    /// failed photo says so for a few seconds and leaves the page in view to be taken again
    /// (`LiveQuadTracker.rearm`).
    public func shoot() async -> IOSCameraShot? {
        guard canShoot else { return nil }
        isTakingPhoto = true
        photoFailed = false
        failedNoticeClear?.cancel()
        let outline: Quad? = live?.outline
        let photo: IOSCameraPhoto? = await driver.takePhoto()
        isTakingPhoto = false
        guard let taken = photo else {
            photoFailed = true
            // No photo of the page: Auto takes it once it holds still again.
            tracker.rearm()
            failedNoticeClear = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: IOSCameraModel.failedNoticeNanoseconds)
                guard !Task.isCancelled, let model = self else { return }
                model.photoFailed = false
            }
            return nil
        }
        shotCount += 1
        // The page in view is taken: the next photo waits for the next page; the outline starts again.
        tracker.markCaptured()
        live = nil
        var seed: Quad?
        if let shown = outline, let degrees = taken.rotationDegrees, !taken.mirrored {
            seed = LiveQuadTracker.photoOutline(shown, rotationDegrees: degrees)
        }
        return IOSCameraShot(data: taken.data, liveOutline: seed)
    }

    // MARK: The session

    private func start() {
        torchOn = false
        live = nil
        if let source = driver.frameSource {
            tracker.follow(source) { [weak self] (update: LiveQuadUpdate) -> Void in
                guard let model = self else { return }
                Task { @MainActor in
                    model.show(update)
                }
            }
        }
        driver.startRunning()
    }

    private func stop() {
        // Paused, not forgotten: the page taken before stays taken when the camera comes back.
        tracker.pauseFollowing()
        driver.stopRunning()
        torchOn = false
        live = nil
    }

    private func show(_ update: LiveQuadUpdate) {
        guard lifecycle.isLive else { return }
        live = update
        if update.shouldCapture {
            shootAutomatically()
        }
    }

    /// The live search says the page held still on a sharp, lit frame: the photo is taken and handed to
    /// `onAutoShot`, when the automatic shutter is on; when a photo cannot be taken now, the page is judged
    /// again.
    private func shootAutomatically() {
        guard autoShutter, let deliver = onAutoShot else { return }
        var free: Bool = true
        if let check = canTakePage {
            free = check()
        }
        guard canShoot, free else {
            tracker.reset()
            return
        }
        Task { @MainActor [weak self] in
            guard let model = self else { return }
            if let shot = await model.shoot() {
                await deliver(shot)
            }
        }
    }

    private func startObserving() {
        guard thermalObserver == nil else { return }
        thermalObserver = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                             queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.thermalChanged()
            }
        }
    }

    private func stopObserving() {
        if let observer = thermalObserver {
            center.removeObserver(observer)
        }
        thermalObserver = nil
    }

    private func thermalChanged() {
        apply(.thermal(thermalState()))
    }
}
#endif
