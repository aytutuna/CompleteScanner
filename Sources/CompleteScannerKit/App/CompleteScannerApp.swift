import AppKit
import SwiftUI

public struct CompleteScannerApp: App {
    @StateObject private var state = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup("CompleteScanner") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1080, minHeight: 660)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
