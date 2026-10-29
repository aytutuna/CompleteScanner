"""Draws the Windows app icon from the same picture as the iPhone one (scripts/make_ios_icon.py).
Windows does not round icons, so the square gets rounded corners, transparent outside them. Every
frame is a PNG, which .ico files may hold since Windows Vista.

Usage: python scripts/make_ico.py <out.ico>
"""

import struct
import sys

from make_ios_icon import DESIGN, draw

SIZES = (16, 20, 24, 32, 40, 48, 64, 256)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python scripts/make_ico.py <out.ico>")
    frames = [draw(size, corner=0.22 * DESIGN) for size in SIZES]
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = len(header) + 16 * len(frames)
    entries = b""
    for size, png in zip(SIZES, frames):
        # A width or height of 0 in the directory means 256.
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset)
        offset += len(png)
    with open(sys.argv[1], "wb") as out:
        out.write(header + entries + b"".join(frames))
    print("wrote %s (%s)" % (sys.argv[1], ", ".join(str(size) for size in SIZES)))


if __name__ == "__main__":
    main()
