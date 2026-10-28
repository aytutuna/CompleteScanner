import XCTest

// The page grid's Select mode, as a person uses it on the Simulator: the three pages of the batch fixture
// brought in at launch (`-importFixture`, as in BatchTests), Select, the first two pages ticked, Delete and
// its question, and one page is left; and Delete All, which empties the queue and closes the sheet.

final class PagesTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_twoPagesSelected_areDeletedTogether() throws {
        let fixture: URL = try XCTUnwrap(Bundle(for: PagesTests.self).url(forResource: "batch", withExtension: "pdf"),
                                         "The fixture PDF in the test bundle")
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture", "-importTask", "batch"]
        app.launchEnvironment["COMPLETESCANNER_IMPORT_FIXTURE"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launch()

        app.openPages(3)
        let select: XCUIElement = app.descendants(matching: .any)["pages.select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 10), "Select")
        select.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pages.cancel"].firstMatch.waitForExistence(timeout: 10),
                      "Cancel while selecting")
        XCTAssertFalse(app.descendants(matching: .any)["pages.done"].firstMatch.exists, "No Done while selecting")
        for number in [1, 2] {
            let page: XCUIElement = app.descendants(matching: .any)["page.\(number)"].firstMatch
            page.tap()
            let ticked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: page)
            XCTAssertEqual(XCTWaiter.wait(for: [ticked], timeout: 10), .completed, "Page \(number) ticked")
        }
        XCTAssertTrue(app.navigationBars["2 Selected"].waitForExistence(timeout: 10), "2 Selected as the title")

        let delete: XCUIElement = app.descendants(matching: .any)["pages.deleteSelected"].firstMatch
        // Off until the import is done, as Save is in BatchTests.
        app.waitUntilEnabled(delete, "Delete", timeout: 120)
        delete.tap()
        // By its label: a dialog's button may not keep its identifier. The bar's Delete is the other one.
        let confirm: XCUIElement = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete",
                                                                    "pages.deleteSelected")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The question's Delete")
        confirm.tap()

        XCTAssertTrue(app.navigationBars["1 page"].waitForExistence(timeout: 30), "1 page as the title")
        XCTAssertFalse(app.descendants(matching: .any)["page.2"].exists, "No second page")
        app.closePages()
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 page"),
                                                object: app.pagesButton)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 30), .completed, "1 page on the pages' button")
    }

    @MainActor
    func test_deleteAll_emptiesTheQueue_andClosesTheSheet() throws {
        let fixture: URL = try XCTUnwrap(Bundle(for: PagesTests.self).url(forResource: "batch", withExtension: "pdf"),
                                         "The fixture PDF in the test bundle")
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture", "-importTask", "batch"]
        app.launchEnvironment["COMPLETESCANNER_IMPORT_FIXTURE"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launch()

        app.openPages(3)
        let deleteAll: XCUIElement = app.descendants(matching: .any)["pages.deleteAll"].firstMatch
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 10), "Delete All")
        // Off until the import is done.
        app.waitUntilEnabled(deleteAll, "Delete All", timeout: 120)
        deleteAll.tap()
        let confirm: XCUIElement = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete All",
                                                                    "pages.deleteAll")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The question's Delete All")
        confirm.tap()

        let done: XCUIElement = app.descendants(matching: .any)["pages.done"].firstMatch
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 30), .completed, "The page strip closed")
        XCTAssertFalse(app.descendants(matching: .any)["page.1"].exists, "No pages left")
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "0 pages"),
                                                object: app.pagesButton)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 30), .completed, "0 pages on the pages' button")
    }
}
