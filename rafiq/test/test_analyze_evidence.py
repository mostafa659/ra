import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))
sys.path.insert(0, os.path.join(ROOT, "test"))

import analyze_evidence as ae  # noqa: E402
import report_testkit as kit  # noqa: E402

OLD_RECORD = {
    "v": 2, "surah": 112, "ayah": 1, "reference": "lexicon", "tokens": ["a", "b"],
    "verdicts": {"0": "correct", "1": "tajweedWarning: x"},
    "frames": {
        "status": "ok",
        "words": [[0, 1, "weak", "a", "b", 0.25, 0.4, -0.47], [1, 0, "ok", "b", "c", 0.9, 0.01, 4.5]],
        "tokens": [[0, 0, "a", 0, 40, 1, "weak", 0.25, 0.4, "b", -0.47, 0.0],
                   [1, 1, "b", 80, 120, 0, "ok", 0.90, 0.01, "c", 4.5, 0.0],
                   [2, 1, "c", 160, 200, 0, "edge", 0.50, 0.1, "d", 1.6, 0.0]],
    },
}


def run(text, *extra):
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "evidence.jsonl")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = ae.main([path] + list(extra))
        return code, buffer.getvalue()


def v3_log():
    words = [kit.word("w", "ab", tokens=[kit.tok("ب", 400, 440), kit.tok("ت", 480, 520)]),
             kit.word("w", "ab", status="warning", fa="applied",
                      tokens=[kit.tok("ب", 800, 840, 1, "weak", 0.25, 0.05, "ع"), kit.tok("ت", 880, 920)])]
    record = kit.make_record("112-1-5", words=words, heard=[("ب", 400), ("ب", 800)], window=(320, 1200))
    labels = [kit.label(0, "confirmed", rid="112-1-5", shown="correct"),
              kit.label(1, "false_alarm", rid="112-1-5", shown="warning")]
    return "\n".join(json.dumps(x, ensure_ascii=False) for x in [record] + labels)


class AnalyzeEvidenceTests(unittest.TestCase):
    def test_old_records_keep_their_summary_and_get_no_label_section(self):
        code, out = run(json.dumps(OLD_RECORD))
        self.assertEqual(code, 0)
        self.assertIn("- 112:1 mode=lexicon frames=ok heard_tokens=2", out)
        self.assertIn("word 0 severity 1 weak token=a rival=b p_ref=0.25", out)
        self.assertIn("clean tokens: 2", out)    # unchanged: a tajweedWarning verdict still counts as clean
        self.assertIn("p05  p_ref=", out)
        self.assertNotIn("== التغطية ==", out)

    def test_an_ayah_with_a_rejected_word_adds_no_clean_tokens(self):
        rejected = dict(OLD_RECORD, verdicts={"0": "incorrect: x"})
        code, out = run(json.dumps(rejected))
        self.assertEqual(code, 0)
        self.assertNotIn("clean tokens", out)

    def test_label_lines_are_not_printed_as_records_and_trigger_the_analysis(self):
        code, out = run(v3_log(), "--target-fpr", "0.05")
        self.assertEqual(code, 0)
        self.assertEqual(len([line for line in out.splitlines() if line.startswith("- ")]), 1)
        self.assertIn("rid=112-1-5", out)
        self.assertIn("== التغطية ==", out)
        self.assertIn("== مصفوفة الارتباك", out)
        self.assertIn("TP 0 | FP 1 | FN 0 | TN 1", out)

    def test_damaged_lines_are_counted_not_fatal(self):
        code, out = run("not json\n" + json.dumps(OLD_RECORD) + "\n[1]\n")
        self.assertEqual(code, 0)
        self.assertIn("(2 damaged line(s) skipped)", out)

    def test_labels_flag_forces_the_section_and_json_is_strict(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "evidence.jsonl")
            target = os.path.join(folder, "out.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(v3_log())
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                ae.main([path, "--labels", "--json", target])
            with open(target, encoding="utf-8") as handle:
                text = handle.read()
            self.assertNotIn("Infinity", text)
            self.assertEqual(json.loads(text)["overall"]["fp"], 1)


if __name__ == "__main__":
    unittest.main()
