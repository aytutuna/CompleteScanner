import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import CompleteScannerKit

// The Mac's barcode reading (VisionBarcodeReader) and QR sheets (CoreImageQrEncoder) on synthetic
// scans: codes drawn at their printed size on a page (at 300 dpi, which keeps the debug build quick),
// "scanned" at common resolutions (each scan pixel the mean of the printed ones it covers), with the
// scanner's noise and a slant. The logic around them is in BarcodeTests (a stand-in reader, the same
// cases as Windows); Windows reads with ZXing.Net (CompleteScanner.App.Tests/BarcodeReaderTests.cs).
// Core Image draws QR and Code 128 codes and Core draws Code 39; macOS has no Data Matrix generator,
// so Data Matrix is checked on Windows only.

private let printDPI = 300
private let paperLevel: UInt8 = 242
private let tonerLevel: UInt8 = 30

/// A small, seeded random generator (SplitMix64), so the noise is the same on every run.
private struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in (0, 1].
    mutating func unit() -> Double { Double(next() >> 11 &+ 1) / Double(1 << 53) }
}

/// A printed page: paper with `draw`'s marks on it.
private func printed(_ widthInches: Double, _ heightInches: Double,
                     _ draw: (inout [UInt8], Int, Int) -> Void = { _, _, _ in }) -> GrayImage {
    let w = Int((widthInches * Double(printDPI)).rounded()), h = Int((heightInches * Double(printDPI)).rounded())
    var pixels = [UInt8](repeating: paperLevel, count: w * h)
    draw(&pixels, w, h)
    return GrayImage(width: w, height: h, pixels: pixels, dpi: Double(printDPI))
}

/// `modules` (one per pixel, true dark) drawn with its top-left corner at (`xInches`, `yInches`), each
/// module `moduleInches` wide and tall.
private func stamp(_ modules: GrayImage, x xInches: Double, y yInches: Double, moduleInches: Double)
    -> (inout [UInt8], Int, Int) -> Void {
    { pixels, w, _ in
        let module = Int((moduleInches * Double(printDPI)).rounded())
        let x0 = Int((xInches * Double(printDPI)).rounded()), y0 = Int((yInches * Double(printDPI)).rounded())
        for y in 0..<(modules.height * module) {
            for x in 0..<(modules.width * module) where modules[x / module, y / module] < 128 {
                pixels[(y0 + y) * w + x0 + x] = tonerLevel
            }
        }
    }
}

/// What a Core Image barcode filter draws, one pixel per module (its own quiet zone kept).
private func generated(_ image: CIImage?) throws -> GrayImage {
    let output = try XCTUnwrap(image)
    let context = CIContext(options: [.useSoftwareRenderer: true])
    let cgImage = try XCTUnwrap(context.createCGImage(output, from: output.extent.integral))
    return try XCTUnwrap(GrayImage(cgImage: cgImage, sourceDPI: 72, analysisDPI: 72))
}

/// The QR code of `text` as modules (no quiet zone).
private func qrModules(_ text: String) throws -> GrayImage {
    let code = try XCTUnwrap(CoreImageQrEncoder().encode(text))
    var pixels = [UInt8](repeating: 255, count: code.size * code.size)
    for y in 0..<code.size {
        for x in 0..<code.size where code[x, y] { pixels[y * code.size + x] = 0 }
    }
    return GrayImage(width: code.size, height: code.size, pixels: pixels, dpi: 72)
}

/// Code 128 for `text`: one pixel per narrow module, `rows` rows tall.
private func code128(_ text: String) throws -> GrayImage {
    let filter = CIFilter.code128BarcodeGenerator()
    filter.message = try XCTUnwrap(text.data(using: .ascii))
    filter.quietSpace = 0
    filter.barcodeHeight = 1
    return try generated(filter.outputImage)
}

/// `page` as a scanner delivers it at `dpi`: averaged down, turned `degrees` clockwise about its middle
/// (bilinear, paper beyond the edges), with Gaussian noise of `noise` levels.
private func scanned(_ page: GrayImage, dpi: Int, degrees: Double = 0, noise: Double = 6, seed: UInt64 = 1) -> GrayImage {
    let scan = page.atResolution(dpi)
    let w = scan.width, h = scan.height
    var turned = [UInt8](repeating: 0, count: w * h)
    let radians = degrees * Double.pi / 180, c = cos(radians), s = sin(radians)
    let cx = Double(w) / 2, cy = Double(h) / 2
    var random = SeededRandom(state: seed)
    for y in 0..<h {
        for x in 0..<w {
            let dx = Double(x) - cx, dy = Double(y) - cy
            let sx = cx + dx * c + dy * s, sy = cy - dx * s + dy * c
            var value = Double(paperLevel)
            let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
            if ix >= 0 && iy >= 0 && ix + 1 < w && iy + 1 < h {
                let fx = sx - Double(ix), fy = sy - Double(iy)
                let p00 = Double(scan.pixels[iy * w + ix]), p10 = Double(scan.pixels[iy * w + ix + 1])
                let p01 = Double(scan.pixels[(iy + 1) * w + ix]), p11 = Double(scan.pixels[(iy + 1) * w + ix + 1])
                value = p00 * (1 - fx) * (1 - fy) + p10 * fx * (1 - fy) + p01 * (1 - fx) * fy + p11 * fx * fy
            }
            let u1 = random.unit(), u2 = random.unit()
            value += noise * (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
            turned[y * w + x] = UInt8(max(0, min(255, value.rounded())))
        }
    }
    return GrayImage(width: w, height: h, pixels: turned, dpi: Double(dpi))
}

/// The codes on a scanned page, read the way the clean-up stage reads them.
private func read(_ scan: GrayImage) throws -> [BarcodeReading] {
    try BarcodeSeparators.read(scan.toRgba(), dpi: Int(scan.dpi), reader: VisionBarcodeReader())
}

/// The iOS Simulator may have no barcode detector for Vision to run: there the tests that read codes
/// are skipped, saying so, when a plain QR code printed large reads as nothing. macOS (and a device)
/// always runs them.
private func skipUnlessVisionReadsCodes() throws {
    #if targetEnvironment(simulator)
    let modules = try qrModules("CS-SEP PROBE")
    let page = printed(3, 3) { pixels, w, h in
        stamp(modules, x: 0.5, y: 0.5, moduleInches: 0.06)(&pixels, w, h)
    }
    let found: [BarcodeReading]
    do {
        found = try read(scanned(page, dpi: 200, noise: 0))
    } catch {
        throw XCTSkip("Vision cannot read barcodes in this iOS Simulator (\(error.localizedDescription)); the macOS job runs these tests.")
    }
    if found.isEmpty {
        throw XCTSkip("Vision read no barcode in this iOS Simulator; the macOS job runs these tests.")
    }
    #endif
}

final class VisionBarcodeTests: XCTestCase {
    func test_qrAndCode128_areRead_atCommonResolutions_withNoiseAndASlant() throws {
        try skipUnlessVisionReadsCodes()
        let qrCode = try qrModules("Invoice 0042 · März")
        let bars = try code128("INV-0042/b")
        let cases: [(GrayImage, BarcodeSymbology, String, Double)] = [
            (qrCode, .qrCode, "Invoice 0042 · März", 0.03),
            (bars, .code128, "INV-0042/b", 0.013),
        ]
        for (modules, kind, text, moduleInches) in cases {
            let tall = kind == .code128
            // Bars 0.5 in tall: the one-row code repeated down.
            let page = printed(8.5, 5.5) { pixels, w, h in
                if tall {
                    let rows = Int(0.5 / moduleInches)
                    var stacked = [UInt8](repeating: 255, count: modules.width * rows)
                    for y in 0..<rows {
                        for x in 0..<modules.width { stacked[y * modules.width + x] = modules[x, 0] }
                    }
                    stamp(GrayImage(width: modules.width, height: rows, pixels: stacked, dpi: 72),
                          x: 1.0, y: 0.8, moduleInches: moduleInches)(&pixels, w, h)
                } else {
                    stamp(modules, x: 1.0, y: 0.8, moduleInches: moduleInches)(&pixels, w, h)
                }
            }
            for dpi in [150, 200, 300] {
                for degrees in [0.0, 2.5, -3] {
                    let found = try read(scanned(page, dpi: dpi, degrees: degrees, seed: UInt64(dpi)))
                    XCTAssertEqual(found.count, 1, "\(kind) at \(dpi) dpi, \(degrees)°")
                    XCTAssertEqual(found.first?.symbology, kind, "\(kind) at \(dpi) dpi, \(degrees)°")
                    XCTAssertEqual(found.first?.text, text, "\(kind) at \(dpi) dpi, \(degrees)°")
                }
            }
        }
    }

    func test_theQrSeparatorSheet_readsBackItsName() throws {
        try skipUnlessVisionReadsCodes()
        let cases: [(String?, Int, Double)] = [
            ("Lease 2026", 150, 0), ("Fatura Şubat 2026 — №5", 200, 2), ("東京の請求書 0042", 200, -2),
            ("Αρχείο Ιανουάριος", 300, 1), (nil, 150, -1.5),
        ]
        for (name, dpi, degrees) in cases {
            let code = try XCTUnwrap(CoreImageQrEncoder().encode(QrSeparatorSheet.text(name)))
            let sheet = QrSeparatorSheet.render(code, name: name, widthInches: 8.5, heightInches: 11, dpi: QrSeparatorSheet.dpi)
            let found = try read(scanned(sheet, dpi: dpi, degrees: degrees, noise: 8))
            XCTAssertEqual(found.count, 1, "\(name ?? "no name")")
            XCTAssertEqual(found.first?.symbology, .qrCode)
            XCTAssertEqual(found.first?.text, QrSeparatorSheet.text(name))
            XCTAssertTrue(BarcodeSeparators.startsWithPrefix(found.first?.text ?? "", BarcodeSeparators.defaultPrefix))
            XCTAssertEqual(BarcodeSeparators.codeLabel(found.first?.text, options: DocumentOptions()), BarcodeSeparators.label(name))
        }
    }

    func test_theDemoScannersCode39Sheet_readsAsItsText() throws {
        try skipUnlessVisionReadsCodes()
        // The demo's sheets carry the separator prefix and a name (`MockScannerBackend.batchBarcodeText`).
        for dpi in [150, 300] {
            let sheet = Code39.renderSheet("CS-SEP INVOICE 1002", widthInches: 8.5, heightInches: 11, dpi: dpi)
            let found = try read(scanned(sheet, dpi: dpi, noise: 4))
            XCTAssertEqual(found.map(\.symbology), [.code39], "at \(dpi) dpi")
            XCTAssertEqual(found.map(\.text), ["CS-SEP INVOICE 1002"], "at \(dpi) dpi")
            XCTAssertEqual(BarcodeSeparators.codeLabel(found.first?.text, options: DocumentOptions()), "INVOICE 1002")
        }
    }

    func test_pagesWithoutCodes_readNothing() throws {
        try skipUnlessVisionReadsCodes()
        XCTAssertEqual(try read(scanned(printed(8.5, 11), dpi: 200, noise: 8)), [])
        let patch = PatchCodeDetector.renderSheet(.patchT, widthInches: 8.5, heightInches: 11, dpi: 300)
        XCTAssertEqual(try read(scanned(patch, dpi: 200)), [])
    }

    func test_aStack_splitsAtItsCodeSheets_andTheirTextNamesTheDocuments() throws {
        try skipUnlessVisionReadsCodes()
        let encoder = CoreImageQrEncoder()
        let lease = try XCTUnwrap(encoder.encode(QrSeparatorSheet.text("Lease 2026")))
        let unnamed = try XCTUnwrap(encoder.encode(QrSeparatorSheet.text(nil)))
        let document = printed(8.5, 11) { pixels, w, _ in
            for y in (2 * printDPI)..<(2 * printDPI + 60) {
                for x in printDPI..<(printDPI + 900) { pixels[y * w + x] = tonerLevel }
            }
        }
        let stack: [GrayImage] = [
            document,
            QrSeparatorSheet.render(lease, name: "Lease 2026", widthInches: 8.5, heightInches: 11, dpi: 300),
            document,
            document,
            Code39.renderSheet("CS-SEP INV-7", widthInches: 8.5, heightInches: 11, dpi: 300),
            document,
            QrSeparatorSheet.render(unnamed, name: nil, widthInches: 8.5, heightInches: 11, dpi: 300),
            document,
        ]
        let pages = try stack.enumerated().map { index, page -> ScannedPage in
            let image = try XCTUnwrap(scanned(page, dpi: 200, degrees: index % 2 == 0 ? 1 : -1.5, seed: UInt64(index + 1))
                .toRgba().makeCGImage())
            return ScannedPage(image: image, dpi: 200, colorMode: .color)
        }
        var settings = TaskCatalog.apply(.batch, to: ScanSettings())
        settings.document.splitMode = .barcode
        let processed = try PageProcessor.forScan(settings, barcodes: VisionBarcodeReader()).process(pages).pages
        let plan = DocumentSplitter.plan(processed, options: settings.document)
        XCTAssertEqual(plan.documents.map(\.pages), [[0], [2, 3], [5], [7]])
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Lease 2026", "INV-7", nil])
        settings.document.barcodeStartsDocument = true
        let kept = DocumentSplitter.plan(processed, options: settings.document)
        XCTAssertEqual(kept.documents.map(\.pages), [[0], [1, 2, 3], [4, 5], [6, 7]])
        XCTAssertEqual(kept.documents.map(\.label), [nil, "Lease 2026", "INV-7", nil])
    }

    func test_theQrEncoder_makesAQrCodesModules() throws {
        let encoder = CoreImageQrEncoder()
        let code = try XCTUnwrap(encoder.encode("SEPARATOR"))
        XCTAssertEqual((code.size - 21) % 4, 0)
        // The three finder patterns: a dark 7 × 7 ring with a dark 3 × 3 middle, in three corners.
        for (cx, cy) in [(0, 0), (code.size - 7, 0), (0, code.size - 7)] {
            for k in 0..<7 {
                XCTAssertTrue(code[cx + k, cy] && code[cx + k, cy + 6] && code[cx, cy + k] && code[cx + 6, cy + k])
            }
            XCTAssertFalse(code[cx + 1, cy + 1])
            XCTAssertTrue(code[cx + 3, cy + 3])
        }
        XCTAssertNil(encoder.encode(""))
        XCTAssertNil(encoder.encode(String(repeating: "x", count: 4000)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(encoder.encode(String(repeating: "漢", count: DocumentSplitter.maxLabelLength))).size, 177)
    }
}
