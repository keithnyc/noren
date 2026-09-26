import unittest

import _load  # noqa: F401 -- puts host/ on the path
import noren_steal as st
import noren_theme as th

# A made-up page: white, dark grey body text, an orange brand on its buttons,
# blue links. Weights are in each kind's own units, as the extension sends them.
PAGE = {
    "bg": [["#ffffff", 700], ["#fafafa", 100], ["#f6f6ef", 60], ["#ff6600", 40]],
    "text": [["#222222", 3000], ["#828282", 800], ["#0969da", 300]],
    "accent": [["#ff6600", 50], ["#0969da", 30], ["#d1242f", 5]],
    "themeColor": None,
}

KEYS = [key for group in st.ORDER for key in group]


class Cluster(unittest.TestCase):
    def test_near_identical_colours_merge_under_the_heaviest(self):
        self.assertEqual(st.cluster([("#1b1b1b", 1), ("#1a1a1a", 5)]), [("#1a1a1a", 6)])

    def test_distinct_colours_stay_apart(self):
        self.assertEqual(len(st.cluster([("#ffffff", 1), ("#000000", 1)])), 2)


class Build(unittest.TestCase):
    def test_every_key_omarchy_expects(self):
        theme = st.build(PAGE)
        self.assertEqual(sorted(theme), sorted(KEYS))

    def test_the_page_decides_the_mode(self):
        self.assertEqual(st.build(PAGE)["mode"], "light")
        self.assertEqual(st.build(PAGE)["background"], "#ffffff")

    def test_the_brand_beats_the_links(self):
        # Link text outweighs the buttons in raw characters; only proportions
        # are comparable across kinds, and the buttons are the brand.
        _, _, hue = th.to_oklch(st.build(PAGE)["accent"])
        self.assertLess(st.hue_gap(hue, st.HUES["orange"]), 20)

    def test_a_page_colour_fills_one_slot_only(self):
        theme = st.build(PAGE, mode="dark")
        self.assertNotEqual(theme["red"], theme["orange"])

    def test_body_text_does_not_become_a_terminal_colour(self):
        # A dark page with peach body text: peach is "orange" by hue, and an
        # orange identical to plain text is useless in a terminal.
        page = {"bg": [["#030610", 1]], "text": [["#ffcead", 1]], "accent": [["#7d82d9", 1]]}
        theme = st.build(page)
        self.assertGreater(st.distance(theme["orange"], theme["foreground"]), 0.08)

    def test_everything_is_readable(self):
        for mode in (None, "dark", "light"):
            theme = st.build(PAGE, mode=mode)
            for key in ["foreground", "accent"] + list(st.HUES):
                self.assertGreaterEqual(
                    th.contrast(theme[key], theme["background"]), th.AA_NORMAL - 0.01,
                    f"{key} in {mode}")

    def test_flipping_to_dark_keeps_it_in_the_band_themes_live_in(self):
        theme = st.build(PAGE, mode="dark")
        lightness, _, _ = th.to_oklch(theme["background"])
        self.assertTrue(0.18 < lightness < 0.32, lightness)

    def test_a_grey_page_still_gets_a_coloured_accent(self):
        grey = {"bg": [["#ffffff", 1]], "text": [["#333333", 1]], "accent": [["#666666", 1]]}
        _, chroma, _ = th.to_oklch(st.build(grey)["accent"])
        self.assertGreater(chroma, st.CHROMATIC)

    def test_empty_samples_do_not_crash(self):
        self.assertEqual(sorted(st.build({})), sorted(KEYS))

    def test_theme_color_is_a_strong_hint(self):
        page = dict(PAGE, themeColor="#6f42c1")
        _, _, hue = th.to_oklch(st.build(page)["accent"])
        _, _, want = th.to_oklch("#6f42c1")
        self.assertLess(st.hue_gap(hue, want), 10)


class Overrides(unittest.TestCase):
    def test_a_chosen_accent_keeps_its_hue(self):
        theme = st.build(PAGE, overrides={"accent": "#6f42c1"})
        _, _, hue = th.to_oklch(theme["accent"])
        _, _, want = th.to_oklch("#6f42c1")
        self.assertLess(st.hue_gap(hue, want), 10)

    def test_a_chosen_colour_is_still_made_readable(self):
        theme = st.build(PAGE, overrides={"green": "#ccffcc"})
        self.assertGreaterEqual(th.contrast(theme["green"], theme["background"]), th.AA_NORMAL - 0.01)

    def test_the_background_decides_the_mode(self):
        theme = st.build(PAGE, overrides={"background": "#1e1e2e"})
        self.assertEqual(theme["mode"], "dark")
        self.assertGreaterEqual(th.contrast(theme["foreground"], "#1e1e2e"), th.AA_NORMAL - 0.01)

    def test_nonsense_is_ignored(self):
        self.assertEqual(st.build(PAGE, overrides={"accent": "red", "nope": "#000000"}), st.build(PAGE))


class PageColours(unittest.TestCase):
    def test_most_used_first_and_merged(self):
        colours = st.page_colours(PAGE)
        self.assertEqual(colours[0], "#ffffff")
        self.assertEqual(len(colours), len(set(colours)))


class Wallpaper(unittest.TestCase):
    def test_each_kind_is_a_png_of_the_asked_size(self):
        import struct
        import zlib

        theme = st.build(PAGE)
        for kind in st.GRADIENTS:
            data = st.wallpaper(theme, kind, width=32, height=18)
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n", kind)
            self.assertEqual(struct.unpack(">II", data[16:24]), (32, 18), kind)
            # Filter byte plus three bytes per pixel, per row.
            idat = data[data.index(b"IDAT") + 4:data.index(b"IEND") - 8]
            self.assertEqual(len(zlib.decompress(idat)), 18 * (1 + 32 * 3), kind)

    def test_solid_is_the_background(self):
        import zlib

        theme = st.build(PAGE, mode="dark")
        data = st.wallpaper(theme, "solid", width=4, height=2)
        idat = data[data.index(b"IDAT") + 4:data.index(b"IEND") - 8]
        pixel = zlib.decompress(idat)[1:4]
        self.assertEqual("#" + pixel.hex(), theme["background"])


class Toml(unittest.TestCase):
    def test_parses_and_round_trips(self):
        import tomllib

        theme = st.build(PAGE)
        parsed = tomllib.loads(st.to_toml(theme, "example"))
        self.assertEqual(parsed, theme)


if __name__ == "__main__":
    unittest.main()
