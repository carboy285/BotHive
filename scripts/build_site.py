#!/usr/bin/env python3
"""Builds the generated parts of the website in site/ (10.0):
- site/bots.svg: the Bots as an SVG sprite, drawn from the same shapes as the apps (scripts/make_dmg_background.py).
- site/privacy.html, site/terms.html, site/licenses.html: from PRIVACY.md, TERMS.md and THIRD_PARTY_NOTICES.md.
index.html, iphone.html, style.css and site.js are written by hand. Needs the `markdown` package.
"""
import html
import re
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'site'
sys.path.insert(0, str(ROOT / 'scripts'))
from make_dmg_background import body, eyes, COLORS  # noqa: E402  (same drawing as the DMG and the apps)

# Every shape/colour pair the pages use.
CREW = [('cloud', 'green'), ('circle', 'pink'), ('droplet', 'purple'), ('pebble', 'ochre'), ('capsule', 'amber'),
        ('heart', 'red'), ('square', 'blue'), ('flower', 'teal'), ('hexagon', 'orange'), ('sparkle', 'purple'),
        ('clover', 'gray'), ('circle', 'white')]


def path(points):
    return 'M' + ' L'.join(f'{x:.2f} {y:.2f}' for x, y in points) + ' Z'


def sprite():
    symbols = []
    for shape, color in CREW:
        fill = '#%06x' % COLORS[color]
        ink = '#000' if color == 'white' else '#fff'
        outline = ' stroke="#00000022" stroke-width="1.5"' if color == 'white' else ''
        parts = [f'<path d="{path(body(shape, 100))}" fill="{fill}"{outline}/>']
        parts += [f'<path class="eye" d="{path(eye)}" fill="{ink}"/>' for eye in eyes(100)]
        symbols.append(f'<symbol id="bot-{shape}-{color}" viewBox="-52 -52 104 104">{"".join(parts)}</symbol>')
    return '<svg xmlns="http://www.w3.org/2000/svg" style="display:none">' + ''.join(symbols) + '</svg>\n'


# The floating Bots on the home page: shape, colour, centre (% of the hero), size (px), tilt (deg),
# drift (px), drift time (s), delay (s) and blink period (s). Some hang off the edges on purpose.
HERO = [
    ('cloud', 'green', 34, 16, 92, -8, 10, -14, 7, 0, 5.2), ('circle', 'pink', 72, 18, 72, 0, -12, 10, 8, -2, 6.1),
    ('droplet', 'purple', 8, 34, 70, 12, 14, 8, 9, -4, 4.7), ('pebble', 'ochre', 92, 33, 76, -6, -10, -12, 7.5, -1, 5.6),
    ('capsule', 'amber', 2, 58, 104, 70, 10, -10, 10, -3, 6.6), ('heart', 'red', 99, 56, 100, -14, -14, 8, 8.5, -5, 4.9),
    ('square', 'blue', 18, 80, 78, 0, 12, -10, 9.5, -2, 5.8), ('flower', 'teal', 84, 77, 78, 10, -10, -12, 8, -6, 6.3),
    ('hexagon', 'orange', 55, 88, 94, 4, 8, -14, 7, -3, 5.1), ('sparkle', 'purple', 9, 95, 52, -10, 10, -6, 11, -1, 7.2),
    ('clover', 'gray', 92, 96, 50, 18, -8, -8, 10, -4, 6.8),
]


def crowd():
    out = ['<div class="crowd" aria-hidden="true">']
    for shape, color, x, y, size, tilt, dx, dy, speed, delay, blink in HERO:
        fill = '#%06x' % COLORS[color]
        ink = '#000' if color == 'white' else '#fff'
        eyes_svg = ''.join(f'<path class="eye" d="{path(e)}" fill="{ink}"/>' for e in eyes(100))
        style = (f'--x:{x}%;--y:{y}%;--size:{size}px;--tilt:{tilt}deg;--dx:{dx}px;--dy:{dy}px;'
                 f'--speed:{speed}s;--delay:{delay}s;--blink:{blink}s')
        # Bots in the middle band would cover the text on a phone; CSS hides them there.
        band = ' data-middle' if 25 < y < 70 else ''
        out.append(f'<svg viewBox="-52 -52 104 104"{band} style="{style}"><path d="{path(body(shape, 100))}" fill="{fill}"/>{eyes_svg}</svg>')
    out.append('</div>')
    return '\n'.join(out)


PAGE = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · Bothive</title>
<meta name="description" content="{description}">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="style.css">
</head>
<body class="doc">
<header class="bar"><a class="brand" href="./"><svg class="brand-bot" aria-hidden="true"><use href="bots.svg#bot-circle-white"/></svg>Bothive</a>
<nav><a href="./#download">Download</a><a href="iphone.html">iPhone</a><a href="https://github.com/carboy285/bothive">GitHub</a></nav></header>
<main class="prose">
{content}
</main>
{footer}
</body>
</html>
'''

FOOTER = '''<footer class="foot">
<nav><a href="privacy.html">Privacy</a><a href="terms.html">Terms</a><a href="licenses.html">Licenses</a><a href="https://github.com/carboy285/bothive">Source code</a><a href="https://github.com/carboy285/bothive/issues">Report a problem</a></nav>
<p>Bots are AI. They can be wrong, and they act through the AI accounts you connect.</p>
<p>Bothive is free, open-source software under the MIT License. It is an independent project, not affiliated with or endorsed by xAI, Anthropic, OpenAI, Google, Microsoft or Composio. Their names are used only to say which tools Bothive works with.</p>
</footer>'''

# Links between the Markdown files become links between pages.
LINKS = {'PRIVACY.md': 'privacy.html', 'TERMS.md': 'terms.html', 'THIRD_PARTY_NOTICES.md': 'licenses.html',
         'LICENSE': 'https://github.com/carboy285/bothive/blob/main/LICENSE'}


def page(source, out, title, description):
    text = (ROOT / source).read_text()
    for name, target in LINKS.items():
        text = text.replace(f']({name})', f']({target})')
    content = markdown.markdown(text, extensions=['tables', 'fenced_code'])
    (SITE / out).write_text(PAGE.format(title=html.escape(title), description=html.escape(description), content=content, footer=FOOTER))


if __name__ == '__main__':
    SITE.mkdir(exist_ok=True)
    (SITE / 'bots.svg').write_text(sprite())
    page('PRIVACY.md', 'privacy.html', 'Privacy policy', 'What Bothive stores, where it goes and how to delete it.')
    page('TERMS.md', 'terms.html', 'Terms of use', 'Terms for the free Bothive account and relay.')
    page('THIRD_PARTY_NOTICES.md', 'licenses.html', 'Open-source licenses', 'The open-source components Bothive includes and their licenses.')
    index = SITE / 'index.html'
    if index.exists():
        index.write_text(re.sub(r'<!--crowd-->.*?<!--/crowd-->', lambda _: '<!--crowd-->\n' + crowd() + '\n<!--/crowd-->', index.read_text(), flags=re.S))
    # The favicon is Hive itself.
    (SITE / 'favicon.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="-52 -52 104 104">' +
        f'<path d="{path(body("circle", 100))}" fill="#111"/>' + ''.join(f'<path d="{path(e)}" fill="#fff"/>' for e in eyes(100)) + '</svg>\n')
    # The hand-written pages share the same footer, between <!--footer--> markers.
    for name in ['index.html', 'iphone.html']:
        target = SITE / name
        if target.exists():
            target.write_text(re.sub(r'<!--footer-->.*?<!--/footer-->', lambda _: '<!--footer-->\n' + FOOTER + '\n<!--/footer-->', target.read_text(), flags=re.S))
    print('Built site/bots.svg and the legal pages.')
