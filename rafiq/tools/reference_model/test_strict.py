import sys
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from strict_eval import *

W = ["ءِننننَ", "للَذِۦۦنَ", "كَفَرُۥۥ", "سَوَااااءُن", "عَلَيهِم", "ءَءَںںںذَرتَهُم"]
RULES = {3: ('madd_muttasil',), 2: ('madd_tabii',), 1: ('madd_tabii',)}


def words(ph=W, last_text=None):
    return [WordT(i, 'ٱ' if (i == 1) else 'x', p, RULES.get(i, ())) for i, p in enumerate(ph)]


def runs_of(s):
    out, i = [], 0
    while i < len(s):
        j = i
        while j < len(s) and s[j] == s[i]:
            j += 1
        out.append(s[i:j]); i = j
    return out


def stream(ev, hyp, step=0.2, gap_after=None, finish=True):
    """Feed hyp (string) run by run like a streaming decoder; returns all events."""
    rs = runs_of(hyp)
    events = []
    toks, tms = [], []
    t = 0.0
    for k, r in enumerate(rs):
        toks.append(r); tms.append(t)
        t += step
        if gap_after and k in gap_after:
            t += gap_after[k]
        events += ev.update(''.join(toks), toks, tms)
    if finish:
        events += ev.finish(''.join(toks), toks, tms)
    return events


def verdicts(events):
    return [(e.word, e.verdict) for e in events]


def check(name, cond):
    print(('PASS ' if cond else 'FAIL ') + name)
    if not cond:
        global FAILED
        FAILED = True

FAILED = False

# 1 perfect recitation -> everything correct
ev = StrictEvaluator(words())
evs = stream(ev, ''.join(W))
check('perfect: all 6 correct', verdicts(evs) == [(i, 'correct') for i in range(6)])
check('perfect: complete', ev.is_complete)

# 2 haraka substitution (fatha -> kasra on word 2)
bad = W.copy(); bad[2] = "كَفِرُۥۥ"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs))
check('haraka sub flagged hard', v.get(2) == 'incorrect' and all(v.get(i) == 'correct' for i in (0, 1, 3, 4, 5)))
check('haraka message names both vowels', any('كسرة' in (e.message or '') and 'فتحة' in (e.message or '') for e in evs if e.word == 2))

# 3 dropped letter
bad = W.copy(); bad[4] = "عَلَهِم"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('dropped letter flagged', v.get(4) == 'incorrect')

# 4 whole word substituted
bad = W.copy(); bad[4] = "رَبِّهِم"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('word substitution flagged', v.get(4) == 'incorrect' and v.get(5) == 'correct')

# 5 skipped word
bad = W.copy(); del bad[3]
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('skipped word flagged', v.get(3) == 'incorrect' and v.get(4) == 'correct' and v.get(5) == 'correct')

# 6 madd tabii shortened (كَفَرُۥ instead of ۥۥ) -> soft warning
bad = W.copy(); bad[2] = "كَفَرُۥ"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('short madd tabii -> warning', v.get(2) == 'warning')
check('short madd rule', [e.rule for e in evs if e.word == 2][0] == 'madd_tabii')

# 7 madd muttasil 4 -> 6 allowed, -> 2 flagged
for hv, exp in (("سَوَااااااءُن", 'correct'), ("سَوَااااااءُن".replace("اااااا", "ااااا"), 'correct'), ("سَوَاااءُن", 'warning'), ("سَوَااءُن", 'warning')):
    bad = W.copy(); bad[3] = hv
    ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
    v = dict(verdicts(evs)); check(f'muttasil {hv} -> {exp}', v.get(3) == exp)

# 8 shadda lost
bad = W.copy(); bad[1] = "لَذِۦۦنَ"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('lost shadda hard', v.get(1) == 'incorrect')

# 9 final vowel dropped mid-ayah: forgiven only with pause
bad = W.copy(); bad[2] = "كَفَرُۥۥ"; bad[4] = "عَلَيهِم"
ph2 = W.copy(); ph2[2] = "كَفَرُۥۥ"
# word 3 final damma + noon (tanween) dropped => "سَوَاااءُن" -> "سَوَااااء"
bad = W.copy(); bad[3] = "سَوَااااء"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('final vowel dropped, no pause -> flagged', v.get(3) == 'incorrect')
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad), gap_after={ }, finish=True)
# with a pause: stretch times after the run containing 'ء' (index of run)
rs = runs_of(''.join(bad)); idx = rs.index('اااا') + 1
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad), gap_after={idx: 0.8})
v = dict(verdicts(evs)); check('final vowel dropped + pause -> forgiven', v.get(3) == 'correct')

# 10 wrong vowel before a pause is still flagged
bad = W.copy(); bad[3] = "سَوَااااءَن"
rs = runs_of(''.join(bad)); idx = len(rs) - 1
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('wrong final vowel flagged', v.get(3) == 'incorrect')

# 11 incomplete session: user stops mid word
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(W[:3]) + "سَوَا")
v = dict(verdicts(evs)); check('stopped mid-word: earlier words correct', v.get(0) == 'correct' and v.get(1) == 'correct' and v.get(2) == 'correct')
check('stopped mid-word: partial word flagged on final', v.get(3) == 'incorrect')
check('stopped mid-word: later words untouched', 4 not in v and 5 not in v)

# 12 repetition of a word is harmless
rep = W[:2] + [W[1]] + W[2:]
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(rep))
v = dict(verdicts(evs)); check('repeat previous word harmless', all(v.get(i) == 'correct' for i in range(6)))

# 13 memorize: failure is provisional, retry succeeds
bad = W.copy(); bad[1] = "للَذَۦۦنَ"
evm = StrictEvaluator(words(), mode='memorize')
evs = stream(evm, ''.join(W[:1]) + bad[1], finish=False)
check('memorize: no verdict for failure before pause', all(e.word == 0 for e in evs))
evs2 = evm.update(''.join(W[:1]) + bad[1], runs_of(''.join(W[:1]) + bad[1]), None, stable=True)
check('memorize: provisional failure at pause', [(e.word, e.verdict, e.advanced) for e in evs2] == [(1, 'incorrect', False)])
check('memorize: cursor stays', evm.cursor == 1)
hyp = ''.join(W[:1]) + bad[1] + W[1]
evs3 = evm.update(hyp, runs_of(hyp), None, stable=True)
check('memorize: retry advances', [(e.word, e.verdict, e.advanced) for e in evs3][:1] == [(1, 'correct', True)])

# 14 empty hypothesis never judges
ev = StrictEvaluator(words()); check('empty hyp -> no events', ev.update('') == [] and ev.finish('') == [])

# 15 garbage hypothesis flags first word, never passes
ev = StrictEvaluator(words()); evs = ev.finish('زززززز', ['زززززز'], None)
check('garbage never passes', all(e.verdict != 'correct' for e in evs) and len(evs) >= 1)

# 16 extra letter
bad = W.copy(); bad[4] = "عَلَيهِمم"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('extra letter flagged', v.get(4) in ('incorrect', 'warning'))

# 17 no timestamps still works
ev = StrictEvaluator(words()); h = ''.join(W)
evs = ev.finish(h, runs_of(h), None)
check('no timestamps: perfect', verdicts(evs) == [(i, 'correct') for i in range(6)])

# 18 leading wasl hamza forgiven
w2 = words(); w2[1] = WordT(1, 'ٱللَّذِينَ', "ءَللَذِۦۦنَ", ())
ev = StrictEvaluator(w2); h = W[0] + "لل" + "َذِۦۦنَ" + ''.join(W[2:])
evs = ev.finish(h, runs_of(h), None)
v = dict(verdicts(evs)); check('missing leading hamza-wasl forgiven', v.get(1) == 'correct')

# 19 qalqalah-like/letter confusion ص vs س
w3 = [WordT(0, 'a', 'صِرَاطَ', ()), WordT(1, 'b', 'مُستَقِيم', ())]
ev = StrictEvaluator(w3); h = 'سِرَاطَ' + 'مُستَقِيم'
evs = ev.finish(h, runs_of(h), None); v = dict(verdicts(evs))
check('ص->س flagged', v.get(0) == 'incorrect' and v.get(1) == 'correct')

# 20 gibberish in place of the LAST spoken word is flagged at the pause/stop
ev = StrictEvaluator(words()); h = ''.join(W[:3]) + 'زززكككتتت'
evs = ev.finish(h, runs_of(h), None); v = dict(verdicts(evs))
check('gibberish for next word flagged', v.get(0) == 'correct' and v.get(2) == 'correct' and v.get(3) == 'incorrect' and 4 not in v)

# 21 single stray run at the end is noise (not an attempt at a word)
ev = StrictEvaluator(words()); h = ''.join(W[:3]) + 'ز'
evs = ev.finish(h, runs_of(h), None); v = dict(verdicts(evs))
check('single stray phoneme ignored', v == {0: 'correct', 1: 'correct', 2: 'correct'})

# 22 a mistake in the last spoken word of the session is caught at the stop
bad = W[:4]; bad[3] = "سَوَااااءِن"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad)); v = dict(verdicts(evs))
check('mistake in final word caught', v.get(3) == 'incorrect' and v.get(2) == 'correct')

# 23 streaming never emits a verdict twice and never goes backwards
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(W))
ws = [e.word for e in evs]
check('verdicts unique and ordered', ws == sorted(set(ws)))

# 24 two mistakes in one word are both reported
bad = W.copy(); bad[4] = "عَلَيهُمم"
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad))
ee = [e for e in evs if e.word == 4][0]
check('multiple findings reported', ee.verdict == 'incorrect' and len(ee.findings) >= 2)


# 25 balanced mode softens an isolated single haraka discrepancy but never hides it
bad = W.copy(); bad[2] = "كَفِرُۥۥ"
ev = StrictEvaluator(words(), strictness='balanced'); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('balanced: single haraka -> warning (not silent)', v.get(2) == 'warning')
bad[4] = "عَلَيهُمم"
ev = StrictEvaluator(words(), strictness='balanced'); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('balanced: multiple discrepancies stay hard', v.get(4) == 'incorrect')
bad = W.copy(); bad[4] = "عَلَهِم"
ev = StrictEvaluator(words(), strictness='balanced'); evs = stream(ev, ''.join(bad))
v = dict(verdicts(evs)); check('balanced: dropped letter stays hard', v.get(4) == 'incorrect')


# 26 a mid-word vowel deleted before a pause is NOT a waqf: still flagged
bad = W.copy(); bad[4] = "عَلَيهم"   # kasra before the final meem removed
rs = runs_of(''.join(bad)); idx = len(rs) - 1
ev = StrictEvaluator(words()); evs = stream(ev, ''.join(bad)); v = dict(verdicts(evs))
check('mid-word vowel deletion still flagged', v.get(4) == 'incorrect')

# 27 balanced/strict on the same ayah never downgrade letter-level errors
bad = W.copy(); bad[1] = "للَذِۦۦبَ"
for lvl in ('strict', 'balanced'):
    ev = StrictEvaluator(words(), strictness=lvl); evs = stream(ev, ''.join(bad)); v = dict(verdicts(evs))
    check(f'{lvl}: letter substitution is hard', v.get(1) == 'incorrect')

print('\nFAILED' if FAILED else '\nALL PASS')
