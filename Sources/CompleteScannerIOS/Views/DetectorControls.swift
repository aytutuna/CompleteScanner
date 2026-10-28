#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// The page detector test in the drawer's Camera group (`PageDetector`): which finder the live outline and
/// the photos use, the Neural Engine for DocAligner's models, and the speed test on the camera's last frame.
struct DetectorControls: View {
    @AppStorage(PageDetector.key) private var detector: PageDetector = .apple
    @AppStorage(PageDetector.neuralEngineKey) private var neuralEngine: Bool = false
    @State private var testing: Bool = false
    @State private var frame: CGImage?
    /// The camera's frames, for the speed test; nil without a camera.
    let feed: IOSFrameFeed?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(IOSCameraText.detectorLabel) {
                HStack(spacing: 4) {
                    Picker(IOSCameraText.detectorLabel, selection: $detector) {
                        ForEach(PageDetector.allCases) { (choice: PageDetector) in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("detector.picker")
                    Button(IOSCameraText.speedTestLabel) {
                        frame = feed?.uprightFrame()
                        testing = true
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("detector.speedTest")
                }
            }
            if detector.model != nil {
                Toggle(IOSCameraText.neuralEngineLabel, isOn: $neuralEngine)
                    .accessibilityIdentifier("detector.neuralEngine")
            }
        }
        .sheet(isPresented: $testing) {
            DetectorSpeedTest(frame: frame)
        }
    }
}

/// Each of DocAligner's models on the CPU and with the Neural Engine (Core ML): 3 runs to warm up, then 30
/// timed, on `frame` or on a drawn page when the camera has handed none over yet; the median and the 90th
/// percentile in ms, a line where Core ML could not be used and one for a model not in this build. The runs
/// go to the shared runner's queue, one after the other, never the main thread.
struct DetectorSpeedTest: View {
    @Environment(\.dismiss) private var dismiss
    let frame: CGImage?
    @State private var lines: [String] = []
    @State private var running: Bool = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lines.indices, id: \.self) { (index: Int) in
                        Text(lines[index])
                            .font(.callout.monospacedDigit())
                    }
                    if running {
                        ProgressView()
                    }
                } header: {
                    Text(frame == nil ? IOSCameraText.speedTestOnDrawing : IOSCameraText.speedTestOnFrame)
                }
            }
            .navigationTitle(IOSCameraText.speedTestLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSCameraText.doneLabel) {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("detector.speedResults")
        .task {
            await measure()
        }
    }

    private func measure() async {
        guard let image = frame ?? DetectorSpeedTest.drawnPage() else {
            running = false
            return
        }
        for model in DocAlignerModel.allCases {
            guard model.isAvailable else {
                lines.append(DocAlignerError.missing(model).errorDescription ?? model.title)
                continue
            }
            for engine in [false, true] {
                let measured: [String] = await withCheckedContinuation {
                    (continuation: CheckedContinuation<[String], Never>) -> Void in
                    DocAligner.queue.async {
                        continuation.resume(returning: DetectorSpeedTest.timed(image, model: model, neuralEngine: engine))
                    }
                }
                lines.append(contentsOf: measured)
            }
        }
        running = false
    }

    /// The speed test's lines for `model` on `image`; called on `DocAligner.queue`.
    nonisolated static func timed(_ image: CGImage, model: DocAlignerModel, neuralEngine: Bool) -> [String] {
        do {
            let timing: (ms: [Double], coreMLProblem: String?) = try DocAligner.shared.time(image, model: model,
                                                                                            neuralEngine: neuralEngine)
            var result: [String] = [IOSCameraText.speedLine(model, neuralEngine: neuralEngine,
                                                            median: DocAligner.percentile(timing.ms, 0.5),
                                                            p90: DocAligner.percentile(timing.ms, 0.9))]
            if let why = timing.coreMLProblem {
                result.append(IOSCameraText.noCoreML(model, why: why))
            }
            return result
        } catch {
            return ["\(model.title): \(error.localizedDescription)"]
        }
    }

    /// A light sheet a little turned on a grey table, the size of a live frame made small, upright.
    static func drawnPage() -> CGImage? {
        let width: Int = 360
        let height: Int = 480
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 0.25, green: 0.24, blue: 0.22, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1)
        context.move(to: CGPoint(x: 70, y: 390))
        context.addLine(to: CGPoint(x: 300, y: 410))
        context.addLine(to: CGPoint(x: 320, y: 60))
        context.addLine(to: CGPoint(x: 50, y: 80))
        context.closePath()
        context.fillPath()
        return context.makeImage()
    }
}

/// The viewfinder's caption while one of DocAligner's models finds the page: its name and how long it ran
/// on the last frame (`IOSFrameFeed.modelMs(_:)`), read twice a second.
struct DetectorCaption: View {
    let model: DocAlignerModel
    let feed: IOSFrameFeed

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(IOSCameraText.detectorCaption(model, ms: feed.modelMs(model)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .accessibilityIdentifier("detector.caption")
    }
}
#endif
