#if os(iOS)
import AVFoundation
import CompleteScannerKit
import SwiftUI
import UIKit
import Vision
import VisionKit

/// The camera looking for the computer's pairing code (its QR code): VisionKit's live scanner where this
/// device has it, else the camera's own QR reader (AVCaptureMetadataOutput). The first text read that is
/// a pairing code (`isPairingCode`) is handed to `onCode`, once. Camera access is asked for the first
/// time, as our camera asks (`IOSCameraAvailability`); without a camera (the Simulator) or access, one
/// line says why, and the pairing text is entered below instead.
struct PairingScannerView: View {
    let onCode: @MainActor (String) -> Void
    @State private var availability: IOSCameraAvailability?

    var body: some View {
        Group {
            if let shown = availability {
                if shown.isAvailable {
                    if PairingScannerView.usesDataScanner {
                        PairingDataScanner(onCode: onCode)
                    } else {
                        PairingCaptureScanner(onCode: onCode)
                    }
                } else {
                    unavailable(shown)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("companion.scanner")
        .task {
            availability = await PairingScannerView.cameraAvailability()
        }
    }

    private func unavailable(_ shown: IOSCameraAvailability) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
            Text(shown.reason ?? "")
                .font(.headline)
                .foregroundStyle(Color.white)
                .accessibilityIdentifier("companion.scanner.message")
            if shown.opensSettings {
                Button(IOSNetworkText.settingsButton) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("companion.scanner.settings")
            }
        }
        .padding(16)
    }

    /// VisionKit's scanner can run here now (it needs camera access too).
    @MainActor
    static var usesDataScanner: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// Whether this device can look for codes, asking for camera access when it never was.
    @MainActor
    static func cameraAvailability() async -> IOSCameraAvailability {
        let found: Bool = DataScannerViewController.isSupported || IOSCameraLens.hasCamera
        var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if found && status == .notDetermined {
            let granted: Bool = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
        }
        return IOSCameraAvailability.resolve(isSupported: found, authorization: status)
    }

    /// A text read from a QR code that is a CompleteScanner pairing code.
    static func isPairingCode(_ text: String) -> Bool {
        text.lowercased().hasPrefix(PairingUri.prefix)
    }
}

/// VisionKit's live scanner, for QR codes only.
private struct PairingDataScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner: DataScannerViewController = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                                           qualityLevel: .balanced,
                                                                           recognizesMultipleItems: false,
                                                                           isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Void
        private var handed: Bool = false

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !handed, case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                      PairingScannerView.isPairingCode(text) else { continue }
                handed = true
                onCode(text)
            }
        }
    }
}

/// The camera's own QR reader, where VisionKit's scanner is not supported.
private struct PairingCaptureScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> PairingCaptureController {
        PairingCaptureController(onCode: onCode)
    }

    func updateUIViewController(_ controller: PairingCaptureController, context: Context) {
        controller.onCode = onCode
    }
}

/// The capture session, started and stopped off the main thread as AVFoundation asks.
private final class PairingCaptureSession: @unchecked Sendable {
    let session: AVCaptureSession = AVCaptureSession()
    let queue: DispatchQueue = DispatchQueue(label: "CompleteScanner.pairing.camera")

    func start() {
        queue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

private final class PairingCaptureController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: @MainActor (String) -> Void
    private let capture: PairingCaptureSession = PairingCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handed: Bool = false

    init(onCode: @escaping @MainActor (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        let session: AVCaptureSession = capture.session
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output: AVCaptureMetadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        // Only once the output is in the session does it offer QR codes.
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        let layer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        capture.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        capture.stop()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        var texts: [String] = []
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                texts.append(text)
            }
        }
        MainActor.assumeIsolated {
            self.read(texts)
        }
    }

    private func read(_ texts: [String]) {
        for text in texts where !handed && PairingScannerView.isPairingCode(text) {
            handed = true
            onCode(text)
        }
    }
}
#endif
