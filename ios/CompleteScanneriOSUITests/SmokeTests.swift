import XCTest

// The app as a person uses it, on the Simulator: launched on the demo scanner alone (`-demoScanner`),
// pick Document to PDF, scan a page, see it in the page strip, save the PDF, and see the saved file
// with its Share button; and open Settings, open Presets, save the settings as a preset and see it
// listed (I15). The demo scanner draws made-up pages, so no scanner, camera or network is needed, and
// the PDF goes to the app's own Documents folder in the Simulator.

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
    func test_settings_presets_saveAPreset_andSeeItListed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        let settings: XCUIElement = app.buttons["open.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60), "The start screen's Settings button")
        settings.tap()

        let presets: XCUIElement = app.buttons["settings.presets"]
        XCTAssertTrue(presets.waitForExistence(timeout: 30), "Presets in Settings")
        presets.tap()

        let save: XCUIElement = app.buttons["presets.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "Save preset")
        save.tap()

        // A name of its own, so a preset left by an earlier run on the same Simulator is not mistaken for it.
        let name: String = "Smoke \(Int(Date().timeIntervalSince1970) % 100_000)"
        let alert: XCUIElement = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "The preset's name")
        let field: XCUIElement = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The name field")
        field.tap()
        field.typeText(name)
        // By identifier: the list's Save preset button carries the same label.
        let confirm: XCUIElement = app.buttons["presets.name.save"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The alert's Save preset")
        confirm.tap()

        let row: XCUIElement = app.buttons["preset.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The new preset in the list")
        XCTAssertEqual(row.label, "\(name) preset")
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
