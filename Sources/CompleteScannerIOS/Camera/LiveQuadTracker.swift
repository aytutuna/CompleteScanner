#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation

/// One live frame of the camera, made small for the page search: its pixels (upright as the sensor
/// gives them, not turned for the screen) and when it was taken, in milliseconds of the capture clock.
public struct IOSCameraFrame: Sendable {
    public let image: RgbaImage
    public let timestampMs: Double

    public init(image: RgbaImage, timestampMs: Double) {
        self.image = image
        self.timestampMs = timestampMs
    }
}

/// Where live frames come from: the camera's video output (`IOSFrameFeed`), or fixture frames in tests.
/// A source hands its frames over one at a time, never two at once, off the main thread when it is the
/// camera, until `stopFrames()`.
public protocol FrameSource: AnyObject {
    /// Starts handing frames to `deliver`; a second call replaces the first one's `deliver`.
    func startFrames(_ deliver: @escaping @Sendable (IOSCameraFrame) -> Void)
    /// Stops handing frames over.
    func stopFrames()
}

/// What the tracker saw in a frame: the page's outline (corners as shares of the frame, 0...1, x to the
/// right and y down, named by `Quad.fromCorners`), nil when no page is in view; how steady it is
/// (`CaptureStability`); whether it holds still now; and the frame's time.
public struct LiveQuadUpdate: Equatable, Sendable {
    public let outline: Quad?
    public let state: CaptureState
    public let progress: Double
    public let timestampMs: Double
    /// The page holds still now (the outline is drawn green): `.steadying`, or `.captured` while the page
    /// stays where it held still (`LiveQuadTracker`), not merely within `newPageMovement` of it.
    public let isSteady: Bool

    /// `isSteady` nil: the page holds still while `state` is `.steadying`.
    public init(outline: Quad?, state: CaptureState, progress: Double, timestampMs: Double, isSteady: Bool? = nil) {
        self.outline = outline
        self.state = state
        self.progress = progress
        self.timestampMs = timestampMs
        if let given = isSteady {
            self.isSteady = given
        } else {
            self.isSteady = state == .steadying
        }
    }
}

/// Follows the page in the camera's live frames for the outline drawn over the preview. About ten
/// frames a second are searched (`frameIntervalMs`; the others are passed over before any work), each
/// small (at most `analysisLongSide` px) and by the shared page search (`PhotoDocumentDetector`, the
/// photo import's), with the outline of the frame before as its hint. A page missed for a moment keeps
/// its outline for `holdMs`, so it does not flicker; how steady it is comes from `CaptureStability`.
/// Once `CaptureStability` has taken the page (`.captured`) it keeps that state until the page moves
/// `newPageMovement` away, so whether the page holds still meanwhile is judged here, by the same rules:
/// it does while no corner strays `stayMovement` from where it held still, and holds still again once no
/// corner moved `enterMovement` since the frame before (`LiveQuadUpdate.isSteady`). Frames are searched on the source's own queue, one at a time, never on the main thread; `reset()`
/// may be called from any thread and drops a frame being searched meanwhile.
public final class LiveQuadTracker: @unchecked Sendable {
    /// About ten searches a second.
    public static let frameIntervalMs: Double = 100
    /// A frame this soon after the last one searched is passed over (a 30 fps camera's every third frame
    /// is searched).
    public static let minFrameGapMs: Double = 90
    /// The long side live frames are searched at.
    public static let analysisLongSide: Int = 480
    /// A page missed for at most this long keeps its outline.
    public static let holdMs: Double = 300

    /// The page search: a frame and the outline found in the frame before (its pixels), if any.
    public typealias Detector = @Sendable (RgbaImage, Quad?) -> PhotoDocumentDetection

    private let detector: Detector
    private let stabilityOptions: CaptureStabilityOptions
    private let lock = NSLock()
    private var stability: CaptureStability
    private var lastSearchedMs: Double?
    private var lastQuad: Quad?
    private var lastSeenMs: Double = -Double.infinity
    /// The page found in the frame searched before (pixels); nil when none was.
    private var lastFound: Quad?
    /// Where the page held still while `.captured` (pixels); nil while it does not.
    private var heldAt: Quad?
    private var frameWidth: Int = 0
    private var frameHeight: Int = 0
    private var generation: Int = 0
    private var source: FrameSource?

    /// `detector` nil: the shared page search with `liveOptions` (tests may pass their own).
    public init(detector: Detector? = nil, stability: CaptureStabilityOptions = .default) {
        if let given = detector {
            self.detector = given
        } else {
            self.detector = { (image: RgbaImage, hint: Quad?) -> PhotoDocumentDetection in
                LiveQuadTracker.detect(image, hint: hint)
            }
        }
        self.stabilityOptions = stability
        self.stability = CaptureStability(options: stability)
    }

    /// The page search's options for live frames: the frame searched at `analysisLongSide`.
    public static var liveOptions: PhotoDocumentOptions {
        var options = PhotoDocumentOptions()
        options.analysisLongSide = analysisLongSide
        return options
    }

    /// The shared page search on one live frame.
    public static func detect(_ image: RgbaImage, hint: Quad?) -> PhotoDocumentDetection {
        PhotoDocumentDetector.detect(image, hint: hint, options: liveOptions)
    }

    /// Searches `frame` unless it comes too soon after the last one searched (nil then). A frame from
    /// an earlier time than the last one (the camera started again) or of another size starts over.
    public func process(_ frame: IOSCameraFrame) -> LiveQuadUpdate? {
        let t: Double = frame.timestampMs
        let width: Int = frame.image.width
        let height: Int = frame.image.height
        lock.lock()
        if let last = lastSearchedMs {
            if t < last {
                clearState()
            } else if t - last < LiveQuadTracker.minFrameGapMs {
                lock.unlock()
                return nil
            }
        }
        if width != frameWidth || height != frameHeight {
            clearState()
            frameWidth = width
            frameHeight = height
        }
        lastSearchedMs = t
        var hint: Quad?
        if let quad = lastQuad, t - lastSeenMs <= LiveQuadTracker.holdMs {
            hint = quad
        }
        let started: Int = generation
        lock.unlock()

        let detection: PhotoDocumentDetection = detector(frame.image, hint)

        lock.lock()
        defer { lock.unlock() }
        // Reset while the frame was searched: its answer belongs to before.
        guard started == generation else { return nil }
        let observation = CaptureObservation(quad: detection.quad, confidence: detection.confidence, timestampMs: t,
                                             frameWidth: width, frameHeight: height)
        let decision: CaptureDecision = stability.update(observation)
        let diagonal: Double = (Double(width) * Double(width) + Double(height) * Double(height)).squareRoot()
        let steady: Bool = holdsStill(decision, quad: detection.quad, confidence: detection.confidence, diagonal: diagonal)
        lastFound = detection.quad
        var shown: Quad?
        if let quad = detection.quad {
            lastQuad = quad
            lastSeenMs = t
            shown = quad
        } else if let held = lastQuad, t - lastSeenMs <= LiveQuadTracker.holdMs {
            shown = held
        } else {
            lastQuad = nil
        }
        var outline: Quad?
        if let quad = shown {
            outline = LiveQuadTracker.normalized(quad, width: width, height: height)
        }
        return LiveQuadUpdate(outline: outline, state: decision.state, progress: decision.progress, timestampMs: t,
                              isSteady: steady)
    }

    /// Whether the page holds still after `decision` (called with the lock held): while `.steadying`, yes;
    /// while `.captured`, as long as no corner strays `stayMovement` of the `diagonal` from where it held
    /// still, and again once no corner moved `enterMovement` since the frame before (with the confidences
    /// `CaptureStability` asks for); a page missed for a moment holds still as it did. Otherwise, no.
    private func holdsStill(_ decision: CaptureDecision, quad: Quad?, confidence: Double, diagonal: Double) -> Bool {
        let o: CaptureStabilityOptions = stabilityOptions
        switch decision.state {
        case .steadying:
            heldAt = nil
            return true
        case .noPage, .moving:
            heldAt = nil
            return false
        case .captured:
            guard let found = quad else {
                return heldAt != nil
            }
            if decision.shouldCapture {
                heldAt = found
                return true
            }
            if let held = heldAt, confidence >= o.stayConfidence,
               CaptureStability.movement(found, held) <= o.stayMovement * diagonal {
                return true
            }
            if let earlier = lastFound, confidence >= o.enterConfidence,
               CaptureStability.movement(found, earlier) <= o.enterMovement * diagonal {
                heldAt = earlier
                return true
            }
            heldAt = nil
            return false
        }
    }

    /// Forgets the page (the photo was taken, the camera stopped): the next frame starts over.
    public func reset() {
        lock.lock()
        clearState()
        generation += 1
        lock.unlock()
    }

    /// Searches the frames `source` hands over and reports each search to `onUpdate`, on the source's
    /// queue; any source followed before is let go.
    public func follow(_ source: FrameSource, onUpdate: @escaping @Sendable (LiveQuadUpdate) -> Void) {
        stopFollowing()
        lock.lock()
        self.source = source
        lock.unlock()
        source.startFrames { [weak self] (frame: IOSCameraFrame) -> Void in
            guard let tracker = self else { return }
            if let update = tracker.process(frame) {
                onUpdate(update)
            }
        }
    }

    /// Stops following the source (its frames are no longer searched) and forgets the page.
    public func stopFollowing() {
        lock.lock()
        let followed: FrameSource? = source
        source = nil
        lock.unlock()
        followed?.stopFrames()
        reset()
    }

    /// `quad` (pixels of a `width` × `height` frame) as shares of the frame.
    public static func normalized(_ quad: Quad, width: Int, height: Int) -> Quad {
        let sx: Double = 1.0 / Double(max(width, 1))
        let sy: Double = 1.0 / Double(max(height, 1))
        return quad.scaled(sx, sy)
    }

    /// A live outline (shares of the sensor's frame, as the frames come) in the photo taken with the
    /// turn `rotationDegrees` (clockwise; 0, 90, 180 or 270, the capture's rotation angle), as shares of
    /// that photo once it is upright; nil for any other turn.
    public static func photoOutline(_ outline: Quad, rotationDegrees: Int) -> Quad? {
        let turn: Int = ((rotationDegrees % 360) + 360) % 360
        guard turn % 90 == 0 else { return nil }
        let quarters: Int = turn / 90
        var points: [CGPoint] = []
        for corner in outline.corners {
            let x: Double = Double(corner.x)
            let y: Double = Double(corner.y)
            var turned: CGPoint
            if quarters == 1 {
                turned = CGPoint(x: 1.0 - y, y: x)
            } else if quarters == 2 {
                turned = CGPoint(x: 1.0 - x, y: 1.0 - y)
            } else if quarters == 3 {
                turned = CGPoint(x: y, y: 1.0 - x)
            } else {
                turned = CGPoint(x: x, y: y)
            }
            points.append(turned)
        }
        return Quad.fromCorners(points)
    }

    /// Called with the lock held.
    private func clearState() {
        stability = CaptureStability(options: stabilityOptions)
        lastSearchedMs = nil
        lastQuad = nil
        lastSeenMs = -Double.infinity
        lastFound = nil
        heldAt = nil
    }
}

/// Makes a camera frame (BGRA, as the video output hands it over) small for the page search: the frame is
/// split into blocks of `step` × `step` pixels (`step` the smallest whole number that brings the long
/// side to at most `maxLongSide`), and each block gives one pixel, the mean of four of its pixels (at a
/// quarter and three quarters of the block each way), so the work is bounded by the small frame's size,
/// not the camera's.
public enum IOSFrameScaler {
    public static func downscaled(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                  maxLongSide: Int) -> RgbaImage? {
        guard width > 0, height > 0, maxLongSide > 0, bytesPerRow >= width * 4 else { return nil }
        guard bgra.count >= bytesPerRow * (height - 1) + width * 4 else { return nil }
        let longSide: Int = max(width, height)
        let step: Int = max((longSide + maxLongSide - 1) / maxLongSide, 1)
        let outWidth: Int = max(width / step, 1)
        let outHeight: Int = max(height / step, 1)
        let near: Int = step / 4
        let far: Int = (3 * step) / 4
        var pixels: [UInt8] = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        var oy: Int = 0
        while oy < outHeight {
            let y0: Int = min(oy * step + near, height - 1)
            let y1: Int = min(oy * step + far, height - 1)
            var ox: Int = 0
            while ox < outWidth {
                let x0: Int = min(ox * step + near, width - 1)
                let x1: Int = min(ox * step + far, width - 1)
                let a: Int = y0 * bytesPerRow + x0 * 4
                let b: Int = y0 * bytesPerRow + x1 * 4
                let c: Int = y1 * bytesPerRow + x0 * 4
                let d: Int = y1 * bytesPerRow + x1 * 4
                let o: Int = (oy * outWidth + ox) * 4
                var channel: Int = 0
                while channel < 3 {
                    // BGRA in, RGBA out: red is the frame's third byte, blue its first.
                    let from: Int = 2 - channel
                    let sum: Int = Int(bgra[a + from]) + Int(bgra[b + from]) + Int(bgra[c + from]) + Int(bgra[d + from])
                    pixels[o + channel] = UInt8((sum + 2) / 4)
                    channel += 1
                }
                ox += 1
            }
            oy += 1
        }
        return RgbaImage(width: outWidth, height: outHeight, pixels: pixels)
    }
}
#endif
