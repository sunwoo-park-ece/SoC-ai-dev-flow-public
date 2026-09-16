#!/usr/bin/env python3
import argparse
from pathlib import Path


def bin_to_words(bin_path: Path, depth: int):
    raw = bin_path.read_bytes() if bin_path.exists() else b""
    words = [0] * depth

    max_bytes = depth * 4
    use_bytes = min(len(raw), max_bytes)
    word_count = (use_bytes + 3) // 4

    for idx in range(word_count):
        chunk = raw[idx * 4 : idx * 4 + 4]
        if len(chunk) < 4:
            chunk += b"\x00" * (4 - len(chunk))
        words[idx] = int.from_bytes(chunk, byteorder="little", signed=False)

    overflow = len(raw) - max_bytes
    return words, overflow if overflow > 0 else 0


def write_mif(out_path: Path, depth: int, words):
    with out_path.open("w", encoding="ascii") as handle:
        handle.write(f"DEPTH = {depth};\n")
        handle.write("WIDTH = 32;\n")
        handle.write("ADDRESS_RADIX = DEC;\n")
        handle.write("DATA_RADIX = HEX;\n\n")
        handle.write("CONTENT BEGIN\n")
        for idx, value in enumerate(words):
            handle.write(f"\t{idx} : {value:08X};\n")
        handle.write("END;\n")


def main():
    parser = argparse.ArgumentParser(description="Convert little-endian binary to Quartus MIF (32-bit words).")
    parser.add_argument("--bin", required=True, help="Input binary path")
    parser.add_argument("--depth", type=int, required=True, help="Word depth")
    parser.add_argument("--out", required=True, help="Output MIF path")
    args = parser.parse_args()

    bin_path = Path(args.bin)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    words, overflow = bin_to_words(bin_path, args.depth)
    write_mif(out_path, args.depth, words)

    print(f"[OK] {out_path} generated from {bin_path}")
    if overflow:
        print(f"[WARN] input overflow: {overflow} bytes truncated")


if __name__ == "__main__":
    main()

