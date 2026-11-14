import random, sys, io, contextlib
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
with contextlib.redirect_stdout(io.StringIO()):
    from test_strict import W, words, runs_of, stream, verdicts
from strict_eval import *

random.seed(7)
LET = list("بتثجحخدذرزسشصضطظعغفقكلمنهوي")
MARKS = ['\u064E', '\u064F', '\u0650']
BASE = [
    "ءِننننَ", "للَذِۦۦنَ", "كَفَرُۥۥ", "سَوَااااءُن", "عَلَيهِم", "ءَءَںںںذَرتَهُم", "ءَم", "لَم",
    "تُںںںذِرهُم", "لَاا", "يُؤمِنُۥۥن", "خَتَمَ", "للَاهُ", "عَلَاا", "قُلُۥۥبِهِم", "وَعَلَاا", "سَمعِهِم",
    "وَعَلَاا", "ءَبصَارِهِم", "غِشَاوَه",
]

def mutate(word, kind):
    cs = list(word)
    idx = [i for i, c in enumerate(cs)]
    if kind == 'haraka_sub':
        pos = [i for i, c in enumerate(cs) if c in MARKS]
        if not pos: return None
        i = random.choice(pos); cs[i] = random.choice([m for m in MARKS if m != cs[i]])
    elif kind == 'letter_sub':
        pos = [i for i, c in enumerate(cs) if c in LET]
        if not pos: return None
        i = random.choice(pos); cs[i] = random.choice([l for l in LET if l != cs[i]])
    elif kind == 'letter_del':
        pos = [i for i, c in enumerate(cs) if c in LET]
        if not pos: return None
        del cs[random.choice(pos)]
    elif kind == 'haraka_del':
        pos = [i for i, c in enumerate(cs) if c in MARKS and i < len(cs) - 1]
        if not pos: return None
        del cs[random.choice(pos)]
    elif kind == 'letter_ins':
        i = random.randrange(1, len(cs)); cs.insert(i, random.choice(LET))
    elif kind == 'madd_short':
        pos = [i for i, c in enumerate(cs) if c in 'اۥۦ' and i + 1 < len(cs) + 0 and cs[i] == cs[i - 1:i + 1][-1]]
        runs = [(i, c) for i, c in enumerate(cs) if c in 'اۥۦ' and (i + 1 < len(cs) and cs[i + 1] == c)]
        if not runs: return None
        del cs[runs[0][0]]
    elif kind == 'whole_word':
        return random.choice([b for b in BASE if b != word])
    return ''.join(cs)

KINDS = ['haraka_sub', 'letter_sub', 'letter_del', 'haraka_del', 'letter_ins', 'madd_short', 'whole_word']

def old_flags(word, heard, accept=0.25):
    # old rule: accepted when edit distance(code points) / len <= acceptRatio
    a, b = list(word), list(heard)
    n, m = len(a), len(b)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            cur[j] = min(prev[j - 1] + (a[i - 1] != b[j - 1]), prev[j] + 1, cur[j - 1] + 1)
        prev = cur
    return prev[m] / n > accept

def run_new(seq, target_pos):
    ws = [WordT(i, 'x', p, ()) for i, p in enumerate(seq)]
    return ws

res = {k: [0, 0, 0] for k in KINDS}   # trials, new detected, old detected
neighbour_fp = 0; trials_total = 0
for _ in range(2500):
    n = random.randint(4, 7)
    start = random.randrange(0, len(BASE) - n)
    seq = BASE[start:start + n]
    pos = random.randrange(1, n - 1)
    kind = random.choice(KINDS)
    m = mutate(seq[pos], kind)
    if m is None or m == seq[pos]:
        continue
    heard = seq.copy(); heard[pos] = m
    ev = StrictEvaluator([WordT(i, 'x', p, ()) for i, p in enumerate(seq)])
    evs = stream(ev, ''.join(heard))
    v = {e.word: e.verdict for e in evs}
    res[kind][0] += 1
    if v.get(pos) in ('incorrect', 'warning'):
        res[kind][1] += 1
    if old_flags(seq[pos], m):
        res[kind][2] += 1
    others = [w for w in v if w != pos and v[w] != 'correct']
    trials_total += 1
    neighbour_fp += 1 if others else 0

print(f"{'error type':14s} {'trials':>6s} {'NEW detect':>11s} {'OLD detect':>11s}")
tn = tnew = told = 0
for k in KINDS:
    t, a, b = res[k]
    tn += t; tnew += a; told += b
    print(f"{k:14s} {t:6d} {a/t*100:10.1f}% {b/t*100:10.1f}%")
print(f"{'ALL':14s} {tn:6d} {tnew/tn*100:10.1f}% {told/tn*100:10.1f}%")
print('neighbour words wrongly flagged (error spill-over):', neighbour_fp, 'of', trials_total)

# ASR-noise stress: perfect recitation with random token-level errors
def noisy(seq, p):
    out = []
    for w in seq:
        cs = []
        for c in w:
            r = random.random()
            if r < p / 3: continue
            if r < 2 * p / 3: cs.append(random.choice(LET)); continue
            if r < p: cs.append(c); cs.append(random.choice(LET)); continue
            cs.append(c)
        out.append(''.join(cs))
    return out
for p in (0.0, 0.015, 0.03):
    flagged = total = 0
    for _ in range(600):
        n = 6; start = random.randrange(0, len(BASE) - n); seq = BASE[start:start + n]
        h = noisy(seq, p)
        ev = StrictEvaluator([WordT(i, 'x', q, ()) for i, q in enumerate(seq)])
        evs = stream(ev, ''.join(h))
        total += n; flagged += sum(1 for e in evs if e.verdict != 'correct')
    print(f"ASR char error {p*100:.1f}% -> correct words flagged: {flagged/total*100:.1f}%")
