import XCTest

// Several photos in one shot, as a person does it on the Simulator (I13): the app is launched on the demo
// scanner with one photo to import into the Photos task (`-importFixture` with `-importTask photos`; the
// Simulator has no camera, and a UI test cannot drive the system's pickers, so the photo's bytes come in
// the environment, as a camera's shot would be read). The photo is the test's own fixture
// (Fixtures/photos-on-table.png, drawn by scripts/make_ios_ui_fixture.py: two prints with white borders on
// a dark table, no picture of anything). Both prints are found (Vision's rectangles, or the photo search of
// the whole shot where Vision finds none), the photo review opens with a card for each, and Save writes two
// JPEGs in the app's own Documents folder in the Simulator.

final class PhotosTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_twoPrintsInOneShot_underThePhotosTask_saveTwoJPEGs() throws {
        let fixture: URL = try XCTUnwrap(Bundle(for: PhotosTests.self).url(forResource: "photos-on-table", withExtension: "png"),
                                         "The fixture photo in the test bundle")
        let bytes: Data = try Data(contentsOf: fixture)
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture", "-importTask", "photos"]
        app.launchEnvironment["LAZYSCAN_IMPORT_FIXTURE"] = bytes.base64EncodedString()
        app.launch()

        let save: XCUIElement = app.buttons["review.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 180), "The photo review's Save button")
        XCTAssertTrue(app.descendants(matching: .any)["review.card.1"].exists, "The first print's card")
        XCTAssertTrue(app.descendants(matching: .any)["review.card.2"].exists, "The second print's card")
        XCTAssertFalse(app.descendants(matching: .any)["review.card.3"].exists, "Only the two prints")
        // Keep carries the toggle trait, so it is not among the buttons.
        XCTAssertTrue(app.descendants(matching: .any)["review.keep.1"].exists, "Keep on each card")
        XCTAssertTrue(app.buttons["review.crop.1"].exists, "Fix crop on each card")
        XCTAssertTrue(app.buttons["review.cancel"].exists, "Cancel")
        XCTAssertEqual(save.label, "Save 2 photos")
        waitUntilEnabled(save, timeout: 60)
        save.tap()

        let saved: XCUIElement = app.staticTexts["saved.files"]
        XCTAssertTrue(saved.waitForExistence(timeout: 240), "The saved files' names")
        let names: [String] = saved.label.components(separatedBy: ", ")
        XCTAssertEqual(names.count, 2, saved.label)
        for name in names {
            XCTAssertTrue(name.hasSuffix(".jpg"), name)
        }
        XCTAssertFalse(save.exists, "The review closed once saved")
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
