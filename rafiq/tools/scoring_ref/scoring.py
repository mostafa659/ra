"""Python reference of the Rafiq 0.7.0 decision engine (pure numpy; the Dart port must mirror it 1:1).

Input per ayah: logits[T,43] (25 fps, id 0 = blank) + expected reference (words from assets/qps_reference.json.gz).
Steps (spec §5): free greedy decode + edit alignment -> forced Viterbi spans -> substitution-aware
alignment-free CTC-GOP (local window) -> segment posterior mass -> per-class temperature -> tiers.
No language model. No heuristic escalates a word. Final tokens of words are judged like any other.

Thresholds in DEFAULT_CALIBRATION are UNCALIBRATED placeholders until tools/scoring_ref/calibrate.py is run on
self-test data (spec §7); every report must say so (see `calibration_status`).
"""
from __future__ import annotations
import json, math, os
from dataclasses import dataclass, field
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
VOCAB = json.load(open(os.path.join(HERE, "phoneme_vocab.json")))["id_to_char"]
CID = {c: i for i, c in enumerate(VOCAB)}
BLANK = 0
HARAKAT = "َُِ"
MADD_SYMS = set("اۦۥ")  # QPS madd symbols; plain و/ي are consonants or leen and are NOT madd
NEG = -1e30

# Confusable consonant groups (spec §5.2). To be extended by the model's own confusion matrix on validation data.
CONFUSABLE = ["صس", "ضدظ", "طت", "قكء", "حه", "عء", "غخ", "ذزظ", "ثس", "تث", "دذ", "شس", "جش"]

DEFAULT_CALIBRATION = {
    "version": 1,
    "calibration_status": "UNCALIBRATED_DEFAULTS",
    "temperature": {"vowel": 1.0, "consonant": 1.0, "madd": 1.0, "ghunna": 1.0},
    "window_frames": 10,
    "context_tokens": 2,
    # GOP (nats) = min over alternatives of (L_alt - L_canon): small/negative => alternative fits as well/better.
    # per class: [tauHard, tauSoft]. PROVISIONAL: tuned by hand on the owner's two 103:3 recordings
    # (rec_a fully correct, rec_b deliberate errors) -- see AUDIT/ENGINE docs. Replace with calibrate.py output.
    # error = free-decode disagrees AND gop < tauHard; doubt = gop < tauSoft.
    "tau": {
        "vowel_sub": [0.0, 0.5], "vowel_del": [-4.0, -3.0], "consonant_sub": [0.0, 1.0],
    },
    "no_gop_sentinel": 99.0,
    "madd_beats_error": 2, "madd_beats_doubt": 1,
}
LEVELS = {  # named sensitivity levels (spec §5.7): additive shifts in nats ('strict' = fewest flags, 'maximum' = most)
    "strict": {"soft_shift": -1.0, "hard_shift": -1.0, "beat_doubt": False},
    "balanced": {"soft_shift": 0.0, "hard_shift": 0.0, "beat_doubt": False},
    "maximum": {"soft_shift": 2.0, "hard_shift": 1.0, "beat_doubt": True},
}


def log_softmax(x: np.ndarray, temperature: float = 1.0) -> np.ndarray:
    z = x / temperature
    z = z - z.max(axis=-1, keepdims=True)
    return z - np.log(np.exp(z).sum(axis=-1, keepdims=True))


def lse(a):
    m = np.max(a)
    return m + math.log(np.sum(np.exp(a - m))) if m > NEG / 2 else NEG


def ctc_nll(lp: np.ndarray, seq: list[int]) -> float:
    """-log P(seq | lp) summed over ALL CTC alignments (forward algorithm). lp: [T,V] log-probs."""
    T = lp.shape[0]
    if not seq:
        return float(-lp[:, BLANK].sum())
    ext = [BLANK]
    for s in seq:
        ext += [s, BLANK]
    S = len(ext)
    e = np.array(ext)
    skip = np.zeros(S, dtype=bool)
    for i in range(2, S):
        skip[i] = ext[i] != BLANK and ext[i] != ext[i - 2]
    a = np.full(S, NEG)
    a[0] = lp[0, BLANK]
    if S > 1:
        a[1] = lp[0, ext[1]]
    for t in range(1, T):
        p1 = np.concatenate(([NEG], a[:-1]))
        p2 = np.concatenate(([NEG, NEG], a[:-2]))
        p2 = np.where(skip, p2, NEG)
        a = np.logaddexp(np.logaddexp(a, p1), p2) + lp[t, e]
    tot = np.logaddexp(a[-1], a[-2]) if S > 1 else a[-1]
    return float(-tot)


def viterbi_spans(lp: np.ndarray, seq: list[int]):
    """Forced alignment of seq to frames. Returns list of (start,end_exclusive) per token, or None if impossible."""
    T = lp.shape[0]
    ext = [BLANK]
    for s in seq:
        ext += [s, BLANK]
    S = len(ext)
    if T < len(seq):
        return None
    e = np.array(ext)
    skip = np.array([i >= 2 and ext[i] != BLANK and ext[i] != ext[i - 2] for i in range(S)])
    d = np.full(S, NEG)
    d[0] = lp[0, BLANK]
    d[1] = lp[0, ext[1]]
    bp = np.zeros((T, S), dtype=np.int8)  # 0 stay, 1 from s-1, 2 from s-2
    for t in range(1, T):
        c0 = d
        c1 = np.concatenate(([NEG], d[:-1]))
        c2 = np.where(skip, np.concatenate(([NEG, NEG], d[:-2])), NEG)
        st = np.stack([c0, c1, c2])
        k = st.argmax(0)
        d = st.max(0) + lp[t, e]
        bp[t] = k
    s = S - 1 if d[S - 1] >= d[S - 2] else S - 2
    path = [0] * T
    for t in range(T - 1, -1, -1):
        path[t] = s
        s -= int(bp[t, s])
    spans: list[list[int]] = [[-1, -1] for _ in seq]
    for t, st_ in enumerate(path):
        if st_ % 2 == 1:
            k = st_ // 2
            if spans[k][0] < 0:
                spans[k][0] = t
            spans[k][1] = t + 1
    return [tuple(x) for x in spans]


def greedy_decode(lp: np.ndarray):
    """CTC greedy decode -> (tokens, spans) with frame spans per emitted token."""
    ids = lp.argmax(-1)
    toks, spans, prev = [], [], -1
    for t, i in enumerate(ids):
        if i != BLANK and i != prev:
            toks.append(int(i)); spans.append([t, t + 1])
        elif i != BLANK and i == prev:
            spans[-1][1] = t + 1
        prev = i
    return toks, [tuple(s) for s in spans]


def edit_align(exp: list[int], dec: list[int]):
    """Levenshtein alignment. Returns per-expected-token: ('match'|'sub'|'del', decoded_index|None) and
    insertions: dict expected_index_after -> list of decoded indices inserted after that expected token (-1 = before first)."""
    n, m = len(exp), len(dec)
    D = np.zeros((n + 1, m + 1))
    D[:, 0] = np.arange(n + 1) * 1.0
    D[0, :] = np.arange(m + 1) * 1.0
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            D[i, j] = min(D[i - 1, j] + 1, D[i, j - 1] + 1, D[i - 1, j - 1] + (0 if exp[i - 1] == dec[j - 1] else 1))
    i, j = n, m
    res = [None] * n
    ins: dict[int, list[int]] = {}
    while i > 0 or j > 0:
        if i > 0 and j > 0 and D[i, j] == D[i - 1, j - 1] + (0 if exp[i - 1] == dec[j - 1] else 1):
            res[i - 1] = ("match" if exp[i - 1] == dec[j - 1] else "sub", j - 1)
            i -= 1; j -= 1
        elif i > 0 and D[i, j] == D[i - 1, j] + 1:
            res[i - 1] = ("del", None)
            i -= 1
        else:
            ins.setdefault(i - 1, []).append(j - 1)
            j -= 1
    return res, ins


def token_class(ch: str) -> str:
    if ch in HARAKAT:
        return "vowel"
    if ch in MADD_SYMS:
        return "madd"
    if ch in "نںمۜ":
        return "ghunna"
    return "consonant"


def alternatives(ch: str):
    """Perturbations for GOP (spec §5.2): returns list of replacement ids (None = deletion)."""
    if ch in HARAKAT:
        return [CID[h] for h in HARAKAT if h != ch] + [None]
    out = []
    for g in CONFUSABLE:
        if ch in g:
            out += [CID[c] for c in g if c != ch and c in CID]
    return sorted(set(out))


@dataclass
class Cfg:
    cal: dict = field(default_factory=lambda: json.loads(json.dumps(DEFAULT_CALIBRATION)))
    level: str = "balanced"

    def tau(self, cls: str):
        hard, soft = self.cal["tau"][cls]
        lv = LEVELS[self.level]
        return hard + lv["hard_shift"], soft + lv["soft_shift"]


def local_gop(lp: np.ndarray, seq: list[int], p: int, span, cfg: Cfg):
    """GOP at token p with a local window (spec §5.2). Returns (gop, best_alt_id, l_canon, l_alt)."""
    W, K = cfg.cal["window_frames"], cfg.cal["context_tokens"]
    lo, hi = max(0, span[0] - W), min(lp.shape[0], span[1] + W)
    a, b = max(0, p - K), min(len(seq), p + K + 1)
    sub = seq[a:b]
    q = p - a
    seg = lp[lo:hi]
    lc = ctc_nll(seg, sub)
    best, bid, bl = math.inf, None, None
    if not alternatives(VOCAB[seq[p]]):
        return cfg.cal["no_gop_sentinel"], None, lc, None
    for alt in alternatives(VOCAB[seq[p]]):
        s2 = sub[:q] + ([] if alt is None else [alt]) + sub[q + 1:]
        la = ctc_nll(seg, s2)
        if la - lc < best:
            best, bid, bl = la - lc, alt, la
    return best, bid, lc, bl


def segment_mass(lp: np.ndarray, span, sibling_ids: list[int]):
    """log-sum-exp posterior of each sibling over the aligned segment plus one adjacent frame each side."""
    lo, hi = max(0, span[0] - 1), min(lp.shape[0], span[1] + 1)
    return {VOCAB[s]: float(lse(lp[lo:hi, s])) for s in sibling_ids}


def build_expected(words: list[dict], final_stop: bool = True):
    """Concatenate per-word wasl forms (waqf form for the last word of the ayah if final_stop).
    Returns ids, word index per token, intervals {token_index: (lo, hi)} for free-length madd runs."""
    ids, wmap, iv = [], [], {}
    for i, w in enumerate(words):
        s = w["wasl"]
        base = len(ids)
        for k, ch in enumerate(s):
            ids.append(CID[ch]); wmap.append(i)
        for pos, lo, hi in (w.get("intervals") or []):
            iv[base + pos] = (lo, hi)
    return ids, wmap, iv


def judge_ayah(logits: np.ndarray, words: list[dict], cfg: Cfg | None = None, rate_sps: float | None = None):
    """Full-ayah (final-pass) judgement. Returns per-word dicts with tier and per-token evidence."""
    cfg = cfg or Cfg()
    T_ = cfg.cal["temperature"]
    # per-class temperature: apply group temperature on the token's own logit row at scoring time; the shared
    # matrix uses the vowel temperature for GOP of vowels and consonant temperature otherwise.
    lp_v = log_softmax(logits, T_["vowel"])
    lp_c = log_softmax(logits, T_["consonant"])
    exp, wmap, ivs = build_expected(words)
    dec, dspans = greedy_decode(lp_c)
    spans = viterbi_spans(lp_c, exp)
    if spans is None:
        return {"error": "audio too short for the expected sequence", "words": []}
    align, ins = edit_align(exp, dec)
    toks = []
    for p, tid in enumerate(exp):
        ch = VOCAB[tid]
        cls = token_class(ch)
        status, dj = align[p]
        rec = {"p": p, "w": wmap[p], "sym": ch, "class": cls, "span": spans[p], "free": status,
               "decoded": VOCAB[dec[dj]] if dj is not None else None, "tier": "ok"}
        if cls in ("vowel", "consonant"):
            lp = lp_v if cls == "vowel" else lp_c
            gop, alt, lc, la = local_gop(lp, exp, p, spans[p], cfg)
            if gop >= cfg.cal["no_gop_sentinel"]:
                gop = cfg.cal["no_gop_sentinel"]
            sibs = [CID[h] for h in HARAKAT] if cls == "vowel" else alternatives(ch)
            rec.update({"gop": round(gop, 4), "alt": VOCAB[alt] if alt is not None else "∅", "L_canon": round(lc, 4),
                        "L_alt": round(la, 4) if la is not None else None, "mass": {k: round(v, 3) for k, v in segment_mass(lp, spans[p], sibs).items()}})
            key = "vowel_sub" if cls == "vowel" else "consonant_sub"
            if cls == "vowel" and rec["alt"] == "∅":
                key = "vowel_del"
            hard, soft = cfg.tau(key)
            disagree = status != "match"
            geminate_tail = p > 0 and exp[p - 1] == exp[p]  # 2nd letter of a doubled run: judged as run length below
            if geminate_tail:
                rec["gop"] = None; rec["tier"] = "ok"
            elif disagree and gop < hard:
                rec["tier"] = "error"
            elif gop < soft:
                rec["tier"] = "doubt"
        toks.append(rec)
    # madd length vs legal interval (+-1 beat noise tolerated as doubt at most)
    p = 0
    while p < len(exp):
        if (p == 0 or exp[p - 1] != exp[p]) and (VOCAB[exp[p]] in MADD_SYMS or (p + 1 < len(exp) and exp[p + 1] == exp[p])):
            q = p
            while q + 1 < len(exp) and exp[q + 1] == exp[p]:
                q += 1
            lo, hi = ivs.get(p, (q - p + 1, q - p + 1))
            got = sum(1 for k in range(p, q + 1) if align[k][0] != "del") + sum(
                1 for k in range(p, q + 1) for j in ins.get(k, []) if dec[j] == exp[p])
            dev = max(lo - got, got - hi, 0)
            for k in range(p, q + 1):
                toks[k]["madd_len"] = {"got": got, "legal": [lo, hi]}
            is_madd = VOCAB[exp[p]] in MADD_SYMS
            # madd: >=2 beats outside the legal interval = error, 1 beat = doubt (model is +-1 beat noisy).
            # shadda / ghunna runs: the model often emits one symbol of a doubled letter (seen on the owner's
            # fully correct recording), so a deficit is at most 'doubt'; 'error' only for runs of >=3 (ghunna) with >=2 missing.
            if is_madd and dev >= cfg.cal["madd_beats_error"] or (not is_madd and dev >= 2 and (q - p + 1) >= 3):
                toks[p]["tier"] = max(toks[p]["tier"], "error", key=lambda x: {"ok": 0, "doubt": 1, "error": 2}[x]); toks[p]["madd_dev"] = dev
            elif dev >= cfg.cal["madd_beats_doubt"] and LEVELS[cfg.level]["beat_doubt"]:  # 1-beat noise: doubt only at maximum
                toks[p]["tier"] = max(toks[p]["tier"], "doubt", key=lambda x: {"ok": 0, "doubt": 1, "error": 2}[x]); toks[p]["madd_dev"] = dev
            p = q + 1
        else:
            p += 1
    order = {"ok": 0, "doubt": 1, "error": 2}
    out = []
    for i in range(len(words)):
        ts = [t for t in toks if t["w"] == i]
        worst = max((t["tier"] for t in ts), key=lambda x: order[x]) if ts else "ok"
        weakest = min((t for t in ts if t.get("gop") is not None), key=lambda t: t["gop"], default=None)
        out.append({"word": i, "uthmani": words[i]["uthmani"], "tier": worst, "weakest": weakest, "tokens": ts})
    return {"decoded": "".join(VOCAB[i] for i in dec), "expected": "".join(VOCAB[i] for i in exp),
            "calibration_status": cfg.cal["calibration_status"], "level": cfg.level, "words": out}
