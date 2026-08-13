// Generates the CompleteScanner app icon as a 1024x1024 PNG.
// Usage: swift scripts/MakeIcon.swift <output.png>
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
guard CommandLine.arguments.count > 1 else { fatalError("usage: MakeIcon <out.png>") }
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS-style rounded square
let inset: CGFloat = 100
let square = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: square, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.clip()

// Background gradient (deep teal -> blue)
let colors = [CGColor(red: 0.05, green: 0.32, blue: 0.55, alpha: 1),
              CGColor(red: 0.02, green: 0.16, blue: 0.32, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: size / 2, y: size), end: CGPoint(x: size / 2, y: 0), options: [])

// Flatbed glass
let glass = CGRect(x: 232, y: 330, width: 560, height: 420)
ctx.setFillColor(CGColor(red: 0.88, green: 0.94, blue: 0.98, alpha: 1))
ctx.addPath(CGPath(roundedRect: glass, cornerWidth: 28, cornerHeight: 28, transform: nil))
ctx.fillPath()

// Two "photos" on the glass, slightly rotated
func photo(_ center: CGPoint, _ w: CGFloat, _ h: CGFloat, _ deg: CGFloat, _ color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: deg * .pi / 180)
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(r.insetBy(dx: -12, dy: -12))
    ctx.setFillColor(color)
    ctx.fill(r)
    ctx.restoreGState()
}
photo(CGPoint(x: 388, y: 560), 210, 150, 12, CGColor(red: 0.94, green: 0.55, blue: 0.20, alpha: 1))
photo(CGPoint(x: 640, y: 520), 190, 190, -9, CGColor(red: 0.22, green: 0.62, blue: 0.45, alpha: 1))

// Scan beam
ctx.setFillColor(CGColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.85))
ctx.fill(CGRect(x: 232, y: 528, width: 560, height: 14))
ctx.setFillColor(CGColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.25))
ctx.fill(CGRect(x: 232, y: 500, width: 560, height: 70))

// Lid bar
ctx.setFillColor(CGColor(red: 0.10, green: 0.45, blue: 0.72, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: 200, y: 770, width: 624, height: 56), cornerWidth: 24, cornerHeight: 24, transform: nil))
ctx.fillPath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
