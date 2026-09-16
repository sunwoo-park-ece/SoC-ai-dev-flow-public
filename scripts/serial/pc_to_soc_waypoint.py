#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
import time

import serial

from common_serial_frame import TYPE_PC_WAYPOINT, encode_frame


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Final demo helper: send one PC_WAYPOINT frame to SoC UART1 while "
            "the SoC is in coordinate-transfer mode (SW[1:0]=2'b11)."
        )
    )
    parser.add_argument("--port", default="COM10", help="PC UART port connected to SoC UART1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--x", type=int, default=100)
    parser.add_argument("--y", type=int, default=200)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--monitor-sec", type=float, default=2.0)
    args = parser.parse_args()

    payload = struct.pack("<ii", args.x, args.y)
    frame = encode_frame(TYPE_PC_WAYPOINT, payload)

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        print(f"[PC->SoC] opened {args.port} @ {args.baud}")
        print("[PC->SoC] set SoC switches to SW[1:0]=2'b11 before sending waypoint")
        print("[PC->SoC] frame format: SOF TYPE LEN X[31:0] Y[31:0] SUM EOF")
        for i in range(args.repeat):
            ser.write(frame)
            ser.flush()
            print(f"[PC->SoC] waypoint #{i + 1}: x={args.x} y={args.y} bytes={frame.hex(' ')}")
            time.sleep(args.interval)

        end = time.time() + args.monitor_sec
        buf = bytearray()
        print("[PC->SoC] monitoring UART1 log...")
        while time.time() < end:
            data = ser.read(256)
            if not data:
                continue
            for b in data:
                if b in (10, 13):
                    if buf:
                        print(buf.decode(errors="replace"))
                        buf.clear()
                else:
                    buf.append(b)
        if buf:
            print(buf.decode(errors="replace"))


if __name__ == "__main__":
    main()
