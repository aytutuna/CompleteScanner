using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/PhotoImportModelTests.swift: the photo import with a corner model tried
// first, on the wood scene (PhotoScenes) with a fake model that draws its heatmaps where it is told.

public class PhotoImportModelTests
{
    /// <summary>A corner model that answers <paramref name="answer"/> and keeps what it was given.</summary>
    private sealed class FakeModel(CornerHeatmaps? answer) : ICornerModel
    {
        public List<float[]> Inputs { get; } = [];

        public CornerHeatmaps? Heatmaps(float[] input)
        {
            Inputs.Add(input);
            return answer;
        }
    }

    private const int Side = 128;

    private static Quad Truth => PhotoScenes.WoodMap.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight);

    /// <summary>A spot of <paramref name="peaks"/>[i] on corner i of <paramref name="corners"/> (the wood scene's pixels).</summary>
    private static DrawnHeatmap Spots(Quad corners, double[] peaks)
    {
        var heat = new DrawnHeatmap(Side);
        var points = corners.Corners;
        for (int i = 0; i < 4; i++)
        {
            heat.Spot(i, points[i].X / PhotoScenes.Width * Side, points[i].Y / PhotoScenes.Height * Side, peaks[i], 1.5);
        }
        return heat;
    }

    private static CornerHeatmaps Heatmaps(DrawnHeatmap heat) => new(heat.Values, Side, Side);

    [Fact]
    public void AClearPageFromTheModelIsCorrectedWithoutAsking()
    {
        var photo = PhotoScenes.WoodScene();
        var heat = Spots(Truth, [0.9, 0.9, 0.9, 0.9]);
        var model = new FakeModel(Heatmaps(heat));
        var plan = PhotoImport.Plan(photo, model);
        Assert.Equal(PhotoImportAction.Correct, plan.Action);
        Assert.Equal(PhotoReviewReason.None, plan.Reason);
        Assert.True(plan.Corners.MaxCornerDistance(Truth) < 1.5, $"{plan.Corners}");
        Assert.Equal(heat.WeakestPeak, plan.Detection.Confidence);
        Assert.Equal(PhotoDocumentRejection.None, plan.Detection.Rejection);
        Assert.Single(model.Inputs);
        Assert.Equal(CornerModelInput.Make(photo), model.Inputs[0]);
    }

    [Fact]
    public void AnUnsurePageFromTheModelGoesToTheCornerEditor()
    {
        var photo = PhotoScenes.WoodScene();
        // Its spots fall between values, so its weakest corner peaks a little under 0.6.
        var heat = Spots(Truth, [0.9, 0.6, 0.9, 0.9]);
        var plan = PhotoImport.Plan(photo, new FakeModel(Heatmaps(heat)));
        Assert.Equal(PhotoImportAction.Review, plan.Action);
        Assert.Equal(PhotoReviewReason.Unsure, plan.Reason);
        Assert.True(plan.Corners.MaxCornerDistance(Truth) < 1.5, $"{plan.Corners}");
        Assert.Equal(heat.WeakestPeak, plan.Detection.Confidence);
        Assert.InRange(plan.Detection.Confidence, PhotoImport.MinModelConfidence, PhotoImport.SureConfidence);
    }

    [Fact]
    public void WithoutAPageFromTheModelThePageSearchDecides()
    {
        var photo = PhotoScenes.WoodScene();
        var searched = PhotoImport.Plan(photo);
        Assert.Equal(searched, PhotoImport.Plan(photo, null));
        // The model cannot run, is too unsure, finds no corner, or finds an outline too small for a page.
        var weak = Heatmaps(Spots(Truth, [0.9, 0.45, 0.9, 0.9]));
        var square = new Quad(new PointD(100, 100), new PointD(160, 100), new PointD(160, 180), new PointD(100, 180));
        var small = Heatmaps(Spots(square, [0.9, 0.9, 0.9, 0.9]));
        var empty = new CornerHeatmaps(new float[Side * Side * 4], Side, Side);
        foreach (var answer in new[] { null, weak, small, empty })
        {
            var model = new FakeModel(answer);
            Assert.Equal(searched, PhotoImport.Plan(photo, model));
            Assert.Single(model.Inputs);
        }
    }
}
