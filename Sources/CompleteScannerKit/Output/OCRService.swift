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
    public static func recognizeLines(in image: CGImage, languages: [String]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        applyLanguages(languages, to: request)

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

    /// Set the requested recognition languages, silently dropping any the request
    /// does not support (and leaving Vision's defaults when none are supported).
    private static func applyLanguages(_ languages: [String], to request: VNRecognizeTextRequest) {
        guard !languages.isEmpty else { return }
        if let supported = try? request.supportedRecognitionLanguages() {
            let usable = languages.filter { supported.contains($0) }
            if !usable.isEmpty { request.recognitionLanguages = usable }
        } else {
            request.recognitionLanguages = languages
        }
    }
}
