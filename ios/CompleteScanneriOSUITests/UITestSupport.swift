import XCTest

// By identifier among every element: toolbar items and some rows are not buttons in the Simulator's tree.

extension XCUIApplication {
    /// Picks what is scanned the way a person does on the iPhone: the kind's chip in the scan screen's top
    /// row, swiped into view when the row has scrolled it off, sets its task up. `task` is the chip's name
    /// ("document", "photos", "receipts", "idCard", "book", "text"). The chip already picked changes
    /// nothing, and the app comes back on the task the last run left, so that one is set up afresh by way
    /// of another kind.
    @MainActor
    func pickTask(_ task: String, file: StaticString = #filePath, line: UInt = #line) {
        let chips: XCUIElement = descendants(matching: .any)["task.chips"].firstMatch
        XCTAssertTrue(chips.waitForExistence(timeout: 60), "The scan screen's kinds", file: file, line: line)
        let chip: XCUIElement = descendants(matching: .any)["task.\(task)"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "The \(task) chip", file: file, line: line)
        if chip.isSelected {
            tapChip(task == "receipts" ? "document" : "receipts", in: chips, file: file, line: line)
        }
        tapChip(task, in: chips, file: file, line: line)
    }

    @MainActor
    private func tapChip(_ task: String, in chips: XCUIElement, file: StaticString, line: UInt) {
        let chip: XCUIElement = descendants(matching: .any)["task.\(task)"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "The \(task) chip", file: file, line: line)
        // The row keeps the picked chip in its middle, so the one wanted may be off either edge.
        var swipes: Int = 0
        while !chip.isHittable && swipes < 3 {
            if chip.frame.midX < chips.frame.midX {
                chips.swipeRight()
            } else {
                chips.swipeLeft()
            }
            swipes += 1
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 60), .completed, "The \(task) chip enabled",
                       file: file, line: line)
        chip.tap()
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 30), .completed, "The \(task) chip picked",
                       file: file, line: line)
    }

    /// The element by identifier, the scan screen's list scrolled until it is on screen: the list makes its
    /// rows only as they come into view, so one below the fold is not in the tree yet.
    @MainActor
    func scrolledTo(_ id: String) -> XCUIElement {
        let element: XCUIElement = descendants(matching: .any)[id].firstMatch
        var swipes: Int = 0
        while !(element.waitForExistence(timeout: 2) && element.isHittable) && swipes < 8 {
            if swipes < 3 {
                swipeUp()
            } else {
                swipeDown()
            }
            swipes += 1
        }
        return element
    }

    /// Opens an option group of the scan screen as its sheet by the row's name: "Scanner" (the picker and
    /// the scanner's settings), "Camera" (Both sides, Apple's scanner), "Book", "Photos" (Restore faded
    /// colours) or "Export" (the format, Separate documents, the PDF's choices, After saving).
    @MainActor
    func openOptions(_ group: String, file: StaticString = #filePath, line: UInt = #line) {
        let row: XCUIElement = scrolledTo("options.row.\(group.lowercased())")
        XCTAssertTrue(row.exists && row.isHittable, "The \(group) options' row", file: file, line: line)
        row.tap()
        let done: XCUIElement = descendants(matching: .any)["options.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The \(group) options' sheet", file: file, line: line)
    }

    /// Closes the option group's sheet with Done.
    @MainActor
    func closeOptions(file: StaticString = #filePath, line: UInt = #line) {
        let done: XCUIElement = descendants(matching: .any)["options.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The options' Done", file: file, line: line)
        done.tap()
        waitUntilGone(done, "The options' sheet closed", file: file, line: line)
    }

    /// Turns an Options switch on or off by its identifier and waits until it says so. A SwiftUI toggle's
    /// row is not always what takes the tap, so its switch is tapped when the tree has one.
    @MainActor
    func turnSwitch(_ id: String, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let toggle: XCUIElement = switches[id].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "The \(id) switch", file: file, line: line)
        let wanted: String = on ? "1" : "0"
        if (toggle.value as? String) != wanted {
            let inner: XCUIElement = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
        }
        let turned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 10), .completed, "\(id) turned \(on ? "on" : "off")",
                       file: file, line: line)
    }

    /// The title of the kind's chip that is picked: "Document"; empty when none is.
    @MainActor
    var chipTitle: String {
        for kind in ["document", "photos", "receipts", "idCard", "book", "text"] {
            let chip: XCUIElement = descendants(matching: .any)["task.\(kind)"].firstMatch
            if chip.exists && chip.isSelected {
                return chip.label
            }
        }
        return ""
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
