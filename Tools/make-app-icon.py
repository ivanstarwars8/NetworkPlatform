#!/usr/bin/env python3
"""Generates the app icon of «Бык»: the horn arc of the connect control in bronze on slate.

Original artwork from our own geometry (Packages/DesignSystem/Sources/DesignSystem/Horn/HornGeometry.swift);
the numbers below are the same (HornGeometryTests compares the SVG this script writes with the Swift file).
Pure Python (zlib only), no input assets. Writes, relative to the repository root:

    Apps/Branding/horn.svg                                         vector source (1000x1000 view box)
    Apps/Branding/iOS/Assets.xcassets/AppIcon.appiconset/          1024 opaque PNG (iOS/iPadOS masks it)
    Apps/Branding/macOS/Assets.xcassets/AppIcon.appiconset/        16…1024 PNGs, rounded square with margin

    Tools/make-app-icon.py            # from the repository root
"""
import json
import os
import struct
import sys
import zlib

# --- Geometry (thousandths of the unit square, y downwards) — keep equal to HornGeometry.swift -----------------
LEFT = {
    "start": (270, 940),
    "outer": ((0, 800), (30, 220), (500, 50)),
    "inner": ((250, 210), (220, 700), (450, 940)),
}

# --- Colours (Palette.swift) ----------------------------------------------------------------------------------
SLATE = (0x1E, 0x24, 0x29)       # surface, dark
BRONZE = (0xC9, 0x9A, 0x45)      # accent, dark

STEPS = 96  # samples per curve
SUB = 4     # sub-rows per pixel row (vertical anti-aliasing; horizontal coverage is exact per span)


def mirrored(outline):
    m = lambda p: (1000 - p[0], p[1])
    return {"start": m(outline["start"]), "outer": tuple(map(m, outline["outer"])), "inner": tuple(map(m, outline["inner"]))}


OUTLINES = [LEFT, mirrored(LEFT)]


def svg_path():
    def p(pt):
        return f"{pt[0]} {pt[1]}"

    def c(cubic):
        return "C " + " ".join(p(pt) for pt in cubic)

    return " ".join(f"M {p(o['start'])} {c(o['outer'])} {c(o['inner'])} Z" for o in OUTLINES)


def cubic_points(p0, cubic):
    c1, c2, p3 = cubic
    pts = []
    for i in range(1, STEPS + 1):
        t = i / STEPS
        u = 1 - t
        a, b, d, e = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
        pts.append((a * p0[0] + b * c1[0] + d * c2[0] + e * p3[0], a * p0[1] + b * c1[1] + d * c2[1] + e * p3[1]))
    return pts


def horn_polygons(scale, dx, dy):
    """Both horns as polygons in pixel coordinates: unit thousandths * scale + offset."""
    polys = []
    for o in OUTLINES:
        pts = [o["start"]] + cubic_points(o["start"], o["outer"]) + cubic_points(o["outer"][2], o["inner"])
        polys.append([(x / 1000 * scale + dx, y / 1000 * scale + dy) for x, y in pts])
    return polys


def rounded_rect(x0, y0, x1, y1, r, steps=24):
    import math
    pts = []
    corners = [(x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)]
    for cx, cy, a0 in corners:
        for i in range(steps + 1):
            a = math.radians(a0 + 90 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def coverage(polys, size):
    """Per-pixel coverage (0..1) of the union of polygons (non-zero winding), size x size."""
    cov = [[0.0] * size for _ in range(size)]
    edges = []
    for poly in polys:
        n = len(poly)
        for i in range(n):
            (xa, ya), (xb, yb) = poly[i], poly[(i + 1) % n]
            if ya != yb:
                edges.append((xa, ya, xb, yb))
    weight = 1.0 / SUB
    for py in range(size):
        row = cov[py]
        for s in range(SUB):
            y = py + (s + 0.5) / SUB
            crossings = []
            for xa, ya, xb, yb in edges:
                if (ya <= y < yb) or (yb <= y < ya):
                    x = xa + (y - ya) * (xb - xa) / (yb - ya)
                    crossings.append((x, 1 if yb > ya else -1))
            crossings.sort()
            winding = 0
            for i, (x, w) in enumerate(crossings):
                before = winding
                winding += w
                if before == 0 and winding != 0:
                    start = x
                elif before != 0 and winding == 0:
                    add_span(row, start, x, weight, size)
    return cov


def add_span(row, x0, x1, weight, size):
    x0 = max(0.0, x0)
    x1 = min(float(size), x1)
    if x1 <= x0:
        return
    i0, i1 = int(x0), int(x1)
    if i0 == i1:
        row[i0] += (x1 - x0) * weight
        return
    row[i0] += (i0 + 1 - x0) * weight
    for i in range(i0 + 1, min(i1, size)):
        row[i] += weight
    if i1 < size:
        row[i1] += (x1 - i1) * weight


def png(size, pixels, alpha):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    color_type = 6 if alpha else 2
    header = struct.pack(">IIBBBBB", size, size, 8, color_type, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def render_ios(size):
    """Full-bleed opaque square (the system applies the mask). Horn ~60% of the width, optically centred."""
    scale = size * 0.60
    dx = (size - scale) / 2
    dy = (size - scale) / 2 + size * 0.01
    horn = coverage(horn_polygons(scale, dx, dy), size)
    rows = []
    for py in range(size):
        bg = SLATE  # flat: no decorative gradients (DESIGN.md)
        row = bytearray()
        for px in range(size):
            row += bytes(mix(bg, BRONZE, min(1.0, horn[py][px])))
        rows.append(row)
    return png(size, rows, alpha=False)


def render_macos(size):
    """macOS draws no mask: a rounded square with the standard margin (824/1024 body), transparent outside."""
    inset = size * 100 / 1024
    body = size - 2 * inset
    plate = coverage([rounded_rect(inset, inset, size - inset, size - inset, body * 0.225)], size)
    scale = body * 0.60
    dx = inset + (body - scale) / 2
    dy = inset + (body - scale) / 2 + body * 0.01
    horn = coverage(horn_polygons(scale, dx, dy), size)
    rows = []
    for py in range(size):
        bg = SLATE
        row = bytearray()
        for px in range(size):
            a = min(1.0, plate[py][px])
            rgb = mix(bg, BRONZE, min(1.0, horn[py][px]))
            row += bytes(rgb) + bytes([round(a * 255)])
        rows.append(row)
    return png(size, rows, alpha=True)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as out:
        out.write(data)


def main():
    root = os.getcwd()
    if not os.path.exists(os.path.join(root, "Package.swift")):
        sys.exit("run from the repository root\n" + __doc__)
    branding = os.path.join(root, "Apps", "Branding")

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000">\n'
        "  <!-- «Бык» horn arc. Generated by Tools/make-app-icon.py from HornGeometry.swift; do not edit. -->\n"
        f'  <path fill="#C99A45" d="{svg_path()}"/>\n'
        "</svg>\n"
    )
    write(os.path.join(branding, "horn.svg"), svg.encode())

    ios = os.path.join(branding, "iOS", "Assets.xcassets", "AppIcon.appiconset")
    write(os.path.join(ios, "AppIcon-1024.png"), render_ios(1024))

    mac = os.path.join(branding, "macOS", "Assets.xcassets")
    images = []
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            px = points * factor
            name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
            write(os.path.join(mac, "AppIcon.appiconset", name), render_macos(px))
            images.append({"filename": name, "idiom": "mac", "scale": f"{factor}x", "size": f"{points}x{points}"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    write(os.path.join(mac, "AppIcon.appiconset", "Contents.json"), (json.dumps(contents, indent=2) + "\n").encode())
    write(os.path.join(mac, "Contents.json"), (json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n").encode())


if __name__ == "__main__":
    main()
