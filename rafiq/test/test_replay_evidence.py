import io
import json
import math
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))
sys.path.insert(0, os.path.join(ROOT, "test"))

import judge_ref as jr  # noqa: E402
import replay_evidence as rp  # noqa: E402
import report_testkit as kit  # noqa: E402
import wav_ref  # noqa: E402

with open(os.path.join(ROOT, "test", "fixtures", "frame_golden.json"), encoding="utf-8") as handle:
    GOLDEN = {s["name"]: s for s in json.load(handle)["judge"]["scenarios"]}

SESSION_START_FRAME = 24   # where the ayah's window starts in the live session
CLIP_OFFSET_FRAMES = 12    # the saved clip starts 0.48 s into the session


def vocabulary(scenario):
    """tokens.txt-like list: duration labels on the golden's duration ids, the blank last."""
    held = list("\u0627\u06e5\u06e6\u0649")
    tokens = []
    for i in range(scenario["classes"] - 1):
        if i in scenario["durationIds"]:
            tokens.append(held[sorted(scenario["durationIds"]).index(i)])
        else:
            tokens.append("abcdefghijk"[i])
    tokens.append("<blk>")
    return tokens


def make_case(name, words, logged_sensitivity="balanced"):
    """A record the way the phone would write it, plus the matrix a replay would compute."""
    sc = GOLDEN[name]
    tokens = vocabulary(sc)
    word_of = [w for w, group in enumerate(words) for _ in group]
    soft = {group[-1] for group in words}
    findings = jr.judge(sc["matrix"], sc["targets"], sc["blank"], logged_sensitivity, soft, set(),
                        set(sc["durationIds"]))
    rows = []
    for j, f in enumerate(findings):
        margin = 99.0 if math.isinf(f["margin"]) else f["margin"]
        rows.append([j, word_of[j], tokens[f["token"]],
                     (f["start"] + SESSION_START_FRAME) * 40, (f["end"] + SESSION_START_FRAME) * 40,
                     f["severity"], f["kind"], round(f["p_ref"], 4), round(f["p_comp"], 4),
                     tokens[f["comp"]] if 0 <= f["comp"] < len(tokens) else "", round(margin, 4),
                     round(f["ratio"], 4)])
    frames = len(sc["matrix"])
    record = kit.make_record("112-1-1", words=[kit.word("w", "x", tokens=[]) for _ in words],
                             window=(SESSION_START_FRAME * 40, (SESSION_START_FRAME + frames) * 40),
                             sensitivity=logged_sensitivity)
    record["frames"]["tokens"] = rows
    record["frames"]["wordMap"] = list(range(len(words)))
    record["audio"] = {"file": "112-1-1.wav", "offsetSec": CLIP_OFFSET_FRAMES * 0.04, "seconds": 3.0, "sr": 16000}
    filler = [[math.log(1.0 / sc["classes"])] * sc["classes"] for _ in range(SESSION_START_FRAME - CLIP_OFFSET_FRAMES)]
    return record, filler + [list(row) for row in sc["matrix"]], tokens, sc["blank"]


class FakeRunner:
    """Stands in for stream_ref.OrtStream: ignores the audio, serves a prepared matrix."""

    def __init__(self, rows):
        self.log_probs = rows
        self.fed = 0

    def reset(self):
        self.fed = 0

    def accept(self, samples):
        self.fed += len(samples)

    def finish(self):
        pass


class ReferenceTests(unittest.TestCase):
    def test_reference_is_rebuilt_from_the_logged_rows(self):
        record, _, tokens, blank = make_case("duration_runs", [[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]])
        ref = rp.reference_from_record(record, tokens)
        self.assertEqual(ref["targets"], GOLDEN["duration_runs"]["targets"])
        self.assertEqual(ref["soft_exempt"], {2, 5, 8, 11})
        self.assertEqual(ref["duration_ids"], {0, 2, 4, 6})
        self.assertEqual(ref["all_exempt"], set())

    def test_exempt_kind_marks_the_elided_hamza(self):
        record, _, tokens, _ = make_case("weak_elided_hamza", [[0, 1, 2]])
        record["frames"]["tokens"][0][6] = "exempt"
        self.assertEqual(rp.reference_from_record(record, tokens)["all_exempt"], {0})

    def test_unknown_or_ambiguous_labels_are_refused(self):
        record, _, tokens, _ = make_case("clean", [[0, 1, 2]])
        with self.assertRaises(ValueError):
            rp.reference_from_record(record, tokens[:2] + ["zz"] + tokens[3:])
        with self.assertRaises(ValueError):
            rp.reference_from_record(record, ["a", "a", "c", "<blk>"])
        record["frames"]["tokens"] = []
        with self.assertRaises(ValueError):
            rp.reference_from_record(record, tokens)


class ReplayTests(unittest.TestCase):
    def test_identical_posteriors_reproduce_the_phone_exactly(self):
        for name, words in (("substitution", [[0, 1, 2]]), ("weak", [[0, 1]]),
                            ("duration_runs", [[0, 1, 2], [3, 4, 5], [6, 7, 8], [9, 10, 11]])):
            record, rows, tokens, blank = make_case(name, words)
            log_probs = rp.run_stream(FakeRunner(rows), [0.0] * 16000)
            replay = rp.rejudge(record, log_probs, tokens, blank)
            parity = rp.compare(record, replay)
            self.assertEqual(parity["max_abs_p_ref"], 0.0, name)
            self.assertEqual(parity["max_abs_p_comp"], 0.0, name)
            self.assertEqual(parity["kind_mismatches"], [], name)
            self.assertEqual(parity["moved_alignments"], [], name)
            self.assertTrue(parity["same_sensitivity"])
            for t in parity["tokens"]:
                self.assertEqual(t["logged"]["start_ms"], t["replay"]["start_ms"], name)

    def test_the_audio_is_fed_in_phone_sized_blocks(self):
        record, rows, tokens, blank = make_case("clean", [[0, 1, 2]])
        runner = FakeRunner(rows)
        rp.run_stream(runner, [0.0] * 16000)
        self.assertEqual(runner.fed, 16000)

    def test_a_different_posterior_is_reported(self):
        record, rows, tokens, blank = make_case("clean", [[0, 1, 2]])
        spike = max(range(len(rows)), key=lambda t: rows[t][0])
        rows[spike] = [math.log(0.2)] + [math.log(0.7 / (len(rows[spike]) - 1))] * (len(rows[spike]) - 1)
        replay = rp.rejudge(record, rows, tokens, blank)
        parity = rp.compare(record, replay)
        self.assertGreater(parity["max_abs_p_ref"], 0.1)

    def test_another_sensitivity_changes_verdicts_not_posteriors(self):
        record, rows, tokens, blank = make_case("weak", [[0, 1]], logged_sensitivity="balanced")
        same = rp.compare(record, rp.rejudge(record, rows, tokens, blank))
        strict = rp.compare(record, rp.rejudge(record, rows, tokens, blank, "strict"))
        self.assertEqual(same["kind_mismatches"], [])
        self.assertFalse(strict["same_sensitivity"])
        self.assertEqual(strict["kind_mismatches"], [1])
        self.assertEqual(strict["max_abs_p_ref"], 0.0)
        # the weak token closes its word, so strict only calls it an edge (soft warnings stop at a word's end)
        self.assertEqual(strict["tokens"][1]["replay"]["kind"], "edge")

    def test_a_window_too_small_for_the_reference_is_an_error(self):
        record, rows, tokens, blank = make_case("clean", [[0, 1, 2]])
        with self.assertRaises(ValueError):
            rp.rejudge(record, rows[:14], tokens, blank)   # 2 frames left for 3 reference tokens

    def test_render_marks_disagreements(self):
        record, rows, tokens, blank = make_case("weak", [[0, 1]])
        text = rp.render(record, *(lambda r: (r, rp.compare(record, r)))(rp.rejudge(record, rows, tokens, blank, "strict")))
        self.assertIn("حساسية مختلفة", text)
        self.assertIn("اختلاف", text)


class InputTests(unittest.TestCase):
    def records(self):
        a = kit.make_record("112-1-1", words=[kit.word("w", "x", tokens=None)])
        b = kit.make_record("112-2-2", ayah=2, words=[kit.word("w", "x", tokens=None)])
        return a, b

    def test_evidence_log_store_and_export_are_all_understood(self):
        a, b = self.records()
        evidence = "\n".join(json.dumps(x, ensure_ascii=False) for x in (a, {"kind": "label", "rid": "112-1-1"}, b))
        store = "\n".join(json.dumps({"k": "rec", "r": x}, ensure_ascii=False) for x in (a, b))
        export = json.dumps({"format": "rafiq-report/3", "records": [a, b], "labels": [], "reports": []})
        for text in (evidence, store, export):
            self.assertEqual(rp.find_record(text)["rid"], "112-2-2")
            self.assertEqual(rp.find_record(text, "112-1-1")["rid"], "112-1-1")
            with self.assertRaises(KeyError):
                rp.find_record(text, "nope")
        with self.assertRaises(KeyError):
            rp.find_record("")

    def test_wav_round_trip_and_rate_check(self):
        pcm = [0, 5, -5, 32767, -32768]
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "a.wav")
            with open(path, "wb") as handle:
                handle.write(wav_ref.encode_wav16(pcm))
            self.assertEqual(rp.load_wav(path), [v / 32768.0 for v in pcm])
            other = os.path.join(folder, "b.wav")
            with open(other, "wb") as handle:
                handle.write(wav_ref.encode_wav16(pcm, 8000))
            with self.assertRaises(ValueError):
                rp.load_wav(other)

    def test_read_tokens_finds_the_blank(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "tokens.txt")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("a 0\nب 1\n<blk> 2\n")
            self.assertEqual(rp.read_tokens(path), (["a", "ب", "<blk>"], 2))


class CommandLineTests(unittest.TestCase):
    def test_logprobs_path_runs_without_the_model(self):
        import numpy as np
        record, rows, tokens, blank = make_case("weak", [[0, 1]])
        with tempfile.TemporaryDirectory() as folder:
            evidence = os.path.join(folder, "ev.jsonl")
            token_file = os.path.join(folder, "tokens.txt")
            npy = os.path.join(folder, "lp.npy")
            out = os.path.join(folder, "out.json")
            with open(evidence, "w", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False))
            with open(token_file, "w", encoding="utf-8") as handle:
                handle.write("".join("%s %d\n" % (t, i) for i, t in enumerate(tokens)))
            np.save(npy, np.asarray(rows))
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = rp.main(["--evidence", evidence, "--tokens", token_file, "--logprobs", npy,
                                "--sensitivity", "strict", "--json", out])
            self.assertEqual(code, 0)
            self.assertIn("إعادة تشغيل 112-1-1", buffer.getvalue())
            with open(out, encoding="utf-8") as handle:
                self.assertEqual(json.load(handle)["kind_mismatches"], [1])

    def test_missing_inputs_are_explained(self):
        record, rows, tokens, blank = make_case("clean", [[0, 1, 2]])
        with tempfile.TemporaryDirectory() as folder:
            evidence = os.path.join(folder, "ev.jsonl")
            token_file = os.path.join(folder, "tokens.txt")
            with open(evidence, "w", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False))
            with open(token_file, "w", encoding="utf-8") as handle:
                handle.write("".join("%s %d\n" % (t, i) for i, t in enumerate(tokens)))
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                self.assertEqual(rp.main(["--evidence", evidence, "--tokens", token_file]), 2)
                self.assertEqual(rp.main(["--evidence", evidence]), 2)
            self.assertIn("--model", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
