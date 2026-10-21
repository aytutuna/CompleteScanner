import XCTest

// Our own camera as a person meets it on the Simulator: launched on the demo scanner alone
// (`-demoScanner`), pick Document to PDF, and the scan screen offers Camera beside Apple's document
// scanner (Doc scanner, the task's default, dimmed there with its reason). The Simulator has no camera,
// so the camera screen opens and says so in one line, and Done brings the scan screen back. Nothing is
// photographed and no permission prompt is shown.

final class CameraTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_ourCamera_showsTheNoCameraState_inTheSimulator() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        let tile: XCUIElement = app.buttons["task.document"]
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "The start screen's Document to PDF tile")
        tile.tap()

        // Apple's document scanner stays on the task, dimmed in the Simulator; our camera is beside it.
        let scanner: XCUIElement = app.buttons["capture.camera"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 30), "The Doc scanner button")
        XCTAssertFalse(scanner.isEnabled, "No document scanner in the Simulator")
        let camera: XCUIElement = app.buttons["capture.live"]
        XCTAssertTrue(camera.exists, "The Camera button")
        waitUntilEnabled(camera, timeout: 60)
        camera.tap()

        let message: XCUIElement = app.staticTexts["camera.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "The camera screen's one line")
        XCTAssertEqual(message.label, "No camera here")
        XCTAssertFalse(app.buttons["camera.settings"].exists, "Settings is only for access turned off")
        let shutter: XCUIElement = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.exists, "The shutter")
        XCTAssertFalse(shutter.isEnabled, "No shutter without a camera")

        app.buttons["camera.done"].tap()
        XCTAssertTrue(app.buttons["save.button"].waitForExistence(timeout: 30), "Back on the scan screen")
        waitUntilGone(message, timeout: 30)
        XCTAssertFalse(app.descendants(matching: .any)["page.1"].exists, "No page came in")
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "isEnabled == true")
        let enabled = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result: XCTWaiter.Result = XCTWaiter.wait(for: [enabled], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) stayed disabled", file: file, line: line)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval,
                               file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == false")
        let gone = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result: XCTWaiter.Result = XCTWaiter.wait(for: [gone], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) stayed", file: file, line: line)
    }
}
