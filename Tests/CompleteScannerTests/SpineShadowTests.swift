import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/SpineShadowTests.cs: softening the shadow along the spine on
// a page cut from a spread, on the same synthetic book pages (TestPages, byte-identical, checked by
// checksum), with the same softened bytes on both platforms.

/// The page is 550 px wide; the shadow reaches 80 px from its right edge.
private let shadowZone = 80

private func inPicture(_ x: Int, _ y: Int) -> Bool { x >= 400 && x < 530 && y >= 300 && y < 520 }

private func inTint(_ x: Int, _ y: Int) -> Bool { x >= 430 && y >= 640 && y < 740 }

private func nowhere(_ x: Int, _ y: Int) -> Bool { false }

private func assertIn(_ value: Double, _ low: Double, _ high: Double, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value >= low && value <= high, "\(value) not in \(low)...\(high) \(message)", file: file, line: line)
}

/// What softening did to the paper and the ink within `shadowZone` of the right edge, against the page with no shadow.
private struct Zone {
    var darkeningBefore: Double, darkeningAfter: Double, worstColumn: Double
    var inkContrastClean: Double, inkContrastAfter: Double, inkClean: Double, inkAfter: Double
}

private func measureZone(_ clean: GrayImage, _ shadowed: GrayImage, _ softened: GrayImage,
                         excluded: (Int, Int) -> Bool) -> Zone {
    let w = clean.width
    var paperClean = 0.0, paperShadow = 0.0, paperSoft = 0.0, inkClean = 0.0, inkSoft = 0.0
    var paper = 0, ink = 0
    var columnClean = [Double](repeating: 0, count: shadowZone)
    var columnSoft = [Double](repeating: 0, count: shadowZone)
    for y in 0..<clean.height {
        for d in 0..<shadowZone {
            let x = w - 1 - d
            if excluded(x, y) { continue }
            let i = y * w + x
            let c = Int(clean.pixels[i])
            if c >= 200 {
                paperClean += Double(c)
                paperShadow += Double(shadowed.pixels[i])
                paperSoft += Double(softened.pixels[i])
                columnClean[d] += Double(c)
                columnSoft[d] += Double(softened.pixels[i])
                paper += 1
            } else if c <= 60 {
                inkClean += Double(c)
                inkSoft += Double(softened.pixels[i])
                ink += 1
            }
        }
    }
    var worst = 0.0
    for d in 0..<shadowZone where columnClean[d] > 0 {
        worst = max(worst, abs(1 - columnSoft[d] / columnClean[d]))
    }
    let pc = paperClean / Double(paper), ps = paperSoft / Double(paper)
    let ic = inkClean / Double(ink), isoft = inkSoft / Double(ink)
    return Zone(darkeningBefore: 1 - paperShadow / paperClean, darkeningAfter: 1 - paperSoft / paperClean,
                worstColumn: worst, inkContrastClean: (pc - ic) / pc, inkContrastAfter: (ps - isoft) / ps,
                inkClean: ic, inkAfter: isoft)
}

/// The largest change of a pixel where `area` holds.
private func largestChange(_ before: GrayImage, _ after: GrayImage, where area: (Int, Int) -> Bool) -> Int {
    var largest = 0
    for y in 0..<before.height {
        for x in 0..<before.width where area(x, y) {
            let i = y * before.width + x
            largest = max(largest, abs(Int(after.pixels[i]) - Int(before.pixels[i])))
        }
    }
    return largest
}

/// The largest change of a pixel where `area` holds (in the page's pixels) when the page is scanned at 300 dpi,
/// its content `shift` px further right and down (off the 100 dpi grid).
private func largestChangeAt300Dpi(_ page: GrayImage, where area: @escaping (Int, Int) -> Bool, shift: Int = 0,
                                   file: StaticString = #filePath, line: UInt = #line) -> Int {
    let scan = shifted(TestPages.enlarged(page, 3), shift)
    guard let result = SpineShadow.soften(scan, dpi: 300, edge: .right) else {
        XCTFail("not softened at 300 dpi", file: file, line: line)
        return -1
    }
    return largestChange(GrayImage.luma(scan), GrayImage.luma(result.image),
                         where: { x, y in x >= shift && y >= shift && area((x - shift) / 3, (y - shift) / 3) })
}

/// The image's content `shift` px further right and down, its first column and row repeated.
private func shifted(_ image: RgbaImage, _ shift: Int) -> RgbaImage {
    let w = image.width, h = image.height
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let from = (max(0, y - shift) * w + max(0, x - shift)) * 4
            for c in 0..<4 { p[(y * w + x) * 4 + c] = image.pixels[from + c] }
        }
    }
    return RgbaImage(width: w, height: h, pixels: p)
}

/// A book page with a flat mid-tone picture (150) where `inPicture` holds, in a shadow 0.8 in wide and 40 % deep.
private func flatPicturePage() -> GrayImage {
    let c = TestPages.Canvas(550, 850, paper: 245, seed: 0xB00C_002A)
    c.textBlock(60, 60, maxWidth: 460, lines: 36, pitch: 20, ink: 40, TestPages.Rng(0xB00C_002B))
    c.fillRect(400, 300, 130, 220, 150)
    c.spineShadow(width: 80, depthTop: 400, depthBottom: 400)
    return c.gray()
}

/// A text page with a flat bar `width` px wide printed all along its right edge, and no shadow.
private func barPage(_ width: Int, _ tint: UInt8, ramp: Int) -> GrayImage {
    let c = TestPages.Canvas(550, 850, paper: 245, seed: 0xB00C_0030)
    c.textBlock(60, 60, maxWidth: 430, lines: 36, pitch: 20, ink: 40, TestPages.Rng(0xB00C_0031))
    c.fillRect(550 - width, 0, width, 850, tint)
    // A scanned bar's edge is a ramp of a few pixels to the paper.
    if ramp > 0 {
        for k in 1...ramp {
            c.fillRect(550 - width - k, 0, 1, 850, UInt8(Int(tint) + (245 - Int(tint)) * k / (ramp + 1)))
        }
    }
    return c.gray()
}

/// The image mirrored left to right.
private func mirrored(_ image: RgbaImage) -> RgbaImage {
    let w = image.width, h = image.height
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<4 { p[(y * w + w - 1 - x) * 4 + c] = image.pixels[(y * w + x) * 4 + c] }
        }
    }
    return RgbaImage(width: w, height: h, pixels: p)
}

/// The image transposed: pixel (x, y) moves to (y, x).
private func transposed(_ image: RgbaImage) -> RgbaImage {
    let w = image.width, h = image.height
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<4 { p[(x * h + y) * 4 + c] = image.pixels[(y * w + x) * 4 + c] }
        }
    }
    return RgbaImage(width: h, height: w, pixels: p)
}

private func softened(_ page: GrayImage) -> GrayImage {
    GrayImage.luma(SpineShadow.soften(page.toRgba(), dpi: 100, edge: .right)!.image)
}

final class SpineShadowTests: XCTestCase {

    // MARK: The pages are the same on both platforms

    func test_bookPages_areTheSameBytesOnBothPlatforms() {
        XCTAssertEqual(TestPages.checksum(TestPages.shadowedBookPage()), 0xFBE5_8022)
        XCTAssertEqual(TestPages.checksum(TestPages.unshadowedBookPage()), 0x1305_BF67)
        XCTAssertEqual(TestPages.checksum(TestPages.pictureBookPage()), 0xDFE3_62B3)
        XCTAssertEqual(TestPages.checksum(TestPages.unshadowedPictureBookPage()), 0xE9AD_3B0B)
        XCTAssertEqual(TestPages.checksum(TestPages.tintBookPage()), 0xE58F_1808)
    }

    func test_softenedPages_areTheSameBytesOnBothPlatforms() throws {
        XCTAssertEqual(TestPages.checksum(softened(TestPages.shadowedBookPage())), 0xC2E3_6A2C)
        XCTAssertEqual(TestPages.checksum(softened(TestPages.pictureBookPage())), 0xF553_8C1C)
        XCTAssertEqual(TestPages.checksum(softened(TestPages.tintBookPage())), 0xDCF2_6252)
        let scan = try XCTUnwrap(SpineShadow.soften(TestPages.enlarged(TestPages.shadowedBookPage(), 3), dpi: 300, edge: .right))
        XCTAssertEqual(TestPages.checksum(GrayImage.luma(scan.image)), 0x5592_BA21)
        let picture = try XCTUnwrap(SpineShadow.soften(TestPages.enlarged(TestPages.pictureBookPage(), 3), dpi: 300, edge: .right))
        XCTAssertEqual(TestPages.checksum(GrayImage.luma(picture.image)), 0xC77A_A721)
    }

    // MARK: Which edge runs along the spine

    func test_gutterEdge_isTheEdgeOfTheCut_turnedWithTheBook() {
        let id = UUID()
        let vertical = BookSplitter.manual(.vertical, fraction: 0.5, width: 100, height: 80)
        let horizontal = BookSplitter.manual(.horizontal, fraction: 0.5, width: 80, height: 100)
        func edge(_ part: Int?, _ gutter: GutterResult?, _ turns: Int) -> PageEdge? {
            SpineShadow.gutterEdge(SpreadPart(spreadID: id, part: part, gutter: gutter), rotationQuarterTurns: turns)
        }
        XCTAssertEqual(edge(0, vertical, 0), .right)
        XCTAssertEqual(edge(1, vertical, 0), .left)
        XCTAssertEqual(edge(0, horizontal, 0), .bottom)
        XCTAssertEqual(edge(1, horizontal, 0), .top)
        // A book lying sideways: its pages are turned a quarter clockwise, and the cut's edge with them.
        XCTAssertEqual(edge(0, vertical, 1), .bottom)
        XCTAssertEqual(edge(1, vertical, 1), .top)
        XCTAssertEqual(edge(1, horizontal, 1), .right)
        XCTAssertEqual(edge(0, horizontal, -1), .right)
        XCTAssertEqual(edge(0, vertical, 2), .left)
        // A whole spread, or a page not cut from one, has no spine edge.
        XCTAssertNil(edge(nil, nil, 0))
        XCTAssertNil(SpineShadow.gutterEdge(nil, rotationQuarterTurns: 0))
        XCTAssertEqual([0, 1, 2, 3].map { SpineShadow.turned(.top, quarterTurns: $0) }, [.top, .right, .bottom, .left])
        XCTAssertEqual(SpineShadow.turned(.left, quarterTurns: 7), .bottom)
    }

    // MARK: Softening

    func test_shadowedPage_paperComesBackToWhite_andTextKeepsItsContrast() throws {
        let shadowed = TestPages.shadowedBookPage()
        let result = try XCTUnwrap(SpineShadow.soften(shadowed.toRgba(), dpi: 100, edge: .right))
        let zone = measureZone(TestPages.unshadowedBookPage(), shadowed, GrayImage.luma(result.image), excluded: nowhere)
        // The paper within 0.8 in of the spine was 13 % darker on average (45 % at the edge, top).
        assertIn(zone.darkeningBefore, 0.12, 0.15)
        assertIn(zone.darkeningAfter, -0.01, 0.03)
        XCTAssertLessThan(zone.worstColumn, 0.05)
        // Ink keeps its share of the paper's light: the text is as dark against the paper as without the shadow.
        assertIn(zone.inkContrastAfter / zone.inkContrastClean, 0.98, 1.02)
        assertIn(zone.inkAfter, zone.inkClean - 5, zone.inkClean + 5)
        let r = result.result
        XCTAssertEqual(r.edge, .right)
        // The shadow most of the edge agrees on: 30-45 % deep at the edge, faded within 0.8 in.
        assertIn(r.depth, 0.25, 0.45)
        assertIn(r.widthInches, 0.4, 0.8)
        assertIn(r.maxGain, 1.4, SpineShadow.maxGain)
        XCTAssertEqual(r.protectedFraction, 0)
    }

    func test_shadowedPage_scannedAt300Dpi_isSoftenedAsAt100() throws {
        let scan = TestPages.enlarged(TestPages.shadowedBookPage(), 3)
        let result = try XCTUnwrap(SpineShadow.soften(scan, dpi: 300, edge: .right))
        let softenedPage = GrayImage.luma(result.image).downsampled(width: 550, height: 850)
        let zone = measureZone(TestPages.unshadowedBookPage(), TestPages.shadowedBookPage(), softenedPage, excluded: nowhere)
        assertIn(zone.darkeningAfter, -0.01, 0.03)
        assertIn(zone.inkContrastAfter / zone.inkContrastClean, 0.98, 1.02)
        XCTAssertEqual(result.image.width, 1650)
        // Alpha is kept, and nothing past the 1.5 in band changes.
        for i in 0..<(scan.width * scan.height) where result.image.pixels[i * 4 + 3] != 255 {
            XCTFail("alpha changed at \(i)")
            break
        }
        var changed = 0
        for y in stride(from: 0, to: scan.height, by: 7) {
            for x in 0..<(scan.width - 3 * 150) where scan.pixels[(y * scan.width + x) * 4] != result.image.pixels[(y * scan.width + x) * 4] {
                changed += 1
            }
        }
        XCTAssertEqual(changed, 0)
    }

    func test_everyEdge_givesTheSamePage() throws {
        let page = TestPages.shadowedBookPage().toRgba()
        let right = try XCTUnwrap(SpineShadow.soften(page, dpi: 100, edge: .right)).image
        let left = try XCTUnwrap(SpineShadow.soften(mirrored(page), dpi: 100, edge: .left)).image
        let bottom = try XCTUnwrap(SpineShadow.soften(transposed(page), dpi: 100, edge: .bottom)).image
        let top = try XCTUnwrap(SpineShadow.soften(transposed(mirrored(page)), dpi: 100, edge: .top)).image
        XCTAssertEqual(right.pixels, mirrored(left).pixels)
        XCTAssertEqual(right.pixels, transposed(bottom).pixels)
        XCTAssertEqual(right.pixels, mirrored(transposed(top)).pixels)
    }

    func test_colorPages_areLiftedEvenly_keepingThePapersTint() throws {
        // Cream paper: every channel is brightened by the same factor, so the tint stays.
        let gray = TestPages.shadowedBookPage()
        var p = [UInt8](repeating: 0, count: gray.width * gray.height * 4)
        for i in 0..<gray.pixels.count {
            let v = Int(gray.pixels[i])
            p[i * 4] = UInt8(v)
            p[i * 4 + 1] = UInt8(v * 96 / 100)
            p[i * 4 + 2] = UInt8(v * 82 / 100)
            p[i * 4 + 3] = 255
        }
        let color = RgbaImage(width: gray.width, height: gray.height, pixels: p)
        let result = try XCTUnwrap(SpineShadow.soften(color, dpi: 100, edge: .right))
        // Paper at the edge, in the middle of the page (between two lines of text): red, green and blue in the cream's proportions.
        let at = (430 * gray.width + gray.width - 3) * 4
        let o = result.image.pixels
        XCTAssertGreaterThan(Int(o[at]), Int(p[at]) + 40)
        assertIn(Double(o[at + 1]) / Double(o[at]), 0.93, 0.99)
        assertIn(Double(o[at + 2]) / Double(o[at]), 0.79, 0.85)
    }

    func test_picturesBesideTheSpine_areLeftAlone() throws {
        let shadowed = TestPages.pictureBookPage()
        let result = try XCTUnwrap(SpineShadow.soften(shadowed.toRgba(), dpi: 100, edge: .right))
        let softenedPage = GrayImage.luma(result.image)
        // The picture keeps its pixels (and the shadow on it): its tones are not washed out.
        XCTAssertEqual(largestChange(shadowed, softenedPage, where: inPicture), 0)
        // The paper around it, and the text, are softened as on a page without a picture.
        let zone = measureZone(TestPages.unshadowedPictureBookPage(), shadowed, softenedPage, excluded: inPicture)
        assertIn(zone.darkeningBefore, 0.13, 0.17)
        assertIn(zone.darkeningAfter, -0.01, 0.03)
        assertIn(zone.inkContrastAfter / zone.inkContrastClean, 0.98, 1.02)
        // The picture is the band's protected part: 1.3 × 2.2 in of 1.5 × 8.5 in.
        assertIn(result.result.protectedFraction, 0.2, 0.25)
        // Scanned at 300 dpi, the picture keeps every pixel too, to its outermost rows and columns, and the paper
        // around it is softened as at 100 dpi.
        XCTAssertEqual(largestChangeAt300Dpi(shadowed, where: inPicture), 0)
        let scan = try XCTUnwrap(SpineShadow.soften(TestPages.enlarged(shadowed, 3), dpi: 300, edge: .right))
        let zone300 = measureZone(TestPages.unshadowedPictureBookPage(), shadowed,
                                  GrayImage.luma(scan.image).downsampled(width: 550, height: 850), excluded: inPicture)
        assertIn(zone300.darkeningAfter, -0.01, 0.03)
        assertIn(zone300.inkContrastAfter / zone300.inkContrastClean, 0.98, 1.02)
    }

    func test_pictureOffTheAnalysisGrid_keepsEveryPixel() throws {
        // At 300 dpi a picture's edges need not fall on the 100 dpi grid the shadow is measured on: an analysis
        // pixel only partly on a flat mid-tone picture is lighter than the picture, and left out of its box; the
        // picture's outermost rows and columns in that pixel keep their values all the same.
        let page = flatPicturePage()
        let result = try XCTUnwrap(SpineShadow.soften(page.toRgba(), dpi: 100, edge: .right))
        XCTAssertEqual(largestChange(page, GrayImage.luma(result.image), where: inPicture), 0)
        for shift in [0, 1, 2] {
            XCTAssertEqual(largestChangeAt300Dpi(page, where: inPicture, shift: shift), 0, "flat picture, shift \(shift)")
            XCTAssertEqual(largestChangeAt300Dpi(TestPages.pictureBookPage(), where: inPicture, shift: shift), 0,
                           "picture, shift \(shift)")
        }
    }

    func test_flatTintReachingTheSpine_isLeftAlone() throws {
        let shadowed = TestPages.tintBookPage()
        let result = try XCTUnwrap(SpineShadow.soften(shadowed.toRgba(), dpi: 100, edge: .right))
        let softenedPage = GrayImage.luma(result.image)
        // A flat gray band reaching the spine looks like shadowed paper close up, but not beside the blocks around it.
        XCTAssertEqual(largestChange(shadowed, softenedPage, where: inTint), 0)
        let clean = TestPages.bookPage(0, 0, 80, seed: 0xB00C_0022, tint: true)
        let zone = measureZone(clean, shadowed, softenedPage, excluded: inTint)
        assertIn(zone.darkeningAfter, -0.01, 0.03)
        XCTAssertGreaterThan(result.result.protectedFraction, 0.08)
        XCTAssertEqual(largestChangeAt300Dpi(shadowed, where: inTint), 0)
    }

    func test_barPrintedAllAlongTheSpine_isNoShadow() {
        // A tint, a thumb index or a bleed running the whole length of the spine darkens the paper there in
        // every block, but comes back to the paper in a step: it is left as printed.
        for width in [10, 20] {
            for tint: UInt8 in [200, 160, 120] {
                for ramp in [0, 2] {
                    let page = barPage(width, tint, ramp: ramp)
                    XCTAssertNil(SpineShadow.estimate(page, edge: .right), "bar \(width) px, \(tint), ramp \(ramp)")
                    XCTAssertNil(SpineShadow.soften(TestPages.enlarged(page, 3), dpi: 300, edge: .right),
                                 "bar \(width) px, \(tint), ramp \(ramp), 300 dpi")
                }
            }
        }
        // A shadow as narrow and faint (0.2 in, 10 % deep) fades gradually, and is softened.
        XCTAssertNotNil(SpineShadow.soften(TestPages.bookPage(100, 100, 20, seed: 0xB00C_0029).toRgba(), dpi: 100, edge: .right))
    }

    // MARK: Pages left alone

    func test_pagesWithoutAShadow_areLeftAlone() {
        XCTAssertNil(SpineShadow.soften(TestPages.unshadowedBookPage().toRgba(), dpi: 100, edge: .right))
        XCTAssertNil(SpineShadow.soften(TestPages.unshadowedPictureBookPage().toRgba(), dpi: 100, edge: .right))
        // The shadow is on the right: the left edge has none.
        XCTAssertNil(SpineShadow.soften(TestPages.shadowedBookPage().toRgba(), dpi: 100, edge: .left))
        XCTAssertNil(SpineShadow.estimate(TestPages.shadowedBookPage(), edge: .top))
        // A shadow too faint to matter (3 %), a dark page, a page too narrow for a band.
        XCTAssertNil(SpineShadow.soften(TestPages.bookPage(30, 30, 80, seed: 0xB00C_0023).toRgba(), dpi: 100, edge: .right))
        XCTAssertNil(SpineShadow.soften(RgbaImage.filled(width: 550, height: 850, r: 60, g: 60, b: 60), dpi: 100, edge: .right))
        XCTAssertNil(SpineShadow.soften(RgbaImage.filled(width: 40, height: 850, r: 200, g: 200, b: 200), dpi: 100, edge: .right))
    }

    func test_darkAreasAllAcrossTheBand_areNoShadow() {
        // A dark picture running the whole length of the edge, wider than the band: nothing fades, nothing is softened.
        let c = TestPages.Canvas(550, 850, paper: 245, seed: 0xB00C_0024)
        c.textBlock(60, 60, maxWidth: 300, lines: 36, pitch: 20, ink: 40, TestPages.Rng(0xB00C_0025))
        c.picture(380, 0, 170, 850)
        XCTAssertNil(SpineShadow.soften(c.gray().toRgba(), dpi: 100, edge: .right))
        // A dark stripe 0.5 in from the edge, the paper at the edge as bright as elsewhere: not the spine's shadow.
        let stripe = TestPages.Canvas(550, 850, paper: 245, seed: 0xB00C_0026)
        stripe.textBlock(60, 60, maxWidth: 400, lines: 36, pitch: 20, ink: 40, TestPages.Rng(0xB00C_0027))
        stripe.fillRect(470, 0, 30, 850, 150)
        XCTAssertNil(SpineShadow.soften(stripe.gray().toRgba(), dpi: 100, edge: .right))
    }

    func test_gains_areCapped() throws {
        // A fold 90 % dark at the edge: the paper there is brightened at most maxGain times.
        let deep = TestPages.bookPage(900, 900, 60, seed: 0xB00C_0028)
        let model = try XCTUnwrap(SpineShadow.estimate(deep, edge: .right))
        XCTAssertEqual(model.result.maxGain, SpineShadow.maxGain)
        XCTAssertTrue(model.gains.allSatisfy { $0 >= 1 && $0 <= SpineShadow.maxGain })
        XCTAssertEqual([model.band, model.length, model.extent], [150, 850, 550])
        XCTAssertEqual(model.gains.count, model.pictures.count)
    }

    func test_hint_saysWhatTheSwitchDoes() {
        XCTAssertEqual(SpineShadow.hint(true), "Lightens the dark band along the spine")
        XCTAssertEqual(SpineShadow.hint(false), "Lightens the dark band along the spine")
    }
}
