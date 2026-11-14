import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))
sys.path.insert(0, os.path.join(ROOT, "test"))

import judge_ref as jr  # noqa: E402
import report_ref as rr  # noqa: E402
import report_testkit as kit  # noqa: E402
import wav_ref  # noqa: E402

SCENARIOS = {name: (record, labels) for name, record, labels in kit.scenarios()}


def report(name):
    record, labels = SCENARIOS[name]
    return rr.build_ayah_report(record, labels)


class FormatTests(unittest.TestCase):
    def test_fmt2_is_integer_arithmetic(self):
        cases = [(0.0, "0.00"), (0.5, "0.50"), (0.97, "0.97"), (1.4469, "1.45"), (-0.539, "-0.54"),
                 (-0.001, "0.00"), (2.2, "2.20"), (12.345, "12.35"), (0.004, "0.00"), (0.005, "0.01"),
                 (98.99, "98.99"), (99.0, "∞"), (-99.0, "-∞"), (None, "—"), (float("nan"), "—")]
        for value, want in cases:
            self.assertEqual(rr.fmt2(value), want, value)

    def test_norm_label_drops_word_marks_and_spaces(self):
        self.assertEqual(rr.norm_label("\u2581ق"), "ق")
        self.assertEqual(rr.norm_label(" \u00a0ل\t"), "ل")
        self.assertEqual(rr.norm_label("\u2581"), "")
        self.assertEqual(rr.norm_label("َ"), "َ")


class AlignTests(unittest.TestCase):
    def test_identical(self):
        self.assertEqual(rr.align_ops(list("abc"), list("abc")), [["=", "a", "a"], ["=", "b", "b"], ["=", "c", "c"]])

    def test_empty_sides(self):
        self.assertEqual(rr.align_ops([], []), [])
        self.assertEqual(rr.align_ops(list("ab"), []), [["-", "a", ""], ["-", "b", ""]])
        self.assertEqual(rr.align_ops([], list("ab")), [["+", "", "a"], ["+", "", "b"]])

    def test_one_missing_and_one_extra_have_a_single_minimal_alignment(self):
        self.assertEqual(rr.align_ops(list("abcd"), list("abd")),
                         [["=", "a", "a"], ["=", "b", "b"], ["-", "c", ""], ["=", "d", "d"]])
        self.assertEqual(rr.align_ops(list("abd"), list("abcd")),
                         [["=", "a", "a"], ["=", "b", "b"], ["+", "", "c"], ["=", "d", "d"]])

    def test_substitution(self):
        self.assertEqual(rr.align_ops(list("صلى"), list("سلى")),
                         [["~", "ص", "س"], ["=", "ل", "ل"], ["=", "ى", "ى"]])

    def test_ties_prefer_substitution_over_gap_pairs(self):
        # both readings cost 2; the diagonal wins so a heard sound is shown as a replacement
        ops = rr.align_ops(list("klmt"), list("kmnt"))
        self.assertEqual([op[0] for op in ops], ["=", "~", "~", "="])

    def test_cost_is_edit_distance(self):
        import random
        rng = random.Random(7)
        for _ in range(200):
            a = [rng.choice("abc") for _ in range(rng.randint(0, 7))]
            b = [rng.choice("abc") for _ in range(rng.randint(0, 7))]
            ops = rr.align_ops(a, b)
            cost = sum(1 for op in ops if op[0] != "=")
            self.assertEqual([op[1] for op in ops if op[0] in "=~-"], a)
            self.assertEqual([op[2] for op in ops if op[0] in "=~+"], b)
            dp = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
            for i in range(len(a) + 1):
                for j in range(len(b) + 1):
                    if i == 0 or j == 0:
                        dp[i][j] = i + j
                    else:
                        dp[i][j] = min(dp[i - 1][j - 1] + (a[i - 1] != b[j - 1]), dp[i - 1][j] + 1, dp[i][j - 1] + 1)
            self.assertEqual(cost, dp[len(a)][len(b)])


class AttributionTests(unittest.TestCase):
    def test_clean_ayah_is_fully_attributed_and_matched(self):
        rep = report("clean_ayah")
        self.assertTrue(rep["has_frames"])
        self.assertEqual(rep["counts"]["correct"], 3)
        self.assertEqual(rep["unattributed"], [])
        for w in rep["words"]:
            self.assertEqual(w["heard_scope"], "window")
            self.assertTrue(all(op[0] == "=" for op in w["ops"]))
        self.assertEqual(rep["words"][0]["span_ms"], [400, 520])
        self.assertEqual(rep["watch"], [])

    def test_text_rejected_word_gets_its_gap_and_pending_word_gets_nothing(self):
        rep = report("text_rejected_gap")
        w1, w3 = rep["words"][1], rep["words"][3]
        self.assertEqual(w1["heard_scope"], "gap")
        self.assertEqual(w1["heard"], [["ه", 800]])
        self.assertIsNone(w1["ops"])
        self.assertIsNone(w1["span_ms"])
        self.assertEqual(w3["heard"], [])
        self.assertEqual(w3["status"], "pending")

    def test_two_rejected_words_share_the_gap(self):
        rep = report("shared_gap")
        a, b = rep["words"][1], rep["words"][2]
        self.assertEqual(a["heard_scope"], "gap_shared")
        self.assertEqual(a["heard"], b["heard"])
        self.assertEqual(a["heard"], [["ه", 800], ["ل", 1000]])

    def test_slack_boundary_and_window(self):
        rep = report("slack_and_unattributed")
        w0, w1 = rep["words"]
        # 530 ms is 11 ms past word 0's span: owned by it; 560 ms is 41 ms past: owned by nobody
        self.assertIn(["ن", 530], w0["heard"])
        self.assertEqual(rep["unattributed"], [["ا", 560]])
        self.assertIn(["ن", 830], w1["heard"])
        # the sound at 100 ms (before the window) and at 900 ms (after it) belong to other ayahs
        flat = [t for w in rep["words"] for t in w["heard"]] + rep["unattributed"]
        self.assertNotIn(["ب", 100], flat)
        self.assertNotIn(["م", 900], flat)

    def test_missing_and_extra_sounds_are_shown(self):
        rep = report("missing_and_extra")
        self.assertEqual([op[0] for op in rep["words"][0]["ops"]], ["=", "-", "=", "="])
        self.assertEqual([op[0] for op in rep["words"][1]["ops"]], ["=", "=", "+", "=", "="])

    def test_elided_hamza_is_not_expected_in_the_diff(self):
        rep = report("watch_items")
        w = rep["words"][3]
        self.assertEqual(w["expected_labels"], ["ء", "ل", "ا", "ا", "ب"])
        self.assertTrue(all(op[0] == "=" for op in w["ops"]))
        self.assertEqual(len(w["ops"]), 3)

    def test_approximate_reference_has_no_windows(self):
        rep = report("approximate_reference")
        self.assertFalse(rep["has_frames"])
        self.assertEqual(rep["counts"]["uncertain"], 2)
        for w in rep["words"]:
            self.assertEqual(w["heard_scope"], "none")
            self.assertEqual(w["heard"], [])
        self.assertEqual(rep["watch"], [])

    def test_times_may_arrive_as_numbers(self):
        record, _ = SCENARIOS["clean_ayah"]
        copy = json.loads(json.dumps(record))
        copy["times"] = [float(t) for t in copy["times"]]
        self.assertEqual(rr.build_ayah_report(copy)["words"][0]["heard"], [["ق", 400], ["ل", 480]])


class VerdictTests(unittest.TestCase):
    def test_frame_verdict_decides_and_is_explained(self):
        w = report("substitution_applied")["words"][0]
        self.assertEqual(w["status"], "incorrect")
        self.assertEqual(w["source"], "frame")
        self.assertEqual(w["frame"]["flag"]["kind"], "substitution")
        text = "\n".join(w["reasons"])
        self.assertIn("المقيّم النصي: صحيحة", text)
        self.assertIn("استبدال", text)
        self.assertIn("p_ref=0.35", text)
        self.assertIn("«س»", text)
        self.assertIn("الهامش=-0.54", text)
        self.assertIn("أُضيف حكم الحَكَم الإطاري", text)
        self.assertIn("المصدر: الحَكَم الإطاري", text)

    def test_text_verdict_with_history_and_message(self):
        w = report("text_rejected_gap")["words"][1]
        text = "\n".join(w["reasons"])
        self.assertEqual(w["source"], "text")
        self.assertIn("المقيّم النصي: خطأ — المسموع هـ بدل هو", text)
        self.assertIn("تسلسل الأحكام: تنبيه تجويدي ثم خطأ", text)
        self.assertIn("خارج المرجع الإطاري", text)

    def test_unread_and_approximate_words(self):
        pending = report("text_rejected_gap")["words"][3]
        self.assertEqual(pending["source"], "none")
        self.assertIn("المقيّم النصي: لم يُصدر حكمًا", pending["reasons"][0])
        self.assertIn("لم تُقرأ بعد", pending["reasons"][1])
        approx = report("approximate_reference")["words"][0]
        self.assertIn("لم يُجرَ (مرجع تقريبي: لا تحليل إطاري)", "\n".join(approx["reasons"]))

    def test_guard_suppression_is_explained(self):
        w = report("guard_suppressed")["words"][0]
        self.assertEqual(w["status"], "correct")
        self.assertIn("عُلّق حكم الحَكَم الإطاري", "\n".join(w["reasons"]))
        self.assertIn("40٪", "\n".join(w["reasons"]))

    def test_unflagged_word_shows_its_weakest_token(self):
        w = report("watch_items")["words"][0]
        self.assertIn("لا ملاحظة؛ أضعف رمز «ا»: p_ref=0.52", "\n".join(w["reasons"]))

    def test_every_word_ends_with_a_final_line(self):
        for name in SCENARIOS:
            for w in report(name)["words"]:
                self.assertTrue(w["reasons"][-1].startswith("الحكم النهائي: "), (name, w["i"]))


class WatchTests(unittest.TestCase):
    def test_order_and_kinds(self):
        watch = report("watch_items")["watch"]
        self.assertEqual([e["word"] for e in watch], [2, 0, 1])
        self.assertEqual([[i["type"] for i in e["items"]] for e in watch], [["duration"], ["weak"], ["close"]])
        self.assertAlmostEqual(watch[0]["doubt"], 1.0 - 1.0 / 2.1, places=12)

    def test_ignored_kinds_never_count(self):
        # word d holds exempt, unit and edge tokens with terrible numbers
        indexes = [e["word"] for e in report("watch_items")["watch"]]
        self.assertNotIn(3, indexes)

    def test_suppressed_words_come_first_then_by_doubt(self):
        watch = report("guard_suppressed")["watch"]
        self.assertEqual([(e["word"], e["suppressed"]) for e in watch], [(4, True), (2, True), (0, True), (1, False)])

    def test_thresholds_are_exclusive(self):
        base, _ = SCENARIOS["clean_ayah"]
        for p_ref, p_comp, margin, listed in [(0.60, 0.01, 4.0, False), (0.5999, 0.01, 4.0, True),
                                              (0.9, 0.08, 1.5, False), (0.9, 0.08, 1.4999, True),
                                              (0.9, 0.0799, 1.0, False)]:
            words = [kit.word("w", "ab", tokens=[kit.tok("a", 400, 440, 0, "ok", p_ref, p_comp, "c", margin),
                                                 kit.tok("b", 480, 520)])]
            rec = kit.make_record(words=words, heard=[("a", 400), ("b", 480)], window=(320, 800))
            self.assertEqual(bool(rr.build_ayah_report(rec)["watch"]), listed, (p_ref, p_comp, margin))

    def test_flagged_words_are_not_in_the_watch_list(self):
        for name in SCENARIOS:
            rep = report(name)
            for e in rep["watch"]:
                self.assertEqual(rep["words"][e["word"]]["status"], "correct")


class LabelTests(unittest.TestCase):
    def test_codes_and_types_are_the_agreed_vocabulary(self):
        self.assertEqual(rr.LABEL_CODES, ("confirmed", "false_alarm", "missed"))
        self.assertEqual([c for c, _ in rr.ERROR_TYPES][:7],
                         ["haraka", "madd", "ghunna", "ikhfa", "idgham", "qalqala", "harf"])
        self.assertEqual(dict(rr.LABELS)["false_alarm"], "إنذار كاذب: قلتها صحيحة")
        self.assertEqual(len(set(rr.ERROR_TYPE_CODES)), len(rr.ERROR_TYPE_CODES))

    def test_validation_matrix(self):
        ok = lambda *a, **k: rr.make_label(*a, **k)  # noqa: E731
        self.assertEqual(ok("confirmed", ["madd"], " note ", "warning")[0],
                         {"label": "confirmed", "types": ["madd"], "note": "note"})
        self.assertEqual(ok("missed", ["haraka", "madd", "haraka"], "", "correct")[0]["types"], ["haraka", "madd"])
        self.assertEqual(ok("false_alarm", [], "", "warning")[1], None)
        self.assertEqual(ok("false_alarm", [], "", "correct")[1], "false_alarm_needs_flagged")
        self.assertEqual(ok("missed", [], "", "incorrect")[1], "missed_needs_unflagged")
        self.assertEqual(ok("missed", [], "", "pending")[1], None)
        self.assertEqual(ok("confirmed", ["madd"], "", "correct")[1], "type_without_error")
        self.assertEqual(ok("false_alarm", ["madd"], "", "warning")[1], "type_without_error")
        self.assertEqual(ok("confirmed", ["nope"], "", "warning")[1], "unknown_type")
        self.assertEqual(ok("maybe", [], "", "warning")[1], "unknown_label")
        self.assertEqual(ok("missed", ["haraka", "madd", "ghunna", "ikhfa"], "", "correct")[1], "too_many_types")
        self.assertEqual(len(ok("confirmed", [], "x" * 900, "correct")[0]["note"]), rr.MAX_NOTE)
        self.assertEqual(ok("none", [], "", "correct")[0]["label"], "none")

    def test_label_line_links_to_record_and_word(self):
        record, _ = SCENARIOS["substitution_applied"]
        label, error = rr.make_label("confirmed", ["tafkheem"], "ص", "incorrect")
        self.assertIsNone(error)
        line = rr.label_line(record, 0, label, "2026-11-02T10:05:00Z")
        self.assertEqual(line["kind"], "label")
        self.assertEqual((line["v"], line["rid"], line["surah"], line["ayah"], line["word"]), (3, "112-2-100", 112, 2, 0))
        self.assertEqual(line["shown"], "incorrect")
        self.assertEqual(line["types"], ["tafkheem"])

    def test_latest_label_wins_and_none_removes(self):
        lines = [
            {"kind": "label", "rid": "r", "word": 1, "label": "confirmed", "types": [], "note": ""},
            {"kind": "label", "rid": "r", "word": 1, "label": "missed", "types": ["madd"], "note": ""},
            {"kind": "label", "rid": "r", "word": 2, "label": "confirmed", "types": [], "note": ""},
            {"kind": "label", "rid": "r", "word": 2, "label": "none", "types": [], "note": ""},
            {"kind": "record", "rid": "r", "word": 3, "label": "confirmed"},
        ]
        latest = rr.latest_labels(lines)
        self.assertEqual(list(latest), [("r", 1)])
        self.assertEqual(latest[("r", 1)]["label"], "missed")

    def test_labels_show_up_in_the_report_and_summary(self):
        rep = report("labels_merged")
        self.assertEqual(rep["words"][0]["label"]["types"], ["tafkheem"])
        text = rr.summary_text(rep)
        self.assertIn("التسمية: صحيح (تفخيم/ترقيق) — ص مكان س", text)


class SummaryAndExportTests(unittest.TestCase):
    def test_summary_is_deterministic_and_complete(self):
        rep = report("text_rejected_gap")
        first, second = rr.summary_text(rep), rr.summary_text(rep)
        self.assertEqual(first, second)
        self.assertIn("تقرير رَفِيق الفني — سورة 112 آية 3", first)
        self.assertIn("الكلمات: 4 — صحيحة 2، تنبيه 0، خطأ 1، غير حاسم 0، لم تُقرأ 1", first)
        self.assertIn("المحاذاة: ق ل", first)
        self.assertIn("الزمن: من 400 إلى 520 مللي ثانية", first)
        self.assertIn("المسموع: ه@800", first)

    def test_summary_lists_the_watch_section(self):
        text = rr.summary_text(report("watch_items"))
        self.assertIn("ما لم يُرصد", text)
        self.assertIn("كلمة 3: زمن المدّ بعيد عن المعتاد", text)
        self.assertIn("كلمة 1: ثقة منخفضة", text)

    def test_ops_render(self):
        self.assertEqual(rr._op_text(["~", "ص", "س"]), "ص←س")
        self.assertEqual(rr._op_text(["-", "ل", ""]), "[ناقص ل]")
        self.assertEqual(rr._op_text(["+", "", "ن"]), "[زائد ن]")

    def test_export_document_merges_latest_labels_by_record(self):
        records = [SCENARIOS["substitution_applied"][0], SCENARIOS["labels_merged"][0]]
        lines = [
            rr.label_line(records[0], 0, {"label": "confirmed", "types": [], "note": ""}, "t1"),
            rr.label_line(records[0], 0, {"label": "confirmed", "types": ["tafkheem"], "note": ""}, "t2"),
            rr.label_line(records[1], 1, {"label": "confirmed", "types": [], "note": ""}, "t3"),
        ]
        doc = rr.export_document(records, lines, "2026-11-02T11:00:00Z")
        self.assertEqual(doc["format"], "rafiq-report/3")
        self.assertEqual(len(doc["records"]), 2)
        self.assertEqual(len(doc["labels"]), 2)
        self.assertEqual(doc["reports"][0]["words"][0]["label"]["types"], ["tafkheem"])
        self.assertIsNone(doc["reports"][1]["words"][0]["label"])
        self.assertEqual(doc["reports"][1]["words"][1]["label"]["label"], "confirmed")
        json.loads(rr.dumps(doc))


class JudgeMeasurementTests(unittest.TestCase):
    """The held-sound ratio is measured under every preset; only flagging depends on the preset."""

    def setUp(self):
        with open(os.path.join(ROOT, "test", "fixtures", "frame_golden.json"), encoding="utf-8") as handle:
            golden = json.load(handle)
        self.case = [s for s in golden["judge"]["scenarios"] if s["name"] == "duration_runs"][0]

    def run_preset(self, name):
        c = self.case
        return jr.judge(c["matrix"], c["targets"], c["blank"], name, set(c["softExempt"]),
                        set(c["allExempt"]), set(c["durationIds"]))

    def test_balanced_measures_the_same_ratios_as_strict_but_never_flags(self):
        strict, balanced = self.run_preset("strict"), self.run_preset("balanced")
        self.assertEqual([r["ratio"] for r in balanced], [r["ratio"] for r in strict])
        self.assertTrue(any(r["ratio"] > 0 for r in balanced))
        self.assertTrue(all(r["kind"] in ("ok", "unit") for r in balanced))
        self.assertTrue(any(r["kind"] == "long" for r in strict))

    def test_too_few_runs_measure_nothing(self):
        c = self.case
        out = jr.judge(c["matrix"], c["targets"][:6], c["blank"], "balanced", set(), set(), {0, 2})
        self.assertTrue(all(r["ratio"] == 0.0 for r in out))

    def test_presets_keep_their_own_flagging_minimum(self):
        self.assertEqual(jr.MEASURE_MIN_RUNS, 3)
        self.assertEqual(min(jr.PRESETS["maximum"]["duration_min_runs"], jr.MEASURE_MIN_RUNS), 2)
        self.assertEqual(min(jr.PRESETS["strict"]["duration_min_runs"], jr.MEASURE_MIN_RUNS), 3)


class WavTests(unittest.TestCase):
    def test_conversion_rounds_half_away_from_zero_and_clamps(self):
        tie = 0.5 / 32768.0
        self.assertEqual(wav_ref.float_to_pcm16(tie), 1)
        self.assertEqual(wav_ref.float_to_pcm16(-tie), -1)
        self.assertEqual(wav_ref.float_to_pcm16(1.5 / 32768.0), 2)
        self.assertEqual(wav_ref.float_to_pcm16(-2.5 / 32768.0), -3)
        self.assertEqual(wav_ref.float_to_pcm16(1.0), 32767)
        self.assertEqual(wav_ref.float_to_pcm16(-1.0), -32768)
        self.assertEqual(wav_ref.float_to_pcm16(7.0), 32767)
        self.assertEqual(wav_ref.float_to_pcm16(float("nan")), 0)

    def test_phone_samples_survive_the_round_trip_exactly(self):
        # the phone's floats are pcm / 32768: saving and reloading must not change a bit
        pcm = list(range(-32768, 32768, 977)) + [32767, -32768, 0]
        floats = [v / 32768.0 for v in pcm]
        blob = wav_ref.encode_wav16([wav_ref.float_to_pcm16(x) for x in floats])
        back, rate = wav_ref.decode_wav16(blob)
        self.assertEqual(rate, 16000)
        self.assertEqual(back, floats)

    def test_standard_readers_accept_the_file(self):
        import io
        import wave
        pcm = [0, 1, -1, 32767, -32768, 1234]
        blob = wav_ref.encode_wav16(pcm)
        self.assertEqual(len(blob), 44 + 2 * len(pcm))
        with wave.open(io.BytesIO(blob), "rb") as reader:
            self.assertEqual((reader.getnchannels(), reader.getsampwidth(), reader.getframerate()), (1, 2, 16000))
            self.assertEqual(reader.getnframes(), len(pcm))
            frames = reader.readframes(len(pcm))
        import struct
        self.assertEqual(list(struct.unpack("<%dh" % len(pcm), frames)), pcm)

    def test_decoder_rejects_other_formats(self):
        blob = bytearray(wav_ref.encode_wav16([0, 1]))
        blob[22] = 2   # stereo
        with self.assertRaises(ValueError):
            wav_ref.decode_wav16(bytes(blob))
        with self.assertRaises(ValueError):
            wav_ref.decode_wav16(b"not a wav file at all, but long enough to index")


class PerfTests(unittest.TestCase):
    def test_summary_uses_nearest_rank_percentiles(self):
        self.assertEqual(rr.perf_summary([]), {"n": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0})
        self.assertEqual(rr.perf_summary([5]), {"n": 1, "mean": 5.0, "p50": 5.0, "p95": 5.0, "max": 5.0})
        s = rr.perf_summary([100, 200, 300, 400, 1000])
        self.assertEqual((s["n"], s["mean"], s["p50"], s["p95"], s["max"]), (5, 400.0, 300.0, 1000.0, 1000.0))
        hundred = rr.perf_summary([float(i) for i in range(1, 101)])
        self.assertEqual((hundred["p50"], hundred["p95"], hundred["max"]), (50.0, 95.0, 100.0))
        self.assertEqual(rr.perf_summary([12.34, 0.05])["mean"], 6.2)

    def test_the_verdict_follows_the_queue_arithmetic(self):
        # just under every limit: still fine
        self.assertEqual(rr.perf_health({"workerRtf": 0.79, "backlogMax": 7,
                                         "lag": {"n": 3, "p95": 1500.0}})[0], "ok")
        self.assertEqual(rr.perf_health({"workerRtf": 0.99, "backlogMax": 7})[0], "tight")
        self.assertEqual(rr.perf_health({"workerRtf": 1.0})[0], "slow")      # the queue only grows from here
        self.assertEqual(rr.perf_health({"workerRtf": 0.5, "backlogMax": 8})[0], "slow")
        self.assertEqual(rr.perf_health({"workerRtf": 0.8})[0], "tight")
        self.assertEqual(rr.perf_health({"workerRtf": 0.5, "lag": {"n": 4, "p95": 1501.0}})[0], "tight")
        self.assertEqual(rr.perf_health({"workerRtf": 0.5, "lag": {"n": 0, "p95": 9999.0}})[0], "ok")

    def test_old_records_fall_back_to_the_model_step_ratio(self):
        self.assertEqual(rr.perf_health({"realTimeFactor": 1.4})[0], "slow")
        self.assertEqual(rr.perf_health(None)[0], "ok")
        self.assertIn("خطوة النموذج 300 مللي ثانية لكل 480", rr.perf_line({"stepMsMean": 300, "stepMsMax": 520}))

    def test_the_line_names_only_what_was_measured(self):
        full = rr.perf_line({"stepMsMean": 300, "stepMsMax": 520, "hopMs": 320, "workerRtf": 0.71,
                             "lag": {"n": 5, "p95": 900.4, "max": 1200.0}, "judge": {"n": 1, "mean": 88.0},
                             "judgeWaitMs": 350, "backlogMax": 3})
        for part in ("لكل 320", "نسبة زمن المحرك كله 0.71", "كمون الرمز p95 900", "الحَكَم 88", "انتظار الانتقال للحَكَم 350",
                     "أقصى طابور 3"):
            self.assertIn(part, full)
        bare = rr.perf_line({"stepMsMean": 300, "stepMsMax": 520})
        self.assertNotIn("كمون", bare)
        self.assertNotIn("طابور", bare)

    def test_summary_text_carries_the_performance_lines(self):
        text = rr.summary_text(report("clean_ayah"))
        self.assertIn("الأداء: خطوة النموذج 120 مللي ثانية لكل 480", text)
        self.assertIn("السرعة جيدة", text)


class GoldenFixtureTests(unittest.TestCase):
    def test_fixture_is_current(self):
        sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))
        import gen_report_fixtures as gen
        path = os.path.join(ROOT, "test", "fixtures", "report_golden.json")
        with open(path, encoding="utf-8") as handle:
            on_disk = json.load(handle)
        fresh = json.loads(json.dumps(gen.build(), ensure_ascii=False))
        self.assertEqual(
            on_disk, fresh,
            "report_golden.json is stale: run python3 tools/frame_engine/gen_report_fixtures.py and commit it")


if __name__ == "__main__":
    unittest.main()
