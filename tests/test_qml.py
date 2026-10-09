import re
import unittest

import _load


class ThemeColours(unittest.TestCase):

    def test_no_bare_color_singleton(self):
        # Qt 6.12's QtQuick has a `Color` singleton of its own, and it wins
        # over Omarchy's: a bare `Color.menu` is undefined and the url bar's
        # scrim drew as a black box. Always `Commons.Color`.
        bare = re.compile(r"(?<![\w.])Color\.[a-z]")
        found = []
        for path in sorted(_load.ROOT.glob("*.qml")):
            for n, line in enumerate(path.read_text().splitlines(), 1):
                if bare.search(line.split("//")[0]):
                    found.append(f"{path.name}:{n}")
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
