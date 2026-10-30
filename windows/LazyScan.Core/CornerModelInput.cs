namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/CornerModelInput.swift: the same sampling arithmetic in the
// same order, so a corner model gets the very same numbers on both platforms.

/// <summary>
/// A photo as DocAligner's corner models take it: stretched to <see cref="Side"/> × <see cref="Side"/> (its
/// shape not kept, as the models were trained) and given as blue, green and red planes of values from 0 to
/// 1, one row after another. Sampled bilinearly with the pixel centres matched, as OpenCV's linear resize
/// does: input pixel (x, y) reads the photo at ((x + 0.5) × width / side − 0.5, (y + 0.5) × height / side −
/// 0.5), clamped to the photo, from the four pixels around it. Written out here rather than left to WPF or
/// CoreGraphics, whose scaling differs.
/// </summary>
public static class CornerModelInput
{
    /// <summary>The input's side, in pixels.</summary>
    public const int Side = 256;

    /// <summary><paramref name="photo"/> (alpha left out) as the model's input: 3 × <see cref="Side"/> × <see cref="Side"/> values.</summary>
    public static float[] Make(RgbaImage photo)
    {
        const int plane = Side * Side;
        var input = new float[3 * plane];
        var pixels = photo.Pixels;
        double scaleX = (double)photo.Width / Side, scaleY = (double)photo.Height / Side;
        for (int y = 0; y < Side; y++)
        {
            var row = Tap(y, scaleY, photo.Height);
            int top = row.Low * photo.Width, bottom = row.High * photo.Width;
            for (int x = 0; x < Side; x++)
            {
                var column = Tap(x, scaleX, photo.Width);
                for (int channel = 0; channel < 3; channel++)
                {
                    // Blue first: the models read OpenCV's BGR.
                    int offset = 2 - channel;
                    double a = pixels[(top + column.Low) * 4 + offset];
                    double b = pixels[(top + column.High) * 4 + offset];
                    double c = pixels[(bottom + column.Low) * 4 + offset];
                    double d = pixels[(bottom + column.High) * 4 + offset];
                    double upper = a + (b - a) * column.Weight;
                    double lower = c + (d - c) * column.Weight;
                    input[channel * plane + y * Side + x] = (float)((upper + (lower - upper) * row.Weight) / 255);
                }
            }
        }
        return input;
    }

    /// <summary>The two photo pixels input pixel <paramref name="index"/> reads along a side of <paramref name="size"/> pixels, and the second's weight.</summary>
    internal static (int Low, int High, double Weight) Tap(int index, double scale, int size)
    {
        double at = Math.Max((index + 0.5) * scale - 0.5, 0);
        int low = Math.Min((int)at, size - 1);
        int high = Math.Min(low + 1, size - 1);
        return (low, high, at - low);
    }
}
