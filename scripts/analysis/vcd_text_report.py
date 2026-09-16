#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert VCD waveform into text reports (summary + transitions)."
    )
    parser.add_argument("vcd", type=Path, help="Input VCD file path")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("sim/logs/wave_text"),
        help="Output directory",
    )
    parser.add_argument(
        "--prefix",
        default="wave",
        help="Output file prefix (default: wave)",
    )
    parser.add_argument(
        "--include",
        action="append",
        default=[],
        help="Regex filter for full signal name (repeatable)",
    )
    parser.add_argument(
        "--max-events",
        type=int,
        default=200000,
        help="Max transitions rows to write (default: 200000)",
    )
    return parser.parse_args()


def normalize_vector(value: str) -> str:
    value = value.strip().lower()
    if not value:
        return value
    return value


def name_selected(name: str, patterns: list[re.Pattern[str]]) -> bool:
    if not patterns:
        return True
    return any(p.search(name) for p in patterns)


def run(vcd_path: Path, out_dir: Path, prefix: str, include: list[str], max_events: int) -> None:
    if not vcd_path.exists():
        raise FileNotFoundError(f"VCD not found: {vcd_path}")

    out_dir.mkdir(parents=True, exist_ok=True)
    summary_csv = out_dir / f"{prefix}_summary.csv"
    events_csv = out_dir / f"{prefix}_transitions.csv"
    meta_txt = out_dir / f"{prefix}_meta.txt"

    patterns = [re.compile(p) for p in include]

    scopes: list[str] = []
    id_to_name: dict[str, str] = {}
    selected_ids: set[str] = set()

    current_time = 0
    timescale = "unknown"

    last_value: dict[str, str] = {}
    first_time: dict[str, int] = {}
    last_time: dict[str, int] = {}
    toggle_count: defaultdict[str, int] = defaultdict(int)
    xz_count: defaultdict[str, int] = defaultdict(int)

    events_written = 0

    with vcd_path.open("r", encoding="utf-8", errors="replace") as f, events_csv.open(
        "w", newline="", encoding="utf-8"
    ) as ef:
        ew = csv.writer(ef)
        ew.writerow(["time", "signal", "old", "new"])

        for raw in f:
            line = raw.strip()
            if not line:
                continue

            if line.startswith("$timescale"):
                # supports single-line style: $timescale 1ns $end
                ts = line.replace("$timescale", "").replace("$end", "").strip()
                if ts:
                    timescale = ts
                continue

            if line.startswith("$scope"):
                tokens = line.split()
                if len(tokens) >= 3:
                    scopes.append(tokens[2])
                continue

            if line.startswith("$upscope"):
                if scopes:
                    scopes.pop()
                continue

            if line.startswith("$var"):
                # Example: $var wire 1 ! clk $end
                tokens = line.split()
                if len(tokens) >= 5:
                    symbol = tokens[3]
                    ref = tokens[4]
                    suffix = ""
                    if len(tokens) > 5 and tokens[5] != "$end":
                        suffix = f" {tokens[5]}"
                    full_name = ".".join(scopes + [f"{ref}{suffix}"])
                    id_to_name[symbol] = full_name
                    if name_selected(full_name, patterns):
                        selected_ids.add(symbol)
                continue

            if line.startswith("#"):
                try:
                    current_time = int(line[1:])
                except ValueError:
                    pass
                continue

            symbol = None
            new_val = None

            # scalar: 0!, 1!, x!, z!
            if line[0] in "01xXzZ" and len(line) >= 2:
                new_val = line[0].lower()
                symbol = line[1:].strip()
            # vector: b1010 !
            elif line[0] in "bB":
                parts = line[1:].strip().split()
                if len(parts) == 2:
                    new_val = normalize_vector(parts[0])
                    symbol = parts[1]

            if symbol is None or new_val is None:
                continue
            if symbol not in selected_ids:
                continue

            signal_name = id_to_name.get(symbol, symbol)
            old_val = last_value.get(symbol)

            if old_val is None:
                first_time[symbol] = current_time
                last_value[symbol] = new_val
                last_time[symbol] = current_time
                if "x" in new_val or "z" in new_val:
                    xz_count[symbol] += 1
                continue

            if old_val != new_val:
                toggle_count[symbol] += 1
                last_time[symbol] = current_time
                if "x" in new_val or "z" in new_val:
                    xz_count[symbol] += 1

                if events_written < max_events:
                    ew.writerow([current_time, signal_name, old_val, new_val])
                    events_written += 1

                last_value[symbol] = new_val

    with summary_csv.open("w", newline="", encoding="utf-8") as sf:
        sw = csv.writer(sf)
        sw.writerow([
            "signal",
            "toggles",
            "first_time",
            "last_time",
            "last_value",
            "xz_events",
        ])
        for symbol, name in sorted(id_to_name.items(), key=lambda x: x[1]):
            if symbol not in selected_ids:
                continue
            sw.writerow(
                [
                    name,
                    toggle_count.get(symbol, 0),
                    first_time.get(symbol, ""),
                    last_time.get(symbol, ""),
                    last_value.get(symbol, ""),
                    xz_count.get(symbol, 0),
                ]
            )

    with meta_txt.open("w", encoding="utf-8") as mf:
        mf.write(f"vcd={vcd_path}\n")
        mf.write(f"timescale={timescale}\n")
        mf.write(f"signals_selected={len(selected_ids)}\n")
        mf.write(f"events_written={events_written}\n")
        mf.write(f"summary_csv={summary_csv}\n")
        mf.write(f"transitions_csv={events_csv}\n")

    print(f"[OK] summary: {summary_csv}")
    print(f"[OK] transitions: {events_csv}")
    print(f"[OK] meta: {meta_txt}")


def main() -> int:
    args = parse_args()
    run(args.vcd, args.out_dir, args.prefix, args.include, args.max_events)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
