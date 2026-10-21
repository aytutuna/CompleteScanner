import Foundation

/// When the app is about to end and when it comes to the front, as the platform reports it. `AppState`
/// flushes the settings when the app may end and reads the printers again when it comes back. Each
/// app shell passes its own: the Mac's is `AppKitLifecycle` (CompleteScannerMac, NSApplication's
/// notifications), the iPhone's `UIKitLifecycle` (CompleteScannerIOS, UIApplication's); tests pass a
/// stand-in that sends the events by hand.
@MainActor
public protocol PlatformLifecycle: AnyObject {
    /// Runs `handler` on the main actor when the app may end now: it is about to quit (and, where the
    /// system ends apps in the background without telling them, it has gone to the background). What
    /// must not be lost is written then.
    func observeWillTerminate(_ handler: @escaping @MainActor () -> Void)
    /// Runs `handler` on the main actor each time the app comes to the front.
    func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void)
}
