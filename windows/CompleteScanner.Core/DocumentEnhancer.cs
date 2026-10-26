namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/DocumentEnhancer.swift: the same tiles, the same sums and
// the same arithmetic in the same order, so a page gives the same bytes on both platforms.

/// <summary>How a page taken by a camera is cleaned up (<see cref="DocumentEnhancer"/>).</summary>
public enum DocumentEnhanceMode
{
    /// <summary>As <see cref="Color"/>, then gray when the page has no color left (<see cref="ColorAnalysis.IsEffectivelyGray(RgbaImage)"/>).</summary>
    Auto,
    /// <summary>The lighting evened out, the paper made white and neutral, the print stretched to black, in color.</summary>
    Color,
    /// <summary>As <see cref="Color"/>, in gray.</summary>
    Gray,
    /// <summary>The gray page thresholded: black print on white paper, every pixel 0 or 255.</summary>
    BlackAndWhite,
    /// <summary>A photo: its levels stretched as a whole, nothing evened out.</summary>
    Photo,
}

/// <summary>
/// The look of a document page taken by a camera, chosen page by page: cleaned up (<see cref="DocumentEnhancer"/>
/// in <see cref="DocumentEnhanceMode.Auto"/>), as the camera saw it (cut out, nothing else), or cleaned up in
/// gray or in black and white. Stored by its camelCase name; the first is the default and the fallback.
/// </summary>
public enum CaptureFilter
{
    Enhanced,
    Original,
    Grayscale,
    BlackAndWhite,
}

public static class CaptureFilters
{
    /// <summary>The order the filters are offered in.</summary>
    public static IReadOnlyList<CaptureFilter> DisplayOrder { get; } =
        [CaptureFilter.Original, CaptureFilter.Enhanced, CaptureFilter.Grayscale, CaptureFilter.BlackAndWhite];

    public static string Label(this CaptureFilter filter) => filter switch
    {
        CaptureFilter.Original => "Original",
        CaptureFilter.Grayscale => "Grayscale",
        CaptureFilter.BlackAndWhite => "B&W",
        _ => "Enhanced",
    };

    /// <summary>The clean-up this filter runs; null for <see cref="CaptureFilter.Original"/>.</summary>
    public static DocumentEnhanceMode? Mode(this CaptureFilter filter) => filter switch
    {
        CaptureFilter.Original => null,
        CaptureFilter.Grayscale => DocumentEnhanceMode.Gray,
        CaptureFilter.BlackAndWhite => DocumentEnhanceMode.BlackAndWhite,
        _ => DocumentEnhanceMode.Auto,
    };

    /// <summary>The filter of a page cleaned up in <paramref name="mode"/> as asked for (before <see cref="DocumentEnhanceMode.Auto"/> is resolved); null for a photo, which has no filter.</summary>
    public static CaptureFilter? Of(DocumentEnhanceMode mode) => mode switch
    {
        DocumentEnhanceMode.Auto or DocumentEnhanceMode.Color => CaptureFilter.Enhanced,
        DocumentEnhanceMode.Gray => CaptureFilter.Grayscale,
        DocumentEnhanceMode.BlackAndWhite => CaptureFilter.BlackAndWhite,
        _ => null,
    };
}

/// <summary>A page cleaned up: its pixels and the mode applied (<see cref="DocumentEnhanceMode.Auto"/> resolved to color or gray).</summary>
public sealed record DocumentEnhancement(RgbaImage Image, DocumentEnhanceMode Mode);

/// <summary>The paper's color as gains per channel: a channel times its gain is the paper's luma.</summary>
public readonly record struct PaperWhiteBalance(double R, double G, double B)
{
    public static PaperWhiteBalance Neutral { get; } = new(1, 1, 1);
}

/// <summary>
/// Cleans up a page taken by a camera, after it was cut out of its photo: the lighting evened out, so a
/// shadow across the sheet or a lamp's falloff leaves the paper one white, the paper's tint taken out,
/// and the print stretched to black. How bright the paper is everywhere is estimated in large tiles
/// (<see cref="TileSize"/>: about a sixteenth of the page's long side), each tile's paper the
/// <see cref="BackgroundPercentile"/> of its luma (<see cref="BackgroundMap"/>), tiles much darker than
/// the paper beside them (a picture, a black bar) filled in from it (<see cref="BackgroundMap.RaisedDarkTiles"/>
/// at <see cref="DarkTileShare"/>; a dark region that reaches the page's edge is a shadow cast across it
/// and is evened out instead), every tile at least <see cref="MinBackgroundShare"/> of the median
/// tile and <see cref="MinBackground"/>, and interpolated between tile centers. Each pixel is then
/// divided by the paper there, as a level of <see cref="Levels"/>: its luma for gray, each channel times
/// the paper's white balance (<see cref="WhiteBalance"/>: the paper's mean luma over each channel's mean,
/// over the pixels at least <see cref="PaperShare"/> of the paper there, within
/// <see cref="MinGain"/>...<see cref="MaxGain"/>) for color, at most 1. The levels are stretched linearly:
/// <see cref="WhitePoint"/> and above becomes white, the black point (the <see cref="BlackPercentile"/>
/// of the sampled luma levels, at most <see cref="MaxBlackPoint"/>) and below black. Black and white
/// thresholds the gray result at <see cref="Bilevel.Threshold"/>; since the levels are against the paper
/// where each pixel is, the threshold follows the lighting, and print in a shadow stays black. Photos are only stretched as a whole
/// (<see cref="DocumentEnhanceMode.Photo"/>). A page whose ground is dark with light print on it (a
/// chalkboard, a dark flyer, a slide: <see cref="IsLightOnDark"/>) has no paper to even out against, so it
/// is stretched as a whole like a photo and then made gray or black and white as the mode says. The
/// samples (white balance, black point, light on dark) are every <see cref="SampleStep"/>-th pixel of
/// every <see cref="SampleStep"/>-th row. Pure arithmetic in a fixed order: the same bytes on both platforms.
/// </summary>
public static class DocumentEnhancer
{
    /// <summary>The paper is estimated in tiles of about the long side over this.</summary>
    public const int TilesAlongLongSide = 16;
    /// <summary>The smallest tile, in pixels.</summary>
    public const int MinTileSize = 8;
    /// <summary>A tile's paper is this percentile of its luma (the paper between the print).</summary>
    public const double BackgroundPercentile = 0.9;
    /// <summary>A tile darker than this share of its brightest neighbor is no paper and is filled from it.</summary>
    public const double DarkTileShare = 0.7;
    /// <summary>Every tile is at least this share of the median tile…</summary>
    public const double MinBackgroundShare = 0.4;
    /// <summary>…and at least this luma, so a dark area is not blown up.</summary>
    public const int MinBackground = 32;
    /// <summary>A pixel at least this share of the paper there counts as paper for the white balance.</summary>
    public const double PaperShare = 0.9;
    /// <summary>The white balance's gains are kept within MinGain...MaxGain.</summary>
    public const double MinGain = 0.625;
    public const double MaxGain = 1.6;
    /// <summary>Levels at or above this share of the paper become white.</summary>
    public const double WhitePoint = 0.9;
    /// <summary>The share of the sampled levels taken as the darkest print.</summary>
    public const double BlackPercentile = 0.005;
    /// <summary>The black point is at most this level, so a page with little print is not stretched into noise.</summary>
    public const double MaxBlackPoint = 0.5;
    /// <summary>The steps a level is counted in.</summary>
    public const int Levels = 1024;
    /// <summary>The samples are every SampleStep-th pixel of every SampleStep-th row.</summary>
    public const int SampleStep = 2;
    /// <summary>A photo's levels are stretched from this share of its pixels at the dark end to as many at the bright end…</summary>
    public const double PhotoClip = 0.005;
    /// <summary>…when those two lumas are at least this far apart; a flatter photo is left as it is.</summary>
    public const int MinPhotoRange = 64;
    /// <summary>The ground of a page, to tell light print on a dark ground, is this percentile of each tile's luma.</summary>
    public const double GroundPercentile = 0.5;
    /// <summary>A pixel this many times as bright as the ground there is light print; this many times darker, dark print.</summary>
    public const double LightContrast = 1.5;
    /// <summary>A page is light on dark only with at least this share of the samples light print.</summary>
    public const double MinLightShare = 0.005;

    /// <summary>
    /// The mode for the pages of a task with <paramref name="settings"/>: <see cref="DocumentEnhanceMode.Photo"/>
    /// for photo tasks; else by the color mode: gray, black and white, or <see cref="DocumentEnhanceMode.Auto"/>
    /// for color (color where the page has color). A color task that collects pages in the queue takes the
    /// camera's filter instead (<see cref="TaskOptions.CameraFilter"/>): null for Original, no clean-up;
    /// receipts, cards and copies are always cleaned up.
    /// </summary>
    public static DocumentEnhanceMode? ModeFor(ScanSettings settings)
    {
        if (settings.Intent == ScanIntent.Photo) return DocumentEnhanceMode.Photo;
        return settings.ColorMode switch
        {
            ColorMode.Grayscale => DocumentEnhanceMode.Gray,
            ColorMode.BlackWhite => DocumentEnhanceMode.BlackAndWhite,
            _ => TaskCatalog.FlowOf(settings) == TaskFlowKind.DocumentQueue
                ? settings.TaskOptions.CameraFilter.Mode()
                : DocumentEnhanceMode.Auto,
        };
    }

    /// <summary><paramref name="mode"/> for a shot of <paramref name="kind"/>: a photo print or an ID card is a photo, never evened out.</summary>
    public static DocumentEnhanceMode ModeFor(DocumentEnhanceMode mode, CaptureKind kind) =>
        kind is CaptureKind.Photo or CaptureKind.IdCard ? DocumentEnhanceMode.Photo : mode;

    /// <summary>The tile the paper is estimated in, for a page of <paramref name="width"/> × <paramref name="height"/>.</summary>
    public static int TileSize(int width, int height) => Math.Max(MinTileSize, Math.Max(width, height) / TilesAlongLongSide);

    /// <summary>How bright the paper is across <paramref name="gray"/> (see the type).</summary>
    public static BackgroundMap PaperMap(GrayImage gray)
    {
        var raw = BackgroundMap.Estimate(gray, 0, 0, gray.Width, gray.Height, TileSize(gray.Width, gray.Height), BackgroundPercentile)!;
        var filled = raw.RaisedDarkTiles(DarkTileShare);
        int floor = Math.Max(MinBackground, (int)Math.Floor(filled.MedianTile() * MinBackgroundShare));
        return filled.ClampedBelow((byte)Math.Min(255, floor));
    }

    /// <summary>
    /// Whether <paramref name="gray"/> is light print on a dark ground (a chalkboard, a dark flyer with white
    /// text, a slide), whose ground no division by the paper can make white: the ground is the
    /// <see cref="GroundPercentile"/> of each tile (<see cref="BackgroundMap"/>, tiles as for the paper). A
    /// sampled pixel at least <see cref="LightContrast"/> times the brightest ground of its tile and the eight
    /// around it (<see cref="BackgroundMap.MaxSmoothed"/>, interpolated, at least <see cref="MinBackground"/>)
    /// is light print; one at most the darkest of them (<see cref="BackgroundMap.MinSmoothed"/>, at least
    /// <see cref="MinBackground"/>) over <see cref="LightContrast"/> dark print. So the paper beside a hard
    /// step (the edge of a shadow, a dark picture), which is the ground of a tile next to it, counts as
    /// neither. Light on dark when there is more light print than dark, and at least
    /// <see cref="MinLightShare"/> of the samples.
    /// </summary>
    public static bool IsLightOnDark(GrayImage gray)
    {
        int w = gray.Width, h = gray.Height;
        var ground = BackgroundMap.Estimate(gray, 0, 0, w, h, TileSize(w, h), GroundPercentile);
        if (ground is null) return false;
        var highest = ground.MaxSmoothed();
        var lowest = ground.MinSmoothed();
        int light = 0, dark = 0, samples = 0;
        for (int y = 0; y < h; y += SampleStep)
        {
            for (int x = 0; x < w; x += SampleStep)
            {
                int luma = gray.Pixels[y * w + x];
                double above = Math.Max(highest.ValueAt(x, y), MinBackground);
                double below = Math.Max(lowest.ValueAt(x, y), MinBackground);
                if (luma >= above * LightContrast) light++;
                else if (luma * LightContrast <= below) dark++;
                samples++;
            }
        }
        return light > dark && light >= MinLightShare * samples;
    }

    /// <summary>
    /// The paper's white balance: over the sampled pixels at least <see cref="PaperShare"/> of the paper
    /// there, each channel's gain is the luma's sum over that channel's sum, within
    /// <see cref="MinGain"/>...<see cref="MaxGain"/>; neutral when no paper is seen.
    /// </summary>
    public static PaperWhiteBalance WhiteBalance(RgbaImage image, GrayImage gray, BackgroundMap paper)
    {
        int w = image.Width, h = image.Height;
        var src = image.Pixels;
        long sumR = 0, sumG = 0, sumB = 0, sumL = 0;
        for (int y = 0; y < h; y += SampleStep)
        {
            for (int x = 0; x < w; x += SampleStep)
            {
                int p = y * w + x;
                int luma = gray.Pixels[p];
                if (luma >= paper.ValueAt(x, y) * PaperShare)
                {
                    sumR += src[p * 4];
                    sumG += src[p * 4 + 1];
                    sumB += src[p * 4 + 2];
                    sumL += luma;
                }
            }
        }
        if (sumL == 0 || sumR == 0 || sumG == 0 || sumB == 0) return PaperWhiteBalance.Neutral;
        return new PaperWhiteBalance(Gain(sumL, sumR), Gain(sumL, sumG), Gain(sumL, sumB));
    }

    /// <summary>
    /// The black point: the <see cref="BlackPercentile"/> of the sampled pixels' luma levels against the
    /// paper there, at most <see cref="MaxBlackPoint"/>.
    /// </summary>
    public static double BlackPoint(GrayImage gray, BackgroundMap paper)
    {
        int w = gray.Width, h = gray.Height;
        var histogram = new int[Levels + 1];
        int samples = 0;
        for (int y = 0; y < h; y += SampleStep)
        {
            for (int x = 0; x < w; x += SampleStep)
            {
                histogram[Level(gray.Pixels[y * w + x], paper.ValueAt(x, y))]++;
                samples++;
            }
        }
        return Math.Min(Percentile(histogram, samples, BlackPercentile) / (double)Levels, MaxBlackPoint);
    }

    /// <summary><paramref name="image"/> cleaned up as <paramref name="mode"/> says (see the type).</summary>
    public static DocumentEnhancement Enhance(RgbaImage image, DocumentEnhanceMode mode)
    {
        if (mode == DocumentEnhanceMode.Photo) return new DocumentEnhancement(Photo(image), DocumentEnhanceMode.Photo);
        int w = image.Width, h = image.Height;
        var gray = GrayImage.Luma(image);
        if (IsLightOnDark(gray)) return LightOnDark(image, mode);
        var paper = PaperMap(gray);
        var lut = Stretch(BlackPoint(gray, paper), WhitePoint);
        bool color = mode is DocumentEnhanceMode.Auto or DocumentEnhanceMode.Color;
        var balance = color ? WhiteBalance(image, gray, paper) : PaperWhiteBalance.Neutral;
        var src = image.Pixels;
        var output = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int p = y * w + x, i = p * 4;
                double background = paper.ValueAt(x, y);
                if (color)
                {
                    output[i] = lut[Level(src[i] * balance.R, background)];
                    output[i + 1] = lut[Level(src[i + 1] * balance.G, background)];
                    output[i + 2] = lut[Level(src[i + 2] * balance.B, background)];
                }
                else
                {
                    byte v = lut[Level(gray.Pixels[p], background)];
                    if (mode == DocumentEnhanceMode.BlackAndWhite) v = v < Bilevel.Threshold ? (byte)0 : (byte)255;
                    output[i] = v;
                    output[i + 1] = v;
                    output[i + 2] = v;
                }
                output[i + 3] = 255;
            }
        }
        if (mode == DocumentEnhanceMode.Auto)
        {
            if (!ColorAnalysis.IsEffectivelyGray(output, w, h))
            {
                return new DocumentEnhancement(new RgbaImage(w, h, output), DocumentEnhanceMode.Color);
            }
            // No color left: the gray page, as the gray mode makes it.
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    int p = y * w + x, i = p * 4;
                    byte v = lut[Level(gray.Pixels[p], paper.ValueAt(x, y))];
                    output[i] = v;
                    output[i + 1] = v;
                    output[i + 2] = v;
                }
            }
            return new DocumentEnhancement(new RgbaImage(w, h, output), DocumentEnhanceMode.Gray);
        }
        return new DocumentEnhancement(new RgbaImage(w, h, output), mode);
    }

    /// <summary>
    /// A light on dark page (<see cref="IsLightOnDark"/>) in <paramref name="mode"/>: stretched as a whole
    /// (<see cref="Photo"/>), in color for <see cref="DocumentEnhanceMode.Color"/> and for
    /// <see cref="DocumentEnhanceMode.Auto"/> where it has color; else its luma, thresholded at
    /// <see cref="Bilevel.Threshold"/> for <see cref="DocumentEnhanceMode.BlackAndWhite"/>.
    /// </summary>
    private static DocumentEnhancement LightOnDark(RgbaImage image, DocumentEnhanceMode mode)
    {
        var stretched = Photo(image);
        int w = stretched.Width, h = stretched.Height;
        if (mode == DocumentEnhanceMode.Color) return new DocumentEnhancement(stretched, DocumentEnhanceMode.Color);
        if (mode == DocumentEnhanceMode.Auto && !ColorAnalysis.IsEffectivelyGray(stretched.Pixels, w, h))
        {
            return new DocumentEnhancement(stretched, DocumentEnhanceMode.Color);
        }
        var gray = GrayImage.Luma(stretched);
        var output = new byte[w * h * 4];
        for (int p = 0; p < w * h; p++)
        {
            byte v = gray.Pixels[p];
            if (mode == DocumentEnhanceMode.BlackAndWhite) v = v < Bilevel.Threshold ? (byte)0 : (byte)255;
            output[p * 4] = v;
            output[p * 4 + 1] = v;
            output[p * 4 + 2] = v;
            output[p * 4 + 3] = 255;
        }
        var applied = mode == DocumentEnhanceMode.Auto ? DocumentEnhanceMode.Gray : mode;
        return new DocumentEnhancement(new RgbaImage(w, h, output), applied);
    }

    /// <summary>
    /// A photo's levels stretched as a whole, the same for each channel: the <see cref="PhotoClip"/> and
    /// 1 − <see cref="PhotoClip"/> percentiles of its luma become 0 and 255; a photo whose two are less
    /// than <see cref="MinPhotoRange"/> apart is returned as it is (a copy).
    /// </summary>
    public static RgbaImage Photo(RgbaImage image)
    {
        int w = image.Width, h = image.Height;
        var gray = GrayImage.Luma(image);
        var histogram = new int[256];
        foreach (byte v in gray.Pixels) histogram[v]++;
        int count = w * h;
        int lo = BackgroundMap.Percentile(histogram, count, PhotoClip);
        int hi = BackgroundMap.Percentile(histogram, count, 1 - PhotoClip);
        if (hi - lo < MinPhotoRange) return image.Clone();
        var lut = new byte[256];
        for (int v = 0; v < 256; v++)
        {
            lut[v] = (byte)Math.Clamp(Math.Floor((v - lo) * 255.0 / (hi - lo) + 0.5), 0, 255);
        }
        var src = image.Pixels;
        var output = new byte[src.Length];
        for (int i = 0; i < src.Length; i += 4)
        {
            output[i] = lut[src[i]];
            output[i + 1] = lut[src[i + 1]];
            output[i + 2] = lut[src[i + 2]];
            output[i + 3] = src[i + 3];
        }
        return new RgbaImage(w, h, output);
    }

    /// <summary><paramref name="value"/> against the paper's <paramref name="background"/>, as a level 0...<see cref="Levels"/> (at most the paper's own).</summary>
    public static int Level(double value, double background) =>
        (int)Math.Floor(Math.Min(1.0, value / background) * Levels + 0.5);

    /// <summary>The levels 0...<see cref="Levels"/> stretched linearly from <paramref name="lo"/> (black) to <paramref name="hi"/> (white).</summary>
    public static byte[] Stretch(double lo, double hi)
    {
        var lut = new byte[Levels + 1];
        for (int k = 0; k <= Levels; k++)
        {
            double v = Math.Clamp((k / (double)Levels - lo) / (hi - lo), 0, 1);
            lut[k] = (byte)Math.Floor(v * 255 + 0.5);
        }
        return lut;
    }

    private static double Gain(long luma, long channel) => Math.Clamp((double)luma / channel, MinGain, MaxGain);

    /// <summary>The smallest level with at least ⌈fraction × count⌉ values at or below it.</summary>
    private static int Percentile(int[] histogram, int count, double fraction)
    {
        int rank = Math.Clamp((int)Math.Ceiling(fraction * count), 1, Math.Max(1, count));
        int seen = 0;
        for (int k = 0; k < histogram.Length; k++)
        {
            seen += histogram[k];
            if (seen >= rank) return k;
        }
        return histogram.Length - 1;
    }
}
