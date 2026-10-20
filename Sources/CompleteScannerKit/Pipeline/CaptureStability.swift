import CoreGraphics
import Foundation

/// Where the camera's automatic shutter stands (`CaptureStability`). Twin of C# `CaptureState`.
public enum CaptureState: Sendable {
    /// No page is seen clearly enough.
    case noPage
    /// A page is seen but moves.
    case moving
    /// The page holds still; the shutter fires when it has for long enough.
    case steadying
    /// The page was taken; waiting for it to go or move before the next.
    case captured
}

/// One video frame's detection, as the stability logic reads it.
public struct CaptureObservation: Equatable, Sendable {
    /// The page found in the frame, in the frame's pixels; nil when none.
    public var quad: Quad?
    /// The detection's confidence, 0...1.
    public var confidence: Double
    /// When the frame was taken, in milliseconds on any steady clock.
    public var timestampMs: Double
    /// The frame's size in pixels (movement is measured against its diagonal).
    public var frameWidth: Int
    public var frameHeight: Int

    public init(quad: Quad?, confidence: Double, timestampMs: Double, frameWidth: Int, frameHeight: Int) {
        self.quad = quad
        self.confidence = confidence
        self.timestampMs = timestampMs
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }
}

/// What the shutter should do after a frame.
public struct CaptureDecision: Equatable, Sendable {
    /// The state after the frame.
    public var state: CaptureState
    /// Take the photo now (true on exactly one frame per steady page).
    public var shouldCapture: Bool
    /// How far the page is through the steady time, 0...1 (for a ring in the view).
    public var progress: Double
}

/// The thresholds of `CaptureStability`; the defaults are its constants.
public struct CaptureStabilityOptions: Equatable, Sendable {
    /// The page must hold still this long before the shutter fires.
    public var steadyMs = CaptureStability.steadyMs
    /// To start holding still, no corner moved more than this share of the frame's diagonal since the last frame.
    public var enterMovement = CaptureStability.enterMovement
    /// While holding still, no corner strays more than this share from where it was when holding started.
    public var stayMovement = CaptureStability.stayMovement
    /// To start holding still the detection must be at least this confident…
    public var enterConfidence = CaptureStability.enterConfidence
    /// …and to stay, at least this.
    public var stayConfidence = CaptureStability.stayConfidence
    /// A page missing from the frames for up to this long is still the same page.
    public var maxGapMs = CaptureStability.maxGapMs
    /// After a capture, the next page counts as new once a corner moved this share of the diagonal from the captured page.
    public var newPageMovement = CaptureStability.newPageMovement

    public init() {}

    public static let `default` = CaptureStabilityOptions()
}

/// Decides when the camera may take the page by itself: the page must be seen with confidence for
/// `steadyMs` with its corners holding still. Hysteresis keeps the decision from flickering: holding
/// still starts when no corner moved more than `enterMovement` of the diagonal since the previous
/// frame with confidence at least `enterConfidence`, and lasts while no corner strays more than
/// `stayMovement` from where it was then and the confidence stays at least `stayConfidence`; a page
/// missing for up to `maxGapMs` is waited for, and the time it was missing does not count as holding
/// still. Once taken, the same page is not taken again: the shutter re-arms when frames without a
/// page span more than `maxGapMs` (the page has gone) or a corner moved `newPageMovement` from where
/// it was taken, or when `reset()` is called; a pause between frames alone does not re-arm it.
/// Corners are compared whichever of them a quad names first (`movement`), so a page turned to where
/// `Quad.fromCorners` names its corners from another edge does not seem to move. Pure logic: the
/// camera feeds it one `CaptureObservation` per analysed frame, in time order. Twin of C#
/// `CaptureStability`.
public struct CaptureStability: Sendable {
    public static let steadyMs = 600.0
    public static let enterMovement = 0.01
    public static let stayMovement = 0.025
    public static let enterConfidence = 0.6
    public static let stayConfidence = 0.45
    public static let maxGapMs = 250.0
    public static let newPageMovement = 0.15

    private let options: CaptureStabilityOptions
    private var previous: Quad?
    private var anchor: Quad?
    private var captured: Quad?
    private var steadySince = 0.0
    private var lastSeen = -Double.infinity
    private var missing = false

    /// The state after the last frame.
    public private(set) var state: CaptureState = .noPage

    public init(options: CaptureStabilityOptions = .default) {
        self.options = options
    }

    /// Forget everything (a new document, the user took a photo by hand): the next steady page is taken.
    public mutating func reset() {
        state = .noPage
        previous = nil
        anchor = nil
        captured = nil
        lastSeen = -Double.infinity
        missing = false
    }

    /// The decision after one more frame.
    public mutating func update(_ frame: CaptureObservation) -> CaptureDecision {
        let o = options
        let fw = Double(frame.frameWidth), fh = Double(frame.frameHeight)
        let diagonal = (fw * fw + fh * fh).squareRoot()
        let t = frame.timestampMs

        guard let quad = frame.quad else {
            if t - lastSeen <= o.maxGapMs {
                // Waiting for the page to come back; the steady time stands still meanwhile.
                missing = true
                return CaptureDecision(state: state, shouldCapture: false,
                                       progress: state == .steadying ? progress(lastSeen) : 0)
            }
            previous = nil
            anchor = nil
            captured = nil
            missing = false
            state = .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }

        let returning = t - lastSeen > o.maxGapMs
        // Back after frames without it: the time it was missing is not time held still.
        if missing && !returning { steadySince += t - lastSeen }
        missing = false
        lastSeen = t
        let last = previous
        previous = quad

        if state == .captured {
            // The page taken stays taken, however long since the last frame, until it moves away.
            if let taken = captured, CaptureStability.movement(quad, taken) < o.newPageMovement * diagonal {
                return CaptureDecision(state: state, shouldCapture: false, progress: 1)
            }
            captured = nil
            state = .moving
        }
        if returning {
            anchor = nil
            state = frame.confidence >= o.stayConfidence ? .moving : .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }

        if state == .steadying, let held = anchor {
            let stays = frame.confidence >= o.stayConfidence && CaptureStability.movement(quad, held) <= o.stayMovement * diagonal
            if stays {
                if t - steadySince >= o.steadyMs {
                    state = .captured
                    captured = quad
                    anchor = nil
                    return CaptureDecision(state: state, shouldCapture: true, progress: 1)
                }
                return CaptureDecision(state: state, shouldCapture: false, progress: progress(t))
            }
            anchor = nil
            state = frame.confidence >= o.stayConfidence ? .moving : .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }

        if frame.confidence < o.enterConfidence {
            state = frame.confidence >= o.stayConfidence ? .moving : .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }
        if let earlier = last, CaptureStability.movement(quad, earlier) <= o.enterMovement * diagonal {
            state = .steadying
            anchor = earlier
            steadySince = t
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }
        state = .moving
        return CaptureDecision(state: state, shouldCapture: false, progress: 0)
    }

    private func progress(_ t: Double) -> Double {
        min(max((t - steadySince) / options.steadyMs, 0), 1)
    }

    /// How far the page moved from `b` to `a`: the largest distance between their corners, paired from
    /// whichever corner of `b` fits best (the least over the four ways round), so a quad whose corners
    /// are named from another edge is the same.
    public static func movement(_ a: Quad, _ b: Quad) -> Double {
        var best = Double.greatestFiniteMagnitude
        for shift in 0..<4 {
            var worst = 0.0
            for i in 0..<4 { worst = max(worst, Quad.distance(a[i], b[i + shift])) }
            best = min(best, worst)
        }
        return best
    }
}
