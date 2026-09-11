"""Noren — turn the active Omarchy palette into CSS for web pages.

Omarchy publishes the current palette as `colors.toml` under
`~/.local/state/omarchy/current/theme/`, rewritten on every theme switch.
`omarchy-theme-color --all` resolves that into the full vocabulary the themed
templates see — aliases, derived shades, and `mode`.

Why this lives in the host rather than in a `.tpl`: Omarchy's template renderer
is pure `sed`. It substitutes values and can `mix` two of them, but it cannot
branch and cannot solve. Mapping palette hues onto semantic roles needs both,
because a palette colour that reads fine as terminal text routinely fails
WCAG AA against the same theme's page background:

    catppuccin-latte   green on background   2.96:1
    flexoki-light      green on background   3.04:1

Measured across the 62 themes installed on this machine, 90 of 434 role/background
pairs fail 4.5:1 untouched — 37 of 91 in light themes. So the correction is not
an edge case, and it cannot be a constant: the required lightness depends on the
theme's own background, so it has to be solved per theme. Forcing a single
lightness on every theme needs L=0.20 in light mode to clear AA everywhere, which
flattens every hue to near-black.

`solve_contrast` instead moves lightness the minimum distance that clears the
target, keeping hue and chroma. Across those same 62 themes that leaves 0
failures with 344 of 434 colours untouched and a mean lightness shift of 0.055.
"""

import math
import os
import subprocess

THEME_DIR = os.path.expanduser("~/.local/state/omarchy/current/theme")
COLORS_FILE = os.path.join(THEME_DIR, "colors.toml")
# A theme (or a user template) may ship a finished stylesheet. If it does it
# wins outright -- a human tuned it for this palette and we should not argue.
THEME_OVERRIDE = os.path.join(THEME_DIR, "noren.css")

# Roles we map onto the page. Kept deliberately small: these are the ones a
# document actually uses. Anything more and we are repainting, not theming.
ROLES = {
    "accent": "accent",
    "link": "blue",
    "success": "green",
    "warning": "yellow",
    "danger": "red",
}

AA_NORMAL = 4.5


# --------------------------------------------------------------- colour maths


def _srgb_to_linear(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(c):
    c = 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055
    return max(0, min(255, round(c * 255)))


def _parse(hex_str):
    h = hex_str.lstrip("#")
    if len(h) == 3:
        h = "".join(ch * 2 for ch in h)
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def luminance(hex_str):
    r, g, b = (_srgb_to_linear(c) for c in _parse(hex_str))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def to_oklch(hex_str):
    r, g, b = (_srgb_to_linear(c) for c in _parse(hex_str))
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = l ** (1 / 3), m ** (1 / 3), s ** (1 / 3)
    lightness = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    a_ = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    b_ = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return lightness, math.hypot(a_, b_), math.degrees(math.atan2(b_, a_)) % 360


def from_oklch(lightness, chroma, hue):
    a_ = chroma * math.cos(math.radians(hue))
    b_ = chroma * math.sin(math.radians(hue))
    l_ = lightness + 0.3963377774 * a_ + 0.2158037573 * b_
    m_ = lightness - 0.1055613458 * a_ - 0.0638541728 * b_
    s_ = lightness - 0.0894841775 * a_ - 1.2914855480 * b_
    l, m, s = l_**3, m_**3, s_**3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return "#%02x%02x%02x" % (
        _linear_to_srgb(r),
        _linear_to_srgb(g),
        _linear_to_srgb(b),
    )


def solve_contrast(fg, bg, target=AA_NORMAL):
    """Nearest colour to `fg` that clears `target` against `bg`.

    Hue and chroma are held; only lightness moves, and only as far as it must,
    so a theme's identity survives the correction. Returns `fg` untouched when
    it already passes -- which is the common case.
    """
    if contrast(fg, bg) >= target:
        return fg

    lightness, chroma, hue = to_oklch(fg)
    # Move away from the background, not toward some fixed pole. 0.18 is the
    # perceptual midpoint of the sRGB range, not 0.5 -- luminance is not linear.
    bg_is_light = luminance(bg) > 0.18
    lo, hi = (0.0, lightness) if bg_is_light else (lightness, 1.0)

    best = None
    for _ in range(32):
        mid = (lo + hi) / 2
        candidate = from_oklch(mid, chroma, hue)
        if contrast(candidate, bg) >= target:
            best = candidate
            # Keep narrowing toward the original lightness.
            if bg_is_light:
                lo = mid
            else:
                hi = mid
        elif bg_is_light:
            hi = mid
        else:
            lo = mid

    if best is not None:
        return best

    # Saturated hues on a mid-grey ground can be unreachable at full chroma:
    # yellow on white has nowhere to go while it stays yellow. Desaturate only
    # then, and only as far as needed.
    for factor in (0.75, 0.5, 0.25, 0.0):
        end = 0.0 if bg_is_light else 1.0
        candidate = from_oklch(end, chroma * factor, hue)
        if contrast(candidate, bg) >= target:
            return candidate
    return "#000000" if bg_is_light else "#ffffff"


# ------------------------------------------------------------------- palette


def read_palette(colors_file=COLORS_FILE):
    """The resolved Omarchy vocabulary, or None if no theme is published yet."""
    if not os.path.exists(colors_file):
        return None
    try:
        out = subprocess.run(
            ["omarchy-theme-color", "--file", colors_file, "--all"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None

    palette = {}
    for line in out.stdout.splitlines():
        if "\t" in line:
            key, value = line.split("\t", 1)
            palette[key.strip()] = value.strip()
    return palette or None


def derive(palette):
    """Semantic roles, contrast-corrected against this theme's own background."""
    bg = palette.get("background", "#000000")
    fg = palette.get("foreground", "#ffffff")

    # Surfaces step *toward the text*, never "lighter". In light themes
    # `lighter_background` is darker than `background` -- and darker than
    # `dark_background` -- because the names encode distance from the ground,
    # not direction. Mixing toward the foreground is the only rule that holds
    # in both modes.
    def toward_fg(amount):
        lb, cb, hb = to_oklch(bg)
        lf, _, _ = to_oklch(fg)
        return from_oklch(lb + (lf - lb) * amount, cb, hb)

    roles = {
        "bg": bg,
        "fg": fg,
        "surface": toward_fg(0.06),
        "surface-2": toward_fg(0.12),
        "border": toward_fg(0.22),
        "muted": solve_contrast(palette.get("muted", fg), bg, 4.5),
        "selection-bg": palette.get("selection_background", palette.get("accent", fg)),
        "selection-fg": palette.get("selection_foreground", bg),
    }
    for role, source in ROLES.items():
        raw = palette.get(source)
        if raw:
            roles[role] = solve_contrast(raw, bg)
    return roles


# ----------------------------------------------------------------------- css


def _vars_block(roles, mode):
    lines = [f"  color-scheme: {mode};"]
    lines += [f"  --noren-{k}: {v};" for k, v in sorted(roles.items())]
    return ":root {\n" + "\n".join(lines) + "\n}"


# Painting the canvas is the whole reason `respect` is not the only useful mode:
# between pages the browser shows its own base colour, and on a dark desktop
# that white frame is the single most jarring thing about browsing. `color-scheme`
# above fixes the scrollbars and form controls; this fixes the gap.
# Split out because immerse must not include it: the surface pass reads the
# site's own ground before remapping anything, and painting `html` first would
# make every page look like it was already themed.
CANVAS = """
html {
  background-color: var(--noren-bg) !important;
}
"""

TINT = """
::selection {
  background-color: var(--noren-selection-bg) !important;
  color: var(--noren-selection-fg) !important;
}
:root {
  accent-color: var(--noren-accent);
  caret-color: var(--noren-accent);
  scrollbar-color: var(--noren-border) var(--noren-bg);
}
"""

# Immerse repaints the page's own surfaces, not just the canvas behind them.
#
# Its honest limit: it restyles the root surfaces, links, controls and borders,
# and lets inheritance carry `color` down. It cannot recolour a site that paints
# its own surfaces -- a white card on a white page stays white -- because
# `background-color` does not inherit, so there is nothing to override without
# first reading every element's computed style and deciding whether its colour
# is decoration or meaning. That is what Dark Reader does, it is a large piece
# of work, and guessing at it produces unreadable pages and destroyed diffs.
# Until that exists, immerse is a stronger tint, not a full reskin.
# Immerse adds only what a walk of the document cannot do well. Surfaces, text
# and borders are remapped at runtime by the extension's surface pass, which
# reads each element's *computed* colour -- the only way to reach a card that
# paints itself.
#
# Nothing here may paint `html` or `body`. The stylesheet lands before the pass
# runs, so forcing the page background would destroy the very reading the pass
# depends on: the site's own ground, which is what every remapped colour is
# measured against.
# Empty on purpose. Link colouring used to live here, but a blanket
# `a:link { ... !important }` at USER origin overrides the surface pass's own
# decisions -- including its refusal to touch text sitting on a surface it does
# not own. On a webmail site that painted the theme's link colour onto links inside
# light-blue gradient cards, where it was unreadable. Links are coloured by the
# pass instead, which knows what each one is sitting on.
IMMERSE = """
"""


def build_css(palette=None):
    """{mode_name: stylesheet} for every theming mode, plus the palette mode.

    Returns None when no Omarchy theme is published, so callers can stay quiet
    rather than injecting a guess.
    """
    palette = palette or read_palette()
    if not palette:
        return None

    mode = palette.get("mode", "dark")
    if mode not in ("light", "dark"):
        mode = "dark"

    roles = derive(palette)
    base = _vars_block(roles, mode)

    # A theme that ships its own noren.css replaces the generated rules but
    # still gets the variables, so an override can be a few lines rather than
    # a whole stylesheet.
    override = None
    if os.path.exists(THEME_OVERRIDE):
        try:
            with open(THEME_OVERRIDE, "r") as fh:
                override = fh.read()
        except OSError:
            override = None

    if override is not None:
        tint = base + "\n" + override
        immerse = tint
    else:
        tint = base + "\n" + CANVAS + TINT
        # No CANVAS: the surface pass paints the page background itself, from
        # the site's real ground rather than over the top of it.
        immerse = base + "\n" + TINT + IMMERSE

    return {
        "mode": mode,
        "themed": bool(override),
        "roles": roles,
        "tint": tint,
        "immerse": immerse,
    }
