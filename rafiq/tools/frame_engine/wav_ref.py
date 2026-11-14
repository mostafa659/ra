"""Reference for lib/core/audio_engine/report/wav_writer.dart.

The phone captures PCM16 and hands the engine floats (pcm / 32768). Saving the
audio with the same scale makes the round trip exact: ci_parity.load_wav reads
the file back as pcm / 32768.0, which is bit-for-bit what the phone's model saw.
"""
import math
import struct

SAMPLE_RATE = 16000


def float_to_pcm16(x):
    """Round half away from zero at scale 32768, clamped to the int16 range."""
    if x != x:
        return 0
    magnitude = int(math.floor(abs(x) * 32768.0 + 0.5))
    if x < 0:
        return -min(magnitude, 32768)
    return min(magnitude, 32767)


def encode_wav16(pcm, sample_rate=SAMPLE_RATE):
    """44-byte RIFF header + little-endian int16 mono samples."""
    data_bytes = len(pcm) * 2
    header = b"RIFF" + struct.pack("<I", 36 + data_bytes) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", data_bytes)
    return header + struct.pack("<%dh" % len(pcm), *pcm)


def decode_wav16(blob):
    """(samples as floats pcm/32768, sample_rate) of a file written by encode_wav16."""
    if blob[0:4] != b"RIFF" or blob[8:12] != b"WAVE" or blob[12:16] != b"fmt ":
        raise ValueError("not a RIFF/WAVE file")
    fmt, channels, rate, _, _, bits = struct.unpack("<HHIIHH", blob[20:36])
    if fmt != 1 or channels != 1 or bits != 16:
        raise ValueError("expected mono PCM16")
    if blob[36:40] != b"data":
        raise ValueError("data chunk not where the writer puts it")
    size = struct.unpack("<I", blob[40:44])[0]
    pcm = struct.unpack("<%dh" % (size // 2), blob[44:44 + size])
    return [v / 32768.0 for v in pcm], rate
