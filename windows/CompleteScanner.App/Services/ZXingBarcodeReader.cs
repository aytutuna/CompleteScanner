using CompleteScanner.Core;
using ZXing;
using ZXing.Common;
using IBarcodeReader = CompleteScanner.Core.IBarcodeReader;

namespace CompleteScanner.App.Services;

/// <summary>
/// Reads barcodes and QR codes (<see cref="BarcodeSymbologies.All"/>) on a page's gray copy with
/// ZXing.Net, fed the gray pixels directly. Three passes, each only when the ones before found
/// nothing: the image as given (at <see cref="BarcodeSeparators.ReadingDpi"/>,
/// fine enough for 0.01 in bars); the image at half that resolution, where the scanner's noise inside
/// the large modules of a separator sheet's code is averaged out (ZXing's local threshold otherwise
/// breaks them up); and the likely spots of a Data Matrix code one at a time, since ZXing finds one
/// only around the middle of the image it is given. The Windows counterpart of the Mac's
/// <c>VisionBarcodeReader</c>.
/// </summary>
public sealed class ZXingBarcodeReader : IBarcodeReader
{
    /// <summary>The kinds read, in ZXing's terms.</summary>
    private static readonly Dictionary<BarcodeFormat, BarcodeSymbology> Kinds = new()
    {
        [BarcodeFormat.QR_CODE] = BarcodeSymbology.QrCode,
        [BarcodeFormat.CODE_128] = BarcodeSymbology.Code128,
        [BarcodeFormat.CODE_39] = BarcodeSymbology.Code39,
        [BarcodeFormat.DATA_MATRIX] = BarcodeSymbology.DataMatrix,
    };

    /// <summary>A Data Matrix spot is looked for in cells this big; a code of at least this size is found.</summary>
    public const double SpotCellInches = 0.25;

    /// <summary>The window read around each spot, the most spots read on a page, and the most read again enlarged.</summary>
    public const double SpotWindowInches = 2;
    public const int MaxSpots = 64, MaxZoomedSpots = 16;

    /// <summary>A spot's cell is this share dark (a Data Matrix code is about half dark; text, rules and paper are not).</summary>
    public const double MinSpotInk = 0.25, MaxSpotInk = 0.75;

    /// <summary>Pixels darker than this count as ink when spots are looked for.</summary>
    public const byte DarkLevel = 128;

    public bool IsAvailable => true;

    public IReadOnlyList<BarcodeReading> Read(GrayImage image, CancellationToken token)
    {
        var all = new BarcodeReaderGeneric
        {
            AutoRotate = false,
            Options = new DecodingOptions { TryHarder = true, PossibleFormats = [.. Kinds.Keys] },
        };
        var found = Decode(all, image.Pixels, image.Width, image.Height, 0, 0, 1).ToList();
        token.ThrowIfCancellationRequested();
        if (found.Count == 0 && image.Width >= 400 && image.Height >= 400)
        {
            var half = image.Downsampled(image.Width / 2, image.Height / 2);
            found.AddRange(Decode(all, half.Pixels, half.Width, half.Height, 0, 0, (double)image.Width / half.Width));
            token.ThrowIfCancellationRequested();
        }
        if (found.Count == 0) found.AddRange(DataMatrixSpots(image, token));
        return found;
    }

    /// <summary>
    /// The Data Matrix codes found by reading a window centred on each likely spot: a cell about half
    /// dark, most even first, skipping spots inside a code already found; then the most even spots
    /// again, enlarged.
    /// </summary>
    private static List<BarcodeReading> DataMatrixSpots(GrayImage image, CancellationToken token)
    {
        int cell = Math.Max(8, (int)Math.Round(image.Dpi * SpotCellInches));
        int w = image.Width, h = image.Height;
        // Dark pixels summed over every rectangle from the top-left corner, to count each cell at once.
        var sums = new int[(w + 1) * (h + 1)];
        for (int y = 0; y < h; y++)
        {
            int row = 0;
            for (int x = 0; x < w; x++)
            {
                if (image.Pixels[y * w + x] < DarkLevel) row++;
                sums[(y + 1) * (w + 1) + x + 1] = sums[y * (w + 1) + x + 1] + row;
            }
        }
        // Cells overlapping by half, so a small code fills one of them.
        var spots = new List<(int X, int Y, double Unevenness)>();
        int step = Math.Max(1, cell / 2);
        for (int top = 0; top + cell <= h; top += step)
        {
            for (int left = 0; left + cell <= w; left += step)
            {
                int dark = sums[(top + cell) * (w + 1) + left + cell] - sums[top * (w + 1) + left + cell]
                           - sums[(top + cell) * (w + 1) + left] + sums[top * (w + 1) + left];
                double ink = (double)dark / (cell * cell);
                if (ink >= MinSpotInk && ink <= MaxSpotInk) spots.Add((left + cell / 2, top + cell / 2, Math.Abs(ink - 0.5)));
            }
        }
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = false,
            Options = new DecodingOptions { TryHarder = true, PossibleFormats = [BarcodeFormat.DATA_MATRIX] },
        };
        int window = Math.Max(cell * 2, (int)Math.Round(image.Dpi * SpotWindowInches));
        var buffer = new byte[window * window];
        var found = new List<BarcodeReading>();
        var ordered = spots.OrderBy(s => s.Unevenness).ThenBy(s => s.Y).ThenBy(s => s.X).ToList();
        // Each spot's window as it is; then, when none was read, the most even spots' windows enlarged
        // twice, for codes whose modules are only a few pixels or lie at a slant.
        foreach (int zoom in new[] { 1, 2 })
        {
            if (zoom == 2 && found.Count > 0) break;
            foreach (var (x, y, _) in ordered.Take(zoom == 1 ? MaxSpots : MaxZoomedSpots))
            {
                if (found.Any(r => Contains(r.Bounds, x, y, cell))) continue;
                token.ThrowIfCancellationRequested();
                // The window centred on the spot, white beyond the page's edges, so the spot stays in its middle.
                double half = window / 2.0 / zoom;
                Sample(image, x - half, y - half, 1.0 / zoom, buffer, window);
                found.AddRange(Decode(reader, buffer, window, window, x - half, y - half, 1.0 / zoom, multiple: false));
            }
        }
        return found;
    }

    /// <summary>
    /// Fills the <paramref name="size"/> × <paramref name="size"/> <paramref name="buffer"/> with the
    /// image from (<paramref name="left"/>, <paramref name="top"/>), <paramref name="step"/> image pixels
    /// a buffer pixel (bilinear), white beyond the image's edges.
    /// </summary>
    private static void Sample(GrayImage image, double left, double top, double step, byte[] buffer, int size)
    {
        int w = image.Width, h = image.Height;
        for (int by = 0; by < size; by++)
        {
            double sy = top + by * step;
            int iy = (int)Math.Floor(sy);
            double fy = sy - iy;
            for (int bx = 0; bx < size; bx++)
            {
                double sx = left + bx * step;
                int ix = (int)Math.Floor(sx);
                if (ix < 0 || iy < 0 || ix >= w || iy >= h)
                {
                    buffer[by * size + bx] = 255;
                    continue;
                }
                if (step == 1)
                {
                    buffer[by * size + bx] = image.Pixels[iy * w + ix];
                    continue;
                }
                double fx = sx - ix;
                int x1 = Math.Min(w - 1, ix + 1), y1 = Math.Min(h - 1, iy + 1);
                double value = image.Pixels[iy * w + ix] * (1 - fx) * (1 - fy) + image.Pixels[iy * w + x1] * fx * (1 - fy)
                               + image.Pixels[y1 * w + ix] * (1 - fx) * fy + image.Pixels[y1 * w + x1] * fx * fy;
                buffer[by * size + bx] = (byte)Math.Round(value);
            }
        }
    }

    /// <summary>Whether (<paramref name="x"/>, <paramref name="y"/>) lies within <paramref name="margin"/> pixels of <paramref name="bounds"/>.</summary>
    private static bool Contains(RectD bounds, int x, int y, int margin) =>
        x >= bounds.X - margin && x <= bounds.X + bounds.Width + margin
        && y >= bounds.Y - margin && y <= bounds.Y + bounds.Height + margin;

    /// <summary>
    /// The codes ZXing reads on the gray pixels, with their bounds (the box around ZXing's points)
    /// multiplied by <paramref name="scale"/> and moved by (<paramref name="offsetX"/>, <paramref name="offsetY"/>).
    /// </summary>
    private static IEnumerable<BarcodeReading> Decode(BarcodeReaderGeneric reader, byte[] pixels, int width, int height,
                                                      double offsetX, double offsetY, double scale, bool multiple = true)
    {
        var source = new RGBLuminanceSource(pixels, width, height, RGBLuminanceSource.BitmapFormat.Gray8);
        var results = multiple ? reader.DecodeMultiple(source) : reader.Decode(source) is { } one ? [one] : null;
        if (results is null) yield break;
        foreach (var result in results)
        {
            if (result is null || string.IsNullOrEmpty(result.Text) || !Kinds.TryGetValue(result.BarcodeFormat, out var kind)) continue;
            var points = (result.ResultPoints ?? []).Where(p => p is not null).ToList();
            var bounds = new RectD(0, 0, 0, 0);
            if (points.Count > 0)
            {
                double minX = points.Min(p => p.X), maxX = points.Max(p => p.X);
                double minY = points.Min(p => p.Y), maxY = points.Max(p => p.Y);
                bounds = new RectD(offsetX + minX * scale, offsetY + minY * scale, (maxX - minX) * scale, (maxY - minY) * scale);
            }
            yield return new BarcodeReading(kind, result.Text, bounds);
        }
    }
}
