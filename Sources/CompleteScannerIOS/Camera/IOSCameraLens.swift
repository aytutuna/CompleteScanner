#if os(iOS)
import AVFoundation
import CoreMedia
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
/// (`startZoom`), since its zoom 1 is the ultra wide lens's view. Photos are taken at the largest size of
/// about 24 MP at most (`maxPhotoPixels`), which already resolves a page filling the frame at over 400 dpi:
/// a 48 MP photo takes about 195 MB as pixels and the clean-up holds several copies of it at once.
public enum IOSCameraLens {
    /// The cameras picked first, in order.
    public static let preferred: [IOSLensKind] = [.triple, .dualWide, .wide]
    /// The largest photo taken: 5712 × 4284 (24.5 MP) fits, 8064 × 6048 does not.
    public static let maxPhotoPixels: Int = 25_000_000

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

    /// The photo size to take among those the camera offers: the largest of at most `maxPixels` (the
    /// first of them on a tie), else the smallest offered; nil when none is offered.
    public static func photoSize(_ supported: [IOSPhotoSize], maxPixels: Int = IOSCameraLens.maxPhotoPixels) -> IOSPhotoSize? {
        var fitting: IOSPhotoSize?
        var smallest: IOSPhotoSize?
        for size in supported {
            guard size.width > 0, size.height > 0 else { continue }
            if size.pixels <= maxPixels {
                if let current = fitting {
                    if size.pixels > current.pixels {
                        fitting = size
                    }
                } else {
                    fitting = size
                }
            }
            if let current = smallest {
                if size.pixels < current.pixels {
                    smallest = size
                }
            } else {
                smallest = size
            }
        }
        if let chosen = fitting { return chosen }
        return smallest
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

    /// The photo size to take with `device` in its current format; nil when it offers none.
    static func photoDimensions(_ device: AVCaptureDevice) -> CMVideoDimensions? {
        let offered: [CMVideoDimensions] = device.activeFormat.supportedMaxPhotoDimensions
        var sizes: [IOSPhotoSize] = []
        for dimensions in offered {
            sizes.append(IOSPhotoSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        }
        guard let chosen = photoSize(sizes) else { return nil }
        for dimensions in offered where Int(dimensions.width) == chosen.width && Int(dimensions.height) == chosen.height {
            return dimensions
        }
        return nil
    }
}
#endif
