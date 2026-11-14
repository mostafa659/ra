"""Line-by-line transliteration of strict_recitation_evaluator.dart into Python.

Purpose: validate the *Dart control flow* (not the original reference) against the
same scenarios. Anything that differs structurally from strict_eval.py is
re-implemented here exactly the way the Dart code does it.
"""
import math
from strict_eval import (normalize, kind_of, K_CONS, K_MARK, K_MADD, K_NASAL, HAMZA)

OP_MATCH, OP_LENGTH, OP_SUB, OP_DEL, OP_INS = 0, 1, 2, 3, 4
INDEL, SUBC, CROSS = 0.8, 1.0, 1.8
PAUSE_GAP = 0.5
ANCHOR_RUNS = 2
NOON, MEEM = 0x0646, 0x0645
SOFTENABLE = {'haraka_sub', 'mark_del', 'mark_ins', 'letter_ins'}


class Run:
    def __init__(self, code, length, word=-1, start=0, t0=None, t1=None):
        self.code, self.length, self.word, self.start, self.t0, self.t1 = code, length, word, start, t0, t1

    @property
    def end(self):
        return self.start + self.length


def runs_of_string(ph, word, base):
    chars = [ord(c) for c in normalize(ph)]
    runs, i = [], 0
    while i < len(chars):
        j = i
        while j < len(chars) and chars[j] == chars[i]:
            j += 1
        runs.append(Run(chars[i], j - i, word=word, start=base + i))
        i = j
    return runs


def heard_runs(chars, times, frm):
    runs, i = [], frm
    while i < len(chars):
        j = i
        while j < len(chars) and chars[j] == chars[i]:
            j += 1
        runs.append(Run(chars[i], j - i, start=i,
                        t0=None if times is None else times[i],
                        t1=None if times is None else times[j - 1]))
        i = j
    return runs


def sub_cost(e, h):
    if e.code == h.code:
        if e.length == h.length:
            return 0.0
        d = abs(e.length - h.length)
        return min(0.9, 0.3 + 0.1 * (d - 1))
    if kind_of(e.code) == kind_of(h.code):
        return SUBC
    return CROSS


def align(e, h, forced_end=None):
    n, m = len(e), len(h)
    inf = 1e18
    d = [[inf] * (m + 1) for _ in range(n + 1)]
    p = [[0] * (m + 1) for _ in range(n + 1)]
    d[0][0] = 0.0
    for i in range(n + 1):
        for j in range(m + 1):
            if i == 0 and j == 0:
                continue
            best, pointer = inf, 0
            if i > 0 and j > 0:
                c = d[i - 1][j - 1] + sub_cost(e[i - 1], h[j - 1])
                if c < best - 1e-9:
                    best, pointer = c, 1
            if i > 0:
                c = d[i - 1][j] + INDEL
                if c < best - 1e-9:
                    best, pointer = c, 2
            if j > 0:
                c = d[i][j - 1] + INDEL
                if c < best - 1e-9:
                    best, pointer = c, 3
            d[i][j], p[i][j] = best, pointer
    if forced_end is not None:
        end, best_cost = forced_end, d[forced_end][m]
    else:
        end, best_cost = 0, d[0][m]
        for i in range(1, n + 1):
            if d[i][m] <= best_cost + 1e-9:
                end, best_cost = i, d[i][m]
    rev = []
    ti, tj = end, m
    while ti > 0 or tj > 0:
        pointer = p[ti][tj]
        if pointer == 1:
            er, hr = e[ti - 1], h[tj - 1]
            if er.code == hr.code:
                rev.append((OP_MATCH if er.length == hr.length else OP_LENGTH, ti - 1, tj - 1))
            else:
                rev.append((OP_SUB, ti - 1, tj - 1))
            ti -= 1; tj -= 1
        elif pointer == 2:
            rev.append((OP_DEL, ti - 1, -1)); ti -= 1
        elif pointer == 3:
            rev.append((OP_INS, -1, tj - 1)); tj -= 1
        else:
            break
    rev.reverse()
    return rev, end, best_cost


def run_distance(a, b):
    n, m = len(a), len(b)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [0] * (m + 1); cur[0] = i
        for j in range(1, m + 1):
            same = a[i - 1].code == b[j - 1].code and a[i - 1].length == b[j - 1].length
            best = prev[j - 1] + (0 if same else 1)
            if prev[j] + 1 < best: best = prev[j] + 1
            if cur[j - 1] + 1 < best: best = cur[j - 1] + 1
            cur[j] = best
        prev = cur
    return prev[m]


class Finding:
    def __init__(self, hard, kind, message, rule=None):
        self.hard, self.kind, self.message, self.rule = hard, kind, message, rule


class Row:
    def __init__(self, op, e, h, ei, hi):
        self.op, self.e, self.h, self.ei, self.hi = op, e, h, ei, hi


class Word:
    def __init__(self, index, text, phonemes, rules=()):
        self.index, self.text, self.phonemes, self.rules = index, text, normalize(phonemes), tuple(rules)


class Evaluation:
    def __init__(self, word, verdict, advanced, rule=None, message=None, findings=()):
        self.word, self.verdict, self.advanced, self.rule, self.message = word, verdict, advanced, rule, message
        self.findings = list(findings)

    def __repr__(self):
        return f'Eval({self.word},{self.verdict},{self.advanced},{self.rule})'


def glyph(c): return chr(c)
def haraka_name(c): return {0x064E: 'فتحة', 0x064F: 'ضمّة', 0x0650: 'كسرة'}.get(c)


class Evaluator:
    def __init__(self, words, mode='recite', strictness='strict', canonical=True):
        self.words, self.mode, self.strictness, self.canonical = words, mode, strictness, canonical
        self.cursor = 0; self.consumed = 0; self.failed = False; self.last_key = ''
        self.expected_for = -1; self.expected = None; self.last_report = ''

    @property
    def is_complete(self): return self.cursor >= len(self.words)

    def set_consumed(self, v): self.consumed = 0 if v < 0 else v; self.last_key = ''

    @staticmethod
    def build_hyp(text, tokens, timestamps):
        if tokens:
            chars, times, all_timed = [], [], True
            for i, tok in enumerate(tokens):
                n = normalize(tok)
                has_time = i < len(timestamps)
                for ch in n:
                    chars.append(ord(ch)); times.append(timestamps[i] if has_time else 0.0)
                if not has_time and len(n) > 0:
                    all_timed = False
            return chars, (times if (all_timed and times) else None)
        return [ord(c) for c in normalize(text)], None

    def expected_runs(self):
        if self.expected is not None and self.expected_for == self.cursor:
            return self.expected
        runs, starts, ends, position = [], [], [], 0
        for w in range(self.cursor, len(self.words)):
            ph = normalize(self.words[w].phonemes)
            starts.append(len(runs))
            runs.extend(runs_of_string(ph, w, position))
            ends.append(len(runs))
            position += len(ph)
        self.expected = (runs, starts, ends); self.expected_for = self.cursor
        return self.expected

    def update(self, hypothesis, tokens=(), timestamps=(), stable=False, is_final=False):
        chars, times = self.build_hyp(hypothesis, list(tokens), list(timestamps))
        key = f'{"".join(map(chr, chars))}|{stable}|{is_final}|{self.cursor}|{self.consumed}|{self.failed}'
        if key == self.last_key:
            return []
        self.last_key = key
        if self.consumed > len(chars):
            self.consumed = 0
        events, guard = [], 0
        while not self.is_complete and guard < 64:
            guard += 1
            if not self.step((chars, times), stable, is_final, events):
                break
        self.last_key = f'{"".join(map(chr, chars))}|{stable}|{is_final}|{self.cursor}|{self.consumed}|{self.failed}'
        return events

    def finish(self, hypothesis, tokens=(), timestamps=()):
        return self.update(hypothesis, tokens, timestamps, stable=True, is_final=True)

    def step(self, hyp, stable, is_final, events):
        chars, times = hyp
        word = self.words[self.cursor]
        e, starts, ends = self.expected_runs()
        word_start, word_end = starts[0], ends[0]
        if word_start == word_end:
            events.append(Evaluation(word.index, 'uncertain', True, message='no reference'))
            self.cursor += 1
            return True
        heard_all = heard_runs(chars, times, self.consumed)
        use_all = stable or is_final
        h = heard_all if use_all else (heard_all if not heard_all else heard_all[:-1])
        if not h:
            return False
        alignment = align(e, h)
        if use_all:
            tr, tc = 0, 0
            for k in range(len(alignment[0]) - 1, -1, -1):
                op = alignment[0][k]
                if op[0] == OP_INS:
                    tr += 1; tc += h[op[2]].length
                else:
                    break
            if (tr >= 2 or tc >= 3) and alignment[1] < len(e):
                target = e[alignment[1]].word - self.cursor
                alignment = align(e, h, forced_end=ends[target])
        ops, istar, cost = alignment
        self.last_report = f'cost={cost:.2f} reached={istar}/{len(e)}'
        attr = self.attribute(ops, e, h)
        per_word, h_end, last_op, trailing_start = attr
        w = self.cursor
        covered = word_end <= istar
        touched = word_start < istar
        items = per_word.get(w, [])
        if covered:
            last_k = last_op.get(w, -1)
            anchors = 0
            for k in range(last_k + 1, len(ops)):
                op = ops[k]
                if op[0] in (OP_MATCH, OP_LENGTH) and e[op[1]].word > w:
                    anchors += 1
            later = sum(1 for r in e if r.word > w)
            trailing_count = len(ops) - trailing_start
            anchored = (anchors >= min(ANCHOR_RUNS, later)) if later > 0 else trailing_count >= 4
            if not (stable or is_final or anchored):
                return False
            if not (stable or is_final):
                core_last = -1
                for k in range(len(ops)):
                    if ops[k][0] != OP_INS and e[ops[k][1]].word == w:
                        core_last = k
                nxt = core_last + 1
                if nxt < len(ops) and ops[nxt][0] == OP_INS:
                    jn = nxt
                    while jn < len(ops) and ops[jn][0] == OP_INS:
                        jn += 1
                    if jn < len(ops) and e[ops[jn][1]].word != w:
                        b = e[ops[jn][1]].word
                        b_end = ends[b - self.cursor]
                        if b_end > istar:
                            return False
        elif not (is_final and touched):
            return False
        partial = not covered
        findings = self.analyze(w, items, e, h, heard_all, word_start, word_end, partial, stable, is_final)
        hend = h_end.get(w, self.consumed)
        if w == len(self.words) - 1:
            taken = 0
            k = trailing_start
            while k < len(ops) and taken < 2:
                op = ops[k]
                if op[0] == OP_INS and kind_of(h[op[2]].code) == K_MARK:
                    hend = max(hend, h[op[2]].end); taken += 1
                else:
                    break
                k += 1
        if (self.strictness == 'balanced' and len(findings) == 1 and findings[0].hard
                and findings[0].kind in SOFTENABLE):
            f0 = findings[0]
            findings = [Finding(False, f0.kind, 'x' + f0.message)]
        hard = [f for f in findings if f.hard]
        soft = [f for f in findings if not f.hard]
        if hard: verdict, rule = 'incorrect', None
        elif soft: verdict, rule = 'warning', soft[0].rule
        else: verdict, rule = 'correct', None
        ordered = hard + soft
        message = '؛ '.join(f.message for f in ordered[:2]) if ordered else None
        if not self.canonical and verdict == 'correct':
            verdict = 'uncertain'
            message = 'x'
        if verdict == 'incorrect' and self.mode == 'memorize':
            if not (stable or is_final):
                return False
            events.append(Evaluation(word.index, 'incorrect', False, message=message, findings=findings))
            self.failed = True
            self.consumed = len(chars)
            return False
        events.append(Evaluation(word.index, verdict, True, rule, message, findings))
        self.failed = False
        self.consumed = max(self.consumed, hend)
        self.cursor += 1
        return True

    def attribute(self, ops, e, h):
        n = len(ops)
        trailing_start = n
        for k in range(n - 1, -1, -1):
            if ops[k][0] == OP_INS:
                trailing_start = k
            else:
                break
        word_at = [-1] * n
        has_error = {}
        for k in range(n):
            if ops[k][0] != OP_INS:
                wd = e[ops[k][1]].word
                word_at[k] = wd
                if ops[k][0] != OP_MATCH:
                    has_error[wd] = True
        owner = [-1] * n
        k = 0
        while k < n:
            if ops[k][0] != OP_INS:
                owner[k] = word_at[k]; k += 1; continue
            j = k
            while j < n and ops[j][0] == OP_INS:
                j += 1
            prev_w = word_at[k - 1] if k > 0 else -1
            next_w = word_at[j] if j < n else -1
            if j >= trailing_start and next_w == -1: who = -1
            elif prev_w == -1: who = next_w
            elif prev_w == next_w: who = prev_w
            elif has_error.get(prev_w) is True: who = prev_w
            elif has_error.get(next_w) is True: who = next_w
            else: who = prev_w
            for t in range(k, j):
                owner[t] = who
            k = j
        per_word, h_end, last_op = {}, {}, {}
        h_pos = self.consumed
        for idx in range(n):
            op = ops[idx]
            if op[2] >= 0:
                h_pos = h[op[2]].end
            who = owner[idx]
            if who == -1:
                continue
            per_word.setdefault(who, []).append(op)
            last_op[who] = idx
            cand = h[op[2]].end if op[2] >= 0 else h_pos
            h_end[who] = max(h_end.get(who, 0), cand)
        return per_word, h_end, last_op, trailing_start

    def analyze(self, w, items, e, h, heard_all, ws, we, partial, stable, is_final):
        word = self.words[w]
        is_last = (w == len(self.words) - 1)
        rows = [Row(op[0], e[op[1]] if op[1] >= 0 else None, h[op[2]] if op[2] >= 0 else None, op[1], op[2]) for op in items]
        if partial:
            reached = ws - 1
            for r in rows:
                if r.ei >= 0 and r.ei > reached:
                    reached = r.ei
            for ei in range(reached + 1, we):
                rows.append(Row(OP_DEL, e[ei], None, ei, -1))
        last_h = -1
        for r in rows:
            if r.hi > last_h:
                last_h = r.hi
        pause_after = False
        if last_h >= 0:
            if last_h + 1 < len(heard_all):
                cur, nxt = heard_all[last_h], heard_all[last_h + 1]
                if cur.t1 is not None and nxt.t0 is not None:
                    pause_after = (nxt.t0 - cur.t1) >= PAUSE_GAP
            else:
                pause_after = stable or is_final
        else:
            pause_after = stable or is_final
        tail_forgive = pause_after or is_last
        if word.text.startswith('\u0671') and (we - ws) >= 2:
            e0, e1 = e[ws], e[ws + 1]
            if e0.code == HAMZA and kind_of(e1.code) == K_MARK:
                rows = [r for r in rows if not (r.op == OP_DEL and (r.ei == ws or r.ei == ws + 1))]
        if tail_forgive:
            last_index = we - 1
            deleted = {}
            for r in rows:
                if r.op == OP_DEL:
                    deleted[r.ei] = r
            drop = set()
            last_row = deleted.get(last_index)
            if last_row is not None and kind_of(last_row.e.code) == K_MARK:
                drop.add(last_index)
            elif (last_row is not None and last_row.e.code == NOON and last_row.e.length == 1
                  and deleted.get(last_index - 1) is not None
                  and kind_of(deleted[last_index - 1].e.code) == K_MARK):
                drop.add(last_index); drop.add(last_index - 1)
            rows = [r for r in rows if not (r.op == OP_DEL and r.ei in drop)]
            last_e = -1
            for r in rows:
                if r.ei > last_e:
                    last_e = r.ei
            seen_last, kept = False, []
            for r in rows:
                if r.ei >= 0 and r.ei == last_e:
                    seen_last = True
                if r.op == OP_INS and seen_last and r.h is not None and kind_of(r.h.code) == K_MARK:
                    continue
                kept.append(r)
            rows = kept
        rows = self.drop_repetitions(rows, w)
        if self.consumed == 0:
            lead = []
            for r in rows:
                if r.op == OP_INS: lead.append(r)
                else: break
            if len(lead) == 1 and lead[0].h.length == 1:
                rows = rows[1:]
        findings = []
        if not self.canonical:
            bad = 0
            for r in rows:
                if r.op not in (OP_SUB, OP_DEL, OP_INS):
                    continue
                e_cons = r.e is not None and kind_of(r.e.code) == K_CONS
                h_cons = r.h is not None and kind_of(r.h.code) == K_CONS
                if e_cons or h_cons:
                    bad += 1
            total = 0
            for i in range(ws, we):
                if kind_of(e[i].code) == K_CONS:
                    total += 1
            if total < 1: total = 1
            if bad / total >= 0.4:
                findings.append(Finding(True, 'approximate_mismatch', 'approx'))
            return findings
        for r in rows:
            if r.op == OP_MATCH:
                continue
            f = self.classify(r, word.rules)
            if f is not None:
                findings.append(f)
        return findings

    def drop_repetitions(self, rows, w):
        out, i = [], 0
        while i < len(rows):
            if rows[i].op != OP_INS:
                out.append(rows[i]); i += 1; continue
            j = i
            while j < len(rows) and rows[j].op == OP_INS:
                j += 1
            block = [rows[t].h for t in range(i, j)]
            drop = False
            if len(block) >= 3:
                for cand in (w - 1, w + 1):
                    if 0 <= cand < len(self.words):
                        ref = runs_of_string(self.words[cand].phonemes, cand, 0)
                        if ref and run_distance(block, ref) <= len(ref) // 4:
                            drop = True; break
                if not drop:
                    own = runs_of_string(self.words[w].phonemes, w, 0)
                    if own and run_distance(block, own) <= len(own) // 4:
                        drop = True
            if not drop:
                for t in range(i, j):
                    out.append(rows[t])
            i = j
        return out

    def classify(self, r, rules):
        er, hr = r.e, r.h
        if r.op == OP_SUB and er is not None and hr is not None:
            ke, kh = kind_of(er.code), kind_of(hr.code)
            if ke == K_MARK and kh == K_MARK:
                return Finding(True, 'haraka_sub', f'الحركة {haraka_name(hr.code)} {haraka_name(er.code)}')
            if ke == K_MADD and kh == K_MADD:
                return Finding(True, 'madd_letter_sub', 'madd sub')
            return Finding(True, 'letter_sub', f'نطقتَ «{glyph(hr.code)}» بدل «{glyph(er.code)}»')
        if r.op == OP_DEL and er is not None:
            k = kind_of(er.code)
            if k == K_MARK: return Finding(True, 'mark_del', 'mark del')
            if k == K_MADD: return Finding(True, 'madd_del', 'madd del')
            return Finding(True, 'letter_del', 'letter del')
        if r.op == OP_INS and hr is not None:
            k = kind_of(hr.code)
            if k == K_MARK: return Finding(True, 'mark_ins', 'mark ins')
            if k == K_MADD: return Finding(False, 'madd_ins', 'madd ins', 'madd_tabii')
            return Finding(True, 'letter_ins', 'letter ins')
        if r.op == OP_LENGTH and er is not None and hr is not None:
            return self.classify_length(er, hr, rules)
        return None

    def madd_range(self, le, rules):
        if le <= 2: return (2, 2)
        if le >= 6: return (2, 8) if 'madd_arid' in rules else (5, 8)
        if 'madd_munfasil' in rules or 'madd_arid' in rules: return (2, 6)
        if 'madd_muttasil' in rules: return (4, 6)
        return (max(2, le - 1), le + 1)

    def madd_rule(self, le, rules):
        if le >= 6 and 'madd_lazim' in rules: return 'madd_lazim'
        if le > 2:
            for cand in ('madd_muttasil', 'madd_munfasil', 'madd_arid', 'madd_lazim'):
                if cand in rules: return cand
        return 'madd_tabii'

    def classify_length(self, er, hr, rules):
        kind, le, lh = kind_of(er.code), er.length, hr.length
        if kind == K_MADD:
            lo, hi = self.madd_range(le, rules)
            if lo <= lh <= hi: return None
            return Finding(False, 'madd_length', 'madd length', self.madd_rule(le, rules))
        if kind == K_NASAL:
            if abs(le - lh) <= 1: return None
            return Finding(False, 'ikhfa_length', 'ikhfa', 'ikhfa')
        if kind == K_CONS:
            if le >= 2 and lh == 1: return Finding(True, 'shadda_lost', 'shadda lost')
            if le == 1 and lh >= 2: return Finding(True, 'shadda_extra', 'shadda extra')
            if er.code in (NOON, MEEM) and abs(le - lh) >= 2:
                return Finding(False, 'ghunna_length', 'ghunna', 'ghunna')
        return None
