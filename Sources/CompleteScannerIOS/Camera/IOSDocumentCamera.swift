#if os(iOS)
import AVFoundation
import CompleteScannerKit
import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import VisionKit

/// Whether Apple's document scanner can be opened here, and if not, why (one short line).
public enum IOSCameraAvailability: Equatable, Sendable {
    /// It can be opened (asking for the camera the first time, as iOS does).
    case available
    /// This device has no document camera (the Simulator, an iPad without one).
    case noCamera
    /// The user turned camera access off for this app in Settings.
    case denied
    /// Camera access is not allowed here (Screen Time or a device profile).
    case restricted

    /// From the scanner's own check (`VNDocumentCameraViewController.isSupported`) and the camera
    /// permission (`AVCaptureDevice.authorizationStatus(for: .video)`).
    public static func resolve(isSupported: Bool, authorization: AVAuthorizationStatus) -> IOSCameraAvailability {
        if !isSupported { return .noCamera }
        switch authorization {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .available
        }
    }

    /// This device, now.
    @MainActor
    public static var current: IOSCameraAvailability {
        resolve(isSupported: VNDocumentCameraViewController.isSupported,
                authorization: AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Our own camera (`CameraScreen`) on this device, now: a camera to capture with
    /// (`IOSCameraLens.hasCamera`; none in the Simulator) and the camera permission.
    @MainActor
    public static var ownCamera: IOSCameraAvailability {
        resolve(isSupported: IOSCameraLens.hasCamera, authorization: AVCaptureDevice.authorizationStatus(for: .video))
    }

    public var isAvailable: Bool { self == .available }

    /// Why the camera cannot be used: the line under the dimmed Camera button; nil when it can.
    public var reason: String? {
        switch self {
        case .available: return nil
        case .noCamera: return "No camera here"
        case .denied: return "Camera access is off"
        case .restricted: return "Camera not allowed"
        }
    }

    /// Settings can turn camera access back on.
    public var opensSettings: Bool { self == .denied }
}

/// Apple's document scanner (VisionKit) as the Document, Email and Word tasks' camera: it finds the page,
/// takes it when steady and hands back each page upright and cropped. It gives no corners and no
/// original photo, so each page comes in whole, sized by its shape (`CaptureScale.fromAspect`).
public enum IOSDocumentCamera {
    /// The tasks whose cards open Apple's scanner.
    public static let tasks: [ScanTask] = [.document, .email, .word]

    /// The scanner's pages as pages of the queue: each a color page from a photo at the resolution its
    /// shape gives (`CaptureScale.fromAspect`: A4, Letter, Legal or an ID card within 3 %, else 200
    /// dpi), with capture facts saying it was taken whole and is measured already (the whole picture as
    /// its corners, the scale set), so the clean-up stage does not cut it again.
    public static func pages(_ images: [CGImage], createdAt: Date = Date()) -> [ScannedPage] {
        var pages: [ScannedPage] = []
        for image in images {
            let width: Int = image.width
            let height: Int = image.height
            guard width > 0, height > 0 else { continue }
            let scale: CaptureScaleResult = CaptureScale.fromAspect(pixelWidth: width, pixelHeight: height, kind: .document)
            let facts = CaptureFacts(quad: PhotoImport.wholePhoto(width: width, height: height), sourceWidth: width,
                                     sourceHeight: height, kind: .document, focalLength: nil, scale: scale)
            var page: ScannedPage = ScannedPage(image: image, dpi: scale.dpi, colorMode: .color, createdAt: createdAt)
                .withCapture(facts)
            page.source = .photo
            pages.append(page)
        }
        return pages
    }

    /// `image`'s pixels the right way up: its own picture when it is upright, else drawn upright at its
    /// full pixel size.
    public static func uprightImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let drawn: UIImage = renderer.image { (_: UIGraphicsImageRendererContext) -> Void in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        return drawn.cgImage
    }
}

/// Apple's document scanner in a full-screen cover. `onFinish` gets the pages taken (upright), in order;
/// `onCancel` runs when the user closes it without saving, `onFail` with the error it reports.
struct DocumentCameraView: UIViewControllerRepresentable {
    let onFinish: @MainActor ([CGImage]) -> Void
    let onCancel: @MainActor () -> Void
    let onFail: @MainActor (String) -> Void

    func makeCoordinator() -> DocumentCameraCoordinator {
        DocumentCameraCoordinator(onFinish: onFinish, onCancel: onCancel, onFail: onFail)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
}

/// The scanner's delegate: the pages read one at a time as upright pictures.
final class DocumentCameraCoordinator: NSObject, VNDocumentCameraViewControllerDelegate {
    private let onFinish: @MainActor ([CGImage]) -> Void
    private let onCancel: @MainActor () -> Void
    private let onFail: @MainActor (String) -> Void

    init(onFinish: @escaping @MainActor ([CGImage]) -> Void, onCancel: @escaping @MainActor () -> Void,
         onFail: @escaping @MainActor (String) -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onFail = onFail
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFinishWith scan: VNDocumentCameraScan) {
        var images: [CGImage] = []
        var index: Int = 0
        while index < scan.pageCount {
            let page: UIImage = scan.imageOfPage(at: index)
            if let upright = IOSDocumentCamera.uprightImage(page) {
                images.append(upright)
            }
            index += 1
        }
        let finish: @MainActor ([CGImage]) -> Void = onFinish
        let taken: [CGImage] = images
        Task { @MainActor in
            finish(taken)
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        let cancel: @MainActor () -> Void = onCancel
        Task { @MainActor in
            cancel()
        }
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        let fail: @MainActor (String) -> Void = onFail
        let message: String = error.localizedDescription
        Task { @MainActor in
            fail(message)
        }
    }
}
#endif
