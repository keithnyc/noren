import unittest
from unittest import mock

import _load

MONITOR = {"id": 0, "width": 3840, "height": 2160, "scale": 1.875, "reserved": [0, 26, 0, 0]}


class FloatPage(unittest.TestCase):
    """`noren float-page` against a stand-in Hyprland."""

    def setUp(self):
        self.cli = _load.cli()
        patcher = mock.patch.object(self.cli.time, "sleep", lambda s: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.sent = []
        self.cli.hypr_do = self.sent.append
        self.win = {"address": "0xa", "class": "chrome-example.com__-Default", "floating": False,
                    "grouped": [], "monitor": 0}
        self.front = {"address": "0xa"}
        self.cli.hypr_json = self.answer

    def answer(self, what):
        if what == "clients":
            return [self.win]
        if what == "monitors":
            return [MONITOR]
        if what == "activewindow":
            return dict(self.front)
        return None

    def test_floats_sizes_and_centres_by_address(self):
        self.assertEqual(self.cli.float_page("0xa"), "floated")
        self.assertEqual(self.sent, [
            'hl.dsp.window.float({ window = "address:0xa", action = "toggle" })',
            'hl.dsp.window.resize({ window = "address:0xa", x = 1228, y = 731 })',
            'hl.dsp.window.center({ window = "address:0xa" })',
        ])

    def test_a_grouped_window_leaves_its_group_first(self):
        # Floating a grouped window floats the whole group.
        self.win["grouped"] = ["0xa", "0xb"]
        self.front = {"address": "0xa", "grouped": ["0xa"]}   # out, once asked
        self.assertEqual(self.cli.float_page("0xa"), "floated")
        self.assertEqual(self.sent[0], "hl.dsp.window.move({ out_of_group = true })")
        self.assertIn("window.float", self.sent[1])

    def test_a_grouped_window_not_in_front_waits_instead_of_taking_focus(self):
        self.win["grouped"] = ["0xa", "0xb"]
        self.front = {"address": "0xb", "grouped": ["0xa", "0xb"]}
        self.assertEqual(self.cli.float_page("0xa"), "wait")
        self.assertEqual(self.sent, [])

    def test_never_floats_while_still_grouped(self):
        self.win["grouped"] = ["0xa", "0xb"]
        self.front = {"address": "0xa", "grouped": ["0xa", "0xb"]}   # the move did not take
        self.assertEqual(self.cli.float_page("0xa"), "no")
        self.assertEqual(self.sent, ["hl.dsp.window.move({ out_of_group = true })"])

    def test_only_page_windows(self):
        self.win["class"] = "Alacritty"
        self.assertEqual(self.cli.float_page("0xa"), "no")
        self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
