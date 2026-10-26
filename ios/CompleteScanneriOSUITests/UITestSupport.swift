import XCTest

// By identifier among every element: toolbar items and some rows are not buttons in the Simulator's tree.

extension XCUIApplication {
    /// The kinds in camera mode's row, left to right (`IOSShell.cameraKinds`).
    static let cameraKinds: [String] = ["photos", "receipts", "document", "idCard", "book", "text"]

    /// Waits for the scan screen in either mode and says which: true for camera mode (its kinds row), false
    /// for printer mode (its chips). The app comes back in the mode the last run left.
    @MainActor
    @discardableResult
    func waitForScanScreen(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let row: XCUIElement = descendants(matching: .any)["kinds.row"].firstMatch
        let chips: XCUIElement = descendants(matching: .any)["task.chips"].firstMatch
        let deadline: Date = Date().addingTimeInterval(60)
        while Date() < deadline {
            if row.exists { return true }
            if chips.exists { return false }
            _ = row.waitForExistence(timeout: 1)
        }
        XCTFail("The scan screen", file: file, line: line)
        return false
    }

    /// Camera mode, from printer mode by its camera button; nothing when it is up already.
    @MainActor
    func switchToCamera(file: StaticString = #filePath, line: UInt = #line) {
        guard !waitForScanScreen(file: file, line: line) else { return }
        let button: XCUIElement = descendants(matching: .any)["mode.camera"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The camera button", file: file, line: line)
        waitUntilEnabled(button, "The camera button", file: file, line: line)
        button.tap()
        let row: XCUIElement = descendants(matching: .any)["kinds.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Camera mode's kinds", file: file, line: line)
    }

    /// Printer mode, from camera mode by its printer button; nothing when it is up already. The scanner is
    /// the one picked last, which `pickScanner(_:)` picks when there is none.
    @MainActor
    func switchToPrinter(file: StaticString = #filePath, line: UInt = #line) {
        guard waitForScanScreen(file: file, line: line) else { return }
        let drawer: XCUIElement = descendants(matching: .any)["drawer"].firstMatch
        if drawer.exists {
            closeDrawer(file: file, line: line)
        }
        let button: XCUIElement = descendants(matching: .any)["mode.printer"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The printer button", file: file, line: line)
        waitUntilEnabled(button, "The printer button", file: file, line: line)
        button.tap()
        let chips: XCUIElement = descendants(matching: .any)["task.chips"].firstMatch
        XCTAssertTrue(chips.waitForExistence(timeout: 30), "The printer screen's kinds", file: file, line: line)
    }

    /// Picks what is scanned the way a person does, in either mode: the kind's chip in the printer screen's
    /// top row, swiped into view when the row has scrolled it off, or the kind in camera mode's row, reached
    /// a neighbour at a time as each tap centres it. `task` is the kind's name ("document", "photos",
    /// "receipts", "idCard", "book", "text"). The kind already picked changes nothing, and the app comes
    /// back on the task the last run left, so that one is set up afresh by way of another kind.
    @MainActor
    func pickTask(_ task: String, file: StaticString = #filePath, line: UInt = #line) {
        if waitForScanScreen(file: file, line: line) {
            pickCameraKind(task, file: file, line: line)
            return
        }
        let chips: XCUIElement = descendants(matching: .any)["task.chips"].firstMatch
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
        waitUntilEnabled(chip, "The \(task) chip", file: file, line: line)
        chip.tap()
        waitUntilSelected(chip, "The \(task) chip picked", file: file, line: line)
    }

    @MainActor
    private func pickCameraKind(_ task: String, file: StaticString, line: UInt) {
        let drawer: XCUIElement = descendants(matching: .any)["drawer"].firstMatch
        if drawer.exists {
            closeDrawer(file: file, line: line)
        }
        guard let target = XCUIApplication.cameraKinds.firstIndex(of: task) else {
            XCTFail("No kind \(task)", file: file, line: line)
            return
        }
        var index: Int = XCUIApplication.cameraKinds.firstIndex(of: cameraKind) ?? 2
        if index == target {
            index = target == 0 ? 1 : target - 1
            tapCameraKind(XCUIApplication.cameraKinds[index], file: file, line: line)
        }
        while index != target {
            index += index < target ? 1 : -1
            tapCameraKind(XCUIApplication.cameraKinds[index], file: file, line: line)
        }
    }

    @MainActor
    private func tapCameraKind(_ task: String, file: StaticString, line: UInt) {
        let item: XCUIElement = descendants(matching: .any)["kinds.\(task)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 30), "The \(task) kind", file: file, line: line)
        waitUntilEnabled(item, "The \(task) kind", file: file, line: line)
        item.tap()
        waitUntilSelected(item, "The \(task) kind picked", file: file, line: line)
    }

    /// The name of the kind picked in camera mode's row; empty when none is.
    @MainActor
    private var cameraKind: String {
        for kind in XCUIApplication.cameraKinds {
            let item: XCUIElement = descendants(matching: .any)["kinds.\(kind)"].firstMatch
            if item.exists && item.isSelected {
                return kind
            }
        }
        return ""
    }

    /// Opens camera mode's options drawer on a group: "export", "colour", "quality", "flash" or "camera".
    @MainActor
    func openDrawer(_ group: String, file: StaticString = #filePath, line: UInt = #line) {
        let drawer: XCUIElement = descendants(matching: .any)["drawer"].firstMatch
        if !drawer.exists {
            let toggle: XCUIElement = descendants(matching: .any)["drawer.toggle"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 30), "The drawer's chevron", file: file, line: line)
            toggle.tap()
            XCTAssertTrue(drawer.waitForExistence(timeout: 10), "The options drawer", file: file, line: line)
        }
        let button: XCUIElement = descendants(matching: .any)["drawer.\(group)"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The drawer's \(group) group", file: file, line: line)
        button.tap()
        waitUntilSelected(button, "The drawer's \(group) group picked", file: file, line: line)
    }

    /// Closes the options drawer: the kinds come back.
    @MainActor
    func closeDrawer(file: StaticString = #filePath, line: UInt = #line) {
        let toggle: XCUIElement = descendants(matching: .any)["drawer.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "The drawer's chevron", file: file, line: line)
        toggle.tap()
        let row: XCUIElement = descendants(matching: .any)["kinds.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The kinds again", file: file, line: line)
    }

    /// The element by identifier, the printer screen's list scrolled until it is on screen: the list makes
    /// its rows only as they come into view, so one below the fold is not in the tree yet.
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

    /// Opens an option group of the printer screen as its sheet by the row's name: "Scanner" (the scanners,
    /// then the one picked's settings), "Book", "Photos" (Restore faded colours) or "Export" (the format,
    /// Separate documents, the PDF's choices, After saving).
    @MainActor
    func openOptions(_ group: String, file: StaticString = #filePath, line: UInt = #line) {
        let row: XCUIElement = scrolledTo("options.row.\(group.lowercased())")
        XCTAssertTrue(row.exists && row.isHittable, "The \(group) options' row", file: file, line: line)
        row.tap()
        let done: XCUIElement = descendants(matching: .any)["options.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The \(group) options' sheet", file: file, line: line)
    }

    /// In printer mode, opens the Scanner options and picks the scanner there by its row
    /// ("scanner.row.mock:demo" for the demo scanner). The sheet stays open, at full height. The app keeps
    /// the scanner from run to run.
    @MainActor
    func pickScanner(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        openOptions("Scanner", file: file, line: line)
        let row: XCUIElement = descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The \(id) row in the Scanner options", file: file, line: line)
        waitUntilEnabled(row, "The \(id) row", file: file, line: line)
        row.tap()
        waitUntilSelected(row, "\(id) picked", file: file, line: line)
        growOptions()
    }

    /// Drags the Scanner options' sheet from half height to full: the scanner's settings sit below the
    /// list, and the list makes its rows only once they come on screen.
    @MainActor
    func growOptions() {
        let bar: XCUIElement = navigationBars["Scanner"].firstMatch
        guard bar.waitForExistence(timeout: 10) else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
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

    /// The title of the kind picked, in either mode: "Document"; empty when none is.
    @MainActor
    var chipTitle: String {
        for kind in XCUIApplication.cameraKinds {
            for id in ["task.\(kind)", "kinds.\(kind)"] {
                let chip: XCUIElement = descendants(matching: .any)[id].firstMatch
                if chip.exists && chip.isSelected {
                    return chip.label
                }
            }
        }
        return ""
    }

    /// The pages' button of the mode shown: camera mode's stack or the printer screen's capture bar.
    @MainActor
    var pagesButton: XCUIElement {
        let stack: XCUIElement = descendants(matching: .any)["camera.pages"].firstMatch
        return stack.exists ? stack : descendants(matching: .any)["capture.pages"].firstMatch
    }

    /// Waits for the pages' button to count `count` pages, then opens the page strip's sheet and waits for
    /// the last page's cell.
    @MainActor
    func openPages(_ count: Int, timeout: TimeInterval = 240, file: StaticString = #filePath, line: UInt = #line) {
        waitForScanScreen(file: file, line: line)
        let pages: XCUIElement = pagesButton
        let label: String = count == 1 ? "1 page" : "\(count) pages"
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: pages)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: timeout), .completed,
                       "\(label) on the pages' button", file: file, line: line)
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
    func waitUntilEnabled(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 60,
                          file: StaticString = #filePath, line: UInt = #line) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "\(message) enabled",
                       file: file, line: line)
    }

    @MainActor
    private func waitUntilSelected(_ element: XCUIElement, _ message: String, file: StaticString, line: UInt) {
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 30), .completed, message, file: file, line: line)
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, _ message: String, file: StaticString, line: UInt) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 30), .completed, message, file: file, line: line)
    }
}
