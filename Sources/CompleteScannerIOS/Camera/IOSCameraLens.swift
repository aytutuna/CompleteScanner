#if os(iOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// The kinds of camera iOS offers, in the order the camera picks them after the preferred ones.
public enum IOSLensKind: Int, CaseIterable, Sendable {
    /// The virtual camera of three lenses (Pro models): it switches to the ultra wide lens for a close page.
    case triple
    /// The virtual camera of the wide and ultra wide lenses: it switches for a close page too.
    case dualWide
    /// The virtual camera of the wide and telephoto lenses.
    case dual
    /// The wide lens alone, which every iPhone has.
    case wide
    case ultraWide
    case telephoto
    case trueDepth
    case other
}

/// Which side of the device a camera faces.
public enum IOSLensPosition: Equatable, Sendable {
    case back
    case front
    case unspecified
}

/// A camera the device has, as the choice sees it.
public struct IOSLensOption: Equatable, Sendable {
    public let kind: IOSLensKind
    public let position: IOSLensPosition

    public init(kind: IOSLensKind, position: IOSLensPosition) {
        self.kind = kind
        self.position = position
    }
}

/// A photo size the camera can take, in pixels.
public struct IOSPhotoSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixels: Int { width * height }
}

/// Which camera our own camera uses and how large its photos are. The camera is the virtual one that
/// switches lenses by itself (three lenses, then the wide pair, as `preferred` says), so a page held close
/// is taken with the lens that can focus on it; then the wide lens; then whatever the device has, a back
/// camera before any other. A virtual camera with the ultra wide lens starts at the wide lens's zoom
/// (`startZoom`), since its zoom 1 is the ultra wide lens's view. Photos are taken at the size picked among
/// those the camera offers (`choices`, kept on the device under `megapixelsKey`), else at 24 MP where the
/// camera offers it and 12 MP where it does not (`photoSize`): 24 MP already resolves a page filling the
/// frame at over 400 dpi, and a page is cut out and cleaned up with several copies of the photo's pixels in
/// memory at once (`processingBytes`), which a 48 MP photo may not fit on a phone with 6 GB (`warns`).
public enum IOSCameraLens {
    /// The cameras picked first, in order.
    public static let preferred: [IOSLensKind] = [.triple, .dualWide, .wide]
    /// Where the photo size picked is kept, as its whole megapixels (`megapixels`); none or 0: the default.
    public static let megapixelsKey: String = "camera.megapixels"
    /// The size taken when none is picked, where the camera offers it.
    public static let defaultMegapixels: Int = 24
    /// Else the largest size of at most this: 4032 × 3024 (12.2 MP). No smaller size is offered.
    public static let basePixels: Int = 12_600_000
    /// What a page takes in memory while it is cut out and cleaned up, per pixel of its photo: about four
    /// RGBA copies at once.
    public static let processingBytesPerPixel: Int = 16

    /// How good a choice `option` is: lower is better (the preferred kinds first, in order, then the other
    /// kinds; any camera that does not face back after every one that does).
    public static func rank(_ option: IOSLensOption) -> Int {
        var rank: Int
        if let index = preferred.firstIndex(of: option.kind) {
            rank = index
        } else {
            rank = preferred.count + option.kind.rawValue
        }
        if option.position != .back {
            rank += 100
        }
        return rank
    }

    /// The index of the camera to use among `options` (the first of the best on a tie); nil for none.
    public static func choose(_ options: [IOSLensOption]) -> Int? {
        var best: Int?
        var bestRank: Int = Int.max
        var index: Int = 0
        while index < options.count {
            let rank: Int = IOSCameraLens.rank(options[index])
            if rank < bestRank {
                bestRank = rank
                best = index
            }
            index += 1
        }
        return best
    }

    /// The size's whole megapixels, rounded down as Apple names them: 12 for 4032 × 3024 (12.2), 24 for
    /// 5712 × 4284 (24.5), 48 for 8064 × 6048 (48.8).
    public static func megapixels(_ size: IOSPhotoSize) -> Int {
        size.pixels / 1_000_000
    }

    /// The sizes offered to pick from among those the camera takes, smallest first: one for each whole
    /// megapixels (the largest of them), none under the largest of at most `basePixels` (the sizes of the
    /// camera's small video formats).
    public static func choices(_ supported: [IOSPhotoSize]) -> [IOSPhotoSize] {
        var base: Int = 0
        for size in supported where size.width > 0 && size.height > 0 && size.pixels <= basePixels {
            base = max(base, size.pixels)
        }
        var result: [IOSPhotoSize] = []
        for size in supported where size.width > 0 && size.height > 0 && size.pixels >= base {
            if let index = result.firstIndex(where: { (kept: IOSPhotoSize) -> Bool in megapixels(kept) == megapixels(size) }) {
                if size.pixels > result[index].pixels {
                    result[index] = size
                }
            } else {
                result.append(size)
            }
        }
        result.sort { (a: IOSPhotoSize, b: IOSPhotoSize) -> Bool in a.pixels < b.pixels }
        return result
    }

    /// The photo size to take among those the camera offers (`choices`): the one of `megapixels` picked,
    /// else 24 MP (`defaultMegapixels`), else the smallest offered, 12 MP on every iPhone; nil when none is
    /// offered. A size picked on another phone that this one does not offer gets the default.
    public static func photoSize(_ supported: [IOSPhotoSize], megapixels picked: Int = 0) -> IOSPhotoSize? {
        let offered: [IOSPhotoSize] = choices(supported)
        if picked > 0, let size = offered.first(where: { (size: IOSPhotoSize) -> Bool in megapixels(size) == picked }) {
            return size
        }
        if let size = offered.first(where: { (size: IOSPhotoSize) -> Bool in megapixels(size) == defaultMegapixels }) {
            return size
        }
        return offered.first
    }

    /// The size after `current` among `choices` (smallest first), back to the first after the last; nil
    /// for none.
    public static func nextChoice(after current: IOSPhotoSize, in choices: [IOSPhotoSize]) -> IOSPhotoSize? {
        guard !choices.isEmpty else { return nil }
        guard let index = choices.firstIndex(of: current) else { return choices[0] }
        return choices[(index + 1) % choices.count]
    }

    /// The memory a page from a photo of `size` takes at most while it is cut out and cleaned up: about
    /// 195 MB at 12 MP, 390 MB at 24 MP, 780 MB at 48 MP.
    public static func processingBytes(_ size: IOSPhotoSize) -> Int {
        size.pixels * processingBytesPerPixel
    }

    /// The memory the device reports, in whole gigabytes (iOS reports a little less than the phone has).
    public static func gigabytes(_ physicalMemory: UInt64) -> Int {
        Int((Double(physicalMemory) / 1_000_000_000).rounded())
    }

    /// A page from a photo of `size` may take more memory than iOS leaves the app on a device with
    /// `physicalMemory`: more than an eighth of it (counted in whole gigabytes, as the warning says), so
    /// 48 MP warns on a 6 GB phone and not on an 8 GB one.
    public static func warns(_ size: IOSPhotoSize, physicalMemory: UInt64) -> Bool {
        processingBytes(size) * 8 > gigabytes(physicalMemory) * 1_000_000_000
    }

    /// The largest of `choices` that does not `warn`; nil when every one does.
    public static func saferSize(among choices: [IOSPhotoSize], physicalMemory: UInt64) -> IOSPhotoSize? {
        var safer: IOSPhotoSize?
        for size in choices where !warns(size, physicalMemory: physicalMemory) {
            if let current = safer, current.pixels >= size.pixels { continue }
            safer = size
        }
        return safer
    }

    /// The zoom the camera of `kind` starts at, kept within `minZoom...maxZoom` (what the camera allows
    /// now, never below 1). On a virtual camera with the ultra wide lens (`.triple`, `.dualWide`) zoom 1
    /// is the ultra wide lens's view and the wide lens takes over at the first of its switch-over factors
    /// (`virtualDeviceSwitchOverVideoZoomFactors`, 2 on an iPhone), so it starts there: the wide lens's
    /// view, from which the camera still switches to the ultra wide lens by itself for a page held close.
    /// Every other camera, and one that reports no switch-over factor above 1, starts at 1.
    public static func startZoom(kind: IOSLensKind, switchOverFactors: [Double], minZoom: Double = 1,
                                 maxZoom: Double = Double.greatestFiniteMagnitude) -> Double {
        var zoom: Double = 1
        if kind == .triple || kind == .dualWide, let first = switchOverFactors.first, first.isFinite, first > 1 {
            zoom = first
        }
        let lowest: Double = minZoom.isFinite ? max(minZoom, 1) : 1
        var highest: Double = maxZoom.isNaN ? lowest : maxZoom
        if highest < lowest {
            highest = lowest
        }
        return min(max(zoom, lowest), highest)
    }

    // MARK: The device's cameras

    /// The kinds of camera looked for.
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera,
    ]

    static func kind(_ type: AVCaptureDevice.DeviceType) -> IOSLensKind {
        if type == .builtInTripleCamera { return .triple }
        if type == .builtInDualWideCamera { return .dualWide }
        if type == .builtInDualCamera { return .dual }
        if type == .builtInWideAngleCamera { return .wide }
        if type == .builtInUltraWideCamera { return .ultraWide }
        if type == .builtInTelephotoCamera { return .telephoto }
        if type == .builtInTrueDepthCamera { return .trueDepth }
        return .other
    }

    static func position(_ position: AVCaptureDevice.Position) -> IOSLensPosition {
        switch position {
        case .back: return .back
        case .front: return .front
        default: return .unspecified
        }
    }

    /// The cameras this device has (none in the Simulator).
    static func devices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        return discovery.devices
    }

    /// The camera to use (`choose`); nil when the device has none.
    static func bestDevice() -> AVCaptureDevice? {
        let found: [AVCaptureDevice] = devices()
        var options: [IOSLensOption] = []
        for device in found {
            options.append(IOSLensOption(kind: kind(device.deviceType), position: position(device.position)))
        }
        guard let index = choose(options) else { return nil }
        return found[index]
    }

    /// The device has a camera our camera can use.
    public static var hasCamera: Bool { !devices().isEmpty }

    /// The photo sizes this device's camera offers (`bestDevice`, `offeredSizes`); none in the Simulator.
    public static let offered: [IOSPhotoSize] = {
        guard let camera = IOSCameraLens.bestDevice() else { return [] }
        return IOSCameraLens.offeredSizes(camera)
    }()

    /// `format` takes photos as ours are taken: 4:3 frames, full-range 4:2:0, the best photo quality.
    static func takesPhotos(_ format: AVCaptureDevice.Format) -> Bool {
        let size: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return size.width * 3 == size.height * 4
            && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            && format.isHighPhotoQualitySupported
    }

    /// The 4:3 photo sizes `camera` takes in any format that `takesPhotos`, so a size picked among them can
    /// always be set (`IOSCaptureSession.usePhotoSize`).
    static func offeredSizes(_ camera: AVCaptureDevice) -> [IOSPhotoSize] {
        var sizes: [IOSPhotoSize] = []
        for format in camera.formats where takesPhotos(format) {
            for dimensions in format.supportedMaxPhotoDimensions where dimensions.width * 3 == dimensions.height * 4 {
                let size = IOSPhotoSize(width: Int(dimensions.width), height: Int(dimensions.height))
                if !sizes.contains(size) {
                    sizes.append(size)
                }
            }
        }
        return sizes
    }

    /// `size` as `format` lists it among its photo sizes; nil when it does not.
    static func listed(_ size: IOSPhotoSize, in format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        for dimensions in format.supportedMaxPhotoDimensions
            where Int(dimensions.width) == size.width && Int(dimensions.height) == size.height {
            return dimensions
        }
        return nil
    }

    /// The photo size of `megapixels` (`photoSize`) among those `device` takes in its current format; nil
    /// when it offers none.
    static func photoDimensions(_ device: AVCaptureDevice, megapixels: Int) -> CMVideoDimensions? {
        var sizes: [IOSPhotoSize] = []
        for dimensions in device.activeFormat.supportedMaxPhotoDimensions {
            sizes.append(IOSPhotoSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        }
        guard let chosen = photoSize(sizes, megapixels: megapixels) else { return nil }
        return listed(chosen, in: device.activeFormat)
    }
}
#endif
