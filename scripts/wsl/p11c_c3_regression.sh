#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
out="$RUN_ROOT/p11c_c3_regression"; mkdir -p "$out"

echo "=== P11C-C3 Regression Suite ==="

mapfile -t src < <(python3 "$root/scripts/wsl/source_list.py" OPEN_SIM_VERILOG)
mapfile -t dirs < <(find "$root/rtl/core/v" -type d | sort)
inc=()
for d in "${dirs[@]}"; do
    inc+=("-I$d")
done

# 1. Lint standalone modules & SoC Top
echo "--- Lint: Joystick_Policy.v ---"
verilator --lint-only -Wall -Wno-fatal "$root/rtl/peripherals/Joystick_Policy.v" > "$out/lint_joystick_policy.log" 2>&1
echo "PASS lint Joystick_Policy"

echo "--- Lint: APB_ADC_Controller.v ---"
verilator --lint-only -Wall -Wno-fatal "$root/rtl/peripherals/APB_ADC_Controller.v" > "$out/lint_apb_adc.log" 2>&1
echo "PASS lint APB_ADC_Controller"

echo "--- Lint: adc_error_event_cdc.v ---"
verilator --lint-only -Wall -Wno-fatal "$root/rtl/soc/adc_error_event_cdc.v" > "$out/lint_error_cdc.log" 2>&1
echo "PASS lint adc_error_event_cdc"

echo "--- Lint: AMBA_SoC_TOP ---"
verilator --lint-only --sv --timing --relative-includes -Wno-fatal \
    --top-module AMBA_SoC_TOP \
    "${inc[@]}" "${src[@]}" > "$out/lint_soc_top.log" 2>&1
echo "PASS lint AMBA_SoC_TOP"

# 2. RTL Test: tb_joystick_policy
echo "--- Test: tb_joystick_policy ---"
iverilog -g2012 -s tb_joystick_policy -o "$out/tb_joystick_policy.vvp" \
    "$root/rtl/peripherals/Joystick_Policy.v" \
    "$root/verification/directed/adc/tb_joystick_policy.sv" > "$out/compile_joystick_policy.log" 2>&1
vvp "$out/tb_joystick_policy.vvp" > "$out/run_joystick_policy.log" 2>&1
grep -q '^SUMMARY: PASS tb_joystick_policy' "$out/run_joystick_policy.log"
cat "$out/run_joystick_policy.log"
echo "PASS tb_joystick_policy"

# 3. RTL Test: tb_apb_adc_v2
echo "--- Test: tb_apb_adc_v2 ---"
iverilog -g2012 -s tb_apb_adc_v2 -o "$out/tb_apb_adc_v2.vvp" \
    "$root/rtl/peripherals/APB_ADC_Controller.v" \
    "$root/verification/directed/adc/tb_apb_adc_v2.sv" > "$out/compile_apb_v2.log" 2>&1
vvp "$out/tb_apb_adc_v2.vvp" > "$out/run_apb_v2.log" 2>&1
grep -q '^SUMMARY: PASS tb_apb_adc_v2 standalone regression$' "$out/run_apb_v2.log"
cat "$out/run_apb_v2.log"
echo "PASS tb_apb_adc_v2"

# 4. RTL Test: tb_adc_error_event_cdc
echo "--- Test: tb_adc_error_event_cdc ---"
iverilog -g2012 -s tb_adc_error_event_cdc -o "$out/tb_adc_error_event_cdc.vvp" \
    "$root/rtl/soc/adc_error_event_cdc.v" \
    "$root/verification/directed/adc/tb_adc_error_event_cdc.sv" > "$out/compile_error_cdc.log" 2>&1
vvp "$out/tb_adc_error_event_cdc.vvp" > "$out/run_error_cdc.log" 2>&1
grep -q '^SUMMARY: PASS tb_adc_error_event_cdc$' "$out/run_error_cdc.log"
cat "$out/run_error_cdc.log"
echo "PASS tb_adc_error_event_cdc"

# 5. RTL Test: tb_adc_engine_cdc_integration
echo "--- Test: tb_adc_engine_cdc_integration ---"
iverilog -g2012 -s tb_adc_engine_cdc_integration -o "$out/tb_adc_engine_cdc_integration.vvp" \
    "$root/rtl/soc/adc_acquisition_engine.v" \
    "$root/rtl/soc/adc_error_event_cdc.v" \
    "$root/verification/directed/adc/tb_adc_engine_cdc_integration.sv" > "$out/compile_engine_cdc.log" 2>&1
vvp "$out/tb_adc_engine_cdc_integration.vvp" > "$out/run_engine_cdc.log" 2>&1
grep -q '^SUMMARY: PASS tb_adc_engine_cdc_integration$' "$out/run_engine_cdc.log"
cat "$out/run_engine_cdc.log"
echo "PASS tb_adc_engine_cdc_integration"

# 6. RTL Test: tb_soc_bus_fault_adc
echo "--- Test: tb_soc_bus_fault_adc ---"
iverilog -g2012 -s tb_soc_bus_fault_adc -o "$out/tb_soc_bus_fault_adc.vvp" \
    "${inc[@]}" "${src[@]}" \
    "$root/verification/directed/bus/tb_soc_bus_fault_adc.sv" > "$out/compile_bus_fault.log" 2>&1
vvp "$out/tb_soc_bus_fault_adc.vvp" > "$out/run_bus_fault.log" 2>&1
grep -q '^SUMMARY: PASS tb_soc_bus_fault_adc' "$out/run_bus_fault.log"
cat "$out/run_bus_fault.log"
echo "PASS tb_soc_bus_fault_adc"

# 7. RTL Test: tb_soc_adc_v2_integration
echo "--- Test: tb_soc_adc_v2_integration ---"
iverilog -g2012 -s tb_soc_adc_v2_integration -o "$out/tb_soc_adc_v2_integration.vvp" \
    "${inc[@]}" "${src[@]}" \
    "$root/verification/directed/adc/tb_soc_adc_v2_integration.sv" > "$out/compile_soc_v2.log" 2>&1
vvp "$out/tb_soc_adc_v2_integration.vvp" > "$out/run_soc_v2.log" 2>&1
grep -q '^SUMMARY: PASS tb_soc_adc_v2_integration$' "$out/run_soc_v2.log"
cat "$out/run_soc_v2.log"
echo "PASS tb_soc_adc_v2_integration"

# 8. Firmware Host Test: p11c_adc_host_test
echo "--- Test: p11c_adc_host_test ---"
RUN_ROOT="$out/host" bash "$root/scripts/wsl/p11c_adc_host_test.sh" > "$out/run_host.log" 2>&1
grep -q '^SUMMARY: PASS P11C ADC Firmware Host Verification$' "$out/run_host.log"
cat "$out/run_host.log"
echo "PASS p11c_adc_host_test"

# 9. Production Firmware Rebuild: final_main
echo "--- Build: final_main production firmware ---"
RUN_ROOT="$out/fw_build" bash "$root/scripts/firmware/build_fw.sh" final_main > "$out/run_fw_build.log" 2>&1
grep -q '^\[DONE\] firmware built:' "$out/run_fw_build.log"
cat "$out/run_fw_build.log"
echo "PASS build final_main"

# 10. Check no v1 register usage in active firmware
echo "--- Check: active firmware v1 register exclusion ---"
! grep -E "sw.*400500(14|18|24|28|2c|30|34)" "$out/fw_build/fw/final_main/final_main.dis"
echo "PASS zero v1 register accesses in active firmware"

echo "SUMMARY: PASS P11C-C3 Regression Suite"
