#!/usr/bin/env python3
"""Resolve public build-profile source groups without machine-specific paths."""

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=("OPEN_SIM_VERILOG", "OPEN_SIM_MIXED_MODELSIM", "PRIVATE_QUARTUS"))
    parser.add_argument("--group", action="store_true", help="print group and path separated by a tab")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    manifest = json.loads((root / "fpga/quartus/build_profiles.json").read_text())
    seen: set[Path] = set()
    for group in manifest["profiles"][args.profile]["groups"]:
        for pattern in manifest["source_groups"][group]:
            matches = sorted(root.glob(pattern))
            if not matches:
                raise SystemExit(f"no source matches {pattern}")
            for path in matches:
                if not path.is_file() or path in seen:
                    continue
                seen.add(path)
                print(f"{group}\t{path}" if args.group else path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
