#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/bus_cpu_apb"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo 'RUN_ROOT must be outside the public checkout' >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

mapfile -t all_sources < <(python3 scripts/wsl/source_list.py OPEN_SIM_VERILOG)
mapfile -t cpu_dirs < <(find rtl/core/v -type d | sort)
includes=()
for dir in "${cpu_dirs[@]}"; do includes+=("-I$dir"); done

run_test() {
    local name="$1" top="$2"; shift 2
    iverilog -g2012 -s "$top" -o "$run_dir/$name.vvp" "$@" \
        > "$run_dir/$name.compile.log" 2>&1
    vvp "$run_dir/$name.vvp" > "$run_dir/$name.run.log" 2>&1
    grep -q 'SUMMARY: PASS' "$run_dir/$name.run.log"
    echo "PASS $name"
}
run_test hsize tb_ahb_master_hsize \
    rtl/bus/AHB_MASTER.v verification/directed/bus/tb_ahb_master_hsize.sv
run_test bridge tb_ahb_apb_bridge_fault \
    rtl/bus/AHB_APB_bridge.v verification/directed/bus/tb_ahb_apb_bridge_fault.sv
run_test p04_boardio tb_p04_boardio \
    rtl/peripherals/APB_GPIO.v rtl/peripherals/APB_SW.v rtl/peripherals/APB_LED.v \
    verification/directed/bus/tb_p04_boardio.sv
run_test decode tb_soc_bus_fault_decode \
    "${includes[@]}" "${all_sources[@]}" verification/directed/bus/tb_soc_bus_fault_decode.sv
run_test transitions tb_soc_bus_transitions \
    "${includes[@]}" "${all_sources[@]}" verification/directed/bus/tb_soc_bus_transitions.sv
run_test cpu_harness tb_cpu_access_fault \
    "${includes[@]}" "${all_sources[@]}" verification/directed/bus/tb_cpu_access_fault.sv
run_test cpu_soc_e2e tb_soc_cpu_fault_e2e \
    "${includes[@]}" "${all_sources[@]}" verification/directed/bus/tb_soc_cpu_fault_e2e.sv
echo 'SUMMARY: PASS CPU/AHB/APB directed suite'
