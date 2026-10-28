namespace CompleteScanner.Core;

/// <summary>
/// The heatmaps a corner model gives (<see cref="CornerHeatmap"/> reads them): four channels of
/// <see cref="Width"/> × <see cref="Height"/> values from 0 to 1, top left, top right, bottom right and
/// bottom left, one channel after another, each row after row.
/// </summary>
public sealed record CornerHeatmaps(float[] Values, int Width, int Height);

/// <summary>
/// A model that finds a page's corners in a photo: DocAligner's FastViT-T8 on ONNX Runtime. The photo
/// import tries it first (<see cref="PhotoImport.Plan(RgbaImage, ICornerModel?)"/>); tests give it fakes.
/// </summary>
public interface ICornerModel
{
    /// <summary>The heatmaps for <paramref name="input"/> (<see cref="CornerModelInput.Make"/>); null when the model cannot run.</summary>
    CornerHeatmaps? Heatmaps(float[] input);
}
