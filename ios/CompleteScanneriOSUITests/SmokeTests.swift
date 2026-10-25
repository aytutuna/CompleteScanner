import XCTest

// The app as a person uses it, on the Simulator: launched on the demo scanner alone (`-demoScanner`, so
// the camera does not open by itself), pick Document to PDF among the kinds, scan a page, see it in the page strip, save the PDF, and see the saved file
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

        app.pickTask("document")

        let scan: XCUIElement = app.buttons["scan.button"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "The scan screen's Scan button")
        waitUntilEnabled(scan, timeout: 60)
        scan.tap()

        app.openPages(1)
        app.closePages()

        let save: XCUIElement = app.buttons["save.button"]
        waitUntilEnabled(save, timeout: 120)
        save.tap()

        let saved: XCUIElement = app.staticTexts["saved.files"]
        XCTAssertTrue(saved.waitForExistence(timeout: 240), "The saved file's name")
        XCTAssertTrue(saved.label.hasSuffix(".pdf"), saved.label)
        XCTAssertTrue(app.buttons["share.button"].exists, "The saved file's Share button")
    }

    @MainActor
    func test_printFromSave_showsThePagesAsACopy_andCloseKeepsThem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.pickTask("document")
        let scan: XCUIElement = app.buttons["scan.button"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "The scan screen's Scan button")
        waitUntilEnabled(scan, timeout: 60)
        scan.tap()
        let pages: XCUIElement = app.descendants(matching: .any)["capture.pages"].firstMatch
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 page"), object: pages)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 240), .completed, "1 page in the capture bar")

        let menu: XCUIElement = app.descendants(matching: .any)["save.menu"].firstMatch
        waitUntilEnabled(menu, timeout: 60)
        menu.tap()
        XCTAssertTrue(app.buttons["save.email"].waitForExistence(timeout: 10), "Email\u{2026} in Save's menu")
        let printItem: XCUIElement = app.buttons["save.print"]
        XCTAssertTrue(printItem.waitForExistence(timeout: 10), "Print\u{2026} in Save's menu")
        printItem.tap()

        let close: XCUIElement = app.buttons["copy.discard"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 60), "The copy screen")
        XCTAssertEqual(close.label, "Close")
        waitUntilEnabled(close, timeout: 60)
        close.tap()
        XCTAssertTrue(app.buttons["save.button"].waitForExistence(timeout: 30), "Back on the scan screen")
        XCTAssertEqual(pages.label, "1 page", "The page is still in the queue")
    }

    @MainActor
    func test_settings_presets_saveAPreset_andSeeItListed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["task.chips"].firstMatch.waitForExistence(timeout: 60),
                      "The scan screen")
        let settings: XCUIElement = app.scrolledTo("scan.settings")
        XCTAssertTrue(settings.exists, "The scan screen's Settings row")
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
        // By identifier, first match: the Simulator lists an alert's button twice.
        let confirm: XCUIElement = app.buttons["presets.name.save"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The alert's Save preset")
        confirm.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed, "The alert closed after Save")

        // A List row is not always a button to the test: look among every element.
        let row: XCUIElement = app.descendants(matching: .any)["preset.\(name)"]
        if !row.waitForExistence(timeout: 30) {
            let lines: [String] = app.debugDescription.components(separatedBy: "\n")
                .filter { $0.contains("preset") || $0.contains("Preset") || $0.contains("Alert") }
            XCTFail("The new preset in the list; tree: \(lines.joined(separator: " | "))")
            return
        }
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
