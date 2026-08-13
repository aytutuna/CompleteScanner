namespace CompleteScanner.Core;

/// <summary>
/// A plain RGBA8 bitmap: row-major, top-left origin, y down, 4 bytes per pixel (R, G, B, A).
/// This is the Core's replacement for CGImage — every algorithm in the portable core works
/// on this type, and the platform shell converts to/from its native bitmap type at the edges
/// (WPF BitmapSource on Windows, CGImage on macOS).
/// </summary>
public sealed class RgbaImage
{
    public int Width { get; }
    public int Height { get; }
    /// <summary>Length = Width * Height * 4. Mutable by design: the pipeline edits in place on copies.</summary>
    public byte[] Pixels { get; }

    public RgbaImage(int width, int height, byte[] pixels)
    {
        if (width <= 0 || height <= 0)
            throw new ArgumentOutOfRangeException(nameof(width), "Image dimensions must be positive.");
        if (pixels.Length != width * height * 4)
            throw new ArgumentException($"Pixel buffer must be {width * height * 4} bytes, got {pixels.Length}.", nameof(pixels));
        Width = width;
        Height = height;
        Pixels = pixels;
    }

    /// <summary>A width x height image filled with an opaque color.</summary>
    public static RgbaImage Filled(int width, int height, byte r, byte g, byte b)
    {
        var pixels = new byte[width * height * 4];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = r;
            pixels[i + 1] = g;
            pixels[i + 2] = b;
            pixels[i + 3] = 255;
        }
        return new RgbaImage(width, height, pixels);
    }

    public RgbaImage Clone() => new(Width, Height, (byte[])Pixels.Clone());

    /// <summary>
    /// Scaled copy. Minification uses box-filter averaging (each destination pixel is the
    /// mean of the source pixels it covers, matching CG's medium-quality downsampling well
    /// enough for detection); magnification uses bilinear sampling.
    /// </summary>
    public RgbaImage Resized(int newWidth, int newHeight)
    {
        if (newWidth <= 0 || newHeight <= 0)
            throw new ArgumentOutOfRangeException(nameof(newWidth), "Target dimensions must be positive.");
        if (newWidth == Width && newHeight == Height) return this;

        var output = new byte[newWidth * newHeight * 4];
        bool minifying = newWidth <= Width && newHeight <= Height;
        if (minifying)
        {
            // Box filter: average the source rectangle covered by each destination pixel.
            double xRatio = (double)Width / newWidth;
            double yRatio = (double)Height / newHeight;
            for (int dy = 0; dy < newHeight; dy++)
            {
                int sy0 = (int)(dy * yRatio);
                int sy1 = Math.Max(sy0 + 1, Math.Min(Height, (int)Math.Ceiling((dy + 1) * yRatio)));
                for (int dx = 0; dx < newWidth; dx++)
                {
                    int sx0 = (int)(dx * xRatio);
                    int sx1 = Math.Max(sx0 + 1, Math.Min(Width, (int)Math.Ceiling((dx + 1) * xRatio)));
                    long r = 0, g = 0, b = 0, a = 0;
                    int count = 0;
                    for (int sy = sy0; sy < sy1; sy++)
                    {
                        int row = (sy * Width + sx0) * 4;
                        for (int sx = sx0; sx < sx1; sx++)
                        {
                            r += Pixels[row];
                            g += Pixels[row + 1];
                            b += Pixels[row + 2];
                            a += Pixels[row + 3];
                            row += 4;
                            count++;
                        }
                    }
                    int di = (dy * newWidth + dx) * 4;
                    output[di] = (byte)(r / count);
                    output[di + 1] = (byte)(g / count);
                    output[di + 2] = (byte)(b / count);
                    output[di + 3] = (byte)(a / count);
                }
            }
        }
        else
        {
            for (int dy = 0; dy < newHeight; dy++)
            {
                double sy = (dy + 0.5) * Height / newHeight - 0.5;
                for (int dx = 0; dx < newWidth; dx++)
                {
                    double sx = (dx + 0.5) * Width / newWidth - 0.5;
                    int di = (dy * newWidth + dx) * 4;
                    SampleBilinear(sx, sy, output, di, 255, 255, 255);
                }
            }
        }
        return new RgbaImage(newWidth, newHeight, output);
    }

    /// <summary>
    /// Axis-aligned crop, clamped to the image bounds. Returns null when the clamped
    /// rectangle is empty (mirrors CGImage.cropping(to:)).
    /// </summary>
    public RgbaImage? Cropped(RectD rect)
    {
        var r = rect.Standardized.Integral.Intersection(new RectD(0, 0, Width, Height));
        int x = (int)r.MinX, y = (int)r.MinY, w = (int)r.Width, h = (int)r.Height;
        if (w < 1 || h < 1) return null;
        var output = new byte[w * h * 4];
        for (int row = 0; row < h; row++)
        {
            Array.Copy(Pixels, ((y + row) * Width + x) * 4, output, row * w * 4, w * 4);
        }
        return new RgbaImage(w, h, output);
    }

    /// <summary>
    /// Extract a rotated rectangle as an upright image: output pixel (u, v) in the
    /// rectangle's local frame samples the source at
    ///   ix = center.X + u*cos(a) - v*sin(a)
    ///   iy = center.Y + u*sin(a) + v*cos(a)
    /// — exactly the <see cref="DetectedPhotoRegion"/> corner convention (top-left origin,
    /// y down, positive angle clockwise on screen). Samples bilinearly; areas outside the
    /// source are white, matching the Swift extractor's white fill.
    /// </summary>
    public RgbaImage? ExtractRotated(PointD center, SizeD size, double angleDegrees)
    {
        int outW = (int)Math.Round(size.Width);
        int outH = (int)Math.Round(size.Height);
        if (outW <= 0 || outH <= 0) return null;

        double a = angleDegrees * Math.PI / 180;
        double cos = Math.Cos(a), sin = Math.Sin(a);
        var output = new byte[outW * outH * 4];
        for (int oy = 0; oy < outH; oy++)
        {
            double v = oy - (outH - 1) / 2.0;
            for (int ox = 0; ox < outW; ox++)
            {
                double u = ox - (outW - 1) / 2.0;
                double sx = center.X + u * cos - v * sin;
                double sy = center.Y + u * sin + v * cos;
                SampleBilinear(sx, sy, output, (oy * outW + ox) * 4, 255, 255, 255);
            }
        }
        return new RgbaImage(outW, outH, output);
    }

    /// <summary>Lossless 90° steps, clockwise on screen. quarterTurns is taken modulo 4.</summary>
    public RgbaImage RotatedQuarterTurns(int quarterTurns)
    {
        int turns = ((quarterTurns % 4) + 4) % 4;
        if (turns == 0) return this;

        int w = Width, h = Height;
        bool swaps = turns % 2 == 1;
        int nw = swaps ? h : w;
        int nh = swaps ? w : h;
        var output = new byte[nw * nh * 4];
        for (int dy = 0; dy < nh; dy++)
        {
            for (int dx = 0; dx < nw; dx++)
            {
                // Map each destination pixel back to its source pixel (y-down coordinates;
                // turns=1 is 90° clockwise on screen: source top-left → destination top-right).
                int sx, sy;
                switch (turns)
                {
                    case 1: sx = dy; sy = h - 1 - dx; break;
                    case 2: sx = w - 1 - dx; sy = h - 1 - dy; break;
                    default: sx = w - 1 - dy; sy = dx; break; // 3 = 90° counterclockwise
                }
                Array.Copy(Pixels, (sy * w + sx) * 4, output, (dy * nw + dx) * 4, 4);
            }
        }
        return new RgbaImage(nw, nh, output);
    }

    /// <summary>
    /// Bilinear sample at (sx, sy) into dest[destIndex..destIndex+3]; coordinates outside
    /// the image blend toward the given background color (opaque).
    /// </summary>
    private void SampleBilinear(double sx, double sy, byte[] dest, int destIndex,
                                byte bgR, byte bgG, byte bgB)
    {
        int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
        double fx = sx - x0, fy = sy - y0;

        Span<double> acc = stackalloc double[4];
        for (int corner = 0; corner < 4; corner++)
        {
            int cx = x0 + (corner & 1), cy = y0 + (corner >> 1);
            double weight = ((corner & 1) == 0 ? 1 - fx : fx) * ((corner >> 1) == 0 ? 1 - fy : fy);
            if (weight == 0) continue;
            if (cx >= 0 && cx < Width && cy >= 0 && cy < Height)
            {
                int si = (cy * Width + cx) * 4;
                acc[0] += weight * Pixels[si];
                acc[1] += weight * Pixels[si + 1];
                acc[2] += weight * Pixels[si + 2];
                acc[3] += weight * Pixels[si + 3];
            }
            else
            {
                acc[0] += weight * bgR;
                acc[1] += weight * bgG;
                acc[2] += weight * bgB;
                acc[3] += weight * 255;
            }
        }
        dest[destIndex] = (byte)Math.Clamp(Math.Round(acc[0]), 0, 255);
        dest[destIndex + 1] = (byte)Math.Clamp(Math.Round(acc[1]), 0, 255);
        dest[destIndex + 2] = (byte)Math.Clamp(Math.Round(acc[2]), 0, 255);
        dest[destIndex + 3] = (byte)Math.Clamp(Math.Round(acc[3]), 0, 255);
    }
}
