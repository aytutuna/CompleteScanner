// Generates the Lazy Scan app icon as a 1024x1024 PNG.
// A white page on flat blue with a cyan scan beam across it: the lines the beam has passed are
// sharp, the ones below it are still soft.
// Usage: swift scripts/MakeIcon.swift <output.png>
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
guard CommandLine.arguments.count > 1 else { fatalError("usage: MakeIcon <out.png>") }
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

func canvas() -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let ctx = canvas()
let full = CGRect(x: 0, y: 0, width: size, height: size)

// macOS-style rounded square
let inset: CGFloat = 100
let square = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: square, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.clip()

// The design is laid out on a 1024 square with y going down; scale it into the inset square.
let s = square.width / size
func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
    CGRect(x: inset + x0 * s, y: inset + (size - y1) * s, width: (x1 - x0) * s, height: (y1 - y0) * s)
}

func hex(_ v: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: 1)
}

func fill(_ c: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: CGColor) {
    c.setFillColor(color)
    c.addPath(CGPath(roundedRect: r, cornerWidth: radius * s, cornerHeight: radius * s, transform: nil))
    c.fillPath()
}

let ci = CIContext()
func blurred(_ sigma: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let layer = canvas()
    draw(layer)
    let input = CIImage(cgImage: layer.makeImage()!)
    let blur = CIFilter(name: "CIGaussianBlur")!
    blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(sigma * s, forKey: kCIInputRadiusKey)
    let out = blur.outputImage!.cropped(to: input.extent)
    return ci.createCGImage(out, from: input.extent)!
}

let blue = hex(0x1769AA)
let ink = hex(0xA9BFD6)
let cyan = hex(0x22D3EE)

ctx.setFillColor(blue)
ctx.fill(square)

fill(ctx, box(292, 201, 732, 823), 36, hex(0xFFFFFF))

for (y, w) in [(290, 300), (360, 255), (430, 300), (500, 240)] as [(CGFloat, CGFloat)] {
    fill(ctx, box(356, y, 356 + w, y + 30), 15, ink)
}

let soft = blurred(9) { c in
    for (y, w) in [(640, 300), (710, 220)] as [(CGFloat, CGFloat)] {
        fill(c, box(356, y, 356 + w, y + 30), 15, ink)
    }
}
ctx.setAlpha(0.7)
ctx.draw(soft, in: full)

let glow = blurred(16) { c in
    fill(c, box(192, 562, 832, 598), 18, cyan)
}
ctx.setAlpha(0.55)
ctx.draw(glow, in: full)

ctx.setAlpha(1)
fill(ctx, box(212, 569, 812, 591), 11, cyan)

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
