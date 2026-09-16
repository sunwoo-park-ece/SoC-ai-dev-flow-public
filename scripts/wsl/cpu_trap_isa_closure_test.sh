#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/cpu_trap_isa_closure"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the public checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"
mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done
iverilog -g2012 -s tb_trap_isa_closure -o "$run_dir/trap_isa.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/cpu/tb_trap_isa_closure.sv \
    > "$run_dir/trap_isa.compile.log" 2>&1
vvp "$run_dir/trap_isa.vvp" > "$run_dir/trap_isa.run.log" 2>&1
grep -q 'SUMMARY: PASS 3B3' "$run_dir/trap_isa.run.log"
iverilog -g2012 -s tb_mepc_storage -o "$run_dir/mepc_storage.vvp" \
    "${includes[@]}" \
    rtl/core/v/id_stage/CSR_File.v \
    verification/directed/cpu/tb_mepc_storage.sv \
    > "$run_dir/mepc_storage.compile.log" 2>&1
vvp "$run_dir/mepc_storage.vvp" > "$run_dir/mepc_storage.run.log" 2>&1
grep -q 'SUMMARY: PASS mepc' "$run_dir/mepc_storage.run.log"
echo "SUMMARY: PASS 3B3 trap/ISA focused suite"
