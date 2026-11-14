"""Reference for lib/core/audio_engine/lexicon_alignment.dart.

The model's lexicon sometimes has a different number of words than the Uthmani text (it merges a
proclitic into the next word, or splits one). The old mapping gave each lexicon word to the text word
it overlapped most, by length, and a short text word between two long ones could receive nothing:
its reference came out empty and the evaluator showed it as "inconclusive" whatever was recited.

This mapping cuts the ayah's whole phoneme-unit sequence into exactly one non-empty piece per text
word, in order, with cut points as close as possible to the text words' proportional edges and, when
nearly equal, on a lexicon word boundary. A unit is a base letter with the marks that follow it.
"""

BOUNDARY_PENALTY = 0.0004  # about a 2 % shift in position


def _is_mark(ch):
    c = ord(ch)
    return 0x064B <= c <= 0x065F or c == 0x0670 or 0x06D6 <= c <= 0x06ED


def split_units(text):
    units = []
    for ch in text:
        if _is_mark(ch) and units:
            units[-1] += ch
        else:
            units.append(ch)
    return units


def align(lex_words, text_lengths):
    """lex_words: the lexicon's phoneme words. text_lengths: a weight per text word (>= 1).
    Returns one string per text word, or None when there are fewer units than text words."""
    n = len(text_lengths)
    units, boundary = [], set()
    for word in lex_words:
        units.extend(split_units(word))
        boundary.add(len(units))
    total = len(units)
    if n == 0 or total < n:
        return None
    if n == 1:
        return ["".join(units)]
    weight = float(sum(text_lengths))
    edges, run = [], 0
    for length in text_lengths[:-1]:
        run += length
        edges.append(run / weight)
    inf = float("inf")
    # best[i][c]: least cost with cut i (0-based) placed after c units
    best = [[inf] * (total + 1) for _ in range(n - 1)]
    back = [[0] * (total + 1) for _ in range(n - 1)]
    for i in range(n - 1):
        running, running_at = inf, 0
        for c in range(1, total):
            if i == 0:
                prior, prior_at = 0.0, 0
            else:
                # prefix minimum over earlier cut positions c' < c
                candidate = best[i - 1][c - 1]
                if candidate < running:
                    running, running_at = candidate, c - 1
                prior, prior_at = running, running_at
            if prior == inf:
                continue
            d = c / total - edges[i]
            cost = d * d + (0.0 if c in boundary else BOUNDARY_PENALTY)
            best[i][c] = prior + cost
            back[i][c] = prior_at
    last_cut, last_cost = -1, inf
    for c in range(1, total):
        if best[n - 2][c] < last_cost:
            last_cut, last_cost = c, best[n - 2][c]
    if last_cut < 0:
        return None
    cuts = [0] * (n - 1)
    cuts[n - 2] = last_cut
    for i in range(n - 2, 0, -1):
        cuts[i - 1] = back[i][cuts[i]]
    bounds = [0] + cuts + [total]
    return ["".join(units[bounds[k]:bounds[k + 1]]) for k in range(n)]


def old_align(lex_words, text_lengths):
    """The mapping this replaces (kept to show the empty-reference bug in tests)."""
    def edges(lengths):
        lengths = [max(1, v) for v in lengths]
        total, run, out = sum(lengths), 0, [0.0]
        for v in lengths:
            run += v
            out.append(run / total)
        return out
    text_edges = edges(text_lengths)
    lex_edges = edges([len(w) for w in lex_words])
    buffers = ["" for _ in text_lengths]
    for k, word in enumerate(lex_words):
        frm, to = lex_edges[k], lex_edges[k + 1]
        best_word, best_overlap = 0, -1.0
        for i in range(len(text_lengths)):
            overlap = min(to, text_edges[i + 1]) - max(frm, text_edges[i])
            if overlap > best_overlap:
                best_overlap, best_word = overlap, i
        buffers[best_word] += word
    return buffers
