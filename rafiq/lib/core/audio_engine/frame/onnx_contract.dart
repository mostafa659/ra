import 'dart:convert';
import 'dart:typed_data';

/// One graph input or output as declared in the ONNX file.
class OnnxValueSpec {
  const OnnxValueSpec({
    required this.name,
    required this.elemType,
    required this.dims,
  });

  static const int elemFloat = 1;
  static const int elemInt32 = 6;
  static const int elemInt64 = 7;

  final String name;
  final int elemType;

  /// Static dimensions; -1 marks a symbolic (dynamic) dimension.
  final List<int> dims;

  List<int> get concreteShape => <int>[for (final int d in dims) d > 0 ? d : 1];

  int get elementCount {
    int count = 1;
    for (final int d in dims) {
      count *= d > 0 ? d : 1;
    }
    return count;
  }
}

/// What the streaming runner needs from the model file: input/output names,
/// element types, shapes and the exporter's metadata (chunk size, ...).
///
/// The ORT binding exposes only the names, so the rest is read straight from
/// the ONNX protobuf. This is a literal port of
/// tools/frame_engine/onnx_contract.py, which is checked against onnxruntime.
class OnnxContract {
  const OnnxContract({
    required this.inputs,
    required this.outputs,
    required this.metadata,
  });

  final List<OnnxValueSpec> inputs;
  final List<OnnxValueSpec> outputs;
  final Map<String, String> metadata;

  static OnnxContract parse(Uint8List data) {
    final List<OnnxValueSpec> inputs = <OnnxValueSpec>[];
    final List<OnnxValueSpec> outputs = <OnnxValueSpec>[];
    final Set<String> initializers = <String>{};
    final Map<String, String> metadata = <String, String>{};

    for (final _Field f in _fields(data, 0, data.length)) {
      if (f.number == 7 && f.wire == 2) {
        for (final _Field g in _fields(data, f.start, f.end)) {
          if (g.number == 11 && g.wire == 2) {
            inputs.add(_valueInfo(data, g.start, g.end));
          } else if (g.number == 12 && g.wire == 2) {
            outputs.add(_valueInfo(data, g.start, g.end));
          } else if (g.number == 5 && g.wire == 2) {
            for (final _Field t in _fields(data, g.start, g.end)) {
              if (t.number == 8 && t.wire == 2) {
                initializers.add(_text(data, t.start, t.end));
              }
            }
          }
        }
      } else if (f.number == 14 && f.wire == 2) {
        String key = '';
        String value = '';
        for (final _Field g in _fields(data, f.start, f.end)) {
          if (g.number == 1 && g.wire == 2) {
            key = _text(data, g.start, g.end);
          } else if (g.number == 2 && g.wire == 2) {
            value = _text(data, g.start, g.end);
          }
        }
        metadata[key] = value;
      }
    }
    return OnnxContract(
      inputs: List<OnnxValueSpec>.unmodifiable(
        inputs.where((OnnxValueSpec i) => !initializers.contains(i.name)),
      ),
      outputs: List<OnnxValueSpec>.unmodifiable(outputs),
      metadata: Map<String, String>.unmodifiable(metadata),
    );
  }

  static OnnxValueSpec _valueInfo(Uint8List b, int start, int end) {
    String name = '';
    int elem = 0;
    List<int> dims = <int>[];
    for (final _Field f in _fields(b, start, end)) {
      if (f.number == 1 && f.wire == 2) {
        name = _text(b, f.start, f.end);
      } else if (f.number == 2 && f.wire == 2) {
        for (final _Field t in _fields(b, f.start, f.end)) {
          if (t.number == 1 && t.wire == 2) {
            for (final _Field s in _fields(b, t.start, t.end)) {
              if (s.number == 1 && s.wire == 0) {
                elem = s.value;
              } else if (s.number == 2 && s.wire == 2) {
                dims = _shape(b, s.start, s.end);
              }
            }
          }
        }
      }
    }
    return OnnxValueSpec(name: name, elemType: elem, dims: dims);
  }

  static List<int> _shape(Uint8List b, int start, int end) {
    final List<int> dims = <int>[];
    for (final _Field f in _fields(b, start, end)) {
      if (f.number == 1 && f.wire == 2) {
        int dim = -1;
        for (final _Field d in _fields(b, f.start, f.end)) {
          if (d.number == 1 && d.wire == 0) {
            dim = d.value;
          }
        }
        dims.add(dim);
      }
    }
    return dims;
  }

  static String _text(Uint8List b, int start, int end) {
    return utf8.decode(Uint8List.sublistView(b, start, end), allowMalformed: true);
  }

  static Iterable<_Field> _fields(Uint8List b, int start, int end) sync* {
    int pos = start;
    while (pos < end) {
      int tag = 0;
      int shift = 0;
      while (true) {
        final int byte = b[pos++];
        tag |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
          break;
        }
        shift += 7;
      }
      final int number = tag >> 3;
      final int wire = tag & 7;
      if (wire == 0) {
        int value = 0;
        int valueShift = 0;
        while (true) {
          final int byte = b[pos++];
          value |= (byte & 0x7F) << valueShift;
          if ((byte & 0x80) == 0) {
            break;
          }
          valueShift += 7;
        }
        yield _Field(number, wire, value, 0, 0);
      } else if (wire == 2) {
        int length = 0;
        int lengthShift = 0;
        while (true) {
          final int byte = b[pos++];
          length |= (byte & 0x7F) << lengthShift;
          if ((byte & 0x80) == 0) {
            break;
          }
          lengthShift += 7;
        }
        yield _Field(number, wire, 0, pos, pos + length);
        pos += length;
      } else if (wire == 1) {
        yield _Field(number, wire, 0, 0, 0);
        pos += 8;
      } else if (wire == 5) {
        yield _Field(number, wire, 0, 0, 0);
        pos += 4;
      } else {
        throw FormatException('Unsupported protobuf wire type $wire.');
      }
    }
  }
}

class _Field {
  const _Field(this.number, this.wire, this.value, this.start, this.end);

  final int number;
  final int wire;
  final int value;
  final int start;
  final int end;
}
