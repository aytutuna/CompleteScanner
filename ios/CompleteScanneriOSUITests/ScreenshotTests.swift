import XCTest

// Walks the app's main screens on the demo scanner and keeps a screenshot of each, named by screen, so
// CI's ios-screenshots artifact shows what the screens look like after a change. A screen whose button is
// not there is left out rather than failed, so the walk stays green while the screens change.

final class ScreenshotTests: XCTestCase {
    @MainActor
    func test_mainScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        let chip: XCUIElement = app.buttons["task.chip"]
        let launched: Bool = chip.waitForExistence(timeout: 60)
        shot("01-scan")
        if launched {
            chip.tap()
            let tile: XCUIElement = app.buttons["task.document"]
            if tile.waitForExistence(timeout: 5) {
                shot("02-task-sheet")
                tile.tap()
                waitUntilGone(tile)
            }
        }

        let scan: XCUIElement = app.buttons["scan.button"]
        if scan.waitForExistence(timeout: 5) && waitUntilEnabled(scan, timeout: 30) {
            scan.tap()
            if app.descendants(matching: .any)["page.1"].waitForExistence(timeout: 60) {
                shot("03-pages")
                if tapIfThere(app.buttons["save.menu"]) {
                    Thread.sleep(forTimeInterval: 1)
                    shot("04-save-menu")
                    // Up in the status bar, where the tap only closes the menu.
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
                }
            }
        }

        if tapIfThere(app.buttons["scan.settings"]) {
            let presets: XCUIElement = app.buttons["settings.presets"]
            if presets.waitForExistence(timeout: 5) {
                shot("05-settings")
                if tapIfThere(app.buttons["settings.companion"]) {
                    Thread.sleep(forTimeInterval: 1)
                    shot("06-my-computer")
                    back(app)
                }
                if tapIfThere(presets) {
                    if app.buttons["presets.save"].waitForExistence(timeout: 5) {
                        shot("09-presets")
                    }
                    back(app)
                }
            }
            let done: XCUIElement = app.buttons["settings.done"]
            if tapIfThere(done) {
                waitUntilGone(done)
            }
        }

        if tapIfThere(app.buttons["open.library"]) {
            let part: XCUIElement = app.segmentedControls["library.part"]
            if part.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                shot("07-library-saved")
                if tapIfThere(part.buttons["Scans"]) {
                    Thread.sleep(forTimeInterval: 1)
                    shot("08-library-history")
                }
            }
            back(app)
        }
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tapIfThere(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5) else {
            return false
        }
        element.tap()
        return true
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        _ = tapIfThere(app.navigationBars.buttons["BackButton"].firstMatch)
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        _ = XCTWaiter.wait(for: [gone], timeout: 5)
    }
}
