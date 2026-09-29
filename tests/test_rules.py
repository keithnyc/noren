import os
import tempfile
import unittest
from unittest import mock

import _load


class Rules(unittest.TestCase):
    """Against a throwaway config and hypr dir: the real ones are never touched,
    and Hyprland is never reloaded."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cli = _load.cli()
        c = self.cli
        c.RULES_FILE = os.path.join(self.tmp.name, "noren", "rules.json")
        c.HYPR_DIR = os.path.join(self.tmp.name, "hypr")
        c.RULES_LUA = os.path.join(c.HYPR_DIR, "noren-rules.lua")
        c.HYPR_MAIN = os.path.join(c.HYPR_DIR, "hyprland.lua")
        os.makedirs(c.HYPR_DIR)
        with open(c.HYPR_MAIN, "w") as fh:
            fh.write('require("default.hypr.omarchy")\n')
        self.reloads = []
        real = c.subprocess.run
        patcher = mock.patch.object(
            c.subprocess, "run",
            lambda cmd, **kw: self.reloads.append(cmd) if cmd[0] == "hyprctl" else real(cmd, **kw))
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, path):
        with open(path) as fh:
            return fh.read()

    def test_a_rule_becomes_one_hyprland_rule(self):
        rule = self.cli.clean_rule({"when": "site", "site": "https://www.Example.com/path",
                                    "then": {"opacity": 0.9, "border": "#FF3355", "rounding": 12}})
        self.assertEqual(rule["site"], "example.com")
        self.assertEqual(self.cli.rule_lua(rule),
                         'hl.window_rule({ match = { tag = "noren:site:example.com" }, '
                         'opacity = 0.90, border_color = "rgba(ff3355ff) rgba(ff3355cc)", rounding = 12 })')

    def test_values_are_clamped_and_junk_is_dropped(self):
        rule = self.cli.clean_rule({"when": "typing", "then": {
            "opacity": 0.01, "border_size": 99, "rounding": -5, "border": "red",
            "dim_around": "yes", "float": True, "shell": "rm -rf ~"}})
        self.assertEqual(rule["then"], {"opacity": 0.2, "border_size": 10, "rounding": 0, "float": True})

    def test_nothing_a_page_or_a_person_types_reaches_lua_as_code(self):
        # A hostname is chosen by the page; a colour or a condition by whoever
        # edits rules.json. None of it may become code.
        hostile = [
            {"when": "site", "site": 'example.com" }) hl.exec_cmd("rm -rf ~") --', "then": {"opacity": 0.5}},
            {"when": 'typing" }) hl.exec_cmd("x") --', "then": {"opacity": 0.5}},
            {"when": "login", "then": {"border": '#ff0000") hl.exec_cmd("x'}},
            {"when": "login", "then": {"opacity": "0.5) hl.exec_cmd('x'"}},
        ]
        for raw in hostile:
            rule = self.cli.clean_rule(raw)
            lua = self.cli.rule_lua(rule) if rule else ""
            self.assertNotIn("exec_cmd", lua, raw)

    def test_saving_writes_both_files_and_reloads_once(self):
        rules, block = self.cli.save_rules([
            {"when": "typing", "then": {"border": "#ffb000"}},
            {"when": "login", "on": False, "then": {"border": "#ff3355"}},
        ])
        self.assertEqual(block, "added")
        lua = self.read(self.cli.RULES_LUA)
        self.assertIn('tag = "noren:typing"', lua)
        self.assertNotIn("noren:login", lua)          # switched off
        self.assertEqual(self.reloads, [["hyprctl", "reload", "config-only"]])
        self.assertEqual(len(self.cli.load_rules()), 2)

    def test_the_loader_block_goes_in_once_with_a_backup(self):
        self.cli.save_rules([])
        self.cli.save_rules([])
        main = self.read(self.cli.HYPR_MAIN)
        self.assertEqual(main.count(self.cli.BLOCK_BEGIN), 1)
        self.assertTrue(main.startswith('require("default.hypr.omarchy")'))
        self.assertIn("pcall(dofile, path)", main)   # a broken rules file cannot break the config
        backups = [f for f in os.listdir(self.cli.HYPR_DIR) if f.startswith("hyprland.lua.bak.")]
        self.assertEqual(len(backups), 1)

    def test_float_is_left_to_the_host(self):
        rule = self.cli.clean_rule({"when": "site", "site": "example.com", "then": {"float": True}})
        self.assertTrue(self.cli.rule_lua(rule).startswith("-- float:"))

    def test_the_command_line_form(self):
        rule = self.cli.parse_rule_args(["site:example.com", "opacity=0.9", "float", "border=#00ff00"])
        self.assertEqual(rule["when"], "site")
        self.assertEqual(rule["then"], {"opacity": 0.9, "border": "#00ff00", "float": True})
        self.assertIsNone(self.cli.parse_rule_args(["nonsense"]))


if __name__ == "__main__":
    unittest.main()
