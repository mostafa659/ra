"""Reference for the Dart FrameJudge: CTC forced alignment + per-token scoring.

For every reference token the judge asks two questions on the model's own
frame posteriors: how confident is the expected token around its aligned frame
(p_ref) and how strong is the best competing non-blank token there (p_comp).
Greedy text decoding hides both, which is why a model that "writes the rule
instead of the deviation" still shows a weaker expected token or a rising
competitor when the recitation deviates.
"""
import math
import struct

NEG_INF = float("-inf")

PRESETS = {
    "strict": dict(p_ref_warn=0.60, margin_warn=1.5, p_comp_warn=0.08, p_comp_hard=0.30,
                   duration_high=1.8, duration_low=0.5, duration_min_runs=3,
                   vowel_warn=0.10, vowel_hard=0.30, final_vowel_warn=0.05, vowel_margin=3.0),
    "balanced": dict(p_ref_warn=0.30, margin_warn=0.5, p_comp_warn=0.20, p_comp_hard=0.50,
                     duration_high=float("inf"), duration_low=0.0, duration_min_runs=99,
                     vowel_warn=0.20, vowel_hard=0.50, final_vowel_warn=0.08, vowel_margin=2.5),
    # "never miss": flags any doubt; expect many false alarms on correct recitation.
    "maximum": dict(p_ref_warn=0.90, margin_warn=3.5, p_comp_warn=0.02, p_comp_hard=0.20,
                    duration_high=1.45, duration_low=0.65, duration_min_runs=2,
                    vowel_warn=0.03, vowel_hard=0.15, final_vowel_warn=0.02, vowel_margin=3.5),
}

# Frames searched for a sibling vowel beyond a token's aligned span (CTC spikes are not time-locked to
# the sound: a changed vowel often fires a few frames away from where the reference token was aligned),
# never entering a neighbouring token's own span.
SIBLING_REACH_FRAMES = 6
# A sibling weaker than this is noise, whatever the margin to the expected token.
VOWEL_FLOOR = 0.01

SEV_NONE, SEV_WARN, SEV_HARD = 0, 1, 2

# Runs of a held sound needed to know the reciter's own tempo. Below a preset's
# own minimum the ratio is still measured (the technical report shows it) but
# the preset never flags on it, so no verdict depends on this constant.
MEASURE_MIN_RUNS = 3


def quantize(rows):
    """Round-trips every value through float32 (what the Dart FrameStore holds)."""
    pack, unpack = struct.pack, struct.unpack
    return [[unpack("f", pack("f", float(v)))[0] for v in row] for row in rows]


def _can_skip(expanded, state):
    return expanded[state] != expanded[state - 1] and expanded[state] != expanded[state - 2]


def forced_align(logp, targets, blank):
    """Viterbi CTC alignment; returns [(start, end_exclusive, mean_log_prob)] per target."""
    frames, count = len(logp), len(targets)
    expanded = []
    for token in targets:
        expanded += [blank, token]
    expanded.append(blank)
    states = len(expanded)
    if frames < count:
        raise ValueError("not enough frames")
    prev = [NEG_INF] * states
    cur = [NEG_INF] * states
    back = [[0] * states for _ in range(frames)]
    prev[0] = logp[0][blank]
    if states > 1:
        prev[1] = logp[0][expanded[1]]
    for t in range(1, frames):
        for s in range(states):
            best, move = prev[s], 0
            if s >= 1 and prev[s - 1] > best:
                best, move = prev[s - 1], 1
            if s >= 2 and _can_skip(expanded, s) and prev[s - 2] > best:
                best, move = prev[s - 2], 2
            cur[s] = best + logp[t][expanded[s]]
            back[t][s] = move
        prev, cur = cur, prev
        for i in range(states):
            cur[i] = NEG_INF
    state, best = states - 1, prev[states - 1]
    if states >= 2 and prev[states - 2] > best:
        state, best = states - 2, prev[states - 2]
    if not math.isfinite(best):
        raise ValueError("no valid CTC path")
    path = [0] * frames
    cursor = state
    for t in range(frames - 1, -1, -1):
        path[t] = cursor
        if t > 0:
            move = back[t][cursor]
            if move > cursor:
                raise ValueError("invalid backpointer")
            cursor -= move
    spans = []
    for j in range(count):
        token_state = 2 * j + 1
        start = end = -1
        total, hits = 0.0, 0
        for t in range(frames):
            if path[t] == token_state:
                if start < 0:
                    start = t
                end = t + 1
                total += logp[t][targets[j]]
                hits += 1
        if start < 0:
            raise ValueError("target %d not aligned" % j)
        spans.append((start, end, total / hits))
    return spans


def score_token(logp, span, ref, blank):
    """Peak expected probability and strongest non-blank competitor around the span."""
    frames = len(logp)
    lo, hi = max(0, span[0] - 1), min(frames, span[1] + 1)
    ref_peak, comp_peak, comp_id = NEG_INF, NEG_INF, -1
    for t in range(lo, hi):
        row = logp[t]
        ref_peak = max(ref_peak, row[ref])
        for c, value in enumerate(row):
            if c == ref or c == blank:
                continue
            if value > comp_peak:
                comp_peak, comp_id = value, c
    return ref_peak, comp_peak, comp_id


def decide(ref_peak, comp_peak, cfg):
    p_ref = math.exp(ref_peak)
    p_comp = math.exp(comp_peak) if comp_peak > NEG_INF else 0.0
    margin = ref_peak - comp_peak if comp_peak > NEG_INF else float("inf")
    if comp_peak >= ref_peak and p_comp >= cfg["p_comp_hard"]:
        return SEV_HARD, "substitution", p_ref, p_comp, margin
    if p_ref < cfg["p_ref_warn"]:
        return SEV_WARN, "weak", p_ref, p_comp, margin
    if margin < cfg["margin_warn"] and p_comp >= cfg["p_comp_warn"]:
        return SEV_WARN, "close", p_ref, p_comp, margin
    return SEV_NONE, "ok", p_ref, p_comp, margin


def _sibling_window(spans, j, frames):
    """Frames where a sibling vowel of token j counts: its span +-1 (as before), widened up to
    SIBLING_REACH_FRAMES each side but never into a neighbouring token's own span."""
    start, end = spans[j][0], spans[j][1]
    prev_end = spans[j - 1][1] if j > 0 else 0
    next_start = spans[j + 1][0] if j + 1 < len(spans) else frames
    lo = max(prev_end, start - SIBLING_REACH_FRAMES)
    hi = min(next_start, end + SIBLING_REACH_FRAMES)
    return min(max(0, start - 1), max(0, lo)), max(min(frames, end + 1), min(frames, hi))


def _median(values):
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2.0


def _duration_pass(result, spans, targets, duration_ids, cfg):
    """Held sounds (madd, ghunna, shadda) graded by timing, not by symbol count.

    A run is consecutive identical duration tokens. Its time per unit is the
    distance from its first unit to the next token, divided by its unit count.
    Compared with the median of all runs in the window (the reciter's own
    tempo), a run far longer or shorter is flagged. Over 3x is a pause, not a
    held note, and a run with no following token cannot be measured.
    """
    runs, j = [], 0
    while j < len(targets):
        k = j
        while k + 1 < len(targets) and targets[k + 1] == targets[j]:
            k += 1
        if k > j and targets[j] in duration_ids and k + 1 < len(targets):
            runs.append((j, k))
        j = k + 1
    per_unit = [(j0, (spans[j1 + 1][0] - spans[j0][0]) / float(j1 - j0 + 1)) for j0, j1 in runs]
    if len(per_unit) < min(cfg["duration_min_runs"], MEASURE_MIN_RUNS):
        return
    tempo = _median([value for _, value in per_unit])
    if tempo <= 0:
        return
    flaggable = len(per_unit) >= cfg["duration_min_runs"]
    for j0, value in per_unit:
        ratio = value / tempo
        result[j0]["ratio"] = ratio
        if not flaggable or ratio > 3.0 or result[j0]["kind"] not in ("ok", "edge"):
            continue
        if ratio > cfg["duration_high"]:
            result[j0].update(severity=SEV_WARN, kind="long")
        elif ratio < cfg["duration_low"]:
            result[j0].update(severity=SEV_WARN, kind="short")


def judge(logp, targets, blank, strictness="strict", soft_exempt=(), all_exempt=(), duration_ids=(),
          vowel_siblings=None, edge_gap_frames=None):
    """Returns one dict per target token (frames are window-relative).

    all_exempt: token indices never judged (an elided hamzat al-wasl, ...).
    soft_exempt: token indices where only a hard substitution counts; the last
    token of a word is legitimately weak when the reciter pauses after it.
    duration_ids: token ids whose repeated units encode a held duration.
    vowel_siblings: {token id: [ids of the same consonant with another short vowel]}; a strong
    sibling (even on a last token, even at a pause) is a changed vowel -> kind "vowel".
    edge_gap_frames: when set, the soft exemption applies only if the next token starts at least
    this many frames after the token ends (a real pause); mid-flow the final letter is judged.
    """
    vowel_siblings = vowel_siblings or {}
    logp = quantize(logp)
    cfg = PRESETS[strictness]
    spans = forced_align(logp, targets, blank)
    result = []
    for j, span in enumerate(spans):
        ref_peak, comp_peak, comp_id = score_token(logp, span, targets[j], blank)
        severity, kind, p_ref, p_comp, margin = decide(ref_peak, comp_peak, cfg)
        edge = j in soft_exempt
        if edge and edge_gap_frames is not None and j + 1 < len(spans):
            edge = (spans[j + 1][0] - spans[j][1]) >= edge_gap_frames
        if j in all_exempt:
            severity, kind = SEV_NONE, "exempt"
        elif edge and severity == SEV_WARN:
            severity, kind = SEV_NONE, "edge"
        sibs = vowel_siblings.get(targets[j])
        comp_out, p_comp_out, margin_out = comp_id, p_comp, margin
        if sibs and j not in all_exempt:
            lo, hi = _sibling_window(spans, j, len(logp))
            sib_peak, sib_id = NEG_INF, -1
            for t in range(lo, hi):
                for sid in sibs:
                    if logp[t][sid] > sib_peak:
                        sib_peak, sib_id = logp[t][sid], sid
            p_sib = math.exp(sib_peak)
            sib_margin = ref_peak - sib_peak
            # The last letter of a word said in the flow (no real pause after it) gets the sensitive rule:
            # the model leans on sentence context and \"corrects\" exactly that vowel, so an absolute
            # probability bar alone lets it through; the ratio to the expected token is checked as well.
            final_flow = j in soft_exempt and not edge
            warn_abs = min(cfg["vowel_warn"], cfg["final_vowel_warn"]) if final_flow else cfg["vowel_warn"]
            hit = sib_peak >= ref_peak and p_sib >= cfg["vowel_hard"]
            warn = p_sib >= warn_abs or (final_flow and p_sib >= VOWEL_FLOOR and sib_margin < cfg["vowel_margin"])
            if hit:
                severity, kind = SEV_HARD, "vowel"
            elif warn and severity < SEV_WARN:
                severity, kind = SEV_WARN, "vowel"
            if kind == "vowel":
                comp_out, p_comp_out, margin_out = sib_id, p_sib, sib_margin
        repeat = j > 0 and targets[j] == targets[j - 1]
        if repeat:  # extra units of a prolonged sound: duration, not identity
            severity, kind = SEV_NONE, "unit"
        result.append(dict(index=j, token=targets[j], start=span[0], end=span[1], severity=severity,
                           kind=kind, p_ref=p_ref, p_comp=p_comp_out, comp=comp_out, margin=margin_out, ratio=0.0))
    _duration_pass(result, spans, targets, set(duration_ids), cfg)
    return result
