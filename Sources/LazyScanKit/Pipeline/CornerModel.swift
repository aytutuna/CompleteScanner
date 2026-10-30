import Foundation

/// The heatmaps a corner model gives (`CornerHeatmap` reads them): four channels of `width` × `height`
/// values from 0 to 1, top left, top right, bottom right and bottom left, one channel after another, each
/// row after row. Twin of C# `CornerHeatmaps`.
public struct CornerHeatmaps: Equatable, Sendable {
    public var values: [Float]
    public var width: Int
    public var height: Int

    public init(values: [Float], width: Int, height: Int) {
        self.values = values
        self.width = width
        self.height = height
    }
}

/// A model that finds a page's corners in a photo: DocAligner's FastViT-T8 on ONNX Runtime. The photo
/// import tries it first (`PhotoImport.plan(_:model:)`); tests give it fakes. Twin of C# `ICornerModel`.
public protocol CornerModel {
    /// The heatmaps for `input` (`CornerModelInput.make`); nil when the model cannot run.
    func heatmaps(_ input: [Float]) -> CornerHeatmaps?
}
