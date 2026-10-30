using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/PDFImageEncodingTests.swift: the same table and cases.
// The actual file sizes per setting depend on the platform's JPEG encoder; the Swift suite
// checks their order on a synthetic page, and real documents were measured by hand (see
// windows/README.md).

public class PdfImageEncodingTests
{
    [Fact]
    public void Profiles_Table()
    {
        Assert.Equal(new PdfSizeProfile(null, 0.90, 0.90, false, null), PdfImageEncoding.Profile(PdfSizePreset.Best));
        Assert.Equal(new PdfSizeProfile(300, 0.80, 0.80, true, 600), PdfImageEncoding.Profile(PdfSizePreset.Standard));
        Assert.Equal(new PdfSizeProfile(200, 0.65, 0.70, true, 300), PdfImageEncoding.Profile(PdfSizePreset.Compact));
        Assert.Equal(new PdfSizeProfile(150, 0.50, 0.55, true, 300), PdfImageEncoding.Profile(PdfSizePreset.Smallest));
    }

    [Fact]
    public void DisplayOrder_LargestFirst_EverySizeOnce()
    {
        Assert.Equal([PdfSizePreset.Best, PdfSizePreset.Standard, PdfSizePreset.Compact, PdfSizePreset.Smallest],
                     PdfSizePresets.DisplayOrder);
        Assert.Equal(Enum.GetValues<PdfSizePreset>().Order(), PdfSizePresets.DisplayOrder.Order());
        Assert.Equal(["Best", "Standard", "Compact", "Smallest"], PdfSizePresets.DisplayOrder.Select(p => p.Label()));
        Assert.All(PdfSizePresets.DisplayOrder, p => Assert.False(string.IsNullOrWhiteSpace(p.Hint())));
    }

    [Fact]
    public void Hint_NamesTheSizesLimits_BlackAndWhiteToo()
    {
        // Black & white pages are stored as G4 up to their own limit, and the detail (the help text
        // behind the short tooltip) says so. Same case as the Swift one.
        Assert.StartsWith("Full resolution", PdfSizePreset.Best.Detail());
        foreach (var size in new[] { PdfSizePreset.Standard, PdfSizePreset.Compact, PdfSizePreset.Smallest })
        {
            var profile = PdfImageEncoding.Profile(size);
            Assert.StartsWith($"Up to {profile.MaxDpi} dpi (black & white {profile.BilevelMaxDpi}), ", size.Detail());
        }
    }

    /// <summary>"300 Color 0.80" — target dpi, kind (Color, Gray or G4) and quality of one plan.</summary>
    private static string Row(PdfImagePlan plan) =>
        $"{plan.TargetDpi} {(plan.IsBilevel ? "G4" : plan.IsGray ? "Gray" : "Color")} {plan.Quality:0.00}";

    [Fact]
    public void Plan_Table_SizeByModeByDpi()
    {
        // Color pages that have color.
        var rows = new List<string>();
        foreach (var size in PdfSizePresets.DisplayOrder)
        {
            foreach (var mode in Enum.GetValues<ColorMode>())
            {
                foreach (int dpi in new[] { 150, 300, 600 })
                {
                    rows.Add($"{size} {mode} {dpi}: {Row(PdfImageEncoding.Plan(mode, dpi, size, looksGray: false))}");
                }
            }
        }
        Assert.Equal(
            [
                "Best Color 150: 150 Color 0.90", "Best Color 300: 300 Color 0.90", "Best Color 600: 600 Color 0.90",
                "Best Grayscale 150: 150 Gray 0.90", "Best Grayscale 300: 300 Gray 0.90", "Best Grayscale 600: 600 Gray 0.90",
                "Best BlackWhite 150: 150 G4 0.90", "Best BlackWhite 300: 300 G4 0.90", "Best BlackWhite 600: 600 G4 0.90",
                "Standard Color 150: 150 Color 0.80", "Standard Color 300: 300 Color 0.80", "Standard Color 600: 300 Color 0.80",
                "Standard Grayscale 150: 150 Gray 0.80", "Standard Grayscale 300: 300 Gray 0.80", "Standard Grayscale 600: 300 Gray 0.80",
                "Standard BlackWhite 150: 150 G4 0.80", "Standard BlackWhite 300: 300 G4 0.80", "Standard BlackWhite 600: 600 G4 0.80",
                "Compact Color 150: 150 Color 0.65", "Compact Color 300: 200 Color 0.65", "Compact Color 600: 200 Color 0.65",
                "Compact Grayscale 150: 150 Gray 0.70", "Compact Grayscale 300: 200 Gray 0.70", "Compact Grayscale 600: 200 Gray 0.70",
                "Compact BlackWhite 150: 150 G4 0.70", "Compact BlackWhite 300: 300 G4 0.70", "Compact BlackWhite 600: 300 G4 0.70",
                "Smallest Color 150: 150 Color 0.50", "Smallest Color 300: 150 Color 0.50", "Smallest Color 600: 150 Color 0.50",
                "Smallest Grayscale 150: 150 Gray 0.55", "Smallest Grayscale 300: 150 Gray 0.55", "Smallest Grayscale 600: 150 Gray 0.55",
                "Smallest BlackWhite 150: 150 G4 0.55", "Smallest BlackWhite 300: 300 G4 0.55", "Smallest BlackWhite 600: 300 G4 0.55",
            ],
            rows);
    }

    [Fact]
    public void Plan_ColorPagesWithoutColor_AreGray_ExceptAtBest()
    {
        Assert.Equal("300 Color 0.90", Row(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Best, looksGray: true)));
        Assert.Equal("300 Gray 0.80", Row(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Standard, looksGray: true)));
        Assert.Equal("200 Gray 0.70", Row(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Compact, looksGray: true)));
        Assert.Equal("150 Gray 0.55", Row(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Smallest, looksGray: true)));
        // Gray scans are gray whatever the check says.
        Assert.Equal("300 Gray 0.90", Row(PdfImageEncoding.Plan(ColorMode.Grayscale, 300, PdfSizePreset.Best, looksGray: false)));
    }

    [Fact]
    public void Plan_QualityComesFromTheSizeAlone()
    {
        // Plan takes no JPEG quality setting (that setting is for JPEG files), so a low setting
        // can never lower a PDF size without the size picker showing it.
        foreach (var size in PdfSizePresets.DisplayOrder)
        {
            var profile = PdfImageEncoding.Profile(size);
            Assert.Equal(profile.ColorQuality, PdfImageEncoding.Plan(ColorMode.Color, 300, size, false).Quality);
            Assert.Equal(profile.GrayQuality, PdfImageEncoding.Plan(ColorMode.Grayscale, 300, size, false).Quality);
            Assert.Equal(profile.GrayQuality, PdfImageEncoding.Plan(ColorMode.BlackWhite, 600, size, false).Quality);
        }
        Assert.Equal(0.9, PdfImageEncoding.Plan(ColorMode.Color, 1200, PdfSizePreset.Best, false).Quality);
    }

    [Fact]
    public void Plan_DownsamplesOnlyClearlyFinerPages()
    {
        int Target(int dpi, PdfSizePreset size) => PdfImageEncoding.Plan(ColorMode.Color, dpi, size, false).TargetDpi;
        Assert.Equal(330, Target(330, PdfSizePreset.Standard)); // within 10 %
        Assert.Equal(300, Target(331, PdfSizePreset.Standard));
        Assert.Equal(220, Target(220, PdfSizePreset.Compact));
        Assert.Equal(200, Target(221, PdfSizePreset.Compact));
        Assert.Equal(165, Target(165, PdfSizePreset.Smallest));
        Assert.Equal(150, Target(166, PdfSizePreset.Smallest));
        Assert.Equal(1200, Target(1200, PdfSizePreset.Best));
        Assert.Equal(75, Target(75, PdfSizePreset.Smallest));   // never upsampled
        Assert.Equal(1, Target(0, PdfSizePreset.Standard));     // a page without a resolution
    }

    [Fact]
    public void Plan_BlackAndWhite_IsG4_UpToItsOwnLimit()
    {
        PdfImagePlan Plan(int dpi, PdfSizePreset size) => PdfImageEncoding.Plan(ColorMode.BlackWhite, dpi, size, looksGray: false);
        Assert.Equal(660, Plan(660, PdfSizePreset.Standard).TargetDpi);  // within 10 %
        Assert.Equal(600, Plan(661, PdfSizePreset.Standard).TargetDpi);
        Assert.Equal(600, Plan(1200, PdfSizePreset.Standard).TargetDpi);
        Assert.Equal(330, Plan(330, PdfSizePreset.Compact).TargetDpi);
        Assert.Equal(300, Plan(331, PdfSizePreset.Compact).TargetDpi);
        Assert.Equal(300, Plan(600, PdfSizePreset.Smallest).TargetDpi);
        Assert.Equal(1200, Plan(1200, PdfSizePreset.Best).TargetDpi);
        Assert.Equal(75, Plan(75, PdfSizePreset.Smallest).TargetDpi);    // never upsampled
        Assert.Equal(1, Plan(0, PdfSizePreset.Standard).TargetDpi);
        foreach (var size in PdfSizePresets.DisplayOrder)
        {
            var plan = Plan(300, size);
            Assert.Equal(PdfImageKind.BilevelG4, plan.Kind);
            Assert.True(plan.IsBilevel && plan.IsGray);
            Assert.Equal(plan, PdfImageEncoding.Plan(ColorMode.BlackWhite, 300, size, looksGray: true));
            Assert.False(PdfImageEncoding.Plan(ColorMode.Grayscale, 300, size, false).IsBilevel);
            Assert.False(PdfImageEncoding.Plan(ColorMode.Color, 300, size, true).IsBilevel);
        }
    }

    [Fact]
    public void Plan_SizesShrinkInDisplayOrder()
    {
        foreach (var mode in Enum.GetValues<ColorMode>())
        {
            foreach (int dpi in new[] { 200, 300, 600 })
            {
                var plans = PdfSizePresets.DisplayOrder
                    .Select(size => PdfImageEncoding.Plan(mode, dpi, size, looksGray: false)).ToList();
                for (int i = 1; i < plans.Count; i++)
                {
                    Assert.True(plans[i].TargetDpi <= plans[i - 1].TargetDpi, $"{mode} {dpi}: dpi order at {i}");
                    Assert.True(plans[i].Quality < plans[i - 1].Quality, $"{mode} {dpi}: quality order at {i}");
                }
            }
        }
    }

    [Fact]
    public void Plan_ForAnImage_ChecksColorOnlyWhenItMatters()
    {
        var plain = RgbaImage.Filled(40, 40, 245, 245, 240);
        var colorful = RgbaImage.Filled(40, 40, 200, 40, 40);
        Assert.True(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Standard, plain).IsGray);
        Assert.False(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Standard, colorful).IsGray);
        Assert.False(PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Best, plain).IsGray);
        Assert.True(PdfImageEncoding.Plan(ColorMode.Grayscale, 300, PdfSizePreset.Best, colorful).IsGray);
    }

    [Fact]
    public void EffectiveDpi_OfAPreviewIsLower()
    {
        Assert.Equal(300, PdfImageEncoding.EffectiveDpi(2550, 2550, 300));
        Assert.Equal(188, PdfImageEncoding.EffectiveDpi(1600, 2550, 300)); // 188.2
        Assert.Equal(150, PdfImageEncoding.EffectiveDpi(1275, 2550, 300));
        Assert.Equal(300, PdfImageEncoding.EffectiveDpi(1275, 0, 300));
        Assert.Equal(1, PdfImageEncoding.EffectiveDpi(1, 10000, 2));
    }

    [Fact]
    public void TargetSize_RoundsHalfAwayFromZero_AndKeepsAtLeastOnePixel()
    {
        Assert.Equal((1700, 2200), PdfImageEncoding.TargetSize(2550, 3300, 300, 200));
        Assert.Equal((2550, 3300), PdfImageEncoding.TargetSize(5100, 6600, 600, 300));
        Assert.Equal((2, 1), PdfImageEncoding.TargetSize(3, 1, 300, 150));   // 1.5 -> 2, 0.5 -> 1
        Assert.Equal((1, 1), PdfImageEncoding.TargetSize(1, 1, 600, 150));
        Assert.Equal((2550, 3300), PdfImageEncoding.TargetSize(2550, 3300, 300, 300));
        Assert.Equal((100, 50), PdfImageEncoding.TargetSize(100, 50, 150, 300)); // never larger
    }

    [Fact]
    public void Downsample_BoxFiltersToThePlannedSize_OrKeepsTheImage()
    {
        var image = RgbaImage.Filled(600, 400, 10, 20, 30);
        var keep = PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Standard, false);
        Assert.Same(image, PdfImageEncoding.Downsample(image, 300, keep));

        var compact = PdfImageEncoding.Plan(ColorMode.Color, 300, PdfSizePreset.Compact, false);
        var small = PdfImageEncoding.Downsample(image, 300, compact);
        Assert.Equal((400, 267), (small.Width, small.Height));
        Assert.Equal(new byte[] { 10, 20, 30, 255 }, small.Pixels[..4]);

        // A 2 × 2 checker averages to mid-gray at half the resolution.
        var checker = RgbaImage.Filled(2, 2, 0, 0, 0);
        for (int i = 0; i < 4; i += 3)
        {
            checker.Pixels[i * 4] = 255;
            checker.Pixels[i * 4 + 1] = 255;
            checker.Pixels[i * 4 + 2] = 255;
        }
        var half = PdfImageEncoding.Downsample(checker, 300,
                                               PdfImageEncoding.Plan(ColorMode.Grayscale, 300, PdfSizePreset.Smallest, false));
        Assert.Equal((1, 1), (half.Width, half.Height));
        Assert.Equal(new byte[] { 127, 127, 127, 255 }, half.Pixels);
    }
}
