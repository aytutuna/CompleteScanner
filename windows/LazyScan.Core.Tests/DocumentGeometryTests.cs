using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/DocumentGeometryTests.swift: crop to the page and straighten
// it, on the same synthetic pages (TestPages, byte-identical, checked by checksum).

public class DocumentGeometryTests
{
    private static RgbaImage Rgba(GrayImage page) => page.ToRgba();

    // MARK: - The pages are the same on both platforms

    [Fact]
    public void GeometryPages_AreTheSameBytesOnBothPlatforms()
    {
        Assert.Equal(0xF559B7D5u, TestPages.Checksum(TestPages.TextPage()));
        Assert.Equal(0x944A54E5u, TestPages.Checksum(TestPages.Turned(TestPages.TextPage(), TestPages.Plus3, 245)));
        Assert.Equal(0x04B32746u, TestPages.Checksum(TestPages.Turned(TestPages.TextPage(), TestPages.Minus1Point5, 245)));
        Assert.Equal(0x25E92C27u, TestPages.Checksum(TestPages.SheetOnBackdrop(TestPages.Plus2, 245, 250, 2, 0x5EE70001)));
        Assert.Equal(0xA9450876u, TestPages.Checksum(TestPages.SheetOnBackdrop(TestPages.Minus4, 30, 240, 0, 0x5EE70002)));
        // Turning by nothing changes nothing.
        Assert.Equal(0xF559B7D5u, TestPages.Checksum(TestPages.Turned(TestPages.TextPage(), TestPages.Straight, 245)));
    }

    // MARK: - Text lines

    [Theory]
    [InlineData(3.0)]
    [InlineData(-1.5)]
    [InlineData(6.5)]
    public void EstimateTextLayout_RecoversTheSkew(double degrees)
    {
        var turn = degrees switch { 3.0 => TestPages.Plus3, -1.5 => TestPages.Minus1Point5, _ => TestPages.Plus6Point5 };
        var layout = DocumentGeometry.EstimateTextLayout(TestPages.Turned(TestPages.TextPage(), turn, 245));
        Assert.Equal(TextAxis.Horizontal, layout.Axis);
        Assert.True(layout.IsConfident, $"confidence {layout.Confidence}, points {layout.InkPoints}");
        Assert.InRange(layout.SkewDegrees, turn.Degrees - 0.15, turn.Degrees + 0.15);
    }

    [Fact]
    public void EstimateTextLayout_StraightText_IsStraight()
    {
        var layout = DocumentGeometry.EstimateTextLayout(TestPages.TextPage());
        Assert.Equal(TextAxis.Horizontal, layout.Axis);
        Assert.True(layout.IsConfident);
        Assert.InRange(layout.SkewDegrees, -0.1, 0.1);
    }

    [Fact]
    public void EstimateTextLayout_PageOnItsSide_HasVerticalLines()
    {
        var sideways = GrayImage.Luma(TestPages.Turned(TestPages.TextPage(), TestPages.Plus2, 245).ToRgba().RotatedQuarterTurns(1));
        var layout = DocumentGeometry.EstimateTextLayout(sideways);
        Assert.Equal(TextAxis.Vertical, layout.Axis);
        Assert.True(layout.IsConfident);
        // Turning the page a quarter keeps the skew's sense: the columns lean the same way.
        Assert.InRange(layout.SkewDegrees, TestPages.Plus2.Degrees - 0.15, TestPages.Plus2.Degrees + 0.15);
    }

    [Fact]
    public void EstimateTextLayout_BlankPage_IsNotConfident()
    {
        foreach (var page in new[] { TestPages.CleanBlank(), TestPages.NoisyBlank(), TestPages.PageNumber() })
        {
            var layout = DocumentGeometry.EstimateTextLayout(page);
            Assert.False(layout.IsConfident);
            Assert.Null(DocumentGeometry.Plan(page, crop: false, straighten: true));
        }
    }

    [Fact]
    public void Plan_TinySkew_LeavesThePage()
    {
        var page = TestPages.Turned(TestPages.TextPage(), TestPages.Plus0Point1, 245);
        Assert.Null(DocumentGeometry.Plan(page, crop: false, straighten: true));
        Assert.Null(DocumentGeometry.Plan(TestPages.TextPage(), crop: true, straighten: true));
    }

    [Fact]
    public void Plan_SkewedText_TurnsTheScanInPlace()
    {
        var page = TestPages.Turned(TestPages.TextPage(), TestPages.Plus3, 245);
        var plan = DocumentGeometry.Plan(page, crop: true, straighten: true);
        Assert.NotNull(plan);
        Assert.Equal(GeometryAction.Rotate, plan.Action);
        Assert.Equal(GeometryBasis.TextLines, plan.Basis);
        Assert.InRange(plan.AngleDegrees, 2.85, 3.15);
        // The corners turned out of the frame are paper: the scan keeps its size.
        Assert.Equal(new SizeD(page.Width, page.Height), plan.Canvas);
        Assert.Equal(new PageGeometry(false, plan.AngleDegrees, GeometryBasis.TextLines), plan.Geometry);
        // Straightening is not asked: nothing to do without a sheet.
        Assert.Null(DocumentGeometry.Plan(page, crop: true, straighten: false));
    }

    [Fact]
    public void Plan_TurningWouldCutOffMarksInTheCorners_GrowsTheCanvas()
    {
        var page = TestPages.Turned(TestPages.TextPage(), TestPages.Plus3, 245);
        // A mark in each corner of the scan: turning the page in place would cut them off.
        foreach (var (x, y) in new[] { (6, 6), (834, 6), (6, 1084), (834, 1084) })
        {
            for (int py = y; py < y + 10; py++)
            {
                for (int px = x; px < x + 10; px++) page.Pixels[py * page.Width + px] = 30;
            }
        }
        var plan = DocumentGeometry.Plan(page, crop: false, straighten: true);
        Assert.NotNull(plan);
        Assert.Equal(GeometryAction.Rotate, plan.Action);
        Assert.True(plan.Canvas.Width > page.Width && plan.Canvas.Height > page.Height, $"{plan.Canvas}");
        // Every corner mark lies inside the turned canvas.
        double a = plan.AngleDegrees * Math.PI / 180;
        foreach (var (x, y) in new[] { (6, 6), (844, 6), (6, 1094), (844, 1094) })
        {
            double dx = x - page.Width / 2.0, dy = y - page.Height / 2.0;
            Assert.True(Math.Abs(dx * Math.Cos(a) + dy * Math.Sin(a)) <= plan.Canvas.Width / 2);
            Assert.True(Math.Abs(-dx * Math.Sin(a) + dy * Math.Cos(a)) <= plan.Canvas.Height / 2);
        }
    }

    // MARK: - Page edges

    [Fact]
    public void DetectPage_WhiteSheetShownOnlyByItsShadow_IsFound()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Plus2, 245, 250, 2, 0x5EE70001);
        var search = DocumentGeometry.FindPage(page);
        Assert.Equal(PageRejection.None, search.Rejection);
        var region = search.Page!;
        Assert.InRange(region.Center.X, 425 - 2, 425 + 2);
        Assert.InRange(region.Center.Y, 550 - 2, 550 + 2);
        Assert.InRange(region.AngleDegrees, TestPages.Plus2.Degrees - 0.3, TestPages.Plus2.Degrees + 0.3);
        // The outline found is the sheet with its shadow.
        Assert.InRange(region.Size.Width, TestPages.SheetWidth - 2, TestPages.SheetWidth + 4 + 2);
        Assert.InRange(region.Size.Height, TestPages.SheetHeight - 2, TestPages.SheetHeight + 4 + 2);
        Assert.False(search.TouchesBorder);
    }

    [Fact]
    public void DetectPage_SheetOnADarkBackdrop_IsFound()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Minus4, 30, 240, 0, 0x5EE70002);
        var region = DocumentGeometry.DetectPage(page);
        Assert.NotNull(region);
        Assert.InRange(region.Center.X, 425 - 2, 425 + 2);
        Assert.InRange(region.Center.Y, 550 - 2, 550 + 2);
        Assert.InRange(region.AngleDegrees, TestPages.Minus4.Degrees - 0.3, TestPages.Minus4.Degrees + 0.3);
        Assert.InRange(region.Size.Width, TestPages.SheetWidth - 2, TestPages.SheetWidth + 2);
        Assert.InRange(region.Size.Height, TestPages.SheetHeight - 2, TestPages.SheetHeight + 2);
    }

    [Fact]
    public void DetectPage_SheetWithNoVisibleEdge_IsNotFound()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Plus2, 245, 248, 0, 0x5EE70003);
        Assert.Null(DocumentGeometry.DetectPage(page));
        Assert.Null(DocumentGeometry.Plan(page, crop: true, straighten: false));
    }

    [Fact]
    public void DetectPage_PageFillingTheScan_IsNotCropped()
    {
        Assert.Null(DocumentGeometry.DetectPage(TestPages.TextPage()));
        // A page with a thin dark line all around the scan's edge: the "sheet" is all of it.
        var framed = TestPages.TextPage();
        for (int x = 0; x < framed.Width; x++) { framed.Pixels[x] = 20; framed.Pixels[(framed.Height - 1) * framed.Width + x] = 20; }
        for (int y = 0; y < framed.Height; y++) { framed.Pixels[y * framed.Width] = 20; framed.Pixels[y * framed.Width + framed.Width - 1] = 20; }
        var search = DocumentGeometry.FindPage(framed);
        Assert.Null(search.Page);
        Assert.Equal(PageRejection.FillsScan, search.Rejection);
    }

    [Fact]
    public void DetectPage_PictureOnAPageOfText_IsNeverTakenForTheSheet()
    {
        // A dark 4 × 5 in picture (with a 0.2 in margin) in the middle of a page of text that fills
        // the scan: cropping to it would cut away the text.
        var page = TestPages.TextPage();
        for (int y = 280; y < 820; y++)
        {
            for (int x = 205; x < 645; x++)
            {
                bool picture = y >= 300 && y < 800 && x >= 225 && x < 625;
                page.Pixels[y * page.Width + x] = picture ? (byte)60 : (byte)245;
            }
        }
        var search = DocumentGeometry.FindPage(page);
        Assert.Null(search.Page);
        Assert.Equal(PageRejection.TextAround, search.Rejection);
        Assert.True(search.OutsideMarks > DocumentGeometry.MaxOutsideMarks);
        Assert.Null(DocumentGeometry.Plan(page, crop: true, straighten: false));
    }

    [Fact]
    public void DetectPage_AnotherSheetBesideIt_IsNotCropped_ASmallObjectIs()
    {
        // A 1 x 2 in card beside the sheet: cropping to the sheet would drop it.
        var page = TestPages.SheetOnBackdrop(TestPages.Straight, 30, 240, 0, 0x5EE70005);
        for (int y = 100; y < 300; y++)
        {
            for (int x = 740; x < 840; x++) page.Pixels[y * page.Width + x] = 240;
        }
        var search = DocumentGeometry.FindPage(page);
        Assert.Null(search.Page);
        Assert.Equal(PageRejection.OtherObjects, search.Rejection);
        // A thin 0.1 x 1.5 in strip (a thread, a ruler's edge) is not worth keeping: the sheet is found.
        var strip = TestPages.SheetOnBackdrop(TestPages.Straight, 30, 240, 0, 0x5EE70005);
        for (int y = 100; y < 250; y++)
        {
            for (int x = 760; x < 770; x++) strip.Pixels[y * strip.Width + x] = 240;
        }
        Assert.NotNull(DocumentGeometry.DetectPage(strip));
    }

    [Fact]
    public void DetectPage_SmallOrNothing_IsNotASheet()
    {
        Assert.Equal(PageRejection.NothingFound, DocumentGeometry.FindPage(TestPages.CleanBlank()).Rejection);
        // A card of 2 × 3 in on a dark backdrop: under the smallest sheet.
        var card = GrayImage.Filled(850, 1100, 30);
        for (int y = 400; y < 700; y++)
        {
            for (int x = 300; x < 500; x++) card.Pixels[y * 850 + x] = 240;
        }
        Assert.Equal(PageRejection.TooSmall, DocumentGeometry.FindPage(card).Rejection);
    }

    [Fact]
    public void Plan_SheetOnTheBackdrop_IsCutOutUpright()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Minus4, 30, 240, 0, 0x5EE70002);
        var plan = DocumentGeometry.Plan(page, crop: true, straighten: true)!;
        Assert.Equal(GeometryAction.CropStraightened, plan.Action);
        Assert.Equal(GeometryBasis.PageEdges, plan.Basis);
        Assert.InRange(plan.AngleDegrees, TestPages.Minus4.Degrees - 0.3, TestPages.Minus4.Degrees + 0.3);
        Assert.Equal("Cropped and straightened 4.0°", plan.Geometry.Caption);
        // Crop only: the box around the sheet, not turned.
        var box = DocumentGeometry.Plan(page, crop: true, straighten: false)!;
        Assert.Equal(GeometryAction.CropBox, box.Action);
        Assert.Equal(0, box.AngleDegrees);
        Assert.Equal("Cropped", box.Geometry.Caption);
        // Straighten only: the scan turned by the sheet's angle.
        var turn = DocumentGeometry.Plan(page, crop: false, straighten: true)!;
        Assert.Equal(GeometryAction.Rotate, turn.Action);
        Assert.Equal(GeometryBasis.PageEdges, turn.Basis);
        Assert.Equal("Straightened 4.0°", turn.Geometry.Caption);
    }

    [Fact]
    public void Plan_StraightSheet_IsCroppedNotTurned()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Straight, 30, 240, 0, 0x5EE70004);
        Assert.Equal(GeometryAction.CropBox, DocumentGeometry.Plan(page, crop: true, straighten: true)!.Action);
        // The sheet's edges say it is straight: the text is not asked.
        Assert.Null(DocumentGeometry.Plan(page, crop: false, straighten: true));
    }

    // MARK: - Correct (full resolution)

    [Fact]
    public void Correct_SheetOnADarkBackdrop_GivesTheSheetUpright()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Minus4, 30, 240, 0, 0x5EE70002);
        var result = DocumentGeometry.Correct(Rgba(page), 100, crop: true, straighten: true)!;
        Assert.True(result.Geometry.Cropped);
        Assert.InRange(result.Geometry.AngleDegrees, TestPages.Minus4.Degrees - 0.3, TestPages.Minus4.Degrees + 0.3);
        Assert.InRange(result.Image.Width, TestPages.SheetWidth - 4, TestPages.SheetWidth + 2);
        Assert.InRange(result.Image.Height, TestPages.SheetHeight - 4, TestPages.SheetHeight + 2);
        // No backdrop left along the edges: the outermost rows and columns are paper.
        var gray = GrayImage.Luma(result.Image);
        foreach (int x in new[] { 0, gray.Width - 1 }) Assert.True(ColumnMean(gray, x) > 150, $"column {x}: {ColumnMean(gray, x)}");
        foreach (int y in new[] { 0, gray.Height - 1 }) Assert.True(RowMean(gray, y) > 150, $"row {y}: {RowMean(gray, y)}");
    }

    [Fact]
    public void Correct_WhiteSheetOnALid_TrimsTheShadow()
    {
        var page = TestPages.SheetOnBackdrop(TestPages.Plus2, 245, 250, 2, 0x5EE70001);
        var result = DocumentGeometry.Correct(Rgba(page), 100, crop: true, straighten: true)!;
        Assert.Equal(GeometryAction.CropStraightened, result.Plan.Action);
        Assert.InRange(result.Image.Width, TestPages.SheetWidth - 4, TestPages.SheetWidth + 2);
        Assert.InRange(result.Image.Height, TestPages.SheetHeight - 4, TestPages.SheetHeight + 2);
        var gray = GrayImage.Luma(result.Image);
        foreach (int x in new[] { 0, gray.Width - 1 }) Assert.True(ColumnMean(gray, x) > 230, $"column {x}: {ColumnMean(gray, x)}");
        foreach (int y in new[] { 0, gray.Height - 1 }) Assert.True(RowMean(gray, y) > 230, $"row {y}: {RowMean(gray, y)}");
    }

    [Fact]
    public void Correct_NothingAskedOrNothingFound_LeavesThePage()
    {
        var page = Rgba(TestPages.TextPage());
        Assert.Null(DocumentGeometry.Correct(page, 100, crop: false, straighten: false));
        Assert.Null(DocumentGeometry.Correct(page, 100, crop: true, straighten: true));
        Assert.Null(DocumentGeometry.Correct(Rgba(TestPages.NoisyBlank()), 100, crop: true, straighten: true));
    }

    [Fact]
    public void Correct_TurnedText_KeepsTheScanSizeAndStraightensIt()
    {
        var page = Rgba(TestPages.Turned(TestPages.TextPage(), TestPages.Plus3, 245));
        var result = DocumentGeometry.Correct(page, 100, crop: false, straighten: true)!;
        Assert.Equal((850, 1100), (result.Image.Width, result.Image.Height));
        Assert.False(result.Geometry.Cropped);
        var after = DocumentGeometry.EstimateTextLayout(GrayImage.Luma(result.Image));
        Assert.InRange(after.SkewDegrees, -0.15, 0.15);
    }

    // MARK: - Helpers

    [Fact]
    public void RectAtAngle_EnclosesThePoints()
    {
        var points = new[] { new PointD(0, 0), new PointD(100, 0), new PointD(100, 50), new PointD(0, 50) };
        var straight = DocumentGeometry.RectAtAngle(points, 0);
        Assert.Equal(new PointD(50, 25), straight.Center);
        Assert.Equal(new SizeD(100, 50), straight.Size);
        var turned = DocumentGeometry.RectAtAngle(points, 10);
        foreach (var p in points)
        {
            double a = 10 * Math.PI / 180;
            double dx = p.X - turned.Center.X, dy = p.Y - turned.Center.Y;
            Assert.True(Math.Abs(dx * Math.Cos(a) + dy * Math.Sin(a)) <= turned.Size.Width / 2 + 1e-9);
            Assert.True(Math.Abs(-dx * Math.Sin(a) + dy * Math.Cos(a)) <= turned.Size.Height / 2 + 1e-9);
        }
    }

    [Fact]
    public void EdgeInsets_TrimOnlyDarkLinesAtTheEdge()
    {
        var gray = GrayImage.Filled(200, 300, 240);
        // A 2 px shadow along the left edge; print 10 px in from the right edge.
        for (int y = 0; y < 300; y++)
        {
            gray.Pixels[y * 200] = 150;
            gray.Pixels[y * 200 + 1] = 170;
            gray.Pixels[y * 200 + 189] = 20;
        }
        Assert.Equal((2, 0, 0, 0), DocumentGeometry.EdgeInsets(gray.ToRgba(), 100));
    }

    [Fact]
    public void BorderColor_IsTheRingsMedianPerChannel()
    {
        var image = RgbaImage.Filled(100, 100, 10, 20, 30);
        Assert.Equal(((byte)10, (byte)20, (byte)30), DocumentGeometry.BorderColor(image, 100));
    }

    [Fact]
    public void AngleText_HasOneDecimal()
    {
        Assert.Equal("2.4°", DocumentGeometry.AngleText(-2.4361));
        Assert.Equal("0.3°", DocumentGeometry.AngleText(0.25));
    }

    private static double RowMean(GrayImage gray, int y)
    {
        long sum = 0;
        for (int x = 0; x < gray.Width; x++) sum += gray.Pixels[y * gray.Width + x];
        return (double)sum / gray.Width;
    }

    private static double ColumnMean(GrayImage gray, int x)
    {
        long sum = 0;
        for (int y = 0; y < gray.Height; y++) sum += gray.Pixels[y * gray.Width + x];
        return (double)sum / gray.Height;
    }
}
