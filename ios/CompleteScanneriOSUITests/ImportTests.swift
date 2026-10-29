import XCTest

// Importing a photo of a document, as a person does it on the Simulator: the app is launched on the
// demo scanner with one photo to import (`-importFixture`; a UI test cannot drive the system's Photos
// or Files pickers, so the photo's bytes come in the environment, as the Files app would hand them
// over). The photo is the test's own fixture (Fixtures/document-photo.png, drawn by
// scripts/make_ios_ui_fixture.py: a sheet on a table, no real document). The page is found, the corner
// editor opens with its corners, Use corners puts the straightened page in the strip, and Save writes
// a PDF in the app's own Documents folder in the Simulator, with Save floating on camera mode's
// viewfinder. The Simulator has no document scanner, so Use Apple's scanner, in camera mode's drawer, is
// dimmed with its reason. Stop in the corner editor ends the import: no page comes in. The page stays when
// Book is picked, which collects pages too; Receipts and the ID card would leave it without a Save, so
// picking either asks first, and Cancel keeps the kind and the page.

final class ImportTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_photoImport_goesThroughTheCornerEditor_andSavesAPDF() throws {
        // Into Document by name: without it the photo goes into the task kept from the test before (Book),
        // which has no Use Apple's scanner.
        let app: XCUIApplication = try launchWithFixture(task: "document")

        let use: XCUIElement = app.buttons["corners.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 120), "The corner editor's Use corners button")
        XCTAssertTrue(app.descendants(matching: .any)["corners.stage"].exists, "The photo with its corners")
        XCTAssertTrue(app.buttons["corners.whole"].exists, "Use whole photo")
        XCTAssertTrue(app.buttons["corners.skip"].exists, "Skip photo")
        waitUntilEnabled(use, timeout: 30)
        use.tap()

        app.openPages(1)
        app.closePages()

        // The Simulator has no document scanner: Use Apple's scanner is in the drawer's Camera group,
        // dimmed, with why, beside our camera's shutter (the viewfinder says there is no camera).
        app.switchToCamera()
        app.openDrawer("camera")
        let scanner: XCUIElement = app.buttons["capture.scanner"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 10), "The Use Apple's scanner button")
        XCTAssertFalse(scanner.isEnabled, "No document scanner in the Simulator")
        XCTAssertTrue(app.staticTexts["scanner.reason"].exists, "Why there is no document scanner")
        app.closeDrawer()
        XCTAssertTrue(app.buttons["camera.shutter"].exists, "The shutter")

        let save: XCUIElement = app.buttons["save.button"]
        waitUntilEnabled(save, timeout: 120)
        save.tap()

        let saved: XCUIElement = app.staticTexts["saved.files"]
        XCTAssertTrue(saved.waitForExistence(timeout: 240), "The saved file's name")
        XCTAssertTrue(saved.label.hasSuffix(".pdf"), saved.label)
        XCTAssertTrue(app.buttons["share.button"].exists, "The saved file's Share button")
    }

    @MainActor
    func test_stop_inTheCornerEditor_endsTheImport() throws {
        let app: XCUIApplication = try launchWithFixture()
        let stop: XCUIElement = app.buttons["corners.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 120), "The corner editor's Stop button")
        stop.tap()

        // Back on the scan screen with the import over: no editor, no progress, no Stop, no page.
        waitUntilGone(app.buttons["corners.use"], timeout: 30)
        waitUntilGone(app.descendants(matching: .any)["import.progress"], timeout: 30)
        XCTAssertFalse(app.buttons["import.stop"].exists, "The scan screen's Stop button")
        app.switchToPrinter()
        XCTAssertTrue(app.buttons["save.button"].waitForExistence(timeout: 30), "The printer screen")
        XCTAssertEqual(app.descendants(matching: .any)["capture.pages"].firstMatch.label, "0 pages",
                       "A page came in after Stop")
        XCTAssertFalse(app.buttons["save.button"].isEnabled, "Save with nothing to save")
    }

    @MainActor
    func test_book_keepsThePage_photoAndTheIdCardAskFirst() throws {
        let app: XCUIApplication = try launchWithFixture(task: "document")
        let use: XCUIElement = app.buttons["corners.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 120), "The corner editor's Use corners button")
        waitUntilEnabled(use, timeout: 30)
        use.tap()
        app.openPages(1)
        app.closePages()

        app.switchToCamera()
        XCTAssertEqual(app.chipTitle, "Document")
        for kind in ["photos", "idCard"] {
            let item: XCUIElement = app.descendants(matching: .any)["kinds.\(kind)"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 30), "The \(kind) kind")
            app.waitUntilEnabled(item, "The \(kind) kind")
            item.tap()
            let question: XCUIElement = app.alerts["Keep the page?"].firstMatch
            XCTAssertTrue(question.waitForExistence(timeout: 10), "Asked before \(kind)")
            // First match: the Simulator lists an alert's button twice.
            XCTAssertTrue(question.buttons["Save PDF first"].firstMatch.exists, "Save PDF first")
            XCTAssertTrue(question.buttons["Discard 1 page"].firstMatch.exists, "Discard 1 page")
            question.buttons["Cancel"].firstMatch.tap()
            waitUntilGone(question, timeout: 10)
            XCTAssertEqual(app.chipTitle, "Document", "Cancel keeps the kind")
            XCTAssertEqual(app.pagesButton.label, "1 page", "Cancel keeps the page")
            XCTAssertEqual(app.buttons["save.button"].label, "Save PDF \u{00B7} 1")
        }

        // Book is two kinds away in camera mode's row, past the ID card: the printer screen's chip is one tap.
        app.switchToPrinter()
        app.pickTask("book")
        XCTAssertEqual(app.chipTitle, "Book")
        XCTAssertEqual(app.pagesButton.label, "1 page", "Book keeps the page")
        XCTAssertTrue(app.buttons["save.button"].isEnabled, "Save still has the page")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Nothing asked for Book")
    }

    /// The app on the demo scanner with the fixture photo to import at launch, into `task` when one is given
    /// (`ScanTask`'s raw value).
    @MainActor
    private func launchWithFixture(task: String? = nil) throws -> XCUIApplication {
        let fixture: URL = try XCTUnwrap(Bundle(for: ImportTests.self).url(forResource: "document-photo", withExtension: "png"),
                                         "The fixture photo in the test bundle")
        let bytes: Data = try Data(contentsOf: fixture)
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture"]
        if let task {
            app.launchArguments += ["-importTask", task]
        }
        app.launchEnvironment["COMPLETESCANNER_IMPORT_FIXTURE"] = bytes.base64EncodedString()
        app.launch()
        return app
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval,
                               file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == false")
        let gone = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result: XCTWaiter.Result = XCTWaiter.wait(for: [gone], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) stayed", file: file, line: line)
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
