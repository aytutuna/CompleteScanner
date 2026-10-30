import XCTest

// Walks the app's main screens on the demo scanner and keeps a screenshot of each, named by screen, so
// CI's ios-screenshots artifact shows what the screens look like after a change: camera mode (the
// Simulator's viewfinder says there is no camera), its kinds with Receipts picked and its drawer on
// Export, then printer mode, its Scanner sheet, two scanned pages in the page grid (and selecting, one
// ticked), Save's menu and the Export sheet, Settings with My computer and Presets, and the library from
// camera mode; and, on a run of its own, a photo of a page in the page viewer with its filters. A screen
// whose button is not there is left out rather than failed, so the walk stays green while the screens
// change; a "skipped-" screenshot shows what was on screen instead.

final class ScreenshotTests: XCTestCase {
    @MainActor
    func test_mainScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner"]
        app.launch()

        // The mode is kept from run to run: the walk starts in camera mode.
        app.switchToCamera()
        Thread.sleep(forTimeInterval: 1)
        shot("01-camera")
        cameraScreens(app)
        printerScreens(app)
        settingsScreens(app)
        libraryScreens(app)
    }

    /// A photo of a page brought in through the corner editor, opened from the page grid in the page viewer
    /// with its filters shown: the page as the camera saw it (Original) and the other filters beside it.
    @MainActor
    func test_pageViewer() throws {
        let fixture: URL = try XCTUnwrap(Bundle(for: ScreenshotTests.self).url(forResource: "document-photo", withExtension: "png"),
                                         "The fixture photo in the test bundle")
        let app = XCUIApplication()
        app.launchArguments = ["-demoScanner", "-importFixture", "-importTask", "document"]
        app.launchEnvironment["COMPLETESCANNER_IMPORT_FIXTURE"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launch()

        let use: XCUIElement = app.buttons["corners.use"]
        guard use.waitForExistence(timeout: 120), waitUntilEnabled(use, timeout: 30) else {
            shot("skipped-06b-page-viewer")
            return
        }
        use.tap()
        app.openPages(1)
        guard tapIfThere(app, "page.1", for: "06b-page-viewer"),
              tapIfThere(app, "viewer.filters", for: "06b-page-viewer") else { return }
        if element(app, "filter.original").waitForExistence(timeout: 10) {
            // The small pictures of each filter are made off the main thread.
            Thread.sleep(forTimeInterval: 3)
            shot("06b-page-viewer")
        } else {
            shot("skipped-06b-page-viewer")
        }
        if tapIfThere(app, "viewer.text", for: "06c-page-text") {
            let done: XCUIElement = element(app, "text.done")
            if done.waitForExistence(timeout: 10) {
                // The text is read off the main thread: the shot once it is in, or once none was found.
                let ids: [String] = ["text.body", "text.none"]
                let read: XCUIElement = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier IN %@", ids)).firstMatch
                _ = read.waitForExistence(timeout: 60)
                shot("06c-page-text")
                done.tap()
                waitUntilGone(done)
            } else {
                shot("skipped-06c-page-text")
            }
        }
        if tapIfThere(app, "viewer.done", for: "viewer-closed") {
            waitUntilGone(element(app, "viewer.done"))
        }
    }

    /// Camera mode's kinds with Photo picked, and its drawer open on Export.
    @MainActor
    private func cameraScreens(_ app: XCUIApplication) {
        let photo: XCUIElement = element(app, "kinds.photos")
        let document: XCUIElement = element(app, "kinds.document")
        if photo.waitForExistence(timeout: 5) && document.exists {
            photo.tap()
            waitUntilSelected(photo)
            Thread.sleep(forTimeInterval: 1)
            shot("02-kinds-photo")
            document.tap()
            waitUntilSelected(document)
        } else {
            shot("skipped-02-kinds-photo")
        }
        if tapIfThere(app, "drawer.toggle", for: "03-drawer-export") {
            if tapIfThere(app, "drawer.export", for: "03-drawer-export") {
                Thread.sleep(forTimeInterval: 1)
                shot("03-drawer-export")
            }
            if tapIfThere(app, "drawer.toggle", for: "drawer-closed") {
                waitUntilGone(element(app, "drawer"))
            }
        }
    }

    /// Printer mode with the demo scanner picked in its Scanner sheet, two pages scanned, Save's menu and the
    /// Export sheet.
    @MainActor
    private func printerScreens(_ app: XCUIApplication) {
        guard tapIfThere(app, "mode.printer", for: "04-printer") else { return }
        guard element(app, "task.chips").waitForExistence(timeout: 10) else {
            shot("skipped-04-printer")
            return
        }
        Thread.sleep(forTimeInterval: 1)
        shot("04-printer")
        if tapIfThere(app, "options.row.scanner", for: "05-scanner-sheet") {
            let demo: XCUIElement = element(app, "scanner.row.mock:demo")
            if demo.waitForExistence(timeout: 5) {
                demo.tap()
                Thread.sleep(forTimeInterval: 1)
                shot("05-scanner-sheet")
            } else {
                shot("skipped-05-scanner-sheet")
            }
            closeOptions(app)
        }
        let scan: XCUIElement = element(app, "scan.button")
        let pages: XCUIElement = element(app, "capture.pages")
        guard scan.waitForExistence(timeout: 5) && waitUntilEnabled(scan, timeout: 30) else {
            shot("skipped-06-pages")
            return
        }
        scan.tap()
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 page"), object: pages)
        if XCTWaiter.wait(for: [counted], timeout: 60) == .completed {
            // A second page, so the grid shows two across.
            if waitUntilEnabled(scan, timeout: 30) {
                scan.tap()
                let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 pages"), object: pages)
                _ = XCTWaiter.wait(for: [second], timeout: 60)
            }
            pages.tap()
            let done: XCUIElement = element(app, "pages.done")
            if done.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                shot("06-pages")
                selectionScreen(app)
                if done.waitForExistence(timeout: 5) {
                    done.tap()
                    waitUntilGone(done)
                } else {
                    shot("skipped-pages-select-closed")
                    // Down to half height, then away.
                    app.swipeDown()
                    app.swipeDown()
                }
            } else {
                shot("skipped-06-pages")
            }
            if tapIfThere(app, "save.menu", for: "07-save-menu") {
                Thread.sleep(forTimeInterval: 1)
                shot("07-save-menu")
                closeMenu(app, item: element(app, "append.button"))
            }
        } else {
            shot("skipped-06-pages")
        }
        if tapIfThere(app, "options.row.export", for: "08-export-options") {
            if element(app, "options.format").waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                shot("08-export-options")
            } else {
                shot("skipped-08-export-options")
            }
            closeOptions(app)
        }
    }

    /// The page grid selecting, its first page ticked, then Cancel back to Done.
    @MainActor
    private func selectionScreen(_ app: XCUIApplication) {
        guard tapIfThere(app, "pages.select", for: "06b-pages-select") else { return }
        if tapIfThere(app, "page.1", for: "06b-pages-select") {
            waitUntilSelected(element(app, "page.1"))
            Thread.sleep(forTimeInterval: 1)
            shot("06b-pages-select")
        }
        if tapIfThere(app, "pages.cancel", for: "pages-select-closed") {
            _ = element(app, "pages.done").waitForExistence(timeout: 5)
        }
    }

    /// Settings from printer mode's row, with My computer and Presets.
    @MainActor
    private func settingsScreens(_ app: XCUIApplication) {
        guard tapIfThere(app, "scan.settings", for: "09-settings") else { return }
        if element(app, "settings.presets").waitForExistence(timeout: 5) {
            shot("09-settings")
            if tapIfThere(app, "settings.companion", for: "10-my-computer") {
                Thread.sleep(forTimeInterval: 1)
                shot("10-my-computer")
                back(app)
            }
            if tapIfThere(app, "settings.presets", for: "11-presets") {
                if element(app, "presets.save").waitForExistence(timeout: 5) {
                    shot("11-presets")
                } else {
                    shot("skipped-11-presets")
                }
                back(app)
            }
        } else {
            shot("skipped-09-settings")
        }
        let done: XCUIElement = element(app, "settings.done")
        if done.waitForExistence(timeout: 5) {
            done.tap()
            waitUntilGone(done)
        }
    }

    /// The library from camera mode's top bar, its saved files and its scans.
    @MainActor
    private func libraryScreens(_ app: XCUIApplication) {
        if tapIfThere(app, "mode.camera", for: "12-library-saved") {
            _ = element(app, "kinds.row").waitForExistence(timeout: 10)
        }
        guard tapIfThere(app, "open.library", for: "12-library-saved") else { return }
        let part: XCUIElement = app.segmentedControls["library.part"]
        if part.waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 1)
            shot("12-library-saved")
            let scans: XCUIElement = part.buttons["Scans"]
            if scans.waitForExistence(timeout: 5) {
                scans.tap()
                Thread.sleep(forTimeInterval: 1)
                shot("13-library-history")
            } else {
                shot("skipped-13-library-history")
            }
        } else {
            shot("skipped-12-library-saved")
        }
        back(app)
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

    /// Taps the element if it comes, else keeps a "skipped-" screenshot of what is there instead. The
    /// printer screen's list rows (`options.row.*`, Settings) are scrolled into view first.
    @MainActor
    private func tapIfThere(_ app: XCUIApplication, _ id: String, for screen: String) -> Bool {
        let inList: Bool = id.hasPrefix("options.row.") || id == "scan.settings"
        let target: XCUIElement = inList ? app.scrolledTo(id) : element(app, id)
        guard target.waitForExistence(timeout: 5) else {
            shot("skipped-\(screen)")
            return false
        }
        target.tap()
        return true
    }

    /// Closes the open Save menu with a tap on the preview area, or a swipe down when that leaves it open.
    @MainActor
    private func closeMenu(_ app: XCUIApplication, item: XCUIElement) {
        element(app, "preview.area").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !waitUntilGone(item) {
            app.swipeDown()
            waitUntilGone(item)
        }
    }

    /// Closes an option group's sheet with Done.
    @MainActor
    private func closeOptions(_ app: XCUIApplication) {
        let done: XCUIElement = element(app, "options.done")
        if done.waitForExistence(timeout: 5) {
            done.tap()
            waitUntilGone(done)
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
    private func waitUntilSelected(_ element: XCUIElement) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        _ = XCTWaiter.wait(for: [selected], timeout: 5)
    }

    @MainActor
    @discardableResult
    private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }
}
