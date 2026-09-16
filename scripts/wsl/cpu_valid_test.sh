#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/cpu_valid"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the public checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done

iverilog -g2012 -DVALID_INFRA -s tb_fetch_valid -o "$run_dir/fetch.vvp" \
    rtl/core/v/pipeline_regs/IF_ID_Register.v verification/models/memory/IMEM.sv \
    verification/directed/cpu/tb_fetch_valid.sv \
    > "$run_dir/fetch.compile.log" 2>&1
vvp "$run_dir/fetch.vvp" > "$run_dir/fetch.run.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/fetch.run.log"
echo 'PASS fetch'

iverilog -g2012 -s tb_pipeline_valid -o "$run_dir/pipeline.vvp" \
    "${includes[@]}" "${all_sources[@]}" \
    verification/directed/cpu/tb_pipeline_valid.sv \
    > "$run_dir/pipeline.compile.log" 2>&1
vvp "$run_dir/pipeline.vvp" > "$run_dir/pipeline.run.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/pipeline.run.log"
echo 'PASS pipeline'
echo 'SUMMARY: PASS CPU fetch/stage-valid directed suite'
