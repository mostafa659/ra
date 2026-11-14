"""Reference model of the strict phoneme evaluator (mirrors the Dart implementation).

Everything operates on code points of the model's phonetic alphabet. Runs of the
same character encode duration (madd counts, gemination, ghunna), so alignment is
done over (code, length) runs, which makes length errors visible and cheap to
classify while substitutions / deletions / insertions stay fully strict.
"""
import math, re

# ---- character classes -------------------------------------------------
K_CONS, K_MARK, K_MADD, K_NASAL = 0, 1, 2, 3
HARAKA_NAMES = {0x064E: 'فتحة', 0x064F: 'ضمّة', 0x0650: 'كسرة'}
MADD_LETTERS = {0x0627, 0x06E5, 0x06E6, 0x0649}
NASAL = 0x06BA
HAMZA = 0x0621


def kind_of(c):
    if 0x064B <= c <= 0x0652 or c == 0x0670:
        return K_MARK
    if c in MADD_LETTERS:
        return K_MADD
    if c == NASAL:
        return K_NASAL
    return K_CONS


_STRIP = re.compile(r'[\s\u200B-\u200F\u202A-\u202E\u0640\u2581\ufeff]')


def normalize(text):
    return _STRIP.sub('', text)


class Run:
    __slots__ = ('code', 'length', 'word', 'start', 't0', 't1')

    def __init__(self, code, length, word=-1, start=0, t0=None, t1=None):
        self.code, self.length, self.word, self.start = code, length, word, start
        self.t0, self.t1 = t0, t1

    @property
    def end(self):
        return self.start + self.length

    def __repr__(self):
        return f"{chr(self.code)}x{self.length}"


def expected_runs(words_phonemes):
    """words_phonemes: list[str]. Returns (runs, spans) where spans[w]=(rs,re)."""
    runs, spans, pos = [], [], 0
    for w, ph in enumerate(words_phonemes):
        s = normalize(ph)
        rs = len(runs)
        i = 0
        while i < len(s):
            j = i
            while j < len(s) and s[j] == s[i]:
                j += 1
            runs.append(Run(ord(s[i]), j - i, word=w, start=pos + i))
            i = j
        pos += len(s)
        spans.append((rs, len(runs)))
    return runs, spans


def heard_runs(chars, times=None, base=0):
    """chars: normalized string, times: per-char seconds or None. Index `base` is
    the offset of chars[0] in the global hypothesis (for consumed bookkeeping)."""
    runs = []
    i = 0
    while i < len(chars):
        j = i
        while j < len(chars) and chars[j] == chars[i]:
            j += 1
        t0 = times[i] if times else None
        t1 = times[j - 1] if times else None
        runs.append(Run(ord(chars[i]), j - i, start=base + i, t0=t0, t1=t1))
        i = j
    return runs


# ---- alignment -----------------------------------------------------------
M, L, S, D, I = 'M', 'L', 'S', 'D', 'I'
INDEL_COST = 0.8
SUB_COST = 1.0
CROSS_COST = 1.8


def sub_cost(e, h):
    if e.code == h.code:
        if e.length == h.length:
            return 0.0
        d = abs(e.length - h.length)
        return min(0.9, 0.3 + 0.1 * (d - 1))
    if kind_of(e.code) == kind_of(h.code):
        return SUB_COST
    return CROSS_COST


def align(E, H, forced_end=None):
    """Semi-global: all of H consumed, E prefix free. Returns (ops, istar, cost).
    ops: list of (op, ei, hi)."""
    n, m = len(E), len(H)
    INF = 1e18
    D_ = [[INF] * (m + 1) for _ in range(n + 1)]
    P = [[None] * (m + 1) for _ in range(n + 1)]
    D_[0][0] = 0.0
    for i in range(n + 1):
        for j in range(m + 1):
            if i == 0 and j == 0:
                continue
            best, bp = INF, None
            if i > 0 and j > 0:
                c = D_[i - 1][j - 1] + sub_cost(E[i - 1], H[j - 1])
                if c < best - 1e-9:
                    best, bp = c, 'd'
            if i > 0:
                c = D_[i - 1][j] + INDEL_COST
                if c < best - 1e-9:
                    best, bp = c, 'u'      # deletion of E run
            if j > 0:
                c = D_[i][j - 1] + INDEL_COST
                if c < best - 1e-9:
                    best, bp = c, 'l'      # insertion of H run
            D_[i][j], P[i][j] = best, bp
    # free end in E: smallest cost, ties -> larger i
    if forced_end is not None:
        istar, bc = forced_end, D_[forced_end][m]
    else:
        istar, bc = 0, D_[0][m]
        for i in range(1, n + 1):
            if D_[i][m] <= bc + 1e-9:
                istar, bc = i, D_[i][m]
    ops = []
    i, j = istar, m
    while i > 0 or j > 0:
        p = P[i][j]
        if p == 'd':
            e, h = E[i - 1], H[j - 1]
            if e.code == h.code:
                ops.append((M if e.length == h.length else L, i - 1, j - 1))
            else:
                ops.append((S, i - 1, j - 1))
            i, j = i - 1, j - 1
        elif p == 'u':
            ops.append((D, i - 1, -1)); i -= 1
        else:
            ops.append((I, -1, j - 1)); j -= 1
    ops.reverse()
    return ops, istar, bc


# ---- word-level judgement -------------------------------------------------
PAUSE_GAP_SEC = 0.5
ANCHOR_RUNS = 2
HARD, SOFT = 'hard', 'soft'
SOFTENABLE = {'haraka_sub', 'mark_del', 'mark_ins', 'letter_ins'}


class Finding:
    def __init__(self, hard, kind, expected, heard, message, rule=None):
        self.hard, self.kind, self.expected, self.heard = hard, kind, expected, heard
        self.message, self.rule = message, rule

    def __repr__(self):
        return f"<{'H' if self.hard else 's'}:{self.kind} e={self.expected!r} h={self.heard!r} r={self.rule}>"


class WordT:
    def __init__(self, index, text, phonemes, rules=()):
        self.index, self.text, self.phonemes, self.rules = index, text, phonemes, tuple(rules)


class WordEval:
    def __init__(self, word, verdict, advanced, rule=None, message=None, findings=()):
        self.word, self.verdict, self.advanced = word, verdict, advanced
        self.rule, self.message, self.findings = rule, message, list(findings)

    def __repr__(self):
        return f"WordEval(w={self.word}, {self.verdict}, adv={self.advanced}, rule={self.rule}, msg={self.message!r})"


def glyph(c):
    return chr(c)


def run_str(r):
    return chr(r.code) * r.length


def allowed_madd_range(le, rules):
    has = lambda r: r in rules
    if le <= 2:
        return (2, 2)
    if le >= 6:
        return (2, 8) if has('madd_arid') else (5, 8)
    if has('madd_munfasil') or has('madd_arid'):
        return (2, 6)
    if has('madd_muttasil'):
        return (4, 6)
    return (max(2, le - 1), le + 1)


def madd_rule(le, rules):
    if le >= 6 and 'madd_lazim' in rules:
        return 'madd_lazim'
    for r in ('madd_muttasil', 'madd_munfasil', 'madd_arid', 'madd_lazim'):
        if le > 2 and r in rules:
            return r
    return 'madd_tabii'


def classify_length(e, h, rules):
    """e,h: Runs with the same code, different length. Returns Finding or None."""
    k = kind_of(e.code)
    le, lh = e.length, h.length
    g = glyph(e.code)
    if k == K_MADD:
        lo, hi = allowed_madd_range(le, rules)
        if lo <= lh <= hi:
            return None
        rule = madd_rule(le, rules)
        if lh < lo:
            msg = f'قصّرتَ المدّ: سمعتُ {lh} حركات والمطلوب {le}'
        else:
            msg = f'زدتَ في المدّ: سمعتُ {lh} حركات والمطلوب {le}'
        return Finding(False, 'madd_length', run_str(e), run_str(h), msg, rule)
    if k == K_NASAL:
        if abs(le - lh) <= 1:
            return None
        return Finding(False, 'ikhfa_length', run_str(e), run_str(h),
                       'الإخفاء: أخفِ النون مع غنّة بمقدارها', 'ikhfa')
    if k == K_CONS:
        if le >= 2 and lh == 1:
            return Finding(True, 'shadda_lost', run_str(e), run_str(h),
                           f'الشدّة: لم تُشدِّد الحرف «{g}»')
        if le == 1 and lh >= 2:
            return Finding(True, 'shadda_extra', run_str(e), run_str(h),
                           f'شدّة زائدة على الحرف «{g}»')
        if e.code in (0x0646, 0x0645) and abs(le - lh) >= 2:
            return Finding(False, 'ghunna_length', run_str(e), run_str(h),
                           'الغنّة: التزم مقدار حركتين', 'ghunna')
        return None
    return None


def classify_op(op, e, h, rules):
    if op == S:
        ke, kh = kind_of(e.code), kind_of(h.code)
        if ke == K_MARK and kh == K_MARK:
            ne = HARAKA_NAMES.get(e.code, 'علامة'); nh = HARAKA_NAMES.get(h.code, 'علامة')
            return Finding(True, 'haraka_sub', glyph(e.code), glyph(h.code),
                           f'الحركة: نطقتَ {nh} والصواب {ne}')
        if ke == K_MADD and kh == K_MADD:
            return Finding(True, 'madd_letter_sub', run_str(e), run_str(h),
                           f'حرف المدّ: نطقتَ «{glyph(h.code)}» بدل «{glyph(e.code)}»')
        return Finding(True, 'letter_sub', run_str(e), run_str(h),
                       f'نطقتَ «{glyph(h.code)}» بدل «{glyph(e.code)}»')
    if op == D:
        k = kind_of(e.code)
        if k == K_MARK:
            nm = HARAKA_NAMES.get(e.code)
            return Finding(True, 'mark_del', run_str(e), '', f'سقطت {nm}' if nm else 'سقطت علامة من الكلمة')
        if k == K_MADD:
            return Finding(True, 'madd_del', run_str(e), '', f'سقط حرف المدّ «{glyph(e.code)}»')
        return Finding(True, 'letter_del', run_str(e), '', f'سقط الحرف «{glyph(e.code)}»')
    if op == I:
        k = kind_of(h.code)
        if k == K_MARK:
            nm = HARAKA_NAMES.get(h.code)
            return Finding(True, 'mark_ins', '', run_str(h), f'زدتَ {nm}' if nm else 'زدتَ علامة زائدة')
        if k == K_MADD:
            return Finding(False, 'madd_ins', '', run_str(h), 'مدّ زائد في غير موضعه', 'madd_tabii')
        return Finding(True, 'letter_ins', '', run_str(h), f'زدتَ الحرف «{glyph(h.code)}»')
    if op == L:
        return classify_length(e, h, rules)
    return None


def _run_distance(a, b):
    """Levenshtein over runs (equal code and length)."""
    n, m = len(a), len(b)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            same = a[i - 1].code == b[j - 1].code and a[i - 1].length == b[j - 1].length
            cur[j] = min(prev[j - 1] + (0 if same else 1), prev[j] + 1, cur[j - 1] + 1)
        prev = cur
    return prev[m]


class StrictEvaluator:
    def __init__(self, words, mode='recite', strict=True, strictness='strict'):
        self.words, self.mode, self.strict, self.strictness = words, mode, strict, strictness
        self.cursor = 0
        self.consumed = 0
        self._last_key = None
        self.failed = False
        self.report = ''
        self._E = None  # cache (cursor, runs, spans)

    # --- state -------------------------------------------------------
    @property
    def is_complete(self):
        return self.cursor >= len(self.words)

    def reset_segment(self):
        self.consumed = 0
        self._last_key = None
        self.failed = False

    def set_consumed(self, v):
        self.consumed = max(0, v)
        self._last_key = None

    # --- helpers -----------------------------------------------------
    def _expected(self):
        if self._E is None or self._E[0] != self.cursor:
            subset = self.words[self.cursor:]
            runs, spans = expected_runs([w.phonemes for w in subset])
            for r in runs:
                r.word += self.cursor
            self._E = (self.cursor, runs, [(a, b) for a, b in spans])
        return self._E[1], self._E[2]

    @staticmethod
    def _hyp(text, tokens, times):
        if tokens:
            chars, tms = [], []
            for i, tok in enumerate(tokens):
                n = normalize(tok)
                t = times[i] if times and i < len(times) else None
                for ch in n:
                    chars.append(ch)
                    tms.append(t)
            ts = tms if all(t is not None for t in tms) and tms else None
            return ''.join(chars), ts
        return normalize(text), None

    # --- main --------------------------------------------------------
    def update(self, text, tokens=None, times=None, stable=False, final=False):
        chars, tms = self._hyp(text, tokens, times)
        key = (chars, stable, final, self.cursor, self.consumed, self.failed)
        if key == self._last_key:
            return []
        self._last_key = key
        if self.consumed > len(chars):
            self.consumed = 0
        events = []
        guard = 0
        while not self.is_complete and guard < 64:
            guard += 1
            produced = self._step(chars, tms, stable, final, events)
            if not produced:
                break
        self._last_key = (chars, stable, final, self.cursor, self.consumed, self.failed)
        return events

    def finish(self, text, tokens=None, times=None):
        return self.update(text, tokens, times, stable=True, final=True)

    def _step(self, chars, tms, stable, final, events):
        word = self.words[self.cursor]
        E, spans = self._expected()
        rs, re_ = spans[0]
        if rs == re_:
            events.append(WordEval(word.index, 'uncertain', True,
                                   message='لا توجد مرجعية فونيمية صالحة لهذه الكلمة؛ لم تُحتسب صحيحة أو خاطئة.'))
            self.cursor += 1
            return True
        tail = chars[self.consumed:]
        ttimes = tms[self.consumed:] if tms else None
        Hall = heard_runs(tail, ttimes, base=self.consumed)
        use_all = stable or final
        H = Hall if use_all else Hall[:-1]
        if not H:
            return False
        ops, istar, cost = align(E, H)
        if use_all:
            tn = 0
            tchars = 0
            for o in reversed(ops):
                if o[0] == I:
                    tn += 1
                    tchars += H[o[2]].length
                else:
                    break
            if (tn >= 2 or tchars >= 3) and istar < len(E):
                # speech that matches nothing after the last explained word is an
                # attempt at the next word: force that word to take responsibility
                ops, istar, cost = align(E, H, forced_end=spans[E[istar].word - self.cursor][1])
        self.report = f'cost={cost:.2f} istar={istar}/{len(E)} ops=' + ''.join(o[0] for o in ops)

        # attribute ops to words
        per_word, h_end_of, last_k_of, trailing_start = self._attribute(ops, E, H)
        w = self.cursor
        covered = E[spans[0][1] - 1].word == w and (spans[0][1] <= istar)
        touched = spans[0][0] < istar
        items = per_word.get(w, [])
        if covered:
            # Anchoring: a word is only committed when later words confirm the
            # alignment (>= 2 exact later matches), or the speaker paused/stopped.
            last_k = last_k_of.get(w, -1)
            anchors = 0
            for (op, ei, hi) in ops[last_k + 1:]:
                if op in (M, L) and E[ei].word > w:
                    anchors += 1
            later_runs = sum(1 for r in E if r.word > w)
            trailing_n = len(ops) - trailing_start
            if later_runs > 0:
                anchored = anchors >= min(ANCHOR_RUNS, later_runs)
            else:
                anchored = trailing_n >= 4
            if not (stable or final or anchored):
                return False
            if not (stable or final):
                # an insertion block between this word and the next may belong to
                # either; wait until the next word has been fully processed
                core_last = -1
                for k, (op, ei, hi) in enumerate(ops):
                    if op != I and E[ei].word == w:
                        core_last = k
                nxt = core_last + 1
                if nxt < len(ops) and ops[nxt][0] == I:
                    jn = nxt
                    while jn < len(ops) and ops[jn][0] == I:
                        jn += 1
                    if jn < len(ops) and E[ops[jn][1]].word != w:
                        b = E[ops[jn][1]].word
                        b_end = spans[b - self.cursor][1]
                        if b_end > istar:
                            return False
        elif not (final and touched):
            return False
        last_idx = spans[0][1] - 1
        partial = not covered
        findings = self._analyze(w, items, E, H, Hall, spans[0], partial, stable, final)
        # state advance
        hend = h_end_of.get(w, self.consumed)
        if w == len(self.words) - 1:
            for (op, ei, hi) in ops[trailing_start:][:2]:
                if op == I and kind_of(H[hi].code) == K_MARK:
                    hend = max(hend, H[hi].end)
                else:
                    break
        if (self.strictness == 'balanced' and len(findings) == 1 and findings[0].hard
                and findings[0].kind in SOFTENABLE):
            f0 = findings[0]
            findings = [Finding(False, f0.kind, f0.expected, f0.heard,
                                'تنبيه — قد يكون من التعرّف الصوتي: ' + f0.message, None)]
        hard = [f for f in findings if f.hard]
        soft = [f for f in findings if not f.hard]
        if hard:
            verdict, rule = 'incorrect', None
        elif soft:
            verdict, rule = 'warning', soft[0].rule
        else:
            verdict, rule = 'correct', None
        msg = '؛ '.join(f.message for f in (hard + soft)[:2]) if findings else None

        if verdict == 'incorrect' and self.mode == 'memorize':
            if not (stable or final):
                return False  # defer provisional failures until the speaker pauses
            events.append(WordEval(word.index, 'incorrect', False, None, msg, findings))
            self.failed = True
            self.consumed = len(chars)
            return False
        events.append(WordEval(word.index, verdict, True, rule, msg, findings))
        self.failed = False
        self.consumed = max(self.consumed, hend)
        self.cursor += 1
        return True


    def _attribute(self, ops, E, H):
        """Assign every alignment op to a word.

        Insertions inside a word belong to that word. An insertion block between
        two words goes to the neighbour that already has errors (so one wrong
        word cannot make its correct neighbour look wrong); otherwise it is an
        extra sound after the previous word. Trailing insertions are left for
        the next, not yet judged word."""
        n = len(ops)
        trailing_start = n
        for k in range(n - 1, -1, -1):
            if ops[k][0] == I:
                trailing_start = k
            else:
                break
        # word of each non-insertion op, then blocks of insertions
        word_at = [None] * n
        for k, (op, ei, hi) in enumerate(ops):
            if op != I:
                word_at[k] = E[ei].word
        core = {}
        for k, (op, ei, hi) in enumerate(ops):
            if op != I:
                core.setdefault(word_at[k], []).append(op)
        def has_err(wd):
            return any(o != M for o in core.get(wd, []))
        owner = [None] * n
        k = 0
        while k < n:
            if ops[k][0] != I:
                owner[k] = word_at[k]
                k += 1
                continue
            j = k
            while j < n and ops[j][0] == I:
                j += 1
            prev_w = word_at[k - 1] if k > 0 else None
            next_w = word_at[j] if j < n else None
            if j >= trailing_start and next_w is None:
                who = None                       # trailing: not attributed
            elif prev_w is None:
                who = next_w                     # leading: the first word's attempt
            elif prev_w == next_w:
                who = prev_w                     # inside a word
            elif has_err(prev_w):
                who = prev_w
            elif has_err(next_w):
                who = next_w
            else:
                who = prev_w
            for t in range(k, j):
                owner[t] = who
            k = j
        per_word, h_end_of, last_k_of = {}, {}, {}
        h_pos = self.consumed
        for k, (op, ei, hi) in enumerate(ops):
            if hi >= 0:
                h_pos = H[hi].end
            who = owner[k]
            if who is None:
                continue
            per_word.setdefault(who, []).append(ops[k])
            last_k_of[who] = k
            if op == I:
                h_end_of[who] = max(h_end_of.get(who, 0), H[hi].end)
            else:
                h_end_of[who] = max(h_end_of.get(who, 0), h_pos if hi < 0 else H[hi].end)
        return per_word, h_end_of, last_k_of, trailing_start

    # --- analysis of one word ------------------------------------------
    def _analyze(self, w, items, E, H, Hall, span, partial, stable, final):
        word = self.words[w]
        rs, re_ = span
        rules = word.rules
        is_last_word = (w == len(self.words) - 1)

        # materialise items as (op, e, h)
        rows = []
        for op, ei, hi in items:
            rows.append([op, E[ei] if ei >= 0 else None, H[hi] if hi >= 0 else None, ei, hi])
        # partial word at the end of the session: unreached runs are missing
        if partial:
            reached = max([r[3] for r in rows if r[3] >= 0], default=rs - 1)
            for ei in range(reached + 1, re_):
                rows.append([D, E[ei], None, ei, -1])

        # pause after word?
        last_h = max([r[4] for r in rows if r[4] >= 0], default=-1)
        pause_after = False
        if last_h >= 0 or True:
            nxt = None
            if last_h >= 0:
                idx_all = next((i for i, r in enumerate(Hall) if r.start == H[last_h].start), None)
                if idx_all is not None and idx_all + 1 < len(Hall):
                    nxt = Hall[idx_all + 1]
                    cur = Hall[idx_all]
                    if cur.t1 is not None and nxt.t0 is not None:
                        pause_after = (nxt.t0 - cur.t1) >= PAUSE_GAP_SEC
                else:
                    pause_after = stable or final
            else:
                pause_after = stable or final
        tail_forgive = pause_after or is_last_word

        # forgive: leading hamza wasl
        if word.text.startswith('\u0671') and (re_ - rs) >= 2:
            e0, e1 = E[rs], E[rs + 1]
            if e0.code == HAMZA and kind_of(e1.code) == K_MARK:
                rows = [r for r in rows if not (r[0] == D and r[3] in (rs, rs + 1))]
        # forgive: final vowel (or vowel + tanween noon) at a pause or at the ayah end
        if tail_forgive:
            last_i = re_ - 1
            by_ei = {r[3]: r for r in rows if r[0] == D}
            drop = set()
            last_row = by_ei.get(last_i)
            if last_row is not None and kind_of(last_row[1].code) == K_MARK:
                drop.add(last_i)
            elif (last_row is not None and last_row[1].code == 0x0646 and last_row[1].length == 1
                  and (last_i - 1) in by_ei and kind_of(by_ei[last_i - 1][1].code) == K_MARK):
                drop.add(last_i)
                drop.add(last_i - 1)
            rows = [r for r in rows if not (r[0] == D and r[3] in drop)]
            # extra trailing vowel(s) after the last expected run
            last_e = max([r[3] for r in rows if r[3] >= 0], default=-1)
            seen_last = False
            kept = []
            for r in rows:
                if r[3] == last_e and r[3] >= 0:
                    seen_last = True
                if r[0] == I and seen_last and r[2] is not None and kind_of(r[2].code) == K_MARK:
                    continue
                kept.append(r)
            rows = kept
        # forgive: harmless repetition of a neighbouring word
        rows = self._drop_repetitions(rows, w, E)
        # forgive: one stray phoneme before the very first word of the session
        if self.consumed == 0:
            lead = []
            for r in rows:
                if r[0] == I:
                    lead.append(r)
                else:
                    break
            if len(lead) == 1 and lead[0][2].length == 1:
                rows = rows[1:]

        findings = []
        if not self.strict:
            cons = [r for r in rows if r[1] is not None and kind_of(r[1].code) == K_CONS]
            bad = [r for r in rows if r[0] in (S, D, I) and
                   ((r[1] is not None and kind_of(r[1].code) == K_CONS) or
                    (r[2] is not None and kind_of(r[2].code) == K_CONS))]
            total = max(1, len([e for e in E[rs:re_] if kind_of(e.code) == K_CONS]))
            if len(bad) / total >= 0.4:
                findings.append(Finding(True, 'approximate_mismatch', '', '',
                                        'الكلمة لا تطابق المتوقع بوضوح'))
            return findings
        for op, e, h, ei, hi in rows:
            if op == M:
                continue
            f = classify_op(op, e, h, rules)
            if f is not None:
                findings.append(f)
        return findings

    def _drop_repetitions(self, rows, w, E):
        out, i = [], 0
        while i < len(rows):
            if rows[i][0] != I:
                out.append(rows[i]); i += 1; continue
            j = i
            while j < len(rows) and rows[j][0] == I:
                j += 1
            block = [r[2] for r in rows[i:j]]
            drop = False
            if len(block) >= 3:
                for cand in (w - 1, w + 1):
                    if 0 <= cand < len(self.words):
                        rr, _ = expected_runs([self.words[cand].phonemes])
                        if rr and _run_distance(block, rr) <= len(rr) // 4:
                            drop = True
                            break
                if not drop:
                    rr, _ = expected_runs([self.words[w].phonemes])
                    if rr and _run_distance(block, rr) <= len(rr) // 4:
                        drop = True
            if not drop:
                out.extend(rows[i:j])
            i = j
        return out
