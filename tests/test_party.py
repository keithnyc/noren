import json
import os
import subprocess
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

    def test_unfocused_video_lights_nothing_without_the_background_setting(self):
        self.hypr.front = {"address": "0xdef", "class": "Alacritty", "title": "Terminal"}
        self.frame()
        self.assertEqual(self.hypr.sent, [])
        self.assertFalse(os.path.exists(self.host.PARTY_FILE))

    def test_background_keeps_the_bar_but_never_the_window_colours(self):
        # There is no per-window shadow colour, and the inactive colours are
        # every other window's: behind other windows, only the bar lights.
        self.host.read_config = lambda: {"party": True, "party_background": True}
        self.hypr.front = {"address": "0xdef", "class": "Alacritty", "title": "Terminal"}
        self.frame(energy=0.7)
        self.assertEqual(self.hypr.sent, [])
        self.assertTrue(self.party()["lit"])

    def test_focus_leaving_in_background_mode_keeps_the_bar(self):
        self.host.read_config = lambda: {"party": True, "party_background": True}
        self.frame()
        self.assertIsNotNone(self.host._glow)
        self.host.glow_focus("0xother")
        self.assertIsNone(self.host._glow)                       # window colours back
        self.assertIn("angle = 45", self.hypr.sent[-1])
        self.assertTrue(self.party()["lit"])                     # bar still going

    def test_one_video_runs_the_lights(self):
        self.host.read_config = lambda: {"party": True, "party_background": True}
        self.hypr.front = {"address": "0xdef", "class": "Alacritty", "title": "Terminal"}
        self.frame()
        self.host.glow_frame({"rgb": [0, 255, 0], "level": 0.5, "title": "Another video"})
        self.assertEqual(self.party()["rgb"], [200, 40, 120])
        # ...and the other one pausing does not put this one's show out.
        self.host.glow_restore("Another video")
        self.assertTrue(self.party()["lit"])
        self.host.glow_restore("A video")
        self.assertEqual(self.party(), {"lit": False})

    def test_the_video_in_front_takes_the_lights(self):
        self.host.read_config = lambda: {"party": True, "party_background": True}
        self.hypr.front = {"address": "0xdef", "class": "Alacritty", "title": "Terminal"}
        self.host.glow_frame({"rgb": [0, 255, 0], "level": 0.5, "title": "Another video"})
        self.hypr.front = self.page
        self.frame()
        self.assertEqual(self.party()["rgb"], [200, 40, 120])
        self.assertIsNotNone(self.host._glow)

    def test_after_lighting_only_the_two_colours_are_sent(self):
        # Every hl.config runs on the compositor's thread, where the cursor is
        # drawn. Measured on 0.56.2: the colours cost ~0.75 ms each and the
        # group border ~20 ms. Thirty full updates a second stalled the desktop.
        self.frame()
        self.assertIn("range = 20", self.hypr.sent[-1])        # the statics, once
        self.assertNotIn("border_active", self.hypr.sent[-1])  # not in a group
        self.host._glow["at"] = 0                               # let the next one through
        self.host.glow_frame({"rgb": [20, 200, 90], "level": 0.5, "title": "A video"})
        per_frame = self.hypr.sent[-1]
        self.assertIn("active_border", per_frame)
        self.assertIn("shadow = { color", per_frame)
        for static in ("range", "render_power", "enabled", "color_inactive", "border_active"):
            self.assertNotIn(static, per_frame)

    def test_hyprland_hears_about_the_colour_at_most_fifteen_times_a_second(self):
        self.frame()
        before = len(self.hypr.sent)
        for i in range(10):                                     # a burst, all at once
            self.host.glow_frame({"rgb": [10 * i, 200, 90], "level": 0.5, "title": "A video"})
        configs = [c for c in self.hypr.sent[before:] if c.startswith("eval")]
        self.assertLessEqual(len(configs), 1)

    def test_a_grouped_window_gets_its_group_border_once(self):
        self.hypr.front = {**self.page, "grouped": ["0xabc", "0xdef"]}
        self.frame()
        self.assertIn("border_active", self.hypr.sent[-1])
        self.host._glow["at"] = 0
        self.host.glow_frame({"rgb": [20, 200, 90], "level": 0.5, "title": "A video"})
        self.assertNotIn("border_active", self.hypr.sent[-1])
        self.host.glow_restore()
        self.assertIn("border_active", self.hypr.sent[-1])     # and put back

    def test_off_in_the_config_means_nothing_is_touched(self):
        self.host.read_config = lambda: {}
        self.frame()
        self.assertEqual(self.hypr.sent, [])


class Shake(unittest.TestCase):
    """The bar's shake is on unless turned off; the shell reads the file."""

    def run_cli(self, *args):
        env = dict(os.environ, XDG_CONFIG_HOME=self.tmp.name,
                   XDG_RUNTIME_DIR=self.tmp.name)
        return subprocess.run([str(_load.ROOT / "bin" / "noren"), "party", "shake", *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_on_by_default_and_off_is_written_down(self):
        self.assertEqual(self.run_cli().stdout.strip(), "party shake on")
        self.assertEqual(self.run_cli("off").stdout.strip(), "party shake off")
        with open(os.path.join(self.tmp.name, "noren", "config.json")) as fh:
            self.assertIs(json.load(fh)["party_shake"], False)
        self.assertEqual(self.run_cli("on").stdout.strip(), "party shake on")

    def test_a_bad_argument_changes_nothing(self):
        self.assertNotEqual(self.run_cli("loud").returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "noren", "config.json")))

    def test_the_start_page_switch_goes_through_the_cli(self):
        make = _load.host().PREF_COMMANDS["partyShake"]
        self.assertEqual(make(False), ["party", "shake", "off"])


if __name__ == "__main__":
    unittest.main()
