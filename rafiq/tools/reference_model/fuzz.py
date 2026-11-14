import random, sys, io, contextlib, time
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
with contextlib.redirect_stdout(io.StringIO()):
    import sim
from strict_eval import *

random.seed(2024)
ALPHA = list("ءبتثجحخدذرزسشصضطظعغفقكلمنهويا") + ['\u064E', '\u064F', '\u0650', 'ۥ', 'ۦ', 'ں']
t0 = time.time()
bad = 0
for trial in range(6000):
    n = random.randint(1, 8)
    seq = random.sample(sim.BASE, n)
    mode = random.choice(['recite', 'memorize'])
    strictness = random.choice(['strict', 'balanced'])
    ev = StrictEvaluator([WordT(i, 'ٱ' if random.random() < .2 else 'x', p, ()) for i, p in enumerate(seq)], mode=mode, strictness=strictness)
    # hypothesis: mixture of the expected words (with random edits) and noise, delivered in random chunks
    h = ''
    for p in seq:
        r = random.random()
        if r < .6: h += p
        elif r < .8: h += ''.join(random.choice(ALPHA) for _ in range(random.randint(1, 8)))
        elif r < .9: h += p[:max(1, len(p) // 2)]
    chars = list(h)
    seen = set(); last_cursor = 0
    pos = 0
    ok = True
    while pos < len(chars):
        pos = min(len(chars), pos + random.randint(1, 6))
        txt = ''.join(chars[:pos])
        stable = random.random() < .2
        try:
            evs = ev.update(txt, None, None, stable=stable)
        except Exception as ex:
            print('EXC', repr(ex), seq, h); ok = False; break
        for e in evs:
            if e.advanced:
                if e.word in seen: print('DUP verdict', e.word); ok = False
                seen.add(e.word)
        if ev.cursor < last_cursor or ev.consumed > len(txt):
            print('STATE', ev.cursor, ev.consumed, len(txt)); ok = False
        last_cursor = ev.cursor
    try:
        evs = ev.finish(h, None, None)
    except Exception as ex:
        print('EXC final', repr(ex), seq, h); ok = False
    for e in evs:
        if e.advanced and e.word in seen: print('DUP verdict final', e.word); ok = False
        if e.advanced: seen.add(e.word)
    if not ok: bad += 1
print('trials 6000, failures', bad, 'time %.1fs' % (time.time() - t0))
