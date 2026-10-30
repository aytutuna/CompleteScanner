#if os(macOS)
import AppKit
import XCTest
@testable import LazyScanMac

// The Mac's app lifecycle for AppState (`PlatformLifecycle`): NSApplication's notifications reach
// the handler that asked for them, and only that one. Each test posts on a notification center of
// its own, so the test runner's application is never involved.

/// How many times a handler ran.
private final class CallCount {
    var value = 0
}

final class AppKitLifecycleTests: XCTestCase {
    @MainActor
    func test_willTerminate_reachesOnlyItsHandler() async {
        let center = NotificationCenter()
        let lifecycle = AppKitLifecycle(center: center)
        let ended = expectation(description: "will terminate")
        let endedCount = CallCount()
        let activeCount = CallCount()
        lifecycle.observeWillTerminate {
            endedCount.value += 1
            ended.fulfill()
        }
        lifecycle.observeDidBecomeActive {
            activeCount.value += 1
        }
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(endedCount.value, 1)
        XCTAssertEqual(activeCount.value, 0)
    }

    @MainActor
    func test_didBecomeActive_reachesItsHandlerEachTime() async {
        let center = NotificationCenter()
        let lifecycle = AppKitLifecycle(center: center)
        let active = expectation(description: "became active twice")
        active.expectedFulfillmentCount = 2
        let endedCount = CallCount()
        lifecycle.observeWillTerminate {
            endedCount.value += 1
        }
        lifecycle.observeDidBecomeActive {
            active.fulfill()
        }
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [active], timeout: 5)
        XCTAssertEqual(endedCount.value, 0)
    }
}
#endif
