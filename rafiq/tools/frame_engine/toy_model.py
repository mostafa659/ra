"""A tiny but real streaming-style ONNX model, built by hand (no onnx package).

Same I/O shape of the problem as the pinned export: a feature window `x`, one
state tensor that must be fed back, an int64 counter state, `log_probs` plus
`new_<state>` outputs, and `T` / `decode_chunk_len` metadata. It lets the tests
run the real onnxruntime through model_probe.py and stream_ref.py without the
gated 73 MB model.
"""
import struct

import numpy as np

from onnx_contract import build_model, w_field, w_varint, w_value_info

CLASSES = 5          # a b c d <blk>
WINDOW, HOP, DIM = 61, 48, 80
OUT_FRAMES = HOP // 4
WEIGHTS = np.array(
    [[1.5, -0.5, 0.2, 0.1, 0.0],
     [-0.4, 1.2, 0.3, -0.2, 0.1],
     [0.2, 0.1, 1.4, -0.6, 0.0],
     [0.0, -0.3, 0.1, 1.3, 0.4]], dtype=np.float32)
STATE_DELTA = np.array([[0.0, 0.5, 0.0, 0.0, -0.5]], dtype=np.float32)


def _tensor(name, dims, dtype, array):
    raw = np.ascontiguousarray(array).tobytes()
    out = b"".join(w_field(1, 0, w_varint(d)) for d in dims)
    return out + w_field(2, 0, w_varint(dtype)) + w_field(8, 2, name.encode()) + w_field(9, 2, raw)


def _attr_ints(name, values):
    body = w_field(1, 2, name.encode()) + w_field(20, 0, w_varint(7))
    return body + b"".join(w_field(8, 0, w_varint(v)) for v in values)


def _attr_int(name, value):
    return w_field(1, 2, name.encode()) + w_field(20, 0, w_varint(2)) + w_field(3, 0, w_varint(value))


def _node(op, inputs, outputs, name, attrs=()):
    body = b"".join(w_field(1, 2, i.encode()) for i in inputs)
    body += b"".join(w_field(2, 2, o.encode()) for o in outputs)
    body += w_field(3, 2, name.encode()) + w_field(4, 2, op.encode())
    return body + b"".join(w_field(5, 2, a) for a in attrs)


def build_toy_model():
    inits = [
        _tensor("W", [4, CLASSES], 1, WEIGHTS),
        _tensor("s_starts", [1], 7, np.array([0], dtype=np.int64)),
        _tensor("s_ends", [1], 7, np.array([HOP], dtype=np.int64)),
        _tensor("s_axes", [1], 7, np.array([1], dtype=np.int64)),
        _tensor("shape_r", [3], 7, np.array([1, OUT_FRAMES, 4], dtype=np.int64)),
        _tensor("shape_c", [3], 7, np.array([1, 1, CLASSES], dtype=np.int64)),
        _tensor("delta", [1, CLASSES], 1, STATE_DELTA),
        _tensor("hop", [1], 7, np.array([HOP], dtype=np.int64)),
    ]
    nodes = [
        _node("ReduceMean", ["x"], ["m"], "mean", [_attr_ints("axes", [2]), _attr_int("keepdims", 0)]),
        _node("Slice", ["m", "s_starts", "s_ends", "s_axes"], ["s"], "slice"),
        _node("Reshape", ["s", "shape_r"], ["r"], "reshape_r"),
        _node("MatMul", ["r", "W"], ["h"], "matmul"),
        _node("Reshape", ["cached_bias_0", "shape_c"], ["c"], "reshape_c"),
        _node("Add", ["h", "c"], ["z"], "mix"),
        _node("LogSoftmax", ["z"], ["log_probs"], "logsoftmax", [_attr_int("axis", 2)]),
        _node("Add", ["cached_bias_0", "delta"], ["new_cached_bias_0"], "state_bias"),
        _node("Add", ["processed_lens", "hop"], ["new_processed_lens"], "state_lens"),
    ]
    graph = w_field(2, 2, b"toy")
    graph += b"".join(w_field(1, 2, n) for n in nodes)
    graph += b"".join(w_field(5, 2, t) for t in inits)
    for spec in (("x", 1, [1, WINDOW, DIM]), ("cached_bias_0", 1, [1, CLASSES]), ("processed_lens", 7, [1])):
        graph += w_field(11, 2, w_value_info(*spec))
    for spec in (("log_probs", 1, [1, OUT_FRAMES, CLASSES]), ("new_cached_bias_0", 1, [1, CLASSES]),
                 ("new_processed_lens", 7, [1])):
        graph += w_field(12, 2, w_value_info(*spec))
    model = w_field(1, 0, w_varint(7)) + w_field(8, 2, w_field(2, 0, w_varint(13))) + w_field(7, 2, graph)
    for key, value in {"T": str(WINDOW), "decode_chunk_len": str(HOP)}.items():
        model += w_field(14, 2, w_field(1, 2, key.encode()) + w_field(2, 2, value.encode()))
    return model


def numpy_reference(windows):
    """Expected log_probs per step for a list of [WINDOW, DIM] feature windows."""
    state = np.zeros((1, CLASSES), dtype=np.float64)
    steps = []
    for window in windows:
        m = np.asarray(window, dtype=np.float64).mean(axis=1)[:HOP]
        h = m.reshape(OUT_FRAMES, 4) @ WEIGHTS.astype(np.float64)
        z = h + state
        z = z - z.max(axis=1, keepdims=True)
        steps.append(z - np.log(np.exp(z).sum(axis=1, keepdims=True)))
        state = state + STATE_DELTA
    return steps
