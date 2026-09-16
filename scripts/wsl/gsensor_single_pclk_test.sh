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
    iverilog -g2012 -s "$top" -o "$run_dir/$name.vvp" \
        "$@" > "$run_dir/$name.compile.log" 2>&1
    vvp "$run_dir/$name.vvp" > "$run_dir/$name.run.log" 2>&1
    rg -q 'SUMMARY: PASS' "$run_dir/$name.run.log"
    echo "PASS $name"
}

run_test legacy_replacement tb_gsensor_replacements \
    rtl/peripherals/gsensor/reset_delay.v "$sensor_rtl" \
    verification/directed/models/gsensor/tb_gsensor_replacements.sv
run_test single_pclk tb_gsensor_single_pclk \
    "$wrapper_rtl" rtl/peripherals/gsensor/reset_delay.v "$sensor_rtl" \
    verification/directed/models/gsensor/tb_gsensor_single_pclk.sv

echo 'SUMMARY: PASS GSensor focused single-PCLK suite'
