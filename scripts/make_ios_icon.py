"""Draws the iPhone and iPad app icon: a white page on a blue square, crossed by the scan beam. The
lines of text above the beam are sharp, the ones below it still out of focus. iOS rounds the corners
itself, so the square is drawn full and opaque; scripts/make_ico.py draws the same picture with
rounded, transparent corners for Windows.

Every shape is a signed distance (in pixels) to a rounded rectangle, and its edge is smoothed over
one pixel, or over a gaussian falloff for the blurred shapes, so the picture is the same at any size
without a drawing library. Only the standard library is used; the output is the same bytes on every
run.

Usage: python scripts/make_ios_icon.py <out.png> [size]   (size defaults to 1024)
"""

import math
import struct
import sys
import zlib
from array import array

# The design is laid out on a 1024-pixel square; other sizes scale it.
DESIGN = 1024.0


def rounded_rect(px, py, cx, cy, hw, hh, r):
    """Signed distance from (px, py) to a rounded rectangle centred at (cx, cy)."""
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def hex_color(text):
    text = text.lstrip("#")
    return tuple(int(text[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


class Canvas:
    def __init__(self, size):
        self.size = size
        self.scale = size / DESIGN
        n = size * size
        self.r = array("d", [0.0]) * n
        self.g = array("d", [0.0]) * n
        self.b = array("d", [0.0]) * n
        self.a = None

    def fill(self, color):
        n = self.size * self.size
        cr, cg, cb = hex_color(color)
        self.r = array("d", [cr]) * n
        self.g = array("d", [cg]) * n
        self.b = array("d", [cb]) * n

    def round_corners(self, radius):
        """Makes the canvas transparent outside a square with corners of `radius` (design units)."""
        size = self.size
        s = self.scale
        half = DESIGN / 2.0
        self.a = array("d", [1.0]) * (size * size)
        for y in range(size):
            py = (y + 0.5) / s
            for x in range(size):
                d = rounded_rect((x + 0.5) / s, py, half, half, half, half, radius) * s
                self.a[y * size + x] = min(max(0.5 - d, 0.0), 1.0)

    def shape(self, distance, bounds, color, opacity=1.0, soft=0.0):
        """Paints where `distance` (design units) is negative, the edge smoothed over one pixel;
        `soft` > 0 blurs the edge instead, as a gaussian of that sigma would."""
        cr, cg, cb = hex_color(color)
        s = self.scale
        margin = soft * 3.0 + 2.0
        # A blur smaller than a pixel still gets about a pixel of antialiasing.
        spread = math.hypot(soft * s, 0.4) * math.sqrt(2.0)
        x0 = max(0, int((bounds[0] - margin) * s))
        y0 = max(0, int((bounds[1] - margin) * s))
        x1 = min(self.size, int(math.ceil((bounds[2] + margin) * s)) + 1)
        y1 = min(self.size, int(math.ceil((bounds[3] + margin) * s)) + 1)
        for y in range(y0, y1):
            py = (y + 0.5) / s
            row = y * self.size
            for x in range(x0, x1):
                px = (x + 0.5) / s
                d = distance(px, py) * s
                if soft > 0.0:
                    alpha = 0.5 * math.erfc(d / spread)
                else:
                    alpha = min(max(0.5 - d, 0.0), 1.0)
                alpha *= opacity
                if alpha <= 0.0:
                    continue
                i = row + x
                self.r[i] += (cr - self.r[i]) * alpha
                self.g[i] += (cg - self.g[i]) * alpha
                self.b[i] += (cb - self.b[i]) * alpha

    def png(self):
        size = self.size
        raw = bytearray()
        for y in range(size):
            raw.append(0)
            start = y * size
            for x in range(size):
                i = start + x
                raw.append(int(round(min(max(self.r[i], 0.0), 1.0) * 255)))
                raw.append(int(round(min(max(self.g[i], 0.0), 1.0) * 255)))
                raw.append(int(round(min(max(self.b[i], 0.0), 1.0) * 255)))
                if self.a is not None:
                    raw.append(int(round(self.a[i] * 255)))

        def chunk(kind, data):
            body = kind + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        kind = 2 if self.a is None else 6
        header = struct.pack(">IIBBBBB", size, size, 8, kind, 0, 0, 0)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def rect_shape(canvas, left, top, right, bottom, radius, color, opacity=1.0, soft=0.0):
    cx = (left + right) / 2.0
    cy = (top + bottom) / 2.0
    hw = (right - left) / 2.0
    hh = (bottom - top) / 2.0
    canvas.shape(lambda px, py: rounded_rect(px, py, cx, cy, hw, hh, radius),
                 (left, top, right, bottom), color, opacity, soft)


def draw(size, corner=0.0):
    canvas = Canvas(size)
    canvas.fill("#1769AA")
    rect_shape(canvas, 292, 201, 732, 823, 36, "#FFFFFF")

    # The beam has swept down the page: text above it is scanned and sharp, below it still soft.
    for top, width in ((290, 300), (360, 255), (430, 300), (500, 240)):
        rect_shape(canvas, 356, top, 356 + width, top + 30, 15, "#A9BFD6")
    for top, width in ((640, 300), (710, 220)):
        rect_shape(canvas, 356, top, 356 + width, top + 30, 15, "#A9BFD6", opacity=0.7, soft=9.0)

    rect_shape(canvas, 192, 562, 832, 598, 18, "#22D3EE", opacity=0.55, soft=16.0)
    rect_shape(canvas, 212, 569, 812, 591, 11, "#22D3EE")
    if corner:
        canvas.round_corners(corner)
    return canvas.png()


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: python scripts/make_ios_icon.py <out.png> [size]")
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    with open(sys.argv[1], "wb") as out:
        out.write(draw(size))
    print("wrote %s (%d x %d)" % (sys.argv[1], size, size))


if __name__ == "__main__":
    main()
