#if os(iOS)
import LazyScanKit
import CoreGraphics
import Foundation

/// One live frame of the camera, made small for the page search: its pixels (upright as the sensor
/// gives them, not turned for the screen), when it was taken, in milliseconds of the capture clock, and
/// the page the corner model found in it (`IOSFrameFeed.modelPage`, in `image`'s pixels), nil when the model
/// found none or did not run (fixture frames).
public struct IOSCameraFrame: Sendable {
    public let image: RgbaImage
    public let timestampMs: Double
    public let page: QuadCandidate?

    public init(image: RgbaImage, timestampMs: Double, page: QuadCandidate? = nil) {
        self.image = image
        self.timestampMs = timestampMs
        self.page = page
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
/// (`CaptureStability`); whether it holds still now; the frame's time; and the shutter's decision: take
/// the photo now (`shouldCapture`, once per page held still on a sharp, lit frame) and how the frame was
/// judged (`quality`).
public struct LiveQuadUpdate: Equatable, Sendable {
    public let outline: Quad?
    public let state: CaptureState
    public let progress: Double
    public let timestampMs: Double
    /// The page holds still now (the outline is drawn green): `.steadying`, or `.captured` while the page
    /// stays where it held still (`LiveQuadTracker`), not merely within `newPageMovement` of it. For the
    /// outline's colour only: the automatic shutter follows `shouldCapture`.
    public let isSteady: Bool
    /// Take the photo now (`CaptureDecision.shouldCapture`): the automatic shutter's trigger.
    public let shouldCapture: Bool
    /// How the frame was judged (`CaptureDecision.quality`): why a page held still is not taken yet.
    public let quality: CaptureQuality

    /// `isSteady` nil: the page holds still while `state` is `.steadying`.
    public init(outline: Quad?, state: CaptureState, progress: Double, timestampMs: Double, isSteady: Bool? = nil,
                shouldCapture: Bool = false, quality: CaptureQuality = .good) {
        self.outline = outline
        self.state = state
        self.progress = progress
        self.timestampMs = timestampMs
        if let given = isSteady {
            self.isSteady = given
        } else {
            self.isSteady = state == .steadying
        }
        self.shouldCapture = shouldCapture
        self.quality = quality
    }
}

/// Follows the page in the camera's live frames for the outline drawn over the preview. About ten
/// frames a second are searched (`frameIntervalMs`; the others are passed over before any work): the
/// page the corner model found in the frame (`IOSCameraFrame.page`) when it is a page's (`IOSPageFinder.accepted`)
/// and sure enough to start holding still (`CaptureStability.enterConfidence`, at least), else the shared
/// page search (`PhotoDocumentDetector`, the photo import's) on the frame made small (at most
/// `analysisLongSide` px), with the outline of the frame before as its hint. Once the model has found the
/// page the search waits until the model has missed it for `holdMs`, so the two outlines (a pixel or two
/// apart) do not take turns and shake the outline. What is found is steadied (`LiveQuadFilter`): small
/// jitter is smoothed, a jump is believed only once it is seen twice, a new page is drawn from its second
/// sighting and a page missed for a moment keeps its outline for `holdMs`, so it does not flicker; how
/// steady the steadied page is comes from `CaptureStability`.
/// Once `CaptureStability` has taken the page (`.captured`) it keeps that state until the page moves
/// `newPageMovement` away, so whether the page holds still meanwhile is judged here, by the same rules:
/// it does while no corner strays `stayMovement` from where it held still, and holds still again once no
/// corner moved `enterMovement` since the frame before (`LiveQuadUpdate.isSteady`). Each frame searched is
/// also measured (`FrameQuality`, over the page found: how sharp, how bright), so the shutter's decision
/// (`LiveQuadUpdate.shouldCapture`) comes only from a page held still on a sharp, lit frame. A photo taken
/// (`markCaptured()`) counts the page in view as taken, so the next is taken only once the page moved away
/// or went (continuous capture); a pause (`pauseFollowing()`: the camera stopped for the corner editor, the
/// background, heat) keeps that, and the time the camera was stopped counts neither as time the page was
/// missing nor as time it held still (`CaptureStability.resume(atMs:)` on the first frame searched after
/// it). Turning the automatic shutter on re-arms only a page taken without a photo (`rearm()`). Frames are
/// searched on the source's own queue, one at a time, never on the main thread; `reset()` may be called
/// from any thread and drops a frame being searched meanwhile.
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
    /// How sharp and bright a frame is, over the page found in it (its pixels), if any.
    public typealias QualityMeasure = @Sendable (RgbaImage, Quad?) -> FrameQualityReading

    private let detector: Detector
    private let measure: QualityMeasure
    private let stabilityOptions: CaptureStabilityOptions
    private let lock = NSLock()
    private var stability: CaptureStability
    private var lastSearchedMs: Double?
    private var lastQuad: Quad?
    private var lastSeenMs: Double = -Double.infinity
    private var filter = LiveQuadFilter()
    /// When the corner model last found the page (ms of the capture clock).
    private var modelSeenMs: Double = -Double.infinity
    /// The page found in the frame searched before (pixels); nil when none was.
    private var lastFound: Quad?
    /// Where the page held still while `.captured` (pixels); nil while it does not.
    private var heldAt: Quad?
    private var frameWidth: Int = 0
    private var frameHeight: Int = 0
    private var generation: Int = 0
    private var source: FrameSource?
    /// A source was let go (a pause): the next frame searched resumes `stability` first.
    private var resuming: Bool = false
    /// A photo was taken of the page `stability` counts as taken (`markCaptured()`), not only decided on;
    /// false again once it is no longer taken.
    private var photographed: Bool = false

    /// `detector` nil: the shared page search with `liveOptions`; `quality` nil: `FrameQuality.measure` (tests
    /// may pass their own).
    public init(detector: Detector? = nil, stability: CaptureStabilityOptions = .default, quality: QualityMeasure? = nil) {
        if let given = detector {
            self.detector = given
        } else {
            self.detector = { (image: RgbaImage, hint: Quad?) -> PhotoDocumentDetection in
                LiveQuadTracker.detect(image, hint: hint)
            }
        }
        if let given = quality {
            self.measure = given
        } else {
            self.measure = { (image: RgbaImage, page: Quad?) -> FrameQualityReading in
                FrameQuality.measure(image, region: page)
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

    /// The corner model's `page` in a live frame of `width` x `height` as the page search's answer, when it is sure
    /// enough and a page's (`IOSPageFinder.accepted`, as for a photo); nil otherwise.
    public static func detection(_ page: QuadCandidate, width: Int, height: Int) -> PhotoDocumentDetection? {
        guard let quad = IOSPageFinder.accepted(page, width: width, height: height) else { return nil }
        var result: PhotoDocumentDetection = PhotoDocumentDetection.nothing
        result.quad = quad
        result.confidence = page.confidence
        result.rejection = PhotoDocumentRejection.none
        return result
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
        if let quad = lastQuad, t >= lastSeenMs, t - lastSeenMs <= LiveQuadTracker.holdMs {
            hint = quad
        }
        let modelLately: Bool = t >= modelSeenMs && t - modelSeenMs <= LiveQuadTracker.holdMs
        let started: Int = generation
        lock.unlock()

        // A page the model is less sure of than holding still needs would never be taken: the search looks then.
        let modelFloor: Double = max(PhotoImport.minModelConfidence, stabilityOptions.enterConfidence)
        var seen: PhotoDocumentDetection?
        if let page = frame.page, page.confidence >= modelFloor {
            seen = LiveQuadTracker.detection(page, width: width, height: height)
        }
        let detection: PhotoDocumentDetection
        if let found = seen {
            detection = found
        } else if modelLately {
            detection = PhotoDocumentDetection.nothing
        } else {
            detection = detector(frame.image, hint)
        }
        let reading: FrameQualityReading = measure(frame.image, detection.quad)

        lock.lock()
        defer { lock.unlock() }
        // Reset while the frame was searched: its answer belongs to before.
        guard started == generation else { return nil }
        if resuming {
            // The first frame after a pause: the time the camera was stopped is not time without the page.
            resuming = false
            stability.resume(atMs: t)
        }
        let diagonal: Double = (Double(width) * Double(width) + Double(height) * Double(height)).squareRoot()
        let steadied: LiveQuadFilter.Output = filter.update(detection.quad, atMs: t, diagonal: diagonal)
        let observation = CaptureObservation(quad: steadied.page, confidence: detection.confidence, timestampMs: t,
                                             frameWidth: width, frameHeight: height,
                                             sharpness: reading.sharpness, brightness: reading.brightness)
        let decision: CaptureDecision = stability.update(observation)
        if decision.state != .captured {
            photographed = false
        }
        let steady: Bool = holdsStill(decision, quad: steadied.page, confidence: detection.confidence, diagonal: diagonal)
        lastFound = steadied.page
        if seen != nil {
            modelSeenMs = t
        }
        if let quad = detection.quad {
            lastQuad = quad
            lastSeenMs = t
        } else if t - lastSeenMs > LiveQuadTracker.holdMs {
            lastQuad = nil
        }
        var outline: Quad?
        if let quad = steadied.shown {
            outline = LiveQuadTracker.normalized(quad, width: width, height: height)
        }
        return LiveQuadUpdate(outline: outline, state: decision.state, progress: decision.progress, timestampMs: t,
                              isSteady: steady, shouldCapture: decision.shouldCapture, quality: decision.quality)
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

    /// Judges the page afresh (the camera screen closed, a page to be judged again): how steady it is and
    /// whether it was taken start over with the next frame. The outline drawn stays, so it does not blink;
    /// once frames stop coming for longer than `holdMs` it goes by itself.
    public func reset() {
        lock.lock()
        clearJudgement()
        generation += 1
        lock.unlock()
    }

    /// A photo was taken of the page in view (by hand, or as the shutter's decision said): it counts as
    /// taken (`CaptureStability.markCaptured`), so it is not taken again until it moves away or goes.
    public func markCaptured() {
        lock.lock()
        stability.markCaptured()
        if stability.state == .captured {
            heldAt = lastFound
            photographed = true
        }
        lock.unlock()
    }

    /// The automatic shutter was turned on, or a photo can be taken again: a page `CaptureStability` counted
    /// as taken while no photo was taken of it (the shutter was off when it decided, or no photo could be
    /// taken then) is judged afresh (as `reset()`), so it is taken once it holds still; a page photographed
    /// (`markCaptured()`) stays taken, and nothing else changes.
    public func rearm() {
        lock.lock()
        let untaken: Bool = stability.state == .captured && !photographed
        lock.unlock()
        if untaken {
            reset()
        }
    }

    /// Searches the frames `source` hands over and reports each search to `onUpdate`, on the source's
    /// queue; any source followed before is let go. What the tracker knows of the page is kept (see
    /// `pauseFollowing()`).
    public func follow(_ source: FrameSource, onUpdate: @escaping @Sendable (LiveQuadUpdate) -> Void) {
        detach()
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
        detach()
        reset()
    }

    /// Stops following the source but keeps what is known of the page, above all that it was taken: the
    /// camera stopped for a while (the corner editor, the background, heat) and the same page still in view
    /// afterwards is not taken again.
    public func pauseFollowing() {
        detach()
    }

    private func detach() {
        lock.lock()
        let followed: FrameSource? = source
        source = nil
        if followed != nil {
            resuming = true
        }
        lock.unlock()
        followed?.stopFrames()
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

    /// Forgets everything (frames of another size, a clock that started over). Called with the lock held.
    private func clearState() {
        clearJudgement()
        lastQuad = nil
        lastSeenMs = -Double.infinity
        filter = LiveQuadFilter()
        modelSeenMs = -Double.infinity
    }

    /// Forgets how steady the page was and whether it was taken. Called with the lock held.
    private func clearJudgement() {
        stability = CaptureStability(options: stabilityOptions)
        lastSearchedMs = nil
        lastFound = nil
        heldAt = nil
        resuming = false
        photographed = false
    }
}

/// Steadies the page found in successive live frames (pixels of one frame size) before it is drawn and
/// judged. A corner that moved at most `jitterShare` of the frame's diagonal since the outline before is
/// moved only `smoothing` of the way (the outline stops trembling); one that moved further is followed
/// at once, so a page slid across the table is not drawn behind it. A page that jumped more than
/// `jumpShare` (a corner of it) is not believed on one frame: it is passed over (no page that frame)
/// unless the next frame finds it away from the outline too, there or further on (a page moved fast), when
/// it is the page from then on; while it keeps jumping, each frame is followed. A page seen for the first
/// time is not drawn until it is found again on the next frame (one missing in between forgets it); a page
/// drawn and then missed keeps its outline for `LiveQuadTracker.holdMs` after it was last found. Corners
/// are paired with the outline before whichever corner the search named first, as `CaptureStability`
/// compares them. Pure logic, one frame after another in time order.
public struct LiveQuadFilter: Sendable {
    /// How far a trembling corner moves toward where it was found.
    public static let smoothing: Double = 0.5
    /// A corner moving at most this share of the diagonal trembles; further, it moves.
    public static let jitterShare: Double = 0.01
    /// A page whose corner jumped more than this share of the diagonal is believed on its second sighting.
    public static let jumpShare: Double = 0.06

    /// What one frame gives: the steadied page for the shutter's judgement (nil when none was found, or a
    /// jump was passed over), and the outline to draw (nil when there is none to draw).
    public struct Output: Equatable, Sendable {
        public let page: Quad?
        public let shown: Quad?
    }

    private var current: Quad?
    private var drawn: Bool = false
    private var jumped: Quad?
    private var seenMs: Double = -Double.infinity

    public init() {}

    /// The frame taken at `t` ms, where the page search found `found` (nil: no page), in a frame whose
    /// diagonal is `diagonal` px.
    public mutating func update(_ found: Quad?, atMs t: Double, diagonal: Double) -> Output {
        if current != nil && (t - seenMs > LiveQuadTracker.holdMs || t < seenMs) {
            current = nil
            drawn = false
            jumped = nil
        }
        guard let quad = found else {
            jumped = nil
            if !drawn {
                current = nil
            }
            return Output(page: nil, shown: drawn ? current : nil)
        }
        guard let before = current else {
            current = quad
            seenMs = t
            return Output(page: quad, shown: nil)
        }
        let aligned: Quad = LiveQuadFilter.aligned(quad, to: before)
        let limit: Double = LiveQuadFilter.jumpShare * diagonal
        if aligned.maxCornerDistance(before) > limit {
            if !drawn {
                current = quad
                seenMs = t
                return Output(page: quad, shown: nil)
            }
            if jumped != nil {
                current = quad
                jumped = quad
                seenMs = t
                return Output(page: quad, shown: quad)
            }
            jumped = quad
            return Output(page: nil, shown: before)
        }
        let steadied: Quad = LiveQuadFilter.blended(before, aligned, jitter: LiveQuadFilter.jitterShare * diagonal)
        current = steadied
        drawn = true
        jumped = nil
        seenMs = t
        return Output(page: steadied, shown: steadied)
    }

    /// `quad`'s corners renamed to pair with `reference`'s: shifted round by whichever of the four ways
    /// brings the farthest pair nearest.
    static func aligned(_ quad: Quad, to reference: Quad) -> Quad {
        var bestShift: Int = 0
        var best: Double = Double.greatestFiniteMagnitude
        var shift: Int = 0
        while shift < 4 {
            var worst: Double = 0
            var index: Int = 0
            while index < 4 {
                let a: CGPoint = quad[index + shift]
                let b: CGPoint = reference[index]
                let dx: Double = Double(a.x) - Double(b.x)
                let dy: Double = Double(a.y) - Double(b.y)
                worst = max(worst, (dx * dx + dy * dy).squareRoot())
                index += 1
            }
            if worst < best {
                best = worst
                bestShift = shift
            }
            shift += 1
        }
        return Quad(topLeft: quad[bestShift], topRight: quad[bestShift + 1], bottomRight: quad[bestShift + 2],
                    bottomLeft: quad[bestShift + 3])
    }

    /// Each corner of `before` moved `smoothing` of the way to `found`'s when within `jitter` px of it,
    /// else all the way.
    static func blended(_ before: Quad, _ found: Quad, jitter: Double) -> Quad {
        var corners: [CGPoint] = []
        var index: Int = 0
        while index < 4 {
            let a: CGPoint = before[index]
            let b: CGPoint = found[index]
            let dx: Double = Double(b.x) - Double(a.x)
            let dy: Double = Double(b.y) - Double(a.y)
            if (dx * dx + dy * dy).squareRoot() <= jitter {
                corners.append(CGPoint(x: Double(a.x) + LiveQuadFilter.smoothing * dx,
                                       y: Double(a.y) + LiveQuadFilter.smoothing * dy))
            } else {
                corners.append(b)
            }
            index += 1
        }
        return Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
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
