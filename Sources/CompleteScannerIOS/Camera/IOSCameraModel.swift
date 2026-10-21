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
/// photo's shares; the scan screen hands it to the import (`IOSImportSession.importShot`).
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

    public let driver: any IOSCameraDriving
    private let tracker: LiveQuadTracker
    private let hasCamera: @MainActor () -> Bool
    private let authorization: @MainActor () -> AVAuthorizationStatus
    private let requestAccess: @MainActor () async -> Bool
    private let thermalState: @MainActor () -> ProcessInfo.ThermalState
    private let center: NotificationCenter
    private var asked: Bool = false
    /// The session is set up (the preview can show it).
    @Published private var prepared: Bool = false
    private var thermalObserver: NSObjectProtocol?

    /// `driver` runs the session. The others default to the device's own: its cameras
    /// (`IOSCameraLens.hasCamera`), the camera permission and its prompt, and the thermal state with
    /// its notifications on `center`; tests pass stand-ins.
    public init(driver: any IOSCameraDriving, tracker: LiveQuadTracker? = nil,
                hasCamera: (@MainActor () -> Bool)? = nil,
                authorization: (@MainActor () -> AVAuthorizationStatus)? = nil,
                requestAccess: (@MainActor () async -> Bool)? = nil,
                thermalState: (@MainActor () -> ProcessInfo.ThermalState)? = nil,
                center: NotificationCenter = .default) {
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

    /// The screen is gone: the session stops.
    public func disappear() {
        apply(.hidden)
        stopObserving()
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
    /// mirrored photo, or with no outline shown); nil when the camera does not run or the photo failed.
    public func shoot() async -> IOSCameraShot? {
        guard canShoot else { return nil }
        isTakingPhoto = true
        photoFailed = false
        let outline: Quad? = live?.outline
        let photo: IOSCameraPhoto? = await driver.takePhoto()
        isTakingPhoto = false
        guard let taken = photo else {
            photoFailed = true
            return nil
        }
        shotCount += 1
        tracker.reset()
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
        tracker.stopFollowing()
        driver.stopRunning()
        torchOn = false
        live = nil
    }

    private func show(_ update: LiveQuadUpdate) {
        guard lifecycle.isLive else { return }
        live = update
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
