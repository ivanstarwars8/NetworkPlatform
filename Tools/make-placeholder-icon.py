#!/usr/bin/env python3
"""Generates the placeholder app icon of the "Byk" build: a monochrome horned-ring glyph on a flat background.

Pure Python (zlib only), no input assets: every pixel comes from the geometry below. Output is a 1024x1024 opaque
RGB PNG (App Store icons must not have an alpha channel).

    Tools/make-placeholder-icon.py Apps/Branding/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import struct
import sys
import zlib

SIZE = 1024
SAMPLES = 3  # supersampling per axis (anti-aliasing)
BACKGROUND = (24, 28, 36)
FOREGROUND = (236, 239, 244)


def inside(x, y):
    """Glyph membership in unit coordinates (y grows downwards)."""
    def d2(cx, cy):
        return (x - cx) ** 2 + (y - cy) ** 2
    # Ring (the head).
    ring = 0.135 ** 2 <= d2(0.5, 0.62) <= 0.205 ** 2
    # Crescent opening upwards (the horns): inside the lower circle, outside the shifted upper one.
    crescent = d2(0.5, 0.30) <= 0.275 ** 2 and d2(0.5, 0.215) > 0.255 ** 2 and y < 0.47
    return ring or crescent


def render():
    rows = []
    step = 1.0 / (SIZE * SAMPLES)
    total = SAMPLES * SAMPLES
    for py in range(SIZE):
        row = bytearray(b"\x00")  # PNG filter type 0
        for px in range(SIZE):
            hits = 0
            for sy in range(SAMPLES):
                y = (py * SAMPLES + sy + 0.5) * step
                for sx in range(SAMPLES):
                    if inside((px * SAMPLES + sx + 0.5) * step, y):
                        hits += 1
            a = hits / total
            row += bytes(round(b + (f - b) * a) for b, f in zip(BACKGROUND, FOREGROUND))
        rows.append(bytes(row))
    return b"".join(rows)


def png(raw):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB, no alpha
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as out:
        out.write(png(render()))
