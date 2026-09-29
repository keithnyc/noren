import unittest

import _load


@unittest.skipUnless(_load.NODE, "node is not installed")
class ShortTitle(unittest.TestCase):
    """bar.js's shortTitle, the real function under node. A page window's title
    is its tab in a Hyprland group, and the group bar clips a long one at both
    ends."""

    def short(self, titles):
        src = "const TITLE_MAX = 64;\n" + _load.js_function("extension/bar.js", "shortTitle")
        return _load.run_js(src, "shortTitle", titles)

    def test_a_long_title_keeps_its_site(self):
        post = 'Someone on Example: "' + "a very long post about a theme " * 4 + '" / Example'
        [out] = self.short([post])
        self.assertLessEqual(len(out), 64)
        self.assertTrue(out.endswith("… / Example"), out)
        self.assertTrue(out.startswith("Someone on Example:"))

    def test_short_titles_are_left_alone(self):
        titles = ["Short title", "A video - Example Tube", "x" * 64]
        self.assertEqual(self.short(titles), titles)

    def test_cut_at_a_word_not_mid_word(self):
        [out] = self.short(["word " * 30])
        self.assertTrue(out.endswith("word…"), out)

    def test_dashes_inside_a_title_are_not_its_site(self):
        [out] = self.short(["Release notes - version 2 - what changed in the new build, "
                            "and the long list of fixes that came with it"])
        self.assertTrue(out.startswith("Release notes - version 2"))
        self.assertTrue(out.endswith("…"))


if __name__ == "__main__":
    unittest.main()
