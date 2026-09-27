import json
import os
import stat
import tempfile
import unittest

import _load

PAGE = {
    "url": "https://example.com/article",
    "title": "An article",
    "icon": "data:image/png;base64,AAAA",
    "scroll": {"x": 0, "y": 1840, "ratio": 0.42},
    "fields": [{"sel": "#comment", "value": "half-written reply"}],
}


class Stash(unittest.TestCase):
    """Against a throwaway XDG_DATA_HOME: the real stash is never touched."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved_env = os.environ.get("XDG_DATA_HOME")
        os.environ["XDG_DATA_HOME"] = self.tmp.name
        # Loaded after the environment is set: the path is fixed at import.
        self.cli = _load.cli()
        self.assertTrue(self.cli.STASH_FILE.startswith(self.tmp.name))

    def tearDown(self):
        if self.saved_env is None:
            os.environ.pop("XDG_DATA_HOME", None)
        else:
            os.environ["XDG_DATA_HOME"] = self.saved_env
        self.tmp.cleanup()

    def entry(self, **changes):
        return self.cli.stash_entry({**PAGE, **changes})

    def test_round_trip(self):
        first = self.entry()
        self.cli.save_stash([first])
        self.assertEqual(self.cli.load_stash(), [first])

    def test_the_file_is_private(self):
        self.cli.save_stash([self.entry()])
        mode = stat.S_IMODE(os.stat(self.cli.STASH_FILE).st_mode)
        self.assertEqual(mode, 0o600)

    def test_the_file_has_the_contract_shape(self):
        self.cli.save_stash([self.entry()])
        with open(self.cli.STASH_FILE) as fh:
            data = json.load(fh)
        self.assertEqual(data["version"], 1)
        self.assertEqual(sorted(data["items"][0]),
                         ["fields", "icon", "id", "scroll", "stashedAt", "title", "url"])

    def test_missing_file_is_empty(self):
        self.assertEqual(self.cli.load_stash(), [])

    def test_corrupt_file_is_empty(self):
        os.makedirs(os.path.dirname(self.cli.STASH_FILE), exist_ok=True)
        for text in ("{not json", "[]", '{"items": 3}', '{"items": ["x", {"id": "bad"}]}'):
            with open(self.cli.STASH_FILE, "w") as fh:
                fh.write(text)
            self.assertEqual(self.cli.load_stash(), [], text)

    def test_newest_first(self):
        a = self.entry(url="https://example.com/a")
        b = self.entry(url="https://example.com/b")
        items = self.cli.stash_upsert(self.cli.stash_upsert([], a), b)
        self.assertEqual([i["url"] for i in items],
                         ["https://example.com/b", "https://example.com/a"])

    def test_the_same_url_again_replaces_and_moves_to_the_top(self):
        a = self.entry(url="https://example.com/a", title="old")
        b = self.entry(url="https://example.com/b")
        again = self.entry(url="https://example.com/a", title="new")
        items = self.cli.stash_upsert([b, a], again)
        self.assertEqual([i["title"] for i in items], ["new", PAGE["title"]])
        self.assertEqual(len(items), 2)

    def test_drop(self):
        a, b = self.entry(url="https://example.com/a"), self.entry(url="https://example.com/b")
        kept, gone = self.cli.stash_remove([a, b], a["id"])
        self.assertEqual(kept, [b])
        self.assertEqual(gone, a)
        kept, gone = self.cli.stash_remove([b], "s_000000000000")
        self.assertEqual((kept, gone), ([b], None))

    def test_ids(self):
        entry = self.entry()
        self.assertRegex(entry["id"], r"^s_[0-9a-f]{12}$")
        self.assertNotEqual(entry["id"], self.entry()["id"])
        for bad in ("", "s_", "s_ABCDEF123456", "s_0123456789abc", "x_0123456789ab",
                    "--replace", "s_0123456789ab\n"):
            self.assertIsNone(self.cli.STASH_ID.fullmatch(bad), repr(bad))

    def test_an_entry_with_a_bad_id_is_not_loaded(self):
        good = self.entry()
        bad = {**self.entry(), "id": "--replace"}
        self.cli.save_stash([good, bad])
        self.assertEqual([i["id"] for i in self.cli.load_stash()], [good["id"]])

    def test_only_web_pages(self):
        for url in ("", "file:///etc/passwd", "javascript:alert(1)", "chrome://settings"):
            self.assertIsNone(self.entry(url=url), url)

    def test_a_large_icon_is_dropped(self):
        big = "data:image/png;base64," + "A" * (16 * 1024)
        self.assertEqual(self.entry(icon=big)["icon"], "")
        self.assertEqual(self.entry(icon="https://example.com/favicon.ico")["icon"], "")

    def test_fields_are_capped_by_count(self):
        fields = [{"sel": f"#f{i}", "value": "x"} for i in range(80)]
        self.assertEqual(len(self.entry(fields=fields)["fields"]), 50)

    def test_fields_are_capped_by_characters(self):
        fields = [{"sel": f"#f{i}", "value": "x" * 7000} for i in range(5)]
        kept = self.entry(fields=fields)["fields"]
        self.assertEqual(len(kept), 2)
        self.assertLessEqual(sum(len(f["value"]) for f in kept), 20000)

    def test_empty_and_malformed_fields_are_dropped(self):
        fields = [{"sel": "#a", "value": ""}, {"sel": "", "value": "x"}, "junk",
                  {"sel": "#b", "value": 3}, {"sel": "#c", "value": "kept"}]
        self.assertEqual(self.entry(fields=fields)["fields"], [{"sel": "#c", "value": "kept"}])

    def test_scroll_is_numbers(self):
        scroll = self.entry(scroll={"x": "nan", "y": None, "ratio": 7})["scroll"]
        self.assertEqual(scroll, {"x": 0, "y": 0, "ratio": 1})

    def test_the_summary_never_carries_field_values(self):
        summary = self.cli.stash_summary(self.entry())
        self.assertEqual(sorted(summary),
                         ["hasFields", "icon", "id", "stashedAt", "title", "url"])
        self.assertTrue(summary["hasFields"])
        self.assertNotIn("half-written", json.dumps(summary))


class HostReadsWhatTheCliWrites(unittest.TestCase):
    """The host reads the stash for the bar; the CLI writes it. They must agree
    on the file and on the summary, or the bar's list is silently empty."""

    def test_same_summary(self):
        import importlib.machinery
        import importlib.util

        with tempfile.TemporaryDirectory() as tmp:
            saved = os.environ.get("XDG_DATA_HOME")
            os.environ["XDG_DATA_HOME"] = tmp
            try:
                cli = _load.cli()
                path = str(_load.ROOT / "host" / "noren-host")
                loader = importlib.machinery.SourceFileLoader("noren_host", path)
                spec = importlib.util.spec_from_loader("noren_host", loader)
                host = importlib.util.module_from_spec(spec)
                loader.exec_module(host)

                entries = [cli.stash_entry({**PAGE, "url": f"https://example.com/{n}"})
                           for n in range(3)]
                cli.save_stash(entries)
                self.assertEqual(host.STASH_FILE, cli.STASH_FILE)
                self.assertEqual(host.read_stash(), [cli.stash_summary(e) for e in entries])
            finally:
                if saved is None:
                    os.environ.pop("XDG_DATA_HOME", None)
                else:
                    os.environ["XDG_DATA_HOME"] = saved


if __name__ == "__main__":
    unittest.main()
