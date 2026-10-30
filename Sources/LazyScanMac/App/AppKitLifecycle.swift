#if os(macOS)
import AppKit
import LazyScanKit
import Foundation

/// The Mac's `PlatformLifecycle`: NSApplication's will-terminate and did-become-active notifications,
/// delivered on the main queue.
@MainActor
public final class AppKitLifecycle: PlatformLifecycle {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// Listens on `center` (the default center; a center of their own in tests).
    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    public func observeWillTerminate(_ handler: @escaping @MainActor () -> Void) {
        observe(NSApplication.willTerminateNotification, handler)
    }

    public func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void) {
        observe(NSApplication.didBecomeActiveNotification, handler)
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let observer: NSObjectProtocol = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observers.append(observer)
    }
}
#endif
