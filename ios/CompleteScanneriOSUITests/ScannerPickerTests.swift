import XCTest

// The scanner picker as a person uses it, on the Simulator and without any network: launched on the
// demo scanner alone (`-demoScanner`: no network scanners, nothing is searched for), printer mode's
// Scanner options list the demo scanner, and no camera; Add by address opens its sheet, which says what is
// wrong with an address that cannot be one before anything is sent. The demo scanner picked there is what
// printer mode scans with; camera mode leaves it remembered, so printer mode finds it again.

final class ScannerPickerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_scannerPicker_listsTheDemoScanner_andAddByAddressExplainsABadAddress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToPrinter()
        app.pickTask("document")
        app.openOptions("Scanner")

        // On iPad the scanners are listed in the sidebar beside the screen.
        let demo: XCUIElement = app.descendants(matching: .any)["scanner.row.mock:demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "The demo scanner in the picker")
        XCTAssertFalse(app.descendants(matching: .any)["source.camera"].firstMatch.exists, "No camera among the scanners")
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
    func test_printerMode_scansWithTheDemoScanner_andKeepsItThroughCameraMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToPrinter()
        app.pickTask("document")
        app.pickScanner("scanner.row.mock:demo")
        XCTAssertFalse(app.switches["options.bothSides"].exists, "Both sides is the camera's")
        app.closeOptions()
        let scan: XCUIElement = app.buttons["scan.button"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "Scan with the demo scanner")
        XCTAssertTrue(app.buttons["save.button"].exists, "Save beside Scan")
        XCTAssertFalse(app.buttons["camera.shutter"].exists, "No shutter in printer mode")
        let row: XCUIElement = app.scrolledTo("options.row.scanner")
        XCTAssertTrue(row.label.contains("Demo Scanner"), row.label)

        app.switchToCamera()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 30), "The shutter in camera mode")
        XCTAssertFalse(scan.exists, "No Scan in camera mode")

        app.switchToPrinter()
        let again: XCUIElement = app.scrolledTo("options.row.scanner")
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Demo Scanner"),
                                              object: again)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 60), .completed, "The demo scanner again: \(again.label)")
        app.waitUntilEnabled(scan, "Scan")
    }
}
