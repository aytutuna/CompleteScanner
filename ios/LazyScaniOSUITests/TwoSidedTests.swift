import XCTest

// Two-sided on the iPhone (I14), as a person does it on the Simulator: a Document with Both sides on in
// camera mode's drawer (Camera), which is the two-sided task under the hood. The app is launched on the demo scanner with a PDF
// of two pages to import into the two-sided task (`-importFixture` with `-importTask twoSided`; the
// Simulator has no camera and a UI test cannot drive the system's pickers, so the file's bytes come in
// the environment, as the Files app would hand them over, and only at launch). The pages come in as Flip
// & capture takes them: the first is the sheet's front, the second its back, as the page strip says; Save
// writes one PDF with both sides. The second case picks Document among the kinds and turns Both sides on
// and off. The fixture (Fixtures/two-sided.pdf, drawn by scripts/make_ios_ui_fixture.py) holds grey lines
// on two Letter pages, no real document.

final class TwoSidedTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_twoPages_underTheTwoSidedTask_saveOnePDFWithBothSides() throws {
        let fixture: URL = try XCTUnwrap(Bundle(for: TwoSidedTests.self).url(forResource: "two-sided", withExtension: "pdf"),
                                         "The fixture PDF in the test bundle")
        let bytes: Data = try Data(contentsOf: fixture)
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture", "-importTask", "twoSided"]
        app.launchEnvironment["COMPLETESCANNER_IMPORT_FIXTURE"] = bytes.base64EncodedString()
        app.launch()

        app.openPages(2)
        let back: XCUIElement = app.descendants(matching: .any)["page.2"]
        XCTAssertTrue(back.label.contains("Sheet 1, back"), back.label)
        let front: XCUIElement = app.descendants(matching: .any)["page.1"]
        XCTAssertTrue(front.label.contains("Sheet 1, front"), front.label)
        app.closePages()
        app.switchToCamera()
        XCTAssertEqual(app.chipTitle, "Document")
        app.openDrawer("camera")
        let bothSides: XCUIElement = app.switches["options.bothSides"].firstMatch
        XCTAssertTrue(bothSides.waitForExistence(timeout: 10), "Both sides in the drawer")
        XCTAssertEqual(bothSides.value as? String, "1")
        XCTAssertTrue(app.descendants(matching: .any)["task.sidesWay"].waitForExistence(timeout: 10),
                      "Flip & capture or fronts first")
        app.closeDrawer()

        let save: XCUIElement = app.buttons["save.button"]
        waitUntilEnabled(save, timeout: 120)
        save.tap()

        let saved: XCUIElement = app.staticTexts["saved.files"]
        XCTAssertTrue(saved.waitForExistence(timeout: 240), "The saved file's name")
        let names: [String] = saved.label.components(separatedBy: ", ")
        XCTAssertEqual(names.count, 1, saved.label)
        XCTAssertTrue(saved.label.hasSuffix(".pdf"), saved.label)
    }

    @MainActor
    func test_document_withBothSidesInOptions_offersHowTheSidesAreTaken() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToCamera()
        app.pickTask("document")
        app.openDrawer("camera")
        let way: XCUIElement = app.descendants(matching: .any)["task.sidesWay"]
        XCTAssertFalse(way.exists, "One side until Both sides is on")
        app.turnSwitch("options.bothSides", on: true)
        XCTAssertTrue(way.waitForExistence(timeout: 10), "Flip & capture or fronts first")
        app.closeDrawer()
        XCTAssertEqual(app.chipTitle, "Document")
        app.openDrawer("camera")
        app.turnSwitch("options.bothSides", on: false)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: way)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "One side again")
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
