"""Draws the photos the iPhone app's UI tests bring in.

document (the default; Fixtures/document-photo.png, the import test's): a sheet of paper photographed
at a slight angle on a dark wooden table. The sheet carries grey bars where a letter's heading, address
block and paragraphs would be; there is no real text, logo or flag. The sheet is placed with a
perspective transform (a unit square mapped onto its four corners), and every pixel is sampled 3 x 3
so its edges are smooth.

photos (Fixtures/photos-on-table.png, the Photos task's test): two prints with white borders lying on a
plain dark table, 1200 x 900: a 450 x 300 print at (120, 150) and a 420 x 280 print at (650, 420), each a
soft color gradient inside an 18 px border (no picture of anything). Its pixels are those of
ObjectShots.printsOnTable in the unit tests (the FNV-1a of its RGBA bytes is printed when it is drawn and
pinned there), so the unit tests prove what the UI test relies on: the two prints are found, by Vision's
rectangles or, where Vision finds none, by the photo search of the whole shot.

Only the standard library is used; the output is the same bytes on every run.

Usage: python scripts/make_ios_ui_fixture.py <out.png> [document|photos]
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


PRINTS_WIDTH, PRINTS_HEIGHT = 1200, 900
PRINT_BORDER = 18
PRINT_PAPER = (245, 244, 238)
PRINTS_TABLE = (40, 36, 34)


def print_pixel(x, y):
    """The photos fixture's pixel: the table, a print's white border, or the gradient inside it."""
    b = PRINT_BORDER
    if 120 <= x < 570 and 150 <= y < 450:
        if 120 + b <= x < 570 - b and 150 + b <= y < 450 - b:
            return (70 + (x - 120) * 120 // 450, 110 + (y - 150) * 90 // 300, 180)
        return PRINT_PAPER
    if 650 <= x < 1070 and 420 <= y < 700:
        if 650 + b <= x < 1070 - b and 420 + b <= y < 700 - b:
            return (190, 140 - (y - 420) * 70 // 280, 60 + (x - 650) * 100 // 420)
        return PRINT_PAPER
    return PRINTS_TABLE


def render_prints():
    """The photos fixture's rows for the PNG (filter Sub), and the FNV-1a of its RGBA bytes."""
    rows = []
    fnv = 0x811C9DC5
    for j in range(PRINTS_HEIGHT):
        row = bytearray([1])  # PNG filter: Sub
        previous = (0, 0, 0)
        for i in range(PRINTS_WIDTH):
            pixel = print_pixel(i, j)
            for value in (pixel[0], pixel[1], pixel[2], 255):
                fnv = ((fnv ^ value) * 0x01000193) & 0xFFFFFFFF
            row += bytes(((pixel[k] - previous[k]) & 0xFF) for k in range(3))
            previous = pixel
        rows.append(bytes(row))
    return b"".join(rows), fnv


def png(raw, width=WIDTH, height=HEIGHT):
    def chunk(kind, body):
        data = kind + body
        return struct.pack(">I", len(body)) + data + struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    kind = sys.argv[2] if len(sys.argv) == 3 else "document"
    if kind == "photos":
        raw, fnv = render_prints()
        data = png(raw, PRINTS_WIDTH, PRINTS_HEIGHT)
        print("photos fixture: FNV-1a of the RGBA bytes 0x%08X" % fnv)
    elif kind == "document":
        data = png(render())
    else:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as out:
        out.write(data)


if __name__ == "__main__":
    main()
