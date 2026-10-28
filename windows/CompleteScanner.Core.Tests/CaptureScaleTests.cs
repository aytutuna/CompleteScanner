using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/CaptureScaleTests.swift: the same shots, sizes and answers.

public class CaptureScaleTests
{
    /// <summary>cos and sin of the angles the shots are taken at, as literals so both platforms use the same numbers.</summary>
    private const double Cos35 = 0.8191520442889918, Sin35 = 0.573576436351046;
    private const double Cos25 = 0.9063077870366499, Sin25 = 0.42261826174069944;

    /// <summary>A 12 MP photo (4032 × 3024) from a camera of focal length 3000 px centered on it.</summary>
    private const int PhotoWidth = 4032, PhotoHeight = 3024;
    private const double Focal = 3000;

    /// <summary>
    /// The quad a flat <paramref name="width"/> × <paramref name="height"/> mm rectangle makes in the
    /// photo: turned by (cos, sin) <paramref name="turn"/> in its own plane, tilted back about the
    /// camera's x axis by (cos, sin) <paramref name="tilt"/>, its center moved by
    /// (<paramref name="offsetX"/>, <paramref name="offsetY"/>) mm at <paramref name="distance"/> mm.
    /// </summary>
    internal static Quad Shot(double width, double height, (double Cos, double Sin) turn, (double Cos, double Sin) tilt,
                              double distance, double offsetX = 0, double offsetY = 0)
    {
        var corners = new PointD[4];
        double[] us = [-width / 2, width / 2, width / 2, -width / 2];
        double[] vs = [-height / 2, -height / 2, height / 2, height / 2];
        for (int i = 0; i < 4; i++)
        {
            double u = us[i] * turn.Cos - vs[i] * turn.Sin;
            double v = us[i] * turn.Sin + vs[i] * turn.Cos;
            double x = u + offsetX;
            double y = v * tilt.Cos + offsetY;
            double z = distance + v * tilt.Sin;
            corners[i] = new PointD(PhotoWidth / 2.0 + Focal * x / z, PhotoHeight / 2.0 + Focal * y / z);
        }
        return Quad.FromCorners(corners);
    }

    private static readonly (double, double) Straight = (1, 0);

    private static Quad Rect(double x, double y, double w, double h) =>
        new(new PointD(x, y), new PointD(x + w, y), new PointD(x + w, y + h), new PointD(x, y + h));

    [Fact]
    public void AnIdCardTiltedBy35DegreesSnapsToId1()
    {
        // Turned 25° in its plane and tilted back 35°: the quad tells the camera's focal length.
        var card = Shot(85.6, 53.98, (Cos25, Sin25), (Cos35, Sin35), 260, 30, -20);
        var estimate = CaptureScale.Aspect(card, PhotoWidth, PhotoHeight);
        Assert.NotNull(estimate.FocalLength);
        Assert.InRange(estimate.FocalLength!.Value, Focal * 0.99, Focal * 1.01);
        Assert.InRange(estimate.LongOverShort, 1.5858 * 0.99, 1.5858 * 1.01);
        foreach (var kind in new[] { CaptureKind.IdCard, CaptureKind.Document })
        {
            var scale = CaptureScale.Measure(card, PhotoWidth, PhotoHeight, kind);
            Assert.Equal(CaptureScaleBasis.Paper, scale.Basis);
            Assert.Equal("idCard", scale.Size);
            Assert.Equal(PaperSize.IdCard, scale.Paper);
            Assert.True(scale.IsRealSize);
            // Made at its real size: 85.60 × 53.98 mm within 0.5 mm.
            double longMm = Math.Max(scale.PixelWidth, scale.PixelHeight) * 25.4 / scale.Dpi;
            double shortMm = Math.Min(scale.PixelWidth, scale.PixelHeight) * 25.4 / scale.Dpi;
            Assert.InRange(longMm, 85.1, 86.1);
            Assert.InRange(shortMm, 53.48, 54.48);
            Assert.InRange(scale.Dpi, 250, 400);
        }
    }

    [Fact]
    public void ACardTiltedAboutItsOwnEdgeNeedsTheFocalLength()
    {
        // Tilted 35° about an axis along its long edges: the quad alone tells no focal length.
        var card = Shot(85.6, 53.98, Straight, (Cos35, Sin35), 260);
        Assert.Null(CaptureScale.Aspect(card, PhotoWidth, PhotoHeight).FocalLength);
        Assert.Equal(CaptureScaleBasis.Nominal, CaptureScale.Measure(card, PhotoWidth, PhotoHeight, CaptureKind.IdCard).Basis);
        var known = CaptureScale.Measure(card, PhotoWidth, PhotoHeight, CaptureKind.IdCard, Focal);
        Assert.Equal("idCard", known.Size);
        Assert.True(known.PixelWidth > known.PixelHeight);
        // The camera's focal length from its EXIF 35 mm equivalent.
        double focal35 = Focal * CaptureScale.FullFrameDiagonalMm / Math.Sqrt(PhotoWidth * (double)PhotoWidth + PhotoHeight * (double)PhotoHeight);
        Assert.Equal(Focal, CaptureScale.FocalLengthPixels(focal35, PhotoWidth, PhotoHeight)!.Value, 6);
        Assert.Null(CaptureScale.FocalLengthPixels(0, PhotoWidth, PhotoHeight));
        Assert.Null(CaptureScale.FocalLengthPixels(26, 0, PhotoHeight));
    }

    [Fact]
    public void A4SnapsEitherWayRoundAtTheResolutionTheCameraResolved()
    {
        var portrait = Shot(210, 297, Straight, Straight, 600);
        var upright = CaptureScale.Measure(portrait, PhotoWidth, PhotoHeight, CaptureKind.Document);
        Assert.Equal(CaptureScaleBasis.Paper, upright.Basis);
        Assert.Equal("a4", upright.Size);
        // 297 mm at 600 mm and 3000 px: 1485 px over 11.6929 in = 127.0 dpi.
        Assert.Equal(127, upright.Dpi);
        Assert.Equal((int)Math.Floor(8.2677 * 127 + 0.5), upright.PixelWidth);
        Assert.Equal((int)Math.Floor(11.6929 * 127 + 0.5), upright.PixelHeight);
        Assert.Equal(8.2677, upright.WidthInches);
        Assert.Equal(11.6929, upright.HeightInches);

        var landscape = Shot(297, 210, Straight, Straight, 600);
        var turned = CaptureScale.Measure(landscape, PhotoWidth, PhotoHeight, CaptureKind.Document);
        Assert.Equal("a4", turned.Size);
        Assert.Equal(upright.PixelHeight, turned.PixelWidth);
        Assert.Equal(upright.PixelWidth, turned.PixelHeight);
        Assert.Equal(11.6929, turned.WidthInches);

        var letter = CaptureScale.Measure(Shot(215.9, 279.4, Straight, (Cos35, Sin35), 500, 0, 40), PhotoWidth, PhotoHeight,
                                          CaptureKind.Document, Focal);
        Assert.Equal("letter", letter.Size);
    }

    [Fact]
    public void NothingIsUpsampledAndCloseUpsAreCapped()
    {
        // A small A4 far away: its resolution follows its pixels, the page is no larger than seen.
        var small = Rect(100, 100, 200, 283);
        var far = CaptureScale.Measure(small, 1000, 1000, CaptureKind.Document);
        Assert.Equal("a4", far.Size);
        Assert.Equal(24, far.Dpi); // 283 / 11.6929 = 24.2
        Assert.True(far.PixelHeight <= 283 && far.PixelWidth <= 200);
        // A card filling a 12 MP photo keeps its pixels: 4000 / 3.370 = 1186.9 dpi.
        var close = Rect(16, 12, 4000, 2522);
        var card = CaptureScale.Measure(close, PhotoWidth, PhotoHeight, CaptureKind.IdCard);
        Assert.Equal("idCard", card.Size);
        Assert.Equal(1186, card.Dpi);
        Assert.Equal((int)Math.Floor(3.370 * 1186 + 0.5), card.PixelWidth);
        Assert.Equal((int)Math.Floor(2.125 * 1186 + 0.5), card.PixelHeight);
        Assert.True(card.PixelWidth <= 4000 && card.PixelHeight <= 2522);
        // Filling a 24 MP photo (5712 × 4284) it would be 1661 dpi: it is made at 1200.
        var closer = Rect(16, 12, 5600, 3531);
        var capped = CaptureScale.Measure(closer, 5712, 4284, CaptureKind.IdCard);
        Assert.Equal("idCard", capped.Size);
        Assert.Equal(CaptureScale.MaxDpi, capped.Dpi);
        Assert.Equal(1200, capped.Dpi);
        Assert.Equal((int)Math.Floor(3.370 * 1200 + 0.5), capped.PixelWidth);
        Assert.Equal((int)Math.Floor(2.125 * 1200 + 0.5), capped.PixelHeight);
    }

    [Fact]
    public void APageThatMatchesNothingGetsTheNominalResolution()
    {
        // 3:2 is no paper size: 200 dpi, the page keeps its pixels, its size is made up.
        var odd = Rect(50, 50, 900, 600);
        var scale = CaptureScale.Measure(odd, 1000, 800, CaptureKind.Document);
        Assert.Equal(CaptureScaleBasis.Nominal, scale.Basis);
        Assert.Null(scale.Size);
        Assert.Null(scale.Paper);
        Assert.False(scale.IsRealSize);
        Assert.Equal(CaptureScale.NominalDpi, scale.Dpi);
        Assert.Equal(900, scale.PixelWidth);
        Assert.Equal(600, scale.PixelHeight);
        Assert.Equal(4.5, scale.WidthInches);
        Assert.Equal(3.0, scale.HeightInches);
        // As a photo it is 4 × 6 in.
        var photo = CaptureScale.Measure(odd, 1000, 800, CaptureKind.Photo);
        Assert.Equal(CaptureScaleBasis.PhotoSize, photo.Basis);
        Assert.Equal("photo4x6in", photo.Size);
        Assert.Equal(150, photo.Dpi);
        Assert.Equal((900, 600), (photo.PixelWidth, photo.PixelHeight));
        Assert.Equal((6.0, 4.0), (photo.WidthInches, photo.HeightInches));
    }

    [Fact]
    public void AReceiptSnapsToItsWidthWhateverItsLength()
    {
        // 320 × 1600 px: 80 mm wide (3.15 in) at 101 dpi, its length its own.
        var receipt = Rect(100, 100, 320, 1600);
        var scale = CaptureScale.Measure(receipt, 1000, 2000, CaptureKind.Receipt);
        Assert.Equal(CaptureScaleBasis.ReceiptWidth, scale.Basis);
        Assert.Equal("receipt80mm", scale.Size);
        Assert.Equal(101, scale.Dpi);
        Assert.Equal((int)Math.Floor(80 / 25.4 * 101 + 0.5), scale.PixelWidth);
        Assert.Equal((int)Math.Floor(80 / 25.4 * 5 * 101 + 0.5), scale.PixelHeight);
        Assert.True(scale.PixelHeight <= 1600);
        Assert.Equal(80 / 25.4 * 5, scale.HeightInches, 9);
        // A list naming 57 mm first takes it.
        var narrow = CaptureScale.Measure(receipt, 1000, 2000, [CaptureScale.ReceiptWidths[1]]);
        Assert.Equal("receipt57mm", narrow.Size);
        Assert.Equal(142, narrow.Dpi); // 320 px over 2.244 in
    }

    [Fact]
    public void MatchTakesTheNearestWithinThreePercentThenAFreeLength()
    {
        Assert.Equal("a4", CaptureScale.Match(1.4142, CaptureScale.Papers)!.Id);
        Assert.Equal("a4", CaptureScale.Match(1.4142 * 1.029, CaptureScale.Papers)!.Id);
        Assert.Null(CaptureScale.Match(1.4142 * 1.031 * 1.0, [CaptureScale.Papers[0]]));
        Assert.Equal("letter", CaptureScale.Match(1.30, CaptureScale.Papers)!.Id);
        Assert.Equal("legal", CaptureScale.Match(1.64, CaptureScale.Papers)!.Id);
        Assert.Equal("idCard", CaptureScale.Match(1.60, CaptureScale.Papers)!.Id);
        Assert.Null(CaptureScale.Match(1.50, CaptureScale.Papers));
        Assert.Equal("photo5x7in", CaptureScale.Match(1.40, CaptureScale.PhotoSizes)!.Id);
        Assert.Equal("photo3.5x5in", CaptureScale.Match(1.43, CaptureScale.PhotoSizes)!.Id);
        Assert.Equal("receipt80mm", CaptureScale.Match(1.0, CaptureScale.ReceiptWidths)!.Id);
        Assert.Null(CaptureScale.Match(0.5, CaptureScale.Papers));
        Assert.Null(CaptureScale.Match(double.NaN, CaptureScale.ReceiptWidths));
        // 10 × 15 cm has 4 × 6 in's shape: the first listed wins.
        Assert.Equal("photo4x6in", CaptureScale.Match(1.5, CaptureScale.PhotoSizes)!.Id);
        Assert.Equal("photo10x15cm", CaptureScale.Match(1.5, [CaptureScale.PhotoSizes[3], CaptureScale.PhotoSizes[0]])!.Id);
    }

    [Fact]
    public void EveryKindHasItsSizesAndEveryNameIsFound()
    {
        foreach (var kind in Enum.GetValues<CaptureKind>())
        {
            Assert.NotEmpty(CaptureScale.Candidates(kind));
            foreach (var size in CaptureScale.Candidates(kind))
            {
                Assert.Same(size, CaptureScale.Find(size.Id));
                Assert.True(size.ShortInches > 0);
                Assert.True(size.LongInches is null || size.LongInches >= size.ShortInches);
            }
        }
        Assert.Equal(["a4", "letter", "legal", "idCard"], CaptureScale.Papers.Select(s => s.Id));
        Assert.Equal(["idCard"], CaptureScale.Candidates(CaptureKind.IdCard).Select(s => s.Id));
        Assert.Equal(PaperSize.A4, CaptureScale.Find("a4")!.Paper);
        Assert.Null(CaptureScale.Find("a3"));
        Assert.Null(CaptureScale.Find(null));
        // Each basis has its sizes.
        Assert.All(CaptureScale.Papers, s => Assert.Equal(CaptureScaleBasis.Paper, s.Basis));
        Assert.All(CaptureScale.ReceiptWidths, s => Assert.Equal(CaptureScaleBasis.ReceiptWidth, s.Basis));
        Assert.All(CaptureScale.PhotoSizes, s => Assert.Equal(CaptureScaleBasis.PhotoSize, s.Basis));
    }

    [Fact]
    public void FromAspectKeepsThePixelsOfAnUprightPage()
    {
        // Apple's scanner's A4 page, 2480 × 3508: 300 dpi.
        var a4 = CaptureScale.FromAspect(2480, 3508, CaptureKind.Document);
        Assert.Equal(("a4", 300, 2480, 3508), (a4.Size, a4.Dpi, a4.PixelWidth, a4.PixelHeight));
        Assert.Equal((8.2677, 11.6929), (a4.WidthInches, a4.HeightInches));
        // A close-up card keeps its 1200 dpi: its pixels are not touched.
        var card = CaptureScale.FromAspect(4044, 2550, CaptureKind.IdCard);
        Assert.Equal(("idCard", 1200), (card.Size, card.Dpi));
        var odd = CaptureScale.FromAspect(1000, 1000, CaptureKind.Document);
        Assert.Equal((CaptureScaleBasis.Nominal, 200, 5.0, 5.0), (odd.Basis, odd.Dpi, odd.WidthInches, odd.HeightInches));
        var receipt = CaptureScale.FromAspect(630, 3000, CaptureKind.Receipt);
        Assert.Equal(("receipt80mm", 200), (receipt.Size, receipt.Dpi));
        Assert.Equal(1, CaptureScale.FromAspect(0, 0, CaptureKind.Document).PixelWidth);
    }
}
