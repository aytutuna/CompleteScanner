import AppKit
import SwiftUI

public struct CompleteScannerApp: App {
    @StateObject private var state = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup("CompleteScanner") {
            // Minimum size lives on ContentView (700x560) — an outer minimum here
            // would override it and force an oversized window on small screens.
            ContentView()
                .environmentObject(state)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
