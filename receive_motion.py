#!/usr/bin/env python3
"""Example consumer of the local WeeWaa raw-motion JSON stream (not DSU)."""
import json
import socket


with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
    receiver.bind(("127.0.0.1", 8765))
    print("Listening on 127.0.0.1:8765; Ctrl-C to stop", flush=True)
    try:
        while True:
            packet, _ = receiver.recvfrom(65535)
            event = json.loads(packet)
            if event["valid"]:
                print(event.get("hand", event["device"]), event["counter"], event["axes"], flush=True)
    except KeyboardInterrupt:
        pass
