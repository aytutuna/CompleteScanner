import XCTest

// By identifier among every element: toolbar items and some rows are not buttons in the Simulator's tree.

extension XCUIApplication {
    /// Picks a task the way a person does on the iPhone: the scan screen's task chip opens the task sheet,
    /// the task's tile sets it up and the sheet closes. `task` is the tile's name ("document").
    @MainActor
    func pickTask(_ task: String, file: StaticString = #filePath, line: UInt = #line) {
        let chip: XCUIElement = descendants(matching: .any)["task.chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 60), "The scan screen's task chip", file: file, line: line)
        chip.tap()
        let tile: XCUIElement = descendants(matching: .any)["task.\(task)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "The task sheet's \(task) tile", file: file, line: line)
        tile.tap()
        waitUntilGone(tile, "The task sheet closed", file: file, line: line)
    }

    /// Opens the scan screen's Options, where how the task is taken, Apple's scanner and the PDF's
    /// choices are.
    @MainActor
    func openOptions(file: StaticString = #filePath, line: UInt = #line) {
        var group: XCUIElement = descendants(matching: .any)["options.group"].firstMatch
        if !group.waitForExistence(timeout: 30) {
            group = buttons["Options"].firstMatch
        }
        XCTAssertTrue(group.waitForExistence(timeout: 5), "The scan screen's Options", file: file, line: line)
        group.tap()
    }

    /// Waits for the capture bar to count `count` pages, then opens the page strip's sheet and waits for
    /// the last page's cell.
    @MainActor
    func openPages(_ count: Int, timeout: TimeInterval = 240, file: StaticString = #filePath, line: UInt = #line) {
        let pages: XCUIElement = descendants(matching: .any)["capture.pages"].firstMatch
        let label: String = count == 1 ? "1 page" : "\(count) pages"
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: pages)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: timeout), .completed,
                       "\(label) in the capture bar", file: file, line: line)
        pages.tap()
        let cell: XCUIElement = descendants(matching: .any)["page.\(count)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "Page \(count) in the page strip", file: file, line: line)
    }

    /// Closes the page strip's sheet with Done.
    @MainActor
    func closePages(file: StaticString = #filePath, line: UInt = #line) {
        let done: XCUIElement = descendants(matching: .any)["pages.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The page strip's Done", file: file, line: line)
        done.tap()
        waitUntilGone(done, "The page strip closed", file: file, line: line)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, _ message: String, file: StaticString, line: UInt) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 30), .completed, message, file: file, line: line)
    }
}
