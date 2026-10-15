import subprocess
import unittest
from unittest import mock

import _load


def answers(table):
    """Stand-in for subprocess.run: each command's stdout from `table`."""
    def run(command, **kwargs):
        out = table.get(command[0] if command[0] != "env" else "xdg-settings")
        if out is None:
            raise FileNotFoundError(command[0])
        return subprocess.CompletedProcess(command, 0, stdout=out + "\n", stderr="")
    return run


class DefaultBrowser(unittest.TestCase):
    """Omarchy's link router is the system default now; it is never the browser."""

    def check(self, module, table, expect):
        with mock.patch.object(module.subprocess, "run", answers(table)):
            self.assertEqual(module.default_browser_desktop(), expect)

    def test_omarchy_answer_wins(self):
        for module in (_load.cli(), _load.host()):
            self.check(module, {"omarchy-cmd-default-browser": "chromium.desktop",
                                "xdg-settings": "omarchy-browser.desktop"}, "chromium.desktop")

    def test_the_router_is_skipped(self):
        for module in (_load.cli(), _load.host()):
            self.check(module, {"xdg-settings": "omarchy-browser.desktop",
                                "xdg-mime": "brave-browser.desktop"}, "brave-browser.desktop")

    def test_older_omarchy_still_asks_xdg_settings(self):
        for module in (_load.cli(), _load.host()):
            self.check(module, {"xdg-settings": "chromium.desktop"}, "chromium.desktop")

    def test_nothing_but_the_router_is_no_answer(self):
        cli = _load.cli()
        with mock.patch.object(cli.subprocess, "run", answers({"xdg-settings": "omarchy-browser.desktop"})):
            self.assertEqual(cli.default_browser(), "your browser")


if __name__ == "__main__":
    unittest.main()
