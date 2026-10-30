namespace LazyScan.App;

/// <summary>
/// The inspector's centered adjustment sliders: every slider shows one -100...+100 scale
/// with 0 (neutral) in the middle, mapped onto the model's parameter ranges. Settings and
/// presets keep the model semantics on disk. Port of the bindings in
/// Sources/CompleteScannerKit/UI/InspectorView.swift.
/// </summary>
public static class AdjustmentScale
{
    public const double Min = -100;
    public const double Max = 100;

    /// <summary>Brightness -1...1 ↔ -100...100, linear.</summary>
    public static double BrightnessToAmount(double brightness) => brightness * 100;
    public static double BrightnessFromAmount(double amount) => amount / 100;

    /// <summary>Contrast 0.25...4 ↔ -100...100 exponentially, so 0 is exactly neutral (1.0).</summary>
    public static double ContrastToAmount(double contrast) =>
        Math.Log(Math.Max(contrast, 0.25)) / Math.Log(4.0) * 100;
    public static double ContrastFromAmount(double amount) => Math.Pow(4.0, amount / 100);

    /// <summary>Saturation 0...2 ↔ -100...100, linear around neutral 1.</summary>
    public static double SaturationToAmount(double saturation) => (saturation - 1) * 100;
    public static double SaturationFromAmount(double amount) => 1 + amount / 100;

    /// <summary>Sharpness -2...2 ↔ -100...100; negative values soften (see ImagePipeline).</summary>
    public static double SharpnessToAmount(double sharpness) => sharpness * 50;
    public static double SharpnessFromAmount(double amount) => amount / 50;

    /// <summary>Readout text: "0" at neutral, otherwise a signed whole number ("+25", "-40").</summary>
    public static string AmountText(double amount)
    {
        int rounded = (int)Math.Round(amount, MidpointRounding.AwayFromZero);
        return rounded == 0 ? "0" : rounded.ToString("+0;-0");
    }
}
