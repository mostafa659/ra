#!/usr/bin/env python3
"""Measures the app against the reader's own labels.

Input: the evidence log (rafiq_evidence.jsonl, schema v3: ayah records + label
lines) or the JSON export of the technical report (format rafiq-report/3).

    python3 tools/frame_engine/label_analysis.py evidence.jsonl
    python3 tools/frame_engine/label_analysis.py export.json --target-fpr 0.02 --json out.json

Ground truth comes only from the reader's labels (never from the app's verdict):
  confirmed   the app's verdict on the word was right
  false_alarm the app flagged a word the reader said correctly
  missed      the reader erred and the app did not flag the word
A word is "flagged" when its final status is warning or incorrect. Unlabelled
words are NOT assumed correct unless --assume-unlabeled-correct is given: use
that flag only when you labelled every false alarm and every miss in the
ayahs you recorded (the app has a one-tap "rest are correct" action for it).

Threshold simulation re-applies the judge's own decision rule (judge_ref.decide
plus the unit / last-token / duration rules) to the p_ref, p_comp, margin and
duration ratio logged for every token, so it needs no model and no audio. It
does not simulate the 40% calibration guard, and it takes the text evaluator's
flags as given. Small samples give wide intervals: the report prints them and
refuses to call a suggestion anything but exploratory below the minimums.
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

HARAKAT = set("\u064b\u064c\u064d\u064e\u064f\u0650\u0652\u0670")
MADD_LABELS = set("\u0627\u06e5\u06e6\u0649")
NASAL_LABELS = set("\u0646\u0645\u06ba")
EMPHATIC_PAIRS = {("\u0635", "\u0633"), ("\u0636", "\u062f"), ("\u0637", "\u062a"), ("\u0638", "\u0630")}
CLAIM_STATUSES = ("correct", "warning", "incorrect")
MIN_CORRECT = 30
MIN_ERRORS = 10

INF = float("inf")


# ------------------------------------------------------------------- ingestion

def load_events(text):
    """Returns (records {rid: record}, label_lines [dict], stats)."""
    records, labels = {}, []
    stats = {"bad_lines": 0, "old_records": 0}
    text = text.strip()
    if not text:
        return records, labels, stats
    document = None
    try:
        document = json.loads(text)
    except ValueError:
        document = None
    if isinstance(document, dict) and str(document.get("format", "")).startswith("rafiq-report/"):
        for rec in document.get("records") or []:
            if rec.get("rid"):
                records[str(rec["rid"])] = rec
        labels = [line for line in document.get("labels") or [] if line.get("kind") == "label"]
        return records, labels, stats
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            stats["bad_lines"] += 1
            continue
        if not isinstance(obj, dict):
            stats["bad_lines"] += 1
        elif obj.get("kind") == "label":
            labels.append(obj)
        elif obj.get("rid") and "expected" in obj:
            records[str(obj["rid"])] = obj
        elif "expected" in obj:
            stats["old_records"] += 1
    return records, labels, stats


# ------------------------------------------------------------- per-word table

def _nonignored(tokens):
    return [t for t in tokens if t["kind"] not in rr.IGNORED_KINDS]


def flag_kind(word):
    if not rr.is_flagged(word["status"]):
        return None
    if word["source"] == "frame":
        fr = word["frame"]
        if fr and fr["flag"]:
            return fr["flag"]["kind"]
        return "frame"
    te = word["text_eval"]
    return "text:" + (te["verdict"] if te else "unknown")


def type_from_tokens(label, comp):
    if label in HARAKAT:
        return "haraka"
    if (label, comp) in EMPHATIC_PAIRS or (comp, label) in EMPHATIC_PAIRS:
        return "tafkheem"
    if label in MADD_LABELS:
        return "madd"
    if label in NASAL_LABELS:
        return "ghunna"
    return "harf"


def predicted_type(word):
    """Heuristic class of a flag, used only for the per-type confusion matrix.

    Frame flags are classified from the flagged token and its strongest rival;
    text-evaluator flags from the tajweed rule code when it names one. The
    table is a starting point: the matrix itself shows how flags really map to
    the readers' error types.
    """
    if not rr.is_flagged(word["status"]):
        return "none"
    if word["source"] == "frame" and word["frame"] and word["frame"]["flag"]:
        t = word["frame"]["flag"]
        if t["kind"] in ("long", "short"):
            return "ghunna" if t["label"] in NASAL_LABELS else "madd"
        return type_from_tokens(t["label"], t["comp"])
    te = word["text_eval"] or {}
    rule = str(te.get("rule") or "").lower()
    for needle, kind in (("madd", "madd"), ("ghunna", "ghunna"), ("ikhfa", "ikhfa"),
                         ("idgham", "idgham"), ("qalqal", "qalqala")):
        if needle in rule:
            return kind
    return "other"


def _make_row(report, word, truth, line, implicit):
    frame_tokens = []
    last_j = -1
    if word["frame"]:
        frame_tokens = word["frame"]["tokens"]
        last_j = max(t["j"] for t in frame_tokens) if frame_tokens else -1
    runs = 0
    for w in report["words"]:
        if w["frame"]:
            runs += sum(1 for t in w["frame"]["tokens"] if t["ratio"] > 0)
    te = word["text_eval"]
    return {
        "rid": report["rid"], "surah": report["surah"], "ayah": report["ayah"],
        "word": word["i"], "status": word["status"],
        "flagged": rr.is_flagged(word["status"]),
        "claim": word["status"] in CLAIM_STATUSES,
        "truth": truth,
        "types": list(line.get("types") or []) if line else [],
        "implicit": implicit,
        "source": word["source"],
        "kind": flag_kind(word),
        "pred": predicted_type(word),
        "text_flagged": bool(te and te["verdict"] in ("tajweedWarning", "incorrect")),
        "tokens": frame_tokens,
        "last_j": last_j,
        "ayah_runs": runs,
        "sensitivity": report["sensitivity"],
    }


def build_rows(records, label_lines, assume_unlabeled_correct=False):
    latest = rr.latest_labels(label_lines)
    reports = {rid: rr.build_ayah_report(rec) for rid, rec in records.items()}
    rows, orphans, inconsistent = [], [], []
    for (rid, w), line in sorted(latest.items()):
        report = reports.get(rid)
        if report is None or not (0 <= w < len(report["words"])):
            orphans.append([rid, w])
            continue
        word = report["words"][w]
        flagged = rr.is_flagged(word["status"])
        code = line.get("label")
        if (code == "false_alarm" and not flagged) or (code == "missed" and flagged) or code not in rr.LABEL_CODES:
            inconsistent.append([rid, w, code, word["status"]])
            continue
        truth = code == "missed" or (code == "confirmed" and flagged)
        rows.append(_make_row(report, word, truth, line, False))
    if assume_unlabeled_correct:
        for rid, report in reports.items():
            for word in report["words"]:
                if (rid, word["i"]) not in latest and word["status"] == "correct":
                    rows.append(_make_row(report, word, False, None, True))
    return rows, reports, orphans, inconsistent


# --------------------------------------------------------------------- metrics

def wilson(k, n, z=1.96):
    if n <= 0:
        return [0.0, 1.0]
    p = float(k) / n
    denom = 1.0 + z * z / n
    centre = (p + z * z / (2.0 * n)) / denom
    half = z * math.sqrt(p * (1.0 - p) / n + z * z / (4.0 * n * n)) / denom
    return [max(0.0, centre - half), min(1.0, centre + half)]


def _ratio(a, b):
    return (float(a) / b) if b else None


def confusion(rows, flagged_of=None):
    flagged_of = flagged_of or (lambda r: r["flagged"])
    tp = fp = fn = tn = 0
    for r in rows:
        flagged = flagged_of(r)
        if r["truth"]:
            if flagged:
                tp += 1
            else:
                fn += 1
        elif r["claim"]:
            if flagged:
                fp += 1
            else:
                tn += 1
    return summarize(tp, fp, fn, tn)


def summarize(tp, fp, fn, tn):
    precision = _ratio(tp, tp + fp)
    recall = _ratio(tp, tp + fn)
    f1 = None
    if precision is not None and recall is not None and (precision + recall) > 0:
        f1 = 2 * precision * recall / (precision + recall)
    return {
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
        "precision": precision, "recall": recall, "f1": f1,
        "false_alarm_rate": _ratio(fp, fp + tn),
        "false_alarm_ci": wilson(fp, fp + tn),
        "recall_ci": wilson(tp, tp + fn),
        "correct_words": fp + tn,
        "error_words": tp + fn,
    }


def by_kind(rows):
    """Precision of each kind of flag the app raised."""
    table = {}
    for r in rows:
        if not r["flagged"]:
            continue
        entry = table.setdefault(r["kind"] or "?", {"flagged": 0, "confirmed": 0})
        entry["flagged"] += 1
        if r["truth"]:
            entry["confirmed"] += 1
    for entry in table.values():
        entry["precision"] = _ratio(entry["confirmed"], entry["flagged"])
        entry["precision_ci"] = wilson(entry["confirmed"], entry["flagged"])
    return table


def by_type_recall(rows):
    """Recall per error type the reader named (a word may carry several)."""
    table = {}
    for r in rows:
        if not r["truth"]:
            continue
        for t in (r["types"] or ["untyped"]):
            entry = table.setdefault(t, {"errors": 0, "detected": 0})
            entry["errors"] += 1
            if r["flagged"]:
                entry["detected"] += 1
    for entry in table.values():
        entry["recall"] = _ratio(entry["detected"], entry["errors"])
        entry["recall_ci"] = wilson(entry["detected"], entry["errors"])
    return table


def type_matrix(rows):
    """True class (reader's first type, or none) by predicted class (heuristic)."""
    matrix = {}
    for r in rows:
        if not (r["truth"] or r["flagged"]):
            continue
        true_class = (r["types"][0] if r["types"] else "untyped") if r["truth"] else "none"
        pred_class = r["pred"] if r["flagged"] else "none"
        matrix.setdefault(true_class, {})
        matrix[true_class][pred_class] = matrix[true_class].get(pred_class, 0) + 1
    classes = sorted({c for row in matrix.values() for c in row} | set(matrix))
    per_class = {}
    for c in classes:
        if c == "none":
            continue
        hit = matrix.get(c, {}).get(c, 0)
        predicted = sum(matrix.get(t, {}).get(c, 0) for t in matrix)
        actual = sum(matrix.get(c, {}).values())
        per_class[c] = {"precision": _ratio(hit, predicted), "recall": _ratio(hit, actual),
                        "predicted": predicted, "actual": actual}
    return {"matrix": matrix, "per_class": per_class}


# ------------------------------------------------------- threshold simulation

def frame_flag(row, cfg):
    """Would a judge with `cfg` flag this word from its logged token numbers?"""
    flagged = False
    for t in row["tokens"]:
        if t["kind"] in ("unit", "exempt"):
            continue
        severity = 0
        if t["margin"] <= 0 and t["p_comp"] >= cfg["p_comp_hard"]:
            severity = 2
        elif t["p_ref"] < cfg["p_ref_warn"]:
            severity = 1
        elif t["margin"] < cfg["margin_warn"] and t["p_comp"] >= cfg["p_comp_warn"]:
            severity = 1
        if severity == 1 and t["j"] == row["last_j"]:
            severity = 0
        if severity > 0:
            flagged = True
            break
        ratio = t["ratio"]
        if (ratio > 0 and ratio <= rr.PAUSE_RATIO and row["ayah_runs"] >= cfg["duration_min_runs"]
                and (ratio > cfg["duration_high"] or ratio < cfg["duration_low"])):
            flagged = True
            break
    return flagged


def simulate(rows, cfg):
    return confusion(rows, lambda r: r["text_flagged"] or frame_flag(r, cfg))


def _cfg(**over):
    base = dict(p_ref_warn=0.0, margin_warn=-INF, p_comp_warn=1.0, p_comp_hard=0.5,
                duration_high=INF, duration_low=0.0, duration_min_runs=99)
    base.update(over)
    return base


def sweeps(rows):
    grid = {
        "p_ref_warn": [0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95],
        "margin_warn": [0.0, 0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
        "p_comp_warn": [0.01, 0.02, 0.05, 0.08, 0.12, 0.2, 0.3, 0.5],
        "duration_high": [1.2, 1.3, 1.45, 1.6, 1.8, 2.0, 2.5, 3.0],
        "duration_low": [0.3, 0.4, 0.5, 0.65, 0.8],
    }
    out = {}
    for theta in grid["p_ref_warn"]:
        out.setdefault("p_ref_warn", []).append(_entry(theta, simulate(rows, _cfg(p_ref_warn=theta))))
    for theta in grid["margin_warn"]:
        out.setdefault("margin_warn", []).append(
            _entry(theta, simulate(rows, _cfg(margin_warn=theta, p_comp_warn=0.0))))
    for theta in grid["p_comp_warn"]:
        out.setdefault("p_comp_warn", []).append(
            _entry(theta, simulate(rows, _cfg(margin_warn=INF, p_comp_warn=theta))))
    for theta in grid["duration_high"]:
        out.setdefault("duration_high", []).append(
            _entry(theta, simulate(rows, _cfg(duration_high=theta, duration_min_runs=3))))
    for theta in grid["duration_low"]:
        out.setdefault("duration_low", []).append(
            _entry(theta, simulate(rows, _cfg(duration_low=theta, duration_min_runs=3))))
    return out


def _entry(theta, metrics):
    entry = {"theta": theta}
    entry.update(metrics)
    return entry


def preset_cfg(name):
    p = jr.PRESETS[name]
    return dict(p_ref_warn=p["p_ref_warn"], margin_warn=p["margin_warn"], p_comp_warn=p["p_comp_warn"],
                p_comp_hard=p["p_comp_hard"], duration_high=p["duration_high"],
                duration_low=p["duration_low"], duration_min_runs=p["duration_min_runs"])


def suggest(rows, target_fpr):
    """Grid search of the judge's thresholds: best recall within the false-alarm budget."""
    durations = {
        "off": (INF, 0.0, 99),
        "strict": (1.8, 0.5, 3),
        "maximum": (1.45, 0.65, 2),
    }
    results = []
    for p_ref in (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        for margin in (0.0, 0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 3.5):
            for p_comp_warn in (0.02, 0.05, 0.08, 0.12, 0.2, 0.3):
                for p_comp_hard in (0.2, 0.3, 0.5):
                    for name, (high, low, runs) in durations.items():
                        cfg = dict(p_ref_warn=p_ref, margin_warn=margin, p_comp_warn=p_comp_warn,
                                   p_comp_hard=p_comp_hard, duration_high=high, duration_low=low,
                                   duration_min_runs=runs)
                        metrics = simulate(rows, cfg)
                        results.append({"cfg": cfg, "durations": name, "metrics": metrics})

    def recall(entry):
        return entry["metrics"]["recall"] if entry["metrics"]["recall"] is not None else -1.0

    def fpr(entry):
        value = entry["metrics"]["false_alarm_rate"]
        return value if value is not None else 1.0

    def precision(entry):
        value = entry["metrics"]["precision"]
        return value if value is not None else 0.0

    within = [e for e in results if fpr(e) <= target_fpr]
    within.sort(key=lambda e: (-recall(e), fpr(e), -precision(e)))
    best_f1 = sorted(results, key=lambda e: (-(e["metrics"]["f1"] or 0.0), fpr(e)))[:1]
    return {"target_fpr": target_fpr, "within_budget": within[:5], "best_f1": best_f1, "evaluated": len(results)}


def baselines(rows):
    return {name: {"cfg": preset_cfg(name), "metrics": simulate(rows, preset_cfg(name))}
            for name in ("strict", "balanced", "maximum")}


# ---------------------------------------------------------------------- report

def analyze(text, assume_unlabeled_correct=False, target_fpr=0.02):
    records, label_lines, stats = load_events(text)
    rows, reports, orphans, inconsistent = build_rows(records, label_lines, assume_unlabeled_correct)
    explicit = [r for r in rows if not r["implicit"]]
    judged_words = sum(1 for rep in reports.values() for w in rep["words"] if w["status"] in CLAIM_STATUSES)
    result = {
        "coverage": {
            "ayah_records": len(records), "label_lines": len(label_lines),
            "labelled_words": len(explicit), "implicit_correct_words": len(rows) - len(explicit),
            "judged_words": judged_words,
            "orphan_labels": len(orphans), "inconsistent_labels": len(inconsistent),
            "bad_lines": stats["bad_lines"], "old_v2_records": stats["old_records"],
        },
        "overall": confusion(rows),
        "by_kind": by_kind(rows),
        "by_type_recall": by_type_recall(rows),
        "type_matrix": type_matrix(rows),
        "sweeps": sweeps(rows),
        "baselines": baselines(rows),
        "suggestion": suggest(rows, target_fpr),
        "warnings": [],
    }
    overall = result["overall"]
    if overall["correct_words"] < MIN_CORRECT:
        result["warnings"].append(
            "كلمات صحيحة موسومة %d < %d: نسبة الإنذارات الكاذبة غير مستقرّة." % (overall["correct_words"], MIN_CORRECT))
    if overall["error_words"] < MIN_ERRORS:
        result["warnings"].append(
            "كلمات خاطئة موسومة %d < %d: الإدراك غير مستقرّ." % (overall["error_words"], MIN_ERRORS))
    if not assume_unlabeled_correct and explicit and overall["tn"] == 0:
        result["warnings"].append(
            "لا كلمات صحيحة غير مُنبَّهة موسومة: وسّم الباقي «صحيح» أو استعمل --assume-unlabeled-correct.")
    result["exploratory"] = bool(result["warnings"])
    result["_rows"] = rows
    return result


def _clean(value):
    """Strict JSON: infinities become null."""
    if isinstance(value, float) and (math.isinf(value) or value != value):
        return None
    if isinstance(value, dict):
        return {str(k): _clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_clean(v) for v in value]
    return value


def _pct(value):
    return "—" if value is None else "%.1f%%" % (100.0 * value)


def _ci(ci):
    return "[%.1f%%–%.1f%%]" % (100.0 * ci[0], 100.0 * ci[1])


def render(result):
    out = []
    cov = result["coverage"]
    out.append("== التغطية ==")
    out.append("سجلات الآيات %d | أسطر التسمية %d | كلمات موسومة %d | ضمنيًا «صحيحة» %d | كلمات محكومة %d" % (
        cov["ayah_records"], cov["label_lines"], cov["labelled_words"], cov["implicit_correct_words"],
        cov["judged_words"]))
    if cov["orphan_labels"] or cov["inconsistent_labels"] or cov["bad_lines"] or cov["old_v2_records"]:
        out.append("تنبيه: يتيمة %d، غير متسقة %d، أسطر تالفة %d، سجلات v2 بلا تسميات %d" % (
            cov["orphan_labels"], cov["inconsistent_labels"], cov["bad_lines"], cov["old_v2_records"]))
    o = result["overall"]
    out.append("")
    out.append("== الأداء الكلي (كلمات) ==")
    out.append("TP %d | FP %d | FN %d | TN %d" % (o["tp"], o["fp"], o["fn"], o["tn"]))
    out.append("precision %s | recall %s %s | F1 %s" % (
        _pct(o["precision"]), _pct(o["recall"]), _ci(o["recall_ci"]), _pct(o["f1"])))
    out.append("إنذارات كاذبة لكل كلمة صحيحة: %s %s (من %d كلمة صحيحة)" % (
        _pct(o["false_alarm_rate"]), _ci(o["false_alarm_ci"]), o["correct_words"]))
    out.append("")
    out.append("== دقة كل نوع إنذار (precision) ==")
    for kind, e in sorted(result["by_kind"].items()):
        out.append("%-24s أُنذر %3d | أُكّد %3d | precision %s %s" % (
            kind, e["flagged"], e["confirmed"], _pct(e["precision"]), _ci(e["precision_ci"])))
    out.append("")
    out.append("== إدراك كل نوع خطأ (recall، كما سمّاه القارئ) ==")
    names = dict(rr.ERROR_TYPES)
    for t, e in sorted(result["by_type_recall"].items()):
        out.append("%-14s %-12s أخطاء %3d | رُصد %3d | recall %s %s" % (
            t, names.get(t, ""), e["errors"], e["detected"], _pct(e["recall"]), _ci(e["recall_ci"])))
    out.append("")
    out.append("== مصفوفة الارتباك (الصف: الحقيقة بتسمية القارئ، العمود: تصنيف الإنذار التقديري) ==")
    matrix = result["type_matrix"]["matrix"]
    cols = sorted({c for row in matrix.values() for c in row})
    out.append("%-14s" % "" + "".join("%-10s" % c for c in cols))
    for t in sorted(matrix):
        out.append("%-14s" % t + "".join("%-10d" % matrix[t].get(c, 0) for c in cols))
    for c, e in sorted(result["type_matrix"]["per_class"].items()):
        out.append("  %-12s precision %s | recall %s" % (c, _pct(e["precision"]), _pct(e["recall"])))
    out.append("")
    out.append("== منحنيات العتبة (كل عتبة وحدها؛ الحكم النصي كما سُجّل؛ الاستبدال الصلب ثابت عند p_comp ≥ 0.50) ==")
    for name, entries in result["sweeps"].items():
        out.append("-- %s" % name)
        out.append("   theta   TP  FP  FN  TN  precision  recall  FPR")
        for e in entries:
            out.append("   %-6s %3d %3d %3d %3d  %8s %7s %6s" % (
                e["theta"], e["tp"], e["fp"], e["fn"], e["tn"], _pct(e["precision"]), _pct(e["recall"]),
                _pct(e["false_alarm_rate"])))
    out.append("")
    out.append("== الإعدادات الجاهزة على هذه البيانات ==")
    for name, e in result["baselines"].items():
        m = e["metrics"]
        out.append("%-9s precision %s | recall %s | FPR %s %s" % (
            name, _pct(m["precision"]), _pct(m["recall"]), _pct(m["false_alarm_rate"]), _ci(m["false_alarm_ci"])))
    sug = result["suggestion"]
    out.append("")
    out.append("== اقتراح العتبات (هدف الإنذارات الكاذبة ≤ %s، قُيِّم %d إعدادًا) ==" % (
        _pct(sug["target_fpr"]), sug["evaluated"]))
    if not sug["within_budget"]:
        out.append("لا إعداد ضمن الميزانية على هذه البيانات.")
    for e in sug["within_budget"]:
        c, m = e["cfg"], e["metrics"]
        out.append("p_ref<%.2f هامش<%.2f p_comp≥%.2f صلب≥%.2f مدّ:%s | recall %s | FPR %s %s | precision %s" % (
            c["p_ref_warn"], c["margin_warn"], c["p_comp_warn"], c["p_comp_hard"], e["durations"],
            _pct(m["recall"]), _pct(m["false_alarm_rate"]), _ci(m["false_alarm_ci"]), _pct(m["precision"])))
    if result["warnings"]:
        out.append("")
        out.append("== تحذيرات (النتائج استكشافية) ==")
        out.extend(result["warnings"])
    out.append("")
    out.append("المحاكاة تقرأ p_ref/p_comp/الهامش/نسبة المد المسجَّلة ولا تحاكي حارس التعليق (40٪)؛ "
               "ولا تقيس إلا ما رآه الحَكَم الإطاري، أما أخطاء النموذج الأعمى فتحتاج LLR أو ضبطًا دقيقًا (المهمة B).")
    return "\n".join(out)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", help="evidence JSONL or rafiq-report/3 JSON export")
    parser.add_argument("--assume-unlabeled-correct", action="store_true",
                        help="count unlabelled words shown as correct as truly correct")
    parser.add_argument("--target-fpr", type=float, default=0.02)
    parser.add_argument("--json", help="write the full result as JSON")
    args = parser.parse_args(argv)
    with open(args.path, encoding="utf-8") as handle:
        text = handle.read()
    result = analyze(text, args.assume_unlabeled_correct, args.target_fpr)
    print(render(result))
    if args.json:
        result.pop("_rows", None)
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(_clean(result), handle, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
