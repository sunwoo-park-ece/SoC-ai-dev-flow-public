#!/usr/bin/env python3
from __future__ import annotations

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SOF = 0x7E
EOF = 0x0A
MAX_PAYLOAD = 64
SECURE_BLOCK_LEN = 16
SECURE_WIRE_LEN = 46

TYPE_MODE_CHANGE = 0x10
TYPE_MANUAL_CMD = 0x11
TYPE_WAYPOINT_CMD = 0x12
TYPE_TELEMETRY_REQ = 0x13
TYPE_PC_WAYPOINT = 0x21
TYPE_SECURE_C2R = 0x30
TYPE_MANUAL_ACK = 0x81
TYPE_MODE_ACK = 0x90
TYPE_WAYPOINT_ACK = 0x92
TYPE_TELEMETRY_DATA = 0x93
TYPE_SECURE_R2C = 0xB0

AES_DEMO_KEY = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
AES_SESSION_NONCE = 0x102030
AES_DIR_C2R = 0x00
AES_DIR_R2C = 0x01
AES_MAGIC = b"\xA5\x5A"


def checksum(frame_type: int, payload: bytes) -> int:
    return (frame_type + len(payload) + sum(payload)) & 0xFF


def encode_frame(frame_type: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload too long: {len(payload)} > {MAX_PAYLOAD}")
    return bytes([SOF, frame_type & 0xFF, len(payload)]) + payload + bytes(
        [checksum(frame_type, payload), EOF]
    )


def nonce_dir(direction: int) -> int:
    return ((AES_SESSION_NONCE & 0xFFFFFF) << 8) | (direction & 0xFF)


def secure_header(nonce_dir_value: int, seq_hi: int, seq_lo: int, payload_len: int) -> bytes:
    return (
        AES_MAGIC
        + nonce_dir_value.to_bytes(4, "big")
        + (seq_hi & 0xFFFFFFFF).to_bytes(4, "big")
        + (seq_lo & 0xFFFFFFFF).to_bytes(4, "big")
        + (payload_len & 0xFFFF).to_bytes(2, "big")
    )


def secure_iv(nonce_dir_value: int, seq_hi: int, seq_lo: int) -> bytes:
    return (
        nonce_dir_value.to_bytes(4, "big")
        + (seq_hi & 0xFFFFFFFF).to_bytes(4, "big")
        + (seq_lo & 0xFFFFFFFF).to_bytes(4, "big")
    )


def encode_secure_payload(app_type: int, app_payload: bytes, direction: int, seq_lo: int, seq_hi: int = 0) -> bytes:
    plain = bytes([app_type & 0xFF]) + app_payload[: SECURE_BLOCK_LEN - 1]
    plain = plain.ljust(SECURE_BLOCK_LEN, b"\x00")
    nd = nonce_dir(direction)
    aad = secure_header(nd, seq_hi, seq_lo, SECURE_BLOCK_LEN)
    encrypted = AESGCM(AES_DEMO_KEY).encrypt(secure_iv(nd, seq_hi, seq_lo), plain, aad)
    cipher = encrypted[:SECURE_BLOCK_LEN]
    tag = encrypted[SECURE_BLOCK_LEN:]
    return (
        nd.to_bytes(4, "big")
        + (seq_hi & 0xFFFFFFFF).to_bytes(4, "big")
        + (seq_lo & 0xFFFFFFFF).to_bytes(4, "big")
        + SECURE_BLOCK_LEN.to_bytes(2, "big")
        + cipher
        + tag
    )


def decode_secure_payload(wire_payload: bytes, expected_direction: int) -> tuple[int, bytes, int]:
    if len(wire_payload) != SECURE_WIRE_LEN:
        raise ValueError(f"bad secure payload length: {len(wire_payload)}")
    nd = int.from_bytes(wire_payload[0:4], "big")
    seq_hi = int.from_bytes(wire_payload[4:8], "big")
    seq_lo = int.from_bytes(wire_payload[8:12], "big")
    payload_len = int.from_bytes(wire_payload[12:14], "big")
    if nd != nonce_dir(expected_direction):
        raise ValueError(f"bad nonce_dir: 0x{nd:08X}")
    if payload_len != SECURE_BLOCK_LEN:
        raise ValueError(f"bad secure payload len field: {payload_len}")
    aad = secure_header(nd, seq_hi, seq_lo, payload_len)
    cipher = wire_payload[14:30]
    tag = wire_payload[30:46]
    plain = AESGCM(AES_DEMO_KEY).decrypt(secure_iv(nd, seq_hi, seq_lo), cipher + tag, aad)
    return plain[0], plain[1:], seq_lo


class FrameParser:
    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.state = 0
        self.frame_type = 0
        self.length = 0
        self.payload = bytearray()
        self.sum = 0

    def feed_byte(self, byte: int):
        byte &= 0xFF
        if self.state == 0:
            if byte == SOF:
                self.state = 1
                self.payload.clear()
                self.sum = 0
        elif self.state == 1:
            self.frame_type = byte
            self.sum = byte
            self.state = 2
        elif self.state == 2:
            self.length = byte
            self.sum = (self.sum + byte) & 0xFF
            if self.length > MAX_PAYLOAD:
                self.reset()
            else:
                self.state = 4 if self.length == 0 else 3
        elif self.state == 3:
            self.payload.append(byte)
            self.sum = (self.sum + byte) & 0xFF
            if len(self.payload) >= self.length:
                self.state = 4
        elif self.state == 4:
            if byte == self.sum:
                self.state = 5
            else:
                self.reset()
        elif self.state == 5:
            if byte == EOF:
                result = (self.frame_type, bytes(self.payload))
                self.reset()
                return result
            self.reset()
        else:
            self.reset()
        return None

    def feed(self, data: bytes):
        frames = []
        for byte in data:
            frame = self.feed_byte(byte)
            if frame is not None:
                frames.append(frame)
        return frames


def frame_name(frame_type: int) -> str:
    names = {
        TYPE_MODE_CHANGE: "MODE_CHANGE",
        TYPE_MANUAL_CMD: "MANUAL_CMD",
        TYPE_WAYPOINT_CMD: "WAYPOINT_CMD",
        TYPE_TELEMETRY_REQ: "TELEMETRY_REQ",
        TYPE_PC_WAYPOINT: "PC_WAYPOINT",
        TYPE_SECURE_C2R: "SECURE_C2R",
        TYPE_MANUAL_ACK: "MANUAL_ACK",
        TYPE_MODE_ACK: "MODE_ACK",
        TYPE_WAYPOINT_ACK: "WAYPOINT_ACK",
        TYPE_TELEMETRY_DATA: "TELEMETRY_DATA",
        TYPE_SECURE_R2C: "SECURE_R2C",
    }
    return names.get(frame_type, f"0x{frame_type:02X}")
