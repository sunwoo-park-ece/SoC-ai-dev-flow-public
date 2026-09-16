#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
run_id="${1:-p06b_timer_01}"
run_dir="${RUN_ROOT}/open_sim/${run_id}"
case "$(realpath -m "$run_dir")" in
    "$repo_root"|"$repo_root"/*) echo "RUN_ROOT must be outside the public checkout" >&2; exit 2 ;;
esac
mkdir -p "$run_dir"
cd "$repo_root"

iverilog -g2012 -s tb_p06b_timer -o "$run_dir/p06b_timer.vvp" \
    rtl/peripherals/APB_TIMER.v rtl/bus/AHB_APB_bridge.v \
    verification/directed/timer/tb_p06b_timer.sv \
    > "$run_dir/p06b_timer.compile.log" 2>&1
vvp "$run_dir/p06b_timer.vvp" > "$run_dir/p06b_timer.run.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/p06b_timer.run.log"
echo 'PASS p06b_timer_directed'

verilator --lint-only --sv --timing --relative-includes -Wno-fatal \
    --top-module tb_p06b_timer \
    rtl/peripherals/APB_TIMER.v rtl/bus/AHB_APB_bridge.v \
    verification/directed/timer/tb_p06b_timer.sv \
    > "$run_dir/p06b_timer.verilator.log" 2>&1
echo 'PASS p06b_timer_verilator'

"${HOST_CC:-gcc}" -std=c11 -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined -I "$repo_root/firmware/include" \
    -include "$repo_root/verification/firmware/p06b_timer_mmio.h" \
    "$repo_root/firmware/drivers/timer.c" \
    "$repo_root/verification/firmware/p06b_timer_host.c" \
    -o "$run_dir/p06b_timer_host"
"$run_dir/p06b_timer_host" > "$run_dir/p06b_timer_host.log" 2>&1
grep -q 'SUMMARY: PASS' "$run_dir/p06b_timer_host.log"
echo 'PASS p06b_timer_firmware_host'

if rg -n 'TIMER_CTRL_ENABLE|timer_count_raw|timer_counter_reset_zero|mmio_(read|write)32\(TIMER_BASE' \
    firmware/apps/final_main.c \
    > "$run_dir/legacy_timer_usage.log"; then
    echo 'Legacy Timer application access remains' >&2
    exit 1
fi
rg -n -U 'timer_clear_ready\(\);\n[[:space:]]*timer_start\(TIMER_TIMEBASE_COMPARE\);' \
    firmware/apps/final_main.c > "$run_dir/final_main_rearm.log"
echo 'PASS p06b_timer_application_structure'

sha256sum \
    rtl/peripherals/APB_TIMER.v rtl/soc/AMBA_SoC_TOP.v \
    firmware/include/timer.h firmware/drivers/timer.c \
    firmware/apps/final_main.c \
    verification/directed/timer/tb_p06b_timer.sv \
    verification/firmware/p06b_timer_host.c \
    > "$run_dir/source_hashes.sha256"

echo 'SUMMARY: PASS P06B focused Timer verification'
