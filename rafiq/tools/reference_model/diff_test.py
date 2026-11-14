import random, sys, io, contextlib
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
with contextlib.redirect_stdout(io.StringIO()):
    import sim
import strict_eval as R
import dart_translit as DT

random.seed(99)
ALPHA = list("ءبتثجحخدذرزسشصضطظعغفقكلمنهويا") + ['\u064E', '\u064F', '\u0650', 'ۥ', 'ۦ', 'ں']

def runs_of(s):
    out, i = [], 0
    while i < len(s):
        j = i
        while j < len(s) and s[j] == s[i]: j += 1
        out.append(s[i:j]); i = j
    return out

def drive(make, seq, hyp, mode, strictness, chunks, stables, with_times):
    ev = make(seq, mode, strictness)
    out = []
    pos = 0
    rs = runs_of(hyp)
    k = 0
    toks, tms = [], []
    t = 0.0
    for idx, r in enumerate(rs):
        toks.append(r); tms.append(t); t += 0.2 + (0.7 if idx in chunks else 0.0)
        st = idx in stables
        evs = ev.update(''.join(toks), list(toks), list(tms) if with_times else None, stable=st) if make is mk_ref else ev.update(''.join(toks), list(toks), list(tms) if with_times else [], stable=st)
        out += [(e.word, e.verdict, e.advanced) for e in evs]
    evs = ev.finish(''.join(toks), list(toks), list(tms) if with_times else None) if make is mk_ref else ev.finish(''.join(toks), list(toks), list(tms) if with_times else [])
    out += [(e.word, e.verdict, e.advanced) for e in evs]
    return out, ev.cursor, ev.consumed

def mk_ref(seq, mode, strictness):
    return R.StrictEvaluator([R.WordT(i, 'ٱ' if i % 3 == 1 else 'x', p, ('madd_muttasil',) if i % 4 == 0 else ()) for i, p in enumerate(seq)], mode=mode, strictness=strictness)

def mk_dt(seq, mode, strictness):
    return DT.Evaluator([DT.Word(i, 'ٱ' if i % 3 == 1 else 'x', p, ('madd_muttasil',) if i % 4 == 0 else ()) for i, p in enumerate(seq)], mode=mode, strictness=strictness)

bad = 0
N = 3000
for trial in range(N):
    n = random.randint(2, 7)
    seq = random.sample(sim.BASE, n)
    hyp = ''
    for p in seq:
        r = random.random()
        if r < .55: hyp += p
        elif r < .7:
            m = sim.mutate(p, random.choice(sim.KINDS)); hyp += m if m else p
        elif r < .8: hyp += ''.join(random.choice(ALPHA) for _ in range(random.randint(1, 6)))
        elif r < .9: hyp += p[:max(1, len(p) // 2)]
    mode = random.choice(['recite', 'memorize']); st = random.choice(['strict', 'balanced'])
    nr = len(runs_of(hyp))
    chunks = {random.randrange(nr) for _ in range(2)} if nr else set()
    stables = {random.randrange(nr) for _ in range(2)} if nr and random.random() < .5 else set()
    wt = random.random() < .7
    a = drive(mk_ref, seq, hyp, mode, st, chunks, stables, wt)
    b = drive(mk_dt, seq, hyp, mode, st, chunks, stables, wt)
    if a != b:
        bad += 1
        if bad <= 3:
            print('DIVERGENCE', seq, hyp, mode, st); print(' ref', a); print(' dt ', b)
print('differential trials', N, 'divergences', bad)
