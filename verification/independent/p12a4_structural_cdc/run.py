#!/usr/bin/env python3
"""Small isolated sensitivity runner. Does not execute RTL simulation."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--run", required=True, type=Path)
    ap.add_argument("--lane", choices=["control", "missing_stage", "reset_bypass", "missing_record"], required=True)
    args = ap.parse_args()
    lane = args.run / args.lane
    lane.mkdir(exist_ok=False)
    source = args.repo / "rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v"
    reset = args.repo / "rtl/soc/reset_release_sync.v"
    checker = Path(__file__).with_name("audit.py")
    before = {str(p): digest(p) for p in [source, reset, checker, Path(__file__)]}
    selected = source
    expected = None
    activation = None
    text = source.read_text()
    if args.lane == "missing_stage":
        old = "req_sync_p    <= req_meta_p;"
        new = "req_sync_p    <= request_toggle_h;"
        if text.count(old) != 1:
            raise RuntimeError("fixture injection did not identify exactly one assignment")
        selected = lane / "vga_fixture.v"
        selected.write_text(text.replace(old, new))
        expected = "C01_CHAIN"
        activation = {"old": old, "new": new, "count": 1}
    elif args.lane == "reset_bypass":
        pattern = r"reset_release_sync\s+u_vga_reset_sync\s*\(.*?\);"
        mutated, count = re.subn(pattern, "assign vga_reset_n = HRESETn & vga_pll_locked;", text, flags=re.S)
        if count != 1:
            raise RuntimeError("reset bypass injection did not reach exactly one route")
        selected = lane / "vga_fixture.v"
        selected.write_text(mutated)
        expected = "RESET_ROUTE_u_vga_reset_sync"
        activation = {"removed_instance": "u_vga_reset_sync", "replacement": "raw-reset assignment", "count": count}
    commands = []
    def execute(name, argv):
        p = subprocess.run(argv, cwd=args.repo, capture_output=True, timeout=30)
        (lane / (name + ".stdout")).write_bytes(p.stdout)
        (lane / (name + ".stderr")).write_bytes(p.stderr)
        commands.append({"name": name, "argv": argv, "exit": p.returncode,
                         "stdout_sha256": digest(lane / (name + ".stdout")),
                         "stderr_sha256": digest(lane / (name + ".stderr"))})
        return p
    compile_exit = None
    if expected:
        dependencies = ["rtl/video/vram/HW_Cleaner.v", "rtl/video/vga/VGA_SyncGen.v",
                        "rtl/soc/reset_release_sync.v", "verification/models/clock/vga_pll.sv",
                        "verification/models/memory/VRAM.sv"]
        p = execute("fixture-elaboration", ["iverilog", "-g2012", "-tnull", "-s", "AHB_VRAM_DUAL_BUFFER",
                    "-o", str(lane / "fixture.null"), str(selected)] + dependencies)
        compile_exit = p.returncode
    target = execute("checker", [sys.executable, str(checker), "--vga", str(selected), "--reset", str(reset)])
    guard_errors = []
    try:
        record = json.loads(target.stdout)
        if args.lane == "missing_record":
            record = None  # isolated observation-input self-test; original stdout retained
        if not record:
            guard_errors.append("EVIDENCE_REQUIRED_RECORD")
        else:
            wanted = {str(p): digest(p) for p in [selected, reset]}
            if record.get("input_sha256") != wanted:
                guard_errors.append("EVIDENCE_INPUT_IDENTITY")
            if not record.get("checks") or len(record["checks"]) != 18:
                guard_errors.append("EVIDENCE_CHECK_SET")
            failed = record.get("failed_ids")
            if not isinstance(failed, list) or target.returncode != (1 if failed else 0):
                guard_errors.append("EVIDENCE_EXIT_SEMANTICS")
            if expected and (expected not in failed or compile_exit != 0):
                guard_errors.append("SENSITIVITY_EXPECTED_ID_OR_ELABORATION")
            if not expected and failed:
                guard_errors.append("CONTROL_REJECTED")
    except (ValueError, TypeError, KeyError):
        record = None
        guard_errors.append("EVIDENCE_PARSE")
    unchanged = all(digest(Path(p)) == h for p, h in before.items())
    if not unchanged:
        guard_errors.append("SOURCE_IDENTITY_DRIFT")
    final_exit = 1 if guard_errors else 0
    classification = "BLOCK" if guard_errors else ("SELFTEST_EXPECTED_REJECTION" if expected else "STRUCTURAL_CHECK_CONTROL_PASS")
    result = {"lane": args.lane, "claim": "SOURCE_CHECK_SENSITIVITY_ONLY",
              "classification": classification, "target_exit": target.returncode,
              "guard_exit": int(bool(guard_errors)), "final_exit": final_exit,
              "compile_exit": compile_exit, "expected_id": expected,
              "observed_failed_ids": record.get("failed_ids") if record else None,
              "guard_errors": guard_errors, "activation": activation,
              "fixture_sha256": digest(selected), "source_hashes_unchanged": unchanged,
              "source_pre": before, "source_post": {p: digest(Path(p)) for p in before}, "commands": commands}
    (lane / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return final_exit


if __name__ == "__main__":
    raise SystemExit(main())
