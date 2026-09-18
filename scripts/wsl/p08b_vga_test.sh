#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/p08b_vga"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*)
        echo 'RUN_ROOT must be outside the public checkout' >&2
        exit 2
        ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

sources=(
    rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v
    rtl/video/vram/HW_Cleaner.v
    rtl/video/vga/VGA_SyncGen.v
    rtl/soc/reset_release_sync.v
    verification/models/clock/vga_pll.sv
    verification/models/memory/VRAM.sv
    verification/directed/vga/tb_p08b_vga.sv
)

iverilog -g2012 -s tb_p08b_vga -o "$run_dir/p08b_vga.vvp" "${sources[@]}" \
    > "$run_dir/compile.log" 2>&1
vvp "$run_dir/p08b_vga.vvp" > "$run_dir/run.log" 2>&1
grep -q 'SUMMARY: PASS P08B VGA focused RTL' "$run_dir/run.log"

verilator --lint-only --top-module AHB_VRAM_DUAL_BUFFER \
    "${sources[@]:0:6}" > "$run_dir/lint.log" 2>&1

sha256sum "${sources[@]}" > "$run_dir/source_hashes.sha256"
echo 'SUMMARY: PASS P08B VGA focused RTL and lint'
