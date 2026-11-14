"""Export mel filters + Povey window from the HF extractor to little-endian float32 files (assets/frontend/)."""
import sys, os
import numpy as np
from seamless_fbank_ref import make
fe = make(); d = sys.argv[1]; os.makedirs(d, exist_ok=True)
np.asarray(fe.mel_filters, dtype="<f4").tofile(f"{d}/mel_filters_257x80.f32")
np.asarray(fe.window, dtype="<f4").tofile(f"{d}/povey_window_400.f32")
print(np.asarray(fe.mel_filters).shape, np.asarray(fe.window).shape)
