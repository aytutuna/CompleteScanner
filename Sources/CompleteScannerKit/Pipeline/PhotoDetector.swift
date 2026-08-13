import CoreGraphics
import Foundation

public struct PhotoDetectorOptions {
    public var minPhotoSideInches: Double = 1.0
    public var maxPhotoCount: Int = 20
    /// Pixels (at full scan resolution) shaved off each edge of the detected rect before extraction.
    public var edgeInsetPixels: Int = 0
    public init() {}
}

public enum PhotoDetector {

    /// Find distinct photos lying on a flatbed scan. Regions are in full-resolution pixel
    /// coordinates of `image`, sorted top-to-bottom then left-to-right.
    public static func detectRegions(in image: CGImage, dpi: Int, options: PhotoDetectorOptions = PhotoDetectorOptions()) -> [DetectedPhotoRegion] {
        let fullW = image.width, fullH = image.height
        guard fullW > 0, fullH > 0, options.maxPhotoCount > 0 else { return [] }

        // 1. Downsample to at most 1000 px on the long side; only ever iterate these pixels.
        let scale = min(1.0, 1000.0 / Double(max(fullW, fullH)))
        let dw = max(1, Int((Double(fullW) * scale).rounded()))
        let dh = max(1, Int((Double(fullH) * scale).rounded()))
        // Exact per-axis scales after rounding, used when mapping back to full resolution.
        let sx = Double(dw) / Double(fullW)
        let sy = Double(dh) / Double(fullH)
        guard let rgba = rasterizeRGBA(image, width: dw, height: dh) else { return [] }

        // 2. Per-pixel luminance and saturation in 0...1.
        let count = dw * dh
        var lum = [Float](repeating: 0, count: count)
        var sat = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let r = Float(rgba[i * 4]) / 255
            let g = Float(rgba[i * 4 + 1]) / 255
            let b = Float(rgba[i * 4 + 2]) / 255
            lum[i] = 0.299 * r + 0.587 * g + 0.114 * b
            sat[i] = max(r, g, b) - min(r, g, b)
        }

        // 3. Background estimate: median luminance of the outer 2% border ring.
        let ring = max(1, Int((Double(min(dw, dh)) * 0.02).rounded()))
        var border: [Float] = []
        border.reserveCapacity(4 * ring * (dw + dh))
        for y in 0..<dh {
            let edgeRow = y < ring || y >= dh - ring
            for x in 0..<dw where edgeRow || x < ring || x >= dw - ring {
                border.append(lum[y * dw + x])
            }
        }
        border.sort()
        let background = border.isEmpty ? Float(1) : border[border.count / 2]

        // 4. Foreground mask.
        var mask = [UInt8](repeating: 0, count: count)
        for i in 0..<count where abs(lum[i] - background) > 0.09 || sat[i] > 0.13 {
            mask[i] = 1
        }

        // 5. Close (seal photo interiors that match the background), then a light open (drop speckle).
        mask = erode(dilate(mask, dw, dh, radius: 2), dw, dh, radius: 2)
        mask = dilate(erode(mask, dw, dh, radius: 1), dw, dh, radius: 1)

        // 6. Connected components.
        let components = connectedComponents(mask: mask, width: dw, height: dh)

        // 7 + 8. Filter components, then fit min-area rectangles.
        let minSidePx = options.minPhotoSideInches * Double(max(dpi, 1)) * scale
        let minArea = minSidePx * minSidePx * 0.5
        var fitted: [MinAreaRect] = []
        for component in components {
            guard Double(component.area) >= minArea else { continue }
            // Per-row extremes as pixel-corner points: enough for an exact convex hull,
            // and a W-pixel-wide run measures a width of exactly W.
            var pts: [CGPoint] = []
            pts.reserveCapacity(component.rows.count * 4)
            for (y, span) in component.rows {
                pts.append(CGPoint(x: CGFloat(span.minX), y: CGFloat(y)))
                pts.append(CGPoint(x: CGFloat(span.minX), y: CGFloat(y + 1)))
                pts.append(CGPoint(x: CGFloat(span.maxX + 1), y: CGFloat(y)))
                pts.append(CGPoint(x: CGFloat(span.maxX + 1), y: CGFloat(y + 1)))
            }
            let rect = minAreaRect(of: convexHull(pts))
            let rectArea = Double(rect.size.width * rect.size.height)
            guard rectArea > 0, Double(component.area) / rectArea >= 0.45 else { continue }
            fitted.append(rect)
        }

        // 9. Map back to full resolution and cap at the largest maxPhotoCount.
        let sizeScale = (sx + sy) / 2
        var regions: [DetectedPhotoRegion] = fitted.map { r in
            DetectedPhotoRegion(center: CGPoint(x: Double(r.center.x) / sx, y: Double(r.center.y) / sy),
                                size: CGSize(width: Double(r.size.width) / sizeScale,
                                             height: Double(r.size.height) / sizeScale),
                                angleDegrees: r.angleDegrees)
        }
        regions.sort { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
        if regions.count > options.maxPhotoCount {
            regions.removeSubrange(options.maxPhotoCount...)
        }

        // 10. Merge near-duplicates.
        regions = mergeOverlapping(regions)

        // 11. Snap each region to the true photo edges at FULL resolution. The low-res
        // mask bleeds a few pixels at the borders — visible as background slivers around
        // extracted photos — and its loose threshold can shave off a photo's white print
        // border; both are corrected here.
        regions = regions.map { refineRegion($0, in: image, backgroundLuminance: Double(background)) ?? $0 }

        // 12. Apply the edge inset and sort row-major.
        if options.edgeInsetPixels > 0 {
            let shrink = CGFloat(options.edgeInsetPixels) * 2
            for i in regions.indices {
                regions[i].size.width = max(1, regions[i].size.width - shrink)
                regions[i].size.height = max(1, regions[i].size.height - shrink)
            }
        }
        return sortRowMajor(regions)
    }

    /// Crop (and if `deskew`, rotate to upright) one region out of the source scan.
    public static func extractPhoto(from image: CGImage, region: DetectedPhotoRegion, deskew: Bool) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }

        guard deskew else {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let crop = region.boundingBox.integral.intersection(bounds)
            guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
            return image.cropping(to: crop)
        }

        let outW = Int(region.size.width.rounded())
        let outH = Int(region.size.height.rounded())
        guard outW > 0, outH > 0 else { return nil }
        guard let ctx = makeRGBAContext(data: nil, width: outW, height: outH, bytesPerRow: 0) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))

        // The region lives in top-left-origin/y-down image coordinates, where a positive
        // angle is clockwise on screen. CG contexts are bottom-left-origin/y-up, so:
        //   - the region center (cx, cy) becomes (cx, H - cy);
        //   - flipping y negates angles, so the region appears rotated by -angle in CG
        //     coordinates, and undoing it means rotating the drawing by +angle
        //     (ctx.rotate is counterclockwise in y-up terms, i.e. counterclockwise on
        //     screen — exactly how a region with angleDegrees = +10, clockwise on screen,
        //     must be turned 10° counterclockwise to straighten).
        // Composition (applied to source points): translate the region center to the
        // context center, rotating about it, so the region lands axis-aligned and
        // centered in the outW x outH context. The source is drawn at full size but
        // clipped by the context bounds, so no full rotated copy is ever allocated.
        let h = CGFloat(image.height)
        let cgCenter = CGPoint(x: region.center.x, y: h - region.center.y)
        let angle = CGFloat(region.angleDegrees * .pi / 180)
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: angle)
        ctx.translateBy(x: -cgCenter.x, y: -cgCenter.y)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h))
        return ctx.makeImage()
    }
}

// MARK: - Full-resolution edge refinement

extension PhotoDetector {
    /// Re-fit one detected region against the full-resolution pixels.
    ///
    /// The region (plus a margin) is rendered upright, then each side is scanned from the
    /// outside for the first row/column that is not background. The background test is
    /// deliberately much tighter than the detection threshold: a photo's white print
    /// border usually differs only slightly from the bed glass, and the faint edge shadow
    /// a lying photo casts differs clearly — so borders are kept while bed background is
    /// trimmed exactly. Returns nil (caller keeps the unrefined region) when the result
    /// would be degenerate.
    fileprivate static func refineRegion(_ region: DetectedPhotoRegion, in image: CGImage,
                                         backgroundLuminance bg: Double) -> DetectedPhotoRegion? {
        let margin = max(24.0, 0.05 * Double(min(region.size.width, region.size.height)))
        let cw = Int((Double(region.size.width) + 2 * margin).rounded())
        let ch = Int((Double(region.size.height) + 2 * margin).rounded())
        guard cw >= 8, ch >= 8, cw * ch <= 60_000_000 else { return nil }
        guard let rgba = rasterizeRotated(image, center: region.center,
                                         angleDegrees: region.angleDegrees,
                                         width: cw, height: ch, fillGray: bg) else { return nil }

        let lumTolerance = 0.035
        let satTolerance = 0.06
        func isBackground(_ index: Int) -> Bool {
            let r = Double(rgba[index * 4]) / 255
            let g = Double(rgba[index * 4 + 1]) / 255
            let b = Double(rgba[index * 4 + 2]) / 255
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            let sat = max(r, max(g, b)) - min(r, min(g, b))
            return abs(lum - bg) < lumTolerance && sat < satTolerance
        }
        // A line is still "background" while ≥92% of its pixels are (tolerates dust).
        let backgroundShare = 0.92
        func rowIsBackground(_ y: Int) -> Bool {
            var count = 0
            for x in 0..<cw where isBackground(y * cw + x) { count += 1 }
            return Double(count) >= backgroundShare * Double(cw)
        }
        func columnIsBackground(_ x: Int) -> Bool {
            var count = 0
            for y in 0..<ch where isBackground(y * cw + x) { count += 1 }
            return Double(count) >= backgroundShare * Double(ch)
        }

        // Each side starts at the ORIGINAL detected edge (index `m` from the buffer
        // border): first trim inward over background lines (removes bed slivers), then
        // grow outward across contiguous non-background lines (recovers white print
        // borders and edge shadows). Growth stops at the first background line, so a
        // neighboring photo inside the margin ring — always separated by a background
        // gap — is never absorbed.
        let m = Int(margin.rounded())
        var top = min(m, ch - 1)
        while top < ch - 1, rowIsBackground(top) { top += 1 }
        while top > 0, !rowIsBackground(top - 1) { top -= 1 }
        var bottom = max(ch - 1 - m, top)
        while bottom > top, rowIsBackground(bottom) { bottom -= 1 }
        while bottom < ch - 1, !rowIsBackground(bottom + 1) { bottom += 1 }
        var left = min(m, cw - 1)
        while left < cw - 1, columnIsBackground(left) { left += 1 }
        while left > 0, !columnIsBackground(left - 1) { left -= 1 }
        var right = max(cw - 1 - m, left)
        while right > left, columnIsBackground(right) { right -= 1 }
        while right < cw - 1, !columnIsBackground(right + 1) { right += 1 }

        let newW = Double(right - left + 1)
        let newH = Double(bottom - top + 1)
        // Safety: keep the original detection if refinement collapsed (glare, unusual
        // bed color) — better a slightly loose crop than a destroyed one.
        guard newW >= 8, newH >= 8,
              newW * newH >= 0.3 * Double(region.size.width * region.size.height) else { return nil }

        // Center shift in the upright frame, rotated back into image coordinates.
        let dx = (Double(left) + Double(right) + 1) / 2 - Double(cw) / 2
        let dy = (Double(top) + Double(bottom) + 1) / 2 - Double(ch) / 2
        let a = region.angleDegrees * .pi / 180
        let (c, s) = (cos(a), sin(a))
        let center = CGPoint(x: Double(region.center.x) + dx * c - dy * s,
                             y: Double(region.center.y) + dx * s + dy * c)
        return DetectedPhotoRegion(center: center,
                                   size: CGSize(width: newW, height: newH),
                                   angleDegrees: region.angleDegrees)
    }
}

/// Render the rotated region upright into an RGBA8 buffer (rows top-to-bottom), the same
/// transform `extractPhoto` uses; areas outside the source are filled with the bed's
/// background gray so they read as background during refinement.
private func rasterizeRotated(_ image: CGImage, center: CGPoint, angleDegrees: Double,
                              width: Int, height: Int, fillGray: Double) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = makeRGBAContext(data: raw.baseAddress, width: width, height: height,
                                        bytesPerRow: width * 4) else { return false }
        ctx.interpolationQuality = .medium
        ctx.setFillColor(gray: fillGray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let h = CGFloat(image.height)
        let cgCenter = CGPoint(x: center.x, y: h - center.y)
        let angle = CGFloat(angleDegrees * .pi / 180)
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: angle)
        ctx.translateBy(x: -cgCenter.x, y: -cgCenter.y)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h))
        return true
    }
    return ok ? buffer : nil
}

// MARK: - Rasterization

private func makeRGBAContext(data: UnsafeMutableRawPointer?, width: Int, height: Int, bytesPerRow: Int) -> CGContext? {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                     bytesPerRow: bytesPerRow, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// Draw `image` scaled into a width x height RGBA8 buffer (rows top-to-bottom).
private func rasterizeRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = makeRGBAContext(data: raw.baseAddress, width: width, height: height,
                                        bytesPerRow: width * 4) else { return false }
        ctx.interpolationQuality = .medium
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return ok ? buffer : nil
}

// MARK: - Morphology (square kernel, separable passes)

private func dilate(_ mask: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
    var tmp = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = y * w
        for x in 0..<w {
            var v: UInt8 = 0
            for xx in max(0, x - r)...min(w - 1, x + r) where mask[row + xx] == 1 { v = 1; break }
            tmp[row + x] = v
        }
    }
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            var v: UInt8 = 0
            for yy in max(0, y - r)...min(h - 1, y + r) where tmp[yy * w + x] == 1 { v = 1; break }
            out[y * w + x] = v
        }
    }
    return out
}

private func erode(_ mask: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
    // Pixels outside the image count as background, so the mask shrinks at the borders.
    var tmp = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = y * w
        for x in 0..<w {
            var v: UInt8 = (x - r >= 0 && x + r < w) ? 1 : 0
            if v == 1 {
                for xx in (x - r)...(x + r) where mask[row + xx] == 0 { v = 0; break }
            }
            tmp[row + x] = v
        }
    }
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            var v: UInt8 = (y - r >= 0 && y + r < h) ? 1 : 0
            if v == 1 {
                for yy in (y - r)...(y + r) where tmp[yy * w + x] == 0 { v = 0; break }
            }
            out[y * w + x] = v
        }
    }
    return out
}

// MARK: - Connected components

private struct ComponentInfo {
    var area = 0
    /// Per-row horizontal extent: y -> (minX, maxX).
    var rows: [Int: (minX: Int, maxX: Int)] = [:]
}

private func connectedComponents(mask: [UInt8], width: Int, height: Int) -> [ComponentInfo] {
    var visited = [Bool](repeating: false, count: mask.count)
    var components: [ComponentInfo] = []
    var stack: [Int] = []
    for start in 0..<mask.count {
        guard mask[start] == 1, !visited[start] else { continue }
        var comp = ComponentInfo()
        visited[start] = true
        stack.removeAll(keepingCapacity: true)
        stack.append(start)
        while let idx = stack.popLast() {
            let x = idx % width, y = idx / width
            comp.area += 1
            if let span = comp.rows[y] {
                comp.rows[y] = (min(span.minX, x), max(span.maxX, x))
            } else {
                comp.rows[y] = (x, x)
            }
            if x > 0, mask[idx - 1] == 1, !visited[idx - 1] { visited[idx - 1] = true; stack.append(idx - 1) }
            if x < width - 1, mask[idx + 1] == 1, !visited[idx + 1] { visited[idx + 1] = true; stack.append(idx + 1) }
            if y > 0, mask[idx - width] == 1, !visited[idx - width] { visited[idx - width] = true; stack.append(idx - width) }
            if y < height - 1, mask[idx + width] == 1, !visited[idx + width] { visited[idx + width] = true; stack.append(idx + width) }
        }
        components.append(comp)
    }
    return components
}

// MARK: - Merging and ordering

/// Merge any two regions whose rotated-rect intersection area exceeds 0.6 of the
/// smaller rect's area, replacing them with the min-area rect of their joint hull.
private func mergeOverlapping(_ input: [DetectedPhotoRegion]) -> [DetectedPhotoRegion] {
    var regions = input
    var merged = true
    while merged && regions.count > 1 {
        merged = false
        outer: for i in 0..<regions.count {
            for j in (i + 1)..<regions.count {
                let a = regions[i], b = regions[j]
                let areaA = Double(a.size.width * a.size.height)
                let areaB = Double(b.size.width * b.size.height)
                let smaller = min(areaA, areaB)
                guard smaller > 0 else { continue }
                let inter = polygonArea(clipPolygon(a.corners, by: b.corners))
                guard inter / smaller > 0.6 else { continue }
                let rect = minAreaRect(of: convexHull(a.corners + b.corners))
                regions[i] = DetectedPhotoRegion(center: rect.center, size: rect.size,
                                                 angleDegrees: rect.angleDegrees)
                regions.remove(at: j)
                merged = true
                break outer
            }
        }
    }
    return regions
}

/// Sort top-to-bottom then left-to-right, grouping into rows with a tolerance of
/// half the mean region height.
private func sortRowMajor(_ regions: [DetectedPhotoRegion]) -> [DetectedPhotoRegion] {
    guard regions.count > 1 else { return regions }
    let meanHeight = regions.reduce(0.0) { $0 + Double($1.size.height) } / Double(regions.count)
    let tolerance = max(1.0, meanHeight / 2)
    let byY = regions.sorted { $0.center.y < $1.center.y }
    var rows: [[DetectedPhotoRegion]] = []
    var currentRow: [DetectedPhotoRegion] = []
    var rowY = 0.0
    for region in byY {
        if currentRow.isEmpty || Double(region.center.y) - rowY <= tolerance {
            if currentRow.isEmpty { rowY = Double(region.center.y) }
            currentRow.append(region)
        } else {
            rows.append(currentRow)
            currentRow = [region]
            rowY = Double(region.center.y)
        }
    }
    if !currentRow.isEmpty { rows.append(currentRow) }
    return rows.flatMap { $0.sorted { $0.center.x < $1.center.x } }
}

// MARK: - Convex polygon intersection (Sutherland–Hodgman)

/// Unsigned area of a simple polygon (shoelace formula).
private func polygonArea(_ pts: [CGPoint]) -> Double {
    guard pts.count >= 3 else { return 0 }
    var sum = 0.0
    for i in 0..<pts.count {
        let a = pts[i], b = pts[(i + 1) % pts.count]
        sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
    }
    return abs(sum) / 2
}

/// Clip a convex `subject` polygon by a convex `clip` polygon whose vertices are in
/// mathematically counterclockwise order (which `DetectedPhotoRegion.corners` is).
private func clipPolygon(_ subject: [CGPoint], by clip: [CGPoint]) -> [CGPoint] {
    guard clip.count >= 3 else { return [] }
    var output = subject
    for i in 0..<clip.count {
        guard !output.isEmpty else { break }
        let a = clip[i], b = clip[(i + 1) % clip.count]

        func inside(_ p: CGPoint) -> Bool {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0
        }
        func intersect(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
            let a1 = Double(b.y - a.y), b1 = Double(a.x - b.x)
            let c1 = a1 * Double(a.x) + b1 * Double(a.y)
            let a2 = Double(q.y - p.y), b2 = Double(p.x - q.x)
            let c2 = a2 * Double(p.x) + b2 * Double(p.y)
            let det = a1 * b2 - a2 * b1
            guard abs(det) > 1e-12 else { return p }
            return CGPoint(x: (c1 * b2 - c2 * b1) / det, y: (a1 * c2 - a2 * c1) / det)
        }

        let input = output
        output = []
        for k in 0..<input.count {
            let current = input[k], previous = input[(k + input.count - 1) % input.count]
            if inside(current) {
                if !inside(previous) { output.append(intersect(previous, current)) }
                output.append(current)
            } else if inside(previous) {
                output.append(intersect(previous, current))
            }
        }
    }
    return output
}
