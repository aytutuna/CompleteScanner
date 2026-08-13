namespace CompleteScanner.Core;

/// <summary>
/// Adjustments + color-mode conversion, ported from
/// Sources/CompleteScannerKit/Pipeline/ImagePipeline.swift.
///
/// The macOS original composes Core Image filters; this port re-implements each step as
/// per-pixel math so the Core stays dependency-free. Semantics per step match the CI filter
/// parameters used by the Swift version; visual output is close but not bit-identical
/// (documented divergences: AutoEnhance is a histogram auto-level rather than Apple's
/// proprietary suggestion list, and grayscale/B&W stay RGBA rather than 8-bit gray).
/// </summary>
public static class ImagePipeline
{
    /// <summary>
    /// Apply adjustments + color-mode conversion. Returns the input instance unchanged when
    /// <c>settings.IsIdentity &amp;&amp; colorMode == Color</c>.
    /// </summary>
    public static RgbaImage Apply(AdjustmentSettings settings, RgbaImage image, ColorMode colorMode)
    {
        if (settings.IsIdentity && colorMode == ColorMode.Color) return image;

        int count = image.Width * image.Height;
        var src = image.Pixels;
        // Work in doubles 0...1 per channel.
        var r = new double[count];
        var g = new double[count];
        var b = new double[count];
        for (int i = 0; i < count; i++)
        {
            r[i] = src[i * 4] / 255.0;
            g[i] = src[i * 4 + 1] / 255.0;
            b[i] = src[i * 4 + 2] / 255.0;
        }

        // 1. Auto enhance — histogram auto-levels: stretch each channel so the 1st/99th
        //    luminance percentiles reach toward black/white (stand-in for CI's suggested filters).
        if (settings.AutoEnhance) AutoLevels(r, g, b);

        // 2. Brightness (-1...1) split across exposure (±1.5 EV) and a small additive lift,
        //    plus contrast and saturation (CIExposureAdjust + CIColorControls semantics).
        if (settings.Brightness != 0)
        {
            double gain = Math.Pow(2, settings.Brightness * 1.5);
            for (int i = 0; i < count; i++)
            {
                r[i] *= gain; g[i] *= gain; b[i] *= gain;
            }
        }
        double additive = settings.Brightness * 0.15;
        if (additive != 0 || settings.Contrast != 1 || settings.Saturation != 1)
            ColorControls(r, g, b, additive, settings.Contrast, settings.Saturation);

        // 3. Sharpen (CISharpenLuminance approximation: unsharp mask).
        if (settings.Sharpness > 0)
            Sharpen(r, g, b, image.Width, image.Height, settings.Sharpness);

        // 4. Descreen: tiny blur to break up halftone moiré, then a mild re-sharpen.
        if (settings.Descreen)
        {
            GaussianBlur3x3(r, g, b, image.Width, image.Height);
            Sharpen(r, g, b, image.Width, image.Height, 0.4);
        }

        // 5. Restore faded colors: vibrance boost + slight contrast.
        if (settings.RestoreFadedColors)
        {
            Vibrance(r, g, b, 0.5);
            ColorControls(r, g, b, 0, 1.05, 1);
        }

        // 6. Color-mode conversion.
        switch (colorMode)
        {
            case ColorMode.Color:
                break;
            case ColorMode.Grayscale:
                ColorControls(r, g, b, 0, 1, 0);
                break;
            case ColorMode.BlackWhite:
                // Desaturate first so the threshold applies to luminance.
                ColorControls(r, g, b, 0, 1, 0);
                for (int i = 0; i < count; i++)
                {
                    double v = r[i] > settings.BlackWhiteThreshold ? 1 : 0;
                    r[i] = v; g[i] = v; b[i] = v;
                }
                break;
        }

        // 7. Render back to bytes, preserving the exact pixel dimensions of the input.
        var output = new byte[count * 4];
        for (int i = 0; i < count; i++)
        {
            output[i * 4] = ToByte(r[i]);
            output[i * 4 + 1] = ToByte(g[i]);
            output[i * 4 + 2] = ToByte(b[i]);
            output[i * 4 + 3] = src[i * 4 + 3];
        }
        return new RgbaImage(image.Width, image.Height, output);
    }

    /// <summary>Lossless 90° steps, clockwise. quarterTurns 0...3.</summary>
    public static RgbaImage Rotate(RgbaImage image, int quarterTurns) =>
        image.RotatedQuarterTurns(quarterTurns);

    // MARK: - Steps

    private static byte ToByte(double v) => (byte)Math.Clamp(Math.Round(v * 255), 0, 255);

    private static double Luma(double r, double g, double b) =>
        0.299 * r + 0.587 * g + 0.114 * b;

    /// <summary>
    /// CIColorControls: additive brightness, contrast about mid-gray, saturation as a
    /// lerp between the pixel and its luminance.
    /// </summary>
    private static void ColorControls(double[] r, double[] g, double[] b,
                                      double brightness, double contrast, double saturation)
    {
        for (int i = 0; i < r.Length; i++)
        {
            double pr = r[i] + brightness;
            double pg = g[i] + brightness;
            double pb = b[i] + brightness;
            if (contrast != 1)
            {
                pr = (pr - 0.5) * contrast + 0.5;
                pg = (pg - 0.5) * contrast + 0.5;
                pb = (pb - 0.5) * contrast + 0.5;
            }
            if (saturation != 1)
            {
                double y = Luma(pr, pg, pb);
                pr = y + (pr - y) * saturation;
                pg = y + (pg - y) * saturation;
                pb = y + (pb - y) * saturation;
            }
            r[i] = pr; g[i] = pg; b[i] = pb;
        }
    }

    /// <summary>Unsharp mask: out = px + amount * (px - blur3x3(px)).</summary>
    private static void Sharpen(double[] r, double[] g, double[] b, int w, int h, double amount)
    {
        var br = (double[])r.Clone();
        var bg = (double[])g.Clone();
        var bb = (double[])b.Clone();
        GaussianBlur3x3(br, bg, bb, w, h);
        for (int i = 0; i < r.Length; i++)
        {
            r[i] += amount * (r[i] - br[i]);
            g[i] += amount * (g[i] - bg[i]);
            b[i] += amount * (b[i] - bb[i]);
        }
    }

    /// <summary>Separable [1 2 1]/4 Gaussian, edge-clamped — the radius-1 blur used by descreen.</summary>
    private static void GaussianBlur3x3(double[] r, double[] g, double[] b, int w, int h)
    {
        BlurPass(r, w, h);
        BlurPass(g, w, h);
        BlurPass(b, w, h);
    }

    private static void BlurPass(double[] channel, int w, int h)
    {
        var tmp = new double[channel.Length];
        // Horizontal.
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                double left = channel[row + Math.Max(0, x - 1)];
                double mid = channel[row + x];
                double right = channel[row + Math.Min(w - 1, x + 1)];
                tmp[row + x] = (left + 2 * mid + right) / 4;
            }
        }
        // Vertical.
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                double up = tmp[Math.Max(0, y - 1) * w + x];
                double mid = tmp[y * w + x];
                double down = tmp[Math.Min(h - 1, y + 1) * w + x];
                channel[y * w + x] = (up + 2 * mid + down) / 4;
            }
        }
    }

    /// <summary>CIVibrance approximation: boost saturation more for less-saturated pixels.</summary>
    private static void Vibrance(double[] r, double[] g, double[] b, double amount)
    {
        for (int i = 0; i < r.Length; i++)
        {
            double maxC = Math.Max(r[i], Math.Max(g[i], b[i]));
            double minC = Math.Min(r[i], Math.Min(g[i], b[i]));
            double sat = maxC - minC;
            double boost = 1 + amount * (1 - Math.Clamp(sat * 2, 0, 1));
            double y = Luma(r[i], g[i], b[i]);
            r[i] = y + (r[i] - y) * boost;
            g[i] = y + (g[i] - y) * boost;
            b[i] = y + (b[i] - y) * boost;
        }
    }

    /// <summary>
    /// Auto-levels: linear-stretch all channels by the same gain/offset so the image's 1st/99th
    /// luminance percentiles map toward 0/1. Conservative stand-in for CI auto-enhance.
    /// </summary>
    private static void AutoLevels(double[] r, double[] g, double[] b)
    {
        int count = r.Length;
        if (count == 0) return;
        var lum = new double[count];
        for (int i = 0; i < count; i++) lum[i] = Luma(r[i], g[i], b[i]);
        var sorted = (double[])lum.Clone();
        Array.Sort(sorted);
        double lo = sorted[(int)(count * 0.01)];
        double hi = sorted[Math.Min(count - 1, (int)(count * 0.99))];
        if (hi - lo < 0.05) return; // nearly flat image: leave it alone
        double gain = 1.0 / (hi - lo);
        for (int i = 0; i < count; i++)
        {
            r[i] = (r[i] - lo) * gain;
            g[i] = (g[i] - lo) * gain;
            b[i] = (b[i] - lo) * gain;
        }
    }
}
