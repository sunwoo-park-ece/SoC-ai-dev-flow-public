#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT to an output directory outside the public checkout}"
run_id="${1:-p05b_reset_clock_async_01}"
run_dir="${RUN_ROOT}/open_sim/${run_id}"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

run_test() {
    local name="$1" top="$2"; shift 2
    iverilog -g2012 -s "$top" -o "$run_dir/$name.vvp" "$@" \
        > "$run_dir/$name.compile.log" 2>&1
    vvp "$run_dir/$name.vvp" > "$run_dir/$name.run.log" 2>&1
    grep -q 'SUMMARY: PASS' "$run_dir/$name.run.log"
    echo "PASS $name"
}

run_test reset_adc_aux tb_p05b_reset_adc_aux \
    rtl/soc/system_reset_controller.v rtl/soc/reset_release_sync.v \
    rtl/soc/adc_command_sequencer.v rtl/peripherals/APB_UART_LORA_RT.v \
    verification/directed/reset_clock/tb_p05b_reset_adc_aux.sv

run_test vga_reset tb_p05b_vga_reset \
    rtl/soc/reset_release_sync.v rtl/video/vga/VGA_SyncGen.v \
    rtl/video/vram/HW_Cleaner.v rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v \
    verification/models/memory/VRAM.sv verification/models/clock/vga_pll.sv \
    verification/directed/reset_clock/tb_p05b_vga_reset.sv

run_test uart_rx tb_p05b_uart_rx_regression \
    rtl/peripherals/APB_UART_LORA_RT.v rtl/peripherals/APB_UART_RT.v \
    verification/directed/reset_clock/tb_p05b_uart_rx_regression.sv

verilator --lint-only --sv --timing --relative-includes -Wno-fatal \
    --top-module tb_p05b_reset_adc_aux \
    rtl/soc/system_reset_controller.v rtl/soc/reset_release_sync.v \
    rtl/soc/adc_command_sequencer.v rtl/peripherals/APB_UART_LORA_RT.v \
    verification/directed/reset_clock/tb_p05b_reset_adc_aux.sv \
    > "$run_dir/verilator_reset_adc_aux.log" 2>&1

sha256sum \
    rtl/soc/system_reset_controller.v rtl/soc/reset_release_sync.v \
    rtl/soc/adc_command_sequencer.v rtl/soc/AMBA_SoC_TOP.v \
    rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v \
    rtl/peripherals/APB_UART_LORA_RT.v verification/models/clock/vga_pll.sv \
    verification/directed/reset_clock/tb_p05b_reset_adc_aux.sv \
    verification/directed/reset_clock/tb_p05b_vga_reset.sv \
    verification/directed/reset_clock/tb_p05b_uart_rx_regression.sv \
    > "$run_dir/source_hashes.sha256"

echo 'SUMMARY: PASS P05B focused reset/clock/async verification'
