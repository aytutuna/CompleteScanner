#if os(iOS)
import CompleteScannerKit
import CompleteScannerModel
import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// DocAligner's corner models (DocsaidLab/DocAligner 1.1.1, Apache-2.0). Only FastViT-T8 is fetched now
/// (scripts/fetch_docaligner.sh, into CompleteScannerModel's Models folder); LC100 stays in the test switch
/// as not in this build.
public enum DocAlignerModel: String, CaseIterable, Identifiable, Sendable {
    case lc100
    case fastvitT8

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lc100: return "LC100"
        case .fastvitT8: return "FastViT-T8"
        }
    }

    /// The model's file; nil when it was not fetched.
    public var url: URL? {
        switch self {
        case .lc100: return nil
        case .fastvitT8: return FastViTCornerModel.url
        }
    }

    public var isAvailable: Bool { url != nil }
}

/// Why DocAligner did not run.
public enum DocAlignerError: Error, Equatable, LocalizedError {
    /// The model's file is not in the app.
    case missing(DocAlignerModel)
    /// This build of ONNX Runtime has no Core ML.
    case noCoreML
    /// The image could not be drawn at the model's size, or the model answered in another shape.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missing(let model): return "\(model.title) is not in this build"
        case .noCoreML: return "Core ML is not in this build of ONNX Runtime"
        case .unreadable: return "The model's answer could not be read"
        }
    }
}

/// One run of a model: the page it found (`CornerHeatmap`: corners as shares of the image given, top left
/// first), nil when it found none; how long the model ran, in ms (drawing the image at its size not counted);
/// and why Core ML was not used when the Neural Engine was asked for and the model ran on the CPU instead.
public struct DocAlignerRun: Sendable {
    public let page: QuadCandidate?
    public let ms: Double
    public let coreMLProblem: String?
}

/// Runs DocAligner's models with ONNX Runtime. The image is stretched to 256 × 256 (its shape not kept, as
/// the models were trained), its pixels given as blue, green and red planes from 0 to 1, and the four
/// heatmaps read back by `CornerHeatmap`. A model's session is made on its first run and kept, one for the
/// CPU (all graph optimizations, two threads) and one with Core ML in front (`neuralEngine`; the CPU's when
/// Core ML cannot take the model). Not thread-safe: the app's runner (`shared`) is used on `queue` only.
public final class DocAligner: @unchecked Sendable {
    public static let shared = DocAligner()
    public static let queue = DispatchQueue(label: "CompleteScanner.docaligner", qos: .userInitiated)
    /// The models' input side, in pixels.
    static let side: Int = 256

    private struct Loaded {
        let session: ORTSession
        let coreMLProblem: String?
    }

    private var env: ORTEnv?
    private var sessions: [String: Loaded] = [:]
    private let canvas: CGContext?
    private let input: NSMutableData

    public init() {
        let side: Int = DocAligner.side
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context: CGContext? = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.interpolationQuality = .medium
        canvas = context
        input = NSMutableData(length: 3 * side * side * MemoryLayout<Float>.size) ?? NSMutableData()
    }

    /// `model` on `image`, with Core ML in front when `neuralEngine`.
    public func run(_ image: CGImage, model: DocAlignerModel, neuralEngine: Bool) throws -> DocAlignerRun {
        let loaded: Loaded = try session(model, neuralEngine: neuralEngine)
        try draw(image)
        let side = NSNumber(value: DocAligner.side)
        let value = try ORTValue(tensorData: input, elementType: .float, shape: [1, 3, side, side])
        let started: UInt64 = DispatchTime.now().uptimeNanoseconds
        let outputs: [String: ORTValue] = try loaded.session.run(withInputs: ["img": value], outputNames: ["heatmap"],
                                                                 runOptions: nil)
        let ms: Double = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        guard let heatmap = outputs["heatmap"] else { throw DocAlignerError.unreadable }
        let shape: [NSNumber] = try heatmap.tensorTypeAndShapeInfo().shape
        guard shape.count == 4, shape[1].intValue == 4 else { throw DocAlignerError.unreadable }
        let height: Int = shape[2].intValue
        let width: Int = shape[3].intValue
        let count: Int = 4 * width * height
        let data: NSMutableData = try heatmap.tensorData()
        guard width > 0, height > 0, data.length >= count * MemoryLayout<Float>.size else {
            throw DocAlignerError.unreadable
        }
        var heat: [Float] = [Float](repeating: 0, count: count)
        heat.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Void in
            target.copyMemory(from: UnsafeRawBufferPointer(start: data.bytes, count: count * MemoryLayout<Float>.size))
        }
        let page: QuadCandidate? = CornerHeatmap.decode(heat, width: width, height: height)
        return DocAlignerRun(page: page, ms: ms, coreMLProblem: loaded.coreMLProblem)
    }

    /// The ms of `runs` runs of `model` on `image` after `warmUps` that are not timed, and why Core ML was
    /// not used, if it was asked for and not.
    public func time(_ image: CGImage, model: DocAlignerModel, neuralEngine: Bool, warmUps: Int = 3,
                     runs: Int = 30) throws -> (ms: [Double], coreMLProblem: String?) {
        var index: Int = 0
        while index < warmUps {
            _ = try run(image, model: model, neuralEngine: neuralEngine)
            index += 1
        }
        var times: [Double] = []
        var problem: String?
        index = 0
        while index < runs {
            let timed: DocAlignerRun = try run(image, model: model, neuralEngine: neuralEngine)
            times.append(timed.ms)
            problem = timed.coreMLProblem
            index += 1
        }
        return (times, problem)
    }

    /// The value `share` of the way up `values` once sorted (0.5 the median, 0.9 the 90th percentile), the
    /// nearest one; 0 for none.
    public static func percentile(_ values: [Double], _ share: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted: [Double] = values.sorted()
        let index: Int = Int((share * Double(sorted.count - 1)).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func session(_ model: DocAlignerModel, neuralEngine: Bool) throws -> Loaded {
        let key: String = "\(model.rawValue)-\(neuralEngine)"
        if let kept = sessions[key] {
            return kept
        }
        guard let url = model.url else { throw DocAlignerError.missing(model) }
        let environment: ORTEnv
        if let made = env {
            environment = made
        } else {
            environment = try ORTEnv(loggingLevel: .warning)
            env = environment
        }
        let loaded: Loaded
        if neuralEngine {
            do {
                loaded = Loaded(session: try DocAligner.makeSession(url.path, env: environment, coreML: true),
                                coreMLProblem: nil)
            } catch {
                let session: ORTSession = try DocAligner.makeSession(url.path, env: environment, coreML: false)
                loaded = Loaded(session: session, coreMLProblem: error.localizedDescription)
            }
        } else {
            loaded = Loaded(session: try DocAligner.makeSession(url.path, env: environment, coreML: false),
                            coreMLProblem: nil)
        }
        sessions[key] = loaded
        return loaded
    }

    private static func makeSession(_ path: String, env: ORTEnv, coreML: Bool) throws -> ORTSession {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        if coreML {
            guard ORTIsCoreMLExecutionProviderAvailable() else { throw DocAlignerError.noCoreML }
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.createMLProgram = true
            try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }
        return try ORTSession(env: env, modelPath: path, sessionOptions: options)
    }

    /// `image` stretched over the canvas, its pixels into `input` as blue, green and red planes from 0 to 1.
    private func draw(_ image: CGImage) throws {
        guard let context = canvas, let pixels = context.data else { throw DocAlignerError.unreadable }
        let side: Int = DocAligner.side
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.draw(image, in: rect)
        let bytes: UnsafeMutablePointer<UInt8> = pixels.assumingMemoryBound(to: UInt8.self)
        let planes: UnsafeMutablePointer<Float> = input.mutableBytes.assumingMemoryBound(to: Float.self)
        let plane: Int = side * side
        var index: Int = 0
        while index < plane {
            let at: Int = index * 4
            planes[index] = Float(bytes[at + 2]) / 255
            planes[plane + index] = Float(bytes[at + 1]) / 255
            planes[2 * plane + index] = Float(bytes[at]) / 255
            index += 1
        }
    }
}
#endif
