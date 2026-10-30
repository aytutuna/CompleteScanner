import CoreGraphics
import Foundation
import XCTest
@testable import LazyScanKit

// Twin of windows/LazyScan.Core.Tests/MultiQuadPickerTests.cs: the same outlines and picks.

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Quad {
    Quad(topLeft: CGPoint(x: x, y: y), topRight: CGPoint(x: x + w, y: y),
         bottomRight: CGPoint(x: x + w, y: y + h), bottomLeft: CGPoint(x: x, y: y + h))
}

private func candidate(_ quad: Quad, _ confidence: Double) -> QuadCandidate {
    QuadCandidate(quad: quad, confidence: confidence)
}

final class MultiQuadPickerTests: XCTestCase {
    func testOverlapAndIntersectionArea() {
        let a = box(0, 0, 100, 100)
        XCTAssertEqual(a.intersectionArea(a), 10000, accuracy: 1e-9)
        XCTAssertEqual(a.intersectionArea(box(50, 50, 100, 100)), 2500, accuracy: 1e-9)
        XCTAssertEqual(a.intersectionArea(box(200, 0, 50, 50)), 0)
        XCTAssertEqual(MultiQuadPicker.overlap(a, box(50, 50, 100, 100)), 2500.0 / 17500.0, accuracy: 1e-12)
        XCTAssertEqual(MultiQuadPicker.overlap(a, a), 1, accuracy: 1e-12)
        // A diamond inside the square: half its area.
        let diamond = Quad(topLeft: CGPoint(x: 50, y: 0), topRight: CGPoint(x: 100, y: 50),
                           bottomRight: CGPoint(x: 50, y: 100), bottomLeft: CGPoint(x: 0, y: 50))
        XCTAssertEqual(a.intersectionArea(diamond), 5000, accuracy: 1e-9)
        XCTAssertEqual(diamond.intersectionArea(a), 5000, accuracy: 1e-9)
        // Turned 45° about the square's center: the regular octagon, (2√2 − 2) × 100² ≈ 8284.27.
        let h = 50 * 2.0.squareRoot()
        let turned = Quad(topLeft: CGPoint(x: 50, y: 50 - h), topRight: CGPoint(x: 50 + h, y: 50),
                          bottomRight: CGPoint(x: 50, y: 50 + h), bottomLeft: CGPoint(x: 50 - h, y: 50))
        XCTAssertEqual(a.intersectionArea(turned), 8284.271247461902, accuracy: 1e-6)
    }

    func testReceiptsAreKeptByShapeSizeAndInReadingOrder() {
        // Three receipts in two rows, a square coaster, a speck and the whole table.
        let candidates: [QuadCandidate] = [
            candidate(box(600, 120, 160, 700), 0.9),   // top row, right
            candidate(box(100, 100, 150, 600), 0.8),   // top row, left
            candidate(box(350, 1100, 140, 500), 0.95), // second row
            candidate(box(1000, 300, 300, 300), 0.99), // square: not a receipt
            candidate(box(10, 10, 20, 50), 0.99),      // too small
            candidate(box(0, 0, 1600, 2000), 0.99),    // the table, too large
        ]
        let picked = MultiQuadPicker.pick(candidates, imageWidth: 1600, imageHeight: 2000, kind: .receipt)
        XCTAssertEqual(picked, [box(100, 100, 150, 600), box(600, 120, 160, 700), box(350, 1100, 140, 500)])
    }

    func testOverlappingOutlinesAreOneObjectTheSurerStays() {
        let sure = box(100, 100, 400, 600)
        let shifted = box(130, 120, 400, 600)   // the same photo seen again, a little off
        let beside = box(600, 100, 400, 600)
        let picked = MultiQuadPicker.pick([candidate(shifted, 0.6), candidate(sure, 0.9), candidate(beside, 0.5)],
                                          imageWidth: 1200, imageHeight: 900, kind: .photo)
        XCTAssertEqual(picked, [sure, beside])
        // On a tie the larger stays, then the earlier.
        let larger = box(100, 100, 420, 620)
        var options = MultiQuadOptions()
        options.maxLongOverShort = 2
        options.minAreaFraction = 0.01
        XCTAssertEqual(MultiQuadPicker.pick([candidate(shifted, 0.7), candidate(larger, 0.7)],
                                            imageWidth: 1200, imageHeight: 900, options: options), [larger])
    }

    func testAnOutlineInsideALargerOneIsPartOfIt() {
        // A print with a white border: Vision also finds the picture inside it, and surer.
        let printed = box(200, 200, 600, 400)
        let picture = box(230, 230, 540, 340)
        XCTAssertEqual(MultiQuadPicker.pick([candidate(picture, 0.95), candidate(printed, 0.7)],
                                            imageWidth: 1200, imageHeight: 900, kind: .photo), [printed])
        // Two corners a pixel outside still count as inside.
        let almost = box(199, 230, 540, 340)
        XCTAssertEqual(MultiQuadPicker.pick([candidate(almost, 0.95), candidate(printed, 0.7)],
                                            imageWidth: 1200, imageHeight: 900, kind: .photo), [printed])
    }

    func testAnOutlineHoldingSeveralIsTheBackground() {
        // An album page holding four prints, one of them with its picture found too: the prints.
        let page = box(250, 300, 1000, 1400)
        let prints: [Quad] = [box(300, 350, 400, 300), box(750, 350, 400, 300), box(300, 800, 400, 300), box(750, 800, 400, 300)]
        let picture = box(320, 370, 360, 260)
        let album: [QuadCandidate] = [candidate(page, 0.99), candidate(prints[3], 0.8), candidate(picture, 0.95),
                                      candidate(prints[1], 0.7), candidate(prints[0], 0.6), candidate(prints[2], 0.9)]
        XCTAssertEqual(MultiQuadPicker.pick(album, imageWidth: 1500, imageHeight: 2000, kind: .photo), prints)
        // The same page holding one print cannot be told from a print with a border: one object.
        XCTAssertEqual(MultiQuadPicker.pick([candidate(page, 0.5), candidate(prints[0], 0.9)],
                                            imageWidth: 1500, imageHeight: 2000, kind: .photo), [page])
        // Receipts on an A4 sheet laid under them for contrast (A4's shape is a receipt's too): the receipts.
        let sheet = box(200, 200, 1000, 1414)
        let receipts: [Quad] = [box(250, 250, 150, 600), box(500, 250, 160, 700), box(800, 300, 140, 500)]
        XCTAssertEqual(MultiQuadPicker.pick([candidate(receipts[2], 0.7), candidate(sheet, 0.99),
                                             candidate(receipts[0], 0.8), candidate(receipts[1], 0.9)],
                                            imageWidth: 1600, imageHeight: 2000, kind: .receipt), receipts)
        // Wanting one object, the outermost outline is it, whatever it holds.
        let document = box(100, 100, 700, 990)
        let top = box(150, 150, 600, 400)
        let bottom = box(150, 600, 600, 400)
        var one = MultiQuadOptions()
        one.minAreaFraction = 0.01
        XCTAssertEqual(MultiQuadPicker.pick([candidate(top, 0.9), candidate(bottom, 0.9), candidate(document, 0.5)],
                                            imageWidth: 2400, imageHeight: 1600, options: one), [document])
        var two = one
        two.maxCount = 2
        XCTAssertEqual(MultiQuadPicker.pick([candidate(top, 0.9), candidate(bottom, 0.9), candidate(document, 0.5)],
                                            imageWidth: 2400, imageHeight: 1600, options: two), [top, bottom])
    }

    func testFeaturesInsideOnePrintLeaveItWhole() {
        // A 4 × 6 in print of a house over 40 % of the shot; two of its windows are found too, each
        // under 2 % of the shot and photo-shaped, together 8 % of the print: the print.
        let print = box(300, 325, 900, 1350)
        let windows: [Quad] = [box(450, 500, 200, 250), box(850, 500, 200, 250)]
        XCTAssertEqual(MultiQuadPicker.pick([candidate(windows[0], 0.9), candidate(print, 0.8), candidate(windows[1], 0.85)],
                                            imageWidth: 1500, imageHeight: 2000, kind: .photo), [print])
        // The print's picture found as well, holding the windows: still the print.
        let picture = box(330, 355, 840, 1290)
        XCTAssertEqual(MultiQuadPicker.pick([candidate(windows[0], 0.9), candidate(picture, 0.95), candidate(print, 0.8),
                                             candidate(windows[1], 0.85)],
                                            imageWidth: 1500, imageHeight: 2000, kind: .photo), [print])
        // The picture found twice, a little apart: one object seen twice, so the print.
        let again = box(326, 351, 840, 1290)
        XCTAssertEqual(MultiQuadPicker.pick([candidate(picture, 0.95), candidate(again, 0.9), candidate(print, 0.8)],
                                            imageWidth: 1500, imageHeight: 2000, kind: .photo), [print])
        // Two prints laid on the same outline cover enough of it to make it the background.
        let left = box(330, 355, 420, 600)
        let right = box(760, 355, 420, 600)
        XCTAssertEqual(MultiQuadPicker.pick([candidate(print, 0.99), candidate(left, 0.8), candidate(right, 0.7)],
                                            imageWidth: 1500, imageHeight: 2000, kind: .photo), [left, right])
    }

    func testACardIsPickedByItsShapeAndOnlyOne() {
        let card = box(300, 300, 856, 540)
        let page = box(100, 100, 700, 990)
        let second = box(1300, 300, 850, 536)
        let picked = MultiQuadPicker.pick([candidate(page, 0.99), candidate(card, 0.8), candidate(second, 0.7)],
                                          imageWidth: 2400, imageHeight: 1600, kind: .idCard)
        XCTAssertEqual(picked, [card])
        // A document takes the surest page-shaped outline, a card's shape included.
        XCTAssertEqual(MultiQuadPicker.pick([candidate(page, 0.9), candidate(card, 0.5)],
                                            imageWidth: 2400, imageHeight: 1600, kind: .document), [page])
        XCTAssertEqual(MultiQuadPicker.pick([candidate(page, 0.5), candidate(card, 0.9)],
                                            imageWidth: 2400, imageHeight: 1600, kind: .document), [card])
    }

    func testPhotosAreCappedAndOddInputLeftOut() {
        var candidates: [QuadCandidate] = []
        for i in 0..<12 {
            let x = Double(20 + i % 4 * 300), y = Double(20 + i / 4 * 300)
            candidates.append(candidate(box(x, y, 240, 180), 0.5 + Double(i) / 100.0))
        }
        let picked = MultiQuadPicker.pick(candidates, imageWidth: 1240, imageHeight: 920, kind: .photo)
        XCTAssertEqual(picked.count, 8)
        // The surest eight (the last eight given), in reading order.
        XCTAssertEqual(picked.first, box(20, 320, 240, 180))
        XCTAssertEqual(picked.last, box(920, 620, 240, 180))
        // Corners given counterclockwise are named again; a bow tie is no outline; no photo, no pick.
        let counter = box(100, 100, 300, 200)
        let reversed = Quad(topLeft: counter.topLeft, topRight: counter.bottomLeft,
                            bottomRight: counter.bottomRight, bottomLeft: counter.topRight)
        XCTAssertEqual(MultiQuadPicker.pick([candidate(reversed, 0.9)], imageWidth: 1240, imageHeight: 920, kind: .photo),
                       [counter])
        let bowTie = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 400, y: 300),
                          bottomRight: CGPoint(x: 400, y: 100), bottomLeft: CGPoint(x: 100, y: 300))
        XCTAssertTrue(MultiQuadPicker.pick([candidate(bowTie, 0.9)], imageWidth: 1240, imageHeight: 920, kind: .photo).isEmpty)
        XCTAssertTrue(MultiQuadPicker.pick([candidate(counter, 0.9)], imageWidth: 0, imageHeight: 920, kind: .photo).isEmpty)
        XCTAssertTrue(MultiQuadPicker.pick([], imageWidth: 1240, imageHeight: 920, kind: .photo).isEmpty)
    }

    func testEveryKindHasOptions() {
        for kind in CaptureKind.allCases {
            let options = MultiQuadPicker.options(for: kind)
            XCTAssertTrue(options.minLongOverShort >= 1 && options.maxLongOverShort > options.minLongOverShort, "\(kind)")
            XCTAssertTrue(options.minAreaFraction >= 0 && options.maxAreaFraction > options.minAreaFraction, "\(kind)")
            XCTAssertGreaterThanOrEqual(options.maxCount, 1, "\(kind)")
        }
        XCTAssertEqual(MultiQuadPicker.options(for: .receipt).maxCount, 6)
        XCTAssertEqual(MultiQuadPicker.options(for: .photo).maxCount, 8)
        XCTAssertEqual(MultiQuadPicker.options(for: .idCard).maxCount, 1)
        XCTAssertEqual(MultiQuadPicker.options(for: .document).maxCount, 1)
    }
}
