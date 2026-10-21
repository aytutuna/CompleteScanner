"""Draws the iPhone and iPad app icon: a sheet rising from a flatbed scanner, crossed by the scan
beam, on a deep blue square. iOS rounds the corners itself, so the square is drawn full and opaque.

Every shape is a signed distance (in pixels) to a rounded rectangle or a circle, and its edge is
smoothed over one pixel, so the picture is the same at any size without a drawing library. Only the
standard library is used; the output is the same bytes on every run.

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


def circle(px, py, cx, cy, r):
    return math.hypot(px - cx, py - cy) - r


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

    def vertical_gradient(self, top, bottom):
        top_c = hex_color(top)
        bottom_c = hex_color(bottom)
        size = self.size
        for y in range(size):
            t = y / (size - 1)
            color = [top_c[i] + (bottom_c[i] - top_c[i]) * t for i in range(3)]
            start = y * size
            for x in range(size):
                self.r[start + x] = color[0]
                self.g[start + x] = color[1]
                self.b[start + x] = color[2]

    def shape(self, distance, bounds, color, opacity=1.0, glow=0.0):
        """Paints where `distance` (design units) is negative, the edge smoothed over one pixel;
        `glow` > 0 adds a soft halo of that width outside the edge."""
        cr, cg, cb = hex_color(color)
        s = self.scale
        margin = glow * 2.5 + 2.0
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
                alpha = min(max(0.5 - d, 0.0), 1.0)
                if glow > 0.0 and d > 0.0:
                    halo = math.exp(-((d / (glow * s)) ** 2)) * 0.55
                    alpha = max(alpha, halo)
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

        def chunk(kind, data):
            body = kind + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def rect_shape(canvas, left, top, right, bottom, radius, color, opacity=1.0, glow=0.0):
    cx = (left + right) / 2.0
    cy = (top + bottom) / 2.0
    hw = (right - left) / 2.0
    hh = (bottom - top) / 2.0
    canvas.shape(lambda px, py: rounded_rect(px, py, cx, cy, hw, hh, radius),
                 (left, top, right, bottom), color, opacity, glow)


def draw(size):
    canvas = Canvas(size)
    # The square: deep blue, lighter at the top.
    canvas.vertical_gradient("#13649A", "#062A4D")

    # The sheet, rising from the scanner: white with a faint shadow, lines of text in blue-grey.
    rect_shape(canvas, 300, 196, 724, 660, 30, "#021A30", opacity=0.35, glow=18.0)
    rect_shape(canvas, 300, 180, 724, 660, 30, "#FFFFFF")
    lines = [(356, 262, 668), (356, 322, 640), (356, 382, 668), (356, 442, 600), (356, 502, 652)]
    for left, top, right in lines:
        rect_shape(canvas, left, top, right, top + 24, 12, "#A9C1D6")

    # The scan beam across the sheet, glowing.
    rect_shape(canvas, 252, 556, 772, 576, 10, "#5FE3FF", glow=26.0)
    rect_shape(canvas, 252, 559, 772, 573, 7, "#E9FBFF")

    # The scanner's body over the bottom of the sheet, with its slot and a light.
    rect_shape(canvas, 176, 636, 848, 836, 56, "#D9E8F3")
    rect_shape(canvas, 176, 636, 848, 676, 20, "#B9D0E2")
    rect_shape(canvas, 236, 728, 640, 752, 12, "#9DB8CE")
    canvas.shape(lambda px, py: circle(px, py, 760, 740, 22), (738, 718, 782, 762), "#2FC6E8")
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
