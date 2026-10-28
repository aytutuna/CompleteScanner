#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import Vision
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The page detectors side by side on the SmartDoc 2015 Challenge 1 frames (jchazalon/smartdoc15-ch1-dataset
// v2.0.0, CC BY 4.0): DocAligner's FastViT-T8 on the CPU, our own detector as the photo import calls it
// (`IOSPageFinder.fallback`) and Apple's Vision document segmentation. Runs only where SMARTDOC_FRAMES names
// the extracted frames with their metadata.csv (gunzipped); every SMARTDOC_STEP-th frame (25 unless set).
// The table goes to BENCH_OUT/bench.md (the temporary folder unless set) and to the log. Low scores never
// fail it, only frames or metadata that cannot be read.

/// What one detector found in the frames of one background, or of all.
struct BenchTally {
    var frames: Int = 0
    var iouSum: Double = 0
    var errorSum: Double = 0
    var misses: Int = 0
    var ms: [Double] = []

    mutating func add(_ found: Quad?, truth: Quad, diagonal: Double, ms: Double) {
        frames += 1
        self.ms.append(ms)
        guard let quad = found else {
            misses += 1
            errorSum += 100
            return
        }
        iouSum += BenchTally.iou(quad, truth)
        errorSum += BenchTally.cornerError(quad, truth) / diagonal * 100
    }

    /// The share of the two outlines' joint area they have in common; `truth` convex.
    static func iou(_ found: Quad, _ truth: Quad) -> Double {
        let outline: Quad = Quad.fromCorners(found.corners)
        let shared: Double = outline.intersectionArea(truth)
        let union: Double = outline.area + truth.area - shared
        guard union > 0 else { return 0 }
        return min(max(shared / union, 0), 1)
    }

    /// The corners' mean distance in pixels, `found`'s corners paired with `truth`'s whichever way round fits
    /// best (the detectors name corners by where they are, the ground truth by the page's top).
    static func cornerError(_ found: Quad, _ truth: Quad) -> Double {
        let outline: Quad = Quad.fromCorners(found.corners)
        var best: Double = Double.infinity
        var shift: Int = 0
        while shift < 4 {
            var sum: Double = 0
            var index: Int = 0
            while index < 4 {
                let a: CGPoint = outline[index + shift]
                let b: CGPoint = truth[index]
                let dx: Double = Double(a.x) - Double(b.x)
                let dy: Double = Double(a.y) - Double(b.y)
                sum += (dx * dx + dy * dy).squareRoot()
                index += 1
            }
            best = min(best, sum / 4)
            shift += 1
        }
        return best
    }
}

final class DocAlignerBenchTests: XCTestCase {
    private enum Detector: String, CaseIterable {
        case fastvitT8 = "FastViT-T8 (CPU)"
        case builtIn = "Built-in"
        case vision = "Apple Vision (Simulator)"
    }

    private struct Frame {
        let background: String
        let path: String
        let truth: Quad
    }

    func test_detectorsOnSmartDocFrames() throws {
        let environment: [String: String] = ProcessInfo.processInfo.environment
        guard let root = environment["SMARTDOC_FRAMES"], !root.isEmpty else {
            throw XCTSkip("SMARTDOC_FRAMES is not set")
        }
        let step: Int = max(Int(environment["SMARTDOC_STEP"] ?? "") ?? 25, 1)
        let out: String = environment["BENCH_OUT"].flatMap { (value: String) -> String? in value.isEmpty ? nil : value }
            ?? NSTemporaryDirectory()
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        let frames: [Frame] = try DocAlignerBenchTests.frames(in: folder, step: step)
        XCTAssertFalse(frames.isEmpty, "No frames in metadata.csv")

        let runner = DocAligner()
        var tallies: [Detector: [String: BenchTally]] = [:]
        var visionProblem: String?
        for frame in frames {
            try autoreleasepool {
                let url: URL = folder.appendingPathComponent(frame.path)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let photo = RgbaImage(cgImage: image) else {
                    throw BenchError.unreadable(frame.path)
                }
                let width: Double = Double(image.width)
                let height: Double = Double(image.height)
                let diagonal: Double = (width * width + height * height).squareRoot()
                for detector in Detector.allCases {
                    let started: UInt64 = DispatchTime.now().uptimeNanoseconds
                    var found: Quad?
                    switch detector {
                    case .fastvitT8:
                        guard DocAlignerModel.fastvitT8.isAvailable else { continue }
                        found = try runner.run(image, model: .fastvitT8, neuralEngine: false).page?.quad.scaled(width, height)
                    case .builtIn:
                        let page: IOSFoundPage = IOSPageFinder.fallback(photo)
                        found = page.reason == PhotoReviewReason.nothingFound ? nil : page.corners
                    case .vision:
                        let request = VNDetectDocumentSegmentationRequest()
                        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                        do {
                            try handler.perform([request])
                            let observation: VNObservation? = request.results?.first
                            if let first = observation as? VNRectangleObservation {
                                let points: [CGPoint] = [first.topLeft, first.topRight, first.bottomRight, first.bottomLeft]
                                found = IOSPageFinder.quad(fromNormalized: points, width: image.width, height: image.height)
                            }
                        } catch {
                            visionProblem = error.localizedDescription
                        }
                    }
                    let ms: Double = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    var byBackground: [String: BenchTally] = tallies[detector] ?? [:]
                    var tally: BenchTally = byBackground[frame.background] ?? BenchTally()
                    tally.add(found, truth: frame.truth, diagonal: diagonal, ms: ms)
                    byBackground[frame.background] = tally
                    tallies[detector] = byBackground
                }
            }
        }

        var lines: [String] = []
        lines.append("# Page detectors on SmartDoc 2015 Challenge 1")
        lines.append("")
        lines.append("Every \(step)th frame, \(frames.count) frames, on the iOS Simulator (CPU). IoU: the outline found against "
            + "the ground truth in the frame's pixels. Corner error: the corners' mean distance as % of the frame's "
            + "diagonal. A miss counts as IoU 0 and 100 %. Built-in counts a miss only where it found nothing at all. "
            + "DocAligner may have been trained on SmartDoc, so its scores here are likely optimistic. The Simulator's "
            + "Vision results are not trustworthy; the Apple Vision (macOS) rows are Apple's real score.")
        lines.append("")
        for model in [DocAlignerModel.fastvitT8] where !model.isAvailable {
            lines.append("\(model.title) was not fetched (scripts/fetch_docaligner.sh) and is left out.")
            lines.append("")
        }
        if let problem = visionProblem {
            lines.append("Vision could not run on some frames here: \(problem). Those frames count as misses.")
            lines.append("")
        }
        lines.append("| Detector | Background | Frames | Mean IoU | Mean corner error | Misses | Median ms |")
        lines.append("|---|---|---:|---:|---:|---:|---:|")
        for detector in Detector.allCases {
            guard let byBackground = tallies[detector] else { continue }
            var all = BenchTally()
            for background in byBackground.keys.sorted() {
                let tally: BenchTally = byBackground[background] ?? BenchTally()
                lines.append(DocAlignerBenchTests.row(detector.rawValue, background, tally))
                all.frames += tally.frames
                all.iouSum += tally.iouSum
                all.errorSum += tally.errorSum
                all.misses += tally.misses
                all.ms += tally.ms
            }
            lines.append(DocAlignerBenchTests.row(detector.rawValue, "**all**", all))
        }
        let table: String = lines.joined(separator: "\n") + "\n"
        print(table)
        let outFolder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        try table.write(to: outFolder.appendingPathComponent("bench.md"), atomically: true, encoding: .utf8)
    }

    private enum BenchError: Error {
        case unreadable(String)
        case missingColumn(String)
    }

    private static func row(_ name: String, _ background: String, _ tally: BenchTally) -> String {
        let count: Double = Double(max(tally.frames, 1))
        let iou: String = String(format: "%.3f", tally.iouSum / count)
        let error: String = String(format: "%.2f %%", tally.errorSum / count)
        let median: String = String(format: "%.1f", DocAligner.percentile(tally.ms, 0.5))
        return "| \(name) | \(background) | \(tally.frames) | \(iou) | \(error) | \(tally.misses) | \(median) |"
    }

    /// Every `step`-th frame listed in `folder`'s metadata.csv (columns named in its header: bg_name,
    /// image_path, and the corners tl_x … tr_y in the frame's pixels).
    private static func frames(in folder: URL, step: Int) throws -> [Frame] {
        let text: String = try String(contentsOf: folder.appendingPathComponent("metadata.csv"), encoding: .utf8)
        var rows: [Substring] = text.split(whereSeparator: { (c: Character) -> Bool in c == "\n" || c == "\r\n" })
        guard !rows.isEmpty else { throw BenchError.unreadable("metadata.csv") }
        let header: [String] = rows.removeFirst().split(separator: ",").map { (s: Substring) -> String in
            s.trimmingCharacters(in: .whitespaces)
        }
        func column(_ name: String) throws -> Int {
            guard let index = header.firstIndex(of: name) else { throw BenchError.missingColumn(name) }
            return index
        }
        let background: Int = try column("bg_name")
        let path: Int = try column("image_path")
        let corners: [Int] = try ["tl_x", "tl_y", "tr_x", "tr_y", "br_x", "br_y", "bl_x", "bl_y"].map(column)
        var frames: [Frame] = []
        var index: Int = 0
        for row in rows {
            defer { index += 1 }
            guard index % step == 0 else { continue }
            let fields: [String] = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == header.count else { throw BenchError.unreadable("metadata.csv row \(index + 2)") }
            var values: [Double] = []
            for at in corners {
                guard let value = Double(fields[at].trimmingCharacters(in: .whitespaces)) else {
                    throw BenchError.unreadable("metadata.csv row \(index + 2)")
                }
                values.append(value)
            }
            let truth = Quad(topLeft: CGPoint(x: values[0], y: values[1]), topRight: CGPoint(x: values[2], y: values[3]),
                             bottomRight: CGPoint(x: values[4], y: values[5]), bottomLeft: CGPoint(x: values[6], y: values[7]))
            frames.append(Frame(background: fields[background], path: fields[path], truth: Quad.fromCorners(truth.corners)))
        }
        return frames
    }
}

final class BenchTallyTests: XCTestCase {
    func test_theSameOutline_scoresOne_andAHalfOverlap_aThird() {
        let truth = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 100, y: 0), bottomRight: CGPoint(x: 100, y: 100),
                         bottomLeft: CGPoint(x: 0, y: 100))
        XCTAssertEqual(BenchTally.iou(truth, truth), 1, accuracy: 1e-9)
        let shifted = Quad(topLeft: CGPoint(x: 50, y: 0), topRight: CGPoint(x: 150, y: 0), bottomRight: CGPoint(x: 150, y: 100),
                           bottomLeft: CGPoint(x: 50, y: 100))
        XCTAssertEqual(BenchTally.iou(shifted, truth), 1.0 / 3.0, accuracy: 1e-9)
        // Named from another corner, the same outline is no error.
        let renamed = Quad(topLeft: truth.topRight, topRight: truth.bottomRight, bottomRight: truth.bottomLeft,
                           bottomLeft: truth.topLeft)
        XCTAssertEqual(BenchTally.cornerError(renamed, truth), 0, accuracy: 1e-9)
        XCTAssertEqual(BenchTally.cornerError(shifted, truth), 50, accuracy: 1e-9)
        var tally = BenchTally()
        tally.add(nil, truth: truth, diagonal: 141, ms: 3)
        tally.add(truth, truth: truth, diagonal: 141, ms: 5)
        XCTAssertEqual(tally.misses, 1)
        XCTAssertEqual(tally.iouSum, 1, accuracy: 1e-9)
        XCTAssertEqual(tally.errorSum, 100, accuracy: 1e-9)
    }
}
#endif
