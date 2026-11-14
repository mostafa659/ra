#!/usr/bin/env python3
"""Writes test/fixtures/report_golden.json: the vectors Dart replays against report_ref.py.

    python3 tools/frame_engine/gen_report_fixtures.py

test_report_ref.GoldenFixtureTests fails when the file on disk differs from what
this script would write now, so report_ref.py and the Dart port cannot drift apart
silently.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "test"))

import report_ref as rr  # noqa: E402
import report_testkit as kit  # noqa: E402
import thread_tuner_ref as tt  # noqa: E402
import wav_ref  # noqa: E402

OUT = os.path.join(ROOT, "test", "fixtures", "report_golden.json")
OUT_TUNER = os.path.join(ROOT, "test", "fixtures", "thread_tuner_golden.json")


def _constants():
    return {
        "schema": rr.SCHEMA_VERSION,
        "stepMs": rr.STEP_MS,
        "slackMs": rr.SLACK_MS,
        "pauseRatio": rr.PAUSE_RATIO,
        "ignoredKinds": list(rr.IGNORED_KINDS),
        "statuses": list(rr.STATUSES),
        "watch": rr.WATCH,
        "statusAr": rr.STATUS_AR,
        "textVerdictAr": rr.TEXT_VERDICT_AR,
        "kindAr": rr.KIND_AR,
        "sourceAr": rr.SOURCE_AR,
        "watchAr": rr.WATCH_AR,
        "labels": [list(pair) for pair in rr.LABELS],
        "errorTypes": [list(pair) for pair in rr.ERROR_TYPES],
        "maxTypes": rr.MAX_TYPES,
        "maxNote": rr.MAX_NOTE,
        "rtfSlow": rr.RTF_SLOW,
        "rtfTight": rr.RTF_TIGHT,
        "backlogSlow": rr.BACKLOG_SLOW,
        "lagP95TightMs": rr.LAG_P95_TIGHT_MS,
    }


def _fmt_vectors():
    values = [0.0, 0.5, 0.97, 1.4469, -0.539, -0.001, 2.2, 12.345, 0.004, 0.005, 98.99, 99.0, -99.0, 1.005, 0.125,
              0.375, 5.4220087, None]
    return [[v, rr.fmt2(v)] for v in values]


def _norm_vectors():
    inputs = ["\u2581ق", " \u00a0ل\t", "\u2581", "َ", "ا\nب", ""]
    return [[s, rr.norm_label(s)] for s in inputs]


def _align_vectors():
    pairs = [("abc", "abc"), ("", ""), ("ab", ""), ("", "ab"), ("abcd", "abd"), ("abd", "abcd"), ("صلى", "سلى"),
             ("klmt", "kmnt"), ("اببج", "بباج"), ("aaab", "aab")]
    return [{"expected": list(a), "heard": list(b), "ops": rr.align_ops(list(a), list(b))} for a, b in pairs]


def _label_vectors():
    cases = [
        ("confirmed", ["madd"], " note ", "warning"),
        ("missed", ["haraka", "madd", "haraka"], "", "correct"),
        ("false_alarm", [], "", "warning"),
        ("false_alarm", [], "", "correct"),
        ("missed", [], "", "incorrect"),
        ("missed", [], "", "pending"),
        ("confirmed", ["madd"], "", "correct"),
        ("false_alarm", ["madd"], "", "warning"),
        ("confirmed", ["nope"], "", "warning"),
        ("maybe", [], "", "warning"),
        ("missed", ["haraka", "madd", "ghunna", "ikhfa"], "", "correct"),
        ("confirmed", [], "x" * 900, "correct"),
        ("none", [], "", "correct"),
    ]
    out = []
    for label, types, note, status in cases:
        result, error = rr.make_label(label, types, note, status)
        out.append({"label": label, "types": types, "note": note, "status": status,
                    "result": result, "error": error})
    return out


def _scenarios():
    out = []
    for name, record, labels in kit.scenarios():
        report = rr.build_ayah_report(record, labels)
        out.append({
            "name": name,
            "record": record,
            "labels": [labels[k] for k in sorted(labels)],
            "report": report,
            "summary": rr.summary_text(report),
        })
    return out


def _export():
    by_name = {name: record for name, record, _ in kit.scenarios()}
    records = [by_name["substitution_applied"], by_name["labels_merged"]]
    lines = [
        rr.label_line(records[0], 0, {"label": "confirmed", "types": [], "note": ""}, "t1"),
        rr.label_line(records[0], 0, {"label": "confirmed", "types": ["tafkheem"], "note": "ص"}, "t2"),
        rr.label_line(records[1], 1, {"label": "confirmed", "types": [], "note": ""}, "t3"),
        {"v": 3, "kind": "label", "at": "t4", "rid": records[1]["rid"], "surah": 112, "ayah": 10, "word": 0,
         "label": "none", "types": [], "note": "", "shown": "incorrect"},
    ]
    return {"records": records, "lines": lines, "exportedAt": "2026-11-02T11:00:00Z",
            "document": rr.export_document(records, lines, "2026-11-02T11:00:00Z")}


def _wav_vectors():
    tie = 0.5 / 32768.0
    floats = [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 10.0 / 32768.0, -10.0 / 32768.0, tie, -tie, 1.5 / 32768.0,
              -2.5 / 32768.0, 0.99997, -0.99997, 32767.0 / 32768.0, -32768.0 / 32768.0]
    pcm = [wav_ref.float_to_pcm16(x) for x in floats]
    small = [0.0, 0.25, -0.25, 1.0, -1.0, 100.0 / 32768.0]
    small_pcm = [wav_ref.float_to_pcm16(x) for x in small]
    return {
        "pcm": [[x, wav_ref.float_to_pcm16(x)] for x in floats],
        "file": {"floats": small, "pcm": small_pcm, "sampleRate": 16000,
                 "hex": wav_ref.encode_wav16(small_pcm).hex()},
        "samples": pcm,
    }


def _perf_vectors():
    summaries = [[], [5], [100, 200, 300, 400, 1000], [12.34, 0.05, 99.99, 250.5, 250.5, 1.0, 7.77, 3.14, 2.72, 1.41],
                 [float(i) for i in range(1, 101)]]
    perfs = [
        {},
        {"stepMsMean": 300, "stepMsMax": 520, "realTimeFactor": 0.62},
        {"stepMsMean": 300, "stepMsMax": 520, "hopMs": 480, "workerRtf": 0.55,
         "lag": {"n": 10, "mean": 700.0, "p50": 650.0, "p95": 820.0, "max": 900.0}, "backlogMax": 1},
        {"stepMsMean": 410, "stepMsMax": 700, "hopMs": 480, "workerRtf": 0.85,
         "lag": {"n": 10, "mean": 900.0, "p50": 800.0, "p95": 1200.0, "max": 1500.0}, "backlogMax": 3},
        {"stepMsMean": 300, "stepMsMax": 520, "hopMs": 480, "workerRtf": 0.5,
         "lag": {"n": 10, "mean": 1400.0, "p50": 1300.0, "p95": 1800.0, "max": 2500.0}, "backlogMax": 2},
        {"stepMsMean": 520, "stepMsMax": 900, "hopMs": 480, "workerRtf": 1.12, "backlogMax": 10,
         "lag": {"n": 40, "mean": 2500.0, "p50": 2400.0, "p95": 4100.0, "max": 5200.0},
         "eval": {"n": 80, "mean": 4.0, "p50": 3.0, "p95": 12.3, "max": 40.0},
         "judge": {"n": 1, "mean": 88.0, "p50": 88.0, "p95": 88.0, "max": 88.0}, "judgeWaitMs": 350},
        {"stepMsMean": 200, "stepMsMax": 300, "hopMs": 320, "workerRtf": 0.79, "backlogMax": 7,
         "lag": {"n": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}},
        {"stepMsMean": 200, "realTimeFactor": 1.0},
    ]
    return {
        "summary": [{"values": v, "result": rr.perf_summary(v)} for v in summaries],
        "health": [{"perf": p, "level": rr.perf_health(p)[0], "text": rr.perf_health(p)[1]} for p in perfs],
        "line": [{"perf": p, "text": rr.perf_line(p)} for p in perfs],
    }


def build():
    return {
        "version": 1,
        "note": "generated by tools/frame_engine/gen_report_fixtures.py; do not edit by hand",
        "constants": _constants(),
        "fmt2": _fmt_vectors(),
        "normLabel": _norm_vectors(),
        "align": _align_vectors(),
        "labelValidation": _label_vectors(),
        "scenarios": _scenarios(),
        "export": _export(),
        "wav": _wav_vectors(),
        "perf": _perf_vectors(),
    }


def build_tuner():
    """Session sequences and the state the reference reaches after each one."""
    long_run = {"steps": 40, "audio": 20.0}
    scripts = [
        ("fast_phone_never_changes", 8, [(3, 0.55), (3, 0.6), (3, 0.5), (3, 0.62)]),
        ("slow_default_climbs_to_a_better_count", 8,
         [(3, 1.2), (2, 0.9), (1, 1.5), (4, 0.7), (4, 0.72)]),
        ("everything_is_slow_keeps_the_least_bad", 6, [(3, 1.3), (2, 1.1), (1, 1.6), (4, 1.4), (2, 1.05)]),
        ("two_cores_only_try_one_and_two", 2, [(2, 0.95), (1, 0.85), (1, 0.9)]),
        ("short_and_empty_sessions_are_ignored", 8,
         [(3, 1.4, 5, 20.0), (3, 1.4, 40, 3.0), (3, 0.0, 40, 20.0), (7, 1.4, 40, 20.0), (3, 1.4)]),
        ("a_settled_choice_is_explored_again_when_it_gets_worse", 8,
         [(3, 0.6), (3, 0.7), (3, 0.9), (3, 1.4), (2, 0.8)]),
        ("a_slightly_slower_settled_choice_stays", 8, [(3, 0.6), (3, 0.79), (3, 0.76)]),
    ]
    out = []
    for name, cores, sessions in scripts:
        state = tt.initial_state(cores)
        steps_log = []
        for session in sessions:
            threads, rtf = session[0], session[1]
            steps = session[2] if len(session) > 2 else long_run["steps"]
            audio = session[3] if len(session) > 3 else long_run["audio"]
            state = tt.observe(state, cores, threads, rtf, steps, audio)
            steps_log.append({"threads": threads, "rtf": rtf, "steps": steps, "audio": audio,
                              "state": state, "next": tt.threads_for(state, cores)})
        out.append({"name": name, "cores": cores, "initial": tt.initial_state(cores), "sessions": steps_log})
    return {
        "version": 1,
        "constants": {"okRtf": tt.OK_RTF, "retryMargin": tt.RETRY_MARGIN, "minSteps": tt.MIN_STEPS,
                      "minAudioSeconds": tt.MIN_AUDIO_SECONDS, "maxThreads": tt.MAX_THREADS},
        "defaults": [{"cores": c, "default": tt.default_threads(c), "candidates": tt.candidates(c)}
                     for c in (1, 2, 4, 5, 6, 8, 12)],
        "clamp": [{"cores": 2, "stored": 4, "threads": tt.threads_for({"threads": 4}, 2)},
                  {"cores": 8, "stored": 4, "threads": tt.threads_for({"threads": 4}, 8)},
                  {"cores": 8, "stored": 0, "threads": tt.threads_for({"threads": 0}, 8)}],
        "scenarios": out,
    }


def main():
    data = json.loads(json.dumps(build(), ensure_ascii=False))
    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))
    tuner = json.loads(json.dumps(build_tuner()))
    with open(OUT_TUNER, "w", encoding="utf-8") as handle:
        json.dump(tuner, handle, separators=(",", ":"))
        handle.write("\n")
    print("wrote %s (%d bytes)" % (OUT_TUNER, os.path.getsize(OUT_TUNER)))


if __name__ == "__main__":
    main()
