#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import struct
import time

import serial

from common_serial_frame import (
    AES_DIR_C2R,
    AES_DIR_R2C,
    TYPE_MANUAL_ACK,
    TYPE_MANUAL_CMD,
    TYPE_MODE_ACK,
    TYPE_MODE_CHANGE,
    TYPE_SECURE_C2R,
    TYPE_SECURE_R2C,
    TYPE_TELEMETRY_DATA,
    TYPE_TELEMETRY_REQ,
    TYPE_WAYPOINT_ACK,
    TYPE_WAYPOINT_CMD,
    FrameParser,
    decode_secure_payload,
    encode_frame,
    encode_secure_payload,
    frame_name,
)


def send_frame(
    ser: serial.Serial,
    frame_type: int,
    payload: bytes,
    response_delay: float,
    inter_byte_delay: float,
    repeat_response: int,
) -> None:
    frame = encode_frame(frame_type, payload)
    if response_delay > 0.0:
        time.sleep(response_delay)
    for repeat_idx in range(max(1, repeat_response)):
        if repeat_idx != 0 and response_delay > 0.0:
            time.sleep(response_delay)
        if inter_byte_delay <= 0.0:
            ser.write(frame)
        else:
            for byte in frame:
                ser.write(bytes([byte]))
                time.sleep(inter_byte_delay)
    ser.flush()
    print(f"[RC->SoC] {frame_name(frame_type)} payload={payload.hex(' ')} frame={frame.hex(' ')}")


def send_secure_app(
    ser: serial.Serial,
    app_type: int,
    app_payload: bytes,
    seq_lo: int,
    response_delay: float,
    inter_byte_delay: float,
    repeat_response: int,
) -> None:
    secure_payload = encode_secure_payload(app_type, app_payload, AES_DIR_R2C, seq_lo)
    plain = bytes([app_type]) + app_payload
    send_frame(
        ser,
        TYPE_SECURE_R2C,
        secure_payload,
        response_delay,
        inter_byte_delay,
        repeat_response,
    )
    print(
        f"  secure {frame_name(app_type)} seq={seq_lo} "
        f"plain={plain.hex(' ')}"
    )


def telemetry_position_cm(request_id: int, seq: int) -> tuple[int, int]:
    """Generate a visible 10 m x 5 m demo-space path in signed centimeters."""

    phase = (request_id if request_id else seq) & 0xFFFF
    theta = (phase % 96) * (2.0 * math.pi / 96.0)
    x_cm = int(round(math.sin(theta) * 450.0))
    y_cm = int(round(math.sin(theta * 2.0) * 220.0))
    return x_cm, y_cm


def make_telemetry_payload(request_id: int, seq: int) -> bytes:
    gps_x_cm, gps_y_cm = telemetry_position_cm(request_id, seq)
    ekf_x_cm = gps_x_cm + 3
    ekf_y_cm = gps_y_cm - 2
    rc_mode = 1
    flags = 0x07  # GPS valid, EKF initialized, auto_enable
    heading_u8 = (seq * 3) & 0xFF
    return struct.pack(
        "<HhhhhBBB2x",
        seq & 0xFFFF,
        ekf_x_cm,
        ekf_y_cm,
        gps_x_cm,
        gps_y_cm,
        rc_mode,
        flags,
        heading_u8,
    )


def handle_frame(
    ser: serial.Serial,
    frame_type: int,
    payload: bytes,
    telemetry_counter: int,
    rc_tx_seq: int,
    response_delay: float,
    inter_byte_delay: float,
    repeat_response: int,
) -> tuple[int, int]:
    print(f"[SoC->RC] {frame_name(frame_type)} payload={payload.hex(' ')}")

    if frame_type == TYPE_SECURE_C2R:
        try:
            app_type, app_payload, soc_seq = decode_secure_payload(payload, AES_DIR_C2R)
        except Exception as exc:
            print(f"  secure decode failed: {exc}")
            return telemetry_counter, rc_tx_seq

        plain = bytes([app_type]) + app_payload
        print(
            f"  secure {frame_name(app_type)} soc_seq={soc_seq} "
            f"plain={plain.hex(' ')}"
        )

        if app_type == TYPE_MODE_CHANGE and len(app_payload) >= 2:
            mode = app_payload[0]
            send_secure_app(
                ser,
                TYPE_MODE_ACK,
                bytes([mode, 0x00, 0x00]),
                rc_tx_seq,
                response_delay,
                inter_byte_delay,
                repeat_response,
            )
            return telemetry_counter, rc_tx_seq + 1

        if app_type == TYPE_MANUAL_CMD and len(app_payload) >= 8:
            cmd = app_payload[0]
            seq_lo = app_payload[6]
            cmd_text = "space" if cmd == 0x20 else chr(cmd)
            x_raw = struct.unpack_from("<H", app_payload, 1)[0]
            y_raw = struct.unpack_from("<H", app_payload, 3)[0]
            print(f"  manual cmd={cmd_text} x={x_raw} y={y_raw} seq_lo={seq_lo}")
            send_frame(
                ser,
                TYPE_MANUAL_ACK,
                bytes([seq_lo, cmd, 0x00]),
                response_delay,
                inter_byte_delay,
                repeat_response,
            )
            return telemetry_counter, rc_tx_seq

        if app_type == TYPE_WAYPOINT_CMD and len(app_payload) >= 10:
            waypoint_id = struct.unpack_from("<H", app_payload, 0)[0]
            x = struct.unpack_from("<i", app_payload, 2)[0]
            y = struct.unpack_from("<i", app_payload, 6)[0]
            print(f"  waypoint id={waypoint_id} x={x} y={y}")
            send_secure_app(
                ser,
                TYPE_WAYPOINT_ACK,
                struct.pack("<HB", waypoint_id, 0),
                rc_tx_seq,
                response_delay,
                inter_byte_delay,
                repeat_response,
            )
            return telemetry_counter, rc_tx_seq + 1

        if app_type == TYPE_TELEMETRY_REQ and len(app_payload) >= 4:
            request_id = struct.unpack_from("<H", app_payload, 0)[0]
            seq = telemetry_counter & 0xFFFF
            gps_x_cm, gps_y_cm = telemetry_position_cm(request_id, seq)
            ekf_x_cm = gps_x_cm + 3
            ekf_y_cm = gps_y_cm - 2
            print(
                f"  telemetry request_id={request_id} -> seq={seq} "
                f"ekf=({ekf_x_cm},{ekf_y_cm}) gps=({gps_x_cm},{gps_y_cm}) flags=0x07"
            )
            telemetry_payload = make_telemetry_payload(request_id, seq)
            send_secure_app(
                ser,
                TYPE_TELEMETRY_DATA,
                telemetry_payload,
                rc_tx_seq,
                response_delay,
                inter_byte_delay,
                repeat_response,
            )
            return telemetry_counter + 1, rc_tx_seq + 1

        return telemetry_counter, rc_tx_seq

    if frame_type == TYPE_MODE_CHANGE and len(payload) >= 2:
        print("  legacy plaintext MODE_CHANGE ignored in AES-GCM full demo")
        return telemetry_counter, rc_tx_seq
        mode = payload[0]
        send_frame(
            ser,
            TYPE_MODE_ACK,
            bytes([mode, 0x00, 0x00]),
            response_delay,
            inter_byte_delay,
            repeat_response,
        )
        return telemetry_counter, rc_tx_seq

    if frame_type == TYPE_MANUAL_CMD and len(payload) >= 8:
        cmd = payload[0]
        seq_lo = payload[6]
        cmd_text = "space" if cmd == 0x20 else chr(cmd)
        x_raw = struct.unpack_from("<H", payload, 1)[0]
        y_raw = struct.unpack_from("<H", payload, 3)[0]
        print(f"  manual cmd={cmd_text} x={x_raw} y={y_raw} seq_lo={seq_lo}")
        send_frame(
            ser,
            TYPE_MANUAL_ACK,
            bytes([seq_lo, cmd, 0x00]),
            response_delay,
            inter_byte_delay,
            repeat_response,
        )
        return telemetry_counter, rc_tx_seq

    if frame_type == TYPE_WAYPOINT_CMD and len(payload) >= 10:
        waypoint_id = struct.unpack_from("<H", payload, 0)[0]
        x = struct.unpack_from("<i", payload, 2)[0]
        y = struct.unpack_from("<i", payload, 6)[0]
        print(f"  waypoint id={waypoint_id} x={x} y={y}")
        send_frame(
            ser,
            TYPE_WAYPOINT_ACK,
            struct.pack("<HB", waypoint_id, 0),
            response_delay,
            inter_byte_delay,
            repeat_response,
        )
        return telemetry_counter, rc_tx_seq

    if frame_type == TYPE_TELEMETRY_REQ and len(payload) >= 4:
        request_id = struct.unpack_from("<H", payload, 0)[0]
        seq = telemetry_counter & 0xFFFF
        gps_x_cm, gps_y_cm = telemetry_position_cm(request_id, seq)
        ekf_x_cm = gps_x_cm + 3
        ekf_y_cm = gps_y_cm - 2
        print(
            f"  telemetry request_id={request_id} -> seq={seq} "
            f"ekf=({ekf_x_cm},{ekf_y_cm}) gps=({gps_x_cm},{gps_y_cm}) flags=0x07"
        )
        telemetry_payload = make_telemetry_payload(request_id, seq)
        send_frame(
            ser,
            TYPE_TELEMETRY_DATA,
            telemetry_payload,
            response_delay,
            inter_byte_delay,
            repeat_response,
        )
        return telemetry_counter + 1, rc_tx_seq

    return telemetry_counter, rc_tx_seq


def main() -> None:
    parser = argparse.ArgumentParser(
        description="PC-side RC car LoRa peer simulator for SoC UART0/LoRa tests."
    )
    parser.add_argument("--port", default="COM7", help="UART port connected to the RC-side LoRa module")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "--response-delay",
        type=float,
        default=0.25,
        help="Delay before replying after a received LoRa frame. Useful because the LoRa module may still be busy.",
    )
    parser.add_argument(
        "--inter-byte-delay",
        type=float,
        default=0.0,
        help="Delay between response bytes. Keep 0 for LoRa packet-mode modules that split frames on UART gaps.",
    )
    parser.add_argument(
        "--repeat-response",
        type=int,
        default=1,
        help="Transmit each response frame multiple times for reverse-link bring-up tests.",
    )
    args = parser.parse_args()

    parser_state = FrameParser()
    telemetry_counter = 1
    rc_tx_seq = 1

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        print(f"[RC peer] opened {args.port} @ {args.baud}")
        print("[RC peer] AES-GCM full demo mode: H753ZI RC-car node substitute")
        print("[RC peer] keep --inter-byte-delay 0 for packet-mode LoRa modules")
        print("[RC peer] waiting for SoC LoRa frames...")
        while True:
            data = ser.read(256)
            if not data:
                time.sleep(0.01)
                continue
            for frame_type, payload in parser_state.feed(data):
                telemetry_counter, rc_tx_seq = handle_frame(
                    ser,
                    frame_type,
                    payload,
                    telemetry_counter,
                    rc_tx_seq,
                    args.response_delay,
                    args.inter_byte_delay,
                    args.repeat_response,
                )


if __name__ == "__main__":
    main()
