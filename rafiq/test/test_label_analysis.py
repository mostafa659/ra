import json
import math
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))
sys.path.insert(0, os.path.join(ROOT, "test"))

import judge_ref as jr  # noqa: E402
import label_analysis as la  # noqa: E402
import report_ref as rr  # noqa: E402
import report_testkit as kit  # noqa: E402

GROUPS = [
    ("tn_strong", 30), ("tn_mid", 8), ("fp_weak", 4), ("tp_sub", 10), ("tp_text", 3),
    ("fn_mid", 4), ("fn_deep", 3), ("madd_ok", 2), ("fn_duration", 1),
]


def group_word(group, start):
    """One two-token word (the last token is always strong) for each kind of case."""
    last = kit.tok("ت", start + 80, start + 120)
    if group == "tn_strong":
        return kit.word("w", "ab", tokens=[kit.tok("ب", start, start + 40, 0, "ok", 0.95, 0.01, "ع"), last])
    if group == "tn_mid":
        return kit.word("w", "ab", tokens=[kit.tok("ب", start, start + 40, 0, "ok", 0.55, 0.10, "ع"), last])
    if group == "fp_weak":
        return kit.word("w", "ab", status="warning", fa="applied",
                        tokens=[kit.tok("ب", start, start + 40, 1, "weak", 0.25, 0.05, "ع"), last])
    if group == "tp_sub":
        return kit.word("w", "ab", status="incorrect", fa="applied",
                        tokens=[kit.tok("ص", start, start + 40, 2, "substitution", 0.20, 0.70, "س", -1.2528), last])
    if group == "tp_text":
        return kit.word("w", "ab", status="incorrect", tv="incorrect", tm="خطأ", tokens=None)
    if group == "fn_mid":
        return kit.word("w", "ab", tokens=[kit.tok("ب", start, start + 40, 0, "ok", 0.50, 0.15, "ع", 1.204), last])
    if group == "fn_deep":
        return kit.word("w", "ab", tokens=[kit.tok("ب", start, start + 40, 0, "ok", 0.90, 0.02, "ع"), last])
    ratio = 2.2 if group == "fn_duration" else 1.0
    return kit.word("w", "ab", tokens=[kit.tok("ب", start, start + 40), kit.tok("ا", start + 80, start + 120, 0, "ok", 0.97, 0.01, "", None, ratio),
                                       kit.tok("ا", start + 160, start + 200, 0, "unit"), kit.tok("ت", start + 240, start + 280)])


LABEL_FOR = {
    "tn_strong": ("confirmed", []), "tn_mid": ("confirmed", []), "fp_weak": ("false_alarm", []),
    "tp_sub": ("confirmed", ["tafkheem"]), "tp_text": ("confirmed", ["haraka"]),
    "fn_mid": ("missed", ["haraka"]), "fn_deep": ("missed", ["ikhfa"]),
    "madd_ok": ("confirmed", []), "fn_duration": ("missed", ["madd"]),
}


def build_dataset(extra_unlabelled=0):
    """Records and label lines with the confusion counts worked out by hand in the tests."""
    records, lines = [], []
    cases = []
    for group, n in GROUPS:
        cases += [group] * n
    # the three held-sound words must share one ayah (the preset needs 3 runs to know the tempo)
    madd = [g for g in cases if g in ("madd_ok", "fn_duration")]
    rest = [g for g in cases if g not in ("madd_ok", "fn_duration")]
    chunks = [rest[i:i + 4] for i in range(0, len(rest), 4)] + [madd]
    chunks += [["tn_strong"] * 4 for _ in range(extra_unlabelled // 4)]
    for n, chunk in enumerate(chunks):
        rid = "112-%d-1" % (n + 1)
        words, heard, start = [], [], 400
        for group in chunk:
            w = group_word(group, start)
            words.append(w)
            heard.append(("ب", start))
            start += 400
        record = kit.make_record(rid, ayah=n + 1, words=words, heard=heard, window=(320, start + 400))
        records.append(record)
        if n >= len(chunks) - extra_unlabelled // 4 and extra_unlabelled:
            continue
        for i, group in enumerate(chunk):
            code, types = LABEL_FOR[group]
            lines.append(kit.label(i, code, types, rid=rid, ayah=n + 1, shown=words[i]["st"]))
    return records, lines


def to_jsonl(records, lines):
    return "\n".join(json.dumps(x, ensure_ascii=False) for x in list(records) + list(lines))


def analyze(extra_unlabelled=0, **kw):
    records, lines = build_dataset(extra_unlabelled)
    return la.analyze(to_jsonl(records, lines), **kw)


class IngestionTests(unittest.TestCase):
    def test_jsonl_and_export_document_are_equivalent(self):
        records, lines = build_dataset()
        from_log = la.analyze(to_jsonl(records, lines))
        doc = rr.export_document(records, lines, "t")
        from_export = la.analyze(json.dumps(doc, ensure_ascii=False))
        self.assertEqual(from_log["overall"], from_export["overall"])

    def test_bad_lines_and_old_records_are_counted_not_fatal(self):
        records, lines = build_dataset()
        text = "not json\n[1,2]\n" + json.dumps({"v": 2, "expected": ["x"]}) + "\n" + to_jsonl(records, lines)
        result = la.analyze(text)
        self.assertEqual(result["coverage"]["bad_lines"], 2)
        self.assertEqual(result["coverage"]["old_v2_records"], 1)
        self.assertEqual(result["overall"]["tp"], 13)

    def test_orphan_and_inconsistent_labels_are_excluded_and_reported(self):
        records, lines = build_dataset()
        lines.append(kit.label(0, "confirmed", rid="no-such-record"))
        # a false alarm on a word the app did not flag, a miss on one it did
        lines.append(kit.label(0, "false_alarm", rid="112-1-1", ayah=1))
        flagged_word = [i for i, w in enumerate(records[0]["words"]) if w["st"] in rr.FLAGGED_STATUSES]
        if flagged_word:
            lines.append(kit.label(flagged_word[0], "missed", rid="112-1-1", ayah=1))
        result = la.analyze(to_jsonl(records, lines))
        self.assertEqual(result["coverage"]["orphan_labels"], 1)
        self.assertGreaterEqual(result["coverage"]["inconsistent_labels"], 1)

    def test_a_later_label_replaces_an_earlier_one_and_none_removes(self):
        records, lines = build_dataset()
        before = la.analyze(to_jsonl(records, lines))["coverage"]["labelled_words"]
        lines.append(kit.label(0, "none", rid="112-1-1", ayah=1))
        after = la.analyze(to_jsonl(records, lines))["coverage"]["labelled_words"]
        self.assertEqual(after, before - 1)

    def test_empty_input(self):
        result = la.analyze("")
        self.assertEqual(result["overall"]["tp"], 0)
        self.assertIsNone(result["overall"]["precision"])
        self.assertTrue(result["warnings"])
        la.render(result)


class MetricTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = analyze()

    def test_confusion_counts_worked_out_by_hand(self):
        o = self.result["overall"]
        self.assertEqual((o["tp"], o["fp"], o["fn"], o["tn"]), (13, 4, 8, 40))
        self.assertAlmostEqual(o["precision"], 13 / 17)
        self.assertAlmostEqual(o["recall"], 13 / 21)
        self.assertAlmostEqual(o["false_alarm_rate"], 4 / 44)
        self.assertEqual((o["correct_words"], o["error_words"]), (44, 21))

    def test_precision_of_each_kind_of_flag(self):
        kinds = self.result["by_kind"]
        self.assertEqual((kinds["weak"]["flagged"], kinds["weak"]["confirmed"]), (4, 0))
        self.assertEqual((kinds["substitution"]["flagged"], kinds["substitution"]["confirmed"]), (10, 10))
        self.assertEqual((kinds["text:incorrect"]["flagged"], kinds["text:incorrect"]["confirmed"]), (3, 3))
        self.assertEqual(kinds["weak"]["precision"], 0.0)

    def test_recall_of_each_error_type_the_reader_named(self):
        table = self.result["by_type_recall"]
        self.assertEqual((table["tafkheem"]["errors"], table["tafkheem"]["detected"]), (10, 10))
        self.assertEqual((table["haraka"]["errors"], table["haraka"]["detected"]), (7, 3))
        self.assertEqual((table["ikhfa"]["errors"], table["ikhfa"]["detected"]), (3, 0))
        self.assertEqual((table["madd"]["errors"], table["madd"]["detected"]), (1, 0))
        self.assertEqual(table["ikhfa"]["recall"], 0.0)

    def test_type_matrix(self):
        m = self.result["type_matrix"]
        self.assertEqual(m["matrix"]["tafkheem"], {"tafkheem": 10})
        self.assertEqual(m["matrix"]["haraka"], {"other": 3, "none": 4})
        self.assertEqual(m["matrix"]["none"], {"harf": 4})
        self.assertEqual(m["matrix"]["ikhfa"], {"none": 3})
        self.assertEqual(m["per_class"]["tafkheem"]["precision"], 1.0)
        self.assertEqual(m["per_class"]["tafkheem"]["recall"], 1.0)
        self.assertEqual(m["per_class"]["haraka"]["recall"], 0.0)

    def test_coverage(self):
        c = self.result["coverage"]
        self.assertEqual(c["labelled_words"], 65)
        self.assertEqual(c["judged_words"], 65)
        self.assertEqual(c["implicit_correct_words"], 0)

    def test_wilson_interval(self):
        lo, hi = la.wilson(4, 44)
        self.assertLess(lo, 4 / 44)
        self.assertGreater(hi, 4 / 44)
        self.assertEqual(la.wilson(0, 0), [0.0, 1.0])
        lo0, hi0 = la.wilson(0, 30)
        self.assertEqual(lo0, 0.0)
        self.assertAlmostEqual(hi0, 0.1135, places=3)

    def test_unlabelled_correct_words_count_only_on_request(self):
        plain = analyze(extra_unlabelled=8)["overall"]
        assumed = analyze(extra_unlabelled=8, assume_unlabeled_correct=True)
        self.assertEqual(plain["tn"], 40)
        self.assertEqual(assumed["overall"]["tn"], 48)
        self.assertEqual(assumed["coverage"]["implicit_correct_words"], 8)
        self.assertEqual(assumed["overall"]["tn"] + assumed["overall"]["fp"], 52)

    def test_small_samples_are_marked_exploratory(self):
        result = analyze()
        self.assertFalse(result["exploratory"])   # 44 correct and 21 erroneous words meet both minimums
        self.assertEqual((la.MIN_CORRECT, la.MIN_ERRORS), (30, 10))
        records, lines = build_dataset()
        tiny = la.analyze(to_jsonl(records[:1], [l for l in lines if l["rid"] == records[0]["rid"]]))
        self.assertTrue(tiny["exploratory"])
        self.assertTrue(any("كلمات صحيحة موسومة" in w for w in tiny["warnings"]))


class SimulationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = analyze()["_rows"]

    def curve(self, name):
        return analyze()["sweeps"][name]

    def test_p_ref_sweep_values_worked_out_by_hand(self):
        by_theta = {e["theta"]: e for e in self.curve("p_ref_warn")}
        e = by_theta[0.6]
        self.assertEqual((e["tp"], e["fp"], e["fn"], e["tn"]), (17, 12, 4, 32))
        e = by_theta[0.2]
        self.assertEqual((e["tp"], e["fp"], e["fn"], e["tn"]), (13, 0, 8, 44))

    def test_margin_sweep(self):
        by_theta = {e["theta"]: e for e in self.curve("margin_warn")}
        e = by_theta[1.5]
        self.assertEqual((e["tp"], e["fp"]), (17, 0))

    def test_duration_sweep_catches_the_long_madd(self):
        by_theta = {e["theta"]: e for e in self.curve("duration_high")}
        self.assertEqual(by_theta[2.0]["tp"], 14)
        self.assertEqual(by_theta[2.5]["tp"], 13)

    def test_every_sweep_is_monotone(self):
        sweeps = analyze()["sweeps"]
        growing = ("p_ref_warn", "margin_warn", "duration_low")
        for name, entries in sweeps.items():
            flagged = [e["tp"] + e["fp"] for e in entries]
            if name in growing:
                self.assertEqual(flagged, sorted(flagged), name)
            else:
                self.assertEqual(flagged, sorted(flagged, reverse=True), name)

    def test_baselines_are_the_engine_presets(self):
        base = analyze()["baselines"]
        self.assertEqual(set(base), {"strict", "balanced", "maximum"})
        self.assertEqual(base["balanced"]["cfg"], la.preset_cfg("balanced"))
        # balanced on its own logs reproduces what the app showed
        m = base["balanced"]["metrics"]
        self.assertEqual((m["tp"], m["fp"], m["fn"], m["tn"]), (13, 4, 8, 40))

    def test_suggestion_respects_the_false_alarm_budget_and_finds_the_separable_errors(self):
        sug = analyze(target_fpr=0.02)["suggestion"]
        self.assertTrue(sug["within_budget"])
        for entry in sug["within_budget"]:
            self.assertLessEqual(entry["metrics"]["false_alarm_rate"], 0.02)
        best = sug["within_budget"][0]["metrics"]
        self.assertGreaterEqual(best["recall"], 17 / 21 - 1e-9)   # tp_sub, tp_text, fn_mid (+ the long madd)
        self.assertLess(best["recall"], 1.0)                     # fn_deep (3 words) is invisible to any threshold
        self.assertEqual(sug["evaluated"], 9 * 8 * 6 * 3 * 3)

    def test_nothing_is_suggested_when_no_correct_word_is_labelled(self):
        records, lines = build_dataset()
        # keep only words that really are errors (a false alarm is a truly correct word)
        only_errors = [l for l in lines if l["label"] == "missed" or (l["label"] == "confirmed" and l["types"])]
        result = la.analyze(to_jsonl(records, only_errors))
        self.assertEqual(result["overall"]["correct_words"], 0)
        self.assertEqual(result["suggestion"]["within_budget"], [])


class SimulationMatchesTheRealJudge(unittest.TestCase):
    """frame_flag() must agree with judge_ref.judge() on the numbers the app logs."""

    BLANK = 11
    DURATION_IDS = {0, 1}

    def scenario(self, seed):
        import random
        rng = random.Random(seed)
        words = []
        targets = []
        word_of = []
        for w in range(rng.randint(2, 5)):
            count = rng.randint(2, 5)
            ids = []
            while len(ids) < count:
                token = rng.choice([0, 0, 1, 2, 3, 4, 5, 6, 7])
                ids.append(token)
                if token in self.DURATION_IDS and rng.random() < 0.6 and len(ids) < count + 2:
                    ids.append(token)
                    if rng.random() < 0.4:
                        ids.append(token)
            words.append(list(range(len(targets), len(targets) + len(ids))))
            targets += ids
            word_of += [w] * len(ids)
        # held sounds are spread unevenly so the duration pass has long and short runs to find
        positions, t = [], 2
        for token in targets:
            positions.append(t)
            t += rng.choice([3, 3, 5, 8]) if token in self.DURATION_IDS else 3
        frames = t + 4
        logp = []
        for _ in range(frames):
            row = [0.0005] * 12
            row[self.BLANK] = 0.9
            logp.append(row)
        for j, token in enumerate(targets):
            t = positions[j]
            p = rng.choice([rng.uniform(0.05, 0.4), rng.uniform(0.4, 0.99), rng.uniform(0.85, 0.995)])
            q = rng.choice([0.0, rng.uniform(0.0, 0.3), rng.uniform(0.2, 0.9)]) * (1.0 - p)
            comp = rng.choice([c for c in range(11) if c != token])
            row = [0.0005] * 12
            row[token] = p
            row[comp] = max(row[comp], q)
            row[self.BLANK] = max(0.0005, 1.0 - sum(row[:11]))
            total = sum(row)
            logp[t] = [v / total for v in row]
        logp = [[math.log(max(v, 1e-9)) for v in row] for row in logp]
        soft = {w[-1] for w in words}
        hard = set()
        for w in words[1:]:
            if rng.random() < 0.3 and len(w) >= 2:
                hard |= {w[0], w[1]}
        return logp, targets, words, word_of, soft, hard

    def rows_for(self, findings, words):
        out = []
        for w, idx in enumerate(words):
            tokens = []
            for j in idx:
                f = findings[j]
                margin = 99.0 if math.isinf(f["margin"]) else f["margin"]
                tokens.append({"j": j, "label": str(f["token"]), "start_ms": f["start"] * 40, "end_ms": f["end"] * 40,
                               "severity": f["severity"], "kind": f["kind"], "p_ref": round(f["p_ref"], 4),
                               "p_comp": round(f["p_comp"], 4), "comp": str(f["comp"]), "margin": round(margin, 4),
                               "ratio": round(f["ratio"], 4)})
            out.append(tokens)
        return out

    def near_a_threshold(self, tokens, cfg):
        for t in tokens:
            for value, edge in ((t["p_ref"], cfg["p_ref_warn"]), (t["margin"], cfg["margin_warn"]),
                                (t["p_comp"], cfg["p_comp_warn"]), (t["p_comp"], cfg["p_comp_hard"]),
                                (t["margin"], 0.0), (t["ratio"], cfg["duration_high"]),
                                (t["ratio"], cfg["duration_low"]), (t["ratio"], rr.PAUSE_RATIO)):
                if not math.isinf(edge) and abs(value - edge) < 2e-3:
                    return True
        return False

    def test_flag_simulation_equals_the_judge_for_every_preset(self):
        compared = flagged_any = 0
        kinds_seen = set()
        for seed in range(120):
            logp, targets, words, word_of, soft, hard = self.scenario(seed)
            for name in ("strict", "balanced", "maximum"):
                findings = jr.judge(logp, targets, self.BLANK, name, soft, hard, self.DURATION_IDS)
                rows = self.rows_for(findings, words)
                runs = sum(1 for tokens in rows for t in tokens if t["ratio"] > 0)
                cfg = la.preset_cfg(name)
                for tokens in rows:
                    kinds_seen.update(t["kind"] for t in tokens)
                    real = any(t["severity"] > 0 for t in tokens)
                    row = {"tokens": tokens, "last_j": max(t["j"] for t in tokens), "ayah_runs": runs}
                    sim = la.frame_flag(row, cfg)
                    if sim != real and self.near_a_threshold(tokens, cfg):
                        continue
                    self.assertEqual(sim, real, (seed, name, tokens))
                    compared += 1
                    flagged_any += 1 if real else 0
        self.assertGreater(compared, 800)
        self.assertGreater(flagged_any, 100)
        self.assertLess(flagged_any, compared)
        # the comparison is only meaningful if every way of being flagged was actually exercised
        for kind in ("weak", "close", "substitution", "edge", "exempt", "unit"):
            self.assertIn(kind, kinds_seen)

    def duration_scenario(self, seed):
        """Runs of a held sound with uneven spacing, each followed by a plain token."""
        import random
        rng = random.Random(1000 + seed)
        targets, words, positions, t = [], [], [], 2
        for _ in range(rng.randint(3, 6)):
            held = rng.choice([0, 1])
            units = rng.choice([2, 2, 3])
            spacing = rng.choice([2, 3, 3, 3, 3, 6, 9, 12])
            first = len(targets)
            for _ in range(units):
                targets.append(held)
                positions.append(t)
                t += spacing
            targets.append(rng.choice([2, 3, 4, 5, 6, 7]))
            positions.append(t)
            t += 3
            words.append(list(range(first, len(targets))))
        logp = []
        for _ in range(t + 4):
            row = [0.0005] * 12
            row[self.BLANK] = 0.9
            logp.append(row)
        for j, token in enumerate(targets):
            row = [0.0005] * 12
            row[token] = 0.9
            row[self.BLANK] = 0.05
            total = sum(row)
            logp[positions[j]] = [v / total for v in row]
        logp = [[math.log(max(v, 1e-9)) for v in row] for row in logp]
        return logp, targets, words, {w[-1] for w in words}

    def test_duration_flags_equal_the_judge(self):
        kinds_seen, flagged, compared = set(), 0, 0
        for seed in range(150):
            logp, targets, words, soft = self.duration_scenario(seed)
            for name in ("strict", "balanced", "maximum"):
                findings = jr.judge(logp, targets, self.BLANK, name, soft, set(), self.DURATION_IDS)
                rows = self.rows_for(findings, words)
                runs = sum(1 for tokens in rows for t in tokens if t["ratio"] > 0)
                cfg = la.preset_cfg(name)
                for tokens in rows:
                    kinds_seen.update(t["kind"] for t in tokens)
                    real = any(t["severity"] > 0 for t in tokens)
                    row = {"tokens": tokens, "last_j": max(t["j"] for t in tokens), "ayah_runs": runs}
                    sim = la.frame_flag(row, cfg)
                    if sim != real and self.near_a_threshold(tokens, cfg):
                        continue
                    self.assertEqual(sim, real, (seed, name, tokens))
                    compared += 1
                    flagged += 1 if real else 0
        self.assertIn("long", kinds_seen)
        self.assertIn("short", kinds_seen)
        self.assertGreater(flagged, 40)
        self.assertGreater(compared, 1000)

    def test_balanced_measures_but_never_flags_durations(self):
        for seed in range(40):
            logp, targets, words, soft = self.duration_scenario(seed)
            findings = jr.judge(logp, targets, self.BLANK, "balanced", soft, set(), self.DURATION_IDS)
            self.assertTrue(all(f["kind"] not in ("long", "short") for f in findings))
            measured = [f for f in findings if f["ratio"] > 0]
            runs = sum(1 for w in words if len([j for j in w if targets[j] in self.DURATION_IDS]) > 1)
            if runs >= jr.MEASURE_MIN_RUNS:
                self.assertTrue(measured, seed)


class CommandLineTests(unittest.TestCase):
    def test_cli_prints_the_report_and_writes_strict_json(self):
        records, lines = build_dataset()
        with tempfile.TemporaryDirectory() as folder:
            source = os.path.join(folder, "evidence.jsonl")
            target = os.path.join(folder, "out.json")
            with open(source, "w", encoding="utf-8") as handle:
                handle.write(to_jsonl(records, lines))
            import io
            from contextlib import redirect_stdout
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = la.main([source, "--json", target, "--target-fpr", "0.05"])
            self.assertEqual(code, 0)
            out = buffer.getvalue()
            for heading in ("== التغطية ==", "== الأداء الكلي", "== مصفوفة الارتباك", "== منحنيات العتبة",
                            "== اقتراح العتبات"):
                self.assertIn(heading, out)
            with open(target, encoding="utf-8") as handle:
                text = handle.read()
            self.assertNotIn("Infinity", text)
            self.assertNotIn("NaN", text)
            data = json.loads(text)
            self.assertEqual(data["overall"]["tp"], 13)


if __name__ == "__main__":
    unittest.main()
