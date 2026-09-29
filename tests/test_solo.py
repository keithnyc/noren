import os
import tempfile
import unittest

import _load


class Solo(unittest.TestCase):
    """`noren solo` against a stand-in Hyprland: it may only ever dissolve the
    group of the window already in front, and never mid-gather."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cli = _load.cli()
        self.cli.GATHERING = os.path.join(self.tmp.name, "gathering")
        self.front = {"address": "0xa", "class": "chrome-example.com__-Default", "grouped": ["0xa"]}
        self.cli.hypr_json = lambda what: dict(self.front) if what == "activewindow" else None
        self.sent = []
        self.cli.hypr_do = self.sent.append

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_group_of_one_is_dissolved(self):
        self.cli.solo()
        self.assertEqual(self.sent, ["hl.dsp.group.toggle()"])

    def test_a_real_group_is_left_alone(self):
        self.front["grouped"] = ["0xa", "0xb"]
        self.cli.solo()
        self.assertEqual(self.sent, [])

    def test_never_anything_but_a_page_window(self):
        # The invariant: only chrome-* windows. Never keith's terminal.
        self.front["class"] = "Alacritty"
        self.cli.solo()
        self.assertEqual(self.sent, [])

    def test_waits_out_a_gather(self):
        # gather's anchor is a group of one until the first fold.
        with open(self.cli.GATHERING, "w"):
            pass
        self.cli.solo()
        self.assertEqual(self.sent, [])

    def test_focus_moving_before_the_dispatch_stops_it(self):
        reads = iter([dict(self.front), {"address": "0xb", "class": "Alacritty"}])
        self.cli.hypr_json = lambda what: next(reads)
        self.cli.solo()
        self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
