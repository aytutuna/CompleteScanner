#if os(iOS)
import AVFoundation
import CompleteScannerKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// The camera's live frames for the page outline: each BGRA frame of the video output made small
/// (`IOSFrameScaler`, at most `LiveQuadTracker.analysisLongSide` px) and handed to the tracker on the
/// frames' own queue. Frames that come sooner than `LiveQuadTracker.minFrameGapMs` after the last one
/// handed over are passed over before any work, and the video output drops frames while one is being
/// searched (`alwaysDiscardsLateVideoFrames`), so the work per second stays bounded.
final class IOSFrameFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (IOSCameraFrame) -> Void)?
    private var lastMs: Double?

    func startFrames(_ deliver: @escaping @Sendable (IOSCameraFrame) -> Void) {
        lock.lock()
        self.deliver = deliver
        lastMs = nil
        lock.unlock()
    }

    func stopFrames() {
        lock.lock()
        deliver = nil
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let time: CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds: Double = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        let ms: Double = seconds * 1000.0
        lock.lock()
        let handler: (@Sendable (IOSCameraFrame) -> Void)? = deliver
        var due: Bool = handler != nil
        if let last = lastMs, ms >= last, ms - last < LiveQuadTracker.minFrameGapMs {
            due = false
        }
        if due {
            lastMs = ms
        }
        lock.unlock()
        guard due, let send = handler, let image = IOSFrameFeed.image(sampleBuffer) else { return }
        send(IOSCameraFrame(image: image, timestampMs: ms))
    }

    /// The frame's pixels made small; nil when it is not a BGRA frame.
    static func image(_ sampleBuffer: CMSampleBuffer) -> RgbaImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width: Int = CVPixelBufferGetWidth(pixelBuffer)
        let height: Int = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: bytesPerRow * height)
        return IOSFrameScaler.downscaled(bgra: bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                                         maxLongSide: LiveQuadTracker.analysisLongSide)
    }
}

/// Waits for one photo: its file's bytes once the camera has written them, handed over once.
final class IOSPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Data?) -> Void
    private var data: Data?
    private var finished: Bool = false

    init(completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil {
            data = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard !finished else { return }
        finished = true
        completion(data)
    }
}

/// The capture session and its outputs; every method here runs on `queue` (the controller sends them
/// there), so the session is set up, started and stopped off the main thread.
final class IOSCaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "CompleteScanner.camera.session")
    let feed = IOSFrameFeed()
    private let frameQueue = DispatchQueue(label: "CompleteScanner.camera.frames", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?
    private var configured: Bool = false
    private var pending: [Int64: IOSPhotoDelegate] = [:]

    /// Sets the session up once: the camera `IOSCameraLens` picks, photos of about 12 MP at most at the
    /// best quality, and BGRA video frames for the outline (the camera works without them when the
    /// session cannot add them). False when there is no camera or it cannot be used.
    func configure() -> Bool {
        if configured { return device != nil }
        configured = true
        guard let camera = IOSCameraLens.bestDevice() else { return false }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            return false
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        let format: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)]
        videoOutput.videoSettings = format
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(feed, queue: frameQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
        // The photo size is one the format chosen for the preset offers.
        if let dimensions = IOSCameraLens.photoDimensions(camera) {
            session.beginConfiguration()
            photoOutput.maxPhotoDimensions = dimensions
            session.commitConfiguration()
        }
        IOSCaptureSession.focusForPages(camera)
        IOSCaptureSession.zoomForPages(camera)
        device = camera
        return true
    }

    /// The wide lens's view on a virtual camera whose zoom 1 is the ultra wide lens (`IOSCameraLens.startZoom`);
    /// its lens switching stays automatic, so a page held close still gets the lens that can focus on it.
    static func zoomForPages(_ camera: AVCaptureDevice) {
        var factors: [Double] = []
        for factor in camera.virtualDeviceSwitchOverVideoZoomFactors {
            factors.append(factor.doubleValue)
        }
        let lowest: Double = Double(camera.minAvailableVideoZoomFactor)
        let highest: Double = min(Double(camera.maxAvailableVideoZoomFactor), Double(camera.activeFormat.videoMaxZoomFactor))
        let zoom: Double = IOSCameraLens.startZoom(kind: IOSCameraLens.kind(camera.deviceType), switchOverFactors: factors,
                                                   minZoom: lowest, maxZoom: highest)
        let wanted: CGFloat = CGFloat(zoom)
        guard wanted != camera.videoZoomFactor else { return }
        do {
            try camera.lockForConfiguration()
        } catch {
            return
        }
        camera.videoZoomFactor = wanted
        camera.unlockForConfiguration()
    }

    /// Focus that keeps adjusting, kept to near things where the camera allows it (a page held over).
    static func focusForPages(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
        } catch {
            return
        }
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isAutoFocusRangeRestrictionSupported {
            camera.autoFocusRangeRestriction = .near
        }
        camera.unlockForConfiguration()
    }

    func start() {
        if !session.isRunning {
            session.startRunning()
            // Set again once running, in case the session chose the camera's format afresh on starting.
            if let camera = device {
                IOSCaptureSession.zoomForPages(camera)
            }
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    var hasTorch: Bool {
        guard let camera = device else { return false }
        return camera.hasTorch && camera.isTorchModeSupported(.on)
    }

    /// Turns the torch on or off; whether it is on afterwards.
    func setTorch(_ on: Bool) -> Bool {
        guard let camera = device, camera.hasTorch else { return false }
        let mode: AVCaptureDevice.TorchMode = on ? .on : .off
        guard camera.isTorchModeSupported(mode), !on || camera.isTorchAvailable else {
            return camera.torchMode == .on
        }
        do {
            try camera.lockForConfiguration()
        } catch {
            return camera.torchMode == .on
        }
        camera.torchMode = mode
        camera.unlockForConfiguration()
        return on
    }

    /// Takes a photo turned by `rotationAngle` (the capture's angle; nil leaves the connection as it is):
    /// HEIC where the camera writes it, else JPEG, at the session's photo size and best quality.
    /// `completion` gets its file's bytes, or nil.
    func capture(rotationAngle: CGFloat?, completion: @escaping @Sendable (Data?) -> Void) {
        guard session.isRunning, let connection = photoOutput.connection(with: .video), connection.isEnabled,
              connection.isActive else {
            completion(nil)
            return
        }
        if let angle = rotationAngle, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        let id: Int64 = settings.uniqueID
        let delegate = IOSPhotoDelegate { [weak self] (data: Data?) -> Void in
            if let box = self {
                box.queue.async {
                    box.pending[id] = nil
                }
            }
            completion(data)
        }
        // The output holds its delegate weakly: kept here until the photo is in.
        pending[id] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }
}

/// Notification observers, removed from their center when this goes (with the controller).
final class IOSObserverTokens: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

/// Our own camera on a device (`IOSCameraDriving`): the capture session (`IOSCaptureSession`) driven
/// from the main actor, the preview's and the photo's turn from `AVCaptureDevice.RotationCoordinator`
/// (the photo is taken level with the horizon however the phone is held; the preview turns with the
/// screen), and the session's interruptions and errors as `IOSCameraEvent`s.
@MainActor
public final class IOSCameraController: IOSCameraDriving {
    let capture = IOSCaptureSession()
    public var onEvent: (@MainActor (IOSCameraEvent) -> Void)?
    public private(set) var hasTorch: Bool = false
    private let center: NotificationCenter
    private let observers: IOSObserverTokens
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var prepared: Bool = false

    public init(center: NotificationCenter = .default) {
        self.center = center
        self.observers = IOSObserverTokens(center: center)
    }

    /// The session the preview shows.
    public var session: AVCaptureSession { capture.session }

    public var frameSource: FrameSource? { capture.feed }

    public func prepare() async -> Bool {
        let box: IOSCaptureSession = capture
        let ready: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
            box.queue.async {
                continuation.resume(returning: box.configure())
            }
        }
        if ready && !prepared {
            prepared = true
            hasTorch = box.hasTorch
            observeSession()
            attachRotation()
        }
        return ready
    }

    public func startRunning() {
        let box: IOSCaptureSession = capture
        box.queue.async {
            box.start()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.applyPreviewRotation()
                }
            }
        }
    }

    public func stopRunning() {
        let box: IOSCaptureSession = capture
        box.queue.async {
            box.stop()
        }
    }

    public func setTorch(_ on: Bool) async -> Bool {
        let box: IOSCaptureSession = capture
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
            box.queue.async {
                continuation.resume(returning: box.setTorch(on))
            }
        }
    }

    public func takePhoto() async -> IOSCameraPhoto? {
        let box: IOSCaptureSession = capture
        var angle: CGFloat?
        if let coordinator = rotation {
            angle = coordinator.videoRotationAngleForHorizonLevelCapture
        }
        let wanted: CGFloat? = angle
        let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) -> Void in
            box.queue.async {
                box.capture(rotationAngle: wanted) { (taken: Data?) -> Void in
                    continuation.resume(returning: taken)
                }
            }
        }
        guard let bytes = data else { return nil }
        var degrees: Int?
        if let turn = wanted {
            degrees = Int(Double(turn).rounded())
        }
        let front: Bool = box.device?.position == .front
        return IOSCameraPhoto(data: bytes, rotationDegrees: degrees, mirrored: front)
    }

    /// The preview's layer, once its view is made: it shows the session and turns with the screen.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        if previewLayer !== layer {
            // A new preview: its turn comes from a coordinator of its own.
            rotationObservation = nil
            rotation = nil
        }
        previewLayer = layer
        layer.session = capture.session
        layer.videoGravity = .resizeAspectFill
        attachRotation()
    }

    // MARK: Turning

    private func attachRotation() {
        guard rotation == nil, let camera = capture.device, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: layer)
        rotation = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
            [weak self] (_: AVCaptureDevice.RotationCoordinator, _: NSKeyValueObservedChange<CGFloat>) -> Void in
            guard let controller = self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    controller.applyPreviewRotation()
                }
            }
        }
        applyPreviewRotation()
    }

    private func applyPreviewRotation() {
        guard let coordinator = rotation, let connection = previewLayer?.connection else { return }
        let angle: CGFloat = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: Interruptions and errors

    private func observeSession() {
        let observed: AVCaptureSession = capture.session
        let interrupted: NSObjectProtocol = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                               object: observed, queue: .main) {
            [weak self] (note: Notification) -> Void in
            let event: IOSCameraEvent = IOSCameraController.interruptionEvent(note)
            MainActor.assumeIsolated {
                self?.onEvent?(event)
            }
        }
        let ended: NSObjectProtocol = center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                         object: observed, queue: .main) {
            [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.onEvent?(IOSCameraEvent.interruptionEnded)
            }
        }
        let failed: NSObjectProtocol = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                          object: observed, queue: .main) {
            [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.onEvent?(IOSCameraEvent.runtimeError)
            }
        }
        observers.add(interrupted)
        observers.add(ended)
        observers.add(failed)
    }

    /// The interruption a session's notification reports.
    nonisolated static func interruptionEvent(_ note: Notification) -> IOSCameraEvent {
        var why: IOSCameraInterruption = .other
        if let number = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber,
           let reason = AVCaptureSession.InterruptionReason(rawValue: number.intValue) {
            why = IOSCameraInterruption.from(reason)
        }
        return IOSCameraEvent.interrupted(why)
    }

    deinit {
        let box: IOSCaptureSession = capture
        box.queue.async {
            box.stop()
        }
    }
}
#endif
