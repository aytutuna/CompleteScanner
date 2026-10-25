import XCTest

// Importing a photo of a document, as a person does it on the Simulator: the app is launched on the
// demo scanner with one photo to import (`-importFixture`; a UI test cannot drive the system's Photos
// or Files pickers, so the photo's bytes come in the environment, as the Files app would hand them
// over). The photo is the test's own fixture (Fixtures/document-photo.png, drawn by
// scripts/make_ios_ui_fixture.py: a sheet on a table, no real document). The page is found, the corner
// editor opens with its corners, Use corners puts the straightened page in the strip, and Save writes
// a PDF in the app's own Documents folder in the Simulator. The Simulator has no document scanner, so
// Use Apple's scanner is dimmed with its reason, while Camera (our own, the default) stays available.
// Stop in the corner editor ends the import: no page comes in.

final class ImportTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_photoImport_goesThroughTheCornerEditor_andSavesAPDF() throws {
        let app: XCUIApplication = try launchWithFixture()

        let use: XCUIElement = app.buttons["corners.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 120), "The corner editor's Use corners button")
        XCTAssertTrue(app.descendants(matching: .any)["corners.stage"].exists, "The photo with its corners")
        XCTAssertTrue(app.buttons["corners.whole"].exists, "Use whole photo")
        XCTAssertTrue(app.buttons["corners.skip"].exists, "Skip photo")
        waitUntilEnabled(use, timeout: 30)
        use.tap()

        app.openPages(1)
        app.closePages()

        // The Simulator has no document scanner: Use Apple's scanner is in the Camera options, dimmed, with
        // why; our camera, the default, is there too (its own screen says there is no camera).
        app.openOptions("Camera")
        let scanner: XCUIElement = app.buttons["capture.scanner"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 10), "The Use Apple's scanner button")
        XCTAssertFalse(scanner.isEnabled, "No document scanner in the Simulator")
        XCTAssertTrue(app.staticTexts["scanner.reason"].exists, "Why there is no document scanner")
        app.closeOptions()
        XCTAssertTrue(app.buttons["capture.camera"].exists, "The Camera button")

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
        XCTAssertTrue(app.buttons["save.button"].waitForExistence(timeout: 30), "The scan screen")
        waitUntilGone(app.descendants(matching: .any)["import.progress"], timeout: 30)
        XCTAssertFalse(app.buttons["import.stop"].exists, "The scan screen's Stop button")
        XCTAssertEqual(app.descendants(matching: .any)["capture.pages"].firstMatch.label, "0 pages",
                       "A page came in after Stop")
        XCTAssertFalse(app.buttons["save.button"].isEnabled, "Save with nothing to save")
    }

    /// The app on the demo scanner with the fixture photo to import at launch.
    @MainActor
    private func launchWithFixture() throws -> XCUIApplication {
        let fixture: URL = try XCTUnwrap(Bundle(for: ImportTests.self).url(forResource: "document-photo", withExtension: "png"),
                                         "The fixture photo in the test bundle")
        let bytes: Data = try Data(contentsOf: fixture)
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture"]
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
