#if os(iOS)
import UIKit
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The iPhone's side of the network scanner connection (I11): UIKit's background time for a scan job
// (`UIKitBackgroundActivity`, here with begin and end of its own, so the test host's application is
// never involved) and the shell's internal entry point that puts an eSCL connection beside the demo
// scanner. The connection itself is checked in the shared suite (EsclClientTests, EsclLoopbackTests).

private typealias FakeExpiry = @MainActor () -> Void

/// How many times a handler ran.
@MainActor
private final class FakeCount {
    var value: Int = 0
}

/// Background tasks begun and ended by hand.
@MainActor
private final class FakeBackgroundTasks {
    var begun: [String] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    var handlers: [UIBackgroundTaskIdentifier: FakeExpiry] = [:]
    var next: Int = 1
    var refuse: Bool = false
    /// The background time left, as UIApplication.backgroundTimeRemaining reports it.
    var remaining: TimeInterval = TimeInterval.greatestFiniteMagnitude

    func begin(_ name: String, _ expired: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        if refuse {
            return .invalid
        }
        let identifier: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: next)
        next += 1
        begun.append(name)
        handlers[identifier] = expired
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }
}

final class IOSNetworkScannerTests: XCTestCase {
    @MainActor
    private func makeActivity(_ tasks: FakeBackgroundTasks) -> UIKitBackgroundActivity {
        UIKitBackgroundActivity(begin: { (name: String, expired: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier in
            tasks.begin(name, expired)
        }, end: { (identifier: UIBackgroundTaskIdentifier) in
            tasks.end(identifier)
        }, remaining: { () -> TimeInterval in
            tasks.remaining
        })
    }

    @MainActor
    func test_backgroundActivity_nearTheEndOfItsTime_stopsTheWorkAndKeepsTheTaskUntilGivenBack() {
        let tasks: FakeBackgroundTasks = FakeBackgroundTasks()
        let activity: UIKitBackgroundActivity = makeActivity(tasks)
        let stopped: FakeCount = FakeCount()
        let token: Int? = activity.beginActivity("Scanning on Office MFP", expired: {
            stopped.value += 1
        })
        // In front, or with time to spare in the background: the work goes on.
        activity.checkRemaining()
        tasks.remaining = 25
        activity.checkRemaining()
        XCTAssertEqual(stopped.value, 0)

        // A few seconds before the system's time is up, the work is told to stop, once; the task stays so
        // the job's deletion can still be sent.
        tasks.remaining = UIKitBackgroundActivity.windDownTime - 1
        activity.checkRemaining()
        activity.checkRemaining()
        XCTAssertEqual(stopped.value, 1)
        XCTAssertTrue(tasks.ended.isEmpty)
        XCTAssertEqual(activity.runningCount, 1)

        // The work gives the time back once it has wound down.
        activity.endActivity(token ?? 0)
        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_backgroundActivity_whenTimeRunsOutWhileWindingDown_endsTheTaskWithoutStoppingTheWorkTwice() {
        let tasks: FakeBackgroundTasks = FakeBackgroundTasks()
        let activity: UIKitBackgroundActivity = makeActivity(tasks)
        let stopped: FakeCount = FakeCount()
        _ = activity.beginActivity("Scanning on Office MFP", expired: {
            stopped.value += 1
        })
        tasks.remaining = 2
        activity.checkRemaining()
        XCTAssertEqual(stopped.value, 1)
        let identifier: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 1)
        guard let handler = tasks.handlers[identifier] else {
            XCTFail("No expiration handler")
            return
        }
        // The deletion did not finish in time: the system's expiration ends the task.
        handler()
        XCTAssertEqual(stopped.value, 1)
        XCTAssertEqual(tasks.ended, [identifier])
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_backgroundActivity_endsItsTaskOnce() {
        let tasks: FakeBackgroundTasks = FakeBackgroundTasks()
        let activity: UIKitBackgroundActivity = makeActivity(tasks)
        let token: Int? = activity.beginActivity("Scanning on Office MFP", expired: {})
        XCTAssertNotNil(token)
        XCTAssertEqual(tasks.begun, ["Scanning on Office MFP"])
        XCTAssertEqual(activity.runningCount, 1)
        activity.endActivity(token ?? 0)
        activity.endActivity(token ?? 0)
        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_backgroundActivity_whenTimeRunsOut_stopsTheWorkThenEndsTheTask() {
        let tasks: FakeBackgroundTasks = FakeBackgroundTasks()
        let activity: UIKitBackgroundActivity = makeActivity(tasks)
        let stopped: FakeCount = FakeCount()
        let token: Int? = activity.beginActivity("Scanning on Office MFP", expired: {
            stopped.value += 1
            // The work stops at once; the task is not ended yet.
            XCTAssertTrue(tasks.ended.isEmpty)
        })
        let identifier: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 1)
        guard let handler = tasks.handlers[identifier] else {
            XCTFail("No expiration handler")
            return
        }
        handler()
        XCTAssertEqual(stopped.value, 1)
        XCTAssertEqual(tasks.ended, [identifier])
        // The job winding down afterwards gives back a task that has ended already: nothing happens.
        activity.endActivity(token ?? 0)
        XCTAssertEqual(tasks.ended, [identifier])
    }

    @MainActor
    func test_backgroundActivity_withoutTimeFromTheSystem_hasNoToken() {
        let tasks: FakeBackgroundTasks = FakeBackgroundTasks()
        tasks.refuse = true
        let activity: UIKitBackgroundActivity = makeActivity(tasks)
        XCTAssertNil(activity.beginActivity("Scanning on Office MFP", expired: {}))
        XCTAssertEqual(activity.runningCount, 0)
    }

    @MainActor
    func test_shell_putsTheNetworkConnectionBesideTheDemoScanner_unlessTheDemoScannerIsAlone() throws {
        let folder: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSNetworkScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let address: ScannerAddress = try ScannerAddress.parse("https://192.0.2.10")
        let network: EsclScannerBackend = IOSShell.networkBackend(endpoints: [EsclScannerBackend.endpoint(address)],
                                                                  trust: EsclTrustStore(directory: folder))
        XCTAssertTrue(network.background is UIKitBackgroundActivity)

        let backends: [any ScannerBackend] = IOSShell.backends(options: IOSLaunchOptions(demoScannerOnly: false), network: network)
        XCTAssertEqual(backends.count, 2)
        XCTAssertTrue(backends[0] is MockScannerBackend)
        XCTAssertTrue(backends[1] === network)
        // Listed from what it was given; no network search, nothing sent.
        network.startBrowsing()
        XCTAssertEqual(network.devices.count, 1)
        XCTAssertEqual(network.devices.first?.id, "escl:https://192.0.2.10")
        XCTAssertEqual(network.devices.first?.transport, "Network")
        network.stopBrowsing()

        let demoOnly: [any ScannerBackend] = IOSShell.backends(options: IOSLaunchOptions(demoScannerOnly: true), network: network)
        XCTAssertEqual(demoOnly.count, 1)
        // Without network scanners passed in (tests, previews) the demo scanner is alone; the app passes its
        // own (`backends(options:networkScanners:)`, IOSScannerPickerTests).
        XCTAssertEqual(IOSShell.backends(options: IOSLaunchOptions(demoScannerOnly: false)).count, 1)
    }
}
#endif
