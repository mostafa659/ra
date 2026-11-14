"""Reference for the Dart FinalVowelProbe: an acoustic check of a short vowel that does not use the
recognizer at all.

Why: the phoneme model was trained on correct recitation and "writes the rule instead of the
deviation" (its model card), and it leans on sentence context exactly for the vowel that ends a
word. Whatever probability it reports for kayfu vs kayfa is therefore biased toward the reference.
Fatha, kasra and damma, however, differ physically in the first two formants (F1 high for fatha;
F2 high for kasra, low for damma), and that is measurable on the audio itself.

Pipeline: pre-emphasis -> 25 ms frames every 10 ms -> voiced test (energy + periodicity) ->
LPC (order 12, Levinson-Durbin) -> peaks of the LPC envelope on a fixed grid -> median F1/F2 over
the central voiced frames. A speaker's own vowels in the same ayah (reference known, aligned) give
the centroids; a population prior shifted by the speaker's own mean offset fills missing ones.
Classification happens in log-frequency, where a longer or shorter vocal tract is a translation.
"""
import math

SR = 16000
FRAME = 400
HOP = 160
ORDER = 16
PRE = 0.97
VOICED_ENERGY = 0.10      # of the segment's loudest frame
VOICED_PERIODICITY = 0.35  # normalized autocorrelation peak, lags for 40-320 Hz
LAG_MIN, LAG_MAX = 50, 400
GRID_LO, GRID_HI, GRID_STEP = 150.0, 4000.0, 25.0
F1_RANGE = (200.0, 1100.0)
F2_MIN_GAP, F2_MAX = 100.0, 3300.0
MIN_FRAMES = 2

# population priors (Hz): fatha, damma, kasra
PRIOR = {"a": (700.0, 1250.0), "u": (380.0, 900.0), "i": (350.0, 2200.0)}
MARKS = {"\u064e": "a", "\u064f": "u", "\u0650": "i"}
MIN_ANCHORS = 3
WARN_GAP = 0.12   # log units (about 12 %)
HARD_GAP = 0.30


def _hamming(n):
    return [0.54 - 0.46 * math.cos(2.0 * math.pi * i / (n - 1)) for i in range(n)]


_WINDOW = _hamming(FRAME)


def _frames(samples):
    pre = [samples[0]] + [samples[i] - PRE * samples[i - 1] for i in range(1, len(samples))] if samples else []
    out = []
    start = 0
    while start + FRAME <= len(pre):
        out.append((pre[start:start + FRAME], samples[start:start + FRAME]))
        start += HOP
    return out


def _autocorr(x, lags):
    n = len(x)
    return [sum(x[i] * x[i + k] for i in range(n - k)) for k in range(lags + 1)]


def _levinson(r, order):
    a = [1.0] + [0.0] * order
    err = r[0]
    if err <= 0:
        return None
    for i in range(1, order + 1):
        acc = r[i] + sum(a[j] * r[i - j] for j in range(1, i))
        k = -acc / err
        nxt = a[:]
        for j in range(1, i):
            nxt[j] = a[j] + k * a[i - j]
        nxt[i] = k
        a = nxt
        err *= (1.0 - k * k)
        if err <= 0:
            return None
    return a


def _poly_roots(a):
    """Roots of z^n + a1 z^(n-1) + ... + an by Durand-Kerner (fixed start, fixed sweeps: the Dart
    port repeats exactly this)."""
    n = len(a) - 1
    zs = [(0.4 + 0.9j) ** k for k in range(n)]
    for _ in range(200):
        moved = 0.0
        for i in range(n):
            value = 1.0 + 0j
            for k in range(1, n + 1):
                value = value * zs[i] + a[k]
            denom = 1.0 + 0j
            for j in range(n):
                if j != i:
                    denom *= (zs[i] - zs[j])
            if abs(denom) < 1e-30:
                continue
            step = value / denom
            zs[i] -= step
            moved = max(moved, abs(step))
        if moved < 1e-10:
            break
    return zs


def _envelope_peaks(a):
    """F1 and F2 from the LPC poles: close formants (fatha: F1 and F2 near each other) stay apart as
    poles although their envelope merges into one peak."""
    found = []
    for z in _poly_roots(a):
        if z.imag <= 0.01:
            continue
        freq = math.atan2(z.imag, z.real) * SR / (2.0 * math.pi)
        radius = abs(z)
        if radius <= 0.0 or radius >= 1.0:
            continue
        bandwidth = -math.log(radius) * SR / math.pi
        if GRID_LO <= freq <= GRID_HI and bandwidth < 800.0:
            found.append(freq)
    found.sort()
    f1 = next((p for p in found if F1_RANGE[0] <= p <= F1_RANGE[1]), None)
    if f1 is None:
        return None
    f2 = next((p for p in found if p >= f1 + F2_MIN_GAP and p <= F2_MAX), None)
    if f2 is None:
        return None
    return f1, f2


def _median(values):
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2.0


def estimate_formants(samples):
    """samples: floats in -1..1 at 16 kHz. Returns (F1, F2, voiced_frames_used) or None."""
    frames = _frames(list(samples))
    if not frames:
        return None
    energies = [sum(v * v for v in raw) / FRAME for _, raw in frames]
    loudest = max(energies)
    if loudest <= 1e-10:
        return None
    valid = []
    for (pre, raw), energy in zip(frames, energies):
        if energy < VOICED_ENERGY * loudest:
            continue
        windowed = [raw[i] * _WINDOW[i] for i in range(FRAME)]
        r = _autocorr(windowed, LAG_MAX)
        if r[0] <= 0 or max(r[LAG_MIN:LAG_MAX + 1]) / r[0] < VOICED_PERIODICITY:
            continue
        w2 = [pre[i] * _WINDOW[i] for i in range(FRAME)]
        lpc_r = _autocorr(w2, ORDER)
        lpc_r[0] = lpc_r[0] * 1.0001 + 1e-9
        a = _levinson(lpc_r, ORDER)
        if a is None:
            continue
        peaks = _envelope_peaks(a)
        if peaks is not None:
            valid.append(peaks)
    if len(valid) < MIN_FRAMES:
        return None
    if len(valid) >= 5:
        cut = len(valid) // 5
        valid = valid[cut:len(valid) - cut]
    return _median([v[0] for v in valid]), _median([v[1] for v in valid]), len(valid)


def _log2d(p):
    return math.log(p[0]), math.log(p[1])


def classify(anchors, observed, expected):
    """anchors: {"a"|"u"|"i": [(F1, F2), ...]} of the same speaker's other vowels in the ayah.
    observed: (F1, F2) of the vowel under test. expected: "a" | "u" | "i".
    Returns dict(status, nearest, gap, d_expected, d_nearest, severity)."""
    total = sum(len(v) for v in anchors.values())
    if total < MIN_ANCHORS:
        return dict(status="no_anchors", nearest=expected, gap=0.0, d_expected=0.0, d_nearest=0.0, severity=0)
    offsets1, offsets2 = [], []
    for vowel, items in anchors.items():
        for item in items:
            l1, l2 = _log2d(item)
            p1, p2 = _log2d(PRIOR[vowel])
            offsets1.append(l1 - p1)
            offsets2.append(l2 - p2)
    shift = (_median(offsets1), _median(offsets2))
    centroids = {}
    for vowel in PRIOR:
        items = anchors.get(vowel, [])
        if len(items) >= 2:
            centroids[vowel] = (_median([_log2d(i)[0] for i in items]), _median([_log2d(i)[1] for i in items]))
        else:
            p = _log2d(PRIOR[vowel])
            centroids[vowel] = (p[0] + shift[0], p[1] + shift[1])
    x = _log2d(observed)
    dist = {v: math.hypot(x[0] - c[0], x[1] - c[1]) for v, c in centroids.items()}
    nearest = min(dist, key=lambda v: dist[v])
    gap = dist[expected] - dist[nearest]
    severity = 0
    if nearest != expected:
        if gap >= HARD_GAP:
            severity = 2
        elif gap >= WARN_GAP:
            severity = 1
    return dict(status="ok", nearest=nearest, gap=gap, d_expected=dist[expected], d_nearest=dist[nearest],
                severity=severity)
