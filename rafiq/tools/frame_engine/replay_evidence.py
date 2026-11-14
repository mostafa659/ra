#!/usr/bin/env python3
"""Replays one recorded ayah without the phone.

The app (with "save raw audio" on in the technical report) keeps each judged
ayah as a 16 kHz WAV and links it from the evidence record (audio.file,
audio.offsetSec). This tool runs that audio through the same model and the same
frame judge on the PC and compares the result with what the phone logged:

    python3 tools/frame_engine/replay_evidence.py \\
        --evidence rafiq_evidence.jsonl --rid 112-1-1730550000000 \\
        --wav 112-1-1730550000000.wav --model model.int8.onnx --tokens tokens.txt

    # judge the same posteriors again with another sensitivity, no model needed
    python3 tools/frame_engine/replay_evidence.py --evidence ... --rid ... \\
        --logprobs window.npy --sensitivity strict

The phone's session started earlier than the clip, so the encoder's state at the
start of the clip differs from the live one (the clip starts on the model's
chunk grid, which keeps the frame grid and chunk phase identical). Expect the
first words to differ slightly; the parity numbers say by how much. Nothing here
has been run against the real model in CI: it needs the licensed model files.
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import judge_ref as jr  # noqa: E402
import report_ref as rr  # noqa: E402
import wav_ref  # noqa: E402

FRAME_S = 0.04
# the engine's "held sound" labels: madd alef/waw/yeh marks, alef maksura, nasal mark, noon, meem
DURATION_LABELS = ("\u0627", "\u06e5", "\u06e6", "\u0649", "\u06ba", "\u0646", "\u0645")


# ---------------------------------------------------------------- inputs

def find_record(text, rid=None):
    """The record `rid` (default: the last one) from an evidence log, a report store or an export."""
    text = text.strip()
    records = []
    try:
        document = json.loads(text)
    except ValueError:
        document = None
    if isinstance(document, dict) and str(document.get("format", "")).startswith("rafiq-report/"):
        records = [r for r in document.get("records") or [] if r.get("rid")]
    else:
        for raw in text.splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            if obj.get("k") == "rec" and isinstance(obj.get("r"), dict):
                obj = obj["r"]
            if obj.get("rid") and "expected" in obj:
                records.append(obj)
    if rid is not None:
        for record in reversed(records):
            if str(record["rid"]) == rid:
                return record
        raise KeyError("no record %s (found: %s)" % (rid, ", ".join(str(r["rid"]) for r in records[-5:])))
    if not records:
        raise KeyError("no schema-v3 ayah record in the input")
    return records[-1]


def read_tokens(path):
    """tokens.txt lines are '<token> <id>'; returns (list by id, blank id)."""
    table = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            token, _, ident = line.rpartition(" ")
            table[int(ident)] = token
    tokens = [table[i] for i in range(len(table))]
    blank = next((i for i, t in enumerate(tokens) if "blk" in t.lower()), len(tokens) - 1)
    return tokens, blank


def reference_from_record(record, tokens):
    """The judge's inputs, rebuilt from the token rows the phone logged for the ayah."""
    rows = (record.get("frames") or {}).get("tokens") or []
    if not rows:
        raise ValueError("the record has no judged token rows (needs schema v3 and a frame judgement)")
    ids_of, ids_norm = {}, {}
    for i, token in enumerate(tokens):
        ids_of.setdefault(token, []).append(i)
        ids_norm.setdefault(rr.norm_label(token), []).append(i)

    def ident(label):
        found = ids_of.get(label) or ids_norm.get(rr.norm_label(label))
        if not found:
            raise ValueError("label %r is not in tokens.txt" % label)
        if len(found) > 1:
            raise ValueError("label %r is ambiguous in tokens.txt: %s" % (label, found))
        return found[0]

    targets = [ident(str(row[2])) for row in rows]
    last_of_word = {}
    for j, row in enumerate(rows):
        last_of_word[int(row[1])] = j
    duration = set()
    for label in DURATION_LABELS:
        found = ids_of.get(label) or ids_norm.get(label)
        if found:
            duration.add(found[0])
    return {
        "targets": targets,
        "soft_exempt": set(last_of_word.values()),
        "all_exempt": {j for j, row in enumerate(rows) if str(row[6]) == "exempt"},
        "duration_ids": duration,
    }


def load_wav(path):
    with open(path, "rb") as handle:
        samples, rate = wav_ref.decode_wav16(handle.read())
    if rate != 16000:
        raise ValueError("need 16 kHz audio, got %d" % rate)
    return samples


# ---------------------------------------------------------------- replay

def run_stream(runner, samples, chunk=3840):
    """Feeds the audio the way the phone does (0.24 s blocks) and returns the log-prob rows."""
    import numpy as np
    runner.reset()
    audio = np.asarray(samples, dtype=np.float32)
    for k in range(0, len(audio), chunk):
        runner.accept(audio[k:k + chunk])
    runner.finish()
    return runner.log_probs


def window_of(record, available):
    """(first, last, offset_frames): the judged window as indices into the clip's own frames."""
    frames = record["frames"]
    audio = record.get("audio") or {}
    offset = int(round(float(audio.get("offsetSec", 0.0)) / FRAME_S))
    first = int(frames["startFrame"]) - offset
    last = int(frames["endFrame"]) - offset
    return max(0, first), min(available, last), offset


def rejudge(record, log_probs, tokens, blank, sensitivity=None):
    """Judges the ayah's window of `log_probs` (the clip's own frames) like the phone did."""
    ref = reference_from_record(record, tokens)
    first, last, offset = window_of(record, len(log_probs))
    if last - first < len(ref["targets"]):
        raise ValueError("window of %d frames cannot hold %d reference tokens" % (last - first, len(ref["targets"])))
    window = [list(map(float, row)) for row in log_probs[first:last]]
    name = sensitivity or record.get("sensitivity") or "balanced"
    findings = jr.judge(window, ref["targets"], blank, name, ref["soft_exempt"], ref["all_exempt"],
                        ref["duration_ids"])
    return {"findings": findings, "sensitivity": name, "first": first, "last": last, "offset": offset,
            "window": window}


def compare(record, replay):
    """Token by token, what the phone logged against what the replay computed."""
    rows = record["frames"]["tokens"]
    findings = replay["findings"]
    shift_ms = (replay["first"] + replay["offset"]) * 40
    tokens = []
    for j, (row, f) in enumerate(zip(rows, findings)):
        margin = 99.0 if math.isinf(f["margin"]) else f["margin"]
        tokens.append({
            "j": j, "label": row[2],
            "logged": {"p_ref": row[7], "p_comp": row[8], "margin": row[10], "kind": row[6],
                       "severity": row[5], "start_ms": row[3], "end_ms": row[4]},
            "replay": {"p_ref": round(f["p_ref"], 4), "p_comp": round(f["p_comp"], 4),
                       "margin": round(margin, 4), "kind": f["kind"], "severity": f["severity"],
                       "start_ms": f["start"] * 40 + shift_ms, "end_ms": f["end"] * 40 + shift_ms},
        })

    def worst(key):
        return max((abs(t["logged"][key] - t["replay"][key]) for t in tokens), default=0.0)

    same_kind = [t["j"] for t in tokens if t["logged"]["kind"] != t["replay"]["kind"]]
    moved = [t["j"] for t in tokens if abs(t["logged"]["start_ms"] - t["replay"]["start_ms"]) > 40]
    return {
        "tokens": tokens,
        "max_abs_p_ref": worst("p_ref"),
        "max_abs_p_comp": worst("p_comp"),
        "kind_mismatches": same_kind,
        "moved_alignments": moved,
        "same_sensitivity": (replay["sensitivity"] == record.get("sensitivity")),
    }


def render(record, replay, parity):
    out = ["== إعادة تشغيل %s (الحساسية: %s) ==" % (record.get("rid"), replay["sensitivity"])]
    if parity["same_sensitivity"]:
        out.append("أكبر فرق في p_ref: %.4f | في p_comp: %.4f | رموز اختلف نوعها: %d | رموز تحرّكت محاذاتها: %d" % (
            parity["max_abs_p_ref"], parity["max_abs_p_comp"], len(parity["kind_mismatches"]),
            len(parity["moved_alignments"])))
    else:
        out.append("حساسية مختلفة عمّا سُجّل على الهاتف: تُعرض الأحكام الجديدة فقط.")
    out.append("")
    out.append("  j  رمز   مسجَّل(نوع p_ref p_comp)        إعادة(نوع p_ref p_comp)")
    for t in parity["tokens"]:
        a, b = t["logged"], t["replay"]
        flag = "" if a["kind"] == b["kind"] else "   <-- اختلاف"
        out.append("%3d  %-4s  %-12s %5.2f %5.2f     %-12s %5.2f %5.2f%s" % (
            t["j"], t["label"], a["kind"], a["p_ref"], a["p_comp"], b["kind"], b["p_ref"], b["p_comp"], flag))
    return "\n".join(out)


# -------------------------------------------------------------------- CLI

def make_runner(model, tokens_path, threads):
    import stream_ref
    return stream_ref.OrtStream(model, tokens_path, threads=threads)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--evidence", required=True, help="evidence JSONL, report store or rafiq-report/3 export")
    parser.add_argument("--rid", help="record id (default: the last record)")
    parser.add_argument("--tokens", help="tokens.txt of the model")
    parser.add_argument("--wav", help="the ayah's WAV (default: audio.file next to the evidence file)")
    parser.add_argument("--model", help="model .onnx (runs the audio through it)")
    parser.add_argument("--logprobs", help=".npy of log-probs saved by --dump-logprobs (skips the model)")
    parser.add_argument("--dump-logprobs", help="save the clip's log-probs (frames x classes) as .npy")
    parser.add_argument("--sensitivity", choices=("strict", "balanced", "maximum"))
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--json", help="write the comparison as JSON")
    args = parser.parse_args(argv)

    with open(args.evidence, encoding="utf-8") as handle:
        record = find_record(handle.read(), args.rid)
    if not args.tokens:
        print("--tokens is required")
        return 2
    tokens, blank = read_tokens(args.tokens)

    import numpy as np
    if args.logprobs:
        log_probs = np.load(args.logprobs)
    elif args.model:
        wav = args.wav
        if not wav:
            name = (record.get("audio") or {}).get("file")
            if not name:
                print("the record links no audio: pass --wav")
                return 2
            wav = os.path.join(os.path.dirname(os.path.abspath(args.evidence)), name)
        log_probs = np.asarray(run_stream(make_runner(args.model, args.tokens, args.threads), load_wav(wav)))
    else:
        print("give --model with the audio, or --logprobs")
        return 2
    if args.dump_logprobs:
        np.save(args.dump_logprobs, np.asarray(log_probs))

    replay = rejudge(record, log_probs, tokens, blank, args.sensitivity)
    parity = compare(record, replay)
    print(render(record, replay, parity))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({k: v for k, v in parity.items()}, handle, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
