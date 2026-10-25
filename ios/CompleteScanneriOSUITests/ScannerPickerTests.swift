import XCTest

// The scanner picker as a person uses it, on the Simulator and without any network: launched on the
// demo scanner alone (`-demoScanner`: no network scanners, nothing is searched for), the first row of the
// scan screen's Scanner options opens the picker with the demo scanner listed; Add by address opens its sheet, which says
// what is wrong with an address that cannot be one before anything is sent.

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

        // On iPhone the scanner row opens the picker as a sheet; on iPad the picker is the sidebar.
        let row: XCUIElement = app.buttons["scanner.menu"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The Scanner options' scanner row")
        let sidebar: Bool = app.descendants(matching: .any)["scanners.sidebar"].exists
        if !sidebar {
            row.tap()
        }

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
        if !sidebar {
            app.buttons["scanners.done"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 30), "Back in the Scanner options")
        }
    }
}
