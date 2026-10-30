namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Pipeline/CornerHeatmap.swift: the same search, sums and divisions in
// the same order, so both platforms read the same corners from the same heatmaps.

/// <summary>
/// The page's corners from the heatmaps of DocAligner's corner models: four channels of
/// <c>width</c> × <c>height</c> values from 0 to 1, one per corner, top left, top right, bottom right and
/// bottom left. In each channel the values from <see cref="Threshold"/> up are the corner's; of their
/// 8-connected blobs the largest (most values) is taken, and the corner is its centre weighted by the heat,
/// as shares of the image (x right, y down; value (x, y) stands for the point (x + 0.5) / width,
/// (y + 0.5) / height). The confidence is the lowest of the four channels' peaks. Null when a channel has no
/// value from <see cref="Threshold"/> up, or the four corners are not a convex outline in their order.
/// </summary>
public static class CornerHeatmap
{
    public const float Threshold = 0.3f;

    public static QuadCandidate? Decode(float[] heat, int width, int height)
    {
        if (width <= 0 || height <= 0) return null;
        int plane = width * height;
        if (heat.Length < plane * 4) return null;
        var visited = new bool[plane];
        var stack = new Stack<int>();
        var corners = new PointD[4];
        double confidence = 1;
        for (int channel = 0; channel < 4; channel++)
        {
            if (Corner(heat, channel * plane, width, height, visited, stack) is not { } found) return null;
            corners[channel] = found.Point;
            confidence = Math.Min(confidence, found.Peak);
        }
        var quad = new Quad(corners[0], corners[1], corners[2], corners[3]);
        if (!quad.IsConvex) return null;
        return new QuadCandidate(quad, confidence);
    }

    /// <summary>The heat-weighted centre of the largest blob in the channel starting at <paramref name="start"/>, and the channel's peak.</summary>
    private static (PointD Point, double Peak)? Corner(float[] heat, int start, int width, int height, bool[] visited, Stack<int> stack)
    {
        int plane = width * height;
        Array.Clear(visited);
        float peak = 0;
        int bestCount = 0;
        double bestX = 0, bestY = 0;
        for (int first = 0; first < plane; first++)
        {
            float value = heat[start + first];
            peak = Math.Max(peak, value);
            if (value < Threshold || visited[first]) continue;
            visited[first] = true;
            stack.Clear();
            stack.Push(first);
            int count = 0;
            double sum = 0, sumX = 0, sumY = 0;
            while (stack.Count > 0)
            {
                int at = stack.Pop();
                int x = at % width, y = at / width;
                double weight = heat[start + at];
                count++;
                sum += weight;
                sumX += weight * (x + 0.5);
                sumY += weight * (y + 0.5);
                for (int ny = Math.Max(y - 1, 0); ny <= Math.Min(y + 1, height - 1); ny++)
                {
                    for (int nx = Math.Max(x - 1, 0); nx <= Math.Min(x + 1, width - 1); nx++)
                    {
                        int next = ny * width + nx;
                        if (!visited[next] && heat[start + next] >= Threshold)
                        {
                            visited[next] = true;
                            stack.Push(next);
                        }
                    }
                }
            }
            if (count > bestCount)
            {
                bestCount = count;
                bestX = sumX / sum;
                bestY = sumY / sum;
            }
        }
        if (bestCount == 0) return null;
        return (new PointD(bestX / width, bestY / height), peak);
    }
}
