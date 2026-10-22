#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI

/// Where the ID card's guide frame sits on the camera's screen (I13): an outline of the ID-1 card's shape
/// (85.60 × 53.98 mm), centered, as wide as `widthShare` of the screen, or as tall as `heightShare` of it
/// where the screen is short (an iPhone held sideways), never wider than the screen allows. The card held to
/// fill it is close enough to be sharp and real-sized; the shot itself finds the card wherever it is.
public enum IOSIdCardGuide {
    /// The card's long side over its short side (`MultiQuadPicker.idCardLongOverShort`).
    public static let aspect: Double = MultiQuadPicker.idCardLongOverShort
    /// The frame's width as a share of the screen's.
    public static let widthShare: Double = 0.86
    /// The frame's height as a share of the screen's, at most.
    public static let heightShare: Double = 0.6

    /// The frame in a screen of `size` (points, top-left origin).
    public static func frame(in size: CGSize) -> CGRect {
        let width: Double = Double(size.width)
        let height: Double = Double(size.height)
        guard width > 0, height > 0 else { return CGRect.zero }
        var frameWidth: Double = width * widthShare
        var frameHeight: Double = frameWidth / aspect
        let tallest: Double = height * heightShare
        if frameHeight > tallest {
            frameHeight = tallest
            frameWidth = frameHeight * aspect
        }
        return CGRect(x: (width - frameWidth) / 2, y: (height - frameHeight) / 2, width: frameWidth, height: frameHeight)
    }

    /// What the camera asks for at the ID card's step: the front, or the back; nil at any other step.
    public static func prompt(stepID: String?) -> String? {
        guard let side = IdCardSteps.sideOf(stepID) else { return nil }
        return side == .front ? IOSReviewText.cardFrontPrompt : IOSReviewText.cardBackPrompt
    }

    /// The glare hint the camera shows for the side just taken: while the back is next, when the front was
    /// taken with glare on it (its note ends with `GlareDetector.hint`, `CaptureObjects.cardNote`); nil otherwise.
    public static func glareLine(stepID: String?, frontNote: String?) -> String? {
        guard stepID == IdCardSteps.backStepID, let note = frontNote, note.hasSuffix(GlareDetector.hint) else { return nil }
        return GlareDetector.hint
    }
}

/// The ID card's guide frame drawn over the camera's preview: a rounded outline of the card's shape with the
/// side to take above it ("Fit the front in the frame"). It takes no touches.
struct IdCardGuide: View {
    let prompt: String

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            let frame: CGRect = IOSIdCardGuide.frame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Text(prompt)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .frame(width: frame.width)
                    .offset(x: frame.minX, y: max(0, frame.minY - 44))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(IOSReviewText.guideName))
        .accessibilityValue(Text(prompt))
        .accessibilityIdentifier("camera.cardGuide")
    }
}
#endif
