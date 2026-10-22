import XCTest

extension XCUIApplication {
    /// Picks a task the way a person does on the iPhone: the scan screen's task chip opens the task sheet,
    /// the task's tile sets it up and the sheet closes. `task` is the tile's name ("document").
    @MainActor
    func pickTask(_ task: String, file: StaticString = #filePath, line: UInt = #line) {
        let chip: XCUIElement = buttons["task.chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 60), "The scan screen's task chip", file: file, line: line)
        chip.tap()
        let tile: XCUIElement = buttons["task.\(task)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "The task sheet's \(task) tile", file: file, line: line)
        tile.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: tile)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 30), .completed, "The task sheet closed",
                       file: file, line: line)
    }
}
