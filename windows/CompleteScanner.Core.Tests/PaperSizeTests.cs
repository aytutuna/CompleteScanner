using System.Text.Json;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/PaperSizeTests.swift: the same cases.

public class PaperSizeTests
{
    private static void AssertSize(double width, double height, SizeD? actual)
    {
        Assert.NotNull(actual);
        Assert.Equal(width, actual.Value.Width, 4);
        Assert.Equal(height, actual.Value.Height, 4);
    }

    private static void AssertRect(double x, double y, double width, double height, RectD? actual)
    {
        Assert.NotNull(actual);
        Assert.Equal(x, actual.Value.X, 4);
        Assert.Equal(y, actual.Value.Y, 4);
        Assert.Equal(width, actual.Value.Width, 4);
        Assert.Equal(height, actual.Value.Height, 4);
    }

    [Fact]
    public void AutomaticIsTheFirstSizeAndTheDefault()
    {
        Assert.Equal(PaperSize.Auto, PaperSizes.All[0]);
        Assert.Equal(PaperSize.Auto, new ScanSettings().PaperSize);
        Assert.Null(PaperSizes.Inches(PaperSize.Auto));
    }

    [Fact]
    public void RawValues_AreTheStoredNames()
    {
        Assert.Equal(["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard"],
                     PaperSizes.All.Select(size => size.RawValue()));
        Assert.All(PaperSizes.All, size =>
            Assert.Equal($"\"{size.RawValue()}\"", JsonSerializer.Serialize(size, StoreFiles.JsonOptions)));
    }

    [Fact]
    public void Inches_PortraitWidthByHeight()
    {
        AssertSize(8.5, 11, PaperSizes.Inches(PaperSize.Letter));
        AssertSize(8.5, 14, PaperSizes.Inches(PaperSize.Legal));
        AssertSize(7.25, 10.5, PaperSizes.Inches(PaperSize.Executive));
        AssertSize(8.2677, 11.6929, PaperSizes.Inches(PaperSize.A4));
        AssertSize(5.8268, 8.2677, PaperSizes.Inches(PaperSize.A5));
        AssertSize(4.1339, 5.8268, PaperSizes.Inches(PaperSize.A6));
        AssertSize(7.1654, 10.1181, PaperSizes.Inches(PaperSize.B5Jis));
        AssertSize(2.125, 3.370, PaperSizes.Inches(PaperSize.IdCard));
        // 210 × 297 mm.
        Assert.Equal(210, PaperSizes.Inches(PaperSize.A4)!.Value.Width * 25.4, 0);
        Assert.Equal(297, PaperSizes.Inches(PaperSize.A4)!.Value.Height * 25.4, 0);
    }

    [Fact]
    public void Parse_IsLenient()
    {
        Assert.Equal(PaperSize.A4, PaperSizes.Parse("a4"));
        Assert.Equal(PaperSize.A4, PaperSizes.Parse("A4"));
        Assert.Equal(PaperSize.Letter, PaperSizes.Parse(" letter "));
        Assert.Equal(PaperSize.B5Jis, PaperSizes.Parse("b5jis"));
        Assert.Equal(PaperSize.IdCard, PaperSizes.Parse("idCard"));
        Assert.Equal(PaperSize.Auto, PaperSizes.Parse("tabloid"));
        Assert.Equal(PaperSize.Auto, PaperSizes.Parse(""));
        Assert.Equal(PaperSize.Auto, PaperSizes.Parse(null));
    }

    [Fact]
    public void DefaultForRegion_LetterInTheAmericasAndThePhilippines_A4Elsewhere()
    {
        Assert.Equal(14, PaperSizes.LetterRegions.Count);
        foreach (string code in new[] { "US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE", "us", " ca " })
        {
            Assert.Equal(PaperSize.Letter, PaperSizes.DefaultForRegion(code));
        }
        foreach (string? code in new[] { "DE", "GB", "JP", "BR", "AU", "TR", "", null })
        {
            Assert.Equal(PaperSize.A4, PaperSizes.DefaultForRegion(code));
        }
    }

    [Fact]
    public void Match_ThePaperAPrinterReports()
    {
        // Windows reports A4 as 793.7 × 1122.5 device-independent pixels (1/96 in).
        Assert.Equal(PaperSize.A4, PaperSizes.Match(new SizeD(793.700787 / 96, 1122.519685 / 96)));
        Assert.Equal(PaperSize.Letter, PaperSizes.Match(new SizeD(8.5, 11)));
        // Either way round, within a little rounding.
        Assert.Equal(PaperSize.Letter, PaperSizes.Match(new SizeD(11.02, 8.49)));
        Assert.Equal(PaperSize.Legal, PaperSizes.Match(new SizeD(8.5, 14)));
        Assert.Equal(PaperSize.A5, PaperSizes.Match(new SizeD(5.83, 8.27)));
        Assert.Null(PaperSizes.Match(new SizeD(8, 10)));
        Assert.Null(PaperSizes.Match(new SizeD(8.5, 11.2)));
        Assert.Null(PaperSizes.Match(new SizeD(0, 0)));
        foreach (var size in PaperSizes.All)
        {
            if (PaperSizes.Inches(size) is { } inches) Assert.Equal(size, PaperSizes.Match(inches));
        }
    }

    [Fact]
    public void DisplayOrder_AutomaticThenTheUsualSize()
    {
        Assert.Equal(
            [PaperSize.Auto, PaperSize.Letter, PaperSize.Legal, PaperSize.Executive, PaperSize.A4, PaperSize.A5,
             PaperSize.A6, PaperSize.B5Jis, PaperSize.IdCard],
            PaperSizes.DisplayOrder("US"));
        Assert.Equal(
            [PaperSize.Auto, PaperSize.A4, PaperSize.Letter, PaperSize.Legal, PaperSize.Executive, PaperSize.A5,
             PaperSize.A6, PaperSize.B5Jis, PaperSize.IdCard],
            PaperSizes.DisplayOrder("DE"));
    }

    [Fact]
    public void Fits_WithinTheAreaAndALittleRounding()
    {
        var letterGlass = new SizeD(8.5, 11.7);
        Assert.True(PaperSizes.Fits(PaperSize.A4, letterGlass));
        Assert.True(PaperSizes.Fits(PaperSize.Letter, letterGlass));
        Assert.False(PaperSizes.Fits(PaperSize.Legal, letterGlass));
        Assert.True(PaperSizes.Fits(PaperSize.A4, new SizeD(8.26, 11.65)));
        Assert.False(PaperSizes.Fits(PaperSize.Letter, new SizeD(8.27, 11.69)));
        Assert.True(PaperSizes.Fits(PaperSize.Auto, new SizeD(1, 1)));
        Assert.True(PaperSizes.Fits(PaperSize.Legal, null));
        Assert.True(PaperSizes.Fits(PaperSize.Legal, new SizeD(0, 0)));
    }

    [Fact]
    public void FlatbedSelection_FromTheCornerOfTheGlass()
    {
        var glass = new SizeD(8.5, 11.7);
        Assert.Null(PaperSizes.FlatbedSelection(PaperSize.Auto, glass));
        AssertRect(0, 0, 1, 11 / 11.7, PaperSizes.FlatbedSelection(PaperSize.Letter, glass));
        AssertRect(0, 0, 5.8268 / 8.5, 8.2677 / 11.7, PaperSizes.FlatbedSelection(PaperSize.A5, glass));
        // Larger than the glass: clamped to it.
        AssertRect(0, 0, 1, 1, PaperSizes.FlatbedSelection(PaperSize.Legal, glass));
        Assert.Null(PaperSizes.FlatbedSelection(PaperSize.A4, new SizeD(0, 11)));
    }

    [Fact]
    public void FeederRegion_ThePaperClampedToTheLargestSheet()
    {
        var legal = new SizeD(8.5, 14);
        AssertRect(0, 0, 8.5, 14, PaperSizes.FeederRegionInches(PaperSize.Auto, legal));
        AssertRect(0, 0, 8.2677, 11.6929, PaperSizes.FeederRegionInches(PaperSize.A4, legal));
        AssertRect(0, 0, 8.5, 11, PaperSizes.FeederRegionInches(PaperSize.Legal, new SizeD(8.5, 11)));
    }

    [Fact]
    public void LabelsAndHints()
    {
        Assert.Equal(["Automatic", "Letter", "Legal", "Executive", "A4", "A5", "A6", "B5 (JIS)", "ID card"],
                     PaperSizes.All.Select(size => size.Label()));
        Assert.Equal("210 × 297 mm", PaperSize.A4.Detail());
        Assert.Equal("8.5 × 11 in", PaperSize.Letter.Detail());
        Assert.Equal("The whole glass, or the area selected on the preview.", PaperSizes.Hint(PaperSize.Auto, ScanSource.Flatbed));
        Assert.Equal("The sheet size the feeder takes.", PaperSizes.Hint(PaperSize.Auto, ScanSource.DocumentFeeder));
        Assert.Equal("Sheets of this size, from the feeder.", PaperSizes.Hint(PaperSize.A4, ScanSource.DocumentFeeder));
        Assert.Equal("From the glass corner. A preview selection replaces it.",
                     PaperSizes.Hint(PaperSize.Letter, ScanSource.Flatbed));
        Assert.Equal("Too big for this glass", PaperSizes.DoesNotFitReason(ScanSource.Flatbed));
        Assert.Equal("Too big for this feeder", PaperSizes.DoesNotFitReason(ScanSource.DocumentFeeder));
        Assert.Equal("Using the selected area", PaperSizes.SelectedAreaNote);
    }
}
