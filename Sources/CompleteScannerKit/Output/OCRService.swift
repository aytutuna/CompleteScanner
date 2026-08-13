import CoreGraphics
import Foundation
import Vision

/// One recognized line of text on a scanned page.
public struct OCRLine {
    public let text: String
    /// Vision-normalized bounding box (origin bottom-left).
    public let boundingBox: CGRect
    public let confidence: Float
    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public enum OCRService {
    /// Run accurate text recognition over `image` and return one OCRLine per observation
    /// (top candidate). Throws `ScanError.scanFailed` when the Vision handler fails.
    ///
    /// Recognition is universal: Vision detects the language(s) on the page itself, so no
    /// configuration is required. The `languages` parameter is kept for API stability but
    /// no longer constrains recognition.
    public static func recognizeLines(in image: CGImage, languages: [String] = []) throws -> [OCRLine] {
        _ = languages
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Offer every language Vision knows so mixed-language and non-Latin pages
        // recognize too; automatic detection narrows per page.
        if let supported = try? request.supportedRecognitionLanguages(), !supported.isEmpty {
            request.recognitionLanguages = supported
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScanError.scanFailed("OCR failed: \(error.localizedDescription)")
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string,
                           boundingBox: observation.boundingBox,
                           confidence: candidate.confidence)
        }
    }

}
