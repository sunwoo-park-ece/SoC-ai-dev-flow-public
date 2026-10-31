#!/usr/bin/env python3
"""Bounded source audit of the pinned VGA shape; NOT a Verilog/CDC engine.

Icarus elaboration and independent manual endpoint/semantic review are required
companions. These checks do not qualify vendor primitives or physical timing.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path


def strip_comments(text):
    return re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: "\n" * m[0].count("\n"), text, flags=re.S)


def always_regions(text):
    regions = []
    for match in re.finditer(r"always\s*@\s*\(([^)]*)\)\s*begin\b", text):
        depth = 1
        end = None
        for word in re.finditer(r"\bbegin\b|\bend\b", text[match.end():]):
            depth += 1 if word[0] == "begin" else -1
            if depth == 0:
                end = match.end() + word.end()
                break
        if end is None:
            raise ValueError("unterminated always block")
        regions.append((match[1], text[match.end():end]))
    return regions


def audit(vga, reset):
    v, r = strip_comments(vga), strip_comments(reset)
    checks = []
    def check(cid, ok, detail):
        checks.append({"id": cid, "passed": bool(ok), "detail": detail})
    regions = always_regions(v)
    chains = [
        ("C01", "request_toggle_h", "req_meta_p", "req_sync_p", "pclk_25", "vga_reset_n"),
        ("C02", "ack_toggle_p", "ack_meta_h", "ack_sync_h", "HCLK", "h_epoch_valid"),
        ("C03", "pixel_ready_p", "pixel_ready_h1", "pixel_ready_h2", "HCLK", "h_epoch_valid"),
        ("C04", "vga_vsync_sig", "vsync_h1", "vsync_h2", "HCLK", "HRESETn"),
        ("C05", "vga_pll_locked", "pll_lock_h1", "pll_lock_h2", "HCLK", "HRESETn"),
    ]
    for cid, source, first, second, clock, rst in chains:
        expected_event = f"posedge {clock} or negedge {rst}"
        block = [b for ev, b in regions if re.sub(r"\s+", " ", ev.strip()) == expected_event
                 and re.search(rf"\b{first}\s*<=\s*{source}\s*;", b)]
        ok = len(block) == 1 and bool(re.search(rf"\b{second}\s*<=\s*{first}\s*;", block[0]))
        check(cid + "_CHAIN", ok, {"source": source, "first": first, "second": second,
                                   "clock": clock, "reset": rst})
        # Remove only declaration, assignment LHS, and approved second-stage RHS.
        # Any remaining first-stage token is an unapproved functional use.
        uses = re.sub(rf"\breg\s+{first}\s*;", "", v)
        uses = re.sub(rf"\b{first}(?=\s*<=)", "", uses)
        uses = re.sub(rf"\b{second}\s*<=\s*{first}\s*;", "", uses)
        check(cid + "_ISOLATION", not re.search(rf"\b{first}\b", uses), "first stage only feeds second")

    raw = []
    for m in re.finditer(r"(?:wire\s+(?:\[[^]]+\]\s*)?|assign\s+)(\w+)\s*=\s*([^;]+);", v):
        if re.search(r"\bvga_pll_locked\b", m[2]):
            raw.append({"sink": m[1], "expression": m[2].strip()})
    for m in re.finditer(r"\b(\w+)\s*<=\s*([^;]+);", v):
        if re.search(r"\bvga_pll_locked\b", m[2]):
            raw.append({"sink": m[1], "expression": m[2].strip()})
    for instance in ["u_vga_reset_sync", "u_h_epoch_sync"]:
        m = re.search(rf"reset_release_sync\s+{instance}\s*\((.*?)\);", v, re.S)
        ports = dict(re.findall(r"\.(\w+)\s*\(([^()]*)\)", m[1])) if m else {}
        if re.search(r"\bvga_pll_locked\b", ports.get("async_reset_n", "")):
            raw.append({"sink": instance + ".async_reset_n", "expression": ports["async_reset_n"].strip()})
        expected_clk, expected_out = (("pclk_25", "vga_reset_n") if instance == "u_vga_reset_sync"
                                      else ("HCLK", "h_epoch_valid"))
        check("RESET_ROUTE_" + instance,
              ports.get("clk", "").strip() == expected_clk
              and ports.get("reset_n", "").strip() == expected_out
              and ports.get("async_reset_n", "").replace(" ", "") == "HRESETn&vga_pll_locked"
              and not re.search(rf"assign\s+{expected_out}\s*=", v),
              {"clock": expected_clk, "output": expected_out, "ports": ports})
    expected_raw = {"clear_abort", "data_commit_blocked", "physical_write", "pll_lock_h1",
                    "u_vga_reset_sync.async_reset_n", "u_h_epoch_sync.async_reset_n"}
    check("RAW_LOCK_SINK_SET", {x["sink"] for x in raw} == expected_raw, raw)
    # Token-count consistency rejects any uncatalogued occurrence of raw lock.
    raw_without_decl = re.sub(r"wire\s+vga_pll_locked\s*;", "", v)
    raw_without_driver = re.sub(r"\.locked\s*\(vga_pll_locked\)", "", raw_without_decl)
    check("RAW_LOCK_COMPLETE", len(re.findall(r"\bvga_pll_locked\b", raw_without_driver)) == len(raw),
          "all remaining raw-lock references represented by direct sinks")
    check("RESET_PRIMITIVE", bool(re.search(r"STAGES\s*=\s*2", r))
          and "posedge clk or negedge async_reset_n" in r
          and "sync_ff <= {STAGES{1'b0}}" in r
          and "sync_ff <= {sync_ff[STAGES-2:0], 1'b1}" in r
          and "reset_n = sync_ff[STAGES-1]" in r,
          "async-low assertion, default two destination edges; stopped clock cannot shift release")
    pixel_blocks = [b for ev, b in regions if "posedge pclk_25" in ev]
    forbidden = ["HWDATA", "front_bank_h", "operation_busy", "operation_clear", "operation_swap"]
    check("PIXEL_CONTROL_LOCALITY", all(not re.search(rf"\b{x}\b", b) for b in pixel_blocks for x in forbidden),
          "no sampled HCLK command/bank/busy vector in pixel always blocks")
    ram_ports = {}
    for bank in [0, 1]:
        m = re.search(rf"VRAM\s+u_VRAM{bank}\s*\((.*?)\);", v, re.S)
        ports = dict(re.findall(r"\.(\w+)\s*\(([^()]*)\)", m[1])) if m else {}
        ram_ports[str(bank)] = {k: x.strip() for k, x in ports.items()}
        check("RAM_PORTS_" + str(bank), ram_ports[str(bank)] == {
            "data": "write_data", "rd_aclr": "~vga_reset_n", "rdaddress": "vram_read_addr",
            "rdclock": "pclk_25", "wraddress": "write_addr", "wrclock": "HCLK",
            "wren": f"vram{bank}_we", "q": f"vram{bank}_q"}, "dual-clock boundary wiring only")
    return {"claim": "BOUNDED_SOURCE_CHECKS_ONLY_NOT_CDC_SIGNOFF", "checks": checks,
            "raw_lock_sinks": raw, "ram_ports": ram_ports,
            "failed_ids": [x["id"] for x in checks if not x["passed"]]}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vga", required=True, type=Path)
    p.add_argument("--reset", required=True, type=Path)
    args = p.parse_args()
    result = audit(args.vga.read_text(), args.reset.read_text())
    result["input_sha256"] = {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in [args.vga, args.reset]}
    print(json.dumps(result, indent=2))
    return 1 if result["failed_ids"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
