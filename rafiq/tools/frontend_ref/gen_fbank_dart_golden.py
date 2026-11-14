"""Golden for the Dart front-end: deterministic synthetic signal (no RNG) -> numpy-mirror features.
Dart builds the same signal with integer LCG arithmetic and must match within 2e-3."""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fbank_numpy as n
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def signal(N: int) -> np.ndarray:
    i = np.arange(N, dtype="float64")
    lcg = (i * 1103515245 + 12345) % 2147483648
    x = 0.3 * np.sin(2 * np.pi * 220 * i / 16000) + 0.1 * np.sin(2 * np.pi * 1330 * i / 16000) + 0.02 * (lcg / 2147483648 - 0.5)
    return x.astype("float32")

mel, win = n.load_constants(os.path.join(ROOT, "assets/frontend"))
out = {}
for N in (16000, 16160):  # even and odd frame counts (odd => HF pads one row of 1.0)
    f = n.finish(n.log_mel(signal(N), mel, win))
    out[str(N)] = {"shape": list(f.shape), "rows": np.round(f[0], 5).tolist()}
json.dump({"signal": "x[i]=0.3 sin(2pi 220 i/16000)+0.1 sin(2pi 1330 i/16000)+0.02((i*1103515245+12345 mod 2^31)/2^31-0.5)", "cases": out},
          open(os.path.join(ROOT, "test/fixtures/fbank_dart_golden.json"), "w"))
print({k: v["shape"] for k, v in out.items()})
