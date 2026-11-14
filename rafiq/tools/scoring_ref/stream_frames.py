"""Reference of the live frame accumulator (spec §6.A2 multi-window ensembling, §8 FINAL/TENTATIVE frames).
Mirrored by lib/core/audio_engine/muaalem/frame_accumulator.dart; golden: test/fixtures/stream_golden.json.
Absolute frame index = 25 fps grid from the ayah start. A window contributes frames [lo, n): lo = 0 when the
window starts at the ayah start, else `left_margin` (frames near the left edge lack left context)."""
import numpy as np

class FrameAccumulator:
    def __init__(self, v: int, left_margin: int, lag: int):
        self.v, self.left_margin, self.lag = v, left_margin, lag
        self.sum: dict[int, np.ndarray] = {}
        self.cnt: dict[int, int] = {}
        self.final_upto = 0  # frames [0, final_upto) are FINAL

    def add_window(self, lp: np.ndarray, start_abs: int, at_ayah_start: bool, last: bool = False):
        n = lp.shape[0]
        lo = 0 if at_ayah_start else min(self.left_margin, n)
        for k in range(lo, n):
            a = start_abs + k
            self.sum[a] = self.sum.get(a, 0.0) + lp[k]
            self.cnt[a] = self.cnt.get(a, 0) + 1
        newest = start_abs + n
        self.final_upto = max(self.final_upto, newest if last else newest - self.lag)

    def frame(self, a: int) -> np.ndarray:
        """Average of the log-probs over covering windows, renormalised (log-sum-exp)."""
        m = self.sum[a] / self.cnt[a]
        mx = m.max()
        return m - (mx + np.log(np.exp(m - mx).sum()))

    def known_upto(self) -> int:
        a = 0
        while a in self.sum:
            a += 1
        return a
