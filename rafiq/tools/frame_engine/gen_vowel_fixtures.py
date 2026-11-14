#!/usr/bin/env python3
"""Writes test/fixtures/vowel_golden.json: golden vectors the Dart FinalVowelProbe test replays.

Run from the repository root after changing vowel_ref.py:  python3 tools/frame_engine/gen_vowel_fixtures.py
"""
import importlib.util
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import vowel_ref as vr  # noqa: E402

spec = importlib.util.spec_from_file_location("vowel_tests", os.path.join(ROOT, "test", "test_vowel_ref.py"))
vowel_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vowel_tests)


def f32(x):
    return float(np.float32(x))


def main():
    segments = []
    for name, vowel, scale, f0, seed in (("a_male", "a", 1.0, 120.0, 1), ("i_female", "i", 1.18, 210.0, 2),
                                         ("u_male", "u", 1.0, 120.0, 3)):
        samples = [f32(v) for v in vowel_tests.synth(vowel, scale, f0, seconds=0.11, seed=seed)]
        est = vr.estimate_formants(samples)
        segments.append({"name": name, "samples": [round(v, 7) for v in samples],
                         "f1": est[0], "f2": est[1], "frames": est[2]})
    anchors = {"a": [(720.0, 1215.0), (724.0, 1220.0), (718.0, 1210.0)],
               "i": [(310.0, 2303.0), (311.0, 2309.0)],
               "u": [(449.0, 720.0), (452.0, 724.0)]}
    cases = []
    for name, obs, expected in (("fatha_ok", (720.0, 1216.0), "a"), ("kasra_for_fatha", (312.0, 2300.0), "a"),
                                ("damma_for_fatha", (450.0, 722.0), "a"), ("kasra_ok", (310.0, 2300.0), "i"),
                                ("fatha_for_kasra", (720.0, 1215.0), "i")):
        v = vr.classify(anchors, obs, expected)
        cases.append({"name": name, "anchors": {k: [list(p) for p in vs] for k, vs in anchors.items()},
                      "f1": obs[0], "f2": obs[1], "expected": expected, "status": v["status"],
                      "nearest": v["nearest"], "gap": v["gap"], "severity": v["severity"]})
    cases.append({"name": "few_anchors", "anchors": {"a": [[700.0, 1200.0]]}, "f1": 330.0, "f2": 850.0,
                  "expected": "a", "status": "no_anchors", "nearest": "a", "gap": 0.0, "severity": 0})
    path = os.path.join(ROOT, "test", "fixtures", "vowel_golden.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"segments": segments, "classify": cases}, handle, ensure_ascii=False, separators=(",", ":"))
    print("wrote", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
