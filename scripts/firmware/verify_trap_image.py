#!/usr/bin/env python3
"""Validate and convert a firmware image containing the P08B trap entry."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path


IMEM_BYTES = 16 * 1024
IMEM_WORDS = IMEM_BYTES // 4
NOP = 0x00000013
EXPECTED_TRAP_WORDS = (
    0x342022F3,  # csrrs x5, mcause, x0
    0x34102373,  # csrrs x6, mepc, x0
    0x545243B7,  # lui x7, 0x54524
    0x15038393,  # addi x7, x7, 0x150
    0x0000006F,  # jal x0, self
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_symbols(nm: str, elf: Path) -> dict[str, int]:
    output = subprocess.check_output([nm, "-n", str(elf)], text=True)
    wanted = {
        "_start",
        "__trap_entry",
        "__trap_fail_stop",
        "main",
        "__bss_start",
        "__bss_end",
        "__stack_top",
    }
    symbols: dict[str, int] = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[2] in wanted:
            symbols[fields[2]] = int(fields[0], 16)
    missing = sorted(wanted - symbols.keys())
    if missing:
        raise SystemExit(f"missing required ELF symbols: {', '.join(missing)}")
    return symbols


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--elf", required=True, type=Path)
    parser.add_argument("--map", required=True, dest="map_file", type=Path)
    parser.add_argument("--imem-bin", required=True, type=Path)
    parser.add_argument("--word-hex", required=True, type=Path)
    parser.add_argument("--result-json", required=True, type=Path)
    parser.add_argument("--nm", default="riscv32-unknown-elf-nm")
    args = parser.parse_args()

    symbols = read_symbols(args.nm, args.elf)
    image = args.imem_bin.read_bytes()
    failures: list[str] = []

    if len(image) == 0 or len(image) > IMEM_BYTES:
        failures.append(f"IMEM byte count {len(image)} is outside 1..{IMEM_BYTES}")
    if len(image) % 4:
        failures.append(f"IMEM byte count {len(image)} is not word aligned")
    if symbols["_start"] != 0:
        failures.append(f"_start is 0x{symbols['_start']:08x}, expected 0")

    trap_entry = symbols["__trap_entry"]
    trap_loop = symbols["__trap_fail_stop"]
    if trap_entry & 3:
        failures.append(f"trap entry 0x{trap_entry:08x} is not IALIGN32 aligned")
    if trap_entry >= IMEM_BYTES or trap_loop >= IMEM_BYTES:
        failures.append("trap entry or fail-stop loop is outside canonical IMEM")
    if trap_loop != trap_entry + 16:
        failures.append("fail-stop loop is not the fifth trap-entry instruction")

    map_text = args.map_file.read_text(errors="replace")
    if ".trap" not in map_text or "__trap_entry" not in map_text:
        failures.append("link map does not show retained .trap/__trap_entry")

    words = list(struct.unpack(f"<{len(image) // 4}I", image)) if len(image) % 4 == 0 else []
    trap_index = trap_entry // 4
    observed_trap = tuple(words[trap_index : trap_index + len(EXPECTED_TRAP_WORDS)])
    if observed_trap != EXPECTED_TRAP_WORDS:
        failures.append(
            "trap opcodes differ: " + ",".join(f"{word:08x}" for word in observed_trap)
        )
    if len(words) < 3 or words[2] != 0x30529073:
        failures.append("startup word 2 is not csrrw x0,mtvec,x5")

    padded_words = words + [NOP] * (IMEM_WORDS - len(words))
    args.word_hex.parent.mkdir(parents=True, exist_ok=True)
    args.word_hex.write_text("".join(f"{word:08x}\n" for word in padded_words))

    result = {
        "status": "PASS" if not failures else "FAIL",
        "imem_limit_bytes": IMEM_BYTES,
        "imem_used_bytes": len(image),
        "imem_free_bytes": IMEM_BYTES - len(image),
        "symbols": {name: f"0x{value:08x}" for name, value in sorted(symbols.items())},
        "expected_trap_words": [f"0x{word:08x}" for word in EXPECTED_TRAP_WORDS],
        "observed_trap_words": [f"0x{word:08x}" for word in observed_trap],
        "hashes": {
            "elf_sha256": sha256(args.elf),
            "map_sha256": sha256(args.map_file),
            "imem_bin_sha256": sha256(args.imem_bin),
            "word_hex_sha256": sha256(args.word_hex),
        },
        "failures": failures,
    }
    args.result_json.parent.mkdir(parents=True, exist_ok=True)
    args.result_json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
