"""Reference for the Dart technical report (lib/core/audio_engine/report/tech_report_model.dart).

Pure functions over one evidence record (schema v3, see REPORT_0_6_3_AR.md). Every
function here is mirrored one-to-one in Dart and pinned by
test/fixtures/report_golden.json, so change both together and regenerate the
fixture with tools/frame_engine/gen_report_fixtures.py.

What a report is: for every word of an ayah, what was expected (the reference
tokens), what was heard (the greedy CTC tokens attributed to the word by their
time), how the two differ, what the text evaluator and the frame judge said and
why the final colour is what it is. The report only reads what the engine
already logged; it never re-judges anything.
"""
import json
import math

SCHEMA_VERSION = 3
STEP_MS = 40            # one model output frame
SLACK_MS = 40           # a heard token may sit one frame outside its aligned span
PAUSE_RATIO = 3.0       # same constant as the judge: over 3x a held sound is a pause
IGNORED_KINDS = ("unit", "exempt", "edge")   # tokens the judge never grades on identity

STATUSES = ("correct", "warning", "uncertain", "incorrect", "pending")
FLAGGED_STATUSES = ("warning", "incorrect")

# "What was not caught": a word the app showed as correct is listed when one of
# its judged tokens is weaker than the `strict` preset would accept. These are
# reporting thresholds, independent of the sensitivity the judge ran with.
WATCH = {"p_ref": 0.60, "margin": 1.5, "p_comp": 0.08, "ratio_high": 1.8, "ratio_low": 0.5}

STATUS_AR = {
    "correct": "صحيحة",
    "warning": "تنبيه",
    "uncertain": "غير حاسم",
    "incorrect": "خطأ",
    "pending": "لم تُقرأ",
}
TEXT_VERDICT_AR = {
    "correct": "صحيحة",
    "tajweedWarning": "تنبيه تجويدي",
    "incorrect": "خطأ",
    "uncertain": "غير حاسم",
}
KIND_AR = {
    "substitution": "استبدال (منافس أقوى من المتوقع)",
    "weak": "ثقة منخفضة في الرمز المتوقع",
    "close": "منافس قريب من المتوقع",
    "vowel": "حركة مجاورة منافسة (تغيير حركة الحرف)",
    "long": "مدّ أو غنة أطول من المعتاد",
    "short": "مدّ أو غنة أقصر من المعتاد",
    "ok": "سليم",
    "unit": "وحدة مكرّرة (لا تُحكم منفردة)",
    "edge": "آخر رمز في الكلمة (مُعفى من التنبيه الخفيف)",
    "exempt": "همزة وصل محذوفة (لا تُحكم)",
}
SOURCE_AR = {"text": "المقيّم النصي", "frame": "الحَكَم الإطاري", "none": "لا حكم"}
WATCH_AR = {
    "weak": "ثقة منخفضة",
    "close": "منافس قريب",
    "duration": "زمن المدّ بعيد عن المعتاد",
    "suppressed": "رصدها الحَكَم وعُلّق بحارس المعايرة",
}

# What the reader says about the app's verdict on one word.
LABELS = (
    ("confirmed", "صحيح"),
    ("false_alarm", "إنذار كاذب: قلتها صحيحة"),
    ("missed", "فاتك خطأ: أخطأتُ ولم تُنبّه"),
)
LABEL_CODES = tuple(code for code, _ in LABELS)
ERROR_TYPES = (
    ("haraka", "حركة"),
    ("madd", "مدّ"),
    ("ghunna", "غنة"),
    ("ikhfa", "إخفاء"),
    ("idgham", "إدغام"),
    ("qalqala", "قلقلة"),
    ("harf", "حرف"),
    ("tafkheem", "تفخيم/ترقيق"),
    ("waqf", "وقف/وصل"),
    ("missing_word", "كلمة ناقصة"),
    ("extra_word", "كلمة زائدة"),
    ("other", "أخرى"),
)
ERROR_TYPE_CODES = tuple(code for code, _ in ERROR_TYPES)
MAX_TYPES = 3
MAX_NOTE = 500


# ----------------------------------------------------------------- primitives

def fmt2(value):
    """Two decimals, identical in Python and Dart (no banker's rounding ties)."""
    if value is None or value != value:
        return "—"
    if abs(value) >= 99.0:
        return "∞" if value > 0 else "-∞"
    scaled = int(math.floor(abs(value) * 100.0 + 0.5))
    sign = "-" if value < 0 and scaled > 0 else ""
    return "%s%d.%02d" % (sign, scaled // 100, scaled % 100)


def norm_label(text):
    """A token as compared in the report: no word-start mark, no whitespace."""
    out = str(text)
    for junk in ("\u2581", " ", "\t", "\n", "\r", "\u00a0"):
        out = out.replace(junk, "")
    return out


def is_flagged(status):
    return status in FLAGGED_STATUSES


def align_ops(expected, heard):
    """Edit-distance alignment for display only (it never decides a verdict).

    Returns [op, expected, heard] with op '=' match, '~' substitution,
    '-' expected token not heard, '+' heard token not expected. Backtrace
    prefers the diagonal, then a missing token, then an extra one.
    """
    n, m = len(expected), len(heard)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        dp[i][0] = i
    for j in range(m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if expected[i - 1] == heard[j - 1] else 1
            dp[i][j] = min(dp[i - 1][j - 1] + cost, dp[i - 1][j] + 1, dp[i][j - 1] + 1)
    ops = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0:
            cost = 0 if expected[i - 1] == heard[j - 1] else 1
            if dp[i][j] == dp[i - 1][j - 1] + cost:
                ops.append(["=" if cost == 0 else "~", expected[i - 1], heard[j - 1]])
                i -= 1
                j -= 1
                continue
        if i > 0 and dp[i][j] == dp[i - 1][j] + 1:
            ops.append(["-", expected[i - 1], ""])
            i -= 1
            continue
        ops.append(["+", "", heard[j - 1]])
        j -= 1
    ops.reverse()
    return ops


# ------------------------------------------------------------- record parsing

def _num(value, default=0.0):
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value))
    except ValueError:
        return default


def heard_tokens(record):
    """[(label, ms)] from the record's cumulative greedy tokens and their times."""
    tokens = record.get("tokens") or []
    times = record.get("times") or []
    out = []
    for k in range(len(tokens)):
        label = norm_label(tokens[k])
        if not label or k >= len(times):
            continue
        out.append((label, int(math.floor(_num(times[k]) * 1000.0 + 0.5))))
    return out


def _token_dicts(rows):
    by_word = {}
    for row in rows:
        by_word.setdefault(int(row[1]), []).append({
            "j": int(row[0]),
            "label": str(row[2]),
            "start_ms": int(row[3]),
            "end_ms": int(row[4]),
            "severity": int(row[5]),
            "kind": str(row[6]),
            "p_ref": _num(row[7]),
            "p_comp": _num(row[8]),
            "comp": str(row[9]),
            "margin": _num(row[10]),
            "ratio": _num(row[11]),
        })
    return by_word


def _worst_flag(tokens):
    best = None
    for t in tokens:
        if t["severity"] <= 0:
            continue
        if best is None or t["severity"] > best["severity"] or (
                t["severity"] == best["severity"] and t["margin"] < best["margin"]):
            best = t
    return best


def _weakest(tokens):
    best = None
    for t in tokens:
        if t["kind"] in IGNORED_KINDS:
            continue
        if best is None or t["p_ref"] < best["p_ref"]:
            best = t
    return best


def _distance(t, a, b):
    if t < a:
        return a - t
    if t >= b:
        return t - b + 1
    return 0


def _word_row(record, i):
    for row in record.get("words") or []:
        if int(_num(row.get("i"), -1)) == i:
            return row
    return {}


# ------------------------------------------------------------------- the report

def build_ayah_report(record, labels=None):
    """Everything the report screen and the exports show for one ayah record.

    labels: {word_index: label dict} (latest label per word, see make_label).
    """
    labels = labels or {}
    expected = record.get("expected") or []
    frames = record.get("frames") or {}
    frames_status = str(frames.get("status") or "none")
    rows = frames.get("tokens") or []
    word_map = frames.get("wordMap")
    guard = frames.get("guard") or {}
    has_frames = frames_status == "ok" and len(rows) > 0 and word_map is not None
    by_reduced = _token_dicts(rows) if has_frames else {}
    reduced_of = {}
    if has_frames:
        for r, i in enumerate(word_map):
            reduced_of[int(i)] = r

    heard = heard_tokens(record)
    win_start = int(_num(frames.get("startFrame"))) * STEP_MS if has_frames else 0
    win_end = int(_num(frames.get("endFrame"))) * STEP_MS if has_frames else 0

    # Judged words have an aligned span; the others share the gaps between them.
    spans = {}
    for i in range(len(expected)):
        toks = by_reduced.get(reduced_of.get(i, -1))
        if toks:
            spans[i] = (min(t["start_ms"] for t in toks), max(t["end_ms"] for t in toks))
    judged = sorted(spans)
    assigned = {i: [] for i in range(len(expected))}
    scope = {i: ("window" if i in spans else "none") for i in range(len(expected))}
    unattributed = []
    if has_frames and judged:
        runs = _gap_runs(len(expected), judged, spans, win_start, win_end)
        for run in runs:
            kind = "gap" if len(run["words"]) == 1 else "gap_shared"
            for i in run["words"]:
                scope[i] = kind
        for label, ms in heard:
            if ms < win_start or ms >= win_end:
                continue
            owner = _owner(ms, judged, spans)
            if owner is None:
                owner = _gap_owner(ms, runs)
            if owner is None:
                unattributed.append([label, ms])
            else:
                assigned[owner].append([label, ms])
        # the sounds of a shared gap cannot be split between its words: each shows them all
        for run in runs:
            if len(run["words"]) > 1:
                shared = list(assigned[run["words"][0]])
                for i in run["words"]:
                    assigned[i] = [list(t) for t in shared]

    words = []
    counts = {s: 0 for s in STATUSES}
    for i in range(len(expected)):
        row = _word_row(record, i)
        status = str(row.get("st") or "pending")
        if status not in STATUSES:
            status = "pending"
        counts[status] += 1
        tv = row.get("tv")
        hist = [str(h) for h in (row.get("hist") or [])]
        fa = str(row.get("fa") or "none")
        frame = None
        expected_labels = None
        ops = None
        span = None
        if i in spans:
            toks = by_reduced[reduced_of[i]]
            flag = _worst_flag(toks)
            frame = {
                "reduced": reduced_of[i],
                "tokens": toks,
                "flag": flag,
                "weakest": _weakest(toks),
            }
            expected_labels = [norm_label(t["label"]) for t in toks if norm_label(t["label"])]
            # an elided hamzat al-wasl is not expected to be heard, so the diff leaves it out
            compared = [norm_label(t["label"]) for t in toks if t["kind"] != "exempt" and norm_label(t["label"])]
            span = [spans[i][0], spans[i][1]]
            ops = align_ops(compared, [t[0] for t in assigned[i]])
        if fa == "applied":
            source = "frame"
        elif tv is not None:
            source = "text"
        else:
            source = "none"
        word = {
            "i": i,
            "text": str(row.get("text") or ""),
            "ph": str(expected[i]),
            "status": status,
            "source": source,
            "text_eval": None if tv is None else {
                "verdict": str(tv),
                "message": row.get("tm"),
                "rule": row.get("tr"),
                "advanced": bool(row.get("adv")),
                "events": int(_num(row.get("n"), 0)),
                "hist": hist,
            },
            "frame": frame,
            "frame_action": fa,
            "span_ms": span,
            "expected_labels": expected_labels,
            "heard": assigned[i],
            "heard_scope": scope[i],
            "ops": ops,
            "label": labels.get(i),
        }
        word["reasons"] = word_reasons(word, frames_status, has_frames, guard)
        words.append(word)

    return {
        "rid": str(record.get("rid", "")),
        "surah": int(_num(record.get("surah"))),
        "ayah": int(_num(record.get("ayah"))),
        "at": str(record.get("at", "")),
        "complete": bool(record.get("complete")),
        "reference": str(record.get("reference", "")),
        "sensitivity": str(record.get("sensitivity", "")),
        "strictness": str(record.get("strictness", "")),
        "frames_status": frames_status,
        "has_frames": has_frames,
        "guard": guard,
        "cfg": frames.get("cfg"),
        "audio": record.get("audio"),
        "perf": record.get("perf"),
        "alignment": str(record.get("alignment", "")),
        "counts": counts,
        "words": words,
        "watch": watch_list(words),
        "unattributed": unattributed,
    }


def _gap_runs(word_count, judged, spans, win_start, win_end):
    """Maximal runs of consecutive non-judged words with the time interval they own."""
    runs = []
    first = judged[0]
    if first > 0:
        runs.append({"words": list(range(0, first)), "from": win_start, "to": spans[first][0]})
    for k in range(len(judged) - 1):
        a, b = judged[k], judged[k + 1]
        if b - a > 1:
            runs.append({"words": list(range(a + 1, b)), "from": spans[a][1], "to": spans[b][0]})
    last = judged[-1]
    if last < word_count - 1:
        runs.append({"words": list(range(last + 1, word_count)), "from": spans[last][1], "to": win_end})
    return runs


def _owner(ms, judged, spans):
    """The judged word whose aligned span holds the token, else the nearest within a frame."""
    for i in judged:
        if spans[i][0] <= ms < spans[i][1]:
            return i
    best, best_distance = None, SLACK_MS + 1
    for i in judged:
        d = _distance(ms, spans[i][0], spans[i][1])
        if d <= SLACK_MS and d < best_distance:
            best, best_distance = i, d
    return best


def _gap_owner(ms, runs):
    for run in runs:
        if run["from"] <= ms < run["to"]:
            return run["words"][0]
    return None


def word_reasons(word, frames_status, has_frames, guard):
    out = []
    te = word["text_eval"]
    if te is None:
        out.append("المقيّم النصي: لم يُصدر حكمًا على هذه الكلمة.")
    else:
        line = "المقيّم النصي: " + TEXT_VERDICT_AR.get(te["verdict"], te["verdict"])
        if te["message"]:
            line += " — " + str(te["message"])
        if te["rule"]:
            line += " (قاعدة: " + str(te["rule"]) + ")"
        if len(te["hist"]) > 1:
            line += " [تسلسل الأحكام: " + " ثم ".join(TEXT_VERDICT_AR.get(h, h) for h in te["hist"]) + "]"
        out.append(line)

    fr = word["frame"]
    if not has_frames:
        out.append("الحَكَم الإطاري: لم يُجرَ (%s)." % frames_status)
    elif fr is None and word["status"] == "pending":
        out.append("الحَكَم الإطاري: لا شيء للحكم عليه (الكلمة لم تُقرأ بعد).")
    elif fr is None:
        out.append("الحَكَم الإطاري: الكلمة خارج المرجع الإطاري (حذفها المقيّم النصي منه كي لا تُزاح محاذاة جاراتها).")
    elif fr["flag"] is not None:
        t = fr["flag"]
        line = "الحَكَم الإطاري: %s على «%s» — p_ref=%s، p_comp=%s" % (
            KIND_AR.get(t["kind"], t["kind"]), t["label"], fmt2(t["p_ref"]), fmt2(t["p_comp"]))
        if t["comp"]:
            line += " («%s»)" % t["comp"]
        line += "، الهامش=%s" % fmt2(t["margin"])
        if t["kind"] in ("long", "short"):
            line += "، نسبة المد=%s×" % fmt2(t["ratio"])
        out.append(line + ".")
    elif fr["weakest"] is None:
        out.append("الحَكَم الإطاري: لا رموز قابلة للحكم في هذه الكلمة.")
    else:
        t = fr["weakest"]
        out.append("الحَكَم الإطاري: لا ملاحظة؛ أضعف رمز «%s»: p_ref=%s، p_comp=%s، الهامش=%s." % (
            t["label"], fmt2(t["p_ref"]), fmt2(t["p_comp"]), fmt2(t["margin"])))

    fa = word["frame_action"]
    if fa == "applied":
        out.append("أُضيف حكم الحَكَم الإطاري إلى الكلمة فصارت «%s»." % STATUS_AR[word["status"]])
    elif fa == "guard_suppressed":
        out.append("عُلّق حكم الحَكَم الإطاري: لوحظت أكثر من %s٪ من كلمات الآية فاحتُمل سوء معايرة ولم يُعرض."
                   % int(_num(guard.get("limit"), 40)))
    elif fa == "skipped":
        out.append("لم يغيّر حكم الحَكَم الإطاري الحالة (الكلمة مُعلَّمة بخطأ مسبقًا أو انتقلت الآية).")

    out.append("الحكم النهائي: %s — المصدر: %s." % (STATUS_AR[word["status"]], SOURCE_AR[word["source"]]))
    return out


def watch_list(words):
    """Words shown as correct whose evidence is weak or near a threshold."""
    out = []
    for w in words:
        if w["status"] != "correct":
            continue
        items = []
        fr = w["frame"]
        suppressed = w["frame_action"] == "guard_suppressed"
        if fr is not None:
            for t in fr["tokens"]:
                if t["kind"] not in IGNORED_KINDS:
                    if t["p_ref"] < WATCH["p_ref"]:
                        items.append({"type": "weak", "j": t["j"], "label": t["label"],
                                      "p_ref": t["p_ref"], "p_comp": t["p_comp"], "margin": t["margin"],
                                      "doubt": 1.0 - t["p_ref"]})
                    if t["margin"] < WATCH["margin"] and t["p_comp"] >= WATCH["p_comp"]:
                        total = t["p_ref"] + t["p_comp"]
                        items.append({"type": "close", "j": t["j"], "label": t["label"],
                                      "p_ref": t["p_ref"], "p_comp": t["p_comp"], "margin": t["margin"],
                                      "doubt": (t["p_comp"] / total) if total > 0 else 0.0})
                ratio = t["ratio"]
                if t["kind"] != "exempt" and 0 < ratio <= PAUSE_RATIO and (
                        ratio > WATCH["ratio_high"] or ratio < WATCH["ratio_low"]):
                    far = ratio if ratio >= 1.0 else 1.0 / ratio
                    items.append({"type": "duration", "j": t["j"], "label": t["label"],
                                  "ratio": ratio, "doubt": 1.0 - 1.0 / far})
        if suppressed:
            items.append({"type": "suppressed", "j": -1, "label": "", "doubt": 0.0})
        if not items:
            continue
        out.append({
            "word": w["i"],
            "doubt": max(item["doubt"] for item in items),
            "suppressed": suppressed,
            "items": items,
        })
    out.sort(key=lambda e: (0 if e["suppressed"] else 1, -e["doubt"], e["word"]))
    return out


# ----------------------------------------------------------------------- labels

def make_label(label, types=(), note="", status="pending"):
    """Validates and normalises a reader's label for a word shown with `status`.

    Returns (label_dict, error). error is None when the label is acceptable:
    a false alarm needs the word to have been flagged, a miss needs it not to
    have been, a correct word has no error type, and types are known and unique.
    """
    if label == "none":
        return {"label": "none", "types": [], "note": ""}, None
    if label not in LABEL_CODES:
        return None, "unknown_label"
    flagged = is_flagged(status)
    if label == "false_alarm" and not flagged:
        return None, "false_alarm_needs_flagged"
    if label == "missed" and flagged:
        return None, "missed_needs_unflagged"
    clean = []
    for t in types:
        if t not in ERROR_TYPE_CODES:
            return None, "unknown_type"
        if t not in clean:
            clean.append(t)
    if len(clean) > MAX_TYPES:
        return None, "too_many_types"
    if clean and (label == "false_alarm" or (label == "confirmed" and not flagged)):
        return None, "type_without_error"
    text = str(note or "").strip()
    if len(text) > MAX_NOTE:
        text = text[:MAX_NOTE]
    return {"label": label, "types": clean, "note": text}, None


def label_line(record, word, label, at):
    """The append-only line written to the evidence log for one labelling action."""
    return {
        "v": SCHEMA_VERSION,
        "kind": "label",
        "at": at,
        "rid": str(record.get("rid", "")),
        "surah": int(_num(record.get("surah"))),
        "ayah": int(_num(record.get("ayah"))),
        "word": int(word),
        "label": label["label"],
        "types": list(label["types"]),
        "note": label["note"],
        "shown": str(_word_row(record, int(word)).get("st") or "pending"),
    }


def latest_labels(lines):
    """{(rid, word): label line}: later lines win; label 'none' removes."""
    out = {}
    for line in lines:
        if line.get("kind") != "label":
            continue
        key = (str(line.get("rid", "")), int(_num(line.get("word"), -1)))
        if line.get("label") == "none":
            out.pop(key, None)
        else:
            out[key] = line
    return out


# ------------------------------------------------------------------ real-time health

# Worker busy time / audio time at or above 1.0 means the engine falls further behind
# the reciter every second (the queue only grows); 0.8 leaves no room for a slow moment.
RTF_SLOW = 1.0
RTF_TIGHT = 0.8
BACKLOG_SLOW = 8          # queued audio blocks (0.24 s each, about 1.9 s)
LAG_P95_TIGHT_MS = 1500   # a token reaching the screen more than 1.5 s after it was said


def _round_ms(value):
    return int(math.floor(float(value) + 0.5))


def _round1(value):
    return math.floor(float(value) * 10.0 + 0.5) / 10.0


def perf_summary(values):
    """n, mean, p50, p95 (nearest rank) and max of a list of milliseconds, to 0.1 ms."""
    n = len(values)
    if n == 0:
        return {"n": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
    ordered = sorted(float(v) for v in values)

    def nearest(q):
        rank = int(math.ceil(q * n)) - 1
        return ordered[min(n - 1, max(0, rank))]

    # a plain left-to-right sum: the builtin sum() is compensated since Python 3.12, which
    # would make the reference differ in the last bit from the Dart loop (and across versions)
    total = 0.0
    for v in ordered:
        total += v
    return {
        "n": n,
        "mean": _round1(total / n),
        "p50": _round1(nearest(0.50)),
        "p95": _round1(nearest(0.95)),
        "max": _round1(ordered[-1]),
    }


def _stat(perf, key, field):
    block = perf.get(key)
    if isinstance(block, dict):
        return _num(block.get(field), 0.0)
    return 0.0


def perf_health(perf):
    """('ok'|'tight'|'slow', Arabic sentence) for a record's perf block."""
    perf = perf or {}
    rtf = _num(perf.get("workerRtf"), 0.0)
    if rtf <= 0.0:
        rtf = _num(perf.get("realTimeFactor"), 0.0)
    backlog = int(_num(perf.get("backlogMax"), 0.0))
    lag_n = int(_stat(perf, "lag", "n"))
    lag_p95 = _stat(perf, "lag", "p95")
    if rtf >= RTF_SLOW or backlog >= BACKLOG_SLOW:
        return "slow", "الجهاز أبطأ من الصوت: يتراكم التأخر (نسبة الزمن %s، أقصى طابور %d كتلة)." % (fmt2(rtf), backlog)
    if rtf >= RTF_TIGHT or (lag_n > 0 and lag_p95 > LAG_P95_TIGHT_MS):
        return "tight", "الجهاز على الحافة: نسبة الزمن %s، كمون الرمز p95 %s مللي ثانية." % (
            fmt2(rtf), _round_ms(lag_p95))
    if lag_n > 0:
        return "ok", "السرعة جيدة: نسبة الزمن %s، كمون الرمز p95 %s مللي ثانية." % (fmt2(rtf), _round_ms(lag_p95))
    return "ok", "السرعة جيدة: نسبة الزمن %s." % fmt2(rtf)


def perf_line(perf):
    """One Arabic line with every stage that was measured (older records show less)."""
    perf = perf or {}
    hop = int(_num(perf.get("hopMs"), 480.0))
    parts = ["الأداء: خطوة النموذج %s مللي ثانية لكل %d (أقصى %s)" % (
        _round_ms(_num(perf.get("stepMsMean"))), hop, _round_ms(_num(perf.get("stepMsMax"))))]
    if _num(perf.get("workerRtf"), 0.0) > 0.0:
        parts.append("نسبة زمن المحرك كله %s" % fmt2(_num(perf.get("workerRtf"))))
    if _stat(perf, "lag", "n") > 0:
        parts.append("كمون الرمز p95 %s (أقصى %s) مللي ثانية" % (
            _round_ms(_stat(perf, "lag", "p95")), _round_ms(_stat(perf, "lag", "max"))))
    if _stat(perf, "eval", "n") > 0:
        parts.append("المقيّم على الواجهة p95 %s (أقصى %s) مللي ثانية" % (
            _round_ms(_stat(perf, "eval", "p95")), _round_ms(_stat(perf, "eval", "max"))))
    if _stat(perf, "judge", "n") > 0:
        parts.append("الحَكَم %s مللي ثانية" % _round_ms(_stat(perf, "judge", "mean")))
    wait = int(_num(perf.get("judgeWaitMs"), 0.0))
    if wait > 0:
        parts.append("انتظار الانتقال للحَكَم %d مللي ثانية" % wait)
    if "backlogMax" in perf:
        parts.append("أقصى طابور %d كتلة" % int(_num(perf.get("backlogMax"), 0.0)))
    return " · ".join(parts) + "."


# ----------------------------------------------------------------------- exports

def summary_text(report):
    """Plain-text summary of one ayah report (what the export copies)."""
    lines = []
    lines.append("تقرير رَفِيق الفني — سورة %d آية %d" % (report["surah"], report["ayah"]))
    lines.append("السجل: %s | الوقت: %s" % (report["rid"], report["at"]))
    lines.append("المرجع: %s | الحساسية: %s | الصرامة: %s | التحليل الإطاري: %s" % (
        report["reference"], report["sensitivity"], report["strictness"], report["frames_status"]))
    c = report["counts"]
    if report.get("perf"):
        lines.append(perf_line(report["perf"]))
        lines.append(perf_health(report["perf"])[1])
    lines.append("الكلمات: %d — صحيحة %d، تنبيه %d، خطأ %d، غير حاسم %d، لم تُقرأ %d" % (
        len(report["words"]), c["correct"], c["warning"], c["incorrect"], c["uncertain"], c["pending"]))
    for w in report["words"]:
        lines.append("")
        lines.append("كلمة %d «%s» — %s" % (w["i"] + 1, w["text"], STATUS_AR[w["status"]]))
        lines.append("  المتوقع: %s" % w["ph"])
        if w["heard_scope"] == "none":
            lines.append("  المسموع: غير متاح لهذه الكلمة")
        else:
            heard = " ".join("%s@%d" % (t[0], t[1]) for t in w["heard"])
            note = " (مشترك مع كلمات الفجوة)" if w["heard_scope"] == "gap_shared" else ""
            lines.append("  المسموع%s: %s" % (note, heard if heard else "—"))
        if w["span_ms"] is not None:
            lines.append("  الزمن: من %d إلى %d مللي ثانية" % (w["span_ms"][0], w["span_ms"][1]))
        if w["ops"] is not None:
            lines.append("  المحاذاة: " + " ".join(_op_text(op) for op in w["ops"]))
        for reason in w["reasons"]:
            lines.append("  - " + reason)
        if w["label"] is not None:
            lines.append("  التسمية: " + label_text(w["label"]))
    if report["watch"]:
        lines.append("")
        lines.append("ما لم يُرصد (صحيحة بثقة منخفضة أو قريبة من العتبة):")
        for entry in report["watch"]:
            kinds = "، ".join(WATCH_AR[item["type"]] for item in entry["items"])
            lines.append("  كلمة %d: %s" % (entry["word"] + 1, kinds))
    return "\n".join(lines)


def _op_text(op):
    if op[0] == "=":
        return op[1]
    if op[0] == "~":
        return "%s←%s" % (op[1], op[2])
    if op[0] == "-":
        return "[ناقص %s]" % op[1]
    return "[زائد %s]" % op[2]


def label_text(label):
    names = dict(LABELS)
    types = dict(ERROR_TYPES)
    text = names.get(label["label"], label["label"])
    if label.get("types"):
        text += " (" + "، ".join(types.get(t, t) for t in label["types"]) + ")"
    if label.get("note"):
        text += " — " + label["note"]
    return text


def export_document(records, label_lines, exported_at):
    """The JSON export: raw records + latest labels + computed reports."""
    latest = latest_labels(label_lines)
    reports = []
    for record in records:
        rid = str(record.get("rid", ""))
        mine = {w: line for (r, w), line in latest.items() if r == rid}
        reports.append(build_ayah_report(record, mine))
    return {
        "format": "rafiq-report/%d" % SCHEMA_VERSION,
        "exportedAt": exported_at,
        "records": records,
        "labels": [line for line in latest.values()],
        "reports": reports,
    }


def dumps(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
