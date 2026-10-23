import XCTest

// Walks the app's main screens on the demo scanner and keeps a screenshot of each, named by screen, so
// CI's ios-screenshots artifact shows what the screens look like after a change. A screen whose button is
// not there is left out rather than failed, so the walk stays green while the screens change; a
// "skipped-" screenshot shows what was on screen instead.

final class ScreenshotTests: XCTestCase {
    @MainActor
    func test_mainScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        let chip: XCUIElement = element(app, "task.chip")
        let launched: Bool = chip.waitForExistence(timeout: 60)
        shot("01-scan")
        if launched {
            chip.tap()
            let tile: XCUIElement = element(app, "task.document")
            if tile.waitForExistence(timeout: 5) {
                shot("02-task-sheet")
                tile.tap()
                waitUntilGone(tile)
            } else {
                shot("skipped-02-task-sheet")
            }
        }

        let scan: XCUIElement = element(app, "scan.button")
        let pages: XCUIElement = element(app, "capture.pages")
        if scan.waitForExistence(timeout: 5) && waitUntilEnabled(scan, timeout: 30) {
            scan.tap()
            let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 page"), object: pages)
            if XCTWaiter.wait(for: [counted], timeout: 60) == .completed {
                pages.tap()
                let done: XCUIElement = element(app, "pages.done")
                if done.waitForExistence(timeout: 5) {
                    Thread.sleep(forTimeInterval: 1)
                    shot("03-pages")
                    done.tap()
                    waitUntilGone(done)
                } else {
                    shot("skipped-03-pages")
                }
                if tapIfThere(app, "save.menu", for: "04-save-menu") {
                    Thread.sleep(forTimeInterval: 1)
                    shot("04-save-menu")
                    closeMenu(app, item: element(app, "append.button"))
                }
            } else {
                shot("skipped-03-pages")
            }
        } else {
            shot("skipped-03-pages")
        }

        if tapIfThere(app, "scan.settings", for: "05-settings") {
            if element(app, "settings.presets").waitForExistence(timeout: 5) {
                shot("05-settings")
                if tapIfThere(app, "settings.companion", for: "06-my-computer") {
                    Thread.sleep(forTimeInterval: 1)
                    shot("06-my-computer")
                    back(app)
                }
                if tapIfThere(app, "settings.presets", for: "09-presets") {
                    if element(app, "presets.save").waitForExistence(timeout: 5) {
                        shot("09-presets")
                    } else {
                        shot("skipped-09-presets")
                    }
                    back(app)
                }
            } else {
                shot("skipped-05-settings")
            }
            let done: XCUIElement = element(app, "settings.done")
            if done.waitForExistence(timeout: 5) {
                done.tap()
                waitUntilGone(done)
            }
        }

        if tapIfThere(app, "open.library", for: "07-library-saved") {
            let part: XCUIElement = app.segmentedControls["library.part"]
            if part.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                shot("07-library-saved")
                let scans: XCUIElement = part.buttons["Scans"]
                if scans.waitForExistence(timeout: 5) {
                    scans.tap()
                    Thread.sleep(forTimeInterval: 1)
                    shot("08-library-history")
                } else {
                    shot("skipped-08-library-history")
                }
            } else {
                shot("skipped-07-library-saved")
            }
            back(app)
        }

        if tapIfThere(app, "options.group", for: "10-options") {
            Thread.sleep(forTimeInterval: 1)
            shot("10-options")
        }
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// By identifier among every element: toolbar items and some rows are not buttons to the test.
    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Taps the element if it comes, else keeps a "skipped-" screenshot of what is there instead.
    @MainActor
    private func tapIfThere(_ app: XCUIApplication, _ id: String, for screen: String) -> Bool {
        let target: XCUIElement = element(app, id)
        guard target.waitForExistence(timeout: 5) else {
            shot("skipped-\(screen)")
            return false
        }
        target.tap()
        return true
    }

    /// Closes the open Save menu with a tap on the task chip, or a swipe down when that leaves it open;
    /// the task sheet is closed again should the tap have reached the chip.
    @MainActor
    private func closeMenu(_ app: XCUIApplication, item: XCUIElement) {
        element(app, "task.chip").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !waitUntilGone(item) {
            app.swipeDown()
            waitUntilGone(item)
        }
        let tasksDone: XCUIElement = element(app, "tasks.done")
        if tasksDone.waitForExistence(timeout: 2) {
            tasksDone.tap()
            waitUntilGone(tasksDone)
        }
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let button: XCUIElement = app.navigationBars.buttons["BackButton"].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
        }
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    @MainActor
    @discardableResult
    private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }
}
