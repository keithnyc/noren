import json
import os
import tempfile
import unittest

import _load


class Hyprland:
    """Stands in for Hyprland's request socket: options by name, and a log of
    every hl.config the host sends. The real compositor is never touched."""

    def __init__(self, front):
        self.front = front
        self.options = {
            "general:col.active_border": {"gradient": "eef2fcff ee6fb8e3 45deg"},
            "group:col.border_active": {"gradient": "ff89b4fa 0deg"},
            "decoration:shadow:enabled": {"bool": False},
            "decoration:shadow:color": {"gradient": "886fb8e3 0deg"},
            "decoration:shadow:color_inactive": {"gradient": "ffffffff 0deg", "set": False},
            "decoration:shadow:range": {"int": 13},
            "decoration:shadow:render_power": {"int": 3},
        }
        self.sent = []

    def __call__(self, command, timeout=1.0):
        if command == "j/activewindow":
            return json.dumps(self.front)
        if command.startswith("j/getoption "):
            name = command.split(" ", 1)[1]
            return json.dumps({"option": name, "set": True, **self.options[name]})
        self.sent.append(command)
        return "ok"


class Party(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.host = _load.host()
        self.host.PARTY_FILE = os.path.join(self.tmp.name, "party.json")
        self.host.read_config = lambda: {"party": True}
        self.page = {"address": "0xabc", "class": "chrome-example.com__-Default",
                     "title": "A video"}
        self.hypr = Hyprland(self.page)
        self.host.hypr_request = self.hypr

    def tearDown(self):
        self.host._glow = None
        self.tmp.cleanup()

    def frame(self, **extra):
        self.host.glow_frame({"rgb": [200, 40, 120], "level": 0.5, "title": "A video", **extra})

    def party(self):
        with open(self.host.PARTY_FILE) as fh:
            return json.load(fh)

    def test_gradients_are_read_back_the_way_hl_config_takes_them(self):
        # Hyprland reports AARRGGBB words and an angle; hl.config takes rgba()
        # and a table. Getting this wrong loses the theme's gradient for good.
        self.assertEqual(self.host._hypr_option_lua("general:col.active_border"),
                         '{ colors = { "rgba(f2fcffee)", "rgba(6fb8e3ee)" }, angle = 45 }')
        self.assertEqual(self.host._hypr_option_lua("decoration:shadow:range"), "13")
        self.assertEqual(self.host._hypr_option_lua("decoration:shadow:enabled"), "false")

    def test_one_nested_table_never_a_repeated_key(self):
        # `{ decoration = A, decoration = B }` is legal Lua and keeps only B:
        # that silently dropped the shadow colour. And `col.active_border` is
        # two levels, not one key with a dot in it.
        self.host._glow_apply({"general:col.active_border": '"x"',
                               "decoration:shadow:color": '"y"',
                               "decoration:shadow:range": "20"})
        code = self.hypr.sent[-1]
        self.assertEqual(code.count("decoration ="), 1)
        self.assertIn("col = { active_border = \"x\" }", code)
        self.assertIn("shadow = { color = \"y\", range = 20 }", code)

    def test_lights_the_page_and_puts_everything_back(self):
        self.frame()
        lit = self.hypr.sent[-1]
        self.assertIn('active_border = "rgba(c82878ee)"', lit)
        self.assertIn("enabled = true", lit)
        # Shadows were off, so every other window keeps having none.
        self.assertIn('color_inactive = "rgba(00000000)"', lit)
        self.assertTrue(self.party()["lit"])

        self.host.glow_restore()
        back = self.hypr.sent[-1]
        self.assertIn('{ colors = { "rgba(f2fcffee)", "rgba(6fb8e3ee)" }, angle = 45 }', back)
        self.assertIn("enabled = false", back)
        self.assertIn("range = 13", back)
        self.assertEqual(self.party(), {"lit": False})

    def test_never_paints_a_window_that_is_not_a_noren_page(self):
        self.hypr.front = {"address": "0xdef", "class": "Alacritty", "title": "A video"}
        self.frame()
        self.assertEqual(self.hypr.sent, [])

    def test_a_frame_in_flight_does_not_paint_the_next_window(self):
        # Focus moved to another page while this frame was on its way.
        self.hypr.front = {**self.page, "title": "Something else"}
        self.frame()
        self.assertEqual(self.hypr.sent, [])

    def test_focus_moving_away_puts_it_back(self):
        self.frame()
        self.host.glow_focus("0xother")
        self.assertIsNone(self.host._glow)
        self.assertEqual(self.party(), {"lit": False})

    def test_beats_and_cuts_are_counted_for_the_bar(self):
        self.frame()
        self.frame(beat=True, energy=0.8)
        self.frame(beat=True, cut=True, energy=0.6)
        state = self.party()
        self.assertEqual(state["energy"], 0.6)
        self.assertEqual(state["beats"] - self.host._party_beats, 0)
        self.assertGreaterEqual(state["beats"], 2)
        self.assertGreaterEqual(state["cuts"], 1)

    def test_off_in_the_config_means_nothing_is_touched(self):
        self.host.read_config = lambda: {}
        self.frame()
        self.assertEqual(self.hypr.sent, [])


if __name__ == "__main__":
    unittest.main()
