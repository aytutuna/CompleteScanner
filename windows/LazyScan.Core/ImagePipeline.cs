using System.Numerics;

namespace LazyScan.Core;

/// <summary>
/// Adjustments + color-mode conversion, ported from
/// Sources/LazyScanKit/Pipeline/ImagePipeline.swift.
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

        // 3. Sharpen (CISharpenLuminance approximation: unsharp mask) — or, for negative
        //    values, soften with a small Gaussian blur (CIGaussianBlur semantics: the radius
        //    is the standard deviation; edges are clamped, so the extent is unchanged).
        if (settings.Sharpness > 0)
        {
            Sharpen(r, g, b, image.Width, image.Height, settings.Sharpness);
        }
        else if (settings.Sharpness < 0)
        {
            double radius = Math.Min(-settings.Sharpness, 2) * 2;
            var scratch = new double[count];
            GaussianBlur(r, image.Width, image.Height, radius, scratch);
            GaussianBlur(g, image.Width, image.Height, radius, scratch);
            GaussianBlur(b, image.Width, image.Height, radius, scratch);
        }

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
        var scratch = new double[r.Length];
        BlurPass(r, w, h, scratch);
        BlurPass(g, w, h, scratch);
        BlurPass(b, w, h, scratch);
    }

    /// <summary>
    /// One edge-clamped [1 2 1]/4 pass in each direction, in place. <paramref name="scratch"/>
    /// (at least <c>w * h</c> long, contents ignored) is reused when given so several
    /// channels share one temporary buffer.
    /// </summary>
    internal static void BlurPass(double[] channel, int w, int h, double[]? scratch = null)
    {
        var tmp = scratch is not null && scratch.Length >= channel.Length ? scratch : new double[channel.Length];
        // Horizontal: only the first and last column clamp; the interior reads its neighbors directly.
        ForEachRow(h, (long)w * 3, y =>
        {
            int row = y * w;
            BlurPassBorder(channel, tmp, row, w, 0);
            if (w > 1) BlurPassBorder(channel, tmp, row, w, w - 1);
            int x = 1;
            int end = w - 1;
            if (Vector.IsHardwareAccelerated)
            {
                var two = new Vector<double>(2);
                var four = new Vector<double>(4);
                for (; x <= end - Vector<double>.Count; x += Vector<double>.Count)
                {
                    var left = new Vector<double>(channel, row + x - 1);
                    var mid = new Vector<double>(channel, row + x);
                    var right = new Vector<double>(channel, row + x + 1);
                    ((left + two * mid + right) / four).CopyTo(tmp, row + x);
                }
            }
            for (; x < end; x++)
            {
                tmp[row + x] = (channel[row + x - 1] + 2 * channel[row + x] + channel[row + x + 1]) / 4;
            }
        });
        // Vertical: clamping picks whole rows, so every column of a row shares the same sources.
        ForEachRow(h, (long)w * 3, y =>
        {
            int row = y * w;
            int up = Math.Max(0, y - 1) * w;
            int down = Math.Min(h - 1, y + 1) * w;
            int x = 0;
            if (Vector.IsHardwareAccelerated)
            {
                var two = new Vector<double>(2);
                var four = new Vector<double>(4);
                for (; x <= w - Vector<double>.Count; x += Vector<double>.Count)
                {
                    var a = new Vector<double>(tmp, up + x);
                    var mid = new Vector<double>(tmp, row + x);
                    var c = new Vector<double>(tmp, down + x);
                    ((a + two * mid + c) / four).CopyTo(channel, row + x);
                }
            }
            for (; x < w; x++)
            {
                channel[row + x] = (tmp[up + x] + 2 * tmp[row + x] + tmp[down + x]) / 4;
            }
        });
    }

    private static void BlurPassBorder(double[] channel, double[] tmp, int row, int w, int x)
    {
        double left = channel[row + Math.Max(0, x - 1)];
        double mid = channel[row + x];
        double right = channel[row + Math.Min(w - 1, x + 1)];
        tmp[row + x] = (left + 2 * mid + right) / 4;
    }

    /// <summary>
    /// Below this standard deviation the kernel is numerically [0 1 0] (the outer taps
    /// underflow to zero), so the blur is the identity — and for absurdly small values
    /// (hand-edited settings) 2σ² itself underflows to zero and the kernel turns into NaN.
    /// </summary>
    private const double MinBlurSigma = 1e-3;

    /// <summary>
    /// Separable Gaussian with standard deviation <paramref name="sigma"/>, sampled over
    /// ±3σ and clamped to the edge — CIGaussianBlur on a clamped-to-extent image, cropped
    /// back to the original extent. <paramref name="scratch"/> (at least <c>w * h</c> long,
    /// contents ignored) is reused when given so several channels share one temporary buffer.
    ///
    /// Each output pixel accumulates its taps in the same order as the plain clamp-per-tap
    /// loop, so the result is bit-identical to it; the speed comes from clamping only at the
    /// borders, vectorizing across pixels, and processing rows in parallel.
    /// </summary>
    internal static void GaussianBlur(double[] channel, int w, int h, double sigma, double[]? scratch = null)
    {
        if (!(sigma >= MinBlurSigma)) return; // also rejects NaN
        int k = Math.Max(1, (int)Math.Ceiling(3 * sigma));
        var kernel = new double[2 * k + 1];
        double sum = 0;
        for (int i = -k; i <= k; i++)
        {
            kernel[i + k] = Math.Exp(-(i * i) / (2 * sigma * sigma));
            sum += kernel[i + k];
        }
        for (int i = 0; i < kernel.Length; i++) kernel[i] /= sum;

        var tmp = scratch is not null && scratch.Length >= channel.Length ? scratch : new double[channel.Length];
        long workPerRow = (long)w * kernel.Length;
        // Horizontal: clamp only where the kernel overhangs the left/right edge.
        ForEachRow(h, workPerRow, y =>
        {
            int row = y * w;
            int interiorStart = Math.Min(k, w);
            int interiorEnd = Math.Max(interiorStart, w - k);
            for (int x = 0; x < interiorStart; x++) tmp[row + x] = ClampedTaps(channel, row, w, x, kernel, k);
            for (int x = interiorEnd; x < w; x++) tmp[row + x] = ClampedTaps(channel, row, w, x, kernel, k);

            int ix = interiorStart;
            if (Vector.IsHardwareAccelerated)
            {
                for (; ix <= interiorEnd - Vector<double>.Count; ix += Vector<double>.Count)
                {
                    var acc = Vector<double>.Zero;
                    int start = row + ix - k;
                    for (int j = 0; j < kernel.Length; j++)
                        acc += new Vector<double>(kernel[j]) * new Vector<double>(channel, start + j);
                    acc.CopyTo(tmp, row + ix);
                }
            }
            for (; ix < interiorEnd; ix++)
            {
                double acc = 0;
                int start = row + ix - k;
                for (int j = 0; j < kernel.Length; j++) acc += kernel[j] * channel[start + j];
                tmp[row + ix] = acc;
            }
        });
        // Vertical: clamping picks whole source rows, so each output row accumulates
        // tap by tap across all its pixels (cache-friendly row reads, no per-pixel clamp).
        ForEachRow(h, workPerRow, y =>
        {
            int row = y * w;
            var output = channel.AsSpan(row, w);
            output.Clear();
            for (int j = 0; j < kernel.Length; j++)
            {
                int source = Math.Clamp(y - k + j, 0, h - 1) * w;
                double weight = kernel[j];
                int x = 0;
                if (Vector.IsHardwareAccelerated)
                {
                    var weightVector = new Vector<double>(weight);
                    for (; x <= w - Vector<double>.Count; x += Vector<double>.Count)
                    {
                        var acc = new Vector<double>(channel, row + x)
                                  + weightVector * new Vector<double>(tmp, source + x);
                        acc.CopyTo(channel, row + x);
                    }
                }
                for (; x < w; x++) channel[row + x] += weight * tmp[source + x];
            }
        });
    }

    /// <summary>One horizontal Gaussian tap sum with edge clamping (border pixels only).</summary>
    private static double ClampedTaps(double[] channel, int row, int w, int x, double[] kernel, int k)
    {
        double acc = 0;
        for (int i = -k; i <= k; i++)
            acc += kernel[i + k] * channel[row + Math.Clamp(x + i, 0, w - 1)];
        return acc;
    }

    /// <summary>
    /// Run <paramref name="body"/> for every row, in parallel once the total work is large
    /// enough to repay the scheduling cost. Rows must be independent.
    /// </summary>
    private static void ForEachRow(int h, long workPerRow, Action<int> body)
    {
        if (h * workPerRow < 1 << 18)
        {
            for (int y = 0; y < h; y++) body(y);
            return;
        }
        Parallel.For(0, h, body);
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
