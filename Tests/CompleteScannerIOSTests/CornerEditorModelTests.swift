#if os(iOS)
import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The iPhone's corner editor without a screen (`CornerEditorModel`): the photo fitted into the view, a
// finger taking the nearest handle and moving its corner by as much as it moves, the corners kept in the
// photo and on a convex outline, Reset, the answers, the magnifier kept in the view, and VoiceOver's steps.

/// A 400 × 300 photo with a page outlined inside it.
private let start = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 320, y: 50),
                         bottomRight: CGPoint(x: 330, y: 260), bottomLeft: CGPoint(x: 70, y: 250))

private func model() -> CornerEditorModel {
    CornerEditorModel(photoWidth: 400, photoHeight: 300, corners: start)
}

/// A 448 × 648 view: the photo fits its width (24 pt in from each side) at 1 pt a pixel.
private let viewSize = CGSize(width: 448, height: 648)

final class CornerEditorModelTests: XCTestCase {
    func test_thePhoto_fitsTheViewCentered_andPointsMapBothWays() {
        let editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        XCTAssertEqual(frame, CGRect(x: 24, y: 174, width: 400, height: 300))
        // A tall photo in a wide view fits its height.
        let tall = CornerEditorModel(photoWidth: 300, photoHeight: 600, corners: start)
        XCTAssertEqual(tall.fittedFrame(in: CGSize(width: 1000, height: 648)), CGRect(x: 350, y: 24, width: 300, height: 600))
        // No room: nothing to show.
        XCTAssertEqual(editor.fittedFrame(in: CGSize(width: 40, height: 40)), CGRect(x: 0, y: 0, width: 0, height: 0))

        let point = CGPoint(x: 123.5, y: 77.25)
        let shown: CGPoint = editor.viewPoint(point, frame: frame)
        XCTAssertEqual(shown, CGPoint(x: 147.5, y: 251.25))
        let back: CGPoint = editor.imagePoint(shown, frame: frame)
        XCTAssertEqual(Double(back.x), 123.5, accuracy: 1e-9)
        XCTAssertEqual(Double(back.y), 77.25, accuracy: 1e-9)
        let corners: [CGPoint] = editor.viewCorners(frame: frame)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0], CGPoint(x: 104, y: 214))
    }

    func test_aFinger_takesTheNearestHandleWithinReach() {
        let editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        // The top-right corner is shown at (344, 224).
        XCTAssertEqual(editor.handle(at: CGPoint(x: 350, y: 230), frame: frame), 1)
        XCTAssertEqual(editor.handle(at: CGPoint(x: 344 + 30, y: 224), frame: frame), 1)
        XCTAssertNil(editor.handle(at: CGPoint(x: 344 + 40, y: 224), frame: frame))
        XCTAssertNil(editor.handle(at: CGPoint(x: 224, y: 324), frame: frame))
        // Two handles within reach: the nearer one.
        let close = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                      corners: Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 140, y: 100),
                                                    bottomRight: CGPoint(x: 140, y: 140), bottomLeft: CGPoint(x: 100, y: 140)))
        XCTAssertEqual(close.handle(at: CGPoint(x: 24 + 132, y: 174 + 102), frame: frame), 1)
        XCTAssertEqual(close.handle(at: CGPoint(x: 24 + 105, y: 174 + 103), frame: frame), 0)
    }

    func test_aCorner_movesByAsMuchAsTheFinger_andStaysInThePhoto() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        XCTAssertFalse(editor.showsLoupe)
        // The finger comes down 10 pt off the bottom-left handle: the corner does not jump to it.
        let down = CGPoint(x: 24 + 70 + 10, y: 174 + 250)
        XCTAssertTrue(editor.beginDrag(at: down, frame: frame))
        XCTAssertEqual(editor.dragging, 3)
        XCTAssertEqual(editor.selected, 3)
        XCTAssertTrue(editor.showsLoupe)
        editor.drag(from: down, to: CGPoint(x: down.x - 20, y: down.y + 15), frame: frame)
        XCTAssertEqual(editor.corners.bottomLeft, CGPoint(x: 50, y: 265))
        // Past the photo's edge it stops at the edge.
        editor.drag(from: down, to: CGPoint(x: down.x - 200, y: down.y + 200), frame: frame)
        XCTAssertEqual(editor.corners.bottomLeft, CGPoint(x: 0, y: 300))
        editor.endDrag()
        XCTAssertNil(editor.dragging)
        XCTAssertFalse(editor.showsLoupe)
        XCTAssertTrue(editor.canReset)
        XCTAssertTrue(editor.canUseCorners)
        // A drag that would fold the outline is not taken.
        XCTAssertTrue(editor.beginDrag(at: editor.viewPoint(editor.corners.topLeft, frame: frame), frame: frame))
        let before: Quad = editor.corners
        let from: CGPoint = editor.viewPoint(editor.corners.topLeft, frame: frame)
        editor.drag(from: from, to: CGPoint(x: from.x + 300, y: from.y + 250), frame: frame)
        XCTAssertEqual(editor.corners, before)
        editor.endDrag()
        // Away from every handle, nothing moves.
        XCTAssertFalse(editor.beginDrag(at: CGPoint(x: 224, y: 324), frame: frame))
        editor.drag(from: CGPoint(x: 224, y: 324), to: CGPoint(x: 260, y: 360), frame: frame)
        XCTAssertEqual(editor.corners, before)
    }

    func test_reset_andTheAnswers() throws {
        var editor: CornerEditorModel = model()
        XCTAssertFalse(editor.canReset)
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let down: CGPoint = editor.viewPoint(start.topRight, frame: frame)
        editor.beginDrag(at: down, frame: frame)
        editor.drag(from: down, to: CGPoint(x: down.x + 12, y: down.y - 8), frame: frame)
        editor.endDrag()
        XCTAssertEqual(editor.corners.topRight, CGPoint(x: 332, y: 42))
        let answer: PhotoCornersAnswer = editor.useCornersAnswer
        XCTAssertEqual(answer.choice, .useCorners)
        XCTAssertEqual(answer.corners, editor.corners)
        editor.reset()
        XCTAssertEqual(editor.corners, start)
        XCTAssertFalse(editor.canReset)
        // An outline the page cannot be cut out along cannot be used.
        let thin = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                     corners: Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 20, y: 10),
                                                   bottomRight: CGPoint(x: 20, y: 200), bottomLeft: CGPoint(x: 10, y: 200)))
        XCTAssertFalse(thin.canUseCorners)
        // The editor opens with the request's corners.
        let photo: RgbaImage = RgbaImage.filled(width: 400, height: 300, r: 0, g: 0, b: 0)
        let plan = PhotoImportPlan(action: .review, corners: start, reason: .unsure, detection: PhotoDocumentDetection.nothing)
        let request = PhotoCornersRequest(photo: photo, plan: plan, fileName: "IMG_0001.HEIC", number: 1, count: 2)
        let opened = CornerEditorModel(request: request)
        XCTAssertEqual(opened.corners, start)
        XCTAssertEqual(opened.photoWidth, 400)
        XCTAssertEqual(opened.photoHeight, 300)
    }

    func test_theMagnifier_sitsAwayFromThePage_andStaysInTheView() {
        let size = CGSize(width: 400, height: 600)
        let half: CGFloat = CornerEditorModel.loupeSize / 2
        let reach: CGFloat = half + CornerEditorModel.loupeGap
        // A top-left corner well inside the view: up and to the left of it.
        let inside: CGPoint = CornerEditorModel.loupeCenter(corner: CGPoint(x: 200, y: 300), middle: CGPoint(x: 260, y: 360), in: size)
        XCTAssertEqual(inside, CGPoint(x: 200 - reach, y: 300 - reach))
        // Near the view's top-left: the first diagonal that fits.
        let corner = CGPoint(x: 30, y: 30)
        let near: CGPoint = CornerEditorModel.loupeCenter(corner: corner, middle: CGPoint(x: 200, y: 300), in: size)
        XCTAssertEqual(near, CGPoint(x: 30 + reach, y: 30 + reach))
        XCTAssertGreaterThanOrEqual(near.x - half, 0)
        XCTAssertGreaterThanOrEqual(near.y - half, 0)
        // The magnified photo is placed so the corner is at the magnifier's center.
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        editor.beginDrag(at: editor.viewPoint(start.topLeft, frame: frame), frame: frame)
        let offset: CGSize = editor.loupeImageOffset(frame: frame)
        XCTAssertEqual(Double(offset.width), Double(half - 80 * CornerEditorModel.loupeZoom), accuracy: 1e-9)
        XCTAssertEqual(Double(offset.height), Double(half - 40 * CornerEditorModel.loupeZoom), accuracy: 1e-9)
        // The top-left corner is shown at (104, 214): up and to the left would leave the view, so up
        // and to the right.
        let center: CGPoint = editor.loupeCenter(frame: frame, in: viewSize)
        XCTAssertEqual(center, CGPoint(x: 104 + reach, y: 214 - reach))
    }

    func test_voiceOver_namesTheCorners_andStepsThemOutAndIn() {
        XCTAssertEqual(CornerEditorModel.cornerName(0), "Top left corner")
        XCTAssertEqual(CornerEditorModel.cornerName(2), "Bottom right corner")
        XCTAssertEqual(CornerEditorModel.cornerName(5), "Top right corner")
        var editor: CornerEditorModel = model()
        // A hundredth of the long side (4 px) each way, away from the middle.
        editor.nudge(2, outward: true)
        XCTAssertEqual(editor.corners.bottomRight, CGPoint(x: 334, y: 264))
        XCTAssertEqual(editor.selected, 2)
        editor.nudge(2, outward: false)
        XCTAssertEqual(editor.corners.bottomRight, CGPoint(x: 330, y: 260))
        editor.nudge(0, outward: true)
        XCTAssertEqual(editor.corners.topLeft, CGPoint(x: 76, y: 36))
    }

    func test_voiceOver_namesEachCornerByWhereItSitsNow() {
        // As found: each corner by its own place.
        let editor: CornerEditorModel = model()
        XCTAssertEqual(editor.cornerLabel(0), "Top left corner")
        XCTAssertEqual(editor.cornerLabel(1), "Top right corner")
        XCTAssertEqual(editor.cornerLabel(2), "Bottom right corner")
        XCTAssertEqual(editor.cornerLabel(3), "Bottom left corner")
        XCTAssertEqual(editor.cornerLabel(4), editor.cornerLabel(0))
        // The outline turned a quarter turn: corner 0 sits at the page's top right now.
        let turned = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                       corners: Quad(topLeft: start.topRight, topRight: start.bottomRight,
                                                     bottomRight: start.bottomLeft, bottomLeft: start.topLeft))
        XCTAssertEqual(turned.cornerLabel(0), "Top right corner")
        XCTAssertEqual(turned.cornerLabel(1), "Bottom right corner")
        XCTAssertEqual(turned.cornerLabel(2), "Bottom left corner")
        XCTAssertEqual(turned.cornerLabel(3), "Top left corner")
        XCTAssertEqual(turned.cornerValue(0), "80 percent from the left, 17 percent from the top")
        // Corners that meet still get a name each.
        let point = CGPoint(x: 100, y: 100)
        let met = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                    corners: Quad(topLeft: point, topRight: point, bottomRight: point, bottomLeft: point))
        var names: Set<String> = []
        for index in 0..<4 {
            names.insert(met.cornerLabel(index))
        }
        XCTAssertEqual(names.count, 4)
    }

    func test_voiceOver_saysWhereEachCornerIs_andHearsEachStep() {
        var editor: CornerEditorModel = model()
        // (80, 40) in 400 × 300: 20 % from the left, 13 % from the top.
        XCTAssertEqual(editor.cornerValue(0), "20 percent from the left, 13 percent from the top")
        XCTAssertEqual(editor.cornerValue(2), "83 percent from the left, 87 percent from the top")
        XCTAssertEqual(editor.cornerValue(4), editor.cornerValue(0))
        // A step outward (4 px) changes what is read.
        editor.nudge(0, outward: true)
        XCTAssertEqual(editor.cornerValue(0), "19 percent from the left, 12 percent from the top")
        // At the photo's edge a step changes nothing, and the value says the corner is there.
        var step: Int = 0
        while step < 40 {
            editor.nudge(0, outward: true)
            step += 1
        }
        XCTAssertEqual(editor.corners.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(editor.cornerValue(0), "0 percent from the left, 0 percent from the top")
    }
}
#endif
