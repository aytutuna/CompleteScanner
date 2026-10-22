import XCTest

// Separate documents on the iPhone (I14), as a person does it on the Simulator: the app is launched on the
// demo scanner with a PDF of three pages to import into the Separate documents task (`-importFixture` with
// `-importTask batch`): a page, the Patch T separator sheet, and another page. The sheet is found on its
// page (its bars are measured at the page's real size), marked as a separator and left out, so Save writes
// two PDFs, one page each. The fixture (Fixtures/batch.pdf, drawn by scripts/make_ios_ui_fixture.py) holds
// grey lines and the sheet's bars on Letter pages, no real document.

final class BatchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_aPatchCodeSheetBetweenTwoPages_savesTwoPDFs() throws {
        let fixture: URL = try XCTUnwrap(Bundle(for: BatchTests.self).url(forResource: "batch", withExtension: "pdf"),
                                         "The fixture PDF in the test bundle")
        let bytes: Data = try Data(contentsOf: fixture)
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture", "-importTask", "batch"]
        app.launchEnvironment["COMPLETESCANNER_IMPORT_FIXTURE"] = bytes.base64EncodedString()
        app.launch()

        let last: XCUIElement = app.descendants(matching: .any)["page.3"]
        XCTAssertTrue(last.waitForExistence(timeout: 240), "The third page in the page strip")
        let sheet: XCUIElement = app.descendants(matching: .any)["page.2"]
        XCTAssertTrue(sheet.label.contains("Separator"), sheet.label)
        XCTAssertTrue(last.label.contains("Document 2"), last.label)
        XCTAssertTrue(app.buttons["task.newDocument"].exists, "New document")
        XCTAssertTrue(app.buttons["separator.save"].exists, "Separator sheet")

        let save: XCUIElement = app.buttons["save.button"]
        waitUntilEnabled(save, timeout: 120)
        save.tap()

        let saved: XCUIElement = app.staticTexts["saved.files"]
        XCTAssertTrue(saved.waitForExistence(timeout: 240), "The saved files' names")
        let names: [String] = saved.label.components(separatedBy: ", ")
        XCTAssertEqual(names.count, 2, saved.label)
        for name in names {
            XCTAssertTrue(name.hasSuffix(".pdf"), name)
        }
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
