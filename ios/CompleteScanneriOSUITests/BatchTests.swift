import XCTest

// Separate documents on the iPhone (I14), as a person does it on the Simulator: a Document with Separate
// documents on in Options' Export, which is the Separate documents task under the hood. The app is launched
// on the demo scanner with a PDF of three pages to import into that task (`-importFixture` with
// `-importTask batch`, at launch since a UI test cannot drive Files): a page, the Patch T separator sheet,
// and another page. The sheet is found on its page (its bars are measured at the page's real size), marked
// as a separator and left out, so Save writes two PDFs, one page each. The second case picks Document in
// the printer screen's kinds, turns Separate documents on in its Export sheet, picks QR code sheets and
// turns it off again. The fixture (Fixtures/batch.pdf, drawn by scripts/make_ios_ui_fixture.py) holds
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

        app.openPages(3)
        let last: XCUIElement = app.descendants(matching: .any)["page.3"]
        let sheet: XCUIElement = app.descendants(matching: .any)["page.2"]
        XCTAssertTrue(sheet.label.contains("Separator"), sheet.label)
        XCTAssertTrue(last.label.contains("Document 2"), last.label)
        app.closePages()
        XCTAssertTrue(app.buttons["task.newDocument"].exists, "New document")
        XCTAssertEqual(app.chipTitle, "Document")
        app.switchToPrinter()
        app.openOptions("Export")
        let separate: XCUIElement = app.switches["options.separate"].firstMatch
        XCTAssertTrue(separate.waitForExistence(timeout: 10), "Separate documents in Export")
        XCTAssertEqual(separate.value as? String, "1")
        XCTAssertTrue(app.buttons["separator.save"].waitForExistence(timeout: 10), "Separator sheet")
        app.closeOptions()

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
    func test_document_withSeparateDocumentsInOptions_offersTheSeparatorSheets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        app.switchToPrinter()
        app.pickTask("document")
        app.openOptions("Export")
        let sheet: XCUIElement = app.buttons["separator.save"]
        XCTAssertFalse(sheet.exists, "One document until Separate documents is on")
        app.turnSwitch("options.separate", on: true)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Separator sheet")
        app.closeOptions()
        XCTAssertTrue(app.buttons["task.newDocument"].exists, "New document")
        XCTAssertEqual(app.chipTitle, "Document")

        app.openOptions("Export")
        let kind: XCUIElement = app.descendants(matching: .any)["separator.kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 10), "Patch code or QR code")
        kind.buttons["QR code"].tap()
        XCTAssertTrue(app.textFields["separator.name"].waitForExistence(timeout: 10), "The QR sheet's name")

        app.turnSwitch("options.separate", on: false)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "One document again")
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
