import CoreGraphics
import Foundation

/// A rotated rectangle in image pixel coordinates (origin top-left, x right, y down).
///
/// `angleDegrees` follows the `DetectedPhotoRegion` convention: it is applied with the
/// standard rotation matrix
///   ix = center.x + x*cos(a) - y*sin(a)
///   iy = center.y + x*sin(a) + y*cos(a)
/// Because y grows DOWNWARD in image coordinates, a positive angle appears as a
/// CLOCKWISE rotation on screen. `minAreaRect(of:)` normalizes the angle to (-45, 45],
/// swapping width/height as needed.
struct MinAreaRect {
    var center: CGPoint
    var size: CGSize
    var angleDegrees: Double
}

/// Andrew monotone chain convex hull.
///
/// Returns the hull vertices in counterclockwise order in the mathematical (y-up) sense —
/// which appears clockwise on screen for top-left-origin/y-down image coordinates.
/// Degenerate inputs: fewer than 3 distinct points return the distinct points themselves;
/// collinear input returns the two extreme endpoints.
func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    var pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    var unique: [CGPoint] = []
    unique.reserveCapacity(pts.count)
    for p in pts where unique.last != p { unique.append(p) }
    pts = unique
    guard pts.count >= 3 else { return pts }

    var lower: [CGPoint] = []
    for p in pts {
        while lower.count >= 2 && crossZ(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
            lower.removeLast()
        }
        lower.append(p)
    }
    var upper: [CGPoint] = []
    for p in pts.reversed() {
        while upper.count >= 2 && crossZ(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
            upper.removeLast()
        }
        upper.append(p)
    }
    lower.removeLast()
    upper.removeLast()
    return lower + upper
}

/// Minimum-area enclosing rectangle of a convex hull (rotating calipers: the optimal
/// rectangle has one side collinear with a hull edge, so every hull edge direction is
/// tried and all points are projected onto it).
///
/// The returned angle is normalized to (-45, 45] per the `DetectedPhotoRegion`
/// convention (see `MinAreaRect`), swapping width and height for each 90° step removed.
/// Degenerate inputs (empty, single point, all points coincident) return a zero-size
/// rectangle; collinear points return a rectangle with one zero dimension.
func minAreaRect(of hull: [CGPoint]) -> MinAreaRect {
    let pts = hull
    guard !pts.isEmpty else { return MinAreaRect(center: .zero, size: .zero, angleDegrees: 0) }

    var best: MinAreaRect?
    var bestArea = Double.greatestFiniteMagnitude
    let n = pts.count
    for i in 0..<n {
        let p0 = pts[i], p1 = pts[(i + 1) % n]
        let ex = Double(p1.x - p0.x), ey = Double(p1.y - p0.y)
        let len = (ex * ex + ey * ey).squareRoot()
        guard len > 1e-9 else { continue }
        // Unit edge direction (the candidate local x axis) and its normal (local y axis).
        let dx = ex / len, dy = ey / len
        let nx = -dy, ny = dx

        var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
        for p in pts {
            let u = Double(p.x) * dx + Double(p.y) * dy
            let v = Double(p.x) * nx + Double(p.y) * ny
            minU = min(minU, u); maxU = max(maxU, u)
            minV = min(minV, v); maxV = max(maxV, v)
        }
        let w = maxU - minU, h = maxV - minV
        let area = w * h
        if area < bestArea {
            bestArea = area
            let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
            best = MinAreaRect(center: CGPoint(x: cu * dx + cv * nx, y: cu * dy + cv * ny),
                               size: CGSize(width: w, height: h),
                               angleDegrees: atan2(dy, dx) * 180 / .pi)
        }
    }

    guard var rect = best else {
        // Every "edge" had zero length: all points coincide.
        return MinAreaRect(center: pts[0], size: .zero, angleDegrees: 0)
    }
    normalizeAngle(&rect)
    return rect
}

// MARK: - Private helpers

/// z-component of (a - o) × (b - o). Positive = mathematical counterclockwise turn.
private func crossZ(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
}

/// Bring the angle into (-45, 45]. A rectangle is unchanged by a 180° rotation, and a
/// ±90° rotation maps to the same rectangle with width and height exchanged.
private func normalizeAngle(_ r: inout MinAreaRect) {
    var a = r.angleDegrees.truncatingRemainder(dividingBy: 180)
    if a > 90 { a -= 180 } else if a <= -90 { a += 180 }
    if a > 45 {
        a -= 90
        r.size = CGSize(width: r.size.height, height: r.size.width)
    } else if a <= -45 {
        a += 90
        r.size = CGSize(width: r.size.height, height: r.size.width)
    }
    r.angleDegrees = a
}
