#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT to an output directory outside the public checkout}"
run_dir="${RUN_ROOT}/de10_lite/modelsim/${1:-manual}"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"
vlib "$run_dir/work" > "$run_dir/vlib.log" 2>&1
mapfile -t grouped_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_MIXED_MODELSIM --group)
vhdl_sources=()
verilog_sources=()
for group_line in "${grouped_sources[@]}"; do
    group=${group_line%%$'\t'*}
    source_file=${group_line#*$'\t'}
    if [[ $group == aes_vhdl_dependency_order ]]; then
        vhdl_sources+=("$source_file")
    else
        verilog_sources+=("$source_file")
    fi
done
vcom -2008 -work "$run_dir/work" "${vhdl_sources[@]}" > "$run_dir/vcom.log" 2>&1
vlog_includes=()
while IFS= read -r dir; do vlog_includes+=("+incdir+$dir"); done < <(find rtl/core/v -type d | sort)
vlog -sv -work "$run_dir/work" "${vlog_includes[@]}" \
    "${verilog_sources[@]}" verification/directed/fpga/tb_open_soc_smoke.sv \
    > "$run_dir/vlog.log" 2>&1
(cd "$run_dir" && vsim -c -lib "$run_dir/work" tb_open_soc_smoke \
    -do 'run -all; quit -f') > "$run_dir/vsim.log" 2>&1
grep -q 'SUMMARY: PASS mixed-language SoC structural smoke' "$run_dir/vsim.log"
echo 'SUMMARY: PASS mixed-language SoC structural smoke'
