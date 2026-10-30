using System.IO;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

/// <summary>
/// A test that runs the corner model, skipped when scripts/fetch_docaligner.sh has not fetched it, unless
/// LAZYSCAN_REQUIRE_CORNER_MODEL=1 (CI fetches it), where it runs anyway and fails.
/// </summary>
public sealed class CornerModelFactAttribute : FactAttribute
{
    public CornerModelFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("LAZYSCAN_REQUIRE_CORNER_MODEL") != "1" && OnnxCornerModel.Load() is null)
        {
            Skip = "The corner model is not fetched (scripts/fetch_docaligner.sh).";
        }
    }
}

// Twin of Tests/LazyScanModelTests/FastViTCornerModelTests.swift: DocAligner's FastViT-T8 on the
// SmartDoc frames in Tests/Fixtures/Pages, here on ONNX Runtime's CPU: every corner within 1.5 % of the
// photo's diagonal of the ground truth, and the photo import taking the page.
public class OnnxCornerModelTests
{
    /// <summary>The farthest a corner may lie from the ground truth, as a share of the photo's diagonal.</summary>
    private const double Tolerance = 0.015;

    [CornerModelFact]
    public void FastViTFindsEveryPageWithinOnePointFivePercentOfTheDiagonal()
    {
        var model = OnnxCornerModel.Load() ?? throw new FileNotFoundException("The corner model is not next to the tests.", OnnxCornerModel.DefaultPath);
        foreach (var photo in PageFixtures.All())
        {
            var image = PageFixtures.Read(photo);
            var heat = model.Run(CornerModelInput.Make(image));
            var found = CornerHeatmap.Decode(heat.Values, heat.Width, heat.Height);
            Assert.True(found is not null, $"No page in {photo.File}");
            double w = image.Width, h = image.Height;
            double diagonal = Math.Sqrt(w * w + h * h);
            var quad = Quad.FromCorners(found.Quad.Scaled(w, h).Corners);
            for (int i = 0; i < 4; i++)
            {
                double error = quad[i].DistanceTo(photo.Truth[i]) / diagonal;
                Assert.True(error < Tolerance, $"{photo.File} corner {i}: {error * 100:F2} % of the diagonal");
            }
            Assert.True(PhotoImport.ModelPlan(image, model) is not null, $"The photo import did not take the page in {photo.File}");
        }
    }

    [Fact]
    public void AnInputOfTheWrongSizeIsRefused()
    {
        var model = new OnnxCornerModel(Path.Combine(Path.GetTempPath(), "no-such-model.onnx"));
        Assert.Throws<ArgumentException>(() => model.Run([0, 0, 0]));
        Assert.Null(model.Heatmaps([]));
        // No file there: no heatmaps either, the photo import's own search takes over.
        Assert.Null(model.Heatmaps(new float[3 * CornerModelInput.Side * CornerModelInput.Side]));
    }
}
