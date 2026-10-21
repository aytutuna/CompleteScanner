import XCTest

// The app as a person uses it, on the Simulator: launched on the demo scanner alone (`-demoScanner`),
// pick Document to PDF, scan a page, see it in the page strip, save the PDF, and see the saved file
// with its Share button. The demo scanner draws made-up pages, so no scanner, camera or network is
// needed, and the PDF goes to the app's own Documents folder in the Simulator.

final class SmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_documentTask_onTheDemoScanner_scansAndSavesAPDF() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        let tile: XCUIElement = app.buttons["task.document"]
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "The start screen's Document to PDF tile")
        tile.tap()

        let scan: XCUIElement = app.buttons["scan.button"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "The scan screen's Scan button")
        waitUntilEnabled(scan, timeout: 60)
        scan.tap()

        let page: XCUIElement = app.descendants(matching: .any)["page.1"]
        XCTAssertTrue(page.waitForExistence(timeout: 240), "The scanned page in the page strip")

        let save: XCUIElement = app.buttons["save.button"]
        waitUntilEnabled(save, timeout: 120)
        save.tap()

        let saved: XCUIElement = app.staticTexts["saved.files"]
        XCTAssertTrue(saved.waitForExistence(timeout: 240), "The saved file's name")
        XCTAssertTrue(saved.label.hasSuffix(".pdf"), saved.label)
        XCTAssertTrue(app.buttons["share.button"].exists, "The saved file's Share button")
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "isEnabled == true")
        let enabled = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result: XCTWaiter.Result = XCTWaiter.wait(for: [enabled], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) stayed disabled", file: file, line: line)
    }
}
