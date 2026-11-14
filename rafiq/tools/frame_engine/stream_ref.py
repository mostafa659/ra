"""Reference streaming runner: audio -> Kaldi features -> ONNX chunks -> greedy CTC.

The same loop as lib/core/audio_engine/frame/streaming_ctc_core.dart +
ort_chunk_model.dart, driven by the contract read from the model file. CI runs
it next to sherpa-onnx on the same audio (ci_parity.py): identical tokens mean
the Dart port is built on a verified recipe.
"""
import numpy as np

import fbank_ref as fb
import onnx_contract as oc

DTYPES = {oc.ELEM_FLOAT: np.float32, oc.ELEM_INT32: np.int32, oc.ELEM_INT64: np.int64}


def read_tokens(path):
    """tokens.txt lines are '<token> <id>'; returns (list by id, blank id)."""
    table = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            token, _, ident = line.rpartition(" ")
            table[int(ident)] = token
    tokens = [table[i] for i in range(len(table))]
    blank = next((i for i, t in enumerate(tokens) if "blk" in t.lower()), len(tokens) - 1)
    return tokens, blank


class OrtStream:
    def __init__(self, model_path, tokens_path, scale=1.0, threads=1):
        import onnxruntime as ort

        with open(model_path, "rb") as handle:
            self.contract = oc.parse_contract(handle.read())
        c = self.contract
        self.x_spec = c["inputs"][0]
        self.states = c["inputs"][1:]
        dims = self.x_spec["dims"]
        self.window = dims[1] if dims[1] > 0 else int(c["metadata"].get("T", 61))
        self.dim = dims[2] if dims[2] > 0 else 80
        self.hop = int(c["metadata"].get("decode_chunk_len", self.window - 13))
        out_names = [o["name"] for o in c["outputs"]]
        self.slots = []
        for i, spec in enumerate(self.states):
            idx = out_names.index("new_" + spec["name"]) if ("new_" + spec["name"]) in out_names else i + 1
            self.slots.append((spec["name"], idx))
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.log_severity_level = 3
        self.session = ort.InferenceSession(model_path, options, providers=["CPUExecutionProvider"])
        self.out_names = out_names
        self.tokens, self.blank = read_tokens(tokens_path)
        self.fbank = fb.KaldiFbank(scale=scale)
        self.reset()

    def _zero_states(self):
        return {
            s["name"]: np.zeros([d if d > 0 else 1 for d in s["dims"]], dtype=DTYPES[s["elem_type"]])
            for s in self.states
        }

    def reset(self):
        self.fbank = fb.KaldiFbank(scale=self.fbank.scale)
        self.state = self._zero_states()
        self.feats = []
        self.offset = 0
        self.prev = self.blank
        self.out_frames = 0
        self.emitted = []      # (token, time seconds)
        self.log_probs = []    # rows, for the judge

    def accept(self, samples):
        self.feats.extend(self.fbank.accept(samples))
        while len(self.feats) - self.offset >= self.window:
            block = np.asarray(self.feats[self.offset:self.offset + self.window], dtype=np.float32)
            feeds = {self.x_spec["name"]: block[None, :, :]}
            feeds.update(self.state)
            outputs = self.session.run(self.out_names, feeds)
            rows = np.asarray(outputs[0][0], dtype=np.float64)
            for name, idx in self.slots:
                self.state[name] = outputs[idx]
            for r, row in enumerate(rows):
                lse = row.max() + np.log(np.exp(row - row.max()).sum())
                if abs(lse) > 1e-4:
                    row = row - lse
                best = int(row.argmax())
                if best != self.blank and best != self.prev:
                    self.emitted.append((self.tokens[best], (self.out_frames + r) * 0.04))
                self.prev = best
                self.log_probs.append(row)
            self.out_frames += len(rows)
            self.offset += self.hop

    def finish(self):
        self.accept(np.zeros(19200, dtype=np.float32))

    @property
    def token_list(self):
        return [t for t, _ in self.emitted]
