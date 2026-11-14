#!/usr/bin/env python3
"""Fetch + verify the Muaalem-mini ONNX pack (public, no token). AGPL-3.0 weights.

Usage: fetch_muaalem.py [--variant q8|q4] [--out assets/models]
Fails loudly (non-zero exit) on any size/SHA-256 mismatch. No fallback to another model:
q4 is only used when the caller explicitly passes --variant q4 (ladder step after Gate G1).
"""
import argparse, hashlib, json, sys, urllib.request
BASE = "https://raw.githubusercontent.com/mahmoodana1/quran-models/main/"
EXTRA = ["muaalem/phoneme_vocab.json", "muaalem/preprocessor_config.json", "muaalem/NOTICE.md"]

def get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()

def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="q8", choices=["q8", "q4"])
    ap.add_argument("--out", default="assets/models")
    a = ap.parse_args()
    import os
    os.makedirs(a.out, exist_ok=True)
    man = json.loads(get(BASE + "muaalem/manifest.json"))
    v = man["variants"][a.variant]
    blob = bytearray()
    for p in v["parts"]:
        d = get(BASE + p["path"])
        if len(d) != p["bytes"] or sha(d) != p["sha256"]:
            print(f"FATAL: part {p['path']} failed size/SHA-256 check", file=sys.stderr)
            return 1
        blob += d
    if len(blob) != v["bytes"] or sha(bytes(blob)) != v["sha256"]:
        print("FATAL: joined model failed size/SHA-256 check", file=sys.stderr)
        return 1
    open(f"{a.out}/muaalem_{a.variant}.onnx", "wb").write(blob)
    for f in EXTRA:
        open(f"{a.out}/{os.path.basename(f)}", "wb").write(get(BASE + f))
    json.dump({"model": man["model"], "variant": a.variant, "file": f"muaalem_{a.variant}.onnx",
               "bytes": v["bytes"], "sha256": v["sha256"], "parts": v["parts"],
               "license": "AGPL-3.0 (weights); see NOTICE.md"},
              open(f"{a.out}/model_manifest.json", "w"), indent=1)
    print("OK", a.variant, v["sha256"])
    return 0

if __name__ == "__main__":
    sys.exit(main())
