"""Kaldi-compatible 80-bin log-mel filterbank, structured like the Dart port.

Matches kaldi-native-fbank as sherpa-onnx configures it for this model:
16 kHz, 25 ms frames / 10 ms shift, snip_edges=false (centred frames with
reflection at the start), DC removal, pre-emphasis 0.97, povey window, 512-point
power spectrum, 80 mel bins from 20 Hz to Nyquist-400 Hz, natural log with a
float32-epsilon floor. Samples arrive as floats in [-1, 1] and are used AS IS:
sherpa-onnx scales by 32768 only when normalize_samples=false (paraformer);
zipformer models, this one included, run with the default normalize_samples=true.
Scaling by 32768 anyway shifts every log-mel value by about +20.8 and makes the
model emit garbage (this was the 0.6.0/0.6.1 bug). CI compares this file with
kaldi_native_fbank and the tokens with sherpa-onnx (tools/frame_engine/ci_parity.py).
"""
import math

FRAME_LENGTH = 400
FRAME_SHIFT = 160
PADDED = 512
NUM_BINS = 80
LOW_FREQ = 20.0
HIGH_FREQ = -400.0
PREEMPH = 0.97
EPSILON = 1.1920928955078125e-07
SAMPLE_RATE = 16000.0


def mel_scale(freq):
    return 1127.0 * math.log(1.0 + freq / 700.0)


def build_banks():
    """Per bin: (first fft index, [weights]) over the 256 usable fft bins."""
    nyquist = SAMPLE_RATE / 2.0
    high = HIGH_FREQ + nyquist if HIGH_FREQ <= 0 else HIGH_FREQ
    fft_bins = PADDED // 2
    bin_width = SAMPLE_RATE / PADDED
    mel_low, mel_high = mel_scale(LOW_FREQ), mel_scale(high)
    delta = (mel_high - mel_low) / (NUM_BINS + 1)
    banks = []
    for b in range(NUM_BINS):
        left = mel_low + b * delta
        center = mel_low + (b + 1) * delta
        right = mel_low + (b + 2) * delta
        first, weights = -1, []
        for i in range(fft_bins):
            mel = mel_scale(bin_width * i)
            if left < mel < right:
                w = (mel - left) / (center - left) if mel <= center else (right - mel) / (right - center)
                if first < 0:
                    first = i
                weights.append(w)
        banks.append((first, weights))
    return banks


def povey_window():
    return [
        math.pow(0.5 - 0.5 * math.cos(2.0 * math.pi * i / (FRAME_LENGTH - 1)), 0.85)
        for i in range(FRAME_LENGTH)
    ]


def _bit_reverse_table(n):
    bits = n.bit_length() - 1
    table = []
    for i in range(n):
        r = 0
        for b in range(bits):
            if i & (1 << b):
                r |= 1 << (bits - 1 - b)
        table.append(r)
    return table


_REV = _bit_reverse_table(PADDED)
_COS = [math.cos(2.0 * math.pi * k / PADDED) for k in range(PADDED // 2)]
_SIN = [math.sin(2.0 * math.pi * k / PADDED) for k in range(PADDED // 2)]


def fft_radix2(re, im):
    """In-place iterative radix-2 FFT over PADDED points (the Dart code is this)."""
    n = PADDED
    for i in range(n):
        j = _REV[i]
        if j > i:
            re[i], re[j] = re[j], re[i]
            im[i], im[j] = im[j], im[i]
    length = 2
    while length <= n:
        half = length >> 1
        step = n // length
        for i in range(0, n, length):
            for k in range(half):
                wr = _COS[k * step]
                wi = -_SIN[k * step]
                a = i + k
                b = a + half
                tr = re[b] * wr - im[b] * wi
                ti = re[b] * wi + im[b] * wr
                re[b] = re[a] - tr
                im[b] = im[a] - ti
                re[a] += tr
                im[a] += ti
        length <<= 1


def frames_ready(num_samples):
    """Frames whose whole 400-sample window lies inside the received samples."""
    count = (num_samples + FRAME_SHIFT // 2) // FRAME_SHIFT
    end = (count - 1) * FRAME_SHIFT - 120 + FRAME_LENGTH
    while count > 0 and end > num_samples:
        count -= 1
        end -= FRAME_SHIFT
    return max(count, 0)


class KaldiFbank:
    def __init__(self, scale=1.0):
        self.scale = scale
        self.banks = build_banks()
        self.window = povey_window()
        self.buf = []          # samples (already scaled), rolling
        self.buf_start = 0     # absolute index of buf[0]
        self.total = 0
        self.next_frame = 0

    def accept(self, samples):
        """Returns the newly completed feature frames (lists of 80 floats)."""
        self.buf.extend(float(s) * self.scale for s in samples)
        self.total += len(samples)
        ready = frames_ready(self.total)
        frames = []
        while self.next_frame < ready:
            frames.append(self._compute(self.next_frame))
            self.next_frame += 1
        keep_from = max(self.next_frame * FRAME_SHIFT - 120, 0)
        drop = keep_from - self.buf_start
        if drop > 0:
            del self.buf[:drop]
            self.buf_start = keep_from
        return frames

    def _compute(self, frame):
        start = frame * FRAME_SHIFT - 120
        x = []
        for i in range(FRAME_LENGTH):
            idx = start + i
            if idx < 0:
                idx = -idx - 1
            x.append(self.buf[idx - self.buf_start])
        mean = sum(x) / FRAME_LENGTH
        x = [v - mean for v in x]
        y = [0.0] * FRAME_LENGTH
        y[0] = x[0] - PREEMPH * x[0]
        for i in range(1, FRAME_LENGTH):
            y[i] = x[i] - PREEMPH * x[i - 1]
        re = [y[i] * self.window[i] for i in range(FRAME_LENGTH)] + [0.0] * (PADDED - FRAME_LENGTH)
        im = [0.0] * PADDED
        fft_radix2(re, im)
        power = [re[i] * re[i] + im[i] * im[i] for i in range(PADDED // 2)]
        out = []
        for first, weights in self.banks:
            energy = 0.0
            for k, w in enumerate(weights):
                energy += w * power[first + k]
            out.append(math.log(max(energy, EPSILON)))
        return out


def reference_features(samples, scale=1.0):
    """Independent numpy implementation (no rolling buffer, library FFT)."""
    import numpy as np

    x = np.asarray(samples, dtype=np.float64) * scale
    n = len(x)
    count = frames_ready(n)
    window = np.array(povey_window())
    banks = np.zeros((NUM_BINS, PADDED // 2))
    for b, (first, weights) in enumerate(build_banks()):
        banks[b, first:first + len(weights)] = weights
    out = np.zeros((count, NUM_BINS))
    for f in range(count):
        start = f * FRAME_SHIFT - 120
        idx = np.arange(start, start + FRAME_LENGTH)
        idx = np.where(idx < 0, -idx - 1, idx)
        w = x[idx]
        w = w - w.mean()
        w = np.concatenate([[w[0] - PREEMPH * w[0]], w[1:] - PREEMPH * w[:-1]])
        spec = np.abs(np.fft.rfft(w * window, n=PADDED)) ** 2
        out[f] = np.log(np.maximum(banks @ spec[:PADDED // 2], EPSILON))
    return out
