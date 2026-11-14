"""Dependency-free (numpy only) mirror of SeamlessM4TFeatureExtractor, i.e. exactly what the Dart port does.
Needs two constants exported once from HF: mel filters [257,80] and the Povey window [400] (see export_constants.py)."""
import numpy as np

def load_constants(d):
    mel = np.fromfile(f"{d}/mel_filters_257x80.f32", dtype="<f4").reshape(257, 80).astype("float64")
    win = np.fromfile(f"{d}/povey_window_400.f32", dtype="<f4").astype("float64")
    return mel, win

def log_mel(x: np.ndarray, mel: np.ndarray, win: np.ndarray) -> np.ndarray:
    """x: float waveform in [-1,1] -> raw log-mel [frames,80] (BEFORE per-window normalisation)."""
    w = x.astype("float64") * 32768.0
    n = 1 + (len(w) - 400) // 160
    out = np.empty((n, 80))
    for i in range(n):
        f = w[i * 160: i * 160 + 400].copy()
        f -= f.mean()                       # remove_dc_offset
        f = np.concatenate(([f[0] * (1 - 0.97)], f[1:] - 0.97 * f[:-1]))  # preemphasis 0.97
        f *= win
        p = np.abs(np.fft.rfft(f, 512)) ** 2
        out[i] = np.log(np.maximum(p @ mel, 1.192092955078125e-07))
    return out

def finish(lm: np.ndarray, stride: int = 2, pad_value: float = 1.0) -> np.ndarray:
    """Per-mel-bin zero-mean/unit-variance over the WHOLE window (variance ddof=1, as HF), pad an odd frame count
    with one row of `pad_value` (HF: pad_to_multiple_of=stride, padding_value=1), stack `stride` frames -> [1,ceil(T/2),160]."""
    f = (lm - lm.mean(0)) / np.sqrt(lm.var(0, ddof=1) + 1e-7)
    if len(f) % stride:
        f = np.vstack([f, np.full((stride - len(f) % stride, f.shape[1]), pad_value)])
    return f.reshape(1, len(f) // stride, f.shape[1] * stride).astype("float32")
