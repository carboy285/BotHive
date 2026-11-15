#!/usr/bin/env python3
"""Draw the DMG window background (0.9.9): Bots scattered around the edges and an arrow from the app
to Applications. Shapes and colors match GrokBot/Design/BotGlyph.swift.

Writes scripts/dmg/background.png (640x400) and background@2x.png (1280x800).
scripts/build-macos.sh combines them into a HiDPI TIFF. Needs Pillow.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent / 'dmg'
WIDTH, HEIGHT = 640, 400
# Icon centers in window points; build-macos.sh places the Finder icons at the same spots.
APP, APPLICATIONS = (180, 190), (460, 190)

COLORS = {'black': 0x111111, 'ochre': 0xA46E39, 'red': 0xFF2948, 'orange': 0xFF7012, 'amber': 0xF69A0A,
          'green': 0x10BF70, 'teal': 0x15B6A5, 'blue': 0x2385FF, 'purple': 0x9355FF, 'pink': 0xF62A9B,
          'gray': 0x969696, 'white': 0xFFFFFF}

# (shape, color, x, y, size, tilt in degrees). Points, origin top-left. Some hang off the edges on purpose.
CREW = [
    ('cloud', 'green', 318, 58, 46, -8),
    ('pebble', 'ochre', 150, 44, 30, -6),
    ('circle', 'pink', 548, 62, 36, 0),
    ('droplet', 'purple', 44, 96, 40, 12),
    ('capsule', 'amber', 8, 236, 58, 70),
    ('heart', 'red', 630, 210, 56, -14),
    ('square', 'blue', 76, 338, 38, 0),
    ('hexagon', 'orange', 322, 352, 46, 4),
    ('flower', 'teal', 584, 318, 38, 10),
    ('sparkle', 'purple', 500, 378, 24, -10),
]


def rgb(name):
    value = COLORS[name]
    return ((value >> 16) & 255, (value >> 8) & 255, value & 255, 255)


def rotate(points, degrees):
    """Clockwise on screen (y grows downward), like SwiftUI's rotationEffect."""
    angle = math.radians(degrees)
    c, s = math.cos(angle), math.sin(angle)
    return [(x * c - y * s, x * s + y * c) for x, y in points]


def capsule(width, height, steps=16):
    """A vertical capsule centered on the origin."""
    r = width / 2
    half = max(0.0, height / 2 - r)
    top = [(r * math.cos(math.pi + math.pi * i / steps), -half + r * math.sin(math.pi + math.pi * i / steps)) for i in range(steps + 1)]
    bottom = [(r * math.cos(math.pi * i / steps), half + r * math.sin(math.pi * i / steps)) for i in range(steps + 1)]
    return top + bottom


def cubic(p0, p1, p2, p3, steps=24):
    return [tuple((1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t ** 2 * c + t ** 3 * d for a, b, c, d in zip(p0, p1, p2, p3))
            for t in (i / steps for i in range(1, steps + 1))]


def body(shape, size):
    """Outline centered on the origin. Mirrors BotGlyphShape, drawn inside 4% padding."""
    w = size * 0.92
    if shape in ('circle', 'fruit'):
        return [(w / 2 * math.cos(a), w / 2 * math.sin(a)) for a in (2 * math.pi * i / 120 for i in range(120))]
    if shape == 'square':
        r, half, pts = w * 0.13, w / 2, []
        for cx, cy, start in [(half - r, -half + r, -90), (half - r, half - r, 0), (-half + r, half - r, 90), (-half + r, -half + r, 180)]:
            pts += [(cx + r * math.cos(math.radians(start + 90 * i / 8)), cy + r * math.sin(math.radians(start + 90 * i / 8))) for i in range(9)]
        return rotate(pts, -20)
    if shape == 'capsule':
        return rotate(capsule(w * 0.76, w), 90)
    if shape == 'heart':
        def p(x, y): return (w * (x - 0.5), w * (y - 0.5))
        pts = [p(0.5, 0.94)]
        pts += cubic(p(0.5, 0.94), p(0.1, 0.75), p(-0.1, 0.55), p(0.04, 0.3))
        pts += cubic(p(0.04, 0.3), p(0.1, -0.02), p(0.4, 0.01), p(0.5, 0.22))
        pts += cubic(p(0.5, 0.22), p(0.6, 0.01), p(0.9, -0.02), p(0.96, 0.3))
        pts += cubic(p(0.96, 0.3), p(1.1, 0.55), p(0.9, 0.75), p(0.5, 0.94))
        return pts
    pts = []
    for i in range(120):
        a = i / 120 * 2 * math.pi - math.pi / 2
        radius = {
            'hexagon': lambda: 0.42 / math.cos((a + 2 * math.pi) % (math.pi / 3) - math.pi / 6),
            'triangle': lambda: 0.37 + 0.105 * math.cos(3 * a),
            'sparkle': lambda: 0.37 + 0.11 * math.cos(4 * a),
            'star': lambda: 0.37 + 0.105 * math.cos(6 * a),
            'flower': lambda: 0.41 + 0.07 * math.cos(5 * a),
            'clover': lambda: 0.40 + 0.085 * math.cos(4 * a + 0.6),
            'cloud': lambda: 0.42 + 0.055 * math.cos(7 * a) + 0.025 * math.sin(3 * a),
            'droplet': lambda: 0.39 + 0.08 * math.cos(a) + 0.055 * math.cos(3 * a),
            'pebble': lambda: 0.43 + 0.035 * math.cos(3 * a) + 0.025 * math.sin(2 * a),
        }.get(shape, lambda: 0.46)()
        pts.append((w * radius * math.cos(a), w * radius * math.sin(a)))
    return pts


def eyes(size):
    """Two capsule eyes: spaced, the second raised, the pair tilted -25° and nudged up and right."""
    w, h, gap = size * 0.09, size * 0.25, size * 0.115
    centers = [(-(w + gap) / 2, 0), ((w + gap) / 2, -size * 0.035)]
    out = []
    for cx, cy in centers:
        eye = [(x + cx, y + cy) for x, y in capsule(w, h)]
        out.append([(x + size * 0.07, y - size * 0.06) for x, y in rotate(eye, -25)])
    return out


def draw_bot(draw, shape, color, x, y, size, tilt, scale):
    def place(points): return [((x + px) * scale, (y + py) * scale) for px, py in rotate(points, tilt)]
    draw.polygon(place(body(shape, size)), fill=rgb(color))
    ink = (0, 0, 0, 255) if color == 'white' else (255, 255, 255, 255)
    for eye in eyes(size):
        draw.polygon(place(eye), fill=ink)


def draw_arrow(draw, scale):
    """A soft curved arrow from the app toward Applications."""
    gray = (196, 196, 202, 255)
    start, end = (APP[0] + 82, APP[1] - 10), (APPLICATIONS[0] - 84, APPLICATIONS[1] - 10)
    control = ((start[0] + end[0]) / 2, start[1] - 46)
    pts = [((1 - t) ** 2 * start[0] + 2 * (1 - t) * t * control[0] + t ** 2 * end[0],
            (1 - t) ** 2 * start[1] + 2 * (1 - t) * t * control[1] + t ** 2 * end[1]) for t in (i / 60 for i in range(61))]
    width = 3.2 * scale
    for a, b in zip(pts, pts[1:]):
        draw.line([(a[0] * scale, a[1] * scale), (b[0] * scale, b[1] * scale)], fill=gray, width=round(width))
    for px, py in (pts[0], pts[-1]):
        r = width / 2
        draw.ellipse([px * scale - r, py * scale - r, px * scale + r, py * scale + r], fill=gray)
    # Arrowhead along the last segment's direction.
    (ax, ay), (bx, by) = pts[-4], pts[-1]
    angle = math.atan2(by - ay, bx - ax)
    for side in (-1, 1):
        a = angle + math.pi - side * math.radians(38)
        tip = (bx + 13 * math.cos(a), by + 13 * math.sin(a))
        draw.line([(bx * scale, by * scale), (tip[0] * scale, tip[1] * scale)], fill=gray, width=round(width))
        r = width / 2
        draw.ellipse([tip[0] * scale - r, tip[1] * scale - r, tip[0] * scale + r, tip[1] * scale + r], fill=gray)


def draw_caption(draw, scale):
    """One quiet line under the icons. The PNGs are committed, so the font only matters where this runs."""
    size = round(13 * scale)
    font = None
    for path in ['/usr/share/fonts/opentype/inter/Inter-Medium.otf', '/System/Library/Fonts/SFNS.ttf', '/Library/Fonts/Arial.ttf']:
        try:
            font = ImageFont.truetype(path, size)
            break
        except OSError:
            continue
    draw.text((WIDTH / 2 * scale, 300 * scale), 'Drag Bothive into Applications', fill=(150, 150, 156, 255),
              font=font or ImageFont.load_default(size), anchor='mm')


def render(factor):
    supersample = 4
    scale = factor * supersample
    image = Image.new('RGBA', (WIDTH * scale, HEIGHT * scale), (252, 252, 252, 255))
    draw = ImageDraw.Draw(image)
    draw_arrow(draw, scale)
    draw_caption(draw, scale)
    for crew in CREW:
        draw_bot(draw, *crew, scale)
    return image.resize((WIDTH * factor, HEIGHT * factor), Image.LANCZOS).convert('RGB')


if __name__ == '__main__':
    OUT.mkdir(exist_ok=True)
    render(1).save(OUT / 'background.png', optimize=True)
    render(2).save(OUT / 'background@2x.png', optimize=True)
    print('Wrote', OUT / 'background.png', 'and', OUT / 'background@2x.png')
