#if os(iOS)
import CompleteScannerKit
import Foundation
import UIKit

/// The iPhone's and iPad's `PlatformLifecycle`: UIApplication's notifications, delivered on the main
/// queue. iOS usually ends an app in the background without telling it, so going to the background
/// counts as "may end now" too, as well as the will-terminate it sends when it does tell.
@MainActor
public final class UIKitLifecycle: PlatformLifecycle {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// Listens on `center` (the default center; a center of their own in tests).
    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    public func observeWillTerminate(_ handler: @escaping @MainActor () -> Void) {
        observe(UIApplication.didEnterBackgroundNotification, handler)
        observe(UIApplication.willTerminateNotification, handler)
    }

    public func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void) {
        observe(UIApplication.didBecomeActiveNotification, handler)
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
