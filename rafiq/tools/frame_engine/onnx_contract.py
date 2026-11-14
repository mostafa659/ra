"""Minimal ONNX protobuf reader: graph inputs/outputs and metadata only.

The Dart ORT binding exposes input/output *names* but not shapes, element types
or the model's metadata, and the streaming state tensors have to be created
from exactly those. Reading them from the model file itself keeps the app
independent of any external contract file. The Dart port
(lib/core/audio_engine/frame/onnx_contract.dart) is a literal translation of
this file; tools/model_probe.py checks it against onnxruntime on the real model.
"""

ELEM_FLOAT, ELEM_INT32, ELEM_INT64 = 1, 6, 7


def _varint(buf, pos):
    result = 0
    shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return result, pos
        shift += 7


def _fields(buf, start, end):
    """Yields (field number, wire type, value); length-delimited values are (a, b) slices."""
    pos = start
    while pos < end:
        tag, pos = _varint(buf, pos)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, pos = _varint(buf, pos)
            yield field, wire, value
        elif wire == 1:
            yield field, wire, None
            pos += 8
        elif wire == 2:
            length, pos = _varint(buf, pos)
            yield field, wire, (pos, pos + length)
            pos += length
        elif wire == 5:
            yield field, wire, None
            pos += 4
        else:
            raise ValueError("unsupported protobuf wire type %d" % wire)


def _text(buf, span):
    return bytes(buf[span[0]:span[1]]).decode("utf-8")


def _shape(buf, span):
    dims = []
    for field, wire, value in _fields(buf, *span):
        if field == 1 and wire == 2:
            dim = -1  # dim_param (symbolic) stays -1
            for f2, w2, v2 in _fields(buf, *value):
                if f2 == 1 and w2 == 0:
                    dim = v2
            dims.append(dim)
    return dims


def _type(buf, span):
    elem, dims = 0, None
    for field, wire, value in _fields(buf, *span):
        if field == 1 and wire == 2:  # tensor_type
            for f2, w2, v2 in _fields(buf, *value):
                if f2 == 1 and w2 == 0:
                    elem = v2
                elif f2 == 2 and w2 == 2:
                    dims = _shape(buf, v2)
    return elem, dims


def _value_info(buf, span):
    name, elem, dims = "", 0, None
    for field, wire, value in _fields(buf, *span):
        if field == 1 and wire == 2:
            name = _text(buf, value)
        elif field == 2 and wire == 2:
            elem, dims = _type(buf, value)
    return {"name": name, "elem_type": elem, "dims": dims if dims is not None else []}


def parse_contract(data):
    inputs, outputs, initializers, metadata = [], [], set(), {}
    for field, wire, value in _fields(data, 0, len(data)):
        if field == 7 and wire == 2:  # graph
            for g, gw, gv in _fields(data, *value):
                if g == 11 and gw == 2:
                    inputs.append(_value_info(data, gv))
                elif g == 12 and gw == 2:
                    outputs.append(_value_info(data, gv))
                elif g == 5 and gw == 2:  # initializer: only its name matters
                    for t, tw, tv in _fields(data, *gv):
                        if t == 8 and tw == 2:
                            initializers.add(_text(data, tv))
        elif field == 14 and wire == 2:  # metadata_props
            key, val = "", ""
            for g, gw, gv in _fields(data, *value):
                if g == 1 and gw == 2:
                    key = _text(data, gv)
                elif g == 2 and gw == 2:
                    val = _text(data, gv)
            metadata[key] = val
    inputs = [i for i in inputs if i["name"] not in initializers]
    return {"inputs": inputs, "outputs": outputs, "metadata": metadata}


# ------------------------------------------------------------ writer (tests only)
def w_varint(number):
    out = bytearray()
    while True:
        byte = number & 0x7F
        number >>= 7
        if number:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def w_field(field, wire, payload):
    tag = w_varint((field << 3) | wire)
    if wire == 2:
        return tag + w_varint(len(payload)) + payload
    return tag + payload


def w_value_info(name, elem, dims):
    shape = b"".join(
        w_field(1, 2, w_field(1, 0, w_varint(d)) if isinstance(d, int) else w_field(2, 2, d.encode()))
        for d in dims
    )
    tensor = w_field(1, 0, w_varint(elem)) + w_field(2, 2, shape)
    return w_field(1, 2, name.encode()) + w_field(2, 2, w_field(1, 2, tensor))


def build_model(inputs, outputs, metadata, initializers=()):
    graph = w_field(2, 2, b"g")
    for name in initializers:
        graph += w_field(5, 2, w_field(8, 2, name.encode()) + w_field(9, 2, b"\x00" * 16))
    for spec in inputs:
        graph += w_field(11, 2, w_value_info(*spec))
    for spec in outputs:
        graph += w_field(12, 2, w_value_info(*spec))
    model = w_field(1, 0, w_varint(8)) + w_field(7, 2, graph)
    for key, value in metadata.items():
        model += w_field(14, 2, w_field(1, 2, key.encode()) + w_field(2, 2, value.encode()))
    return model
