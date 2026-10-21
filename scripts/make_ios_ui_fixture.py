"""Draws the photo the iPhone app's import UI test brings in: a sheet of paper photographed at a
slight angle on a dark wooden table. The sheet carries grey bars where a letter's heading, address
block and paragraphs would be; there is no real text, logo or flag. The sheet is placed with a
perspective transform (a unit square mapped onto its four corners), and every pixel is sampled 3 x 3
so its edges are smooth. Only the standard library is used; the output is the same bytes on every run.

Usage: python scripts/make_ios_ui_fixture.py <out.png>
"""

import math
import struct
import sys
import zlib

WIDTH, HEIGHT = 360, 480
# The sheet's corners in the photo (top-left, top-right, bottom-right, bottom-left), a page about
# A4-shaped seen a little from below and turned a few degrees.
CORNERS = [(70.0, 84.0), (300.0, 70.0), (318.0, 402.0), (52.0, 414.0)]
TABLE = (58, 41, 30)
PAPER = (240, 238, 232)
INK = (88, 88, 94)
SAMPLES = 3


def square_to_quad(corners):
    """The projective map of the unit square onto the quad (Heckbert): (u, v) -> (x, y)."""
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = corners
    dx1, dx2, dx3 = x1 - x2, x3 - x2, x0 - x1 + x2 - x3
    dy1, dy2, dy3 = y1 - y2, y3 - y2, y0 - y1 + y2 - y3
    det = dx1 * dy2 - dx2 * dy1
    g = (dx3 * dy2 - dx2 * dy3) / det
    h = (dx1 * dy3 - dx3 * dy1) / det
    a, b, c = x1 - x0 + g * x1, x3 - x0 + h * x3, x0
    d, e, f = y1 - y0 + g * y1, y3 - y0 + h * y3, y0
    return [[a, b, c], [d, e, f], [g, h, 1.0]]


def inverse(m):
    (a, b, c), (d, e, f), (g, h, i) = m
    A, B, C = e * i - f * h, -(d * i - f * g), d * h - e * g
    D, E, F = -(b * i - c * h), a * i - c * g, -(a * h - b * g)
    G, H, I = b * f - c * e, -(a * f - c * d), a * e - b * d
    det = a * A + b * B + c * C
    return [[A / det, D / det, G / det], [B / det, E / det, H / det], [C / det, F / det, I / det]]


TO_SHEET = inverse(square_to_quad(CORNERS))

# The sheet's bars in its own coordinates (u across, v down, 0 to 1): a heading, an address block,
# then paragraphs with a short last line each.
BARS = [(0.12, 0.08, 0.55, 0.115)]
for row in range(3):
    top = 0.17 + row * 0.035
    BARS.append((0.12, top, 0.42, top + 0.016))
for paragraph in range(3):
    for line in range(4):
        top = 0.33 + paragraph * 0.19 + line * 0.04
        right = 0.62 if line == 3 else 0.88
        BARS.append((0.12, top, right, top + 0.017))


def table(x, y):
    """Dark wood: slow grain along x, a little light from the top."""
    grain = 0.5 + 0.5 * math.sin(y * 0.11 + 2.0 * math.sin(x * 0.013) + 0.6 * math.sin(y * 0.031))
    light = 1.0 - 0.18 * (y / HEIGHT)
    return tuple(min(255.0, channel * (0.82 + 0.3 * grain) * light) for channel in TABLE)


def sheet(u, v):
    for (u0, v0, u1, v1) in BARS:
        if u0 <= u <= u1 and v0 <= v <= v1:
            return INK
    shade = 1.0 - 0.06 * v - 0.03 * u
    return tuple(channel * shade for channel in PAPER)


def color(x, y):
    m = TO_SHEET
    w = m[2][0] * x + m[2][1] * y + m[2][2]
    u = (m[0][0] * x + m[0][1] * y + m[0][2]) / w
    v = (m[1][0] * x + m[1][1] * y + m[1][2]) / w
    if 0.0 <= u <= 1.0 and 0.0 <= v <= 1.0:
        return sheet(u, v)
    return table(x, y)


def render():
    rows = []
    for j in range(HEIGHT):
        row = bytearray([1])  # PNG filter: Sub
        previous = (0, 0, 0)
        for i in range(WIDTH):
            r = g = b = 0.0
            for sj in range(SAMPLES):
                for si in range(SAMPLES):
                    c = color(i + (si + 0.5) / SAMPLES, j + (sj + 0.5) / SAMPLES)
                    r += c[0]
                    g += c[1]
                    b += c[2]
            n = SAMPLES * SAMPLES
            pixel = (int(r / n + 0.5), int(g / n + 0.5), int(b / n + 0.5))
            row += bytes(((pixel[k] - previous[k]) & 0xFF) for k in range(3))
            previous = pixel
        rows.append(bytes(row))
    return b"".join(rows)


def png(raw):
    def chunk(kind, body):
        data = kind + body
        return struct.pack(">I", len(body)) + data + struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as out:
        out.write(png(render()))


if __name__ == "__main__":
    main()
