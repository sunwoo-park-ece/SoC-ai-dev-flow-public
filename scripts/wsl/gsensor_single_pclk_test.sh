#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_dir="${RUN_ROOT}/gsensor_single_pclk/${1:-manual}"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

finalize() {
    local final_exit=$?
    local status=FAIL
    trap - EXIT
    if [[ $final_exit -eq 0 ]]; then status=PASS; fi
    printf '{"status":"%s","final_exit":%d}\n' "$status" "$final_exit" > "$run_dir/summary.json"
    printf '# GSensor focused suite\n\nStatus: %s\nFinal exit: %d\n' \
        "$status" "$final_exit" > "$run_dir/summary.md"
    exit "$final_exit"
}
trap finalize EXIT

sensor_rtl=rtl/peripherals/gsensor/spi_ee_config.v
wrapper_rtl=rtl/peripherals/gsensor/APB_GSENSOR_MB.v
if rg -q 'spi_pll[[:space:]]+u_spi_pll|iSPI_CLK|iSPI_CLK_OUT' "$wrapper_rtl" "$sensor_rtl"; then
    echo "FAIL: active G-sensor still uses the SPI PLL clock domain" >&2
    exit 1
fi
if ! rg -q 'always @\(posedge iPCLK or negedge iRSTN\)' "$sensor_rtl" ||
   ! rg -q 'int_meta <= iG_INT2;' "$sensor_rtl" ||
   ! rg -q 'int_sync <= int_meta;' "$sensor_rtl"; then
    echo "FAIL: single-PCLK or two-flop INT structure missing" >&2
    exit 1
fi
if [[ $(rg -c 'always @' "$sensor_rtl") != 2 ]]; then
    echo "FAIL: unexpected extra G-sensor sequential/combinational block" >&2
    exit 1
fi

run_test() {
    local name="$1" top="$2"; shift 2
    local compile_exit=0 target_exit=null guard_exit=null status=FAIL
    if iverilog -g2012 -s "$top" -o "$run_dir/$name.vvp" \
        "$@" > "$run_dir/$name.compile.log" 2>&1; then
        :
    else
        compile_exit=$?
    fi
    if [[ $compile_exit -eq 0 ]]; then
        if vvp "$run_dir/$name.vvp" > "$run_dir/$name.run.log" 2>&1; then
            target_exit=0
        else
            target_exit=$?
        fi
    fi
    if [[ $target_exit == 0 ]]; then
        if rg -q 'SUMMARY: PASS' "$run_dir/$name.run.log" > "$run_dir/$name.guard.log" 2>&1; then
            guard_exit=0
        else
            guard_exit=$?
        fi
    fi
    if [[ $compile_exit -eq 0 && $target_exit == 0 && $guard_exit == 0 ]]; then
        status=PASS
    fi
    printf '{"status":"%s","compile_exit":%d,"target_exit":%s,"guard_exit":%s}\n' \
        "$status" "$compile_exit" "$target_exit" "$guard_exit" > "$run_dir/$name.result.json"
    if [[ $compile_exit -ne 0 ]]; then return "$compile_exit"; fi
    if [[ $target_exit != 0 ]]; then return "$target_exit"; fi
    if [[ $guard_exit != 0 ]]; then return "$guard_exit"; fi
    echo "PASS $name"
}

run_test single_pclk tb_gsensor_single_pclk \
    "$wrapper_rtl" "$sensor_rtl" \
    verification/directed/models/gsensor/tb_gsensor_single_pclk.sv
run_test snapshot tb_gsensor_snapshot \
    "$wrapper_rtl" "$sensor_rtl" \
    verification/directed/models/gsensor/tb_gsensor_snapshot.sv
run_test reset_abort tb_gsensor_reset_abort \
    "$wrapper_rtl" "$sensor_rtl" \
    verification/directed/models/gsensor/tb_gsensor_snapshot.sv
run_test scheduler tb_gsensor_scheduler \
    "$sensor_rtl" \
    verification/directed/models/gsensor/tb_gsensor_scheduler.sv

echo 'SUMMARY: PASS GSensor P09B focused single-PCLK suite'
