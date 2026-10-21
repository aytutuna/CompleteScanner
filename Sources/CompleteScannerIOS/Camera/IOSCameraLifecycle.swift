#if os(iOS)
import AVFoundation
import Foundation

/// Why the camera was taken from us for a while (`AVCaptureSession` interruptions: a phone call,
/// another app using the camera, the iPad showing two apps side by side, the device under strain).
public enum IOSCameraInterruption: Equatable, Sendable {
    /// Another app (a call, FaceTime) has the camera.
    case inUse
    /// The device is too warm or under strain (system pressure).
    case tooWarm
    /// The iPad shows other apps beside this one (Split View, Slide Over, Stage Manager).
    case multitasking
    /// Anything else.
    case other

    /// The interruption a session reports.
    public static func from(_ reason: AVCaptureSession.InterruptionReason) -> IOSCameraInterruption {
        switch reason {
        case .videoDeviceInUseByAnotherClient: return .inUse
        case .videoDeviceNotAvailableDueToSystemPressure: return .tooWarm
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return .multitasking
        default: return .other
        }
    }

    /// The camera screen's one line while it lasts.
    public var reason: String {
        switch self {
        case .inUse: return IOSCameraText.inUse
        case .tooWarm: return IOSCameraText.tooWarm
        case .multitasking: return IOSCameraText.needsFullScreen
        case .other: return IOSCameraText.paused
        }
    }
}

/// What happens to the camera screen and the app that decides whether the camera may run.
public enum IOSCameraEvent: Equatable, Sendable {
    /// The camera screen is shown, or gone.
    case shown
    case hidden
    /// The app went to the background, or is active (again: back from the background, or after a moment
    /// inactive in the front).
    case background
    case foreground
    /// The camera is allowed and set up (true), or not (false).
    case ready(Bool)
    /// The device's thermal state changed (`ProcessInfo.thermalState`).
    case thermal(ProcessInfo.ThermalState)
    /// The session was interrupted (the system stopped it), or the interruption ended (the system
    /// started it again).
    case interrupted(IOSCameraInterruption)
    case interruptionEnded
    /// A photo taken is in the corner editor, or the editor closed.
    case reviewStarted
    case reviewEnded
    /// The session stopped with an error (media services were reset, say).
    case runtimeError
}

/// What the camera screen does with the session after an event.
public enum IOSCameraCommand: Equatable, Sendable {
    /// Leave the session as it is.
    case keep
    case start
    case stop
}

/// When our camera runs: only while its screen is shown, the app is in the front, the camera is allowed
/// and set up, the device is not too warm (thermal state `.serious` or worse stops it) and no photo is in
/// the corner editor. It starts again as soon as all of that holds. An interruption (a call, Control
/// Center, another app using the camera) is the system stopping the session: it is not stopped again
/// here, so AVFoundation starts it again by itself when the interruption ends; meanwhile the camera is
/// not live (`isLive`: no frames, no shutter) and the screen says why. Coming back from the background or
/// to the screen forgets an interruption whose end was not reported; the app made active again without
/// having gone to the background (`.foreground` while in the front) does not. After a session error it is started again,
/// up to `maxRestarts` times while the screen is shown. A value: `handle` answers what to do with the
/// session.
public struct IOSCameraLifecycle: Equatable, Sendable {
    /// Restarts after session errors while the screen is shown, before it stays stopped.
    public static let maxRestarts: Int = 3

    public private(set) var isShown: Bool = false
    public private(set) var isInForeground: Bool = true
    public private(set) var isReady: Bool = false
    public private(set) var isTooWarm: Bool = false
    public private(set) var interruption: IOSCameraInterruption?
    public private(set) var isReviewing: Bool = false
    /// The session runs (the last command was start).
    public private(set) var isRunning: Bool = false
    /// The session stopped with errors more often than `maxRestarts`.
    public private(set) var hasFailed: Bool = false
    private var restarts: Int = 0

    public init() {}

    /// Everything allows the camera to run now (an interruption aside, which the system handles).
    public var shouldRun: Bool {
        isShown && isInForeground && isReady && !isTooWarm && !isReviewing && !hasFailed
    }

    /// The camera runs and is not interrupted: frames come and a photo can be taken.
    public var isLive: Bool {
        isRunning && interruption == nil
    }

    /// Takes `event` in and answers what to do with the session.
    public mutating func handle(_ event: IOSCameraEvent) -> IOSCameraCommand {
        switch event {
        case .shown:
            isShown = true
            interruption = nil
            restarts = 0
            hasFailed = false
        case .hidden:
            isShown = false
        case .background:
            isInForeground = false
        case .foreground:
            // Only back from the background: the app made active again without leaving the front (Control
            // Center pulled down and closed) leaves an interruption still in effect as it is.
            if !isInForeground {
                interruption = nil
            }
            isInForeground = true
        case .ready(let ready):
            isReady = ready
        case .thermal(let state):
            isTooWarm = !IOSCameraLifecycle.thermalAllows(state)
        case .interrupted(let why):
            interruption = why
        case .interruptionEnded:
            interruption = nil
        case .reviewStarted:
            isReviewing = true
        case .reviewEnded:
            isReviewing = false
        case .runtimeError:
            // The session stopped by itself: started again below while it may run.
            isRunning = false
            restarts += 1
            if restarts > IOSCameraLifecycle.maxRestarts {
                hasFailed = true
            }
        }
        return settle()
    }

    /// The camera screen's one line while the camera waits (too warm, interrupted, failed); nil while it
    /// runs or waits for nothing the user should know about.
    public var pauseReason: String? {
        if hasFailed { return IOSCameraText.notStarted }
        if isTooWarm { return IOSCameraText.tooWarm }
        if let why = interruption { return why.reason }
        return nil
    }

    /// The camera may run at this thermal state: nominal or fair, not serious or critical.
    public static func thermalAllows(_ state: ProcessInfo.ThermalState) -> Bool {
        state.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    private mutating func settle() -> IOSCameraCommand {
        let run: Bool = shouldRun
        if run && !isRunning {
            isRunning = true
            return .start
        }
        if !run && isRunning {
            isRunning = false
            return .stop
        }
        return .keep
    }
}

/// The camera screen's short texts.
public enum IOSCameraText {
    public static let title = "Camera"
    public static let doneLabel = "Done"
    public static let shutterLabel = "Take photo"
    public static let shutterHint = "The page is found again in the photo, then you check its corners"
    public static let torchLabel = "Torch"
    public static let settingsLabel = "Settings"
    /// The session could not be set up, or stopped with errors.
    public static let notStarted = "Camera did not start"
    public static let tooWarm = "Paused: too warm"
    public static let inUse = "Camera in use"
    public static let needsFullScreen = "Needs full screen"
    public static let paused = "Camera paused"
    public static let photoFailed = "Photo not taken"
    /// The pages in the queue: "1 page", "3 pages".
    public static func pageCount(_ count: Int) -> String {
        count == 1 ? "1 page" : "\(count) pages"
    }
}
#endif
