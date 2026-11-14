import math
import os
import random
import sys
import unittest

try:
    import numpy  # noqa: F401
    HAVE_NUMPY = True
except Exception:  # CI installs numpy; a bare interpreter skips the numeric tests
    HAVE_NUMPY = False

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))

import fbank_ref as fb  # noqa: E402
import judge_ref as jr  # noqa: E402
import onnx_contract as oc  # noqa: E402


class OnnxContractTests(unittest.TestCase):
    def test_round_trip_and_initializer_filtering(self):
        data = oc.build_model(
            inputs=[("x", 1, [1, 61, 80]), ("cached_len_0", 7, [2, 1]), ("w", 1, [3]), ("n", 1, [1, "T"])],
            outputs=[("log_probs", 1, [1, 12, 251]), ("new_cached_len_0", 7, [2, 1])],
            metadata={"T": "61", "decode_chunk_len": "48"},
            initializers=["w"],
        )
        contract = oc.parse_contract(data)
        self.assertEqual([i["name"] for i in contract["inputs"]], ["x", "cached_len_0", "n"])
        self.assertEqual(contract["inputs"][1]["elem_type"], oc.ELEM_INT64)
        self.assertEqual(contract["inputs"][2]["dims"], [1, -1])
        self.assertEqual(contract["outputs"][0]["dims"], [1, 12, 251])
        self.assertEqual(contract["metadata"], {"T": "61", "decode_chunk_len": "48"})

    def test_matches_onnxruntime_on_real_models(self):
        try:
            import onnxruntime as ort
            from onnxruntime.datasets import get_example
        except Exception:
            self.skipTest("onnxruntime not installed")
        checked = 0
        for name in ("sigmoid.onnx", "mul_1.onnx", "logreg_iris.onnx"):
            try:
                path = get_example(name)
            except Exception:
                continue
            session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
            with open(path, "rb") as handle:
                parsed = oc.parse_contract(handle.read())
            self.assertEqual([i["name"] for i in parsed["inputs"]], [i.name for i in session.get_inputs()])
            self.assertEqual([o["name"] for o in parsed["outputs"]], [o.name for o in session.get_outputs()])
            for mine, theirs in zip(parsed["inputs"], session.get_inputs()):
                static = [d for d in theirs.shape if isinstance(d, int)]
                self.assertEqual([d for d in mine["dims"] if d > 0], static)
            checked += 1
        if checked == 0:
            self.skipTest("no bundled onnx examples")


@unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
class FbankTests(unittest.TestCase):
    @staticmethod
    def signal(n):
        return [
            0.3 * math.sin(2 * math.pi * 220 * i / 16000)
            + 0.2 * math.sin(2 * math.pi * 1370 * i / 16000 + 0.5)
            + 0.05 * math.sin(2 * math.pi * 3100 * i / 16000)
            for i in range(n)
        ]

    def test_fft_matches_numpy(self):
        import numpy as np

        rnd = random.Random(7)
        re = [rnd.uniform(-1, 1) for _ in range(fb.PADDED)]
        im = [0.0] * fb.PADDED
        expected = np.fft.fft(np.array(re))
        fb.fft_radix2(re, im)
        self.assertLess(float(np.abs(np.array(re) + 1j * np.array(im) - expected).max()), 1e-9)

    def test_streaming_equals_independent_reference(self):
        import numpy as np

        samples = np.asarray(self.signal(4800), dtype=np.float32)
        expected = fb.reference_features(samples)
        for chunking in (4800, 1000, 160, 37):
            extractor = fb.KaldiFbank()
            frames = []
            for i in range(0, len(samples), chunking):
                frames += extractor.accept(samples[i:i + chunking])
            self.assertEqual(len(frames), len(expected))
            self.assertLess(float(np.abs(np.array(frames) - expected).max()), 1e-8)

    def test_frame_counts_follow_centred_framing(self):
        self.assertEqual(fb.frames_ready(279), 0)
        self.assertEqual(fb.frames_ready(280), 1)
        self.assertEqual(fb.frames_ready(3200), 19)

    def test_bank_shape(self):
        banks = fb.build_banks()
        self.assertEqual(len(banks), 80)
        self.assertTrue(all(len(w) > 0 and min(w) > 0 for _, w in banks))
        firsts = [f for f, _ in banks]
        self.assertEqual(firsts, sorted(firsts))


def spike_matrix(classes, blank, spikes, frames):
    """spikes: list of (frame, ref_id, p_ref, comp_id, p_comp). Normalised log-probs."""
    rows = []
    others = [c for c in range(classes) if c != blank]
    for t in range(frames):
        probs = [0.0] * classes
        spike = next((s for s in spikes if s[0] == t), None)
        if spike is None:
            probs[blank] = 0.97
            for c in others:
                probs[c] = 0.03 / len(others)
        else:
            _, ref, p_ref, comp, p_comp = spike
            probs[ref] = p_ref
            if comp is not None:
                probs[comp] += p_comp
            rest = 1.0 - sum(probs)
            spread = [c for c in range(classes) if probs[c] == 0.0]
            for c in spread:
                probs[c] = rest / len(spread)
        total = sum(probs)
        rows.append([math.log(p / total) for p in probs])
    return rows


class JudgeTests(unittest.TestCase):
    CLASSES, BLANK = 8, 7

    def run_case(self, targets, spikes, frames=40, strictness="strict"):
        logp = spike_matrix(self.CLASSES, self.BLANK, spikes, frames)
        return jr.judge(logp, targets, self.BLANK, strictness)

    def test_clean_recitation_is_not_flagged(self):
        out = self.run_case([0, 1, 2], [(5, 0, 0.97, None, 0), (15, 1, 0.96, None, 0), (25, 2, 0.98, None, 0)])
        self.assertEqual([r["severity"] for r in out], [0, 0, 0])
        self.assertEqual([(r["start"], r["end"]) for r in out], [(5, 6), (15, 16), (25, 26)])

    def test_substitution_is_hard(self):
        out = self.run_case([0, 1, 2], [(5, 0, 0.97, None, 0), (15, 1, 0.35, 3, 0.60), (25, 2, 0.98, None, 0)])
        self.assertEqual([r["severity"] for r in out], [0, 2, 0])
        self.assertEqual(out[1]["kind"], "substitution")
        self.assertEqual(out[1]["comp"], 3)

    def test_canonicalised_deviation_still_shows_as_close_call(self):
        # greedy decoding would print the expected token (0.75 > 0.22) ...
        spikes = [(5, 0, 0.75, 3, 0.22)]
        strict = self.run_case([0], spikes, strictness="strict")
        balanced = self.run_case([0], spikes, strictness="balanced")
        self.assertEqual(strict[0]["kind"], "close")  # ... but the competitor is too near
        self.assertEqual(balanced[0]["severity"], 0)

    def test_weak_expected_token_is_flagged_even_without_competitor(self):
        out = self.run_case([0, 1], [(5, 0, 0.97, None, 0), (15, 1, 0.45, None, 0)])
        self.assertEqual(out[1]["kind"], "weak")
        balanced = self.run_case([0, 1], [(5, 0, 0.97, None, 0), (15, 1, 0.45, None, 0)], strictness="balanced")
        self.assertEqual(balanced[1]["severity"], 0)

    def test_extra_units_of_a_prolonged_sound_are_not_judged(self):
        out = self.run_case([2, 2, 2], [(5, 2, 0.97, None, 0), (12, 2, 0.30, None, 0), (19, 2, 0.20, None, 0)])
        self.assertEqual([r["severity"] for r in out], [0, 0, 0])
        self.assertEqual([r["kind"] for r in out], ["ok", "unit", "unit"])

    def test_word_edges_and_elided_hamza_are_exempted_but_substitutions_still_count(self):
        weak_end = [(5, 0, 0.97, None, 0), (15, 1, 0.97, None, 0), (25, 2, 0.45, None, 0)]
        logp = spike_matrix(self.CLASSES, self.BLANK, weak_end, 40)
        plain = jr.judge(logp, [0, 1, 2], self.BLANK)
        exempt = jr.judge(logp, [0, 1, 2], self.BLANK, soft_exempt={2})
        self.assertEqual((plain[2]["severity"], exempt[2]["severity"], exempt[2]["kind"]), (1, 0, "edge"))
        hard = [(5, 0, 0.97, None, 0), (15, 1, 0.97, None, 0), (25, 2, 0.30, 3, 0.65)]
        out = jr.judge(spike_matrix(self.CLASSES, self.BLANK, hard, 40), [0, 1, 2], self.BLANK, soft_exempt={2})
        self.assertEqual(out[2]["severity"], 2)
        hamza = [(5, 0, 0.40, None, 0), (15, 1, 0.97, None, 0), (25, 2, 0.97, None, 0)]
        out = jr.judge(spike_matrix(self.CLASSES, self.BLANK, hamza, 40), [0, 1, 2], self.BLANK, all_exempt={0})
        self.assertEqual((out[0]["severity"], out[0]["kind"]), (0, "exempt"))

    def test_maximum_sensitivity_flags_a_doubt_the_other_levels_accept(self):
        spikes = [(5, 0, 0.97, None, 0), (15, 1, 0.85, 3, 0.05)]
        strict = self.run_case([0, 1], spikes, strictness="strict")
        maximum = self.run_case([0, 1], spikes, strictness="maximum")
        self.assertEqual(strict[1]["severity"], 0)
        self.assertEqual((maximum[1]["severity"], maximum[1]["kind"]), (1, "weak"))

    def test_held_sounds_are_graded_by_timing_against_the_reciters_own_tempo(self):
        layout = [(0, 4, 9, 1, 14), (2, 19, 24, 3, 29), (4, 34, 45, 5, 56), (6, 61, 63, 7, 65)]
        spikes, targets = [], []
        for unit, a, b, sep, sep_frame in layout:
            spikes += [(a, unit, 0.97, None, 0), (b, unit, 0.97, None, 0), (sep_frame, sep, 0.97, None, 0)]
            targets += [unit, unit, sep]
        logp = spike_matrix(10, 9, spikes, 75)
        strict = jr.judge(logp, targets, 9, "strict", duration_ids={0, 2, 4, 6})
        kinds = {r["index"]: r["kind"] for r in strict}
        self.assertEqual((kinds[0], kinds[3], kinds[6], kinds[9]), ("ok", "ok", "long", "short"))
        self.assertAlmostEqual(strict[6]["ratio"], 2.2, places=6)
        balanced = jr.judge(logp, targets, 9, "balanced", duration_ids={0, 2, 4, 6})
        self.assertTrue(all(r["kind"] in ("ok", "unit") for r in balanced))
        # too few runs to know the reciter's tempo: nothing is guessed
        few = jr.judge(logp, targets[:6], 9, "strict", duration_ids={0, 2})
        self.assertTrue(all(r["kind"] in ("ok", "unit") for r in few))

    def test_a_pause_after_a_held_sound_is_not_called_a_long_note(self):
        spikes = [(4, 0, 0.97, None, 0), (9, 0, 0.97, None, 0), (14, 1, 0.97, None, 0),
                  (19, 2, 0.97, None, 0), (24, 2, 0.97, None, 0), (29, 3, 0.97, None, 0),
                  (34, 4, 0.97, None, 0), (39, 4, 0.97, None, 0), (75, 5, 0.97, None, 0)]
        logp = spike_matrix(8, 7, spikes, 90)
        out = jr.judge(logp, [0, 0, 1, 2, 2, 3, 4, 4, 5], 7, "strict", duration_ids={0, 2, 4})
        self.assertEqual(out[6]["kind"], "ok")

    def test_alignment_needs_enough_frames(self):
        with self.assertRaises(ValueError):
            jr.forced_align(spike_matrix(8, 7, [], 2), [0, 1, 2], 7)


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
class RealOnnxRuntimeTests(unittest.TestCase):
    """Runs the CI tooling against a real (hand-built) streaming ONNX model."""

    @classmethod
    def setUpClass(cls):
        try:
            import onnxruntime  # noqa: F401
        except Exception:
            raise unittest.SkipTest("onnxruntime not installed")
        import tempfile

        import toy_model

        cls.toy = toy_model
        cls.dir = tempfile.mkdtemp()
        cls.model = os.path.join(cls.dir, "toy.onnx")
        with open(cls.model, "wb") as handle:
            handle.write(toy_model.build_toy_model())
        cls.tokens = os.path.join(cls.dir, "tokens.txt")
        with open(cls.tokens, "w", encoding="utf-8") as handle:
            handle.write("a 0\nb 1\nc 2\nd 3\n<blk> 4\n")

    def test_contract_parser_agrees_with_onnxruntime(self):
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import model_probe

        contract = model_probe.describe(self.model)
        self.assertTrue(contract["parser_check"]["ok"], contract["parser_check"])
        self.assertEqual(contract["state_families"], {"cached_bias": 1, "processed_lens": 1})
        self.assertEqual(contract["output_mapping"]["by"], "name")
        smoke = model_probe.smoke_run(contract)
        self.assertTrue(smoke["ok"], smoke)
        self.assertTrue(smoke["log_probs_are_normalised"])
        self.assertEqual(smoke["log_probs_shape"], [1, 12, 5])

    def test_streaming_runner_matches_a_numpy_emulation_with_state_feedback(self):
        import numpy as np
        import stream_ref

        samples = np.asarray(FbankTests.signal(16000 * 2), dtype=np.float32)
        runner = stream_ref.OrtStream(self.model, self.tokens)
        for i in range(0, len(samples), 3840):
            runner.accept(samples[i:i + 3840])
        self.assertEqual(runner.hop, 48)
        self.assertEqual(runner.window, 61)
        # rebuild the windows independently and run the numpy twin of the toy graph
        frames = fb.reference_features(samples)
        windows, offset = [], 0
        while len(frames) - offset >= 61:
            windows.append(frames[offset:offset + 61])
            offset += 48
        expected = self.toy.numpy_reference(windows)
        self.assertEqual(len(runner.log_probs), 12 * len(expected))
        got = np.array(runner.log_probs).reshape(len(expected), 12, 5)
        for step, want in enumerate(expected):
            self.assertLess(float(np.abs(got[step] - want).max()), 2e-3, "step %d" % step)
        # the state really is fed back: identical inputs would otherwise repeat
        self.assertGreater(float(np.abs(got[0] - got[1]).max()), 1e-3)
        # greedy tokens and their times follow the argmax rule
        prev, want_tokens = 4, []
        for step in range(len(expected)):
            for r in range(12):
                best = int(np.argmax(got[step][r]))
                if best != 4 and best != prev:
                    want_tokens.append(("abcd"[best], (step * 12 + r) * 0.04))
                prev = best
        self.assertEqual([t for t, _ in runner.emitted], [t for t, _ in want_tokens])
        self.assertTrue(all(abs(a[1] - b[1]) < 1e-9 for a, b in zip(runner.emitted, want_tokens)))

    def test_reset_restores_the_zero_state(self):
        import numpy as np
        import stream_ref

        samples = np.asarray(FbankTests.signal(16000), dtype=np.float32)
        runner = stream_ref.OrtStream(self.model, self.tokens)
        runner.accept(samples)
        first = np.array(runner.log_probs)
        runner.reset()
        runner.accept(samples)
        self.assertLess(float(np.abs(first - np.array(runner.log_probs)).max()), 1e-6)



class FinalVowelTests(unittest.TestCase):
    """A changed vowel on the LAST letter of a word (kayfa -> kayfi) must be flagged."""

    BLANK, A, I, Y, K = 0, 1, 2, 3, 4  # ids: blank, "fa", "fi", next-word token, previous token

    @staticmethod
    def _rows(spec):
        rows = []
        for probs in spec:
            rest = max(1e-6, 1.0 - sum(probs.values()))
            row = [math.log(1e-6)] * 5
            row[0] = math.log(rest)
            for k, v in probs.items():
                row[k] = math.log(v)
            rows.append(row)
        return rows

    def _run(self, p_fa, p_fi, strictness, gap=2, **kw):
        spec = [{4: 0.95}] + [{}] * 3 + [{1: p_fa, 2: p_fi}] + [{}] * gap + [{3: 0.95}, {}]
        return jr.judge(self._rows(spec), [4, 1, 3], 0, strictness, soft_exempt={1}, **kw)

    def test_old_behaviour_missed_it(self):
        # model "autocorrects": fi is audible (0.25) but fa still wins -> legacy judge stays silent
        res = self._run(0.60, 0.25, "balanced")
        self.assertEqual(res[1]["severity"], jr.SEV_NONE)

    def test_final_vowel_sibling_is_flagged(self):
        sibs = {1: [2], 2: [1]}
        res = self._run(0.60, 0.25, "balanced", vowel_siblings=sibs, edge_gap_frames=12)
        self.assertEqual((res[1]["kind"], res[1]["severity"]), ("vowel", jr.SEV_WARN))
        res = self._run(0.30, 0.55, "balanced", vowel_siblings=sibs, edge_gap_frames=12)
        self.assertEqual((res[1]["kind"], res[1]["severity"]), ("vowel", jr.SEV_HARD))

    def test_vowel_checked_even_at_a_pause_but_dropping_is_free(self):
        sibs = {1: [2], 2: [1]}
        res = self._run(0.60, 0.25, "balanced", gap=14, vowel_siblings=sibs, edge_gap_frames=12)
        self.assertEqual(res[1]["kind"], "vowel")
        res = self._run(0.15, 0.01, "balanced", gap=14, vowel_siblings=sibs, edge_gap_frames=12)
        self.assertEqual(res[1]["severity"], jr.SEV_NONE)  # weak final vowel before a pause: exempt

    def test_clean_final_vowel_is_silent(self):
        res = self._run(0.97, 0.001, "maximum", vowel_siblings={1: [2], 2: [1]}, edge_gap_frames=12)
        self.assertNotEqual(res[1]["kind"], "vowel")


class FinalVowelOffsetTests(unittest.TestCase):
    """The model fires the changed vowel a few frames away from where the reference token was aligned,
    and 'corrects' it enough that the absolute bar alone never trips (the 0.6.5 blind spot)."""

    BLANK, FA, FI, NEXT, PREV = 0, 1, 2, 3, 4
    SIBS = {1: [2], 2: [1]}

    def _matrix(self, frames, gap=4):
        # frame 0 prev token, 4 = the word's last token, then `gap` quiet frames, then the next word
        total = 5 + gap + 3
        rows = []
        for t in range(total):
            probs = frames.get(t, {})
            row = [math.log(1e-6)] * 5
            row[0] = math.log(max(1e-6, 1.0 - sum(probs.values())))
            for k, v in probs.items():
                row[k] = math.log(v)
            rows.append(row)
        return rows

    def _run(self, frames, strictness="balanced", gap=4, edge_gap=12):
        base = {0: {self.PREV: 0.95}, 4: {self.FA: 0.85}, 5 + gap: {self.NEXT: 0.95}}
        for t, probs in frames.items():
            merged = dict(base.get(t, {}))
            merged.update(probs)
            base[t] = merged
        return jr.judge(self._matrix(base, gap), [self.PREV, self.FA, self.NEXT], self.BLANK, strictness,
                        soft_exempt={1}, vowel_siblings=self.SIBS, edge_gap_frames=edge_gap)

    def test_sibling_firing_after_the_aligned_frame_is_seen(self):
        res = self._run({7: {self.FI: 0.12}})  # 3 frames after the aligned "fa"
        self.assertEqual((res[1]["kind"], res[1]["severity"]), ("vowel", jr.SEV_WARN))

    def test_sibling_firing_before_the_aligned_frame_is_seen(self):
        res = self._run({2: {self.FI: 0.12}})
        self.assertEqual((res[1]["kind"], res[1]["severity"]), ("vowel", jr.SEV_WARN))

    def test_reported_rival_is_the_sibling_vowel(self):
        res = self._run({6: {self.FI: 0.12}})
        self.assertEqual(res[1]["comp"], self.FI)
        self.assertAlmostEqual(res[1]["p_comp"], 0.12, places=5)
        self.assertAlmostEqual(res[1]["margin"], math.log(0.85 / 0.12), places=4)

    def test_faint_sibling_ratio_rule_in_the_flow(self):
        # fa 0.85 vs fi 0.06: below the absolute bar of every old preset, but only 14x weaker
        self.assertEqual(self._run({6: {self.FI: 0.06}}, "balanced")[1]["kind"], "ok")
        self.assertEqual(self._run({6: {self.FI: 0.10}}, "balanced")[1]["kind"], "vowel")
        self.assertEqual(self._run({6: {self.FI: 0.05}}, "strict")[1]["kind"], "vowel")
        # maximum already flags a 0.85 expected token as weak; with a firm one the faint sibling is still caught
        res = self._run({4: {self.FA: 0.95}, 6: {self.FI: 0.04}}, "maximum")
        self.assertEqual(res[1]["severity"], jr.SEV_WARN)

    def test_clean_recitation_is_silent_in_every_preset(self):
        for preset in ("strict", "balanced", "maximum"):
            res = self._run({4: {self.FA: 0.97}, 6: {self.FI: 0.002}}, preset)
            self.assertEqual(res[1]["kind"], "ok", preset)

    def test_pause_after_the_word_keeps_the_absolute_rule_only(self):
        # a reciter who stops may weaken the last vowel: a 0.06 sibling there is not a changed vowel
        res = self._run({6: {self.FI: 0.06}}, "balanced", gap=16)
        self.assertNotEqual(res[1]["kind"], "vowel")
        res = self._run({6: {self.FI: 0.30}}, "balanced", gap=16)
        self.assertEqual(res[1]["kind"], "vowel")

    def test_sibling_inside_the_next_tokens_span_is_not_counted(self):
        # the spike sits on the next word's own frame: it belongs to that token
        res = self._run({9: {self.FI: 0.40}}, "balanced", gap=4)
        self.assertNotEqual(res[1]["kind"], "vowel")
