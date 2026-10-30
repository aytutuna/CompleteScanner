using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/MultiQuadPickerTests.swift: the same outlines and picks.

public class MultiQuadPickerTests
{
    private static Quad Rect(double x, double y, double w, double h) =>
        new(new PointD(x, y), new PointD(x + w, y), new PointD(x + w, y + h), new PointD(x, y + h));

    private static QuadCandidate C(Quad quad, double confidence) => new(quad, confidence);

    [Fact]
    public void OverlapAndIntersectionArea()
    {
        var a = Rect(0, 0, 100, 100);
        Assert.Equal(10000, a.IntersectionArea(a), 9);
        Assert.Equal(2500, a.IntersectionArea(Rect(50, 50, 100, 100)), 9);
        Assert.Equal(0, a.IntersectionArea(Rect(200, 0, 50, 50)));
        Assert.Equal(2500.0 / 17500.0, MultiQuadPicker.Overlap(a, Rect(50, 50, 100, 100)), 12);
        Assert.Equal(1, MultiQuadPicker.Overlap(a, a), 12);
        // A diamond inside the square: half its area.
        var diamond = new Quad(new PointD(50, 0), new PointD(100, 50), new PointD(50, 100), new PointD(0, 50));
        Assert.Equal(5000, a.IntersectionArea(diamond), 9);
        Assert.Equal(5000, diamond.IntersectionArea(a), 9);
        // Turned 45° about the square's center: the regular octagon, (2√2 − 2) × 100² ≈ 8284.27.
        double h = 50 * Math.Sqrt(2);
        var turned = new Quad(new PointD(50, 50 - h), new PointD(50 + h, 50), new PointD(50, 50 + h), new PointD(50 - h, 50));
        Assert.Equal(8284.271247461902, a.IntersectionArea(turned), 6);
    }

    [Fact]
    public void ReceiptsAreKeptByShapeSizeAndInReadingOrder()
    {
        // Three receipts in two rows, a square coaster, a speck and the whole table.
        var candidates = new[]
        {
            C(Rect(600, 120, 160, 700), 0.9),   // top row, right
            C(Rect(100, 100, 150, 600), 0.8),   // top row, left
            C(Rect(350, 1100, 140, 500), 0.95), // second row
            C(Rect(1000, 300, 300, 300), 0.99), // square: not a receipt
            C(Rect(10, 10, 20, 50), 0.99),      // too small
            C(Rect(0, 0, 1600, 2000), 0.99),    // the table, too large
        };
        var picked = MultiQuadPicker.Pick(candidates, 1600, 2000, CaptureKind.Receipt);
        Assert.Equal([Rect(100, 100, 150, 600), Rect(600, 120, 160, 700), Rect(350, 1100, 140, 500)], picked);
    }

    [Fact]
    public void OverlappingOutlinesAreOneObjectTheSurerStays()
    {
        var sure = Rect(100, 100, 400, 600);
        var shifted = Rect(130, 120, 400, 600);   // the same photo seen again, a little off
        var beside = Rect(600, 100, 400, 600);
        var picked = MultiQuadPicker.Pick([C(shifted, 0.6), C(sure, 0.9), C(beside, 0.5)], 1200, 900, CaptureKind.Photo);
        Assert.Equal([sure, beside], picked);
        // On a tie the larger stays, then the earlier.
        var larger = Rect(100, 100, 420, 620);
        Assert.Equal([larger], MultiQuadPicker.Pick([C(shifted, 0.7), C(larger, 0.7)], 1200, 900,
                                                     new MultiQuadOptions { MaxLongOverShort = 2, MinAreaFraction = 0.01 }));
    }

    [Fact]
    public void AnOutlineInsideALargerOneIsPartOfIt()
    {
        // A print with a white border: Vision also finds the picture inside it, and surer.
        var printed = Rect(200, 200, 600, 400);
        var picture = Rect(230, 230, 540, 340);
        var picked = MultiQuadPicker.Pick([C(picture, 0.95), C(printed, 0.7)], 1200, 900, CaptureKind.Photo);
        Assert.Equal([printed], picked);
        // Two corners a pixel outside still count as inside.
        var almost = Rect(199, 230, 540, 340);
        Assert.Equal([printed], MultiQuadPicker.Pick([C(almost, 0.95), C(printed, 0.7)], 1200, 900, CaptureKind.Photo));
    }

    [Fact]
    public void AnOutlineHoldingSeveralIsTheBackground()
    {
        // An album page holding four prints, one of them with its picture found too: the prints.
        var page = Rect(250, 300, 1000, 1400);
        var prints = new[] { Rect(300, 350, 400, 300), Rect(750, 350, 400, 300), Rect(300, 800, 400, 300), Rect(750, 800, 400, 300) };
        var picture = Rect(320, 370, 360, 260);
        var album = new[] { C(page, 0.99), C(prints[3], 0.8), C(picture, 0.95), C(prints[1], 0.7), C(prints[0], 0.6), C(prints[2], 0.9) };
        Assert.Equal(prints, MultiQuadPicker.Pick(album, 1500, 2000, CaptureKind.Photo));
        // The same page holding one print cannot be told from a print with a border: one object.
        Assert.Equal([page], MultiQuadPicker.Pick([C(page, 0.5), C(prints[0], 0.9)], 1500, 2000, CaptureKind.Photo));
        // Receipts on an A4 sheet laid under them for contrast (A4's shape is a receipt's too): the receipts.
        var sheet = Rect(200, 200, 1000, 1414);
        var receipts = new[] { Rect(250, 250, 150, 600), Rect(500, 250, 160, 700), Rect(800, 300, 140, 500) };
        Assert.Equal(receipts, MultiQuadPicker.Pick([C(receipts[2], 0.7), C(sheet, 0.99), C(receipts[0], 0.8), C(receipts[1], 0.9)],
                                                    1600, 2000, CaptureKind.Receipt));
        // Wanting one object, the outermost outline is it, whatever it holds.
        var document = Rect(100, 100, 700, 990);
        var top = Rect(150, 150, 600, 400);
        var bottom = Rect(150, 600, 600, 400);
        var one = new MultiQuadOptions { MinAreaFraction = 0.01 };
        Assert.Equal([document], MultiQuadPicker.Pick([C(top, 0.9), C(bottom, 0.9), C(document, 0.5)], 2400, 1600, one));
        Assert.Equal([top, bottom], MultiQuadPicker.Pick([C(top, 0.9), C(bottom, 0.9), C(document, 0.5)], 2400, 1600,
                                                         one with { MaxCount = 2 }));
    }

    [Fact]
    public void FeaturesInsideOnePrintLeaveItWhole()
    {
        // A 4 × 6 in print of a house over 40 % of the shot; two of its windows are found too, each
        // under 2 % of the shot and photo-shaped, together 8 % of the print: the print.
        var print = Rect(300, 325, 900, 1350);
        var windows = new[] { Rect(450, 500, 200, 250), Rect(850, 500, 200, 250) };
        Assert.Equal([print], MultiQuadPicker.Pick([C(windows[0], 0.9), C(print, 0.8), C(windows[1], 0.85)], 1500, 2000,
                                                   CaptureKind.Photo));
        // The print's picture found as well, holding the windows: still the print.
        var picture = Rect(330, 355, 840, 1290);
        Assert.Equal([print], MultiQuadPicker.Pick([C(windows[0], 0.9), C(picture, 0.95), C(print, 0.8), C(windows[1], 0.85)],
                                                   1500, 2000, CaptureKind.Photo));
        // The picture found twice, a little apart: one object seen twice, so the print.
        var again = Rect(326, 351, 840, 1290);
        Assert.Equal([print], MultiQuadPicker.Pick([C(picture, 0.95), C(again, 0.9), C(print, 0.8)], 1500, 2000,
                                                   CaptureKind.Photo));
        // Two prints laid on the same outline cover enough of it to make it the background.
        var left = Rect(330, 355, 420, 600);
        var right = Rect(760, 355, 420, 600);
        Assert.Equal([left, right], MultiQuadPicker.Pick([C(print, 0.99), C(left, 0.8), C(right, 0.7)], 1500, 2000,
                                                         CaptureKind.Photo));
    }

    [Fact]
    public void ACardIsPickedByItsShapeAndOnlyOne()
    {
        var card = Rect(300, 300, 856, 540);
        var page = Rect(100, 100, 700, 990);
        var second = Rect(1300, 300, 850, 536);
        var picked = MultiQuadPicker.Pick([C(page, 0.99), C(card, 0.8), C(second, 0.7)], 2400, 1600, CaptureKind.IdCard);
        Assert.Equal([card], picked);
        // A document takes the surest page-shaped outline, a card's shape included.
        Assert.Equal([page], MultiQuadPicker.Pick([C(page, 0.9), C(card, 0.5)], 2400, 1600, CaptureKind.Document));
        Assert.Equal([card], MultiQuadPicker.Pick([C(page, 0.5), C(card, 0.9)], 2400, 1600, CaptureKind.Document));
    }

    [Fact]
    public void PhotosAreCappedAndOddInputLeftOut()
    {
        var candidates = new List<QuadCandidate>();
        for (int i = 0; i < 12; i++)
        {
            candidates.Add(C(Rect(20 + i % 4 * 300, 20 + i / 4 * 300, 240, 180), 0.5 + i / 100.0));
        }
        var picked = MultiQuadPicker.Pick(candidates, 1240, 920, CaptureKind.Photo);
        Assert.Equal(8, picked.Count);
        // The surest eight (the last eight given), in reading order.
        Assert.Equal(Rect(20, 320, 240, 180), picked[0]);
        Assert.Equal(Rect(920, 620, 240, 180), picked[7]);
        // Corners given counterclockwise are named again; a bow tie is no outline; no photo, no pick.
        var counter = Rect(100, 100, 300, 200);
        var reversed = new Quad(counter.TopLeft, counter.BottomLeft, counter.BottomRight, counter.TopRight);
        Assert.Equal([counter], MultiQuadPicker.Pick([C(reversed, 0.9)], 1240, 920, CaptureKind.Photo));
        var bowTie = new Quad(new PointD(100, 100), new PointD(400, 300), new PointD(400, 100), new PointD(100, 300));
        Assert.Empty(MultiQuadPicker.Pick([C(bowTie, 0.9)], 1240, 920, CaptureKind.Photo));
        Assert.Empty(MultiQuadPicker.Pick([C(counter, 0.9)], 0, 920, CaptureKind.Photo));
        Assert.Empty(MultiQuadPicker.Pick([], 1240, 920, CaptureKind.Photo));
    }

    [Fact]
    public void EveryKindHasOptions()
    {
        foreach (var kind in Enum.GetValues<CaptureKind>())
        {
            var options = MultiQuadPicker.OptionsFor(kind);
            Assert.True(options.MinLongOverShort >= 1 && options.MaxLongOverShort > options.MinLongOverShort, kind.ToString());
            Assert.True(options.MinAreaFraction >= 0 && options.MaxAreaFraction > options.MinAreaFraction, kind.ToString());
            Assert.True(options.MaxCount >= 1, kind.ToString());
        }
        Assert.Equal(6, MultiQuadPicker.OptionsFor(CaptureKind.Receipt).MaxCount);
        Assert.Equal(8, MultiQuadPicker.OptionsFor(CaptureKind.Photo).MaxCount);
        Assert.Equal(1, MultiQuadPicker.OptionsFor(CaptureKind.IdCard).MaxCount);
        Assert.Equal(1, MultiQuadPicker.OptionsFor(CaptureKind.Document).MaxCount);
    }
}
