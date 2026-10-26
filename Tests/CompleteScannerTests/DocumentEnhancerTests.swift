import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/DocumentEnhancerTests.cs: the same pages, the same bytes.
// The checksums were recomputed by an independent model of the algorithm as CONTRACTS.md describes it.

/// The luma of pixel (x, y), as `ColorAnalysis.grayPixels` computes it.
private func lumaAt(_ image: RgbaImage, _ x: Int, _ y: Int) -> Int {
    let i: Int = (y * image.width + x) * 4
    let r: Int = Int(image.pixels[i])
    let g: Int = Int(image.pixels[i + 1])
    let b: Int = Int(image.pixels[i + 2])
    return (299 * r + 587 * g + 114 * b + 500) / 1000
}

/// Min, max and mean luma of the pixels of one kind (`EnhancerPages.kind`).
private struct LumaRange {
    var min: Int = 255
    var max: Int = 0
    var mean: Double = 0
}

private func lumas(_ image: RgbaImage, _ kind: Int, stamp: Bool = true, picture: Bool = false) -> LumaRange {
    var range = LumaRange()
    var sum: Int = 0
    var count: Int = 0
    var y: Int = 0
    while y < image.height {
        var x: Int = 0
        while x < image.width {
            if EnhancerPages.kind(x, y, width: image.width, height: image.height, stamp: stamp, picture: picture) == kind {
                let v: Int = lumaAt(image, x, y)
                range.min = Swift.min(range.min, v)
                range.max = Swift.max(range.max, v)
                sum += v
                count += 1
            }
            x += 1
        }
        y += 1
    }
    range.mean = Double(sum) / Double(Swift.max(count, 1))
    return range
}

final class DocumentEnhancerTests: XCTestCase {
    func testTheFixturesAreTheSharedPixels() {
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.shadowed()), 0x4329_E79A)
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.shadowed(stamp: false)), 0x8F96_0753)
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.shadowed(stamp: false, picture: true)), 0x2C86_F2C0)
    }

    func testAShadowedPageComesOutWithOneWhitePaper() {
        let page: RgbaImage = EnhancerPages.shadowed()
        let before: LumaRange = lumas(page, 0)
        // The shadow: the paper from about 37 % to full light.
        XCTAssertGreaterThanOrEqual(before.max - before.min, 100, "paper \(before.min)...\(before.max)")
        let result: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .gray)
        XCTAssertEqual(result.mode, .gray)
        XCTAssertEqual(result.image.width, page.width)
        XCTAssertEqual(result.image.height, page.height)
        let paper: LumaRange = lumas(result.image, 0)
        XCTAssertGreaterThanOrEqual(paper.min, 250, "paper \(paper.min)...\(paper.max)")
        // The print stays black everywhere, in the shadow too: the contrast is kept.
        let inked: LumaRange = lumas(result.image, 1)
        XCTAssertLessThanOrEqual(inked.max, 10, "print \(inked.min)...\(inked.max)")
        let printBefore: LumaRange = lumas(page, 1)
        XCTAssertGreaterThanOrEqual(paper.mean - inked.mean, Double(before.max - printBefore.min), "contrast kept")
        var i: Int = 0
        let out: [UInt8] = result.image.pixels
        while i < out.count {
            XCTAssertEqual(out[i], out[i + 1])
            XCTAssertEqual(out[i], out[i + 2])
            XCTAssertEqual(out[i + 3], 255)
            i += 4
        }
    }

    func testColorTakesThePapersTintOutAndKeepsTheStampRed() {
        let result: DocumentEnhancement = DocumentEnhancer.enhance(EnhancerPages.shadowed(), mode: .color)
        XCTAssertEqual(result.mode, .color)
        let image: RgbaImage = result.image
        var stampR: Int = 0
        var stampG: Int = 0
        var stamps: Int = 0
        var y: Int = 0
        while y < image.height {
            var x: Int = 0
            while x < image.width {
                let i: Int = (y * image.width + x) * 4
                let kind: Int = EnhancerPages.kind(x, y, width: image.width, height: image.height, stamp: true, picture: false)
                let r: Int = Int(image.pixels[i])
                let g: Int = Int(image.pixels[i + 1])
                let b: Int = Int(image.pixels[i + 2])
                if kind == 0 {
                    // White and neutral: the warm paper's tint is gone.
                    XCTAssertTrue(r >= 250 && g >= 250 && b >= 250, "paper at \(x), \(y)")
                    XCTAssertLessThanOrEqual(abs(r - b), 3, "tint at \(x), \(y)")
                } else if kind == 2 {
                    stampR += r
                    stampG += g
                    stamps += 1
                }
                x += 1
            }
            y += 1
        }
        XCTAssertGreaterThanOrEqual(Double(stampR - stampG) / Double(stamps), 150, "the stamp stays red")
        XCTAssertLessThanOrEqual(lumas(image, 1).max, 10)
    }

    func testAutoKeepsColorOnlyWhereThePageHasColor() {
        let colored: RgbaImage = EnhancerPages.shadowed()
        let auto: DocumentEnhancement = DocumentEnhancer.enhance(colored, mode: .auto)
        XCTAssertEqual(auto.mode, .color)
        XCTAssertEqual(auto.image.pixels, DocumentEnhancer.enhance(colored, mode: .color).image.pixels)

        let plain: RgbaImage = EnhancerPages.shadowed(stamp: false)
        let grayAuto: DocumentEnhancement = DocumentEnhancer.enhance(plain, mode: .auto)
        XCTAssertEqual(grayAuto.mode, .gray)
        XCTAssertEqual(grayAuto.image.pixels, DocumentEnhancer.enhance(plain, mode: .gray).image.pixels)
    }

    func testBlackAndWhiteIsPrintOnPaper() {
        let result: DocumentEnhancement = DocumentEnhancer.enhance(EnhancerPages.shadowed(), mode: .blackAndWhite)
        XCTAssertEqual(result.mode, .blackAndWhite)
        let image: RgbaImage = result.image
        var y: Int = 0
        while y < image.height {
            var x: Int = 0
            while x < image.width {
                let v: UInt8 = image.pixels[(y * image.width + x) * 4]
                XCTAssertTrue(v == 0 || v == 255)
                let kind: Int = EnhancerPages.kind(x, y, width: image.width, height: image.height, stamp: true, picture: false)
                if kind == 0 { XCTAssertEqual(v, 255) }
                if kind == 1 { XCTAssertEqual(v, 0) }
                x += 1
            }
            y += 1
        }
        // Every pixel is kept as it is when the page is packed for CCITT G4.
        let packed: [UInt8] = Bilevel.pack(image)
        XCTAssertEqual(Bilevel.unpack(packed, width: image.width, height: image.height).pixels, image.pixels)
    }

    func testALargeDarkPictureIsNotWashedOut() throws {
        let page: RgbaImage = EnhancerPages.shadowed(stamp: false, picture: true)
        let result: RgbaImage = DocumentEnhancer.enhance(page, mode: .gray).image
        XCTAssertGreaterThanOrEqual(lumas(result, 0, stamp: false, picture: true).min, 250)
        let picture: LumaRange = lumas(result, 3, stamp: false, picture: true)
        XCTAssertLessThanOrEqual(picture.mean, 70, "picture mean \(picture.mean)")
        // Its tiles were filled in from the paper around it.
        let gray: GrayImage = GrayImage.luma(page)
        let size: Int = DocumentEnhancer.tileSize(width: page.width, height: page.height)
        let raw: BackgroundMap = try XCTUnwrap(BackgroundMap.estimate(gray, x: 0, y: 0, width: page.width,
                                                                      height: page.height, tileSize: size))
        let paper: BackgroundMap = try XCTUnwrap(DocumentEnhancer.paperMap(gray))
        XCTAssertLessThan(raw.valueAt(x: 90, y: 245), 80)
        XCTAssertGreaterThan(paper.valueAt(x: 90, y: 245), 120)
    }

    func testAPhotoIsStretchedAsAWholeNotEvenedOut() {
        let page: RgbaImage = EnhancerPages.shadowed()
        let result: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .photo)
        XCTAssertEqual(result.mode, .photo)
        let paper: LumaRange = lumas(result.image, 0)
        // The shadow stays (the light is the photo's), the ends of the range are stretched.
        XCTAssertGreaterThanOrEqual(paper.max - paper.min, 100, "paper \(paper.min)...\(paper.max)")
        XCTAssertGreaterThanOrEqual(paper.max, 250)
        XCTAssertLessThanOrEqual(lumas(result.image, 1).min, 5)
        // A flat picture is left as it is.
        let flat: RgbaImage = RgbaImage.filled(width: 40, height: 30, r: 120, g: 110, b: 100)
        XCTAssertEqual(DocumentEnhancer.enhance(flat, mode: .photo).image, flat)
    }

    func testTheBytesAreTheSameOnBothPlatforms() {
        let page: RgbaImage = EnhancerPages.shadowed()
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .auto).image), 0x7060_4295)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .color).image), 0x7060_4295)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .gray).image), 0xEC45_26A3)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .blackAndWhite).image), 0x4342_2875)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .photo).image), 0xBCA2_862C)
        let plain: RgbaImage = EnhancerPages.shadowed(stamp: false)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(plain, mode: .auto).image), 0xF814_68D6)
        let picture: RgbaImage = EnhancerPages.shadowed(stamp: false, picture: true)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(picture, mode: .gray).image), 0x13CF_7A4C)
    }

    func testDarkTilesAreFilledFromThePaperBesideThem() throws {
        // A 4 × 4 map: paper at 200 with a gentle step (still paper) and a 2 × 2 dark block.
        let tiles: [UInt8] = [
            200, 200, 190, 180,
            200, 60, 50, 175,
            200, 55, 40, 170,
            200, 200, 180, 170,
        ]
        var gray: [UInt8] = [UInt8](repeating: 0, count: 16 * 16)
        for y in 0..<16 {
            for x in 0..<16 {
                gray[y * 16 + x] = tiles[(y / 4) * 4 + x / 4]
            }
        }
        let map: BackgroundMap = try XCTUnwrap(BackgroundMap.estimate(GrayImage(width: 16, height: 16, pixels: gray),
                                                                      x: 0, y: 0, width: 16, height: 16, tileSize: 4))
        XCTAssertEqual(map.tiles, tiles)
        let raised: BackgroundMap = map.raisedDarkTiles(share: DocumentEnhancer.darkTileShare)
        // The block takes the paper beside it; the gentle step stays.
        let expected: [UInt8] = [
            200, 200, 190, 180,
            200, 200, 200, 175,
            200, 200, 200, 170,
            200, 200, 180, 170,
        ]
        XCTAssertEqual(raised.tiles, expected)
        XCTAssertEqual(raised.width, map.width)
        XCTAssertEqual(raised.columns, map.columns)
        // A block wider than a tile's neighbors is filled pass after pass, from the paper inwards.
        var wide: [UInt8] = [UInt8](repeating: 210, count: 8 * 8)
        for y in 1..<7 {
            for x in 1..<7 {
                wide[y * 8 + x] = 50
            }
        }
        var widePixels: [UInt8] = [UInt8](repeating: 0, count: 32 * 32)
        for y in 0..<32 {
            for x in 0..<32 {
                widePixels[y * 32 + x] = wide[(y / 4) * 8 + x / 4]
            }
        }
        let wideMap: BackgroundMap = try XCTUnwrap(BackgroundMap.estimate(GrayImage(width: 32, height: 32, pixels: widePixels),
                                                                          x: 0, y: 0, width: 32, height: 32, tileSize: 4))
        let filled: BackgroundMap = wideMap.raisedDarkTiles(share: 0.7)
        XCTAssertEqual(filled.tiles, [UInt8](repeating: 210, count: 64))
        // A dark region that reaches the map's edge is a shadow cast from beyond the sheet: it keeps its own
        // tiles, the one inside it too, while a dark tile inside the paper is still filled.
        let mixed: [UInt8] = [
            200, 200, 200, 200, 200, 90,
            200, 50, 200, 200, 60, 80,
            200, 200, 200, 200, 200, 85,
            200, 200, 200, 200, 200, 200,
        ]
        var mixedPixels: [UInt8] = [UInt8](repeating: 0, count: 24 * 16)
        for y in 0..<16 {
            for x in 0..<24 {
                mixedPixels[y * 24 + x] = mixed[(y / 4) * 6 + x / 4]
            }
        }
        let mixedMap: BackgroundMap = try XCTUnwrap(BackgroundMap.estimate(GrayImage(width: 24, height: 16, pixels: mixedPixels),
                                                                           x: 0, y: 0, width: 24, height: 16, tileSize: 4))
        var kept: [UInt8] = mixed
        kept[7] = 200
        XCTAssertEqual(mixedMap.raisedDarkTiles(share: DocumentEnhancer.darkTileShare).tiles, kept)
    }

    func testAHardShadowFromTheEdgeIsEvenedOutNotFilledIn() throws {
        let page: RgbaImage = EnhancerPages.hardShadow()
        XCTAssertEqual(PhotoScenes.checksum(page), 0xA8CB_3FCD)
        let w: Int = page.width
        let h: Int = page.height
        let tile: Int = DocumentEnhancer.tileSize(width: w, height: h)
        // The shadowed paper is at 45 % of the lit paper, so its tiles are much darker than their lit
        // neighbors; the shadow reaches the page's edge, so the paper map follows it instead of filling it in.
        let gray: GrayImage = GrayImage.luma(page)
        XCTAssertLessThanOrEqual(gray.pixels[20 * w + 200], 105)
        let paper: BackgroundMap = try XCTUnwrap(DocumentEnhancer.paperMap(gray))
        XCTAssertLessThan(paper.valueAt(x: 200, y: 20), 110)
        XCTAssertGreaterThan(paper.valueAt(x: 40, y: 20), 220)
        // The paper one white on both sides (but within a tile of the shadow's edge, where the map steps
        // between tile centers), the print black on both; in black and white the print stays in the shadow too.
        let result: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .gray)
        let bw: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .blackAndWhite)
        XCTAssertEqual(bw.mode, .blackAndWhite)
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let ink: Bool = EnhancerPages.isInk(x, y, width: w, height: h)
                let nearEdge: Bool = x >= EnhancerPages.shadowEdge && x < EnhancerPages.shadowEdge + tile
                let v: Int = lumaAt(result.image, x, y)
                let b: UInt8 = bw.image.pixels[(y * w + x) * 4]
                if ink {
                    XCTAssertLessThanOrEqual(v, 30, "print \(v) at \(x), \(y)")
                    XCTAssertEqual(b, 0)
                } else if !nearEdge {
                    XCTAssertGreaterThanOrEqual(v, 250, "paper \(v) at \(x), \(y)")
                    XCTAssertEqual(b, 255)
                }
                x += 1
            }
            y += 1
        }
        XCTAssertEqual(PhotoScenes.checksum(result.image), 0x2E7F_EF38)
        XCTAssertEqual(PhotoScenes.checksum(bw.image), 0x1EDF_C6F4)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .color).image), 0x2C52_0A1D)
        let auto: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .auto)
        XCTAssertEqual(auto.mode, .gray)
        XCTAssertEqual(auto.image.pixels, result.image.pixels)
    }

    func testLightPrintOnADarkGroundIsKeptNotWhitenedAway() {
        let page: RgbaImage = EnhancerPages.darkGround()
        XCTAssertEqual(PhotoScenes.checksum(page), 0xE4CF_C2D5)
        XCTAssertTrue(DocumentEnhancer.isLightOnDark(GrayImage.luma(page)))
        let w: Int = page.width
        let h: Int = page.height
        let modes: [(DocumentEnhanceMode, DocumentEnhanceMode)] = [
            (.gray, .gray),
            (.blackAndWhite, .blackAndWhite),
            (.auto, .gray),
            (.color, .color),
        ]
        for (mode, applied) in modes {
            // Stretched as a whole: the ground black, the print white, never the whole page white.
            let result: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: mode)
            XCTAssertEqual(result.mode, applied)
            var y: Int = 0
            while y < h {
                var x: Int = 0
                while x < w {
                    let i: Int = (y * w + x) * 4
                    let v: Int = lumaAt(result.image, x, y)
                    if EnhancerPages.isLightPrint(x, y, width: w, height: h) {
                        XCTAssertGreaterThanOrEqual(v, 250, "\(mode): print \(v) at \(x), \(y)")
                    } else {
                        XCTAssertLessThanOrEqual(v, 5, "\(mode): ground \(v) at \(x), \(y)")
                    }
                    XCTAssertEqual(result.image.pixels[i], result.image.pixels[i + 2])
                    XCTAssertEqual(result.image.pixels[i + 3], 255)
                    x += 1
                }
                y += 1
            }
            XCTAssertEqual(PhotoScenes.checksum(result.image), 0x6EDC_8C95)
        }
        // A page with paper is not light on dark: shadowed, with a dark picture, or under a hard shadow.
        XCTAssertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.shadowed())))
        XCTAssertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.shadowed(stamp: false, picture: true))))
        XCTAssertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.hardShadow())))
        // Nor is a blank dark sheet: it has no light print.
        let blank: RgbaImage = RgbaImage.filled(width: 240, height: 320, r: 55, g: 55, b: 55)
        XCTAssertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(blank)))
        // Nor a page with little or no print beside a hard step: the lit paper next to a shadow's edge or
        // around a big dark picture is the ground of the tile beside it, not light print, wherever in its
        // tile the edge falls.
        let edges: [Int] = [109, 127, EnhancerPages.shadowEdge, 148]
        let prints: [EnhancerPages.ShadowPrint] = [.fewLines, .blank]
        for edge in edges {
            for print in prints {
                let shadowed: RgbaImage = EnhancerPages.hardShadow(print: print, edge: edge)
                XCTAssertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(shadowed)), "\(print), edge at \(edge)")
            }
        }
        XCTAssertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.pictureWithCaption())))
    }

    func testAHardShadowOnAPageWithLittlePrintIsEvenedOutToo() {
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.hardShadow(print: .fewLines)), 0x4B4A_6495)
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.hardShadow(print: .blank)), 0x2EC9_94C5)
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.hardShadow(print: .fewLines, edge: 109)), 0x263A_9905)
        XCTAssertEqual(PhotoScenes.checksum(EnhancerPages.hardShadow(print: .blank, edge: 148)), 0xA99E_33C5)
        let prints: [EnhancerPages.ShadowPrint] = [.fewLines, .blank]
        for print in prints {
            let page: RgbaImage = EnhancerPages.hardShadow(print: print)
            let w: Int = page.width
            let h: Int = page.height
            let tile: Int = DocumentEnhancer.tileSize(width: w, height: h)
            // A short note or a blank sheet under a phone's shadow: the shadowed paper white like the lit
            // paper (not black), the print black in the shadow too, in gray and in black and white.
            let gray: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .gray)
            let bw: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .blackAndWhite)
            XCTAssertEqual(gray.mode, .gray)
            XCTAssertEqual(bw.mode, .blackAndWhite)
            var y: Int = 0
            while y < h {
                var x: Int = 0
                while x < w {
                    let nearEdge: Bool = x >= EnhancerPages.shadowEdge && x < EnhancerPages.shadowEdge + tile
                    let v: Int = lumaAt(gray.image, x, y)
                    let b: UInt8 = bw.image.pixels[(y * w + x) * 4]
                    if EnhancerPages.isPrint(x, y, width: w, height: h, print: print) {
                        XCTAssertLessThanOrEqual(v, 30, "\(print): print \(v) at \(x), \(y)")
                        XCTAssertEqual(b, 0)
                    } else if !nearEdge {
                        XCTAssertGreaterThanOrEqual(v, 250, "\(print): paper \(v) at \(x), \(y)")
                        XCTAssertEqual(b, 255)
                    }
                    x += 1
                }
                y += 1
            }
        }
        let note: RgbaImage = EnhancerPages.hardShadow(print: .fewLines)
        let noteGray: RgbaImage = DocumentEnhancer.enhance(note, mode: .gray).image
        XCTAssertEqual(PhotoScenes.checksum(noteGray), 0x7181_A6C5)
        let noteAuto: DocumentEnhancement = DocumentEnhancer.enhance(note, mode: .auto)
        XCTAssertEqual(noteAuto.mode, .gray)
        XCTAssertEqual(noteAuto.image.pixels, noteGray.pixels)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(note, mode: .blackAndWhite).image), 0xF843_23D5)
        let blank: RgbaImage = EnhancerPages.hardShadow(print: .blank)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(blank, mode: .blackAndWhite).image), 0x55EE_99C5)
    }

    func testABigDarkPictureWithACaptionKeepsItsPaperAndItsPicture() {
        let page: RgbaImage = EnhancerPages.pictureWithCaption()
        XCTAssertEqual(PhotoScenes.checksum(page), 0x78DD_9B25)
        let w: Int = page.width
        let h: Int = page.height
        let gray: DocumentEnhancement = DocumentEnhancer.enhance(page, mode: .gray)
        XCTAssertEqual(gray.mode, .gray)
        var paperMin: Int = 255
        var captionMax: Int = 0
        var pictureSum: Int = 0
        var pictureCount: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let v: Int = lumaAt(gray.image, x, y)
                if EnhancerPages.isBigPicture(x, y) {
                    pictureSum += v
                    pictureCount += 1
                } else if EnhancerPages.isCaption(x, y) {
                    captionMax = max(captionMax, v)
                } else {
                    paperMin = min(paperMin, v)
                }
                x += 1
            }
            y += 1
        }
        let pictureMean: Double = Double(pictureSum) / Double(pictureCount)
        XCTAssertGreaterThanOrEqual(paperMin, 250, "paper \(paperMin)")
        XCTAssertLessThanOrEqual(captionMax, 30, "caption \(captionMax)")
        XCTAssertLessThanOrEqual(pictureMean, 70, "picture mean \(pictureMean)")
        XCTAssertEqual(PhotoScenes.checksum(gray.image), 0x8956_57F5)
        XCTAssertEqual(PhotoScenes.checksum(DocumentEnhancer.enhance(page, mode: .blackAndWhite).image), 0x4ACC_E6B5)
    }

    func testTheModeFollowsTheTaskAndWhatWasShot() {
        var settings = ScanSettings()
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .auto)
        settings.colorMode = .grayscale
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .gray)
        settings.colorMode = .blackWhite
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .blackAndWhite)
        settings.intent = .photo
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .photo)
        XCTAssertEqual(DocumentEnhancer.mode(.gray, kind: .photo), .photo)
        XCTAssertEqual(DocumentEnhancer.mode(.auto, kind: .idCard), .photo)
        XCTAssertEqual(DocumentEnhancer.mode(.gray, kind: .receipt), .gray)
        XCTAssertEqual(DocumentEnhancer.mode(.blackAndWhite, kind: .document), .blackAndWhite)
        XCTAssertEqual(DocumentEnhancer.tileSize(width: 240, height: 320), 20)
        XCTAssertEqual(DocumentEnhancer.tileSize(width: 40, height: 30), DocumentEnhancer.minTileSize)
    }

    func testTheCameraFilterDecidesTheModeOfAColorQueue() {
        var settings = ScanSettings()
        XCTAssertEqual(settings.taskOptions.cameraFilter, .enhanced)
        settings.taskOptions.cameraFilter = .original
        XCTAssertNil(DocumentEnhancer.mode(for: settings))
        settings.taskOptions.cameraFilter = .grayscale
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .gray)
        settings.taskOptions.cameraFilter = .blackAndWhite
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .blackAndWhite)
        // The task's color mode comes first.
        settings.taskOptions.cameraFilter = .original
        settings.colorMode = .grayscale
        XCTAssertEqual(DocumentEnhancer.mode(for: settings), .gray)
        settings.colorMode = .color
        // Receipts, the ID card and copies are cleaned up whatever the filter.
        // Receipts start in gray: in color they are still cleaned up.
        var receipt: ScanSettings = TaskCatalog.apply(.receipt, to: settings)
        receipt.colorMode = .color
        XCTAssertEqual(DocumentEnhancer.mode(for: receipt), .auto)
        XCTAssertEqual(DocumentEnhancer.mode(for: TaskCatalog.apply(.idCard, to: settings)), .auto)
        XCTAssertEqual(DocumentEnhancer.mode(for: TaskCatalog.apply(.copy, to: settings)), .auto)
        XCTAssertNil(DocumentEnhancer.mode(for: TaskCatalog.apply(.book, to: settings)))
        XCTAssertEqual(CaptureFilter.displayOrder, [.original, .enhanced, .grayscale, .blackAndWhite])
        XCTAssertEqual(CaptureFilter.displayOrder.map(\.label), ["Original", "Enhanced", "Grayscale", "B&W"])
        XCTAssertEqual(CaptureFilter.displayOrder.map(\.mode), [nil, .auto, .gray, .blackAndWhite])
        XCTAssertEqual(CaptureFilter(mode: .auto), .enhanced)
        XCTAssertEqual(CaptureFilter(mode: .color), .enhanced)
        XCTAssertEqual(CaptureFilter(mode: .gray), .grayscale)
        XCTAssertEqual(CaptureFilter(mode: .blackAndWhite), .blackAndWhite)
        XCTAssertNil(CaptureFilter(mode: .photo))
    }

    func testTheOriginalFilterKeepsTheCutsPixels() throws {
        let sheet: RgbaImage = EnhancerPages.shadowed()
        let photo: TablePhoto = CameraSheets.squareOnATable(sheet)
        var page = ScannedPage(image: try XCTUnwrap(photo.photo.makeCGImage()), dpi: CaptureScale.nominalDPI, colorMode: .color)
            .withCapture(CaptureFacts(quad: photo.quad, sourceWidth: photo.photo.width, sourceHeight: photo.photo.height))
        page.source = .photo
        let cut: ScannedPage = PerspectiveStep().apply(page)
        let kept: ScannedPage = EnhanceStep(mode: nil).apply(cut)
        XCTAssertTrue(kept.image === cut.image)
        XCTAssertEqual(kept.colorMode, .color)
        XCTAssertEqual(kept.capture?.filter, .original)
        XCTAssertNil(kept.capture?.enhancement)
        // Once only: a page with its filter is not cleaned up afterwards.
        XCTAssertTrue(EnhanceStep(mode: .auto).apply(kept).image === cut.image)
        XCTAssertEqual(EnhanceStep(mode: .gray).apply(cut).capture?.filter, .grayscale)
        XCTAssertEqual(EnhanceStep(mode: .blackAndWhite).apply(cut).capture?.filter, .blackAndWhite)
        // A whole camera page with the Original filter goes into the queue as cut.
        var settings = ScanSettings()
        settings.taskOptions.cameraFilter = .original
        let processed: ScannedPage = try XCTUnwrap(PageProcessor.forCapture(settings).process([page]).pages.first)
        XCTAssertEqual(try XCTUnwrap(RgbaImage(cgImage: processed.image)).pixels, try XCTUnwrap(RgbaImage(cgImage: cut.image)).pixels)
        XCTAssertEqual(processed.capture?.filter, .original)
    }

    func testTheEnhanceStepCleansACutPageUpOnce() throws {
        let quad = Quad(topLeft: CGPoint(x: 100, y: 60), topRight: CGPoint(x: 340, y: 60),
                        bottomRight: CGPoint(x: 340, y: 380), bottomLeft: CGPoint(x: 100, y: 380))
        // The shadowed page laid on a dark table, as a camera took it.
        let sheet: RgbaImage = EnhancerPages.shadowed()
        var photoPixels: [UInt8] = [UInt8](repeating: 0, count: 440 * 440 * 4)
        for y in 0..<440 {
            for x in 0..<440 {
                let o: Int = (y * 440 + x) * 4
                let onSheet: Bool = x >= 100 && x < 340 && y >= 60 && y < 380
                if onSheet {
                    let s: Int = ((y - 60) * 240 + (x - 100)) * 4
                    photoPixels[o] = sheet.pixels[s]
                    photoPixels[o + 1] = sheet.pixels[s + 1]
                    photoPixels[o + 2] = sheet.pixels[s + 2]
                } else {
                    photoPixels[o] = 30
                    photoPixels[o + 1] = 32
                    photoPixels[o + 2] = 36
                }
                photoPixels[o + 3] = 255
            }
        }
        let photo: CGImage = try XCTUnwrap(RgbaImage(width: 440, height: 440, pixels: photoPixels).makeCGImage())
        var page = ScannedPage(image: photo, dpi: CaptureScale.nominalDPI, colorMode: .color)
            .withCapture(CaptureFacts(quad: quad, sourceWidth: 440, sourceHeight: 440))
        page.source = .photo
        let cut: ScannedPage = PerspectiveStep().apply(page)
        let step = EnhanceStep(mode: .auto)
        XCTAssertEqual(step.name, "enhance")
        let cleaned: ScannedPage = step.apply(cut)
        XCTAssertEqual(cleaned.capture?.enhancement, .color)
        var expectedFacts: CaptureFacts = try XCTUnwrap(cut.capture)
        expectedFacts.enhancement = .color
        expectedFacts.filter = .enhanced
        XCTAssertEqual(cleaned.capture, expectedFacts)
        let cutPixels: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: cut.image))
        let cleanedPixels: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: cleaned.image))
        XCTAssertEqual(cleanedPixels.pixels, DocumentEnhancer.enhance(cutPixels, mode: .auto).image.pixels)
        XCTAssertTrue(cleaned.alternate?.image === photo)
        XCTAssertEqual(cleaned.geometry, cut.geometry)
        XCTAssertEqual(cleaned.dpi, cut.dpi)
        XCTAssertEqual(cleaned.colorMode, .color)
        // Once only.
        XCTAssertTrue(step.apply(cleaned).image === cleaned.image)
        // Gray sets the page's color mode.
        let grayed: ScannedPage = EnhanceStep(mode: .gray).apply(cut)
        XCTAssertEqual(grayed.colorMode, .grayscale)
        XCTAssertEqual(grayed.capture?.enhancement, .gray)
        XCTAssertEqual(EnhanceStep(mode: .blackAndWhite).apply(cut).colorMode, .blackWhite)
        // A photo print is a photo, whatever the task says.
        let printPage: ScannedPage = page.withCapture(CaptureFacts(quad: quad, sourceWidth: 440, sourceHeight: 440, kind: .photo))
        let printCut: ScannedPage = PerspectiveStep().apply(printPage)
        XCTAssertEqual(EnhanceStep(mode: .gray).apply(printCut).capture?.enhancement, .photo)
        XCTAssertNil(EnhanceStep(mode: .gray).apply(printCut).capture?.filter)
        XCTAssertEqual(EnhanceStep(mode: nil).apply(printCut).capture?.enhancement, .photo)
        XCTAssertNil(EnhanceStep(mode: nil).apply(printCut).capture?.filter)
        // Not cut out yet, cut out whole (Apple's scanner) or a scanner's page: left alone.
        XCTAssertTrue(step.apply(page).image === page.image)
        XCTAssertNil(step.apply(page).capture?.enhancement)
        let sheetImage: CGImage = try XCTUnwrap(sheet.makeCGImage())
        let whole: ScannedPage = ScannedPage(image: sheetImage, dpi: 200, colorMode: .color)
            .withCapture(CaptureFacts(quad: quad, sourceWidth: 440, sourceHeight: 440,
                                      scale: CaptureScale.fromAspect(pixelWidth: 240, pixelHeight: 320, kind: .document)))
        XCTAssertTrue(step.apply(whole).image === whole.image)
        XCTAssertNil(step.apply(whole).capture?.enhancement)
        let scanned = ScannedPage(image: sheetImage, dpi: 300, colorMode: .color)
        XCTAssertTrue(step.apply(scanned).image === scanned.image)
    }
}
