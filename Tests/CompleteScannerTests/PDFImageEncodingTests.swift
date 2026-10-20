import XCTest
import CoreGraphics
import PDFKit
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/PdfImageEncodingTests.cs: the same table and cases.
// The Mac-only part at the end encodes pages with ImageIO and builds PDFs with CoreGraphics.

/// "300 Color 0.80" — target dpi, kind (Color, Gray or G4) and quality of one plan.
private func row(_ plan: PDFImagePlan) -> String {
    let kind = plan.isBilevel ? "G4" : (plan.isGray ? "Gray" : "Color")
    return "\(plan.targetDPI) \(kind) \(String(format: "%.2f", plan.quality))"
}

/// C# enum member names, so the table reads the same on both platforms. Not called `name`:
/// inside an XCTestCase that would resolve to `XCTest.name`.
private func sizeName(_ size: PDFSizePreset) -> String {
    switch size {
    case .standard: return "Standard"
    case .best: return "Best"
    case .compact: return "Compact"
    case .smallest: return "Smallest"
    }
}

private func modeName(_ mode: ColorMode) -> String {
    switch mode {
    case .color: return "Color"
    case .grayscale: return "Grayscale"
    case .blackWhite: return "BlackWhite"
    }
}

/// A one-color RGBA8 buffer.
private func filled(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for p in 0..<(width * height) {
        rgba[p * 4] = r
        rgba[p * 4 + 1] = g
        rgba[p * 4 + 2] = b
    }
    return rgba
}

/// A deterministic busy page: a color gradient with fine stripes, so JPEG sizes depend on
/// quality and resolution the way scans do.
private func makeBusyImage(width: Int, height: Int, gray: Bool = false) -> CGImage {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let stripe = ((x / 3 + y / 5) % 2 == 0) ? 0 : 60
            let r = UInt8((x * 255 / max(1, width - 1) + stripe) % 256)
            let g = UInt8((y * 255 / max(1, height - 1) + stripe) % 256)
            let b = UInt8(((x + y) * 3 + stripe) % 256)
            let v = gray ? UInt8((Int(r) + Int(g) + Int(b)) / 3) : 0
            rgba[i] = gray ? v : r
            rgba[i + 1] = gray ? v : g
            rgba[i + 2] = gray ? v : b
        }
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

final class PDFImageEncodingTests: XCTestCase {

    func test_profiles_table() {
        XCTAssertEqual(PDFImageEncoding.profile(.best),
                       PDFSizeProfile(maxDPI: nil, colorQuality: 0.90, grayQuality: 0.90, autoGray: false,
                                      bilevelMaxDPI: nil))
        XCTAssertEqual(PDFImageEncoding.profile(.standard),
                       PDFSizeProfile(maxDPI: 300, colorQuality: 0.80, grayQuality: 0.80, autoGray: true,
                                      bilevelMaxDPI: 600))
        XCTAssertEqual(PDFImageEncoding.profile(.compact),
                       PDFSizeProfile(maxDPI: 200, colorQuality: 0.65, grayQuality: 0.70, autoGray: true,
                                      bilevelMaxDPI: 300))
        XCTAssertEqual(PDFImageEncoding.profile(.smallest),
                       PDFSizeProfile(maxDPI: 150, colorQuality: 0.50, grayQuality: 0.55, autoGray: true,
                                      bilevelMaxDPI: 300))
    }

    func test_displayOrder_largestFirst_everySizeOnce() {
        XCTAssertEqual(PDFSizePreset.displayOrder, [.best, .standard, .compact, .smallest])
        XCTAssertEqual(Set(PDFSizePreset.displayOrder), Set(PDFSizePreset.allCases))
        XCTAssertEqual(PDFSizePreset.displayOrder.map(\.label), ["Best", "Standard", "Compact", "Smallest"])
        for size in PDFSizePreset.displayOrder {
            XCTAssertFalse(size.hint.isEmpty)
        }
    }

    func test_hint_namesTheSizesLimits() {
        // The Mac stores black & white pages as gray JPEGs up to the gray limit until its port of the
        // C# PDF writer, so its hint names that limit only; the Windows case also checks the black &
        // white (G4) limit its hint names: "Up to 300 dpi (black & white 600), ...".
        XCTAssertTrue(PDFSizePreset.best.hint.hasPrefix("Full resolution"))
        for size in [PDFSizePreset.standard, .compact, .smallest] {
            let maxDPI = PDFImageEncoding.profile(size).maxDPI ?? 0
            XCTAssertTrue(size.hint.hasPrefix("Up to \(maxDPI) dpi, "), size.hint)
        }
    }

    func test_plan_table_sizeByModeByDPI() {
        var rows: [String] = []
        for size in PDFSizePreset.displayOrder {
            for mode in ColorMode.allCases {
                for dpi in [150, 300, 600] {
                    // Color pages that have color.
                    let plan = PDFImageEncoding.plan(mode: mode, imageDPI: dpi, size: size, looksGray: false)
                    rows.append("\(sizeName(size)) \(modeName(mode)) \(dpi): \(row(plan))")
                }
            }
        }
        XCTAssertEqual(rows, [
            "Best Color 150: 150 Color 0.90", "Best Color 300: 300 Color 0.90", "Best Color 600: 600 Color 0.90",
            "Best Grayscale 150: 150 Gray 0.90", "Best Grayscale 300: 300 Gray 0.90", "Best Grayscale 600: 600 Gray 0.90",
            "Best BlackWhite 150: 150 G4 0.90", "Best BlackWhite 300: 300 G4 0.90", "Best BlackWhite 600: 600 G4 0.90",
            "Standard Color 150: 150 Color 0.80", "Standard Color 300: 300 Color 0.80", "Standard Color 600: 300 Color 0.80",
            "Standard Grayscale 150: 150 Gray 0.80", "Standard Grayscale 300: 300 Gray 0.80", "Standard Grayscale 600: 300 Gray 0.80",
            "Standard BlackWhite 150: 150 G4 0.80", "Standard BlackWhite 300: 300 G4 0.80", "Standard BlackWhite 600: 600 G4 0.80",
            "Compact Color 150: 150 Color 0.65", "Compact Color 300: 200 Color 0.65", "Compact Color 600: 200 Color 0.65",
            "Compact Grayscale 150: 150 Gray 0.70", "Compact Grayscale 300: 200 Gray 0.70", "Compact Grayscale 600: 200 Gray 0.70",
            "Compact BlackWhite 150: 150 G4 0.70", "Compact BlackWhite 300: 300 G4 0.70", "Compact BlackWhite 600: 300 G4 0.70",
            "Smallest Color 150: 150 Color 0.50", "Smallest Color 300: 150 Color 0.50", "Smallest Color 600: 150 Color 0.50",
            "Smallest Grayscale 150: 150 Gray 0.55", "Smallest Grayscale 300: 150 Gray 0.55", "Smallest Grayscale 600: 150 Gray 0.55",
            "Smallest BlackWhite 150: 150 G4 0.55", "Smallest BlackWhite 300: 300 G4 0.55", "Smallest BlackWhite 600: 300 G4 0.55",
        ])
    }

    func test_plan_colorPagesWithoutColor_areGray_exceptAtBest() {
        func planned(_ mode: ColorMode, _ size: PDFSizePreset, looksGray: Bool) -> String {
            row(PDFImageEncoding.plan(mode: mode, imageDPI: 300, size: size, looksGray: looksGray))
        }
        XCTAssertEqual(planned(.color, .best, looksGray: true), "300 Color 0.90")
        XCTAssertEqual(planned(.color, .standard, looksGray: true), "300 Gray 0.80")
        XCTAssertEqual(planned(.color, .compact, looksGray: true), "200 Gray 0.70")
        XCTAssertEqual(planned(.color, .smallest, looksGray: true), "150 Gray 0.55")
        // Gray scans are gray whatever the check says.
        XCTAssertEqual(planned(.grayscale, .best, looksGray: false), "300 Gray 0.90")
    }

    func test_plan_qualityComesFromTheSizeAlone() {
        // `plan` takes no JPEG quality setting (that setting is for JPEG files), so a low setting
        // can never lower a PDF size without the size picker showing it.
        for size in PDFSizePreset.displayOrder {
            let sizeProfile = PDFImageEncoding.profile(size)
            XCTAssertEqual(PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: size, looksGray: false).quality,
                           sizeProfile.colorQuality)
            XCTAssertEqual(PDFImageEncoding.plan(mode: .grayscale, imageDPI: 300, size: size, looksGray: false).quality,
                           sizeProfile.grayQuality)
            XCTAssertEqual(PDFImageEncoding.plan(mode: .blackWhite, imageDPI: 600, size: size, looksGray: false).quality,
                           sizeProfile.grayQuality)
        }
        XCTAssertEqual(PDFImageEncoding.plan(mode: .color, imageDPI: 1200, size: .best, looksGray: false).quality, 0.9)
    }

    func test_plan_downsamplesOnlyClearlyFinerPages() {
        func target(_ dpi: Int, _ size: PDFSizePreset) -> Int {
            PDFImageEncoding.plan(mode: .color, imageDPI: dpi, size: size, looksGray: false).targetDPI
        }
        XCTAssertEqual(target(330, .standard), 330) // within 10 %
        XCTAssertEqual(target(331, .standard), 300)
        XCTAssertEqual(target(220, .compact), 220)
        XCTAssertEqual(target(221, .compact), 200)
        XCTAssertEqual(target(165, .smallest), 165)
        XCTAssertEqual(target(166, .smallest), 150)
        XCTAssertEqual(target(1200, .best), 1200)
        XCTAssertEqual(target(75, .smallest), 75)   // never upsampled
        XCTAssertEqual(target(0, .standard), 1)     // a page without a resolution
    }

    func test_plan_blackAndWhite_isG4_upToItsOwnLimit() {
        func plan(_ dpi: Int, _ size: PDFSizePreset) -> PDFImagePlan {
            PDFImageEncoding.plan(mode: .blackWhite, imageDPI: dpi, size: size, looksGray: false)
        }
        XCTAssertEqual(plan(660, .standard).targetDPI, 660)   // within 10 %
        XCTAssertEqual(plan(661, .standard).targetDPI, 600)
        XCTAssertEqual(plan(1200, .standard).targetDPI, 600)
        XCTAssertEqual(plan(330, .compact).targetDPI, 330)
        XCTAssertEqual(plan(331, .compact).targetDPI, 300)
        XCTAssertEqual(plan(600, .smallest).targetDPI, 300)
        XCTAssertEqual(plan(1200, .best).targetDPI, 1200)
        XCTAssertEqual(plan(75, .smallest).targetDPI, 75)     // never upsampled
        XCTAssertEqual(plan(0, .standard).targetDPI, 1)
        for size in PDFSizePreset.displayOrder {
            let planned = plan(300, size)
            XCTAssertEqual(planned.kind, .bilevelG4)
            XCTAssertTrue(planned.isBilevel && planned.isGray)
            XCTAssertEqual(planned, PDFImageEncoding.plan(mode: .blackWhite, imageDPI: 300, size: size, looksGray: true))
            XCTAssertFalse(PDFImageEncoding.plan(mode: .grayscale, imageDPI: 300, size: size, looksGray: false).isBilevel)
            XCTAssertFalse(PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: size, looksGray: true).isBilevel)
        }
    }

    func test_plan_sizesShrinkInDisplayOrder() {
        for mode in ColorMode.allCases {
            for dpi in [200, 300, 600] {
                let plans = PDFSizePreset.displayOrder.map {
                    PDFImageEncoding.plan(mode: mode, imageDPI: dpi, size: $0, looksGray: false)
                }
                for i in 1..<plans.count {
                    XCTAssertLessThanOrEqual(plans[i].targetDPI, plans[i - 1].targetDPI, "\(mode) \(dpi): dpi order at \(i)")
                    XCTAssertLessThan(plans[i].quality, plans[i - 1].quality, "\(mode) \(dpi): quality order at \(i)")
                }
            }
        }
    }

    func test_plan_forAnImage_checksColorOnlyWhenItMatters() {
        let plain = makeBusyImage(width: 40, height: 40, gray: true)
        let colorful = makeBusyImage(width: 40, height: 40)
        XCTAssertTrue(PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: .standard, image: plain).isGray)
        XCTAssertFalse(PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: .standard, image: colorful).isGray)
        XCTAssertFalse(PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: .best, image: plain).isGray)
        XCTAssertTrue(PDFImageEncoding.plan(mode: .grayscale, imageDPI: 300, size: .best, image: colorful).isGray)
    }

    func test_effectiveDPI_ofAPreviewIsLower() {
        XCTAssertEqual(PDFImageEncoding.effectiveDPI(imageWidth: 2550, pagePixelWidth: 2550, pageDPI: 300), 300)
        XCTAssertEqual(PDFImageEncoding.effectiveDPI(imageWidth: 1600, pagePixelWidth: 2550, pageDPI: 300), 188)
        XCTAssertEqual(PDFImageEncoding.effectiveDPI(imageWidth: 1275, pagePixelWidth: 2550, pageDPI: 300), 150)
        XCTAssertEqual(PDFImageEncoding.effectiveDPI(imageWidth: 1275, pagePixelWidth: 0, pageDPI: 300), 300)
        XCTAssertEqual(PDFImageEncoding.effectiveDPI(imageWidth: 1, pagePixelWidth: 10000, pageDPI: 2), 1)
    }

    func test_targetSize_roundsHalfAwayFromZero_andKeepsAtLeastOnePixel() {
        func size(_ w: Int, _ h: Int, _ from: Int, _ to: Int) -> [Int] {
            let s = PDFImageEncoding.targetSize(width: w, height: h, imageDPI: from, targetDPI: to)
            return [s.width, s.height]
        }
        XCTAssertEqual(size(2550, 3300, 300, 200), [1700, 2200])
        XCTAssertEqual(size(5100, 6600, 600, 300), [2550, 3300])
        XCTAssertEqual(size(3, 1, 300, 150), [2, 1])   // 1.5 -> 2, 0.5 -> 1
        XCTAssertEqual(size(1, 1, 600, 150), [1, 1])
        XCTAssertEqual(size(2550, 3300, 300, 300), [2550, 3300])
        XCTAssertEqual(size(100, 50, 150, 300), [100, 50]) // never larger
    }

    func test_downsample_boxFiltersToThePlannedSize() {
        let flat = filled(600, 400, 10, 20, 30)
        XCTAssertEqual(PDFImageEncoding.downsample(rgba: flat, width: 600, height: 400, newWidth: 600, newHeight: 400), flat)
        let small = PDFImageEncoding.downsample(rgba: flat, width: 600, height: 400, newWidth: 400, newHeight: 267)
        XCTAssertEqual(small.count, 400 * 267 * 4)
        XCTAssertEqual(Array(small[0..<4]), [10, 20, 30, 255])

        // A 2 × 2 checker averages to mid-gray at half the resolution.
        var checker = filled(2, 2, 0, 0, 0)
        for i in [0, 3] {
            checker[i * 4] = 255
            checker[i * 4 + 1] = 255
            checker[i * 4 + 2] = 255
        }
        XCTAssertEqual(PDFImageEncoding.downsample(rgba: checker, width: 2, height: 2, newWidth: 1, newHeight: 1),
                       [127, 127, 127, 255])
    }

    // MARK: Mac page encoding (ImageIO + CoreGraphics; no C# counterpart)

    func test_jpegHeader_readsSizeAndComponents() throws {
        let color = try XCTUnwrap(PDFImageEncoding.encodeJPEG(makeBusyImage(width: 64, height: 40), quality: 0.8))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(color), JPEGHeader(width: 64, height: 40, components: 3))
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data()))
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data("%PDF-1.4".utf8)))
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(color.prefix(12)))
    }

    func test_encodedPage_followsThePlan() throws {
        // A 600 dpi color page that has color.
        let page = makeBusyImage(width: 600, height: 400)
        let standard = try XCTUnwrap(PDFImageEncoding.encodedPage(page, imageDPI: 600, mode: .color,
                                                                  size: .standard))
        XCTAssertEqual(standard.plan, PDFImagePlan(targetDPI: 300, kind: .jpegColor, quality: 0.8))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(standard.jpegData), JPEGHeader(width: 300, height: 200, components: 3))
        XCTAssertEqual(standard.image.width, 300)
        XCTAssertEqual(standard.image.height, 200)

        // The same page scanned in gray: one-component JPEG.
        let gray = try XCTUnwrap(PDFImageEncoding.encodedPage(page, imageDPI: 600, mode: .grayscale,
                                                              size: .compact))
        XCTAssertEqual(gray.plan, PDFImagePlan(targetDPI: 200, kind: .jpegGray, quality: 0.7))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(gray.jpegData), JPEGHeader(width: 200, height: 133, components: 1))

        // A color scan without color is stored gray, except at Best.
        let plain = makeBusyImage(width: 300, height: 200, gray: true)
        let auto = try XCTUnwrap(PDFImageEncoding.encodedPage(plain, imageDPI: 300, mode: .color,
                                                              size: .standard))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(auto.jpegData)?.components, 1)
        let best = try XCTUnwrap(PDFImageEncoding.encodedPage(plain, imageDPI: 300, mode: .color,
                                                              size: .best))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(best.jpegData), JPEGHeader(width: 300, height: 200, components: 3))

        // A black & white page is planned as G4, which the Mac cannot write yet: it is stored as a
        // gray JPEG, planned as a gray page is (300 dpi at Standard, not G4's 600).
        let blackWhite = try XCTUnwrap(PDFImageEncoding.encodedPage(page, imageDPI: 600, mode: .blackWhite,
                                                                    size: .standard))
        XCTAssertEqual(blackWhite.plan, PDFImagePlan(targetDPI: 300, kind: .jpegGray, quality: 0.8))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(blackWhite.jpegData), JPEGHeader(width: 300, height: 200, components: 1))
    }

    func test_pdfSizesShrinkInOrder_andKeepThePageSize() throws {
        // 2 × 2.5 in at 400 dpi: Best keeps 400 dpi, the others store 300, 200 and 150 dpi.
        let pages = [ScannedPage(image: makeBusyImage(width: 800, height: 1000), dpi: 400, colorMode: .color)]
        var sizes: [Int] = []
        for size in PDFSizePreset.displayOrder {
            let data = try PDFBuilder.makePDF(pages: pages, searchable: false, ocrLanguages: [],
                                              pdfSize: size, progress: nil)
            let document = try XCTUnwrap(PDFDocument(data: data), "\(size)")
            XCTAssertEqual(document.pageCount, 1)
            let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
            XCTAssertEqual(Double(bounds.width), 144, accuracy: 0.5, "\(size)")   // 800 / 400 × 72
            XCTAssertEqual(Double(bounds.height), 180, accuracy: 0.5, "\(size)")  // 1000 / 400 × 72
            sizes.append(data.count)
        }
        for i in 1..<sizes.count {
            XCTAssertLessThan(sizes[i], sizes[i - 1], "sizes in display order: \(sizes)")
        }
    }
}
