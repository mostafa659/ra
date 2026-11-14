import math
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "frame_engine"))
import vowel_ref as vr  # noqa: E402

FORMANTS = {"a": (700, 1200, 2600, 3300), "i": (300, 2300, 3000, 3600), "u": (330, 850, 2400, 3300)}
BANDWIDTH = (80, 110, 160, 220)


def synth(vowel, scale=1.0, f0=120.0, seconds=0.14, seed=1, noise=0.002):
    """Glottal pulses with spectral tilt through four resonators, then lip radiation: a textbook
    source-filter vowel."""
    rng = random.Random(seed)
    n = int(seconds * vr.SR)
    period = vr.SR / f0
    x = [0.0] * n
    pos = 0.0
    while int(pos) < n:
        x[int(pos)] = 1.0
        pos += period
    for _ in range(2):  # glottal tilt
        y = 0.0
        out = []
        for v in x:
            y = v + 0.97 * y
            out.append(y)
        x = out
    for f, bw in zip(FORMANTS[vowel], BANDWIDTH):
        f *= scale
        r = math.exp(-math.pi * bw / vr.SR)
        c1 = 2 * r * math.cos(2 * math.pi * f / vr.SR)
        c2 = -r * r
        y1 = y2 = 0.0
        out = []
        for v in x:
            y = (1 - r) * v + c1 * y1 + c2 * y2
            out.append(y)
            y2, y1 = y1, y
        x = out
    x = [x[i] - (x[i - 1] if i else 0.0) for i in range(n)]  # lip radiation
    peak = max(abs(v) for v in x) or 1.0
    return [0.5 * v / peak + rng.gauss(0, noise) for v in x]


SPEAKERS = ((1.0, 120.0), (1.18, 210.0), (0.92, 100.0), (1.3, 240.0))


class FormantTests(unittest.TestCase):
    def test_vowel_order_in_the_formant_plane(self):
        est = {v: vr.estimate_formants(synth(v)) for v in "aiu"}
        for v in "aiu":
            self.assertIsNotNone(est[v])
            self.assertGreaterEqual(est[v][2], 2)
        self.assertGreater(est["a"][0], est["i"][0])  # F1: fatha above kasra and damma
        self.assertGreater(est["a"][0], est["u"][0])
        self.assertGreater(est["i"][1], est["a"][1])  # F2: kasra > fatha > damma
        self.assertGreater(est["a"][1], est["u"][1])

    def test_silence_gives_nothing(self):
        self.assertIsNone(vr.estimate_formants([0.0] * 3200))


class ClassifyTests(unittest.TestCase):
    def _anchors(self, scale, f0):
        out = {"a": [], "u": [], "i": []}
        for vowel, seeds in (("a", (1, 2, 3)), ("i", (4, 5)), ("u", (6, 7))):
            for seed in seeds:
                est = vr.estimate_formants(synth(vowel, scale, f0, seed=seed))
                out[vowel].append(est[:2])
        return out

    def _verdict(self, scale, f0, spoken, expected):
        anchors = self._anchors(scale, f0)
        obs = vr.estimate_formants(synth(spoken, scale, f0, seed=11))[:2]
        return vr.classify(anchors, obs, expected)

    def test_correct_final_vowel_is_silent_for_two_speakers(self):
        for scale, f0 in SPEAKERS:
            for vowel in "aiu":
                self.assertEqual(self._verdict(scale, f0, vowel, vowel)["severity"], 0, (scale, vowel))

    def test_changed_final_vowel_is_flagged_for_two_speakers(self):
        for scale, f0 in SPEAKERS:
            for spoken, expected in (("u", "a"), ("i", "a"), ("a", "i"), ("a", "u"), ("i", "u"), ("u", "i")):
                v = self._verdict(scale, f0, spoken, expected)
                self.assertGreaterEqual(v["severity"], 1, (scale, spoken, expected, v))

    def test_too_few_anchors_gives_no_verdict(self):
        v = vr.classify({"a": [(700.0, 1200.0)]}, (330.0, 850.0), "a")
        self.assertEqual((v["status"], v["severity"]), ("no_anchors", 0))


if __name__ == "__main__":
    unittest.main()
