import json
import os
import unittest

import _load


class Hyprland:
    """A stand-in for Hyprland's socket: clients in, dispatches recorded."""

    def __init__(self, clients):
        self.clients = clients
        self.sent = []

    def __call__(self, command, timeout=1.0):
        if command == "j/clients":
            return json.dumps(self.clients)
        self.sent.append(command)
        return "ok"


def page(address, title, tags=(), cls="chrome-example.com__-Default"):
    return {"address": address, "class": cls, "title": title, "tags": list(tags)}


class Tags(unittest.TestCase):

    def setUp(self):
        self.host = _load.host()

    def run_with(self, clients, report):
        hypr = Hyprland(clients)
        self.host.hypr_request = hypr
        self.host.set_tag_report(report)
        return hypr.sent

    def test_adds_what_is_missing_and_removes_what_is_stale(self):
        sent = self.run_with(
            [page("0xa", "A video", ["noren:page", "noren:loading"])],
            [{"title": "A video", "tags": ["noren:page", "noren:playing"]}])
        self.assertEqual(sent, [
            'dispatch hl.dsp.window.tag({ tag = "-noren:loading", window = "address:0xa" })',
            'dispatch hl.dsp.window.tag({ tag = "+noren:playing", window = "address:0xa" })',
        ])

    def test_never_touches_a_tag_that_is_not_ours(self):
        sent = self.run_with(
            [page("0xa", "Docs", ["noren:page", "default-opacity", "terminal"])],
            [{"title": "Docs", "tags": ["noren:page"]}])
        self.assertEqual(sent, [])

    def test_never_touches_a_window_that_is_not_a_page(self):
        # The invariant: only chrome-* windows. The browser's own tabbed window
        # shares a title with its active tab, and keith's terminal is right there.
        sent = self.run_with(
            [page("0xa", "Docs", cls="chromium"), page("0xb", "Docs", cls="Alacritty")],
            [{"title": "Docs", "tags": ["noren:page", "noren:typing"]}])
        self.assertEqual(sent, [])

    def test_a_hostile_hostname_cannot_become_code(self):
        # A page picks its own hostname; the tag goes inside a Lua string.
        hostile = [
            'noren:site:x"}) hl.exec_cmd("rm -rf ~") --',
            "noren:site:a\\\\b",
            "noren:site:UPPER.example.com",
            "noren:site:[::1]",
            "other:tag",
            "noren:" + "a" * 200,
        ]
        sent = self.run_with([page("0xa", "Page")],
                             [{"title": "Page", "tags": hostile}])
        self.assertEqual(sent, ['dispatch hl.dsp.window.tag({ tag = "+noren:page", window = "address:0xa" })'])

    def test_a_bad_address_is_never_dispatched_to(self):
        sent = self.run_with([page('0xa" }) --', "Page")],
                             [{"title": "Page", "tags": ["noren:page"]}])
        self.assertEqual(sent, [])

    def test_mid_navigation_the_tags_are_left_alone(self):
        # Hyprland already has the new title, the report still the old one:
        # dropping everything would flicker every rule that matches.
        sent = self.run_with(
            [page("0xa", "New title", ["noren:page", "noren:site:example.com"])],
            [{"title": "Old title", "tags": ["noren:page"]}])
        self.assertEqual(sent, [])

    def test_theatre_darkens_the_dim_and_puts_it_back(self):
        hypr = Hyprland([page("0xa", "A video")])
        hypr_calls = hypr

        def request(command, timeout=1.0):
            if command == "j/getoption decoration:dim_around":
                return json.dumps({"option": "decoration:dim_around", "float": 0.4})
            return hypr_calls(command, timeout)

        self.host.hypr_request = request
        self.host.set_tag_report([{"title": "A video", "tags": ["noren:page", "noren:theatre"]}])
        self.assertIn("eval hl.config({ decoration = { dim_around = 0.800 } })", hypr.sent)
        hypr.clients = [page("0xa", "A video", ["noren:page", "noren:theatre"])]
        self.host.set_tag_report([{"title": "A video", "tags": ["noren:page"]}])
        self.assertEqual(hypr.sent[-1], "eval hl.config({ decoration = { dim_around = 0.400 } })")
        self.assertIsNone(self.host._theatre_saved)

    def test_a_float_rule_hands_the_window_to_the_cli_once(self):
        import tempfile
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.host.RULES_FILE = os.path.join(tmp.name, "rules.json")
        with open(self.host.RULES_FILE, "w") as fh:
            json.dump({"rules": [{"id": "r_00000001", "on": True, "when": "site",
                                  "site": "example.com", "then": {"float": True}}]}, fh)
        floated = []
        self.host.float_page = floated.append
        from unittest import mock
        inline = mock.patch.object(self.host.threading, "Thread", lambda target, args, daemon: type(
            "T", (), {"start": lambda self_: target(*args)})())
        inline.start()
        self.addCleanup(inline.stop)
        self.run_with([dict(page("0xa", "A video"), floating=False)],
                      [{"title": "A video", "tags": ["noren:page", "noren:site:example.com"]}])
        self.assertEqual(floated, ["0xa"])
        # Already carrying the tag: not floated again.
        self.run_with([dict(page("0xa", "A video", ["noren:page", "noren:site:example.com"]), floating=False)],
                      [{"title": "A video", "tags": ["noren:page", "noren:site:example.com"]}])
        self.assertEqual(floated, ["0xa"])

    def test_the_report_is_all_booleans_and_hostnames_from_the_page_side(self):
        # signals.js reports three booleans and nothing else; the worker adds
        # only the host name. No typed text can reach a tag.
        src = (_load.ROOT / "extension" / "signals.js").read_text()
        self.assertIn("return { playing, login, typing: edited.size > 0 };", src)


if __name__ == "__main__":
    unittest.main()
