"""Noren — turn the colours of a web page into an Omarchy theme.

The extension reads the page (`norenPalette` in background.js) and sends back
weighted colour samples in three kinds:

    bg      what the screen is covered with, sampled on a grid, so the weight is
            real screen area rather than the sum of every nested box
    text    text colours, weighted by how much text uses them
    accent  colours of the things you press -- buttons, links, the current tab,
            icons -- plus the page's own <meta name="theme-color">

`build` turns those into the vocabulary of an Omarchy v4 `colors.toml`. Omarchy
derives every app's colours from that one file, so it is all Noren writes.

Everything here is pure: samples in, dict out. Readability is not negotiable, so
each role goes through `solve_contrast` the same way page theming does; a page
may get away with light grey text on white, a terminal cannot.
"""

import math

from noren_theme import AA_NORMAL, contrast, from_oklch, luminance, solve_contrast, to_oklch

# Where each named colour sits on the OKLCH hue wheel. Measured from the stock
# Omarchy themes' own reds, greens, etc., rounded.
HUES = {
    "red": 25,
    "orange": 55,
    "yellow": 95,
    "green": 145,
    "cyan": 195,
    "blue": 255,
    "magenta": 330,
}
# How far a page colour may sit from a slot's hue and still fill it. Wide enough
# that a brand orange-red counts as red; narrow enough that it is not also green.
HUE_REACH = 22
# Below this a colour is a grey, whatever its nominal hue.
CHROMATIC = 0.05


def _lab(hex_str):
    lightness, chroma, hue = to_oklch(hex_str)
    return (
        lightness,
        chroma * math.cos(math.radians(hue)),
        chroma * math.sin(math.radians(hue)),
    )


def distance(a, b):
    """Perceptual distance (OKLab). ~0.02 is just noticeable."""
    return math.dist(_lab(a), _lab(b))


def mix(a, b, amount):
    """`a` moved `amount` of the way to `b`, in OKLab."""
    la, lb = _lab(a), _lab(b)
    lightness, x, y = (p + (q - p) * amount for p, q in zip(la, lb))
    return from_oklch(lightness, math.hypot(x, y), math.degrees(math.atan2(y, x)) % 360)


def hue_gap(a, b):
    gap = abs(a - b) % 360
    return min(gap, 360 - gap)


def share(samples):
    """Weights as fractions of their kind.

    The three kinds are counted in different units -- grid cells, characters,
    button area -- so only their proportions can be compared across kinds.
    """
    samples = [(h, w) for h, w in (samples or []) if w > 0]
    total = sum(w for _, w in samples) or 1
    return [(h, w / total) for h, w in samples]


def cluster(samples, radius=0.03):
    """Merge near-identical colours. [(hex, weight)] -> [(hex, weight)], heaviest first.

    Pages are full of `#1a1a1a` next to `#1b1b1b`; counted apart, neither wins.
    Greedy by weight, so each group is named after its most used member.
    """
    merged = []
    for hex_str, weight in sorted(samples, key=lambda s: -s[1]):
        hex_str = hex_str.lower()
        for group in merged:
            if distance(group[0], hex_str) <= radius:
                group[1] += weight
                break
        else:
            merged.append([hex_str, weight])
    merged.sort(key=lambda g: -g[1])
    return [(h, w) for h, w in merged]


def _shift(hex_str, delta):
    lightness, chroma, hue = to_oklch(hex_str)
    return from_oklch(max(0.0, min(1.0, lightness + delta)), chroma, hue)


def _scale_chroma(hex_str, factor):
    lightness, chroma, hue = to_oklch(hex_str)
    return from_oklch(lightness, chroma * factor, hue)


def is_light(hex_str):
    # The same midpoint solve_contrast uses: luminance is not linear.
    return luminance(hex_str) > 0.18


def flip(hex_str, to_light):
    """The same hue on the other side of the lightness range.

    Most of the web is white, and most people run a dark desktop. Flipping keeps
    the page's identity -- its tint, its brand colour -- and moves only
    lightness, into the band real themes live in.
    """
    lightness, chroma, hue = to_oklch(hex_str)
    if to_light:
        target = 0.93 + 0.05 * (1 - lightness)
    else:
        target = 0.22 + 0.06 * (1 - lightness)
    # A background that is itself strongly coloured stays tinted, not garish.
    return from_oklch(target, min(chroma, 0.04), hue)


def pick_background(bg):
    return bg[0][0] if bg else "#ffffff"


def pick_foreground(text, background):
    """The most used text colour that is actually readable as body text."""
    for hex_str, _ in text:
        if contrast(hex_str, background) >= 3:
            return hex_str
    return "#1a1a1a" if is_light(background) else "#e8e8e8"


def pick_accent(accent, others, background, foreground, theme_color=None):
    """The colour the page presses with.

    Chromatic candidates from buttons and links win on weight; the page's
    theme-color is a strong hint because the site chose it for exactly this.
    A page with no colour at all gets a quiet blue rather than a grey accent.
    """
    scored = {}
    for hex_str, weight in accent:
        scored[hex_str] = scored.get(hex_str, 0) + weight * 3
    for hex_str, weight in others:
        scored[hex_str] = scored.get(hex_str, 0) + weight
    if theme_color:
        scored[theme_color.lower()] = scored.get(theme_color.lower(), 0) + 1e9

    best, best_score = None, 0
    for hex_str, weight in scored.items():
        _, chroma, _ = to_oklch(hex_str)
        if chroma < CHROMATIC:
            continue
        if distance(hex_str, background) < 0.08 or distance(hex_str, foreground) < 0.08:
            continue
        score = weight * min(chroma, 0.2)
        if score > best_score:
            best, best_score = hex_str, score
    return best or from_oklch(0.6, 0.12, HUES["blue"])


def pick_hues(samples, accent, background=None, foreground=None):
    """One colour per named hue: the page's own where it has one, else made up.

    Made-up hues borrow the accent's lightness and chroma, so a muted site gets
    a muted terminal and a loud one a loud terminal -- the same family, not a
    stock palette bolted on.
    """
    a_light, a_chroma, _ = to_oklch(accent)
    chroma = max(0.08, min(a_chroma, 0.2))
    lightness = max(0.45, min(a_light, 0.75))

    # Each page colour fills at most the one slot it is nearest, so a brand
    # orange does not also become the red. The page's own text and ground are
    # not candidates: a peach body text is "orange" by hue, and orange that
    # looks exactly like plain text is no colour at all.
    found = {}
    for hex_str, _ in samples:
        _, c, h = to_oklch(hex_str)
        if c < CHROMATIC:
            continue
        if any(ref and distance(hex_str, ref) < 0.08 for ref in (background, foreground)):
            continue
        name = min(HUES, key=lambda n: hue_gap(h, HUES[n]))
        if hue_gap(h, HUES[name]) <= HUE_REACH:
            found.setdefault(name, hex_str)

    out = {}
    for name, target in HUES.items():
        out[name] = found.get(name) or from_oklch(lightness, chroma, target)
    out["brown"] = from_oklch(0.45, 0.06, HUES["orange"])
    return out


# The roles the adjust window lets you repaint. Everything else in the theme is
# derived from these, so it follows along.
EDITABLE = ["background", "foreground", "accent"] + list(HUES)


def _hex(value):
    value = str(value or "").strip().lower()
    if len(value) == 7 and value[0] == "#" and all(c in "0123456789abcdef" for c in value[1:]):
        return value
    return None


def page_colours(samples, limit=18):
    """The page's own colours, most used first: what the adjust window offers."""
    kinds = [cluster(share(samples.get(k))) for k in ("bg", "text", "accent")]
    return [h for h, _ in cluster([pair for kind in kinds for pair in kind])[:limit]]


def build(samples, mode=None, vividness=1.0, overrides=None):
    """Samples from the page -> a complete Omarchy palette.

    `samples` is the extension's reply: {"bg", "text", "accent": [[hex, weight]],
    "themeColor": hex or None}. `mode` forces "dark" or "light"; by default the
    theme is whatever the page is. `vividness` scales every colour's chroma.
    `overrides` maps an EDITABLE role to a colour you chose. A chosen colour is
    still made readable: you pick the hue, the theme keeps it legible.
    """
    overrides = {k: _hex(v) for k, v in (overrides or {}).items() if k in EDITABLE and _hex(v)}
    bg = cluster(share(samples.get("bg")))
    text = cluster(share(samples.get("text")))
    accents = cluster(share(samples.get("accent")))
    everything = cluster(bg + text + accents)

    background = pick_background(bg)
    foreground = pick_foreground(text, background)
    accent = pick_accent(accents, everything, background, foreground, samples.get("themeColor"))

    page_background, page_foreground = background, foreground
    page_light = is_light(background)
    light = page_light if mode is None else mode == "light"
    if light != page_light:
        background = flip(background, light)
        foreground = flip(foreground, not light)
    if "background" in overrides:
        # The ground decides the mode, whatever was asked for.
        background = overrides["background"]
        light = is_light(background)
        if contrast(foreground, background) < 3:
            foreground = flip(foreground, not light)
    foreground = overrides.get("foreground", foreground)

    hues = pick_hues(everything, accent, page_background, page_foreground)
    if vividness != 1.0:
        accent = _scale_chroma(accent, vividness)
        hues = {k: _scale_chroma(v, vividness) for k, v in hues.items()}
    accent = overrides.get("accent", accent)
    hues.update({k: v for k, v in overrides.items() if k in HUES})

    readable = lambda c: solve_contrast(c, background, AA_NORMAL)
    foreground = readable(foreground)
    accent = readable(accent)
    hues = {k: readable(v) for k, v in hues.items()}

    # Surfaces step toward the foreground; dark_ and darker_ always step down.
    # Both are how the stock themes do it, light ones included.
    theme = {
        "mode": "light" if light else "dark",
        "accent": accent,
        "selection": mix(background, accent, 0.3),
        "muted": mix(background, foreground, 0.3),
        "background": background,
        "dark_background": _shift(background, -0.03),
        "darker_background": _shift(background, -0.06),
        "lighter_background": mix(background, foreground, 0.08),
        "foreground": foreground,
        "dark_foreground": mix(foreground, background, 0.35),
        "light_foreground": mix(foreground, background, 0.1),
        "bright_foreground": _shift(foreground, -0.04 if light else 0.04),
    }
    brighter = -0.07 if light else 0.07
    for name in ("red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown"):
        theme[name] = hues[name]
    for name in ("red", "yellow", "green", "cyan", "blue", "magenta"):
        theme["bright_" + name] = readable(_shift(hues[name], brighter))
    return theme


ORDER = [
    ["mode"],
    ["accent", "selection", "muted"],
    ["background", "dark_background", "darker_background", "lighter_background"],
    ["foreground", "dark_foreground", "light_foreground", "bright_foreground"],
    ["red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown"],
    ["bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta"],
]


def to_toml(theme, source=""):
    lines = [f"# Made by noren steal{' from ' + source if source else ''}."]
    for group in ORDER:
        lines.append("")
        lines.extend(f'{key} = "{theme[key]}"' for key in group)
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------- wallpapers
#
# Made from the finished theme, so they match it. Pure Python on purpose: no
# PIL, no ImageMagick. They are small -- the desktop scales them up, and a
# gradient has no detail to lose -- so a plain loop is quick enough.

GRADIENTS = ["glow", "dusk", "solid"]


def _rgb(hex_str):
    h = hex_str.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def png(width, height, rows):
    """A minimal RGB PNG. `rows` yields `height` byte strings of width*3."""
    import struct
    import zlib

    def chunk(kind, data):
        head = struct.pack(">I", len(data)) + kind + data
        return head + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def wallpaper(theme, kind, width=640, height=360):
    """A PNG wallpaper in the theme's colours.

    glow   the background with the accent rising from the lower left
    dusk   darker at the top, warming toward the accent at the bottom
    solid  just the background
    StealPanel.qml draws the same three for its thumbnails; keep them alike.
    """
    background = _rgb(theme["background"])
    if kind == "solid":
        row = bytes(background) * width
        return png(width, height, (row for _ in range(height)))

    if kind == "dusk":
        top = _rgb(theme["darker_background"])
        bottom = _rgb(mix(theme["background"], theme["accent"], 0.3))

        def dusk_rows():
            for y in range(height):
                t = y / (height - 1)
                pixel = bytes(round(a + (b - a) * t) for a, b in zip(top, bottom))
                yield pixel * width
        return png(width, height, dusk_rows())

    accent = _rgb(theme["accent"])
    cx, cy, reach = 0.28 * width, 0.78 * height, 0.85 * width

    def glow_rows():
        for y in range(height):
            row = bytearray(width * 3)
            dy = (y - cy) ** 2
            for x in range(width):
                # Gaussian, so the middle is soft rather than a point.
                d = math.sqrt((x - cx) ** 2 + dy) / reach
                t = 0.42 * math.exp(-((d / 0.45) ** 2))
                i = x * 3
                row[i] = round(background[0] + (accent[0] - background[0]) * t)
                row[i + 1] = round(background[1] + (accent[1] - background[1]) * t)
                row[i + 2] = round(background[2] + (accent[2] - background[2]) * t)
            yield row
    return png(width, height, glow_rows())
