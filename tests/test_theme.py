import unittest

import noren_theme as th

# catppuccin-latte: the docstring's own example of a palette colour that fails
# AA against its theme's background (2.96:1).
LATTE_BG = "#eff1f5"
LATTE_GREEN = "#40a02b"


class SolveContrast(unittest.TestCase):
    def test_passing_colour_is_returned_untouched(self):
        self.assertEqual(th.solve_contrast("#000000", LATTE_BG), "#000000")

    def test_failing_colour_is_lifted_to_aa(self):
        self.assertLess(th.contrast(LATTE_GREEN, LATTE_BG), th.AA_NORMAL)
        fixed = th.solve_contrast(LATTE_GREEN, LATTE_BG)
        self.assertGreaterEqual(th.contrast(fixed, LATTE_BG), th.AA_NORMAL)

    def test_moves_only_as_far_as_it_must(self):
        # The point of solving rather than forcing a lightness: the result
        # lands on the threshold, not somewhere safely past it.
        fixed = th.solve_contrast(LATTE_GREEN, LATTE_BG)
        self.assertLess(th.contrast(fixed, LATTE_BG), th.AA_NORMAL + 0.1)

    def test_keeps_the_hue(self):
        _, _, before = th.to_oklch(LATTE_GREEN)
        _, _, after = th.to_oklch(th.solve_contrast(LATTE_GREEN, LATTE_BG))
        self.assertLess(abs(before - after) % 360, 10)

    def test_moves_away_from_the_background(self):
        # Light ground: darker. Dark ground: lighter.
        light_l = th.to_oklch(th.solve_contrast(LATTE_GREEN, LATTE_BG))[0]
        dark_l = th.to_oklch(th.solve_contrast("#1e5a12", "#1e1e2e"))[0]
        self.assertLess(light_l, th.to_oklch(LATTE_GREEN)[0])
        self.assertGreater(dark_l, th.to_oklch("#1e5a12")[0])

    def test_unreachable_hue_still_clears_the_target(self):
        # Saturated yellow on mid-grey cannot reach AA while staying yellow.
        fixed = th.solve_contrast("#ffff00", "#777777")
        self.assertGreaterEqual(th.contrast(fixed, "#777777"), th.AA_NORMAL)


class Derive(unittest.TestCase):
    LIGHT = {"background": LATTE_BG, "foreground": "#4c4f69", "accent": "#1e66f5",
             "blue": "#1e66f5", "green": LATTE_GREEN, "yellow": "#df8e1d",
             "red": "#d20f39", "muted": "#9ca0b0"}
    DARK = {"background": "#1e1e2e", "foreground": "#cdd6f4", "accent": "#89b4fa",
            "blue": "#89b4fa", "green": "#a6e3a1", "yellow": "#f9e2af",
            "red": "#f38ba8", "muted": "#585b70"}

    def test_every_text_role_passes_aa(self):
        for name, palette in (("light", self.LIGHT), ("dark", self.DARK)):
            roles = th.derive(palette)
            for role in list(th.ROLES) + ["muted"]:
                with self.subTest(theme=name, role=role):
                    self.assertGreaterEqual(
                        th.contrast(roles[role], palette["background"]), th.AA_NORMAL)

    def test_surfaces_step_toward_the_text(self):
        # In a light theme a raised surface is *darker* than the page.
        for name, palette in (("light", self.LIGHT), ("dark", self.DARK)):
            roles = th.derive(palette)
            bg_l = th.to_oklch(roles["bg"])[0]
            fg_l = th.to_oklch(roles["fg"])[0]
            with self.subTest(theme=name):
                for surface in ("surface", "surface-2", "border"):
                    s_l = th.to_oklch(roles[surface])[0]
                    self.assertLess(abs(s_l - fg_l), abs(bg_l - fg_l), surface)


if __name__ == "__main__":
    unittest.main()
