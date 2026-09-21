#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
mode="${1:-}"
case "$mode" in ""|--inject-bad-expectation) ;; *) echo "usage: $0 [--inject-bad-expectation]" >&2; exit 2 ;; esac
run_name="hex_s0"
[[ "$mode" == "--inject-bad-expectation" ]] && run_name="hex_s0_injected_bad_expectation"
run_dir="$RUN_ROOT/p10-hex/$run_name"
case "$(realpath -m "$run_dir")" in "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside public checkout" >&2; exit 2 ;; esac
mkdir -p "$run_dir"
cd "$repo_root"
iverilog -g2012 -s tb_hex_s0_apb -o "$run_dir/tb_hex_s0_apb.vvp" rtl/peripherals/APB_HEX_display.v verification/directed/hex/tb_hex_s0_apb.sv >"$run_dir/compile.log" 2>&1
if [[ "$mode" == "--inject-bad-expectation" ]]; then
    vvp "$run_dir/tb_hex_s0_apb.vvp" +INJECT_BAD_EXPECTATION >"$run_dir/run.log" 2>&1
else
    vvp "$run_dir/tb_hex_s0_apb.vvp" >"$run_dir/run.log" 2>&1
fi
grep -q 'SUMMARY: PASS HEX S0' "$run_dir/run.log"
echo "PASS $run_name"
