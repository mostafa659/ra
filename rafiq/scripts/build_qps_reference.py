#!/usr/bin/env python3
"""Offline QPS reference for all 6,236 ayahs (no regex ports to Dart).

Uses the MIT `quran-transcript` phonetizer. Output: assets/qps_reference.json.gz

Per ayah: words[] each with
  uthmani   : the uthmani word
  wasl      : QPS of the word as read in continuous recitation (madd at the *short* legal setting)
  wasl_max  : same with every free madd at the *long* legal setting
  waqf      : the word phonetized alone (stop on it: final harakah->sukun, tanween, ta marbuta -> ha, madd aared/leen)
  begin     : the word phonetized alone when it starts a reading (hamzat-wasl start)
  deleted   : true when the phonetizer elides the whole word (never judged)
Variable spans are encoded by comparing wasl vs wasl_max (min/max repetition of madd symbols)
via `intervals` : list of [start_in_wasl, min_run, max_run] for runs whose length differs.

Honest limits: `waqf`/`begin` are produced by phonetizing the word in isolation, which is the library's
own stop/start behaviour; cross-word rules inside `wasl` come from the whole-ayah run.
Usage: build_qps_reference.py [--out assets/qps_reference.json.gz] [--limit N]
"""
import argparse, gzip, json, re, sys
from quran_transcript import Aya, MoshafAttributes, quran_phonetizer

def surah_ayat() -> list:
    """Ayah counts read from the phonetizer library's own Quran data (never typed from memory)."""
    import os, quran_transcript
    p = os.path.join(os.path.dirname(quran_transcript.__file__), "quran-script", "quran-uthmani-imlaey.json")
    suras = json.load(open(p, encoding="utf-8"))["quran"]["sura"]
    counts = [len(x["aya"]) for x in suras]
    assert len(counts) == 114 and sum(counts) == 6236, (len(counts), sum(counts))
    return counts


SURAH_AYAT = surah_ayat()


def moshaf(madd: int, munf: int, aared: int) -> MoshafAttributes:
    return MoshafAttributes(rewaya="hafs", madd_monfasel_len=munf, madd_mottasel_len=madd,
                            madd_mottasel_waqf=madd, madd_aared_len=aared)


MIN = moshaf(4, 2, 2)
MAX = moshaf(6, 5, 6)  # library-legal maxima: mottasel 6, munfasil 5, aared 6


def word_slices(text: str, o) -> list:
    """Phoneme string per uthmani word, from the char->phoneme mapping."""
    words, cur_start, out = text.split(" "), 0, []
    pos = 0
    for w in words:
        a, b = pos, pos + len(w)
        ps = [m.pos for m in o.mappings[a:b]]
        lo = min((p[0] for p in ps), default=0)
        hi = max((p[1] for p in ps), default=0)
        out.append(o.phonemes[lo:hi].strip())
        pos = b + 1
    return out


def runs(s: str):
    return [(m.start(), m.group(0)) for m in re.finditer(r"(.)\1*", s)]


def intervals(lo: str, hi: str):
    """Aligned run-length differences between the short and long variants (same symbol sequence)."""
    a, b = runs(lo), runs(hi)
    if [c[1][0] for c in a] != [c[1][0] for c in b]:
        return None  # structure differs: caller keeps both strings, no interval claim
    return [[p, len(r), len(r2)] for (p, r), (_, r2) in zip(a, b) if len(r) != len(r2)]


def ayah_entry(s: int, a: int) -> dict:
    text = Aya(s, a).get().uthmani
    lo = quran_phonetizer(text, MIN, remove_spaces=False)
    hi = quran_phonetizer(text, MAX, remove_spaces=False)
    wl, wh = word_slices(text, lo), word_slices(text, hi)
    words = []
    for i, w in enumerate(text.split(" ")):
        alone = quran_phonetizer(w, MIN, remove_spaces=False).phonemes.strip()
        iv = intervals(wl[i], wh[i])
        words.append({"uthmani": w, "wasl": wl[i], "wasl_max": wh[i] if iv is None or iv else None,
                      "intervals": iv, "waqf": alone, "begin": alone, "deleted": wl[i] == ""})
    return {"s": s, "a": a, "text": text, "qps": lo.phonemes, "words": words}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="assets/qps_reference.json.gz")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    out, fails, n = [], [], 0
    for s, cnt in enumerate(SURAH_AYAT, 1):
        for a in range(1, cnt + 1):
            try:
                out.append(ayah_entry(s, a))
            except Exception as e:  # report, never hide
                fails.append(f"{s}:{a} {type(e).__name__}: {e}")
            n += 1
            if args.limit and n >= args.limit:
                break
        if args.limit and n >= args.limit:
            break
    with gzip.open(args.out, "wt", encoding="utf-8") as f:
        json.dump({"version": 1, "generator": "quran-transcript (MIT)", "ayat": out}, f, ensure_ascii=False,
                  separators=(",", ":"))
    print(f"ayahs={len(out)} failures={len(fails)}")
    for x in fails[:20]:
        print("FAIL", x)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
