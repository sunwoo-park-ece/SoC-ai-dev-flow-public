#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/trap002"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the public checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"
mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done
iverilog -g2012 -s tb_trap_precision_interaction -o "$run_dir/interaction.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/cpu/tb_trap_precision_interaction.sv \
    > "$run_dir/interaction.compile.log" 2>&1
vvp "$run_dir/interaction.vvp" > "$run_dir/interaction.run.log" 2>&1
grep -q 'SUMMARY: PASS TRAP-002 interaction' "$run_dir/interaction.run.log"
iverilog -g2012 -s tb_trap_precision_apb_wait -o "$run_dir/apb_wait.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/cpu/tb_trap_precision_apb_wait.sv \
    > "$run_dir/apb_wait.compile.log" 2>&1
vvp "$run_dir/apb_wait.vvp" > "$run_dir/apb_wait.run.log" 2>&1
grep -q 'SUMMARY: PASS TRAP-002 APB precision' "$run_dir/apb_wait.run.log"
echo 'SUMMARY: PASS TRAP-002 precision interactions'
