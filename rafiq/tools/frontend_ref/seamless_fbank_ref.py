"""Python reference of the Muaalem-mini front-end (SeamlessM4TFeatureExtractor, as used by the
reference lab `mahmoodana1/quran-models/lab/worker.js` via preprocessor_config.json).
Pipeline (HF source): x*2^15 -> 25ms/10ms Povey-window Kaldi fbank (80 mel, preemph .97, DC removal,
FFT 512, log floor 1.19e-7) -> PER-WINDOW per-mel mean/var normalisation -> stack 2 frames => [1,T/2,160].
NOTE: normalisation is over the whole input window, so an incremental mel cache must renormalise
per window (cache raw log-mel, normalise at read time). `gen_golden.py` writes test/fixtures/fbank_golden.json.
"""
import json, sys
import numpy as np
from transformers import SeamlessM4TFeatureExtractor as F

def make():
    return F(feature_size=80, num_mel_bins=80, sampling_rate=16000, padding_value=1, stride=2,
             return_attention_mask=True)

def features(x: np.ndarray) -> np.ndarray:
    return make()(x.astype("float32"), sampling_rate=16000, return_tensors="np")["input_features"]

def synth(n: int = 16000) -> np.ndarray:
    t = np.arange(n) / 16000.0
    r = np.random.default_rng(7).standard_normal(n)
    return (0.3 * np.sin(2 * np.pi * 220 * t) + 0.1 * np.sin(2 * np.pi * 1330 * t) + 0.02 * r).astype("float32")

if __name__ == "__main__":
    x = synth()
    f = features(x)
    json.dump({"samples": 16000, "shape": list(f.shape), "signal_rule": "see synth()",
               "head": f[0, :3, :].round(6).tolist(), "tail": f[0, -2:, :].round(6).tolist(),
               "mean": float(f.mean()), "std": float(f.std())},
              open(sys.argv[1] if len(sys.argv) > 1 else "fbank_golden.json", "w"))
    print(f.shape)
