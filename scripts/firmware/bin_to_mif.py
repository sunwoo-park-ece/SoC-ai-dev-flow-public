#!/usr/bin/env python3
import argparse
from pathlib import Path


def read_words(path):
    data = Path(path).read_bytes()
    words = []
    for idx in range(0, len(data), 4):
        chunk = data[idx:idx + 4]
        chunk = chunk + (b"\x00" * (4 - len(chunk)))
        words.append(int.from_bytes(chunk, byteorder="little"))
    return words


def write_mif(path, words, depth):
    if len(words) > depth:
        raise SystemExit(f"binary has {len(words)} words, exceeds MIF depth {depth}")

    with Path(path).open("w", encoding="ascii") as f:
        f.write(f"DEPTH = {depth};\n")
        f.write("WIDTH = 32;\n")
        f.write("ADDRESS_RADIX = DEC;\n")
        f.write("DATA_RADIX = HEX;\n\n")
        f.write("CONTENT BEGIN\n")
        for addr in range(depth):
            value = words[addr] if addr < len(words) else 0
            f.write(f"\t{addr} : {value:08X};\n")
        f.write("END;\n")


def main():
    parser = argparse.ArgumentParser(description="Convert a little-endian binary section to Quartus MIF.")
    parser.add_argument("--bin", required=True, dest="bin_path")
    parser.add_argument("--depth", required=True, type=int)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    write_mif(args.out, read_words(args.bin_path), args.depth)


if __name__ == "__main__":
    main()
