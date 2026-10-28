import CoreGraphics
import Foundation
import ImageIO
import Vision

// Apple's document segmentation on the SmartDoc 2015 Challenge 1 frames, run natively on the Mac: the
// Simulator's Vision gives nothing usable. The frames, the sampling, IoU and corner error are the same as
// Tests/CompleteScannerIOSTests/DocAlignerBenchTests.swift. Appends its rows to the bench table.
//
//   swift scripts/bench_vision.swift <framesDir> <step> <outFile>

let label: String = "Apple Vision (macOS)"

struct Frame {
    let background: String
    let path: String
    let truth: [CGPoint]
}

struct Tally {
    var frames: Int = 0
    var iouSum: Double = 0
    var errorSum: Double = 0
    var misses: Int = 0
    var ms: [Double] = []

    mutating func add(_ found: [CGPoint]?, truth: [CGPoint], diagonal: Double, ms: Double) {
        frames += 1
        self.ms.append(ms)
        guard let quad = found else {
            misses += 1
            errorSum += 100
            return
        }
        iouSum += iou(quad, truth)
        errorSum += cornerError(quad, truth) / diagonal * 100
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func signedArea(_ polygon: [CGPoint]) -> Double {
    var sum: Double = 0
    var index: Int = 0
    while index < polygon.count {
        let a: CGPoint = polygon[index]
        let b: CGPoint = polygon[(index + 1) % polygon.count]
        sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        index += 1
    }
    return sum / 2
}

/// `subject` cut to the inside of the convex `clip` (Sutherland-Hodgman), both counter-clockwise.
func clipped(_ subject: [CGPoint], to clip: [CGPoint]) -> [CGPoint] {
    var output: [CGPoint] = subject
    var edge: Int = 0
    while edge < clip.count && !output.isEmpty {
        let a: CGPoint = clip[edge]
        let b: CGPoint = clip[(edge + 1) % clip.count]
        func side(_ p: CGPoint) -> Double {
            (Double(b.x) - Double(a.x)) * (Double(p.y) - Double(a.y)) - (Double(b.y) - Double(a.y)) * (Double(p.x) - Double(a.x))
        }
        let input: [CGPoint] = output
        output = []
        var index: Int = 0
        while index < input.count {
            let current: CGPoint = input[index]
            let previous: CGPoint = input[(index + input.count - 1) % input.count]
            let currentSide: Double = side(current)
            let previousSide: Double = side(previous)
            if currentSide >= 0 {
                if previousSide < 0 { output.append(crossing(previous, current, previousSide, currentSide)) }
                output.append(current)
            } else if previousSide >= 0 {
                output.append(crossing(previous, current, previousSide, currentSide))
            }
            index += 1
        }
        edge += 1
    }
    return output
}

func crossing(_ p: CGPoint, _ q: CGPoint, _ sideP: Double, _ sideQ: Double) -> CGPoint {
    let t: Double = sideP / (sideP - sideQ)
    return CGPoint(x: Double(p.x) + t * (Double(q.x) - Double(p.x)), y: Double(p.y) + t * (Double(q.y) - Double(p.y)))
}

func counterClockwise(_ polygon: [CGPoint]) -> [CGPoint] {
    signedArea(polygon) < 0 ? Array(polygon.reversed()) : polygon
}

/// The share of the two outlines' joint area they have in common, whatever corner each starts from.
func iou(_ found: [CGPoint], _ truth: [CGPoint]) -> Double {
    let a: [CGPoint] = counterClockwise(found)
    let b: [CGPoint] = counterClockwise(truth)
    let shared: Double = abs(signedArea(clipped(a, to: b)))
    let union: Double = abs(signedArea(a)) + abs(signedArea(b)) - shared
    guard union > 0 else { return 0 }
    return min(max(shared / union, 0), 1)
}

/// The corners' mean distance in pixels, paired whichever way round fits best.
func cornerError(_ found: [CGPoint], _ truth: [CGPoint]) -> Double {
    let outline: [CGPoint] = counterClockwise(found)
    let wanted: [CGPoint] = counterClockwise(truth)
    var best: Double = Double.infinity
    var shift: Int = 0
    while shift < 4 {
        var sum: Double = 0
        var index: Int = 0
        while index < 4 {
            let a: CGPoint = outline[(index + shift) % 4]
            let b: CGPoint = wanted[index]
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

func percentile(_ values: [Double], _ share: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted: [Double] = values.sorted()
    let index: Int = Int((share * Double(sorted.count - 1)).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
}

func row(_ background: String, _ tally: Tally) -> String {
    let count: Double = Double(max(tally.frames, 1))
    let iouText: String = String(format: "%.3f", tally.iouSum / count)
    let errorText: String = String(format: "%.2f %%", tally.errorSum / count)
    let median: String = String(format: "%.1f", percentile(tally.ms, 0.5))
    return "| \(label) | \(background) | \(tally.frames) | \(iouText) | \(errorText) | \(tally.misses) | \(median) |"
}

/// Every `step`-th frame listed in `folder`'s metadata.csv.
func frames(in folder: URL, step: Int) -> [Frame] {
    guard let text = try? String(contentsOf: folder.appendingPathComponent("metadata.csv"), encoding: .utf8) else {
        fail("metadata.csv cannot be read in \(folder.path)")
    }
    var rows: [Substring] = text.split(whereSeparator: { (c: Character) -> Bool in c == "\n" || c == "\r\n" })
    guard !rows.isEmpty else { fail("metadata.csv is empty") }
    let header: [String] = rows.removeFirst().split(separator: ",").map { (s: Substring) -> String in
        s.trimmingCharacters(in: .whitespaces)
    }
    func column(_ name: String) -> Int {
        guard let index = header.firstIndex(of: name) else { fail("metadata.csv has no column \(name)") }
        return index
    }
    let background: Int = column("bg_name")
    let path: Int = column("image_path")
    let corners: [Int] = ["tl_x", "tl_y", "tr_x", "tr_y", "br_x", "br_y", "bl_x", "bl_y"].map(column)
    var found: [Frame] = []
    var index: Int = 0
    for row in rows {
        defer { index += 1 }
        guard index % step == 0 else { continue }
        let fields: [String] = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == header.count else { fail("metadata.csv row \(index + 2) is malformed") }
        var values: [Double] = []
        for at in corners {
            guard let value = Double(fields[at].trimmingCharacters(in: .whitespaces)) else {
                fail("metadata.csv row \(index + 2) is malformed")
            }
            values.append(value)
        }
        let truth: [CGPoint] = [CGPoint(x: values[0], y: values[1]), CGPoint(x: values[2], y: values[3]),
                                CGPoint(x: values[4], y: values[5]), CGPoint(x: values[6], y: values[7])]
        found.append(Frame(background: fields[background], path: fields[path], truth: truth))
    }
    return found
}

let arguments: [String] = CommandLine.arguments
guard arguments.count == 4, let step = Int(arguments[2]), step >= 1 else {
    fail("usage: swift scripts/bench_vision.swift <framesDir> <step> <outFile>")
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outFile = URL(fileURLWithPath: arguments[3])
let sampled: [Frame] = frames(in: folder, step: step)
if sampled.isEmpty { fail("No frames in metadata.csv") }

var byBackground: [String: Tally] = [:]
var problem: String?
var shown: Int = 0
for frame in sampled {
    autoreleasepool {
        let url: URL = folder.appendingPathComponent(frame.path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fail("Cannot read \(frame.path)")
        }
        let width: Double = Double(image.width)
        let height: Double = Double(image.height)
        let diagonal: Double = (width * width + height * height).squareRoot()
        let started: UInt64 = DispatchTime.now().uptimeNanoseconds
        var found: [CGPoint]?
        var raw: [CGPoint] = []
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            if let first = request.results?.first as? VNRectangleObservation {
                raw = [first.topLeft, first.topRight, first.bottomRight, first.bottomLeft]
                found = raw.map { (p: CGPoint) -> CGPoint in CGPoint(x: Double(p.x) * width, y: (1 - Double(p.y)) * height) }
            }
        } catch {
            problem = error.localizedDescription
        }
        let ms: Double = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        if shown < 3 {
            print("frame \(frame.path) \(image.width)x\(image.height)")
            print("  vision (normalized, y up): \(raw)")
            print("  mapped (pixels, y down):   \(found ?? [])")
            print("  truth  (pixels, y down):   \(frame.truth)")
            shown += 1
        }
        var tally: Tally = byBackground[frame.background] ?? Tally()
        tally.add(found, truth: frame.truth, diagonal: diagonal, ms: ms)
        byBackground[frame.background] = tally
    }
}

var lines: [String] = []
var all = Tally()
for background in byBackground.keys.sorted() {
    let tally: Tally = byBackground[background] ?? Tally()
    lines.append(row(background, tally))
    all.frames += tally.frames
    all.iouSum += tally.iouSum
    all.errorSum += tally.errorSum
    all.misses += tally.misses
    all.ms += tally.ms
}
lines.append(row("**all**", all))
if let problem = problem {
    lines.append("")
    lines.append("Vision could not run on some frames on the Mac: \(problem). Those frames count as misses.")
}
let rowsText: String = lines.joined(separator: "\n") + "\n"
print(rowsText)

// Without the Simulator's table (its step failed) the Mac rows get a header of their own.
var table: String = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
if table.isEmpty {
    table = "# Page detectors on SmartDoc 2015 Challenge 1\n\nEvery \(step)th frame, \(sampled.count) frames, run on the Mac.\n\n"
        + "| Detector | Background | Frames | Mean IoU | Mean corner error | Misses | Median ms |\n"
        + "|---|---|---:|---:|---:|---:|---:|\n"
}
if !table.hasSuffix("\n") { table += "\n" }
try FileManager.default.createDirectory(at: outFile.deletingLastPathComponent(), withIntermediateDirectories: true)
try (table + rowsText).write(to: outFile, atomically: true, encoding: .utf8)
