#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation

/// Which page finder the live outline and the photo import use, a test switch in the camera's drawer
/// until one is kept: Apple's Vision first with our own search behind it (`apple`, the default, as before),
/// our own search alone (`builtIn`), or one of DocAligner's models with our own search behind it. Kept in
/// the user's defaults under `key`; whether DocAligner's models run with Core ML (the Neural Engine) under
/// `neuralEngineKey`, off unless turned on.
public enum PageDetector: String, CaseIterable, Identifiable, Sendable {
    case apple
    case builtIn
    case lc100
    case fastvitT8

    public static let key = "detection.detector"
    public static let neuralEngineKey = "detection.neuralEngine"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: return IOSCameraText.appleDetector
        case .builtIn: return IOSCameraText.builtInDetector
        case .lc100: return DocAlignerModel.lc100.title
        case .fastvitT8: return DocAlignerModel.fastvitT8.title
        }
    }

    /// DocAligner's model this detector runs; nil for Apple's and our own.
    public var model: DocAlignerModel? {
        switch self {
        case .apple, .builtIn: return nil
        case .lc100: return .lc100
        case .fastvitT8: return .fastvitT8
        }
    }

    /// The detector kept in `defaults`; `apple` when none or an unknown one is.
    public static func stored(_ defaults: UserDefaults = .standard) -> PageDetector {
        PageDetector(rawValue: defaults.string(forKey: key) ?? "") ?? .apple
    }

    public static func usesNeuralEngine(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: neuralEngineKey)
    }

    /// `model` on `image` (upright) with the shared runner, on its queue, and the Neural Engine as set; nil
    /// when the model cannot run.
    static func run(_ model: DocAlignerModel, on image: CGImage) -> DocAlignerRun? {
        let engine: Bool = usesNeuralEngine()
        return DocAligner.queue.sync { () -> DocAlignerRun? in
            try? DocAligner.shared.run(image, model: model, neuralEngine: engine)
        }
    }
}
#endif
