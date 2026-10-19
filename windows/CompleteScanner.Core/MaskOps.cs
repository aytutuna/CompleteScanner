namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/MaskOps.swift.

/// <summary>One 4-connected region of a binary mask.</summary>
internal sealed class MaskComponent
{
    public int Area;
    /// <summary>Per-row horizontal extent: y -> (minX, maxX), in the order rows were first reached.</summary>
    public readonly Dictionary<int, (int MinX, int MaxX)> Rows = [];
}

/// <summary>
/// Binary-mask operations shared by the detectors (photos, blank pages, and later receipts and
/// page edges). A mask is one byte per pixel, row-major, 1 = set and 0 = clear. Moved out of
/// <see cref="PhotoDetector"/> unchanged, so photo detection gives exactly the same regions.
/// </summary>
internal static class MaskOps
{
    // MARK: - Morphology (square kernel, separable passes)

    /// <summary>Dilation with a (2r+1)×(2r+1) square: a pixel is set when any pixel within r (per axis) is.</summary>
    public static byte[] Dilate(byte[] mask, int w, int h, int r)
    {
        var tmp = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                byte v = 0;
                int lo = Math.Max(0, x - r), hi = Math.Min(w - 1, x + r);
                for (int xx = lo; xx <= hi; xx++)
                {
                    if (mask[row + xx] == 1) { v = 1; break; }
                }
                tmp[row + x] = v;
            }
        }
        var output = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte v = 0;
                int lo = Math.Max(0, y - r), hi = Math.Min(h - 1, y + r);
                for (int yy = lo; yy <= hi; yy++)
                {
                    if (tmp[yy * w + x] == 1) { v = 1; break; }
                }
                output[y * w + x] = v;
            }
        }
        return output;
    }

    /// <summary>
    /// Erosion with a (2r+1)×(2r+1) square: a pixel stays set when every pixel within r is.
    /// Pixels outside the image count as clear, so the mask shrinks at the borders.
    /// </summary>
    public static byte[] Erode(byte[] mask, int w, int h, int r)
    {
        var tmp = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                byte v = (byte)((x - r >= 0 && x + r < w) ? 1 : 0);
                if (v == 1)
                {
                    for (int xx = x - r; xx <= x + r; xx++)
                    {
                        if (mask[row + xx] == 0) { v = 0; break; }
                    }
                }
                tmp[row + x] = v;
            }
        }
        var output = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte v = (byte)((y - r >= 0 && y + r < h) ? 1 : 0);
                if (v == 1)
                {
                    for (int yy = y - r; yy <= y + r; yy++)
                    {
                        if (tmp[yy * w + x] == 0) { v = 0; break; }
                    }
                }
                output[y * w + x] = v;
            }
        }
        return output;
    }

    // MARK: - Connected components

    /// <summary>
    /// The 4-connected components of the set pixels, in the order their first pixel appears
    /// (row-major), each with its area and per-row extent.
    /// </summary>
    public static List<MaskComponent> ConnectedComponents(byte[] mask, int width, int height)
    {
        var visited = new bool[mask.Length];
        var components = new List<MaskComponent>();
        var stack = new Stack<int>();
        for (int start = 0; start < mask.Length; start++)
        {
            if (mask[start] != 1 || visited[start]) continue;
            var comp = new MaskComponent();
            visited[start] = true;
            stack.Clear();
            stack.Push(start);
            while (stack.Count > 0)
            {
                int idx = stack.Pop();
                int x = idx % width, y = idx / width;
                comp.Area += 1;
                if (comp.Rows.TryGetValue(y, out var span))
                    comp.Rows[y] = (Math.Min(span.MinX, x), Math.Max(span.MaxX, x));
                else
                    comp.Rows[y] = (x, x);
                if (x > 0 && mask[idx - 1] == 1 && !visited[idx - 1]) { visited[idx - 1] = true; stack.Push(idx - 1); }
                if (x < width - 1 && mask[idx + 1] == 1 && !visited[idx + 1]) { visited[idx + 1] = true; stack.Push(idx + 1); }
                if (y > 0 && mask[idx - width] == 1 && !visited[idx - width]) { visited[idx - width] = true; stack.Push(idx - width); }
                if (y < height - 1 && mask[idx + width] == 1 && !visited[idx + width]) { visited[idx + width] = true; stack.Push(idx + width); }
            }
            components.Add(comp);
        }
        return components;
    }

    /// <summary>
    /// The areas of the components of the set pixels, in the order their first pixel appears;
    /// cheaper than <see cref="ConnectedComponents"/> when only the sizes matter (dust filtering).
    /// 4-connected like <see cref="ConnectedComponents"/>, or 8-connected (diagonal neighbors join
    /// too, so a thin slanted pen stroke stays one mark).
    /// </summary>
    public static List<int> ComponentAreas(byte[] mask, int width, int height, bool eightConnected = false)
    {
        var visited = new bool[mask.Length];
        var areas = new List<int>();
        var stack = new Stack<int>();
        for (int start = 0; start < mask.Length; start++)
        {
            if (mask[start] != 1 || visited[start]) continue;
            int area = 0;
            visited[start] = true;
            stack.Clear();
            stack.Push(start);
            while (stack.Count > 0)
            {
                int idx = stack.Pop();
                int x = idx % width, y = idx / width;
                area += 1;
                if (x > 0 && mask[idx - 1] == 1 && !visited[idx - 1]) { visited[idx - 1] = true; stack.Push(idx - 1); }
                if (x < width - 1 && mask[idx + 1] == 1 && !visited[idx + 1]) { visited[idx + 1] = true; stack.Push(idx + 1); }
                if (y > 0 && mask[idx - width] == 1 && !visited[idx - width]) { visited[idx - width] = true; stack.Push(idx - width); }
                if (y < height - 1 && mask[idx + width] == 1 && !visited[idx + width]) { visited[idx + width] = true; stack.Push(idx + width); }
                if (!eightConnected) continue;
                if (x > 0 && y > 0 && mask[idx - width - 1] == 1 && !visited[idx - width - 1]) { visited[idx - width - 1] = true; stack.Push(idx - width - 1); }
                if (x < width - 1 && y > 0 && mask[idx - width + 1] == 1 && !visited[idx - width + 1]) { visited[idx - width + 1] = true; stack.Push(idx - width + 1); }
                if (x > 0 && y < height - 1 && mask[idx + width - 1] == 1 && !visited[idx + width - 1]) { visited[idx + width - 1] = true; stack.Push(idx + width - 1); }
                if (x < width - 1 && y < height - 1 && mask[idx + width + 1] == 1 && !visited[idx + width + 1]) { visited[idx + width + 1] = true; stack.Push(idx + width + 1); }
            }
            areas.Add(area);
        }
        return areas;
    }
}
