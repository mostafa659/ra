"""Builds consistent schema-v3 evidence records for the report tests and fixtures.

Not a test module (no test_ prefix): imported by test_report_ref.py,
test_label_analysis.py and tools/frame_engine/gen_report_fixtures.py.
"""
import math

FRAME_MS = 40


def tok(label, start, end, severity=0, kind="ok", p_ref=0.97, p_comp=0.01, comp="", margin=None, ratio=0.0):
    """One judged reference token as the frame judge logs it (times in ms)."""
    if margin is None:
        margin = round(math.log(p_ref / p_comp), 4) if p_comp > 0 else 99.0
    return {"label": label, "start": start, "end": end, "severity": severity, "kind": kind,
            "p_ref": p_ref, "p_comp": p_comp, "comp": comp, "margin": margin, "ratio": ratio}


def word(text, ph, status="correct", tv="correct", tm=None, tr=None, hist=None, fa="none", tokens=None, adv=True):
    """tokens=None means the frame judge never saw the word (rejected, pending, approximate)."""
    return {"text": text, "ph": ph, "st": status, "tv": tv, "tm": tm, "tr": tr, "adv": adv,
            "hist": list(hist) if hist is not None else ([tv] if tv else []), "fa": fa, "tokens": tokens}


def make_record(rid="112-1-1", surah=112, ayah=1, words=(), heard=(), window=(0, 4000),
                frames_status="ok", guard=None, sensitivity="balanced", reference="lexicon",
                at="2026-11-02T10:00:00Z", audio=None):
    rows, word_map, flags = [], [], []
    log = []
    j = 0
    for i, w in enumerate(words):
        log.append({"i": i, "text": w["text"], "ph": w["ph"], "tv": w["tv"], "tm": w["tm"], "tr": w["tr"],
                    "adv": w["adv"], "n": len(w["hist"]), "hist": w["hist"], "st": w["st"], "fa": w["fa"]})
        if w["tokens"] is not None and frames_status == "ok":
            reduced = len(word_map)
            word_map.append(i)
            flags.append(0)
            for t in w["tokens"]:
                rows.append([j, reduced, t["label"], t["start"], t["end"], t["severity"], t["kind"],
                             t["p_ref"], t["p_comp"], t["comp"], t["margin"], t["ratio"]])
                j += 1
    record = {
        "v": 3, "rid": rid, "app": "0.6.3", "at": at, "surah": surah, "ayah": ayah, "complete": True,
        "strictness": "strict", "sensitivity": sensitivity, "reference": reference, "backend": "test",
        "carry": 0,
        "expected": [w["ph"] for w in words],
        "heard": " ".join(label for label, _ in heard),
        "tokens": [label for label, _ in heard],
        "times": ["%.2f" % (ms / 1000.0) for _, ms in heard],
        "verdicts": {str(entry["i"]): (entry["tv"] or "") for entry in log if entry["tv"]},
        "words": log,
        "alignment": "",
        "perf": {"steps": 5, "stepMsMean": 120, "stepMsMax": 180, "realTimeFactor": 0.25},
        "frames": {
            "status": frames_status,
            "startFrame": window[0] // FRAME_MS,
            "endFrame": window[1] // FRAME_MS,
            "tokens": rows,
            "words": [],
            "wordMap": word_map,
            "flags": flags,
            "cfg": {"pRefWarn": 0.3, "marginWarn": 0.5, "pCompWarn": 0.2, "pCompHard": 0.5,
                    "durationHigh": None, "durationLow": 0.0, "durationMinRuns": 99},
            "guard": guard or {"flagged": 0, "total": len(word_map), "limit": 40, "suppressed": False, "applied": 0},
        },
    }
    if audio:
        record["audio"] = audio
    return record


def label(word_index, code, types=(), note="", rid="112-1-1", surah=112, ayah=1, shown="correct",
          at="2026-11-02T10:05:00Z"):
    return {"v": 3, "kind": "label", "at": at, "rid": rid, "surah": surah, "ayah": ayah, "word": word_index,
            "label": code, "types": list(types), "note": note, "shown": shown}


def scenarios():
    """[(name, record, labels {word: label dict})] shared with the Dart golden test."""
    out = []

    # 1. clean recitation: nothing to report
    words = [
        word("قُلْ", "قل", tokens=[tok("ق", 400, 440), tok("ل", 480, 520)]),
        word("هُوَ", "هو", tokens=[tok("ه", 800, 840), tok("و", 880, 920)]),
        word("ٱللَّهُ", "الله", tokens=[tok("ا", 1200, 1240), tok("ل", 1280, 1320), tok("ه", 1360, 1400)]),
    ]
    heard = [("ق", 400), ("ل", 480), ("ه", 800), ("و", 880), ("ا", 1200), ("ل", 1280), ("ه", 1360)]
    out.append(("clean_ayah", make_record("112-1-100", words=words, heard=heard, window=(320, 1600)), {}))

    # 2. frame judge flags a substitution the greedy text agreed with
    words = [
        word("صَلَّى", "صلى", tokens=[tok("ص", 400, 440, 2, "substitution", 0.35, 0.60, "س", -0.5390),
                                       tok("ل", 480, 520)], status="incorrect", fa="applied"),
        word("ٱللَّهُ", "الله", tokens=[tok("ا", 1200, 1240), tok("ل", 1280, 1320)]),
    ]
    heard = [("س", 400), ("ل", 480), ("ا", 1200), ("ل", 1280)]
    out.append(("substitution_applied", make_record("112-2-100", ayah=2, words=words, heard=heard,
                                                    window=(320, 1600)), {}))

    # 3. text evaluator rejected the middle word: heard sounds land in the gap; last word never read
    words = [
        word("قُلْ", "قل", tokens=[tok("ق", 400, 440), tok("ل", 480, 520)]),
        word("هُوَ", "هو", status="incorrect", tv="incorrect", tm="المسموع هـ بدل هو",
             hist=["tajweedWarning", "incorrect"], tokens=None),
        word("ٱللَّهُ", "الله", tokens=[tok("ا", 1400, 1440), tok("ل", 1480, 1520)]),
        word("أَحَدٌ", "احد", status="pending", tv=None, tokens=None),
    ]
    heard = [("ق", 400), ("ل", 480), ("ه", 800), ("ا", 1400), ("ل", 1480)]
    out.append(("text_rejected_gap", make_record("112-3-100", ayah=3, words=words, heard=heard,
                                                  window=(320, 2000)), {}))

    # 4. two consecutive rejected words share one gap
    words = [
        word("قُلْ", "قل", tokens=[tok("ق", 400, 440)]),
        word("هُوَ", "هو", status="incorrect", tv="incorrect", tm="كلمة مختلفة", tokens=None),
        word("ٱللَّهُ", "الله", status="incorrect", tv="incorrect", tm="كلمة ناقصة", tokens=None),
        word("أَحَدٌ", "احد", tokens=[tok("ا", 1600, 1640), tok("ح", 1680, 1720)]),
    ]
    heard = [("ق", 400), ("ه", 800), ("ل", 1000), ("ا", 1600), ("ح", 1680)]
    out.append(("shared_gap", make_record("112-4-100", ayah=4, words=words, heard=heard,
                                          window=(320, 2000)), {}))

    # 5. the calibration guard held back three flags: they head the watch list, strongest doubt first
    words = []
    heard = []
    for k in range(5):
        start = 400 + k * 400
        if k in (0, 2, 4):
            t = tok("ب", start, start + 40, 1, "weak", 0.45 - 0.05 * k, 0.40, "ت")
            words.append(word("w%d" % k, "ب", tokens=[t], fa="guard_suppressed"))
        elif k == 1:
            words.append(word("w%d" % k, "ب", tokens=[tok("ب", start, start + 40, 0, "ok", 0.50, 0.05, "ت")]))
        else:
            words.append(word("w%d" % k, "ب", tokens=[tok("ب", start, start + 40)]))
        heard.append(("ب", start))
    guard = {"flagged": 3, "total": 5, "limit": 40, "suppressed": True, "applied": 0}
    out.append(("guard_suppressed", make_record("112-5-100", ayah=5, words=words, heard=heard,
                                                window=(320, 2600), guard=guard), {}))

    # 6. correct words with weak, close and mistimed evidence; ignored kinds stay out of the list
    words = [
        word("a", "ab", tokens=[tok("ا", 400, 440, 0, "ok", 0.52, 0.05, "ع"), tok("ب", 480, 520)]),
        word("b", "ab", tokens=[tok("ا", 800, 840, 0, "ok", 0.85, 0.20, "ع", 1.4469), tok("ب", 880, 920)]),
        word("c", "ab", tokens=[tok("ا", 1200, 1240, 0, "ok", 0.97, 0.01, "", None, 2.1), tok("ا", 1280, 1320, 0, "unit"),
                                tok("ب", 1360, 1400)]),
        word("d", "ab", tokens=[tok("ء", 1600, 1640, 0, "exempt", 0.20, 0.30, "ع"),
                                tok("ل", 1640, 1680, 0, "exempt", 0.20, 0.30, "ع"),
                                tok("ا", 1680, 1720, 0, "ok"),
                                tok("ا", 1760, 1800, 0, "unit", 0.10, 0.50, "ع"),
                                tok("ب", 1840, 1880, 0, "edge", 0.30, 0.10, "ت")]),
        word("e", "ab", tokens=[tok("ا", 2000, 2040), tok("ب", 2080, 2120)]),
    ]
    heard = [("ا", 400), ("ب", 480), ("ا", 800), ("ب", 880), ("ا", 1200), ("ا", 1280), ("ب", 1360),
             ("ا", 1680), ("ا", 1760), ("ب", 1840), ("ا", 2000), ("ب", 2080)]
    out.append(("watch_items", make_record("112-6-100", ayah=6, words=words, heard=heard,
                                           window=(320, 2400)), {}))

    # 7. approximate reference: no frame judgement, nothing can be called correct
    words = [word("w%d" % k, "x", status="uncertain", tv="uncertain",
                  tm="مرجع تقريبي: لا حكم قاطع", tokens=None) for k in range(2)]
    out.append(("approximate_reference", make_record("112-7-100", ayah=7, words=words, heard=[("x", 400)],
                                                      frames_status="مرجع تقريبي: لا تحليل إطاري",
                                                      reference="approximate"), {}))

    # 8. a missing sound in one word, an extra sound in another (each diff has one minimal alignment)
    words = [
        word("كلمة", "كلمة", tokens=[tok("ك", 400, 440), tok("ل", 480, 520), tok("م", 560, 600),
                                      tok("ة", 640, 680)]),
        word("كلمة", "كلمة", tokens=[tok("ك", 1000, 1040), tok("ل", 1080, 1120), tok("م", 1160, 1200),
                                      tok("ة", 1240, 1280)]),
    ]
    heard = [("ك", 400), ("م", 560), ("ة", 640), ("ك", 1000), ("ل", 1080), ("ن", 1120), ("م", 1160), ("ة", 1240)]
    out.append(("missing_and_extra", make_record("112-8-100", ayah=8, words=words, heard=heard,
                                                  window=(320, 1600)), {}))

    # 9. slack, a sound nobody owns (41 ms past a span), and sounds outside the window
    words = [
        word("a", "اب", tokens=[tok("ا", 400, 440), tok("ب", 480, 520)]),
        word("b", "اب", tokens=[tok("ا", 700, 740), tok("ب", 760, 800)]),
    ]
    heard = [("ب", 100), ("ا", 400), ("ب", 480), ("ن", 530), ("ا", 560), ("ا", 700), ("ب", 760),
             ("ن", 830), ("م", 900)]
    out.append(("slack_and_unattributed", make_record("112-9-100", ayah=9, words=words, heard=heard,
                                                      window=(320, 840)), {}))

    # 10. labels merged into the words and into the summary text
    words = [
        word("صَلَّى", "صلى", status="incorrect", fa="applied",
             tokens=[tok("ص", 400, 440, 2, "substitution", 0.35, 0.60, "س", -0.5390), tok("ل", 480, 520)]),
        word("ٱللَّهُ", "الله", tokens=[tok("ا", 1200, 1240), tok("ل", 1280, 1320)]),
    ]
    heard = [("س", 400), ("ل", 480), ("ا", 1200), ("ل", 1280)]
    labels = {
        0: label(0, "confirmed", ["tafkheem"], "ص مكان س", rid="112-10-100", ayah=10, shown="incorrect"),
        1: label(1, "confirmed", [], "", rid="112-10-100", ayah=10, shown="correct"),
    }
    out.append(("labels_merged", make_record("112-10-100", ayah=10, words=words, heard=heard,
                                             window=(320, 1600)), labels))
    return out
