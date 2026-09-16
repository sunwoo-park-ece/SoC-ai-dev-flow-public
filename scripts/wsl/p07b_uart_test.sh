#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_id="${1:-p07b_uart_01}"
run_dir="${RUN_ROOT}/open_sim/${run_id}"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

iverilog -g2012 -s tb_p07b_uart_direct -o "$run_dir/uart_direct.vvp" \
    rtl/peripherals/APB_UART_RT.v rtl/peripherals/APB_UART_LORA_RT.v \
    verification/directed/uart/tb_p07b_uart_direct.sv \
    > "$run_dir/uart_direct.compile.log" 2>&1
vvp "$run_dir/uart_direct.vvp" > "$run_dir/uart_direct.run.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/uart_direct.run.log"
echo 'PASS p07b_uart_direct'

iverilog -g2012 -s tb_p07b_uart_ahb_wait -o "$run_dir/uart_ahb_wait.vvp" \
    rtl/bus/AHB_APB_bridge.v rtl/peripherals/APB_UART_RT.v \
    rtl/peripherals/APB_LED.v \
    verification/directed/uart/tb_p07b_uart_ahb_wait.sv \
    > "$run_dir/uart_ahb_wait.compile.log" 2>&1
vvp "$run_dir/uart_ahb_wait.vvp" > "$run_dir/uart_ahb_wait.run.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/uart_ahb_wait.run.log"
echo 'PASS p07b_uart_ahb_wait'

verilator --lint-only --sv --timing --relative-includes -Wno-fatal \
    --top-module tb_p07b_uart_direct \
    rtl/peripherals/APB_UART_RT.v rtl/peripherals/APB_UART_LORA_RT.v \
    verification/directed/uart/tb_p07b_uart_direct.sv \
    > "$run_dir/uart_direct.verilator.log" 2>&1
verilator --lint-only --sv --timing --relative-includes -Wno-fatal \
    --top-module tb_p07b_uart_ahb_wait \
    rtl/bus/AHB_APB_bridge.v rtl/peripherals/APB_UART_RT.v \
    rtl/peripherals/APB_LED.v \
    verification/directed/uart/tb_p07b_uart_ahb_wait.sv \
    > "$run_dir/uart_ahb_wait.verilator.log" 2>&1
echo 'PASS p07b_uart_verilator'

"${HOST_CC:-gcc}" -std=c11 -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined -I "$repo_root/firmware/include" \
    -include "$repo_root/verification/firmware/p07b_uart_mmio.h" \
    "$repo_root/firmware/drivers/uart.c" \
    "$repo_root/firmware/drivers/lora_uart.c" \
    "$repo_root/verification/firmware/p07b_uart_host.c" \
    -o "$run_dir/p07b_uart_host"
"$run_dir/p07b_uart_host" > "$run_dir/p07b_uart_host.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/p07b_uart_host.log"
echo 'PASS p07b_uart_firmware_host'

if rg -n 'while[[:space:]]*\([^)]*(tx_ready|aux_ready|TX_READY)|while[[:space:]]*\(!lora_uart_aux_ready' \
    firmware/drivers firmware/apps > "$run_dir/legacy_unbounded_uart_waits.log"; then
    echo 'Legacy unbounded UART/AUX wait remains' >&2
    exit 1
fi
if rg -n 'mmio_write32\(UART[01]_BASE[[:space:]]*\+[[:space:]]*UART_DATA' \
    firmware --glob '*.[ch]' > "$run_dir/raw_uart_data_writes.log"; then
    echo 'Raw production UART DATA write remains outside the UART driver' >&2
    exit 1
fi
echo 'PASS p07b_uart_application_structure'

sha256sum \
    rtl/peripherals/APB_UART_RT.v rtl/peripherals/APB_UART_LORA_RT.v \
    rtl/soc/AMBA_SoC_TOP.v rtl/bus/AHB_APB_bridge.v \
    firmware/include/uart.h firmware/drivers/uart.c \
    firmware/include/lora_uart.h firmware/drivers/lora_uart.c \
    firmware/apps/final_main.c \
    firmware/apps/lora_uart_aux_test.c firmware/apps/lora_rx_debug.c \
    verification/directed/uart/tb_p07b_uart_direct.sv \
    verification/directed/uart/tb_p07b_uart_ahb_wait.sv \
    verification/firmware/p07b_uart_host.c \
    > "$run_dir/source_hashes.sha256"

echo 'SUMMARY: PASS P07B focused UART verification'
