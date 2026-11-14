#!/usr/bin/env python3
"""Writes test/fixtures/frame_golden.json: golden vectors the Dart tests replay.

Run from the repository root after changing fbank_ref.py, judge_ref.py or
onnx_contract.py:  python3 tools/frame_engine/gen_fixtures.py
"""
import base64
import importlib.util
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import fbank_ref as fb  # noqa: E402
import judge_ref as jr  # noqa: E402
import onnx_contract as oc  # noqa: E402

spec = importlib.util.spec_from_file_location("ref_tests", os.path.join(ROOT, "test", "test_frame_engine_ref.py"))
ref_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref_tests)


def f32(x):
    return float(np.float32(x))


def contract_fixture():
    inputs = [
        ("x", 1, [1, 61, 80]),
        ("cached_len_0", 7, [2, 1]),
        ("cached_key_0", 1, [128, 1, 192]),
        ("cached_embed_left_pad", 1, [1, 128, 80]),
        ("processed_lens", 7, [1]),
        ("weights_like_input", 1, [4]),
        ("dynamic", 1, [1, "T"]),
    ]
    outputs = [("log_probs", 1, [1, 12, 251]), ("new_cached_len_0", 7, [2, 1]), ("new_processed_lens", 7, [1])]
    meta = {"T": "61", "decode_chunk_len": "48", "model_type": "zipformer2"}
    data = oc.build_model(inputs, outputs, meta, initializers=["weights_like_input"])
    return {"base64": base64.b64encode(data).decode(), "expected": oc.parse_contract(data)}


def fbank_fixture():
    n = 3200
    samples = [f32(v) for v in ref_tests.FbankTests.signal(n)]
    extractor = fb.KaldiFbank()
    frames = extractor.accept(samples)
    picks = [0, 1, 2, 10, len(frames) - 1]
    return {
        "samples": n,
        "frameCount": len(frames),
        "picks": picks,
        "features": [[round(v, 9) for v in frames[i]] for i in picks],
    }


def judge_fixture():
    classes, blank = 8, 7
    cases = {
        "clean": ([0, 1, 2], [(5, 0, 0.97, None, 0), (15, 1, 0.96, None, 0), (25, 2, 0.98, None, 0)]),
        "substitution": ([0, 1, 2], [(5, 0, 0.97, None, 0), (15, 1, 0.35, 3, 0.60), (25, 2, 0.98, None, 0)]),
        "close_call": ([0], [(5, 0, 0.75, 3, 0.22)]),
        "weak": ([0, 1], [(5, 0, 0.97, None, 0), (15, 1, 0.45, None, 0)]),
        "units": ([2, 2, 2], [(5, 2, 0.97, None, 0), (12, 2, 0.30, None, 0), (19, 2, 0.20, None, 0)]),
        "repeat_then_other": ([4, 4, 5], [(4, 4, 0.9, None, 0), (11, 4, 0.9, None, 0), (20, 5, 0.9, 6, 0.08)]),
        "weak_last_token_of_word": ([0, 1, 2], [(5, 0, 0.97, None, 0), (15, 1, 0.97, None, 0), (25, 2, 0.45, None, 0)]),
        "hard_last_token_of_word": ([0, 1, 2], [(5, 0, 0.97, None, 0), (15, 1, 0.97, None, 0), (25, 2, 0.30, 3, 0.65)]),
        "weak_elided_hamza": ([0, 1, 2], [(5, 0, 0.40, None, 0), (15, 1, 0.97, None, 0), (25, 2, 0.97, None, 0)]),
        "mild_doubt": ([0, 1], [(5, 0, 0.97, None, 0), (15, 1, 0.85, 3, 0.05)]),
    }
    exempt = {
        "weak_last_token_of_word": ([2], []),
        "hard_last_token_of_word": ([2], []),
        "weak_elided_hamza": ([], [0]),
    }
    scenarios = []

    def add(name, targets, spikes, soft, every, duration_ids, frames, cls, blk, sibs=None, edge_gap=None):
        matrix = [[f32(v) for v in row] for row in ref_tests.spike_matrix(cls, blk, spikes, frames)]
        expected = {}
        for sensitivity in ("strict", "balanced", "maximum"):
            expected[sensitivity] = [
                {k: (round(v, 9) if isinstance(v, float) and math.isfinite(v) else v) for k, v in row.items()}
                for row in jr.judge(matrix, targets, blk, sensitivity, set(soft), set(every), set(duration_ids),
                         vowel_siblings=sibs, edge_gap_frames=edge_gap)
            ]
        scenarios.append({"name": name, "classes": cls, "blank": blk, "targets": targets, "matrix": matrix,
                          "softExempt": soft, "allExempt": every, "durationIds": list(duration_ids),
                          "vowelSiblings": {str(k): v for k, v in (sibs or {}).items()}, "edgeGapFrames": edge_gap,
                          "expected": expected})

    for name, (targets, spikes) in cases.items():
        soft, every = exempt.get(name, ([], []))
        add(name, targets, spikes, soft, every, [], 40, classes, blank)

    # Changed vowel on the last token of a word, said in the flow: the sibling fires 3 frames after the
    # aligned frame, faintly (ids: 0 previous word, 1 "fa", 2 "fi", 3 next word).
    sibs = {1: [2], 2: [1]}
    for name, spikes in {
        "final_vowel_offset": [(5, 0, 0.97, None, 0), (15, 1, 0.85, None, 0), (18, 2, 0.12, None, 0), (24, 3, 0.97, None, 0)],
        "final_vowel_faint": [(5, 0, 0.97, None, 0), (15, 1, 0.85, None, 0), (17, 2, 0.06, None, 0), (24, 3, 0.97, None, 0)],
        "final_vowel_clean": [(5, 0, 0.97, None, 0), (15, 1, 0.97, None, 0), (17, 2, 0.002, None, 0), (24, 3, 0.97, None, 0)],
        "final_vowel_pause": [(5, 0, 0.97, None, 0), (15, 1, 0.85, None, 0), (17, 2, 0.06, None, 0), (45, 3, 0.97, None, 0)],
    }.items():
        add(name, [0, 1, 3], spikes, [1], [], [], 60, classes, blank, sibs, 12)

    # Four held-sound runs of two units each. Time per unit: 5, 5, 11 and 2 frames.
    spikes = []
    layout = [(0, 4, 9, 1, 14), (2, 19, 24, 3, 29), (4, 34, 45, 5, 56), (6, 61, 63, 7, 65)]
    targets = []
    for unit, a, b, sep, sep_frame in layout:
        spikes += [(a, unit, 0.97, None, 0), (b, unit, 0.97, None, 0), (sep_frame, sep, 0.97, None, 0)]
        targets += [unit, unit, sep]
    add("duration_runs", targets, spikes, [], [], [0, 2, 4, 6], 75, 10, 9)
    return {"scenarios": scenarios}


if __name__ == "__main__":
    out = {"contract": contract_fixture(), "fbank": fbank_fixture(), "judge": judge_fixture()}
    path = os.path.join(ROOT, "test", "fixtures", "frame_golden.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(out, handle, ensure_ascii=False, separators=(",", ":"))
    print("wrote", path, os.path.getsize(path), "bytes")
