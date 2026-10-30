#if os(iOS)
import CoreGraphics
import Foundation
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit

// The live page outline of our own camera (`LiveQuadTracker`), fed fixture frames through a
// `FrameSource` as the camera's video output feeds it: a page sliding across a dark table, then held
// still, then taken away; frames with no page; a page missed for a moment; frames too close together;
// a clock that starts over; the shutter's decision only from a page held still on a sharp, lit frame
// (blurred and dark frames scripted through a `FrameSource`), a photo taken counting the page as taken,
// and a pause keeping that; the corner model's page taken in place of the search when it is sure. The frames are
// drawn here, pixel by pixel (no real document). Also the outline steadied (`LiveQuadFilter`, scripted
// outlines), the frames made small for the search (`IOSFrameScaler`) and a live outline turned into the
// photo's shares.

/// A colour of a fixture frame.
struct TrackerColor {
    let r: Int
    let g: Int
    let b: Int
}

/// Fixture frames of 320 × 240 like the camera's (small, as searched): a dark table with a little noise
/// and an A4-shaped sheet (112 × 158 px, turned 5°) with a header bar and lines of text, each pixel the
/// mean of 2 × 2 samples. The same frames were checked with the Windows twin of the page search: the
/// page is found in each within 0.1 px.
enum TrackerFrames {
    static let width: Int = 320
    static let height: Int = 240
    static let cosine: Double = 0.99619469809174555
    static let sine: Double = 0.087155742747658166
    static let halfWidth: Double = 56
    static let halfHeight: Double = 79
    static let table = TrackerColor(r: 38, g: 40, b: 46)

    /// -3 ... 3, fixed by the pixel and the seed.
    static func noise(_ x: Int, _ y: Int, _ seed: Int) -> Int {
        var h: UInt64 = UInt64(x) &* 374_761_393 &+ UInt64(y) &* 668_265_263 &+ UInt64(seed) &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Int(h & 0xFFFF) % 7 - 3
    }

    static func sample(_ px: Double, _ py: Double, _ centerX: Double, _ centerY: Double, _ page: Bool) -> TrackerColor {
        if !page { return table }
        let dx: Double = px - centerX
        let dy: Double = py - centerY
        let u: Double = dx * cosine + dy * sine
        let v: Double = -dx * sine + dy * cosine
        if !(abs(u) < halfWidth && abs(v) < halfHeight) { return table }
        let top: Double = v + halfHeight
        let left: Double = u + halfWidth
        let inside: Bool = left >= 12 && left < 2 * halfWidth - 12
        if top >= 6 && top < 14 && inside {
            return TrackerColor(r: 60, g: 70, b: 110)
        }
        if top >= 18 && top < 140 && inside {
            let row: Int = Int(floor(top)) - 18
            if row % 12 < 4 {
                return TrackerColor(r: 70, g: 70, b: 78)
            }
        }
        return TrackerColor(r: 238, g: 236, b: 230)
    }

    static func clamped(_ value: Int) -> UInt8 {
        UInt8(min(max(value, 0), 255))
    }

    /// A frame with the page centred at (`centerX`, `centerY`), or the table alone.
    static func frame(seed: Int, centerX: Double, centerY: Double, page: Bool) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 255, count: width * height * 4)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                var sr: Int = 0
                var sg: Int = 0
                var sb: Int = 0
                var k: Int = 0
                while k < 4 {
                    let px: Double = Double(x) + 0.25 + 0.5 * Double(k & 1)
                    let py: Double = Double(y) + 0.25 + 0.5 * Double(k >> 1)
                    let color: TrackerColor = sample(px, py, centerX, centerY, page)
                    sr += color.r
                    sg += color.g
                    sb += color.b
                    k += 1
                }
                let n: Int = noise(x, y, seed)
                let o: Int = (y * width + x) * 4
                pixels[o] = clamped((sr + 2) / 4 + 2 * n)
                pixels[o + 1] = clamped((sg + 2) / 4 + 2 * n)
                pixels[o + 2] = clamped((sb + 2) / 4 + 2 * n)
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// The page's true corners (pixels) when centred at (`centerX`, `centerY`).
    static func truth(centerX: Double, centerY: Double) -> Quad {
        var corners: [CGPoint] = []
        let us: [Double] = [-halfWidth, halfWidth, halfWidth, -halfWidth]
        let vs: [Double] = [-halfHeight, -halfHeight, halfHeight, halfHeight]
        var index: Int = 0
        while index < 4 {
            let u: Double = us[index]
            let v: Double = vs[index]
            corners.append(CGPoint(x: centerX + u * cosine - v * sine, y: centerY + u * sine + v * cosine))
            index += 1
        }
        return Quad.fromCorners(corners)
    }

    /// Frame `index` of the sequence at 30 frames a second: the page slides 2 px a frame for one second
    /// (frames 0–29), holds still for one second (30–59), and is gone for one second (60–89).
    static func centerX(_ index: Int) -> Double {
        index < 30 ? 110.0 + 2.0 * Double(index) : 170.0
    }

    static let centerY: Double = 120
    static let frameCount: Int = 90

    static func timestamp(_ index: Int) -> Double {
        Double(index) * 100.0 / 3.0
    }

    static func sequence() -> [IOSCameraFrame] {
        var frames: [IOSCameraFrame] = []
        let still: RgbaImage = frame(seed: 7, centerX: 170, centerY: centerY, page: true)
        let empty: RgbaImage = frame(seed: 7, centerX: 0, centerY: 0, page: false)
        var index: Int = 0
        while index < frameCount {
            let image: RgbaImage
            if index >= 60 {
                image = empty
            } else if index >= 30 {
                image = still
            } else {
                image = frame(seed: 7, centerX: centerX(index), centerY: centerY, page: true)
            }
            frames.append(IOSCameraFrame(image: image, timestampMs: timestamp(index)))
            index += 1
        }
        return frames
    }
}

/// Fixture frames handed over one after another, at once, as a camera would over time.
final class FixtureFrameSource: FrameSource, @unchecked Sendable {
    private let frames: [IOSCameraFrame]
    private(set) var started: Int = 0
    private(set) var stopped: Bool = false

    init(_ frames: [IOSCameraFrame]) {
        self.frames = frames
    }

    func startFrames(_ deliver: @escaping @Sendable (IOSCameraFrame) -> Void) {
        started += 1
        stopped = false
        for frame in frames {
            if stopped { break }
            deliver(frame)
        }
    }

    func stopFrames() {
        stopped = true
    }
}

/// The updates a tracker reported, kept across threads.
final class TrackerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [LiveQuadUpdate] = []

    func add(_ update: LiveQuadUpdate) {
        lock.lock()
        kept.append(update)
        lock.unlock()
    }

    var updates: [LiveQuadUpdate] {
        lock.lock()
        let copy: [LiveQuadUpdate] = kept
        lock.unlock()
        return copy
    }
}

/// How often a stand-in page search was asked.
final class SearchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        let copy: Int = count
        lock.unlock()
        return copy
    }
}

/// Frames judged sharp and lit whatever they show (for page searches stood in for).
private let goodReadings: LiveQuadTracker.QualityMeasure = { (_: RgbaImage, _: Quad?) -> FrameQualityReading in
    FrameQualityReading(sharpness: 1000, brightness: 200)
}

/// Live frames of 320 × 240 like the shared `QualityFrames` (LazyScanTests): a wooden table and a
/// blank sheet from (80, 40) to (240, 200), blurred by a box of (2·blur + 1)² pixels and darkened to
/// dim/255, if asked. Measured over the sheet found (±1 px): a sharpness of about 690 sharp, 17 blurred by 2
/// (blurry); a brightness of about 195, 30 dimmed to 40 (dark).
enum LiveFrames {
    static let width: Int = 320
    static let height: Int = 240
    static let sheet = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 240, y: 40),
                            bottomRight: CGPoint(x: 240, y: 200), bottomLeft: CGPoint(x: 80, y: 200))

    static func frame(blur: Int = 0, dim: Int = 255) -> RgbaImage {
        var r: [Int] = [Int](repeating: 88, count: width * height)
        var g: [Int] = [Int](repeating: 80, count: width * height)
        var b: [Int] = [Int](repeating: 72, count: width * height)
        var y: Int = 40
        while y < 200 {
            var x: Int = 80
            while x < 240 {
                let i: Int = y * width + x
                r[i] = 205
                g[i] = 200
                b[i] = 192
                x += 1
            }
            y += 1
        }
        var pixels: [UInt8] = [UInt8](repeating: 255, count: width * height * 4)
        y = 0
        while y < height {
            var x: Int = 0
            while x < width {
                var sr: Int = 0
                var sg: Int = 0
                var sb: Int = 0
                var n: Int = 0
                var yy: Int = max(0, y - blur)
                while yy < min(height, y + blur + 1) {
                    var xx: Int = max(0, x - blur)
                    while xx < min(width, x + blur + 1) {
                        let i: Int = yy * width + xx
                        sr += r[i]
                        sg += g[i]
                        sb += b[i]
                        n += 1
                        xx += 1
                    }
                    yy += 1
                }
                let o: Int = (y * width + x) * 4
                pixels[o] = UInt8(((sr + n / 2) / n * dim + 127) / 255)
                pixels[o + 1] = UInt8(((sg + n / 2) / n * dim + 127) / 255)
                pixels[o + 2] = UInt8(((sb + n / 2) / n * dim + 127) / 255)
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// The sheet moved `dx` px to the right.
    static func sheetMoved(_ dx: Double) -> Quad {
        Quad(topLeft: CGPoint(x: 80 + dx, y: 40), topRight: CGPoint(x: 240 + dx, y: 40),
             bottomRight: CGPoint(x: 240 + dx, y: 200), bottomLeft: CGPoint(x: 80 + dx, y: 200))
    }
}

/// A page search that finds the sheet `offsets[i]` px to the right in frame i, surely (the frame's index is
/// kept in its first pixel's alpha, `tagged`).
private func sheetDetector(_ offsets: [Double]) -> LiveQuadTracker.Detector {
    { (image: RgbaImage, _: Quad?) -> PhotoDocumentDetection in
        let index: Int = Int(image.pixels[3])
        var dx: Double = 0
        if index < offsets.count {
            dx = offsets[index]
        }
        return detection(LiveFrames.sheetMoved(dx))
    }
}

/// `image` with frame index `index` kept in its first pixel's alpha (0...255), for stand-in searches.
private func tagged(_ image: RgbaImage, _ index: Int) -> RgbaImage {
    var pixels: [UInt8] = image.pixels
    pixels[3] = UInt8(index)
    return RgbaImage(width: image.width, height: image.height, pixels: pixels)
}

/// A frame of `width` × `height` of one grey.
private func plainFrame(_ t: Double, width: Int = 64, height: Int = 48) -> IOSCameraFrame {
    IOSCameraFrame(image: RgbaImage.filled(width: width, height: height, r: 90, g: 90, b: 90), timestampMs: t)
}

/// A page outline in a 64 × 48 frame.
private let stubQuad = Quad(topLeft: CGPoint(x: 10, y: 8), topRight: CGPoint(x: 50, y: 8),
                            bottomRight: CGPoint(x: 50, y: 40), bottomLeft: CGPoint(x: 10, y: 40))

/// A page search that finds nothing and counts how often it was asked.
private func countingDetector(_ count: SearchCount) -> LiveQuadTracker.Detector {
    { (_: RgbaImage, _: Quad?) -> PhotoDocumentDetection in
        count.add()
        return PhotoDocumentDetection.nothing
    }
}

/// What the page search answers: `quad` found surely, or nothing.
private func detection(_ quad: Quad?) -> PhotoDocumentDetection {
    var result: PhotoDocumentDetection = PhotoDocumentDetection.nothing
    if let found = quad {
        result.quad = found
        result.confidence = 1
        result.rejection = PhotoDocumentRejection.none
    }
    return result
}

private func assertQuad(_ a: Quad?, _ b: Quad, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    guard let quad = a else {
        XCTFail("No outline", file: file, line: line)
        return
    }
    var index: Int = 0
    while index < 4 {
        XCTAssertEqual(Double(quad[index].x), Double(b[index].x), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(quad[index].y), Double(b[index].y), accuracy: accuracy, file: file, line: line)
        index += 1
    }
}

final class LiveQuadTrackerTests: XCTestCase {
    func test_aPageSlidingThenHeldThenTakenAway_isFollowedAtTenFramesASecond() throws {
        let tracker = LiveQuadTracker()
        let source = FixtureFrameSource(TrackerFrames.sequence())
        let log = TrackerLog()
        tracker.follow(source) { (update: LiveQuadUpdate) -> Void in
            log.add(update)
        }
        let updates: [LiveQuadUpdate] = log.updates
        // 90 frames over 3 s at 30 a second: every third is searched.
        XCTAssertEqual(source.started, 1)
        XCTAssertEqual(updates.count, 30)
        var capturedAt: Double?
        let diagonal: Double = (320.0 * 320.0 + 240.0 * 240.0).squareRoot()
        for update in updates {
            let t: Double = update.timestampMs
            let index: Int = Int((t * 3.0 / 100.0).rounded())
            if index == 0 {
                // Seen for the first time: drawn from the second sighting on.
                XCTAssertNil(update.outline)
            } else if index < 60 {
                // The page is in view: its outline within 1 % of the frame's diagonal (shares of the frame).
                guard let outline = update.outline else {
                    XCTFail("No outline at \(t) ms")
                    continue
                }
                let pixels: Quad = outline.scaled(320, 240)
                let truth: Quad = TrackerFrames.truth(centerX: TrackerFrames.centerX(index), centerY: TrackerFrames.centerY)
                XCTAssertLessThanOrEqual(CaptureStability.movement(pixels, truth), 0.01 * diagonal, "at \(t) ms")
                for corner in outline.corners {
                    XCTAssertTrue(corner.x >= 0 && corner.x <= 1 && corner.y >= 0 && corner.y <= 1, "at \(t) ms")
                }
            }
            if index < 30 {
                // Sliding 6 px between searches: never steady.
                XCTAssertNotEqual(update.state, CaptureState.captured, "at \(t) ms")
                XCTAssertNotEqual(update.state, CaptureState.steadying, "at \(t) ms")
                XCTAssertFalse(update.isSteady)
            }
            if update.state == .captured && capturedAt == nil {
                capturedAt = t
            }
            if t >= 2300 {
                // Gone for more than the hold: no outline, no page.
                XCTAssertNil(update.outline, "at \(t) ms")
            }
        }
        // Held still from 1 s: steady for 0.6 s by 1.7 s.
        let held: Double = try XCTUnwrap(capturedAt)
        XCTAssertGreaterThanOrEqual(held, 1600)
        XCTAssertLessThan(held, 2000)
        let last: LiveQuadUpdate = updates[updates.count - 1]
        XCTAssertEqual(last.state, CaptureState.noPage)
        XCTAssertNil(last.outline)
        // Missed just after it went: the outline stays for the hold.
        var justGone: [LiveQuadUpdate] = []
        for update in updates where update.timestampMs > 1950 && update.timestampMs < 2250 {
            justGone.append(update)
        }
        XCTAssertEqual(justGone.count, 3)
        for update in justGone {
            XCTAssertNotNil(update.outline, "at \(update.timestampMs) ms")
        }
    }

    func test_framesWithNoPage_showNoOutline() {
        let tracker = LiveQuadTracker()
        let empty: RgbaImage = TrackerFrames.frame(seed: 3, centerX: 0, centerY: 0, page: false)
        var frames: [IOSCameraFrame] = []
        var index: Int = 0
        while index < 20 {
            frames.append(IOSCameraFrame(image: empty, timestampMs: Double(index) * 100.0))
            index += 1
        }
        let log = TrackerLog()
        tracker.follow(FixtureFrameSource(frames)) { (update: LiveQuadUpdate) -> Void in
            log.add(update)
        }
        let updates: [LiveQuadUpdate] = log.updates
        XCTAssertEqual(updates.count, 20)
        for update in updates {
            XCTAssertNil(update.outline)
            XCTAssertEqual(update.state, CaptureState.noPage)
            XCTAssertEqual(update.progress, 0)
        }
    }

    func test_aFrameTooSoon_isPassedOverBeforeAnyWork_andAClockThatStartsOverStartsAgain() {
        let count = SearchCount()
        let tracker = LiveQuadTracker(detector: countingDetector(count))
        XCTAssertNotNil(tracker.process(plainFrame(1000)))
        XCTAssertNil(tracker.process(plainFrame(1033)))
        XCTAssertNil(tracker.process(plainFrame(1066)))
        XCTAssertNil(tracker.process(plainFrame(1089.9)))
        XCTAssertNotNil(tracker.process(plainFrame(1090)))
        XCTAssertEqual(count.value, 2)
        // The camera started again: its clock begins anew, and so does the tracker.
        XCTAssertNotNil(tracker.process(plainFrame(20)))
        XCTAssertNil(tracker.process(plainFrame(40)))
        XCTAssertEqual(count.value, 3)
        // A frame of another size starts over too.
        XCTAssertNotNil(tracker.process(plainFrame(200, width: 48, height: 64)))
        XCTAssertEqual(count.value, 4)
        XCTAssertEqual(LiveQuadTracker.frameIntervalMs, 100)
        XCTAssertEqual(LiveQuadTracker.analysisLongSide, 480)
        XCTAssertEqual(LiveQuadTracker.liveOptions.analysisLongSide, 480)
    }

    func test_aPageMissedForAMoment_keepsItsOutline_andTheSearchGetsItAsAHint() {
        let hints = TrackerLog()
        let found: Set<Int> = [0, 100]
        let tracker = LiveQuadTracker(detector: { (image: RgbaImage, hint: Quad?) -> PhotoDocumentDetection in
            // The frame's time is in its grey (see below).
            let t: Int = Int(image.pixels[0]) * 100
            let note = LiveQuadUpdate(outline: hint, state: .noPage, progress: 0, timestampMs: Double(t))
            hints.add(note)
            return detection(found.contains(t) ? stubQuad : nil)
        })
        var shown: [Quad?] = []
        var t: Int = 0
        while t <= 600 {
            let grey: UInt8 = UInt8(t / 100)
            let frame = IOSCameraFrame(image: RgbaImage.filled(width: 64, height: 48, r: grey, g: grey, b: grey),
                                       timestampMs: Double(t))
            let update: LiveQuadUpdate? = tracker.process(frame)
            XCTAssertNotNil(update)
            shown.append(update?.outline)
            t += 100
        }
        let expected: Quad = LiveQuadTracker.normalized(stubQuad, width: 64, height: 48)
        // Found at 0 and 100 ms (drawn from the second sighting); missed from 200 ms: kept until 300 ms
        // after 100 ms, gone after.
        XCTAssertNil(shown[0])
        XCTAssertEqual(shown[1], expected)
        XCTAssertEqual(shown[2], expected)
        XCTAssertEqual(shown[3], expected)
        XCTAssertEqual(shown[4], expected)
        XCTAssertNil(shown[5])
        XCTAssertNil(shown[6])
        // The search is given the outline of the frame before (pixels) while it is kept.
        let asked: [LiveQuadUpdate] = hints.updates
        XCTAssertEqual(asked.count, 7)
        XCTAssertNil(asked[0].outline)
        XCTAssertEqual(asked[1].outline, stubQuad)
        XCTAssertEqual(asked[2].outline, stubQuad)
        XCTAssertEqual(asked[4].outline, stubQuad)
        XCTAssertNil(asked[5].outline)
    }

    func test_aPageMovedAfterItHeldStill_isNotSteady_untilItHoldsStillAgain() {
        // 320 × 240 (diagonal 400 px): it stays still within 10 px (stayMovement), starts holding still
        // within 4 px a frame (enterMovement), and counts as a new page 60 px away (newPageMovement).
        // The frame's index is in its grey; the page is a 120 px square moved `offsets[index]` px right.
        var offsets: [Double] = []
        var index: Int = 0
        while index < 21 {
            if index < 10 {
                offsets.append(0)
            } else if index < 18 {
                offsets.append(6.0 * Double(index - 9))     // sliding 6 px a search: 6 ... 48 px
            } else {
                offsets.append(48)                          // held still again where it stopped
            }
            index += 1
        }
        let moves: [Double] = offsets
        let tracker = LiveQuadTracker(detector: { (image: RgbaImage, _: Quad?) -> PhotoDocumentDetection in
            let at: Int = Int(image.pixels[0])
            let dx: Double = moves[at]
            let quad = Quad(topLeft: CGPoint(x: 100 + dx, y: 60), topRight: CGPoint(x: 220 + dx, y: 60),
                            bottomRight: CGPoint(x: 220 + dx, y: 180), bottomLeft: CGPoint(x: 100 + dx, y: 180))
            return detection(quad)
        }, quality: goodReadings)
        var updates: [LiveQuadUpdate] = []
        index = 0
        while index < moves.count {
            let grey: UInt8 = UInt8(index)
            let frame = IOSCameraFrame(image: RgbaImage.filled(width: 320, height: 240, r: grey, g: grey, b: grey),
                                       timestampMs: Double(index) * 100.0)
            guard let update = tracker.process(frame) else {
                XCTFail("Passed over at \(index)")
                return
            }
            updates.append(update)
            index += 1
        }
        // Found, then holding still from the second frame, taken after 0.6 s.
        XCTAssertFalse(updates[0].isSteady)
        XCTAssertEqual(updates[1].state, CaptureState.steadying)
        XCTAssertTrue(updates[1].isSteady)
        XCTAssertEqual(updates[7].state, CaptureState.captured)
        XCTAssertTrue(updates[7].isSteady)
        XCTAssertTrue(updates[9].isSteady)
        // The first 6 px are within the stillness allowed; from 12 px on it moves, though still the page
        // taken (under 60 px from it): not drawn green.
        XCTAssertTrue(updates[10].isSteady)
        index = 11
        while index < 18 {
            XCTAssertEqual(updates[index].state, CaptureState.captured, "at \(index)")
            XCTAssertFalse(updates[index].isSteady, "at \(index)")
            index += 1
        }
        // Held still again: green again.
        index = 18
        while index < 21 {
            XCTAssertEqual(updates[index].state, CaptureState.captured, "at \(index)")
            XCTAssertTrue(updates[index].isSteady, "at \(index)")
            index += 1
        }
        // An update made without the tracker holds still while steadying.
        XCTAssertTrue(LiveQuadUpdate(outline: nil, state: .steadying, progress: 0.5, timestampMs: 0).isSteady)
        XCTAssertFalse(LiveQuadUpdate(outline: nil, state: .captured, progress: 1, timestampMs: 0).isSteady)
    }

    func test_reset_forgetsThePage() {
        let tracker = LiveQuadTracker(detector: { (_: RgbaImage, _: Quad?) -> PhotoDocumentDetection in
            detection(stubQuad)
        })
        XCTAssertNil(tracker.process(plainFrame(0))?.outline)
        XCTAssertNotNil(tracker.process(plainFrame(100))?.outline)
        tracker.reset()
        // Not passed over as too soon: the reset started over. The outline drawn stays (no blink).
        let after: LiveQuadUpdate? = tracker.process(plainFrame(110))
        XCTAssertNotNil(after)
        XCTAssertEqual(after?.state, CaptureState.moving)
        XCTAssertEqual(after?.outline, LiveQuadTracker.normalized(stubQuad, width: 64, height: 48))
    }

    func test_theShutter_firesOnlyForAPageHeldStillOnASharpLitFrame_throughAFrameSource() {
        // The sheet held still (±1 px) at 10 frames a second: blurred while the camera focuses (frames
        // 0–14), then too dark (15–24), then sharp and lit (25–40). Each frame is measured for real
        // (`FrameQuality`, over the page found); the page search is stood in for, so it finds the sheet in
        // every frame.
        let blurred: RgbaImage = LiveFrames.frame(blur: 2)
        let dark: RgbaImage = LiveFrames.frame(dim: 40)
        let sharp: RgbaImage = LiveFrames.frame()
        var offsets: [Double] = []
        var frames: [IOSCameraFrame] = []
        var index: Int = 0
        while index < 41 {
            offsets.append(index % 2 == 0 ? 1 : -1)
            var image: RgbaImage = sharp
            if index < 15 {
                image = blurred
            } else if index < 25 {
                image = dark
            }
            frames.append(IOSCameraFrame(image: tagged(image, index), timestampMs: Double(index) * 100.0))
            index += 1
        }
        let tracker = LiveQuadTracker(detector: sheetDetector(offsets))
        let log = TrackerLog()
        tracker.follow(FixtureFrameSource(frames)) { (update: LiveQuadUpdate) -> Void in
            log.add(update)
        }
        let updates: [LiveQuadUpdate] = log.updates
        XCTAssertEqual(updates.count, 41)
        var fired: [Int] = []
        index = 0
        while index < updates.count {
            if updates[index].shouldCapture { fired.append(index) }
            index += 1
        }
        // Held still from frame 1, long enough by frame 7: it waits through the blurred and dark frames,
        // and the first sharp, lit frame is taken, once.
        XCTAssertEqual(fired, [25])
        XCTAssertEqual(updates[7].state, CaptureState.steadying)
        XCTAssertEqual(updates[7].quality, CaptureQuality.blurry)
        XCTAssertEqual(updates[14].progress, 1)
        XCTAssertEqual(updates[15].quality, CaptureQuality.dark)
        XCTAssertEqual(updates[25].quality, CaptureQuality.good)
        XCTAssertEqual(updates[40].state, CaptureState.captured)
        // The display-only steadiness says nothing of the shutter: green while waiting, never a shot.
        XCTAssertTrue(updates[10].isSteady)
        XCTAssertFalse(updates[10].shouldCapture)
    }

    func test_aMovingPage_isNeverTaken_howeverSharp() {
        var offsets: [Double] = []
        var frames: [IOSCameraFrame] = []
        let sharp: RgbaImage = LiveFrames.frame()
        var index: Int = 0
        while index < 40 {
            offsets.append(Double((index % 5) * 8))     // 8 px a frame: never within the 4 px to hold still
            frames.append(IOSCameraFrame(image: tagged(sharp, index), timestampMs: Double(index) * 100.0))
            index += 1
        }
        let tracker = LiveQuadTracker(detector: sheetDetector(offsets))
        let log = TrackerLog()
        tracker.follow(FixtureFrameSource(frames)) { (update: LiveQuadUpdate) -> Void in
            log.add(update)
        }
        for update in log.updates {
            XCTAssertFalse(update.shouldCapture)
            XCTAssertNotEqual(update.state, CaptureState.steadying)
        }
    }

    func test_aPhotoTaken_countsThePageAsTaken_untilANewPageComes() {
        var offsets: [Double] = []
        var index: Int = 0
        while index < 60 {
            var dx: Double = index % 2 == 0 ? 1 : -1
            if index >= 40 { dx += 100 }               // the next page laid 100 px aside
            offsets.append(dx)
            index += 1
        }
        let tracker = LiveQuadTracker(detector: sheetDetector(offsets), quality: goodReadings)
        let sharp: RgbaImage = LiveFrames.frame()
        var fired: [Int] = []
        index = 0
        while index < 60 {
            let frame = IOSCameraFrame(image: tagged(sharp, index), timestampMs: Double(index) * 100.0)
            if let update = tracker.process(frame), update.shouldCapture {
                fired.append(index)
            }
            // Taken by hand while the page holds still, before the shutter would have fired.
            if index == 3 {
                tracker.markCaptured()
            }
            index += 1
        }
        // Never taken again until the next page came: its jump believed on its second sighting (41),
        // steady from 42, taken at 48.
        XCTAssertEqual(fired, [48])
    }

    func test_aPause_keepsThePageTaken_whileStoppingForgetsIt() {
        var offsets: [Double] = []
        var index: Int = 0
        while index < 20 {
            offsets.append(index % 2 == 0 ? 1 : -1)
            index += 1
        }
        let sharp: RgbaImage = LiveFrames.frame()
        func frames(from start: Double) -> [IOSCameraFrame] {
            var list: [IOSCameraFrame] = []
            var i: Int = 0
            while i < 20 {
                list.append(IOSCameraFrame(image: tagged(sharp, i), timestampMs: start + Double(i) * 100.0))
                i += 1
            }
            return list
        }
        let tracker = LiveQuadTracker(detector: sheetDetector(offsets), quality: goodReadings)
        let log = TrackerLog()
        tracker.follow(FixtureFrameSource(frames(from: 0))) { (update: LiveQuadUpdate) -> Void in
            log.add(update)
        }
        XCTAssertEqual(log.updates.filter { (update: LiveQuadUpdate) -> Bool in update.shouldCapture }.count, 1)
        // Paused (the corner editor was open) with the same page still in view: not taken again.
        tracker.pauseFollowing()
        let after = TrackerLog()
        tracker.follow(FixtureFrameSource(frames(from: 5000))) { (update: LiveQuadUpdate) -> Void in
            after.add(update)
        }
        XCTAssertEqual(after.updates.filter { (update: LiveQuadUpdate) -> Bool in update.shouldCapture }.count, 0)
        XCTAssertEqual(after.updates.last?.state, CaptureState.captured)
        // Stopped (the screen closed): forgotten, so the page is taken again.
        tracker.stopFollowing()
        let again = TrackerLog()
        tracker.follow(FixtureFrameSource(frames(from: 10000))) { (update: LiveQuadUpdate) -> Void in
            again.add(update)
        }
        XCTAssertEqual(again.updates.filter { (update: LiveQuadUpdate) -> Bool in update.shouldCapture }.count, 1)
    }

    func test_aFirstFrameWithoutThePageAfterAPause_doesNotHaveItTakenAgain() {
        // Frame 20, the first after the pause (the exposure still settling), finds no page; every other frame
        // finds the sheet (±1 px).
        let detector: LiveQuadTracker.Detector = { (image: RgbaImage, _: Quad?) -> PhotoDocumentDetection in
            let index: Int = Int(image.pixels[3])
            if index == 20 {
                return detection(nil)
            }
            return detection(LiveFrames.sheetMoved(index % 2 == 0 ? 1 : -1))
        }
        let sharp: RgbaImage = LiveFrames.frame()
        func frames(_ first: Int, _ end: Int, from start: Double) -> [IOSCameraFrame] {
            var list: [IOSCameraFrame] = []
            var i: Int = first
            while i < end {
                list.append(IOSCameraFrame(image: tagged(sharp, i), timestampMs: start + Double(i - first) * 100.0))
                i += 1
            }
            return list
        }
        let tracker = LiveQuadTracker(detector: detector, quality: goodReadings)
        let log = TrackerLog()
        tracker.follow(FixtureFrameSource(frames(0, 20, from: 0))) { (update: LiveQuadUpdate) -> Void in
            log.add(update)
        }
        XCTAssertEqual(log.updates.filter { (update: LiveQuadUpdate) -> Bool in update.shouldCapture }.count, 1)
        // Paused for the corner editor, about 3 s; the 3 s are not time without the page.
        tracker.pauseFollowing()
        let after = TrackerLog()
        tracker.follow(FixtureFrameSource(frames(20, 40, from: 5000))) { (update: LiveQuadUpdate) -> Void in
            after.add(update)
        }
        let updates: [LiveQuadUpdate] = after.updates
        XCTAssertEqual(updates.count, 20)
        XCTAssertEqual(updates.first?.state, CaptureState.captured)
        XCTAssertEqual(updates.filter { (update: LiveQuadUpdate) -> Bool in update.shouldCapture }.count, 0)
        XCTAssertEqual(updates.last?.state, CaptureState.captured)
    }

    func test_rearm_judgesAgainOnlyAPageTakenWithoutAPhoto() {
        var offsets: [Double] = []
        var index: Int = 0
        while index < 40 {
            offsets.append(index % 2 == 0 ? 1 : -1)
            index += 1
        }
        let tracker = LiveQuadTracker(detector: sheetDetector(offsets), quality: goodReadings)
        let sharp: RgbaImage = LiveFrames.frame()
        var fired: [Int] = []
        index = 0
        while index < 40 {
            let frame = IOSCameraFrame(image: tagged(sharp, index), timestampMs: Double(index) * 100.0)
            if let update = tracker.process(frame), update.shouldCapture {
                fired.append(index)
            }
            if index == 9 {
                // Decided on at 7 with the automatic shutter off, so no photo: turned on, judged afresh.
                tracker.rearm()
            }
            if index == 17 {
                // Decided on again at 17 and photographed this time.
                tracker.markCaptured()
            }
            if index == 20 {
                // Turned on again: the page photographed stays taken.
                tracker.rearm()
            }
            index += 1
        }
        XCTAssertEqual(fired, [7, 17])
    }

    func test_theModelsPage_isTakenWhenSure_andTheSearchWaitsWhileTheModelAnswers() {
        let count = SearchCount()
        let tracker = LiveQuadTracker(detector: countingDetector(count), quality: goodReadings)
        let sure = QuadCandidate(quad: stubQuad, confidence: 0.9)
        let expected: Quad = LiveQuadTracker.normalized(stubQuad, width: 64, height: 48)
        func frame(_ t: Double, _ page: QuadCandidate?) -> IOSCameraFrame {
            IOSCameraFrame(image: RgbaImage.filled(width: 64, height: 48, r: 90, g: 90, b: 90), timestampMs: t, page: page)
        }
        XCTAssertNil(tracker.process(frame(0, sure))?.outline)
        let second: LiveQuadUpdate? = tracker.process(frame(100, sure))
        XCTAssertEqual(second?.outline, expected)
        XCTAssertEqual(count.value, 0)
        // The model misses it (too unsure, a sliver, nothing) for up to 300 ms after it last found it: the
        // search waits and the outline is held.
        let unsure: LiveQuadUpdate? = tracker.process(frame(200, QuadCandidate(quad: stubQuad, confidence: 0.3)))
        XCTAssertEqual(unsure?.outline, expected)
        let sliver = Quad(topLeft: CGPoint(x: 10, y: 20), topRight: CGPoint(x: 54, y: 20),
                          bottomRight: CGPoint(x: 54, y: 24), bottomLeft: CGPoint(x: 10, y: 24))
        _ = tracker.process(frame(300, QuadCandidate(quad: sliver, confidence: 0.9)))
        _ = tracker.process(frame(400, nil))
        XCTAssertEqual(count.value, 0)
        // Missed for longer: the search looks (and finds nothing here).
        _ = tracker.process(frame(500, nil))
        XCTAssertEqual(count.value, 1)
        // Less sure than holding still needs (0.6): never taken, so the search looks.
        _ = tracker.process(frame(600, QuadCandidate(quad: stubQuad, confidence: 0.55)))
        XCTAssertEqual(count.value, 2)
        let found: PhotoDocumentDetection? = LiveQuadTracker.detection(sure, width: 64, height: 48)
        XCTAssertEqual(found?.quad, stubQuad)
        XCTAssertEqual(found?.confidence, 0.9)
        XCTAssertEqual(found?.rejection, PhotoDocumentRejection.none)
    }

    func test_theModelFlickering_doesNotHandTheOutlineToTheSearch() {
        // The model finds the sheet on two frames, then on every other one; the search would find it 5 px to the
        // right (over the jitter), so taking turns would shake the outline.
        let count = SearchCount()
        let tracker = LiveQuadTracker(detector: { (_: RgbaImage, _: Quad?) -> PhotoDocumentDetection in
            count.add()
            return detection(LiveFrames.sheetMoved(5))
        }, quality: goodReadings)
        let image: RgbaImage = LiveFrames.frame()
        let page = QuadCandidate(quad: LiveFrames.sheet, confidence: 0.9)
        var outlines: [Quad?] = []
        var index: Int = 0
        while index < 20 {
            let seen: QuadCandidate? = index < 2 || index % 2 == 1 ? page : nil
            outlines.append(tracker.process(IOSCameraFrame(image: image, timestampMs: Double(index) * 100, page: seen))?.outline)
            index += 1
        }
        XCTAssertEqual(count.value, 0)
        let sheet: Quad = LiveQuadTracker.normalized(LiveFrames.sheet, width: 320, height: 240)
        index = 1
        while index < 20 {
            XCTAssertEqual(outlines[index], sheet, "at \(index)")
            index += 1
        }
    }

    func test_theFilter_dampsJitter() throws {
        // 320 × 240 (diagonal 400 px): corners tremble ±2 px about the sheet (within the 4 px of jitter).
        var filter = LiveQuadFilter()
        var index: Int = 0
        while index < 12 {
            let dx: Double = index % 2 == 0 ? 2 : -2
            let out: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(dx), atMs: Double(index) * 100, diagonal: 400)
            if index == 0 {
                XCTAssertNil(out.shown)
                XCTAssertEqual(out.page, LiveFrames.sheetMoved(2))
            } else {
                let shown: Quad = try XCTUnwrap(out.shown)
                XCTAssertEqual(out.page, shown)
                if index >= 3 {
                    // Halfway each time: the trembling settles to a third of what was found.
                    XCTAssertLessThanOrEqual(shown.maxCornerDistance(LiveFrames.sheet), 1.0, "at \(index)")
                }
            }
            index += 1
        }
        XCTAssertEqual(LiveQuadFilter.smoothing, 0.5)
        XCTAssertEqual(LiveQuadFilter.jitterShare, 0.01)
        XCTAssertEqual(LiveQuadFilter.jumpShare, 0.06)
    }

    func test_theFilter_followsARealMove_withinTwoFrames() {
        var filter = LiveQuadFilter()
        _ = filter.update(LiveFrames.sheet, atMs: 0, diagonal: 400)
        _ = filter.update(LiveFrames.sheet, atMs: 100, diagonal: 400)
        // Slid 10 px (more than jitter, less than a jump): followed at once.
        let slid: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(10), atMs: 200, diagonal: 400)
        XCTAssertEqual(slid.shown, LiveFrames.sheetMoved(10))
        XCTAssertEqual(slid.page, LiveFrames.sheetMoved(10))
        // Jumped 40 px (10 %): passed over once, then followed when found there again.
        let jumped: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(50), atMs: 300, diagonal: 400)
        XCTAssertNil(jumped.page)
        XCTAssertEqual(jumped.shown, LiveFrames.sheetMoved(10))
        let again: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(51), atMs: 400, diagonal: 400)
        XCTAssertEqual(again.shown, LiveFrames.sheetMoved(51))
        XCTAssertEqual(again.page, LiveFrames.sheetMoved(51))
        let settled: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(51), atMs: 500, diagonal: 400)
        XCTAssertEqual(settled.shown, LiveFrames.sheetMoved(51))
        // A jump seen once only (a stray outline) changes nothing.
        let stray: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(-60), atMs: 600, diagonal: 400)
        XCTAssertNil(stray.page)
        XCTAssertEqual(stray.shown, LiveFrames.sheetMoved(51))
        let back: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(51), atMs: 700, diagonal: 400)
        XCTAssertEqual(back.shown, LiveFrames.sheetMoved(51))
        // Corners named from another edge are the same page, not a jump.
        let sheet: Quad = LiveFrames.sheetMoved(51)
        let renamed = Quad(topLeft: sheet.bottomLeft, topRight: sheet.topLeft, bottomRight: sheet.topRight,
                           bottomLeft: sheet.bottomRight)
        let turned: LiveQuadFilter.Output = filter.update(renamed, atMs: 800, diagonal: 400)
        XCTAssertEqual(turned.shown, sheet)
    }

    func test_theFilter_followsAFastMove_fromItsSecondFrame() {
        var filter = LiveQuadFilter()
        _ = filter.update(LiveFrames.sheet, atMs: 0, diagonal: 400)
        _ = filter.update(LiveFrames.sheet, atMs: 100, diagonal: 400)
        // Swept 40 px (10 %) a frame: passed over once, then followed frame by frame, never frozen.
        let first: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(40), atMs: 200, diagonal: 400)
        XCTAssertNil(first.page)
        XCTAssertEqual(first.shown, LiveFrames.sheet)
        var step: Int = 2
        while step <= 5 {
            let dx: Double = 40 * Double(step)
            let out: LiveQuadFilter.Output = filter.update(LiveFrames.sheetMoved(dx), atMs: 100 + 100 * Double(step), diagonal: 400)
            XCTAssertEqual(out.shown, LiveFrames.sheetMoved(dx), "step \(step)")
            XCTAssertEqual(out.page, LiveFrames.sheetMoved(dx), "step \(step)")
            step += 1
        }
    }

    func test_theFilter_holdsALostPage_thenClearsIt() {
        var filter = LiveQuadFilter()
        _ = filter.update(LiveFrames.sheet, atMs: 0, diagonal: 400)
        _ = filter.update(LiveFrames.sheet, atMs: 100, diagonal: 400)
        // Missed: kept for 300 ms after it was last found, with no page for the shutter.
        for t in [200.0, 300.0, 400.0] {
            let missed: LiveQuadFilter.Output = filter.update(nil, atMs: t, diagonal: 400)
            XCTAssertNil(missed.page)
            XCTAssertEqual(missed.shown, LiveFrames.sheet, "at \(t)")
        }
        let gone: LiveQuadFilter.Output = filter.update(nil, atMs: 500, diagonal: 400)
        XCTAssertNil(gone.shown)
        // Found again after that: a new page, drawn from its second sighting.
        let first: LiveQuadFilter.Output = filter.update(LiveFrames.sheet, atMs: 600, diagonal: 400)
        XCTAssertNil(first.shown)
        XCTAssertEqual(first.page, LiveFrames.sheet)
        // A first sighting missing on the next frame is forgotten.
        _ = filter.update(nil, atMs: 700, diagonal: 400)
        let anew: LiveQuadFilter.Output = filter.update(LiveFrames.sheet, atMs: 800, diagonal: 400)
        XCTAssertNil(anew.shown)
        let seenTwice: LiveQuadFilter.Output = filter.update(LiveFrames.sheet, atMs: 900, diagonal: 400)
        XCTAssertEqual(seenTwice.shown, LiveFrames.sheet)
    }

    func test_stopFollowing_stopsTheSource() {
        let tracker = LiveQuadTracker()
        let source = FixtureFrameSource([])
        tracker.follow(source) { (_: LiveQuadUpdate) -> Void in }
        XCTAssertFalse(source.stopped)
        tracker.stopFollowing()
        XCTAssertTrue(source.stopped)
    }

    func test_theFrameScaler_averagesFourPixelsOfEachBlock_andTurnsBGRAIntoRGBA() throws {
        // 8 × 6 BGRA, 40 bytes a row (8 bytes of padding): blue = x, green = y, red = 10x + y.
        let width: Int = 8
        let height: Int = 6
        let bytesPerRow: Int = 40
        var bytes: [UInt8] = [UInt8](repeating: 0, count: bytesPerRow * height)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let o: Int = y * bytesPerRow + x * 4
                bytes[o] = UInt8(x)
                bytes[o + 1] = UInt8(y)
                bytes[o + 2] = UInt8(10 * x + y)
                bytes[o + 3] = 255
                x += 1
            }
            y += 1
        }
        // At most 4 px long: blocks of 2 × 2, all four pixels averaged.
        let small: RgbaImage? = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> RgbaImage? in
            IOSFrameScaler.downscaled(bgra: raw, width: width, height: height, bytesPerRow: bytesPerRow, maxLongSide: 4)
        }
        let image: RgbaImage = try XCTUnwrap(small)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        // Pixel (1, 2) covers x 2...3, y 4...5: red (20+4 + 30+4 + 20+5 + 30+5) / 4 = 29.5 → 30 (half up).
        let o: Int = (2 * 4 + 1) * 4
        XCTAssertEqual(image.pixels[o], 30)
        XCTAssertEqual(image.pixels[o + 1], 5)      // green (4 + 4 + 5 + 5 + 2) / 4
        XCTAssertEqual(image.pixels[o + 2], 3)      // blue (2 + 3 + 2 + 3 + 2) / 4
        XCTAssertEqual(image.pixels[o + 3], 255)
        // Small enough already: kept pixel for pixel.
        let same: RgbaImage? = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> RgbaImage? in
            IOSFrameScaler.downscaled(bgra: raw, width: width, height: height, bytesPerRow: bytesPerRow, maxLongSide: 480)
        }
        let whole: RgbaImage = try XCTUnwrap(same)
        XCTAssertEqual(whole.width, 8)
        XCTAssertEqual(whole.height, 6)
        let p: Int = (3 * 8 + 5) * 4
        XCTAssertEqual(whole.pixels[p], 53)
        XCTAssertEqual(whole.pixels[p + 1], 3)
        XCTAssertEqual(whole.pixels[p + 2], 5)
        // Too few bytes, or rows too short: refused.
        let short: RgbaImage? = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> RgbaImage? in
            IOSFrameScaler.downscaled(bgra: raw, width: width, height: height + 1, bytesPerRow: bytesPerRow, maxLongSide: 4)
        }
        XCTAssertNil(short)
        let narrow: RgbaImage? = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> RgbaImage? in
            IOSFrameScaler.downscaled(bgra: raw, width: width, height: height, bytesPerRow: 16, maxLongSide: 4)
        }
        XCTAssertNil(narrow)
    }

    func test_aLiveOutline_isTurnedIntoTheUprightPhoto() {
        let outline = Quad(topLeft: CGPoint(x: 0.1, y: 0.2), topRight: CGPoint(x: 0.5, y: 0.2),
                           bottomRight: CGPoint(x: 0.5, y: 0.6), bottomLeft: CGPoint(x: 0.1, y: 0.6))
        // Not turned.
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 0), outline, accuracy: 1e-12)
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 360), outline, accuracy: 1e-12)
        // A quarter clockwise (the phone held upright): the sensor's top left is the photo's top right.
        let quarter = Quad(topLeft: CGPoint(x: 0.4, y: 0.1), topRight: CGPoint(x: 0.8, y: 0.1),
                           bottomRight: CGPoint(x: 0.8, y: 0.5), bottomLeft: CGPoint(x: 0.4, y: 0.5))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 90), quarter, accuracy: 1e-12)
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: -270), quarter, accuracy: 1e-12)
        let half = Quad(topLeft: CGPoint(x: 0.5, y: 0.4), topRight: CGPoint(x: 0.9, y: 0.4),
                        bottomRight: CGPoint(x: 0.9, y: 0.8), bottomLeft: CGPoint(x: 0.5, y: 0.8))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 180), half, accuracy: 1e-12)
        let threeQuarters = Quad(topLeft: CGPoint(x: 0.2, y: 0.5), topRight: CGPoint(x: 0.6, y: 0.5),
                                 bottomRight: CGPoint(x: 0.6, y: 0.9), bottomLeft: CGPoint(x: 0.2, y: 0.9))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 270), threeQuarters, accuracy: 1e-12)
        // Any other turn is not a photo's.
        XCTAssertNil(LiveQuadTracker.photoOutline(outline, rotationDegrees: 45))
    }

    // The turn the live frames take for the corner model: the frame turned upright by
    // `RgbaImage.rotatedQuarterTurns` and the corners turned back by `photoOutline` land on the same pixels.
    func test_cornersFoundOnTheUprightFrame_turnBackOntoTheSensorsPixels() throws {
        let width: Int = 48
        let height: Int = 36
        let marks: [(x: Int, y: Int)] = [(5, 4), (40, 7), (37, 30), (8, 27)]
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var index: Int = 0
        for mark in marks {
            let at: Int = (mark.y * width + mark.x) * 4
            pixels[at] = UInt8(100 + index * 40)
            pixels[at + 3] = 255
            index += 1
        }
        let frame = RgbaImage(width: width, height: height, pixels: pixels)
        for turn in [0, 90, 180, 270] {
            let upright: RgbaImage = frame.rotatedQuarterTurns(turn / 90)
            // Where each mark is in the upright frame, as shares of it (the pixel's centre).
            var found: [CGPoint] = []
            index = 0
            while index < 4 {
                let wanted = UInt8(100 + index * 40)
                var at: Int = 0
                while at < upright.width * upright.height {
                    if upright.pixels[at * 4] == wanted {
                        found.append(CGPoint(x: (Double(at % upright.width) + 0.5) / Double(upright.width),
                                             y: (Double(at / upright.width) + 0.5) / Double(upright.height)))
                    }
                    at += 1
                }
                index += 1
            }
            XCTAssertEqual(found.count, 4, "turn \(turn)")
            let back: Quad = try XCTUnwrap(LiveQuadTracker.photoOutline(Quad.fromCorners(found),
                                                                        rotationDegrees: (360 - turn) % 360))
            let sensor: Quad = back.scaled(Double(width), Double(height))
            for mark in marks {
                let centre = CGPoint(x: Double(mark.x) + 0.5, y: Double(mark.y) + 0.5)
                let nearest: Double = sensor.corners.map { (corner: CGPoint) -> Double in
                    let dx: Double = Double(corner.x - centre.x)
                    let dy: Double = Double(corner.y - centre.y)
                    return (dx * dx + dy * dy).squareRoot()
                }.min() ?? Double.infinity
                XCTAssertLessThan(nearest, 1e-6, "turn \(turn), mark \(mark)")
            }
        }
    }
}
#endif
