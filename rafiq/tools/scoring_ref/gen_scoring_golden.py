"""Generates test/fixtures/scoring_golden.json (consumed by the Dart port tests and by test_scoring_ref.py)."""
import gzip, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scoring as S
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rng = np.random.default_rng(11)
cases = []
for k in range(6):  # small CTC cases: nll + viterbi spans + edit alignment
    T, V = 9 + k, 6
    lg = rng.standard_normal((T, V)); lp = S.log_softmax(lg)
    seq = [int(x) for x in rng.integers(1, V, size=3 + k % 3)]
    sp = S.viterbi_spans(lp, seq)
    cases.append({"logits": np.round(lg, 6).tolist(), "seq": seq, "nll": round(S.ctc_nll(lp, seq), 6),
                  "spans": [list(x) for x in sp] if sp else None})
edit = []
for _ in range(6):
    a = [int(x) for x in rng.integers(1, 5, size=7)]; b = [int(x) for x in rng.integers(1, 5, size=6)]
    r, i = S.edit_align(a, b)
    edit.append({"exp": a, "dec": b, "align": [list(x) for x in r], "ins": {str(k): v for k, v in i.items()}})
ref = json.load(gzip.open(os.path.join(ROOT, "assets/qps_reference.json.gz"), "rt"))["ayat"]
words = next(a for a in ref if (a["s"], a["a"]) == (103, 3))["words"]
fx = json.load(gzip.open(os.path.join(ROOT, "test/fixtures/regression_103_3_logits.json.gz"), "rt"))
reg = {}
for rec in ("rec_a", "rec_b"):
    lg = np.array(fx[rec], dtype="float32")
    for lvl in ("strict", "balanced", "maximum"):
        r = S.judge_ayah(lg, words, S.Cfg(level=lvl))
        reg[f"{rec}/{lvl}"] = {"decoded": r["decoded"], "tiers": [w["tier"] for w in r["words"]],
                               "weakest_gop": [None if w["weakest"] is None else w["weakest"]["gop"] for w in r["words"]]}
json.dump({"calibration_status": S.DEFAULT_CALIBRATION["calibration_status"], "ctc": cases, "edit": edit, "regression": reg},
          open(os.path.join(ROOT, "test/fixtures/scoring_golden.json"), "w"), ensure_ascii=False, indent=1)
print("ok", list(reg))

# ---- stream accumulator golden ----
import stream_frames as SF
rng2 = np.random.default_rng(21)
acc = SF.FrameAccumulator(6, 3, 4)
wins = []
for w in range(5):
    start = w * 4
    lg = rng2.standard_normal((10, 6)); lp = S.log_softmax(lg)
    acc.add_window(lp, start, at_ayah_start=(w == 0), last=(w == 4))
    wins.append({"start": start, "start_flag": w == 0, "last": w == 4, "logits": np.round(lg, 6).tolist(),
                 "final_upto": acc.final_upto})
upto = acc.known_upto()
# the golden must use the same rounded logits the test will feed back
acc2 = SF.FrameAccumulator(6, 3, 4)
for w in wins:
    acc2.add_window(S.log_softmax(np.array(w["logits"])), w["start"], w["start_flag"], w["last"])
stream = {"v": 6, "left_margin": 3, "lag": 4, "windows": wins, "known_upto": acc2.known_upto(),
          "frames": {str(a): np.round(acc2.frame(a), 6).tolist() for a in (0, 5, 12, 21, 25)}}
g = json.load(open(os.path.join(ROOT, "test/fixtures/scoring_golden.json")))
g["stream"] = stream
json.dump(g, open(os.path.join(ROOT, "test/fixtures/scoring_golden.json"), "w"), ensure_ascii=False, indent=1)
print("stream ok", stream["known_upto"], [w["final_upto"] for w in wins])
