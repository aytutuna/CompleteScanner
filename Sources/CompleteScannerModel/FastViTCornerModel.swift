import CompleteScannerKit
import Foundation
import OnnxRuntimeBindings
import os

private let modelLog = Logger(subsystem: "CompleteScanner", category: "CornerModel")

/// Why the corner model did not run.
public enum CornerModelError: Error, Equatable, LocalizedError {
    /// The model's file is not in this build (scripts/fetch_docaligner.sh was not run).
    case missing
    /// This build of ONNX Runtime has no Core ML.
    case noCoreML
    /// The input or the model's answer is not of the shape expected.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missing: return "The page corner model is not in this build"
        case .noCoreML: return "Core ML is not in this build of ONNX Runtime"
        case .unreadable: return "The page corner model's answer could not be read"
        }
    }
}

/// DocAligner's FastViT-T8 corner model (DocsaidLab/DocAligner 1.1.1, Apache-2.0, see
/// Models/DocAligner-LICENSE.txt) on ONNX Runtime: the page finder of the Mac and the iPhone, behind
/// `PhotoImport.plan(_:model:)`. Its file is fetched into this target's Models folder by
/// scripts/fetch_docaligner.sh; without it `isAvailable` is false and `heatmaps` answers nil.
///
/// The session is made on the first run and kept, with all graph optimizations and, when `coreML`, Core ML
/// in front (the Neural Engine where there is one). When Core ML cannot take the model, or fails to run it,
/// the CPU runs it alone from then on; why is kept in `coreMLProblem` and logged once. One run at a time.
public final class FastViTCornerModel: CornerModel, @unchecked Sendable {
    public static let shared = FastViTCornerModel()
    static let fileName: String = "fastvit_t8_h_e_bifpn_256_fp32"

    /// The model's file; nil when it was not fetched. The Mac app made by scripts/make_app.sh carries it in its
    /// own Resources; elsewhere it is in this target's bundle.
    public static let url: URL? = {
        if let packaged = Bundle.main.url(forResource: fileName, withExtension: "onnx") {
            return packaged
        }
        #if os(macOS)
        // SwiftPM's Bundle.module stops the app when its bundle is neither next to the executable nor at the
        // path it was built at (an .app, a copied or moved executable), so the bundle is looked for here: next
        // to the executable, or next to the .xctest bundle under `swift test`.
        let places: [URL] = [Bundle.main.bundleURL,
                             Bundle(for: FastViTCornerModel.self).bundleURL.deletingLastPathComponent()]
        for place in places {
            let bundleURL: URL = place.appendingPathComponent("CompleteScanner_CompleteScannerModel.bundle")
            if let bundle = Bundle(url: bundleURL),
               let found = bundle.url(forResource: fileName, withExtension: "onnx", subdirectory: "Models") {
                return found
            }
        }
        return nil
        #else
        return Bundle.module.url(forResource: fileName, withExtension: "onnx", subdirectory: "Models")
        #endif
    }()

    public static var isAvailable: Bool { url != nil }

    /// The text of a licence in Models by its file's name ("DocAligner-LICENSE", "ONNXRuntime-LICENSE"); nil when
    /// it is not in this build. Outside a packaged Mac app only the iPhone finds it, in this target's bundle.
    public static func licence(_ name: String) -> String? {
        var file: URL? = Bundle.main.url(forResource: name, withExtension: "txt")
        #if !os(macOS)
        if file == nil {
            file = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Models")
        }
        #endif
        guard let file else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Core ML is tried in front of the CPU.
    public let coreML: Bool
    private let lock = NSLock()
    private var env: ORTEnv?
    private var session: ORTSession?
    private var onCoreML: Bool = false
    private var problem: String?

    public init(coreML: Bool = true) {
        self.coreML = coreML
    }

    /// Why Core ML is not used though it was asked for; nil when it is, or before the first run.
    public var coreMLProblem: String? {
        lock.lock()
        defer { lock.unlock() }
        return problem
    }

    public func heatmaps(_ input: [Float]) -> CornerHeatmaps? {
        do {
            return try run(input)
        } catch {
            modelLog.error("Corner model did not run: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The heatmaps for `input` (`CornerModelInput.make`).
    public func run(_ input: [Float]) throws -> CornerHeatmaps {
        let side: Int = CornerModelInput.side
        guard input.count == 3 * side * side else { throw CornerModelError.unreadable }
        lock.lock()
        defer { lock.unlock() }
        let loaded: ORTSession = try loadedSession()
        let data = NSMutableData(length: input.count * MemoryLayout<Float>.size) ?? NSMutableData()
        input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Void in
            if let base = bytes.baseAddress {
                data.replaceBytes(in: NSRange(location: 0, length: bytes.count), withBytes: base)
            }
        }
        let shape: [NSNumber] = [1, 3, NSNumber(value: side), NSNumber(value: side)]
        let value = try ORTValue(tensorData: data, elementType: .float, shape: shape)
        let outputs: [String: ORTValue]
        do {
            outputs = try loaded.run(withInputs: ["img": value], outputNames: ["heatmap"], runOptions: nil)
        } catch where onCoreML {
            let cpu: ORTSession = try cpuSession(after: error)
            outputs = try cpu.run(withInputs: ["img": value], outputNames: ["heatmap"], runOptions: nil)
        }
        guard let heatmap = outputs["heatmap"] else { throw CornerModelError.unreadable }
        let dims: [NSNumber] = try heatmap.tensorTypeAndShapeInfo().shape
        guard dims.count == 4, dims[1].intValue == 4 else { throw CornerModelError.unreadable }
        let height: Int = dims[2].intValue
        let width: Int = dims[3].intValue
        let count: Int = 4 * width * height
        let answer: NSMutableData = try heatmap.tensorData()
        guard width > 0, height > 0, answer.length >= count * MemoryLayout<Float>.size else {
            throw CornerModelError.unreadable
        }
        var values: [Float] = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Void in
            target.copyMemory(from: UnsafeRawBufferPointer(start: answer.bytes, count: count * MemoryLayout<Float>.size))
        }
        return CornerHeatmaps(values: values, width: width, height: height)
    }

    private func loadedSession() throws -> ORTSession {
        if let kept = session {
            return kept
        }
        guard let url = FastViTCornerModel.url else { throw CornerModelError.missing }
        let environment: ORTEnv
        if let made = env {
            environment = made
        } else {
            environment = try ORTEnv(loggingLevel: .warning)
            env = environment
        }
        if coreML {
            do {
                let made: ORTSession = try FastViTCornerModel.makeSession(url.path, env: environment, coreML: true)
                session = made
                onCoreML = true
                return made
            } catch {
                return try cpuSession(after: error)
            }
        }
        let made: ORTSession = try FastViTCornerModel.makeSession(url.path, env: environment, coreML: false)
        session = made
        return made
    }

    /// The CPU's session in place of Core ML's, which failed with `error`.
    private func cpuSession(after error: Error) throws -> ORTSession {
        guard let url = FastViTCornerModel.url, let environment = env else { throw CornerModelError.missing }
        let made: ORTSession = try FastViTCornerModel.makeSession(url.path, env: environment, coreML: false)
        session = made
        onCoreML = false
        problem = error.localizedDescription
        modelLog.notice("Corner model runs on the CPU, Core ML failed: \(error.localizedDescription, privacy: .public)")
        return made
    }

    private static func makeSession(_ path: String, env: ORTEnv, coreML: Bool) throws -> ORTSession {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        // As timed on the iPhone (22 ms on the CPU, 10 ms with Core ML).
        try options.setIntraOpNumThreads(2)
        if coreML {
            guard ORTIsCoreMLExecutionProviderAvailable() else { throw CornerModelError.noCoreML }
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.createMLProgram = true
            try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }
        return try ORTSession(env: env, modelPath: path, sessionOptions: options)
    }
}
