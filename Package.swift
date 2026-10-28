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
// - CompleteScannerModel: the page corner model (DocAligner's FastViT-T8 on ONNX Runtime) for both apps.
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
    dependencies: [
        // ONNX Runtime (MIT) runs DocAligner's corner model (CompleteScannerModel) on the Mac and the iPhone.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "CompleteScannerKit",
            path: "Sources/CompleteScannerKit"
        ),
        .target(
            name: "CompleteScannerModel",
            dependencies: [
                "CompleteScannerKit",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/CompleteScannerModel",
            // The model (scripts/fetch_docaligner.sh); the folder holds only its licence until it is fetched.
            resources: [.copy("Models")]
        ),
        .target(
            name: "CompleteScannerMac",
            dependencies: ["CompleteScannerKit", "CompleteScannerModel"],
            path: "Sources/CompleteScannerMac"
        ),
        .target(
            name: "CompleteScannerIOS",
            dependencies: [
                "CompleteScannerKit",
                "CompleteScannerModel",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager",
                         condition: .when(platforms: [.iOS])),
            ],
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
        // The corner model on the page photos in Tests/Fixtures/Pages; skipped where it was not fetched.
        .testTarget(
            name: "CompleteScannerModelTests",
            dependencies: ["CompleteScannerKit", "CompleteScannerModel"],
            path: "Tests/CompleteScannerModelTests"
        ),
        .testTarget(
            name: "CompleteScannerIOSTests",
            dependencies: ["CompleteScannerKit", "CompleteScannerIOS"],
            path: "Tests/CompleteScannerIOSTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
