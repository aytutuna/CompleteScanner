#if os(iOS)
import UIKit
import XCTest
@testable import CompleteScannerIOS

// The iPhone's app lifecycle for AppState (`PlatformLifecycle`): going to the background and
// will-terminate both mean "may end now", becoming active reaches its own handler. Each test posts on
// a notification center of its own, so the test host application is never involved.

/// How many times a handler ran.
private final class CallCount {
    var value = 0
}

final class UIKitLifecycleTests: XCTestCase {
    @MainActor
    func test_backgroundAndWillTerminate_bothReachTheEndHandler() async {
        let center = NotificationCenter()
        let lifecycle = UIKitLifecycle(center: center)
        let ended = expectation(description: "may end, twice")
        ended.expectedFulfillmentCount = 2
        let activeCount = CallCount()
        lifecycle.observeWillTerminate {
            ended.fulfill()
        }
        lifecycle.observeDidBecomeActive {
            activeCount.value += 1
        }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willTerminateNotification, object: nil)
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(activeCount.value, 0)
    }

    @MainActor
    func test_didBecomeActive_reachesOnlyItsHandler() async {
        let center = NotificationCenter()
        let lifecycle = UIKitLifecycle(center: center)
        let active = expectation(description: "became active")
        let endedCount = CallCount()
        lifecycle.observeWillTerminate {
            endedCount.value += 1
        }
        lifecycle.observeDidBecomeActive {
            active.fulfill()
        }
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [active], timeout: 5)
        XCTAssertEqual(endedCount.value, 0)
    }
}
#endif
