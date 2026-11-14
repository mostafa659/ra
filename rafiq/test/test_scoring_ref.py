"""Scoring reference: brute-force CTC check, golden stability, and the spec §1 regression on REAL recordings (103:3)."""
import gzip, itertools, json, math, os, sys, unittest
import numpy as np
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools/scoring_ref"))
import scoring as S, calibrate as C

class Ctc(unittest.TestCase):
    def test_nll_matches_bruteforce(self):
        rng = np.random.default_rng(3)
        for _ in range(8):
            T, V = 5, 4
            lp = S.log_softmax(rng.standard_normal((T, V)))
            seq = [1, 2] if _ % 2 else [1, 1]
            tot = 0.0
            for path in itertools.product(range(V), repeat=T):
                col, prev = [], -1
                for p in path:
                    if p != prev and p != 0: col.append(p)
                    prev = p
                if col == seq: tot += math.exp(sum(lp[t, p] for t, p in enumerate(path)))
            self.assertAlmostEqual(S.ctc_nll(lp, seq), -math.log(tot), places=5)
    def test_viterbi_spans_cover_tokens_in_order(self):
        rng = np.random.default_rng(5); lp = S.log_softmax(rng.standard_normal((12, 6)))
        sp = S.viterbi_spans(lp, [2, 3, 3, 4])
        self.assertEqual(len(sp), 4)
        for (a, b), (c, d) in zip(sp, sp[1:]): self.assertLessEqual(b, c)

class Golden(unittest.TestCase):
    def test_golden_is_current(self):
        with open(os.path.join(ROOT, "test/fixtures/scoring_golden.json")) as f: g = json.load(f)
        for c in g["ctc"]:
            lp = S.log_softmax(np.array(c["logits"]))
            self.assertAlmostEqual(S.ctc_nll(lp, c["seq"]), c["nll"], places=4)

class Regression103_3(unittest.TestCase):
    """Spec §1: word 5 and 7 (ص with kasra) flagged; word 0 «إِلَّا» (owner: false_alarm) NOT flagged.
    Run on the real q8 logits of the owner's recordings. rec_b is the recording whose free decode contains the kasra slips."""
    @classmethod
    def setUpClass(cls):
        ref = json.load(gzip.open(os.path.join(ROOT, "assets/qps_reference.json.gz"), "rt"))["ayat"]
        cls.words = next(a for a in ref if (a["s"], a["a"]) == (103, 3))["words"]
        fx = json.load(gzip.open(os.path.join(ROOT, "test/fixtures/regression_103_3_logits.json.gz"), "rt"))
        cls.fx = fx
    def judge(self, rec, level):
        return S.judge_ayah(np.array(self.fx[rec], dtype="float32"), self.words, S.Cfg(level=level))
    def test_kasra_words_flagged_all_levels(self):
        for lvl in ("strict", "balanced", "maximum"):
            r = self.judge("rec_b", lvl)
            self.assertEqual(r["words"][5]["tier"], "error", lvl)
            self.assertEqual(r["words"][7]["tier"], "error", lvl)
            self.assertTrue(any(t["sym"] == "َ" and t.get("alt") == "ِ" and t["gop"] < 0 for t in r["words"][7]["tokens"]))
    def test_word0_not_flagged_balanced(self):
        for rec in ("rec_a", "rec_b"):
            self.assertEqual(self.judge(rec, "balanced")["words"][0]["tier"], "ok", rec)
    def test_word0_never_error_any_level(self):
        for rec in ("rec_a", "rec_b"):
            for lvl in ("strict", "balanced", "maximum"):
                self.assertNotEqual(self.judge(rec, lvl)["words"][0]["tier"], "error")
    def test_owner_labeled_correct_recording_has_no_errors(self):
        """Owner (14-11-2026): rec_a is 100% correct. No red words at any level; fully green at strict/balanced.
        Provisional: thresholds were tuned on these two recordings (see DEFAULT_CALIBRATION) -> re-check after calibrate.py."""
        for lvl in ("strict", "balanced", "maximum"):
            tiers = [w["tier"] for w in self.judge("rec_a", lvl)["words"]]
            self.assertNotIn("error", tiers, lvl)
            if lvl != "maximum":
                self.assertEqual(set(tiers), {"ok"}, lvl)
    def test_final_token_is_judged(self):
        r = self.judge("rec_b", "balanced")
        last = r["words"][8]["tokens"]
        self.assertTrue(any(t["tier"] != "ok" for t in last))  # final-word damma/fatha slip is not exempt

class Calibrate(unittest.TestCase):
    def test_insufficient_data_stays_uncalibrated(self):
        cal, md = C.calibrate([{"class": "vowel_sub", "gop": 1.0, "is_error": True}])
        self.assertEqual(cal["calibration_status"], "UNCALIBRATED_INSUFFICIENT_DATA")
    def test_separable_data_gives_sane_tau(self):
        rng = np.random.default_rng(1)
        rows = [{"class": "vowel_sub", "gop": float(g), "is_error": True} for g in rng.normal(-3, 1, 50)] + \
               [{"class": "vowel_sub", "gop": float(g), "is_error": False} for g in rng.normal(6, 1.5, 200)]
        cal, _ = C.calibrate(rows)
        h, s = cal["tau"]["vowel_sub"]
        self.assertLessEqual(h, s); self.assertEqual(cal["calibration_status"], "CALIBRATED")
    def test_temperature_fit_recovers_overconfidence(self):
        rng = np.random.default_rng(2); n = 4000
        z = rng.standard_normal((n, 5)) * 2; y = np.array([rng.choice(5, p=np.exp(r / 2) / np.exp(r / 2).sum()) for r in z])
        self.assertAlmostEqual(C.fit_temperature(z, y), 2.0, delta=0.3)


class DartConstsFresh(unittest.TestCase):
    def test_generated_vocab_is_current(self):
        """lib/.../qps_vocab.dart is generated; regenerate with tools/scoring_ref/gen_dart_consts.py when it drifts."""
        import subprocess
        p = os.path.join(ROOT, "lib/core/audio_engine/scoring/qps_vocab.dart")
        before = open(p, encoding="utf-8").read()
        subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools/scoring_ref/gen_dart_consts.py")], check=True)
        self.assertEqual(before, open(p, encoding="utf-8").read())

class StreamGolden(unittest.TestCase):
    def test_final_upto_and_known(self):
        import stream_frames as SF
        g = json.load(open(os.path.join(ROOT, "test/fixtures/scoring_golden.json")))["stream"]
        acc = SF.FrameAccumulator(g["v"], g["left_margin"], g["lag"])
        for w in g["windows"]:
            acc.add_window(S.log_softmax(np.array(w["logits"])), w["start"], w["start_flag"], w["last"])
            self.assertEqual(acc.final_upto, w["final_upto"])
        self.assertEqual(acc.known_upto(), g["known_upto"])
        for k, want in g["frames"].items():
            self.assertTrue(np.allclose(acc.frame(int(k)), want, atol=1e-5))
            self.assertAlmostEqual(float(np.exp(acc.frame(int(k))).sum()), 1.0, places=9)
