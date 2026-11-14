"""The numpy front-end mirror (what Dart ports) must equal the HF SeamlessM4T extractor on real recordings' stand-ins."""
import os, sys, unittest
import numpy as np
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools/frontend_ref"))
import fbank_numpy as n
try:
    import seamless_fbank_ref as r
except Exception:  # transformers not installed
    r = None

@unittest.skipIf(r is None, "transformers not installed")
class Parity(unittest.TestCase):
    def test_matches_hf_even_and_odd_frames(self):
        mel, win = n.load_constants(os.path.join(ROOT, "assets/frontend"))
        rng = np.random.default_rng(4)
        for N in (24000, 24160, 40000):
            x = (0.2 * rng.standard_normal(N)).astype("float32")
            ref = r.features(x); mine = n.finish(n.log_mel(x, mel, win))
            self.assertEqual(ref.shape, mine.shape)
            self.assertLess(float(np.abs(ref - mine).max()), 2e-3)
