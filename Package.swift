// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompleteScanner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CompleteScanner", targets: ["CompleteScanner"])
    ],
    targets: [
        .target(
            name: "CompleteScannerKit",
            path: "Sources/CompleteScannerKit"
        ),
        .executableTarget(
            name: "CompleteScanner",
            dependencies: ["CompleteScannerKit"],
            path: "Sources/CompleteScanner"
        ),
        .testTarget(
            name: "CompleteScannerTests",
            dependencies: ["CompleteScannerKit"],
            path: "Tests/CompleteScannerTests"
        ),
    ]
)
