#if os(macOS)
import AppKit
import XCTest
@testable import LazyScanMac

// Where the macOS menus and share picker open. Mac only: on Windows the photo review is part of
// the main window, so there is no sheet to look past.

final class FileActionsTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    func test_anchorPoint_atThePointerWhenItIsInside() {
        let pointer = NSPoint(x: 120, y: 450)
        XCTAssertEqual(SystemFileActions.anchorPoint(pointer: pointer, bounds: bounds, overSheet: false), pointer)
    }

    func test_anchorPoint_centreWhenThePointerIsOutside() {
        for pointer in [NSPoint(x: -5, y: 300), NSPoint(x: 400, y: 900), NSPoint(x: 1200, y: -40)] {
            XCTAssertEqual(SystemFileActions.anchorPoint(pointer: pointer, bounds: bounds, overSheet: false),
                           NSPoint(x: 400, y: 300), "\(pointer)")
        }
    }

    func test_anchorPoint_centreWhenTheKeyWindowIsASheet() {
        // The pointer is over the sheet (its Save button), not over the window underneath.
        let pointer = NSPoint(x: 520, y: 80)
        XCTAssertEqual(SystemFileActions.anchorPoint(pointer: pointer, bounds: bounds, overSheet: true),
                       NSPoint(x: 400, y: 300))
    }
}
#endif
