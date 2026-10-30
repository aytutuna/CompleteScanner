// swift-tools-version: 6.0
import PackageDescription

// One shared core for the Mac and the iPhone, and a target for each platform's own parts:
// - LazyScanKit: everything both apps share (models, the page pipeline, output, settings
//   files, the demo scanner, AppState and the protocols of the system services). No AppKit, UIKit,
//   SwiftUI or ImageCaptureCore.
// - LazyScanMac: the Mac's views, its ImageCaptureCore scanners and its system services.
//   Every file is wrapped in `#if os(macOS)`, so it builds to nothing for iOS.
// - LazyScanIOS: the iPhone's and iPad's services and views. Every file is wrapped in
//   `#if os(iOS)`, so it builds to nothing for macOS.
// - LazyScanModel: the page corner model (DocAligner's FastViT-T8 on ONNX Runtime) for both apps.
// - LazyScan: the Mac app.
// iOS 18 needs PackageDescription 6.0; the code stays in the Swift 5 language mode.
let package = Package(
    name: "LazyScan",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .executable(name: "LazyScan", targets: ["LazyScan"]),
        .library(name: "LazyScanKit", targets: ["LazyScanKit"]),
        .library(name: "LazyScanIOS", targets: ["LazyScanIOS"]),
    ],
    dependencies: [
        // ONNX Runtime (MIT) runs DocAligner's corner model (LazyScanModel) on the Mac and the iPhone.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "LazyScanKit",
            path: "Sources/LazyScanKit"
        ),
        .target(
            name: "LazyScanModel",
            dependencies: [
                "LazyScanKit",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/LazyScanModel",
            // The model (scripts/fetch_docaligner.sh); the folder holds only the licences until it is fetched.
            resources: [.copy("Models")]
        ),
        .target(
            name: "LazyScanMac",
            dependencies: ["LazyScanKit", "LazyScanModel"],
            path: "Sources/LazyScanMac"
        ),
        .target(
            name: "LazyScanIOS",
            dependencies: ["LazyScanKit", "LazyScanModel"],
            path: "Sources/LazyScanIOS"
        ),
        .executableTarget(
            name: "LazyScan",
            dependencies: [
                .target(name: "LazyScanMac", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/LazyScan"
        ),
        // Shared: `swift test` on macOS and the iOS Simulator run the same cases.
        .testTarget(
            name: "LazyScanTests",
            dependencies: ["LazyScanKit"],
            path: "Tests/LazyScanTests"
        ),
        .testTarget(
            name: "LazyScanMacTests",
            dependencies: ["LazyScanKit", "LazyScanMac"],
            path: "Tests/LazyScanMacTests"
        ),
        // The corner model on the page photos in Tests/Fixtures/Pages; skipped where it was not fetched.
        .testTarget(
            name: "LazyScanModelTests",
            dependencies: ["LazyScanKit", "LazyScanModel"],
            path: "Tests/LazyScanModelTests"
        ),
        .testTarget(
            name: "LazyScanIOSTests",
            dependencies: ["LazyScanKit", "LazyScanIOS", "LazyScanModel"],
            path: "Tests/LazyScanIOSTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
