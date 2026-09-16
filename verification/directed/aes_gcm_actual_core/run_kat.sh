#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_id="${1:-aes001_kat}"
run_dir="${RUN_ROOT}/de10_lite/modelsim/${run_id}"
case "$(realpath -m "$run_dir")" in
  "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the public checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"
vlib "$run_dir/work" > "$run_dir/vlib.log" 2>&1
mapfile -t vhdl_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_MIXED_MODELSIM --group |
  awk -F '\t' '$1=="aes_vhdl_dependency_order" {print $2}')
vcom -2008 -work "$run_dir/work" "${vhdl_sources[@]}" > "$run_dir/vcom.log" 2>&1
vlog -sv -work "$run_dir/work" \
  rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v \
  verification/directed/aes_gcm_actual_core/tb_aes_gcm_actual_core_kat.sv \
  > "$run_dir/vlog.log" 2>&1
(cd "$run_dir" && vsim -c -lib "$run_dir/work" tb_aes_gcm_actual_core_kat \
  -do 'run -all; quit -f') > "$run_dir/vsim.log" 2>&1
grep -q 'SUMMARY: PASS six actual-core AES-128-GCM KATs' "$run_dir/vsim.log"
grep 'KAT .* PASS\|SUMMARY: PASS' "$run_dir/vsim.log"
