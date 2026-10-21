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

/// Time the system gives the app to finish a piece of work once it has gone to the background: the
/// iPhone's is `UIKitBackgroundActivity` (CompleteScannerIOS, `UIApplication.beginBackgroundTask`); the
/// Mac passes none, since a Mac app keeps running in the background; tests pass a stand-in that ends the
/// time by hand. A network scanner's job asks for it while it runs, so a page in flight and the job's
/// deletion on the scanner finish when the user switches apps (`EsclScannerSession`).
@MainActor
public protocol BackgroundActivity: AnyObject {
    /// Asks for time to finish `name` should the app go to the background. When that time is nearly
    /// up, `expired` runs on the main actor (once) and the work must stop at once; the few seconds left
    /// are for it to wind down (a network scan's job deletion), and it gives the time back with
    /// `endActivity` as usual. When the time is up before that, the activity ends by itself.
    /// Returns the token `endActivity` takes, or nil when the system gives no time now.
    func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int?
    /// The work is done (or stopped): gives the time back. A token that has ended already is ignored.
    func endActivity(_ token: Int)
}
