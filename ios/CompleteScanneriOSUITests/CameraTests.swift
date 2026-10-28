import XCTest

// Camera mode as a person meets it on the Simulator: launched on the demo scanner alone (`-demoScanner`),
// the viewfinder is the scan screen. The Simulator has no camera, so the viewfinder says so in one line,
// the shutter is dimmed and no permission prompt is shown; the kinds sit in a row under it, and the chevron
// swaps them for the options drawer, whose Camera group has Auto, Both sides and Use Apple's scanner
// (dimmed there with its reason). The printer button switches to printer mode and its camera button back.
// Nothing is photographed.

final class CameraTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_cameraMode_showsTheNoCameraState_inTheSimulator() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToCamera()
        app.pickTask("document")

        let message: XCUIElement = app.staticTexts["camera.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "The viewfinder's one line")
        XCTAssertEqual(message.label, "No camera here")
        XCTAssertFalse(app.buttons["camera.settings"].exists, "Settings is only for access turned off")
        let shutter: XCUIElement = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.exists, "The shutter")
        XCTAssertFalse(shutter.isEnabled, "No shutter without a camera")
        let pages: XCUIElement = app.descendants(matching: .any)["camera.pages"].firstMatch
        XCTAssertTrue(pages.exists, "The pages")
        XCTAssertEqual(pages.label, "0 pages")
        XCTAssertFalse(app.buttons["save.button"].exists, "No Save before there are pages")
        XCTAssertTrue(app.buttons["import.photos"].exists, "Photos")
        XCTAssertTrue(app.buttons["import.files"].exists, "Files")
        XCTAssertFalse(app.buttons["scan.button"].exists, "No Scan in camera mode")

        // Apple's document scanner is in the drawer's Camera group, dimmed in the Simulator.
        app.openDrawer("camera")
        XCTAssertTrue(app.descendants(matching: .any)["camera.auto"].firstMatch.exists, "The Auto switch")
        XCTAssertTrue(app.switches["options.bothSides"].firstMatch.exists, "Both sides")
        let scanner: XCUIElement = app.buttons["capture.scanner"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 10), "The Use Apple's scanner button")
        XCTAssertFalse(scanner.isEnabled, "No document scanner in the Simulator")
        XCTAssertTrue(app.staticTexts["scanner.reason"].exists, "Why there is no document scanner")
        XCTAssertFalse(app.descendants(matching: .any)["kinds.row"].exists, "The drawer in the kinds' place")
        app.openDrawer("export")
        XCTAssertTrue(app.descendants(matching: .any)["drawer.format"].firstMatch.waitForExistence(timeout: 10),
                      "The format in Export")
        XCTAssertTrue(app.descendants(matching: .any)["chip.more"].firstMatch.exists, "More of Export")
        app.closeDrawer()
        XCTAssertEqual(app.chipTitle, "Document")
    }

    @MainActor
    func test_swipingAKindIntoTheMiddle_picksIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToCamera()
        app.pickTask("photos")

        // With Photos in the middle the leftmost kind showing is Photos too; once Receipts is dragged to the
        // middle Photos still shows on the left, so this catches the leftmost kind being taken for the middle.
        let row: XCUIElement = app.descendants(matching: .any)["kinds.row"].firstMatch
        let receipts: XCUIElement = app.descendants(matching: .any)["kinds.receipts"].firstMatch
        XCTAssertTrue(receipts.waitForExistence(timeout: 10), "The receipts kind")
        let photos: XCUIElement = app.descendants(matching: .any)["kinds.photos"].firstMatch
        let centred = XCTNSPredicateExpectation(predicate: NSPredicate { (_: Any?, _: [String: Any]?) -> Bool in
            abs(photos.frame.midX - row.frame.midX) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centred], timeout: 10), .completed, "Photos in the row's middle once picked")
        let from: XCUICoordinate = receipts.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to: XCUICoordinate = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: receipts)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 10), .completed, "Receipts picked by the swipe")
        XCTAssertFalse(app.descendants(matching: .any)["kinds.photos"].firstMatch.isSelected, "Photos let go")
        XCTAssertEqual(abs(receipts.frame.midX - row.frame.midX), 0, accuracy: 2, "Receipts in the row's middle")
    }

    @MainActor
    func test_printerButton_andCameraButton_switchTheMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToCamera()
        app.switchToPrinter()
        XCTAssertTrue(app.buttons["scan.button"].waitForExistence(timeout: 30), "Scan in printer mode")
        XCTAssertFalse(app.buttons["camera.shutter"].exists, "No shutter in printer mode")
        XCTAssertTrue(app.descendants(matching: .any)["capture.pages"].firstMatch.exists, "The pages")
        app.switchToCamera()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30), "The shutter again")
        XCTAssertFalse(app.buttons["scan.button"].exists, "No Scan in camera mode")
    }
}
