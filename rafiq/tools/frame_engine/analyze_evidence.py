#!/usr/bin/env python3
"""Reads rafiq_evidence.jsonl (pasted from the developer panel) and summarises it.

    python3 tools/frame_engine/analyze_evidence.py evidence.jsonl
    python3 tools/frame_engine/analyze_evidence.py evidence.jsonl --assume-unlabeled-correct --target-fpr 0.02

Per record: reference mode, frame-judge status, flagged words with their scores.
Overall: the distribution of the expected token's peak probability (p_ref) and of
the margin over tokens the text evaluator accepted, which is what the thresholds
in FrameJudgeConfig should be tuned against (a threshold near the low percentiles
of clean recitation flags roughly that share of clean tokens as false alarms).

When the log also holds the reader's labels (schema v3 lines with kind "label",
written from the technical report) the label analysis follows: precision and
recall per kind of flag and per error type, the confusion matrix, one curve per
threshold and a threshold suggestion within a false-alarm budget. That part lives
in label_analysis.py (also usable on its own, and on the report's JSON export).
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import label_analysis  # noqa: E402


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


def parse(text):
    """(ayah records, label lines, damaged line count). Label lines are not records."""
    records, labels, damaged = [], [], 0
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            damaged += 1
            continue
        if not isinstance(obj, dict):
            damaged += 1
        elif obj.get("kind") == "label":
            labels.append(obj)
        else:
            records.append(obj)
    return records, labels, damaged


def summarize(records):
    clean_p, clean_m = [], []
    for r in records:
        frames = r.get("frames") or {}
        verdicts = r.get("verdicts", {})
        rid = (" rid=%s" % r["rid"]) if r.get("rid") else ""
        print("- %s:%s mode=%s frames=%s heard_tokens=%d%s" % (
            r.get("surah"), r.get("ayah"), r.get("reference"), frames.get("status"), len(r.get("tokens", [])), rid))
        for w in frames.get("words", []):
            if w[1] > 0:
                print("    word %d severity %d %s token=%s rival=%s p_ref=%.2f p_comp=%.2f margin=%.2f" % tuple(w[:8]))
        text_ok = all(v.startswith("correct") or v.startswith("tajweedWarning") for v in verdicts.values())
        if text_ok:
            for row in frames.get("tokens", []):
                if row[6] in ("ok", "edge"):
                    clean_p.append(row[7])
                    clean_m.append(min(row[10], 20.0))
    if clean_p:
        print("\nclean tokens: %d" % len(clean_p))
        for q in (0.01, 0.05, 0.10, 0.50):
            print("  p%02d  p_ref=%.3f  margin=%.2f" % (q * 100, percentile(clean_p, q), percentile(clean_m, q)))
        print("A p_ref_warn at the p05 value flags about 5% of clean tokens; margin_warn likewise.")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", help="rafiq_evidence.jsonl (or the report's JSON export for the label part)")
    parser.add_argument("--assume-unlabeled-correct", action="store_true",
                        help="count unlabelled words shown as correct as truly correct")
    parser.add_argument("--target-fpr", type=float, default=0.02, help="false-alarm budget per correct word")
    parser.add_argument("--labels", action="store_true", help="print the label analysis even with no label lines")
    parser.add_argument("--json", help="write the label analysis as JSON")
    args = parser.parse_args(argv)

    with open(args.path, encoding="utf-8") as handle:
        text = handle.read()
    records, labels, damaged = parse(text)
    summarize(records)
    if damaged:
        print("\n(%d damaged line(s) skipped)" % damaged)
    if labels or args.labels:
        result = label_analysis.analyze(text, args.assume_unlabeled_correct, args.target_fpr)
        print("\n" + label_analysis.render(result))
        if args.json:
            result.pop("_rows", None)
            with open(args.json, "w", encoding="utf-8") as handle:
                json.dump(label_analysis._clean(result), handle, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
