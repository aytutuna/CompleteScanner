import XCTest

// The scanner picker as a person uses it, on the Simulator and without any network: launched on the
// demo scanner alone (`-demoScanner`: no network scanners, nothing is searched for), the scan screen's
// Scanner options list Camera and the demo scanner; Add by address opens its sheet, which says what is
// wrong with an address that cannot be one before anything is sent. Picking Camera or the demo scanner
// there makes it the one source: the capture bar has the shutter, or Scan in its place.

final class ScannerPickerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_scannerPicker_listsTheDemoScanner_andAddByAddressExplainsABadAddress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.pickTask("document")
        app.openOptions("Scanner")

        // On iPad the scanners are listed in the sidebar beside the screen.
        let camera: XCUIElement = app.descendants(matching: .any)["source.camera"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 30), "Camera in the picker")
        let demo: XCUIElement = app.descendants(matching: .any)["scanner.row.mock:demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "The demo scanner in the picker")
        XCTAssertTrue(app.descendants(matching: .any)["scanners.empty"].exists, "No scanner found, with the demo scanner alone")

        let add: XCUIElement = app.buttons["scanner.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add by address")
        add.tap()

        let field: XCUIElement = app.textFields["address.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The address field")
        field.tap()
        field.typeText("300.1.1.1")
        app.buttons["address.add"].tap()

        let message: XCUIElement = app.staticTexts["address.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "What is wrong with the address")
        XCTAssertEqual(message.label, "\"300.1.1.1\" is not a valid IP address or host name.")

        app.buttons["address.cancel"].tap()
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "Back in the picker")
        app.closeOptions()
    }

    @MainActor
    func test_cameraOrTheDemoScanner_isTheOneSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.pickTask("document")
        let shutter: XCUIElement = app.buttons["capture.camera"]
        let scan: XCUIElement = app.buttons["scan.button"]
        let row: XCUIElement = app.descendants(matching: .any)["options.row.scanner"].firstMatch

        app.pickSource("scanner.row.mock:demo")
        XCTAssertFalse(app.descendants(matching: .any)["source.camera"].firstMatch.isSelected, "Camera not checked")
        XCTAssertFalse(app.switches["options.bothSides"].exists, "Both sides is the camera's")
        app.closeOptions()
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "Scan with the demo scanner")
        XCTAssertFalse(shutter.exists, "No shutter with a scanner as the source")
        XCTAssertTrue(row.label.contains("Demo Scanner"), row.label)

        app.pickSource("source.camera")
        XCTAssertFalse(app.descendants(matching: .any)["scanner.row.mock:demo"].firstMatch.isSelected,
                       "The demo scanner not checked")
        XCTAssertTrue(app.switches["options.bothSides"].firstMatch.waitForExistence(timeout: 10), "Both sides under Camera")
        app.closeOptions()
        XCTAssertTrue(shutter.waitForExistence(timeout: 30), "The shutter with the camera")
        XCTAssertFalse(scan.exists, "No Scan button with the camera as the source")
        XCTAssertTrue(row.label.contains("Camera"), row.label)
    }
}
