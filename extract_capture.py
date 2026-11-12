#!/usr/bin/env python3
"""Extract complete, unfragmented ATT packets from this PacketLogger capture."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import struct
from motion_protocol import decode_motion


def records(path):
    data = Path(path).read_bytes()
    pos = 0
    while pos < len(data):
        if len(data) - pos < 13:
            raise ValueError(f"Truncated PacketLogger header at {pos}")
        length, seconds, micros = struct.unpack_from("<III", data, pos)
        end = pos + 4 + length
        if length < 9 or end > len(data):
            raise ValueError(f"Invalid PacketLogger length at {pos}")
        yield seconds + micros / 1e6, data[pos + 12], data[pos + 13:end]
        pos = end


def extract(source, target):
    counts = Counter()
    names = {}
    skipped = 0
    events = []
    for timestamp, kind, payload in records(source):
        if kind not in (2, 3) or len(payload) < 8:
            continue
        flags, acl_length, l2cap_length, cid = struct.unpack_from("<4H", payload)
        if ((flags >> 12) & 3) == 1:
            skipped += 1
            continue
        if cid != 4:
            continue
        if len(payload) != acl_length + 4 or acl_length != l2cap_length + 4:
            skipped += 1
            continue
        handle = flags & 0xFFF
        att = payload[8:]
        if not att:
            continue
        # Read By Type response for the device name, captured on both links.
        if att[0] == 9 and b"MRR_Boxing_" in att:
            start = att.index(b"MRR_Boxing_")
            names[handle] = att[start:].rstrip(b"\0").decode("ascii")
        if att[0] not in (0x12, 0x52, 0x1B) or len(att) < 3:
            continue
        event = {"utc": datetime.fromtimestamp(timestamp, timezone.utc).isoformat(),
                 "connection_handle": handle, "direction": "tx" if kind == 2 else "rx",
                 "opcode": att[0], "attribute_handle": int.from_bytes(att[1:3], "little"),
                 "hex": att[3:].hex()}
        motion = decode_motion(att[3:]) if att[0] == 0x1B else None
        if motion:
            event["motion"] = motion
            counts[(handle, "motion")] += 1
        elif kind == 2:
            counts[(handle, "write")] += 1
        events.append(event)
    with Path(target).open("x", encoding="utf-8") as stream:
        for event in events:
            event["device"] = names.get(event["connection_handle"], "unknown")
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")
    print(json.dumps({"devices": names, "counts": {f"{h}:{kind}": n for (h, kind), n in counts.items()},
                      "skipped_fragmented_or_invalid_acl": skipped,
                      "output": str(target)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("output")
    args = parser.parse_args()
    extract(args.source, args.output)
