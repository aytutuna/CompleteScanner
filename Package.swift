// swift-tools-version: 6.0
import PackageDescription

// One shared core for the Mac and the iPhone, and a target for each platform's own parts:
// - CompleteScannerKit: everything both apps share (models, the page pipeline, output, settings
//   files, the demo scanner, AppState and the protocols of the system services). No AppKit, UIKit,
//   SwiftUI or ImageCaptureCore.
// - CompleteScannerMac: the Mac's views, its ImageCaptureCore scanners and its system services.
//   Every file is wrapped in `#if os(macOS)`, so it builds to nothing for iOS.
// - CompleteScannerIOS: the iPhone's and iPad's services and views. Every file is wrapped in
//   `#if os(iOS)`, so it builds to nothing for macOS.
// - CompleteScanner: the Mac app.
// iOS 18 needs PackageDescription 6.0; the code stays in the Swift 5 language mode.
let package = Package(
    name: "CompleteScanner",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .executable(name: "CompleteScanner", targets: ["CompleteScanner"]),
        .library(name: "CompleteScannerKit", targets: ["CompleteScannerKit"]),
        .library(name: "CompleteScannerIOS", targets: ["CompleteScannerIOS"]),
    ],
    targets: [
        .target(
            name: "CompleteScannerKit",
            path: "Sources/CompleteScannerKit"
        ),
        .target(
            name: "CompleteScannerMac",
            dependencies: ["CompleteScannerKit"],
            path: "Sources/CompleteScannerMac"
        ),
        .target(
            name: "CompleteScannerIOS",
            dependencies: ["CompleteScannerKit"],
            path: "Sources/CompleteScannerIOS"
        ),
        .executableTarget(
            name: "CompleteScanner",
            dependencies: [
                .target(name: "CompleteScannerMac", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/CompleteScanner"
        ),
        // Shared: `swift test` on macOS and the iOS Simulator run the same cases.
        .testTarget(
            name: "CompleteScannerTests",
            dependencies: ["CompleteScannerKit"],
            path: "Tests/CompleteScannerTests"
        ),
        .testTarget(
            name: "CompleteScannerMacTests",
            dependencies: ["CompleteScannerKit", "CompleteScannerMac"],
            path: "Tests/CompleteScannerMacTests"
        ),
        .testTarget(
            name: "CompleteScannerIOSTests",
            dependencies: ["CompleteScannerKit", "CompleteScannerIOS"],
            path: "Tests/CompleteScannerIOSTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
