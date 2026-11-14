"""Guards the design assets: fonts exist with their OFL texts and are declared in pubspec.yaml."""
import os, unittest
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
class Design(unittest.TestCase):
    def test_fonts_declared_and_present(self):
        pub = open(os.path.join(ROOT, "pubspec.yaml"), encoding="utf-8").read()
        for f in ("Tajawal-Regular.ttf", "Tajawal-Medium.ttf", "Tajawal-Bold.ttf", "Tajawal-ExtraBold.ttf", "AmiriQuran-Regular.ttf"):
            self.assertIn("assets/fonts/" + f, pub)
            self.assertGreater(os.path.getsize(os.path.join(ROOT, "assets/fonts", f)), 10000)
        for f in ("Tajawal-OFL.txt", "AmiriQuran-OFL.txt"):
            self.assertIn("SIL OPEN FONT LICENSE", open(os.path.join(ROOT, "assets/fonts", f), encoding="utf-8", errors="ignore").read().upper())
    def test_screens_use_theme_widgets(self):
        for rel, needle in (("lib/features/mushaf/surah_index_screen.dart", "IslamicPatternBackground"),
                            ("lib/features/memorize_engine/recitation_screen.dart", "MicPulseButton"),
                            ("lib/features/welcome/welcome_screen.dart", "BreathingGlow")):
            self.assertIn(needle, open(os.path.join(ROOT, rel), encoding="utf-8").read())
