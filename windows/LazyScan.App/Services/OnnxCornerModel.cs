using System.IO;
using LazyScan.Core;
using Microsoft.ML.OnnxRuntime;

namespace LazyScan.App.Services;

/// <summary>
/// DocAligner's FastViT-T8 corner model (DocsaidLab/DocAligner 1.1.1, Apache-2.0, see
/// Models\DocAligner-LICENSE.txt next to the app) on ONNX Runtime's CPU: the page finder of the photo
/// import, behind <see cref="PhotoImport.Plan(RgbaImage, ICornerModel?)"/>. The project file copies the
/// model next to the app when scripts/fetch_docaligner.sh has fetched it; without it there is no model
/// (<see cref="Load"/> gives null) and the photo import uses its own page search. The session is made on
/// the first run and kept; ONNX Runtime runs it for several threads at once. The Mac's and the iPhone's
/// twin is Sources/LazyScanModel/FastViTCornerModel.swift, with Core ML in front.
/// </summary>
public sealed class OnnxCornerModel : ICornerModel
{
    public const string FileName = "fastvit_t8_h_e_bifpn_256_fp32.onnx";

    /// <summary>Where the model is next to the app.</summary>
    public static string DefaultPath => Path.Combine(AppContext.BaseDirectory, "Models", FileName);

    private readonly Lazy<InferenceSession> _session;

    public OnnxCornerModel(string path)
    {
        _session = new Lazy<InferenceSession>(() => CreateSession(path));
    }

    /// <summary>The model next to the app; null when its file is not there.</summary>
    public static OnnxCornerModel? Load() => File.Exists(DefaultPath) ? new OnnxCornerModel(DefaultPath) : null;

    public CornerHeatmaps? Heatmaps(float[] input)
    {
        try
        {
            return Run(input);
        }
        catch (Exception)
        {
            // The model could not be loaded or run: the photo import's own page search takes over.
            return null;
        }
    }

    /// <summary>The heatmaps for <paramref name="input"/> (<see cref="CornerModelInput.Make"/>).</summary>
    public CornerHeatmaps Run(float[] input)
    {
        int side = CornerModelInput.Side;
        if (input.Length != 3 * side * side)
        {
            throw new ArgumentException($"The corner model takes 3 × {side} × {side} values.", nameof(input));
        }
        using var value = OrtValue.CreateTensorValueFromMemory(input, [1, 3, side, side]);
        using var options = new RunOptions();
        var inputs = new Dictionary<string, OrtValue> { ["img"] = value };
        using var outputs = _session.Value.Run(options, inputs, ["heatmap"]);
        var heatmap = outputs.First();
        long[] shape = heatmap.GetTensorTypeAndShape().Shape;
        if (shape.Length != 4 || shape[1] != 4 || shape[2] <= 0 || shape[3] <= 0)
        {
            throw new InvalidDataException("The corner model's answer is not four heatmaps.");
        }
        int height = (int)shape[2], width = (int)shape[3];
        int count = 4 * width * height;
        var values = heatmap.GetTensorDataAsSpan<float>();
        if (values.Length < count) throw new InvalidDataException("The corner model's answer is cut short.");
        return new CornerHeatmaps(values[..count].ToArray(), width, height);
    }

    private static InferenceSession CreateSession(string path)
    {
        using var options = new SessionOptions { GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
        return new InferenceSession(path, options);
    }
}
