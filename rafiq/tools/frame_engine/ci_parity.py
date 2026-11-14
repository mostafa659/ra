#!/usr/bin/env python3
"""CI parity checks for the direct-ONNX frame engine (never needs a device).

1. fbank_ref.py against kaldi_native_fbank (the library sherpa-onnx uses).
2. Greedy tokens of stream_ref.OrtStream against sherpa-onnx on the same real
   recitation. Identical tokens = the recipe the Dart port copies is right.

    python3 tools/frame_engine/ci_parity.py --model assets/models/model.int8.onnx \
        --tokens assets/models/tokens.txt [--wav file.wav]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fbank_ref as fb  # noqa: E402

SAMPLE_URL = "https://everyayah.com/data/Alafasy_128kbps/112001.mp3"


def synthetic(n=16000):
    t = np.arange(n)
    return (0.3 * np.sin(2 * np.pi * 220 * t / 16000) + 0.2 * np.sin(2 * np.pi * 1370 * t / 16000 + 0.5)
            + 0.05 * np.sin(2 * np.pi * 3100 * t / 16000)).astype(np.float32)


def fbank_parity():
    import kaldi_native_fbank as knf

    opts = knf.FbankOptions()
    opts.frame_opts.dither = 0
    opts.frame_opts.snip_edges = False
    opts.frame_opts.samp_freq = 16000
    opts.frame_opts.window_type = "povey"
    opts.frame_opts.remove_dc_offset = True
    opts.mel_opts.num_bins = 80
    opts.mel_opts.low_freq = 20
    opts.mel_opts.high_freq = -400
    opts.energy_floor = 0
    online = knf.OnlineFbank(opts)
    samples = synthetic()
    online.accept_waveform(16000, samples.tolist())  # normalize_samples=true: no scaling
    theirs = np.array([online.get_frame(i) for i in range(online.num_frames_ready)])
    mine = np.array(fb.KaldiFbank().accept(samples))
    count = min(len(theirs), len(mine))
    diff = float(np.abs(theirs[:count] - mine[:count]).max())
    return {"frames_compared": count, "frames_theirs": len(theirs), "frames_mine": len(mine), "max_abs_diff": diff}


def load_wav(path):
    with wave.open(path, "rb") as handle:
        assert handle.getframerate() == 16000 and handle.getnchannels() == 1, "need 16 kHz mono"
        raw = handle.readframes(handle.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def fetch_sample(workdir):
    mp3 = os.path.join(workdir, "sample.mp3")
    wav = os.path.join(workdir, "sample.wav")
    urllib.request.urlretrieve(SAMPLE_URL, mp3)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp3, "-ar", "16000", "-ac", "1", wav], check=True)
    return wav


def sherpa_tokens(model, tokens, samples):
    import sherpa_onnx

    rec = sherpa_onnx.OnlineRecognizer.from_zipformer2_ctc(
        tokens=tokens, model=model, num_threads=1, sample_rate=16000, feature_dim=80,
        enable_endpoint_detection=False, decoding_method="greedy_search",
    )
    stream = rec.create_stream()
    stream.accept_waveform(16000, samples)
    stream.accept_waveform(16000, np.zeros(19200, dtype=np.float32))
    stream.input_finished()
    while rec.is_ready(stream):
        rec.decode_stream(stream)
    result = rec.get_result_all(stream) if hasattr(rec, "get_result_all") else None
    return list(result.tokens) if result is not None else list(rec.get_result(stream))


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def model_parity(model, tokens, wav):
    from stream_ref import OrtStream

    samples = load_wav(wav)
    reference = sherpa_tokens(model, tokens, samples)
    report = {"audio_seconds": round(len(samples) / 16000, 2), "sherpa_tokens": len(reference)}
    for scale in (1.0, 32768.0):
        runner = OrtStream(model, tokens, scale=scale)
        for i in range(0, len(samples), 3840):
            runner.accept(samples[i:i + 3840])
        runner.finish()
        mine = runner.token_list
        report["scale_%g" % scale] = {
            "tokens": len(mine), "identical": mine == reference,
            "edit_distance": edit_distance(mine, reference),
        }
    return report


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="assets/models/model.int8.onnx")
    parser.add_argument("--tokens", default="assets/models/tokens.txt")
    parser.add_argument("--wav")
    parser.add_argument("--out", default="model_contract")
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    report, failed = {}, False
    try:
        report["fbank"] = fbank_parity()
        failed |= report["fbank"]["max_abs_diff"] > 0.05
    except Exception as error:  # noqa: BLE001
        report["fbank"] = {"error": "%s: %s" % (type(error).__name__, error)}
    try:
        wav = args.wav or fetch_sample(tempfile.mkdtemp())
        report["model"] = model_parity(args.model, args.tokens, wav)
        failed |= not report["model"].get("scale_1", {}).get("identical", False)
    except Exception as error:  # noqa: BLE001
        report["model"] = {"error": "%s: %s" % (type(error).__name__, error)}
    text = json.dumps(report, ensure_ascii=False, indent=2)
    print(text)
    with open(os.path.join(args.out, "parity.json"), "w", encoding="utf-8") as handle:
        handle.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Frame engine parity\n```json\n" + text + "\n```\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
