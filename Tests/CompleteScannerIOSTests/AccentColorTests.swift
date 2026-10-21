#if os(iOS)
import Foundation
import XCTest

// The app's accent colour (ios/CompleteScanneriOS/Assets.xcassets/AccentColor.colorset) fills the
// Scan button (`.borderedProminent`, which draws its label white) and the start screen's "Current"
// badge (white caption text). Every variant of it keeps white text at 4.5:1 or more, the WCAG
// minimum for normal text, in light and in dark mode alike.

final class AccentColorTests: XCTestCase {
    private static let minimumContrast: Double = 4.5

    /// An sRGB component (0...1) made linear, as WCAG's relative luminance takes it.
    private static func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    func test_everyAccentVariant_keepsWhiteTextReadable() throws {
        let colorset: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CompleteScannerIOSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the repository
            .appendingPathComponent("ios/CompleteScanneriOS/Assets.xcassets/AccentColor.colorset/Contents.json")
        let data: Data = try Data(contentsOf: colorset)
        let root: [String: Any] = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors: [[String: Any]] = try XCTUnwrap(root["colors"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 2, "The light and the dark variant")
        for entry in colors {
            let variant: String = entry["appearances"] == nil ? "light" : "dark"
            let color: [String: Any] = try XCTUnwrap(entry["color"] as? [String: Any], variant)
            XCTAssertEqual(color["color-space"] as? String, "srgb", variant)
            let components: [String: String] = try XCTUnwrap(color["components"] as? [String: String], variant)
            let red: Double = try XCTUnwrap(Double(components["red"] ?? ""), variant)
            let green: Double = try XCTUnwrap(Double(components["green"] ?? ""), variant)
            let blue: Double = try XCTUnwrap(Double(components["blue"] ?? ""), variant)
            let luminance: Double = 0.2126 * Self.linear(red) + 0.7152 * Self.linear(green)
                + 0.0722 * Self.linear(blue)
            let contrast: Double = (1.0 + 0.05) / (luminance + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, Self.minimumContrast,
                                        "White on the \(variant) accent: \(contrast):1")
        }
    }
}
#endif
