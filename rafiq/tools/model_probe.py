#!/usr/bin/env python3
"""Dump the exact ONNX contract of the pinned Quran-Lab streaming model.

Why this exists
---------------
The model's authors state that it was trained almost entirely on correct
recitation and tends to transcribe the rule instead of a deviation, so decoded
text alone cannot judge ikhfaa/ghunna/qalqalah or madd length. They recommend
frame-level confidence margins and forced-alignment timing instead, which need
the CTC log-probabilities. sherpa-onnx does not expose those for streaming CTC
models, so the next step is a direct ONNX path. Before any of that code is
written, the facts it must match (input/output names, dtypes, shapes, metadata,
chunking, whether log_probs are normalised) have to come from the real file in
CI rather than from memory. This script prints and records them.

Usage
-----
    python3 tools/model_probe.py --model assets/models/model.int8.onnx \
        --out model_contract [--fetch-authors-scripts]

It never fails the build: problems are reported as warnings and a partial
contract.json is still written.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "frame_engine"))
from collections import Counter, OrderedDict
from pathlib import Path

REPOSITORY = "Quran-Lab/zipformer_p-arabic-v3"
AUTHOR_FILES = ("decode_with_confidence.py", "quran_per_eval.py", "README.md")


# ----------------------------------------------------------------- pure helpers
def family(name: str) -> str:
    """cached_key_12 -> cached_key; names without a layer index are unchanged."""
    return re.sub(r"_\d+$", "", name)


def summarize_inputs(inputs: list[dict]) -> "OrderedDict[str, int]":
    """Counts the state tensors per family (the first input, the features, is skipped)."""
    counts: Counter = Counter(family(i["name"]) for i in inputs[1:])
    return OrderedDict(sorted(counts.items()))


def map_outputs(input_names: list[str], output_names: list[str]) -> dict:
    """Pairs every state input with the output that carries its next value.

    Streaming exports name them ``new_<input>``; if that does not hold the
    position (outputs[1:] follow inputs[1:]) is used and flagged as a guess.
    """
    state_inputs = input_names[1:]
    by_name = {}
    for name in state_inputs:
        candidate = f"new_{name}"
        if candidate in output_names:
            by_name[name] = candidate
    if len(by_name) == len(state_inputs):
        return {"by": "name", "pairs": by_name, "unmatched": []}
    state_outputs = output_names[1:]
    if len(state_outputs) == len(state_inputs):
        return {
            "by": "position (GUESS - verify against the authors' loop)",
            "pairs": dict(zip(state_inputs, state_outputs)),
            "unmatched": [],
        }
    return {
        "by": "none",
        "pairs": by_name,
        "unmatched": [n for n in state_inputs if n not in by_name],
    }


def numpy_dtype(onnx_type: str) -> str:
    table = {
        "tensor(float)": "float32",
        "tensor(float16)": "float16",
        "tensor(double)": "float64",
        "tensor(int64)": "int64",
        "tensor(int32)": "int32",
        "tensor(bool)": "bool",
    }
    return table.get(onnx_type, "float32")


def concrete_shape(shape: list) -> list[int]:
    """Replaces dynamic/unknown dimensions (names or None) by 1."""
    return [d if isinstance(d, int) and d > 0 else 1 for d in shape]


# --------------------------------------------------------------- ORT inspection
def describe(model_path: str) -> dict:
    import onnxruntime as ort  # imported here so the pure helpers stay testable

    options = ort.SessionOptions()
    options.log_severity_level = 3
    session = ort.InferenceSession(
        model_path, options, providers=["CPUExecutionProvider"]
    )
    inputs = [
        {"name": i.name, "type": i.type, "shape": list(i.shape)}
        for i in session.get_inputs()
    ]
    outputs = [
        {"name": o.name, "type": o.type, "shape": list(o.shape)}
        for o in session.get_outputs()
    ]
    meta = session.get_modelmeta()
    contract = {
        "onnxruntime": ort.__version__,
        "model_path": model_path,
        "model_bytes": os.path.getsize(model_path),
        "inputs": inputs,
        "outputs": outputs,
        "metadata": dict(meta.custom_metadata_map or {}),
        "state_families": summarize_inputs(inputs),
        "output_mapping": map_outputs(
            [i["name"] for i in inputs], [o["name"] for o in outputs]
        ),
    }
    contract["parser_check"] = parser_check(model_path, inputs, outputs)
    contract["_session"] = session
    return contract


def parser_check(model_path: str, inputs: list, outputs: list) -> dict:
    """The Dart app reads the contract from the file; it must equal onnxruntime's view."""
    problems = []
    try:
        import onnx_contract

        with open(model_path, "rb") as handle:
            parsed = onnx_contract.parse_contract(handle.read())
        elem = {"tensor(float)": 1, "tensor(int32)": 6, "tensor(int64)": 7}
        for side, mine, theirs in (("inputs", parsed["inputs"], inputs), ("outputs", parsed["outputs"], outputs)):
            if [m["name"] for m in mine] != [t["name"] for t in theirs]:
                problems.append(f"{side}: names differ")
                continue
            for m, t in zip(mine, theirs):
                static = [d for d in t["shape"] if isinstance(d, int)]
                if [d for d in m["dims"] if d > 0] != static:
                    problems.append(f"{side} {m['name']}: dims {m['dims']} vs {t['shape']}")
                if elem.get(t["type"], m["elem_type"]) != m["elem_type"]:
                    problems.append(f"{side} {m['name']}: type {m['elem_type']} vs {t['type']}")
    except Exception as error:  # noqa: BLE001
        problems.append(f"{type(error).__name__}: {error}")
    return {"ok": not problems, "problems": problems}


def smoke_run(contract: dict) -> dict:
    """Two chained chunks on silence: checks shapes, state feedback and normalisation."""
    import numpy as np

    session = contract.pop("_session")
    inputs = contract["inputs"]
    feeds = {}
    for spec in inputs:
        shape = concrete_shape(spec["shape"])
        feeds[spec["name"]] = np.zeros(shape, dtype=numpy_dtype(spec["type"]))
    # A dynamic time axis would be fed as 1 frame; prefer the chunk window the
    # export records in its metadata (sherpa calls it T).
    window = str(contract.get("metadata", {}).get("T", "")).strip()
    first = inputs[0]
    if window.isdigit() and len(first["shape"]) == 3 and not isinstance(first["shape"][1], int):
        feeds[first["name"]] = np.zeros(
            [1, int(window), concrete_shape(first["shape"])[2]],
            dtype=numpy_dtype(first["type"]),
        )
    out_names = [o["name"] for o in contract["outputs"]]
    result = {"ok": False}
    try:
        timings = []
        for step in range(2):
            started = time.perf_counter()
            values = session.run(out_names, feeds)
            timings.append(round((time.perf_counter() - started) * 1000.0, 1))
            log_probs = np.asarray(values[0], dtype=np.float64)
            if step == 0:
                result["log_probs_shape"] = list(log_probs.shape)
                shifted = log_probs - log_probs.max(axis=-1, keepdims=True)
                lse = log_probs.max(axis=-1) + np.log(np.exp(shifted).sum(axis=-1))
                result["log_probs_logsumexp_max_abs"] = float(np.abs(lse).max())
                result["log_probs_are_normalised"] = bool(np.abs(lse).max() < 1e-3)
                result["blank_class_guess"] = int(log_probs.shape[-1] - 1)
            pairs = contract["output_mapping"]["pairs"]
            for state_name, out_name in pairs.items():
                feeds[state_name] = values[out_names.index(out_name)]
        result["chunk_ms_cpu"] = timings
        result["ok"] = True
    except Exception as error:  # noqa: BLE001 - report, never fail the build
        result["error"] = f"{type(error).__name__}: {error}"
    return result


# ------------------------------------------------------------------ author files
def fetch_authors_files(revision: str, token: str, out_dir: Path) -> dict:
    status = {}
    target = out_dir / "authors"
    target.mkdir(parents=True, exist_ok=True)
    for name in AUTHOR_FILES:
        url = f"https://huggingface.co/{REPOSITORY}/resolve/{revision or 'main'}/{name}"
        request = urllib.request.Request(url)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                (target / name).write_bytes(response.read())
            status[name] = "downloaded"
        except Exception as error:  # noqa: BLE001
            status[name] = f"unavailable ({type(error).__name__}: {error})"
    return status


# ---------------------------------------------------------------------- reporting
def markdown(contract: dict) -> str:
    inputs = contract.get("inputs", [])
    lines = [
        "### Rafiq model contract",
        "",
        f"- onnxruntime {contract.get('onnxruntime')}, "
        f"{contract.get('model_bytes', 0) / 1e6:.1f} MB",
        f"- inputs: {len(inputs)}, outputs: {len(contract.get('outputs', []))}",
        f"- feature input: `{inputs[0]['name']}` {inputs[0]['shape']} "
        f"{inputs[0]['type']}" if inputs else "- no inputs found",
        f"- output mapping: {contract.get('output_mapping', {}).get('by')}",
        f"- metadata: `{json.dumps(contract.get('metadata', {}), ensure_ascii=False)}`",
        f"- state families: `{json.dumps(contract.get('state_families', {}))}`",
        f"- smoke run: `{json.dumps(contract.get('smoke', {}), ensure_ascii=False)}`",
        f"- Dart contract parser vs onnxruntime: `{json.dumps(contract.get('parser_check', {}), ensure_ascii=False)}`",
        f"- authors' files: `{json.dumps(contract.get('authors_files', {}))}`",
    ]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model", default="assets/models/model.int8.onnx")
    parser.add_argument("--out", default="model_contract")
    parser.add_argument("--fetch-authors-scripts", action="store_true")
    args = parser.parse_args(argv)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    contract: dict = {}
    try:
        contract = describe(args.model)
        contract["smoke"] = smoke_run(contract)
    except Exception as error:  # noqa: BLE001
        contract["error"] = f"{type(error).__name__}: {error}"
        print(f"::warning::model probe failed: {contract['error']}")
    contract.pop("_session", None)

    if args.fetch_authors_scripts:
        contract["authors_files"] = fetch_authors_files(
            os.environ.get("QURAN_LAB_REVISION", "").strip(),
            os.environ.get("HF_TOKEN", "").strip(),
            out_dir,
        )

    (out_dir / "contract.json").write_text(
        json.dumps(contract, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    report = markdown(contract)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
