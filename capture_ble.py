#!/usr/bin/env python3
"""Capture WeeWaa AE02; optionally start the observed motion stream."""
import argparse
import asyncio
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import socket
import time
from motion_protocol import decode_motion


DEFAULT_DEVICE = "FAA399E8-4DCE-2FA2-5791-37DC6DC43DC0"
DEVICES = {
    "right": DEFAULT_DEVICE,
    "left": "36DD541D-4D8C-3E12-3333-A75D12A06B3C",
}
NOTIFY = "0000ae02-0000-1000-8000-00805f9b34fb"
WRITE = "0000ae01-0000-1000-8000-00805f9b34fb"


async def capture(args):
    from bleak import BleakClient

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    lengths = Counter()
    motion_count = 0
    hand = next((side for side, device in DEVICES.items()
                 if device.lower() == args.device.lower()), "unknown")
    started = time.monotonic()
    async with BleakClient(args.device, timeout=20) as client:
        services = [
            {"uuid": service.uuid, "characteristics": [
                {"uuid": char.uuid, "properties": char.properties}
                for char in service.characteristics
            ]}
            for service in client.services
        ]
        with output.open("x", encoding="utf-8") as stream, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            def record(event):
                stream.write(json.dumps(event, ensure_ascii=False) + "\n")
                stream.flush()

            record({"type": "session", "device": args.device, "hand": hand,
                    "label": args.label, "services": services,
                    "utc": datetime.now(timezone.utc).isoformat()})

            def notified(characteristic, data):
                nonlocal motion_count
                elapsed = time.monotonic() - started
                packet = bytes(data)
                lengths[len(packet)] += 1
                event = {"type": "notification", "elapsed_s": elapsed,
                        "utc": datetime.now(timezone.utc).isoformat(),
                        "characteristic": characteristic.uuid,
                        "length": len(packet), "hex": packet.hex()}
                motion = decode_motion(packet)
                if motion:
                    event["motion"] = motion
                    motion_count += 1
                    if args.udp_port:
                        message = {"type": "motion", "device": args.device, "hand": hand,
                                   "utc": event["utc"], "elapsed_s": elapsed, **motion}
                        udp.sendto(json.dumps(message).encode("utf-8"), ("127.0.0.1", args.udp_port))
                record(event)
                if not motion or motion_count % 80 == 1:
                    print(f"{elapsed:9.3f}s  {len(packet):3d} B  {packet.hex(' ')}", flush=True)

            await client.start_notify(NOTIFY, notified)
            print(f"已订阅 AE02，采集 {args.seconds:g} 秒；标签：{args.label}", flush=True)
            try:
                async def write(packet):
                    await client.write_gatt_char(WRITE, packet, response=False)
                    record({"type": "write", "elapsed_s": time.monotonic() - started,
                            "hex": packet.hex()})

                if args.start_stream:
                    # The iPad trace starts streaming immediately after the
                    # final 12... command. Its individual fields remain unknown.
                    await asyncio.sleep(0.9)
                    for packet, delay in [(b"\x29", 0.24), (b"\x60", 0.4),
                                          (b"\x60", 0.38), (b"\x46", 1.0),
                                          (bytes.fromhex("12 64 ff 19 04 50 01 03 05 07 00"), 0)]:
                        await write(packet)
                        await asyncio.sleep(delay)
                end = time.monotonic() + args.seconds
                keepalive = time.monotonic() + 2
                while time.monotonic() < end:
                    if not client.is_connected:
                        raise RuntimeError("手柄已断开，已收到的数据保存在输出文件中")
                    if args.start_stream and time.monotonic() >= keepalive:
                        await write(b"\x19")
                        keepalive = time.monotonic() + 3
                    await asyncio.sleep(min(0.25, max(0, end - time.monotonic())))
            finally:
                if client.is_connected:
                    await client.stop_notify(NOTIFY)
                record({"type": "summary", "packets": sum(lengths.values()),
                        "motion_packets": motion_count, "length_counts": dict(lengths)})
    print(f"共 {sum(lengths.values())} 包，体感候选包 {motion_count}，长度分布：{dict(lengths)}；保存至 {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hand", choices=DEVICES, default="right", help="选择这台 Mac 已发现的左/右手柄")
    parser.add_argument("--device", help="指定设备 UUID，优先于 --hand")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--label", default="unknown")
    parser.add_argument("--start-stream", action="store_true",
                        help="发送原厂 App 的初始化序列（含 12...配置）和周期性 19 指令（实验性）")
    parser.add_argument("--udp-port", type=int, help="同时向本机 127.0.0.1 的指定 UDP 端口发送原始体感 JSON")
    parser.add_argument("--output", default="capture-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".jsonl")
    args = parser.parse_args()
    args.device = args.device or DEVICES[args.hand]
    if args.seconds <= 0:
        parser.error("--seconds 必须大于 0")
    if args.udp_port is not None and not 1 <= args.udp_port <= 65535:
        parser.error("--udp-port 必须在 1–65535 之间")
    try:
        asyncio.run(capture(args))
    except KeyboardInterrupt:
        print("\n采集已停止。")


if __name__ == "__main__":
    main()
