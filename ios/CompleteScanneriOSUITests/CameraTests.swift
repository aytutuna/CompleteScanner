import XCTest

// Our own camera as a person meets it on the Simulator: launched on the demo scanner alone
// (`-demoScanner`), pick Document to PDF, and the scan screen offers Camera, the default, with Apple's
// document scanner below it as Use Apple's scanner (dimmed there with its reason). The Simulator has no
// camera, so the camera screen opens and says so in one line, with the Auto toggle and the shutter
// dimmed, and Done brings the scan screen back. Nothing is photographed and no permission prompt is
// shown.

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

        // Our camera is the task's default; Apple's document scanner stays below it, dimmed in the Simulator.
        let camera: XCUIElement = app.buttons["capture.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 30), "The Camera button")
        let scanner: XCUIElement = app.buttons["capture.scanner"]
        XCTAssertTrue(scanner.exists, "The Use Apple's scanner button")
        XCTAssertFalse(scanner.isEnabled, "No document scanner in the Simulator")
        XCTAssertTrue(app.staticTexts["scanner.reason"].exists, "Why there is no document scanner")
        waitUntilEnabled(camera, timeout: 60)
        camera.tap()

        let message: XCUIElement = app.staticTexts["camera.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "The camera screen's one line")
        XCTAssertEqual(message.label, "No camera here")
        XCTAssertFalse(app.buttons["camera.settings"].exists, "Settings is only for access turned off")
        let shutter: XCUIElement = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.exists, "The shutter")
        XCTAssertFalse(shutter.isEnabled, "No shutter without a camera")
        XCTAssertTrue(app.descendants(matching: .any)["camera.auto"].exists, "The Auto toggle")
        XCTAssertFalse(app.descendants(matching: .any)["camera.lastPage"].exists, "No page taken yet")

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
