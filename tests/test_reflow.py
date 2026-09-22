import unittest

from _load import NODE, js_function, run_js


@unittest.skipUnless(NODE, "node not installed")
class Reflow(unittest.TestCase):
    """The agent's answer card: hard wraps joined, paragraphs kept."""

    def reflow(self, *texts):
        return run_js(js_function("AgentPanel.qml", "reflow"), "reflow", list(texts))

    def test_joins_hard_wraps_and_keeps_paragraphs(self):
        got, = self.reflow("one line\nwrapped here\n\nsecond para\nalso wrapped")
        self.assertEqual(got, "one line wrapped here\n\nsecond para also wrapped")

    def test_drops_carriage_returns(self):
        got, = self.reflow("windows\r\nline ends\r\n\r\nkept")
        self.assertEqual(got, "windows line ends\n\nkept")

    def test_trims_and_tolerates_nothing(self):
        self.assertEqual(self.reflow("\n\n  text  \n", "", None), ["text", "", ""])


if __name__ == "__main__":
    unittest.main()
