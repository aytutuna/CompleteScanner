#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// What the import, camera and corner-editor tests share: pictures drawn here (no files of anyone's),
// files made of them with ImageIO, and an AppState that keeps its settings, spool and saved files in
// a folder of the test's own.

/// Text recognition that cannot run, so no page is read with Vision in these tests.
struct ImportTestScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
struct ImportTestBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

enum ImportTestSupport {
    /// A new folder of the test's own in the temporary folder.
    static func makeFolder(_ name: String) throws -> URL {
        let folder: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An AppState with no scanner, its files in `folder`, collecting document pages and saving
    /// PDFs without text recognition into `folder`/Saved.
    @MainActor
    static func makeState(in folder: URL) -> AppState {
        let state = AppState(backends: [], presetStore: PresetStore(directory: folder),
                             fileActions: IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in }),
                             orientationScorer: ImportTestScorer(), barcodeReader: ImportTestBarcodes(),
                             files: AppStateFiles.all(in: folder))
        var settings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.taskId = nil
        settings.source = .flatbed
        settings.duplex = .off
        settings.format = .pdf
        settings.pdfSearchable = false
        settings.destinationPath = folder.appendingPathComponent("Saved", isDirectory: true).path
        state.settings = settings
        return state
    }

    /// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
    @MainActor
    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out after \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// An sRGB bitmap context of `width` × `height`, opaque.
    static func context(width: Int, height: Int) -> CGContext {
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A photo of a sheet on a dark table: `width` × `height`, the sheet's corners at `corners` (pixels,
    /// top-left origin), the paper light grey with a few dark bars.
    static func sheetPhoto(width: Int, height: Int, corners: [CGPoint]) -> CGImage {
        let ctx: CGContext = context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.14, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics counts y up: flip so the corners are in top-left pixels.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.93, blue: 0.9, alpha: 1))
        ctx.beginPath()
        ctx.move(to: corners[0])
        ctx.addLine(to: corners[1])
        ctx.addLine(to: corners[2])
        ctx.addLine(to: corners[3])
        ctx.closePath()
        ctx.fillPath()
        // Bars along the sheet's top edge direction, inside it.
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1))
        var row: Int = 0
        while row < 5 {
            let t: CGFloat = 0.2 + CGFloat(row) * 0.12
            let left = CGPoint(x: corners[0].x + (corners[3].x - corners[0].x) * t + 12,
                               y: corners[0].y + (corners[3].y - corners[0].y) * t)
            let right = CGPoint(x: corners[1].x + (corners[2].x - corners[1].x) * t - 12,
                                y: corners[1].y + (corners[2].y - corners[1].y) * t)
            ctx.beginPath()
            ctx.move(to: left)
            ctx.addLine(to: right)
            ctx.addLine(to: CGPoint(x: right.x, y: right.y + 5))
            ctx.addLine(to: CGPoint(x: left.x, y: left.y + 5))
            ctx.closePath()
            ctx.fillPath()
            row += 1
        }
        return ctx.makeImage()!
    }

    /// `images` written as one file of `type` with `properties` on each (ImageIO).
    static func file(_ type: UTType, images: [CGImage], properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination: CGImageDestination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString,
                                                                               images.count, nil)!
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The orientation tag ImageIO reads from `data`; 0 when there is none.
    static func orientationTag(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
    }
}
#endif
