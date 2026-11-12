"""Experimental WeeWaa packet decoding, derived from the local iPad capture.

Axis grouping, physical units and the meaning of the device counter are not yet
calibrated. Never label these raw readings as g, degrees/s or orientation.
"""
import struct


def decode_motion(packet):
    if len(packet) != 19 or packet[:3] != b"\x11\x06\x00":
        return None
    counter, *axes = struct.unpack_from("<I6h", packet, 3)
    return {
        "counter": counter,
        "raw_axes": axes,
        "axes": [None if value == -32768 else value for value in axes],
        "valid": all(value != -32768 for value in axes),
    }
