import json
import os
import re
import subprocess
import tempfile
import unittest

import _load


class EnterReplaces(unittest.TestCase):
    """`noren enter replace` swaps the url bar's two keys; it never guesses."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_cli(self, *args):
        env = dict(os.environ, XDG_CONFIG_HOME=self.tmp.name, XDG_RUNTIME_DIR=self.tmp.name)
        return subprocess.run([str(_load.ROOT / "bin" / "noren"), "enter", *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_new_window_by_default_and_replace_is_written_down(self):
        self.assertEqual(self.run_cli().stdout.strip(), "enter new")
        self.assertEqual(self.run_cli("replace").stdout.strip(), "enter replace")
        with open(os.path.join(self.tmp.name, "noren", "config.json")) as fh:
            self.assertIs(json.load(fh)["enter_replaces"], True)
        self.assertEqual(self.run_cli("new").stdout.strip(), "enter new")

    def test_a_bad_argument_changes_nothing(self):
        self.assertNotEqual(self.run_cli("sometimes").returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "noren", "config.json")))

    def test_the_start_page_switch_goes_through_the_cli(self):
        make = _load.host().PREF_COMMANDS["enterReplaces"]
        self.assertEqual(make(True), ["enter", "replace"])
        self.assertEqual(make(False), ["enter", "new"])

    def test_the_footer_never_hardcodes_a_key(self):
        # Every key in the footer comes from openKey / replaceKey, or the
        # setting would leave it promising the wrong thing.
        qml = (_load.ROOT / "UrlBar.qml").read_text()
        start = qml.index("Always visible, so the two outcomes")
        footer = qml[start:qml.index("elide: Text.ElideRight", start)]
        self.assertEqual(re.findall(r"Ctrl\+\\u21B5|\^\\u21B5", footer), [])


if __name__ == "__main__":
    unittest.main()
