namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/BackgroundMap.swift: same tiles, same arithmetic.

/// <summary>
/// How bright the paper is across a page, so that ink can be told from paper whatever the
/// paper's tint, the scanner's uneven lighting or a gradient across the sheet: the area is cut
/// into tiles, each tile's background is a high percentile of its pixels (the paper between the
/// marks), and the background of any pixel is interpolated between tile centers.
/// </summary>
public sealed class BackgroundMap
{
    /// <summary>Left edge of the area the map covers, in image pixels.</summary>
    public int X { get; }
    /// <summary>Top edge of the area the map covers, in image pixels.</summary>
    public int Y { get; }
    /// <summary>Width of the area the map covers.</summary>
    public int Width { get; }
    /// <summary>Height of the area the map covers.</summary>
    public int Height { get; }
    /// <summary>Tiles across.</summary>
    public int Columns { get; }
    /// <summary>Tiles down.</summary>
    public int Rows { get; }
    /// <summary>The background of each tile, row-major (Columns × Rows).</summary>
    public byte[] Tiles { get; }

    // Interpolation tables: for each column (row) of the area, the two tiles whose centers
    // surround it and the weight of the second.
    private readonly int[] _x0, _x1, _y0, _y1;
    private readonly double[] _fx, _fy;

    private BackgroundMap(int x, int y, int width, int height, int columns, int rows, byte[] tiles)
    {
        X = x;
        Y = y;
        Width = width;
        Height = height;
        Columns = columns;
        Rows = rows;
        Tiles = tiles;
        (_x0, _x1, _fx) = Interpolation(width, columns);
        (_y0, _y1, _fy) = Interpolation(height, rows);
    }

    /// <summary>
    /// The map of the area (x, y, width, height) of <paramref name="gray"/>, clamped to the
    /// image: tiles of about <paramref name="tileSize"/> pixels (whole tiles only, so the last
    /// ones are a little larger), each one's background the <paramref name="percentile"/>
    /// (0...1) of its pixels. Null when the area is empty.
    /// </summary>
    public static BackgroundMap? Estimate(GrayImage gray, int x, int y, int width, int height,
                                          int tileSize, double percentile = 0.9)
    {
        int x0 = Math.Clamp(x, 0, gray.Width), y0 = Math.Clamp(y, 0, gray.Height);
        int x1 = Math.Clamp(x + width, x0, gray.Width), y1 = Math.Clamp(y + height, y0, gray.Height);
        int w = x1 - x0, h = y1 - y0;
        if (w <= 0 || h <= 0) return null;
        int size = Math.Max(1, tileSize);
        int columns = Math.Max(1, w / size), rows = Math.Max(1, h / size);
        var tiles = new byte[columns * rows];
        var histogram = new int[256];
        for (int ty = 0; ty < rows; ty++)
        {
            int top = y0 + ty * h / rows, bottom = y0 + (ty + 1) * h / rows;
            for (int tx = 0; tx < columns; tx++)
            {
                int left = x0 + tx * w / columns, right = x0 + (tx + 1) * w / columns;
                Array.Clear(histogram);
                for (int py = top; py < bottom; py++)
                {
                    int row = py * gray.Width;
                    for (int px = left; px < right; px++) histogram[gray.Pixels[row + px]]++;
                }
                tiles[ty * columns + tx] = Percentile(histogram, (bottom - top) * (right - left), percentile);
            }
        }
        return new BackgroundMap(x0, y0, w, h, columns, rows, tiles);
    }

    /// <summary>
    /// The value at <paramref name="fraction"/> (0...1) of a histogram of <paramref name="count"/>
    /// values: the smallest value with at least ⌈fraction × count⌉ values at or below it.
    /// </summary>
    public static byte Percentile(int[] histogram, int count, double fraction)
    {
        int rank = Math.Clamp((int)Math.Ceiling(fraction * count), 1, Math.Max(1, count));
        int seen = 0;
        for (int v = 0; v < 256; v++)
        {
            seen += histogram[v];
            if (seen >= rank) return (byte)v;
        }
        return 255;
    }

    /// <summary>The middle tile background (the upper middle one for an even count).</summary>
    public byte MedianTile()
    {
        var sorted = (byte[])Tiles.Clone();
        Array.Sort(sorted);
        return sorted[sorted.Length / 2];
    }

    /// <summary>
    /// Each tile replaced by the brightest of itself and its eight neighbors, so a tile covered
    /// mostly by ink or a dark mark still gets the paper around it.
    /// </summary>
    public BackgroundMap MaxSmoothed()
    {
        var output = new byte[Tiles.Length];
        for (int ty = 0; ty < Rows; ty++)
        {
            for (int tx = 0; tx < Columns; tx++)
            {
                byte best = 0;
                for (int ny = Math.Max(0, ty - 1); ny <= Math.Min(Rows - 1, ty + 1); ny++)
                {
                    for (int nx = Math.Max(0, tx - 1); nx <= Math.Min(Columns - 1, tx + 1); nx++)
                    {
                        best = Math.Max(best, Tiles[ny * Columns + nx]);
                    }
                }
                output[ty * Columns + tx] = best;
            }
        }
        return new BackgroundMap(X, Y, Width, Height, Columns, Rows, output);
    }

    /// <summary>
    /// Each tile replaced by the darkest of itself and its eight neighbors (the counterpart of
    /// <see cref="MaxSmoothed"/>).
    /// </summary>
    public BackgroundMap MinSmoothed()
    {
        var output = new byte[Tiles.Length];
        for (int ty = 0; ty < Rows; ty++)
        {
            for (int tx = 0; tx < Columns; tx++)
            {
                byte least = 255;
                for (int ny = Math.Max(0, ty - 1); ny <= Math.Min(Rows - 1, ty + 1); ny++)
                {
                    for (int nx = Math.Max(0, tx - 1); nx <= Math.Min(Columns - 1, tx + 1); nx++)
                    {
                        least = Math.Min(least, Tiles[ny * Columns + nx]);
                    }
                }
                output[ty * Columns + tx] = least;
            }
        }
        return new BackgroundMap(X, Y, Width, Height, Columns, Rows, output);
    }

    /// <summary>
    /// Tiles much darker than the paper beside them filled in from it: a tile darker than
    /// <paramref name="share"/> of the brightest of its eight neighbors takes that neighbor's value,
    /// pass after pass (each pass reading the one before), until no tile changes or as many passes as
    /// the map is tiles across or down. A soft shadow darkens from tile to tile by less than that and
    /// stays; a picture or a dark mark larger than a tile is filled from the paper around it inwards.
    /// A filled region (tiles that changed, joined through their eight neighbors) that reaches the map's
    /// outer tiles is lighting, not a picture: a shadow cast across the sheet from beyond its edge, however
    /// hard its edge, so its tiles keep their own values and the shadow is evened out like a soft one.
    /// </summary>
    public BackgroundMap RaisedDarkTiles(double share)
    {
        var current = (byte[])Tiles.Clone();
        var next = new byte[current.Length];
        int passes = Math.Max(Columns, Rows);
        for (int pass = 0; pass < passes; pass++)
        {
            bool changed = false;
            for (int ty = 0; ty < Rows; ty++)
            {
                for (int tx = 0; tx < Columns; tx++)
                {
                    byte best = 0;
                    for (int ny = Math.Max(0, ty - 1); ny <= Math.Min(Rows - 1, ty + 1); ny++)
                    {
                        for (int nx = Math.Max(0, tx - 1); nx <= Math.Min(Columns - 1, tx + 1); nx++)
                        {
                            if (nx == tx && ny == ty) continue;
                            best = Math.Max(best, current[ny * Columns + nx]);
                        }
                    }
                    byte value = current[ty * Columns + tx];
                    if (value < share * best)
                    {
                        next[ty * Columns + tx] = best;
                        changed = true;
                    }
                    else
                    {
                        next[ty * Columns + tx] = value;
                    }
                }
            }
            (current, next) = (next, current);
            if (!changed) break;
        }
        // Each filled region in turn, from its first tile in row-major order; one that reaches an outer
        // tile is lighting and takes its own values back.
        var visited = new bool[current.Length];
        var members = new int[current.Length];
        for (int start = 0; start < current.Length; start++)
        {
            if (visited[start] || current[start] == Tiles[start]) continue;
            visited[start] = true;
            members[0] = start;
            int count = 1;
            bool reachesEdge = false;
            for (int k = 0; k < count; k++)
            {
                int tile = members[k];
                int tx = tile % Columns, ty = tile / Columns;
                if (tx == 0 || ty == 0 || tx == Columns - 1 || ty == Rows - 1) reachesEdge = true;
                for (int ny = Math.Max(0, ty - 1); ny <= Math.Min(Rows - 1, ty + 1); ny++)
                {
                    for (int nx = Math.Max(0, tx - 1); nx <= Math.Min(Columns - 1, tx + 1); nx++)
                    {
                        int n = ny * Columns + nx;
                        if (visited[n] || current[n] == Tiles[n]) continue;
                        visited[n] = true;
                        members[count] = n;
                        count++;
                    }
                }
            }
            if (!reachesEdge) continue;
            for (int k = 0; k < count; k++) current[members[k]] = Tiles[members[k]];
        }
        return new BackgroundMap(X, Y, Width, Height, Columns, Rows, current);
    }

    /// <summary>Each tile raised to at least <paramref name="floor"/>.</summary>
    public BackgroundMap ClampedBelow(byte floor)
    {
        var output = new byte[Tiles.Length];
        for (int i = 0; i < Tiles.Length; i++) output[i] = Math.Max(Tiles[i], floor);
        return new BackgroundMap(X, Y, Width, Height, Columns, Rows, output);
    }

    /// <summary>
    /// The background at image pixel (x, y) inside the area: bilinear between the centers of the
    /// surrounding tiles, the nearest tile's value beyond the outer centers.
    /// </summary>
    public double ValueAt(int x, int y)
    {
        int ax = Math.Clamp(x - X, 0, Width - 1), ay = Math.Clamp(y - Y, 0, Height - 1);
        double top = Lerp(Tiles[_y0[ay] * Columns + _x0[ax]], Tiles[_y0[ay] * Columns + _x1[ax]], _fx[ax]);
        double bottom = Lerp(Tiles[_y1[ay] * Columns + _x0[ax]], Tiles[_y1[ay] * Columns + _x1[ax]], _fx[ax]);
        return top + (bottom - top) * _fy[ay];
    }

    /// <summary>
    /// The ink of the area: 1 where a pixel is darker than (1 − <paramref name="contrast"/>) of
    /// the background there, 0 elsewhere. One byte per pixel, Width × Height, row-major.
    /// </summary>
    public byte[] InkMask(GrayImage gray, double contrast)
    {
        double keep = 1 - contrast;
        var mask = new byte[Width * Height];
        for (int ay = 0; ay < Height; ay++)
        {
            int row = (Y + ay) * gray.Width + X;
            int t0 = _y0[ay] * Columns, t1 = _y1[ay] * Columns;
            double fy = _fy[ay];
            for (int ax = 0; ax < Width; ax++)
            {
                double top = Lerp(Tiles[t0 + _x0[ax]], Tiles[t0 + _x1[ax]], _fx[ax]);
                double bottom = Lerp(Tiles[t1 + _x0[ax]], Tiles[t1 + _x1[ax]], _fx[ax]);
                double background = top + (bottom - top) * fy;
                if (gray.Pixels[row + ax] < background * keep) mask[ay * Width + ax] = 1;
            }
        }
        return mask;
    }

    private static double Lerp(byte a, byte b, double t) => a + (b - a) * t;

    /// <summary>
    /// For each of <paramref name="length"/> pixels split into <paramref name="tiles"/> equal
    /// tiles: the tiles whose centers surround the pixel's center and the second one's weight.
    /// </summary>
    private static (int[] First, int[] Second, double[] Weight) Interpolation(int length, int tiles)
    {
        var first = new int[length];
        var second = new int[length];
        var weight = new double[length];
        var centers = new double[tiles];
        for (int t = 0; t < tiles; t++)
        {
            int start = t * length / tiles, end = (t + 1) * length / tiles;
            centers[t] = (start + end) / 2.0;
        }
        int k = 0;
        for (int p = 0; p < length; p++)
        {
            double c = p + 0.5;
            while (k < tiles - 1 && centers[k + 1] <= c) k++;
            if (c <= centers[0])
            {
                first[p] = 0; second[p] = 0; weight[p] = 0;
            }
            else if (k >= tiles - 1)
            {
                first[p] = tiles - 1; second[p] = tiles - 1; weight[p] = 0;
            }
            else
            {
                first[p] = k; second[p] = k + 1;
                weight[p] = (c - centers[k]) / (centers[k + 1] - centers[k]);
            }
        }
        return (first, second, weight);
    }
}
